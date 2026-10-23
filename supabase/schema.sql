-- =====================================================================
-- Mustela Expo POS — Supabase schema (v2)
-- Run once in Supabase → SQL Editor (safe to re-run on an empty project).
-- =====================================================================

-- ---------- Tables ----------------------------------------------------

create table if not exists public.staff (
  email      text primary key check (email = lower(email)),
  nombre     text,
  admin      boolean not null default false,
  perms      text[] not null default '{caja,surtido,inventario,corte}',
  created_at timestamptz not null default now()
);

create table if not exists public.settings (
  id            int primary key default 1 check (id = 1),
  evento        text not null default 'Expo',
  kiosk_pin     text not null default '2026' check (kiosk_pin ~ '^[0-9]{4,8}$'),
  privacy_url   text not null default '',
  hold_minutes  int  not null default 30 check (hold_minutes between 5 and 1440),
  consejeras    text[] not null default '{}'
);

create table if not exists public.products (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) > 0),
  category    text not null default '',
  size        text not null default '',
  price       numeric(10,2) not null check (price >= 0),
  stock       int  not null default 0 check (stock >= 0),   -- inventario inicial
  restock     int  not null default 0 check (restock >= 0), -- resurtido durante el evento
  codigo      text not null default '',
  sku         text not null default '',
  active      boolean not null default true,
  sort_order  int  not null default 999,
  sample      boolean not null default false,
  image_url   text not null default '',
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
  cancelled_at  timestamptz,
  consejera     text not null default '',
  factura       boolean not null default false,
  sms_count     int not null default 0,
  sms_status    text not null default '',
  sms_at        timestamptz,
  paid_by       text not null default ''
);
create index if not exists orders_status_idx on public.orders (status);

-- Returns (devoluciones) of paid orders. Returned units go back to inventory:
-- _availability() subtracts them from "sold".
create table if not exists public.returns (
  id            uuid primary key default gen_random_uuid(),
  order_number  text not null references public.orders(number),
  items         jsonb not null,           -- [{pid,name,size,price,qty}] at the order's frozen price
  amount        numeric(10,2) not null,
  method        text not null check (method in ('Tarjeta','Efectivo','Transferencia')),
  reason        text not null default '',
  created_by    text not null default '',
  created_at    timestamptz not null default now()
);
create index if not exists returns_order_idx on public.returns (order_number);

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

-- Screen-level permissions: admin = everything; otherwise perms lists caja/surtido/inventario/corte.
create or replace function public.has_perm(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.staff
    where email = lower(coalesce(auth.jwt() ->> 'email', ''))
      and (admin or p = any(perms))
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
  ),
  agg as (
    select l.pid,
      coalesce(sum(l.qty) filter (where l.status in ('pagado','listo','entregado')), 0) as sold_raw,
      coalesce(sum(l.qty) filter (where l.status = 'pendiente'
               and l.created_at > now() - make_interval(mins => (select hold_minutes from cfg))), 0) as held
    from lines l group by l.pid
  ),
  ret as (
    select (i ->> 'pid')::uuid as pid, sum((i ->> 'qty')::int) as qty
    from public.returns r, jsonb_array_elements(r.items) i group by 1
  )
  select p.id, (p.stock + p.restock)::int,
    (coalesce(a.sold_raw, 0) - coalesce(r.qty, 0))::int,
    coalesce(a.held, 0)::int,
    (p.stock + p.restock - (coalesce(a.sold_raw, 0) - coalesce(r.qty, 0)) - coalesce(a.held, 0))::int,
    (p.stock + p.restock - (coalesce(a.sold_raw, 0) - coalesce(r.qty, 0)))::int
  from public.products p
  left join agg a on a.pid = p.id
  left join ret r on r.pid = p.id;
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
    'consejeras',  (select to_jsonb(consejeras) from public.settings where id = 1),
    'products', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'name', p.name, 'category', p.category, 'size', p.size,
               'price', p.price, 'image_url', p.image_url, 'available', greatest(a.available, 0))
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
  v_conse    text := trim(coalesce(p_customer ->> 'consejera', ''));
  v_factura  boolean := coalesce((p_customer ->> 'factura')::boolean, false);
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
  if v_conse <> '' and not exists (select 1 from public.settings where id = 1 and v_conse = any(consejeras)) then v_conse := ''; end if;
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
      insert into public.orders (number, items, total, customer, community, consejera, factura)
      values (v_number, v_items, v_total,
              jsonb_build_object('nombre', v_nombre, 'apellido', v_apellido, 'telefono', v_tel, 'email', v_email),
              coalesce(p_community, false), v_conse, v_factura);
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
  if not (public.has_perm('caja')) then raise exception 'sin_permiso'; end if;
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
     set status = 'pagado', paid_at = now(), pay_method = p_method, pay_ref = left(coalesce(p_ref, ''), 120),
         paid_by = lower(coalesce(auth.jwt() ->> 'email', ''))
   where number = p_number;
  return true;
