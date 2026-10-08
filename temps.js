// ═══════════════════════════════════════════════════════════════════════════
// TEMPS & ABSENCES (2026-10-07) — un seul onglet admin qui remplace Pointage
// (Suivi du jour / Rapports / Contrôle) et Congés. Maquette validée par Hugo :
// https://claude.ai/artifact/PGzJcd9fPGz8ELKtFBDkY2
//
// Trois vues : Aujourd'hui (présents, fil des badgeages), Mois (grille
// salariés × jours, verrouillage par semaine), Clôture paie (points à régler,
// verrouillage du mois, export CSV). Panneau latéral pour un jour ou un
// salarié, une fenêtre par action (ajout/modif/annulation de pointage,
// correction ± h, absence, verrous, PDF, ajustement CP). Réglages dans
// Paramètres → « Temps de travail ».
//
// Heures d'un jour : recalculées ici à partir des pointages bruts, avec la même
// règle que le trigger _sync_heures_journalieres (somme des cycles
// Entrée→Sortie, pauses pointées déduites) — pour afficher aussi les annulés
// et la sortie manquante.
// Heures sup : par semaine civile complète (lundi→dimanche) au-delà de
// heures_ref, les heures_25 premières à 25 %, au-delà 50 %. Une semaine à
// cheval sur deux mois est rattachée au mois de son vendredi (réglage
// « fin ») ou de son lundi (« debut ») — table rh_parametres_temps.
// Écritures uniquement via RPC (journalisées côté serveur dans rh_journal).
// ═══════════════════════════════════════════════════════════════════════════

const TA_JOURS = ['dimanche', 'lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi'];
const TA_MOIS_C = ['janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin', 'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.'];
const TA_MOIS_L = ['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'];
const TA_CODE = { cp: 'CP', maladie: 'MAL', evenement_familial: 'EVT', sans_solde: 'SS', autre: 'AUT' };
const TA_TYPE = { CP: 'cp', MAL: 'maladie', EVT: 'evenement_familial', SS: 'sans_solde', AUT: 'autre' };
const TA_ABS = { CP: 'Congé payé', MAL: 'Maladie', EVT: 'Événement familial', SS: 'Sans solde', AUT: 'Autre absence', F: 'Jour férié' };
const TA_HALF = { am: 'matin', pm: 'après-midi' };
const TA_SRC = { kiosque: 'PIN', nfc: 'Badge', admin: 'ajout admin', auto: 'auto' };

const TA = {
  tab: 'today', filter: 'all', feedRange: 'today',
  mo: null,              // { y, m } affiché dans Mois et Clôture
  loaded: false, loading: null,
  data: {},              // 'YYYY-MM' → jeu de données du mois (pointages, corrections, verrous)
  cfg: { semaine_cheval: 'fin', heures_ref: 35, heures_25: 8, cp_annuels: 25 },
  hol: new Map(), clot: new Map(), cpAdj: [], journal: [], conges: [],
  drawer: null, empTab: 'sum', empLog: null, draft: null, modal: null, busy: false,
  holDate: '', holName: '', channel: null, _reload: null,
};

// ── Dates & formats ─────────────────────────────────────────────────────────
function taEsc(s) { return String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }
function taPad(n) { return String(n).padStart(2, '0'); }
function taD(iso) { const [y, m, d] = iso.split('-').map(Number); return new Date(Date.UTC(y, m - 1, d)); }
function taIso(dt) { return dt.toISOString().slice(0, 10); }
function taAdd(iso, n) { const d = taD(iso); d.setUTCDate(d.getUTCDate() + n); return taIso(d); }
function taDow(iso) { return taD(iso).getUTCDay(); }
function taMonday(iso) { return taAdd(iso, -((taDow(iso) + 6) % 7)); }
function taIsWeekday(iso) { const w = taDow(iso); return w >= 1 && w <= 5; }
function taToday() { return _ptgLocalDateStr(new Date()); }
function taMonthKey(y, m) { return y + '-' + taPad(m); }
function taMonthOf(iso) { return { y: +iso.slice(0, 4), m: +iso.slice(5, 7) }; }
function taMonthFirst(y, m) { return `${y}-${taPad(m)}-01`; }
function taMonthLast(y, m) { return taAdd(m === 12 ? `${y + 1}-01-01` : `${y}-${taPad(m + 1)}-01`, -1); }
function taShiftMonth(mo, n) { const t = mo.y * 12 + (mo.m - 1) + n; return { y: Math.floor(t / 12), m: (t % 12) + 1 }; }
function taMonthLabel(mo) { return TA_MOIS_L[mo.m - 1] + ' ' + mo.y; }
function taCap(s) { return s.charAt(0).toUpperCase() + s.slice(1); }
function taIsoWeek(iso) {
  const d = taD(iso); const day = (d.getUTCDay() + 6) % 7;
  d.setUTCDate(d.getUTCDate() - day + 3);
  const firstThu = new Date(Date.UTC(d.getUTCFullYear(), 0, 4));
  return 1 + Math.round(((d - firstThu) / 86400000 - 3 + ((firstThu.getUTCDay() + 6) % 7)) / 7);
}
function taNice(iso) { const d = taD(iso); return TA_JOURS[d.getUTCDay()] + ' ' + d.getUTCDate() + ' ' + TA_MOIS_C[d.getUTCMonth()]; }
function taNiceLong(iso) { const d = taD(iso); return TA_JOURS[d.getUTCDay()] + ' ' + d.getUTCDate() + ' ' + TA_MOIS_L[d.getUTCMonth()] + ' ' + d.getUTCFullYear(); }
function taShort(iso) { const d = taD(iso); return d.getUTCDate() + ' ' + TA_MOIS_C[d.getUTCMonth()]; }
function taWeekLabel(mon) { const fri = taAdd(mon, 4); return mon.slice(5, 7) === fri.slice(5, 7) ? taD(mon).getUTCDate() + '–' + taShort(fri) : taShort(mon) + '–' + taShort(fri); }
function taFh(h) { const r = Math.round((h || 0) * 100) / 100; return String(r).replace('.', ','); }
function taFh1(h) { return taFh(Math.round((h || 0) * 10) / 10); }
function taHM(min) { const h = Math.floor(min / 60), m = Math.round(min - h * 60); return taPad(h) + ':' + taPad(m); }
function taDur(min) { const h = Math.floor(min / 60), m = Math.round(min - h * 60); return h + ' h ' + taPad(m); }
function taNum(v) { return parseFloat(String(v ?? '').replace(',', '.')); }
function taToMin(t) { const p = String(t || '').split(':'); if (p.length < 2 || p[0] === '') return NaN; return (+p[0]) * 60 + (+p[1]); }
function taParisHM(ts) { return new Date(ts).toLocaleTimeString('fr-FR', { timeZone: 'Europe/Paris', hour: '2-digit', minute: '2-digit' }); }
function taParisMin(ts) { return taToMin(taParisHM(ts)); }
function taNowMin() { return taParisMin(new Date()); }
function taNowTxt() { const n = new Date(); return taNiceLong(taToday()) + ' · ' + taParisHM(n); }
// 'YYYY-MM-DD' + 'HH:MM' heure de Paris → ISO UTC (gère heure d'été/hiver).
function taParisToUtc(iso, hhmm) {
  const [y, mo, d] = iso.split('-').map(Number), [h, mi] = hhmm.split(':').map(Number);
  const guess = Date.UTC(y, mo - 1, d, h, mi);
  const parts = {};
  new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/Paris', hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' })
    .formatToParts(new Date(guess)).forEach(p => { parts[p.type] = p.value; });
  const asUtc = Date.UTC(+parts.year, +parts.month - 1, +parts.day, +parts.hour, +parts.minute);
  return new Date(guess - (asUtc - guess)).toISOString();
}
function taEmp(id) { return employees.find(e => e.id === id) || null; }
function taName(e) { return e ? e.prenom + ' ' + e.nom : '?'; }
function taInContract(e, iso) { return (!e.date_entree || e.date_entree <= iso) && (!e.date_sortie || e.date_sortie >= iso); }
function taContrat(e) { return +e.heures_semaine || 35; }

// ── Chargement ──────────────────────────────────────────────────────────────
async function taLoadGlobals() {
  const db = window.SupabaseDB;
  const [cfg, hol, clot, adj, jr, cg] = await Promise.all([
    db.from('rh_parametres_temps').select('*').maybeSingle(),
    db.from('jours_feries').select('*').order('date'),
    db.from('mois_clotures').select('*'),
    db.from('cp_ajustements').select('*').order('created_at'),
    db.from('rh_journal').select('*').order('at', { ascending: false }).limit(300),
    db.rpc('get_conges_rh'),
  ]);
  const err = [cfg, hol, clot, adj, jr, cg].find(r => r.error);
  if (err) throw err.error;
  if (cfg.data) TA.cfg = { semaine_cheval: cfg.data.semaine_cheval, heures_ref: +cfg.data.heures_ref, heures_25: +cfg.data.heures_25, cp_annuels: +cfg.data.cp_annuels };
  TA.hol = new Map((hol.data || []).map(h => [h.date, h.libelle]));
  TA.clot = new Map((clot.data || []).map(c => [c.mois.slice(0, 7), c]));
  TA.cpAdj = adj.data || [];
  TA.journal = jr.data || [];
  TA.conges = cg.data || [];
  conges = TA.conges; // l'ancien onglet Congés et calcSoldeCP lisent cette variable
}

async function taLoadMonth(mo, into) {
  const db = window.SupabaseDB, key = taMonthKey(mo.y, mo.m);
  const first = taMonthFirst(mo.y, mo.m), last = taMonthLast(mo.y, mo.m), today = taToday();
  let start = taMonday(first);
  const end = taAdd(taMonday(last), 6);
  if (today >= first && today <= last && taAdd(today, -2) < start) start = taAdd(today, -2);
  const [p, c, sv, js] = await Promise.all([
    db.rpc('get_pointages_periode_rh', { p_debut: start, p_fin: end }),
    db.from('heures_corrections').select('*').gte('date', start).lte('date', end),
    db.from('semaines_validees').select('*').gte('semaine_debut', taMonday(start)).lte('semaine_debut', end),
    db.from('jours_statut').select('*').gte('date', start).lte('date', end),
  ]);
  const err = [p, c, sv, js].find(r => r.error);
  if (err) throw err.error;
  const ds = { key, mo, first, last, start, end, punches: new Map(), corr: new Map(), locks: new Map(), ferie: new Set() };
  (p.data || []).forEach(r => { const k = r.employe_id + '|' + r.date; if (!ds.punches.has(k)) ds.punches.set(k, []); ds.punches.get(k).push(r); });
  (c.data || []).forEach(r => { const k = r.employe_id + '|' + r.date; if (!ds.corr.has(k)) ds.corr.set(k, []); ds.corr.get(k).push(r); });
  (sv.data || []).forEach(r => ds.locks.set(r.employe_id + '|' + r.semaine_debut, r));
  (js.data || []).forEach(r => { if (r.statut === 'ferie') ds.ferie.add(r.employe_id + '|' + r.date); });
  (into || TA.data)[key] = ds;
  return ds;
}

function taDs(mo) { return TA.data[taMonthKey(mo.y, mo.m)] || null; }
function taCurMo() { return taMonthOf(taToday()); }

async function taReloadAll() {
  if (!employees.length) await syncEmployeesFromSupabase({ silent: true });
  const want = [taCurMo(), taShiftMonth(taCurMo(), -1)];
  if (TA.mo) want.push(TA.mo);
  Object.values(TA.data).forEach(d => want.push(d.mo));
  const uniq = [...new Map(want.map(m => [taMonthKey(m.y, m.m), m])).values()];
  // Charge dans un nouvel objet puis remplace d'un coup : l'écran reste utilisable pendant le rechargement.
  const fresh = {};
  await taLoadGlobals();
  await Promise.all(uniq.map(m => taLoadMonth(m, fresh)));
  TA.data = fresh;
}

async function taShow() {
  const root = document.getElementById('ta-root');
  if (!root) return;
  if (!TA.loaded) {
    root.innerHTML = '<div class="ta-empty">Chargement…</div>';
    try {
      await taReloadAll();
      TA.loaded = true;
    } catch (e) {
      root.innerHTML = `<div class="ta-note bad">Chargement impossible : ${taEsc(e.message || e)}</div>`;
      return;
    }
    if (!TA.mo) {
      // Par défaut : le mois précédent tant qu'il n'est pas clôturé, sinon le mois en cours.
      const prev = taShiftMonth(taCurMo(), -1), c = TA.clot.get(taMonthKey(prev.y, prev.m));
      TA.mo = c && c.cloture ? taCurMo() : prev;
    }
    taSubscribe();
  }
  taRender();
}

async function taRefresh(msg) {
  try { await taReloadAll(); } catch (e) { ptgToast('⚠ ' + (e.message || e)); }
  taRender();
  if (TA.drawer && TA.drawer.kind === 'emp' && TA.empTab === 'hist') taLoadEmpLog(TA.drawer.emp);
  if (msg) ptgToast(msg);
}

function taSubscribe() {
  const db = window.SupabaseDB;
  if (!db || TA.channel) return;
  const later = () => {
    clearTimeout(TA._reload);
    TA._reload = setTimeout(() => {
      // Ne recharge pas sous les doigts de quelqu'un qui saisit.
      if (TA.modal || TA.draft || !document.getElementById('tab-temps')?.classList.contains('active')) { TA.loaded = false; return; }
      taRefresh();
    }, 1500);
  };
  TA.channel = db.channel('ta-realtime');
  ['pointages', 'heures_corrections', 'semaines_validees'].forEach(t =>
    TA.channel.on('postgres_changes', { event: '*', schema: 'public', table: t }, later));
  TA.channel.subscribe();
}

// ── Calculs ─────────────────────────────────────────────────────────────────
// Même règle que le trigger _sync_heures_journalieres (voir en-tête).
// Plus de pause forfaitaire de 20 min au-delà de 6 h (retirée le 2026-10-07, décision Hugo :
// elle s'ajoutait à la pause déjeuner déjà badgée).
function taCalc(valid, nowMin) {
  let brute = 0, open = null, pause = 0, pOpen = null, lastES = null;
  valid.forEach(p => {
    const m = taParisMin(p.horodatage);
    if (p.type === 'ENTREE') { if (open === null) open = m; lastES = 'E'; }
    else if (p.type === 'SORTIE') { if (open !== null) { brute += m - open; open = null; } lastES = 'S'; }
    else if (p.type === 'PAUSE_DEBUT') pOpen = m;
    else if (p.type === 'PAUSE_FIN' && pOpen !== null) { pause += m - pOpen; pOpen = null; }
  });
  const net = open === null ? brute - pause : brute;
  const running = open !== null && nowMin != null ? Math.max(0, nowMin - open) : 0;
  return { min: net + running, missingOut: open !== null, openAt: open, lastES };
}

