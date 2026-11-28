begin;

-- SaaS control plane: no billing gateway, no automatic entitlement or company activation.
create table public.saas_plans (
  id uuid primary key default gen_random_uuid(), code text not null unique check (code ~ '^[A-Z][A-Z0-9_]{1,31}$'), name text not null check (length(btrim(name)) between 2 and 160),
  status text not null default 'draft' check (status in ('draft','active','retired')), max_companies integer check (max_companies is null or max_companies > 0), max_branches integer check (max_branches is null or max_branches > 0), max_users integer check (max_users is null or max_users > 0), created_at timestamptz not null default clock_timestamp(), updated_at timestamptz not null default clock_timestamp()
);
create table public.saas_subscriptions (
  id uuid primary key default gen_random_uuid(), tenant_id uuid not null unique references public.companies(id) on delete restrict, plan_id uuid not null references public.saas_plans(id) on delete restrict,
  status text not null default 'pending' check (status in ('pending','active','past_due','suspended','cancelled')), starts_at timestamptz, ends_at timestamptz, delinquent_at timestamptz, suspended_at timestamptz, reason text check (reason is null or length(btrim(reason)) between 10 and 1000), changed_by_user_id uuid not null references auth.users(id) on delete restrict, changed_at timestamptz not null default clock_timestamp()
);
create table public.saas_subscription_events (
  id uuid primary key default gen_random_uuid(), subscription_id uuid not null references public.saas_subscriptions(id) on delete restrict, tenant_id uuid not null references public.companies(id) on delete restrict, event_key text not null check (event_key in ('created','activated','past_due','suspended','reactivated','cancelled','plan_changed')), reason text check (reason is null or length(btrim(reason)) between 10 and 1000), actor_user_id uuid not null references auth.users(id) on delete restrict, created_at timestamptz not null default clock_timestamp()
);
alter table public.saas_plans enable row level security; alter table public.saas_plans force row level security;
alter table public.saas_subscriptions enable row level security; alter table public.saas_subscriptions force row level security;
alter table public.saas_subscription_events enable row level security; alter table public.saas_subscription_events force row level security;
revoke all on table public.saas_plans,public.saas_subscriptions,public.saas_subscription_events from public,anon,authenticated,service_role;

create function public.master_save_saas_plan(p_code text,p_name text,p_status text,p_max_branches integer,p_max_users integer)
returns uuid language plpgsql security definer set search_path='' set row_security=off as $f$
declare actor uuid; result uuid;
begin
 actor:=app_private.assert_current_master();
 if coalesce(p_code,'') !~ '^[A-Z][A-Z0-9_]{1,31}$' or length(btrim(coalesce(p_name,''))) not between 2 and 160 or p_status is null or p_status not in ('draft','active','retired') or p_max_branches<=0 or p_max_users<=0 then raise exception 'Invalid SaaS plan' using errcode='22023'; end if;
 insert into public.saas_plans(code,name,status,max_companies,max_branches,max_users) values(p_code,btrim(p_name),p_status,1,p_max_branches,p_max_users)
 on conflict(code) do update set name=excluded.name,status=excluded.status,max_branches=excluded.max_branches,max_users=excluded.max_users,updated_at=clock_timestamp() returning id into result;
 perform app_private.write_provisioning_audit('saas.plan.saved',null,null,actor,jsonb_build_object('plan_id',result,'code',p_code,'status',p_status)); return result;
end;$f$;

