begin;

insert into public.permission_definitions(permission_key,description,approval_state)
values('transaction.treasury.statement.import','Importar extratos OFX validados e consultar sugestões de conciliação.','pending_approval') on conflict do nothing;
insert into public.erp_transaction_authorization_catalog(transaction_code,module_code,permission_key,approval_state)
values('ZTR06','TSY','transaction.treasury.statement.import','pending_approval') on conflict do nothing;

create table public.treasury_ofx_account_bindings (
 tenant_id uuid not null,branch_id uuid not null,bank_account_id uuid not null,
 bank_code text not null check(length(bank_code) between 1 and 32),branch_code text not null default '' check(length(branch_code)<=32),external_account_id text not null check(length(external_account_id) between 1 and 128),
 actor_user_id uuid not null references auth.users(id),created_at timestamptz not null default clock_timestamp(),
 primary key(tenant_id,bank_account_id),unique(tenant_id,bank_code,branch_code,external_account_id),
 foreign key(tenant_id,branch_id,bank_account_id) references public.treasury_bank_accounts(tenant_id,branch_id,id)
);
create table public.treasury_ofx_imports (
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,branch_id uuid not null,bank_account_id uuid not null,
 file_sha256 text not null check(file_sha256 ~ '^[a-f0-9]{64}$'),period_from date not null,period_to date not null,
 line_payload jsonb not null,
 line_count integer not null check(line_count between 1 and 2000),inserted_count integer not null check(inserted_count between 0 and 2000),actor_user_id uuid not null references auth.users(id),created_at timestamptz not null default clock_timestamp(),
 unique(tenant_id,bank_account_id,file_sha256),unique(tenant_id,branch_id,bank_account_id,id),
 foreign key(tenant_id,branch_id,bank_account_id) references public.treasury_bank_accounts(tenant_id,branch_id,id),check(period_to>=period_from and period_to-period_from<=366)
);
alter table public.treasury_bank_movements add unique(tenant_id,branch_id,bank_account_id,id);
create table public.treasury_ofx_lines (
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,branch_id uuid not null,bank_account_id uuid not null,import_id uuid not null,
 fit_id text not null check(length(fit_id) between 1 and 128),posted_on date not null,amount numeric(24,8) not null check(amount<>0 and amount::text not in ('NaN','Infinity','-Infinity')),
 description text not null check(length(description) between 1 and 1000),reference text check(reference is null or length(reference) between 1 and 128),
 matched_movement_id uuid,matched_at timestamptz,matched_by_user_id uuid references auth.users(id),
 unique(tenant_id,bank_account_id,fit_id),unique(matched_movement_id),
 foreign key(tenant_id,branch_id,bank_account_id,import_id) references public.treasury_ofx_imports(tenant_id,branch_id,bank_account_id,id),
 foreign key(tenant_id,branch_id,bank_account_id,matched_movement_id) references public.treasury_bank_movements(tenant_id,branch_id,bank_account_id,id),
 check((matched_movement_id is null and matched_at is null and matched_by_user_id is null) or (matched_movement_id is not null and matched_at is not null and matched_by_user_id is not null))
);
create index treasury_ofx_pending on public.treasury_ofx_lines(tenant_id,branch_id,posted_on,id) where matched_movement_id is null;
alter table public.treasury_ofx_account_bindings enable row level security; alter table public.treasury_ofx_account_bindings force row level security;
alter table public.treasury_ofx_imports enable row level security; alter table public.treasury_ofx_imports force row level security;
alter table public.treasury_ofx_lines enable row level security; alter table public.treasury_ofx_lines force row level security;
revoke all on table public.treasury_ofx_account_bindings,public.treasury_ofx_imports,public.treasury_ofx_lines from public,anon,authenticated,service_role;

