// Panel testleri için sahte Supabase istemcisi (ağ yok). Sayfaya <script> olarak yüklenir.
// Sayfa öncesi ayarlar: window.__role ('admin'|'sales'|'designer'|'none'), window.__preLogged, window.__accessError
(() => {
  const role = window.__role || 'admin';
  const PERMS = {
    admin: ['leads', 'scan', 'customers', 'customers_write', 'team', 'subscriptions'],
    sales: ['leads', 'scan', 'customers', 'customers_write'],
    designer: ['customers', 'customers_write'],
    none: [],
  };
  const has = p => (PERMS[role] || []).includes(p);
  const deny = () => ({ error: { message: 'Bu işlem için yetkiniz yok' } });
  window.__calls = [];
  window.__loggedIn = !!window.__preLogged;

  const B = o => Object.assign({ address: 'Çankaya/Ankara', city: 'Ankara', district: 'Çankaya', sector: 'kuaför', rating: 4.7, review_count: 50,
    website_status: 'none', lead_score: 80, status: 'new', call_list: false, attempt_count: 0, maps_url: 'https://maps.google.com/?cid=1' }, o);
  const biz = [
    B({ id: 'm1', name: 'Mavi Kuaför | Çankaya Saç Tasarım', phone_raw: '0532 111 22 33', phone_normalized: '+905321112233', lead_score: 90 }),
    B({ id: 'm2', name: 'Yeşil Berber', phone_raw: '0533 222 33 44', phone_normalized: '+905332223344', lead_score: 70, maps_url: 'javascript:alert(1)' }),
    B({ id: 'l1', name: 'Sabit Diş', sector: 'diş', phone_raw: '0312 123 45 67', phone_normalized: '+903121234567' }),
    B({ id: 'f1', name: 'Takip Eczane', sector: 'eczane', status: 'callback', lead_score: 95, attempt_count: 1, phone_raw: '0534 000 00 00', phone_normalized: '+905340000000' }),
  ];
  const isMobile = b => /^\+905\d{9}$/.test(b.phone_normalized);
  const lstOf = b => b.status === 'callback' || b.status === 'wa_sent' ? 'followup' : b.status === 'new' ? ((!isMobile(b) || b.call_list) ? 'call' : 'whatsapp') : null;
  const log = [];

  let seq = 10;
  const now = () => new Date().toISOString();
  const customers = [{ id: 'c0', business_id: null, name: 'Eski Müşteri', phone: '0555 111 22 33', city: 'Ankara', sector: 'berber', stage: 'designing', amount: 5000,
    domain: null, next_step: 'Logo iste', next_step_at: new Date(Date.now() - 2 * 86400000).toISOString(), stage_changed_at: new Date(Date.now() - 3 * 86400000).toISOString() }];
  const notes = { c0: [{ id: 'n0', kind: 'created', body: 'Satış kaydedildi', created_at: now(), author: 'Kerim' }] };
  const addNote = (cid, kind, body) => { (notes[cid] = notes[cid] || []).unshift({ id: 'n' + (++seq), kind, body, created_at: now(), author: 'Kerim' }); };
  const lastNote = c => ((notes[c.id] || []).find(n => n.kind === 'note' || n.kind === 'stage') || {}).body || null;
  const STAGE_TR = { sale_done: 'Satış gerçekleşti', collecting: 'Bilgi toplanıyor', designing: 'Site tasarlanıyor', client_review: 'Müşteri onayında', live: 'Yayında', paused: 'Beklemede', cancelled: 'İptal' };
  const users = [
    { user_id: 'u1', email: 'kerim@vitrin.test', display_name: 'Kerim', role: 'admin', last_sign_in_at: now() },
    { user_id: 'u2', email: 'arkadas@vitrin.test', display_name: null, role: 'sales', last_sign_in_at: now() },
    { user_id: 'u3', email: 'yeni@vitrin.test', display_name: null, role: 'none', last_sign_in_at: null },
  ];
  const needs = (perm, fn) => a => has(perm) ? fn(a) : deny();

  const handlers = {
    my_access: () => window.__accessError ? { error: { code: 'PGRST202', message: 'Could not find the function public.my_access without parameters in the schema cache' } }
      : [{ role, perms: PERMS[role], display_name: role === 'admin' ? 'Kerim' : null }],
    next_business: needs('leads', a => { const x = biz.filter(b => lstOf(b) === a.p_list && !(a.p_skip || []).includes(b.id) && (!a.p_city || b.city === a.p_city) && (!a.p_sector || b.sector === a.p_sector))
      .sort((p, q) => q.lead_score - p.lead_score)[0]; return x ? [x] : []; }),
    release_business: () => null,
    move_to_call_list: needs('leads', a => { biz.find(b => b.id === a.p_business_id).call_list = true; return null; }),
    log_call: needs('leads', a => { const b = biz.find(x => x.id === a.p_business_id);
      if (a.p_outcome === 'callback' && !a.p_callback_at) return { error: { message: 'Geri arama tarihi gerekli' } };
      b.status = a.p_outcome; b.attempt_count++; log.push({ ...a });
      if (a.p_outcome === 'won') { const id = 'c' + (++seq); customers.unshift({ id, business_id: b.id, name: b.name, phone: b.phone_raw, city: b.city, sector: b.sector, stage: 'sale_done', amount: null, domain: null, next_step: null, next_step_at: null, stage_changed_at: now() }); addNote(id, 'created', 'Satış kaydedildi' + (a.p_note ? '\n' + a.p_note : '')); }
      return null; }),
    list_counts: needs('leads', a => ['whatsapp', 'call', 'followup'].map(l => ({ lst: l, n: biz.filter(b => lstOf(b) === l && (!a.p_city || b.city === a.p_city) && (!a.p_sector || b.sector === a.p_sector)).length })).filter(r => r.n)),
    filter_options: needs('leads', () => [...new Map(biz.filter(lstOf).map(b => [b.city + b.sector, { city: b.city, sector: b.sector }])).values()]),
    stats: needs('leads', () => [{ week_total: log.length + 7, week_wa: 3, today_total: log.length, today_wa: log.filter(l => l.p_outcome === 'wa_sent').length }]),
    search_history: needs('leads', a => log.filter(l => !a.p_term || JSON.stringify(l).includes(a.p_term)).map(l => ({ called_at: now(), outcome: l.p_outcome, note: l.p_note, name: biz.find(b => b.id === l.p_business_id).name, phone_raw: 'x', city: 'Ankara' }))),
    customer_timeline: needs('customers', a => [...(notes[a.p_id] || [])]),
    set_customer_stage: needs('customers_write', a => { const c = customers.find(x => x.id === a.p_id); const old = c.stage; c.stage = a.p_stage; c.stage_changed_at = now();
      addNote(c.id, 'stage', STAGE_TR[old] + ' → ' + STAGE_TR[a.p_stage] + (a.p_note ? '\n' + a.p_note : '')); return null; }),
    update_customer: needs('customers_write', a => { const c = customers.find(x => x.id === a.p_id);
      for (const [k, v] of Object.entries(a.p_patch)) c[k] = k === 'amount' ? (v === '' ? null : Number(v)) : (v === '' ? null : v);
      addNote(c.id, 'edit', 'Güncellendi: ' + Object.keys(a.p_patch).join(', ')); return null; }),
    add_customer_note: needs('customers_write', a => { addNote(a.p_id, 'note', a.p_body); return null; }),
    create_customer: needs('customers_write', a => { const id = 'c' + (++seq); customers.unshift({ id, business_id: null, name: a.p_name, phone: a.p_phone, city: a.p_city, sector: a.p_sector, stage: 'sale_done', amount: a.p_amount,
      domain: null, next_step: null, next_step_at: null, stage_changed_at: now() }); addNote(id, 'created', a.p_note || 'Müşteri elle eklendi'); return id; }),
    team_list: needs('team', () => users.map(u => ({ ...u }))),
    set_user_role: needs('team', a => { const u = users.find(x => x.user_id === a.p_user); u.role = a.p_role; if (a.p_name) u.display_name = a.p_name; return null; }),
  };

  const tableData = {
    calls: () => [{ called_at: now(), outcome: 'no_answer', note: 'meşguldü' }],
    scan_history: () => [{ scanned_at: now(), city: 'Ankara', district: 'Çankaya', sector: 'kuaför', places_found: 60, saved: 31 }],
    v_customers: () => customers.map(c => ({ ...c, last_note: lastNote(c) })),
  };
  const session = () => window.__loggedIn ? { access_token: 'tok', user: { id: 'u1' } } : null;
  window.supabase = { createClient: () => ({
    auth: {
      getSession: async () => ({ data: { session: session() } }),
      signInWithPassword: async ({ password }) => password === 'dogru' ? (window.__loggedIn = true, { error: null }) : { error: { message: 'bad' } },
      signOut: async () => { window.__loggedIn = false; },
      onAuthStateChange: () => ({}),
    },
    rpc: async (name, args) => {
      window.__calls.push([name, args]);
      const r = handlers[name](args || {});
      return r && r.error ? { data: null, error: r.error } : { data: r, error: null };
    },
    from: table => { const q = { select: () => q, eq: () => q, order: () => q, limit: () => Promise.resolve({ data: (tableData[table] || (() => []))(), error: null }) }; return q; },
  }) };
})();
