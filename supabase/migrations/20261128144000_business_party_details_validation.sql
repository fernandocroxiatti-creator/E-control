begin;

-- Validate new/changed documents without rewriting or invalidating legacy rows.
create function app_private.valid_party_document(d text) returns boolean
language plpgsql immutable set search_path='' as $$
declare n integer; i integer; j integer; total integer; weight integer; digit integer;
begin
 if d is null then return true; end if;
 if d !~ '^([0-9]{11}|[0-9]{14})$' then return false; end if;
 n:=length(d);
 if d=repeat(substr(d,1,1),n) then return false; end if;
 for j in (n-1)..n loop
  total:=0;
  for i in 1..(j-1) loop
   weight:=case when n=11 then j+1-i else ((j-1-i)%8)+2 end;
   total:=total+substr(d,i,1)::integer*weight;
  end loop;
  digit:=case when total%11<2 then 0 else 11-total%11 end;
  if digit<>substr(d,j,1)::integer then return false; end if;
 end loop;
 return true;
end;$$;
alter function app_private.valid_party_document(text) owner to postgres;
revoke all on function app_private.valid_party_document(text) from public,anon,authenticated,service_role;

create function app_private.validate_party_document_change() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if TG_OP='INSERT' or new.document_number is distinct from old.document_number then
  if not app_private.valid_party_document(new.document_number) then raise exception 'Invalid CPF/CNPJ check digits' using errcode='22023'; end if;
 end if;
 return new;
end;$$;
alter function app_private.validate_party_document_change() owner to postgres;
revoke all on function app_private.validate_party_document_change() from public,anon,authenticated,service_role;
create trigger validate_party_document_change before insert or update of document_number on public.business_parties for each row execute function app_private.validate_party_document_change();

