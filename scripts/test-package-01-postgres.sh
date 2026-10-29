#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/.." && pwd)
docker_bin=${DOCKER_BIN:-/Users/nandosouza/.docker/bin/docker}
container="econtrol-package01-postgres-${RANDOM}${RANDOM}"
cleanup(){ "$docker_bin" rm -f "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT
"$docker_bin" run -d --rm --name "$container" --network none --tmpfs /var/lib/postgresql/data:rw,noexec,nosuid,size=512m -e POSTGRES_PASSWORD=local-test-only postgres:17.11 >/dev/null
for _ in $(seq 1 30); do "$docker_bin" exec "$container" pg_isready -U postgres -d postgres >/dev/null 2>&1 && break; sleep 1; done
"$docker_bin" exec "$container" pg_isready -U postgres -d postgres >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/tests/sql/package-01-postgres-bootstrap.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/supabase/migrations/20261029130000_operational_erp_foundation.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/supabase/migrations/20261029140000_company_membership_operational_management.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<'SQL'
insert into auth.users(id,email,email_confirmed_at) values
  ('11111111-1111-4111-8111-111111111111','operator@example.test',clock_timestamp()),
  ('22222222-2222-4222-8222-222222222222','employee@example.test',clock_timestamp());
insert into public.companies(id,legal_name) values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Test Company');
insert into public.branches(id,tenant_id,code,name) values ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','001','Main');
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false);
select set_config('request.jwt.claim.role','authenticated',false);
select public.operational_create_business_party('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','supplier','Supplier Test','12345678000199',null,null,'{}'::jsonb,'33333333-3333-4333-8333-333333333333');
select public.operational_create_catalog_item('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','product','SKU-1','Product Test',null,null,null,null,'UN',null,null,10,15,null,null,1,2,null,null,'44444444-4444-4444-8444-444444444444');
select * from public.operational_record_inventory_movement('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',(select id from public.catalog_items where code='SKU-1'),'initial',2,'55555555-5555-4555-8555-555555555555','test');
select * from public.operational_record_inventory_movement('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',(select id from public.catalog_items where code='SKU-1'),'initial',2,'55555555-5555-4555-8555-555555555555','retry');
do $$ begin
  perform * from public.operational_record_inventory_movement('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',(select id from public.catalog_items where code='SKU-1'),'exit',3,'66666666-6666-4666-8666-666666666666','negative');
  raise exception 'negative inventory was accepted';
exception when check_violation then null;
end $$;
SQL
"$docker_bin" exec "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres -Atc "select count(*) from pg_class where relnamespace in ('public'::regnamespace,'app_private'::regnamespace) and relname in ('business_parties','catalog_items','inventory_movements','company_employee_invitations');" | grep -qx '4'
echo 'PASS: Package 01 migrations compile against isolated PostgreSQL 17.11 with an Auth/Foundation compatibility harness.'
