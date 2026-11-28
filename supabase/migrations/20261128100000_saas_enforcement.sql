begin;
-- Existing tenants are not enrolled in a commercial policy automatically.
-- Commercial access never grants operational authorization.
create table public.saas_company_policies (
 tenant_id uuid primary key references public.companies(id) on delete restrict,
 enforcement_enabled boolean not null default false,
 block_on_overdue boolean not null default true,
 due_on date,
 grace_days integer not null default 0 check(grace_days between 0 and 90),
 reason text not null check(length(btrim(reason)) between 10 and 1000),
 changed_by_user_id uuid not null references auth.users(id),
 changed_at timestamptz not null default clock_timestamp(),
 check(not enforcement_enabled or due_on is not null)
);
alter table public.saas_company_policies enable row level security;
alter table public.saas_company_policies force row level security;
revoke all on table public.saas_company_policies from public,anon,authenticated,service_role;

create function app_private.saas_operational_allowed(p_tenant_id uuid)
returns boolean language plpgsql stable security definer set search_path='' set row_security=off as $f$
declare subscription public.saas_subscriptions%rowtype; policy public.saas_company_policies%rowtype; today date:=(statement_timestamp() at time zone 'America/Sao_Paulo')::date;
begin
 select * into subscription from public.saas_subscriptions where tenant_id=p_tenant_id;
 select * into policy from public.saas_company_policies where tenant_id=p_tenant_id;
 if subscription.id is null then return not coalesce(policy.enforcement_enabled,false); end if;
 if subscription.status in ('pending','suspended','cancelled') then return false; end if;
 if coalesce(policy.enforcement_enabled,false) and policy.block_on_overdue and today>policy.due_on+policy.grace_days then return false; end if;
 -- past_due without an enrolled/due-dated policy fails closed; Master can regularize.
 if subscription.status='past_due' and not coalesce(policy.enforcement_enabled,false) then return false; end if;
 return true;
end;$f$;

create or replace function app_private.has_tenant_permission(
  p_tenant_id uuid,
  p_permission_key text,
  p_branch_id uuid default null
)
returns boolean
language sql
stable
security definer
set search_path = ''
set row_security = off
as $function$
  select (p_permission_key not like 'transaction.%' or app_private.saas_operational_allowed(p_tenant_id)) and exists (
    select 1
    from public.company_memberships as membership
    join public.companies as company
      on company.id = membership.tenant_id
     and company.status = 'active'
    join public.membership_role_assignments as assignment
      on assignment.tenant_id = membership.tenant_id
     and assignment.membership_id = membership.id
    join public.access_role_definitions as role_definition
      on role_definition.role_key = assignment.role_key
     and role_definition.approval_state = 'approved'
    join public.permission_definitions as permission
      on permission.permission_key = p_permission_key
     and permission.approval_state = 'approved'
    where membership.tenant_id = p_tenant_id
      and membership.user_id = auth.uid()
      and membership.status = 'active'
      and (
        (role_definition.scope = 'company' and assignment.branch_id is null)
        or (
          role_definition.scope = 'branch'
          and p_branch_id is not null
          and assignment.branch_id = p_branch_id
        )
      )
      and (
        (permission.permission_key not like 'transaction.%'
          and exists (
            select 1 from public.role_permission_grants global_grant
            where global_grant.role_key = role_definition.role_key
              and global_grant.permission_key = permission.permission_key
          ))
        or exists (
          select 1 from public.company_role_permission_grants scoped_grant
          where scoped_grant.tenant_id = p_tenant_id
            and scoped_grant.role_key = role_definition.role_key
            and scoped_grant.permission_key = permission.permission_key
            and scoped_grant.grant_scope = permission.grant_scope
            and (
              (permission.grant_scope = 'company' and scoped_grant.branch_id is null)
              or (permission.grant_scope = 'branch' and p_branch_id is not null and scoped_grant.branch_id = p_branch_id)
            )
        )
      )
      and (p_branch_id is null or app_private.can_access_branch(p_tenant_id, p_branch_id))
  );
$function$;

