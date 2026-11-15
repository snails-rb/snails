#!/bin/bash
# Contract test for scripts/release-smoke.sh — argument validation, the
# SNAILS_DIR refusal, the installed-dist assertion, and the failure report.
#
# The smoke's full path needs the published channel and a compiled app, so the
# release-smoke workflow is where that runs. This gate pins the parts that must
# not drift: exit codes, usage, the dist assertion, and the stage plus
# reproduce line a failed run leaves behind.
#
# The installer is stubbed here: the real install.sh and its channel are
# covered by test-dist.sh, and this file must never touch the network.
#
# Usage: bash scripts/test-release-smoke.sh
# Exit: 0=all cases pass, 1=failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMOKE="$ROOT/scripts/release-smoke.sh"
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
cd "$WORK" || exit 1

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

# 1. Usage and argument contracts.
bash "$SMOKE" --help > help.out 2>&1
chk "--help exits 0" $? 0
grep -q 'usage: bash scripts/release-smoke.sh' help.out
chk "--help prints the usage line" $? 0
bash "$SMOKE" --bogus > bogus.out 2>&1
chk "an unknown argument exits 2" $? 2
grep -q 'unknown argument: --bogus' bogus.out
chk "the unknown argument is named" $? 0
bash "$SMOKE" --rev > rev-missing.out 2>&1
chk "--rev without a value exits 2" $? 2
grep -q -- '--rev needs a value' rev-missing.out
chk "the missing --rev value is named" $? 0
bash "$SMOKE" --rev deadbee > rev-short.out 2>&1
chk "an abbreviated --rev exits 2" $? 2
grep -q 'must be a full 40-hex revision' rev-short.out
chk "the abbreviated --rev is named" $? 0

# 2. The checkout CLI must never be used: SNAILS_DIR is the switch that would
#    turn every step below into source mode.
SNAILS_DIR="$ROOT" bash "$SMOKE" > dir.out 2>&1
chk "SNAILS_DIR is refused" $? 1
grep -q 'SNAILS_DIR is set' dir.out
chk "the refusal names SNAILS_DIR" $? 0

# 3. A failing installer must leave the stage and the reproduce command in the
#    log — the workflow depends on that report to say where it stopped.
cat > bad-install.sh <<'SH'
echo "installer: cannot download" >&2
exit 1
SH
SNAILS_INSTALL_URL="file://$WORK/bad-install.sh" bash "$SMOKE" > bad.out 2>&1
chk "a failing installer fails the smoke" $? 1
grep -q 'FAILED at step 1/6: install the CLI from the published channel' bad.out
chk "the failing stage is named" $? 0
grep -q 'reproduce: bash scripts/release-smoke.sh' bad.out
chk "the reproduce command is printed" $? 0
grep -q 'installer: cannot download' bad.out
chk "the installer output is echoed" $? 0

# 4. A dist symlink under SNAILS_HOME passes the installed-dist assertion. The
#    stub CLI then fails the scaffold step, so the log names step 3.
FAKE_REV="$(printf 'a%.0s' {1..40})"
cat > good-install.sh <<SH
mkdir -p "\$SNAILS_HOME/dist/$FAKE_REV/bin"
printf '%s\n' "$FAKE_REV" > "\$SNAILS_HOME/dist/$FAKE_REV/REV"
cat > "\$SNAILS_HOME/dist/$FAKE_REV/bin/snails" <<'CLI'
#!/bin/bash
if [[ \${1:-} == version ]]; then echo "snails dist (rev aaaaaaa)"; exit 0; fi
echo "stub CLI: no scaffold" >&2
exit 1
CLI
chmod +x "\$SNAILS_HOME/dist/$FAKE_REV/bin/snails"
mkdir -p "\$SNAILS_BIN_DIR"
ln -sfn "\$SNAILS_HOME/dist/$FAKE_REV/bin/snails" "\$SNAILS_BIN_DIR/snails"
SH
SNAILS_INSTALL_URL="file://$WORK/good-install.sh" bash "$SMOKE" > good.out 2>&1
chk "the smoke fails after the dist assertion" $? 1
grep -q "installed: snails dist (rev ${FAKE_REV:0:7})" good.out
chk "the resolved revision is reported" $? 0
grep -q 'FAILED at step 3/6: create a --scaffold project' good.out
chk "the scaffold failure is reported at step 3" $? 0
grep -q "the snails symlink does not point into" good.out
chk "the dist assertion itself passed" $? 1

echo "----"
echo "pass=$pass fail=$fail"
if ((fail > 0)); then
  exit 1
fi
exit 0
