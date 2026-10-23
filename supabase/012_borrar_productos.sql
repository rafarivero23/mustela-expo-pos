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
                or exists (select 1 from jsonb_array_elements(coalesce(i -> 'comps', '[]'::jsonb)) c where c ->> 'pid' = p_id::text))
     or exists (select 1 from public.orders_archive a, jsonb_array_elements(a.data -> 'items') i where i ->> 'pid' = p_id::text) then
    raise exception 'producto_con_ventas';
  end if;
  if exists (select 1 from public.kit_items where product_id = p_id) then raise exception 'producto_en_kit'; end if;
  delete from public.products where id = p_id and not is_kit;
  return found;
end;
$$;
revoke execute on function public.delete_product(uuid) from public, anon;
grant  execute on function public.delete_product(uuid) to authenticated;