create function public.master_manage_saas_subscription(p_tenant_id uuid,p_plan_id uuid,p_status text,p_reason text default null)
returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $f$
declare actor uuid; result uuid; normalized_reason text:=nullif(btrim(coalesce(p_reason,'')), ''); event_name text; previous public.saas_subscriptions%rowtype; plan public.saas_plans%rowtype;
begin
 actor:=app_private.assert_current_master();
 if p_tenant_id is null or p_plan_id is null or p_status is null or p_status not in ('pending','active','past_due','suspended','cancelled') or coalesce(length(normalized_reason),0) not between 10 and 1000 then raise exception 'Valid subscription and detailed reason required' using errcode='22023'; end if;
 perform 1 from public.companies where id=p_tenant_id for update;
 if not found then raise exception 'Company not found' using errcode='23503'; end if;
 select * into previous from public.saas_subscriptions where tenant_id=p_tenant_id for update;
 select * into plan from public.saas_plans where id=p_plan_id for share;
 if not found or (plan.status<>'active' and (previous.plan_id is distinct from p_plan_id or p_status not in ('suspended','cancelled'))) then raise exception 'Active plan required for assignment or activation' using errcode='23503'; end if;
 if previous.id is null and p_status<>'pending' then raise exception 'New subscription must start pending' using errcode='55000'; end if;
 if previous.id is not null and previous.status<>p_status and not (
 (previous.status='pending' and p_status in ('active','cancelled')) or
 (previous.status='active' and p_status in ('past_due','suspended','cancelled')) or
 (previous.status='past_due' and p_status in ('active','suspended','cancelled')) or
 (previous.status='suspended' and p_status in ('active','cancelled')))
 then raise exception 'Invalid subscription transition' using errcode='55000'; end if;
 if previous.status='cancelled' and previous.plan_id is distinct from p_plan_id then raise exception 'Cancelled subscription is immutable' using errcode='55000'; end if;
 if previous.status is not distinct from p_status and previous.plan_id is not distinct from p_plan_id then return previous.id; end if;
 if p_status='active' and ((plan.max_branches is not null and (select count(*) from public.branches where tenant_id=p_tenant_id and status='active')>plan.max_branches) or (plan.max_users is not null and (select count(*) from public.company_memberships where tenant_id=p_tenant_id and status='active')>plan.max_users)) then raise exception 'Company exceeds plan capacity' using errcode='23514'; end if;
 insert into public.saas_subscriptions(tenant_id,plan_id,status,starts_at,ends_at,delinquent_at,suspended_at,reason,changed_by_user_id)
 values(p_tenant_id,p_plan_id,p_status,case when p_status='active' then clock_timestamp() end,case when p_status='cancelled' then clock_timestamp() end,case when p_status='past_due' then clock_timestamp() end,case when p_status='suspended' then clock_timestamp() end,normalized_reason,actor)
 on conflict(tenant_id) do update set plan_id=excluded.plan_id,status=excluded.status,starts_at=coalesce(public.saas_subscriptions.starts_at,excluded.starts_at),ends_at=excluded.ends_at,delinquent_at=excluded.delinquent_at,suspended_at=excluded.suspended_at,reason=excluded.reason,changed_by_user_id=actor,changed_at=clock_timestamp() returning id into result;
 event_name:=case when previous.id is null then 'created' when previous.status=p_status and previous.plan_id<>p_plan_id then 'plan_changed' when p_status='active' and previous.starts_at is not null then 'reactivated' when p_status='active' then 'activated' else p_status end;
 insert into public.saas_subscription_events(subscription_id,tenant_id,event_key,reason,actor_user_id) values(result,p_tenant_id,event_name,normalized_reason,actor);
 perform app_private.write_provisioning_audit('saas.subscription.'||event_name,p_tenant_id,null,actor,jsonb_build_object('subscription_id',result,'previous_plan_id',previous.plan_id,'plan_id',p_plan_id,'previous_status',previous.status,'status',p_status));
 return result;
end;$f$;

create function public.master_get_saas_control_plane()
returns jsonb language plpgsql stable security definer set search_path='' set row_security=off as $f$
begin
 perform app_private.assert_current_master();
 return jsonb_build_object('plans',coalesce((select jsonb_agg(to_jsonb(p) order by p.code) from public.saas_plans p),'[]'::jsonb),
 'subscriptions',coalesce((select jsonb_agg(to_jsonb(s) order by s.changed_at desc) from public.saas_subscriptions s),'[]'::jsonb),
 'companies',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.legal_name,'status',c.status,'branches',(select count(*) from public.branches b where b.tenant_id=c.id and b.status='active'),'members',(select count(*) from public.company_memberships m where m.tenant_id=c.id and m.status='active'))) from public.companies c),'[]'::jsonb),
 'events',coalesce((select jsonb_agg(to_jsonb(e) order by e.created_at desc) from (select * from public.saas_subscription_events order by created_at desc,id limit 100) e),'[]'::jsonb));
end;$f$;
alter function public.master_save_saas_plan(text,text,text,integer,integer) owner to postgres;
alter function public.master_manage_saas_subscription(uuid,uuid,text,text) owner to postgres;
alter function public.master_get_saas_control_plane() owner to postgres;
revoke all on function public.master_save_saas_plan(text,text,text,integer,integer),public.master_manage_saas_subscription(uuid,uuid,text,text),public.master_get_saas_control_plane() from public,anon,authenticated,service_role;
grant execute on function public.master_save_saas_plan(text,text,text,integer,integer),public.master_manage_saas_subscription(uuid,uuid,text,text),public.master_get_saas_control_plane() to authenticated;
commit;