-- Company row is the common serialization point for seat/branch mutations.
create function app_private.enforce_saas_resource_capacity()
returns trigger language plpgsql security definer set search_path='' set row_security=off as $f$
declare contracted public.saas_plans%rowtype; used bigint; cap integer;
begin
 if tg_op='UPDATE' and new.tenant_id is distinct from old.tenant_id then raise exception 'Company ownership cannot be changed' using errcode='23514'; end if;
 if (tg_table_name='branches' and new.status<>'active') or (tg_table_name='company_memberships' and new.status not in ('pending','active')) then return new; end if;
 perform 1 from public.companies where id=new.tenant_id for update;
 select p.* into contracted from public.saas_subscriptions s join public.saas_plans p on p.id=s.plan_id where s.tenant_id=new.tenant_id;
 if not found then return new; end if;
 if tg_table_name='branches' then
 cap:=contracted.max_branches;
 select count(*) into used from public.branches where tenant_id=new.tenant_id and status='active' and id<>new.id;
 else
 cap:=contracted.max_users;
 select count(*) into used from public.company_memberships where tenant_id=new.tenant_id and status in ('pending','active') and id<>new.id;
 end if;
 if cap is not null and used+1>cap then raise exception 'Contracted resource limit reached; request a plan review' using errcode='23514'; end if;
 return new;
end;$f$;
create trigger saas_branch_capacity before insert or update on public.branches for each row execute function app_private.enforce_saas_resource_capacity();
create trigger saas_member_capacity before insert or update on public.company_memberships for each row execute function app_private.enforce_saas_resource_capacity();

create function app_private.enforce_saas_contract_capacity()
returns trigger language plpgsql security definer set search_path='' set row_security=off as $f$
declare contracted public.saas_plans%rowtype; company_id uuid;
begin
 if tg_table_name='saas_plans' then
 for company_id in select tenant_id from public.saas_subscriptions where plan_id=new.id and status<>'cancelled' order by tenant_id loop
 perform 1 from public.companies where id=company_id for update;
 if (new.max_branches is not null and (select count(*) from public.branches where tenant_id=company_id and status='active')>new.max_branches)
 or (new.max_users is not null and (select count(*) from public.company_memberships where tenant_id=company_id and status in ('pending','active'))>new.max_users) then raise exception 'Plan change would exceed existing resource usage' using errcode='23514'; end if;
 end loop;
 else
 perform 1 from public.companies where id=new.tenant_id for update;
 select * into contracted from public.saas_plans where id=new.plan_id;
 if new.status<>'cancelled' and ((contracted.max_branches is not null and (select count(*) from public.branches where tenant_id=new.tenant_id and status='active')>contracted.max_branches)
 or (contracted.max_users is not null and (select count(*) from public.company_memberships where tenant_id=new.tenant_id and status in ('pending','active'))>contracted.max_users)) then raise exception 'Subscription change would exceed existing resource usage' using errcode='23514'; end if;
 end if;
 return new;
end;$f$;
create trigger saas_plan_capacity before update on public.saas_plans for each row execute function app_private.enforce_saas_contract_capacity();
create trigger saas_subscription_capacity before insert or update on public.saas_subscriptions for each row execute function app_private.enforce_saas_contract_capacity();

create function public.master_set_saas_company_policy(p_tenant_id uuid,p_enforcement_enabled boolean,p_block_on_overdue boolean,p_due_on date,p_grace_days integer,p_reason text)
returns uuid language plpgsql security definer set search_path='' set row_security=off as $f$
declare actor uuid; previous public.saas_company_policies%rowtype;
begin
 actor:=app_private.assert_current_master();
 if p_tenant_id is null or p_enforcement_enabled is null or p_block_on_overdue is null or p_grace_days is null or p_grace_days not between 0 and 90 or (p_enforcement_enabled and p_due_on is null) or length(btrim(coalesce(p_reason,''))) not between 10 and 1000 then raise exception 'Valid commercial policy and reason required' using errcode='22023'; end if;
 perform 1 from public.companies where id=p_tenant_id for update;
 if not found then raise exception 'Company not found' using errcode='23503'; end if;
 if p_enforcement_enabled and not exists(select 1 from public.saas_subscriptions where tenant_id=p_tenant_id) then raise exception 'Assign subscription before enabling commercial enforcement' using errcode='55000'; end if;
 select * into previous from public.saas_company_policies where tenant_id=p_tenant_id;
 insert into public.saas_company_policies(tenant_id,enforcement_enabled,block_on_overdue,due_on,grace_days,reason,changed_by_user_id)
 values(p_tenant_id,p_enforcement_enabled,p_block_on_overdue,p_due_on,p_grace_days,btrim(p_reason),actor)
 on conflict(tenant_id) do update set enforcement_enabled=excluded.enforcement_enabled,block_on_overdue=excluded.block_on_overdue,due_on=excluded.due_on,grace_days=excluded.grace_days,reason=excluded.reason,changed_by_user_id=actor,changed_at=clock_timestamp();
 perform app_private.write_provisioning_audit('saas.policy.changed',p_tenant_id,null,actor,jsonb_build_object('before',to_jsonb(previous),'enforcement_enabled',p_enforcement_enabled,'block_on_overdue',p_block_on_overdue,'due_on',p_due_on,'grace_days',p_grace_days,'reason',btrim(p_reason))); return p_tenant_id;
