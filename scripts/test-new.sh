#!/bin/bash
# Regression test for the scaffolder (`bin/snails new`) — generates
# projects and runs their harness gates (`bin/test`: build, boot, cases
# against the live server) and dev servers (`bin/dev`: foreground serve;
# the sqlite file survives, the boot banner lands in the app tree's
# tmp/development.log, and the pg canary starts its own dev container when
# PG_URL is absent — loading the schema into a new container only — while
# a provided PG_URL is used as-is, never loaded over).
#
# SUSPENDED (2026-10-31): the demo and pg canaries are off by default
# pending a re-evaluation of their cost — a full run compiles two apps and
# starts three postgres containers. A bare run prints one notice and exits
# 0 without building; `--only=demo|pg` runs one canary explicitly.
#
# Acceptance is a FIXED set of canaries plus a cheap option matrix —
# not the options cartesian product. The canaries compile, so their
# count must not grow with scaffolder options:
#
#   demo — the --scaffold (posts/comments) template on the default adapter,
#          plus a model declared under a namespace (its file is scanned,
#          generated, and hydrated). The same app carries the runner/dev
#          contracts — pin gate, port guard, test.env port guard, case
#          selection, sqlite dev DB, pending migrations, --fresh, stale
#          core — and the legacy-layout guard. The destructive steps
#          run last.
#   pg   — the --scaffold template on the pg adapter: the adapter's ONE
#          canary (pg boot, BIGSERIAL DDL, CRUD, dev contract).
#
# New options add text assertions to scripts/test-cli.sh (no compile),
# never a new test-new app; a new core adapter adds exactly one canary.
# The bare `new` output is asserted by test-cli (files, stamps, no runner
# copies) and the demo app starts from that same skeleton, so it covers the
# boot path without a third compiled app.
#
# One canary runs per invocation (--only). Every port this run uses is
# picked free and distinct up front — gate ports, dev ports, the guarded
# foreign listeners, and the docker host ports — so parallel test-new runs
# (and anything else on the machine) cannot collide; a shared fixed port
# lets a foreign listener answer the readiness probe and silence a broken
# app. Each role keeps an env override to pin an exact port for debugging.
# Output is tagged [demo]/[pg].
#
# The `--scaffold` template ships one DDL per adapter (sqlite rowid PK vs
# pg BIGSERIAL); `new` stamps the adapter's file as the first migration
# under a UTC version and writes no db/schema.sql — `migrate dump`
# generates the snapshot, and the canaries run that command next.
#
# Usage: bash scripts/test-new.sh [--only=demo|pg]
# Exit: 0=PASS or suspended, 1=failure, 2=usage.
set -euo pipefail

usage() {
  echo "[test-new] usage: bash scripts/test-new.sh [--only=demo|pg] (a bare run is suspended)" >&2
}

ONLY=""
while (($#)); do
  case "$1" in
    --only=demo | --only=pg) ONLY="${1#--only=}" ;;
    --only)
      ONLY="${2:-}"
      case "$ONLY" in
        demo | pg) ;;
        *)
          usage
          exit 2
          ;;
      esac
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "[test-new] unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

# A bare run used to compile two apps and start three postgres containers,
# which dominated the edit loop. The canaries are suspended until that cost
# is re-evaluated; --only is the deliberate opt-in for measuring them.
if [[ -z $ONLY ]]; then
  echo "[test-new] e2e canaries are suspended (demo, pg) — run 'bash scripts/test-new.sh --only=demo' or '--only=pg' to run one"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../cli/vendor-dir.sh
source "$ROOT/cli/vendor-dir.sh"

WORK="$(mktemp -d)"
# Two pg-adapter dev containers: the runner's own (auto-provisioned from the
# app's APP_NAME) and the developer-provided one the PG_URL probe uses.
# The PID suffix keeps both names unique to this run — the defaults
# (<APP_NAME>-dev-pg, a fixed marker name) are shared by every concurrent
# test-new run and would delete each other's containers mid-flight. Both
# are removed even on failure so a red run does not leak a listener/DB
# into the next one. The pg gate's one-shot container is named per run by
# the runner (its own EXIT trap removes it).
AUTO_PG_CONTAINER="snails-testnew-auto-$$"
DEV_PG_CONTAINER="snails-testnew-marker-$$"
# Named in the parent: the canary runs in a subshell, so only a name the
# parent already owns can reach this cleanup when the run dies early.
DUMP_PG_CONTAINER="snails_dump_pg_$$"
PID_D=""
PID_P=""
cleanup() {
  if [[ -n $PID_D ]]; then kill "$PID_D" 2>/dev/null || true; fi
  if [[ -n $PID_P ]]; then kill "$PID_P" 2>/dev/null || true; fi
  # Canaries die first, then sweep whatever their command chains left
  # behind (the engine forks a server; killing the canary does not reap
  # it) and the foreign listeners recorded at startup.
  if command -v pkill >/dev/null 2>&1; then
    pkill -f "$WORK/" 2>/dev/null || true
  fi
  if [[ -f "$WORK/listeners.pid" ]]; then
    local lp
    while read -r lp; do kill "$lp" 2>/dev/null || true; done < "$WORK/listeners.pid"
  fi
  rm -rf "$WORK"
  if [[ -n $DUMP_PG_CONTAINER ]]; then
    docker rm -fv "$AUTO_PG_CONTAINER" "$DEV_PG_CONTAINER" "$DUMP_PG_CONTAINER" >/dev/null 2>&1 || true
  else
    docker rm -fv "$AUTO_PG_CONTAINER" "$DEV_PG_CONTAINER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Every port this run touches is picked free and distinct in ONE
# subshell: the canaries run concurrently, so roles must not share a
# port (the stray listener and the pg dev server both defaulted to
# 4193), and a fixed default collides with a parallel test-new run or
# any other listener on the machine. Env overrides pin a role to an
# exact port for debugging.
pick_ports() {
  local taken=" " tries port out="" v
  for v in "$@"; do
    if [[ -n $v ]]; then
      out="$out$v "
      taken="$taken$v "
      continue
    fi
    tries=0
    while :; do
      tries=$((tries + 1))
      if (( tries > 60 )); then
        echo "[test-new] no free port left to pick" >&2
        return 1
      fi
      port=$((49152 + RANDOM % 16384))
      case "$taken" in *" $port "*) continue ;; esac
      if (echo > /dev/tcp/127.0.0.1/"$port") 2>/dev/null; then continue; fi
      out="$out$port "
      taken="$taken$port "
      break
    done
  done
  printf '%s\n' "${out% }"
}
read -r OCCUPIED_PORT STRAY_PORT DEV_PORT PORT_DEMO PORT_PG DEV_PG_HTTP DEV_PG_PORT MARKER_PORT <<< "$(
  pick_ports "${OCCUPIED_PORT:-}" "${STRAY_PORT:-}" "${DEV_PORT:-}" \
    "${PORT_DEMO:-}" "${PORT_PG:-}" "${DEV_PG_HTTP:-}" \
    "${DEV_PG_PORT:-}" "${MARKER_PORT:-}"
)"
[[ -n $OCCUPIED_PORT && -n $STRAY_PORT && -n $DEV_PORT && -n $PORT_DEMO &&
  -n $PORT_PG && -n $DEV_PG_HTTP && -n $DEV_PG_PORT && -n $MARKER_PORT ]] || {
  echo "[test-new] port pool pick failed" >&2
  exit 1
}