end;
$$;

-- Cashier edits quantities before payment. p_items: [{pid, qty}].
-- Names/prices stay as frozen in the order; qty 0 removes the line.
create or replace function public.update_order_items(p_number text, p_items jsonb)
returns boolean
language plpgsql volatile security definer set search_path = public as $$
-- Cashier edits a pending order: change quantities, remove lines (qty 0) or ADD products.
-- p_items: full desired list [{pid, qty}]. Existing lines keep their frozen name/price;
-- new lines take the current catalog price. Stock checked against free = stock - sold.
declare
  o public.orders;
  v_items jsonb := '[]'::jsonb;
  r record;
begin
  if not public.is_staff() then raise exception 'no_autorizado'; end if;
  if not (public.has_perm('caja')) then raise exception 'sin_permiso'; end if;
  select * into o from public.orders where number = p_number for update;
  if not found then raise exception 'pedido_no_existe'; end if;
  if o.status <> 'pendiente' then raise exception 'pedido_ya_procesado'; end if;
  if jsonb_typeof(p_items) is distinct from 'array' then raise exception 'pedido_vacio'; end if;

  perform 1 from public.products
   where id::text in (select x ->> 'pid' from jsonb_array_elements(p_items) x)
   order by id for update;

  for r in
    with req as (
      select x ->> 'pid' as pid, sum((x ->> 'qty')::int)::int as qty, min(ord) as ord
      from jsonb_array_elements(p_items) with ordinality as t(x, ord) group by 1
    ),
    cur as (
      select e ->> 'pid' as pid, e, ord from jsonb_array_elements(o.items) with ordinality as t(e, ord)
    )
    select req.pid, req.qty, cur.e as old_e, p.name, p.size, p.price, p.active, a.free
    from req
    left join cur on cur.pid = req.pid
    left join public.products p on p.id::text = req.pid
    left join public._availability() a on a.id::text = req.pid
    where req.qty > 0
    order by coalesce(cur.ord, 100000 + req.ord)
  loop
    if r.qty > 20 then raise exception 'cantidad_invalida'; end if;
    if r.old_e is not null then
      v_items := v_items || jsonb_set(r.old_e, '{qty}', to_jsonb(r.qty));
    else
      if r.name is null or not r.active then raise exception 'producto_no_disponible'; end if;
      v_items := v_items || jsonb_build_object('pid', r.pid, 'name', r.name, 'size', r.size, 'price', r.price, 'qty', r.qty);
    end if;
    if r.free is not null and r.qty > r.free then
      raise exception 'sin_stock:%', coalesce(r.name, r.old_e ->> 'name');
    end if;
  end loop;

  if jsonb_array_length(v_items) = 0 then raise exception 'pedido_vacio'; end if;

  update public.orders
     set items = v_items,
         total = (select sum((e ->> 'price')::numeric * (e ->> 'qty')::int) from jsonb_array_elements(v_items) e)
   where number = p_number;
  return true;
end;
$$;

-- Return (devolución) of products from a paid order. Units go back to inventory.
-- p_items: [{pid, qty}] to return now. Refund uses the order's frozen prices.
create or replace function public.return_items(p_number text, p_items jsonb, p_method text, p_reason text default '')
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  o public.orders;
  v_items jsonb := '[]'::jsonb;
  v_amount numeric := 0;
  v_id uuid;
  r record;