end;$f$;

create function public.master_reactivate_saas_company(p_tenant_id uuid,p_due_on date,p_reason text)
returns uuid language plpgsql security definer set search_path='' set row_security=off as $f$
declare actor uuid; subscription public.saas_subscriptions%rowtype; policy public.saas_company_policies%rowtype; result uuid;
begin
 actor:=app_private.assert_current_master();
 if p_due_on is null or p_due_on<(statement_timestamp() at time zone 'America/Sao_Paulo')::date or length(btrim(coalesce(p_reason,''))) not between 10 and 1000 then raise exception 'A current/future due date and reason are required' using errcode='22023'; end if;
 perform 1 from public.companies where id=p_tenant_id for update;
 select * into subscription from public.saas_subscriptions where tenant_id=p_tenant_id;
 if not found or subscription.status='cancelled' then raise exception 'An existing non-cancelled subscription is required' using errcode='55000'; end if;
 select * into policy from public.saas_company_policies where tenant_id=p_tenant_id;
 result:=public.master_manage_saas_subscription(p_tenant_id,subscription.plan_id,'active',p_reason);
 perform public.master_set_saas_company_policy(p_tenant_id,true,coalesce(policy.block_on_overdue,true),p_due_on,coalesce(policy.grace_days,0),p_reason);
 perform app_private.write_provisioning_audit('saas.company.manually_reactivated',p_tenant_id,null,actor,jsonb_build_object('subscription_id',result,'due_on',p_due_on,'reason',btrim(p_reason)));
 return result;
end;$f$;

create function public.company_get_saas_subscription(p_tenant_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' set row_security=off as $f$
declare subscription public.saas_subscriptions%rowtype; policy public.saas_company_policies%rowtype; plan public.saas_plans%rowtype;
begin
 if coalesce(auth.role(),'')<>'authenticated' or auth.uid() is null or not exists(select 1 from public.company_memberships where tenant_id=p_tenant_id and user_id=auth.uid() and status='active') then raise exception 'Active company membership required' using errcode='42501'; end if;
 select * into subscription from public.saas_subscriptions where tenant_id=p_tenant_id;
 select * into policy from public.saas_company_policies where tenant_id=p_tenant_id;
 select * into plan from public.saas_plans where id=subscription.plan_id;
 return jsonb_build_object('tenant_id',p_tenant_id,'plan',plan.name,'status',subscription.status,'due_on',policy.due_on,'grace_days',coalesce(policy.grace_days,0),'enforcement_enabled',coalesce(policy.enforcement_enabled,false),'operational_allowed',app_private.saas_operational_allowed(p_tenant_id),'branches_used',(select count(*) from public.branches where tenant_id=p_tenant_id and status='active'),'users_used',(select count(*) from public.company_memberships where tenant_id=p_tenant_id and status in ('pending','active')),'max_branches',plan.max_branches,'max_users',plan.max_users);
end;$f$;

create function public.master_list_saas_policies()
returns jsonb language plpgsql stable security definer set search_path='' set row_security=off as $f$
begin
 perform app_private.assert_current_master();
 return coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('operational_allowed',app_private.saas_operational_allowed(p.tenant_id)) order by p.tenant_id) from public.saas_company_policies p),'[]'::jsonb);
end;$f$;

alter function app_private.saas_operational_allowed(uuid) owner to postgres;
alter function app_private.has_tenant_permission(uuid,text,uuid) owner to postgres;
alter function app_private.enforce_saas_resource_capacity() owner to postgres;
alter function app_private.enforce_saas_contract_capacity() owner to postgres;
alter function public.master_set_saas_company_policy(uuid,boolean,boolean,date,integer,text) owner to postgres;
alter function public.master_reactivate_saas_company(uuid,date,text) owner to postgres;
alter function public.company_get_saas_subscription(uuid) owner to postgres;
alter function public.master_list_saas_policies() owner to postgres;
revoke all on function app_private.saas_operational_allowed(uuid),app_private.has_tenant_permission(uuid,text,uuid),app_private.enforce_saas_resource_capacity(),app_private.enforce_saas_contract_capacity(),public.master_set_saas_company_policy(uuid,boolean,boolean,date,integer,text),public.master_reactivate_saas_company(uuid,date,text),public.company_get_saas_subscription(uuid),public.master_list_saas_policies() from public,anon,authenticated,service_role;
grant execute on function public.master_set_saas_company_policy(uuid,boolean,boolean,date,integer,text),public.master_reactivate_saas_company(uuid,date,text),public.company_get_saas_subscription(uuid),public.master_list_saas_policies() to authenticated;
commit;
