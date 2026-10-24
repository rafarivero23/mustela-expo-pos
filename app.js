// Mustela Expo POS — v2 (Vercel + Supabase)
// Vendored locally (no CDN dependency on venue Wi-Fi). Rebuild: see README.
import { createClient } from './vendor/supabase-2.117.2.js';

const CFG = window.MUSTELA_CONFIG || {};
const $ = id => document.getElementById(id);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const money = n => new Intl.NumberFormat('es-MX',{style:'currency',currency:'MXN',maximumFractionDigits:2}).format(Number(n)||0);
const hhmm = iso => iso ? new Date(iso).toLocaleTimeString('es-MX',{hour:'2-digit',minute:'2-digit'}) : '';
const ago = iso => { if(!iso) return ''; const m = Math.floor((Date.now()-new Date(iso))/60000); return m<1?'ahora':m<60?`hace ${m} min`:`hace ${Math.floor(m/60)} h ${m%60} min`; };
const digits = s => String(s||'').replace(/\D/g,'');
const okMail = s => /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(s);

const VIEWS = ['inicio','login','tienda','comunidad','caja','surtido','inventario','corte','personal'];
const KIOSK = ['tienda','comunidad'];
const STAFF = ['caja','surtido','inventario','corte','personal'];
const SOLD = ['pagado','listo','entregado'];
const canSee = v => !STAFF.includes(v) || (S.perms||[]).includes(v);
const firstAllowed = () => ['caja','surtido','inventario','corte','personal'].find(v=>(S.perms||[]).includes(v)) || 'inicio';

const S = {
  view:'inicio', after:'caja',
  // kiosk (public)
  catalog:[], evento:'Expo', privacyUrl:'', kioskLoaded:false,
  cart:{}, cat:'Todos', step:'shop', busy:false,
  // staff
  session:null, isStaff:false, staffLoaded:false,
  products:[], orders:[], members:[], returns:[], resets:[], staff:[], pwFor:null, pwDraft:'', rmArm:null, retIdx:{}, retQty:{}, retMode:false, retMethod:null, avail:{}, cfg:{evento:'Expo', kiosk_pin:'2026', privacy_url:'', hold_minutes:30},
  sel:null, method:null, cancelArm:false, ticks:{}, invPending:false,
};

let sb = null;
if (CFG.SUPABASE_URL && CFG.SUPABASE_ANON_KEY && !/YOUR-/.test(CFG.SUPABASE_URL + CFG.SUPABASE_ANON_KEY)) {
  sb = createClient(CFG.SUPABASE_URL, CFG.SUPABASE_ANON_KEY, { auth: { persistSession:true, autoRefreshToken:true } });
}

let toastT;
function toast(msg){ const t=$('toast'); t.textContent=msg; t.hidden=false; clearTimeout(toastT); toastT=setTimeout(()=>t.hidden=true,3200); }

// Server error codes (raised in schema.sql) → Spanish copy
function errMsg(e){
  const m = String(e?.message || e || '');
  if (m.includes('devolucion_excede:')) return `No se pueden devolver más piezas de ${m.split('devolucion_excede:')[1]} de las que se vendieron.`;
  if (m.startsWith('sin_stock:')) return `Ya no hay suficientes piezas de ${m.slice(10)}. Ajusta el pedido.`;
  const map = {
    nombre_requerido:'Escribe tu nombre.', telefono_invalido:'Escribe tu celular a 10 dígitos.',
    correo_invalido:'Revisa el correo, parece incompleto.', correo_requerido:'Para unirte a la Comunidad necesitamos tu correo.',
    privacidad_requerida:'Para continuar acepta el aviso de privacidad.', pedido_vacio:'El pedido está vacío.',
    producto_no_disponible:'Un producto ya no está disponible. Revisa tu pedido.', cantidad_invalida:'Revisa las cantidades del pedido.',
    no_autorizado:'Tu usuario no tiene acceso de personal.', sin_permiso:'Tu usuario no tiene permiso para esta acción.', 'row-level security':'Tu usuario no tiene permiso para esta acción.', pedido_no_existe:'Ese pedido no existe.',
    pedido_ya_procesado:'Ese pedido ya fue procesado en otro dispositivo.', cambio_invalido:'Ese pedido cambió en otro dispositivo. Revisa la lista.',
    metodo_invalido:'Elige la forma de pago.', pedido_no_cobrado:'Solo se pueden devolver pedidos cobrados.', producto_no_en_pedido:'Ese producto no está en el pedido.', devolucion_vacia:'Marca al menos una pieza para devolver.', producto_con_ventas:'Este producto ya tiene pedidos y no se puede eliminar. Desmarca “Visible” para ocultarlo de la tienda.', producto_en_kit:'Este producto está dentro de un kit. Quítalo del kit primero.', kit_sin_nombre:'Escribe el nombre del kit.', kit_precio:'Escribe el precio final del kit.', kit_sin_productos:'Agrega al menos un producto al kit.', kit_producto_invalido:'Un producto del kit no es válido (no se puede meter un kit dentro de otro).', kit_no_existe:'Ese kit ya no existe.', kit_con_ventas:'Este kit ya tiene ventas y no se puede eliminar. Desmarca “Visible” para ocultarlo de la tienda.', sin_numeros:'No se pudo generar el número. Intenta de nuevo.',
  };
  for (const k in map) if (m.includes(k)) return map[k];
  if (e?.code==='PGRST202' || /Could not find the function|does not exist|schema cache/i.test(m)) return 'Falta correr la actualización de la base de datos (SQL) en Supabase. Avisa al administrador.';
  if (/fetch|network|Failed/i.test(m)) return 'Sin conexión. Revisa el internet e intenta de nuevo.';
  console.warn('Error no mapeado:', e);
  return `No se pudo guardar. Intenta de nuevo. (${String(e?.code||'')} ${m.slice(0,80)})`.replace(' ( )','');
}
async function rpc(fn, args){ const { data, error } = await sb.rpc(fn, args); if (error) throw error; return data; }

/* ---------- routing ---------- */
function go(v){
  if(!VIEWS.includes(v)) v='inicio';
  if(STAFF.includes(v) && !S.isStaff){ S.after=v; v='login'; }
  else if(STAFF.includes(v) && !canSee(v)){ toast('Tu usuario no tiene acceso a esa pantalla'); v=firstAllowed(); }
  S.view=v;
  try{ history.replaceState(null,'','#'+(v==='login'?S.after:v)); }catch(e){}
  for(const x of VIEWS) $('v-'+x).hidden = x!==v;
  const kiosk = KIOSK.includes(v);
  $('topbar').hidden = kiosk || v==='login';
  $('staffLink').hidden = !kiosk;
  document.querySelectorAll('#tabs .tab').forEach(b=>b.setAttribute('aria-current', String(b.dataset.go===v)));
  $('tabs').querySelectorAll('[data-go="caja"],[data-go="surtido"],[data-go="inventario"],[data-go="corte"],[data-go="personal"]').forEach(b=>b.hidden=!(S.isStaff&&canSee(b.dataset.go)));
  document.querySelectorAll('#v-inicio .ltile[data-go]').forEach(b=>b.hidden=STAFF.includes(b.dataset.go)&&S.isStaff&&!canSee(b.dataset.go));
  if(v==='tienda'){ resetKiosk(); loadKiosk(); }
  if(v==='comunidad'){ resetCommunity(); loadKiosk(); }
  if(STAFF.includes(v)) startStaff();
  if(v==='login'){ $('loginErr').hidden=true; setTimeout(()=>$('l-email').focus(),30); }
  renderAll();
  window.scrollTo(0,0);
}
document.addEventListener('click', e=>{ const g=e.target.closest('[data-go]'); if(!g) return; const v=g.dataset.go; if(KIOSK.includes(S.view) && !KIOSK.includes(v)) return askPin(v); go(v); });

/* ---------- kiosk PIN ---------- */
let pinTarget='inicio';
function askPin(target){ pinTarget=target; $('pin').hidden=false; $('pinErr').hidden=true; $('pinInput').value=''; setTimeout(()=>$('pinInput').focus(),30); }
$('staffLink').onclick=()=>askPin('inicio');
$('pinCancel').onclick=()=>$('pin').hidden=true;
$('pinForm').onsubmit=async e=>{
  e.preventDefault();
  let ok=false;
  try{ ok = await rpc('check_kiosk_pin',{ p_pin:$('pinInput').value }); }catch(ex){ $('pinErr').textContent=errMsg(ex); $('pinErr').hidden=false; return; }
  if(ok){ $('pin').hidden=true; go(pinTarget); } else { $('pinErr').textContent='PIN incorrecto. Intenta de nuevo.'; $('pinErr').hidden=false; }
};

/* ---------- auth ---------- */
async function refreshAuth(){
  if(!sb) return;
  const { data } = await sb.auth.getSession();
  S.session = data.session;
  S.isStaff = false;
  S.isAdmin = false;
  if(S.session){ try{ S.isStaff = !!(await rpc('is_staff')); }catch(e){ S.isStaff=false; } }
  S.perms=[];
  if(S.isStaff){ try{ const { data } = await sb.from('staff').select('admin,perms').eq('email', (S.session.user.email||'').toLowerCase()).maybeSingle();
      S.isAdmin = !!data?.admin; S.perms = data?.admin ? ['caja','surtido','inventario','corte','personal'] : (data?.perms||[]); }catch(e){ S.isAdmin=false; } }
  $('who').hidden = !S.session;
  $('whoEmail').textContent = S.session?.user?.email || '';
}
$('loginForm').onsubmit=async e=>{
  e.preventDefault();
  const err=m=>{ $('loginErr').textContent=m; $('loginErr').hidden=false; };
  if(!sb) return err('Falta configurar la conexión (config.js).');
  $('loginBtn').disabled=true;
  try{
    const { error } = await sb.auth.signInWithPassword({ email:$('l-email').value.trim(), password:$('l-pass').value });
    if(error) return err('Correo o contraseña incorrectos.');
    await refreshAuth();
    if(!S.isStaff){ await sb.auth.signOut(); await refreshAuth(); return err('Este usuario no está dado de alta como personal. Pide acceso al administrador.'); }
    $('l-pass').value='';
    go(canSee(S.after)?S.after:firstAllowed());
  } finally { $('loginBtn').disabled=false; }
};
$('loginBack').onclick=()=>go('inicio');
$('logout').onclick=async()=>{ stopStaff(); await sb.auth.signOut(); await refreshAuth(); go('inicio'); };

/* ============================ KIOSK ============================ */
let kioskPoll;
async function loadKiosk(){
  if(!sb) return;
  try{
    const k = await rpc('get_kiosk');
    S.catalog = (k.products||[]).map(p=>({...p, price:Number(p.price)||0, available:Number(p.available)||0}));
    S.evento = k.evento || 'Expo'; S.privacyUrl = k.privacy_url || ''; S.consejeras = Array.isArray(k.consejeras) ? k.consejeras : [];
    renderConsejeras();
    S.kioskLoaded = true; $('dbBanner').hidden=true;
  }catch(e){ $('dbBanner').hidden=false; }
  renderPrivacy();
  if(KIOSK.includes(S.view)) renderKiosk();
}
function startKioskPoll(){ clearInterval(kioskPoll); kioskPoll=setInterval(()=>{ if(KIOSK.includes(S.view) && S.step!=='done') loadKiosk(); },15000); }
function renderPrivacy(){
  document.querySelectorAll('.privlink').forEach(el=>{
    el.innerHTML = S.privacyUrl ? `<a href="${esc(S.privacyUrl)}" target="_blank" rel="noopener">aviso de privacidad</a>` : 'aviso de privacidad';
  });
}

function renderConsejeras(){
  const list=S.consejeras||[], sel=$('c-consejera'), cur=sel.value;
  $('c-conseWrap').hidden=!list.length;
  sel.innerHTML='<option value="">Selecciona…</option>'+list.map(n=>`<option${n===cur?' selected':''}>${esc(n)}</option>`).join('')+'<option value="">Nadie / no recuerdo</option>';
}
let idleT, doneI;
function bumpIdle(){ clearTimeout(idleT); if(S.view!=='tienda'||S.step==='done') return; if(!cartItems().length && S.step==='shop') return; idleT=setTimeout(()=>{ resetKiosk(); renderAll(); toast('Pedido reiniciado por inactividad'); },120000); }
['pointerdown','keydown'].forEach(ev=>document.addEventListener(ev,bumpIdle,true));

const catById = id => S.catalog.find(p=>p.id===id);
// Kit contents, e.g. "2× Crema 300 ml, 1× Gel" (mult = kits in the line)
const compsTxt = (comps, mult=1) => (comps||[]).map(c=>`${(c.qty||1)*mult}× ${c.name}${c.size?' '+c.size:''}`).join(', ');
const kitInc = (comps, mult=1) => comps?.length ? `<div class="kitinc">Incluye: ${esc(compsTxt(comps,mult))}</div>` : '';
const cartItems = () => Object.entries(S.cart).filter(([,q])=>q>0).map(([pid,qty])=>{const p=catById(pid);return p?{pid,name:p.name,size:p.size||'',price:p.price,qty,comps:p.kit?p.includes:null}:null}).filter(Boolean);
const cartTotal = () => cartItems().reduce((s,i)=>s+i.price*i.qty,0);