function taCongeOn(empId, iso) {
  return TA.conges.find(c => c.employe_id === empId && c.date_debut <= iso && c.date_fin >= iso) || null;
}

// État d'un jour pour un salarié. kind : hors | we | abs | work | empty | todo | future
function taDay(ds, empId, iso) {
  const e = taEmp(empId), k = empId + '|' + iso, today = taToday();
  if (!e || !taInContract(e, iso)) return { kind: 'hors', hours: 0, iso };
  const all = (ds.punches.get(k) || []).slice().sort((a, b) => a.horodatage < b.horodatage ? -1 : 1);
  const valid = all.filter(p => p.valide), corr = ds.corr.get(k) || [];
  const corrMin = corr.reduce((s, c) => s + c.delta_min, 0);
  const cg = taCongeOn(empId, iso), hol = TA.hol.get(iso) || (ds.ferie.has(k) ? 'Férié' : null);
  const base = { iso, punches: all, corr, corrMin, conge: cg, hours: 0 };
  if (valid.length || corr.length) {
    const c = taCalc(valid, iso === today ? taNowMin() : null);
    const hours = (c.min + corrMin) / 60;
    const missingOut = c.missingOut && iso < today;
    return Object.assign(base, { kind: 'work', hours, missingOut, running: c.missingOut && iso === today,
      half: cg && cg.demi_journee ? cg : null, bad: missingOut || (hours <= 0 && iso < today && !cg) });
  }
  if (hol && taIsWeekday(iso)) return Object.assign(base, { kind: 'abs', code: 'F', label: hol });
  if (cg && taIsWeekday(iso)) return Object.assign(base, { kind: 'abs', code: TA_CODE[cg.type] || '?', half: cg.demi_journee || null });
  if (!taIsWeekday(iso)) return Object.assign(base, { kind: 'we' });
  if (iso < today) return Object.assign(base, { kind: 'empty', bad: true });
  if (iso === today) return Object.assign(base, { kind: 'todo' });
  return Object.assign(base, { kind: 'future' });
}

function taMonthEmps(mo) {
  const first = taMonthFirst(mo.y, mo.m), last = taMonthLast(mo.y, mo.m);
  return employees
    .filter(e => (!e.date_entree || e.date_entree <= last) && (!e.date_sortie || e.date_sortie >= first))
    .slice().sort((a, b) => (a.nom + a.prenom).localeCompare(b.nom + b.prenom, 'fr'));
}

// Semaines (lundi) qui touchent les jours ouvrés du mois.
function taWeeks(mo) {
  const first = taMonthFirst(mo.y, mo.m), last = taMonthLast(mo.y, mo.m), out = [];
  for (let mon = taMonday(first); mon <= last; mon = taAdd(mon, 7)) {
    const wd = [0, 1, 2, 3, 4].map(i => taAdd(mon, i));
    const inMonth = wd.filter(d => d >= first && d <= last);
    if (!inMonth.length) continue;
    const cross = inMonth.length < 5;
    out.push({ mon, n: taIsoWeek(mon), days: inMonth, all: wd, cross, attach: taAttach(mon), label: taWeekLabel(mon) });
  }
  return out;
}
// Mois de paie (YYYY-MM) d'une semaine : celui de son vendredi (« fin ») ou de son lundi (« debut »).
function taAttach(mon) { return (TA.cfg.semaine_cheval === 'debut' ? mon : taAdd(mon, 4)).slice(0, 7); }
function taHs(fullH) { const over = Math.max(0, fullH - TA.cfg.heures_ref); return [Math.min(over, TA.cfg.heures_25), Math.max(0, over - TA.cfg.heures_25)]; }
function taLocked(ds, empId, mon) { return ds.locks.has(empId + '|' + mon); }
function taWeekFull(ds, empId, mon) { let t = 0; for (let i = 0; i < 7; i++) t += taDay(ds, empId, taAdd(mon, i)).hours; return t; }
function taWeekBad(ds, empId, mon) { let n = 0; for (let i = 0; i < 7; i++) if (taDay(ds, empId, taAdd(mon, i)).bad) n++; return n; }
function taEmpInWeek(e, mon) { return taInContract(e, mon) || taInContract(e, taAdd(mon, 4)); }

function taMonthSum(ds, empId) {
  const mo = ds.mo, key = taMonthKey(mo.y, mo.m);
  const r = { hours: 0, hs25: 0, hs50: 0, CP: 0, MAL: 0, EVT: 0, SS: 0, AUT: 0, F: 0, weeks: [] };
  taWeeks(mo).forEach(w => {
    let wt = 0;
    w.days.forEach(d => {
      const dd = taDay(ds, empId, d);
      wt += dd.hours;
      if (dd.kind === 'abs') r[dd.code] += dd.half ? 0.5 : 1;
      else if (dd.kind === 'work' && dd.half) r[TA_CODE[dd.half.type]] += 0.5;
    });
    const full = taWeekFull(ds, empId, w.mon), hs = taHs(full);
    if (w.attach === key) { r.hs25 += hs[0]; r.hs50 += hs[1]; }
    r.hours += wt;
    r.weeks.push({ w, inMonth: wt, full, hs, locked: taLocked(ds, empId, w.mon), bad: taWeekBad(ds, empId, w.mon) });
  });
  return r;
}

// Solde CP : acquis (prorata, cp_annuels/an, période 1er juin → 31 mai) − pris sur la période + ajustements.
function taCp(e) {
  const { debut, fin } = getCpPeriod();
  const today = new Date(), rate = TA.cfg.cp_annuels;
  const entree = e.date_entree ? new Date(e.date_entree + 'T00:00:00') : debut;
  const from = entree > debut ? entree : debut, to = today < fin ? today : fin;
  const acquis = Math.min(rate, Math.max(0, (to - from) / 86400000) / 30.44 * (rate / 12));
  const d0 = _ptgLocalDateStr(debut), d1 = _ptgLocalDateStr(fin);
  const pris = TA.conges.filter(c => c.employe_id === e.id && c.type === 'cp' && c.date_debut >= d0 && c.date_debut <= d1)
    .reduce((s, c) => s + parseFloat(c.jours), 0);
  const adj = TA.cpAdj.filter(a => a.employe_id === e.id && a.created_at.slice(0, 10) >= d0);
  const adjSum = adj.reduce((s, a) => s + parseFloat(a.jours), 0);
  return { acquis: Math.round(acquis * 10) / 10, pris, adj, adjSum, solde: Math.round((acquis - pris + adjSum) * 10) / 10 };
}

function taWorkdays(from, to) {
  if (!from || !to || to < from) return [];
  const out = [];
  for (let d = from, g = 0; d <= to && g < 400; d = taAdd(d, 1), g++) if (taIsWeekday(d) && !TA.hol.has(d)) out.push(d);
  return out;
}

function taIssues(ds) {
  const out = [], mo = ds.mo;
  taMonthEmps(mo).forEach(e => taWeeks(mo).forEach(w => w.days.forEach(d => {
    const dd = taDay(ds, e.id, d);
    if (dd.bad) out.push({ e, d, dd, w });
  })));
  return out;
}

// Jeu de données qui contient une date (mois chargés), ou null.
function taDsFor(iso) {
  const mo = taMonthOf(iso), ds = taDs(mo);
  if (ds) return ds;
  return Object.values(TA.data).find(d => iso >= d.start && iso <= d.end) || null;
}
function taLockedOn(empId, iso) { const ds = taDsFor(iso); return ds ? taLocked(ds, empId, taMonday(iso)) : false; }

// ── Rendu principal ─────────────────────────────────────────────────────────
function taGo(patch) { Object.assign(TA, patch); taRender(); }

function taRender() {
  const root = document.getElementById('ta-root');
  if (!root || !TA.loaded) return;
  const tabs = [['today', 'Aujourd’hui'], ['month', 'Mois'], ['close', 'Clôture paie']];
  const sub = TA.tab === 'today' ? taNowTxt() : TA.tab === 'month' ? 'contrôle du mois, salarié par salarié' : taMonthLabel(TA.mo) + ' · à faire avant l’envoi au prestataire';
  let body = '';
  try {
    body = TA.tab === 'today' ? taRenderToday() : TA.tab === 'month' ? taRenderMonth() : taRenderClose();
  } catch (e) { console.error(e); body = `<div class="ta-note bad">Erreur d’affichage : ${taEsc(e.message)}</div>`; }
  root.innerHTML = `
    <div class="ta-head">
      <div><h2 class="ta-title">Temps & absences</h2><div class="ta-sub">${taEsc(sub)}</div></div>
      <div class="ta-tabs">${tabs.map(t => `<button class="ta-tab${TA.tab === t[0] ? ' on' : ''}" onclick="taGo({tab:'${t[0]}',drawer:null})">${t[1]}</button>`).join('')}</div>
    </div>
    ${body}
    <div class="ta-legacy">Anciens écrans, gardés pendant la validation :
      <a href="#" onclick="showTab('pointage');return false">Pointage</a> ·
      <a href="#" onclick="showTab('conges');return false">Congés</a></div>`;
  taRenderDrawer();
  taRenderModal();
}

// ── Aujourd'hui ─────────────────────────────────────────────────────────────
function taTodayOf(ds, e) {
  const today = taToday(), dd = taDay(ds, e.id, today);
  const valid = dd.punches ? dd.punches.filter(p => p.valide) : [];
  const firstE = valid.find(p => p.type === 'ENTREE'), lastE = valid.slice().reverse().find(p => p.type === 'ENTREE');
  const lastS = valid.slice().reverse().find(p => p.type === 'SORTIE');
  if (dd.kind === 'hors') return { st: 'hors', label: 'Hors contrat', min: 0 };
  if (dd.kind === 'abs') return { st: 'absent', label: TA_ABS[dd.code] + (dd.code === 'F' ? ' — ' + dd.label : '') + (dd.half ? ' (' + TA_HALF[dd.half] + ')' : ''), min: 0 };
  if (dd.kind === 'we') return { st: 'absent', label: 'Week-end', min: 0 };
  if (dd.kind === 'work' && dd.running) return { st: 'present', label: 'Présent depuis ' + taParisHM(lastE.horodatage), min: dd.hours * 60 };
  if (dd.kind === 'work') {
    const arr = firstE ? ' (arrivé ' + taParisHM(firstE.horodatage) + ')' : '';
    return { st: 'left', label: lastS ? 'Parti à ' + taParisHM(lastS.horodatage) + arr : 'Correction saisie', min: dd.hours * 60 };
  }
  return { st: 'missing', label: 'Pas encore pointé', min: 0 };
}

function taRenderToday() {
  const ds = taDs(taCurMo()), today = taToday(), mon = taMonday(today);
  const emps = taMonthEmps(taCurMo()).filter(e => taInContract(e, today));
  const counts = { present: 0, left: 0, absent: 0, missing: 0 };
  const rows = [];
  emps.forEach(e => {
    const t = taTodayOf(ds, e);
    if (counts[t.st] !== undefined) counts[t.st]++;
    if (TA.filter !== 'all' && TA.filter !== 'feed' && TA.filter !== t.st) return;
    let wk = 0, mo = 0;
    for (let d = mon; d <= today; d = taAdd(d, 1)) wk += taDay(taDsFor(d) || ds, e.id, d).hours;
    for (let d = ds.first; d <= today; d = taAdd(d, 1)) mo += taDay(ds, e.id, d).hours;
    const cp = taCp(e), c = taContrat(e);
    let acts = '';
    if (t.st === 'missing') acts = `<button class="btn btn-ghost btn-sm" onclick="taOpen('punch',{emp:'${e.id}',type:'ENTREE',date:'${today}',time:taHM(taNowMin())})">Pointer l’arrivée</button>
      <button class="btn btn-ghost btn-sm" onclick="taOpen('abs',{emp:'${e.id}',from:'${today}',to:'${today}'})">Absence</button>`;
    else if (t.st === 'present') acts = `<button class="btn btn-ghost btn-sm" onclick="taOpen('punch',{emp:'${e.id}',type:'SORTIE',date:'${today}',time:taHM(taNowMin())})">Pointer la sortie</button>`;
    const dot = { absent: 'var(--blue)', missing: 'var(--danger)', left: 'var(--muted)', present: 'var(--success)' }[t.st] || 'var(--muted)';
    rows.push(`<tr>
      <td><button class="ta-link" onclick="taOpenEmp('${e.id}')">${taEsc(taName(e))}</button><div class="ta-small">${taEsc(e.poste || '')}</div></td>
      <td><span class="ta-dot" style="background:${dot}"></span>${taEsc(t.label)}</td>
      <td class="num">${t.min ? taDur(t.min) : '—'}</td>
      <td><div class="num">${taFh1(wk)} h / ${taFh(c)} h</div><div class="ta-bar"><i style="width:${Math.min(100, Math.round(wk / c * 100))}%"></i></div></td>
      <td class="num">${taFh1(mo)} h</td>
      <td class="num">${taFh(cp.solde)} j</td>
      <td class="ta-acts-td"><div class="ta-acts">${acts}</div></td></tr>`);
  });
  const chipDef = [['all', 'Tout le monde', emps.length], ['present', 'Présents en ce moment', counts.present], ['left', 'Partis', counts.left],
    ['absent', 'Absents prévus', counts.absent], ['missing', 'Pas encore pointé', counts.missing]];
  const feed = taFeed(ds);
  const chips = chipDef.map(c => `<button class="ta-chip${TA.filter === c[0] ? ' on' : ''}" onclick="taGo({filter:'${c[0]}'})"><b>${c[2]}</b><span>${c[1]}</span></button>`).join('')
    + `<button class="ta-chip${TA.filter === 'feed' ? ' on' : ''}" onclick="taGo({filter:TA.filter==='feed'?'all':'feed'})"><b>${feed.todayCount}</b><span>Badgeages du jour</span></button>`;

  // Alertes : mois précédent pas clôturé.
  const prev = taShiftMonth(taCurMo(), -1), pds = taDs(prev), pc = TA.clot.get(taMonthKey(prev.y, prev.m));
  let alerts = '';
  if (pds && !(pc && pc.cloture)) {
    const n = taIssues(pds).length;
    alerts = `<div class="ta-alert"><span>${taCap(taMonthLabel(prev))} n’est pas clôturé${n ? ' : ' + n + ' jour(s) à régler' : ''} avant l’export paie.</span>
      <button class="btn btn-ghost btn-sm" onclick="taGo({tab:'close',mo:{y:${prev.y},m:${prev.m}},drawer:null})">Ouvrir la clôture</button></div>`;
  }
  const table = TA.filter === 'feed' ? '' : `
    <div class="ta-card ta-scroll"><table class="ta-table"><thead><tr><th>Salarié</th><th>Statut</th><th>Aujourd’hui</th><th>Semaine</th><th>Mois</th><th>CP restants</th><th>Action rapide</th></tr></thead>
    <tbody>${rows.join('') || '<tr><td colspan="7" class="ta-empty">Personne dans ce filtre.</td></tr>'}</tbody></table></div>`;
  return `
    <div class="ta-toolbar">
      <button class="btn btn-primary btn-sm" onclick="taOpen('punch',{date:'${today}',time:taHM(taNowMin())})">+ Ajouter un pointage</button>
      <button class="btn btn-ghost btn-sm" onclick="taOpen('abs',{from:'${today}',to:'${today}'})">+ Saisir une absence</button>
    </div>
    <div class="ta-chips">${chips}</div>
    ${alerts}
    <div class="ta-today${TA.filter === 'feed' ? ' feed-only' : ''}">${table}${feed.html}</div>`;
}

