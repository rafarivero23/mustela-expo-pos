-- =====================================================================
-- Mustela Expo POS — migration 002: product images + duplicate cleanup
-- Run once in Supabase → SQL Editor on a project that already has schema.sql.
-- Safe to re-run.
-- =====================================================================

-- 1) Image column
alter table public.products add column if not exists image_url text not null default '';

-- 2) Public bucket for product photos (2 MB max, images only)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-images', 'product-images', true, 2097152, array['image/webp','image/jpeg','image/png'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Only staff can upload / replace / delete. Anyone can view (public bucket).
drop policy if exists product_images_staff_select on storage.objects;
create policy product_images_staff_select on storage.objects for select to authenticated
  using (bucket_id = 'product-images' and public.is_staff());
drop policy if exists product_images_staff_insert on storage.objects;
create policy product_images_staff_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'product-images' and public.is_staff());
drop policy if exists product_images_staff_update on storage.objects;
create policy product_images_staff_update on storage.objects for update to authenticated
  using (bucket_id = 'product-images' and public.is_staff());
drop policy if exists product_images_staff_delete on storage.objects;
create policy product_images_staff_delete on storage.objects for delete to authenticated
  using (bucket_id = 'product-images' and public.is_staff());

-- 3) Tablets receive the image URL
create or replace function public.get_kiosk() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'evento',      (select evento from public.settings where id = 1),
    'privacy_url', (select privacy_url from public.settings where id = 1),
    'products', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'name', p.name, 'category', p.category, 'size', p.size,
               'price', p.price, 'image_url', p.image_url, 'available', greatest(a.available, 0))
             order by p.sort_order, p.name)
      from public.products p join public._availability() a on a.id = p.id
      where p.active), '[]'::jsonb)
  );
$$;
revoke execute on function public.get_kiosk() from public;
grant  execute on function public.get_kiosk() to anon, authenticated;

-- 4) Remove duplicate EXAMPLE products created by running the seed more than once
--    (only sample rows with the same name, never referenced by an order).
delete from public.products p
using (
  select id, row_number() over (partition by name order by created_at, id) as rn
  from public.products where sample
) d
where p.id = d.id and d.rn > 1
  and not exists (select 1 from public.orders o, jsonb_array_elements(o.items) i where i ->> 'pid' = p.id::text);
