#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DOCKER=${DOCKER_BIN:-docker}
NAME="econtroll-first-master-local-$(date -u +%Y%m%d%H%M%S)-$$"
EVIDENCE=$(mktemp -d /tmp/econtroll-first-master-local.XXXXXX)
cleanup(){ "$DOCKER" rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
"$DOCKER" image inspect postgres:17.11 >/dev/null
"$DOCKER" run -d --rm --name "$NAME" --network none --tmpfs /var/lib/postgresql/data:rw,noexec,nosuid,size=256m -e POSTGRES_HOST_AUTH_METHOD=trust postgres:17.11 >/dev/null
for i in $(seq 1 45); do "$DOCKER" exec "$NAME" pg_isready -U postgres -d postgres >/dev/null 2>&1 && break; sleep 1; done
"$DOCKER" exec "$NAME" pg_isready -U postgres -d postgres >/dev/null
[ "$("$DOCKER" inspect -f '{{.HostConfig.NetworkMode}} {{if .HostConfig.PortBindings}}bound{{else}}none{{end}}' "$NAME")" = "none none" ]
[ "$("$DOCKER" exec "$NAME" psql -X -U postgres -d postgres -Atc 'show server_version_num')" = "170011" ]
run(){ "$DOCKER" exec -i "$NAME" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$1" >"$EVIDENCE/$(basename "$1").log" 2>&1; }
run "$HERE/00_supabase_compat.sql"
run "$ROOT/supabase/migrations/20261020000000_multiempresa_access_foundation.sql"
run "$ROOT/supabase/migrations/20261021000000_admin_master_authorization.sql"
run "$ROOT/supabase/migrations/20261028120000_install_first_master_bootstrap_disabled.sql"
run "$HERE/01_assert_and_exercise.sql"
# Replay is a separate authenticated attempt and must fail after the successful one.
if run "$HERE/02_concurrency.sql"; then echo 'FAIL: replay unexpectedly succeeded' >&2; exit 1; fi
grep -q 'First Master bootstrap has already been consumed' "$EVIDENCE/02_concurrency.sql.log"
# A second fresh database makes two real concurrent calls. The test-only trigger
# holds the first transaction after the function's table lock; only one may win.
"$DOCKER" exec "$NAME" createdb -U postgres concurrent
run_db(){ "$DOCKER" exec -i "$NAME" psql -X -v ON_ERROR_STOP=1 -U postgres -d "$1" < "$2" >"$EVIDENCE/$1.$(basename "$2").log" 2>&1; }
for sql in "$HERE/00_supabase_compat.sql" "$ROOT/supabase/migrations/20261020000000_multiempresa_access_foundation.sql" "$ROOT/supabase/migrations/20261021000000_admin_master_authorization.sql" "$ROOT/supabase/migrations/20261028120000_install_first_master_bootstrap_disabled.sql" "$HERE/03_concurrency_setup.sql"; do run_db concurrent "$sql"; done
"$DOCKER" exec -i "$NAME" psql -X -v ON_ERROR_STOP=1 -U postgres -d concurrent < "$HERE/04_concurrency_call.sql" >"$EVIDENCE/concurrency.first.log" 2>&1 & first=$!
sleep 0.25
"$DOCKER" exec -i "$NAME" psql -X -v ON_ERROR_STOP=1 -U postgres -d concurrent < "$HERE/04_concurrency_call.sql" >"$EVIDENCE/concurrency.second.log" 2>&1 & second=$!
set +e
wait "$first"; first_rc=$?
wait "$second"; second_rc=$?
set -e
if [ "$first_rc" -ne 0 ] || [ "$second_rc" -eq 0 ]; then echo 'FAIL: concurrent bootstrap result was not one success and one rejection' >&2; exit 1; fi
grep -q 'First Master bootstrap has already been consumed' "$EVIDENCE/concurrency.second.log"
run_db concurrent "$HERE/05_concurrency_assert.sql"
echo "PASS: PostgreSQL 17.11 isolated migration, disabled install, ACL, identity denial, atomic audit, replay and concurrency protection"
echo "Evidence: $EVIDENCE"
