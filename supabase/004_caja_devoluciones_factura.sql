-- =====================================================================
-- Mustela Expo POS — migration 004: add products in Caja, returns, factura
-- Run once in Supabase → SQL Editor. Safe to re-run.
-- =====================================================================
alter table public.orders add column if not exists factura boolean not null default false;

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

alter table public.returns enable row level security;
drop policy if exists returns_staff_read on public.returns;
create policy returns_staff_read on public.returns for select to authenticated using (public.is_staff());
grant select on public.returns to authenticated;

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
  select p.id, p.stock,
    (coalesce(a.sold_raw, 0) - coalesce(r.qty, 0))::int,
    coalesce(a.held, 0)::int,
    (p.stock - (coalesce(a.sold_raw, 0) - coalesce(r.qty, 0)) - coalesce(a.held, 0))::int,
    (p.stock - (coalesce(a.sold_raw, 0) - coalesce(r.qty, 0)))::int
  from public.products p
  left join agg a on a.pid = p.id
  left join ret r on r.pid = p.id;
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

revoke execute on function public._availability() from public, anon, authenticated;
revoke execute on function public.create_order(jsonb, jsonb, boolean, jsonb) from public;
grant  execute on function public.create_order(jsonb, jsonb, boolean, jsonb) to anon, authenticated;
revoke execute on function public.update_order_items(text, jsonb) from public, anon;
grant  execute on function public.update_order_items(text, jsonb) to authenticated;
revoke execute on function public.return_items(text, jsonb, text, text) from public, anon;
grant  execute on function public.return_items(text, jsonb, text, text) to authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'returns') then
    alter publication supabase_realtime add table public.returns;
  end if;
end $$;
