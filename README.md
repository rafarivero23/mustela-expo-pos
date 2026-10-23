# Mustela Expo POS — v2 (Vercel + Supabase)

Booth system for Mustela trade shows: Tienda and Comunidad screens on tablets, plus Caja, Surtido and Inventario screens for staff. All UI is in Spanish (es-MX) and prices are in MXN.

This is a static site with no build step. All data lives in Supabase (Postgres) and all security is enforced there.

```
index.html        UI (brand: Bleu M #004D9D, Taviraj Light + Work Sans)
app.js            app logic
config.js         ← your Supabase URL + anon key
vendor/           supabase-js 2.117.2 bundled locally (no CDN needed)
fonts/            Work Sans + Taviraj, self-hosted (SIL OFL)
assets/logo.svg   ← drop the official Mustela logo here (optional)
supabase/schema.sql  tables, RLS, RPCs, realtime
supabase/seed.sql    10 example products + staff allowlist
vercel.json       headers
```

## Setup (about 15 min)

1. **Supabase**: create a project (free tier is fine). Pick the **South America (São Paulo)** or **US East** region, which are the closest to Mexico.
2. **SQL Editor**: run `supabase/schema.sql`, then `supabase/002_product_images.sql` (photo storage) , `supabase/003_dermo_consejera.sql` , `supabase/004_caja_devoluciones_factura.sql`, `supabase/005_sms.sql` and `supabase/006_corte_reset.sql` … `supabase/011_kits.sql` (in number order), then edit the staff email in `supabase/seed.sql` and run it.
3. **Authentication → Providers → Email**: turn **off** "Allow new users to sign up". Then under **Authentication → Users → Add user**, create each staff member with email and password, ticking "Auto confirm". Every staff email must also be in the `staff` table:
   ```sql
   insert into staff (email, nombre) values ('persona@optimistinc.mx', 'Nombre');
   ```
4. **config.js**: paste the Project URL and the **anon** public key from Settings → API. Never paste the service_role key.
5. **Vercel**: push this folder to a GitHub repo and import it in Vercel with Framework Preset "Other" and no build command. Or run `npx vercel deploy --prod` from this folder.
6. **Custom domain** (optional): Vercel → Project → Domains.

## At the booth

- **Tablets**: open `https://<your-site>/#tienda` or `/#comunidad`, then add it to the home screen. Use guided access (iPad) or screen pinning (Android) to lock the device to the app. The small "Personal" button plus the kiosk PIN (default `2026`) leaves kiosk mode.
- **Caja / Surtido / Inventario**: open the site on staff devices and sign in with the staff email.
- **Before the event**:
  - Load the real catalog in Inventario. Editing a product removes its "Ejemplo" tag; hide or edit the sample products you don't need.
  - Set the event name, kiosk PIN and **aviso de privacidad** URL in Inventario → Ajustes.
  - Run one full test order from tablet to delivery.
  - Keep a phone hotspot as backup for the venue Wi-Fi.

## How it works

- **Stock is never decremented.** Each screen derives it from the orders:
  - sold = items in pagado, listo and entregado orders
  - held = items in *pendiente* orders younger than `hold_minutes` (default 30, set in Ajustes). Abandoned orders stop blocking stock after that time.
  - available = stock − sold − held (this is the limit at the tablet)
  - free = stock − sold (checked again when the cashier marks an order paid)
- **Customers (anon) cannot read anything** except the catalog and availability through `get_kiosk()`. They can only write through `create_order()` and `join_community()`. Both validate the input on the server, and `create_order()` locks the product rows, re-checks stock and takes prices from the database. In testing, 20 simultaneous orders for 5 remaining units produced exactly 5 successful orders.
- **Staff**: a signed-in Supabase user whose email is in `staff`. Order changes go through `mark_paid`, `update_order_items` and `set_order_status`, which enforce the order lifecycle (pendiente → pagado → listo → entregado, or pendiente → cancelado) and use server timestamps.
- **Realtime**: staff screens update live, and also refresh every 30 s in case the realtime connection drops. Tablets refresh availability every 15 s and again before each order.
- **Kits**: Inventario → Kits. A kit has a name, a final price and its products with quantities. It's sold like any product; each order line stores a snapshot of the kit's contents, so selling a kit deducts those products from inventory (and a return puts them back). Kit availability = how many kits the current stock of its products allows.
- **Product photos**: Inventario → Foto → Subir. Photos are shrunk on the device (max 900 px, WebP) and stored in the public Supabase Storage bucket `product-images`; only staff can upload or delete.
- **CSV exports** (Pedidos and Comunidad) are UTF-8 with a BOM, so Excel shows accents correctly.

## Updating supabase-js

```
npm i @supabase/supabase-js@<ver> esbuild
echo "export { createClient } from '@supabase/supabase-js';" > entry.js
npx esbuild entry.js --bundle --format=esm --minify --outfile=vendor/supabase-<ver>.js
```
Then update the import at the top of `app.js`.
