-- Mustela Sessions — 016: staff can regenerate the photo slots (day, start, end, minutes, families per slot).
-- Bookings whose time still exists keep their slot; the rest go to the waitlist. Safe to re-run.
create or replace function public.ses_regen_slots(p_start timestamptz, p_end timestamptz, p_minutes int, p_capacity int)
returns int
language plpgsql volatile security definer set search_path = public as $$
declare n int;
begin
  if not public.is_staff() then raise exception 'no_autorizado'; end if;
  if p_minutes not between 5 and 240 or p_capacity not between 1 and 20 then raise exception 'cantidad_invalida'; end if;
  if p_end <= p_start or p_end - p_start > interval '16 hours' then raise exception 'horario_invalido'; end if;
  create temp table _new on commit drop as
    select g as starts_at from generate_series(p_start, p_end - make_interval(mins => p_minutes), make_interval(mins => p_minutes)) g;
  select count(*) into n from _new;
  if n = 0 then raise exception 'horario_invalido'; end if;
  delete from public.ses_slots where starts_at not in (select starts_at from _new);   -- their families → waitlist (FK set null)
  update public.ses_slots set minutes = p_minutes, capacity = p_capacity;
  insert into public.ses_slots (starts_at, minutes, capacity)
    select starts_at, p_minutes, p_capacity from _new on conflict (starts_at) do nothing;
  return n;
end $$;
revoke execute on function public.ses_regen_slots(timestamptz, timestamptz, int, int) from public, anon;
grant execute on function public.ses_regen_slots(timestamptz, timestamptz, int, int) to authenticated;
notify pgrst, 'reload schema';