# The two foreign listeners bind right after the pick — the gap between
# picking and binding is where a parallel run could claim the same port,
# and a loud bind failure beats a confusing assert much later. Their PIDs
# are recorded so cleanup takes them down even when a canary dies first.
start_listener() {
  local port="$1" role="$2" pid
  python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 &
  pid=$!
  sleep 1
  kill -0 "$pid" 2>/dev/null || {
    echo "[test-new] could not bind the $role port $port (another run holding it?)" >&2
    exit 1
  }
  printf '%s\n' "$pid" >> "$WORK/listeners.pid"
}
start_listener "$OCCUPIED_PORT" occupied
start_listener "$STRAY_PORT" stray

# GET /up readiness — curl when present (proves the route), else the
# port-open probe the gate runner uses.
probe_up() {
  if command -v curl >/dev/null 2>&1; then
    curl -sf "http://127.0.0.1:$1/up" >/dev/null 2>&1
  else
    (echo > /dev/tcp/127.0.0.1/"$1") 2>/dev/null
  fi
}

# Boot bin/dev in the background, wait for /up, then stop it. Fails loud
# with the server log when the boot never answers or the process dies.
# The stop is a contract: the stamped wrapper execs into the CLI, the
# CLI execs into the engine, and the engine execs into the server — one
# PID for the whole chain — so this kill must reach the server; the probe
# then verifies no app binary outlived it (a forked engine would leak a
# live listener holding the port).
dev_probe() {
  local port="$1" log="$2" app="$3"
  shift 3
  "$@" >"$log" 2>&1 &
  local pid=$!
  local up=""
  local i
  for i in $(seq 1 60); do
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    if probe_up "$port"; then up=1; break; fi
    sleep 1
  done
  if [[ -z $up ]]; then
    echo "[test-new] dev server did not answer GET /up (port $port). log:" >&2
    cat "$log" >&2
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    exit 1
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if command -v pgrep >/dev/null 2>&1 &&
    pgrep -f "$app/build/bin/" >/dev/null 2>&1; then
    echo "[test-new] dev server outlived its own stop: $app/build/bin (the CLI must exec into the engine)" >&2
    pkill -f "$app/build/bin/" 2>/dev/null || true
    exit 1
  fi
}