begin
  if not public.is_staff() then raise exception 'no_autorizado'; end if;
  if not (public.has_perm('caja')) then raise exception 'sin_permiso'; end if;
  if p_method not in ('Tarjeta','Efectivo','Transferencia') then raise exception 'metodo_invalido'; end if;
  select * into o from public.orders where number = p_number for update;
  if not found then raise exception 'pedido_no_existe'; end if;
  if o.status not in ('pagado','listo','entregado') then raise exception 'pedido_no_cobrado'; end if;
  if jsonb_typeof(p_items) is distinct from 'array' then raise exception 'devolucion_vacia'; end if;

  for r in
    with req as (
      select x ->> 'pid' as pid, sum((x ->> 'qty')::int)::int as qty
      from jsonb_array_elements(p_items) x group by 1
    ),
    line as (select e ->> 'pid' as pid, e from jsonb_array_elements(o.items) e),
    done as (
      select i ->> 'pid' as pid, sum((i ->> 'qty')::int)::int as qty
      from public.returns rr, jsonb_array_elements(rr.items) i
      where rr.order_number = o.number group by 1
    )
    select req.pid, req.qty, line.e, coalesce(done.qty, 0) as done_qty
    from req left join line on line.pid = req.pid left join done on done.pid = req.pid
    where req.qty > 0
  loop
    if r.e is null then raise exception 'producto_no_en_pedido'; end if;
    if r.qty > (r.e ->> 'qty')::int - r.done_qty then raise exception 'devolucion_excede:%', r.e ->> 'name'; end if;
    v_items := v_items || jsonb_build_object('pid', r.pid, 'name', r.e ->> 'name', 'size', r.e ->> 'size',
                                             'price', (r.e ->> 'price')::numeric, 'qty', r.qty);
    v_amount := v_amount + (r.e ->> 'price')::numeric * r.qty;
  end loop;

  if jsonb_array_length(v_items) = 0 then raise exception 'devolucion_vacia'; end if;

  insert into public.returns (order_number, items, amount, method, reason, created_by)
  values (o.number, v_items, v_amount, p_method, left(coalesce(p_reason, ''), 200),
          lower(coalesce(auth.jwt() ->> 'email', '')))
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'amount', v_amount);
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
  if not (case when p_status = 'cancelado' then public.has_perm('caja') else (public.has_perm('caja') or public.has_perm('surtido')) end) then raise exception 'sin_permiso'; end if;
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
create policy settings_staff_update on public.settings for update to authenticated using (public.has_perm('inventario')) with check (public.has_perm('inventario'));

drop policy if exists products_staff_all on public.products;
create policy products_staff_all on public.products for all to authenticated using (public.is_staff()) with check (public.has_perm('inventario'));

-- Orders: staff read; every change goes through the RPCs above.
drop policy if exists orders_staff_read on public.orders;
create policy orders_staff_read on public.orders for select to authenticated using (public.is_staff());

drop policy if exists members_staff_read on public.members;
create policy members_staff_read on public.members for select to authenticated using (public.is_staff());

alter table public.returns enable row level security;
drop policy if exists returns_staff_read on public.returns;
create policy returns_staff_read on public.returns for select to authenticated using (public.is_staff());

-- ---------- Table privileges -----------------------------------------
-- Newer Supabase projects don't grant table access by default. RLS above
-- still decides which rows staff see; anon gets no table access at all.
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.products to authenticated;
grant select, update on public.settings to authenticated;
grant select on public.orders, public.members, public.staff, public.returns to authenticated;

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
revoke execute on function public.return_items(text, jsonb, text, text) from public, anon;
revoke execute on function public.set_order_status(text, text)       from public, anon;
grant  execute on function public.product_availability()             to authenticated;
grant  execute on function public.mark_paid(text, text, text)        to authenticated;
grant  execute on function public.update_order_items(text, jsonb)    to authenticated;
grant  execute on function public.return_items(text, jsonb, text, text) to authenticated;
grant  execute on function public.set_order_status(text, text)       to authenticated;

-- ---------- Realtime (staff screens) ---------------------------------

do $$
declare t text;
begin
  foreach t in array array['orders','products','members','settings','returns'] loop
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- Product images (storage bucket + staff-only upload): see 002_product_images.sql

-- SMS function (service_role)
grant usage on schema public to service_role;
grant select, update on public.orders to service_role;
grant select on public.staff to service_role;

-- ---------- Admin: end-of-test reset ---------------------------------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff
                 where email = lower(coalesce(auth.jwt() ->> 'email', '')) and admin);
$$;

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
revoke execute on function public.is_admin() from public, anon;
grant  execute on function public.is_admin() to authenticated;
revoke execute on function public.reset_event_data(text, boolean) from public, anon;
grant  execute on function public.reset_event_data(text, boolean) to authenticated;

-- Staff management function (api/staff.js)
grant select, insert, update, delete on public.staff to service_role;

