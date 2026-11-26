#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/.." && pwd)
docker_bin=${DOCKER_BIN:-/Users/nandosouza/.docker/bin/docker}
container="econtrol-package01-postgres-${RANDOM}${RANDOM}"
onboarding_result_one=''
onboarding_result_two=''
cleanup(){
  "$docker_bin" rm -f "$container" >/dev/null 2>&1 || true
  [ -z "$onboarding_result_one" ] || rm -f "$onboarding_result_one"
  [ -z "$onboarding_result_two" ] || rm -f "$onboarding_result_two"
}
trap cleanup EXIT
"$docker_bin" run -d --rm --name "$container" --network none --tmpfs /var/lib/postgresql/data:rw,noexec,nosuid,size=512m -e POSTGRES_PASSWORD=local-test-only postgres:17.11 >/dev/null
for _ in $(seq 1 30); do "$docker_bin" exec "$container" pg_isready -U postgres -d postgres >/dev/null 2>&1 && break; sleep 1; done
"$docker_bin" exec "$container" pg_isready -U postgres -d postgres >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/tests/sql/package-01-postgres-bootstrap.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/supabase/migrations/20261027180000_company_admin_invitations.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/supabase/migrations/20261029130000_operational_erp_foundation.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/supabase/migrations/20261029140000_company_membership_operational_management.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/supabase/migrations/20261029160000_inventory_history_purchase_foundation.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/supabase/migrations/20261030100000_master_access_governance.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/supabase/migrations/20261030110000_company_access_entitlements.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/supabase/migrations/20261105110000_company_access_availability_deduplication.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/tests/sql/master-access-governance-behavior.sql" >/dev/null
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
do $$
declare order_id uuid; movement_count integer; listed_orders integer; total numeric; audit_count integer;
begin
  select count(*) into movement_count from public.operational_list_inventory_movements(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',null,null,null,null,25,0
  );
  if movement_count <> 1 then raise exception 'inventory history was not tenant/branch scoped correctly'; end if;
  select public.operational_create_purchase_order(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    (select id from public.business_parties where legal_name='Supplier Test'),
    jsonb_build_array(jsonb_build_object('item_id',(select id from public.catalog_items where code='SKU-1'),'quantity',3,'unit_price',12.5)),
    'local isolated test','77777777-7777-4777-8777-777777777777'
  ) into order_id;
  select total_amount into total from public.purchase_orders where id=order_id;
  if total <> 37.5 then raise exception 'purchase order total was not derived from the lines'; end if;
  if public.operational_create_purchase_order(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    (select id from public.business_parties where legal_name='Supplier Test'),
    jsonb_build_array(jsonb_build_object('item_id',(select id from public.catalog_items where code='SKU-1'),'quantity',3,'unit_price',12.5)),
    'retry','77777777-7777-4777-8777-777777777777'
  ) <> order_id then raise exception 'purchase order idempotency failed'; end if;
  perform public.operational_update_purchase_order(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',order_id,
    (select id from public.business_parties where legal_name='Supplier Test'),
    jsonb_build_array(jsonb_build_object('item_id',(select id from public.catalog_items where code='SKU-1'),'quantity',2,'unit_price',15)),
    'updated local isolated test','88888888-8888-4888-8888-888888888888'
  );
  if public.operational_update_purchase_order(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',order_id,
    (select id from public.business_parties where legal_name='Supplier Test'),
    jsonb_build_array(jsonb_build_object('item_id',(select id from public.catalog_items where code='SKU-1'),'quantity',2,'unit_price',15)),
    'same request retry','88888888-8888-4888-8888-888888888888'
  ) <> order_id then raise exception 'purchase order update idempotency failed'; end if;
  select count(*) into listed_orders from public.operational_list_purchase_orders('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',null,'draft',25,0);
  if listed_orders <> 1 then raise exception 'purchase order listing was not branch scoped'; end if;
  select count(*) into audit_count from app_private.operational_audit_events where event_key in ('purchase_order.created','purchase_order.updated');
  if audit_count <> 2 then raise exception 'purchase order audit is incomplete'; end if;
  begin
    perform set_config('request.jwt.claim.sub','',false);
    perform public.operational_list_inventory_movements('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',null,null,null,null,25,0);
    raise exception 'unauthenticated inventory history was accepted';
  exception when insufficient_privilege then null;
  end;
end $$;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false);
do $$ begin
  if has_table_privilege('authenticated','public.purchase_orders','select')
    or has_table_privilege('authenticated','public.purchase_order_items','select')
    or has_function_privilege('anon','public.operational_list_purchase_orders(uuid,uuid,text,text,integer,integer)','execute')
    or has_function_privilege('service_role','public.operational_create_purchase_order(uuid,uuid,uuid,jsonb,text,uuid)','execute') then
    raise exception 'purchase order direct access or broad function grant detected';
  end if;
end $$;
SQL
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/supabase/migrations/20261030120000_operational_transaction_authorization_hardening.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/tests/sql/operational-transaction-authorization-hardening.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/supabase/migrations/20261105100000_inventory_work_order_foundation.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/tests/sql/package-04-inventory-work-order-behavior.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/supabase/migrations/20261109100000_company_employee_access_management.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/tests/sql/company-employee-access-management-behavior.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/supabase/migrations/20261109120000_master_membership_authorization_read_api.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/tests/sql/master-membership-authorization-read-api-behavior.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/supabase/migrations/20261109130000_operational_read_authorization_alignment.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/tests/sql/operational-read-authorization-alignment.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/supabase/migrations/20261110100000_inventory_work_order_read_models.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/tests/sql/package-05-inventory-work-order-read-models.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/supabase/migrations/20261110120000_company_onboarding_activation.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/tests/sql/company-onboarding-activation-behavior.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<'SQL'
insert into auth.users(id,email,email_confirmed_at) values
  ('c5000000-0000-4000-8000-000000000001','concurrency-master@example.test',clock_timestamp()),
  ('c5000000-0000-4000-8000-000000000002','concurrency-owner@example.test',clock_timestamp());
