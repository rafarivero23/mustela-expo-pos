-- =====================================================================
-- Mustela Expo POS — migration 009: staff management from the app
-- (api/staff.js uses the secret key = service_role). Safe to re-run.
-- =====================================================================
grant select, insert, update, delete on public.staff to service_role;