revoke execute on function public.has_perm(text) from public, anon;
grant  execute on function public.has_perm(text) to authenticated;

-- =====================================================================
-- Kits (011_kits.sql) — later definitions replace the earlier ones above.
-- =====================================================================
-- 011 · Kits
-- A kit is a row in products with is_kit = true plus its components in kit_items.
-- Kits are sold like any product (tablet, caja); each order line of a kit keeps a
-- snapshot of its components ({kit:true, comps:[{pid,name,size,qty}]}) so selling a kit
-- deducts the component products from inventory, and editing a kit later never
-- rewrites past sales. Kit availability = min over components of floor(available / qty).

alter table public.products add column if not exists is_kit boolean not null default false;

create table if not exists public.kit_items (
  kit_id      uuid not null references public.products(id) on delete cascade,
  product_id  uuid not null references public.products(id) on delete restrict,
  qty         int  not null default 1 check (qty between 1 and 20),
  primary key (kit_id, product_id)
);
alter table public.kit_items enable row level security;
drop policy if exists kit_items_staff_read on public.kit_items;
create policy kit_items_staff_read on public.kit_items for select to authenticated using (public.is_staff());
grant select on public.kit_items to authenticated;

-- Component snapshot for one kit (per 1 kit).
create or replace function public._kit_comps(p_kit uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('pid', p.id, 'name', p.name, 'size', p.size, 'qty', k.qty)
                            order by p.sort_order, p.name), '[]'::jsonb)
  from public.kit_items k join public.products p on p.id = k.product_id
  where k.kit_id = p_kit;
$$;

-- Availability, kit-aware.
--   Physical products: sold/held include units sold inside kits.
--   Kits: sold/held = kits; stock/available/free = how many kits the components allow.
create or replace function public._availability()
returns table (id uuid, stock int, sold int, held int, available int, free int)
language sql stable security definer set search_path = public as $$
  with cfg as (select hold_minutes from public.settings where id = 1),
  raw as (
    select i, o.status, o.created_at
    from public.orders o, jsonb_array_elements(o.items) i
    where o.status <> 'cancelado'
  ),
  lines as (
    select (i ->> 'pid')::uuid as pid, (i ->> 'qty')::int as qty, status, created_at from raw
    union all
    select (c ->> 'pid')::uuid, (i ->> 'qty')::int * (c ->> 'qty')::int, status, created_at
    from raw, jsonb_array_elements(coalesce(i -> 'comps', '[]'::jsonb)) c
  ),
  agg as (
    select l.pid,
      coalesce(sum(l.qty) filter (where l.status in ('pagado','listo','entregado')), 0) as sold_raw,
      coalesce(sum(l.qty) filter (where l.status = 'pendiente'
               and l.created_at > now() - make_interval(mins => (select hold_minutes from cfg))), 0) as held
    from lines l group by l.pid
  ),
  retraw as (select i from public.returns r, jsonb_array_elements(r.items) i),
  ret as (
    select x.pid, sum(x.qty) as qty from (
      select (i ->> 'pid')::uuid as pid, (i ->> 'qty')::int as qty from retraw
      union all
      select (c ->> 'pid')::uuid, (i ->> 'qty')::int * (c ->> 'qty')::int
      from retraw, jsonb_array_elements(coalesce(i -> 'comps', '[]'::jsonb)) c
    ) x group by x.pid
  ),
  base as (
    select p.id, p.is_kit, (p.stock + p.restock)::int as stock,
      (coalesce(a.sold_raw, 0) - coalesce(r.qty, 0))::int as sold,
      coalesce(a.held, 0)::int as held
    from public.products p
    left join agg a on a.pid = p.id
    left join ret r on r.pid = p.id
  ),
  phys as (
    select b.*, (b.stock - b.sold - b.held) as available, (b.stock - b.sold) as free from base b
  ),
  kit as (
    select k.kit_id,
      min(greatest(f.stock, 0) / k.qty)::int     as stock,
      min(greatest(f.available, 0) / k.qty)::int as available,
      min(greatest(f.free, 0) / k.qty)::int      as free
    from public.kit_items k join phys f on f.id = k.product_id
    group by k.kit_id
  )
  select f.id,
    case when f.is_kit then coalesce(k.stock, 0) else f.stock end,
    f.sold, f.held,
    case when f.is_kit then coalesce(k.available, 0) else f.available end,
    case when f.is_kit then coalesce(k.free, 0) else f.free end
  from phys f left join kit k on k.kit_id = f.id;