function taFeed(ds) {
  const today = taToday(), days = TA.feedRange === '3d' ? [today, taAdd(today, -1), taAdd(today, -2)] : [today];
  let todayCount = 0;
  const groups = days.map(d => {
    const items = [];
    const dsd = taDsFor(d) || ds;
    dsd.punches.forEach((list, k) => {
      if (!k.endsWith('|' + d)) return;
      list.forEach(p => { if (p.valide && (p.type === 'ENTREE' || p.type === 'SORTIE')) items.push(p); });
    });
    items.sort((a, b) => a.horodatage < b.horodatage ? 1 : -1);
    if (d === today) todayCount = items.length;
    const label = d === today ? 'Aujourd’hui · ' + taNice(d) : taCap(taNice(d));
    return `<div class="ta-feed-day">${taEsc(label)}</div>` + (items.length ? items.map(p => `
      <div class="ta-feed-row"><span class="ta-time">${taParisHM(p.horodatage)}</span>
        <span class="ta-tag ${p.type === 'ENTREE' ? 'in' : 'out'}">${p.type === 'ENTREE' ? 'Entrée' : 'Sortie'}</span>
        <span class="ta-feed-name">${taEsc(taName(taEmp(p.employe_id)))}</span><span class="ta-small">${TA_SRC[p.source] || p.source}</span></div>`).join('')
      : '<div class="ta-small" style="padding:6px 0">Aucun badgeage.</div>');
  }).join('');
  const ranges = [['today', 'Aujourd’hui'], ['3d', '3 jours']].map(r => `<button class="ta-mini${TA.feedRange === r[0] ? ' on' : ''}" onclick="taGo({feedRange:'${r[0]}'})">${r[1]}</button>`).join('');
  return { todayCount, html: `<div class="ta-card ta-feed"><div class="ta-feed-head"><b>Fil des badgeages</b><span>${ranges}</span></div>${groups}</div>` };
}

// ── Mois ────────────────────────────────────────────────────────────────────
const TA_CELL = { work: 'c-work', CP: 'c-cp', MAL: 'c-mal', EVT: 'c-evt', SS: 'c-ss', AUT: 'c-aut', F: 'c-f', BAD: 'c-bad' };

function taMonthNav() {
  const mo = TA.mo, key = taMonthKey(mo.y, mo.m), c = TA.clot.get(key), cur = taCurMo();
  const next = taShiftMonth(mo, 1), nextDis = next.y * 12 + next.m > cur.y * 12 + cur.m;
  const sub = c && c.cloture ? 'clôturé' + (c.exporte_le ? (c.export_perime ? ' · export à refaire' : ' · exporté') : '')
    : (key === taMonthKey(cur.y, cur.m) ? 'en cours' : taWeeks(mo).reduce((s, w) => s + w.days.filter(d => !TA.hol.has(d)).length, 0) + ' jours ouvrés');
  return `<div class="ta-monthnav">
    <button class="btn btn-ghost btn-sm" onclick="taGoMonth(-1)" aria-label="Mois précédent">◀</button>
    <div><b>${taCap(taMonthLabel(mo))}</b><div class="ta-small">${sub}</div></div>
    <button class="btn btn-ghost btn-sm" onclick="taGoMonth(1)" ${nextDis ? 'disabled' : ''} aria-label="Mois suivant">▶</button></div>`;
}

async function taGoMonth(n) {
  const mo = taShiftMonth(TA.mo, n);
  TA.mo = mo; TA.drawer = null;
  if (!taDs(mo)) {
    try { await taLoadMonth(mo); } catch (e) { ptgToast('⚠ ' + (e.message || e)); }
  }
  taRender();
}

function taRenderMonth() {
  const ds = taDs(TA.mo);
  if (!ds) { taGoMonth(0); return '<div class="ta-empty">Chargement…</div>'; }
  const mo = TA.mo, key = taMonthKey(mo.y, mo.m), weeks = taWeeks(mo), emps = taMonthEmps(mo), clot = TA.clot.get(key);
  let cols = 'minmax(150px,1.6fr)';
  let head = '<div class="ta-gh name">Salarié</div>';
  weeks.forEach(w => {
    w.days.forEach(d => { cols += ' minmax(30px,1fr)'; head += `<div class="ta-gh day${TA.hol.has(d) ? ' hol' : ''}" title="${taEsc(TA.hol.get(d) || '')}"><b>${taD(d).getUTCDate()}</b><span>${'LMMJV'[taDow(d) - 1]}</span></div>`; });
    cols += ' minmax(52px,1.5fr)';
    const allLk = emps.filter(e => taEmpInWeek(e, w.mon)).every(e => taLocked(ds, e.id, w.mon));
    const att = w.attach === key ? '' : w.attach;
    const subTxt = w.cross ? 'HS en ' + TA_MOIS_L[+w.attach.slice(5) - 1] : (allLk ? 'verrouillée' : 'semaine');
    head += `<button class="ta-gh week${w.cross ? ' cross' : ''}${att ? ' other' : ''}" onclick="taOpen('lockWeek',{mon:'${w.mon}'})" title="Vérifier et verrouiller la semaine">
      <b>${allLk ? '🔒 ' : ''}S${w.n}</b><span>${subTxt}</span></button>`;
  });
  cols += ' minmax(56px,1.3fr) minmax(48px,1.1fr) minmax(48px,1.1fr) minmax(96px,2.2fr) minmax(48px,1.1fr)';
  head += '<div class="ta-gh tot">Mois</div><div class="ta-gh tot">HS 25 %</div><div class="ta-gh tot">HS 50 %</div><div class="ta-gh tot">Absences</div><div class="ta-gh tot">CP</div>';
  let rows = '';
  emps.forEach(e => {
    const m = taMonthSum(ds, e.id);
    rows += `<button class="ta-gname" onclick="taOpenEmp('${e.id}')">${taEsc(taName(e))}</button>`;
    m.weeks.forEach(wk => {
      wk.w.days.forEach(d => {
        const dd = taDay(ds, e.id, d);
        let label = '', cls = '';
        if (dd.kind === 'hors') { label = ''; cls = 'c-hors'; }
        else if (dd.bad) { label = '!'; cls = TA_CELL.BAD; }
        else if (dd.kind === 'abs') { label = dd.code + (dd.half ? '½' : ''); cls = TA_CELL[dd.code]; }
        else if (dd.kind === 'work') { label = taFh1(dd.hours); cls = TA_CELL.work + (dd.running ? ' c-run' : ''); }
        else if (dd.kind === 'todo') { label = '·'; cls = 'c-todo'; }
        else { label = ''; cls = 'c-future'; }
        const sel = TA.drawer && TA.drawer.kind === 'day' && TA.drawer.emp === e.id && TA.drawer.iso === d;
        rows += `<button class="ta-cell ${cls}${wk.locked ? ' lk' : ''}${sel ? ' sel' : ''}" onclick="taOpenDay('${e.id}','${d}')" aria-label="${taEsc(taName(e) + ', ' + taNice(d))}">${label}</button>`;
      });
      const tip = wk.w.cross ? `Semaine complète : ${taFh(wk.full)} h dont ${taFh(wk.inMonth)} h en ${TA_MOIS_L[mo.m - 1]}` : '';
      rows += `<div class="ta-wk${wk.locked ? ' lk' : ''}${wk.w.cross ? ' cross' : ''}${wk.bad ? ' bad' : ''}" title="${taEsc(tip)}">${wk.locked ? '🔒' : ''}${taFh1(wk.full)}</div>`;
    });
    const abs = ['CP', 'MAL', 'EVT', 'SS', 'AUT', 'F'].filter(c => m[c]).map(c => taFh(m[c]) + ' ' + c).join(' · ') || '—';
    rows += `<div class="ta-tot">${taFh1(m.hours)}</div><div class="ta-tot">${m.hs25 ? taFh(m.hs25) : '—'}</div><div class="ta-tot">${m.hs50 ? taFh(m.hs50) : '—'}</div>
      <div class="ta-tot small">${abs}</div><div class="ta-tot">${taFh(taCp(e).solde)}</div>`;
  });
  const issues = taIssues(ds);
  const legend = [['7', 'heures', 'work'], ['CP', 'congé payé', 'CP'], ['MAL', 'maladie', 'MAL'], ['EVT', 'év. familial', 'EVT'], ['SS', 'sans solde', 'SS'],
    ['AUT', 'autre', 'AUT'], ['F', 'férié', 'F'], ['!', 'à régler', 'BAD']].map(l => `<span><i class="ta-cell ${TA_CELL[l[2]]}">${l[0]}</i>${l[1]}</span>`).join('');
  let banner = '';
  if (clot && clot.cloture) banner = taClosedCard(mo, clot);
  else if (issues.length) banner = `<div class="ta-alert"><span>${issues.length} jour(s) en rouge à régler avant de pouvoir clôturer ${TA_MOIS_L[mo.m - 1]}.</span>
    <button class="btn btn-ghost btn-sm" onclick="taGo({tab:'close',drawer:null})">Voir la liste</button></div>`;
  return `${taMonthNav()}${banner}
    <div class="ta-legend">${legend}<span class="ta-small">· clic sur un jour pour le détail, sur « S » pour verrouiller la semaine · encadré pointillé : semaine à cheval sur deux mois</span></div>
    <div class="ta-card ta-scroll"><div class="ta-grid" style="grid-template-columns:${cols}">${head}${rows}</div></div>`;
}

function taClosedCard(mo, c) {
  const fname = 'paie-' + taMonthKey(mo.y, mo.m) + '.csv';
  const dt = ts => taShort(ts.slice(0, 10)) + ' à ' + taParisHM(ts);
  return `<div class="ta-note good ta-row"><span>🔒 ${taCap(taMonthLabel(mo))} clôturé le ${dt(c.cloture_le)} par ${taEsc(c.cloture_par || '')}${c.exporte_le ? ' · exporté le ' + dt(c.exporte_le) + ' par ' + taEsc(c.exporte_par || '') : ' · pas encore exporté'}.</span>
    <span><button class="btn btn-ghost btn-sm" onclick="taDownloadCsv()">${c.exporte_le ? 'Retélécharger' : 'Télécharger'} ${fname}</button>
    <button class="btn btn-ghost btn-sm" onclick="taOpen('unlockMonth',{})">Déverrouiller…</button></span></div>`;
}

// ── Clôture ─────────────────────────────────────────────────────────────────
function taBlockers(ds) {
  const mo = ds.mo, emps = taMonthEmps(mo), out = [];
  taIssues(ds).forEach(i => {
    const what = i.dd.kind === 'empty' ? (i.dd.punches.length ? 'Pointages annulés : 0 h ce jour-là' : 'Aucun pointage, aucune absence') : (i.dd.missingOut ? 'Entrée sans sortie' : '0 h ce jour-là');
    out.push({ kind: 'day', title: taName(i.e) + ' — ' + taNice(i.d), sub: what, go: `taOpenDay('${i.e.id}','${i.d}')`, cta: 'Ouvrir' });
  });
  taWeeks(mo).forEach(w => {
    const open = emps.filter(e => taEmpInWeek(e, w.mon) && !taLocked(ds, e.id, w.mon));
    if (!open.length) return;
    const names = open.length === emps.filter(e => taEmpInWeek(e, w.mon)).length ? 'tous les salariés' : open.map(taName).join(', ');
    out.push({ kind: 'week', title: `Semaine S${w.n} (${w.label}) non verrouillée`, sub: names, go: `taOpen('lockWeek',{mon:'${w.mon}'})`, cta: 'Vérifier et verrouiller' });
  });
  return out;
}

function taCsvRows(ds) {
  return taMonthEmps(ds.mo).map(e => {
    const m = taMonthSum(ds, e.id);
    return { e, m, normales: Math.max(0, Math.round((m.hours - m.hs25 - m.hs50) * 100) / 100) };
  });
}