canary_demo() {
  # The --scaffold template on the default adapter: posts + nested comments
  # schema, models, CRUD controllers, and the harness cases that drive them
  # over real HTTP. The same app carries the runner/dev contracts that used
  # to live in the bare canary (pin gate, port guard, case selection, sqlite
  # dev DB, pending migrations, --fresh, stale core) and a model declared
  # under a namespace, so the scan spec, the column generator, and the
  # compiled attach are all exercised. The legacy-layout and stale-core
  # proofs are destructive, so they run last.
  local APP="$WORK/demo"
  echo "[test-new] scaffolding $APP (--scaffold, default adapter)"
  "$ROOT/bin/snails" new "$APP" --scaffold >/dev/null
  [[ -d "$APP/storage" ]] || {
    echo "[test-new] new --scaffold did not create the sqlite storage directory" >&2
    exit 1
  }
  # The scaffold ships the baseline as a migration only: one UTC-versioned
  # file, both template variants gone, and no db/schema.sql — the
  # snapshot is `migrate dump`'s output (run further below).
  local baseline_file
  baseline_file="$(printf '%s\n' "$APP"/db/migrate/[0-9]*_baseline.sql)"
  [[ $baseline_file == "$APP"/db/migrate/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_baseline.sql ]] || {
    echo "[test-new] new --scaffold did not stamp a UTC baseline migration" >&2
    exit 1
  }
  [[ ! -e $APP/db/migrate/0001_baseline.sqlite.sql && ! -e $APP/db/migrate/0001_baseline.pg.sql ]] || {
    echo "[test-new] new --scaffold left a template variant in db/migrate" >&2
    exit 1
  }
  [[ ! -e $APP/db/schema.sql ]] || {
    echo "[test-new] new --scaffold wrote db/schema.sql (migrate dump owns it)" >&2
    exit 1
  }
  echo "[test-new] require-all generator agrees with the demo template ($APP)"
  "$ROOT/bin/snails" gen-require-all "$APP" --check

  # The scaffolder materializes the pinned spinel toolchain next to the
  # app's pins.toml (gitignored state, never source) — every compile in
  # this tree runs the pin, not whatever is on PATH.
  [[ -x "$APP/.spinel/toolchain/spin" && -x "$APP/.spinel/toolchain/spinel" ]] || {
    echo "[test-new] snails new did not materialize the pinned toolchain (.spinel/toolchain)" >&2
    exit 1
  }
  grep -q '^/.spinel/$' "$APP/.gitignore" || {
    echo "[test-new] the generated .gitignore does not ignore /.spinel/" >&2
    exit 1
  }
  # shellcheck source=/dev/null
  source "$APP/pins.toml"
  # `spin --version` prints a short prefix of its source rev while a pin
  # may carry a longer one, so compare the way the toolchain resolver
  # does — either side is a prefix of the other, never literal inclusion.
  reported_rev="$("$APP/.spinel/toolchain/spin" --version 2>/dev/null | grep -oE '[0-9a-f]{7,40}' | head -n1 || true)"
  if [[ -z $reported_rev ]]; then
    echo "[test-new] the materialized toolchain reports no rev (pin $SPINEL_REV)" >&2
    exit 1
  fi
  if [[ $reported_rev != "$SPINEL_REV"* && $SPINEL_REV != "$reported_rev"* ]]; then
    echo "[test-new] the materialized toolchain reports $reported_rev, not the pins rev $SPINEL_REV" >&2
    exit 1
  fi

  # A namespaced model: `app/models/snails/queue_row.rb` declares its class
  # inside `module Snails`, so the scan spec must reach the subfolder and
  # the generated attach must reopen that class. Attaching to a fresh
  # top-level class instead is silent — the model just keeps the core
  # defaults — so both the wiring and the hydration are pinned here.
  # queue_rows enters through a migration, the way any schema change
  # does: `migrate dump` regenerates the snapshot from the files (the
  # step `new --scaffold` leaves to the user), and a fresh scaffold tree
  # must be verify-clean right after it.
  local queue_version
  queue_version=$(( $(basename "$baseline_file" | cut -d_ -f1) + 1 ))
  printf 'CREATE TABLE IF NOT EXISTS queue_rows (id INTEGER PRIMARY KEY, name TEXT NOT NULL, status TEXT, scheduled_at DATETIME, created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL);\n' \
    > "$APP/db/migrate/${queue_version}_add_queue_rows.sql"
  echo "[test-new] migrate dump generates the snapshot from the migrations ($APP)"
  "$ROOT/bin/snails" migrate dump --app "$APP" >/dev/null
  [[ -f "$APP/db/schema.sql" ]] || {
    echo "[test-new] migrate dump wrote no db/schema.sql" >&2
    exit 1
  }
  if ! "$ROOT/bin/snails" migrate verify --app "$APP" >/dev/null 2>&1; then
    echo "[test-new] the fresh scaffold is not verify-clean after migrate dump" >&2
    exit 1
  fi
  mkdir -p "$APP/app/models/snails"
  cat > "$APP/app/models/snails/queue_row.rb" <<'RB'
module Snails
  class QueueRow < Sqlx::Base
    class << self
      def table_name = "queue_rows"
    end
  end
end
RB
  cat > "$APP/harness/test/queue_row_test.rb" <<'RB'
# A model declared under a namespace — `app/models/snails/queue_row.rb`
# opens `module Snails`, so every piece the column generator writes has to
# reach `Snails::QueueRow`: the COLUMNS constant, the datetime declaration,
# and the readers. A generated attach that landed on a top-level `QueueRow`
# would leave this model on the core defaults instead.
require_relative "../boot"

if Snails::Harness.file_selected?
  class QueueRowTest < Snails::Harness::IntegrationTest
    def tables
      ["queue_rows"]
    end

    test "the generated column metadata reaches the namespaced model" do
      assert_equal ["id", "name", "status", "scheduled_at", "created_at", "updated_at"],
                   Snails::QueueRow::COLUMNS
      assert_equal ["created_at", "scheduled_at", "updated_at"], Snails::QueueRow.datetime_columns.sort
      assert_equal 6, Snails::QueueRow.only_columns.length
    end

    test "the generated readers hydrate the namespaced model" do
      Snails::QueueRow.create!({ name: "row one", status: "pending" })
      saved = Snails::QueueRow.find_by({ name: "row one" })
      assert_equal "pending", saved.status
      assert_equal false, saved.created_at.nil?
    end
  end
end
RB
  printf 'ok the generated column metadata reaches the namespaced model\nok the generated readers hydrate the namespaced model\n' \
    > "$APP/harness/test/queue_row_test.rb.expected"

  # The scaffolded bin/test must keep gen/* fresh on its own: drop in a
  # controller file and let the same gate run pick it up — the generator is
  # wired, not a manual step.
  mkdir -p "$APP/app/controllers"
  cat > "$APP/app/controllers/ping_controller.rb" <<'RB'
class PingController
end
RB

  # The selection probe is created BEFORE the first gate run: the bundle
  # runner compiles the whole case set once, and a case file added after
  # that first compile would invalidate the bundle and force a second
  # compile.
  cat > "$APP/harness/test/selection_probe_test.rb" <<'RB'
require_relative "../boot"

if Snails::Harness.file_selected?
  class SelectionProbeTest < Snails::Harness::IntegrationTest
    test "selection probe answers /up" do
      get("/up")
      assert_response(:ok)
    end
  end
end
RB
  printf 'ok selection probe answers /up\n' > "$APP/harness/test/selection_probe_test.rb.expected"

  # Pin gate — the engine's step 0 checks the declaration itself: a
  # pair-record mismatch stops the run before any build, with the repair
  # line. It runs before the toolchain is materialized, so the failure is
  # immediate instead of starting a spinel source clone — the wrapper
  # carries no check of its own, so this is the only gate in the path.
  echo "[test-new] pin gate stops a mismatched pair before the build ($APP/bin/test)"
  cp "$APP/pins.toml" "$WORK/demo-pins.bak"
  sed -i 's/^SPINEL_REV=.*/SPINEL_REV="deadbeef"/' "$APP/pins.toml"
  if out=$(SNAILS_DIR="$ROOT" "$APP/bin/test" 2>&1); then
    cp "$WORK/demo-pins.bak" "$APP/pins.toml"
    echo "[test-new] the pin gate passed a mismatched spinel pair" >&2
    exit 1
  fi
  cp "$WORK/demo-pins.bak" "$APP/pins.toml"
  grep -q 'is not the rev declared' <<<"$out" &&
    grep -q 'set SPINEL_REV=' <<<"$out" &&
    grep -q "snails sync $APP" <<<"$out" || {
    echo "[test-new] the pin gate does not name the declared rev and the repair" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
  [[ ! -d "$APP/build" ]] || {
    echo "[test-new] the pin gate built before reporting the mismatch" >&2
    exit 1
  }

  echo "[test-new] harness gate with the scaffold resources ($APP/bin/test)"
  PORT="$PORT_DEMO" SNAILS_DIR="$ROOT" "$APP/bin/test"
  grep -q 'require_relative "../app/models/snails/queue_row"' "$APP/gen/models.rb" || {
    echo "[test-new] the scan spec did not reach the namespaced model file" >&2
    exit 1
  }
  grep -q 'extend GeneratedModelColumns::Snails::QueueRow' "$APP/gen/model_columns.rb" || {
    echo "[test-new] the column generator did not attach inside the model's namespace" >&2
    exit 1
  }
  if ! grep -q 'app/controllers/ping_controller' "$APP/gen/controllers.rb"; then
    echo "[test-new] the scaffolded bin/test did not pick up a new controller file" >&2
    exit 1
  fi

  # port guard — a foreign process holding the port answers the ready probe,
  # so the gate must refuse to run instead of talking to someone else's
  # listener (the post-probe liveness check alone cannot catch this: the
  # probe returns immediately while our server is still booting). The
  # listener was bound at startup (its port is this run's own pick).
  if out=$(PORT="$OCCUPIED_PORT" SNAILS_DIR="$ROOT" "$APP/bin/test" 2>&1); then
    echo "[test-new] port guard missing: the gate passed with the port taken" >&2
    exit 1
  fi
  grep -q "port $OCCUPIED_PORT is already in use" <<<"$out" || {
    echo "[test-new] port guard missing: no in-use report" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }

  # test.env is server-only app switches: a PORT= line there must not move
  # the gate at all — a diverging probe/boot pair is a deterministic boot
  # failure, and honoring the line would steer the server onto a busy
  # port. The default-port gate must still pass while test.env points at
  # a foreign listener.
  printf 'PORT=%s\n' "$STRAY_PORT" > "$APP/harness/test.env"
  echo "[test-new] test.env PORT= line is ignored ($APP/bin/test)"
  local stray_rc=0
  SNAILS_DIR="$ROOT" "$APP/bin/test" || stray_rc=$?
  rm -f "$APP/harness/test.env"
  (( stray_rc == 0 )) || {
    echo "[test-new] the default-port gate must pass while test.env points at a foreign listener" >&2
    exit 1
  }

  # Case-file selection — a positional name runs only that file, and a name
  # that does not resolve stops the run (it must never widen to the whole
  # suite). Seven case files exist here (the scaffold's six plus the probe
  # created above), so "only the selected one ran" is observable: the
  # selection line and the 1/1 count, with no mention of the unselected
  # file. The bundle was compiled at the first gate, so these runs reuse it.
  echo "[test-new] a case-file argument selects only that file ($APP/bin/test)"
  local sel_out=""
  if ! sel_out=$(SNAILS_DIR="$ROOT" "$APP/bin/test" -- test/up_test.rb 2>&1); then
    echo "[test-new] selecting a case file failed" >&2
    printf '%s\n' "$sel_out" >&2
    exit 1
  fi
  grep -q 'running 1 of 7 case files' <<<"$sel_out" &&
    grep -q '1/1 passed' <<<"$sel_out" &&
    ! grep -q 'selection_probe' <<<"$sel_out" || {
    echo "[test-new] the case-file argument did not narrow the run" >&2
    printf '%s\n' "$sel_out" >&2
    exit 1
  }
  echo "[test-new] an unknown case-file argument fails without running the suite ($APP/bin/test)"
  if out=$(SNAILS_DIR="$ROOT" "$APP/bin/test" -- test/no_such_probe_test.rb 2>&1); then
    echo "[test-new] an unknown case file ran anyway" >&2
    exit 1
  fi
  grep -q 'no such case file: test/no_such_probe_test.rb' <<<"$out" &&
    ! grep -q 'passed' <<<"$out" || {
    echo "[test-new] the unknown case file was not refused loudly" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }

  # dev server, default adapter — bin/dev serves in the foreground and its DB
  # must survive (unlike the gate's throwaway database): the development
  # sqlite file is still there after the server stops. --skip-build: the
  # gate just built the same binary. The development database does not exist:
  # the first boot stops and prints the explicit load command. The runner
  # never creates, loads, or applies anything.
  echo "[test-new] fresh dev stops on the pending baseline ($APP/bin/dev)"
  if out=$(PORT="$DEV_PORT" SNAILS_DIR="$ROOT" "$APP/bin/dev" --skip-build 2>&1); then
    echo "[test-new] dev served before the explicit load (must stop)" >&2
    exit 1
  fi
  grep -q 'pending migration' <<<"$out" &&
    grep -q "snails migrate load" <<<"$out" || {
    echo "[test-new] the fresh-dev gate does not name the load repair" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
  "$ROOT/bin/snails" migrate status --app "$APP" > "$WORK/dev-status.out" 2>&1
  grep -q '0 applied' "$WORK/dev-status.out" || {
    echo "[test-new] the dev runner applied migrations on its own (ledger is not empty)" >&2
    cat "$WORK/dev-status.out" >&2
    exit 1
  }
  [[ ! -f "$APP/storage/development.sqlite3" ]] || {
    echo "[test-new] the dev runner provisioned the sqlite target before the explicit load" >&2
    exit 1
  }
  echo "[test-new] loading the baseline unblocks dev ($APP/bin/dev)"
  "$ROOT/bin/snails" migrate load --app "$APP" >/dev/null
  dev_probe "$DEV_PORT" "$WORK/dev.log" "$APP" \
    env PORT="$DEV_PORT" SNAILS_DIR="$ROOT" "$APP/bin/dev" --skip-build
  [[ -f "$APP/storage/development.sqlite3" ]] || {
    echo "[test-new] dev server left no development DB (storage/development.sqlite3)" >&2
    exit 1
  }
  # The dev server mirrors its output to the app tree's tmp/development.log
  # (append-only, under the gitignored tmp/). The boot banner must reach
  # it — retried briefly because tee may still be flushing after the
  # server is gone.
  local dev_log_ok=""
  local _i
  for _i in $(seq 1 10); do
    if grep -q "listening on" "$APP/tmp/development.log" 2>/dev/null; then dev_log_ok=1; break; fi
    sleep 0.5
  done
  if [[ -z $dev_log_ok ]]; then
    echo "[test-new] dev server wrote no boot banner to tmp/development.log" >&2
    cat "$APP/tmp/development.log" 2>/dev/null >&2
    exit 1
  fi

  # Pending migrations stop the dev server before the build. A consumer
  # dev DB answered /up while background jobs failed on a missing table, so
  # the gate must name the repair and keep the labels behind --verbose; the
  # apply step then lets the same DB serve, and --fresh recreates the DB so
  # the explicit load records its ledger (the next boot must not see it as
  # pending).
  echo "[test-new] dev stops on a pending migration ($APP/bin/dev)"
  mkdir -p "$APP/db/migrate"
  cat > "$APP/db/migrate/20261030000000_add_dev_probe.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS dev_probe (id INTEGER PRIMARY KEY);
SQL
  if out=$(PORT="$DEV_PORT" SNAILS_DIR="$ROOT" "$APP/bin/dev" --skip-build 2>&1); then
    echo "[test-new] dev served with a pending migration (must stop)" >&2
    exit 1
  fi
  grep -q 'pending migration' <<<"$out" &&
    grep -q "snails migrate apply" <<<"$out" || {
    echo "[test-new] the pending gate does not name the repair" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
  grep -q '20261030000000_add_dev_probe' <<<"$out" && {
    echo "[test-new] the pending gate lists files without --verbose" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
  if out=$(PORT="$DEV_PORT" SNAILS_DIR="$ROOT" "$APP/bin/dev" --skip-build --verbose 2>&1); then
    echo "[test-new] verbose dev served with a pending migration (must stop)" >&2
    exit 1
  fi
  grep -q 'pending 20261030000000_add_dev_probe' <<<"$out" || {
    echo "[test-new] --verbose does not list the pending label" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
  echo "[test-new] applying the pending migration unblocks dev ($APP/bin/dev)"
  "$ROOT/bin/snails" migrate apply --app "$APP" >/dev/null
  dev_probe "$DEV_PORT" "$WORK/dev-after-apply.log" "$APP" \
    env PORT="$DEV_PORT" SNAILS_DIR="$ROOT" "$APP/bin/dev" --skip-build

  cat > "$APP/db/migrate/20261030000100_add_fresh_probe.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS fresh_probe (id INTEGER PRIMARY KEY);
SQL
  echo "[test-new] --fresh recreates the database and stops for the explicit load ($APP/bin/dev)"
  if out=$(PORT="$DEV_PORT" SNAILS_DIR="$ROOT" "$APP/bin/dev" --skip-build --fresh 2>&1); then
    echo "[test-new] --fresh served before the explicit load (must stop)" >&2
    exit 1
  fi
  grep -q 'pending migration' <<<"$out" &&
    grep -q "snails migrate load" <<<"$out" || {
    echo "[test-new] the --fresh gate does not name the load repair" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
  [[ ! -f "$APP/storage/development.sqlite3" ]] || {
    echo "[test-new] --fresh provisioned the sqlite target before the explicit load" >&2
    exit 1
  }
  "$ROOT/bin/snails" migrate load --app "$APP" >/dev/null
  echo "[test-new] the applied ledger keeps the next boot clean ($APP/bin/dev)"
  dev_probe "$DEV_PORT" "$WORK/dev-fresh-rerun.log" "$APP" \
    env PORT="$DEV_PORT" SNAILS_DIR="$ROOT" "$APP/bin/dev" --skip-build

  # The dev runner shares the declaration gate: a broken pair stops the
  # server before anything is served.
  echo "[test-new] dev gate stops a mismatched pair ($APP/bin/dev)"
  cp "$APP/pins.toml" "$WORK/demo-pins.bak"
  sed -i 's/^SPINEL_REV=.*/SPINEL_REV="deadbeef"/' "$APP/pins.toml"
  if out=$(PORT="$DEV_PORT" SNAILS_DIR="$ROOT" "$APP/bin/dev" --skip-build 2>&1); then
    cp "$WORK/demo-pins.bak" "$APP/pins.toml"
    echo "[test-new] the dev runner passed a mismatched spinel pair (must fail)" >&2
    exit 1
  fi
  cp "$WORK/demo-pins.bak" "$APP/pins.toml"
  grep -q 'is not the rev declared' <<<"$out" || {
    echo "[test-new] the dev pin gate: no pair-mismatch report" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }

  # legacy layout guard — schema files at the retired config/ path must fail
  # loudly with the loader's stale-layout message. A silent skip would boot
  # on stub tables and pass every non-DB case, so this locks the raise
  # itself as the contract. The gate's default output is one line naming
  # the kept log — the raise is read from that log.
  echo "[test-new] legacy layout guard ($APP/bin/test with config/schema.sql)"
  echo "-- retired layout" > "$APP/config/schema.sql"
  if out=$(PORT="$PORT_DEMO" SNAILS_DIR="$ROOT" "$APP/bin/test" 2>&1); then
    echo "[test-new] legacy layout guard missing: the gate passed with config/schema.sql" >&2
    exit 1
  fi
  stale_log="$(sed -n 's/^.*log kept: //p' <<<"$out" | tail -n1)"
  if [[ -z $stale_log || ! -f $stale_log ]]; then
    echo "[test-new] legacy layout guard missing: no kept-log path in the gate output" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  grep -q "stale schema layout" "$stale_log" || {
    echo "[test-new] legacy layout guard missing: no stale-layout report in $stale_log" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
  rm -rf "$(dirname "$stale_log")"   # the failure deliberately kept it; the test reads and clears it
  rm -f "$APP/config/schema.sql"

  # snails-core/ freshness — the gate compiles a core only when pins.toml says
  # so. A stray file under snails-core/ is content drift the pin does not
  # declare, so the gate must stop before the build (removing build/ proves
  # it stopped there, not after a compile) and name the repair; --force
  # continues, loudly, for deliberate local edits (the stamped wrapper
  # forwards it, so this is the developer's own path). This is the last
  # step: it deletes build/.
  printf 'stray\n' > "$APP/$SNAILS_VENDOR_DIR/stale-probe.txt"
  echo "[test-new] stale-core --force continues loudly ($APP/bin/test)"
  local forced_out=""
  if ! forced_out=$(SNAILS_DIR="$ROOT" "$APP/bin/test" --force 2>&1); then
    echo "[test-new] --force did not run the gate" >&2
    printf '%s\n' "$forced_out" >&2
    exit 1
  fi
  grep -q 'as-is, not checked against its declared source (--force)' <<<"$forced_out" || {
    echo "[test-new] --force continued silently (no core-check report)" >&2
    printf '%s\n' "$forced_out" >&2
    exit 1
  }
  rm -rf "$APP/build"
  echo "[test-new] stale core stops the gate before the build ($APP/bin/test)"
  if out=$(SNAILS_DIR="$ROOT" "$APP/bin/test" 2>&1); then
    echo "[test-new] stale-core guard missing: the gate passed on a drifted core" >&2
    exit 1
  fi
  grep -q 'stopped before the build' <<<"$out" &&
    grep -q "run: snails sync" <<<"$out" &&
    grep -q -- '--force' <<<"$out" || {
    echo "[test-new] stale-core guard does not name the repair and the escape" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
  [[ ! -d "$APP/build" ]] || {
    echo "[test-new] the gate built before reporting the drifted core" >&2
    exit 1
  }
  rm -f "$APP/$SNAILS_VENDOR_DIR/stale-probe.txt"
}

canary_pg() {
  # the pg adapter's ONE canary: the --scaffold template on pg (pg boot,
  # BIGSERIAL DDL, CRUD over real HTTP) plus the pg dev server contract.
  # Available when docker and psql are (its gate starts a one-shot
  # postgres container).
  if ! command -v docker >/dev/null || ! command -v psql >/dev/null; then
    echo "[test-new] docker/psql not found — pg canary skipped"
    return 0
  fi
  local PG_APP="$WORK/demopg"
  echo "[test-new] scaffolding $PG_APP (--scaffold, pg adapter)"
  "$ROOT/bin/snails" new "$PG_APP" --scaffold --database=postgresql >/dev/null
  # Same shape as the sqlite scaffold: baseline as a UTC migration, no
  # snapshot — and on pg `migrate dump` needs a server to replay into
  # (a throwaway schema), so a scratch container carries that one command
  # and is dropped before the dev scenarios start their own.
  local pg_baseline
  pg_baseline="$(printf '%s\n' "$PG_APP"/db/migrate/[0-9]*_baseline.sql)"
  [[ $pg_baseline == "$PG_APP"/db/migrate/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_baseline.sql &&
      ! -e $PG_APP/db/migrate/0001_baseline.sqlite.sql &&
      ! -e $PG_APP/db/migrate/0001_baseline.pg.sql &&
      ! -e $PG_APP/db/schema.sql ]] || {
    echo "[test-new] pg new --scaffold must stamp the baseline migration and write no snapshot" >&2
    exit 1
  }
  docker run -d --name "$DUMP_PG_CONTAINER" --tmpfs /var/lib/postgresql \
    -e POSTGRES_PASSWORD=postgres -p 5432 postgres:18-alpine >/dev/null
  local dump_port dump_ready="" _di
  dump_port="$(docker port "$DUMP_PG_CONTAINER" 5432/tcp | head -n1 | sed 's/.*://')"
  local dump_url="postgres://postgres:postgres@127.0.0.1:$dump_port/postgres"
  # Readiness is a host-side psql probe, not pg_isready inside the
  # container: during postgres' init phase the temporary server answers
  # on the container's socket while TCP is not accepting yet, so an
  # in-container probe passes seconds before the mapped port works.
  for _di in $(seq 1 150); do
    if psql "$dump_url" -tAc "SELECT 1" >/dev/null 2>&1; then dump_ready=1; break; fi
    if ! docker inspect -f '{{.State.Running}}' "$DUMP_PG_CONTAINER" 2>/dev/null | grep -q true; then
      break
    fi
    sleep 0.2
  done
  if [[ -z $dump_ready ]]; then
    echo "[test-new] the dump scratch container did not start" >&2
    exit 1
  fi
  echo "[test-new] migrate dump generates the pg snapshot from the migrations ($PG_APP)"
  PG_URL="$dump_url" "$ROOT/bin/snails" migrate dump --app "$PG_APP" >/dev/null
  [[ -f "$PG_APP/db/schema.sql" ]] || {
    echo "[test-new] pg migrate dump wrote no db/schema.sql" >&2
    exit 1
  }
  if ! PG_URL="$dump_url" "$ROOT/bin/snails" migrate verify --app "$PG_APP" >/dev/null 2>&1; then
    echo "[test-new] the fresh pg scaffold is not verify-clean after migrate dump" >&2
    exit 1
  fi
  docker rm -f "$DUMP_PG_CONTAINER" >/dev/null 2>&1
  echo "[test-new] harness gate with the scaffold resources on pg ($PG_APP/bin/test)"
  PORT="$PORT_PG" SNAILS_DIR="$ROOT" "$PG_APP/bin/test"

  # dev server, pg adapter — two paths. Without PG_URL the runner starts its
  # own persistent development container (named from the app's APP_NAME); the
  # database inside starts empty and the first boot stops with the explicit
  # `migrate load` command — the runner never loads or applies anything.
  # The explicit load creates `posts` and the ledger; a reused container
  # keeps its data. With PG_URL the database belongs to the developer: the
  # gate stops until they run `migrate load` against it themselves, and
  # after that it is used as-is — no container, no loader, existing data
  # survives.
  # PG_CONTAINER_NAME pins this run's own container name: the
  # APP_NAME-derived default is shared by every concurrent run of this
  # suite and would make runs delete each other's containers.

  # APP_NAME is the definitive identity — its absence fails loudly rather
  # than falling back to the directory name.
  echo "[test-new] dev server without APP_NAME must fail loudly ($PG_APP/bin/dev)"
  cp "$PG_APP/pins.toml" "$WORK/pins.bak"
  grep -v '^APP_NAME=' "$WORK/pins.bak" > "$PG_APP/pins.toml"
  if out=$(env -u PG_URL PORT="$DEV_PG_HTTP" PG_PORT="$DEV_PG_PORT" SNAILS_DIR="$ROOT" "$PG_APP/bin/dev" --skip-build 2>&1); then
    cp "$WORK/pins.bak" "$PG_APP/pins.toml"
    echo "[test-new] dev server ran without APP_NAME (must fail)" >&2
    exit 1
  fi
  cp "$WORK/pins.bak" "$PG_APP/pins.toml"
  grep -q 'has no APP_NAME' <<<"$out" || {
    echo "[test-new] missing APP_NAME guard: no loud report" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }

  echo "[test-new] pg dev container stops for the explicit load ($PG_APP/bin/dev)"
  docker rm -fv "$AUTO_PG_CONTAINER" >/dev/null 2>&1 || true
  local AUTO_URL="postgres://postgres:postgres@127.0.0.1:$DEV_PG_PORT/demopg_development"
  if out=$(env -u PG_URL PORT="$DEV_PG_HTTP" PG_PORT="$DEV_PG_PORT" \
    PG_CONTAINER_NAME="$AUTO_PG_CONTAINER" SNAILS_DIR="$ROOT" \
    "$PG_APP/bin/dev" --skip-build 2>&1); then
    echo "[test-new] pg dev served before the explicit load (must stop)" >&2
    exit 1
  fi
  grep -q 'pending migration' <<<"$out" &&
    grep -q "snails migrate load" <<<"$out" &&
    grep -q -- "--database $AUTO_URL" <<<"$out" || {
    echo "[test-new] the pg dev gate does not name the pasteable load repair" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
  [[ "$(psql "$AUTO_URL" -tAc "SELECT to_regclass('schema_migrations')")" == "" ]] || {
    echo "[test-new] the pg dev runner applied migrations on its own (ledger exists)" >&2
    exit 1
  }
  [[ "$(psql "$AUTO_URL" -tAc "SELECT to_regclass('posts')")" == "" ]] || {
    echo "[test-new] the pg dev runner loaded the snapshot before the explicit load" >&2
    exit 1
  }
  echo "[test-new] loading the pg baseline unblocks dev ($PG_APP/bin/dev)"
  "$ROOT/bin/snails" migrate load --app "$PG_APP" --database "$AUTO_URL" >/dev/null
  dev_probe "$DEV_PG_HTTP" "$WORK/dev-pg-auto.log" "$PG_APP" \
    env -u PG_URL PORT="$DEV_PG_HTTP" PG_PORT="$DEV_PG_PORT" \
    PG_CONTAINER_NAME="$AUTO_PG_CONTAINER" SNAILS_DIR="$ROOT" "$PG_APP/bin/dev" --skip-build
  [[ "$(psql "$AUTO_URL" -tAc "SELECT to_regclass('posts')")" == "posts" ]] || {
    echo "[test-new] pg dev DB did not get the schema (posts missing)" >&2
    exit 1
  }
  # A reused container keeps its data: the second boot must not re-run the
  # loader (a developer's rows would be clobbered otherwise).
  psql "$AUTO_URL" -v ON_ERROR_STOP=1 -c \
    "INSERT INTO posts (title, body, created_at, updated_at) VALUES ('kept', 'x', '2026-01-01 00:00:00', '2026-01-01 00:00:00');" >/dev/null
  dev_probe "$DEV_PG_HTTP" "$WORK/dev-pg-reuse.log" "$PG_APP" \
    env -u PG_URL PORT="$DEV_PG_HTTP" PG_PORT="$DEV_PG_PORT" \
    PG_CONTAINER_NAME="$AUTO_PG_CONTAINER" SNAILS_DIR="$ROOT" "$PG_APP/bin/dev" --skip-build
  [[ "$(psql "$AUTO_URL" -tAc "SELECT title FROM posts WHERE title='kept'")" == "kept" ]] || {
    echo "[test-new] reusing the pg dev container clobbered development data (schema reloaded)" >&2
    exit 1
  }

  echo "[test-new] dev server uses a provided PG_URL as-is ($PG_APP/bin/dev)"
  # The marker stands in for a developer-provided database and dies with
  # the run, so its data directory lives on tmpfs (first boot ~6.7s ->
  # ~1s; postgres 18 wants the mount at /var/lib/postgresql, not the
  # retired /var/lib/postgresql/data path).
  docker run -d --name "$DEV_PG_CONTAINER" \
    --tmpfs /var/lib/postgresql \
    -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=development \
    -p "$MARKER_PORT:5432" postgres:18-alpine >/dev/null
  local MARKER_URL="postgres://postgres:postgres@127.0.0.1:$MARKER_PORT/development"
  local pg_ready=""
  local _i
  for _i in $(seq 1 100); do
    if psql "$MARKER_URL" -tAc "SELECT 1" >/dev/null 2>&1; then pg_ready=1; break; fi
    if ! docker inspect -f '{{.State.Running}}' "$DEV_PG_CONTAINER" 2>/dev/null | grep -q true; then
      break
    fi
    sleep 0.2
  done
  if [[ -z $pg_ready ]]; then
    echo "[test-new] dev pg container did not start" >&2
    exit 1
  fi
  psql "$MARKER_URL" -v ON_ERROR_STOP=1 -c \
    "CREATE TABLE dev_marker (id integer); INSERT INTO dev_marker VALUES (42);" >/dev/null
  # A provided database is the developer's to initialize: with no ledger the
  # gate stops and names the load step — the explicit load is what consents
  # to writing DDL into their database. Only then does the runner serve it
  # as-is.
  echo "[test-new] pending gate stops on a never-migrated provided PG_URL ($PG_APP/bin/dev)"
  if out=$(env PORT="$DEV_PG_HTTP" PG_URL="$MARKER_URL" SNAILS_DIR="$ROOT" \
    "$PG_APP/bin/dev" --skip-build 2>&1); then
    echo "[test-new] a never-migrated provided database served anyway (must stop)" >&2
    exit 1
  fi
  grep -q 'pending migration' <<<"$out" &&
    grep -q "snails migrate load" <<<"$out" || {
    echo "[test-new] the provided-DB pending gate does not name the load repair" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
  "$ROOT/bin/snails" migrate load --app "$PG_APP" --database "$MARKER_URL" >/dev/null
  # The snapshot carries a probe object the provided database must not
  # receive: the loader is additive, so with the app's tables already
  # applied only a fresh object distinguishes "never loaded" from
  # "loaded again".
  printf 'CREATE TABLE loader_probe (id INTEGER PRIMARY KEY);\n' >> "$PG_APP/db/schema.sql"
  dev_probe "$DEV_PG_HTTP" "$WORK/dev-pg.log" "$PG_APP" \
    env PORT="$DEV_PG_HTTP" PG_URL="$MARKER_URL" SNAILS_DIR="$ROOT" "$PG_APP/bin/dev" --skip-build
  [[ "$(psql "$MARKER_URL" -tAc 'SELECT id FROM dev_marker')" == "42" ]] || {
    echo "[test-new] PG_URL mode touched the developer's data (dev_marker row gone)" >&2
    exit 1
  }
  [[ "$(psql "$MARKER_URL" -tAc "SELECT to_regclass('loader_probe')")" == "" ]] || {
    echo "[test-new] PG_URL mode loaded the snapshot (loader_probe appeared)" >&2
    exit 1
  }

  # The pending gate covers the pg path too: a reused dev container whose
  # schema predates a migration file stops before the build, and applying
  # through the container's URL lets it serve again.
  echo "[test-new] dev stops on a pending pg migration ($PG_APP/bin/dev)"
  mkdir -p "$PG_APP/db/migrate"
  cat > "$PG_APP/db/migrate/20261030000000_add_pg_probe.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS pg_probe (id BIGSERIAL PRIMARY KEY);
SQL
  if out=$(env -u PG_URL PORT="$DEV_PG_HTTP" PG_PORT="$DEV_PG_PORT" \
    PG_CONTAINER_NAME="$AUTO_PG_CONTAINER" SNAILS_DIR="$ROOT" \
    "$PG_APP/bin/dev" --skip-build 2>&1); then
    echo "[test-new] pg dev served with a pending migration (must stop)" >&2
    exit 1
  fi
  grep -q 'pending migration' <<<"$out" &&
    grep -q "snails migrate apply" <<<"$out" || {
    echo "[test-new] the pg pending gate does not name the repair" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
  "$ROOT/bin/snails" migrate apply --app "$PG_APP" --database "$AUTO_URL" >/dev/null
  dev_probe "$DEV_PG_HTTP" "$WORK/dev-pg-after-apply.log" "$PG_APP" \
    env -u PG_URL PORT="$DEV_PG_HTTP" PG_PORT="$DEV_PG_PORT" \
    PG_CONTAINER_NAME="$AUTO_PG_CONTAINER" SNAILS_DIR="$ROOT" "$PG_APP/bin/dev" --skip-build
}

# One canary per run — the bare both-canaries path is suspended above, so
# --only is the only way in. Each pipeline carries pipefail inside its
# subshell so `wait` reports the canary's own status; sed unbuffered keeps
# progress live and attributed.
if [[ $ONLY == "demo" ]]; then
  ( set -o pipefail; canary_demo 2>&1 | sed -u 's/^/[demo] /' ) & PID_D=$!
else
  ( set -o pipefail; canary_pg 2>&1 | sed -u 's/^/[pg] /' ) & PID_P=$!
fi
rc_d=0
rc_p=0
if [[ -n $PID_D ]]; then wait "$PID_D" || rc_d=$?; fi
if [[ -n $PID_P ]]; then wait "$PID_P" || rc_p=$?; fi
if ((rc_d != 0 || rc_p != 0)); then
  echo "[test-new] FAILED (demo=$rc_d pg=$rc_p)" >&2
  exit 1
fi

echo "[test-new] PASS"
exit 0