function resetKiosk(){
  S.cart={}; S.cat='Todos'; S.step='shop';
  $('k-form').reset(); $('c-join').checked=true; $('c-wa').checked=true; $('c-mail').checked=true; $('formErr').hidden=true; syncJoin();
  clearInterval(doneI); clearTimeout(idleT);
}
function setStep(st){ S.step=st; renderKiosk(); window.scrollTo(0,0); if(st==='shop') loadKiosk(); }

function renderKiosk(){
  $('k-shop').hidden=S.step!=='shop'; $('k-form').hidden=S.step!=='form'; $('k-done').hidden=S.step!=='done';
  const prods=S.catalog;
  const cats=['Todos',...new Set(prods.map(p=>p.category).filter(Boolean))];
  if(!cats.includes(S.cat)) S.cat='Todos';
  $('cats').innerHTML = cats.length>2 ? cats.map(c=>`<button class="chip" data-cat="${esc(c)}" aria-pressed="${c===S.cat}">${esc(c)}</button>`).join('') : '';
  const list=prods.filter(p=>S.cat==='Todos'||p.category===S.cat);
  if(!S.kioskLoaded) $('pgrid').innerHTML='<div class="empty">Cargando productos…</div>';
  else if(!list.length) $('pgrid').innerHTML='<div class="empty">Aún no hay productos. El personal puede agregarlos en Inventario.</div>';
  else { const hasImgs=S.catalog.some(p=>p.image_url); $('pgrid').innerHTML=list.map(p=>{
    const q=S.cart[p.id]||0, avail=p.available, out=avail<=0&&q===0, max=q>=avail;
    return `<div class="pcard${q?' in':''}${out?' out':''}">
      ${hasImgs?`<div class="pimg" style="background:${lineColor(p.category)}">${p.image_url?`<img src="${esc(p.image_url)}" alt="" loading="lazy" onerror="this.remove()">`:''}</div>`:''}
      <div class="pc-top">${p.category?`<span class="pc-line" style="background:${lineColor(p.category)}">${esc(p.category)}</span>`:'<span></span>'}<span>${esc(p.size||'')}</span></div>
      <h3>${esc(p.name)}</h3>${p.kit&&p.includes?.length?`<p class="pc-inc">Incluye: ${esc(compsTxt(p.includes))}</p>`:''}
      <div class="pc-bot"><span class="price num">${money(p.price)}</span>
      ${out?'<span class="pill p-cancel">Agotado</span>':
        q? `<div class="stepper"><button data-dec="${p.id}" aria-label="Quitar uno">−</button><span class="num">${q}</span><button class="add" data-inc="${p.id}" ${max?'disabled style="opacity:.4"':''} aria-label="Agregar uno">+</button></div>`
         : `<div class="stepper"><button class="add" data-inc="${p.id}" aria-label="Agregar ${esc(p.name)}">+</button></div>`}
      </div></div>`;}).join(''); }
  // drop cart lines for products that disappeared from the catalog
  for(const pid of Object.keys(S.cart)) if(S.kioskLoaded && !catById(pid)) delete S.cart[pid];
  const items=cartItems(), n=items.reduce((s,i)=>s+i.qty,0);
  $('cartbar').hidden = !(S.view==='tienda' && S.step==='shop' && n>0);
  document.body.classList.toggle('kiosk-cart', !$('cartbar').hidden);
  $('cbCount').textContent = `${n} ${n===1?'producto':'productos'}`;
  $('cbTotal').textContent = money(cartTotal());
  if(S.step==='form'){
    $('sumLines').innerHTML = items.map(i=>`<div class="line"><div class="nm"><b>${i.qty} ×</b> ${esc(i.name)} <span class="muted">${esc(i.size)}</span>${kitInc(i.comps)}</div><span class="num">${money(i.price*i.qty)}</span></div>`).join('');
    $('sumTotal').textContent = money(cartTotal());
  }
}
$('cats').onclick=e=>{const b=e.target.closest('[data-cat]'); if(!b) return; S.cat=b.dataset.cat; renderKiosk();};
$('pgrid').onclick=e=>{
  const inc=e.target.closest('[data-inc]'), dec=e.target.closest('[data-dec]');
  if(inc){ const id=inc.dataset.inc, a=catById(id)?.available??0; if((S.cart[id]||0)<a) S.cart[id]=(S.cart[id]||0)+1; else toast('No hay más piezas disponibles de este producto'); }
  else if(dec){ const id=dec.dataset.dec; S.cart[id]=Math.max(0,(S.cart[id]||0)-1); if(!S.cart[id]) delete S.cart[id]; }
  else return;
  renderKiosk(); bumpIdle();
};
$('cbClear').onclick=()=>{S.cart={}; renderKiosk();};
$('cbNext').onclick=()=>setStep('form');
$('backShop').onclick=()=>setStep('shop');
function syncJoin(){ const j=$('c-join').checked; $('c-joinFields').hidden=!j; $('c-privJoin').hidden=!j; }
$('c-join').onchange=syncJoin;

$('k-form').onsubmit=async e=>{
  e.preventDefault(); if(S.busy) return;
  const err=m=>{ $('formErr').textContent=m; $('formErr').hidden=false; };
  $('formErr').hidden=true;
  const nombre=$('c-nombre').value.trim(), apellido=$('c-apellido').value.trim(), tel=digits($('c-tel').value), email=$('c-email').value.trim(), join=$('c-join').checked;
  if(!nombre) return err('Escribe tu nombre.');
  if(tel.length!==10) return err('Escribe tu celular a 10 dígitos.');
  if(email && !okMail(email)) return err('Revisa tu correo, parece incompleto.');
  if(join && !email) return err('Para unirte a la Comunidad necesitamos tu correo.');
  if(!$('c-priv').checked) return err('Para continuar acepta el aviso de privacidad.');
  const items=cartItems(); if(!items.length) return err('Tu pedido está vacío.');
  if(!sb) return err('Sin conexión. Pide ayuda al personal.');
  S.busy=true; $('submitOrder').disabled=true;
  try{
    const res = await rpc('create_order',{
      p_items: items.map(i=>({pid:i.pid, qty:i.qty})),
      p_customer: { nombre, apellido, telefono:tel, email, privacidad:true, consejera:$('c-consejera').value, factura:$('c-factura').checked },
      p_community: join,
      p_member: { etapa:$('c-etapa').value, ciudad:$('c-ciudad').value.trim(), whatsapp:$('c-wa').checked, correo:$('c-mail').checked },
    });
    $('doneName').textContent=`¡Gracias, ${nombre}!`; $('doneCode').textContent=res.number; $('doneTotal').textContent=money(res.total);
    $('doneSms').hidden=true; sendSms(res.number).then(r=>{ if(r.ok){ $('doneSms').textContent=`Te enviamos un SMS al ${tel.slice(-4).padStart(10,'•')} con tu número de pedido.`; $('doneSms').hidden=false; } });
    setStep('done');
    let s=30; $('doneTimer').textContent=`Esta pantalla se reinicia en ${s} s`;
    doneI=setInterval(()=>{ s--; $('doneTimer').textContent=`Esta pantalla se reinicia en ${s} s`; if(s<=0){ clearInterval(doneI); resetKiosk(); setStep('shop'); } },1000);
  }catch(ex){ err(errMsg(ex)); loadKiosk(); }
  finally{ S.busy=false; $('submitOrder').disabled=false; }
};
$('newOrder').onclick=()=>{ resetKiosk(); setStep('shop'); };

/* SMS with the order number (Vercel function /api/sms → Twilio). Never blocks the order. */
async function sendSms(number, asStaff=false){
  try{
    const headers={'Content-Type':'application/json'};
    if(asStaff && S.session?.access_token) headers.Authorization='Bearer '+S.session.access_token;
    const r=await fetch('/api/sms',{ method:'POST', headers, body:JSON.stringify({ number }) });
    const j=await r.json().catch(()=>({}));
    return { ok:r.ok, status:r.status, ...j };
  }catch(e){ return { ok:false, error:'red' }; }
}

/* ---------- COMUNIDAD ---------- */
let mDoneT;
function resetCommunity(){ $('m-form').reset(); $('m-wa').checked=true; $('m-mail').checked=true; $('mErr').hidden=true; $('m-form').hidden=false; $('m-done').hidden=true; clearTimeout(mDoneT); }
$('m-form').onsubmit=async e=>{
  e.preventDefault(); if(S.busy) return;
  const err=m=>{ $('mErr').textContent=m; $('mErr').hidden=false; };
  $('mErr').hidden=true;
  const nombre=$('m-nombre').value.trim(), tel=digits($('m-tel').value), email=$('m-email').value.trim();
  const etapa=(document.querySelector('#m-etapa input:checked')||{}).value||'';
  if(!nombre) return err('Escribe tu nombre.');
  if(tel.length!==10) return err('Escribe tu celular a 10 dígitos.');
  if(!okMail(email)) return err('Escribe un correo válido.');
  if(!$('m-priv').checked) return err('Para registrarte acepta el aviso de privacidad.');
  if(!sb) return err('Sin conexión. Pide ayuda al personal.');
  S.busy=true; $('mSubmit').disabled=true;
  try{
    await rpc('join_community',{ p:{ nombre, apellido:$('m-apellido').value.trim(), telefono:tel, email, etapa, ciudad:$('m-ciudad').value.trim(), whatsapp:$('m-wa').checked, correo:$('m-mail').checked, privacidad:true } });
    $('mDoneName').textContent=`¡Bienvenida, ${nombre}!`;
    $('m-form').hidden=true; $('m-done').hidden=false; window.scrollTo(0,0);
    mDoneT=setTimeout(resetCommunity,12000);
  }catch(ex){ err(errMsg(ex)); }
  finally{ S.busy=false; $('mSubmit').disabled=false; }
};
$('mAgain').onclick=resetCommunity;

/* ============================ STAFF DATA ============================ */
const normOrder = o => ({ number:o.number, items:o.items||[], total:Number(o.total)||0, customer:o.customer||{}, community:o.community, status:o.status,
  consejera:o.consejera||'', factura:!!o.factura, smsCount:o.sms_count||0, smsStatus:o.sms_status||'', smsAt:o.sms_at, createdAt:o.created_at, paidAt:o.paid_at, payMethod:o.pay_method, paidBy:o.paid_by||'', payRef:o.pay_ref, readyAt:o.ready_at, deliveredAt:o.delivered_at, cancelledAt:o.cancelled_at });
const normProduct = p => ({ ...p, price:Number(p.price)||0, order:p.sort_order });
const normMember = m => ({ ...m, createdAt:m.created_at });

let channel=null, staffTick=null; const pending=new Set(); let flushT=null;
async function load(what){
  try{
    if(what==='products'){ const {data,error}=await sb.from('products').select('*').order('sort_order').order('name'); if(error) throw error; S.products=data.map(normProduct); }
    if(what==='orders'){ const {data,error}=await sb.from('orders').select('*').order('created_at',{ascending:false}).limit(2000); if(error) throw error; S.orders=data.map(normOrder); }
    if(what==='members'){ const {data,error}=await sb.from('members').select('*').order('created_at',{ascending:false}).limit(5000); if(error) throw error; S.members=data.map(normMember); }
    if(what==='returns'){ const {data,error}=await sb.from('returns').select('*').order('created_at').limit(5000); if(error) throw error; S.returns=data; indexReturns(); }
    if(what==='resets'){ const {data,error}=await sb.from('reset_log').select('*').order('created_at',{ascending:false}).limit(20); if(error) throw error; S.resets=data; }
    if(what==='staff'){ const {data,error}=await sb.from('staff').select('*').order('email'); if(error) throw error; S.staff=data; }
    if(what==='settings'){ const {data,error}=await sb.from('settings').select('*').eq('id',1).maybeSingle(); if(error) throw error; if(data) S.cfg=data; }
    if(what==='kits'){ const {data,error}=await sb.from('kit_items').select('*'); if(error){ S.kitItems={}; return; } const g={}; for(const r of data) (g[r.kit_id]||(g[r.kit_id]=[])).push({pid:r.product_id, qty:r.qty}); S.kitItems=g; }
    if(what==='avail'){ const data=await rpc('product_availability'); S.avail=Object.fromEntries(data.map(r=>[r.id,r])); }
    $('dbBanner').hidden=true;
  }catch(e){ $('dbBanner').hidden=false; }
}
function queue(...what){ what.forEach(w=>pending.add(w)); clearTimeout(flushT); flushT=setTimeout(flush,250); }
async function flush(){ const w=[...pending]; pending.clear(); await Promise.all(w.map(load)); renderAll(); }
async function startStaff(){
  if(channel || !S.isStaff) return;
  channel = sb.channel('staff')
    .on('postgres_changes',{event:'*',schema:'public',table:'orders'},()=>queue('orders','avail'))
    .on('postgres_changes',{event:'*',schema:'public',table:'products'},()=>queue('products','avail'))
    .on('postgres_changes',{event:'*',schema:'public',table:'kit_items'},()=>queue('kits','avail'))
    .on('postgres_changes',{event:'*',schema:'public',table:'members'},()=>queue('members'))
    .on('postgres_changes',{event:'*',schema:'public',table:'settings'},()=>queue('settings'))
    .on('postgres_changes',{event:'*',schema:'public',table:'returns'},()=>queue('returns','avail'))
    .on('postgres_changes',{event:'*',schema:'public',table:'reset_log'},()=>queue('resets'))
    .subscribe(st=>{ if(st==='SUBSCRIBED') queue('products','kits','orders','members','settings','returns','avail'); });
  await Promise.all(['products','kits','orders','members','settings','returns','avail','resets','staff'].map(load));
  S.staffLoaded=true; renderAll();
  // Safety net if realtime drops (venue Wi-Fi): full refresh every 30 s; also ages "hace X min".
  staffTick=setInterval(()=>{ if(STAFF.includes(S.view)) queue('orders','avail'); },30000);
}
function stopStaff(){ if(channel){ sb.removeChannel(channel); channel=null; } clearInterval(staffTick); S.staffLoaded=false; }

