-- =====================================================================
-- Mustela Expo POS — migration 007: archive + restore for "Borrar ventas"
-- Run once in Supabase → SQL Editor. Safe to re-run.
-- =====================================================================
-- Every reset first archives what it deletes (reset_log + *_archive as jsonb),
-- so an admin can restore it from Corte → "Restaurar".
create table if not exists public.reset_log (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  created_by  text not null default '',
  orders      int not null default 0,
  returns     int not null default 0,
  members     int not null default 0,
  restored_at timestamptz,
  restored_by text
);
create table if not exists public.orders_archive  (reset_id uuid not null references public.reset_log(id), data jsonb not null);
create table if not exists public.returns_archive (reset_id uuid not null references public.reset_log(id), data jsonb not null);
create table if not exists public.members_archive (reset_id uuid not null references public.reset_log(id), data jsonb not null);
alter table public.reset_log       enable row level security;
alter table public.orders_archive  enable row level security;
alter table public.returns_archive enable row level security;
alter table public.members_archive enable row level security;
drop policy if exists reset_log_staff_read on public.reset_log;
create policy reset_log_staff_read on public.reset_log for select to authenticated using (public.is_staff());
grant select on public.reset_log to authenticated;

-- Deletes all orders + returns (and optionally Comunidad sign-ups) after archiving them.
-- Products, stock, photos, settings and staff are kept. Requires p_confirm = 'BORRAR'.
create or replace function public.reset_event_data(p_confirm text, p_members boolean default false)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_id uuid; v_o int; v_r int; v_m int := 0;
begin
  if not public.is_admin() then raise exception 'solo_admin'; end if;
  if p_confirm is distinct from 'BORRAR' then raise exception 'confirmacion_invalida'; end if;
  insert into public.reset_log (created_by) values (lower(coalesce(auth.jwt() ->> 'email', ''))) returning id into v_id;
  insert into public.orders_archive  select v_id, to_jsonb(o) from public.orders o;
  insert into public.returns_archive select v_id, to_jsonb(r) from public.returns r;
  if coalesce(p_members, false) then
    insert into public.members_archive select v_id, to_jsonb(m) from public.members m;
  end if;
  delete from public.returns where true; get diagnostics v_r = row_count;
  delete from public.orders where true;  get diagnostics v_o = row_count;
  if coalesce(p_members, false) then delete from public.members where true; get diagnostics v_m = row_count; end if;
  update public.reset_log set orders = v_o, returns = v_r, members = v_m where id = v_id;
  return jsonb_build_object('id', v_id, 'orders', v_o, 'returns', v_r, 'members', v_m);
end;
$$;

-- Restores an archived reset (default: the most recent one not yet restored).
-- Rows that already exist again (same order number / id) are skipped.
create or replace function public.restore_reset(p_id uuid default null)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_id uuid; v_o int; v_r int; v_m int;
begin
  if not public.is_admin() then raise exception 'solo_admin'; end if;
  select id into v_id from public.reset_log
   where restored_at is null and (p_id is null or id = p_id)
   order by created_at desc limit 1 for update;
  if v_id is null then raise exception 'nada_que_restaurar'; end if;
  insert into public.orders  select (jsonb_populate_record(null::public.orders, data)).* from public.orders_archive where reset_id = v_id
    on conflict (number) do nothing;
  get diagnostics v_o = row_count;
  insert into public.returns select (jsonb_populate_record(null::public.returns, a.data)).* from public.returns_archive a
    where a.reset_id = v_id and exists (select 1 from public.orders o where o.number = a.data ->> 'order_number')
    on conflict (id) do nothing;
  get diagnostics v_r = row_count;
  insert into public.members select (jsonb_populate_record(null::public.members, data)).* from public.members_archive where reset_id = v_id
    on conflict (id) do nothing;
  get diagnostics v_m = row_count;
  update public.reset_log set restored_at = now(), restored_by = lower(coalesce(auth.jwt() ->> 'email', '')) where id = v_id;
  return jsonb_build_object('orders', v_o, 'returns', v_r, 'members', v_m);
end;
$$;
revoke execute on function public.restore_reset(uuid) from public, anon;
grant  execute on function public.restore_reset(uuid) to authenticated;
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'reset_log') then
    alter publication supabase_realtime add table public.reset_log;
  end if;
end $$;
revoke execute on function public.reset_event_data(text, boolean) from public, anon;
grant  execute on function public.reset_event_data(text, boolean) to authenticated;