insert into public.companies(id,legal_name,status)
values ('c6000000-0000-4000-8000-000000000001','Concurrency Company','active');
insert into public.access_role_definitions(role_key,display_name,scope,approval_state)
values ('company_owner','Proprietário empresarial','company','approved')
on conflict (role_key) do update set approval_state='approved';
insert into app_private.master_admins(user_id,status,authorized_by_user_id,authorization_reason,approval_reference)
values ('c5000000-0000-4000-8000-000000000001','active','c5000000-0000-4000-8000-000000000001','Local concurrency test','EC-ONB-01-CONCURRENCY');
select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','c5000000-0000-4000-8000-000000000001',false);
select invitation_id from public.master_create_company_admin_invitation(
  'c6000000-0000-4000-8000-000000000001','concurrency-owner@example.test','c7000000-0000-4000-8000-000000000001'
);
SQL
run_onboarding_accept() {
  "$docker_bin" exec "$container" psql -X -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres \
    -c "select set_config('request.jwt.claim.role','authenticated',false); select set_config('request.jwt.claim.sub','c5000000-0000-4000-8000-000000000002',false); select outcome from public.accept_current_company_admin_invitation();"
}
onboarding_result_one=$(mktemp)
onboarding_result_two=$(mktemp)
run_onboarding_accept >"$onboarding_result_one" & onboarding_accept_one=$!
run_onboarding_accept >"$onboarding_result_two" & onboarding_accept_two=$!
wait "$onboarding_accept_one"
wait "$onboarding_accept_two"
if [ "$(grep -h -x 'accepted' "$onboarding_result_one" "$onboarding_result_two" | wc -l | tr -d ' ')" != '1' ]; then
  echo 'ERROR: concurrent onboarding acceptance did not produce exactly one accepted result' >&2
  exit 1
fi
"$docker_bin" exec "$container" psql -X -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres \
  -c "select count(*) from public.company_memberships where tenant_id='c6000000-0000-4000-8000-000000000001' and user_id='c5000000-0000-4000-8000-000000000002' and status='active';" | grep -qx '1'
run_package05_transfer() {
  "$docker_bin" exec "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres -c "select set_config('request.jwt.claim.role','authenticated',false); select set_config('request.jwt.claim.sub','a3000000-0000-4000-8000-000000000002',false); select public.operational_create_inventory_transfer('a1000000-0000-4000-8000-000000000001','a2000000-0000-4000-8000-000000000001','a2000000-0000-4000-8000-000000000002','a5000000-0000-4000-8000-000000000001',1,'Package 05 concurrent transfer','a8000000-0000-4000-8000-000000000006');" >/dev/null
}
run_package05_transfer & package05_transfer_one=$!
run_package05_transfer & package05_transfer_two=$!
wait "$package05_transfer_one"
wait "$package05_transfer_two"
"$docker_bin" exec "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<'SQL'
do $$
declare source_balance numeric; destination_balance numeric; transfer_count integer;
begin
  select count(*) into transfer_count from public.inventory_transfers where tenant_id='a1000000-0000-4000-8000-000000000001' and request_id='a8000000-0000-4000-8000-000000000006';
  select quantity into source_balance from public.inventory_balances where tenant_id='a1000000-0000-4000-8000-000000000001' and branch_id='a2000000-0000-4000-8000-000000000001' and item_id='a5000000-0000-4000-8000-000000000001';
  select quantity into destination_balance from public.inventory_balances where tenant_id='a1000000-0000-4000-8000-000000000001' and branch_id='a2000000-0000-4000-8000-000000000002' and item_id='a5000000-0000-4000-8000-000000000001';
  if transfer_count<>1 or source_balance<>4 or destination_balance<>1 then
    raise exception 'Concurrent inventory transfer was not idempotent';
  end if;
end $$;
SQL
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/supabase/migrations/20261116180000_purchase_receipt_inventory_valuation.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/tests/sql/purchase-receipt-inventory-valuation-behavior.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/supabase/migrations/20261118190000_company_scoped_permission_governance.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/supabase/migrations/20261123190000_direct_purchase_work_order.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/supabase/migrations/20261123200000_direct_purchase_work_order_reversal.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/tests/sql/company-scoped-permission-governance-behavior.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/supabase/migrations/20261124110000_company_scoped_pilot_operational_entitlements.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/tests/sql/company-scoped-pilot-operational-entitlements-behavior.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<'SQL'
insert into public.role_permission_grants(role_key, permission_key) values
  ('company_owner', 'transaction.masterdata.party.manage'),
  ('company_owner', 'transaction.inventory.stock.read');
insert into public.company_role_permission_grants(
  tenant_id, branch_id, role_key, permission_key, reason, created_by_user_id
) values (
  'e2000000-0000-4000-8000-000000000001',
  'e3000000-0000-4000-8000-000000000001',
  'company_owner',
  'transaction.masterdata.party.manage',
  'Legacy pilot branch grant requiring company-scope normalization',
  'e1000000-0000-4000-8000-000000000001'
), (
  'e2000000-0000-4000-8000-000000000001',
  'e3000000-0000-4000-8000-000000000001',
  'company_owner',
  'transaction.masterdata.catalog.read',
  'Legacy pilot catalog grant requiring company-scope normalization',
  'e1000000-0000-4000-8000-000000000001'
);
SQL
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/supabase/migrations/20261124120000_transition_legacy_operational_grants.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/tests/sql/legacy-operational-grant-transition-behavior.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/tests/sql/purchase-receipt-inventory-valuation-concurrency-setup.sql" >/dev/null

