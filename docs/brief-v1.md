# Mustela Expo POS — Project Brief

Client: **Mustela** (account run by Optimist MX)
Owner: Rafa (Optimist)
Status: working prototype on claude.ai → moving to **Vercel + Supabase**
Attached: `mustela-pos-prototype.html` (full working source of v1)

---

## 1. Goal

A trade-show booth system for Mustela where:

1. Customers pick products at display tables (on tablets), enter their personal info, and get an order number.
2. They go to the checkout desk and pay.
3. Someone else fulfills the order from back stock and hands it over.
4. Customers can also sign up for the **Comunidad Mustela**, with or without buying.
5. Inventory is tracked live.

**Everything customer- and staff-facing is in Spanish (es-MX, MXN).**

## 2. Decisions made so far

| Topic | Decision |
|---|---|
| Build | Custom, not Shopify/Loyverse |
| Product catalog | Started with 10 example products marked "Ejemplo"; real catalog loaded later through the Inventario screen |
| Payment | External terminal (Clip / Mercado Pago / cash / transfer). The cashier charges on the terminal and marks the order paid in the app. No payment gateway in v1 |
| Customer devices | Tablets at the booth only (phones via QR was being considered for the Vercel version, not decided) |
| Community sign-up | Its own screen, plus an opt-in checkbox inside checkout (pre-checked) |
| Hosting | v1 ran as a claude.ai artifact with a built-in database. **Decision: move to Vercel** so it no longer depends on Claude accounts |

### Still open (for the Vercel version)
- How to deploy: give the agent Vercel + Supabase tokens / build files for manual deploy / GitHub repo.
- Staff login: individual email + password (recommended) or one shared password.
- Allow customers' own phones via QR on each table: yes/no.
- Custom domain (e.g. expo.mustela.mx)?
- Mustela's real **aviso de privacidad** text/link (legal requirement, LFPDPPP).
- Real product catalog: names, sizes, prices, stock, photos.
- Event name and dates.

## 3. Screens

Each device is set to one screen on first open (launcher screen: "¿Qué pantalla será este dispositivo?").

### Tienda (tablet, customer-facing)
- Product grid with category chips (line: Bebé, Piel atópica, Maternidad, Kits). Each card shows line, size, name, price, and a +/− stepper. "Agotado" when no stock is available.
- Sticky cart bar: item count, total, Vaciar, Continuar.
- Step 2, "Tus datos": order summary + form: Nombre*, Apellido, Celular* (10 digits), Correo (required if joining the community).
- Community box (pre-checked): "Quiero unirme a la Comunidad Mustela" → Etapa (Estoy embarazada / Bebé 0–12 meses / Niño 1–3 años / 3+ años / Otro), Ciudad.
- Privacy consent checkbox* (wording changes when joining the community).
- Confirmation: big order number (format `M` + 3 characters from `ACDEFHJKLMNPRTUVWXY3479`, e.g. M4K7), total, "Pasa a caja". Auto-resets after 30 s.
- Resets after 2 min of inactivity. Small "Personal" button → staff PIN to leave kiosk mode.
- Link to the Comunidad screen ("Solo quiero unirme a la Comunidad").

### Comunidad (tablet, customer-facing)
- Nombre, Apellido, Celular*, Correo*, Etapa (pill buttons), Ciudad, WhatsApp opt-in, email opt-in, privacy consent*.
- Success screen "¡Bienvenida, {nombre}!" that resets after 12 s.

### Caja (staff)
- "Por cobrar" queue (oldest first), search by number or name. Typing an exact number selects that order automatically.
- Order detail: number, time, customer, community badge, items with +/− (editable before payment), "Sin stock" warning, total.
- Payment method: Tarjeta / Efectivo / Transferencia. Reference field (card/transfer), or cash received with live change calculation.
- "Cobrado · enviar a surtido" blocks the payment if stock is short. Cancel the order with an inline confirm.
- "Cobrados recientes" list.

### Surtido (staff)
- Two columns: **Por surtir** (paid, oldest first) and **Listos para entregar**.
- Ticket: number, customer name, items with tick boxes (kept on that device only), time since paid.
- Buttons: Listo para entregar → Entregado; "Regresar a surtir".

### Inventario (staff)
- Tiles: Ventas cobradas, Pedidos cobrados, Ticket promedio, Piezas vendidas, Por cobrar, Registros Comunidad.
- Product table with inline editing: name, line, size, price, stock, visible. Read-only columns: sold, held, available (shown in red at ≤3).
- Add-product form.
- CSV exports, UTF-8 with BOM so Excel shows accents: **Pedidos** (one row per order line) and **Comunidad**.
- Latest 25 community sign-ups.
- Settings: event name, staff PIN (default `2026`).

