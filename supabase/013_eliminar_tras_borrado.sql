-- 013 · Eliminar: ya solo cuentan los pedidos actuales. Lo borrado en Corte (archivo)
-- ya no impide eliminar productos o kits.
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
revoke execute on function public.delete_kit(uuid) from public, anon;
grant  execute on function public.delete_kit(uuid) to authenticated;
