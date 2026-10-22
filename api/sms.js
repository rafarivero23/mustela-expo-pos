// Vercel serverless function: sends the order number by SMS (Twilio).
// The phone number is read from the database, never taken from the request,
// so this endpoint can't be used to text arbitrary numbers.
//
// Env vars (Vercel → Settings → Environment Variables):
//   TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM (e.g. +15551234567)
//   SUPABASE_URL, SUPABASE_SECRET_KEY (Supabase → Settings → API keys → secret / service_role)

const KIOSK_WINDOW_MIN = 15;   // tablet may trigger the first SMS only for fresh orders
const MAX_SENDS = 5;           // total per order (first + staff resends)

const money = n => new Intl.NumberFormat('es-MX', { style: 'currency', currency: 'MXN' }).format(Number(n) || 0);

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ ok: false, error: 'method' });
  const { TWILIO_ACCOUNT_SID: sid, TWILIO_AUTH_TOKEN: tok, TWILIO_FROM: from,
          SUPABASE_URL: sbUrl, SUPABASE_SECRET_KEY: sbKey } = process.env;
  const missing = ['TWILIO_ACCOUNT_SID','TWILIO_AUTH_TOKEN','TWILIO_FROM','SUPABASE_URL','SUPABASE_SECRET_KEY'].filter(k => !process.env[k]);
  if (missing.length) return res.status(501).json({ ok: false, error: 'sms_no_configurado', missing });

  const body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {});
  const number = String(body.number || '').toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 8);
  if (!number) return res.status(400).json({ ok: false, error: 'pedido_invalido' });

  const db = (path, init = {}) => fetch(`${sbUrl}/rest/v1/${path}`, {
    ...init, headers: { apikey: sbKey, Authorization: `Bearer ${sbKey}`, 'Content-Type': 'application/json', ...(init.headers || {}) } });

  // Staff resend? Verify the caller's Supabase session + staff allowlist.
  let isStaff = false;
  const auth = req.headers.authorization || '';
  if (auth.startsWith('Bearer ')) {
    const u = await fetch(`${sbUrl}/auth/v1/user`, { headers: { apikey: sbKey, Authorization: auth } });
    if (u.ok) {
      const email = String((await u.json()).email || '').toLowerCase();
      const s = await db(`staff?select=email&email=eq.${encodeURIComponent(email)}`);
      isStaff = s.ok && (await s.json()).length > 0;
    }
  }

  const r = await db(`orders?select=number,total,status,created_at,customer,sms_count&number=eq.${encodeURIComponent(number)}`);
  const o = r.ok ? (await r.json())[0] : null;
  if (!o) return res.status(404).json({ ok: false, error: 'pedido_no_existe' });
  if ((o.sms_count || 0) >= MAX_SENDS) return res.status(429).json({ ok: false, error: 'limite_sms' });
  if (!isStaff) {
    const ageMin = (Date.now() - new Date(o.created_at).getTime()) / 60000;
    if ((o.sms_count || 0) > 0 || ageMin > KIOSK_WINDOW_MIN || o.status !== 'pendiente')
      return res.status(403).json({ ok: false, error: 'no_permitido' });
  }
  const tel = String(o.customer?.telefono || '').replace(/\D/g, '');
  if (tel.length !== 10) return res.status(400).json({ ok: false, error: 'telefono_invalido' });

  // Plain ASCII keeps it to one SMS segment.
  const text = `Mustela: tu numero de pedido es ${o.number}. Total ${money(o.total)}. Muestralo en caja para pagar.`;
  const tw = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, {
    method: 'POST',
    headers: { Authorization: 'Basic ' + Buffer.from(`${sid}:${tok}`).toString('base64'), 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ To: `+52${tel}`, From: from, Body: text }),
  });
  const twj = await tw.json().catch(() => ({}));
  const ok = tw.ok;
  await db(`orders?number=eq.${encodeURIComponent(o.number)}`, {
    method: 'PATCH', headers: { Prefer: 'return=minimal' },
    body: JSON.stringify({ sms_count: (o.sms_count || 0) + 1, sms_status: ok ? 'enviado' : `error: ${String(twj.message || tw.status).slice(0, 120)}`, sms_at: new Date().toISOString() }),
  });
  return res.status(ok ? 200 : 502).json({ ok, error: ok ? undefined : 'twilio', detail: ok ? undefined : twj.message });
}