$$;
revoke execute on function public._availability() from public, anon, authenticated;
revoke execute on function public._kit_comps(uuid) from public, anon, authenticated;

-- Checks total demand per physical product (single units + kit components) against
-- available (p_free = false, tablet) or free (p_free = true, caja). Raises sin_stock:<name>.
create or replace function public._check_stock(p_items jsonb, p_free boolean) returns void
language plpgsql stable security definer set search_path = public as $$
declare r record;
begin
  for r in
    with d as (
      select (i ->> 'pid')::uuid as pid, (i ->> 'qty')::int as qty
      from jsonb_array_elements(p_items) i where not (i ? 'comps')
      union all
      select (c ->> 'pid')::uuid, (i ->> 'qty')::int * (c ->> 'qty')::int
      from jsonb_array_elements(p_items) i, jsonb_array_elements(i -> 'comps') c
      where i ? 'comps'
    ),
    s as (select pid, sum(qty)::int as qty from d group by pid)
    select s.pid, s.qty, p.name, case when p_free then a.free else a.available end as lim
    from s left join public.products p on p.id = s.pid
    left join public._availability() a on a.id = s.pid
  loop
    if r.lim is not null and r.qty > r.lim then raise exception 'sin_stock:%', r.name; end if;
  end loop;
end;
$$;
revoke execute on function public._check_stock(jsonb, boolean) from public, anon, authenticated;

-- Locks the given products plus the components of any kits among them.
create or replace function public._lock_products(p_ids uuid[]) returns void
language sql volatile security definer set search_path = public as $$
  select 1 from public.products
   where id = any(p_ids)
      or id in (select product_id from public.kit_items where kit_id = any(p_ids))
   order by id for update;
$$;
revoke execute on function public._lock_products(uuid[]) from public, anon, authenticated;

-- Tablet catalog: kits included, with what they contain.
create or replace function public.get_kiosk() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'evento',      (select evento from public.settings where id = 1),
    'privacy_url', (select privacy_url from public.settings where id = 1),
    'consejeras',  (select to_jsonb(consejeras) from public.settings where id = 1),
    'products', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'name', p.name, 'category', p.category, 'size', p.size,
               'price', p.price, 'image_url', p.image_url, 'available', greatest(a.available, 0),
               'kit', p.is_kit,
               'includes', case when p.is_kit then (select jsonb_agg(jsonb_build_object('name', c ->> 'name', 'size', c ->> 'size', 'qty', (c ->> 'qty')::int))
                                                    from jsonb_array_elements(public._kit_comps(p.id)) c) end)
             order by p.sort_order, p.name)
      from public.products p join public._availability() a on a.id = p.id
      where p.active), '[]'::jsonb)
  );
$$;

create or replace function public.create_order(
  p_items jsonb, p_customer jsonb, p_community boolean default false, p_member jsonb default '{}'::jsonb
) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_nombre   text := left(trim(coalesce(p_customer ->> 'nombre', '')), 80);
  v_apellido text := left(trim(coalesce(p_customer ->> 'apellido', '')), 80);
  v_tel      text := regexp_replace(coalesce(p_customer ->> 'telefono', ''), '\D', '', 'g');
  v_email    text := left(lower(trim(coalesce(p_customer ->> 'email', ''))), 120);
  v_conse    text := trim(coalesce(p_customer ->> 'consejera', ''));
  v_factura  boolean := coalesce((p_customer ->> 'factura')::boolean, false);
  v_chars    text := 'ACDEFHJKLMNPRTUVWXY3479';
  v_items    jsonb := '[]'::jsonb;
  v_total    numeric := 0;
  v_number   text;
  v_try      int := 0;
  v_line     jsonb;
  r          record;