# These are distinct PostgreSQL client sessions.  The test-only trigger pauses
# the first writer *after* the production RPC acquires its inventory lock; the
# second writer therefore contends for the real lock rather than running in a
# sequential mock.  lock_timeout/statement_timeout turn any deadlock or hang
# into a failing test.
run_phase01_receipt() {
  local item="$1" request_id="$2" pause="$3" label="$4"
  "$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
begin;
set local lock_timeout='3s'; set local statement_timeout='8s';
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','ca300000-0000-4000-8000-000000000001',true);
select set_config('phase01.test_pause','$pause',true);
set local application_name='$label';
select public.operational_receive_purchase_order('ca100000-0000-4000-8000-000000000001','ca700000-0000-4000-8000-00000000000${item}',jsonb_build_array(jsonb_build_object('purchase_order_item_id','ca710000-0000-4000-8000-00000000000${item}','quantity',4,'effective_unit_cost',14)),'CONC-${item}','Phase01 concurrency receipt','cab00000-0000-4000-8000-00000000000${request_id}');
commit;
SQL
}
run_phase01_transfer() {
  local item="$1" request_id="$2" pause="$3" label="$4"
  "$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
begin;
set local lock_timeout='3s'; set local statement_timeout='8s';
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','ca300000-0000-4000-8000-000000000001',true);
select set_config('phase01.test_pause','$pause',true);
set local application_name='$label';
select public.operational_create_inventory_transfer('ca100000-0000-4000-8000-000000000001','ca200000-0000-4000-8000-000000000001','ca200000-0000-4000-8000-000000000002','ca500000-0000-4000-8000-00000000000${item}',3,'Phase01 concurrency transfer','cac00000-0000-4000-8000-00000000000${request_id}');
commit;
SQL
}
run_phase01_count_post() {
  local count_request="$1" _unused="$2" pause="$3" label="$4"
  "$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
begin;
set local lock_timeout='3s'; set local statement_timeout='8s';
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','ca300000-0000-4000-8000-000000000001',true);
select set_config('phase01.test_pause','$pause',true);
set local application_name='$label';
select public.operational_post_inventory_count('ca100000-0000-4000-8000-000000000001',(select id from public.inventory_count_sessions where tenant_id='ca100000-0000-4000-8000-000000000001' and request_id='ca940000-0000-4000-8000-00000000000${count_request}'));
commit;
SQL
}
run_phase01_work_order_close() {
  local order_request="$1" _unused="$2" pause="$3" label="$4"
  "$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
begin;
set local lock_timeout='3s'; set local statement_timeout='8s';
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','ca300000-0000-4000-8000-000000000001',true);
select set_config('phase01.test_pause','$pause',true);
set local application_name='$label';
select public.operational_close_work_order('ca100000-0000-4000-8000-000000000001',(select id from public.work_orders where tenant_id='ca100000-0000-4000-8000-000000000001' and request_id='ca950000-0000-4000-8000-00000000000${order_request}'));
commit;
SQL
}
run_phase01_hard_receipt() {
  local order="$1" request_id="$2" pause="$3" label="$4"
  "$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
begin;
set local lock_timeout='3s'; set local statement_timeout='8s';
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','ca300000-0000-4000-8000-000000000001',true);
select set_config('phase01.test_pause','$pause',true);
set local application_name='$label';
select public.operational_receive_purchase_order('ca100000-0000-4000-8000-000000000001','ca700000-0000-4000-8000-000000000${order}',jsonb_build_array(jsonb_build_object('purchase_order_item_id','ca710000-0000-4000-8000-000000000${order}','quantity',4,'effective_unit_cost',14)),'HARD-CONC-${order}','hardening concurrency','caa00000-0000-4000-8000-000000000${request_id}');
commit;
SQL
}
run_phase01_hard_reverse() {
  local order="$1" request_id="$2" pause="$3" label="$4"
  "$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
begin;
set local lock_timeout='3s'; set local statement_timeout='8s';
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','ca300000-0000-4000-8000-000000000001',true);
select set_config('phase01.test_pause','$pause',true);
set local application_name='$label';
select public.operational_reverse_purchase_receipt('ca100000-0000-4000-8000-000000000001',(select id from public.purchase_receipts where purchase_order_id='ca700000-0000-4000-8000-000000000${order}'),jsonb_build_array(jsonb_build_object('purchase_receipt_item_id',(select item.id from public.purchase_receipt_items item join public.purchase_receipts receipt on receipt.id=item.purchase_receipt_id where receipt.purchase_order_id='ca700000-0000-4000-8000-000000000${order}' order by item.item_id limit 1),'quantity',1)),'hardening concurrency','cab00000-0000-4000-8000-000000000${request_id}');
commit;
SQL
}
run_phase01_hard_multi_receipt() {
  local order="$1" request_id="$2" pause="$3" label="$4"
  "$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
begin;
set local lock_timeout='3s'; set local statement_timeout='8s';
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','ca300000-0000-4000-8000-000000000001',true);
select set_config('phase01.test_pause','$pause',true);
set local application_name='$label';
select public.operational_receive_purchase_order('ca100000-0000-4000-8000-000000000001','ca700000-0000-4000-8000-000000000${order}',(select jsonb_agg(jsonb_build_object('purchase_order_item_id',id,'quantity',4,'effective_unit_cost',10) order by case when '${order}'='011' then item_id end asc,case when '${order}'='012' then item_id end desc) from public.purchase_order_items where purchase_order_id='ca700000-0000-4000-8000-000000000${order}'),'HARD-MULTI-${order}','hardening multi receipt','cac00000-0000-4000-8000-000000000${request_id}');
commit;
SQL
}
run_phase01_hard_multi_reverse() {
  local order="$1" request_id="$2" pause="$3" label="$4"
  "$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
begin;
set local lock_timeout='3s'; set local statement_timeout='8s';
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','ca300000-0000-4000-8000-000000000001',true);
select set_config('phase01.test_pause','$pause',true);
set local application_name='$label';
select public.operational_reverse_purchase_receipt('ca100000-0000-4000-8000-000000000001',(select id from public.purchase_receipts where purchase_order_id='ca700000-0000-4000-8000-000000000${order}'),(select jsonb_agg(jsonb_build_object('purchase_receipt_item_id',item.id,'quantity',1) order by case when '${order}'='013' then item.item_id end asc,case when '${order}'='014' then item.item_id end desc) from public.purchase_receipt_items item join public.purchase_receipts receipt on receipt.id=item.purchase_receipt_id where receipt.purchase_order_id='ca700000-0000-4000-8000-000000000${order}'),'hardening multi reversal','cad00000-0000-4000-8000-000000000${request_id}');
commit;
SQL
}
run_phase01_hard_work_order_close() {
  local pause="$1" label="$2"
  "$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
begin;
set local lock_timeout='3s'; set local statement_timeout='8s';
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','ca300000-0000-4000-8000-000000000001',true);
select set_config('phase01.test_pause','$pause',true);
set local application_name='$label';
select public.operational_close_work_order('ca100000-0000-4000-8000-000000000001',(select id from public.work_orders where request_id='ca990000-0000-4000-8000-000000000015'));
commit;
SQL
}
phase01_barrier_sequence=0
phase01_barrier_seen='|'
phase01_barrier_label=''