function taRenderClose() {
  const ds = taDs(TA.mo);
  if (!ds) { taGoMonth(0); return '<div class="ta-empty">Chargement…</div>'; }
  const mo = TA.mo, key = taMonthKey(mo.y, mo.m), c = TA.clot.get(key), closed = !!(c && c.cloture);
  const blockers = closed ? [] : taBlockers(ds), noBlock = blockers.length === 0;
  const fname = 'paie-' + key + '.csv';
  const badge = st => `<span class="ta-step ${st}">${st === 'done' ? '✓' : ''}</span>`;
  const s1 = noBlock || closed ? 'done' : 'on', s2 = closed ? 'done' : (noBlock ? 'on' : 'off'), s3 = closed ? (c.exporte_le && !c.export_perime ? 'done' : 'on') : 'off';
  const rows = taCsvRows(ds);
  const tot = rows.reduce((t, r) => { t.h += r.m.hours; t.hs25 += r.m.hs25; t.hs50 += r.m.hs50; return t; }, { h: 0, hs25: 0, hs50: 0 });
  let exportNote = '';
  if (c && c.exporte_le) {
    const at = taShort(c.exporte_le.slice(0, 10)) + ' à ' + taParisHM(c.exporte_le);
    exportNote = c.export_perime
      ? `<div class="ta-note warn">${taCap(TA_MOIS_L[mo.m - 1])} a été déverrouillé après l’export du ${at} : le fichier envoyé n’est plus à jour. Reverrouille, retélécharge et préviens le prestataire que le précédent est annulé.</div>`
      : `<div class="ta-note good">Exporté le ${at} par ${taEsc(c.exporte_par || '')} · ${fname} (séparateur « ; », décimales à virgule).</div>`;
  }
  const attachTxt = taWeeks(mo).filter(w => w.cross).map(w => `S${w.n} → ${TA_MOIS_L[+w.attach.slice(5) - 1]}`).join(', ');
  return `${taMonthNav()}
    <div class="ta-steps">
      <div class="ta-card ta-stepcard"><div class="ta-stephead">${badge(s1)}<b>1. Régler les points ouverts</b><span class="ta-small">${closed ? 'mois clôturé' : noBlock ? 'tout est réglé' : blockers.length + ' point(s)'}</span></div>
        ${blockers.map(b => `<div class="ta-block"><span class="ta-bdot ${b.kind}"></span><div><b>${taEsc(b.title)}</b><div class="ta-small">${taEsc(b.sub)}</div></div>
          <button class="btn btn-ghost btn-sm" onclick="${b.go}">${b.cta}</button></div>`).join('')}
        ${noBlock && !closed ? '<div class="ta-small">Aucun jour en rouge, toutes les semaines sont verrouillées.</div>' : ''}</div>
      <div class="ta-card ta-stepcard"><div class="ta-stephead">${badge(s2)}<b>2. Verrouiller le mois</b></div>
        ${closed ? `<div class="ta-small">Verrouillé le ${taShort(c.cloture_le.slice(0, 10))} par ${taEsc(c.cloture_par || '')}.</div>
          <button class="btn btn-ghost btn-sm" onclick="taOpen('unlockMonth',{})">Déverrouiller…</button>`
        : `<div class="ta-small">Possible quand l’étape 1 est terminée.</div>
          <button class="btn btn-primary btn-sm" ${noBlock ? '' : 'disabled'} onclick="taOpen('lockMonth',{})">Verrouiller ${TA_MOIS_L[mo.m - 1]}</button>`}</div>
      <div class="ta-card ta-stepcard"><div class="ta-stephead">${badge(s3)}<b>3. Exporter pour la paie</b></div>
        ${exportNote}
        <button class="btn btn-primary btn-sm" ${closed ? '' : 'disabled'} onclick="taDownloadCsv()">${c && c.exporte_le && !c.export_perime ? 'Retélécharger' : 'Télécharger'} ${fname}</button></div>
    </div>
    <div class="ta-card ta-scroll" style="margin-top:12px"><div class="ta-cardhead"><b>Aperçu du CSV</b><span class="ta-small">${rows.length} salariés · ${taFh1(tot.h)} h · HS 25 % : ${taFh(tot.hs25)} h · HS 50 % : ${taFh(tot.hs50)} h</span></div>
      <table class="ta-table${closed ? '' : ' dim'}"><thead><tr><th>Nom</th><th>Prénom</th><th>H. normales</th><th>HS 25 %</th><th>HS 50 %</th><th>CP (j)</th><th>Maladie (j)</th><th>Év. fam. (j)</th><th>Sans solde (j)</th><th>Autre (j)</th><th>Fériés (j)</th></tr></thead>
      <tbody>${rows.map(r => `<tr><td>${taEsc(r.e.nom.toUpperCase())}</td><td>${taEsc(r.e.prenom)}</td><td class="num">${taFh(r.normales)}</td><td class="num">${taFh(r.m.hs25)}</td><td class="num">${taFh(r.m.hs50)}</td>
        <td class="num">${taFh(r.m.CP)}</td><td class="num">${taFh(r.m.MAL)}</td><td class="num">${taFh(r.m.EVT)}</td><td class="num">${taFh(r.m.SS)}</td><td class="num">${taFh(r.m.AUT)}</td><td class="num">${taFh(r.m.F)}</td></tr>`).join('')}</tbody></table>
      <div class="ta-small" style="padding:8px 12px">Heures sup calculées par semaine complète au-delà de ${taFh(TA.cfg.heures_ref)} h : les ${taFh(TA.cfg.heures_25)} premières à 25 %, au-delà à 50 %.${attachTxt ? ' Semaines à cheval : ' + attachTxt + ' (réglage Paramètres).' : ''} Colonnes provisoires en attendant le modèle du prestataire.</div></div>
    <div class="ta-card" style="margin-top:12px"><div class="ta-cardhead"><b>Journal des modifications</b><span class="ta-small">${TA.journal.length >= 300 ? '300 dernières' : TA.journal.length} entrées</span></div>
      ${taJournalHtml(TA.journal, true)}</div>`;
}

function taJournalHtml(list, withEmp) {
  if (!list.length) return '<div class="ta-small" style="padding:10px 12px">Aucune modification enregistrée.</div>';
  return '<div class="ta-journal">' + list.map(j => {
    const at = taShort(j.at.slice(0, 10)) + ' ' + taParisHM(j.at), e = j.employe_id ? taEmp(j.employe_id) : null;
    return `<div class="ta-jrow"><span class="ta-small">${at}</span><span class="ta-small">${taEsc(j.auteur)}</span>
      <span>${withEmp && e ? '<b>' + taEsc(taName(e)) + '</b> — ' : ''}${taEsc(j.action)}${j.motif ? '<span class="ta-small"> · motif : ' + taEsc(j.motif) + '</span>' : ''}</span></div>`;
  }).join('') + '</div>';
}

