begin;

do $setup$
declare tenant_id uuid := pg_catalog.gen_random_uuid(); branch_id uuid := pg_catalog.gen_random_uuid(); actor_id uuid := pg_catalog.gen_random_uuid(); membership_id uuid := pg_catalog.gen_random_uuid(); customer_id uuid := pg_catalog.gen_random_uuid(); supplier_id uuid := pg_catalog.gen_random_uuid(); item_id uuid := pg_catalog.gen_random_uuid();
begin
  insert into auth.users(id,email,email_confirmed_at) values(actor_id,'party-details@example.test',clock_timestamp());
  insert into public.companies(id,legal_name,status) values(tenant_id,'Phase 06 commercial billing','active');
  insert into public.branches(id,tenant_id,code,name,status) values(branch_id,tenant_id,'P06','Phase 06 branch','active');
  insert into public.company_memberships(id,tenant_id,user_id,status,branch_access_mode,created_by_user_id) values(membership_id,tenant_id,actor_id,'active','all_branches',actor_id);
  insert into public.access_role_definitions(role_key,display_name,scope,approval_state) values('party_details_owner','Phase 06 owner','company','approved');
  insert into public.membership_role_assignments(tenant_id,membership_id,role_key,branch_id,assigned_by_user_id) values(tenant_id,membership_id,'party_details_owner',null,actor_id);
  update public.permission_definitions set approval_state='approved' where permission_key in (
    'transaction.sales.order.create','transaction.sales.order.manage','transaction.sales.order.read','transaction.sales.order.decide',
    'transaction.service_order.create','transaction.service_order.update','transaction.service_order.read','transaction.service_order.close',
    'transaction.billing.issue','transaction.billing.read','transaction.billing.cancel'
  );
  update public.erp_transaction_authorization_catalog set approval_state='approved' where transaction_code in ('ZVE01','ZVE02','ZVE03','ZVE04','ZOS01','ZOS02','ZOS03','ZOS04','ZFB01','ZFB02','ZFB03');
  insert into public.company_module_availability(tenant_id,module_code,enabled,changed_by_user_id) values(tenant_id,'SAL',true,actor_id),(tenant_id,'SVC',true,actor_id),(tenant_id,'FIN',true,actor_id);
  insert into public.company_transaction_availability(tenant_id,transaction_code,enabled,changed_by_user_id) values
    (tenant_id,'ZVE01',true,actor_id),(tenant_id,'ZVE02',true,actor_id),(tenant_id,'ZVE03',true,actor_id),(tenant_id,'ZVE04',true,actor_id),
    (tenant_id,'ZOS01',true,actor_id),(tenant_id,'ZOS02',true,actor_id),(tenant_id,'ZOS03',true,actor_id),(tenant_id,'ZOS04',true,actor_id),
    (tenant_id,'ZFB01',true,actor_id),(tenant_id,'ZFB02',true,actor_id),(tenant_id,'ZFB03',true,actor_id);
  insert into public.company_role_permission_grants(tenant_id,branch_id,grant_scope,role_key,permission_key,reason,created_by_user_id)
    select tenant_id,branch_id,'branch','party_details_owner',permission_key,'Phase 06 isolated billing test',actor_id
    from (values
      ('transaction.sales.order.create'),('transaction.sales.order.manage'),('transaction.sales.order.read'),('transaction.sales.order.decide'),
      ('transaction.service_order.create'),('transaction.service_order.update'),('transaction.service_order.read'),('transaction.service_order.close'),
      ('transaction.billing.issue'),('transaction.billing.read'),('transaction.billing.cancel')
    ) granted(permission_key);
  insert into public.business_parties(id,tenant_id,party_type,legal_name,request_id,created_by_user_id) values
    (customer_id,tenant_id,'customer','Phase 06 customer',pg_catalog.gen_random_uuid(),actor_id),
    (supplier_id,tenant_id,'supplier','Phase 06 supplier',pg_catalog.gen_random_uuid(),actor_id);
  insert into public.catalog_items(id,tenant_id,item_type,code,name,unit_of_measure,current_cost,selling_price,minimum_stock,reorder_point,request_id,created_by_user_id)
    values(item_id,tenant_id,'product','P06-PART','Phase 06 part','UN',10,20,0,0,pg_catalog.gen_random_uuid(),actor_id);
  update public.permission_definitions set approval_state='approved' where permission_key in ('transaction.masterdata.party.manage','transaction.masterdata.party.read');
  update public.erp_transaction_authorization_catalog set approval_state='approved' where transaction_code in ('BP01');
  insert into public.company_module_availability(tenant_id,module_code,enabled,changed_by_user_id) values(tenant_id,'MDM',true,actor_id);
  insert into public.company_transaction_availability(tenant_id,transaction_code,enabled,changed_by_user_id) values(tenant_id,'BP01',true,actor_id);
  insert into public.company_role_permission_grants(tenant_id,grant_scope,role_key,permission_key,reason,created_by_user_id) select tenant_id,'company','party_details_owner',v,'Party test',actor_id from unnest(array['transaction.masterdata.party.manage','transaction.masterdata.party.read']) v;
  insert into public.business_parties(tenant_id,party_type,legal_name,document_number,address,request_id,created_by_user_id) values(tenant_id,'supplier','Legacy invalid document','11111111111','{"legacy_key":"preserved","city":"Legacy city"}',gen_random_uuid(),actor_id);
  perform set_config('test.tenant_id',tenant_id::text,false);
  perform set_config('test.branch_id',branch_id::text,false);
  perform set_config('test.customer_id',customer_id::text,false);
  perform set_config('test.supplier_id',supplier_id::text,false);
  perform set_config('test.item_id',item_id::text,false);
  perform set_config('test.actor_id',actor_id::text,false);
