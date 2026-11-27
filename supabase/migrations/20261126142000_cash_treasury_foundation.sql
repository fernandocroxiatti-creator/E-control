begin;

-- Caixa interno: não cria fatos financeiros. Liquidações financeiras futuras
-- podem referenciá-lo, mas toda abertura/fechamento continua tenant/filial scoped.
do $preflight$
begin
  if current_user <> 'postgres' then raise exception 'Apply this migration as postgres'; end if;
  if pg_catalog.to_regclass('public.financial_obligations') is null then
    raise exception 'Financial obligations foundation is required before cash';
  end if;
end $preflight$;

insert into public.permission_definitions(permission_key,description) values
 ('transaction.cash.register.open','Transação ZCX01: abrir caixa.'),
 ('transaction.cash.register.move','Transação ZCX02: registrar suprimento, sangria e movimento de caixa.'),
 ('transaction.cash.register.close','Transação ZCX03: fechar caixa.'),
 ('transaction.cash.register.read','Transação ZCX04: consultar caixa e histórico.')
on conflict(permission_key) do nothing;
insert into public.erp_transaction_authorization_catalog(transaction_code,module_code,permission_key) values
 ('ZCX01','CSH','transaction.cash.register.open'),('ZCX02','CSH','transaction.cash.register.move'),('ZCX03','CSH','transaction.cash.register.close'),('ZCX04','CSH','transaction.cash.register.read')
on conflict(transaction_code) do nothing;

create table public.cash_registers (
 id uuid primary key default pg_catalog.gen_random_uuid(), tenant_id uuid not null references public.companies(id) on delete restrict,
 branch_id uuid not null, code text not null check (code=pg_catalog.upper(pg_catalog.btrim(code)) and pg_catalog.length(code) between 2 and 32),
 name text not null check(pg_catalog.length(pg_catalog.btrim(name)) between 2 and 160), status text not null default 'active' check(status in ('active','inactive')),
 created_by_user_id uuid not null references auth.users(id) on delete restrict, request_id uuid not null, request_payload jsonb not null, created_at timestamptz not null default pg_catalog.clock_timestamp(),
 unique(tenant_id,branch_id,code), unique(tenant_id,request_id), foreign key(tenant_id,branch_id) references public.branches(tenant_id,id) on delete restrict
);
create table public.cash_sessions (
 id uuid primary key default pg_catalog.gen_random_uuid(), tenant_id uuid not null, branch_id uuid not null, cash_register_id uuid not null references public.cash_registers(id) on delete restrict,
 status text not null check(status in ('open','closed')), opening_amount numeric(24,8) not null check(opening_amount>=0), closing_amount numeric(24,8), expected_amount numeric(24,8), difference_amount numeric(24,8),
 opened_by_user_id uuid not null references auth.users(id) on delete restrict, opened_at timestamptz not null default pg_catalog.clock_timestamp(), closed_by_user_id uuid references auth.users(id) on delete restrict, closed_at timestamptz,
 request_id uuid not null, request_payload jsonb not null, close_request_id uuid, close_request_payload jsonb,
 unique(tenant_id,request_id), unique(tenant_id,close_request_id), foreign key(tenant_id,branch_id) references public.branches(tenant_id,id) on delete restrict
);
create unique index cash_sessions_one_open_per_register on public.cash_sessions(tenant_id,cash_register_id) where status='open';
create table public.cash_movements (
 id uuid primary key default pg_catalog.gen_random_uuid(), tenant_id uuid not null, branch_id uuid not null, cash_session_id uuid not null references public.cash_sessions(id) on delete restrict,
 movement_type text not null check(movement_type in ('supply','withdrawal','payment','receipt','adjustment')),
 amount numeric(24,8) not null check(amount>0), direction text not null check(direction in ('in','out')), reason text not null check(pg_catalog.length(pg_catalog.btrim(reason)) between 3 and 1000),
 source_obligation_id uuid references public.financial_obligations(id) on delete restrict, actor_user_id uuid not null references auth.users(id) on delete restrict, request_id uuid not null, request_payload jsonb not null, created_at timestamptz not null default pg_catalog.clock_timestamp(),
 unique(tenant_id,request_id), foreign key(tenant_id,branch_id) references public.branches(tenant_id,id) on delete restrict
);
alter table public.cash_registers enable row level security; alter table public.cash_registers force row level security;
alter table public.cash_sessions enable row level security; alter table public.cash_sessions force row level security;
alter table public.cash_movements enable row level security; alter table public.cash_movements force row level security;
revoke all on table public.cash_registers,public.cash_sessions,public.cash_movements from public,anon,authenticated,service_role;
commit;
