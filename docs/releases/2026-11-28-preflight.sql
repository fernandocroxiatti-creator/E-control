-- Somente leitura. Executar antes e depois da publicação autorizada.
-- Não concede permissões, não aprova transações e não habilita empresas.
begin read only;
with expected(code) as (values
 ('ZCX01'),('ZCX02'),('ZCX03'),('ZCX04'),
 ('ZTR02'),('ZTR03'),('ZTR04'),('ZTR05'),('ZTR06'),
 ('ZGE01'),('ZGE02'),('ZFB04'),
 ('ZRP01'),('ZRP02'),('ZRP03'),('ZRP04'),('ZRP05'),('ZRP06'),('ZIV01'))
select e.code, c.module_code, c.permission_key,
 c.approval_state as transaction_approval, p.approval_state as permission_approval,
 (select count(*) from public.company_transaction_availability a where a.transaction_code=e.code and a.enabled) as enabled_company_count
from expected e left join public.erp_transaction_authorization_catalog c on c.transaction_code=e.code
left join public.permission_definitions p on p.permission_key=c.permission_key
order by e.code;
-- O resultado abaixo deve ser zero antes de qualquer GO comercial.
select count(*) as ziv01_enabled_companies
from public.company_transaction_availability where transaction_code='ZIV01' and enabled;
rollback;
