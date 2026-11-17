-- Assertions after six genuinely overlapping sessions.  Exact values retain
-- eight decimal places, because moving-average residuals remain auditable.
do $assert$
declare q numeric; v numeric; c numeric; n integer;
begin
  -- Receipt -> transfer and transfer -> receipt preserve total quantity/value.
  select quantity,stock_value,average_unit_cost into q,v,c from public.inventory_balances where tenant_id='ca100000-0000-4000-8000-000000000001' and branch_id='ca200000-0000-4000-8000-000000000001' and item_id='ca500000-0000-4000-8000-000000000001';
  if q<>11 or v<>122.57142858 or c<>11.14285714 then raise exception 'receipt-first transfer origin valuation incorrect: %, %, %',q,v,c; end if;
  select quantity,stock_value,average_unit_cost into q,v,c from public.inventory_balances where tenant_id='ca100000-0000-4000-8000-000000000001' and branch_id='ca200000-0000-4000-8000-000000000002' and item_id='ca500000-0000-4000-8000-000000000001';
  if q<>3 or v<>33.42857142 or c<>11.14285714 then raise exception 'receipt-first transfer destination valuation incorrect: %, %, %',q,v,c; end if;
  select quantity,stock_value,average_unit_cost into q,v,c from public.inventory_balances where tenant_id='ca100000-0000-4000-8000-000000000001' and branch_id='ca200000-0000-4000-8000-000000000001' and item_id='ca500000-0000-4000-8000-000000000002';
  if q<>11 or v<>126 or c<>11.45454545 then raise exception 'transfer-first receipt origin valuation incorrect: %, %, %',q,v,c; end if;
  select quantity,stock_value,average_unit_cost into q,v,c from public.inventory_balances where tenant_id='ca100000-0000-4000-8000-000000000001' and branch_id='ca200000-0000-4000-8000-000000000002' and item_id='ca500000-0000-4000-8000-000000000002';
  if q<>3 or v<>30 or c<>10 then raise exception 'transfer-first receipt destination valuation incorrect: %, %, %',q,v,c; end if;
  if (select sum(quantity) from public.inventory_balances where tenant_id='ca100000-0000-4000-8000-000000000001' and item_id='ca500000-0000-4000-8000-000000000001')<>14
     or (select sum(stock_value) from public.inventory_balances where tenant_id='ca100000-0000-4000-8000-000000000001' and item_id='ca500000-0000-4000-8000-000000000001')<>156 then raise exception 'transfer-first total invariants failed'; end if;
  if (select sum(quantity) from public.inventory_balances where tenant_id='ca100000-0000-4000-8000-000000000001' and item_id='ca500000-0000-4000-8000-000000000002')<>14
     or (select sum(stock_value) from public.inventory_balances where tenant_id='ca100000-0000-4000-8000-000000000001' and item_id='ca500000-0000-4000-8000-000000000002')<>156 then raise exception 'transfer-second total invariants failed'; end if;
  if (select count(*) from public.inventory_transfers where tenant_id='ca100000-0000-4000-8000-000000000001' and item_id in ('ca500000-0000-4000-8000-000000000001','ca500000-0000-4000-8000-000000000002'))<>2 then raise exception 'duplicate transfer persisted'; end if;

  -- Receipt first makes the pre-existing count stale; re-count then post is required.
  select quantity,stock_value into q,v from public.inventory_balances where tenant_id='ca100000-0000-4000-8000-000000000001' and branch_id='ca200000-0000-4000-8000-000000000001' and item_id='ca500000-0000-4000-8000-000000000003';
  if q<>8 or v<>89.14285716 then raise exception 'stale-count revalidation valuation incorrect: %, %',q,v; end if;
  select quantity,stock_value into q,v from public.inventory_balances where tenant_id='ca100000-0000-4000-8000-000000000001' and branch_id='ca200000-0000-4000-8000-000000000001' and item_id='ca500000-0000-4000-8000-000000000004';
  if q<>12 or v<>136 then raise exception 'count-first receipt valuation incorrect: %, %',q,v; end if;
  if (select count(*) from public.inventory_count_sessions where tenant_id='ca100000-0000-4000-8000-000000000001' and status='posted')<>2 then raise exception 'inventory counts were not posted exactly once'; end if;

  -- O.S. consumption and receipts serialize on the same balance, without duplication.
  select quantity,stock_value into q,v from public.inventory_balances where tenant_id='ca100000-0000-4000-8000-000000000001' and branch_id='ca200000-0000-4000-8000-000000000001' and item_id='ca500000-0000-4000-8000-000000000005';
  if q<>11 or v<>122.57142858 then raise exception 'receipt-first O.S. valuation incorrect: %, %',q,v; end if;
  select quantity,stock_value into q,v from public.inventory_balances where tenant_id='ca100000-0000-4000-8000-000000000001' and branch_id='ca200000-0000-4000-8000-000000000001' and item_id='ca500000-0000-4000-8000-000000000006';
  if q<>11 or v<>126 then raise exception 'O.S.-first receipt valuation incorrect: %, %',q,v; end if;
  if exists(select 1 from public.inventory_balances where tenant_id='ca100000-0000-4000-8000-000000000001' and quantity<0) then raise exception 'negative stock persisted'; end if;
  if (select count(*) from public.work_order_part_reservations where tenant_id='ca100000-0000-4000-8000-000000000001' and status='consumed' and item_id in ('ca500000-0000-4000-8000-000000000005','ca500000-0000-4000-8000-000000000006'))<>2 then raise exception 'O.S. reservation consumption was duplicated or missing'; end if;
  if (select count(*) from app_private.operational_audit_events where tenant_id='ca100000-0000-4000-8000-000000000001' and event_key in ('purchase_receipt.created','inventory.transfer.created','inventory.count.posted','work_order.closed')) < 8 then raise exception 'concurrency audit events missing'; end if;

  -- Hardening regressions: one reversal + one receipt serialize safely, a
  -- transfer makes reversal fail closed, and inverse-order multiitem documents
  -- leave deterministic balances and values.
  select quantity,stock_value into q,v from public.inventory_balances where tenant_id='ca100000-0000-4000-8000-000000000001' and branch_id='ca200000-0000-4000-8000-000000000001' and item_id='ca500000-0000-4000-8000-000000000007';
  if q<>7 or v<>86 then raise exception 'receipt/reversal serialization valuation incorrect: %, %',q,v; end if;
  select quantity,stock_value into q,v from public.inventory_balances where tenant_id='ca100000-0000-4000-8000-000000000001' and branch_id='ca200000-0000-4000-8000-000000000001' and item_id='ca500000-0000-4000-8000-000000000008';
  if q<>1 or v<>10 then raise exception 'transfer/reversal D05 origin invariant failed: %, %',q,v; end if;
  select quantity,stock_value into q,v from public.inventory_balances where tenant_id='ca100000-0000-4000-8000-000000000001' and branch_id='ca200000-0000-4000-8000-000000000002' and item_id='ca500000-0000-4000-8000-000000000008';
  if q<>3 or v<>30 then raise exception 'transfer/reversal D05 destination invariant failed: %, %',q,v; end if;
  select quantity,stock_value into q,v from public.inventory_balances where tenant_id='ca100000-0000-4000-8000-000000000001' and branch_id='ca200000-0000-4000-8000-000000000001' and item_id='ca500000-0000-4000-8000-000000000009';
  if q<>1 or v<>10 or (select count(*) from public.work_order_part_reservations where tenant_id='ca100000-0000-4000-8000-000000000001' and item_id='ca500000-0000-4000-8000-000000000009' and status='consumed')<>1 then raise exception 'consumption/reversal D05 invariant failed: %, %',q,v; end if;
  select quantity,stock_value into q,v from public.inventory_balances where tenant_id='ca100000-0000-4000-8000-000000000001' and branch_id='ca200000-0000-4000-8000-000000000001' and item_id='ca500000-0000-4000-8000-000000000010';
  if q<>8 or v<>80 then raise exception 'inverse multi-receipt valuation incorrect for first item: %, %',q,v; end if;
  select quantity,stock_value into q,v from public.inventory_balances where tenant_id='ca100000-0000-4000-8000-000000000001' and branch_id='ca200000-0000-4000-8000-000000000001' and item_id='ca500000-0000-4000-8000-000000000011';
  if q<>8 or v<>80 then raise exception 'inverse multi-receipt valuation incorrect for second item: %, %',q,v; end if;
  select quantity,stock_value into q,v from public.inventory_balances where tenant_id='ca100000-0000-4000-8000-000000000001' and branch_id='ca200000-0000-4000-8000-000000000001' and item_id='ca500000-0000-4000-8000-000000000012';
  if q<>6 or v<>60 then raise exception 'inverse multi-reversal valuation incorrect for first item: %, %',q,v; end if;
  select quantity,stock_value into q,v from public.inventory_balances where tenant_id='ca100000-0000-4000-8000-000000000001' and branch_id='ca200000-0000-4000-8000-000000000001' and item_id='ca500000-0000-4000-8000-000000000013';
  if q<>6 or v<>60 then raise exception 'inverse multi-reversal valuation incorrect for second item: %, %',q,v; end if;
end;
$assert$;
