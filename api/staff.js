// Vercel serverless function: staff management for admins (create user, admin flag,
// password, remove). Uses SUPABASE_SECRET_KEY; the caller must be a signed-in admin.

export default async function handler(req, res) {
  try { return await run(req, res); }
  catch (e) { return res.status(500).json({ ok: false, error: 'excepcion', detail: String(e?.message || e).slice(0, 160) }); }
}

const emailOk = e => /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(e);

async function run(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ ok: false, error: 'method' });
  const { SUPABASE_URL: sbUrl, SUPABASE_SECRET_KEY: sbKey } = process.env;
  if (!sbUrl || !sbKey) return res.status(501).json({ ok: false, error: 'no_configurado' });
  const body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {});
  const H = { apikey: sbKey, Authorization: `Bearer ${sbKey}`, 'Content-Type': 'application/json' };
  const rest = (path, init = {}) => fetch(`${sbUrl}/rest/v1/${path}`, { ...init, headers: { ...H, ...(init.headers || {}) } });
  const adm = (path, init = {}) => fetch(`${sbUrl}/auth/v1/admin/${path}`, { ...init, headers: { ...H, ...(init.headers || {}) } });

  // Caller must be an admin
  const auth = req.headers.authorization || '';
  if (!auth.startsWith('Bearer ')) return res.status(401).json({ ok: false, error: 'no_sesion' });
  const u = await fetch(`${sbUrl}/auth/v1/user`, { headers: { apikey: sbKey, Authorization: auth } });
  if (!u.ok) return res.status(401).json({ ok: false, error: 'no_sesion' });
  const me = String((await u.json()).email || '').toLowerCase();
  const sr = await rest(`staff?select=email,admin&email=eq.${encodeURIComponent(me)}`);
  if (!sr.ok) return res.status(500).json({ ok: false, error: 'error_db', detail: (await sr.text()).slice(0, 160) });
  if (!(await sr.json())[0]?.admin) return res.status(403).json({ ok: false, error: 'solo_admin' });

  const email = String(body.email || '').trim().toLowerCase();
  const action = body.action;
  if (!emailOk(email)) return res.status(400).json({ ok: false, error: 'correo_invalido' });

  const findUser = async () => {
    for (let page = 1; page <= 20; page++) {
      const r = await adm(`users?page=${page}&per_page=200`);
      if (!r.ok) throw new Error('auth_list ' + r.status);
      const j = await r.json(); const list = j.users || [];
      const hit = list.find(x => String(x.email || '').toLowerCase() === email);
      if (hit || list.length < 200) return hit || null;
    }
    return null;
  };
  const admins = async () => (await (await rest('staff?select=email&admin=eq.true')).json()).map(x => x.email);

  if (action === 'create') {
    const password = String(body.password || '');
    if (password.length < 8) return res.status(400).json({ ok: false, error: 'contrasena_corta' });
    let user = await findUser(), created = false;
    if (!user) {
      const r = await adm('users', { method: 'POST', body: JSON.stringify({ email, password, email_confirm: true }) });
      const j = await r.json().catch(() => ({}));
      if (!r.ok) return res.status(400).json({ ok: false, error: 'auth', detail: j.msg || j.message || j.error_description || r.status });
      user = j; created = true;
    } else {
      const r = await adm(`users/${user.id}`, { method: 'PUT', body: JSON.stringify({ password, email_confirm: true }) });
      if (!r.ok) return res.status(400).json({ ok: false, error: 'auth', detail: (await r.text()).slice(0, 160) });
    }
    const s = await rest('staff?on_conflict=email', { method: 'POST', headers: { Prefer: 'resolution=merge-duplicates,return=minimal' },
      body: JSON.stringify({ email, nombre: String(body.nombre || '').trim().slice(0, 80), admin: !!body.admin }) });
    if (!s.ok) return res.status(500).json({ ok: false, error: 'error_db', detail: (await s.text()).slice(0, 160) });
    return res.status(200).json({ ok: true, created });
  }

  if (action === 'set_admin') {
    const val = !!body.admin;
    if (!val) { const a = await admins(); if (a.length <= 1 && a.includes(email)) return res.status(400).json({ ok: false, error: 'ultimo_admin' }); }
    const r = await rest(`staff?email=eq.${encodeURIComponent(email)}`, { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ admin: val }) });
    return res.status(r.ok ? 200 : 500).json({ ok: r.ok });
  }

  if (action === 'set_password') {
    const password = String(body.password || '');
    if (password.length < 8) return res.status(400).json({ ok: false, error: 'contrasena_corta' });
    const user = await findUser();
    if (!user) return res.status(404).json({ ok: false, error: 'usuario_no_existe' });
    const r = await adm(`users/${user.id}`, { method: 'PUT', body: JSON.stringify({ password }) });
    return res.status(r.ok ? 200 : 400).json({ ok: r.ok, error: r.ok ? undefined : 'auth', detail: r.ok ? undefined : (await r.text()).slice(0, 160) });
  }

  if (action === 'remove') {
    if (email === me) return res.status(400).json({ ok: false, error: 'no_a_ti_mismo' });
    const a = await admins(); if (a.length <= 1 && a.includes(email)) return res.status(400).json({ ok: false, error: 'ultimo_admin' });
    await rest(`staff?email=eq.${encodeURIComponent(email)}`, { method: 'DELETE', headers: { Prefer: 'return=minimal' } });
    const user = await findUser();
    if (user) await adm(`users/${user.id}`, { method: 'DELETE' });
    return res.status(200).json({ ok: true });
  }

  return res.status(400).json({ ok: false, error: 'accion_invalida' });
}