/* ---------- CAJA ---------- */
const STATUS={pendiente:['Por cobrar','p-pend'],pagado:['Por surtir','p-paid'],listo:['Listo','p-ready'],entregado:['Entregado','p-done'],cancelado:['Cancelado','p-cancel']};
const pill = st => `<span class="pill ${STATUS[st]?.[1]||''}">${STATUS[st]?.[0]||esc(st)}</span>`;
const fullName = c => [c?.nombre,c?.apellido].filter(Boolean).join(' ');

function retInfo(number){ return S.retIdx?.[number] || { qty:{}, amount:0, list:[] }; }
function indexReturns(){
  const idx={};
  for(const r of S.returns){ const x=idx[r.order_number]||(idx[r.order_number]={qty:{},amount:0,list:[]});
    x.amount+=Number(r.amount)||0; x.list.push(r); for(const i of r.items||[]) x.qty[i.pid]=(x.qty[i.pid]||0)+(i.qty||0); }
  S.retIdx=idx;
}
const netTotal = o => (o.total||0) - retInfo(o.number).amount;
const netUnits = o => (o.items||[]).reduce((a,i)=>a+i.qty,0) - Object.values(retInfo(o.number).qty).reduce((a,b)=>a+b,0);
function renderCaja(){
  const q=$('cajaSearch').value.trim().toLowerCase();
  const match=o=>!q||o.number.toLowerCase().includes(q)||fullName(o.customer).toLowerCase().includes(q);
  const pend=S.orders.filter(o=>o.status==='pendiente').sort((a,b)=>String(a.createdAt).localeCompare(String(b.createdAt)));
  const shown=pend.filter(match);
  $('pendCount').textContent=pend.length;
  const row=o=>`<button class="orow" data-sel="${esc(o.number)}" aria-pressed="${S.sel===o.number}"><span><span class="c">${esc(o.number)}</span><br><span class="muted" style="font-size:14px">${esc(fullName(o.customer))} · ${ago(o.createdAt)}${o.factura?' · <b>Factura</b>':''}</span></span><span class="num" style="font-weight:800">${money(o.total)}</span></button>`;
  $('pendList').innerHTML = !S.staffLoaded?'<div class="empty">Cargando…</div>':shown.length?shown.map(row).join(''):`<div class="empty">${q?'Sin pendientes con esa búsqueda':'No hay pedidos por cobrar.'}</div>`;
  let paid=S.orders.filter(o=>SOLD.includes(o.status)&&match(o)).sort((a,b)=>String(b.paidAt).localeCompare(String(a.paidAt)));
  if(!q) paid=paid.slice(0,15);
  if(q && paid.length) $('paidDetails').open=true;
  $('paidList').innerHTML = paid.length?paid.map(o=>{ const r=retInfo(o.number).amount; return `<button class="orow" data-sel="${esc(o.number)}" aria-pressed="${S.sel===o.number}"><span><span class="c">${esc(o.number)}</span><br><span class="muted" style="font-size:14px">${esc(fullName(o.customer))} · ${esc(o.payMethod||'')} · ${hhmm(o.paidAt)}${r?` · <b>Devuelto ${money(r)}</b>`:''}</span></span>${pill(o.status)}</button>`; }).join(''):`<div class="empty">${q?'Sin cobrados con esa búsqueda':'Aún no hay cobros.'}</div>`;
  renderCajaDetail();
}
function renderCajaDetail(){
  const o=S.orders.find(x=>x.number===S.sel);
  $('cajaEmpty').hidden=!!o; $('cajaDetail').hidden=!o;
  $('payPanel').hidden=!(o&&o.status==='pendiente');
  const sold=o&&SOLD.includes(o.status), ri=o?retInfo(o.number):null;
  const returnable=sold?(o.items||[]).some(i=>i.qty-(ri.qty[i.pid]||0)>0):false;
  if(!sold||!returnable) S.retMode=false;
  $('retOpen').hidden=!(sold&&returnable&&!S.retMode);
  $('retPanel').hidden=!(sold&&S.retMode);
  if(!o) return;
  if(document.activeElement?.id==='addPid'){ S.cajaPending=true; return; }
  const editable=o.status==='pendiente';
  const c=o.customer||{};
  const inOrder=Object.fromEntries((o.items||[]).map(i=>[i.pid,i.qty]));
  const addSel = editable ? `<div class="addline"><select id="addPid" aria-label="Agregar producto"><option value="">+ Agregar producto…</option>${[...S.products].filter(p=>p.active!==false).sort((a,b)=>(a.order??999)-(b.order??999)).map(p=>{ const left=(S.avail[p.id]?.free??0)-(inOrder[p.id]||0); return `<option value="${p.id}"${left<=0?' disabled':''}>${p.is_kit&&!/^kit/i.test(p.name)?'Kit · ':''}${esc(p.name)} ${esc(p.size||'')} · ${money(p.price)}${left<=0?' (sin stock)':''}</option>`; }).join('')}</select></div>` : '';
  const lineHtml=(i,ix)=>{
    const r=ri.qty[i.pid]||0, left=i.qty-r;
    if(editable){ const short=i.qty>(S.avail[i.pid]?.free??0);
      return `<div class="line"><div class="nm"><span class="mini-step"><button data-q="${ix}" data-d="-1" aria-label="Quitar">−</button><b class="num" style="min-width:24px;text-align:center">${i.qty}</b><button data-q="${ix}" data-d="1" aria-label="Agregar">+</button></span> ${esc(i.name)} <span class="muted">${esc(i.size||'')}</span>${short?' <span class="pill p-cancel">Sin stock</span>':''}${kitInc(i.comps,i.qty)}</div><span class="num">${money(i.price*i.qty)}</span></div>`; }
    const rq=S.retQty[i.pid]||0;
    const retCtl = S.retMode&&left>0 ? `<span class="mini-step" style="margin-left:8px"><button data-rq="${esc(i.pid)}" data-rd="-1" aria-label="Menos">−</button><b class="num" style="min-width:24px;text-align:center;color:var(--bad)">${rq}</b><button data-rq="${esc(i.pid)}" data-rd="1" data-max="${left}" aria-label="Más">+</button></span>` : '';
    return `<div class="line"><div class="nm"><b>${i.qty} ×</b> ${esc(i.name)} <span class="muted">${esc(i.size||'')}</span>${r?` <span class="pill p-cancel">${r} devuelto${r>1?'s':''}</span>`:''}${retCtl}${kitInc(i.comps,i.qty)}</div><span class="num">${money(i.price*i.qty)}</span></div>`;
  };
  const refunded=ri.amount;
  $('cajaDetail').innerHTML=`
    <div style="display:flex;justify-content:space-between;align-items:flex-start;gap:12px;flex-wrap:wrap">
      <div><p class="eyebrow" style="margin:0">Pedido · ${hhmm(o.createdAt)}</p><div class="code" style="font-size:64px">${esc(o.number)}</div></div>
      <div style="display:grid;gap:6px;justify-items:end">${pill(o.status)}${o.factura?'<span class="pill p-pend">Requiere factura</span>':''}</div>
    </div>
    <div><b>${esc(fullName(c))}</b><br><span class="muted">${esc(c.telefono||'')}${c.email?' · '+esc(c.email):''}</span>${o.community?'<br><span class="pill p-ready" style="margin-top:6px">Se unió a la Comunidad</span>':''}${o.consejera?`<br><span class="muted" style="font-size:14px">Atendió: <b>${esc(o.consejera)}</b></span>`:''}<br><span class="muted" style="font-size:14px">SMS: ${o.smsStatus?esc(o.smsStatus)+(o.smsAt?' · '+hhmm(o.smsAt):''):'no enviado'} <button type="button" class="linkbtn" data-sms="${esc(o.number)}" style="display:inline">${o.smsCount?'Reenviar SMS':'Enviar SMS'}</button></span></div>
    <div class="lines">${(o.items||[]).map(lineHtml).join('')}
      ${addSel}
      <div class="total num"><span>Total</span><span>${money(o.total)}</span></div>
      ${refunded?`<div class="line num" style="color:var(--bad);font-weight:700"><span>Reembolsado</span><span>−${money(refunded)}</span></div><div class="line num" style="font-weight:800;font-size:18px"><span>Neto</span><span>${money(o.total-refunded)}</span></div>`:''}
    </div>
    ${o.status==='cancelado'?`<p class="muted" style="margin:0">Cancelado ${hhmm(o.cancelledAt)}</p>`:o.status!=='pendiente'?`<p class="muted" style="margin:0">Cobrado ${hhmm(o.paidAt)} · ${esc(o.payMethod||'')}${o.payRef?' · Ref. '+esc(o.payRef):''}${o.paidBy?' · '+esc(o.paidBy):''}</p>`:''}
    ${ri.list.length?`<div class="rethist"><b>Devoluciones</b>${ri.list.map(r=>`<div>${hhmm(r.created_at)} · ${(r.items||[]).map(i=>`${i.qty}× ${esc(i.name)}`).join(', ')} · <b>${money(r.amount)}</b> por ${esc(r.method)}${r.reason?` · “${esc(r.reason)}”`:''}${r.created_by?` <span class="muted">(${esc(r.created_by)})</span>`:''}</div>`).join('')}</div>`:''}`;
  updateChange(); updateRet();
}
function updateRet(){
  const o=S.orders.find(x=>x.number===S.sel); if(!o||!S.retMode) return;
  const amt=(o.items||[]).reduce((a,i)=>a+(S.retQty[i.pid]||0)*i.price,0), n=Object.values(S.retQty).reduce((a,b)=>a+b,0);
  document.querySelectorAll('#retMethods button').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.rm===S.retMethod)));
  $('retGo').disabled=!(n>0&&S.retMethod);
  $('retGo').textContent = n>0 ? `Devolver ${n} pieza${n>1?'s':''} · reembolsar ${money(amt)}` : 'Devolver';
}
$('retStart').onclick=()=>{ const o=S.orders.find(x=>x.number===S.sel); S.retMode=true; S.retQty={}; S.retMethod=o?.payMethod||null; $('retReason').value=''; $('retErr').hidden=true; renderCajaDetail(); };
$('retCancel').onclick=()=>{ S.retMode=false; S.retQty={}; renderCajaDetail(); };
$('retMethods').onclick=e=>{ const b=e.target.closest('[data-rm]'); if(!b) return; S.retMethod=b.dataset.rm; updateRet(); };
$('retGo').onclick=async()=>{
  const o=S.orders.find(x=>x.number===S.sel); if(!o||S.busy) return;
  const items=Object.entries(S.retQty).filter(([,q])=>q>0).map(([pid,qty])=>({pid,qty})); if(!items.length) return;
  S.busy=true; $('retGo').disabled=true; $('retErr').hidden=true;
  try{
    const r=await rpc('return_items',{ p_number:o.number, p_items:items, p_method:S.retMethod, p_reason:$('retReason').value.trim() });
    toast(`Devolución registrada · reembolsar ${money(r.amount)} por ${S.retMethod}`);
    S.retMode=false; S.retQty={}; queue('returns','avail');
  }catch(ex){ $('retErr').textContent=errMsg(ex); $('retErr').hidden=false; }
  finally{ S.busy=false; updateRet(); }
};
$('cajaSearch').oninput=()=>{ renderCaja(); const v=$('cajaSearch').value.trim().toUpperCase(); const hit=S.orders.find(o=>o.number===v&&o.status!=='cancelado'); if(hit&&S.sel!==hit.number){ selectOrder(hit.number);} };
function selectOrder(n){ if(S.sel!==n){ S.sel=n; S.method=null; S.cancelArm=false; S.retMode=false; S.retQty={}; $('payRef').value=''; $('cashIn').value=''; $('payErr').hidden=true; syncMethods(); renderCancel(); } renderCaja(); }
['pendList','paidList'].forEach(id=>$(id).onclick=e=>{ const b=e.target.closest('[data-sel]'); if(b) selectOrder(b.dataset.sel); });
async function saveItems(o, next, okMsg, addedPid){
  S.busy=true;
  try{
    await rpc('update_order_items',{ p_number:o.number, p_items:next });
    await load('orders'); await load('avail'); renderAll();
    const now=S.orders.find(x=>x.number===o.number);
    if(addedPid && !now?.items.some(i=>i.pid===addedPid)) toast('No se agregó: falta correr la actualización de la base de datos (SQL) en Supabase.');
    else if(okMsg) toast(okMsg);
  }catch(ex){ toast(errMsg(ex)); } finally{ S.busy=false; }
}
$('cajaDetail').onclick=async e=>{
  const sm=e.target.closest('[data-sms]');
  if(sm){ sm.disabled=true; const r=await sendSms(sm.dataset.sms,true); sm.disabled=false;
    toast(r.ok?'SMS enviado':r.error==='sms_no_configurado'?`El SMS no está configurado. Falta en Vercel: ${(r.missing||[]).join(', ')||'(claves)'}`:r.error==='limite_sms'?'Ya se enviaron 5 SMS para este pedido.':({falta_sql_005:'Falta correr 005_sms.sql en Supabase.',clave_supabase_invalida:'SUPABASE_SECRET_KEY en Vercel no es válida (usa la Secret key sb_secret_…).',pedido_no_existe:'No se encontró el pedido.',no_permitido:'No autorizado: vuelve a iniciar sesión.',telefono_invalido:'El celular del pedido no tiene 10 dígitos.'})[r.error] || `No se pudo enviar el SMS (${r.error||r.status||'red'})${r.detail?': '+r.detail:''}`);
    queue('orders'); return; }
  const rb=e.target.closest('[data-rq]');
  if(rb){ const pid=rb.dataset.rq, cur=S.retQty[pid]||0, d=+rb.dataset.rd;
    const o=S.orders.find(x=>x.number===S.sel); const it=o?.items.find(i=>i.pid===pid); const max=it?it.qty-(retInfo(o.number).qty[pid]||0):0;
    S.retQty[pid]=Math.max(0,Math.min(max,cur+d)); renderCajaDetail(); return; }
  const b=e.target.closest('[data-q]'); if(!b||S.busy) return;
  const o=S.orders.find(x=>x.number===S.sel); if(!o||o.status!=='pendiente') return;
  const items=(o.items||[]).map(i=>({pid:i.pid, qty:i.qty})); const ix=+b.dataset.q; items[ix].qty+= +b.dataset.d;
  if(items[ix].qty>20){ toast('Máximo 20 piezas por producto'); return; }
  const next=items.filter(i=>i.qty>0); if(!next.length){ toast('Para quitar todo, cancela el pedido'); return; }
  saveItems(o,next);
};
$('cajaDetail').addEventListener('change',e=>{
  if(e.target.id!=='addPid') return;
  const pid=e.target.value; e.target.blur(); if(!pid||S.busy){ renderCajaDetail(); return; }
  const o=S.orders.find(x=>x.number===S.sel); if(!o||o.status!=='pendiente') return;
  const items=(o.items||[]).map(i=>({pid:i.pid, qty:i.qty})); const ex=items.find(i=>i.pid===pid);
  if(ex) ex.qty+=1; else items.push({pid, qty:1});
  saveItems(o,items,'Producto agregado',ex?null:pid);
});
$('cajaDetail').addEventListener('focusout',e=>{ if(e.target.id==='addPid'&&S.cajaPending){ S.cajaPending=false; setTimeout(renderCajaDetail,0); } });
function syncMethods(){ document.querySelectorAll('#methods button').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.m===S.method))); $('cashWrap').hidden=S.method!=='Efectivo'; $('refWrap').hidden=S.method==='Efectivo'; $('payBtn').disabled=!S.method; updateChange(); }
$('methods').onclick=e=>{ const b=e.target.closest('[data-m]'); if(!b) return; S.method=b.dataset.m; syncMethods(); if(S.method==='Efectivo') $('cashIn').focus(); };
function updateChange(){ const o=S.orders.find(x=>x.number===S.sel); const v=parseFloat(String($('cashIn').value).replace(/[^0-9.]/g,'')); const show=S.method==='Efectivo'&&o&&!isNaN(v); $('change').hidden=!show; if(show){ const d=v-o.total; $('change').textContent= d>=0?`Cambio: ${money(d)}`:`Faltan ${money(-d)}`; $('change').style.color=d>=0?'var(--ok)':'var(--bad)'; } }
$('cashIn').oninput=updateChange;
function renderCancel(){ $('cancelArea').innerHTML = S.cancelArm ? `<span style="display:inline-flex;gap:8px;align-items:center;flex-wrap:wrap"><span class="muted">¿Cancelar este pedido?</span><button type="button" class="btn danger sm" id="cancelYes">Sí, cancelar</button><button type="button" class="btn ghost sm" id="cancelNo">No</button></span>` : `<button type="button" class="btn danger" id="cancelBtn">Cancelar pedido</button>`; }
$('cancelArea').onclick=async e=>{
  if(e.target.id==='cancelBtn'){ S.cancelArm=true; renderCancel(); }
  else if(e.target.id==='cancelNo'){ S.cancelArm=false; renderCancel(); }
  else if(e.target.id==='cancelYes'){ const n=S.sel; S.cancelArm=false; renderCancel(); try{ await rpc('set_order_status',{p_number:n,p_status:'cancelado'}); toast(`Pedido ${n} cancelado`); S.sel=null; queue('orders','avail'); }catch(ex){ toast(errMsg(ex)); } }
};
$('payBtn').onclick=async()=>{
  const o=S.orders.find(x=>x.number===S.sel); if(!o||!S.method||S.busy) return;
  const err=m=>{ $('payErr').textContent=m; $('payErr').hidden=false; };
  $('payErr').hidden=true;
  if(S.method==='Efectivo'){ const v=parseFloat(String($('cashIn').value).replace(/[^0-9.]/g,'')); if(!isNaN(v)&&v<o.total) return err('El efectivo recibido no cubre el total.'); }
  S.busy=true; $('payBtn').disabled=true;
  try{
    const ref = S.method==='Efectivo' ? ($('cashIn').value?'Recibido '+$('cashIn').value:'') : $('payRef').value.trim();
    await rpc('mark_paid',{ p_number:o.number, p_method:S.method, p_ref:ref });
    toast(`${o.number} cobrado · enviado a surtido`);
    S.sel=null; S.method=null; $('cajaSearch').value=''; syncMethods(); queue('orders','avail'); renderCaja(); $('cajaSearch').focus();
  }catch(ex){ err(errMsg(ex)); }
  finally{ S.busy=false; $('payBtn').disabled=!S.method; }
};

