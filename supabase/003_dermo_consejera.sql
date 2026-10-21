-- =====================================================================
-- Mustela Expo POS — migration 003: Dermo-Consejera on orders
-- Run once in Supabase → SQL Editor. Safe to re-run.
-- =====================================================================
alter table public.settings add column if not exists consejeras text[] not null default '{}';
alter table public.orders   add column if not exists consejera  text   not null default '';

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
      insert into public.orders (number, items, total, customer, community, consejera)
      values (v_number, v_items, v_total,
              jsonb_build_object('nombre', v_nombre, 'apellido', v_apellido, 'telefono', v_tel, 'email', v_email),
              coalesce(p_community, false), v_conse);
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

revoke execute on function public.get_kiosk() from public;
grant  execute on function public.get_kiosk() to anon, authenticated;
revoke execute on function public.create_order(jsonb, jsonb, boolean, jsonb) from public;
grant  execute on function public.create_order(jsonb, jsonb, boolean, jsonb) to anon, authenticated;
