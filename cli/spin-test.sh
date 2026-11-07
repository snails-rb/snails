#!/bin/bash
# Harness bundle runner — compile the whole harness target once and run
# each case file in its own process, diffing stdout against that file's
# `.expected` snapshot.
#
# spinel has no per-file incremental build: `spin test` recompiles the
# whole app graph for every test file. This bundles every
# harness/test/**/*_test.rb into one entry point, compiles it once, and
# dispatches by ENV index — the per-file snapshot contract and process
# isolation stay intact.
#
# The gate lives in each case file (`Snails::Harness.file_selected?`). For a
# single file, `cd <spin_root> && spin test harness/test/<file>` still
# works — the harness has no manifest of its own, so it builds from the
# spin root and shares the app's spin.toml.
#
# The gate engine (`snails harness test`) invokes this from the core
# engine tree — the app tree carries no copy of it.
#
# usage: bash cli/spin-test.sh <harness_dir> [--no-cache] [<case file>...]
#   <harness_dir>  the app target's directory (holds test/); the spin
#                  root comes from $SPIN_ROOT when the engine set it
#                  (SPINEL_SRC override), else the harness's parent
#   <case file>    run only these case files; a path under the harness dir
#                  or the spin root (no globbing, no basename matching —
#                  an unknown name fails). Omitted = the whole suite.
set -euo pipefail

die() {
  printf '[snails] %s\n' "$1" >&2
  exit 1
}

