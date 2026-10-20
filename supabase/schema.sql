-- =====================================================================
-- Mustela Expo POS — Supabase schema (v2)
-- Run once in Supabase → SQL Editor (safe to re-run on an empty project).
-- =====================================================================

-- ---------- Tables ----------------------------------------------------

create table if not exists public.staff (
  email      text primary key check (email = lower(email)),
  nombre     text,
  created_at timestamptz not null default now()
);

create table if not exists public.settings (
  id            int primary key default 1 check (id = 1),
  evento        text not null default 'Expo',
  kiosk_pin     text not null default '2026' check (kiosk_pin ~ '^[0-9]{4,8}$'),
  privacy_url   text not null default '',
  hold_minutes  int  not null default 30 check (hold_minutes between 5 and 1440)
);

create table if not exists public.products (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) > 0),
  category    text not null default '',
  size        text not null default '',
  price       numeric(10,2) not null check (price >= 0),
  stock       int  not null default 0 check (stock >= 0),
  active      boolean not null default true,
  sort_order  int  not null default 999,
  sample      boolean not null default false,
  created_at  timestamptz not null default now()
);

create table if not exists public.orders (
  number        text primary key,
  items         jsonb not null,           -- [{pid,name,size,price,qty}] — prices frozen at order time
  total         numeric(10,2) not null,
  customer      jsonb not null,           -- {nombre,apellido,telefono,email}
  community     boolean not null default false,
  status        text not null default 'pendiente'
                check (status in ('pendiente','pagado','listo','entregado','cancelado')),
  created_at    timestamptz not null default now(),
  paid_at       timestamptz,
  pay_method    text check (pay_method in ('Tarjeta','Efectivo','Transferencia')),
  pay_ref       text,
  ready_at      timestamptz,
  delivered_at  timestamptz,
  cancelled_at  timestamptz
);
create index if not exists orders_status_idx on public.orders (status);

create table if not exists public.members (
  id          uuid primary key default gen_random_uuid(),
  nombre      text not null,
  apellido    text not null default '',
  telefono    text not null,
  email       text not null default '',
  etapa       text not null default '',
  ciudad      text not null default '',
  whatsapp    boolean not null default false,
  correo      boolean not null default false,
  privacidad  boolean not null default true,
  origen      text not null check (origen in ('Tienda','Registro')),
  pedido      text not null default '',
  created_at  timestamptz not null default now()
);

insert into public.settings (id) values (1) on conflict do nothing;

-- ---------- Helpers ---------------------------------------------------

-- Staff = signed-in Supabase Auth user whose email is in public.staff.
create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.staff
    where email = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

-- Internal: availability per product. Not callable by clients directly.
--   sold      = qty in pagado / listo / entregado
--   held      = qty in pendiente orders younger than settings.hold_minutes
--   available = stock - sold - held   (limit at the tablet)
--   free      = stock - sold          (checked at payment)
create or replace function public._availability()
returns table (id uuid, stock int, sold int, held int, available int, free int)
language sql stable security definer set search_path = public as $$
  with cfg as (select hold_minutes from public.settings where id = 1),
  lines as (
    select (i ->> 'pid')::uuid as pid, (i ->> 'qty')::int as qty, o.status, o.created_at
    from public.orders o, jsonb_array_elements(o.items) i
    where o.status <> 'cancelado'
  )
  select p.id, p.stock,
    coalesce(sum(l.qty) filter (where l.status in ('pagado','listo','entregado')), 0)::int,
    coalesce(sum(l.qty) filter (where l.status = 'pendiente'
              and l.created_at > now() - make_interval(mins => (select hold_minutes from cfg))), 0)::int,
    (p.stock
      - coalesce(sum(l.qty) filter (where l.status in ('pagado','listo','entregado')), 0)
      - coalesce(sum(l.qty) filter (where l.status = 'pendiente'
              and l.created_at > now() - make_interval(mins => (select hold_minutes from cfg))), 0))::int,
    (p.stock - coalesce(sum(l.qty) filter (where l.status in ('pagado','listo','entregado')), 0))::int
  from public.products p
  left join lines l on l.pid = p.id
  group by p.id, p.stock;
$$;

create or replace function public._valid_email(e text) returns boolean
language sql immutable as $$ select e ~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' $$;

