-- =====================================================================
-- Mustela Expo POS — migration 005: SMS status on orders
-- Run once in Supabase → SQL Editor. Safe to re-run.
-- =====================================================================
alter table public.orders add column if not exists sms_count  int  not null default 0;
alter table public.orders add column if not exists sms_status text not null default '';
alter table public.orders add column if not exists sms_at     timestamptz;

-- The SMS server function (api/sms.js) uses the Supabase secret key (service_role).
-- Newer projects don't grant table access by default.
grant usage on schema public to service_role;
grant select, update on public.orders to service_role;
grant select on public.staff to service_role;