# Lexical absolute-path resolution — `File.expand_path` without the tilde
# surprises: `.`/`..` and duplicate slashes are removed, nothing is
# required to exist, and symlinks are left alone.
normalize_path() {
  local path="$1" part result=""
  local -a parts
  # shellcheck disable=SC2088
  case $path in
    "~") path="$HOME" ;;
    "~/"*) path="$HOME/${path#\~/}" ;;
  esac
  if [[ $path != /* ]]; then
    path="$PWD/$path"
  fi
  local IFS=/
  set -f
  # shellcheck disable=SC2206
  parts=($path)
  set +f
  for part in "${parts[@]}"; do
    case $part in
      '' | .) ;;
      ..)
        [[ -z $result ]] || result="${result%/*}"
        ;;
      *) result="$result/$part" ;;
    esac
  done
  printf '%s\n' "${result:-/}"
}

usage="usage: bash cli/spin-test.sh <harness_dir> [--no-cache] [<case file>...]"
(( $# > 0 )) || die "$usage"
[[ -n $1 ]] || die "$usage"
HARNESS="$(normalize_path "$1")"
shift
SPIN_ROOT="${SPIN_ROOT:-}"
if [[ -n $SPIN_ROOT ]]; then
  SPIN_ROOT="$(normalize_path "$SPIN_ROOT")"
else
  SPIN_ROOT="$(normalize_path "$HARNESS/..")"
fi
# The app-tree core dir is owned by cli/vendor-dir.sh; the CLI exports it.
# The literal fallback keeps a direct invocation of this runner working.
VENDOR_DIR="${SNAILS_VENDOR_DIR:-snails-core}"
TEST_DIR="$HARNESS/test"
BUILD_DIR="$HARNESS/build"
BUILD_TEST="$BUILD_DIR/test"
ENTRY="$BUILD_DIR/spin_test_bundle.rb"
BUNDLE="$BUILD_TEST/spin_test_bundle"
SPINEL="${SPINEL:-spinel}"
RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

[[ -d $SPIN_ROOT ]] || die "spin root not found: $SPIN_ROOT"

# The snails CLI is located without embedding a machine path: the CLI
# that set SNAILS_CLI (invoking the harness engine) is authoritative,
# else SNAILS_DIR (the checkout), else `snails` on PATH. Both core
# assembly and the require-all generator are CLI engines.
snails_cli() {
  if [[ -n ${SNAILS_CLI:-} ]]; then
    printf '%s\n' "$SNAILS_CLI"
  elif [[ -n ${SNAILS_DIR:-} ]]; then
    printf '%s\n' "$SNAILS_DIR/bin/snails"
  else
    command -v snails 2>/dev/null || true
  fi
}
CLI="$(snails_cli)"
[[ -n $CLI && -x $CLI ]] || die "snails CLI not found; set SNAILS_DIR to the snails checkout (or put snails on PATH)"

# the vendored core is not committed (S5) — assemble it from the pinned core when
# missing. The gate runner or a prior build may have done it already.
if [[ ! -d $SPIN_ROOT/$VENDOR_DIR ]]; then
  "$CLI" sync "$SPIN_ROOT" || die "core assembly failed"
fi

# require-all files (gen/*): spinel is AOT, so a folder-wide require
# cannot be expressed without codegen. The generator is a core engine
# (`bin/snails gen-require-all`) — the app tree carries no copy of it; the
# content-gated write keeps the source mtimes used below stable.
"$CLI" gen-require-all "$SPIN_ROOT" || die "require-all generation failed (a CLI older than bin/snails gen-require-all cannot serve it — update the CLI)"

# Case files: Ruby's Dir.glob(`**/*_test.rb`) semantics — hidden entries
# are skipped, and the list is byte-sorted (the same contract as the
# previous runner, so selection and the entry order do not drift).
tests=()
if [[ -d $TEST_DIR ]]; then
  while IFS= read -r path; do
    tests+=("$path")
  done < <(find "$TEST_DIR" -mindepth 1 \
    \( -name '.*' -prune \) -o \
    \( -type f -name '*_test.rb' -print \) | LC_ALL=C sort)
fi
(( ${#tests[@]} > 0 )) || die "no test files: $TEST_DIR/**/*_test.rb"

# Resolve one case-file selector against the compiled set. A selector is a
# path — absolute, or relative to the harness dir or the spin root. There is
# no globbing and no basename matching (two dirs may share one): an unknown
# name stops the run and lists what exists, so a typo can never quietly run
# more than the caller asked for.
resolve_case_file() {
  local name="$1" candidate test_path
  local -a candidates=()
  # shellcheck disable=SC2088
  case $name in
    "~") name="$HOME" ;;
    "~/"*) name="$HOME/${name#\~/}" ;;
  esac
  if [[ $name == /* ]]; then
    candidates+=("$(normalize_path "$name")")
  else
    candidates+=("$(normalize_path "$HARNESS/$name")")
    candidates+=("$(normalize_path "$SPIN_ROOT/$name")")
  fi
  for candidate in "${candidates[@]}"; do
    for test_path in "${tests[@]}"; do
      if [[ $test_path == "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  done
  printf '[snails] no such case file: %s\n' "$name" >&2
  printf '[snails] case files (a path under the harness dir or the spin root):\n' >&2
  for test_path in "${tests[@]}"; do
    printf '[snails]   %s\n' "${test_path#"$HARNESS"/}" >&2
  done
  return 1
}

# Case-file selection: positional args name the files to run (see
# `resolve_case_file`). Nothing is selected = the whole suite; the entry
# below still carries every file, so a selection changes only which
# processes run — the compiled bundle and its mtime cache stay valid.
NO_CACHE=0
selectors=()
for arg in "$@"; do
  case $arg in
    --no-cache) NO_CACHE=1 ;;
    --) ;;
    *) selectors+=("$arg") ;;
  esac
done
wanted=()
for name in ${selectors[@]+"${selectors[@]}"}; do
  resolved="$(resolve_case_file "$name")" || exit 1
  wanted+=("$resolved")
done
selected=()
if (( ${#wanted[@]} == 0 )); then
  selected=("${!tests[@]}")
else
  for i in "${!tests[@]}"; do
    for name in "${wanted[@]}"; do
      if [[ ${tests[$i]} == "$name" ]]; then
        selected+=("$i")
        break
      fi
    done
  done
fi

# 1. Bundle entry (require order = SPIN_TEST_INDEX order; each file's
#    `$spin_test_file` assignment is the macro's dispatch gate). Written
#    only when the content changes — a fresh mtime every run would
#    invalidate the cache boundary below.
entry="# generated by cli/spin-test.sh — do not edit"$'\n'
entry+=$'\n'
entry+='require_relative "../boot"'$'\n'
i=0
for path in "${tests[@]}"; do
  rel="${path#"$HARNESS"/}"
  entry+="\$spin_test_file = $i"$'\n'
  entry+="require_relative \"../$rel\""$'\n'
  i=$(( i + 1 ))
done
mkdir -p "$BUILD_DIR"
if [[ ! -f $ENTRY ]] || ! printf '%s' "$entry" | cmp -s - "$ENTRY"; then
  printf '%s' "$entry" > "$ENTRY"
fi

# 2. Compile flags are owned by the pinned spinel (`spin flags`). The
#    harness has no manifest of its own — it compiles from the SPIN ROOT
#    so it SHARES the app's spin.toml (deps, allocator): one manifest for
#    the app and its test target. cwd is the spin root here.
# shellcheck disable=SC2016
flags_line="$( cd "$SPIN_ROOT" && spin flags )" || die '`spin flags` failed'
flags_line="${flags_line%%$'\n'*}"
flags_line="${flags_line#"${flags_line%%[![:space:]]*}"}"
flags_line="${flags_line%"${flags_line##*[![:space:]]}"}"
flags=()
if [[ -n $flags_line ]]; then
  read -r -a flags <<< "$flags_line"
fi

# 3. mtime cache: reuse the bundle when it is newer than every source,
#    the compiler, this runner, and the generated entry. The entry is
#    rewritten only when its require list changes, so a REMOVED case
#    file — which leaves every source mtime alone — still invalidates
#    the cache (a stale bundle would dispatch the wrong file's cases).
cached=0
if [[ -f $BUNDLE && $NO_CACHE -eq 0 ]]; then
  newer_source="$(find "$SPIN_ROOT" -mindepth 1 \
    \( -name '.*' -o -name build -o -name vendor \) -prune -o \
    -type f \( -name '*.rb' -o -name '*.rbs' -o -name '*.c' -o -name '*.h' -o -name spin.toml \) \
    -newer "$BUNDLE" -print -quit)"
  spinel_path="$(command -v "$SPINEL" 2>/dev/null || true)"
  entry_newer=0
  [[ ! -f $ENTRY || ! $ENTRY -nt $BUNDLE ]] || entry_newer=1
  spinel_newer=0
  [[ -z $spinel_path || ! $spinel_path -nt $BUNDLE ]] || spinel_newer=1
  runner_newer=0
  [[ ! $RUNNER -nt $BUNDLE ]] || runner_newer=1
  if [[ -z $newer_source && $entry_newer -eq 0 && $spinel_newer -eq 0 && $runner_newer -eq 0 ]]; then
    cached=1
  fi
fi

if (( cached == 0 )); then
  mkdir -p "$BUILD_TEST"
  printf '[snails] compiling bundle (whole graph once): %s files\n' "${#tests[@]}" >&2
  ( cd "$SPIN_ROOT" && "$SPINEL" "$ENTRY" ${flags[@]+"${flags[@]}"} -O 1 -o "$BUNDLE" ) ||
    die "bundle compilation failed"
fi

# 4. Run and diff per file. Each file gets a fresh process, and the
#    comparison uses stdout — the case output contract. stderr is forwarded
#    as diagnostics (a failure diff should not hide it), so a trace or a
#    warning never changes what a snapshot compares. cwd is the harness dir —
#    cases read their files by relative path there, like a single `spin test`.
#    `selected` keeps the entry's own index per file (a filtered run still
#    dispatches through the same gate).
if (( ${#selected[@]} != ${#tests[@]} )); then
  printf '[snails] running %s of %s case files\n' "${#selected[@]}" "${#tests[@]}" >&2
fi
cached_note=""
if (( cached == 1 )); then
  cached_note=" (cached)"
fi
actual="$(mktemp "${TMPDIR:-/tmp}/spin-test.XXXXXX")"
trap 'rm -f "$actual"' EXIT
fails=0
for i in ${selected[@]+"${selected[@]}"}; do
  path="${tests[$i]}"
  expected="$path.expected"
  [[ -f $expected ]] || die "snapshot missing: $expected"

  if ( cd "$HARNESS" && SPIN_TEST_BUNDLE=1 SPIN_TEST_INDEX="$i" "$BUNDLE" ) >"$actual"; then
    :
  fi
  if cmp -s "$expected" "$actual"; then
    printf 'ok   %s%s\n' "${path##*/}" "$cached_note"
  else
    printf 'FAIL %s\n' "${path##*/}"
    printf '%s\n' '--- expected'
    cat "$expected"
    printf '%s\n' '--- actual'
    cat "$actual"
    fails=$(( fails + 1 ))
  fi
done

printf '%s/%s passed\n' "$(( ${#selected[@]} - fails ))" "${#selected[@]}"
(( fails == 0 )) || exit 1
