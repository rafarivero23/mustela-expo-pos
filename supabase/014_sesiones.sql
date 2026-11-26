-- =====================================================================
-- Mustela Expo POS — migration 014: Mustela Sessions (RSVP + horario de fotos)
-- Personal invitation links (/sesiones?c=CODE), one family per photo slot,
-- staff admin at /sesiones-admin. Run once in Supabase → SQL Editor. Safe to re-run.
-- =====================================================================

create table if not exists public.ses_event (
  id          int primary key default 1 check (id = 1),
  nombre      text not null default 'Mustela Sessions',
  lugar       text not null default '',
  direccion   text not null default '',
  maps_url    text not null default '',
  mensaje     text not null default '',
  abierto     boolean not null default true          -- false = links stop accepting changes
);

create table if not exists public.ses_slots (
  id         serial primary key,
  starts_at  timestamptz not null unique,
  minutes    int not null default 25 check (minutes between 5 and 240),
  capacity   int not null default 1 check (capacity between 0 and 20)
);

create table if not exists public.ses_invites (
  code          text primary key check (code ~ '^[A-Z0-9]{6,12}$'),
  num           int not null unique,
  nota          text not null default '',             -- internal note (staff only)
  status        text not null default 'pendiente' check (status in ('pendiente','confirmado','no_asiste')),
  nombre        text not null default '',
  telefono      text not null default '',
  adultos       int  not null default 0 check (adultos between 0 and 10),
  ninos         jsonb not null default '[]'::jsonb,   -- ["Embarazo","6–12 meses","3 años", …]
  comentario    text not null default '',
  slot_id       int references public.ses_slots(id) on delete set null,
  responded_at  timestamptz,
  opened_at     timestamptz,
  checked_in_at timestamptz,
  created_at    timestamptz not null default now()
);
create index if not exists ses_invites_slot on public.ses_invites(slot_id);

-- ---------- Seed: event, 12 slots (Dec 4 2026, 9:00–14:00 CDMX, 25 min), 20 invites
insert into public.ses_event (id, nombre, lugar, direccion, maps_url)
values (1, 'Mustela Sessions', 'Foro Nápoles',
        'Eugenia 43, int. 5, Col. Nápoles, Benito Juárez, 03840, CDMX',
        'https://www.google.com/maps/search/?api=1&query=Eugenia+43+Napoles+Benito+Juarez+03840+CDMX')
on conflict (id) do nothing;

insert into public.ses_slots (starts_at, minutes, capacity)
select g, 25, 1
from generate_series('2026-12-04 09:00:00-06'::timestamptz,
                     '2026-12-04 13:35:00-06'::timestamptz, interval '25 minutes') g
on conflict (starts_at) do nothing;

create or replace function public._ses_code() returns text
language plpgsql volatile set search_path = public as $$
declare a text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; c text; i int;
begin
  loop
    c := '';
    for i in 1..6 loop c := c || substr(a, 1 + floor(random() * length(a))::int, 1); end loop;
    exit when not exists (select 1 from public.ses_invites where code = c);
  end loop;
  return c;
end $$;

insert into public.ses_invites (code, num)
select public._ses_code(), n from generate_series(1, 20) n
where not exists (select 1 from public.ses_invites);

-- ---------- RLS: nothing readable by anon; staff read; writes via RPCs only
alter table public.ses_event   enable row level security;
alter table public.ses_slots   enable row level security;
alter table public.ses_invites enable row level security;
drop policy if exists ses_event_staff on public.ses_event;
create policy ses_event_staff on public.ses_event for select to authenticated using (public.is_staff());
drop policy if exists ses_event_staff_upd on public.ses_event;
create policy ses_event_staff_upd on public.ses_event for update to authenticated using (public.is_staff()) with check (public.is_staff());
drop policy if exists ses_slots_staff on public.ses_slots;
create policy ses_slots_staff on public.ses_slots for select to authenticated using (public.is_staff());
drop policy if exists ses_invites_staff on public.ses_invites;
create policy ses_invites_staff on public.ses_invites for select to authenticated using (public.is_staff());
revoke all on public.ses_event, public.ses_slots, public.ses_invites from anon;
grant select, update on public.ses_event to authenticated;
grant select on public.ses_slots, public.ses_invites to authenticated;

-- ---------- Public: read my invitation + slot availability (no other guest data)
create or replace function public.ses_get(p_code text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v public.ses_invites;
begin
  select * into v from public.ses_invites where code = upper(trim(coalesce(p_code,'')));
  if not found then raise exception 'invitacion_no_existe'; end if;
  update public.ses_invites set opened_at = coalesce(opened_at, now()) where code = v.code;
  return jsonb_build_object(
    'event', (select to_jsonb(e) - 'id' from public.ses_event e where id = 1),
    'privacy_url', coalesce((select privacy_url from public.settings where id = 1), ''),
    'invite', jsonb_build_object('code', v.code, 'num', v.num, 'status', v.status, 'nombre', v.nombre,
                                 'telefono', v.telefono, 'adultos', v.adultos, 'ninos', v.ninos,
                                 'comentario', v.comentario, 'slot_id', v.slot_id, 'checked_in', v.checked_in_at is not null),
    'slots', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'starts_at', s.starts_at, 'minutes', s.minutes,
               'free', s.capacity - (select count(*) from public.ses_invites i
                                     where i.slot_id = s.id and i.status = 'confirmado' and i.code <> v.code))
             order by s.starts_at)
      from public.ses_slots s where s.capacity > 0), '[]'::jsonb)
  );
end $$;