# PostgreSQL stores application_name in a 64-byte field including the trailing
# NUL.  Keep the test identifier below 63 bytes in the shell too; otherwise a
# valid paused backend is silently truncated and the observation probe looks
# for a different name.
phase01_validate_session_label() {
  local label="$1" bytes
  bytes=$(LC_ALL=C printf '%s' "$label" | wc -c | tr -d ' ')
  if [ "$bytes" -eq 0 ] || [ "$bytes" -gt 63 ]; then
    echo "ERROR: PostgreSQL application_name must be 1..63 bytes (got ${bytes})" >&2
    return 1
  fi
}

phase01_new_barrier() {
  local scenario="$1"
  if [[ ! "$scenario" =~ ^[a-z0-9-]+$ ]]; then
    echo "ERROR: invalid Phase 01 barrier scenario ${scenario}" >&2
    return 1
  fi
  phase01_barrier_sequence=$((phase01_barrier_sequence + 1))
  phase01_barrier_label=$(printf 'p01-%s-%03d' "$scenario" "$phase01_barrier_sequence")
  phase01_validate_session_label "$phase01_barrier_label" || return 1
  case "$phase01_barrier_seen" in
    *"|${phase01_barrier_label}|"*)
      echo "ERROR: duplicate Phase 01 barrier identifier ${phase01_barrier_label}" >&2
      return 1
      ;;
  esac
  phase01_barrier_seen="${phase01_barrier_seen}${phase01_barrier_label}|"
}

phase01_assert_barrier_absent() {
  local label="$1" observed
  phase01_validate_session_label "$label" || return 1
  observed=$("$docker_bin" exec "$container" psql -X -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "select count(*) from pg_catalog.pg_stat_activity where application_name='${label}' and wait_event='PgSleep';") || return 1
  if [ "$observed" != '0' ]; then
    echo "ERROR: nonexistent concurrency barrier ${label} was unexpectedly observed" >&2
    return 1
  fi
}

wait_phase01_pause() {
  local label="$1" attempts="${2:-80}" observed
  phase01_validate_session_label "$label" || return 1
  for _ in $(seq 1 "$attempts"); do
    observed=$("$docker_bin" exec "$container" psql -X -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "select count(*) from pg_catalog.pg_stat_activity where application_name='${label}' and wait_event='PgSleep';") || return 1
    if [ "$observed" = '1' ]; then
      echo "BARRIER: observed ${label} in pg_stat_activity"
      return 0
    fi
    if [ "$observed" != '0' ]; then
      echo "ERROR: concurrency barrier ${label} matched ${observed} sessions" >&2
      return 1
    fi
    sleep 0.05
  done
  echo "ERROR: concurrency barrier did not observe ${label} holding the real inventory lock" >&2
  return 1
}
run_phase01_pair() {
  local scenario="$1" first_name="$2" second_name="$3" label second_label
  shift 3
  phase01_new_barrier "$scenario" || return 1
  label="$phase01_barrier_label"
  second_label="${label}-second"
  phase01_validate_session_label "$second_label" || return 1
  echo "CONCURRENCY: ${first_name} holds the product lock while ${second_name} waits"
  "$1" "$2" "$3" on "$label" & local first_pid=$!
  wait_phase01_pause "$label"
  "$4" "$5" "$6" off "$second_label" & local second_pid=$!
  wait "$first_pid"
  wait "$second_pid"
}

# A missing backend must never be accepted as evidence.  The two identifiers
# also prove that separate scenarios cannot confuse the pg_stat_activity probe.
phase01_new_barrier barrier-probe-a
barrier_probe_a="$phase01_barrier_label"
phase01_new_barrier barrier-probe-b
barrier_probe_b="$phase01_barrier_label"
if [ "$barrier_probe_a" = "$barrier_probe_b" ]; then
  echo 'ERROR: distinct concurrency scenarios received the same barrier identifier' >&2
  exit 1
fi
phase01_assert_barrier_absent "$barrier_probe_a"
if wait_phase01_pause "$barrier_probe_a" 1 >/dev/null 2>&1; then
  echo 'ERROR: an absent concurrency barrier produced a false PASS' >&2
  exit 1
fi
echo 'BARRIER: absent and distinct identifiers were validated'

# A: receipt x transfer, in both serializable outcomes.
run_phase01_pair rt-1 receipt transfer run_phase01_receipt 1 1 run_phase01_transfer 1 1
run_phase01_pair tr-2 transfer receipt run_phase01_transfer 2 2 run_phase01_receipt 2 2
# B: receipt first must make the existing physical count stale; it must not
# overwrite the received balance.  The fresh re-count below is the required
# revalidation.  Count-first then receipt is also exercised successfully.
echo 'CONCURRENCY: receipt holds the product lock while inventory count waits (stale count expected)'
phase01_new_barrier receipt-count-stale
stale_label="$phase01_barrier_label"
phase01_validate_session_label "${stale_label}-second"
run_phase01_receipt 3 3 on "$stale_label" & receipt_stale_pid=$!
wait_phase01_pause "$stale_label"
set +e
run_phase01_count_post 1 ignored off "${stale_label}-second" & stale_count_pid=$!
wait "$receipt_stale_pid"; receipt_stale_status=$?
wait "$stale_count_pid"; stale_count_status=$?
set -e
if [ "$receipt_stale_status" -ne 0 ] || [ "$stale_count_status" -eq 0 ]; then
  echo 'ERROR: receipt/count stale-snapshot handling did not produce the expected conflict' >&2
  exit 1