begin
  if v_nombre = '' then raise exception 'nombre_requerido'; end if;
  if length(v_tel) <> 10 then raise exception 'telefono_invalido'; end if;
  if v_email <> '' and not public._valid_email(v_email) then raise exception 'correo_invalido'; end if;
  if coalesce(p_community, false) and v_email = '' then raise exception 'correo_requerido'; end if;
  if coalesce((p_customer ->> 'privacidad')::boolean, false) is not true then raise exception 'privacidad_requerida'; end if;
  if v_conse <> '' and not exists (select 1 from public.settings where id = 1 and v_conse = any(consejeras)) then v_conse := ''; end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then raise exception 'pedido_vacio'; end if;
  if jsonb_array_length(p_items) > 40 then raise exception 'cantidad_invalida'; end if;

  perform public._lock_products(array(select (e ->> 'pid')::uuid from jsonb_array_elements(p_items) e));

  for r in
    with req as (
      select (e ->> 'pid')::uuid as pid, sum((e ->> 'qty')::int)::int as qty, min(ord) as ord
      from jsonb_array_elements(p_items) with ordinality as t(e, ord)
      group by 1
    )
    select req.pid, req.qty, p.name, p.size, p.price, p.active, p.is_kit
    from req left join public.products p on p.id = req.pid
    order by req.ord
  loop
    if r.name is null or not r.active then raise exception 'producto_no_disponible'; end if;
    if r.qty < 1 or r.qty > 20 then raise exception 'cantidad_invalida'; end if;
    v_line := jsonb_build_object('pid', r.pid, 'name', r.name, 'size', r.size, 'price', r.price, 'qty', r.qty);
    if r.is_kit then
      v_line := v_line || jsonb_build_object('kit', true, 'comps', public._kit_comps(r.pid));
      if jsonb_array_length(v_line -> 'comps') = 0 then raise exception 'producto_no_disponible'; end if;
    end if;
    v_items := v_items || v_line;
    v_total := v_total + r.price * r.qty;
  end loop;

  perform public._check_stock(v_items, false);

  loop
    v_number := 'M' || (select string_agg(substr(v_chars, 1 + floor(random() * length(v_chars))::int, 1), '')
                        from generate_series(1, 3));
    begin
      insert into public.orders (number, items, total, customer, community, consejera, factura)
      values (v_number, v_items, v_total,
              jsonb_build_object('nombre', v_nombre, 'apellido', v_apellido, 'telefono', v_tel, 'email', v_email),
              coalesce(p_community, false), v_conse, v_factura);
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

create or replace function public.mark_paid(p_number text, p_method text, p_ref text default '')
returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare
  o public.orders;
begin
  if not public.is_staff() then raise exception 'no_autorizado'; end if;
  if not (public.has_perm('caja')) then raise exception 'sin_permiso'; end if;
  if p_method not in ('Tarjeta','Efectivo','Transferencia') then raise exception 'metodo_invalido'; end if;
  select * into o from public.orders where number = p_number for update;
  if not found then raise exception 'pedido_no_existe'; end if;
  if o.status <> 'pendiente' then raise exception 'pedido_ya_procesado'; end if;

  perform public._lock_products(array(
    select (e ->> 'pid')::uuid from jsonb_array_elements(o.items) e
    union select (c ->> 'pid')::uuid from jsonb_array_elements(o.items) e, jsonb_array_elements(coalesce(e -> 'comps', '[]'::jsonb)) c));
  perform public._check_stock(o.items, true);

  update public.orders
     set status = 'pagado', paid_at = now(), pay_method = p_method, pay_ref = left(coalesce(p_ref, ''), 120),
         paid_by = lower(coalesce(auth.jwt() ->> 'email', ''))
   where number = p_number;
  return true;
end;
$$;

-- Cashier edits a pending order: change quantities, remove lines (qty 0) or ADD products/kits.
create or replace function public.update_order_items(p_number text, p_items jsonb)
returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare
  o public.orders;
  v_items jsonb := '[]'::jsonb;
  v_line jsonb;
  r record;
