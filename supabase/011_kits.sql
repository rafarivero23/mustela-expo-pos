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
  if exists (select 1 from public.orders o, jsonb_array_elements(o.items) i where i ->> 'pid' = p_id::text)
     or exists (select 1 from public.orders_archive a, jsonb_array_elements(a.data -> 'items') i where i ->> 'pid' = p_id::text) then
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
