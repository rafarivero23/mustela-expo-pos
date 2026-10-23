-- =====================================================================
-- Mustela Expo POS — migration 010: per-account screen permissions
-- Run once in Supabase → SQL Editor. Safe to re-run.
-- =====================================================================
alter table public.staff add column if not exists perms text[] not null default '{caja,surtido,inventario,corte}';

create or replace function public.has_perm(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.staff
    where email = lower(coalesce(auth.jwt() ->> 'email', ''))
      and (admin or p = any(perms))
  );
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

drop policy if exists settings_staff_update on public.settings;
create policy settings_staff_update on public.settings for update to authenticated using (public.has_perm('inventario')) with check (public.has_perm('inventario'));
drop policy if exists products_staff_all on public.products;
create policy products_staff_all on public.products for all to authenticated using (public.is_staff()) with check (public.has_perm('inventario'));

revoke execute on function public.has_perm(text) from public, anon;
grant  execute on function public.has_perm(text) to authenticated;
