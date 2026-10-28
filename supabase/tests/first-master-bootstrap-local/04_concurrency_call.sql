set role authenticated;
set request.jwt.claim.sub = '30000000-0000-4000-8000-000000000003';
set request.jwt.claim.role = 'authenticated';
select public.bootstrap_first_master();