-- ---------- Public (anon) RPCs ---------------------------------------

-- Catalog for the tablets: active products + availability + public settings.
create or replace function public.get_kiosk() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'evento',      (select evento from public.settings where id = 1),
    'privacy_url', (select privacy_url from public.settings where id = 1),
    'products', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'name', p.name, 'category', p.category, 'size', p.size,
               'price', p.price, 'available', greatest(a.available, 0))
             order by p.sort_order, p.name)
      from public.products p join public._availability() a on a.id = p.id
      where p.active), '[]'::jsonb)
  );
$$;

create or replace function public.check_kiosk_pin(p_pin text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.settings where id = 1 and kiosk_pin = coalesce(p_pin, ''));
$$;

-- Creates an order atomically: validates customer, locks products, checks
-- availability, takes prices from the DB, generates a unique number.
-- p_items:    [{pid, qty}]
-- p_customer: {nombre, apellido, telefono, email, privacidad}
-- p_member:   {etapa, ciudad, whatsapp, correo}   (used when p_community)
create or replace function public.create_order(
  p_items jsonb, p_customer jsonb, p_community boolean default false, p_member jsonb default '{}'::jsonb
) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_nombre   text := left(trim(coalesce(p_customer ->> 'nombre', '')), 80);
  v_apellido text := left(trim(coalesce(p_customer ->> 'apellido', '')), 80);
  v_tel      text := regexp_replace(coalesce(p_customer ->> 'telefono', ''), '\D', '', 'g');
  v_email    text := left(lower(trim(coalesce(p_customer ->> 'email', ''))), 120);
  v_chars    text := 'ACDEFHJKLMNPRTUVWXY3479';
  v_items    jsonb := '[]'::jsonb;
  v_total    numeric := 0;
  v_number   text;
  v_try      int := 0;
  r          record;
begin
  if v_nombre = '' then raise exception 'nombre_requerido'; end if;
  if length(v_tel) <> 10 then raise exception 'telefono_invalido'; end if;
  if v_email <> '' and not public._valid_email(v_email) then raise exception 'correo_invalido'; end if;
  if coalesce(p_community, false) and v_email = '' then raise exception 'correo_requerido'; end if;
  if coalesce((p_customer ->> 'privacidad')::boolean, false) is not true then raise exception 'privacidad_requerida'; end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then raise exception 'pedido_vacio'; end if;
  if jsonb_array_length(p_items) > 40 then raise exception 'cantidad_invalida'; end if;

  -- Serialize against other orders/payments touching the same products.
  perform 1 from public.products
   where id in (select (e ->> 'pid')::uuid from jsonb_array_elements(p_items) e)
   order by id for update;

  for r in
    with req as (
      select (e ->> 'pid')::uuid as pid, sum((e ->> 'qty')::int)::int as qty, min(ord) as ord
      from jsonb_array_elements(p_items) with ordinality as t(e, ord)
      group by 1
    )
    select req.pid, req.qty, p.name, p.size, p.price, p.active, a.available
    from req
    left join public.products p on p.id = req.pid
    left join public._availability() a on a.id = req.pid
    order by req.ord
  loop
    if r.name is null or not r.active then raise exception 'producto_no_disponible'; end if;
    if r.qty < 1 or r.qty > 20 then raise exception 'cantidad_invalida'; end if;
    if r.qty > r.available then raise exception 'sin_stock:%', r.name; end if;
    v_items := v_items || jsonb_build_object('pid', r.pid, 'name', r.name, 'size', r.size, 'price', r.price, 'qty', r.qty);
    v_total := v_total + r.price * r.qty;
  end loop;

  loop
    v_number := 'M' || (select string_agg(substr(v_chars, 1 + floor(random() * length(v_chars))::int, 1), '')
                        from generate_series(1, 3));
    begin
      insert into public.orders (number, items, total, customer, community)
      values (v_number, v_items, v_total,
              jsonb_build_object('nombre', v_nombre, 'apellido', v_apellido, 'telefono', v_tel, 'email', v_email),
              coalesce(p_community, false));
      exit;
    exception when unique_violation then
      v_try := v_try + 1;
      if v_try > 60 then raise exception 'sin_numeros'; end if;
    end;
  end loop;

  if coalesce(p_community, false) then
    insert into public.members (nombre, apellido, telefono, email, etapa, ciudad, whatsapp, correo, privacidad, origen, pedido)
    values (v_nombre, v_apellido, v_tel, v_email,
            left(coalesce(p_member ->> 'etapa', ''), 60), left(trim(coalesce(p_member ->> 'ciudad', '')), 80),
            coalesce((p_member ->> 'whatsapp')::boolean, false), coalesce((p_member ->> 'correo')::boolean, false),
            true, 'Tienda', v_number);
  end if;

  return jsonb_build_object('number', v_number, 'total', v_total);