create function app_private.assert_ofx_import_permission(p_tenant_id uuid,p_branch_id uuid)
returns uuid language plpgsql stable security definer set search_path='' set row_security=off as $f$
declare actor uuid;
begin
 actor:=app_private.assert_treasury_permission(p_tenant_id,'transaction.treasury.reconcile.manage',p_branch_id);
 if not app_private.has_tenant_permission(p_tenant_id,'transaction.treasury.statement.import',p_branch_id)
 or not exists(select 1 from public.erp_transaction_authorization_catalog c join public.permission_definitions p on p.permission_key=c.permission_key and p.approval_state='approved' join public.company_transaction_availability a on a.tenant_id=p_tenant_id and a.transaction_code=c.transaction_code and a.enabled where c.transaction_code='ZTR06' and c.permission_key='transaction.treasury.statement.import' and c.module_code='TSY' and c.approval_state='approved') then raise exception 'OFX import permission denied' using errcode='42501'; end if;
 return actor;
end;$f$;

create function public.operational_bind_ofx_bank_account(p_tenant_id uuid,p_account_id uuid,p_bank_code text,p_branch_code text,p_external_account_id text)
returns uuid language plpgsql security definer set search_path='' set row_security=off as $f$
declare a public.treasury_bank_accounts%rowtype; binding public.treasury_ofx_account_bindings%rowtype; actor uuid;
begin
 if length(btrim(coalesce(p_bank_code,''))) not between 1 and 32 or p_branch_code is null or length(btrim(p_branch_code))>32 or length(btrim(coalesce(p_external_account_id,''))) not between 1 and 128 or (p_bank_code||p_branch_code||p_external_account_id) ~ '[[:cntrl:]]' then raise exception 'Invalid OFX bank account identification' using errcode='22023'; end if;
 select * into a from public.treasury_bank_accounts where tenant_id=p_tenant_id and id=p_account_id for update;
 if not found or a.status<>'active' then raise exception 'Active bank account required' using errcode='23503'; end if;
 actor:=app_private.assert_treasury_permission(p_tenant_id,'transaction.treasury.account.manage',a.branch_id);
 select * into binding from public.treasury_ofx_account_bindings where tenant_id=p_tenant_id and bank_account_id=a.id for update;
 if found then
 if binding.bank_code=btrim(p_bank_code) and binding.branch_code=btrim(p_branch_code) and binding.external_account_id=btrim(p_external_account_id) then return a.id; end if;
 if exists(select 1 from public.treasury_ofx_imports where tenant_id=p_tenant_id and bank_account_id=a.id) then raise exception 'An account with imported statements cannot change bank identity' using errcode='55000'; end if;
 end if;
 insert into public.treasury_ofx_account_bindings(tenant_id,branch_id,bank_account_id,bank_code,branch_code,external_account_id,actor_user_id)
 values(p_tenant_id,a.branch_id,a.id,btrim(p_bank_code),btrim(p_branch_code),btrim(p_external_account_id),actor)
 on conflict(tenant_id,bank_account_id) do update set bank_code=excluded.bank_code,branch_code=excluded.branch_code,external_account_id=excluded.external_account_id,actor_user_id=actor,created_at=clock_timestamp();
 perform app_private.write_operational_audit('treasury.ofx.account_bound',p_tenant_id,a.branch_id,a.id,actor,jsonb_build_object('bank_code',btrim(p_bank_code),'account_suffix',right(btrim(p_external_account_id),4))); return a.id;
end;$f$;