alter table public.business_parties add column trade_name text check(trade_name is null or length(btrim(trade_name)) between 1 and 200);
alter table public.business_parties drop constraint business_parties_contact_email_check;
alter table public.business_parties add constraint business_parties_contact_email_check check(contact_email is null or (contact_email=lower(btrim(contact_email)) and length(contact_email)<=254 and contact_email ~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$')) not valid;

create or replace function public.operational_update_business_party(p_tenant_id uuid, p_party_id uuid, p_legal_name text, p_contact_email text, p_contact_phone text, p_address jsonb, p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path = '' set row_security = off as $function$
declare actor_id uuid; updated_id uuid;
begin
  actor_id := app_private.assert_operational_permission(p_tenant_id, 'transaction.masterdata.party.manage');
  if p_party_id is null or p_request_id is null or p_legal_name is null or length(btrim(p_legal_name)) not between 1 and 200 or (p_address is not null and jsonb_typeof(p_address) <> 'object') then raise exception 'Invalid business party update request' using errcode='22023'; end if;
  update public.business_parties set legal_name=btrim(p_legal_name),contact_email=nullif(lower(btrim(p_contact_email)),''),contact_phone=nullif(btrim(p_contact_phone),''),address=address||coalesce(p_address,'{}'::jsonb),updated_at=clock_timestamp()
    where tenant_id=p_tenant_id and id=p_party_id returning id into updated_id;
  if not found then raise exception 'Business party not found in this company' using errcode='P0002'; end if;
  perform app_private.write_operational_audit('business_party.updated',p_tenant_id,null,updated_id,actor_id,jsonb_build_object('request_id',p_request_id));
  return updated_id;
end;
$function$;


create function public.operational_create_business_party_v2(p_tenant_id uuid,p_party_type text,p_legal_name text,p_document_number text,p_contact_email text,p_contact_phone text,p_address jsonb,p_request_id uuid,p_trade_name text)
returns uuid language plpgsql security definer set search_path='' set row_security=off as $$
declare actor uuid; result uuid; existing public.business_parties%rowtype; doc text:=nullif(regexp_replace(coalesce(p_document_number,''),'[^0-9]','','g'),''); trade text:=nullif(btrim(p_trade_name),'');
begin
 actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.masterdata.party.manage');
 if p_document_number ~ '[^0-9./[:space:]-]' or not app_private.valid_party_document(doc) or length(trade)>200 then raise exception 'Invalid party details' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended('business-party:'||p_tenant_id::text||':'||p_request_id::text,0));
 select * into existing from public.business_parties where tenant_id=p_tenant_id and request_id=p_request_id;
 if found then
  if (existing.party_type,existing.legal_name,existing.document_number,existing.contact_email,existing.contact_phone,existing.address,existing.trade_name,existing.created_by_user_id) is distinct from (p_party_type,btrim(p_legal_name),doc,nullif(lower(btrim(p_contact_email)),''),nullif(btrim(p_contact_phone),''),coalesce(p_address,'{}'::jsonb),trade,actor) then raise exception 'Request payload differs' using errcode='23505'; end if;
  return existing.id;
 end if;
 result:=public.operational_create_business_party(p_tenant_id,p_party_type,p_legal_name,doc,p_contact_email,p_contact_phone,p_address,p_request_id);
 update public.business_parties set trade_name=trade where tenant_id=p_tenant_id and id=result;
 return result;
end;$$;

create function public.operational_update_business_party_v2(p_tenant_id uuid,p_party_id uuid,p_legal_name text,p_document_number text,p_contact_email text,p_contact_phone text,p_address jsonb,p_request_id uuid,p_trade_name text)
returns uuid language plpgsql security definer set search_path='' set row_security=off as $$
declare result uuid; trade text:=nullif(btrim(p_trade_name),''); doc text:=nullif(regexp_replace(coalesce(p_document_number,''),'[^0-9]','','g'),'');
begin
 perform app_private.assert_operational_permission(p_tenant_id,'transaction.masterdata.party.manage');
 if p_document_number ~ '[^0-9./[:space:]-]' or length(trade)>200 then raise exception 'Invalid party details' using errcode='22023'; end if;
 result:=public.operational_update_business_party(p_tenant_id,p_party_id,p_legal_name,p_contact_email,p_contact_phone,p_address,p_request_id);
 update public.business_parties set document_number=doc,trade_name=trade where tenant_id=p_tenant_id and id=result;
 return result;
end;$$;

create function public.operational_list_business_parties_v2(p_tenant_id uuid, p_search text default null, p_party_type text default null, p_status text default null, p_limit integer default 50, p_offset integer default 0)
returns table (party_id uuid, party_type text, legal_name text, document_number text, contact_email text, contact_phone text, status text, created_at timestamptz, trade_name text, address jsonb, person_type text)
language plpgsql stable security definer set search_path = '' set row_security = off as $function$
begin
  perform app_private.assert_operational_permission(p_tenant_id, 'transaction.masterdata.party.read');
  if p_limit not between 1 and 100 or p_offset < 0 or p_party_type not in ('customer','supplier','both') and p_party_type is not null or p_status not in ('active','inactive') and p_status is not null then
    raise exception 'Invalid business party listing request' using errcode = '22023';
  end if;
  return query select p.id, p.party_type, p.legal_name, p.document_number, p.contact_email, p.contact_phone, p.status, p.created_at, p.trade_name, p.address, case length(p.document_number) when 11 then 'PF' when 14 then 'PJ' else null end
    from public.business_parties p where p.tenant_id = p_tenant_id
      and (p_search is null or p.legal_name ilike '%' || pg_catalog.btrim(p_search) || '%' or coalesce(p.document_number,'') like '%' || pg_catalog.btrim(p_search) || '%' or coalesce(p.trade_name,'') ilike '%' || pg_catalog.btrim(p_search) || '%')
      and (p_party_type is null or p.party_type = p_party_type or p.party_type = 'both')
      and (p_status is null or p.status = p_status)
    order by p.legal_name, p.id limit p_limit offset p_offset;
end;
$function$;


alter function public.operational_create_business_party_v2(uuid,text,text,text,text,text,jsonb,uuid,text) owner to postgres;
alter function public.operational_update_business_party_v2(uuid,uuid,text,text,text,text,jsonb,uuid,text) owner to postgres;
alter function public.operational_list_business_parties_v2(uuid,text,text,text,integer,integer) owner to postgres;
revoke all on function public.operational_create_business_party_v2(uuid,text,text,text,text,text,jsonb,uuid,text),public.operational_update_business_party_v2(uuid,uuid,text,text,text,text,jsonb,uuid,text),public.operational_list_business_parties_v2(uuid,text,text,text,integer,integer) from public,anon,authenticated,service_role;
grant execute on function public.operational_create_business_party_v2(uuid,text,text,text,text,text,jsonb,uuid,text),public.operational_update_business_party_v2(uuid,uuid,text,text,text,text,jsonb,uuid,text),public.operational_list_business_parties_v2(uuid,text,text,text,integer,integer) to authenticated;
commit;