end;
$$;

-- Comunidad sign-up without purchase.
create or replace function public.join_community(p jsonb) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare
  v_nombre text := left(trim(coalesce(p ->> 'nombre', '')), 80);
  v_tel    text := regexp_replace(coalesce(p ->> 'telefono', ''), '\D', '', 'g');
  v_email  text := left(lower(trim(coalesce(p ->> 'email', ''))), 120);
begin
  if v_nombre = '' then raise exception 'nombre_requerido'; end if;
  if length(v_tel) <> 10 then raise exception 'telefono_invalido'; end if;
  if not public._valid_email(v_email) then raise exception 'correo_invalido'; end if;
  if coalesce((p ->> 'privacidad')::boolean, false) is not true then raise exception 'privacidad_requerida'; end if;
  insert into public.members (nombre, apellido, telefono, email, etapa, ciudad, whatsapp, correo, privacidad, origen)
  values (v_nombre, left(trim(coalesce(p ->> 'apellido', '')), 80), v_tel, v_email,
          left(coalesce(p ->> 'etapa', ''), 60), left(trim(coalesce(p ->> 'ciudad', '')), 80),
          coalesce((p ->> 'whatsapp')::boolean, false), coalesce((p ->> 'correo')::boolean, false),
          true, 'Registro');
  return true;
end;
$$;

-- ---------- Staff RPCs -------------------------------------------------