fi
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<'SQL'
select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','ca300000-0000-4000-8000-000000000001',false);
select public.operational_record_inventory_count('ca100000-0000-4000-8000-000000000001',(select id from public.inventory_count_sessions where tenant_id='ca100000-0000-4000-8000-000000000001' and request_id='ca940000-0000-4000-8000-000000000001'),'ca500000-0000-4000-8000-000000000003',8);
select public.operational_post_inventory_count('ca100000-0000-4000-8000-000000000001',(select id from public.inventory_count_sessions where tenant_id='ca100000-0000-4000-8000-000000000001' and request_id='ca940000-0000-4000-8000-000000000001'));
SQL
run_phase01_pair count-receipt inventory-count receipt run_phase01_count_post 2 ignored run_phase01_receipt 4 4
# C: receipt x actual reservation consumption, in both outcomes.
run_phase01_pair receipt-os receipt work-order-close run_phase01_receipt 5 5 run_phase01_work_order_close 5 ignored
run_phase01_pair os-receipt work-order-close receipt run_phase01_work_order_close 6 ignored run_phase01_receipt 6 6
# D: reversal and a later receipt contend on the same balance but both facts are
# safe: inbound-only history does not make the original receipt ambiguous.
run_phase01_pair reversal-receipt receipt-reversal receipt run_phase01_hard_reverse 007 701 run_phase01_hard_receipt 008 702
# E: two documents list the same products in inverse item order.  Both sessions
# must acquire advisory locks by position, not by the incoming JSON/line UUID.
run_phase01_pair multi-receipt multi-receipt-one multi-receipt-two run_phase01_hard_multi_receipt 011 711 run_phase01_hard_multi_receipt 012 712
run_phase01_pair multi-reversal multi-reversal-one multi-reversal-two run_phase01_hard_multi_reverse 013 721 run_phase01_hard_multi_reverse 014 722
# F: a transfer that commits first is a real contending outbound event.  The
# reversal must wait for the inventory lock, then fail closed with the D05
# business state (55000), never through a deadlock or timeout.
echo 'CONCURRENCY: transfer holds the product lock while receipt reversal waits (D05 block expected)'
phase01_new_barrier transfer-reversal
hard_block_label="$phase01_barrier_label"
phase01_validate_session_label "${hard_block_label}-reverse"
run_phase01_transfer 8 8 on "$hard_block_label" & hard_transfer_pid=$!
wait_phase01_pause "$hard_block_label"
set +e
run_phase01_hard_reverse 009 731 off "${hard_block_label}-reverse" & hard_reverse_pid=$!
wait "$hard_transfer_pid"; hard_transfer_status=$?
wait "$hard_reverse_pid"; hard_reverse_status=$?
set -e
if [ "$hard_transfer_status" -ne 0 ] || [ "$hard_reverse_status" -eq 0 ]; then
  echo 'ERROR: transfer/reversal D05 handling did not produce the expected business rejection' >&2
  exit 1
fi
echo 'CONCURRENCY: O.S. consumption holds the product lock while receipt reversal waits (D05 block expected)'
phase01_new_barrier consumption-reversal
hard_os_label="$phase01_barrier_label"
phase01_validate_session_label "${hard_os_label}-reverse"
run_phase01_hard_work_order_close on "$hard_os_label" & hard_close_pid=$!
wait_phase01_pause "$hard_os_label"
set +e
run_phase01_hard_reverse 010 741 off "${hard_os_label}-reverse" & hard_os_reverse_pid=$!
wait "$hard_close_pid"; hard_close_status=$?
wait "$hard_os_reverse_pid"; hard_os_reverse_status=$?
set -e
if [ "$hard_close_status" -ne 0 ] || [ "$hard_os_reverse_status" -eq 0 ]; then
  echo 'ERROR: consumption/reversal D05 handling did not produce the expected business rejection' >&2
  exit 1
fi

# Same request identifiers are serialized by their own advisory locks before a
# position lock. The first session pauses at the real insert trigger; the
# second is therefore genuinely concurrent, not a sequential replay. Divergent
# replays catch only SQLSTATE 23505 inside SQL, so a timeout, deadlock or any
# other error still fails the runner.
run_phase01_idempotent_movement() {
  local case_id="$1" role="$2" pause="$3" label="$4"
  local branch='ca200000-0000-4000-8000-000000000001' item='ca500000-0000-4000-8000-000000000014' quantity=1 cost=11 reference='Idempotent movement' request='cae00000-0000-4000-8000-000000000801' conflict=false
  case "${case_id}:${role}" in
    same:*) ;;
    cost:primary) request='cae00000-0000-4000-8000-000000000802'; cost=12 ;;
    cost:secondary) request='cae00000-0000-4000-8000-000000000802'; cost=13; conflict=true ;;
    reference:primary) request='cae00000-0000-4000-8000-000000000803'; reference='Reference one' ;;
    reference:secondary) request='cae00000-0000-4000-8000-000000000803'; reference='Reference two'; conflict=true ;;
    branch:primary) request='cae00000-0000-4000-8000-000000000804'; cost=14 ;;
    branch:secondary) request='cae00000-0000-4000-8000-000000000804'; branch='ca200000-0000-4000-8000-000000000002'; cost=14; conflict=true ;;
    product:primary) request='cae00000-0000-4000-8000-000000000805'; cost=15 ;;
    product:secondary) request='cae00000-0000-4000-8000-000000000805'; item='ca500000-0000-4000-8000-000000000015'; cost=15; conflict=true ;;
    quantity:primary) request='cae00000-0000-4000-8000-000000000806'; cost=16 ;;
    quantity:secondary) request='cae00000-0000-4000-8000-000000000806'; quantity=2; cost=16; conflict=true ;;
    *) echo "ERROR: unknown idempotent movement case ${case_id}:${role}" >&2; return 1 ;;
  esac
  local statement="select * from public.operational_record_inventory_movement_valued('ca100000-0000-4000-8000-000000000001','${branch}','${item}','entry',${quantity},${cost},'${request}','${reference}');"
  if [ "$conflict" = true ]; then statement="do \$idempotency\$ begin perform * from public.operational_record_inventory_movement_valued('ca100000-0000-4000-8000-000000000001','${branch}','${item}','entry',${quantity},${cost},'${request}','${reference}'); raise exception 'divergent movement request was accepted'; exception when unique_violation then null; end \$idempotency\$;"; fi
  "$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
begin;
set local lock_timeout='3s'; set local statement_timeout='8s';
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','ca300000-0000-4000-8000-000000000001',true);
select set_config('phase01.test_pause','$pause',true);
set local application_name='$label';
${statement}
commit;
SQL
}