create function public.operational_import_ofx_statement(p_tenant_id uuid,p_account_id uuid,p_file_sha256 text,p_bank_code text,p_branch_code text,p_external_account_id text,p_currency text,p_from date,p_to date,p_lines jsonb)
returns jsonb language plpgsql security definer set search_path='' set row_security=off as $f$
declare a public.treasury_bank_accounts%rowtype; binding public.treasury_ofx_account_bindings%rowtype; actor uuid; batch public.treasury_ofx_imports%rowtype; old_line public.treasury_ofx_lines%rowtype; line jsonb; result uuid; inserted integer:=0; fit text; posted date; signed_amount numeric; description_text text; reference_text text;
begin
 if p_file_sha256 is null or p_file_sha256 !~ '^[a-f0-9]{64}$' or p_currency is distinct from 'BRL' or p_from is null or p_to is null or p_from>p_to or p_to-p_from>366 or p_lines is null or jsonb_typeof(p_lines)<>'array' then raise exception 'Invalid OFX statement' using errcode='22023'; end if;
 if jsonb_array_length(p_lines) not between 1 and 2000 or octet_length(p_lines::text)>2097152 then raise exception 'OFX statement exceeds import bounds' using errcode='22023'; end if;
 select * into a from public.treasury_bank_accounts where tenant_id=p_tenant_id and id=p_account_id for update;
 if not found or a.status<>'active' then raise exception 'Active bank account required' using errcode='23503'; end if;
 actor:=app_private.assert_ofx_import_permission(p_tenant_id,a.branch_id);
 select * into binding from public.treasury_ofx_account_bindings where tenant_id=p_tenant_id and bank_account_id=a.id;
 if not found or binding.bank_code is distinct from p_bank_code or binding.branch_code is distinct from p_branch_code or binding.external_account_id is distinct from p_external_account_id then raise exception 'OFX account does not match the configured bank account' using errcode='23514'; end if;
 if exists(select 1 from jsonb_array_elements(p_lines) j group by j->>'fit_id' having count(*)>1) then raise exception 'Duplicate FITID in OFX payload' using errcode='22023'; end if;
 select * into batch from public.treasury_ofx_imports where tenant_id=p_tenant_id and bank_account_id=a.id and file_sha256=p_file_sha256;
 if found then
 if batch.line_payload is distinct from p_lines or batch.period_from<>p_from or batch.period_to<>p_to or batch.line_count<>jsonb_array_length(p_lines) then raise exception 'File hash reused with different statement' using errcode='23505'; end if;
 result:=batch.id;
 else
 insert into public.treasury_ofx_imports(tenant_id,branch_id,bank_account_id,file_sha256,period_from,period_to,line_payload,line_count,inserted_count,actor_user_id) values(p_tenant_id,a.branch_id,a.id,p_file_sha256,p_from,p_to,p_lines,jsonb_array_length(p_lines),0,actor) returning id into result;
 end if;
 for line in select * from jsonb_array_elements(p_lines) loop
 if jsonb_typeof(line)<>'object' or jsonb_typeof(line->'fit_id') is distinct from 'string' or jsonb_typeof(line->'amount') is distinct from 'string' or jsonb_typeof(line->'posted_on') is distinct from 'string' or jsonb_typeof(line->'description') is distinct from 'string' then raise exception 'Invalid OFX line types' using errcode='22023'; end if;
 fit:=line->>'fit_id';description_text:=line->>'description';reference_text:=nullif(line->>'reference','');
 if length(fit) not between 1 and 128 or fit ~ '[[:cntrl:]]' or coalesce(line->>'amount','') !~ '^-?[0-9]{1,15}(\.[0-9]{1,8})?$' or coalesce(line->>'posted_on','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or length(description_text) not between 1 and 1000 or (reference_text is not null and (length(reference_text)>128 or reference_text ~ '[[:cntrl:]]')) then raise exception 'Invalid OFX line data' using errcode='22023'; end if;
 signed_amount:=(line->>'amount')::numeric;posted:=(line->>'posted_on')::date;
 if signed_amount=0 or posted<p_from or posted>p_to then raise exception 'OFX line outside period or zero amount' using errcode='22023'; end if;
 select * into old_line from public.treasury_ofx_lines where tenant_id=p_tenant_id and bank_account_id=a.id and fit_id=fit;
 if found then
 if old_line.posted_on<>posted or old_line.amount<>signed_amount or old_line.description<>description_text or old_line.reference is distinct from reference_text then raise exception 'FITID reused with divergent data' using errcode='23505'; end if;
 elsif batch.id is not null then raise exception 'File hash reused with different lines' using errcode='23505';
 else
 insert into public.treasury_ofx_lines(tenant_id,branch_id,bank_account_id,import_id,fit_id,posted_on,amount,description,reference) values(p_tenant_id,a.branch_id,a.id,result,fit,posted,signed_amount,description_text,reference_text); inserted:=inserted+1;
 end if;
 end loop;
 if batch.id is null then
 update public.treasury_ofx_imports set inserted_count=inserted where id=result;
 perform app_private.write_operational_audit('treasury.ofx.imported',p_tenant_id,a.branch_id,result,actor,jsonb_build_object('account_id',a.id,'file_sha256',p_file_sha256,'line_count',jsonb_array_length(p_lines),'inserted_count',inserted));
 end if;
 return jsonb_build_object('import_id',result,'inserted_count',inserted,'duplicate_count',jsonb_array_length(p_lines)-inserted,'replayed',batch.id is not null);
end;$f$;

create function public.operational_get_ofx_reconciliation(p_tenant_id uuid,p_branch_id uuid,p_from date,p_to date,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' set row_security=off as $f$
begin
 perform app_private.assert_treasury_permission(p_tenant_id,'transaction.treasury.read',p_branch_id);
 if p_from is null or p_to is null or p_from>p_to or p_to-p_from>366 or p_offset is null or p_offset<0 then raise exception 'Invalid OFX query period or offset' using errcode='22023'; end if;
 return jsonb_build_object('bindings',coalesce((select jsonb_agg(jsonb_build_object('bank_account_id',b.bank_account_id,'bank_code',b.bank_code,'branch_code',b.branch_code,'account_suffix',right(b.external_account_id,4))) from public.treasury_ofx_account_bindings b where b.tenant_id=p_tenant_id and b.branch_id=p_branch_id),'[]'::jsonb),
 'lines',coalesce((select jsonb_agg(jsonb_build_object('id',l.id,'bank_account_id',l.bank_account_id,'fit_id',l.fit_id,'posted_on',l.posted_on,'amount',l.amount,'description',l.description,'reference',l.reference,'matched_movement_id',l.matched_movement_id,'suggestions',coalesce((select jsonb_agg(to_jsonb(s) order by s.reference_match desc,s.date_distance,s.id) from (
 select m.id,m.occurred_on,m.description,m.amount,m.direction,abs(m.occurred_on-l.posted_on) date_distance,(l.reference is not null and position(lower(l.reference) in lower(m.description))>0 or position(lower(l.fit_id) in lower(m.description))>0) reference_match
 from public.treasury_bank_movements m where m.tenant_id=l.tenant_id and m.branch_id=l.branch_id and m.bank_account_id=l.bank_account_id and m.reconciled_at is null and (case m.direction when 'in' then m.amount else -m.amount end)=l.amount and abs(m.occurred_on-l.posted_on)<=3 and l.matched_movement_id is null order by reference_match desc,date_distance,m.id limit 5) s),'[]'::jsonb)) order by l.posted_on,l.id) from (select * from public.treasury_ofx_lines where tenant_id=p_tenant_id and branch_id=p_branch_id and posted_on between p_from and p_to order by posted_on,id limit 101 offset p_offset) l),'[]'::jsonb));
end;$f$;

create function public.operational_confirm_ofx_reconciliation(p_tenant_id uuid,p_line_id uuid,p_movement_id uuid,p_allow_date_difference boolean default false)
returns uuid language plpgsql security definer set search_path='' set row_security=off as $f$
declare line public.treasury_ofx_lines%rowtype; m public.treasury_bank_movements%rowtype; actor uuid;
begin
 -- Consistent movement-first lock order with manual un-reconciliation trigger.
 select * into m from public.treasury_bank_movements where tenant_id=p_tenant_id and id=p_movement_id for update;
 if not found then raise exception 'Bank movement not found' using errcode='23503'; end if;
 actor:=app_private.assert_treasury_permission(p_tenant_id,'transaction.treasury.reconcile.manage',m.branch_id);
 select * into line from public.treasury_ofx_lines where tenant_id=p_tenant_id and id=p_line_id for update;
 if not found or line.branch_id<>m.branch_id or line.bank_account_id<>m.bank_account_id then raise exception 'Statement and movement must belong to the same company, branch and bank account' using errcode='23514'; end if;
 if line.matched_movement_id=p_movement_id and m.statement_reference='OFX:'||line.id::text and m.reconciled_at is not null then return m.id; end if;
 if line.matched_movement_id is not null or m.reconciled_at is not null then raise exception 'Statement or movement is already reconciled' using errcode='55000'; end if;
 if line.amount<>(case m.direction when 'in' then m.amount else -m.amount end) or abs(m.occurred_on-line.posted_on)>3 or (m.occurred_on<>line.posted_on and not coalesce(p_allow_date_difference,false)) then raise exception 'Amount/date mismatch; differing dates within three days require explicit confirmation' using errcode='23514'; end if;
 update public.treasury_bank_movements set reconciled_at=clock_timestamp(),reconciled_by_user_id=actor,statement_reference='OFX:'||line.id::text where id=m.id;
 update public.treasury_ofx_lines set matched_movement_id=m.id,matched_at=clock_timestamp(),matched_by_user_id=actor where id=line.id;
 perform app_private.write_operational_audit('treasury.ofx.reconciled',p_tenant_id,m.branch_id,m.id,actor,jsonb_build_object('statement_line_id',line.id,'fit_id',line.fit_id,'statement_date',line.posted_on,'movement_date',m.occurred_on,'date_difference_confirmed',coalesce(p_allow_date_difference,false))); return m.id;
end;$f$;
create function app_private.clear_ofx_reconciliation_on_unmatch()
returns trigger language plpgsql security definer set search_path='' set row_security=off as $f$
begin
 if old.reconciled_at is not null and new.reconciled_at is null then
 update public.treasury_ofx_lines set matched_movement_id=null,matched_at=null,matched_by_user_id=null where tenant_id=old.tenant_id and matched_movement_id=old.id;
 end if;return new;
end;$f$;
create trigger treasury_ofx_unmatch after update of reconciled_at on public.treasury_bank_movements for each row execute function app_private.clear_ofx_reconciliation_on_unmatch();

alter function app_private.assert_ofx_import_permission(uuid,uuid) owner to postgres;
alter function app_private.clear_ofx_reconciliation_on_unmatch() owner to postgres;
alter function public.operational_bind_ofx_bank_account(uuid,uuid,text,text,text) owner to postgres;
alter function public.operational_import_ofx_statement(uuid,uuid,text,text,text,text,text,date,date,jsonb) owner to postgres;
alter function public.operational_get_ofx_reconciliation(uuid,uuid,date,date,integer) owner to postgres;
alter function public.operational_confirm_ofx_reconciliation(uuid,uuid,uuid,boolean) owner to postgres;
revoke all on function app_private.assert_ofx_import_permission(uuid,uuid),app_private.clear_ofx_reconciliation_on_unmatch(),public.operational_bind_ofx_bank_account(uuid,uuid,text,text,text),public.operational_import_ofx_statement(uuid,uuid,text,text,text,text,text,date,date,jsonb),public.operational_get_ofx_reconciliation(uuid,uuid,date,date,integer),public.operational_confirm_ofx_reconciliation(uuid,uuid,uuid,boolean) from public,anon,authenticated,service_role;
grant execute on function public.operational_bind_ofx_bank_account(uuid,uuid,text,text,text),public.operational_import_ofx_statement(uuid,uuid,text,text,text,text,text,date,date,jsonb),public.operational_get_ofx_reconciliation(uuid,uuid,date,date,integer),public.operational_confirm_ofx_reconciliation(uuid,uuid,uuid,boolean) to authenticated;
commit;
