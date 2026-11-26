-- Mustela Sessions — 015: staff can reset an invitation back to "pendiente" (clears all answers). Safe to re-run.
create or replace function public.ses_admin_reset(p_code text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'no_autorizado'; end if;
  update public.ses_invites set status = 'pendiente', nombre = '', telefono = '', adultos = 0, ninos = '[]'::jsonb,
         comentario = '', slot_id = null, responded_at = null, opened_at = null, checked_in_at = null
   where code = p_code;
  if not found then raise exception 'invitacion_no_existe'; end if;
  return true;
end $$;
revoke execute on function public.ses_admin_reset(text) from public, anon;
grant execute on function public.ses_admin_reset(text) to authenticated;
notify pgrst, 'reload schema';
