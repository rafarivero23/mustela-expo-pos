-- =====================================================================
-- Mustela Expo POS — migration 008: código, SKU and resurtido per product
-- Run once in Supabase → SQL Editor. Safe to re-run.
-- =====================================================================
alter table public.products add column if not exists restock int  not null default 0;
alter table public.products add column if not exists codigo  text not null default '';
alter table public.products add column if not exists sku     text not null default '';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'products_restock_check') then
    alter table public.products add constraint products_restock_check check (restock >= 0);
  end if;
end $$;

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
revoke execute on function public._availability() from public, anon, authenticated;