begin
  if not public.is_staff() then raise exception 'no_autorizado'; end if;
  if not (public.has_perm('caja')) then raise exception 'sin_permiso'; end if;
  select * into o from public.orders where number = p_number for update;
  if not found then raise exception 'pedido_no_existe'; end if;
  if o.status <> 'pendiente' then raise exception 'pedido_ya_procesado'; end if;
  if jsonb_typeof(p_items) is distinct from 'array' then raise exception 'pedido_vacio'; end if;

  perform public._lock_products(array(
    select (x ->> 'pid')::uuid from jsonb_array_elements(p_items) x
    union select (c ->> 'pid')::uuid from jsonb_array_elements(o.items) e, jsonb_array_elements(coalesce(e -> 'comps', '[]'::jsonb)) c));

  for r in
    with req as (
      select x ->> 'pid' as pid, sum((x ->> 'qty')::int)::int as qty, min(ord) as ord
      from jsonb_array_elements(p_items) with ordinality as t(x, ord) group by 1
    ),
    cur as (
      select e ->> 'pid' as pid, e, ord from jsonb_array_elements(o.items) with ordinality as t(e, ord)
    )
    select req.pid, req.qty, cur.e as old_e, p.name, p.size, p.price, p.active, p.is_kit
    from req
    left join cur on cur.pid = req.pid
    left join public.products p on p.id::text = req.pid
    where req.qty > 0
    order by coalesce(cur.ord, 100000 + req.ord)
  loop
    if r.qty > 20 then raise exception 'cantidad_invalida'; end if;
    if r.old_e is not null then
      v_items := v_items || jsonb_set(r.old_e, '{qty}', to_jsonb(r.qty));
    else
      if r.name is null or not r.active then raise exception 'producto_no_disponible'; end if;
      v_line := jsonb_build_object('pid', r.pid, 'name', r.name, 'size', r.size, 'price', r.price, 'qty', r.qty);
      if r.is_kit then
        v_line := v_line || jsonb_build_object('kit', true, 'comps', public._kit_comps(r.pid::uuid));
        if jsonb_array_length(v_line -> 'comps') = 0 then raise exception 'producto_no_disponible'; end if;
      end if;
      v_items := v_items || v_line;
    end if;
  end loop;

  if jsonb_array_length(v_items) = 0 then raise exception 'pedido_vacio'; end if;
  perform public._check_stock(v_items, true);

  update public.orders
     set items = v_items,
         total = (select sum((e ->> 'price')::numeric * (e ->> 'qty')::int) from jsonb_array_elements(v_items) e)
   where number = p_number;
  return true;
end;
$$;

-- Returns: a kit is returned as a whole; its components go back to inventory.
create or replace function public.return_items(p_number text, p_items jsonb, p_method text, p_reason text default '')
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  o public.orders;
  v_items jsonb := '[]'::jsonb;
  v_amount numeric := 0;
  v_id uuid;
  r record;
begin
  if not public.is_staff() then raise exception 'no_autorizado'; end if;
  if not (public.has_perm('caja')) then raise exception 'sin_permiso'; end if;
  if p_method not in ('Tarjeta','Efectivo','Transferencia') then raise exception 'metodo_invalido'; end if;
  select * into o from public.orders where number = p_number for update;
  if not found then raise exception 'pedido_no_existe'; end if;
  if o.status not in ('pagado','listo','entregado') then raise exception 'pedido_no_cobrado'; end if;
  if jsonb_typeof(p_items) is distinct from 'array' then raise exception 'devolucion_vacia'; end if;

  for r in
    with req as (
      select x ->> 'pid' as pid, sum((x ->> 'qty')::int)::int as qty
      from jsonb_array_elements(p_items) x group by 1
    ),
    line as (select e ->> 'pid' as pid, e from jsonb_array_elements(o.items) e),
    done as (
      select i ->> 'pid' as pid, sum((i ->> 'qty')::int)::int as qty
      from public.returns rr, jsonb_array_elements(rr.items) i
      where rr.order_number = o.number group by 1
    )
    select req.pid, req.qty, line.e, coalesce(done.qty, 0) as done_qty
    from req left join line on line.pid = req.pid left join done on done.pid = req.pid
    where req.qty > 0
  loop
    if r.e is null then raise exception 'producto_no_en_pedido'; end if;
    if r.qty > (r.e ->> 'qty')::int - r.done_qty then raise exception 'devolucion_excede:%', r.e ->> 'name'; end if;
    v_items := v_items || (jsonb_build_object('pid', r.pid, 'name', r.e ->> 'name', 'size', r.e ->> 'size',
                                              'price', (r.e ->> 'price')::numeric, 'qty', r.qty)
                           || case when r.e ? 'comps' then jsonb_build_object('kit', true, 'comps', r.e -> 'comps') else '{}'::jsonb end);
    v_amount := v_amount + (r.e ->> 'price')::numeric * r.qty;
  end loop;

  if jsonb_array_length(v_items) = 0 then raise exception 'devolucion_vacia'; end if;

  insert into public.returns (order_number, items, amount, method, reason, created_by)
  values (o.number, v_items, v_amount, p_method, left(coalesce(p_reason, ''), 200),
          lower(coalesce(auth.jwt() ->> 'email', '')))
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'amount', v_amount);
end;
$$;

