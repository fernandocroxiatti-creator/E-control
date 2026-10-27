alter table auth.users add column email text unique;
alter table auth.users add column email_confirmed_at timestamptz;
