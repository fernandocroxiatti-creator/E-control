#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
IMAGE=${EC_ADM03_POSTGRES_IMAGE:-postgres:17.11}
CONTAINER="econtroll-ec-adm03-$(date -u +%Y%m%d%H%M%S)-$$"
EVIDENCE=$(mktemp -d "${TMPDIR:-/tmp}/econtroll-ec-adm03.XXXXXX")
started=0
failed_at=preflight

cleanup() {
  rc=$?
  trap - EXIT INT TERM
  if [ "$started" -eq 1 ]; then docker stop "$CONTAINER" >"$EVIDENCE/cleanup.log" 2>&1 || true; fi
  if [ "$rc" -eq 0 ]; then echo "PASS: invitation PostgreSQL suite completed"; else echo "FAIL: $failed_at (exit $rc)" >&2; fi
  echo "Evidence: $EVIDENCE"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for required in \
  "$SCRIPT_DIR/00_supabase_compat.sql" \
  "$SCRIPT_DIR/02_add_auth_email_fields.sql" \
  "$SCRIPT_DIR/03_invitation_behavior.sql" \
  "$ROOT/supabase/migrations/20261020000000_multiempresa_access_foundation.sql" \
  "$ROOT/supabase/migrations/20261021000000_admin_master_authorization.sql" \
  "$ROOT/supabase/migrations/20261022100000_master_create_company.sql" \
  "$ROOT/supabase/migrations/20261022130000_company_authorization_foundation.sql" \
  "$ROOT/supabase/migrations/20261023160000_master_admin_read_api.sql" \
  "$ROOT/supabase/migrations/20261026100000_master_company_branch_management.sql" \
  "$ROOT/supabase/migrations/20261027180000_company_admin_invitations.sql" \
  "$ROOT/supabase/migrations/20261027190000_company_role_permission_authorization.sql" \
  "$SCRIPT_DIR/../EC-ROLE-01-local/01_role_permission_behavior.sql"; do
  [ -f "$required" ] || { echo "FAIL: required test input missing: $required" >&2; exit 2; }
done

command -v docker >/dev/null 2>&1 || { echo 'FAIL: Docker CLI unavailable' >&2; exit 2; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "FAIL: required local image unavailable; refusing pull: $IMAGE" >&2; exit 2; }
if docker inspect "$CONTAINER" >/dev/null 2>&1; then echo 'FAIL: unique local test container name collision' >&2; exit 2; fi

docker run --detach --rm --name "$CONTAINER" --network none \
  --tmpfs /var/lib/postgresql/data:rw,noexec,nosuid,size=512m \
  --env POSTGRES_HOST_AUTH_METHOD=trust "$IMAGE" \
  >"$EVIDENCE/container-id" 2>"$EVIDENCE/container-start.log" || { failed_at='start isolated PostgreSQL'; cat "$EVIDENCE/container-start.log" >&2; exit 1; }
started=1

ready=0
for _ in $(seq 1 60); do
  if docker exec "$CONTAINER" pg_isready -U postgres -d postgres >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
[ "$ready" -eq 1 ] || { failed_at='PostgreSQL readiness'; cat "$EVIDENCE/container-start.log" >&2; exit 1; }

network=$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$CONTAINER")
ports=$(docker inspect --format '{{if .HostConfig.PortBindings}}bound{{else}}none{{end}}' "$CONTAINER")
tmpfs=$(docker inspect --format '{{json .HostConfig.Tmpfs}}' "$CONTAINER")
version=$(docker exec "$CONTAINER" psql -X -U postgres -d postgres -Atc 'show server_version;')
[[ "$version" == 17.11* ]] || { failed_at="PostgreSQL version: $version"; exit 1; }
[ "$network" = none ] && [ "$ports" = none ] && [[ "$tmpfs" == *'"/var/lib/postgresql/data"'* ]] \
  || { failed_at='container isolation verification'; exit 1; }
echo "PASS: isolated container (PostgreSQL $version, network=none, no ports, restricted tmpfs)"

docker exec "$CONTAINER" createdb -U postgres econtroll_ec_adm03_invite
run_sql() {
  label=$1 file=$2
  failed_at=$label
  if docker exec -i "$CONTAINER" psql -X -U postgres -d econtroll_ec_adm03_invite -v ON_ERROR_STOP=1 \
    <"$file" >"$EVIDENCE/$label.log" 2>&1; then echo "PASS: $label"; else cat "$EVIDENCE/$label.log" >&2; exit 1; fi
}

run_sql auth-compat "$SCRIPT_DIR/00_supabase_compat.sql"
run_sql auth-fields "$SCRIPT_DIR/02_add_auth_email_fields.sql"
run_sql base-foundation "$ROOT/supabase/migrations/20261020000000_multiempresa_access_foundation.sql"
run_sql master-authorization "$ROOT/supabase/migrations/20261021000000_admin_master_authorization.sql"
run_sql master-company-create "$ROOT/supabase/migrations/20261022100000_master_create_company.sql"
run_sql tenant-authorization "$ROOT/supabase/migrations/20261022130000_company_authorization_foundation.sql"
run_sql master-read-api "$ROOT/supabase/migrations/20261023160000_master_admin_read_api.sql"
run_sql master-company-branch "$ROOT/supabase/migrations/20261026100000_master_company_branch_management.sql"
run_sql company-admin-invitations "$ROOT/supabase/migrations/20261027180000_company_admin_invitations.sql"
run_sql company-role-permission-authorization "$ROOT/supabase/migrations/20261027190000_company_role_permission_authorization.sql"
run_sql invitation-behavior "$SCRIPT_DIR/03_invitation_behavior.sql"
run_sql role-permission-behavior "$SCRIPT_DIR/../EC-ROLE-01-local/01_role_permission_behavior.sql"