-- ---------- Public: answer / change answer
create or replace function public.ses_respond(p_code text, p_attend boolean, p_nombre text default '',
  p_telefono text default '', p_adultos int default 0, p_ninos jsonb default '[]'::jsonb,
  p_slot int default null, p_comentario text default '') returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v public.ses_invites; s public.ses_slots; taken int; tel text;
begin
  if not coalesce((select abierto from public.ses_event where id = 1), true) then raise exception 'registro_cerrado'; end if;
  select * into v from public.ses_invites where code = upper(trim(coalesce(p_code,''))) for update;
  if not found then raise exception 'invitacion_no_existe'; end if;
  if v.checked_in_at is not null then raise exception 'ya_registrado'; end if;

  if not p_attend then
    update public.ses_invites set status = 'no_asiste', slot_id = null, responded_at = now(),
           comentario = left(coalesce(p_comentario,''), 300) where code = v.code;
    return jsonb_build_object('status', 'no_asiste');
  end if;

  if length(trim(coalesce(p_nombre,''))) < 2 then raise exception 'nombre_requerido'; end if;
  tel := regexp_replace(coalesce(p_telefono,''), '\D', '', 'g');
  if length(tel) = 12 and tel like '52%' then tel := substr(tel, 3); end if;
  if length(tel) <> 10 then raise exception 'telefono_invalido'; end if;
  if coalesce(p_adultos,0) < 1 or p_adultos > 6 then raise exception 'adultos_invalido'; end if;
  if jsonb_typeof(p_ninos) is distinct from 'array' or jsonb_array_length(p_ninos) > 8 then raise exception 'ninos_invalido'; end if;
  if exists (select 1 from jsonb_array_elements(p_ninos) x
             where jsonb_typeof(x) <> 'string' or length(x #>> '{}') not between 1 and 40) then raise exception 'ninos_edad'; end if;

  if p_slot is not null then
    select * into s from public.ses_slots where id = p_slot for update;
    if not found or s.capacity < 1 then raise exception 'horario_no_existe'; end if;
    select count(*) into taken from public.ses_invites
     where slot_id = s.id and status = 'confirmado' and code <> v.code;
    if taken >= s.capacity then raise exception 'horario_ocupado'; end if;
  end if;

  update public.ses_invites set status = 'confirmado', nombre = left(trim(p_nombre), 80), telefono = tel,
         adultos = p_adultos, ninos = p_ninos, slot_id = p_slot, responded_at = now(),
         comentario = left(coalesce(p_comentario,''), 300)
   where code = v.code;
  return jsonb_build_object('status', 'confirmado', 'slot_id', p_slot);
end $$;

-- ---------- Staff
create or replace function public.ses_admin_set(p_code text, p_slot int default null, p_status text default null,
  p_nota text default null, p_checkin boolean default null, p_clear_slot boolean default false) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare v public.ses_invites; s public.ses_slots; taken int;
begin
  if not public.is_staff() then raise exception 'no_autorizado'; end if;
  select * into v from public.ses_invites where code = p_code for update;
  if not found then raise exception 'invitacion_no_existe'; end if;
  if p_slot is not null then
    select * into s from public.ses_slots where id = p_slot for update;
    if not found then raise exception 'horario_no_existe'; end if;
    select count(*) into taken from public.ses_invites where slot_id = s.id and status = 'confirmado' and code <> v.code;
    if taken >= s.capacity then raise exception 'horario_ocupado'; end if;
    update public.ses_invites set slot_id = p_slot, status = 'confirmado' where code = v.code;
  end if;
  if p_clear_slot then update public.ses_invites set slot_id = null where code = v.code; end if;
  if p_status is not null then
    if p_status not in ('pendiente','confirmado','no_asiste') then raise exception 'cambio_invalido'; end if;
    update public.ses_invites set status = p_status,
           slot_id = case when p_status = 'confirmado' then slot_id else null end where code = v.code;
  end if;
  if p_nota is not null then update public.ses_invites set nota = left(p_nota, 120) where code = v.code; end if;
  if p_checkin is not null then
    update public.ses_invites set checked_in_at = case when p_checkin then now() else null end where code = v.code;
  end if;
  return true;
end $$;

create or replace function public.ses_add_invites(p_n int) returns int
language plpgsql volatile security definer set search_path = public as $$
declare m int;
begin
  if not public.is_staff() then raise exception 'no_autorizado'; end if;
  if p_n not between 1 and 50 then raise exception 'cantidad_invalida'; end if;
  select coalesce(max(num), 0) into m from public.ses_invites;
  insert into public.ses_invites (code, num) select public._ses_code(), m + g from generate_series(1, p_n) g;
  return p_n;
end $$;

create or replace function public.ses_set_slot_capacity(p_slot int, p_capacity int) returns boolean
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'no_autorizado'; end if;
  if p_capacity not between 0 and 20 then raise exception 'cantidad_invalida'; end if;
  update public.ses_slots set capacity = p_capacity where id = p_slot;
  return true;
end $$;

revoke execute on function public._ses_code() from public, anon, authenticated;
revoke execute on function public.ses_admin_set(text,int,text,text,boolean,boolean) from public, anon;
revoke execute on function public.ses_add_invites(int) from public, anon;
revoke execute on function public.ses_set_slot_capacity(int,int) from public, anon;
grant execute on function public.ses_get(text) to anon, authenticated;
grant execute on function public.ses_respond(text,boolean,text,text,int,jsonb,int,text) to anon, authenticated;
grant execute on function public.ses_admin_set(text,int,text,text,boolean,boolean) to authenticated;
grant execute on function public.ses_add_invites(int) to authenticated;
grant execute on function public.ses_set_slot_capacity(int,int) to authenticated;

do $$
declare t text;
begin
  foreach t in array array['ses_invites','ses_slots'] loop
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