## 4. Order lifecycle

`pendiente` (created at the tablet) → `pagado` (cashier) → `listo` (fulfillment) → `entregado`
`pendiente` → `cancelado` (cashier)

## 5. Inventory logic

Stock is **never decremented directly**. It is derived from the orders, which avoids race conditions between devices:

- `sold` = qty in orders with status pagado / listo / entregado
- `held` = qty in `pendiente` orders
- `available` = `stock` − sold − held (limit at the tablet)
- `free` = `stock` − sold (checked at payment)
- Editing `stock` means "total units received for the event".

## 6. Data model (v1)

```
products/{id}   name, category, size, price (MXN), stock, active, order, sample
orders/{number} number, items[{pid,name,size,price,qty}], total,
                customer{nombre,apellido,telefono,email}, community(bool),
                status, createdAt, paidAt, payMethod, payRef, readyAt,
                deliveredAt, cancelledAt
members/{id}    nombre, apellido, telefono, email, etapa, ciudad,
                whatsapp, correo, privacidad, origen('Tienda'|'Registro'),
                pedido, createdAt
settings/config evento, pin
```

## 7. Example products seeded in v1 (placeholder prices, replace)

| # | Product | Line | Size | Price | Stock |
|---|---|---|---|---|---|
| 1 | Hydra Bébé Crema Corporal | Bebé | 300 ml | $389 | 40 |
| 2 | Gel Lavante Suave | Bebé | 500 ml | $359 | 40 |
| 3 | Crema para Cambio de Pañal 1 2 3 | Bebé | 100 ml | $279 | 50 |
| 4 | Agua Limpiadora sin Enjuague | Bebé | 300 ml | $299 | 30 |
| 5 | Champú Espuma Recién Nacido | Bebé | 150 ml | $319 | 25 |
| 6 | Stelatopia Crema Emoliente | Piel atópica | 200 ml | $529 | 24 |
| 7 | Stelatopia Aceite de Baño | Piel atópica | 200 ml | $489 | 20 |
| 8 | Maternité Crema Prevención de Estrías | Maternidad | 150 ml | $649 | 20 |
| 9 | Maternité Aceite para Estrías | Maternidad | 105 ml | $599 | 15 |
| 10 | Kit Bienvenida Recién Nacido | Kits | 4 piezas | $999 | 12 |

## 8. Plan for the Vercel version

**Stack:** Vercel (hosting; static site or Next.js) + **Supabase** (Postgres, realtime, auth). Both have free tiers that cover a trade show.

**Why a new backend:** v1's database is built into claude.ai and can't be moved over. The Vercel version needs its own database.

**Security (the site will be public):**
- Customer screens (Tienda, Comunidad) work without login, using the Supabase anon key.
- Row Level Security:
  - anon can **read active products + availability only**. Never orders or members.
  - anon creates orders only through an RPC `create_order(items, customer, community)`. The RPC checks stock atomically on the server and generates a unique order number.
  - anon can **insert** into `members` (no read).
  - Authenticated staff can read and update everything.
- Staff screens (Caja, Surtido, Inventario) require Supabase Auth login. This replaces the v1 PIN; a kiosk PIN can still be kept for leaving the tablet screen.
- Payment marking via an RPC `mark_paid(number, method, ref)` that re-checks stock.
- Availability via a view/RPC `product_availability` (stock, sold, held, available).

**Realtime:** Supabase Realtime subscriptions on `orders` and `products` for Caja, Surtido, Inventario and the tablets.

**Tables:** `products`, `orders`, `order_items` (or JSONB items), `members`, `settings`. Same fields as section 6.

**Nice-to-haves after v2:** product photos (Supabase Storage), QR on tables for customers' phones, custom domain, payment links (Mercado Pago / Stripe), a printed pick ticket, a WhatsApp confirmation with the order number, and syncing the community sign-ups into Mustela's CRM / WhatsApp concierge.

## 9. Operational notes
- Have a phone hotspot as backup for venue Wi-Fi.
- Do one full test order from tablet to delivery before the event.
- Load the real catalog and replace the "Ejemplo" items beforehand.
- Get Mustela's aviso de privacidad and add the link/text to both consent checkboxes.
- v1 prototype (claude.ai artifact): https://claude.ai/artifact/G92BU89LGHA93Bv8HLWgzU
