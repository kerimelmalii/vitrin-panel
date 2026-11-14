// Panel testleri için sahte Supabase istemcisi (ağ yok). Sayfaya <script> olarak yüklenir.
// Sayfa öncesi ayarlar: window.__role ('admin'|'sales'|'designer'|'none'), window.__preLogged, window.__accessError,
//                       window.__ws ('platform' | 'pilot': pilot = demo alan, 500 kota, boş şablon)
(() => {
  const role = window.__role || 'admin';
  const wsKind = window.__ws || 'platform';
  const PERMS = {
    admin: ['leads', 'scan', 'customers', 'customers_write', 'team'],
    sales: ['leads', 'scan', 'customers', 'customers_write'],
    designer: ['customers', 'customers_write'],
    none: [],
  };
  const has = p => (PERMS[role] || []).includes(p);
  const deny = () => ({ error: { message: 'Bu işlem için yetkiniz yok' } });
  window.__calls = []; window.__signups = [];
  window.__loggedIn = !!window.__preLogged;

  const WS = {
    platform: { id: 'w0', name: 'Vitrin', is_platform: true, is_demo: false, weekly_goal: 100, wa_daily_limit: 20, lead_quota: null, leads_this_month: 31,
      message_template: 'Merhaba {isim},\n\nSize özel teklifimiz var.\n\nBizden mesaj almak istemiyorsanız "iptal" yazmanız yeterli.',
      sector_suggestions: ['kuaför', 'diş kliniği', 'avukat'] },
    pilot: { id: 'w1', name: 'Pilot Şirket', is_platform: false, is_demo: true, weekly_goal: 100, wa_daily_limit: 20, lead_quota: 500, leads_this_month: 120,
      message_template: '', sector_suggestions: ['diş kliniği', 'fizik tedavi merkezi', 'avukat'] },
  };
  const ws = WS[wsKind];
  const workspaces = [{ id: 'w0', slug: 'vitrin', name: 'Vitrin', is_platform: true, is_demo: false, lead_quota: null, leads_this_month: 31, members: 2 },
                      { id: 'w1', slug: 'pilot', name: 'Pilot Şirket', is_platform: false, is_demo: true, lead_quota: 500, leads_this_month: 120, members: 1 }];

  const B = o => Object.assign({ address: 'Çankaya/Ankara', city: 'Ankara', district: 'Çankaya', sector: 'kuaför', rating: 4.7, review_count: 50,
    website_status: 'none', lead_score: 80, status: 'new', call_list: false, attempt_count: 0, maps_url: 'https://maps.google.com/?cid=1' }, o);
  const biz = [
    B({ id: 'm1', name: 'Mavi Kuaför | Çankaya Saç Tasarım', phone_raw: '0532 111 22 33', phone_normalized: '+905321112233', lead_score: 90 }),
    B({ id: 'm2', name: 'Yeşil Berber', phone_raw: '0533 222 33 44', phone_normalized: '+905332223344', lead_score: 70, maps_url: 'javascript:alert(1)', rating: null, review_count: null }),
    B({ id: 'l1', name: 'Sabit Diş', sector: 'diş', phone_raw: '0312 123 45 67', phone_normalized: '+903121234567' }),
    B({ id: 'f1', name: 'Takip Eczane', sector: 'eczane', status: 'callback', lead_score: 95, attempt_count: 1, phone_raw: '0534 000 00 00', phone_normalized: '+905340000000' }),
  ];
  const isMobile = b => /^\+905\d{9}$/.test(b.phone_normalized);
  const lstOf = b => b.status === 'wa_sent' ? 'sent' : b.status === 'callback' ? 'followup' : b.status === 'new' ? ((!isMobile(b) || b.call_list) ? 'call' : 'whatsapp') : null;
  const log = [];

  let seq = 10;
  const now = () => new Date().toISOString();
  const customers = [{ id: 'c0', business_id: null, name: 'Eski Müşteri', phone: '0555 111 22 33', city: 'Ankara', sector: 'berber', stage: 'negotiating',
    next_step: 'Teklif gönder', next_step_at: new Date(Date.now() - 2 * 86400000).toISOString(), stage_changed_at: new Date(Date.now() - 3 * 86400000).toISOString() }];
  const sales = [{ id: 's0', customer_id: 'c0', product: 'Danışmanlık', quantity: 1, amount: 5000, sold_at: now() }];
  const notes = { c0: [{ id: 'n0', kind: 'created', body: 'İlgilendi, iletişime geçildi', created_at: now(), author: 'Kerim' }] };
  const addNote = (cid, kind, body) => { (notes[cid] = notes[cid] || []).unshift({ id: 'n' + (++seq), kind, body, created_at: now(), author: 'Kerim' }); };
  const lastNote = c => ((notes[c.id] || []).find(n => ['note', 'stage', 'sale'].includes(n.kind)) || {}).body || null;
  const STAGE_TR = { contacted: 'İletişimde', negotiating: 'Anlaşma aşamasında', won: 'Satış tamamlandı' };
  const users = [
    { user_id: 'u1', email: 'kerim@vitrin.test', display_name: 'Kerim', role: 'admin', workspace_id: 'w0', workspace_name: 'Vitrin', last_sign_in_at: now() },
    { user_id: 'u2', email: 'arkadas@vitrin.test', display_name: null, role: 'sales', workspace_id: 'w0', workspace_name: 'Vitrin', last_sign_in_at: now() },
    { user_id: 'u3', email: 'yeni@pilot.test', display_name: null, role: 'none', workspace_id: null, workspace_name: null, last_sign_in_at: null,
      full_name: 'Deniz Kaya', company: 'Kaya Hukuk', phone: '0532 000 00 00' },
    { user_id: 'u4', email: 'ali@pilot.test', display_name: 'Ali', role: 'sales', workspace_id: 'w1', workspace_name: 'Pilot Şirket', last_sign_in_at: null },
  ];
  const needs = (perm, fn) => a => has(perm) ? fn(a) : deny();
  const custOf = bid => customers.find(c => c.business_id === bid);

  const handlers = {
    my_access: () => window.__accessError ? { error: { code: 'PGRST202', message: 'Could not find the function public.my_access without parameters in the schema cache' } }
      : [{ role, perms: PERMS[role], display_name: role === 'admin' ? 'Kerim' : null, workspace_id: ws.id, workspace_name: ws.name, is_platform: ws.is_platform,
           is_platform_admin: role === 'admin' && ws.is_platform, is_demo: ws.is_demo, weekly_goal: ws.weekly_goal, wa_daily_limit: ws.wa_daily_limit,
           message_template: ws.message_template, sector_suggestions: ws.sector_suggestions, lead_quota: ws.lead_quota, leads_this_month: ws.leads_this_month }],
    next_business: needs('leads', a => { const x = biz.filter(b => lstOf(b) === a.p_list && !(a.p_skip || []).includes(b.id) && (!a.p_city || b.city === a.p_city) && (!a.p_sector || b.sector === a.p_sector))
      .sort((p, q) => q.lead_score - p.lead_score)[0]; return x ? [x] : []; }),
    release_business: () => null,
    move_to_call_list: needs('leads', a => { biz.find(b => b.id === a.p_business_id).call_list = true; return null; }),
    log_call: needs('leads', a => { const b = biz.find(x => x.id === a.p_business_id);
      if (a.p_outcome === 'callback' && !a.p_callback_at) return { error: { message: 'Geri arama tarihi gerekli' } };
      if (a.p_reason && !['rejected', 'do_not_contact'].includes(a.p_outcome)) return { error: { message: 'Geçersiz ret sebebi' } };
      b.status = a.p_outcome; b.attempt_count++; log.push({ ...a });
      if (['interested', 'won'].includes(a.p_outcome)) {
        const ex = custOf(b.id), stage = a.p_outcome === 'won' ? 'won' : 'contacted';
        if (!ex) { const id = 'c' + (++seq); customers.unshift({ id, business_id: b.id, name: b.name, phone: b.phone_raw, city: b.city, sector: b.sector, stage, next_step: null, next_step_at: null, stage_changed_at: now() });
          addNote(id, 'created', (stage === 'won' ? 'Satış kaydedildi' : 'İlgilendi, iletişime geçildi') + (a.p_note ? '\n' + a.p_note : '')); }
        else if (stage === 'won' && ex.stage !== 'won') { addNote(ex.id, 'stage', STAGE_TR[ex.stage] + ' → Satış tamamlandı'); ex.stage = 'won'; }
      }
      return null; }),
    list_counts: needs('leads', a => ['whatsapp', 'call', 'followup', 'sent'].map(l => ({ lst: l, n: biz.filter(b => lstOf(b) === l && (!a.p_city || b.city === a.p_city) && (!a.p_sector || b.sector === a.p_sector)).length })).filter(r => r.n)),
    filter_options: needs('leads', () => [...new Map(biz.filter(lstOf).map(b => [b.city + b.sector, { city: b.city, sector: b.sector }])).values()]),
    stats: needs('leads', () => [{ week_total: log.length + 7, week_wa: 3, today_total: log.length, today_wa: log.filter(l => l.p_outcome === 'wa_sent').length }]),
    search_history: needs('leads', a => log.filter(l => !a.p_term || JSON.stringify(l).includes(a.p_term)).map(l => ({ called_at: now(), outcome: l.p_outcome, note: l.p_note, reason: l.p_reason || null, name: biz.find(b => b.id === l.p_business_id).name, phone_raw: 'x', city: 'Ankara' }))),
    monthly_report: needs('leads', a => ({ month: (a.p_month || '').slice(0, 7), actions: 14, contacted: 12, wa_sent: 7, positive: 4, rejected: 3, unreachable: 2, won: 1,
      sales_count: 2, sales_qty: 3, sales_total: 8500, leads_found: ws.leads_this_month,
      reasons: [{ reason: 'price', label: 'Fiyat yüksek', n: 2 }, { reason: 'no_need', label: 'İhtiyacı yok', n: 1 }],
      sectors: [{ sector: 'diş kliniği', contacted: 8, positive: 3, won: 1 }], people: [{ name: 'Kerim', actions: 14, positive: 4, won: 1 }],
      products: [{ product: 'Danışmanlık', qty: 2, total: 6000 }] })),
    customer_timeline: needs('customers', a => [...(notes[a.p_id] || [])]),
    set_customer_stage: needs('customers_write', a => { const c = customers.find(x => x.id === a.p_id); const old = c.stage; c.stage = a.p_stage; c.stage_changed_at = now();
      addNote(c.id, 'stage', STAGE_TR[old] + ' → ' + STAGE_TR[a.p_stage] + (a.p_note ? '\n' + a.p_note : '')); return null; }),
    update_customer: needs('customers_write', a => { const c = customers.find(x => x.id === a.p_id);
      for (const [k, v] of Object.entries(a.p_patch)) c[k] = v === '' ? null : v;
      addNote(c.id, 'edit', 'Güncellendi: ' + Object.keys(a.p_patch).join(', ')); return null; }),
    add_customer_note: needs('customers_write', a => { addNote(a.p_id, 'note', a.p_body); return null; }),
    add_sale: needs('customers_write', a => { const c = customers.find(x => x.id === a.p_customer);
      const id = 's' + (++seq); sales.unshift({ id, customer_id: c.id, product: a.p_product, quantity: a.p_quantity, amount: a.p_amount, sold_at: now() });
      addNote(c.id, 'sale', `Satış: ${a.p_quantity} × ${a.p_product} — ${a.p_amount} TL`); if (c.stage !== 'won') { c.stage = 'won'; c.stage_changed_at = now(); } return id; }),
    delete_sale: needs('customers_write', a => { const i = sales.findIndex(s => s.id === a.p_id); const s = sales.splice(i, 1)[0]; addNote(s.customer_id, 'edit', 'Satış silindi: ' + s.product); return null; }),
    create_customer: needs('customers_write', a => { const id = 'c' + (++seq); customers.unshift({ id, business_id: null, name: a.p_name, phone: a.p_phone, city: a.p_city, sector: a.p_sector, stage: 'contacted',
      next_step: null, next_step_at: null, stage_changed_at: now() }); addNote(id, 'created', a.p_note || 'Müşteri elle eklendi'); return id; }),
    team_list: needs('team', () => users.filter(u => ws.is_platform || u.workspace_id === ws.id).map(u => ws.is_platform ? { ...u } : { ...u, company: null, phone: null })),
    admin_usage: a => (role === 'admin' && ws.is_platform) ? { month: (a.p_month || '').slice(0, 7), cost_per_call: 0.035,
      totals: { api_calls: 42, scans: 14, leads: 62, actions: log.length + 9, wa_sent: 3, won: 1, sales_total: 8500, active_users: 2, users: users.length,
        pending: users.filter(u => u.role === 'none').length },
      workspaces: [{ id: 'w0', name: 'Vitrin', is_platform: true, is_demo: false, lead_quota: null, members: 2, api_calls: 30, scans: 10, leads: 31, actions: 9, positive: 3, won: 1, sales_total: 8500, last_activity: now() },
                   { id: 'w1', name: 'Pilot Şirket', is_platform: false, is_demo: true, lead_quota: 500, members: 1, api_calls: 12, scans: 4, leads: 120, actions: 0, positive: 0, won: 0, sales_total: 0, last_activity: null }],
      users: users.map(u => ({ id: u.user_id, email: u.email, name: u.display_name || u.full_name || null, company: u.company || null, workspace: u.workspace_name, role: u.role,
        created_at: now(), last_sign_in_at: u.last_sign_in_at, actions: u.user_id === 'u1' ? 9 : 0, scans: u.user_id === 'u1' ? 10 : 0, api_calls: u.user_id === 'u1' ? 30 : 0, leads: 0, last_activity: null })) } : deny(),
    set_user_role: needs('team', a => { const u = users.find(x => x.user_id === a.p_user); u.role = a.p_role; if (a.p_name) u.display_name = a.p_name;
      if (a.p_workspace) { u.workspace_id = a.p_workspace; u.workspace_name = workspaces.find(w => w.id === a.p_workspace).name; } return null; }),
    list_workspaces: () => (role === 'admin' && ws.is_platform) ? workspaces.map(w => ({ ...w })) : deny(),
    create_workspace: a => (role === 'admin' && ws.is_platform) ? (workspaces.push({ id: 'w' + (++seq), slug: 'x', name: a.p_name, is_platform: false, is_demo: a.p_is_demo, lead_quota: a.p_quota, leads_this_month: 0, members: 0 }), 'w' + seq) : deny(),
    update_workspace: needs('team', a => {
      if (a.p_patch.message_template && !/iptal/i.test(a.p_patch.message_template)) return { error: { message: 'Mesajda "iptal" yazarak vazgeçme cümlesi bulunmalı' } };
      if (a.p_ws === ws.id) { const p = a.p_patch;
        if ('name' in p) ws.name = p.name; if ('weekly_goal' in p) ws.weekly_goal = p.weekly_goal; if ('wa_daily_limit' in p) ws.wa_daily_limit = p.wa_daily_limit;
        if ('message_template' in p) ws.message_template = p.message_template; if ('sector_suggestions' in p) ws.sector_suggestions = p.sector_suggestions.map(s => s.toLowerCase()); }
      const w = workspaces.find(x => x.id === a.p_ws); if (w && 'lead_quota' in a.p_patch) w.lead_quota = a.p_patch.lead_quota === '' ? null : Number(a.p_patch.lead_quota);
      if (w && 'is_demo' in a.p_patch) w.is_demo = a.p_patch.is_demo; return null; }),
  };

  const tableData = {
    calls: () => [{ called_at: now(), outcome: 'no_answer', note: 'meşguldü' }],
    scan_history: () => [{ scanned_at: now(), city: 'Ankara', district: 'Çankaya', sector: 'kuaför', places_found: 60, saved: 31 }],
    v_queue: () => biz.filter(b => lstOf(b) === 'sent').map(b => ({ ...b, lst: 'sent', updated_at: now() })),
    v_customers: () => customers.map(c => { const s = sales.filter(x => x.customer_id === c.id);
      return { ...c, last_note: lastNote(c), sales_total: s.reduce((a, x) => a + Number(x.amount), 0), sales_count: s.length }; }),
    customer_sales: () => sales.map(s => ({ ...s })),
  };
  const session = () => window.__loggedIn ? { access_token: 'tok', user: { id: 'u1' } } : null;
  window.supabase = { createClient: () => ({
    auth: {
      getSession: async () => ({ data: { session: session() } }),
      signInWithPassword: async ({ password }) => password === 'dogru' ? (window.__loggedIn = true, { error: null }) : { error: { message: 'bad' } },
      signOut: async () => { window.__loggedIn = false; },
      signUp: async ({ email, options }) => { (window.__signups = window.__signups || []).push({ email, data: options && options.data });
        return /^var@/.test(email) ? { data: {}, error: { message: 'User already registered' } } : { data: { user: { id: 'n1' }, session: null }, error: null }; },
      onAuthStateChange: () => ({}),
    },
    rpc: async (name, args) => {
      window.__calls.push([name, args]);
      const r = handlers[name](args || {});
      return r && r.error ? { data: null, error: r.error } : { data: r, error: null };
    },
    from: table => {
      window.__calls.push(['from:' + table]);
      const filters = [];
      const rows = () => (tableData[table] || (() => []))().filter(x => filters.every(f => f(x)));
      let head = false;
      const q = {
        select: (_cols, opts) => { head = !!(opts && opts.head); return q; },
        eq: (c, v) => { if (table !== 'calls' && table !== 'v_queue') filters.push(x => x[c] === v); return q; }, order: () => q,
        in: (c, vals) => { filters.push(x => vals.includes(x[c])); return q; },
        limit: () => Promise.resolve({ data: rows(), error: null }),
        range: (a, b) => { window.__ranges = (window.__ranges || []).concat([[table, a, b]]); return Promise.resolve({ data: rows().slice(a, b + 1), error: null }); },
        then: (res, rej) => { const r = rows(); return Promise.resolve(head ? { data: null, count: r.length, error: null } : { data: r, error: null }).then(res, rej); },
      };
      return q;
    },
  }) };
})();