function taCsvText(ds) {
  const f = n => taFh(n);
  const head = ['Nom', 'Prénom', 'Heures normales', 'HS 25 %', 'HS 50 %', 'CP (j)', 'Maladie (j)', 'Événement familial (j)', 'Sans solde (j)', 'Autre (j)', 'Fériés (j)'];
  const q = s => /[;"\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  const lines = taCsvRows(ds).map(r => [r.e.nom.toUpperCase(), r.e.prenom, f(r.normales), f(r.m.hs25), f(r.m.hs50), f(r.m.CP), f(r.m.MAL), f(r.m.EVT), f(r.m.SS), f(r.m.AUT), f(r.m.F)].map(q).join(';'));
  return '﻿' + [head.join(';')].concat(lines).join('\r\n') + '\r\n';
}

async function taDownloadCsv() {
  const ds = taDs(TA.mo), key = taMonthKey(TA.mo.y, TA.mo.m), c = TA.clot.get(key);
  if (!ds || !c || !c.cloture) { ptgToast('Verrouille le mois avant l’export.'); return; }
  const fname = 'paie-' + key + '.csv';
  const blob = new Blob([taCsvText(ds)], { type: 'text/csv;charset=utf-8' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob); a.download = fname; document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 2000);
  const { data, error } = await window.SupabaseDB.rpc('marquer_export_mois', { p_mois: taMonthFirst(TA.mo.y, TA.mo.m), p_fichier: fname });
  if (error || !data?.ok) { ptgToast('⚠ Fichier téléchargé, mais l’export n’a pas été noté : ' + (error?.message || data?.message)); return; }
  taRefresh(fname + ' téléchargé');
}

// ── Panneau latéral ─────────────────────────────────────────────────────────
function taOpenDay(empId, iso) { TA.drawer = { kind: 'day', emp: empId, iso }; TA.draft = null; taRender(); }
function taOpenEmp(empId) { TA.drawer = { kind: 'emp', emp: empId }; TA.empTab = 'sum'; TA.empLog = null; taRender(); }
function taCloseDrawer() { TA.drawer = null; TA.draft = null; taRender(); }

async function taLoadEmpLog(empId) {
  const { data, error } = await window.SupabaseDB.from('rh_journal').select('*').eq('employe_id', empId).order('at', { ascending: false }).limit(100);
  TA.empLog = error ? [] : (data || []);
  if (TA.drawer && TA.drawer.emp === empId) taRenderDrawer();
}

function taRenderDrawer() {
  let el = document.getElementById('ta-drawer');
  if (!el) { el = document.createElement('div'); el.id = 'ta-drawer'; document.body.appendChild(el); }
  const dr = TA.drawer;
  if (!dr || !document.getElementById('tab-temps')?.classList.contains('active')) { el.className = ''; el.innerHTML = ''; return; }
  const e = taEmp(dr.emp);
  if (!e) { el.className = ''; el.innerHTML = ''; return; }
  const html = dr.kind === 'day' ? taDrawerDay(e, dr.iso) : taDrawerEmp(e);
  el.className = 'open';
  el.innerHTML = `<div class="ta-dr-back" onclick="taCloseDrawer()"></div><aside class="ta-dr" role="dialog" aria-label="Détail">${html}</aside>`;
}

function taDrawerDay(e, iso) {
  const ds = taDsFor(iso);
  if (!ds) { taLoadMonth(taMonthOf(iso)).then(taRender); return '<div class="ta-empty">Chargement…</div>'; }
  const dd = taDay(ds, e.id, iso), mon = taMonday(iso), lk = taLocked(ds, e.id, mon), today = taToday();
  const head = `<div class="ta-dr-head"><div><h3>${taEsc(taName(e))}</h3><div class="ta-small">${taCap(taNiceLong(iso))} · semaine S${taIsoWeek(iso)}</div></div>
    <button class="btn btn-ghost btn-sm" onclick="taCloseDrawer()" aria-label="Fermer">✕</button></div>`;
  let lock = '';
  if (lk) lock = `<div class="ta-note warn ta-row"><span>🔒 Semaine verrouillée : rien n’est modifiable.</span>
    <button class="btn btn-ghost btn-sm" onclick="taOpen('unlockWeek',{emp:'${e.id}',mon:'${mon}'})">Déverrouiller…</button></div>`;
  let body = '';
  const absNew = `taOpen('abs',{emp:'${e.id}',from:'${iso}',to:'${iso}'})`, corrNew = `taOpen('corr',{emp:'${e.id}',date:'${iso}'})`;
  if (dd.kind === 'hors') body = '<div class="ta-note">Hors contrat ce jour-là (avant l’entrée ou après la sortie).</div>';
  else if (TA.draft && TA.draft.key === e.id + '|' + iso) {
    const d = TA.draft, f = (lbl, k) => `<div class="fg"><label>${lbl}</label><input type="time" value="${d[k]}" oninput="TA.draft.${k}=this.value;taDraftCheck()"></div>`;
    body = `<div class="ta-sec"><b>Ajouter ses pointages</b><div class="ta-small">4 pointages « ajout admin » avec ton motif. Laisse vide l’après-midi pour une demi-journée.</div>
      <div class="form-grid" style="margin-top:8px">${f('Entrée matin', 'e1')}${f('Sortie midi', 's1')}${f('Entrée après-midi', 'e2')}${f('Sortie soir', 's2')}
      <div class="fg full"><label>Motif (obligatoire)</label><input type="text" value="${taEsc(d.motif)}" placeholder="ex : badge oublié toute la journée" oninput="TA.draft.motif=this.value;taDraftCheck()"></div></div>
      <div id="ta-draft-err" class="ta-note bad" style="display:none"></div>
      <div class="ta-row" style="margin-top:10px;justify-content:flex-end"><button class="btn btn-ghost btn-sm" onclick="TA.draft=null;taRenderDrawer()">Annuler</button>
      <button id="ta-draft-save" class="btn btn-primary btn-sm" onclick="taDraftSave()">Enregistrer la journée</button></div></div>`;
  } else {
    if (dd.kind === 'empty' && !dd.punches.length) {
      body = `<div class="ta-note bad">${iso < today ? 'Rien de pointé ce jour-là et aucune absence saisie. Que s’est-il passé ?' : 'Rien de pointé pour l’instant.'}</div>`
        + (lk ? '' : `<div class="ta-fix"><button class="btn btn-ghost" onclick="taDraftStart('${e.id}','${iso}')">Ajouter ses pointages</button>
          <button class="btn btn-ghost" onclick="${absNew}">Saisir une absence</button><button class="btn btn-ghost" onclick="${corrNew}">Corriger ± h</button></div>`);
    }
    if (dd.kind === 'todo' || dd.kind === 'future' || dd.kind === 'we') {
      body = `<div class="ta-note">${dd.kind === 'we' ? 'Week-end.' : dd.kind === 'todo' ? 'Pas encore pointé aujourd’hui.' : 'Jour à venir.'}</div>`
        + (lk ? '' : `<div class="ta-fix">${dd.kind !== 'future' ? `<button class="btn btn-ghost" onclick="taOpen('punch',{emp:'${e.id}',type:'ENTREE',date:'${iso}'})">Ajouter un pointage</button>` : ''}
          <button class="btn btn-ghost" onclick="${absNew}">Saisir une absence</button></div>`);
    }
    if (dd.kind === 'abs') {
      if (dd.code === 'F') body = `<div class="ta-note">Jour férié (${taEsc(dd.label)}) — rempli automatiquement depuis Paramètres → Jours fériés. Si ${taEsc(e.prenom)} a travaillé ce jour-là, ajoute ses pointages.</div>`
        + (lk ? '' : `<div class="ta-fix"><button class="btn btn-ghost" onclick="taOpen('punch',{emp:'${e.id}',type:'ENTREE',date:'${iso}'})">Ajouter un pointage</button></div>`);
      else {
        const cg = dd.conge;
        body = `<div class="ta-note"><b>${TA_ABS[dd.code]}${dd.half ? ' (' + TA_HALF[dd.half] + ')' : ''}</b> — ${cg.date_debut === cg.date_fin ? taNice(cg.date_debut) : 'du ' + taNice(cg.date_debut) + ' au ' + taNice(cg.date_fin)} (${taFh(cg.jours)} j)
          ${cg.motif || cg.notes ? '<div class="ta-small">' + taEsc(cg.motif || cg.notes) + '</div>' : ''}</div>`
          + `<div class="ta-fix"><button class="btn btn-ghost" onclick="taOpenAbsEdit('${cg.id}')">Modifier l’absence</button>
             ${lk ? '' : `<button class="btn btn-ghost" onclick="taOpen('punch',{emp:'${e.id}',type:'ENTREE',date:'${iso}'})">Ajouter un pointage</button>`}</div>`;
      }
    }
    if (dd.kind === 'work' || dd.punches.length) {
      const list = dd.punches.map(p => {
        const meta = !p.valide ? 'annulé · motif : ' + (p.raison_modif || '—')
          : p.horodatage_origine ? 'modifié (était ' + taParisHM(p.horodatage_origine) + ')' + (p.raison_modif ? ' · ' + p.raison_modif : '')
          : p.source === 'admin' ? 'ajout admin' + (p.raison_modif && p.raison_modif !== 'Ajout manuel' ? ' · ' + p.raison_modif : '') : (TA_SRC[p.source] || p.source);
        const typ = { ENTREE: 'Entrée', SORTIE: 'Sortie', PAUSE_DEBUT: 'Pause', PAUSE_FIN: 'Reprise' }[p.type] || p.type;
        const acts = p.valide && !lk ? `<button class="btn btn-ghost btn-xs" title="Modifier l’heure" onclick="taOpen('edit',{pid:'${p.id}',emp:'${e.id}',iso:'${iso}'})">✎</button>
          <button class="btn btn-ghost btn-xs" title="Annuler ce pointage" onclick="taOpen('cancelP',{pid:'${p.id}',emp:'${e.id}',iso:'${iso}'})">✕</button>` : '';
        return `<div class="ta-punch${p.valide ? '' : ' off'}"><span class="ta-tag ${p.type === 'ENTREE' || p.type === 'PAUSE_FIN' ? 'in' : 'out'}">${typ}</span>
          <span class="ta-time">${taParisHM(p.horodatage)}</span><span class="ta-small">${taEsc(meta)}</span><span class="ta-acts">${acts}</span></div>`;
      }).join('');
      const corr = dd.corr.map(c => `<div class="ta-punch"><span class="ta-tag corr">${c.delta_min > 0 ? '+' : '−'}${taFh(Math.abs(c.delta_min) / 60)} h</span><span class="ta-small">${taEsc(c.commentaire)}</span>
        <span class="ta-acts">${lk ? '' : `<button class="btn btn-ghost btn-xs" title="Supprimer la correction" onclick="taDelCorr('${c.id}')">✕</button>`}</span></div>`).join('');
      const tot = dd.kind === 'work' ? (dd.missingOut ? '<span style="color:var(--danger)">sortie manquante</span>' : taFh(dd.hours) + ' h' + (dd.running ? ' (en cours)' : '')) : '0 h';
      body += `<div class="ta-sec"><div class="ta-row"><b>Pointages</b><span>Total : <b>${tot}</b></span></div>${list || '<div class="ta-small">Aucun pointage.</div>'}${corr}
        ${dd.half ? `<div class="ta-small" style="margin-top:6px">+ ${TA_ABS[TA_CODE[dd.half.type]]} (${TA_HALF[dd.half.demi_journee]}) — <a href="#" onclick="taOpenAbsEdit('${dd.half.id}');return false">modifier</a></div>` : ''}</div>`
        + (lk ? '' : `<div class="ta-fix"><button class="btn btn-ghost" onclick="taOpen('punch',{emp:'${e.id}',type:'${dd.missingOut ? 'SORTIE' : 'ENTREE'}',date:'${iso}'})">${dd.missingOut ? 'Ajouter la sortie manquante' : 'Ajouter un pointage'}</button>
          <button class="btn btn-ghost" onclick="${corrNew}">Corriger ± h</button>${dd.half ? '' : `<button class="btn btn-ghost" onclick="${absNew}">Saisir une absence</button>`}</div>`);
    }
  }
  return head + lock + body + `<div class="ta-dr-foot"><button class="ta-link" onclick="taOpenEmp('${e.id}')">Voir la fiche de ${taEsc(e.prenom)} →</button></div>`;
}

function taDraftStart(empId, iso) {
  TA.draft = { key: empId + '|' + iso, emp: empId, iso, e1: '08:00', s1: '12:00', e2: '13:00', s2: taContrat(taEmp(empId)) > 35 ? '17:00' : '16:00', motif: '' };
  taRenderDrawer(); taDraftCheck();
}
function taDraftErrs() {
  const d = TA.draft, errs = [], t = ['e1', 's1', 'e2', 's2'].map(k => taToMin(d[k]));
  if (isNaN(t[0]) || isNaN(t[1])) errs.push('Indique au moins l’entrée et la sortie du matin.');
  else if (t[1] <= t[0]) errs.push('La sortie du matin doit être après l’entrée.');
  if (isNaN(t[2]) !== isNaN(t[3])) errs.push('Pour l’après-midi, indique l’entrée et la sortie (ou aucune des deux).');
  else if (!isNaN(t[2]) && (t[2] <= t[1] || t[3] <= t[2])) errs.push('Les heures de l’après-midi doivent suivre celles du matin.');
  if (!String(d.motif || '').trim()) errs.push('Le motif est obligatoire.');
  return errs;
}
function taDraftCheck() {
  const errs = taDraftErrs(), box = document.getElementById('ta-draft-err'), btn = document.getElementById('ta-draft-save');
  if (box) { box.style.display = errs.length ? '' : 'none'; box.textContent = errs.join(' '); }
  if (btn) btn.disabled = errs.length > 0;
}
async function taDraftSave() {
  const d = TA.draft;
  if (!d || taDraftErrs().length || TA.busy) return;
  TA.busy = true;
  const seq = [['ENTREE', d.e1], ['SORTIE', d.s1], ['ENTREE', d.e2], ['SORTIE', d.s2]].filter(x => x[1]);
  for (const [type, t] of seq) {
    const { data, error } = await window.SupabaseDB.rpc('admin_add_pointage', { p_employe_id: d.emp, p_type: type, p_horodatage: taParisToUtc(d.iso, t), p_modifie_par: taAuteur(), p_motif: d.motif.trim() });
    if (error || !data?.ok) { TA.busy = false; ptgToast('⚠ ' + (error?.message || data?.message)); taRefresh(); return; }
  }
  TA.busy = false; TA.draft = null;
  taRefresh('Journée enregistrée');
}

async function taDelCorr(id) {
  if (!confirm('Supprimer cette correction ?')) return;
  const { data, error } = await window.SupabaseDB.rpc('supprimer_correction_heures', { p_id: id });
  if (error || !data?.ok) { ptgToast('⚠ ' + (error?.message || data?.message)); return; }
  taRefresh('Correction supprimée');
}

function taDrawerEmp(e) {
  const mo = TA.mo || taCurMo(), ds = taDs(mo) || taDs(taCurMo()), cur = taDs(taCurMo());
  const head = `<div class="ta-dr-head"><div><h3>${taEsc(taName(e))}</h3><div class="ta-small">${taEsc(e.poste || '—')} · contrat ${taFh(taContrat(e))} h/semaine · ${taEsc(e.type_contrat || '')}</div></div>
    <button class="btn btn-ghost btn-sm" onclick="taCloseDrawer()" aria-label="Fermer">✕</button></div>`;
  const tabs = `<div class="ta-tabs full"><button class="ta-tab${TA.empTab === 'sum' ? ' on' : ''}" onclick="TA.empTab='sum';taRenderDrawer()">Résumé</button>
    <button class="ta-tab${TA.empTab === 'hist' ? ' on' : ''}" onclick="TA.empTab='hist';taRenderDrawer();if(!TA.empLog)taLoadEmpLog('${e.id}')">Historique des modifications</button></div>`;
  if (TA.empTab === 'hist') {
    if (!TA.empLog) { taLoadEmpLog(e.id); return head + tabs + '<div class="ta-empty">Chargement…</div>'; }
    return head + tabs + `<div class="ta-card">${taJournalHtml(TA.empLog, false)}</div>`;
  }
  const t0 = taTodayOf(cur, e), m = taMonthSum(ds, e.id), cp = taCp(e), weeks = taWeeks(ds.mo);
  const nLk = weeks.filter(w => taLocked(ds, e.id, w.mon)).length;
  const tiles = [
    ['Aujourd’hui', { absent: 'Absent', missing: 'Pas pointé', left: 'Parti', present: 'Présent', hors: '—' }[t0.st], t0.label],
    [taCap(TA_MOIS_L[ds.mo.m - 1]) + ' — heures', taFh1(m.hours) + ' h', 'HS : ' + taFh(m.hs25) + ' h à 25 % · ' + taFh(m.hs50) + ' h à 50 %'],
    ['CP restants', taFh(cp.solde) + ' j', 'acquis ' + taFh(cp.acquis) + ' j · pris ' + taFh(cp.pris) + ' j depuis le 1er juin'],
    ['Semaines de ' + TA_MOIS_C[ds.mo.m - 1], nLk + ' / ' + weeks.length, 'verrouillées'],
  ].map(t => `<div class="ta-tile"><div class="ta-small">${t[0]}</div><b>${taEsc(t[1])}</b><div class="ta-small">${taEsc(t[2])}</div></div>`).join('');
  const cpLine = `Solde CP : ${taFh(cp.solde)} j` + (cp.adj.length ? ' (dont ajustements : ' + cp.adj.map(a => (a.jours > 0 ? '+' : '') + taFh(a.jours) + ' j').join(', ') + ')' : ' — acquis ' + taFh(TA.cfg.cp_annuels) + ' j/an, période 1er juin → 31 mai');
  const absList = TA.conges.filter(c => c.employe_id === e.id && c.date_fin >= ds.first && c.date_debut <= ds.last)
    .sort((a, b) => a.date_debut < b.date_debut ? -1 : 1)
    .map(c => {
      const lk = taWorkdays(c.date_debut, c.date_fin).some(d => taLockedOn(e.id, d));
      const txt = TA_ABS[TA_CODE[c.type]] + (c.demi_journee ? ' (' + TA_HALF[c.demi_journee] + ')' : '') + ' — ' + (c.date_debut === c.date_fin ? taNice(c.date_debut) : 'du ' + taNice(c.date_debut) + ' au ' + taNice(c.date_fin)) + ' (' + taFh(c.jours) + ' j)' + (lk ? ' · semaine verrouillée' : '');
      return `<button class="ta-listbtn" onclick="taOpenAbsEdit('${c.id}')">${taEsc(txt)}</button>`;
    }).join('') || '<div class="ta-small">Aucune.</div>';
  const days = [];
  for (let d = taToday(), g = 0; days.length < 7 && g < 20; d = taAdd(d, -1), g++) {
    if (!taIsWeekday(d) || d < cur.start) continue;
    const dd = taDay(cur, e.id, d);
    const val = dd.bad ? '<span style="color:var(--danger);font-weight:700">à régler</span>' : dd.kind === 'abs' ? TA_ABS[dd.code] : dd.kind === 'work' ? taFh(dd.hours) + ' h' : dd.kind === 'todo' ? 'pas encore pointé' : '—';
    days.push(`<button class="ta-listbtn ta-row" onclick="taOpenDay('${e.id}','${d}')"><span>${taCap(taNice(d))}</span><span>${val}</span></button>`);
  }
  const today = taToday();
  return head + tabs + `<div class="ta-tiles">${tiles}</div>
    <div class="ta-sec"><div class="ta-row"><span>${taEsc(cpLine)}</span><button class="btn btn-ghost btn-sm" onclick="taOpen('cpAdj',{emp:'${e.id}'})">Ajuster le solde</button></div></div>
    <div class="ta-sec"><b>Absences en ${TA_MOIS_L[ds.mo.m - 1]}</b>${absList}</div>
    <div class="ta-sec"><b>Derniers jours</b>${days.join('')}</div>
    <div class="ta-fix"><button class="btn btn-ghost" onclick="taOpen('punch',{emp:'${e.id}',type:'ENTREE',date:'${today}'})">Ajouter un pointage</button>
      <button class="btn btn-ghost" onclick="taOpen('abs',{emp:'${e.id}',from:'${today}',to:'${today}'})">Saisir une absence</button>
      <button class="btn btn-ghost" onclick="taOpen('pdf',{emp:'${e.id}',mon:'${taMonday(today < ds.first || today > ds.last ? ds.first : today)}'})">Relevé PDF de la semaine</button></div>`;
}

// ── Fenêtres ────────────────────────────────────────────────────────────────
// Prénom de l'admin connecté (résolu au démarrage par resolveRoleAndBoot), noté dans pointages.modifie_par.
function taAuteur() { return (window._rhMoi && window._rhMoi.prenom) || 'admin'; }

function taOpen(kind, o) {
  TA.modal = Object.assign({ kind, emp: '', motif: '' }, o || {});
  const M = TA.modal;
  if (kind === 'edit') {
    const p = taFindPunch(M.pid);
    M.old = p ? taParisHM(p.horodatage) : ''; M.time = M.old; M.type = p ? p.type : '';
  }
  if (kind === 'abs') { M.type = M.type || ''; M.half = M.half || 'day'; }
  if (kind === 'cpAdj') { M.why = 'report'; M.val = ''; }
  if (kind === 'corr') M.val = '';
  if (kind === 'punch') { M.type = M.type || 'ENTREE'; M.time = M.time || ''; }
  taRenderModal();
  setTimeout(() => { const f = document.querySelector('#ta-modal input:not([type=hidden]), #ta-modal select'); if (f && !M.emp) f.focus(); }, 30);
}
function taCloseModal() { TA.modal = null; taRenderModal(); }
function taFindPunch(pid) {
  for (const ds of Object.values(TA.data)) for (const list of ds.punches.values()) { const p = list.find(x => x.id === pid); if (p) return p; }
  return null;
}
function taOpenAbsEdit(id) {
  const c = TA.conges.find(x => x.id === id);
  if (!c) return;
  taOpen('abs', { id: c.id, emp: c.employe_id, type: TA_CODE[c.type], from: c.date_debut, to: c.date_fin, half: c.demi_journee || 'day', motif: c.motif || c.notes || '', orig: c });
}

// Champs : la saisie au clavier ne re-rend que la zone d'infos (pour garder le focus).
function taMSet(f, v, full) { TA.modal[f] = v; if (full) taRenderModal(); else taModalInfo(); }
function taFIn(label, f, type, opt = {}) {
  const M = TA.modal;
  return `<div class="fg${opt.full ? ' full' : ''}"><label>${label}</label><input type="${type}" ${opt.step ? 'step="' + opt.step + '"' : ''} placeholder="${taEsc(opt.ph || '')}"
    value="${taEsc(M[f] ?? '')}" oninput="taMSet('${f}',this.value)"></div>`;
}
function taFSel(label, f, options, full) {
  const M = TA.modal;
  return `<div class="fg${full ? ' full' : ''}"><label>${label}</label><select onchange="taMSet('${f}',this.value,true)">
    <option value="">— choisir —</option>${options.map(o => `<option value="${o[0]}"${M[f] === o[0] ? ' selected' : ''}>${taEsc(o[1])}</option>`).join('')}</select></div>`;
}
function taFChips(label, f, options, full) {
  const M = TA.modal;
  return `<div class="fg${full ? ' full' : ''}"><label>${label}</label><div class="ta-chiprow">${options.map(o =>
    `<button type="button" class="ta-mini${M[f] === o[0] ? ' on' : ''}" aria-pressed="${M[f] === o[0]}" onclick="taMSet('${f}','${o[0]}',true)">${taEsc(o[1])}</button>`).join('')}</div></div>`;
}
function taNote(text, tone) { return `<div class="ta-note ${tone || ''}">${text}</div>`; }
function taEmpOpts(iso) { return taMonthEmps(taMonthOf(iso || taToday())).filter(e => !iso || taInContract(e, iso)).map(e => [e.id, taName(e)]); }

function taLockErr(empId, iso) {
  if (!empId || !iso) return '';
  if (taLockedOn(empId, iso)) return `La semaine S${taIsoWeek(iso)} de ${taName(taEmp(empId))} est verrouillée : déverrouille-la d’abord.`;
  return '';
}

// Chaque type de fenêtre : { title, sub, fields(), info() → {html, errs}, save, cls, run(), danger? }
const TA_MODALS = {
  punch: {
    title: () => 'Ajouter un pointage', sub: () => 'Il apparaît comme « ajout admin », avec ton nom, la date de saisie et le motif.',
    fields: M => taFSel('Salarié', 'emp', taEmpOpts(M.date), true) + taFChips('Type', 'type', [['ENTREE', 'Entrée'], ['SORTIE', 'Sortie']], true)
      + taFIn('Date', 'date', 'date') + taFIn('Heure', 'time', 'time') + taFIn('Motif (obligatoire)', 'motif', 'text', { full: true, ph: 'ex : oubli de badge en partant' }),
    info: M => {
      const errs = [], today = taToday(); let html = '';
      if (!M.emp) errs.push('Choisis un salarié.');
      if (!/^\d{4}-\d\d-\d\d$/.test(M.date || '')) errs.push('Date invalide.'); else if (M.date > today) errs.push('Pas de pointage dans le futur.');
      if (isNaN(taToMin(M.time))) errs.push('Indique l’heure.');
      else if (M.date === today && taToMin(M.time) > taNowMin() + 5) errs.push('Cette heure n’est pas encore passée.');
      const le = taLockErr(M.emp, M.date); if (le) errs.push(le);
      const ds = M.date && taDsFor(M.date);
      if (M.emp && ds && !le) {
        const cur = taDay(ds, M.emp, M.date).punches || [];
        html = taNote('Pointages actuels du ' + taNice(M.date) + ' : ' + (cur.filter(p => p.valide).map(p => (p.type === 'ENTREE' ? 'E ' : p.type === 'SORTIE' ? 'S ' : '') + taParisHM(p.horodatage)).join(' · ') || 'aucun') + '.');
      }
      return { html, errs };
    },
    motif: true, save: () => 'Enregistrer',
    run: M => window.SupabaseDB.rpc('admin_add_pointage', { p_employe_id: M.emp, p_type: M.type, p_horodatage: taParisToUtc(M.date, M.time), p_modifie_par: taAuteur(), p_motif: M.motif.trim() }),
    done: 'Pointage ajouté',
  },
  edit: {
    title: () => 'Modifier l’heure d’un pointage',
    sub: M => taName(taEmp(M.emp)) + ' · ' + (M.type === 'ENTREE' ? 'Entrée' : M.type === 'SORTIE' ? 'Sortie' : M.type) + ' du ' + taNice(M.iso),
    fields: M => taNote('Heure actuelle : ' + M.old + '. L’heure d’origine reste visible dans le détail du jour et au journal.') + taFIn('Nouvelle heure', 'time', 'time')
      + '<div></div>' + taFIn('Motif (obligatoire)', 'motif', 'text', { full: true, ph: 'ex : badgé en retard, arrivé à 07:30' }),
    info: M => { const errs = []; if (isNaN(taToMin(M.time))) errs.push('Indique la nouvelle heure.'); else if (M.time === M.old) errs.push('L’heure n’a pas changé.'); return { html: '', errs }; },
    motif: true, save: () => 'Enregistrer',
    run: M => window.SupabaseDB.rpc('admin_modifier_pointage', { p_pointage_id: M.pid, p_horodatage: taParisToUtc(M.iso, M.time), p_modifie_par: taAuteur(), p_motif: M.motif.trim() }),
    done: 'Heure modifiée',
  },
  cancelP: {
    title: () => 'Annuler un pointage',
    sub: M => { const p = taFindPunch(M.pid); return taName(taEmp(M.emp)) + ' · ' + (p ? (p.type === 'ENTREE' ? 'Entrée ' : 'Sortie ') + taParisHM(p.horodatage) + ' du ' + taNice(M.iso) : ''); },
    fields: () => taNote('Le pointage n’est pas effacé : il reste visible, barré, avec ton motif, et ne compte plus dans les heures.', 'warn')
      + taFIn('Motif (obligatoire)', 'motif', 'text', { full: true, ph: 'ex : badge de test, double badgeage' }),
    info: () => ({ html: '', errs: [] }), motif: true, save: () => 'Annuler le pointage', cls: 'btn-danger', cancel: 'Retour',
    run: M => window.SupabaseDB.rpc('admin_annuler_pointage', { p_pointage_id: M.pid, p_motif: M.motif.trim(), p_modifie_par: taAuteur() }),
    done: 'Pointage annulé (reste visible, barré)',
  },
  corr: {
    title: () => 'Corriger ± h', sub: () => 'Pour les cas sans pointage précis : temps de trajet, réunion hors site, pause non badgée…',
    fields: M => taFSel('Salarié', 'emp', taEmpOpts(M.date), true) + taFIn('Jour', 'date', 'date')
      + taFIn('Heures (+ ajoute, − retire)', 'val', 'number', { step: '0.25', ph: 'ex : 1,5 ou -0,5' })
      + taFIn('Commentaire (obligatoire)', 'motif', 'text', { full: true, ph: 'ex : déplacement chantier Lyon' }),
    info: M => {
      const errs = [], v = taNum(M.val); let html = '';
      if (!M.emp) errs.push('Choisis un salarié.');
      if (!/^\d{4}-\d\d-\d\d$/.test(M.date || '')) errs.push('Date invalide.'); else if (M.date > taToday()) errs.push('Pas de correction dans le futur.');
      if (isNaN(v) || v === 0) errs.push('Indique un nombre d’heures (ex : 1,5 ou -0,5).');
      else if (Math.abs(v * 60 - Math.round(v * 60)) > 0.001) errs.push('Arrondis à la minute.');
      const le = taLockErr(M.emp, M.date); if (le) errs.push(le);
      const ds = M.date && taDsFor(M.date);
      if (M.emp && ds && !isNaN(v) && v !== 0) {
        const h = taDay(ds, M.emp, M.date).hours, after = Math.round((h + v) * 100) / 100;
        html = taNote('Total du ' + taNice(M.date) + ' : ' + taFh(h) + ' h → ' + taFh(after) + ' h', after < 0 ? 'bad' : 'good');
        if (after < 0) errs.push('Le total du jour deviendrait négatif.');
      }
      return { html, errs };
    },
    motif: true, save: () => 'Enregistrer',
    run: M => window.SupabaseDB.rpc('ajouter_correction_heures', { p_employe_id: M.emp, p_date: M.date, p_delta_min: Math.round(taNum(M.val) * 60), p_commentaire: M.motif.trim() }),
    done: 'Correction enregistrée',
  },
  abs: {
    title: M => M.id ? 'Modifier l’absence' : 'Saisir une absence',
    sub: () => 'Une seule fenêtre pour tous les types. Les jours décomptés excluent week-ends et fériés.',
    fields: M => taFSel('Salarié', 'emp', taEmpOpts(M.from), true)
      + taFChips('Type', 'type', [['CP', 'Congé payé'], ['MAL', 'Maladie'], ['EVT', 'Événement familial'], ['SS', 'Sans solde'], ['AUT', 'Autre']], true)
      + `<div class="fg"><label>Du</label><input type="date" value="${M.from || ''}" oninput="taMSet('from',this.value)"></div>`
      + `<div class="fg"><label>Au (inclus)</label><input type="date" value="${M.to || ''}" oninput="taMSet('to',this.value)"></div>`
      + taFIn(M.type === 'AUT' ? 'Préciser (obligatoire)' : 'Commentaire', 'motif', 'text', { full: true, ph: M.type === 'MAL' ? 'ex : arrêt reçu le 6 oct.' : 'facultatif' }),
    info: M => {
      const errs = []; let html = '';
      if (!M.emp) errs.push('Choisis un salarié.');
      if (!M.type) errs.push('Choisis le type d’absence.');
      if (M.type === 'AUT' && !String(M.motif || '').trim()) errs.push('Précise le motif pour « Autre ».');
      const okDates = /^\d{4}-\d\d-\d\d$/.test(M.from || '') && /^\d{4}-\d\d-\d\d$/.test(M.to || '');
      if (!okDates) errs.push('Indique les deux dates.'); else if (M.to < M.from) errs.push('La date de fin est avant la date de début.');
      if (okDates && M.from === M.to) {
        html += `<div class="fg full"><label>Durée</label><div class="ta-chiprow">${[['day', 'Journée entière'], ['am', 'Matin'], ['pm', 'Après-midi']].map(o =>
          `<button type="button" class="ta-mini${M.half === o[0] ? ' on' : ''}" onclick="taMSet('half','${o[0]}');taModalInfo()">${o[1]}</button>`).join('')}</div></div>`;
      }
      if (M.emp && okDates && M.to >= M.from) {
        const wd = taWorkdays(M.from, M.to);
        let n = wd.length; if (M.from === M.to && M.half !== 'day') n = n ? 0.5 : 0;
        let lockMsg = wd.map(d => taLockErr(M.emp, d)).find(Boolean) || '';
        if (M.orig && !lockMsg) lockMsg = taWorkdays(M.orig.date_debut, M.orig.date_fin).map(d => taLockErr(M.orig.employe_id, d)).find(Boolean) || '';
        if (lockMsg) errs.push(lockMsg);
        if (!n) errs.push('Aucun jour ouvré dans cette période.');
        const overlap = TA.conges.find(c => c.employe_id === M.emp && c.id !== M.id && c.date_debut <= M.to && c.date_fin >= M.from);
        if (overlap) errs.push('Chevauche une absence déjà saisie (' + TA_ABS[TA_CODE[overlap.type]] + ' du ' + taNice(overlap.date_debut) + ') : modifie-la plutôt.');
        html += taNote('Jours décomptés : ' + taFh(n) + ' jour' + (n > 1 ? 's' : '') + ' ouvré' + (n > 1 ? 's' : '') + ' (' + taNice(M.from) + (M.to !== M.from ? ' → ' + taNice(M.to) : '') + ').');
        if (M.type === 'CP') {
          const e = taEmp(M.emp), before = taCp(e).solde, back = M.orig && M.orig.type === 'cp' ? parseFloat(M.orig.jours) : 0, after = Math.round((before + back - n) * 10) / 10;
          html += taNote('Solde CP de ' + taEsc(e.prenom) + ' : ' + taFh(before + back) + ' j → ' + taFh(after) + ' j' + (after < 0 ? ' — solde négatif : congé par anticipation, à confirmer.' : ''), after < 0 ? 'warn' : 'good');
        }
        if (M.type === 'MAL') html += taNote('Pense à garder l’arrêt de travail : la maladie part dans l’export paie, colonne « Maladie (j) ».');
        M._n = n;
      }
      return { html, errs };
    },
    save: M => M.id ? 'Enregistrer' : 'Enregistrer l’absence',
    danger: M => M.id ? { label: 'Supprimer l’absence', go: 'taAbsDelete()' } : null,
    run: M => {
      const half = M.from === M.to && M.half !== 'day' ? M.half : null, t = TA_TYPE[M.type];
      return window.SupabaseDB.rpc('upsert_conge_rh', { p_id: M.id || null, p_employe_id: M.emp, p_type: t, p_date_debut: M.from, p_date_fin: M.to,
        p_jours: M._n, p_motif: (t === 'evenement_familial' || t === 'autre') ? (M.motif || '').trim() || null : null,
        p_notes: (t === 'evenement_familial' || t === 'autre') ? null : (M.motif || '').trim() || null, p_demi_journee: half });
    },
    done: M => M.id ? 'Absence modifiée' : 'Absence enregistrée',
  },
  lockWeek: {
    wide: true,
    title: M => `Semaine S${taIsoWeek(M.mon)} · ${taWeekLabel(M.mon)}`,
    sub: () => 'Récapitulatif avant verrouillage. Une semaine verrouillée ne se modifie plus (sauf déverrouillage avec motif).',
    fields: M => {
      const ds = taDsFor(M.mon) || taDsFor(taAdd(M.mon, 4)), emps = taMonthEmps(taMonthOf(M.mon)).concat(taMonthEmps(taMonthOf(taAdd(M.mon, 4))))
        .filter((e, i, a) => a.findIndex(x => x.id === e.id) === i && taEmpInWeek(e, M.mon));
      M._ready = []; M._all = emps.map(e => e.id); M._allLocked = true; M._blocked = 0;
      const rows = emps.map(e => {
        const full = taWeekFull(ds, e.id, M.mon), hs = taHs(full), lk = taLocked(ds, e.id, M.mon), nb = taWeekBad(ds, e.id, M.mon);
        let st, col;
        if (!lk) M._allLocked = false;
        if (lk) { st = 'déjà verrouillée'; col = 'var(--muted)'; } else if (nb) { st = nb + ' jour(s) à régler'; col = 'var(--danger)'; M._blocked++; } else { st = 'prête'; col = 'var(--success)'; M._ready.push(e.id); }
        return `<tr><td>${taEsc(taName(e))}</td><td class="num">${taFh(full)} h</td><td class="num">${hs[0] ? taFh(hs[0]) : '—'}</td><td class="num">${hs[1] ? taFh(hs[1]) : '—'}</td><td style="color:${col};font-weight:600">${st}</td></tr>`;
      }).join('');
      let html = `<div class="fg full ta-scroll"><table class="ta-table"><thead><tr><th>Salarié</th><th>Heures</th><th>HS 25 %</th><th>HS 50 %</th><th>État</th></tr></thead><tbody>${rows}</tbody></table></div>`;
      const cross = taAdd(M.mon, 4).slice(0, 7) !== M.mon.slice(0, 7);
      if (cross) { const a = taAttach(M.mon); html += taNote(`Semaine à cheval sur deux mois : ses heures sup seront payées en ${TA_MOIS_L[+a.slice(5) - 1]} (réglage Paramètres → « Semaines à cheval »).`); }
      if (M._allLocked) html += taFIn('Motif du déverrouillage (obligatoire)', 'motif', 'text', { full: true, ph: 'ex : arrêt maladie reçu en retard' });
      else if (M._blocked) html += taNote(M._blocked + ' salarié(s) ont des jours en rouge : ils restent ouverts. Règle-les depuis la grille, puis reviens ici.', 'warn');
      return html;
    },
    info: M => {
      const errs = [];
      if (M._allLocked) { if (!String(M.motif || '').trim()) errs.push('Un motif est obligatoire pour déverrouiller.'); }
      else if (!M._ready.length) errs.push('Aucun salarié prêt.');
      return { html: '', errs };
    },
    save: M => M._allLocked ? 'Déverrouiller pour tous' : M._ready.length ? 'Verrouiller pour ' + M._ready.length + ' salarié(s)' : 'Rien à verrouiller',
    cls: M => M._allLocked ? 'btn-danger' : 'btn-primary',
    run: M => M._allLocked
      ? window.SupabaseDB.rpc('deverrouiller_semaine_pour', { p_employes: M._all, p_semaine_debut: M.mon, p_motif: M.motif.trim() })
      : window.SupabaseDB.rpc('verrouiller_semaine_pour', { p_employes: M._ready, p_semaine_debut: M.mon }),
    done: M => M._allLocked ? `S${taIsoWeek(M.mon)} déverrouillée` : `S${taIsoWeek(M.mon)} verrouillée pour ${M._ready.length} salarié(s)`,
  },
  unlockWeek: {
    title: M => 'Déverrouiller la semaine S' + taIsoWeek(M.mon), sub: M => taName(taEmp(M.emp)) + ' · ' + taWeekLabel(M.mon),
    fields: M => {
      let h = taNote('Ses pointages, corrections et absences de la semaine redeviennent modifiables. Pense à la reverrouiller avant la clôture.');
      const ms = [...new Set([M.mon, taAdd(M.mon, 4)].map(d => d.slice(0, 7)))].map(k => [k, TA.clot.get(k)]).filter(x => x[1] && x[1].cloture);
      ms.forEach(([k, c]) => { h += taNote(taCap(TA_MOIS_L[+k.slice(5) - 1]) + ' est clôturé : il sera rouvert aussi.' + (c.exporte_le ? ' Le CSV déjà téléchargé ne sera plus à jour.' : ''), 'warn'); });
      return h + taFIn('Motif (obligatoire)', 'motif', 'text', { full: true, ph: 'ex : arrêt maladie reçu en retard' });
    },
    info: () => ({ html: '', errs: [] }), motif: true, save: () => 'Déverrouiller',
    run: M => window.SupabaseDB.rpc('deverrouiller_semaine_pour', { p_employes: [M.emp], p_semaine_debut: M.mon, p_motif: M.motif.trim() }),
    done: 'Semaine déverrouillée',
  },
  lockMonth: {
    title: () => 'Verrouiller ' + taMonthLabel(TA.mo), sub: () => 'Dernier contrôle avant l’export paie.',
    fields: () => {
      const ds = taDs(TA.mo), rows = taCsvRows(ds), t = { h: 0, hs25: 0, hs50: 0, CP: 0, MAL: 0, EVT: 0, SS: 0, AUT: 0 };
      rows.forEach(r => { t.h += r.m.hours; t.hs25 += r.m.hs25; t.hs50 += r.m.hs50; ['CP', 'MAL', 'EVT', 'SS', 'AUT'].forEach(c => { t[c] += r.m[c]; }); });
      TA.modal._resume = `${rows.length} salariés, ${taFh1(t.h)} h, HS 25 % ${taFh(t.hs25)} h, HS 50 % ${taFh(t.hs50)} h`;
      const cross = taWeeks(TA.mo).filter(w => w.cross).map(w => `S${w.n} → heures sup en ${TA_MOIS_L[+w.attach.slice(5) - 1]}`).join(', ');
      return taNote(`${rows.length} salariés · ${taFh1(t.h)} h travaillées · HS 25 % : ${taFh(t.hs25)} h · HS 50 % : ${taFh(t.hs50)} h`)
        + taNote(`Absences : ${taFh(t.CP)} j CP · ${taFh(t.MAL)} j maladie · ${taFh(t.EVT)} j év. familial · ${taFh(t.SS)} j sans solde · ${taFh(t.AUT)} j autre`)
        + (cross ? taNote('Semaines à cheval : ' + cross + '.') : '')
        + taNote(`Après verrouillage, toute modification de ${TA_MOIS_L[TA.mo.m - 1]} demandera de déverrouiller avec un motif.`, 'warn');
    },
    info: () => { const ds = taDs(TA.mo); return { html: '', errs: taBlockers(ds).length ? ['Il reste des points à régler (étape 1).'] : [] }; },
    save: () => 'Verrouiller ' + TA_MOIS_L[TA.mo.m - 1],
    run: M => window.SupabaseDB.rpc('cloturer_mois', { p_mois: taMonthFirst(TA.mo.y, TA.mo.m), p_resume: M._resume }),
    done: () => taCap(TA_MOIS_L[TA.mo.m - 1]) + ' verrouillé',
  },
  unlockMonth: {
    title: () => 'Déverrouiller ' + taMonthLabel(TA.mo), sub: () => 'Le mois redevient modifiable une fois ses semaines déverrouillées. La raison est inscrite au journal.',
    fields: () => {
      const c = TA.clot.get(taMonthKey(TA.mo.y, TA.mo.m));
      return (c && c.exporte_le ? taNote('Le CSV a déjà été téléchargé le ' + taShort(c.exporte_le.slice(0, 10)) + ' à ' + taParisHM(c.exporte_le) + '. Après correction, il faudra renvoyer un nouveau fichier au prestataire et lui dire que le précédent est annulé.', 'warn') : '')
        + taNote('Les semaines restent verrouillées : déverrouille ensuite celles à corriger (clic sur « S » dans la grille).')
        + taFIn('Motif (obligatoire)', 'motif', 'text', { full: true, ph: 'ex : arrêt maladie reçu après la clôture' });
    },
    info: () => ({ html: '', errs: [] }), motif: true, save: () => 'Déverrouiller', cls: 'btn-danger',
    run: M => window.SupabaseDB.rpc('rouvrir_mois', { p_mois: taMonthFirst(TA.mo.y, TA.mo.m), p_motif: M.motif.trim() }),
    done: () => taCap(TA_MOIS_L[TA.mo.m - 1]) + ' déverrouillé',
  },
  pdf: {
    wide: true, title: () => 'Relevé de la semaine à faire signer', sub: () => 'Même contenu que le PDF ; à imprimer et faire signer.',
    fields: M => {
      const mons = []; for (let i = 5; i >= 0; i--) mons.push(taAdd(taMonday(taToday()), -7 * i));
      if (!mons.includes(M.mon)) mons.unshift(M.mon);
      return taFSel('Salarié', 'emp', taEmpOpts(), false) + taFChips('Semaine', 'mon', mons.map(m => [m, 'S' + taIsoWeek(m)]), false);
    },
    info: M => {
      const errs = []; if (!M.emp) { errs.push('Choisis un salarié.'); return { html: '', errs }; }
      const ds = taDsFor(M.mon) || taDsFor(taAdd(M.mon, 6));
      if (!ds) { taLoadMonth(taMonthOf(M.mon)).then(taModalInfo); return { html: '<div class="ta-empty">Chargement…</div>', errs: ['Chargement…'] }; }
      const r = taPdfData(M.emp, M.mon);
      const html = `<div class="fg full"><div class="ta-paper"><div class="ta-row"><b>Relevé de présence</b><span>${taEsc(r.week)}</span></div><div>${taEsc(r.name)}</div>
        <table><thead><tr><th>Jour</th><th>Entrée</th><th>Sortie</th><th>Entrée</th><th>Sortie</th><th>Total</th></tr></thead><tbody>
        ${r.rows.map(x => `<tr><td>${taEsc(x.day)}</td>${x.abs ? `<td colspan="4">${taEsc(x.abs)}</td>` : x.cells.map(c => `<td>${c}</td>`).join('')}<td>${taEsc(x.tot)}</td></tr>`).join('')}</tbody></table>
        ${r.notes.length ? '<div class="ta-small">' + r.notes.map(taEsc).join('<br>') + '</div>' : ''}
        <div class="ta-row" style="margin-top:6px"><span>Total semaine : <b>${r.total}</b> · contrat ${r.contrat}</span><span>HS 25 % : ${r.hs25} · HS 50 % : ${r.hs50}</span></div>
        <div class="ta-small">${taEsc(r.note)}</div><div class="ta-sign"><div>Signature du salarié</div><div>Signature de l’employeur</div></div></div></div>`;
      return { html, errs };
    },
    save: () => 'Télécharger le PDF', keepOpen: true,
    run: M => { taPdfDownload(M.emp, M.mon); return Promise.resolve({ data: { ok: true } }); },
    done: 'PDF téléchargé',
  },
  cpAdj: {
    title: () => 'Ajuster le solde de congés payés', sub: M => taName(taEmp(M.emp)) + ' · solde actuel ' + taFh(taCp(taEmp(M.emp)).solde) + ' j',
    fields: () => taFChips('Raison', 'why', [['report', 'Report de l’année précédente'], ['correction', 'Correction']], true)
      + taFIn('Jours (+ ajoute, − retire)', 'val', 'number', { step: '0.5', ph: 'ex : 2 ou -1' }) + '<div></div>'
      + taFIn('Motif (obligatoire)', 'motif', 'text', { full: true, ph: 'ex : 3 j non pris au 31 mai, accord direction' }),
    info: M => {
      const v = taNum(M.val), now = taCp(taEmp(M.emp)).solde, errs = [];
      if (isNaN(v) || v === 0) { errs.push('Indique un nombre de jours.'); return { html: '', errs }; }
      return { html: taNote('Solde : ' + taFh(now) + ' j → ' + taFh(now + v) + ' j', now + v < 0 ? 'warn' : 'good'), errs };
    },
    motif: true, save: () => 'Enregistrer',
    run: M => window.SupabaseDB.rpc('ajuster_solde_cp', { p_employe_id: M.emp, p_jours: taNum(M.val), p_raison: M.why, p_motif: M.motif.trim() }),
    done: 'Solde CP ajusté',
  },
};

function taVal(x, M) { return typeof x === 'function' ? x(M) : x; }

function taRenderModal() {
  let el = document.getElementById('ta-modal');
  if (!el) { el = document.createElement('div'); el.id = 'ta-modal'; el.className = 'overlay'; document.body.appendChild(el); }
  const M = TA.modal;
  if (!M) { el.classList.remove('open'); el.innerHTML = ''; return; }
  const def = TA_MODALS[M.kind];
  const fields = def.fields(M);
  const danger = def.danger ? def.danger(M) : null;
  el.innerHTML = `<div class="modal ta-modal${def.wide ? ' wide' : ''}" role="dialog" aria-modal="true" aria-labelledby="ta-m-title">
    <div class="modal-title" id="ta-m-title">${taEsc(taVal(def.title, M))}</div>
    <div class="ta-small" style="margin:-12px 0 14px">${taEsc(taVal(def.sub, M) || '')}</div>
    <div class="form-grid">${fields}<div class="fg full" id="ta-m-info"></div></div>
    <div id="ta-m-err" class="ta-note bad" style="display:none;margin-top:10px"></div>
    <div class="modal-actions">${danger ? `<button class="btn btn-danger" id="ta-m-danger" onclick="${danger.go}" style="margin-right:auto">${taEsc(danger.label)}</button>` : ''}
      <button class="btn btn-ghost" onclick="taCloseModal()">${def.cancel || 'Annuler'}</button>
      <button class="btn ${taVal(def.cls, M) || 'btn-primary'}" id="ta-m-save" onclick="taModalSave()">${taEsc(taVal(def.save, M))}</button></div></div>`;
  el.classList.add('open');
  el.onclick = ev => { if (ev.target === el) taCloseModal(); };
  taModalInfo();
}

function taModalErrs() {
  const M = TA.modal, def = TA_MODALS[M.kind], r = def.info(M);
  if (def.motif && !String(M.motif || '').trim() && !r.errs.includes('Le motif est obligatoire.')) r.errs.push('Le motif est obligatoire.');
  return r;
}
function taModalInfo() {
  const M = TA.modal;
  if (!M) return;
  const r = taModalErrs(), info = document.getElementById('ta-m-info'), err = document.getElementById('ta-m-err'), btn = document.getElementById('ta-m-save');
  if (info) info.innerHTML = r.html;
  if (err) { err.style.display = r.errs.length ? '' : 'none'; err.textContent = r.errs.join(' '); }
  if (btn) btn.disabled = r.errs.length > 0 || TA.busy;
  const dg = document.getElementById('ta-m-danger');
  if (dg && M.kind === 'abs') dg.disabled = r.errs.some(e => e.includes('verrouillée'));
}

async function taModalSave() {
  const M = TA.modal; if (!M || TA.busy) return;
  const def = TA_MODALS[M.kind];
  if (taModalErrs().errs.length) return;
  TA.busy = true; taModalInfo();
  let res;
  try { res = await def.run(M); } catch (e) { res = { error: e }; }
  TA.busy = false;
  const { data, error } = res || {};
  if (error || (data && data.ok === false)) { ptgToast('⚠ ' + (error?.message || data?.message)); taModalInfo(); return; }
  if (def.keepOpen) { ptgToast(taVal(def.done, M)); taModalInfo(); return; }
  TA.modal = null; taRenderModal();
  taRefresh(taVal(def.done, M));
}

async function taAbsDelete() {
  const M = TA.modal; if (!M || !M.id || TA.busy) return;
  if (!confirm('Supprimer cette absence ? Les jours sans pointage repasseront en rouge.')) return;
  TA.busy = true;
  const { data, error } = await window.SupabaseDB.rpc('supprimer_conge_rh', { p_id: M.id, p_motif: (M.motif || '').trim() || null });
  TA.busy = false;
  if (error || !data?.ok) { ptgToast('⚠ ' + (error?.message || data?.message)); return; }
  TA.modal = null; taRenderModal();
  taRefresh('Absence supprimée');
}

// ── PDF ─────────────────────────────────────────────────────────────────────
function taPdfData(empId, mon) {
  const e = taEmp(empId), rows = [], notes = [];
  let total = 0;
  for (let i = 0; i < 7; i++) {
    const d = taAdd(mon, i), ds = taDsFor(d);
    if (!ds) continue;
    const dd = taDay(ds, empId, d);
    total += dd.hours;
    if (dd.kind === 'we' && !dd.punches.length) continue;
    if (dd.kind === 'future' || (i > 4 && dd.kind !== 'work')) continue;
    const day = taCap(taNice(d));
    if (dd.kind === 'abs') { rows.push({ day, abs: TA_ABS[dd.code] + (dd.code === 'F' ? ' — ' + dd.label : '') + (dd.half ? ' (' + TA_HALF[dd.half] + ')' : ''), tot: '—' }); continue; }
    if (dd.kind === 'hors') { rows.push({ day, abs: 'Hors contrat', tot: '—' }); continue; }
    const t = (dd.punches || []).filter(p => p.valide && (p.type === 'ENTREE' || p.type === 'SORTIE')).map(p => taParisHM(p.horodatage));
    const cells = [0, 1, 2, 3].map(k => t[k] || '—');
    if (t.length > 4) notes.push(day + ' : autres pointages ' + t.slice(4).join(', '));
    dd.corr.forEach(c => notes.push(day + ' : correction ' + (c.delta_min > 0 ? '+' : '−') + taFh(Math.abs(c.delta_min) / 60) + ' h (' + c.commentaire + ')'));
    if (dd.half) notes.push(day + ' : ' + TA_ABS[TA_CODE[dd.half.type]] + ' (' + TA_HALF[dd.half.demi_journee] + ')');
    rows.push({ day, cells, tot: dd.bad ? 'à régler' : dd.kind === 'work' ? taFh(dd.hours) + ' h' : '—' });
  }
  const hs = taHs(total), cross = taAdd(mon, 4).slice(0, 7) !== mon.slice(0, 7);
  return {
    name: taName(e), week: `Semaine ${taIsoWeek(mon)} · ${taWeekLabel(mon)} ${mon.slice(0, 4)}`, rows, notes,
    total: taFh(total) + ' h', contrat: taFh(taContrat(e)) + ' h', hs25: taFh(hs[0]) + ' h', hs50: taFh(hs[1]) + ' h',
    note: cross ? 'Semaine à cheval sur deux mois : heures sup payées en ' + TA_MOIS_L[+taAttach(mon).slice(5) - 1] + '.'
      : `Heures sup au-delà de ${taFh(TA.cfg.heures_ref)} h : ${taFh(TA.cfg.heures_25)} premières à 25 %, au-delà à 50 %.`,
  };
}

function taPdfDownload(empId, mon) {
  const { jsPDF } = window.jspdf || {};
  if (!jsPDF) { ptgToast('jsPDF non disponible'); return; }
  // Police standard jsPDF (WinAnsi) : pas de « → », « − » ni espaces fines.
  const clean = s => String(s).replace(/→/g, '->').replace(/−/g, '-').replace(/[’]/g, "'").replace(/[  ]/g, ' ');
  const r = taPdfData(empId, mon), e = taEmp(empId);
  const doc = new jsPDF({ unit: 'mm', format: 'a4' }), ml = 14, W = 210, cw = W - 2 * ml;
  let y = 18;
  doc.setFont('helvetica', 'bold'); doc.setFontSize(16); doc.setTextColor(30, 41, 59);
  doc.text('RH Sonotrad - Relevé de présence', ml, y); y += 7;
  doc.setFont('helvetica', 'normal'); doc.setFontSize(10); doc.setTextColor(100, 116, 139);
  doc.text(clean(r.week), ml, y);
  doc.text('Édité le ' + new Date().toLocaleDateString('fr-FR'), W - ml, y, { align: 'right' }); y += 8;
  doc.setFillColor(30, 41, 59); doc.roundedRect(ml, y, cw, 9, 2, 2, 'F');
  doc.setFont('helvetica', 'bold'); doc.setFontSize(12); doc.setTextColor(255, 255, 255);
  doc.text(clean(e.prenom + ' ' + e.nom.toUpperCase()), ml + 4, y + 6.2); y += 14;
  const cols = [46, 26, 26, 26, 26, cw - 150], hdr = ['Jour', 'Entrée', 'Sortie', 'Entrée', 'Sortie', 'Total'];
  const row = (cells, bold, fill) => {
    if (fill) { doc.setFillColor(248, 250, 252); doc.rect(ml, y, cw, 7, 'F'); }
    doc.setDrawColor(226, 232, 240); doc.rect(ml, y, cw, 7, 'S');
    doc.setFont('helvetica', bold ? 'bold' : 'normal'); doc.setFontSize(9); doc.setTextColor(30, 41, 59);
    let x = ml;
    cells.forEach((c, i) => { const w = cells.length === 3 && i === 1 ? cols[1] + cols[2] + cols[3] + cols[4] : cols[cells.length === 3 && i === 2 ? 5 : i]; doc.text(clean(c), x + 2, y + 4.8); x += w; });
    y += 7;
  };
  row(hdr, true, true);
  r.rows.forEach(x => row(x.abs ? [x.day, x.abs, x.tot] : [x.day].concat(x.cells, [x.tot]), false, false));
  y += 4;
  doc.setFont('helvetica', 'normal'); doc.setFontSize(9); doc.setTextColor(71, 85, 105);
  r.notes.forEach(n => { doc.text(clean(n), ml, y); y += 5; });
  y += 2;
  doc.setFont('helvetica', 'bold'); doc.setFontSize(10); doc.setTextColor(30, 41, 59);
  doc.text(clean(`Total semaine : ${r.total}  ·  contrat ${r.contrat}  ·  HS 25 % : ${r.hs25}  ·  HS 50 % : ${r.hs50}`), ml, y); y += 6;
  doc.setFont('helvetica', 'normal'); doc.setFontSize(9); doc.setTextColor(100, 116, 139);
  doc.text(clean(r.note), ml, y); y += 14;
  doc.setDrawColor(203, 213, 225);
  doc.rect(ml, y, cw / 2 - 4, 28); doc.rect(ml + cw / 2 + 4, y, cw / 2 - 4, 28);
  doc.text('Signature du salarié', ml + 3, y + 5); doc.text("Signature de l'employeur", ml + cw / 2 + 7, y + 5);
  doc.save(`releve-${e.nom.toLowerCase().replace(/[^a-z0-9]+/g, '-')}-S${taIsoWeek(mon)}-${mon.slice(0, 4)}.pdf`);
}

// ── Paramètres → Temps de travail ──────────────────────────────────────────
async function taRenderSettings() {
  const el = document.getElementById('ta-settings');
  if (!el || KIOSK_MODE || !window.SupabaseDB) return;
  if (!TA.loaded && !TA._settingsLoaded) {
    TA._settingsLoaded = true;
    try { await taLoadGlobals(); } catch (e) { el.innerHTML = taNote('Chargement impossible : ' + taEsc(e.message || e), 'bad'); return; }
  }
  const c = TA.cfg;
  const radio = (v, t, ex) => `<button class="ta-radio${c.semaine_cheval === v ? ' on' : ''}" onclick="taSaveCfg({semaine_cheval:'${v}'})"><i></i><span><b>${t}</b><span class="ta-small">${ex}</span></span></button>`;
  const hol = [...TA.hol.entries()].sort((a, b) => a[0] < b[0] ? -1 : 1).filter(h => h[0] >= taAdd(taToday(), -400))
    .map(h => `<div class="ta-row ta-holrow"><span>${taCap(taNice(h[0]))} ${h[0].slice(0, 4)}</span><span>${taEsc(h[1])}</span>
      <button class="btn btn-ghost btn-xs" onclick="taDelHoliday('${h[0]}')" aria-label="Supprimer">✕</button></div>`).join('');
  const kiosk = location.origin + location.pathname + '?kiosk=1';
  el.innerHTML = `<div class="settings-title">⏱ Temps de travail</div>
    <div class="ta-set-grid">
      <div><div class="ta-label">Semaines à cheval sur deux mois</div><div class="ta-small" style="margin-bottom:8px">Le mois où sont payées les heures sup d’une semaine qui commence dans un mois et finit dans le suivant.</div>
        ${radio('fin', 'Mois de fin de semaine (par défaut)', 'ex. lundi 28 sept. → vendredi 2 oct. : heures sup payées en octobre')}
        ${radio('debut', 'Mois de début de semaine', 'ex. lundi 28 sept. → vendredi 2 oct. : heures sup payées en septembre')}</div>
      <div><div class="ta-label">Heures supplémentaires</div>
        <div class="form-grid"><div class="fg"><label>Durée de référence (h/semaine)</label><input type="number" step="0.5" id="ta-cfg-ref" value="${c.heures_ref}"></div>
        <div class="fg"><label>Heures majorées à 25 %</label><input type="number" step="0.5" id="ta-cfg-25" value="${c.heures_25}"></div>
        <div class="fg"><label>CP acquis par an (j ouvrés)</label><input type="number" step="0.5" id="ta-cfg-cp" value="${c.cp_annuels}"></div>
        <div class="fg" style="justify-content:flex-end"><button class="btn btn-primary btn-sm" onclick="taSaveCfg({heures_ref:taNum(document.getElementById('ta-cfg-ref').value),heures_25:taNum(document.getElementById('ta-cfg-25').value),cp_annuels:taNum(document.getElementById('ta-cfg-cp').value)})">Enregistrer</button></div></div>
        <div class="ta-small" style="margin-top:6px">Au-delà de ${taFh(c.heures_ref)} h : les ${taFh(c.heures_25)} premières heures à 25 % (${taFh(c.heures_ref)} → ${taFh(c.heures_ref + c.heures_25)} h), puis 50 %. Calcul par semaine civile complète.</div></div>
      <div><div class="ta-label">Jours fériés</div><div class="ta-small" style="margin-bottom:6px">Pré-remplis dans la grille (case « F ») et exclus du décompte des congés.</div>
        <div class="ta-hols">${hol || '<div class="ta-small">Aucun.</div>'}</div>
        <div class="ta-row" style="margin-top:8px;gap:6px"><input type="date" class="filter-sel" value="${TA.holDate}" oninput="TA.holDate=this.value">
          <input type="text" class="filter-sel" placeholder="Nom (ex : Pont de l’Ascension)" value="${taEsc(TA.holName)}" oninput="TA.holName=this.value" style="flex:1">
          <button class="btn btn-ghost btn-sm" onclick="taAddHoliday()">Ajouter</button></div></div>
      <div><div class="ta-label">Kiosque de pointage</div><div class="ta-small" style="margin-bottom:6px">Retiré du menu : il s’ouvre directement sur la tablette avec ce lien.</div>
        <div class="ta-row" style="gap:6px"><code class="ta-code">${taEsc(kiosk)}</code><button class="btn btn-ghost btn-sm" onclick="navigator.clipboard.writeText('${taEsc(kiosk)}').then(()=>ptgToast('Lien copié'))">Copier</button></div></div>
    </div>`;
}

async function taSaveCfg(patch) {
  const c = Object.assign({}, TA.cfg, patch);
  if ([c.heures_ref, c.heures_25, c.cp_annuels].some(v => isNaN(v))) { ptgToast('Valeurs invalides'); return; }
  const { data, error } = await window.SupabaseDB.rpc('enregistrer_parametres_temps', { p_semaine_cheval: c.semaine_cheval, p_heures_ref: c.heures_ref, p_heures_25: c.heures_25, p_cp_annuels: c.cp_annuels });
  if (error || !data?.ok) { ptgToast('⚠ ' + (error?.message || data?.message)); return; }
  TA.cfg = c;
  taRenderSettings();
  if (TA.loaded) taRefresh();
  ptgToast('Réglage enregistré — heures sup recalculées');
}
async function taAddHoliday() {
  if (!/^\d{4}-\d\d-\d\d$/.test(TA.holDate) || !TA.holName.trim()) { ptgToast('Indique la date et le nom'); return; }
  const { data, error } = await window.SupabaseDB.rpc('enregistrer_jour_ferie', { p_date: TA.holDate, p_libelle: TA.holName.trim() });
  if (error || !data?.ok) { ptgToast('⚠ ' + (error?.message || data?.message)); return; }
  TA.hol.set(TA.holDate, TA.holName.trim()); TA.holDate = ''; TA.holName = '';
  taRenderSettings(); if (TA.loaded) taRefresh();
  ptgToast('Férié ajouté');
}
async function taDelHoliday(iso) {
  if (!confirm('Supprimer le férié du ' + taNice(iso) + ' ?')) return;
  const { data, error } = await window.SupabaseDB.rpc('supprimer_jour_ferie', { p_date: iso });
  if (error || !data?.ok) { ptgToast('⚠ ' + (error?.message || data?.message)); return; }
  TA.hol.delete(iso); taRenderSettings(); if (TA.loaded) taRefresh();
}

document.addEventListener('keydown', ev => {
  if (ev.key !== 'Escape') return;
  if (TA.modal) taCloseModal(); else if (TA.drawer) taCloseDrawer();
});