/* ---------- SURTIDO ---------- */
function renderSurtido(){
  const paid=S.orders.filter(o=>o.status==='pagado').sort((a,b)=>String(a.paidAt).localeCompare(String(b.paidAt)));
  const ready=S.orders.filter(o=>o.status==='listo').sort((a,b)=>String(a.readyAt).localeCompare(String(b.readyAt)));
  $('cntPaid').textContent=paid.length; $('cntReady').textContent=ready.length;
  const done=S.orders.filter(o=>o.status==='entregado').length; $('cntDone').textContent= done?`${done} pedidos entregados.`:'';
  const card=(o,mode)=>`<div class="ticket"><div class="th"><span class="c">${esc(o.number)}</span><span class="muted" style="font-size:14px">${mode==='paid'?'Pagado '+ago(o.paidAt):'Listo '+ago(o.readyAt)}</span></div>
    <div><b>${esc(fullName(o.customer))}</b>${o.consejera?`<br><span class="muted" style="font-size:14px">Dermo-Consejera: <b>${esc(o.consejera)}</b></span>`:''}</div>
    <ul>${(o.items||[]).map((i,ix)=>{const k=o.number+':'+ix; const rq=retInfo(o.number).qty[i.pid]||0, nq=i.qty-rq; if(nq<=0) return ''; return mode==='paid'?`<li><label><input type="checkbox" data-tick="${esc(k)}" ${S.ticks[k]?'checked':''}><span class="q num">${nq}×</span><span>${esc(i.name)} <span class="muted">${esc(i.size||'')}</span>${kitInc(i.comps,nq)}</span></label></li>`:`<li><span class="q num">${nq}×</span> ${esc(i.name)} <span class="muted">${esc(i.size||'')}</span>${kitInc(i.comps,nq)}</li>`;}).join('')}</ul>
    ${mode==='paid'?`<button class="btn primary" data-ready="${esc(o.number)}">Listo para entregar</button>`:`<div style="display:flex;gap:8px;flex-wrap:wrap"><button class="btn ok" data-deliver="${esc(o.number)}">Entregado</button><button class="btn ghost sm" data-back="${esc(o.number)}">Regresar a surtir</button></div>`}</div>`;
  $('colPaid').innerHTML=paid.length?paid.map(o=>card(o,'paid')).join(''):'<div class="panel empty">Nada por surtir.</div>';
  $('colReady').innerHTML=ready.length?ready.map(o=>card(o,'ready')).join(''):'<div class="panel empty">Nada pendiente de entrega.</div>';
}
$('v-surtido').onclick=async e=>{
  const t=e.target.closest('[data-tick]'); if(t){ S.ticks[t.dataset.tick]=t.checked; return; }
  const r=e.target.closest('[data-ready],[data-deliver],[data-back]'); if(!r||S.busy) return;
  const n=r.dataset.ready||r.dataset.deliver||r.dataset.back;
  const st=r.dataset.ready?'listo':r.dataset.deliver?'entregado':'pagado';
  S.busy=true; r.disabled=true;
  try{ await rpc('set_order_status',{p_number:n,p_status:st}); queue('orders'); }catch(ex){ toast(errMsg(ex)); r.disabled=false; } finally{ S.busy=false; }
};