create or replace function public.product_availability()
returns table (id uuid, stock int, sold int, held int, available int, free int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'no_autorizado'; end if;
  return query select * from public._availability();
end;
$$;

create or replace function public.mark_paid(p_number text, p_method text, p_ref text default '')
returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare
  o public.orders;
  r record;
begin
  if not public.is_staff() then raise exception 'no_autorizado'; end if;
  if p_method not in ('Tarjeta','Efectivo','Transferencia') then raise exception 'metodo_invalido'; end if;
  select * into o from public.orders where number = p_number for update;
  if not found then raise exception 'pedido_no_existe'; end if;
  if o.status <> 'pendiente' then raise exception 'pedido_ya_procesado'; end if;

  perform 1 from public.products
   where id in (select (e ->> 'pid')::uuid from jsonb_array_elements(o.items) e)
   order by id for update;

  for r in
    select (e ->> 'name') as name, (e ->> 'qty')::int as qty, a.free
    from jsonb_array_elements(o.items) e
    left join public._availability() a on a.id = (e ->> 'pid')::uuid
  loop
    if r.free is null or r.qty > r.free then raise exception 'sin_stock:%', r.name; end if;
  end loop;

  update public.orders
     set status = 'pagado', paid_at = now(), pay_method = p_method, pay_ref = left(coalesce(p_ref, ''), 120)
   where number = p_number;
  return true;
end;
$$;

-- Cashier edits quantities before payment. p_items: [{pid, qty}].
-- Names/prices stay as frozen in the order; qty 0 removes the line.
create or replace function public.update_order_items(p_number text, p_items jsonb)
returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare
  o public.orders;
  v_items jsonb;
begin
  if not public.is_staff() then raise exception 'no_autorizado'; end if;
  select * into o from public.orders where number = p_number for update;
  if not found then raise exception 'pedido_no_existe'; end if;
  if o.status <> 'pendiente' then raise exception 'pedido_ya_procesado'; end if;

  select coalesce(jsonb_agg(jsonb_set(oi.e, '{qty}', to_jsonb(nq.qty)) order by oi.ord), '[]'::jsonb)
    into v_items
  from jsonb_array_elements(o.items) with ordinality as oi(e, ord)
  join (select (x ->> 'pid') as pid, (x ->> 'qty')::int as qty from jsonb_array_elements(p_items) x) nq
    on nq.pid = oi.e ->> 'pid'
  where nq.qty between 1 and 20;

  if jsonb_array_length(v_items) = 0 then raise exception 'pedido_vacio'; end if;

  update public.orders
     set items = v_items,
         total = (select sum((e ->> 'price')::numeric * (e ->> 'qty')::int) from jsonb_array_elements(v_items) e)
   where number = p_number;
  return true;
end;
$$;

-- Status changes after payment, with server timestamps.
--   pendiente → cancelado | pagado → listo | listo → entregado | listo → pagado
create or replace function public.set_order_status(p_number text, p_status text)
returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare
  v_from text;
begin
  if not public.is_staff() then raise exception 'no_autorizado'; end if;
  select status into v_from from public.orders where number = p_number for update;
  if not found then raise exception 'pedido_no_existe'; end if;
  if (v_from, p_status) not in (('pendiente','cancelado'), ('pagado','listo'), ('listo','entregado'), ('listo','pagado')) then
    raise exception 'cambio_invalido';
  end if;
  update public.orders set
    status       = p_status,
    cancelled_at = case when p_status = 'cancelado' then now() else cancelled_at end,
    ready_at     = case when p_status = 'listo'     then now() else ready_at end,
    delivered_at = case when p_status = 'entregado' then now() else delivered_at end
  where number = p_number;
  return true;
end;
$$;

-- ---------- Row Level Security ---------------------------------------

alter table public.staff    enable row level security;
alter table public.settings enable row level security;
alter table public.products enable row level security;
alter table public.orders   enable row level security;
alter table public.members  enable row level security;

-- anon gets NO table policies: tablets use get_kiosk / create_order / join_community only.
drop policy if exists staff_read on public.staff;
create policy staff_read on public.staff for select to authenticated using (public.is_staff());

drop policy if exists settings_staff_read on public.settings;
create policy settings_staff_read on public.settings for select to authenticated using (public.is_staff());
drop policy if exists settings_staff_update on public.settings;
create policy settings_staff_update on public.settings for update to authenticated using (public.is_staff()) with check (public.is_staff());

drop policy if exists products_staff_all on public.products;
create policy products_staff_all on public.products for all to authenticated using (public.is_staff()) with check (public.is_staff());

-- Orders: staff read; every change goes through the RPCs above.
drop policy if exists orders_staff_read on public.orders;
create policy orders_staff_read on public.orders for select to authenticated using (public.is_staff());

drop policy if exists members_staff_read on public.members;
create policy members_staff_read on public.members for select to authenticated using (public.is_staff());

-- ---------- Function privileges --------------------------------------

revoke execute on function public._availability()  from public, anon, authenticated;
revoke execute on function public._valid_email(text) from public, anon, authenticated;
revoke execute on function public.is_staff()       from public, anon;
grant  execute on function public.is_staff()       to authenticated;

revoke execute on function public.get_kiosk()                              from public;
revoke execute on function public.check_kiosk_pin(text)                    from public;
revoke execute on function public.create_order(jsonb, jsonb, boolean, jsonb) from public;
revoke execute on function public.join_community(jsonb)                    from public;
grant  execute on function public.get_kiosk()                              to anon, authenticated;
grant  execute on function public.check_kiosk_pin(text)                    to anon, authenticated;
grant  execute on function public.create_order(jsonb, jsonb, boolean, jsonb) to anon, authenticated;
grant  execute on function public.join_community(jsonb)                    to anon, authenticated;

revoke execute on function public.product_availability()             from public, anon;
revoke execute on function public.mark_paid(text, text, text)        from public, anon;
revoke execute on function public.update_order_items(text, jsonb)    from public, anon;
revoke execute on function public.set_order_status(text, text)       from public, anon;
grant  execute on function public.product_availability()             to authenticated;
grant  execute on function public.mark_paid(text, text, text)        to authenticated;
grant  execute on function public.update_order_items(text, jsonb)    to authenticated;
grant  execute on function public.set_order_status(text, text)       to authenticated;

-- ---------- Realtime (staff screens) ---------------------------------

do $$
declare t text;
begin
  foreach t in array array['orders','products','members','settings'] loop
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