run_phase01_idempotent_derived_movement() {
  local _case_id="$1" _role="$2" pause="$3" label="$4"
  "$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
begin;
set local lock_timeout='3s'; set local statement_timeout='8s';
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','ca300000-0000-4000-8000-000000000001',true);
select set_config('phase01.test_pause','$pause',true);
set local application_name='$label';
select * from public.operational_record_inventory_movement('ca100000-0000-4000-8000-000000000001','ca200000-0000-4000-8000-000000000001','ca500000-0000-4000-8000-000000000014','entry',1,'cae00000-0000-4000-8000-000000000807',null);
commit;
SQL
}

run_phase01_idempotent_transfer() {
  local case_id="$1" role="$2" pause="$3" label="$4"
  local source='ca200000-0000-4000-8000-000000000001' destination='ca200000-0000-4000-8000-000000000002' item='ca500000-0000-4000-8000-000000000015' quantity=1 reference='Idempotent transfer' request='cae00000-0000-4000-8000-000000000811' conflict=false
  case "${case_id}:${role}" in
    same:*) ;;
    reference:primary) request='cae00000-0000-4000-8000-000000000812'; reference='Transfer one' ;;
    reference:secondary) request='cae00000-0000-4000-8000-000000000812'; reference='Transfer two'; conflict=true ;;
    quantity:primary) request='cae00000-0000-4000-8000-000000000813' ;;
    quantity:secondary) request='cae00000-0000-4000-8000-000000000813'; quantity=2; conflict=true ;;
    product:primary) request='cae00000-0000-4000-8000-000000000814' ;;
    product:secondary) request='cae00000-0000-4000-8000-000000000814'; item='ca500000-0000-4000-8000-000000000016'; conflict=true ;;
    branch:primary) request='cae00000-0000-4000-8000-000000000815' ;;
    branch:secondary) request='cae00000-0000-4000-8000-000000000815'; destination='ca200000-0000-4000-8000-000000000003'; conflict=true ;;
    *) echo "ERROR: unknown idempotent transfer case ${case_id}:${role}" >&2; return 1 ;;
  esac
  local statement="select public.operational_create_inventory_transfer('ca100000-0000-4000-8000-000000000001','${source}','${destination}','${item}',${quantity},'${reference}','${request}');"
  if [ "$conflict" = true ]; then statement="do \$idempotency\$ begin perform public.operational_create_inventory_transfer('ca100000-0000-4000-8000-000000000001','${source}','${destination}','${item}',${quantity},'${reference}','${request}'); raise exception 'divergent transfer request was accepted'; exception when unique_violation then null; end \$idempotency\$;"; fi
  "$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
begin;
set local lock_timeout='3s'; set local statement_timeout='8s';
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','ca300000-0000-4000-8000-000000000001',true);
select set_config('phase01.test_pause','$pause',true);
set local application_name='$label';
${statement}
commit;
SQL
}

run_phase01_idempotent_valuation() {
  local case_id="$1" role="$2" pause="$3" label="$4"
  local branch='ca200000-0000-4000-8000-000000000001' item='ca500000-0000-4000-8000-000000000017' cost=7 reason='Opening valuation' request='cae00000-0000-4000-8000-000000000821' conflict=false
  case "${case_id}:${role}" in
    same:*) ;;
    cost:primary) request='cae00000-0000-4000-8000-000000000822'; item='ca500000-0000-4000-8000-000000000018' ;;
    cost:secondary) request='cae00000-0000-4000-8000-000000000822'; item='ca500000-0000-4000-8000-000000000018'; cost=8; conflict=true ;;
    reason:primary) request='cae00000-0000-4000-8000-000000000823'; item='ca500000-0000-4000-8000-000000000019' ;;
    reason:secondary) request='cae00000-0000-4000-8000-000000000823'; item='ca500000-0000-4000-8000-000000000019'; reason='Changed reason'; conflict=true ;;
    branch:primary) request='cae00000-0000-4000-8000-000000000824'; item='ca500000-0000-4000-8000-000000000020' ;;
    branch:secondary) request='cae00000-0000-4000-8000-000000000824'; item='ca500000-0000-4000-8000-000000000020'; branch='ca200000-0000-4000-8000-000000000002'; conflict=true ;;
    product:primary) request='cae00000-0000-4000-8000-000000000825'; item='ca500000-0000-4000-8000-000000000021' ;;
    product:secondary) request='cae00000-0000-4000-8000-000000000825'; item='ca500000-0000-4000-8000-000000000017'; conflict=true ;;
    *) echo "ERROR: unknown idempotent valuation case ${case_id}:${role}" >&2; return 1 ;;
  esac
  local statement="select public.operational_record_initial_inventory_valuation('ca100000-0000-4000-8000-000000000001','${branch}','${item}',${cost},'${reason}','${request}');"
  if [ "$conflict" = true ]; then statement="do \$idempotency\$ begin perform public.operational_record_initial_inventory_valuation('ca100000-0000-4000-8000-000000000001','${branch}','${item}',${cost},'${reason}','${request}'); raise exception 'divergent valuation request was accepted'; exception when unique_violation then null; end \$idempotency\$;"; fi
  "$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
begin;
set local lock_timeout='3s'; set local statement_timeout='8s';
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','ca300000-0000-4000-8000-000000000001',true);
select set_config('phase01.test_pause','$pause',true);
set local application_name='$label';
${statement}
commit;
SQL
}

# The request UUID is scoped by operation.  These two pairs use the same UUID
# in one movement and one transfer, but start them in both real contention
# orders.  The public RPCs must each retain their own fact and valuation.
run_phase01_namespace_movement() {
  local case_id="$1" _role="$2" pause="$3" label="$4" request
  case "$case_id" in
    first) request='cae00000-0000-4000-8000-000000000831' ;;
    second) request='cae00000-0000-4000-8000-000000000832' ;;
    *) echo "ERROR: unknown namespace movement case ${case_id}" >&2; return 1 ;;
  esac
  "$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