-- Create / edit a kit. p: {id?, name, category, size, price, active, items:[{pid, qty}]}
create or replace function public.save_kit(p jsonb) returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare
  v_id    uuid := nullif(p ->> 'id', '')::uuid;
  v_name  text := left(trim(coalesce(p ->> 'name', '')), 120);
  v_price numeric := (p ->> 'price')::numeric;
  v_n     int;
begin
  if not public.is_staff() then raise exception 'no_autorizado'; end if;
  if not public.has_perm('inventario') then raise exception 'sin_permiso'; end if;
  if v_name = '' then raise exception 'kit_sin_nombre'; end if;
  if v_price is null or v_price < 0 then raise exception 'kit_precio'; end if;
  if jsonb_typeof(p -> 'items') is distinct from 'array' then raise exception 'kit_sin_productos'; end if;

  create temp table _ki on commit drop as
    select (x ->> 'pid')::uuid as pid, sum((x ->> 'qty')::int)::int as qty
    from jsonb_array_elements(p -> 'items') x where coalesce((x ->> 'qty')::int, 0) > 0 group by 1;
  select count(*) into v_n from _ki;
  if v_n = 0 then raise exception 'kit_sin_productos'; end if;
  if v_n > 20 or exists (select 1 from _ki where qty > 20) then raise exception 'cantidad_invalida'; end if;
  if exists (select 1 from _ki k left join public.products pr on pr.id = k.pid where pr.id is null or pr.is_kit or pr.id = v_id) then
    raise exception 'kit_producto_invalido';
  end if;

  if v_id is null then
    insert into public.products (name, category, size, price, stock, active, sort_order, sample, is_kit)
    values (v_name, coalesce(nullif(trim(p ->> 'category'), ''), 'Kits'), left(trim(coalesce(p ->> 'size', '')), 60), v_price, 0,
            coalesce((p ->> 'active')::boolean, true),
            coalesce((select max(sort_order) from public.products), 0) + 1, false, true)
    returning id into v_id;
  else
    update public.products set name = v_name, category = coalesce(nullif(trim(p ->> 'category'), ''), 'Kits'),
           size = left(trim(coalesce(p ->> 'size', '')), 60), price = v_price,
           active = coalesce((p ->> 'active')::boolean, active), sample = false
     where id = v_id and is_kit;
    if not found then raise exception 'kit_no_existe'; end if;
    delete from public.kit_items where kit_id = v_id;
  end if;
  insert into public.kit_items (kit_id, product_id, qty) select v_id, pid, qty from _ki;
  drop table _ki;
  return v_id;
end;
$$;

-- Deletes a kit that has never been ordered; otherwise hide it (Visible off).
create or replace function public.delete_kit(p_id uuid) returns boolean
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'no_autorizado'; end if;
  if not public.has_perm('inventario') then raise exception 'sin_permiso'; end if;
  if exists (select 1 from public.orders o, jsonb_array_elements(o.items) i where i ->> 'pid' = p_id::text) then
    raise exception 'kit_con_ventas';
  end if;
  delete from public.products where id = p_id and is_kit;
  return found;
end;
$$;

revoke execute on function public.save_kit(jsonb)   from public, anon;
revoke execute on function public.delete_kit(uuid)  from public, anon;
grant  execute on function public.save_kit(jsonb)   to authenticated;
grant  execute on function public.delete_kit(uuid)  to authenticated;

do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'kit_items') then
    alter publication supabase_realtime add table public.kit_items;
  end if;
end $$;

-- 012_borrar_productos.sql
-- 012 · Eliminar productos desde Inventario.
-- Solo se puede eliminar un producto que nunca se ha pedido y que no está dentro de un kit;
-- si ya tiene ventas, se oculta (Visible apagado) para no romper el historial.
create or replace function public.delete_product(p_id uuid) returns boolean
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'no_autorizado'; end if;
  if not public.has_perm('inventario') then raise exception 'sin_permiso'; end if;
  if exists (select 1 from public.orders o, jsonb_array_elements(o.items) i
             where i ->> 'pid' = p_id::text
                or exists (select 1 from jsonb_array_elements(coalesce(i -> 'comps', '[]'::jsonb)) c where c ->> 'pid' = p_id::text)) then
    raise exception 'producto_con_ventas';
  end if;
  if exists (select 1 from public.kit_items where product_id = p_id) then raise exception 'producto_en_kit'; end if;
  delete from public.products where id = p_id and not is_kit;
  return found;
end;
$$;
revoke execute on function public.delete_product(uuid) from public, anon;
grant  execute on function public.delete_product(uuid) to authenticated;