/* ---------- INVENTARIO ---------- */
function renderInv(){
  const paid=S.orders.filter(o=>SOLD.includes(o.status));
  const sales=paid.reduce((s,o)=>s+netTotal(o),0), units=paid.reduce((s,o)=>s+netUnits(o),0), refunds=S.returns.reduce((s,r)=>s+(Number(r.amount)||0),0);
  const pend=S.orders.filter(o=>o.status==='pendiente').length;
  $('tiles').innerHTML=[['Ventas cobradas',money(sales)],['Pedidos cobrados',paid.length],['Ticket promedio',money(paid.length?sales/paid.length:0)],['Piezas vendidas',units],['Por cobrar',pend],['Devoluciones',money(refunds)],['Registros Comunidad',S.staffLoaded?S.members.length:'…']]
    .map(([k,v])=>`<div class="tile"><span class="eyebrow">${k}</span><b class="num">${v}</b></div>`).join('');
  $('sampleNote').hidden=!S.products.some(p=>p.sample);
  renderKits();
  $('catList').innerHTML=[...new Set(S.products.map(p=>p.category).filter(Boolean))].map(c=>`<option value="${esc(c)}">`).join('');
  if($('invWrap').contains(document.activeElement)){ S.invPending=true; }
  else {
    S.invPending=false;
    const rows=physProducts().sort((a,b)=>(a.order??999)-(b.order??999)||String(a.name).localeCompare(b.name));
    $('invBody').innerHTML=rows.length?rows.map(p=>{const i=S.avail[p.id]||{sold:0,held:0,available:0}; return `<tr>
      <td><div class="thumbcell"><div class="thumb">${p.image_url?`<img src="${esc(p.image_url)}" alt="">`:'<span class="muted" style="font-size:12px">—</span>'}</div>
        <div class="thumbbtns"><label class="linkbtn">${p.image_url?'Cambiar':'Subir'}<input class="vh" type="file" accept="image/*" data-img="${p.id}"></label>${p.image_url?`<button type="button" class="linkbtn rm" data-rmimg="${p.id}">Quitar</button>`:''}</div></div></td>
      <td><input data-f="name" data-id="${p.id}" value="${esc(p.name)}" aria-label="Nombre">${p.sample?' <span class="pill p-pend" style="margin-top:4px">Ejemplo</span>':''}</td>
      <td><input data-f="codigo" data-id="${p.id}" value="${esc(p.codigo||'')}" aria-label="Código" style="width:110px"></td>
      <td><input data-f="sku" data-id="${p.id}" value="${esc(p.sku||'')}" aria-label="SKU" style="width:140px"></td>
      <td><input data-f="category" data-id="${p.id}" value="${esc(p.category||'')}" aria-label="Línea" style="min-width:120px"></td>
      <td><input data-f="size" data-id="${p.id}" value="${esc(p.size||'')}" aria-label="Tamaño" style="width:90px"></td>
      <td class="r"><input class="n num" data-f="price" data-id="${p.id}" value="${esc(p.price)}" inputmode="decimal" aria-label="Precio"></td>
      <td class="r"><input class="n num" data-f="stock" data-id="${p.id}" value="${esc(p.stock)}" inputmode="numeric" aria-label="Inventario inicial"></td>
      <td class="r"><input class="n num" data-f="restock" data-id="${p.id}" value="${esc(p.restock||0)}" inputmode="numeric" aria-label="Resurtido"></td>
      <td class="r num">${i.sold}</td><td class="r num">${i.held}</td>
      <td class="r num ${i.available<=3?'lowstock':''}">${i.available}</td>
      <td><input type="checkbox" data-f="active" data-id="${p.id}" ${p.active!==false?'checked':''} aria-label="Visible en tienda"></td>
      <td><button type="button" class="linkbtn rm" data-pdel="${p.id}" style="display:inline;white-space:nowrap">${S.prodDelArm===p.id?'¿Seguro? Toca otra vez':'Eliminar'}</button></td></tr>`;}).join('')
      :`<tr><td colspan="14" class="empty">${S.staffLoaded?'Sin productos. Agrega el primero abajo.':'Cargando…'}</td></tr>`;
  }
  const byC={}; for(const o of paid){ const k=o.consejera||'Sin consejera'; const r=byC[k]||(byC[k]={n:0,u:0,t:0}); r.n++; r.t+=netTotal(o); r.u+=netUnits(o); }
  const cr=Object.entries(byC).sort((a,b)=>b[1].t-a[1].t);
  $('conseBody').innerHTML=cr.length?cr.map(([k,r])=>`<tr><td>${esc(k)}</td><td class="r num">${r.n}</td><td class="r num">${r.u}</td><td class="r num">${money(r.t)}</td></tr>`).join(''):'<tr><td colspan="4" class="empty">Aún no hay ventas cobradas.</td></tr>';
  const ms=S.members.slice(0,25);
  $('memBody').innerHTML=ms.length?ms.map(m=>`<tr><td class="num">${hhmm(m.createdAt)}</td><td>${esc([m.nombre,m.apellido].filter(Boolean).join(' '))}</td><td class="num">${esc(m.telefono)}</td><td>${esc(m.email)}</td><td>${esc(m.etapa)}</td><td>${esc(m.ciudad)}</td><td>${esc(m.origen)}</td></tr>`).join(''):'<tr><td colspan="7" class="empty">Aún no hay registros.</td></tr>';
  if(document.activeElement?.closest?.('#cfgForm')==null){ $('cfg-event').value=S.cfg.evento||''; $('cfg-pin').value=S.cfg.kiosk_pin||''; $('cfg-priv').value=S.cfg.privacy_url||''; $('cfg-hold').value=S.cfg.hold_minutes??30; $('cfg-consejeras').value=(S.cfg.consejeras||[]).join('\n'); }
}
$('invWrap').addEventListener('focusout',()=>setTimeout(()=>{ if(S.invPending && !$('invWrap').contains(document.activeElement)) renderInv(); },0));
/* product photos → Supabase Storage (bucket product-images, staff-only writes) */
const BUCKET='product-images';
async function shrink(file, max=900){
  const bmp = await createImageBitmap(file);
  const k = Math.min(1, max/Math.max(bmp.width,bmp.height));
  const c = document.createElement('canvas'); c.width=Math.round(bmp.width*k); c.height=Math.round(bmp.height*k);
  const draw = bg => { const x=c.getContext('2d'); x.clearRect(0,0,c.width,c.height); if(bg){ x.fillStyle='#fff'; x.fillRect(0,0,c.width,c.height); } x.drawImage(bmp,0,0,c.width,c.height); };
  const toBlob = (t,q) => new Promise(r=>c.toBlob(r,t,q));
  draw(false); let b = await toBlob('image/webp',0.85);
  if(!b || b.type!=='image/webp'){ draw(true); b = await toBlob('image/jpeg',0.85); }
  return b;
}
const storagePath = url => { const m=String(url||'').split('/'+BUCKET+'/'); return m.length>1 ? decodeURIComponent(m[1].split('?')[0]) : null; };
async function uploadImage(id, file){
  if(!file) return;
  if(!/^image\//.test(file.type)) return toast('Elige un archivo de imagen');
  toast('Subiendo foto…');
  try{
    const blob = await shrink(file);
    if(blob.size > 2*1024*1024) return toast('La foto es muy pesada (máx. 2 MB)');
    const ext = blob.type==='image/webp'?'webp':'jpg';
    const path = `${id}/${Date.now()}.${ext}`;
    const up = await sb.storage.from(BUCKET).upload(path, blob, { contentType:blob.type, cacheControl:'31536000', upsert:false });
    if(up.error) throw up.error;
    const url = sb.storage.from(BUCKET).getPublicUrl(path).data.publicUrl;
    const old = storagePath(S.products.find(p=>p.id===id)?.image_url);
    const { error } = await sb.from('products').update({ image_url:url }).eq('id',id);
    if(error) throw error;
    if(old) sb.storage.from(BUCKET).remove([old]);
    toast('Foto guardada'); queue('products');
  }catch(ex){ toast('No se pudo subir la foto. Revisa la conexión.'); }
}
$('invWrap').addEventListener('click',async e=>{
  const b=e.target.closest('[data-pdel]'); if(!b) return;
  const id=b.dataset.pdel;
  if(S.prodDelArm!==id){ S.prodDelArm=id; b.textContent='¿Seguro? Toca otra vez'; return; }
  S.prodDelArm=null; b.disabled=true;
  try{ const old=storagePath(S.products.find(p=>p.id===id)?.image_url);
    await rpc('delete_product',{ p_id:id }); if(old) sb.storage.from(BUCKET).remove([old]);
    toast('Producto eliminado'); queue('products','avail');
  }catch(ex){ toast(errMsg(ex)); b.disabled=false; b.textContent='Eliminar'; }
});
const onImgClick=async e=>{
  const b=e.target.closest('[data-rmimg]'); if(!b) return; b.blur();
  const id=b.dataset.rmimg, old=storagePath(S.products.find(p=>p.id===id)?.image_url);
  const { error } = await sb.from('products').update({ image_url:'' }).eq('id',id);
  if(error) return toast(errMsg(error));
  if(old) sb.storage.from(BUCKET).remove([old]);
  toast('Foto quitada'); queue('products');
};
['invWrap','kitWrap'].forEach(id=>$(id).addEventListener('click',onImgClick));
const onInvChange=async e=>{
  const el=e.target;
  if(el.dataset.img){ const f=el.files?.[0]; el.value=''; el.blur(); return uploadImage(el.dataset.img, f); } const id=el.dataset.id, f=el.dataset.f; if(!id||!f) return;
  let v = f==='active'?el.checked : el.value.trim();
  if(f==='price'||f==='stock'||f==='restock'){ v=Number(String(v).replace(/[^0-9.]/g,'')); if(isNaN(v)||v<0){ toast('Escribe un número válido'); return; } if(f!=='price') v=Math.round(v); }
  if(f==='name'&&!v){ toast('El nombre no puede quedar vacío'); return; }
  const patch={[f]:v}; if(f!=='active') patch.sample=false;
  const { error } = await sb.from('products').update(patch).eq('id',id);
  if(error) toast(errMsg(error)); else { toast('Guardado'); queue('products','avail'); }
};
['invWrap','kitWrap'].forEach(id=>$(id).addEventListener('change',onInvChange));
$('addForm').onsubmit=async e=>{
  e.preventDefault(); const name=$('a-name').value.trim(), price=Number($('a-price').value.replace(/[^0-9.]/g,'')), stock=Math.round(Number($('a-stock').value.replace(/[^0-9]/g,''))||0);
  if(!name) return toast('Escribe el nombre del producto'); if(!(price>0)) return toast('Escribe el precio');
  const { error } = await sb.from('products').insert({ name, codigo:$('a-codigo').value.trim(), sku:$('a-sku').value.trim(), category:$('a-cat').value.trim(), size:$('a-size').value.trim(), price, stock, active:true, sort_order:S.products.length+1, sample:false });
  if(error) toast(errMsg(error)); else { $('addForm').reset(); toast('Producto agregado'); queue('products','avail'); }
};
/* ---------- KITS (products with is_kit + kit_items; selling a kit deducts its components) ---------- */
const physProducts = () => S.products.filter(p=>!p.is_kit);
const kitComps = id => (S.kitItems?.[id]||[]).map(c=>({ ...c, p:S.products.find(p=>p.id===c.pid) })).filter(c=>c.p);
const newKit = () => ({ id:null, items:[] });
function renderKits(){
  if(!S.kitEdit) S.kitEdit=newKit();
  const kits=S.products.filter(p=>p.is_kit).sort((a,b)=>(a.order??999)-(b.order??999)||String(a.name).localeCompare(b.name));
  $('kitBody').innerHTML = kits.length ? kits.map(k=>{ const i=S.avail[k.id]||{sold:0,held:0,available:0}, cs=kitComps(k.id);
    const limit=cs.length?cs.reduce((m,c)=>{ const a=Math.floor(Math.max(0,S.avail[c.pid]?.available??0)/c.qty); return a<m.a?{a,n:c.p.name}:m; },{a:Infinity,n:''}).n:'';
    return `<tr${S.kitEdit.id===k.id?' class="editing"':''}>
      <td><div class="thumbcell"><div class="thumb">${k.image_url?`<img src="${esc(k.image_url)}" alt="">`:'<span class="muted" style="font-size:12px">—</span>'}</div>
        <div class="thumbbtns"><label class="linkbtn">${k.image_url?'Cambiar':'Subir'}<input class="vh" type="file" accept="image/*" data-img="${k.id}"></label>${k.image_url?`<button type="button" class="linkbtn rm" data-rmimg="${k.id}">Quitar</button>`:''}</div></div></td>
      <td><b>${esc(k.name)}</b>${k.size?` <span class="muted">${esc(k.size)}</span>`:''}</td>
      <td style="font-size:14px">${cs.length?cs.map(c=>`${c.qty}× ${esc(c.p.name)}${c.p.size?` <span class="muted">${esc(c.p.size)}</span>`:''}`).join('<br>'):'<span class="pill p-cancel">Sin productos</span>'}</td>
      <td class="r num">${money(k.price)}</td><td class="r num">${i.sold}</td><td class="r num">${i.held}</td>
      <td class="r num ${i.available<=3?'lowstock':''}" title="${limit?'Lo limita: '+esc(limit):''}">${i.available}</td>
      <td><input type="checkbox" data-f="active" data-id="${k.id}" ${k.active!==false?'checked':''} aria-label="Visible en tienda"></td>
      <td style="white-space:nowrap"><button type="button" class="linkbtn" data-kedit="${k.id}" style="display:inline;margin-right:12px">Editar</button><button type="button" class="linkbtn rm" data-kdel="${k.id}" style="display:inline">${S.kitDelArm===k.id?'¿Seguro? Toca otra vez':'Eliminar'}</button></td></tr>`; }).join('')
    : `<tr><td colspan="9" class="empty">${S.staffLoaded?'Aún no hay kits. Crea el primero abajo.':'Cargando…'}</td></tr>`;
  renderKitForm();
}
function renderKitForm(){
  const ke=S.kitEdit, byId=Object.fromEntries(S.products.map(p=>[p.id,p]));
  $('kitTitle').textContent = ke.id ? 'Editar kit' : 'Nuevo kit';
  $('k-save').textContent = ke.id ? 'Guardar cambios' : 'Crear kit';
  $('k-cancel').hidden = !ke.id;
  $('k-items').innerHTML = ke.items.length ? ke.items.map((c,ix)=>{ const p=byId[c.pid]; return `<div class="line"><div class="nm"><span class="mini-step"><button type="button" data-kq="${ix}" data-d="-1" aria-label="Menos">−</button><b class="num" style="min-width:24px;text-align:center">${c.qty}</b><button type="button" data-kq="${ix}" data-d="1" aria-label="Más">+</button></span> ${esc(p?.name||'(producto borrado)')} <span class="muted">${esc(p?.size||'')}</span></div><span class="num">${money((p?.price||0)*c.qty)} <button type="button" class="linkbtn rm" data-krm="${ix}" style="display:inline;margin-left:8px">Quitar</button></span></div>`; }).join('')
    : '<p class="muted" style="margin:0">Agrega los productos que lleva el kit.</p>';
  if(document.activeElement?.id!=='k-add'){
    const inKit=new Set(ke.items.map(c=>c.pid));
    $('k-add').innerHTML='<option value="">+ Agregar producto al kit…</option>'+physProducts().filter(p=>!inKit.has(p.id)).sort((a,b)=>(a.order??999)-(b.order??999)||String(a.name).localeCompare(b.name))
      .map(p=>`<option value="${p.id}">${esc(p.name)} ${esc(p.size||'')} · ${money(p.price)}${p.active===false?' (oculto)':''}</option>`).join('');
  }
  const sep=ke.items.reduce((a,c)=>a+(byId[c.pid]?.price||0)*c.qty,0), price=Number(String($('k-price').value).replace(/[^0-9.]/g,''));
  $('k-sum').textContent = ke.items.length ? `${ke.items.reduce((a,c)=>a+c.qty,0)} piezas · por separado ${money(sep)}${price>0&&price<sep?` · ahorro ${money(sep-price)}`:''}` : '';
}
function editKit(id){
  const k=S.products.find(p=>p.id===id); if(!k) return;
  S.kitEdit={ id, items:(S.kitItems?.[id]||[]).map(c=>({...c})) };
  $('k-name').value=k.name; $('k-price').value=k.price; $('k-size').value=k.size||'';
  renderKits(); $('kitForm').scrollIntoView({behavior:'smooth',block:'start'});
}
function resetKitForm(){ S.kitEdit=newKit(); $('kitForm').reset(); renderKits(); }
$('kitWrap').addEventListener('click',async e=>{
  const ed=e.target.closest('[data-kedit]'); if(ed) return editKit(ed.dataset.kedit);
  const del=e.target.closest('[data-kdel]'); if(!del) return;
  const id=del.dataset.kdel;
  if(S.kitDelArm!==id){ S.kitDelArm=id; renderKits(); return; }
  S.kitDelArm=null;
  try{ const old=storagePath(S.products.find(p=>p.id===id)?.image_url);
    await rpc('delete_kit',{ p_id:id }); if(old) sb.storage.from(BUCKET).remove([old]);
    if(S.kitEdit.id===id) resetKitForm(); toast('Kit eliminado'); queue('products','kits','avail');
  }catch(ex){ toast(errMsg(ex)); renderKits(); }
});
$('k-items').onclick=e=>{
  const ke=S.kitEdit, q=e.target.closest('[data-kq]'), rm=e.target.closest('[data-krm]');
  if(q){ const c=ke.items[+q.dataset.kq]; c.qty=Math.max(1,Math.min(20,c.qty+ +q.dataset.d)); }
  else if(rm) ke.items.splice(+rm.dataset.krm,1); else return;
  renderKitForm();
};
$('k-add').onchange=e=>{ const pid=e.target.value; e.target.blur(); if(pid && !S.kitEdit.items.some(c=>c.pid===pid)) S.kitEdit.items.push({pid,qty:1}); renderKitForm(); };
$('k-price').oninput=renderKitForm;
$('k-cancel').onclick=resetKitForm;
$('kitForm').onsubmit=async e=>{
  e.preventDefault(); if(S.busy) return;
  const ke=S.kitEdit, name=$('k-name').value.trim(), price=Number(String($('k-price').value).replace(/[^0-9.]/g,''));
  if(!name) return toast('Escribe el nombre del kit'); if(!(price>0)) return toast('Escribe el precio final del kit');
  if(!ke.items.length) return toast('Agrega al menos un producto al kit');
  S.busy=true; $('k-save').disabled=true;
  try{
    const cur=ke.id?S.products.find(p=>p.id===ke.id):null;
    await rpc('save_kit',{ p:{ id:ke.id, name, price, size:$('k-size').value.trim(), category:cur?.category||'Kits', items:ke.items } });
    toast(ke.id?'Kit actualizado':'Kit creado'); resetKitForm(); queue('products','kits','avail');
  }catch(ex){ toast(errMsg(ex)); }
  finally{ S.busy=false; $('k-save').disabled=false; }
};
$('cfgForm').onsubmit=async e=>{
  e.preventDefault();
  const pin=digits($('cfg-pin').value); if(pin.length<4||pin.length>8) return toast('El PIN debe tener de 4 a 8 dígitos');
  const hold=Math.round(Number($('cfg-hold').value)); if(!(hold>=5&&hold<=1440)) return toast('Minutos de apartado: entre 5 y 1440');
  const url=$('cfg-priv').value.trim(); if(url && !/^https?:\/\//i.test(url)) return toast('La liga debe empezar con https://');
  const consejeras=[...new Set($('cfg-consejeras').value.split(/\r?\n/).map(x=>x.trim().slice(0,60)).filter(Boolean))].slice(0,60);
  const { error } = await sb.from('settings').update({ evento:$('cfg-event').value.trim()||'Expo', kiosk_pin:pin, privacy_url:url, hold_minutes:hold, consejeras }).eq('id',1);
  if(error) toast(errMsg(error)); else { toast('Ajustes guardados'); queue('settings','avail'); }
};

/* CSV (UTF-8 with BOM so Excel keeps accents) */
const csv = rows => '﻿'+rows.map(r=>r.map(v=>{const s=String(v??''); return /[",\n;]/.test(s)?'"'+s.replace(/"/g,'""')+'"':s;}).join(',')).join('\r\n');
function save(filename,text){
  const url=URL.createObjectURL(new Blob([text],{type:'text/csv;charset=utf-8'}));
  const a=document.createElement('a'); a.href=url; a.download=filename; document.body.appendChild(a); a.click(); a.remove();
  setTimeout(()=>URL.revokeObjectURL(url),2000); $('expNote').textContent=`${filename} listo.`;
}
const stamp=()=>new Date().toISOString().slice(0,10);
$('expOrders').onclick=async()=>{ await Promise.all([load('orders'),load('returns')]);
  const rows=[['Pedido','Estado','Creado','Cobrado','Forma de pago','Referencia','Nombre','Apellido','Celular','Correo','Comunidad','Dermo-Consejera','Factura','Producto','Tamaño','Cantidad','Devuelto','Precio','Subtotal','Total pedido','Reembolso pedido','Neto pedido','Contenido del kit']];
  for(const o of [...S.orders].sort((a,b)=>String(a.createdAt).localeCompare(String(b.createdAt)))) for(const i of o.items||[]) rows.push([o.number,(STATUS[o.status]?.[0]||o.status)+(retInfo(o.number).amount?(netUnits(o)<=0?' · Devuelto total':' · Con devolución'):''),o.createdAt,o.paidAt||'',o.payMethod||'',o.payRef||'',o.customer?.nombre,o.customer?.apellido,o.customer?.telefono,o.customer?.email,o.community?'Sí':'No',o.consejera||'',o.factura?'Sí':'No',i.name,i.size,i.qty,retInfo(o.number).qty[i.pid]||0,i.price,i.qty*i.price,o.total,retInfo(o.number).amount,netTotal(o),compsTxt(i.comps,i.qty)]);
  save(`mustela-pedidos-${stamp()}.csv`,csv(rows)); };
// Long numeric codes (EAN) as text so Excel doesn't turn them into 3.5E+12
const xtxt = v => v ? `="${v}"` : '';
/* Inventario y ventas: inicial, resurtido, vendido (unidades y $ netos de devoluciones), final. Agrupado por línea. */
async function exportInvSales(){
  await Promise.all([load('products'),load('kits'),load('orders'),load('returns')]);
  // u = units of the line itself (product or kit), m = $ of the line, ku = units that left inside kits
  const u={}, m={}, ku={};
  const add=(i,sg)=>{ const q=(i.qty||0)*sg; u[i.pid]=(u[i.pid]||0)+q; m[i.pid]=(m[i.pid]||0)+q*(Number(i.price)||0); for(const c of i.comps||[]) ku[c.pid]=(ku[c.pid]||0)+q*(c.qty||1); };
  for(const o of S.orders){ if(!SOLD.includes(o.status)) continue; for(const i of o.items||[]) add(i,1); }
  for(const r of S.returns) for(const i of r.items||[]) add(i,-1);
  const head=['Código','SKU','Descripción','Inv. inicial','Resurtido','Inv. final','Vendido (unidades)','De ellas en kits','Precio','Ventas ($)'];
  const prods=physProducts().sort((a,b)=>(a.order??999)-(b.order??999)||String(a.name).localeCompare(b.name));
  const kits=S.products.filter(p=>p.is_kit).sort((a,b)=>(a.order??999)-(b.order??999)||String(a.name).localeCompare(b.name));
  const cats=[...new Set(prods.map(p=>p.category||'Sin línea'))];
  const rows=[['Inventario y ventas',S.cfg.evento||'Expo'],['Generado',new Date().toLocaleString('es-MX',{timeZone:TZ})],[],head];
  const T={ini:0,res:0,fin:0,u:0,k:0,m:0};
  for(const c of cats){
    rows.push(['',c.toUpperCase()]);
    for(const p of prods.filter(p=>(p.category||'Sin línea')===c)){
      const inKits=ku[p.id]||0, sold=(u[p.id]||0)+inKits, money_=Math.round((m[p.id]||0)*100)/100, ini=p.stock||0, res=p.restock||0, fin=ini+res-sold;
      rows.push([xtxt(p.codigo),xtxt(p.sku),[p.name,p.size].filter(Boolean).join(' '),ini,res,fin,sold,inKits,p.price,money_]);
      T.ini+=ini; T.res+=res; T.fin+=fin; T.u+=sold; T.k+=inKits; T.m+=money_;
    }
  }
  let nk=0;
  if(kits.length){
    rows.push(['','KITS ARMADOS (sus piezas ya se descontaron arriba)']);
    for(const k of kits){ const sold=u[k.id]||0, money_=Math.round((m[k.id]||0)*100)/100; nk+=sold; T.m+=money_;
      rows.push(['','',k.name+' — '+compsTxt(kitComps(k.id).map(c=>({qty:c.qty,name:c.p.name,size:c.p.size}))),'','','',sold,'',k.price,money_]); }
  }
  rows.push([],['','TOTAL','',T.ini,T.res,T.fin,T.u,T.k,'',Math.round(T.m*100)/100]);
  if(nk) rows.push(['','Kits vendidos','','','','',nk]);
  save(`mustela-inventario-ventas-${stamp()}.csv`,csv(rows));
}
$('expInvSales').onclick=exportInvSales;
$('corteInv').onclick=exportInvSales;
$('expReturns').onclick=async()=>{ await Promise.all([load('orders'),load('returns')]);
  const rows=[['Fecha devolución','Pedido','Fecha pedido','Nombre','Apellido','Celular','Correo','Dermo-Consejera','Producto','Tamaño','Piezas devueltas','Precio','Reembolso línea','Reembolso total devolución','Método de reembolso','Motivo','Registró']];
  for(const r of [...S.returns].sort((a,b)=>String(a.created_at).localeCompare(String(b.created_at)))){
    const o=S.orders.find(x=>x.number===r.order_number)||{customer:{}};
    for(const i of r.items||[]) rows.push([r.created_at,r.order_number,o.createdAt||'',o.customer?.nombre,o.customer?.apellido,o.customer?.telefono,o.customer?.email,o.consejera||'',i.name,i.size,i.qty,i.price,i.qty*i.price,r.amount,r.method,r.reason||'',r.created_by||'']);
  }
  if(rows.length===1){ $('expNote').textContent='Aún no hay devoluciones.'; return; }
  save(`mustela-devoluciones-${stamp()}.csv`,csv(rows)); };
$('expMembers').onclick=async()=>{ await load('members');
  const rows=[['Fecha','Nombre','Apellido','Celular','Correo','Etapa','Ciudad','WhatsApp','Correos','Origen','Pedido']];
  for(const m of [...S.members].sort((a,b)=>String(a.createdAt).localeCompare(String(b.createdAt)))) rows.push([m.createdAt,m.nombre,m.apellido,m.telefono,m.email,m.etapa,m.ciudad,m.whatsapp?'Sí':'No',m.correo?'Sí':'No',m.origen,m.pedido]);
  save(`mustela-comunidad-${stamp()}.csv`,csv(rows)); };

/* ---------- CSV import (Inventario) ---------- */
function parseCSV(text){
  text=text.replace(/^﻿/,'');
  const first=text.split(/\r?\n/)[0]||'';
  const delim=(first.split(';').length>first.split(',').length)?';':(first.includes('\t')&&!first.includes(',')?'\t':',');
  const rows=[]; let row=[], f='', q=false;
  for(let i=0;i<text.length;i++){
    const c=text[i];
    if(q){ if(c==='"'){ if(text[i+1]==='"'){ f+='"'; i++; } else q=false; } else f+=c; }
    else if(c==='"') q=true;
    else if(c===delim){ row.push(f); f=''; }
    else if(c==='\n'||c==='\r'){ if(c==='\r'&&text[i+1]==='\n') i++; row.push(f); rows.push(row); row=[]; f=''; }
    else f+=c;
  }
  if(f!==''||row.length){ row.push(f); rows.push(row); }
  return rows.filter(r=>r.some(v=>String(v).trim()!==''));
}
const norm=s=>String(s??'').trim().toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g,'').replace(/[^a-z0-9]+/g,'_').replace(/^_|_$/g,'');
const COLS={ id:['id'], codigo:['codigo','code','clave','codigo_interno'], sku:['sku','ean','codigo_de_barras','codigo_barras','upc','barcode'], restock:['resurtido','restock','resurtidos'], name:['nombre','producto','name','product'], category:['linea','categoria','category','line'],
  size:['tamano','size','presentacion','contenido'], price:['precio','price','precio_mxn'], stock:['stock','inv_inicial','inventario_inicial','cantidad','inventario','piezas','qty'],
  active:['visible','activo','active'], order:['orden','order','posicion'], image_url:['imagen_url','imagen','image_url','foto','image'] };
const num=v=>{ const s=String(v??'').replace(/[^0-9.,-]/g,''); if(!s) return NaN; const t=/,\d{1,2}$/.test(s)&&!s.includes('.')?s.replace(',','.'):s.replace(/,/g,''); return Number(t); };
const yes=v=>!/^(no|n|0|false|falso|oculto)$/i.test(String(v??'').trim());
let IMP=null;
async function readCSVFile(file){
  const buf=await file.arrayBuffer();
  try{ return new TextDecoder('utf-8',{fatal:true}).decode(buf); }catch(e){ return new TextDecoder('windows-1252').decode(buf); }
}
$('impFile').onchange=async e=>{
  const file=e.target.files?.[0]; e.target.value=''; if(!file) return;
  const rows=parseCSV(await readCSVFile(file));
  if(rows.length<2) return showImp({error:'El archivo no tiene filas de productos.'});
  const head=rows[0].map(norm), idx={};
  for(const [k,al] of Object.entries(COLS)){ const i=head.findIndex(h=>al.includes(h)); if(i>=0) idx[k]=i; }
  const missing=['name','price','stock'].filter(k=>idx[k]===undefined);
  if(missing.length) return showImp({error:`Faltan columnas: ${missing.map(k=>({name:'nombre',price:'precio',stock:'stock'})[k]).join(', ')}. Descarga la plantilla para ver el formato.`});
  const byId=new Map(physProducts().map(p=>[p.id,p])), byKey=new Map(physProducts().map(p=>[norm(p.name)+'|'+norm(p.size),p]));
  const seen=new Set(), items=[];
  rows.slice(1).forEach((r,n)=>{
    const g=k=>idx[k]===undefined?undefined:String(r[idx[k]]??'').trim().replace(/^="(.*)"$/,'$1');
    const it={ line:n+2, codigo:g('codigo'), sku:g('sku'), restock: idx.restock===undefined?undefined:Math.round(num(g('restock'))||0), name:g('name')||'', category:g('category'), size:g('size'), price:num(g('price')), stock:num(g('stock')),
      active: idx.active===undefined?undefined:yes(g('active')), order: idx.order===undefined?undefined:num(g('order')), image_url:g('image_url'), id:g('id') };
    const key=norm(it.name)+'|'+norm(it.size??'');
    const match=(it.id&&byId.get(it.id))||byKey.get(key);
    if(!it.name) it.err='Sin nombre';
    else if(!(it.price>=0)) it.err='Precio inválido';
    else if(!(it.stock>=0)) it.err='Stock inválido';
    else if(seen.has(key)) it.err='Repetido en el archivo';
    else if(it.image_url && !/^https?:\/\//i.test(it.image_url)) it.err='imagen_url debe empezar con https://';
    seen.add(key); it.match=match; it.stock=Math.round(it.stock);
    items.push(it);
  });
  const ok=items.filter(i=>!i.err);
  const keep=new Set(ok.map(i=>i.match?.id).filter(Boolean));
  const hide=physProducts().filter(p=>!keep.has(p.id)&&p.active!==false);
  IMP={ items, ok, hide, file:file.name };
  showImp({});
};
function showImp({error}){
  const box=$('impPreview'); box.hidden=false;
  if(error){ box.innerHTML=`<p class="banner bad" style="margin:0">${esc(error)}</p>`; IMP=null; return; }
  const {items,ok,hide,file}=IMP, nNew=ok.filter(i=>!i.match).length, nUpd=ok.length-nNew, nErr=items.length-ok.length, hideOn=$('impHide').checked;
  box.innerHTML=`<p style="margin:0"><b>${esc(file)}</b>: <span class="pill p-ready">${nNew} nuevos</span> <span class="pill p-paid">${nUpd} se actualizan</span> ${nErr?`<span class="pill p-cancel">${nErr} con error (se omiten)</span>`:''} ${hideOn&&hide.length?`<span class="pill p-pend">${hide.length} se ocultan</span>`:''}</p>
    <div class="tscroll"><table style="min-width:640px"><thead><tr><th>Fila</th><th>Producto</th><th>Línea</th><th>Tamaño</th><th class="r">Precio</th><th class="r">Stock</th><th>Resultado</th></tr></thead><tbody>
    ${items.slice(0,200).map(i=>`<tr><td class="num">${i.line}</td><td>${esc(i.name)}</td><td>${esc(i.category??'')}</td><td>${esc(i.size??'')}</td><td class="r num">${isNaN(i.price)?'—':money(i.price)}</td><td class="r num">${isNaN(i.stock)?'—':i.stock}</td>
      <td>${i.err?`<span class="pill p-cancel">${esc(i.err)}</span>`:i.match?'<span class="pill p-paid">Actualiza</span>':'<span class="pill p-ready">Nuevo</span>'}</td></tr>`).join('')}
    </tbody></table></div>
    <div style="display:flex;gap:10px;justify-content:flex-end;flex-wrap:wrap"><button type="button" class="btn ghost" id="impCancel">Cancelar</button><button type="button" class="btn primary" id="impGo" ${ok.length?'':'disabled'}>Importar ${ok.length} productos</button></div>`;
}
$('impHide').onchange=()=>{ if(IMP) showImp({}); };
$('importBox').addEventListener('click',async e=>{
  if(e.target.id==='impCancel'){ IMP=null; $('impPreview').hidden=true; return; }
  if(e.target.id!=='impGo'||!IMP||S.busy) return;
  S.busy=true; e.target.disabled=true; e.target.textContent='Importando…';
  try{
    let nextOrder=Math.max(0,...S.products.map(p=>p.order||0));
    const row=i=>{ const r={ name:i.name, price:i.price, stock:i.stock, sample:false };
      if(i.codigo!==undefined) r.codigo=i.codigo; if(i.sku!==undefined) r.sku=i.sku; if(i.restock!==undefined) r.restock=i.restock;
      if(i.category!==undefined) r.category=i.category; if(i.size!==undefined) r.size=i.size;
      if(i.active!==undefined) r.active=i.active; if(i.order!==undefined&&!isNaN(i.order)) r.sort_order=Math.round(i.order);
      if(i.image_url) r.image_url=i.image_url; return r; };
    const ins=IMP.ok.filter(i=>!i.match).map(i=>{ const r=row(i); if(r.sort_order===undefined) r.sort_order=++nextOrder; if(r.active===undefined) r.active=true; return r; });
    const upd=IMP.ok.filter(i=>i.match).map(i=>({ ...row(i), id:i.match.id }));
    if(ins.length){ const {error}=await sb.from('products').insert(ins); if(error) throw error; }
    for(const u of upd){ const {id,...patch}=u; const {error}=await sb.from('products').update(patch).eq('id',id); if(error) throw error; }
    if($('impHide').checked && IMP.hide.length){ const {error}=await sb.from('products').update({active:false}).in('id',IMP.hide.map(p=>p.id)); if(error) throw error; }
    toast(`Catálogo importado: ${ins.length} nuevos, ${upd.length} actualizados`);
    IMP=null; $('impPreview').hidden=true; queue('products','avail');
  }catch(ex){ toast('No se pudo importar: '+errMsg(ex)); e.target.disabled=false; e.target.textContent='Reintentar'; }
  finally{ S.busy=false; }
});
$('expCatalog').onclick=async()=>{ await load('products');
  const rows=[['id','codigo','sku','nombre','linea','tamaño','precio','inv_inicial','resurtido','visible','orden','imagen_url']];
  for(const p of physProducts().sort((a,b)=>(a.order??999)-(b.order??999))) rows.push([p.id,xtxt(p.codigo),xtxt(p.sku),p.name,p.category,p.size,p.price,p.stock,p.restock||0,p.active!==false?'sí':'no',p.order??'',p.image_url||'']);
  if(rows.length===1) rows.push(['','87035893','3504105035891','Ejemplo de producto','Bebé','300 ml','389','40','0','sí','1','']);
  save(`mustela-catalogo-${stamp()}.csv`,csv(rows)); };

/* ---------- PERSONAL (admins; Vercel function /api/staff) ---------- */
async function staffApi(payload){
  try{
    const r=await fetch('/api/staff',{ method:'POST', headers:{'Content-Type':'application/json', Authorization:'Bearer '+(S.session?.access_token||'')}, body:JSON.stringify(payload) });
    const j=await r.json().catch(()=>({})); return { ok:r.ok&&j.ok!==false, ...j };
  }catch(e){ return { ok:false, error:'red' }; }
}
const STAFF_ERR={ solo_admin:'Solo un administrador puede hacer esto.', correo_invalido:'Revisa el correo.', contrasena_corta:'La contraseña debe tener al menos 8 caracteres.',
  ultimo_admin:'Debe quedar al menos un administrador.', no_a_ti_mismo:'No puedes quitarte a ti mismo.', usuario_no_existe:'Ese usuario no existe en Supabase.',
  no_configurado:'Falta SUPABASE_SECRET_KEY en Vercel.', red:'Sin conexión.', no_sesion:'Vuelve a iniciar sesión.' };
const staffErr = r => STAFF_ERR[r.error] || `No se pudo (${r.error||'error'}${r.detail?': '+r.detail:''})`;
const genPass = () => { const a='abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'; const b=new Uint32Array(10); crypto.getRandomValues(b); return Array.from(b,x=>a[x%a.length]).join(''); };
function renderPersonal(){
  $('perNoAdmin').hidden=S.isAdmin; $('perBox').hidden=!S.isAdmin; if(!S.isAdmin) return;
  if($('perBody').contains(document.activeElement) && document.activeElement.id==='pw-new') return;
  const me=(S.session?.user?.email||'').toLowerCase();
  $('perBody').innerHTML=(S.staff||[]).map(u=>`<tr>
    <td>${esc(u.nombre||'')}</td><td>${esc(u.email)}${u.email===me?' <span class="pill p-paid">tú</span>':''}</td>
    <td><div class="permcell">${['caja','surtido','inventario','corte'].map(k=>`<label class="check"><input type="checkbox" data-pperm="${k}" data-pe="${esc(u.email)}" ${u.admin||(u.perms||[]).includes(k)?'checked':''} ${u.admin?'disabled':''}><span>${k[0].toUpperCase()+k.slice(1)}</span></label>`).join('')}<label class="check"><input type="checkbox" data-padmin="${esc(u.email)}" ${u.admin?'checked':''}><span><b>Admin</b></span></label></div></td>
    <td>${S.pwFor===u.email
      ?`<span style="display:inline-flex;gap:6px;flex-wrap:wrap"><input id="pw-new" style="width:170px;min-height:36px" placeholder="Nueva contraseña" value="${esc(S.pwDraft||'')}"><button type="button" class="btn sm primary" data-pwsave="${esc(u.email)}">Guardar</button><button type="button" class="btn sm ghost" data-pwcancel>Cancelar</button></span>`
      :`<button type="button" class="linkbtn" data-pw="${esc(u.email)}" style="display:inline;margin-right:12px">Cambiar contraseña</button>${u.email!==me?`<button type="button" class="linkbtn rm" data-prm="${esc(u.email)}" style="display:inline">${S.rmArm===u.email?'¿Seguro? Toca otra vez':'Quitar'}</button>`:''}`}</td></tr>`).join('') || '<tr><td colspan="4" class="empty">Sin usuarios</td></tr>';
}
$('p-gen').onclick=()=>{ $('p-pass').value=genPass(); };
$('perForm').onsubmit=async e=>{
  e.preventDefault();
  const email=$('p-email').value.trim().toLowerCase(), password=$('p-pass').value, nombre=$('p-nombre').value.trim(), admin=$('p-admin').checked;
  if(!okMail(email)) return toast('Revisa el correo.'); if(password.length<8) return toast('La contraseña debe tener al menos 8 caracteres.');
  $('p-go').disabled=true;
  const perms=[...document.querySelectorAll('#p-perms input:checked')].map(x=>x.value);
  if(!admin && !perms.length) return toast('Elige al menos una pantalla o márcalo como administrador.');
  const r=await staffApi({ action:'create', email, password, nombre, admin, perms });
  $('p-go').disabled=false;
  if(!r.ok) return toast(staffErr(r));
  $('perMsg').innerHTML=`Usuario listo. Comparte estos datos: <b>${esc(email)}</b> · contraseña <b>${esc(password)}</b> · ${esc(location.origin)}`; $('perMsg').hidden=false;
  $('perForm').reset(); queue('staff');
};
$('p-admin').onchange=()=>document.querySelectorAll('#p-perms input').forEach(x=>{ x.disabled=$('p-admin').checked; if($('p-admin').checked) x.checked=true; });
$('perBody').addEventListener('change',async e=>{
  const pp=e.target.closest('[data-pperm]');
  if(pp){ const em=pp.dataset.pe; const perms=[...document.querySelectorAll(`#perBody [data-pperm][data-pe="${CSS.escape(em)}"]:checked`)].map(x=>x.dataset.pperm);
    pp.disabled=true; const r=await staffApi({ action:'set_perms', email:em, perms }); pp.disabled=false;
    if(!r.ok){ pp.checked=!pp.checked; toast(staffErr(r)); } else toast('Acceso actualizado');
    queue('staff'); return; }
  const c=e.target.closest('[data-padmin]'); if(!c) return;
  c.disabled=true; const r=await staffApi({ action:'set_admin', email:c.dataset.padmin, admin:c.checked }); c.disabled=false;
  if(!r.ok){ c.checked=!c.checked; toast(staffErr(r)); } else toast(c.checked?'Ahora es administrador':'Ya no es administrador');
  queue('staff');
});
$('perBody').addEventListener('click',async e=>{
  const pw=e.target.closest('[data-pw]'); if(pw){ S.pwFor=pw.dataset.pw; S.pwDraft=genPass(); S.rmArm=null; renderPersonal(); return; }
  if(e.target.closest('[data-pwcancel]')){ S.pwFor=null; renderPersonal(); return; }
  const sv=e.target.closest('[data-pwsave]');
  if(sv){ const password=$('pw-new').value; sv.disabled=true; const r=await staffApi({ action:'set_password', email:sv.dataset.pwsave, password }); sv.disabled=false;
    if(!r.ok) return toast(staffErr(r));
    $('perMsg').innerHTML=`Contraseña actualizada para <b>${esc(sv.dataset.pwsave)}</b>: <b>${esc(password)}</b>`; $('perMsg').hidden=false; S.pwFor=null; renderPersonal(); return; }
  const rm=e.target.closest('[data-prm]');
  if(rm){ if(S.rmArm!==rm.dataset.prm){ S.rmArm=rm.dataset.prm; renderPersonal(); return; }
    S.rmArm=null; const r=await staffApi({ action:'remove', email:rm.dataset.prm });
    toast(r.ok?'Usuario dado de baja':staffErr(r)); queue('staff'); }
});

/* ---------- CORTE DE CAJA ---------- */
const TZ='America/Mexico_City';
const dayOf = iso => iso ? new Date(iso).toLocaleDateString('en-CA',{timeZone:TZ}) : '';
const dayLabel = d => d==='all' ? 'Todo el evento' : new Date(d+'T12:00:00').toLocaleDateString('es-MX',{weekday:'long',day:'numeric',month:'long',year:'numeric'});
const METHODS=['Tarjeta','Efectivo','Transferencia'];
function corteData(){
  const inDay = iso => S.corteDay==='all' || dayOf(iso)===S.corteDay;
  const pays = S.orders.filter(o=>SOLD.includes(o.status) && inDay(o.paidAt)).sort((a,b)=>String(a.paidAt).localeCompare(String(b.paidAt)));
  const rets = S.returns.filter(r=>inDay(r.created_at)).sort((a,b)=>String(a.created_at).localeCompare(String(b.created_at)));
  const by = METHODS.map(m=>{ const p=pays.filter(o=>o.payMethod===m), r=rets.filter(x=>x.method===m);
    const v=p.reduce((a,o)=>a+(o.total||0),0), d=r.reduce((a,x)=>a+(Number(x.amount)||0),0);
    return { m, vn:p.length, v, dn:r.length, d, net:v-d }; });
  const tot = by.reduce((a,x)=>({vn:a.vn+x.vn,v:a.v+x.v,dn:a.dn+x.dn,d:a.d+x.d,net:a.net+x.net}),{vn:0,v:0,dn:0,d:0,net:0});
  const units = pays.reduce((a,o)=>a+(o.items||[]).reduce((b,i)=>b+i.qty,0),0) - rets.reduce((a,r)=>a+(r.items||[]).reduce((b,i)=>b+(i.qty||0),0),0);
  const group = key => { const g={}; for(const o of pays){ const k=key(o)||'—'; const x=g[k]||(g[k]={n:0,t:0}); x.n++; x.t+=o.total||0; } return Object.entries(g).sort((a,b)=>b[1].t-a[1].t); };
  return { pays, rets, by, tot, units, cajeros:group(o=>o.paidBy), conse:group(o=>o.consejera), pend:S.orders.filter(o=>o.status==='pendiente').length };
}
function renderCorte(){
  const days=[...new Set([...S.orders.filter(o=>o.paidAt).map(o=>dayOf(o.paidAt)), ...S.returns.map(r=>dayOf(r.created_at))])].filter(Boolean).sort().reverse();
  const today=dayOf(new Date().toISOString());
  if(!S.corteDay || (S.corteDay!=='all' && !days.includes(S.corteDay) && S.corteDay!==today)) S.corteDay = days.includes(today)||!days.length ? today : days[0];
  const opts=[...new Set([today,...days])].sort().reverse();
  $('corteDay').innerHTML = opts.map(d=>`<option value="${d}"${d===S.corteDay?' selected':''}>${dayLabel(d)}${d===today?' (hoy)':''}</option>`).join('') + `<option value="all"${S.corteDay==='all'?' selected':''}>Todo el evento</option>`;
  const c=corteData();
  $('corteSub').textContent = `${dayLabel(S.corteDay)} · hora de Ciudad de México · generado ${new Date().toLocaleString('es-MX',{timeZone:TZ,dateStyle:'short',timeStyle:'short'})}`;
  const efe=c.by.find(x=>x.m==='Efectivo');
  const tbl=(head,rows,foot)=>`<div class="tscroll"><table class="ctable"><thead><tr>${head}</tr></thead><tbody>${rows}</tbody>${foot?`<tfoot><tr>${foot}</tr></tfoot>`:''}</table></div>`;
  $('corteBody').innerHTML = `
    <div class="tiles">${[['Ventas cobradas',money(c.tot.v)],['Devoluciones',c.tot.d?'−'+money(c.tot.d):money(0)],['Neto',money(c.tot.net)],['Pedidos cobrados',c.tot.vn],['Ticket promedio',money(c.tot.vn?c.tot.v/c.tot.vn:0)],['Piezas netas',c.units]].map(([k,v])=>`<div class="tile"><span class="eyebrow">${k}</span><b class="num">${v}</b></div>`).join('')}</div>
    <div class="panel" style="display:grid;gap:12px;margin-bottom:20px">
      <h2>Por forma de <b>pago</b></h2>
      ${tbl('<th>Forma de pago</th><th class="r">Cobros</th><th class="r">Ventas</th><th class="r">Devol.</th><th class="r">Reembolsos</th><th class="r">Neto</th>',
        c.by.map(x=>`<tr><td>${x.m}</td><td class="r num">${x.vn}</td><td class="r num">${money(x.v)}</td><td class="r num">${x.dn}</td><td class="r num">${x.d?'−'+money(x.d):money(0)}</td><td class="r num"><b>${money(x.net)}</b></td></tr>`).join(''),
        `<td>Total</td><td class="r num">${c.tot.vn}</td><td class="r num">${money(c.tot.v)}</td><td class="r num">${c.tot.dn}</td><td class="r num">${c.tot.d?'−'+money(c.tot.d):money(0)}</td><td class="r num">${money(c.tot.net)}</td>`)}
      <p class="banner warn" style="margin:0">Efectivo que debe haber en caja (sin fondo inicial): <b class="num">${money(efe.net)}</b></p>
      ${c.pend?`<p class="muted" style="margin:0">Hay ${c.pend} pedido${c.pend>1?'s':''} sin cobrar (no cuentan en el corte).</p>`:''}
    </div>
    <div class="cols" style="margin-bottom:20px">
      <div class="panel" style="display:grid;gap:10px"><h3>Por cajero</h3>${tbl('<th>Cobró</th><th class="r">Cobros</th><th class="r">Ventas</th>', c.cajeros.length?c.cajeros.map(([k,x])=>`<tr><td>${esc(k)}</td><td class="r num">${x.n}</td><td class="r num">${money(x.t)}</td></tr>`).join(''):'<tr><td colspan="3" class="empty">Sin cobros</td></tr>')}</div>
      <div class="panel" style="display:grid;gap:10px"><h3>Por Dermo-Consejera</h3>${tbl('<th>Consejera</th><th class="r">Pedidos</th><th class="r">Ventas</th>', c.conse.length?c.conse.map(([k,x])=>`<tr><td>${esc(k==='—'?'Sin consejera':k)}</td><td class="r num">${x.n}</td><td class="r num">${money(x.t)}</td></tr>`).join(''):'<tr><td colspan="3" class="empty">Sin cobros</td></tr>')}</div>
    </div>
    <div class="panel" style="display:grid;gap:10px;margin-bottom:20px"><h3>Cobros (${c.pays.length})</h3>
      ${tbl('<th>Hora</th><th>Pedido</th><th>Cliente</th><th>Forma</th><th>Ref.</th><th>Cobró</th><th class="r">Total</th>', c.pays.length?c.pays.map(o=>`<tr><td class="num">${S.corteDay==='all'?dayOf(o.paidAt)+' ':''}${hhmm(o.paidAt)}</td><td><b>${esc(o.number)}</b>${o.factura?' <span class="pill p-pend">Factura</span>':''}</td><td>${esc(fullName(o.customer))}</td><td>${esc(o.payMethod||'')}</td><td>${esc(o.payRef||'')}</td><td>${esc(o.paidBy||'')}</td><td class="r num">${money(o.total)}</td></tr>`).join(''):'<tr><td colspan="7" class="empty">Sin cobros este día</td></tr>')}
    </div>
    <div class="panel" style="display:grid;gap:10px"><h3>Devoluciones (${c.rets.length})</h3>
      ${tbl('<th>Hora</th><th>Pedido</th><th>Productos</th><th>Forma</th><th>Motivo</th><th>Registró</th><th class="r">Reembolso</th>', c.rets.length?c.rets.map(r=>`<tr><td class="num">${S.corteDay==='all'?dayOf(r.created_at)+' ':''}${hhmm(r.created_at)}</td><td><b>${esc(r.order_number)}</b></td><td>${(r.items||[]).map(i=>`${i.qty}× ${esc(i.name)}`).join(', ')}</td><td>${esc(r.method)}</td><td>${esc(r.reason||'')}</td><td>${esc(r.created_by||'')}</td><td class="r num">−${money(r.amount)}</td></tr>`).join(''):'<tr><td colspan="7" class="empty">Sin devoluciones este día</td></tr>')}
    </div>`;
  $('resetBox').hidden=!S.isAdmin;
  const rs=S.resets||[], firstOpen=rs.find(r=>!r.restored_at);
  $('resetHist').innerHTML = rs.length ? '<b>Historial de borrados</b>' + rs.map(r=>`<div class="line" style="font-size:14px"><span>${new Date(r.created_at).toLocaleString('es-MX',{timeZone:TZ,dateStyle:'short',timeStyle:'short'})} · ${esc(r.created_by)} · ${r.orders} pedidos, ${r.returns} devoluciones${r.members?`, ${r.members} registros`:''}${r.restored_at?` · <span class="pill p-ready">Restaurado</span>`:''}</span>${r===firstOpen?`<button type="button" class="btn sm ghost" data-restore="${r.id}">Restaurar</button>`:''}</div>`).join('') : '';
}
$('corteDay').onchange=e=>{ S.corteDay=e.target.value; renderCorte(); };
$('cortePrint').onclick=()=>window.print();
$('corteCsv').onclick=async()=>{ await Promise.all([load('orders'),load('returns')]); const c=corteData();
  const rows=[['Corte de caja',dayLabel(S.corteDay)],['Generado',new Date().toLocaleString('es-MX',{timeZone:TZ})],[],
    ['Forma de pago','Cobros','Ventas','Devoluciones','Reembolsos','Neto'], ...c.by.map(x=>[x.m,x.vn,x.v,x.dn,x.d,x.net]), ['Total',c.tot.vn,c.tot.v,c.tot.dn,c.tot.d,c.tot.net],
    ['Efectivo esperado en caja (sin fondo inicial)','','','','',c.by.find(x=>x.m==='Efectivo').net],[],
    ['Cobros'],['Fecha','Hora','Pedido','Nombre','Apellido','Forma de pago','Referencia','Cobró','Dermo-Consejera','Factura','Total'],
    ...c.pays.map(o=>[dayOf(o.paidAt),hhmm(o.paidAt),o.number,o.customer?.nombre,o.customer?.apellido,o.payMethod,o.payRef,o.paidBy,o.consejera,o.factura?'Sí':'No',o.total]),[],
    ['Devoluciones'],['Fecha','Hora','Pedido','Productos','Forma de reembolso','Motivo','Registró','Reembolso'],
    ...c.rets.map(r=>[dayOf(r.created_at),hhmm(r.created_at),r.order_number,(r.items||[]).map(i=>`${i.qty}x ${i.name}`).join('; '),r.method,r.reason,r.created_by,r.amount])];
  save(`mustela-corte-${S.corteDay}.csv`,csv(rows)); };
$('resetHist').onclick=async e=>{
  const b=e.target.closest('[data-restore]'); if(!b) return;
  b.disabled=true;
  try{ const r=await rpc('restore_reset',{ p_id:b.dataset.restore });
    toast(`Restaurado: ${r.orders} pedidos, ${r.returns} devoluciones${r.members?`, ${r.members} registros de Comunidad`:''}.`);
    queue('orders','returns','members','avail','resets');
  }catch(ex){ toast(/nada_que_restaurar/.test(ex?.message)?'No hay nada pendiente por restaurar.':/solo_admin/.test(ex?.message)?'Solo un administrador puede restaurar.':errMsg(ex)); b.disabled=false; }
};
$('resetGo').onclick=async()=>{
  if($('resetConfirm').value.trim()!=='BORRAR') return toast('Escribe BORRAR para confirmar');
  $('resetGo').disabled=true;
  try{ const r=await rpc('reset_event_data',{ p_confirm:'BORRAR', p_members:$('resetMembers').checked });
    toast(`Listo: se borraron ${r.orders} pedidos, ${r.returns} devoluciones${r.members?` y ${r.members} registros de Comunidad`:''}.`);
    $('resetConfirm').value=''; $('resetMembers').checked=false; S.sel=null; S.ticks={};
    queue('orders','returns','members','avail','resets');
  }catch(ex){ toast(/solo_admin/.test(ex?.message)?'Solo un administrador puede borrar ventas.':errMsg(ex)); }
  finally{ $('resetGo').disabled=false; }
};

/* ---------- brand ---------- */
// Website palette per product line (Play Book › Website colors)
const LINE_COLORS = { 'bebé':'#E1F3FA', 'bebe':'#E1F3FA', 'piel atópica':'#D2F0EF', 'piel atopica':'#D2F0EF', 'maternidad':'#EFCCD7',
  'kits':'#FBEDC0', 'cambio de pañal':'#EBDDEA', 'piel seca':'#FCEDC8', 'solar':'#FBEDC0', 'orgánico':'#E0E5D7', 'muy sensible':'#FAD9DF' };
const lineColor = c => LINE_COLORS[String(c||'').trim().toLowerCase()] || '#F1D9CD';
// Official logo: drop the file at assets/logo.svg. Until then the slot shows the word "Mustela".
(function(){ const img=new Image(); img.onload=()=>document.querySelectorAll('.logo-slot').forEach(el=>{ el.textContent=''; const i=img.cloneNode(); i.alt='Mustela'; el.appendChild(i); }); img.src='assets/logo.svg'; })();

/* ---------- render + boot ---------- */
function renderAll(){
  if(S.view==='tienda') renderKiosk(); else { $('cartbar').hidden=true; document.body.classList.remove('kiosk-cart'); }
  if(S.view==='caja') renderCaja();
  if(S.view==='surtido') renderSurtido();
  if(S.view==='inventario') renderInv();
  if(S.view==='corte') renderCorte();
  if(S.view==='personal') renderPersonal();
}
async function boot(){
  if(!sb){ $('dbBanner').textContent='Falta configurar Supabase: edita config.js con la URL y la anon key del proyecto.'; $('dbBanner').hidden=false; }
  else {
    await refreshAuth();
    sb.auth.onAuthStateChange((ev)=>{ if(ev==='SIGNED_OUT' && STAFF.includes(S.view)){ stopStaff(); S.isStaff=false; go('login'); } });
  }
  const h=(location.hash||'').slice(1);
  go(VIEWS.includes(h)&&h!=='login'?h:'inicio');
  startKioskPoll();
  window.addEventListener('hashchange',()=>{
    const v=(location.hash||'').slice(1); if(!VIEWS.includes(v)||v===S.view) return;
    if(KIOSK.includes(S.view) && !KIOSK.includes(v)){ history.replaceState(null,'','#'+S.view); return askPin(v); }
    go(v);
  });
  window.addEventListener('online',()=>{ loadKiosk(); if(S.isStaff) queue('products','orders','members','settings','returns','avail'); });
}
boot();
