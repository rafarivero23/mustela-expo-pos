-- =====================================================================
-- Mustela Expo POS — migration 006: corte de caja (who charged) + admin reset
-- Run once in Supabase → SQL Editor. Safe to re-run.
-- =====================================================================
alter table public.orders add column if not exists paid_by text not null default '';
alter table public.staff  add column if not exists admin   boolean not null default false;
update public.staff set admin = true where email = 'rr@optimistinc.mx';

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
     set status = 'pagado', paid_at = now(), pay_method = p_method, pay_ref = left(coalesce(p_ref, ''), 120),
         paid_by = lower(coalesce(auth.jwt() ->> 'email', ''))
   where number = p_number;
  return true;
end;
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff
                 where email = lower(coalesce(auth.jwt() ->> 'email', '')) and admin);
$$;

create or replace function public.reset_event_data(p_confirm text, p_members boolean default false)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_o int; v_r int; v_m int := 0;
begin
  if not public.is_admin() then raise exception 'solo_admin'; end if;
  if p_confirm is distinct from 'BORRAR' then raise exception 'confirmacion_invalida'; end if;
  delete from public.returns where true; get diagnostics v_r = row_count;
  delete from public.orders where true;  get diagnostics v_o = row_count;
  if coalesce(p_members, false) then delete from public.members where true; get diagnostics v_m = row_count; end if;
  return jsonb_build_object('orders', v_o, 'returns', v_r, 'members', v_m);
end;
$$;

revoke execute on function public.mark_paid(text, text, text) from public, anon;
grant  execute on function public.mark_paid(text, text, text) to authenticated;
revoke execute on function public.is_admin() from public, anon;
grant  execute on function public.is_admin() to authenticated;
revoke execute on function public.reset_event_data(text, boolean) from public, anon;
grant  execute on function public.reset_event_data(text, boolean) to authenticated;
