#!/bin/bash
# Format gate for pins files — the pins.toml contract: every value is a
# quoted basic string on a flat KEY="value" line (no tables, no arrays,
# no spaces around `=`). That form is valid TOML AND a declaration the
# CLI reads, so the same bytes serve a TOML parser, `source`, and
# bin/snails. This script asserts the repo pins file and a scaffolded
# project's pins file satisfy all three, and that the CLI enforces the
# contract (rejects lines outside it, still reads legacy bare values).
#
# Usage: bash scripts/test-pins-format.sh
# Exit: 0=all cases pass, 1=violation.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT/bin/snails"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
chk() {
  if [[ $2 == "$3" ]]; then
    pass=$((pass + 1))
    echo "ok: $1"
  else
    fail=$((fail + 1))
    echo "FAIL: $1 (exit=$2 want $3)"
  fi
}

# Assert a pins file is (1) valid TOML, (2) inside the flat subset
# (every value a quoted string), (3) dual-valid: `source` yields the
# same values a TOML parser does. Prints violations, exits non-zero.
check_pins_file() {
  python3 - "$1" <<'PY'
import re, sys, tomllib

path = sys.argv[1]
subset = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*="[^"]*"$')
errors = []

try:
    data = tomllib.load(open(path, "rb"))
except Exception as e:
    print(f"{path}: not valid TOML: {e}")
    sys.exit(1)

for i, raw in enumerate(open(path, encoding="utf-8"), 1):
    line = raw.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    if not subset.match(line):
        errors.append(f"{path}:{i}: outside the flat KEY=\"value\" subset: {line}")

for k, v in data.items():
    if not isinstance(v, str):
        errors.append(f"{path}: {k} is {type(v).__name__}, want a quoted string")

for e in errors:
    print(e)
sys.exit(1 if errors else 0)
PY
}

# Assert `source` yields exactly the values a TOML parser sees.
dual_valid() {
  local file="$1" k tv sv
  local keys
  keys="$(python3 - "$file" <<'PY'
import tomllib, sys
for k in sorted(tomllib.load(open(sys.argv[1], "rb"))):
    print(k)
PY
)"
  for k in $keys; do
    tv="$(python3 - "$file" "$k" <<'PY'
import tomllib, sys
print(tomllib.load(open(sys.argv[1], "rb"))[sys.argv[2]])
PY
)"
    sv="$(bash -c 'set +u; source "$1"; printf %s "${!2}"' _ "$file" "$k")"
    if [[ $tv != "$sv" ]]; then
      echo "$file: $k differs: toml=<$tv> shell=<$sv>"
      return 1
    fi
  done
  return 0
}

# 1. the repo pins file satisfies the contract in all three readings
check_pins_file "$ROOT/pins.toml" && dual_valid "$ROOT/pins.toml"
chk "repo pins.toml: TOML + flat subset + dual validity" $? 0

# 2. a scaffolded project's pins file satisfies the same contract
bash "$CLI" new "$WORK/app" >/dev/null 2>&1
chk "new scaffolds a project" $? 0
[[ -f "$WORK/app/pins.toml" ]]
chk "new writes pins.toml" $? 0
check_pins_file "$WORK/app/pins.toml" && dual_valid "$WORK/app/pins.toml"
chk "generated pins.toml: TOML + flat subset + dual validity" $? 0

# 2a. SNALS_SOURCE is part of the declaration contract: an unknown value is
#     refused instead of falling back to a source.
cp "$WORK/app/pins.toml" "$WORK/app-pins.bak"
sed -i 's/^SNALS_SOURCE=.*/SNALS_SOURCE="bogus"/' "$WORK/app/pins.toml"
bash "$CLI" verify-pins "$WORK/app" > "$WORK/source.out" 2>&1
chk "CLI rejects an unknown SNALS_SOURCE" $? 1
grep -q 'SNALS_SOURCE must be "pin" or "checkout"' "$WORK/source.out"
chk "the refusal names the accepted sources" $? 0
cp "$WORK/app-pins.bak" "$WORK/app/pins.toml"

# 2b. the scaffold template keeps the same shape, so the stamped file can
#     only leave it through a substitution (the values are quoted strings
#     until `new` stamps them).
check_pins_file "$ROOT/scaffold/new/pins.toml"
chk "scaffold pins template: TOML + flat subset" $? 0

# 3. the CLI enforces the contract: a table line is an error, not shell
cat > "$WORK/table.toml" <<'CONF'
SNALS_REV="deadbeef"
[tool]
CONF
"$CLI" verify-pin "$WORK/table.toml" > "$WORK/table.out" 2>&1
chk "CLI rejects a table line" $? 1
grep -q 'invalid pins line' "$WORK/table.out"
chk "CLI names the offending line" $? 0

# 4. legacy bare KEY=value (pre-rename files) is still readable — the
#    transition tolerance, pinned by test so it cannot vanish silently
HEAD_REV="$(git -C "$ROOT" rev-parse HEAD)"
printf 'SNALS_REV=%s\n' "$HEAD_REV" > "$WORK/legacy.conf"
"$CLI" verify-pin "$WORK/legacy.conf" >/dev/null 2>&1
chk "CLI reads a legacy bare-value pins file" $? 0

echo "----"
echo "pass=$pass fail=$fail"
if ((fail > 0)); then
  exit 1
fi
exit 0
