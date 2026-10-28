insert into auth.users (id) values ('30000000-0000-4000-8000-000000000003');
insert into app_private.first_master_bootstrap_authorization (
  target_user_id, approval_reference, authorization_reason, enabled, enabled_at
) values ('30000000-0000-4000-8000-000000000003', 'LOCAL-CONCURRENCY-APPROVAL', 'local concurrency test', true, clock_timestamp());
create function app_private.local_first_master_delay()
returns trigger language plpgsql set search_path = '' as $$ begin perform pg_catalog.pg_sleep(2); return new; end; $$;
create trigger local_first_master_delay before insert on app_private.master_admins
for each row execute function app_private.local_first_master_delay();