end;
$setup$;

commit;
\ir ../../supabase/migrations/20261128144000_business_party_details_validation.sql
begin;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub',current_setting('test.actor_id'),true);
select set_config('test.legacy_id',(select id::text from public.business_parties where tenant_id=current_setting('test.tenant_id')::uuid and legal_name='Legacy invalid document'),true);
set local role authenticated;
do $$
declare t uuid:=current_setting('test.tenant_id')::uuid; actor uuid:=current_setting('test.actor_id')::uuid; a uuid; b uuid; req uuid:=gen_random_uuid(); legacy uuid:=current_setting('test.legacy_id')::uuid; r record;
begin
 if current_user<>'authenticated' then raise exception 'Expected authenticated'; end if;
 a:=public.operational_create_business_party_v2(t,'supplier','PF valid','529.982.247-25','supplier-pf@example.test','11999999999','{"city":"Initial city","street":"Test street"}',req,'PF trade');
 if public.operational_create_business_party_v2(t,'supplier','PF valid','529.982.247-25','supplier-pf@example.test','11999999999','{"city":"Initial city","street":"Test street"}',req,'PF trade')<>a then raise exception 'Replay failed'; end if;
 b:=public.operational_create_business_party_v2(t,'supplier','PJ valid','11.222.333/0001-81','supplier-pj@example.test',null,'{}',gen_random_uuid(),'PJ trade');
 begin perform public.operational_create_business_party_v2(t,'supplier','Duplicate','52998224725',null,null,'{}',gen_random_uuid(),null); raise exception 'Duplicate accepted'; exception when unique_violation then null; end;
 begin perform public.operational_create_business_party(t,'supplier','Invalid old API','22222222222',null,null,'{}',gen_random_uuid()); raise exception 'Legacy API bypassed checksum'; exception when invalid_parameter_value then null; end;
 begin perform public.operational_update_business_party_v2(t,a,'PF invalid','52998224724',null,null,'{}',gen_random_uuid(),null); raise exception 'Invalid edit accepted'; exception when invalid_parameter_value then null; end;
 begin perform public.operational_create_business_party_v2(t,'supplier','Invalid PJ','11222333000182',null,null,'{}',gen_random_uuid(),null); raise exception 'Invalid CNPJ accepted'; exception when invalid_parameter_value then null; end;
 begin perform public.operational_create_business_party_v2(t,'supplier','Invalid email',null,'not-an-email',null,'{}',gen_random_uuid(),null); raise exception 'Invalid email accepted'; exception when check_violation then null; end;
 perform public.operational_update_business_party_v2(t,a,'PF edited','52998224725','updated@example.test','11911111111','{"city":"Updated city"}',gen_random_uuid(),'Edited trade');
 perform public.operational_update_business_party(t,a,'Old client edited','updated@example.test','11911111111','{}',gen_random_uuid());
 perform public.operational_update_business_party_v2(t,legacy,'Legacy edited','11111111111',null,null,'{"city":"New legacy city"}',gen_random_uuid(),null);
 select * into r from public.operational_list_business_parties_v2(t,null,null,null,100,0) where party_id=a;
 if r.person_type<>'PF' or r.trade_name<>'Edited trade' or r.address->>'street'<>'Test street' or r.address->>'city'<>'Updated city' then raise exception 'Updated details or legacy address were lost'; end if;
 select * into r from public.operational_list_business_parties_v2(t,null,null,null,100,0) where party_id=b;
 if r.person_type<>'PJ' then raise exception 'PJ derivation failed'; end if;
 select * into r from public.operational_list_business_parties_v2(t,null,null,null,100,0) where party_id=legacy;
 if r.document_number<>'11111111111' or r.address->>'legacy_key'<>'preserved' then raise exception 'Legacy row changed unexpectedly'; end if;
 perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 begin perform public.operational_create_business_party_v2(t,'supplier','Denied',null,null,null,'{}',gen_random_uuid(),null); raise exception 'Unauthorized create allowed'; exception when insufficient_privilege then null; end;
end;$$;
reset role;
do $$ begin
 if has_function_privilege('anon','public.operational_create_business_party_v2(uuid,text,text,text,text,text,jsonb,uuid,text)','execute') then raise exception 'Anon exposed'; end if;
end;$$;
rollback;