begin;
set local lock_timeout='3s'; set local statement_timeout='8s';
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','ca300000-0000-4000-8000-000000000001',true);
select set_config('phase01.test_pause','$pause',true);
set local application_name='$label';
select * from public.operational_record_inventory_movement_valued('ca100000-0000-4000-8000-000000000001','ca200000-0000-4000-8000-000000000001','ca500000-0000-4000-8000-000000000016','entry',1,11,'${request}','Namespace concurrent movement');
commit;
SQL
}

run_phase01_namespace_transfer() {
  local case_id="$1" _role="$2" pause="$3" label="$4" request
  case "$case_id" in
    first) request='cae00000-0000-4000-8000-000000000831' ;;
    second) request='cae00000-0000-4000-8000-000000000832' ;;
    *) echo "ERROR: unknown namespace transfer case ${case_id}" >&2; return 1 ;;
  esac
  "$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
begin;
set local lock_timeout='3s'; set local statement_timeout='8s';
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','ca300000-0000-4000-8000-000000000001',true);
select set_config('phase01.test_pause','$pause',true);
set local application_name='$label';
select public.operational_create_inventory_transfer('ca100000-0000-4000-8000-000000000001','ca200000-0000-4000-8000-000000000001','ca200000-0000-4000-8000-000000000002','ca500000-0000-4000-8000-000000000016',1,'Namespace concurrent transfer','${request}');
commit;
SQL
}

for idempotency_case in same cost reference branch product quantity; do
  run_phase01_pair "mv-${idempotency_case}" "movement-${idempotency_case}" "movement-${idempotency_case}-replay" run_phase01_idempotent_movement "$idempotency_case" primary run_phase01_idempotent_movement "$idempotency_case" secondary
done
run_phase01_pair mv-derived "movement-derived-same" "movement-derived-same-replay" run_phase01_idempotent_derived_movement same primary run_phase01_idempotent_derived_movement same secondary
for idempotency_case in same reference quantity product branch; do
  run_phase01_pair "tr-${idempotency_case}" "transfer-${idempotency_case}" "transfer-${idempotency_case}-replay" run_phase01_idempotent_transfer "$idempotency_case" primary run_phase01_idempotent_transfer "$idempotency_case" secondary
done
for idempotency_case in same cost reason branch product; do
  run_phase01_pair "val-${idempotency_case}" "valuation-${idempotency_case}" "valuation-${idempotency_case}-replay" run_phase01_idempotent_valuation "$idempotency_case" primary run_phase01_idempotent_valuation "$idempotency_case" secondary
done
run_phase01_pair ns-move-first movement transfer run_phase01_namespace_movement first primary run_phase01_namespace_transfer first secondary
run_phase01_pair ns-transfer-first transfer movement run_phase01_namespace_transfer second primary run_phase01_namespace_movement second secondary

"$docker_bin" exec "$container" psql -X -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "select count(*) from public.inventory_movements where tenant_id='ca100000-0000-4000-8000-000000000001' and request_id='cae00000-0000-4000-8000-000000000807' and unit_cost_input_mode='derived';" | grep -qx '1'

"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<'SQL'
do $$
declare movement_rows integer; movement_ids integer; transfer_rows integer; transfer_ids integer; quantity_total numeric; value_total numeric;
begin
  select count(*),count(distinct id) into movement_rows,movement_ids
    from public.inventory_movements
   where tenant_id='ca100000-0000-4000-8000-000000000001'
     and request_id in ('cae00000-0000-4000-8000-000000000831','cae00000-0000-4000-8000-000000000832');
  select count(*),count(distinct id) into transfer_rows,transfer_ids
    from public.inventory_transfers
   where tenant_id='ca100000-0000-4000-8000-000000000001'
     and request_id in ('cae00000-0000-4000-8000-000000000831','cae00000-0000-4000-8000-000000000832');
  if movement_rows<>2 or movement_ids<>2 or transfer_rows<>2 or transfer_ids<>2 then
    raise exception 'Concurrent request namespaces did not retain exactly one fact per operation';
  end if;
  if exists(
    select 1 from public.inventory_movements movement
    join public.inventory_transfers transfer on transfer.id=movement.id
   where movement.tenant_id='ca100000-0000-4000-8000-000000000001'
  ) then
    raise exception 'Concurrent request namespaces reused an identifier across fact tables';
  end if;
  select coalesce(sum(quantity),0),coalesce(sum(stock_value),0) into quantity_total,value_total
    from public.inventory_balances
   where tenant_id='ca100000-0000-4000-8000-000000000001'
     and branch_id in ('ca200000-0000-4000-8000-000000000001','ca200000-0000-4000-8000-000000000002')
     and item_id='ca500000-0000-4000-8000-000000000016';
  if quantity_total<>22 or value_total<>222 then
    raise exception 'Concurrent request namespaces lost inventory quantity or valuation (% / %)',quantity_total,value_total;
  end if;
end $$;
SQL

"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/tests/sql/purchase-receipt-inventory-valuation-concurrency-assertions.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/tests/sql/phase-02-direct-purchase-work-order.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/tests/sql/phase-02-direct-purchase-work-order-reversal.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/tests/sql/phase-02-direct-purchase-work-order-concurrency-setup.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/supabase/migrations/20261126120000_quotation_foundation.sql" >/dev/null
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres < "$repo_root/tests/sql/phase-03-quotation-foundation.sql" >/dev/null

