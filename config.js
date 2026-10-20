// Supabase → Project Settings → API. The anon key is public by design;
// all access control lives in supabase/schema.sql (RLS + RPCs).
// NEVER put the service_role key here.
window.MUSTELA_CONFIG = {
  SUPABASE_URL: 'https://YOUR-PROJECT.supabase.co',
  SUPABASE_ANON_KEY: 'YOUR-ANON-KEY',
};
