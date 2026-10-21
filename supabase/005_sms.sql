-- =====================================================================
-- Mustela Expo POS — migration 005: SMS status on orders
-- Run once in Supabase → SQL Editor. Safe to re-run.
-- =====================================================================
alter table public.orders add column if not exists sms_count  int  not null default 0;
alter table public.orders add column if not exists sms_status text not null default '';
alter table public.orders add column if not exists sms_at     timestamptz;
