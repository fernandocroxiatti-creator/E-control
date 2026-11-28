begin;

-- Restore the API entry point omitted from the commercial-billing grant list.
-- The existing SECURITY DEFINER function still enforces company membership,
-- branch scope, ZOS02, billing eligibility, audit and idempotency internally.
-- No company, role-permission or transaction-availability grant is added.
grant execute on function public.operational_reverse_work_order_direct_purchase(uuid,uuid,uuid,text,uuid) to authenticated;

commit;
