do $assert$
begin
  if (select count(*) from app_private.master_admins) <> 1
     or (select count(*) from app_private.master_admin_audit_events where event_key = 'master.granted') <> 1 then
    raise exception 'Concurrent calls produced more than one grant or audit event';
  end if;
end;
$assert$;