# T09. The first session holds the exact work-order row lock acquired by the
# production direct-purchase RPC. The second session is a separate PostgreSQL
# client and must wait on that lock. This verifies serialization and replay
# behavior without adding test hooks to Production SQL.
phase02_wait_activity() {
  local label="$1" predicate="$2" observed
  for _ in $(seq 1 80); do
    observed=$("$docker_bin" exec "$container" psql -X -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "select count(*) from pg_catalog.pg_stat_activity where application_name='${label}' and ${predicate};") || return 1
    if [ "$observed" = '1' ]; then
      echo "BARRIER: observed ${label}"
      return 0
    fi
    if [ "$observed" != '0' ]; then
      echo "ERROR: Phase 02 concurrency probe ${label} matched ${observed} sessions" >&2
      return 1
    fi
    sleep 0.05
  done
  echo "ERROR: Phase 02 concurrency probe did not observe ${label}" >&2
  return 1
}
run_phase02_direct_purchase() {
  local mode="$1" first="$2" label="$3" request cost statement
  request='d2700000-0000-4000-8000-000000000002'
  cost=12.5
  if [ "$mode" = divergent ]; then
    request='d2700000-0000-4000-8000-000000000003'
    [ "$first" = yes ] || cost=13
  fi
  statement="select public.operational_record_work_order_direct_purchase('d2000000-0000-4000-8000-000000000001',(select id from public.work_orders where tenant_id='d2000000-0000-4000-8000-000000000001' and request_id='d2700000-0000-4000-8000-000000000001'),'d2400000-0000-4000-8000-000000000002',null,'Concurrent direct material',2,${cost},'supplier receipt','P02C',null,'${request}');"
  if [ "$mode" = divergent ] && [ "$first" != yes ]; then
    statement="do \$idempotency\$ begin ${statement} raise exception 'divergent direct-purchase replay was accepted'; exception when unique_violation then null; end \$idempotency\$;"
  fi
  "$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
begin;
set local lock_timeout='3s'; set local statement_timeout='8s';
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','d2200000-0000-4000-8000-000000000001',true);
set local application_name='${label}';
$(if [ "$first" = yes ]; then printf "%s\n%s\n" "select 1 from public.work_orders where tenant_id='d2000000-0000-4000-8000-000000000001' and request_id='d2700000-0000-4000-8000-000000000001' for update;" "select pg_sleep(0.7);"; fi)
${statement}
commit;
SQL
}
run_phase02_direct_pair() {
  local mode="$1"
  local first_label="p02-${mode}-first"
  local second_label="p02-${mode}-second"
  echo "CONCURRENCY: direct purchase ${mode} replay waits on the real work-order lock"
  run_phase02_direct_purchase "$mode" yes "$first_label" & local first_pid=$!
  phase02_wait_activity "$first_label" "wait_event='PgSleep'"
  run_phase02_direct_purchase "$mode" no "$second_label" & local second_pid=$!
  phase02_wait_activity "$second_label" "wait_event_type='Lock'"
  wait "$first_pid"
  wait "$second_pid"
}
run_phase02_direct_pair same
run_phase02_direct_pair divergent
# T18.14/T18.15: distinct concurrent reversal requests contend on the real
# work-order lock and both fail closed without a billing-status contract.
run_phase02_direct_reversal() {
  local first="$1" label="$2" request
  request='d2700000-0000-4000-8000-000000000004'
  [ "$first" = yes ] || request='d2700000-0000-4000-8000-000000000005'
  "$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
begin;
set local lock_timeout='3s'; set local statement_timeout='8s';
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','d2200000-0000-4000-8000-000000000001',true);
set local application_name='${label}';
$(if [ "$first" = yes ]; then printf "%s\n%s\n" "select 1 from public.work_orders where tenant_id='d2000000-0000-4000-8000-000000000001' and request_id='d2700000-0000-4000-8000-000000000001' for update;" "select pg_sleep(0.7);"; fi)
do \$reversal\$ begin
  perform public.operational_reverse_work_order_direct_purchase('d2000000-0000-4000-8000-000000000001',(select id from public.work_orders where tenant_id='d2000000-0000-4000-8000-000000000001' and request_id='d2700000-0000-4000-8000-000000000001'),(select id from public.work_order_direct_purchases where tenant_id='d2000000-0000-4000-8000-000000000001' and request_id='d2700000-0000-4000-8000-000000000002'),null,'${request}');
  raise exception 'billing-unknown reversal was accepted';
exception when object_not_in_prerequisite_state then
  if sqlerrm not like '%billing status contract%' then raise; end if;
end \$reversal\$;
commit;
SQL
}
echo 'CONCURRENCY: direct-purchase reversals wait on the real work-order lock and fail closed without billing status'
run_phase02_direct_reversal yes p02-reversal-first & phase02_reversal_first_pid=$!
phase02_wait_activity p02-reversal-first "wait_event='PgSleep'"
run_phase02_direct_reversal no p02-reversal-second & phase02_reversal_second_pid=$!
phase02_wait_activity p02-reversal-second "wait_event_type='Lock'"
wait "$phase02_reversal_first_pid"
wait "$phase02_reversal_second_pid"
"$docker_bin" exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<'SQL'
do $$
declare purchases integer; total numeric; movements integer; audits integer; reversals integer;
begin
  select count(*),coalesce(sum(total_cost),0) into purchases,total
    from public.work_order_direct_purchases
   where tenant_id='d2000000-0000-4000-8000-000000000001';
  select direct_purchase_total into total from public.work_orders
   where tenant_id='d2000000-0000-4000-8000-000000000001'
     and request_id='d2700000-0000-4000-8000-000000000001';
  if purchases<>2 or total<>50 then
    raise exception 'Phase 02 concurrent idempotency produced duplicate or lost direct cost (% / %)', purchases,total;
  end if;
  select count(*) into movements from public.inventory_movements where tenant_id='d2000000-0000-4000-8000-000000000001';
  select count(*) into audits from app_private.operational_audit_events where tenant_id='d2000000-0000-4000-8000-000000000001' and event_key='work_order.direct_purchase.recorded';
  select count(*) into reversals from public.work_order_direct_purchase_reversals where tenant_id='d2000000-0000-4000-8000-000000000001';
  -- T15: direct purchases have no financial ledger in the current schema; the
  -- only persisted operational side effect is the direct-purchase audit event.
  if movements<>0 or audits<>2 or reversals<>0 then
    raise exception 'Phase 02 direct purchases changed stock, audit or reversal state (% / % / %)', movements,audits,reversals;
  end if;
end $$;
SQL
# T17 is the full Package 01/03/04/05 and Phase 01 regression above. T18 uses
# an explicit fail-closed billing guard because the current schema has none.
"$docker_bin" exec "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres -Atc "select count(*) from pg_class where relnamespace in ('public'::regnamespace,'app_private'::regnamespace) and relname in ('business_parties','catalog_items','inventory_movements','company_employee_invitations');" | grep -qx '4'
echo 'PASS: Packages 01, 03, 04, 05, Phase 01 valuation, Phase 02 direct work-order purchase, and Phase 03 quotation contracts pass against isolated PostgreSQL 17.11 with an Auth/Foundation compatibility harness.'
