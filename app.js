// Mode kiosque (Raspberry Pi dédié au badge/PIN) : verrouille l'app sur
// Pointage > Kiosque, masque toute donnée RH. Voir showTab() et le bloc
// CSS body.kiosk-mode. Jamais actif par défaut — seule l'URL du Pi porte
// ?kiosk=1, le PC de Hugo garde l'accès admin complet sans ce paramètre.
const KIOSK_MODE = new URLSearchParams(location.search).get('kiosk') === '1';

// ═══════════════════════════════════════════
// DATA DEFAULTS
// ═══════════════════════════════════════════
const DEFAULT_SETTINGS = {
  smic: 12.31,   // SMIC au 1er juin 2026 (revalorisation +2,41%)
  charges: 42,
  baseH: 151.67, // Base 35h/semaine × 52/12
  quotaHSup: 450, // Contingent annuel H.Sup — accord collectif d'entreprise (~8h+/sem)
  maj25: 25,
  maj50: 50,
  nfcEnabled: false, // badge accepté sur le kiosque de ce poste (toujours actif en ?kiosk=1)
};

// ── CCM Métallurgie IDCC 3248 — Grille SMH 2024 (toujours en vigueur en 2026) ──
// 18 classes regroupées par paires en 9 groupes (A→I)
// Source : UIMM / gestionsociale.fr — Pas de revalorisation signée en 2025
// NB : Classes 1 et 2 (Groupe A) ont un SMH < SMIC → SMIC s'applique obligatoirement
const DEFAULT_CCM = {
  1:  {groupe:'A',label:'Classe 1',smhAnnuel:21700, smhMensuel:1808, tauxMin:11.92, categorie:'Non-cadre', desc:"Exécution simple, travaux répétitifs sous instructions précises"},
  2:  {groupe:'A',label:'Classe 2',smhAnnuel:21850, smhMensuel:1821, tauxMin:12.01, categorie:'Non-cadre', desc:"Exécution simple, légère technicité ou polyvalence"},
  3:  {groupe:'B',label:'Classe 3',smhAnnuel:22450, smhMensuel:1871, tauxMin:12.34, categorie:'Non-cadre', desc:'Qualifié, autonomie limitée dans un périmètre défini'},
  4:  {groupe:'B',label:'Classe 4',smhAnnuel:23400, smhMensuel:1950, tauxMin:12.86, categorie:'Non-cadre', desc:'Qualifié, autonomie plus large, contribution active'},
  5:  {groupe:'C',label:'Classe 5',smhAnnuel:24250, smhMensuel:2021, tauxMin:13.33, categorie:'Non-cadre', desc:'Technicien·ne, maîtrise technique du poste'},
  6:  {groupe:'C',label:'Classe 6',smhAnnuel:25550, smhMensuel:2129, tauxMin:14.04, categorie:'Non-cadre', desc:'Technicien·ne confirmé·e — seuil accueil Bac+2 (BTS/DUT)'},
  7:  {groupe:'D',label:'Classe 7',smhAnnuel:26400, smhMensuel:2200, tauxMin:14.51, categorie:'Non-cadre', desc:'Technicien·ne supérieur·e, polyvalence avancée'},
  8:  {groupe:'D',label:'Classe 8',smhAnnuel:28450, smhMensuel:2371, tauxMin:15.63, categorie:'Non-cadre', desc:'Technicien·ne supérieur·e confirmé·e, expertise reconnue'},
  9:  {groupe:'E',label:'Classe 9',smhAnnuel:30500, smhMensuel:2542, tauxMin:16.76, categorie:'Non-cadre', desc:'Agent·e de maîtrise, coordination d\'équipe'},
  10: {groupe:'E',label:'Classe 10',smhAnnuel:33700, smhMensuel:2808, tauxMin:18.51, categorie:'Non-cadre', desc:'Maîtrise confirmée, expertise opérationnelle élargie'},
  11: {groupe:'F',label:'Classe 11',smhAnnuel:34900, smhMensuel:2908, tauxMin:19.17, categorie:'Cadre',     desc:'Cadre débutant — seuil accueil Bac+5 / ingénieur'},
  12: {groupe:'F',label:'Classe 12',smhAnnuel:36700, smhMensuel:3058, tauxMin:20.16, categorie:'Cadre',     desc:'Cadre, expertise technique ou managériale confirmée'},
  13: {groupe:'G',label:'Classe 13',smhAnnuel:40000, smhMensuel:3333, tauxMin:21.98, categorie:'Cadre',     desc:'Cadre senior, responsabilités managériales importantes'},
  14: {groupe:'G',label:'Classe 14',smhAnnuel:43900, smhMensuel:3658, tauxMin:24.12, categorie:'Cadre',     desc:'Cadre senior+, management multi-équipes'},
  15: {groupe:'H',label:'Classe 15',smhAnnuel:47000, smhMensuel:3917, tauxMin:25.83, categorie:'Cadre',     desc:'Cadre confirmé haute responsabilité, direction de département'},
  16: {groupe:'H',label:'Classe 16',smhAnnuel:52000, smhMensuel:4333, tauxMin:28.57, categorie:'Cadre',     desc:'Direction de service, forte autonomie stratégique'},
  17: {groupe:'I',label:'Classe 17',smhAnnuel:59300, smhMensuel:4942, tauxMin:32.59, categorie:'Cadre',     desc:'Cadre dirigeant, expert très haut niveau'},
  18: {groupe:'I',label:'Classe 18',smhAnnuel:68000, smhMensuel:5667, tauxMin:37.37, categorie:'Cadre',     desc:'Direction opérationnelle, impact stratégique majeur'},
};

const CONTRACT_COLORS = {
  CDI:'#10b981', CDD:'#3b82f6', Apprentissage:'#f59e0b',
  Intérim:'#a855f7', 'Temps partiel':'#ec4899', Stage:'#9ca3af'
};

// GROUP_COLORS is now a function: getGroupeColors()

// ═══════════════════════════════════════════
// STATE
// ═══════════════════════════════════════════
let employees = [];
let settings = {...DEFAULT_SETTINGS};
let ccmClasses = JSON.parse(JSON.stringify(DEFAULT_CCM));
let sortField = 'nom', sortDir = 1;
let charts = {};

// Helpers CCM
function getCcmClass(classeNum) {
  return ccmClasses[parseInt(classeNum)] || ccmClasses[1];
}
function getCcmMinRate(classeNum) {
  // Taux horaire convention (peut être sous SMIC pour classes 1-2)
  return getCcmClass(classeNum).tauxMin;
}
function getEffectiveMin(classeNum) {
  // Minimum légal effectif = max(taux CCM, SMIC)
  return Math.max(getCcmMinRate(classeNum), settings.smic);
}
function getGroupeFromClasse(classeNum) {
  return getCcmClass(classeNum).groupe;
}
function getGroupeColors() {
  return {A:'#a89cf8',B:'#00c9a7',C:'#60a5fa',D:'#fbbf24',E:'#f87171',F:'#c084fc',G:'#f472b6',H:'#2dd4bf',I:'#fb923c'};
}
// Retrocompat: some employees might have old 'groupe' field without classe_num
function resolveClasse(emp) {
  if (emp.classe_num && parseInt(emp.classe_num)) return parseInt(emp.classe_num);
  // Map old groupe → default classe
  const defaultMap = {A:1,B:3,C:5,D:7,E:9,F:11,G:13,H:15,I:17};
  return defaultMap[emp.groupe] || 1;
}
function isMinWageExempt(emp) {
  // Apprentis et stagiaires suivent un barème légal spécifique (% du SMIC
  // selon l'âge / l'année de formation), distinct du mini SMIC/CCM des autres
  // contrats — on ne leur applique donc pas le plancher automatique.
  return emp.type_contrat === 'Apprentissage' || emp.type_contrat === 'Stage';
}

// ═══════════════════════════════════════════
// SYNC SUPABASE — salariés (table `employes` partagée avec le module Pointage)
// ═══════════════════════════════════════════
function isUuid(v) {
  return typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
}

function mapSupabaseRowToEmployee(row) {
  const classeNum = row.classe_num || 1;
  const cl = getCcmClass(classeNum);
  return {
    id: row.id,
    nom: row.nom || '',
    prenom: row.prenom || '',
    date_entree: row.date_entree || '',
    date_sortie: row.date_sortie || null,
    type_contrat: row.type_contrat || 'CDI',
    poste: row.poste || '',
    classe_num: classeNum,
    groupe: cl.groupe,
    heures_semaine: row.heures_semaine ?? 35,
    heures_sup_semaine: row.heures_sup_semaine ?? 0,
    taux_horaire: row.taux_horaire ?? 0,
    notes: row.notes || '',
    hasBadge: !!row.has_badge,
    adresse: row.adresse || '',
    telephone_perso: row.telephone_perso || '',
    email_perso: row.email_perso || '',
    alerteVue: !!row.alerte_vue,
    portail_actif: !!row.portail_actif,
    hausse_date: row.hausse_date || null,   // prochaine évolution déjà saisie (table remunerations)
    hausse_taux: row.hausse_taux ?? null,
    acces_externe: !!row.acces_externe,
  };
}

async function pushEmployeeToSupabase(emp) {
  const db = window.SupabaseDB;
  if (!db) return null;
  const { data, error } = await db.rpc('upsert_employe_rh', {
    p_id: isUuid(emp.id) ? emp.id : null,
    p_nom: emp.nom,
    p_prenom: emp.prenom,
    p_classe_num: resolveClasse(emp),
    p_taux_horaire: parseFloat(emp.taux_horaire) || 0,
    p_heures_semaine: parseFloat(emp.heures_semaine) || 35,
    p_heures_sup_semaine: parseFloat(emp.heures_sup_semaine) || 0,
    p_date_entree: emp.date_entree || null,
    p_date_sortie: emp.date_sortie || null,
    p_type_contrat: emp.type_contrat || null,
    p_poste: emp.poste || null,
    p_notes: emp.notes || null,
    p_adresse: emp.adresse || null,
    p_telephone_perso: emp.telephone_perso || null,
    p_email_perso: emp.email_perso || null,
  });
  if (error || data?.ok === false) {
    ptgToast('⚠ Sync Supabase échouée : ' + (data?.message || error?.message || 'erreur inconnue'));
    return null;
  }
  return data.id;
}

async function deleteEmployeeFromSupabase(id) {
  const db = window.SupabaseDB;
  if (!db || !isUuid(id)) return;
  const { data, error } = await db.rpc('supprimer_employe_rh', { p_id: id });
  if (error || data?.ok === false) {
    ptgToast('⚠ Suppression refusée : ' + (error?.message || data?.message));
    syncEmployeesFromSupabase({ silent: true });
  }
}

// La fiche d'un administrateur RH ne part pas à la corbeille (règle aussi côté serveur).
async function adminsParmi(ids) {
  const db = window.SupabaseDB;
  if (!db) return [];
  const { data, error } = await db.rpc('get_admins_rh');
  if (error || !Array.isArray(data)) return [];
  return data.filter(a => a.is_rh_admin && ids.includes(a.id)).map(a => `${a.prenom} ${a.nom}`);
}

let unlinkedPtgAccounts = [];

async function syncEmployeesFromSupabase(opts = {}) {
  const db = window.SupabaseDB;
  if (!db) return;
  const { data, error } = await db.rpc('get_employes_rh');
  if (error) {
    if (!opts.silent) ptgToast('⚠ Chargement Supabase échoué : ' + error.message);
    return;
  }
  const rows = data || [];
  // Ne retient que les salariés déjà enrichis côté RH (classe_num renseigné) —
  // un employé créé uniquement via le kiosque Pointage (classe_num vide) ne
  // doit pas déclencher un écrasement des données locales. On garde ces
  // comptes "sans fiche RH" à part pour les proposer dans l'onglet Équipe.
  const withRh = rows.filter(r => r.classe_num !== null && r.classe_num !== undefined);
  unlinkedPtgAccounts = rows.filter(r => (r.classe_num === null || r.classe_num === undefined) && !r.acces_externe);
  renderUnlinkedPtgAccounts();
  if (!withRh.length) return; // rien d'importé côté RH — on garde les données locales
  employees = withRh.map(mapSupabaseRowToEmployee);
  saveData();
  refresh();
  renderSettings();
  loadAccesExternes();
}

// ── Accès externes : accès à la PWA sans contrat en cours (holding, prestataire) ──
// Tableau à part sous la liste Équipe : hors paie et hors totaux.
let eqExternes = [];
async function loadAccesExternes() {
  const { data, error } = await window.SupabaseDB.rpc('get_acces_externes_rh');
  if (error) return;
  eqExternes = data || [];
  renderAccesExternes();
}
function renderAccesExternes() {
  const el = document.getElementById('eq-externes');
  if (!el) return;
  if (!eqExternes.length) { el.innerHTML = ''; return; }
  const rows = eqExternes.map(x => {
    const fiche = employees.some(e => e.id === x.id);
    const contrat = x.contrat_en_cours ? 'en cours' : x.date_sortie ? 'terminé le ' + fmtDate(x.date_sortie) : '—';
    const pwa = !x.compte_pwa ? '<span class="eq-pill eq-p-warn" title="Sans compte PWA, l’accès externe ne sert à rien">aucun ⚠</span>'
      : x.compte_actif ? taEsc(x.compte_pwa) : `${taEsc(x.compte_pwa)} <span class="eq-pill eq-p-mute">désactivé</span>`;
    const accorde = x.accorde_le
      ? `${fmtDate(x.accorde_le)} par ${taEsc(x.accorde_par || '?')}${x.motif ? ' : « ' + taEsc(x.motif) + ' »' : ''}`
      : '<span class="eq-muted">avant le suivi</span>';
    return `<tr class="row-emp" onclick="${fiche ? `eqOpenFiche('${x.id}','acces')` : `eqOpenRetraitExterne('${x.id}')`}">
      <td class="eq-who"><b>${taEsc((x.nom || '').toUpperCase())} ${taEsc(x.prenom)}</b>${fiche ? '' : '<span>sans fiche RH</span>'}</td>
      <td>${contrat}</td><td>${pwa}</td><td>${x.is_rh_admin ? 'oui' : 'non'}</td><td>${accorde}</td></tr>`;
  }).join('');
  el.innerHTML = `<h3 style="margin:20px 0 4px">🔑 Accès externes (${eqExternes.length})</h3>
    <div class="eq-hint" style="margin-bottom:8px">Accès à la PWA sonotrad sans contrat en cours. Cliquez sur une ligne pour retirer l’accès s’il n’a plus lieu d’être.</div>
    <div class="tbl-wrap"><table style="min-width:0">
      <thead><tr><th>Personne</th><th>Contrat</th><th>Compte PWA</th><th>Admin RH</th><th>Accordé</th></tr></thead>
      <tbody>${rows}</tbody></table></div>`;
}

function renderUnlinkedPtgAccounts() {
  const box  = document.getElementById('unlinked-ptg-section');
  const list = document.getElementById('unlinked-ptg-list');
  if (!box || !list) return;
  if (!unlinkedPtgAccounts.length) { box.style.display = 'none'; list.innerHTML = ''; return; }
  box.style.display = 'block';
  list.innerHTML = unlinkedPtgAccounts.map(e => `
    <div class="card" style="margin-bottom:8px;display:flex;align-items:center;gap:12px;padding:12px;">
      <div style="width:36px;height:36px;border-radius:50%;background:rgba(148,163,184,.2);display:flex;align-items:center;justify-content:center;font-size:16px;flex-shrink:0;">👤</div>
      <div style="flex:1;min-width:0;">
        <div style="font-weight:700;">${e.prenom} ${e.nom}</div>
        <div style="font-size:12px;color:var(--muted);">Compte sonotrad-pwa — pas de fiche RH</div>
      </div>
      <button class="btn btn-primary btn-sm" onclick="openModalForUnlinked('${e.id}','${String(e.prenom||'').replace(/'/g,"\\'")}','${String(e.nom||'').replace(/'/g,"\\'")}')">Compléter la fiche</button>
    </div>`).join('');
}

/* ─── Corbeille : salariés soft-deleted, purge définitive ─────────────── */

let deletedEmployeesRh = [];
let corbeilleLoaded = false;

async function toggleCorbeille() {
  const box = document.getElementById('corbeille-section');
  if (!box) return;
  const opening = box.style.display === 'none';
  if (opening && !corbeilleLoaded) {
    await loadCorbeille();
    corbeilleLoaded = true;
  }
  box.style.display = opening ? 'block' : 'none';
}

async function loadCorbeille() {
  const db = window.SupabaseDB;
  const list = document.getElementById('corbeille-list');
  if (!db || !list) return;
  list.innerHTML = '<div style="padding:12px;color:var(--muted);font-size:13px">Chargement…</div>';
  const { data, error } = await db.rpc('get_employes_supprimes_rh');
  if (error) {
    list.innerHTML = `<div style="padding:12px;color:var(--danger);font-size:13px">Erreur : ${error.message}</div>`;
    return;
  }
  deletedEmployeesRh = data || [];
  renderCorbeille();
}

function renderCorbeille() {
  const list = document.getElementById('corbeille-list');
  if (!list) return;
  if (!deletedEmployeesRh.length) {
    list.innerHTML = '<div style="padding:12px;color:var(--muted);font-size:13px">Corbeille vide.</div>';
    return;
  }
  list.innerHTML = deletedEmployeesRh.map(e => {
    const supprimeLe = e.updated_at ? new Date(e.updated_at).toLocaleDateString('fr-FR') : '?';
    return `
    <div class="card" style="margin-bottom:8px;display:flex;align-items:center;gap:12px;padding:12px;">
      <div style="width:36px;height:36px;border-radius:50%;background:rgba(239,68,68,.15);display:flex;align-items:center;justify-content:center;font-size:16px;flex-shrink:0;">🗑</div>
      <div style="flex:1;min-width:0;">
        <div style="font-weight:700;">${e.prenom || '(sans prénom)'} ${e.nom || '(sans nom)'}</div>
        <div style="font-size:12px;color:var(--muted);">Supprimé le ${supprimeLe}${e.poste ? ' · ' + e.poste : ''}</div>
      </div>
      <button class="btn btn-danger btn-sm" onclick="purgerEmploye('${e.id}','${String(e.prenom||'').replace(/'/g,"\\'")}','${String(e.nom||'').replace(/'/g,"\\'")}')">🗑️ Purger définitivement</button>
    </div>`;
  }).join('');
}

async function purgerEmploye(id, prenom, nom) {
  if (!confirm(`Supprimer DÉFINITIVEMENT ${prenom} ${nom} ?\n\nIrréversible : efface aussi tout son historique (pointages, corrections, congés). Il ne restera aucune trace.`)) return;
  const db = window.SupabaseDB;
  if (!db) return;
  const { data, error } = await db.rpc('purger_employe_rh', { p_id: id });
  if (error || data?.ok === false) {
    ptgToast('Erreur : ' + (data?.message || error?.message || 'inconnue'));
    return;
  }
  ptgToast(`✓ ${prenom} ${nom} purgé définitivement`);
  deletedEmployeesRh = deletedEmployeesRh.filter(e => e.id !== id);
  renderCorbeille();
}

async function importEmployeesToSupabase() {
  const db = window.SupabaseDB;
  if (!db) { ptgToast('Supabase non configuré'); return; }
  if (!employees.length) { ptgToast('Aucun salarié à importer'); return; }
  if (!confirm(`Envoyer ${employees.length} salarié(s) vers Supabase ?\n\nUn salarié déjà présent avec le même nom/prénom (ex. créé via le kiosque Pointage) sera enrichi plutôt que dupliqué.`)) return;
  let ok = 0, fail = 0;
  for (const emp of employees) {
    const id = await pushEmployeeToSupabase(emp);
    if (id) ok++; else fail++;
  }
  ptgToast(`✓ ${ok} salarié(s) synchronisé(s)${fail ? `, ${fail} échec(s)` : ''}`);
  await syncEmployeesFromSupabase({ silent: true });
}

// Écoute les changements de `employes` (édités depuis rh-metal ou sonotrad-pwa)
// pour rafraîchir l'Équipe/Dashboard sans reload manuel. Canal public au
// payload minimal {op,id} — jamais de pin_hash/nfc_uid dessus (voir migration
// employes_broadcast_change côté sonotrad-pwa).
let employesChannel = null;
function subscribeEmployesChanges() {
  if (employesChannel || !window.SupabaseDB) return;
  employesChannel = window.SupabaseDB.channel('employes-changes')
    .on('broadcast', { event: 'employes_changed' }, () => {
      syncEmployeesFromSupabase({ silent: true });
    })
    .subscribe();
}

// ═══════════════════════════════════════════
// CONGÉS — calcul du solde CP (portail salarié ; la saisie est dans Temps & absences)
// ═══════════════════════════════════════════
let conges = [];

// Période de référence CP : 1er juin N-1 → 31 mai N (règle légale standard).
function getCpPeriod(refDate = new Date()) {
  const y = refDate.getFullYear();
  const juin1 = new Date(y, 5, 1);
  if (refDate >= juin1) return { debut: new Date(y, 5, 1), fin: new Date(y + 1, 4, 31) };
  return { debut: new Date(y - 1, 5, 1), fin: new Date(y, 4, 31) };
}

function sommeConges(empId, type, debut, fin) {
  return conges
    .filter(c => c.employe_id === empId && c.type === type)
    .filter(c => { const d = new Date(c.date_debut + 'T00:00:00'); return d >= debut && d <= fin; })
    .reduce((s, c) => s + parseFloat(c.jours), 0);
}

// Acquisition : 25j ouvrés/an (équivalent légal des 30j ouvrables), au
// prorata du temps de présence dans la période depuis l'embauche.
// Simplification connue : n'exclut pas du calcul d'acquisition les longues
// absences maladie/sans solde (qui réduisent légalement l'acquisition réelle
// au-delà d'un certain seuil) — à ajuster manuellement si besoin.
function calcSoldeCP(emp) {
  const { debut, fin } = getCpPeriod();
  const today = new Date();
  const entree = emp.date_entree ? new Date(emp.date_entree + 'T00:00:00') : debut;
  const departCalcul = today < fin ? today : fin;
  const debutAcquisition = entree > debut ? entree : debut;
  const joursEcoules = Math.max(0, (departCalcul - debutAcquisition) / (1000 * 60 * 60 * 24));
  const moisEcoules = joursEcoules / 30.44;
  const acquis = Math.min(25, moisEcoules * (25 / 12));
  const pris = sommeConges(emp.id, 'cp', debut, fin);
  return {
    acquis: Math.round(acquis * 10) / 10,
    pris,
    solde: Math.round((acquis - pris) * 10) / 10,
  };
}

function fmtDateFr(dateStr) {
  if (!dateStr) return '';
  return new Date(dateStr + 'T00:00:00').toLocaleDateString('fr-FR');
}

// ═══════════════════════════════════════════
// PERSISTENCE
// ═══════════════════════════════════════════
function loadData() {
  try {
    const emp = localStorage.getItem('rh_employees');
    if (emp) employees = JSON.parse(emp);
    const set = localStorage.getItem('rh_settings');
    if (set) settings = {...DEFAULT_SETTINGS, ...JSON.parse(set)};
    // Migration : l'ancien quota légal (220h) est remplacé par le contingent
    // de l'accord collectif (450h) — on corrige les réglages déjà enregistrés.
    if (settings.quotaHSup === 220) settings.quotaHSup = 450;
    const ccm = localStorage.getItem('rh_ccm');
    if (ccm) {
      const saved = JSON.parse(ccm);
      // Support both new (numeric keys) and old (letter keys) format
      if (saved[1]) ccmClasses = {...DEFAULT_CCM, ...saved};
    }
  } catch(e) {}
  if (!employees.length) employees = SAMPLE_EMPLOYEES();
}

function saveData() {
  localStorage.setItem('rh_employees', JSON.stringify(employees));
}
function saveSettings() {
  settings.smic = parseFloat(document.getElementById('s-smic').value) || DEFAULT_SETTINGS.smic;
  settings.charges = parseFloat(document.getElementById('s-charges').value) || DEFAULT_SETTINGS.charges;
  settings.baseH = parseFloat(document.getElementById('s-base-h').value) || DEFAULT_SETTINGS.baseH;
  settings.quotaHSup = parseFloat(document.getElementById('s-quota-hsup').value) || DEFAULT_SETTINGS.quotaHSup;
  settings.maj25 = parseFloat(document.getElementById('s-maj25').value) || DEFAULT_SETTINGS.maj25;
  settings.maj50 = parseFloat(document.getElementById('s-maj50').value) || DEFAULT_SETTINGS.maj50;
  settings.nfcEnabled = document.getElementById('s-nfc-enabled').checked;
  localStorage.setItem('rh_settings', JSON.stringify(settings));
}
function saveCcm() {
  Object.keys(ccmClasses).forEach(c => {
    const el = document.getElementById('ccm-min-' + c);
    if (el) ccmClasses[c].tauxMin = parseFloat(el.value) || ccmClasses[c].tauxMin;
  });
  localStorage.setItem('rh_ccm', JSON.stringify(ccmClasses));
}
function saveSettingsAll() { saveSettings(); saveCcm(); }
function resetSettings() {
  settings = {...DEFAULT_SETTINGS};
  ccmClasses = JSON.parse(JSON.stringify(DEFAULT_CCM));
  localStorage.removeItem('rh_settings');
  localStorage.removeItem('rh_ccm');
  renderSettings();
  refresh();
}

// ═══════════════════════════════════════════
// CALCULATIONS
// ═══════════════════════════════════════════
const WEEKS_PER_MONTH = 52/12;

function calcSalary(emp, overrideTaux) {
  // Le taux d'embauche (emp.taux_horaire) reste inchangé en base : c'est un
  // historique. Le taux réellement payé ne peut jamais descendre sous le
  // minimum effectif (SMIC ou CCM, le plus élevé) — revalorisé automatiquement
  // à chaque hausse du SMIC, sans qu'il soit nécessaire de modifier le dossier
  // du salarié.
  const storedRate = parseFloat(emp.taux_horaire) || 0;
  const effMin = getEffectiveMin(resolveClasse(emp));
  const rate = overrideTaux !== undefined ? overrideTaux : (isMinWageExempt(emp) ? storedRate : Math.max(storedRate, effMin));
  const hSem = parseFloat(emp.heures_semaine) || 35;
  const hSup = parseFloat(emp.heures_sup_semaine) || 0;
  const totalSem = hSem + hSup;
  const overSem = Math.max(0, totalSem - 35); // heures au-delà de 35h
  const maj25Sem = Math.min(overSem, 8);
  const maj50Sem = Math.max(0, overSem - 8);

  const baseH = Math.min(hSem, 35) * WEEKS_PER_MONTH;
  const sup25H = maj25Sem * WEEKS_PER_MONTH;
  const sup50H = maj50Sem * WEEKS_PER_MONTH;

  const basePay = baseH * rate;
  const sup25Pay = sup25H * rate * (1 + settings.maj25/100);
  const sup50Pay = sup50H * rate * (1 + settings.maj50/100);
  const totalMonthly = basePay + sup25Pay + sup50Pay;
  const totalAnnual = totalMonthly * 12;
  const costAnnual = totalAnnual * (1 + settings.charges/100);
  const hSupMonth = (sup25H + sup50H);
  const hSupAnnual = hSupMonth * 12;

  return {
    rate, baseH, sup25H, sup50H,
    basePay, sup25Pay, sup50Pay,
    monthly: totalMonthly,
    annual: totalAnnual,
    costAnnual, hSupMonth, hSupAnnual,
    supPay: sup25Pay + sup50Pay,
  };
}

function getAlerts(emp) {
  // Le taux d'embauche sous le SMIC/CCM n'est plus remonté en alerte : la
  // paie applique automatiquement le minimum effectif (voir calcSalary).
  // Seul le dépassement du contingent annuel H.Sup (accord collectif) reste
  // signalé, car il nécessite une action (repos compensateur, régularisation).
  const alerts = [];
  const sal = calcSalary(emp);
  if (sal.hSupAnnual > settings.quotaHSup) {
    alerts.push({type:'warn', msg:`H.Sup annuelles (${Math.round(sal.hSupAnnual)}h) > contingent accord collectif (${settings.quotaHSup}h)`});
  }
  return alerts;
}

function getActiveEmployees() {
  return employees.filter(e => !e.date_sortie || new Date(e.date_sortie) > new Date());
}

function aggregatePayroll(emps) {
  let monthly=0,annual=0,cost=0,hSupMonth=0,headcount=emps.length;
  emps.forEach(e => {
    const s = calcSalary(e);
    monthly += s.monthly;
    annual += s.annual;
    cost += s.costAnnual;
    hSupMonth += s.hSupMonth;
  });
  return {monthly, annual, cost, hSupMonth, headcount};
}

// ═══════════════════════════════════════════
// RENDER DASHBOARD
// ═══════════════════════════════════════════
function renderDashboard() {
  const active = getActiveEmployees();
  const agg = aggregatePayroll(active);
  const allAlerts = active.flatMap(e => getAlerts(e).map(a => ({...a, emp: e})));
  const alertCount = allAlerts.length;
  const avgRate = active.length ? active.reduce((s,e)=>s+(parseFloat(e.taux_horaire)||0),0)/active.length : 0;
  const cdiCount = active.filter(e=>e.type_contrat==='CDI').length;
  const hSupPct = agg.monthly ? (active.reduce((s,e)=>s+calcSalary(e).supPay,0)/agg.monthly*100) : 0;

  // KPIs
  document.getElementById('kpi-grid').innerHTML = `
    <div class="kpi c-accent"><div class="kpi-icon">👥</div><div class="kpi-lbl">Effectif actif</div><div class="kpi-val num">${active.length}</div><div class="kpi-sub">${cdiCount} CDI · ${active.length-cdiCount} autres</div></div>
    <div class="kpi c-teal"><div class="kpi-icon">💶</div><div class="kpi-lbl">Masse salariale / mois</div><div class="kpi-val num">${fmt(agg.monthly)}</div><div class="kpi-sub">Brut salarié</div></div>
    <div class="kpi c-blue"><div class="kpi-icon">📅</div><div class="kpi-lbl">Masse salariale / an</div><div class="kpi-val num">${fmt(agg.annual)}</div><div class="kpi-sub">Brut annuel</div></div>
    <div class="kpi c-purple"><div class="kpi-icon">🏢</div><div class="kpi-lbl">Coût total employeur / an</div><div class="kpi-val num">${fmt(agg.cost)}</div><div class="kpi-sub">Brut + ${settings.charges}% charges</div></div>
    <div class="kpi c-warn"><div class="kpi-icon">⏱️</div><div class="kpi-lbl">H.Sup / mois total</div><div class="kpi-val num">${fmtH(agg.hSupMonth)}</div><div class="kpi-sub">${pct(hSupPct)} de la masse sal.</div></div>
    <div class="kpi ${alertCount>0?'c-danger':'c-teal'}"><div class="kpi-icon">${alertCount>0?'⚠️':'✅'}</div><div class="kpi-lbl">Alertes H.Sup</div><div class="kpi-val">${alertCount}</div><div class="kpi-sub">${alertCount===0?'Sous le contingent':'Contingent annuel dépassé'}</div></div>
    <div class="kpi c-accent"><div class="kpi-icon">💰</div><div class="kpi-lbl">Taux horaire moyen</div><div class="kpi-val num">${avgRate.toFixed(2)}€</div><div class="kpi-sub">vs SMIC ${settings.smic.toFixed(2)}€</div></div>
    <div class="kpi c-teal"><div class="kpi-icon">📊</div><div class="kpi-lbl">Coût / salarié / mois</div><div class="kpi-val num">${active.length?fmt(agg.cost/12/active.length):'—'}</div><div class="kpi-sub">Coût employeur moyen</div></div>
  `;

  // Projection banner
  document.getElementById('proj-banner').innerHTML = `
    <div class="proj-item"><div class="proj-lbl">Brut mensuel</div><div class="proj-val num">${fmt(agg.monthly)}</div></div>
    <div class="proj-item"><div class="proj-lbl">Brut annuel</div><div class="proj-val num">${fmt(agg.annual)}</div></div>
    <div class="proj-item"><div class="proj-lbl">Coût employeur annuel</div><div class="proj-val num">${fmt(agg.cost)}</div></div>
    <div class="proj-item"><div class="proj-lbl">Coût H.Sup mensuelles</div><div class="proj-val num">${fmt(active.reduce((s,e)=>s+calcSalary(e).supPay,0))}</div></div>
    <div class="proj-item"><div class="proj-lbl">ETP moyen (35h)</div><div class="proj-val num">${active.reduce((s,e)=>s+(parseFloat(e.heures_semaine)||35)/35,0).toFixed(1)}</div></div>
  `;

  // Alert bar
  const bar = document.getElementById('alert-bar');
  if (alertCount > 0) {
    bar.style.display='flex';
    bar.innerHTML = `<b>⚠️ ${alertCount} alerte(s) :</b> ` + allAlerts.slice(0,5).map(a=>`<span>${a.emp.prenom} ${a.emp.nom} — ${a.msg}</span>`).join(' · ') + (allAlerts.length>5?` · <em>et ${allAlerts.length-5} autres</em>`:'');
  } else { bar.style.display='none'; }

  // Header badges
  if (alertCount>0) {
    document.getElementById('alert-badge').style.display='';
    document.getElementById('alert-badge').textContent=`⚠️ ${alertCount} alerte${alertCount>1?'s':''}`;
    document.getElementById('ok-badge').style.display='none';
  } else {
    document.getElementById('alert-badge').style.display='none';
    document.getElementById('ok-badge').style.display='';
  }

  renderCharts(active, agg);
}

// ═══════════════════════════════════════════
// CHARTS
// ═══════════════════════════════════════════
function destroyChart(id) { if(charts[id]) { charts[id].destroy(); delete charts[id]; } }

function renderCharts(active, agg) {
  // 1. Contract donut
  destroyChart('contract');
  const contractCounts = {};
  active.forEach(e=>{ contractCounts[e.type_contrat]=(contractCounts[e.type_contrat]||0)+1; });
  charts.contract = new Chart(document.getElementById('chartContract'), {
    type:'doughnut',
    data:{
      labels:Object.keys(contractCounts),
      datasets:[{data:Object.values(contractCounts),backgroundColor:Object.keys(contractCounts).map(k=>CONTRACT_COLORS[k]||'#888'),borderWidth:0,hoverOffset:4}]
    },
    options:{responsive:true,maintainAspectRatio:false,plugins:{legend:{position:'right',labels:{color:'#8b90a8',font:{size:11},boxWidth:10}}}}
  });

  const GC = getGroupeColors();
  // 2. Group bar (masse salariale)
  destroyChart('group');
  const groupPay = {};
  active.forEach(e=>{
    const g = getGroupeFromClasse(resolveClasse(e));
    groupPay[g] = (groupPay[g]||0) + calcSalary(e).monthly;
  });
  const grpKeys = Object.keys(groupPay).sort();
  charts.group = new Chart(document.getElementById('chartGroup'), {
    type:'bar',
    data:{
      labels:grpKeys.map(g=>`Grp ${g}`),
      datasets:[{label:'Masse sal. mensuelle (€)',data:grpKeys.map(g=>Math.round(groupPay[g])),backgroundColor:grpKeys.map(g=>GC[g]||'#888'),borderRadius:6,borderWidth:0}]
    },
    options:{responsive:true,maintainAspectRatio:false,plugins:{legend:{display:false}},scales:{x:{ticks:{color:'#8b90a8'}},y:{ticks:{color:'#8b90a8'},grid:{color:'rgba(42,46,69,.4)'}}}}
  });

  // 3. 12-month projection line
  destroyChart('proj');
  const base = agg.monthly;
  const months = ['Jan','Fév','Mar','Avr','Mai','Jun','Jul','Aoû','Sep','Oct','Nov','Déc'];
  const now = new Date().getMonth();
  const labels = months.slice(now).concat(months.slice(0,now));
  const projData = labels.map((_,i)=>Math.round(base*(1+i*0.001)));
  const costData = projData.map(v=>Math.round(v*(1+settings.charges/100)));
  charts.proj = new Chart(document.getElementById('chartProj'), {
    type:'line',
    data:{
      labels,
      datasets:[
        {label:'Brut mensuel',data:projData,borderColor:'#a89cf8',backgroundColor:'rgba(124,108,248,.1)',fill:true,tension:.4,pointRadius:3,borderWidth:2},
        {label:'Coût employeur',data:costData,borderColor:'#00c9a7',backgroundColor:'rgba(0,201,167,.05)',fill:true,tension:.4,pointRadius:3,borderWidth:2}
      ]
    },
    options:{responsive:true,maintainAspectRatio:false,plugins:{legend:{labels:{color:'#8b90a8',font:{size:11},boxWidth:10}}},scales:{x:{ticks:{color:'#8b90a8'}},y:{ticks:{color:'#8b90a8'},grid:{color:'rgba(42,46,69,.4)'}}}}
  });

  // 4. Individual cost bar
  destroyChart('indiv');
  const sortedByPay = [...active].sort((a,b)=>calcSalary(b).monthly-calcSalary(a).monthly).slice(0,12);
  charts.indiv = new Chart(document.getElementById('chartIndiv'), {
    type:'bar',
    data:{
      labels:sortedByPay.map(e=>`${e.prenom[0]||''}. ${e.nom}`),
      datasets:[
        {label:'Brut mensuel',data:sortedByPay.map(e=>Math.round(calcSalary(e).monthly)),backgroundColor:'rgba(124,108,248,.7)',borderRadius:4,borderWidth:0},
        {label:'H.Sup',data:sortedByPay.map(e=>Math.round(calcSalary(e).supPay)),backgroundColor:'rgba(245,158,11,.7)',borderRadius:4,borderWidth:0}
      ]
    },
    options:{responsive:true,maintainAspectRatio:false,plugins:{legend:{labels:{color:'#8b90a8',font:{size:10},boxWidth:8}}},scales:{x:{ticks:{color:'#8b90a8',font:{size:10}},stacked:true},y:{ticks:{color:'#8b90a8'},grid:{color:'rgba(42,46,69,.4)'},stacked:true}}}
  });

  // 5. H.Sup bar
  destroyChart('hsup');
  const withHsup = active.filter(e=>(parseFloat(e.heures_sup_semaine)||0)>0);
  charts.hsup = new Chart(document.getElementById('chartHSup'), {
    type:'bar',
    data:{
      labels:withHsup.map(e=>`${e.prenom[0]||''}. ${e.nom}`),
      datasets:[{label:'H.Sup / mois',data:withHsup.map(e=>+calcSalary(e).hSupMonth.toFixed(1)),backgroundColor:withHsup.map(e=>{const h=calcSalary(e).hSupAnnual;return h>settings.quotaHSup?'#ef4444':h>settings.quotaHSup*0.8?'#f59e0b':'#10b981';}),borderRadius:5,borderWidth:0}]
    },
    options:{responsive:true,maintainAspectRatio:false,plugins:{legend:{display:false}},scales:{x:{ticks:{color:'#8b90a8',font:{size:10}}},y:{ticks:{color:'#8b90a8'},grid:{color:'rgba(42,46,69,.4)'}}}}
  });
}

// ═══════════════════════════════════════════
// RENDER TABLE
// ═══════════════════════════════════════════
let sortState = {field:'nom', dir:1};
function sortBy(field) {
  if (sortState.field===field) sortState.dir*=-1;
  else { sortState.field=field; sortState.dir=1; }
  renderTable();
}

// ── État d'un salarié (colonne « État », filtre « À vérifier ») ─────────────
function eqToday() { return _ptgLocalDateStr(new Date()); }
function eqIsExited(e) { return !!e.date_sortie && e.date_sortie < eqToday(); }
function eqFmtTaux(v) { return (parseFloat(v) || 0).toFixed(2).replace('.', ',') + ' €'; }
function eqFmtDateLong(iso) { return new Date(iso + 'T12:00').toLocaleDateString('fr-FR', {day:'numeric', month:'long', year:'numeric'}); }
function eqPct(avant, apres) { const p = (apres / avant - 1) * 100; return (p >= 0 ? '+' : '') + p.toFixed(1).replace('.', ',') + ' %'; }

function eqEtat(e) {
  const out = [];
  const exited = eqIsExited(e);
  const cn = resolveClasse(e), min = getEffectiveMin(cn), taux = parseFloat(e.taux_horaire) || 0;
  if (exited) out.push({lvl:'danger', txt:'Contrat terminé', tip:`${e.type_contrat || 'Contrat'} terminé le ${fmtDate(e.date_sortie)}`});
  else if (!isMinWageExempt(e) && taux < min - 0.001) out.push({lvl:'warn', txt:'Sous le minimum', tip:`Taux saisi ${eqFmtTaux(taux)}, minimum ${eqFmtTaux(min)}. La paie applique déjà le minimum ; mettez la fiche à jour avec « Évolution de salaire ».`});
  if (!exited) getAlerts(e).forEach(a => out.push({lvl:'warn', txt:'Contingent h. sup', tip:a.msg}));
  if (!exited && e.hausse_date) out.push({lvl:'accent', txt:`Hausse le ${fmtDate(e.hausse_date).slice(0,5)}`, tip:`${eqFmtTaux(e.taux_horaire)} → ${eqFmtTaux(e.hausse_taux)} le ${fmtDate(e.hausse_date)}`});
  if (!exited && e.date_sortie) out.push({lvl:'mute', txt:`Fin ${fmtDate(e.date_sortie)}`, tip:'Date de fin du contrat en cours'});
  if (e.acces_externe) out.push({lvl:'accent', txt:'Externe', tip:'Accès externe à la PWA sans contrat en cours (voir le tableau Accès externes)'});
  if (isMinWageExempt(e)) out.push({lvl:'mute', txt: e.type_contrat === 'Stage' ? 'Barème stagiaire' : 'Barème apprenti', tip:'Barème légal spécifique : minimum SMIC/CCM non applicable'});
  return out;
}
function eqChips(list) {
  return list.map(c => `<span class="eq-pill eq-p-${c.lvl}" title="${taEsc(c.tip || '')}">${taEsc(c.txt)}</span>`).join('');
}

// ── Multi-select ─────────────────────────────
let selectedIds = new Set();

function toggleSelectAll(cb) {
  const boxes = document.querySelectorAll('#table-body input[type=checkbox]');
  boxes.forEach(b => {
    const id = b.dataset.id;
    b.checked = cb.checked;
    if (cb.checked) selectedIds.add(id); else selectedIds.delete(id);
    b.closest('tr').classList.toggle('selected', cb.checked);
  });
  updateBulkBar();
}

function toggleRow(id, cb) {
  if (cb.checked) selectedIds.add(id); else selectedIds.delete(id);
  cb.closest('tr').classList.toggle('selected', cb.checked);
  // sync select-all checkbox
  const allBoxes = document.querySelectorAll('#table-body input[type=checkbox]');
  const allChecked = [...allBoxes].every(b=>b.checked);
  const cbAll = document.getElementById('cb-all');
  if (cbAll) cbAll.checked = allChecked && allBoxes.length > 0;
  updateBulkBar();
}

function updateBulkBar() {
  const bar = document.getElementById('bulk-bar');
  const count = document.getElementById('bulk-count');
  const n = selectedIds.size;
  if (n > 0) {
    bar.classList.add('visible');
    count.textContent = `${n} salarié(s) sélectionné(s)`;
  } else {
    bar.classList.remove('visible');
  }
}

function clearSelection() {
  selectedIds.clear();
  document.querySelectorAll('#table-body input[type=checkbox]').forEach(b=>{
    b.checked=false;
    b.closest('tr').classList.remove('selected');
  });
  const cbAll = document.getElementById('cb-all');
  if (cbAll) cbAll.checked = false;
  updateBulkBar();
}

async function bulkDelete() {
  if (!selectedIds.size) return;
  const adm = await adminsParmi([...selectedIds]);
  if (adm.length) { alert(`${adm.join(', ')} : administrateur RH.\nRetire d'abord ce droit dans Paramètres avant de supprimer la fiche.`); return; }
  const names = employees.filter(e=>selectedIds.has(e.id)).map(e=>`${e.prenom} ${e.nom}`).join(', ');
  if (!confirm(`Mettre ${selectedIds.size} salarié(s) à la corbeille ?\n${names}`)) return;
  const idsToDelete = [...selectedIds];
  employees = employees.filter(e=>!selectedIds.has(e.id));
  selectedIds.clear();
  saveData();
  renderTable();
  renderDashboard();
  updateBulkBar();
  const cbAll = document.getElementById('cb-all');
  if (cbAll) cbAll.checked = false;
  idsToDelete.forEach(deleteEmployeeFromSupabase);
}

function bulkSetSortie() {
  if (!selectedIds.size) return;
  const today = eqToday();
  if (!confirm(`Marquer ${selectedIds.size} salarié(s) comme sortis aujourd'hui (${fmtDate(today)}) ?`)) return;
  const changed = [];
  employees.forEach(e=>{ if (selectedIds.has(e.id)) { e.date_sortie = today; changed.push(e); } });
  saveData();
  clearSelection();
  renderTable();
  renderDashboard();
  changed.forEach(pushEmployeeToSupabase);
}

function bulkExportCSV() {
  const sel = employees.filter(e=>selectedIds.has(e.id));
  if (!sel.length) return;
  const header = ['Nom','Prénom','Entrée','Sortie','Contrat','Poste','Groupe','Classe','H/sem','H.Sup/sem','Taux €/h','Brut/mois','Brut/an','Coût/an'];
  const rows = sel.map(e=>{
    const s = calcSalary(e);
    const cl = getCcmClass(resolveClasse(e));
    return [e.nom,e.prenom,e.date_entree||'',e.date_sortie||'',e.type_contrat||'',e.poste||'',cl.groupe,`Cl.${resolveClasse(e)}`,e.heures_semaine||35,e.heures_sup_semaine||0,e.taux_horaire||'',s.monthly.toFixed(2),s.annual.toFixed(2),s.costAnnual.toFixed(2)];
  });
  const csv = [header,...rows].map(r=>r.map(v=>`"${String(v).replace(/"/g,'""')}"`).join(';')).join('\n');
  const blob = new Blob(['﻿'+csv],{type:'text/csv;charset=utf-8'});
  const a = document.createElement('a'); a.href=URL.createObjectURL(blob);
  a.download=`selection_rh_${eqToday()}.csv`; a.click();
}

// « Détail paie » : réaffiche entrée, sortie, SMIC, mini CCM, écart, h. sup et brut
// annuel. Préférence d'affichage propre à ce navigateur.
function toggleDetailPaie(on) {
  document.getElementById('eq-tbl')?.classList.toggle('show-det', on);
  try { localStorage.setItem('rh_eq_detail', on ? '1' : ''); } catch (_) {}
}
let _eqDetailInit = false;
function _eqInitDetail() {
  if (_eqDetailInit) return;
  _eqDetailInit = true;
  let on = false;
  try { on = localStorage.getItem('rh_eq_detail') === '1'; } catch (_) {}
  const cb = document.getElementById('eq-detail');
  if (cb) cb.checked = on;
  document.getElementById('eq-tbl')?.classList.toggle('show-det', on);
}

function renderTable() {
  _eqInitDetail();
  const search = document.getElementById('search-input').value.toLowerCase();
  const filterContract = document.getElementById('filter-contrat').value;
  const filterGroup = document.getElementById('filter-groupe').value;
  const filterStatus = document.getElementById('filter-status').value;

  let rows = [...employees];

  // Filters
  if (search) rows = rows.filter(e=>`${e.nom} ${e.prenom} ${e.poste}`.toLowerCase().includes(search));
  if (filterContract) rows = rows.filter(e=>e.type_contrat===filterContract);
  if (filterGroup) rows = rows.filter(e=>e.groupe===filterGroup);
  if (filterStatus==='active') rows = rows.filter(e=>!eqIsExited(e));
  else if (filterStatus==='exited') rows = rows.filter(e=>eqIsExited(e));
  else if (filterStatus==='alerts') rows = rows.filter(e=>eqEtat(e).some(c=>c.lvl==='danger'||c.lvl==='warn'));

  // Sort
  const f = sortState.field;
  rows.sort((a,b)=>{
    let va = a[f]||'', vb = b[f]||'';
    if (f==='sal_mensuel') { va=calcSalary(a).monthly; vb=calcSalary(b).monthly; }
    if (f==='taux_horaire' || f==='classe_num') { va=parseFloat(va)||0; vb=parseFloat(vb)||0; }
    if (typeof va==='string') return va.localeCompare(vb)*sortState.dir;
    return (va-vb)*sortState.dir;
  });

  const tbody = document.getElementById('table-body');
  const cards = document.getElementById('eq-cards');
  renderEquipeAlertesContrats();
  if (!rows.length) {
    tbody.innerHTML = `<tr><td colspan="16"><div class="empty"><div class="empty-ico">🔍</div>Aucun salarié trouvé</div></td></tr>`;
    document.getElementById('table-foot').innerHTML = '';
    cards.innerHTML = `<div class="empty"><div class="empty-ico">🔍</div>Aucun salarié trouvé</div>`;
    eqRefreshFiche();
    return;
  }

  tbody.innerHTML = rows.map(e => {
    const s = calcSalary(e);
    const classeNum = resolveClasse(e);
    const cl = getCcmClass(classeNum);
    const ccmTaux = getCcmMinRate(classeNum);
    const effMin = getEffectiveMin(classeNum);
    const rate = parseFloat(e.taux_horaire)||0;
    const delta = rate - effMin;
    const exempt = isMinWageExempt(e);
    const exited = eqIsExited(e);
    const isSelected = selectedIds.has(e.id);
    const hs = parseFloat(e.heures_sup_semaine)||0;
    return `<tr class="row-emp ${exited?'exited':''}${isSelected?' selected':''}" onclick="eqOpenFiche('${e.id}')">
      <td onclick="event.stopPropagation()"><div class="cb-wrap"><input type="checkbox" data-id="${e.id}" ${isSelected?'checked':''} onchange="toggleRow('${e.id}',this)" aria-label="Sélectionner ${taEsc(e.prenom)} ${taEsc(e.nom)}"></div></td>
      <td class="eq-who"><b>${taEsc((e.nom||'').toUpperCase())} ${taEsc(e.prenom)}</b><span>${taEsc(e.poste||'—')}</span></td>
      <td><span class="badge b-${(e.type_contrat||'').toLowerCase().replace(' ','').replace('é','e')}">${taEsc(e.type_contrat||'—')}</span></td>
      <td class="eq-det num">${fmtDate(e.date_entree)}</td>
      <td class="eq-det num">${e.date_sortie?fmtDate(e.date_sortie):'—'}</td>
      <td><span class="grp-badge grp-${cl.groupe}" title="${taEsc(cl.label+' — '+cl.desc)}">${cl.groupe}</span> <span class="eq-small">Cl.${classeNum}</span></td>
      <td class="r num">${parseFloat(e.heures_semaine)||35} h${hs?` <span class="eq-muted">+${hs}</span>`:''}</td>
      <td class="r eq-det num">${settings.smic.toFixed(2)} €</td>
      <td class="r eq-det num">${ccmTaux.toFixed(2)} €</td>
      <td class="r num"><b>${rate.toFixed(2)} €</b></td>
      <td class="r eq-det num" style="color:${exempt?'var(--muted)':delta<0?'var(--danger)':'var(--success)'}">${exempt?'—':(delta>=0?'+':'')+delta.toFixed(2)}</td>
      <td class="r num"><span title="${salTooltip(s)}">${fmt(s.monthly)}</span></td>
      <td class="r eq-det num" style="color:var(--warn)">${s.supPay>0?fmt(s.supPay):'—'}</td>
      <td class="r eq-det num">${fmt(s.annual)}</td>
      <td class="r num" style="color:var(--teal)">${fmt(s.costAnnual)}</td>
      <td><div class="eq-chips">${eqChips(eqEtat(e))}</div></td>
    </tr>`;
  }).join('');

  cards.innerHTML = rows.map(e => {
    const s = calcSalary(e), cn = resolveClasse(e);
    return `<button type="button" class="eq-card ${eqIsExited(e)?'exited':''}" onclick="eqOpenFiche('${e.id}')">
      <span><b>${taEsc((e.nom||'').toUpperCase())} ${taEsc(e.prenom)}</b><span class="eq-small eq-muted">${taEsc(e.poste||'—')} · ${taEsc(e.type_contrat||'')} · Cl.${cn}</span></span>
      <span class="r num"><b>${(parseFloat(e.taux_horaire)||0).toFixed(2)} €</b><span class="eq-small eq-muted">${fmt(s.monthly)} / mois</span></span>
      <span class="eq-chips" style="grid-column:1/-1">${eqChips(eqEtat(e))}</span>
    </button>`;
  }).join('');

  // Footer totals
  const activeRows = rows.filter(e=>!eqIsExited(e));
  const totals = aggregatePayroll(activeRows);
  document.getElementById('table-foot').innerHTML = `
    <tr class="tbl-footer">
      <td></td>
      <td colspan="2"><b>${activeRows.length} en poste</b></td>
      <td class="eq-det"></td><td class="eq-det"></td><td></td><td></td><td class="eq-det"></td><td class="eq-det"></td><td></td><td class="eq-det"></td>
      <td class="r num"><b>${fmt(totals.monthly)}</b></td>
      <td class="r eq-det num"><b>${fmt(activeRows.reduce((s,e)=>s+calcSalary(e).supPay,0))}</b></td>
      <td class="r eq-det num"><b>${fmt(totals.annual)}</b></td>
      <td class="r num"><b>${fmt(totals.cost)}</b></td>
      <td></td>
    </tr>`;

  eqRefreshFiche();
}

// Bandeau d'alerte : contrats déjà arrivés à échéance (date de fin passée)
// mais pas encore traités (ni renouvelés/prolongés, ni archivés via la
// Corbeille) — l'éligibilité au badge/PIN est déjà bloquée côté Supabase
// (voir migration 20260821152633), ce bandeau sert juste à ce que ça ne
// reste pas invisible côté RH (cas réel : CDD découvert par hasard
// 3 semaines après sa fin). Purement local (employees déjà chargé).
function renderEquipeAlertesContrats() {
  const el = document.getElementById('equipe-alertes-contrats');
  if (!el) return;
  const expires = employees.filter(e => eqIsExited(e) && !e.alerteVue);
  if (!expires.length) { el.style.display = 'none'; el.innerHTML = ''; return; }
  el.style.display = 'block';
  el.innerHTML = `<div class="eq-alert">
    <div class="eq-alert-head">⛔ ${expires.length} contrat${expires.length>1?'s':''} arrivé${expires.length>1?'s':''} à échéance — pointage déjà bloqué, à traiter (renouveler, passer en CDI ou laisser partir)</div>
    ${expires.map(e => `<div class="eq-alert-row">
      <span><b>${taEsc(e.prenom)} ${taEsc(e.nom)}</b> · ${taEsc(e.type_contrat||'')} terminé le ${fmtDate(e.date_sortie)}</span>
      <button onclick="marquerAlerteContratVue('${e.id}')" class="btn btn-ghost btn-xs" title="Pas de renouvellement prévu, mais salarié conservé (il pourrait revenir) : retire juste l'alerte">👁 Vu</button>
      <button onclick="eqOpenFiche('${e.id}');eqOpenContrat()" class="btn btn-danger btn-xs">🔄 Traiter</button>
    </div>`).join('')}
  </div>`;
}

// "👁 Vu" (bandeau contrats expirés) : accusé de réception sans toucher au
// contrat — pour un salarié pas renouvelé mais susceptible de revenir
// (saisonnier...), qu'on ne veut ni supprimer (Corbeille = départ
// définitif) ni voir nagué indéfiniment. Se réinitialise tout seul dès
// qu'un nouveau contrat est créé (alerte_vue redémarre à false).
async function marquerAlerteContratVue(id, vue = true) {
  const db = window.SupabaseDB;
  if (!db) return;
  const { data, error } = await db.rpc('marquer_alerte_contrat_vue_rh', { p_employe_id: id, p_vue: vue });
  if (error || data?.ok === false) {
    ptgToast('Erreur : ' + (data?.message || error?.message || 'inconnue'));
    return;
  }
  await syncEmployeesFromSupabase({ silent: true });
}

function salTooltip(s) {
  return `Base: ${fmt(s.basePay)} | H.Sup +25%: ${fmt(s.sup25Pay)} | H.Sup +50%: ${fmt(s.sup50Pay)}`;
}

// ═══════════════════════════════════════════
// RENDER OPTIMIZATION
// ═══════════════════════════════════════════
// Unique groups for ETP sliders
const ETP_GROUPS = ['A','B','C','D','E','F','G','H','I'];

function renderOptim() {
  // ETP sliders (par groupe)
  const cont = document.getElementById('etp-sliders');
  if (!cont._init) {
    const GC = getGroupeColors();
    cont.innerHTML = ETP_GROUPS.map(g=>{
      const minClasse = Object.values(ccmClasses).find(c=>c.groupe===g);
      const minTaux = minClasse ? Math.max(minClasse.tauxMin, settings.smic) : settings.smic;
      return `
      <div class="slider-lbl" style="margin-top:8px">
        <span><span class="grp-badge grp-${g}" style="margin-right:5px">${g}</span> Grp ${g} (mini ${minTaux.toFixed(2)}€/h)</span>
        <span id="etp-val-${g}">0 ETP</span>
      </div>
      <input type="range" min="0" max="5" step="1" value="0" id="etp-${g}" oninput="document.getElementById('etp-val-${g}').textContent=this.value+' ETP';updateEtp()">`;
    }).join('');
    cont._init=true;
  }

  updateSim();
  updateHsup();
  updateEtp();
  renderCcmAnalysis();
  renderScenarios();
  renderIndivSim();
}

function updateSim() {
  const pct = parseFloat(document.getElementById('sim-pct').value)||0;
  document.getElementById('sim-pct-val').textContent = pct+'%';
  const onlyBelow = document.getElementById('sim-only-below').checked;
  const active = getActiveEmployees();
  const before = aggregatePayroll(active);

  const simEmps = active.map(e=>{
    let rate = parseFloat(e.taux_horaire)||0;
    const effMin = getEffectiveMin(resolveClasse(e));
    if (!onlyBelow || rate < effMin) rate = rate * (1+pct/100);
    return {...e, taux_horaire: rate};
  });
  const after = aggregatePayroll(simEmps);

  document.getElementById('sim-result').innerHTML = `
    <div class="res-row"><span>Avant — Masse sal. mensuelle</span><span>${fmt(before.monthly)}</span></div>
    <div class="res-row"><span>Après — Masse sal. mensuelle</span><span>${fmt(after.monthly)}</span></div>
    <div class="res-row"><span>Δ mensuel</span><span style="color:${after.monthly>before.monthly?'var(--danger)':'var(--success)'}">${fmt(after.monthly-before.monthly)}</span></div>
    <div class="res-row"><span>Avant — Coût employeur annuel</span><span>${fmt(before.cost)}</span></div>
    <div class="res-row"><span>Après — Coût employeur annuel</span><span>${fmt(after.cost)}</span></div>
    <div class="res-row"><span>💶 Impact annuel employeur</span><span>${fmt(after.cost-before.cost)}</span></div>
  `;
}

function updateHsup() {
  const add = parseFloat(document.getElementById('hsup-add').value)||0;
  const pct = parseFloat(document.getElementById('hsup-pct').value)||100;
  document.getElementById('hsup-add-val').textContent = (add>=0?'+':'')+add+'h';
  document.getElementById('hsup-pct-val').textContent = pct+'%';
  const active = getActiveEmployees();
  const before = aggregatePayroll(active);
  const n = Math.round(active.length*pct/100);
  const simEmps = active.map((e,i)=>{
    if (i>=n) return e;
    const hSup = Math.max(0,(parseFloat(e.heures_sup_semaine)||0)+add);
    return {...e, heures_sup_semaine: hSup};
  });
  const after = aggregatePayroll(simEmps);
  const hSupAfter = simEmps.reduce((s,e)=>s+calcSalary(e).hSupMonth,0);
  document.getElementById('hsup-result').innerHTML = `
    <div class="res-row"><span>Salariés concernés</span><span>${n}/${active.length}</span></div>
    <div class="res-row"><span>H.Sup totales / mois (avant)</span><span>${fmtH(before.hSupMonth)}</span></div>
    <div class="res-row"><span>H.Sup totales / mois (après)</span><span>${fmtH(hSupAfter)}</span></div>
    <div class="res-row"><span>Δ masse sal. mensuelle</span><span style="color:${after.monthly>before.monthly?'var(--danger)':'var(--success)'}">${fmt(after.monthly-before.monthly)}</span></div>
    <div class="res-row"><span>💶 Impact coût employeur / an</span><span>${fmt(after.cost-before.cost)}</span></div>
  `;
}

function updateEtp() {
  const active = getActiveEmployees();
  const before = aggregatePayroll(active);
  let addedCost = 0, addedMonthly = 0, addedCount = 0;
  ETP_GROUPS.forEach(g=>{
    const n = parseInt(document.getElementById('etp-'+g)?.value)||0;
    if (n>0) {
      // Use the first class of this group as base rate
      const firstCl = Object.values(ccmClasses).find(c=>c.groupe===g);
      const rate = firstCl ? Math.max(firstCl.tauxMin, settings.smic) : settings.smic;
      addedCount += n;
      addedMonthly += n * rate * settings.baseH;
      addedCost += n * rate * settings.baseH * 12 * (1+settings.charges/100);
    }
  });
  document.getElementById('etp-result').innerHTML = `
    <div class="res-row"><span>ETP ajoutés</span><span>${addedCount}</span></div>
    <div class="res-row"><span>Masse sal. actuelle / mois</span><span>${fmt(before.monthly)}</span></div>
    <div class="res-row"><span>Δ masse sal. / mois</span><span>+${fmt(addedMonthly)}</span></div>
    <div class="res-row"><span>Coût employeur actuel / an</span><span>${fmt(before.cost)}</span></div>
    <div class="res-row"><span>💶 Surcoût annuel (au mini CCM effectif)</span><span style="color:var(--danger)">+${fmt(addedCost)}</span></div>
  `;
}

function renderCcmAnalysis() {
  // Apprentis/stagiaires suivent un barème légal à part (isMinWageExempt) —
  // exclus de cette analyse SMIC/CCM qui ne les concerne pas.
  const active = getActiveEmployees().filter(e=>!isMinWageExempt(e));
  const total = active.length;
  // Conforme = taux >= max(CCM tauxMin, SMIC)
  const aboveCcm = active.filter(e=>{ const rate=parseFloat(e.taux_horaire)||0; return rate>=getEffectiveMin(resolveClasse(e)); });
  const belowCcm = total - aboveCcm.length;
  const belowSmic = active.filter(e=>(parseFloat(e.taux_horaire)||0)<settings.smic);
  const pctConf = total ? Math.round(aboveCcm.length/total*100) : 100;
  const avgCcmMin = Object.values(ccmClasses).reduce((s,c)=>s+Math.max(c.tauxMin,settings.smic),0)/Object.keys(ccmClasses).length;
  document.getElementById('ccm-analysis').innerHTML = `
    <div class="res-box" style="margin-top:0">
      <div class="res-row"><span>Salariés au taux d'embauche ≥ mini effectif</span><span style="color:var(--success)">${aboveCcm.length}/${total} (${pctConf}%)</span></div>
      <div class="res-row"><span>Taux d'embauche sous le mini effectif (ajusté auto à la paie)</span><span style="color:var(--muted)">${belowCcm}</span></div>
      <div class="res-row"><span>dont sous le SMIC seul (SMIC s'applique auto)</span><span style="color:var(--muted)">${belowSmic.length}</span></div>
      <div class="res-row"><span>Cl.1-2 sous SMIC (SMIC s'applique)</span><span style="color:var(--muted)">Classes A1 (11.92€) et A2 (12.01€)</span></div>
      <div class="res-row"><span>Mini CCM effectif moyen (18 classes)</span><span>${avgCcmMin.toFixed(2)}€/h</span></div>
      <div class="res-row"><span style="color:var(--muted);font-size:11px">Hors apprentis/stagiaires (barème spécifique)</span><span></span></div>
    </div>
    ${belowCcm>0?`<div style="margin-top:10px;font-size:12px;color:var(--muted)">
      <b>Paie ajustée automatiquement au SMIC/CCM (taux d'embauche inchangé) :</b>
      ${active.filter(e=>(parseFloat(e.taux_horaire)||0)<getEffectiveMin(resolveClasse(e))).map(e=>{
        const cn=resolveClasse(e); const cl=getCcmClass(cn); const effMin=getEffectiveMin(cn);
        return `<div style="margin-top:5px;padding:6px 8px;background:rgba(124,108,248,.07);border-radius:6px;border-left:2px solid var(--accent)">
          <b>${e.prenom} ${e.nom}</b> (Cl.${cn}/${cl.groupe} — ${cl.label})<br>
          Taux d'embauche : ${(parseFloat(e.taux_horaire)||0).toFixed(2)}€ / Mini effectif : ${effMin.toFixed(2)}€
          → Δ mensuel pris en charge automatiquement : ${fmt((effMin-(parseFloat(e.taux_horaire)||0))*settings.baseH)}
        </div>`;}).join('')}
    </div>`:''}
  `;
}

function renderScenarios() {
  const active = getActiveEmployees();
  const base = aggregatePayroll(active);
  const scenarios = [
    {name:'🎯 Situation actuelle', pct:0},
    {name:'📈 Hausse SMIC +2%', pct:2},
    {name:'📈 Hausse SMIC +3%', pct:3},
    {name:'🔧 Conformité CCM (mini)', pct:0, ccmOnly:true},
    {name:'💡 +1h sup/sem tout le monde', hsup:1},
    {name:'💡 +2h sup/sem tout le monde', hsup:2},
  ];
  let html = '<table style="width:100%;border-collapse:collapse;font-size:12px"><thead><tr>';
  ['Scénario','MS mensuelle','MS annuelle','Coût emp./an','Δ vs actuel','Δ %'].forEach(h=>html+=`<th style="padding:8px;text-align:left;color:var(--muted);border-bottom:1px solid var(--border)">${h}</th>`);
  html += '</tr></thead><tbody>';
  scenarios.forEach(sc=>{
    let simEmps = active.map(e=>({...e}));
    if (sc.pct) simEmps = simEmps.map(e=>({...e,taux_horaire:(parseFloat(e.taux_horaire)||0)*(1+sc.pct/100)}));
    if (sc.ccmOnly) simEmps = simEmps.map(e=>({...e,taux_horaire:Math.max(parseFloat(e.taux_horaire)||0,getEffectiveMin(resolveClasse(e)))}));
    if (sc.hsup) simEmps = simEmps.map(e=>({...e,heures_sup_semaine:(parseFloat(e.heures_sup_semaine)||0)+sc.hsup}));
    const agg = aggregatePayroll(simEmps);
    const delta = agg.cost - base.cost;
    const deltaPct = base.cost ? delta/base.cost*100 : 0;
    html += `<tr>
      <td style="padding:8px;border-bottom:1px solid rgba(42,46,69,.4)">${sc.name}</td>
      <td style="padding:8px;border-bottom:1px solid rgba(42,46,69,.4)" class="num">${fmt(agg.monthly)}</td>
      <td style="padding:8px;border-bottom:1px solid rgba(42,46,69,.4)" class="num">${fmt(agg.annual)}</td>
      <td style="padding:8px;border-bottom:1px solid rgba(42,46,69,.4)" class="num">${fmt(agg.cost)}</td>
      <td style="padding:8px;border-bottom:1px solid rgba(42,46,69,.4);color:${delta>0?'var(--danger)':delta<0?'var(--success)':'var(--muted)'}" class="num">${delta>=0?'+':''}${fmt(delta)}</td>
      <td style="padding:8px;border-bottom:1px solid rgba(42,46,69,.4);color:${delta>0?'var(--danger)':delta<0?'var(--success)':'var(--muted)'}">${delta>=0?'+':''}${deltaPct.toFixed(1)}%</td>
    </tr>`;
  });
  html += '</tbody></table>';
  document.getElementById('scenario-table').innerHTML = html;
}

// ═══════════════════════════════════════════
// RENDER SETTINGS
// ═══════════════════════════════════════════
function renderSettings() {
  renderLastBackupInfo();
  taRenderSettings();
  document.getElementById('s-smic').value = settings.smic;
  document.getElementById('s-charges').value = settings.charges;
  document.getElementById('s-base-h').value = settings.baseH;
  document.getElementById('s-quota-hsup').value = settings.quotaHSup;
  document.getElementById('s-maj25').value = settings.maj25;
  document.getElementById('s-maj50').value = settings.maj50;
  document.getElementById('s-nfc-enabled').checked = !!settings.nfcEnabled;

  const gColors = getGroupeColors();
  document.getElementById('ccm-settings-grid').innerHTML = Object.entries(ccmClasses).map(([c,info])=>{
    const belowSmic = info.tauxMin < settings.smic;
    const effRate = Math.max(info.tauxMin, settings.smic);
    return `
    <div class="ccm-item" style="border-left:3px solid ${gColors[info.groupe]||'#888'}">
      <div class="ccm-header">
        <div class="grp-badge grp-${info.groupe}">${info.groupe}</div>
        <div>
          <div style="font-weight:700;font-size:12px">${info.label}</div>
          <div style="font-size:10px;color:var(--muted)">${info.categorie} · ${info.smhAnnuel.toLocaleString('fr-FR')}€/an</div>
        </div>
      </div>
      <div class="ccm-desc">${info.desc}</div>
      <div class="ccm-rate" style="margin-top:8px">
        <label style="font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:.4px">Taux mini CCM (€/h)</label>
        <input type="number" step="0.01" id="ccm-min-${c}" value="${info.tauxMin.toFixed(2)}">
        ${belowSmic?`<div style="font-size:10px;color:var(--warn);margin-top:3px">⚠️ Sous SMIC → effectif : ${effRate.toFixed(2)}€/h</div>`:`<div style="font-size:10px;color:var(--success);margin-top:3px">✓ SMH mensuel : ${info.smhMensuel.toLocaleString('fr-FR')}€</div>`}
      </div>
    </div>`;
  }).join('');
}

// ═══════════════════════════════════════════
// MODAL
// ═══════════════════════════════════════════
// Création d'une fiche (et complément d'un compte sonotrad-pwa sans fiche RH).
// Une fiche existante s'ouvre dans le panneau latéral (eqOpenFiche).
function openModal(id) {
  if (id) { eqOpenFiche(id); return; }
  document.getElementById('modal-overlay').classList.add('open');
  document.getElementById('f-nom').readOnly = false;
  document.getElementById('f-prenom').readOnly = false;
  document.getElementById('modal-linked-badge').style.display = 'none';
  document.getElementById('modal-title').innerHTML = '<span>👤</span> Nouveau salarié';
  document.getElementById('edit-id').value = '';
  ['f-nom','f-prenom','f-sortie','f-poste','f-taux','f-notes','f-adresse','f-tel-perso','f-email-perso'].forEach(id=>document.getElementById(id).value='');
  document.getElementById('f-entree').value = eqToday();
  document.getElementById('f-entree-hint').textContent = '';
  document.getElementById('f-contrat').value = 'CDI';
  document.getElementById('f-classe').value = '1';
  document.getElementById('f-heures').value = '35';
  document.getElementById('f-hsup').value = '0';
  document.getElementById('f-motif-ext').value = '';
  document.getElementById('f-kind-row').style.display = '';
  setModalExterne(false);
  updateModalCalc();
}

// « Personne externe » : accès PWA sans contrat — les champs contrat/paie se grisent.
function setModalExterne(ext) {
  const m = document.querySelector('#modal-overlay .modal');
  m.classList.toggle('ext', ext);
  document.getElementById('f-kind-sal').classList.toggle('on', !ext);
  document.getElementById('f-kind-ext').classList.toggle('on', ext);
  m.querySelectorAll('.f-ctr input, .f-ctr select').forEach(el => { el.disabled = ext; });
  document.getElementById('modal-title').innerHTML = ext ? '<span>🔑</span> Nouvelle personne externe' : '<span>👤</span> Nouveau salarié';
}

async function saveExterne() {
  const v = id => document.getElementById(id).value.trim();
  if (!v('f-nom') || !v('f-prenom')) { ptgToast('Nom et prénom requis'); return; }
  if (!v('f-motif-ext')) { ptgToast('Le motif est obligatoire'); return; }
  const { data, error } = await window.SupabaseDB.rpc('creer_externe_rh', {
    p_nom: v('f-nom'), p_prenom: v('f-prenom'), p_notes: v('f-notes'), p_adresse: v('f-adresse'),
    p_telephone_perso: v('f-tel-perso'), p_email_perso: v('f-email-perso'), p_motif: v('f-motif-ext') });
  if (error || !data?.ok) { ptgToast('⚠ ' + (error?.message || data?.message)); return; }
  closeModal();
  ptgToast(`✓ ${v('f-prenom')} ${v('f-nom')} ajouté aux accès externes — activez son compte dans la PWA`);
  loadAccesExternes();
}

// Portail salarié — bouton "Activer l'accès" de la fiche (voir Edge Function
// activer-portail, chantier 0 du 2026-08-24). Nécessite un email personnel
// (l'invitation Supabase Auth part dessus) ; une fois activé, l'action n'est
// plus réversible depuis l'app (dissocier un compte n'est pas dans le
// périmètre du portail, hors scope pour l'instant).
function renderPortailStatus(e) {
  const el = document.getElementById('portail-status');
  if (!el) return;
  if (e.portail_actif) {
    el.innerHTML = '<span class="eq-pill eq-p-ok">Accès activé</span> <span class="eq-hint">Le salarié consulte ses heures et son solde de congés.</span>';
  } else if (!e.email_perso) {
    el.innerHTML = '<span class="eq-hint">Ajoutez un e-mail personnel dans l\'onglet Identité pour pouvoir ouvrir le portail.</span>';
  } else {
    el.innerHTML = `<span class="eq-hint">Une invitation partira sur ${taEsc(e.email_perso)}.</span>
      <div><button type="button" class="btn btn-primary btn-sm" onclick="activerPortailAccess('${e.id}')">📧 Activer l'accès portail</button></div>`;
  }
}

async function activerPortailAccess(id) {
  const db = window.SupabaseDB;
  if (!db) return;
  const { data: { session } } = await db.auth.getSession();
  if (!session) return;
  const el = document.getElementById('portail-status');
  if (el) el.innerHTML = '<span class="eq-hint">Envoi de l\'invitation…</span>';
  try {
    const resp = await fetch(`${SUPABASE_URL}/functions/v1/activer-portail`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${session.access_token}`,
        'apikey': SUPABASE_ANON_KEY,
      },
      body: JSON.stringify({ employe_id: id }),
    });
    const result = await resp.json();
    if (!result.ok) {
      if (el) el.innerHTML = `<span style="color:var(--danger)">Erreur : ${taEsc(result.message || 'échec de l\'activation')}</span>`;
      return;
    }
    const emp = employees.find(x => x.id === id);
    if (emp) emp.portail_actif = true;
    ptgToast('✓ Invitation envoyée — le salarié peut définir son mot de passe');
    syncEmployeesFromSupabase({ silent: true });
    eqRenderFiche();
  } catch (err) {
    if (el) el.innerHTML = `<span style="color:var(--danger)">Erreur réseau : ${taEsc(err.message)}</span>`;
  }
}

// ═══════════════════════════════════════════
// FICHE SALARIÉ — panneau latéral à 3 onglets
// ═══════════════════════════════════════════
// Salaire & contrat : conditions en vigueur + historique (table `remunerations`,
// une ligne datée par évolution, regroupées par contrat). Identité : nom,
// notes, coordonnées. Accès & badge : badge kiosque, portail, corbeille.
// Les conditions (taux, classe, heures, poste) ne se modifient que par
// « Évolution de salaire » ou « Nouveau contrat », pour garder l'historique.
const EQ = { id: null, tab: 'salaire', hist: null, histFor: null, histErr: '', editCtr: false, confirmDel: false, delMsg: '', dlg: null, extEdit: false };

const REMU_MOTIFS = {
  debut_contrat: 'Début de contrat',
  augmentation_individuelle: 'Augmentation individuelle',
  augmentation_generale: 'Augmentation générale',
  changement_classe: 'Changement de classe / promotion',
  avenant: 'Avenant (heures, poste…)',
  minimum_conventionnel: 'Mise au minimum',
  correction: 'Correction de saisie',
};
const EQ_TYPES = ['CDI', 'CDD', 'Apprentissage', 'Intérim', 'Temps partiel', 'Stage'];

function eqEmp() { return EQ.id ? employees.find(e => e.id === EQ.id) || null : null; }

function eqAnciennete(iso) {
  if (!iso) return '';
  const a = new Date(iso + 'T12:00'), b = new Date(eqToday() + 'T12:00');
  let m = (b.getFullYear() - a.getFullYear()) * 12 + b.getMonth() - a.getMonth();
  if (b.getDate() < a.getDate()) m--;
  if (m < 0) return 'arrive le ' + fmtDate(iso);
  const y = Math.floor(m / 12); m %= 12;
  return ((y ? y + ' an' + (y > 1 ? 's' : '') : '') + (y && m ? ' ' : '') + (m ? m + ' mois' : '') || 'moins d’un mois') + ' d’ancienneté';
}

function eqOpenFiche(id, tab) {
  if (!employees.some(e => e.id === id)) return;
  const same = EQ.id === id;
  if (!same) { EQ.editCtr = false; EQ.confirmDel = false; EQ.delMsg = ''; EQ.extEdit = false; }
  EQ.tab = tab || (same ? EQ.tab : 'salaire');
  EQ.id = id;
  if (EQ.histFor !== id) { EQ.hist = null; EQ.histErr = ''; EQ.histFor = id; eqLoadHist(id); }
  eqRenderFiche();
}

function eqCloseFiche() {
  EQ.id = null; EQ.dlg = null; EQ.editCtr = false; EQ.confirmDel = false; EQ.extEdit = false;
  const d = document.getElementById('eq-drawer'); if (d) { d.className = ''; d.innerHTML = ''; }
  const g = document.getElementById('eq-dlg'); if (g) g.innerHTML = '';
}

// Appelée à chaque rendu de la liste (synchro, temps réel…) : met la fiche
// ouverte à jour sans perdre une saisie en cours.
function eqRefreshFiche() {
  if (!EQ.id) return;
  if (!eqEmp()) { eqCloseFiche(); return; }
  eqRenderFiche();
}

async function eqLoadHist(id) {
  const db = window.SupabaseDB;
  if (!db || !isUuid(id)) { EQ.hist = []; return; }
  const { data, error } = await db.rpc('get_remunerations_rh', { p_employe_id: id });
  if (EQ.histFor !== id) return;
  if (error) { EQ.hist = []; EQ.histErr = error.message; eqRenderFiche(); return; }
  // Regroupe par contrat (les lignes arrivent du plus récent au plus ancien)
  const contrats = [];
  (data || []).forEach(r => {
    let c = contrats.find(x => x.id === r.contrat_id);
    if (!c) { c = { id: r.contrat_id, debut: r.contrat_debut, fin: r.contrat_fin, type: r.type_contrat, lignes: [] }; contrats.push(c); }
    c.lignes.push(r);
  });
  EQ.hist = contrats;
  EQ.histErr = '';
  if (EQ.id === id) eqRenderFiche();
}

function eqReloadHist() { if (EQ.id) { EQ.histFor = EQ.id; eqLoadHist(EQ.id); } }

// Re-rendu en gardant les valeurs tapées et le focus (champs à id du panneau).
function _eqKeepInputs(root, render) {
  const vals = {};
  root.querySelectorAll('input[id],select[id],textarea[id]').forEach(el => { vals[el.id] = el.type === 'checkbox' ? el.checked : el.value; });
  const act = document.activeElement && root.contains(document.activeElement) ? document.activeElement : null;
  const focusId = act && act.id, pos = act && act.selectionStart;
  const scroll = root.querySelector('.eq-dr-body')?.scrollTop;
  render();
  Object.entries(vals).forEach(([k, v]) => { const el = document.getElementById(k); if (el && root.contains(el)) { if (el.type === 'checkbox') el.checked = v; else el.value = v; } });
  const body = root.querySelector('.eq-dr-body'); if (body && scroll) body.scrollTop = scroll;
  if (focusId) { const el = document.getElementById(focusId); if (el) { el.focus(); try { if (pos != null) el.setSelectionRange(pos, pos); } catch (_) {} } }
}

function eqRenderFiche() {
  const root = document.getElementById('eq-drawer');
  if (!root) return;
  const e = eqEmp();
  if (!e) { root.className = ''; root.innerHTML = ''; return; }
  const wasOpen = root.classList.contains('open') && root.dataset.id === e.id && root.dataset.tab === EQ.tab;
  const draw = () => {
    const cl = getCcmClass(resolveClasse(e));
    const etat = eqEtat(e);
    const tabs = [['salaire', 'Salaire & contrat'], ['identite', 'Identité'], ['acces', 'Accès & badge']];
    root.className = 'open';
    root.dataset.id = e.id; root.dataset.tab = EQ.tab;
    root.innerHTML = `<div class="eq-dr-back" onclick="eqCloseFiche()"></div>
    <aside class="eq-dr" role="dialog" aria-label="Fiche de ${taEsc(e.prenom)} ${taEsc(e.nom)}">
      <div class="eq-dr-head">
        <div class="eq-dr-top">
          <div class="eq-avatar">${taEsc((e.prenom || '?')[0] + (e.nom || '?')[0])}</div>
          <div class="eq-dr-title"><h2>${taEsc(e.prenom)} ${taEsc(e.nom)}</h2>
            <p>${taEsc(e.poste || '—')} · ${taEsc(e.type_contrat || '')} ${e.date_sortie ? (eqIsExited(e) ? 'terminé le ' : 'jusqu’au ') + fmtDate(e.date_sortie) : 'en cours'} · ${eqAnciennete(e.date_entree)}</p></div>
          <button class="btn btn-ghost btn-sm" onclick="eqCloseFiche()" aria-label="Fermer">✕</button>
        </div>
        <div class="eq-chips">${eqChips(etat)}<span class="grp-badge grp-${cl.groupe}" style="width:auto;height:auto;padding:2px 8px;font-size:11px">Cl.${resolveClasse(e)} · ${cl.groupe}</span>${e.hasBadge ? '<span class="eq-pill eq-p-ok">Badge associé</span>' : ''}</div>
        <nav class="eq-tabs" role="tablist">${tabs.map(([k, l]) => `<button class="eq-tab ${EQ.tab === k ? 'on' : ''}" role="tab" aria-selected="${EQ.tab === k}" onclick="EQ.tab='${k}';eqRenderFiche()">${l}</button>`).join('')}</nav>
      </div>
      <div class="eq-dr-body">${!isUuid(e.id) ? '<div class="eq-note">Fiche en cours d’enregistrement… réessayez dans un instant.</div>' : EQ.tab === 'identite' ? eqTabIdentite(e) : EQ.tab === 'acces' ? eqTabAcces(e) : eqTabSalaire(e)}</div>
    </aside>`;
    if (EQ.tab === 'acces') renderPortailStatus(e);
  };
  if (wasOpen) _eqKeepInputs(root, draw); else draw();
}

function eqTabSalaire(e) {
  const cn = resolveClasse(e), cl = getCcmClass(cn), s = calcSalary(e);
  const taux = parseFloat(e.taux_horaire) || 0, min = getEffectiveMin(cn), d = taux - min, exempt = isMinWageExempt(e);
  const exited = eqIsExited(e);
  const hs = parseFloat(e.heures_sup_semaine) || 0;
  const hist = EQ.hist;
  const prochaine = hist && hist[0] ? [...hist[0].lignes].reverse().find(l => l.a_venir) : (e.hausse_date ? { date_effet: e.hausse_date, taux_horaire: e.hausse_taux } : null);

  let histHtml;
  if (hist === null) histHtml = '<span class="eq-hint">Chargement…</span>';
  else if (EQ.histErr) histHtml = `<span style="color:var(--danger)">Erreur : ${taEsc(EQ.histErr)}</span>`;
  else if (!hist.length) histHtml = '<span class="eq-hint">Aucun historique.</span>';
  else histHtml = hist.map((c, ci) => {
    const vig = ci === 0 ? c.lignes.findIndex(l => !l.a_venir) : -1;
    const lignes = c.lignes.map((l, li) => {
      const p = c.lignes[li + 1];
      const t = parseFloat(l.taux_horaire), pt = p ? parseFloat(p.taux_horaire) : 0;
      const ch = [];
      if (p) {
        if (p.classe_num !== l.classe_num) ch.push(`Cl.${p.classe_num} → ${l.classe_num}`);
        if (parseFloat(p.heures_semaine) !== parseFloat(l.heures_semaine) || parseFloat(p.heures_sup_semaine) !== parseFloat(l.heures_sup_semaine))
          ch.push(`${parseFloat(p.heures_semaine)}+${parseFloat(p.heures_sup_semaine)} h → ${parseFloat(l.heures_semaine)}+${parseFloat(l.heures_sup_semaine)} h`);
        if ((p.poste || '') !== (l.poste || '')) ch.push('poste : ' + taEsc(l.poste || '—'));
      }
      const desc = p ? ch.join(' · ') : `Cl.${l.classe_num} · ${parseFloat(l.heures_semaine)} h${parseFloat(l.heures_sup_semaine) ? ' + ' + parseFloat(l.heures_sup_semaine) : ''}${l.poste ? ' · ' + taEsc(l.poste) : ''}`;
      const meta = [REMU_MOTIFS[l.motif] || l.motif, l.note, l.saisi_par && l.saisi_par !== 'reprise' ? 'saisi par ' + l.saisi_par : ''].filter(Boolean).map(taEsc).join(' · ');
      return `<div class="eq-line ${li === vig ? 'now' : ''} ${l.a_venir ? 'next' : ''}">
        <span class="num">${fmtDate(l.date_effet)}</span>
        <span class="num"><b>${eqFmtTaux(t)}/h</b> ${p && pt > 0 && t !== pt ? `<span class="${t > pt ? 'eq-up' : 'eq-down'}">${eqPct(pt, t)}</span>` : ''}
          ${li === vig ? '<span class="eq-pill eq-p-accent">en vigueur</span>' : ''}${l.a_venir ? '<span class="eq-pill eq-p-warn">à venir</span>' : ''}
          <span class="eq-hint">${desc}</span></span>
        <span class="eq-line-meta">${meta}</span>
      </div>`;
    }).join('');
    const corr = ci === 0 && EQ.editCtr ? `<div class="eq-inline">
        <div class="fg"><label for="eq-ec-type">Type</label><select id="eq-ec-type">${EQ_TYPES.map(t => `<option ${t === c.type ? 'selected' : ''}>${t}</option>`).join('')}</select></div>
        <div class="fg"><label for="eq-ec-fin">Date de fin</label><input type="date" id="eq-ec-fin" value="${c.fin || ''}"></div>
        <button class="btn btn-primary btn-sm" onclick="eqSaveCorrection()">Enregistrer</button>
        <button class="btn btn-ghost btn-sm" onclick="EQ.editCtr=false;eqRenderFiche()">Annuler</button>
        <span class="eq-hint" style="flex-basis:100%">Pour un renouvellement ou un passage en CDI, utilisez plutôt « Nouveau contrat » : l’ancien reste dans l’historique.</span>
      </div>` : '';
    const vu = ci === 0 && exited ? (e.alerteVue
      ? `<button class="btn btn-ghost btn-xs" onclick="marquerAlerteContratVue('${e.id}',false)" title="Refaire apparaître ce contrat dans le bandeau d'alertes">👁 Réafficher l’alerte</button>`
      : `<button class="btn btn-ghost btn-xs" onclick="marquerAlerteContratVue('${e.id}')" title="Pas de renouvellement prévu, salarié conservé : retire juste l'alerte">👁 Vu</button>`) : '';
    return `<div class="eq-ctr ${ci ? 'old' : ''}">
      <div class="eq-ctr-h"><span><b>${taEsc(c.type)}</b> <span class="eq-hint">· du ${fmtDate(c.debut)} ${c.fin ? 'au ' + fmtDate(c.fin) : '· en cours'}</span></span>
        <span>${vu}${ci === 0 && !EQ.editCtr ? `<button class="btn btn-ghost btn-xs" onclick="EQ.editCtr=true;eqRenderFiche()">Corriger type / fin</button>` : ''}</span></div>
      ${corr}${lignes}
    </div>`;
  }).join('');

  return `
  ${prochaine && !exited ? `<div class="eq-soon">↗ <span>Le <b>${eqFmtDateLong(prochaine.date_effet)}</b> : ${eqFmtTaux(prochaine.taux_horaire)}/h <span class="eq-up">${taux > 0 ? eqPct(taux, parseFloat(prochaine.taux_horaire)) : ''}</span>${prochaine.motif ? ' · ' + taEsc(REMU_MOTIFS[prochaine.motif] || prochaine.motif) : ''} — s’appliquera tout seul.</span></div>` : ''}
  <section class="eq-box">
    <h3>${exited ? 'Dernières conditions (contrat terminé)' : 'En vigueur aujourd’hui'} <button class="btn btn-primary btn-sm" onclick="eqOpenEvol()">📈 Faire évoluer le salaire</button></h3>
    <div class="eq-kv num">
      <div><small>Taux horaire</small><strong class="big">${eqFmtTaux(taux)}</strong>${s.rate > taux + 0.001 ? `<small style="color:var(--warn)">payé au minimum : ${eqFmtTaux(s.rate)}</small>` : ''}</div>
      <div><small>Classe · groupe</small><strong>Cl.${cn} · ${cl.groupe}</strong><small>${taEsc(cl.desc)}</small></div>
      <div><small>Temps de travail</small><strong>${parseFloat(e.heures_semaine) || 35} h / sem</strong><small>${hs ? '+ ' + hs + ' h sup habituelles' : 'sans heures sup'}</small></div>
      <div><small>Minimum applicable</small><strong>${eqFmtTaux(min)}</strong><small style="color:${exempt ? 'var(--muted)' : d < 0 ? 'var(--danger)' : 'var(--success)'}">${exempt ? 'barème ' + (e.type_contrat === 'Stage' ? 'stagiaire' : 'apprenti') : (d >= 0 ? '+' : '') + d.toFixed(2).replace('.', ',') + ' € ' + (getCcmMinRate(cn) < settings.smic ? '(SMIC)' : '(grille CCM)')}</small></div>
      <div><small>Brut mensuel</small><strong>${fmt(s.monthly)}</strong><small>${s.supPay ? 'dont ' + fmt(s.supPay) + ' d’heures sup' : 'base seule'}</small></div>
      <div><small>Coût employeur</small><strong style="color:var(--teal)">${fmt(s.costAnnual)} / an</strong><small>brut annuel ${fmt(s.annual)}</small></div>
    </div>
  </section>
  <section class="eq-box">
    <h3>Historique <button class="btn btn-ghost btn-sm" onclick="eqOpenContrat()">🔄 Nouveau contrat</button></h3>
    ${histHtml}
  </section>`;
}

function eqTabIdentite(e) {
  return `<section class="eq-box"><h3>Identité</h3>
    <div class="form-grid">
      <div class="fg"><label for="eq-i-nom">Nom</label><input id="eq-i-nom" value="${taEsc(e.nom)}"></div>
      <div class="fg"><label for="eq-i-prenom">Prénom</label><input id="eq-i-prenom" value="${taEsc(e.prenom)}"></div>
      <div class="fg full"><label for="eq-i-entree">Date d’entrée</label><input id="eq-i-entree" value="${fmtDate(e.date_entree)} — ${eqAnciennete(e.date_entree)}" readonly><span class="eq-hint">Début du premier contrat (sert aux congés payés). Se modifie par l’historique des contrats.</span></div>
      <div class="fg full"><label for="eq-i-notes">Notes</label><textarea id="eq-i-notes" rows="2">${taEsc(e.notes)}</textarea></div>
    </div></section>
  <section class="eq-box"><h3>Coordonnées personnelles <span class="eq-hint" style="text-transform:none;letter-spacing:0;font-weight:400">optionnel</span></h3>
    <div class="form-grid">
      <div class="fg full"><label for="eq-i-adr">Adresse postale</label><input id="eq-i-adr" value="${taEsc(e.adresse)}" placeholder="12 rue de l’Exemple, 72000 Le Mans"></div>
      <div class="fg"><label for="eq-i-tel">Téléphone personnel</label><input id="eq-i-tel" type="tel" value="${taEsc(e.telephone_perso)}"></div>
      <div class="fg"><label for="eq-i-mail">E-mail personnel</label><input id="eq-i-mail" type="email" value="${taEsc(e.email_perso)}"><span class="eq-hint">Nécessaire pour ouvrir le portail salarié.</span></div>
    </div></section>
  <div class="eq-actions"><button class="btn btn-primary" onclick="eqSaveIdentite()">💾 Enregistrer</button></div>`;
}

function eqTabAcces(e) {
  return `<section class="eq-box"><h3>Badge du kiosque</h3>
    ${e.hasBadge ? '<div><span class="eq-pill eq-p-ok">Badge associé</span></div>' : '<span class="eq-hint">Aucun badge. Cliquez puis passez le badge sur le lecteur USB.</span>'}
    <div><button class="btn ${e.hasBadge ? 'btn-ghost' : 'btn-primary'} btn-sm" onclick="openBadgeModal('${e.id}')">📡 ${e.hasBadge ? 'Remplacer ou dissocier le badge' : 'Associer un badge'}</button></div>
  </section>
  <section class="eq-box"><h3>Portail salarié</h3><div id="portail-status" class="eq-stack"></div></section>
  ${eqBoxAccesExterne(e)}
  <section class="eq-box eq-danger-zone"><h3>Retirer de l’équipe</h3>
    <span class="eq-hint">La fiche part dans la corbeille de l’onglet Équipe ; elle reste récupérable tant qu’elle n’est pas purgée. Pour un départ en fin de contrat avec retour possible (saisonnier), ne la supprimez pas : marquez plutôt l’alerte « Vu ».</span>
    ${EQ.delMsg ? `<div class="eq-note" style="color:var(--danger)">${taEsc(EQ.delMsg)}</div>` : ''}
    ${EQ.confirmDel ? `<div class="eq-inline"><span style="flex:1">Mettre ${taEsc(e.prenom)} ${taEsc(e.nom)} à la corbeille ?</span>
        <button class="btn btn-danger btn-sm" onclick="eqDeleteConfirmed()">Oui, mettre à la corbeille</button>
        <button class="btn btn-ghost btn-sm" onclick="EQ.confirmDel=false;eqRenderFiche()">Annuler</button></div>`
      : `<div><button class="btn btn-danger btn-sm" onclick="EQ.confirmDel=true;EQ.delMsg='';eqRenderFiche()">🗑 Mettre à la corbeille</button></div>`}
  </section>`;
}

// Accès externe : garde l'accès à la PWA sonotrad sans contrat en cours (holding,
// prestataire). Ne permet pas de pointer. Motif obligatoire, inscrit au journal.
function eqBoxAccesExterne(e) {
  const on = e.acces_externe, want = EQ.extEdit ? !on : on;
  return `<section class="eq-box"><h3>Accès aux applications</h3>
    <label style="display:flex;gap:8px;align-items:flex-start;cursor:pointer;font-size:13px">
      <input type="checkbox" ${want ? 'checked' : ''} onchange="EQ.extEdit=(this.checked!==${on});eqRenderFiche()" style="margin-top:2px">
      <span><b>Accès externe (PWA)</b> ${on ? '<span class="eq-pill eq-p-accent">activé</span>' : ''}<br>
      <span class="eq-hint">Garde l’accès à la PWA sonotrad même sans contrat en cours (personne hors effectif : holding, prestataire). Ne permet pas de pointer. Le compte PWA lui-même se gère dans la PWA (Admin).</span></span>
    </label>
    ${EQ.extEdit ? `<div class="eq-inline">
        <div class="fg" style="flex:1"><label for="eq-ext-motif">Motif (obligatoire)</label><input type="text" id="eq-ext-motif" placeholder="${on ? 'ex : fin de mission' : 'ex : gère la RH depuis la holding'}"></div>
        <button class="btn ${on ? 'btn-danger' : 'btn-primary'} btn-sm" onclick="eqSaveAccesExterne(${!on})">${on ? 'Retirer l’accès externe' : 'Donner l’accès externe'}</button>
        <button class="btn btn-ghost btn-sm" onclick="EQ.extEdit=false;eqRenderFiche()">Annuler</button></div>` : ''}
  </section>`;
}

async function eqSaveAccesExterne(externe) {
  const e = eqEmp(); if (!e) return;
  const motif = document.getElementById('eq-ext-motif').value.trim();
  if (!motif) { ptgToast('Le motif est obligatoire'); return; }
  const { data, error } = await window.SupabaseDB.rpc('definir_acces_externe', { p_employe_id: e.id, p_externe: externe, p_motif: motif });
  if (error || !data?.ok) { ptgToast('⚠ ' + (error?.message || data?.message)); return; }
  e.acces_externe = externe;
  EQ.extEdit = false;
  saveData();
  ptgToast(externe ? '✓ Accès externe accordé' : '✓ Accès externe retiré');
  eqRenderFiche();
  syncEmployeesFromSupabase({ silent: true });
}

async function eqSaveIdentite() {
  const e = eqEmp(); if (!e) return;
  const v = id => document.getElementById(id).value.trim();
  const upd = { ...e, nom: v('eq-i-nom'), prenom: v('eq-i-prenom'), notes: v('eq-i-notes'), adresse: v('eq-i-adr'), telephone_perso: v('eq-i-tel'), email_perso: v('eq-i-mail') };
  if (!upd.nom || !upd.prenom) { ptgToast('Nom et prénom requis'); return; }
  const id = await pushEmployeeToSupabase(upd);
  if (!id) return;
  Object.assign(e, upd);
  saveData();
  ptgToast('✓ Fiche enregistrée');
  document.getElementById('eq-drawer').dataset.tab = ''; // re-rendu complet (valeurs enregistrées)
  refresh();
  syncEmployeesFromSupabase({ silent: true });
}

// Correction du type ou de la date de fin du contrat courant (erreur de saisie,
// prolongation). Passe par upsert_employe_rh, qui ne touche plus aux conditions.
async function eqSaveCorrection() {
  const e = eqEmp(); if (!e) return;
  const type = document.getElementById('eq-ec-type').value, fin = document.getElementById('eq-ec-fin').value || null;
  const id = await pushEmployeeToSupabase({ ...e, type_contrat: type, date_sortie: fin });
  if (!id) return;
  EQ.editCtr = false;
  ptgToast('✓ Contrat corrigé');
  await syncEmployeesFromSupabase({ silent: true });
  eqReloadHist();
}

async function eqDeleteConfirmed() {
  const e = eqEmp(); if (!e) return;
  const adm = await adminsParmi([e.id]);
  if (adm.length) { EQ.confirmDel = false; EQ.delMsg = `${adm[0]} est administrateur RH : retirez d’abord ce droit dans Paramètres.`; eqRenderFiche(); return; }
  const id = e.id;
  eqCloseFiche();
  employees = employees.filter(x => x.id !== id);
  saveData();
  refresh();
  deleteEmployeeFromSupabase(id);
  ptgToast(`${e.prenom} ${e.nom} mis à la corbeille`);
}

// ── Fenêtres de la fiche (Évolution de salaire, Nouveau contrat) ─────────────
function eqFirstNextMonth() { const t = eqToday(); const y = +t.slice(0, 4), m = +t.slice(5, 7); return m === 12 ? `${y + 1}-01-01` : `${y}-${String(m + 1).padStart(2, '0')}-01`; }
function eqFirstJan() { return (+eqToday().slice(0, 4) + 1) + '-01-01'; }
function eqClasseOptions(sel) {
  return Object.keys(ccmClasses).map(k => { const c = ccmClasses[k]; return `<option value="${k}" ${+k === +sel ? 'selected' : ''}>Classe ${k} · groupe ${c.groupe} — ${taEsc(c.desc)}</option>`; }).join('');
}
// Personne externe sans fiche RH : seule action, retirer l'accès (→ corbeille).
function eqOpenRetraitExterne(id) {
  const x = eqExternes.find(r => r.id === id); if (!x) return;
  EQ.dlg = { kind: 'ext', x };
  eqRenderDlg();
}
function eqDlgExt() {
  const x = EQ.dlg.x;
  return `<h2>🔑 ${taEsc(x.prenom)} ${taEsc(x.nom)} · personne externe</h2>
    <p class="eq-sub">Pas de fiche RH : retirer l’accès externe la met aussi à la corbeille (récupérable tant qu’elle n’est pas purgée). Son compte PWA ne pourra plus se connecter.</p>
    <div class="fg"><label for="eq-rx-motif">Motif (obligatoire)</label><input id="eq-rx-motif" placeholder="ex : fin de mission"></div>
    <div class="eq-actions"><button class="btn btn-ghost" onclick="eqCloseDlg()">Annuler</button>
      <button class="btn btn-danger" onclick="eqSaveRetraitExterne()">Retirer l’accès</button></div>`;
}
async function eqSaveRetraitExterne() {
  const x = EQ.dlg && EQ.dlg.x; if (!x) return;
  const motif = document.getElementById('eq-rx-motif').value.trim();
  if (!motif) { ptgToast('Le motif est obligatoire'); return; }
  const { data, error } = await window.SupabaseDB.rpc('definir_acces_externe', { p_employe_id: x.id, p_externe: false, p_motif: motif });
  if (error || !data?.ok) { ptgToast('⚠ ' + (error?.message || data?.message)); return; }
  eqCloseDlg();
  ptgToast(data.corbeille ? `✓ Accès retiré, ${x.prenom} ${x.nom} mis à la corbeille` : '✓ Accès externe retiré');
  loadAccesExternes();
}
function eqCloseDlg() { EQ.dlg = null; const g = document.getElementById('eq-dlg'); if (g) g.innerHTML = ''; }
function eqRenderDlg() {
  const g = document.getElementById('eq-dlg');
  if (!g) return;
  if (!EQ.dlg) { g.innerHTML = ''; return; }
  const html = EQ.dlg.kind === 'evol' ? eqDlgEvol() : EQ.dlg.kind === 'ext' ? eqDlgExt() : eqDlgContrat();
  const act = document.activeElement && g.contains(document.activeElement) ? document.activeElement : null;
  const focusId = act && act.id, pos = act && act.selectionStart;
  g.innerHTML = `<div class="eq-dlg-bg" onclick="if(event.target===this)eqCloseDlg()"><div class="eq-dlg" role="dialog" aria-modal="true">${html}</div></div>`;
  if (focusId) { const el = document.getElementById(focusId); if (el) { el.focus(); try { if (pos != null) el.setSelectionRange(pos, pos); } catch (_) {} } }
}

// Évolution de salaire : même contrat, une ligne datée de plus dans l'historique.
function eqOpenEvol() {
  const e = eqEmp(); if (!e || !isUuid(e.id)) return;
  EQ.dlg = { kind: 'evol', motif: '', date: eqFirstNextMonth(), taux: parseFloat(e.taux_horaire) || 0, classe: resolveClasse(e),
             h: parseFloat(e.heures_semaine) || 35, hs: parseFloat(e.heures_sup_semaine) || 0, poste: e.poste || '', note: '', pct: '', busy: false };
  eqRenderDlg();
}
function eqEv(k, v, rerender = true) {
  const ev = EQ.dlg, e = eqEmp(); if (!ev || !e) return;
  if (k === 'taux') { ev.taux = parseFloat(v) || 0; ev.pct = ''; }
  else if (k === 'pct') { ev.pct = v; const p = parseFloat(String(v).replace(',', '.')); if (!isNaN(p)) ev.taux = Math.round((parseFloat(e.taux_horaire) || 0) * (1 + p / 100) * 100) / 100; }
  else if (k === 'classe') ev.classe = parseInt(v) || 1;
  else if (k === 'h' || k === 'hs') ev[k] = parseFloat(v) || 0;
  else if (k === 'motif') { ev.motif = v; if (v === 'minimum_conventionnel') { ev.taux = Math.ceil(getEffectiveMin(ev.classe) * 100) / 100; ev.pct = ''; } }
  else if (k === 'setmin') { ev.taux = Math.ceil(getEffectiveMin(ev.classe) * 100) / 100; ev.pct = ''; }
  else ev[k] = v;
  if (rerender) eqRenderDlg();
}
function eqDlgEvol() {
  const e = eqEmp(), ev = EQ.dlg;
  const cur = { taux: parseFloat(e.taux_horaire) || 0, classe: resolveClasse(e), h: parseFloat(e.heures_semaine) || 35, hs: parseFloat(e.heures_sup_semaine) || 0, poste: e.poste || '' };
  const chg = k => (k === 'taux' ? Math.abs(ev.taux - cur.taux) > 0.001 : ev[k] !== cur[k]);
  const sA = calcSalary(e), sN = calcSalary({ ...e, taux_horaire: ev.taux, classe_num: ev.classe, heures_semaine: ev.h, heures_sup_semaine: ev.hs });
  const min = getEffectiveMin(ev.classe), today = eqToday(), nm = eqFirstNextMonth(), fj = eqFirstJan();
  const lines = [];
  if (chg('taux')) lines.push(`Taux : ${eqFmtTaux(cur.taux)} → <b>${eqFmtTaux(ev.taux)}</b> ${cur.taux > 0 ? `<span class="${ev.taux > cur.taux ? 'eq-up' : 'eq-down'}">${eqPct(cur.taux, ev.taux)}</span>` : ''}`);
  if (chg('classe')) lines.push(`Classe : ${cur.classe} → <b>${ev.classe}</b> (groupe ${getCcmClass(ev.classe).groupe})`);
  if (chg('h') || chg('hs')) lines.push(`Temps : ${cur.h} h + ${cur.hs} → <b>${ev.h} h + ${ev.hs}</b>`);
  if (chg('poste')) lines.push(`Poste : <b>${taEsc(ev.poste)}</b>`);
  const nothing = !lines.length;
  if (!nothing) lines.push(`Brut mensuel : ${fmt(sA.monthly)} → <b>${fmt(sN.monthly)}</b> · coût employeur ${sN.costAnnual >= sA.costAnnual ? '+' : ''}${fmt(sN.costAnnual - sA.costAnnual)} / an`);
  const under = !isMinWageExempt(e) && ev.taux < min - 0.001;
  const ok = ev.motif && ev.date && !nothing && !ev.busy;
  const row = (k, lbl, curTxt, input) => `<tr class="${chg(k) ? 'chg' : ''}"><td>${lbl}</td><td class="eq-cur num">${curTxt}</td><td>${input}</td></tr>`;
  return `<h2>📈 Évolution de salaire · ${taEsc(e.prenom)} ${taEsc(e.nom)}</h2>
    <p class="eq-sub">Le contrat ne change pas : une ligne datée s’ajoute à l’historique, les précédentes restent telles quelles.</p>
    <div class="fg"><label>Motif</label><div class="eq-motifs">${Object.entries(REMU_MOTIFS).filter(([k]) => k !== 'debut_contrat').map(([k, l]) => `<button type="button" class="eq-motif ${ev.motif === k ? 'on' : ''}" onclick="eqEv('motif','${k}')">${l}</button>`).join('')}</div></div>
    <div class="fg"><label for="eq-ev-date">Date d’effet</label>
      <div class="eq-quick"><input type="date" id="eq-ev-date" value="${ev.date}" onchange="eqEv('date',this.value)">
        <button type="button" class="btn btn-sm ${ev.date === today ? 'btn-primary' : 'btn-ghost'}" onclick="eqEv('date','${today}')">Aujourd’hui</button>
        <button type="button" class="btn btn-sm ${ev.date === nm ? 'btn-primary' : 'btn-ghost'}" onclick="eqEv('date','${nm}')">${eqFmtDateLong(nm)}</button>
        <button type="button" class="btn btn-sm ${ev.date === fj ? 'btn-primary' : 'btn-ghost'}" onclick="eqEv('date','${fj}')">${eqFmtDateLong(fj)}</button></div>
      ${ev.date > today ? '<span class="eq-hint">S’appliquera automatiquement à cette date ; d’ici là, la fiche l’annonce « à venir ».</span>' : ''}</div>
    <table class="eq-cmp"><tbody>
      ${row('taux', 'Taux horaire', eqFmtTaux(cur.taux), `<input type="number" step="0.01" id="eq-ev-taux" value="${ev.taux.toFixed(2)}" oninput="eqEv('taux',this.value)" aria-label="Nouveau taux">
        <div class="eq-pct"><span class="eq-hint">ou</span><input type="number" step="0.1" id="eq-ev-pct" value="${taEsc(ev.pct)}" placeholder="+ %" oninput="eqEv('pct',this.value)" aria-label="Hausse en pourcentage"><span class="eq-hint">%</span></div>`)}
      ${row('classe', 'Classe CCM', `Cl.${cur.classe} · ${getCcmClass(cur.classe).groupe}`, `<select id="eq-ev-classe" onchange="eqEv('classe',this.value)" aria-label="Nouvelle classe">${eqClasseOptions(ev.classe)}</select>`)}
      ${row('h', 'Heures / semaine', cur.h + ' h', `<input type="number" step="0.5" id="eq-ev-h" value="${ev.h}" oninput="eqEv('h',this.value)" aria-label="Heures par semaine">`)}
      ${row('hs', 'Heures sup habituelles', cur.hs + ' h', `<input type="number" step="0.5" id="eq-ev-hs" value="${ev.hs}" oninput="eqEv('hs',this.value)" aria-label="Heures sup habituelles">`)}
      ${row('poste', 'Poste', taEsc(cur.poste || '—'), `<input id="eq-ev-poste" value="${taEsc(ev.poste)}" oninput="eqEv('poste',this.value)" aria-label="Poste">`)}
    </tbody></table>
    <div class="fg"><label for="eq-ev-note">Note <span style="font-weight:400;text-transform:none">(optionnel)</span></label><input id="eq-ev-note" value="${taEsc(ev.note)}" placeholder="Ex. entretien annuel 2026, NAO…" oninput="eqEv('note',this.value,false)"></div>
    <div class="eq-summary">${nothing ? '<span class="eq-hint">Modifiez au moins un élément pour voir l’effet.</span>' : lines.map(l => `<span>${l}</span>`).join('')}
      ${under ? `<span class="eq-warnl">⚠ Sous le minimum de la classe ${ev.classe} (${eqFmtTaux(min)}). <button type="button" class="btn btn-ghost btn-xs" onclick="eqEv('setmin')">Mettre au minimum</button></span>` : ''}</div>
    <div class="eq-actions">${!ev.motif && !nothing ? '<span class="eq-hint">Choisissez un motif pour enregistrer.</span>' : ''}
      <button class="btn btn-ghost" onclick="eqCloseDlg()">Annuler</button><button class="btn btn-primary" onclick="eqSaveEvol()" ${ok ? '' : 'disabled'}>💾 Enregistrer l’évolution</button></div>`;
}
async function eqSaveEvol() {
  const e = eqEmp(), ev = EQ.dlg, db = window.SupabaseDB;
  if (!e || !ev || !db || ev.busy) return;
  ev.busy = true; eqRenderDlg();
  const { data, error } = await db.rpc('ajouter_remuneration_rh', {
    p_employe_id: e.id, p_date_effet: ev.date, p_classe_num: ev.classe, p_taux_horaire: ev.taux,
    p_heures_semaine: ev.h, p_heures_sup_semaine: ev.hs, p_poste: (ev.poste || '').trim(), p_motif: ev.motif, p_note: (ev.note || '').trim(),
  });
  if (error || data?.ok === false) { ev.busy = false; eqRenderDlg(); ptgToast('Erreur : ' + (data?.message || error?.message || 'inconnue')); return; }
  ptgToast(ev.date > eqToday() ? `✓ Évolution enregistrée — appliquée le ${fmtDate(ev.date)}` : '✓ Évolution enregistrée');
  eqCloseDlg();
  await syncEmployeesFromSupabase({ silent: true });
  eqReloadHist();
}

// Nouveau contrat : renouvellement de CDD, passage en CDI, reprise (saisonnier).
function eqOpenContrat() {
  const e = eqEmp(); if (!e || !isUuid(e.id)) return;
  const today = eqToday();
  const debut = e.date_sortie && e.date_sortie < today ? taAdd(e.date_sortie, 1) : today;
  EQ.dlg = { kind: 'contrat', type: e.type_contrat === 'CDD' ? 'CDI' : (e.type_contrat || 'CDI'), debut, fin: '', clore: true,
             taux: parseFloat(e.taux_horaire) || 0, classe: resolveClasse(e), h: parseFloat(e.heures_semaine) || 35, hs: parseFloat(e.heures_sup_semaine) || 0, poste: e.poste || '', busy: false };
  eqRenderDlg();
}
function eqNc(k, v, rerender = false) {
  const nc = EQ.dlg; if (!nc) return;
  if (k === 'clore') nc.clore = !!v;
  else if (k === 'taux' || k === 'h' || k === 'hs') nc[k] = parseFloat(v) || 0;
  else if (k === 'classe') nc.classe = parseInt(v) || 1;
  else nc[k] = v;
  if (rerender) eqRenderDlg();
}
function eqDlgContrat() {
  const e = eqEmp(), nc = EQ.dlg;
  const ouvert = !e.date_sortie || e.date_sortie >= nc.debut;
  const veille = nc.debut ? taAdd(nc.debut, -1) : '';
  return `<h2>🔄 Nouveau contrat · ${taEsc(e.prenom)} ${taEsc(e.nom)}</h2>
    <p class="eq-sub">Pour un renouvellement de CDD, un passage en CDI ou une reprise (saisonnier). Pour une simple hausse de salaire, utilisez « Faire évoluer le salaire ».</p>
    <div class="form-grid">
      <div class="fg"><label for="eq-nc-type">Type de contrat</label><select id="eq-nc-type" onchange="eqNc('type',this.value)">${EQ_TYPES.map(t => `<option ${t === nc.type ? 'selected' : ''}>${t}</option>`).join('')}</select></div>
      <div class="fg"><label for="eq-nc-debut">Début</label><input type="date" id="eq-nc-debut" value="${nc.debut}" onchange="eqNc('debut',this.value,true)"></div>
      <div class="fg"><label for="eq-nc-fin">Fin <span style="font-weight:400;text-transform:none">(vide pour un CDI)</span></label><input type="date" id="eq-nc-fin" value="${nc.fin}" onchange="eqNc('fin',this.value)"></div>
      <div class="fg" style="justify-content:flex-end">${ouvert && nc.debut
        ? `<label class="eq-check"><input type="checkbox" id="eq-nc-clore" ${nc.clore ? 'checked' : ''} onchange="eqNc('clore',this.checked)"> Terminer le ${taEsc(e.type_contrat || 'contrat')} actuel le ${fmtDate(veille)} (veille)</label>`
        : `<span class="eq-hint">Le ${taEsc(e.type_contrat || 'contrat')} précédent s’est terminé le ${fmtDate(e.date_sortie)}.</span>`}</div>
      <div class="fg"><label for="eq-nc-taux">Taux horaire de départ (€)</label><input type="number" step="0.01" id="eq-nc-taux" value="${nc.taux.toFixed(2)}" oninput="eqNc('taux',this.value)"></div>
      <div class="fg"><label for="eq-nc-classe">Classe CCM</label><select id="eq-nc-classe" onchange="eqNc('classe',this.value)">${eqClasseOptions(nc.classe)}</select></div>
      <div class="fg"><label for="eq-nc-h">Heures / semaine</label><input type="number" step="0.5" id="eq-nc-h" value="${nc.h}" oninput="eqNc('h',this.value)"></div>
      <div class="fg"><label for="eq-nc-hs">Heures sup habituelles</label><input type="number" step="0.5" id="eq-nc-hs" value="${nc.hs}" oninput="eqNc('hs',this.value)"></div>
      <div class="fg full"><label for="eq-nc-poste">Poste</label><input id="eq-nc-poste" value="${taEsc(nc.poste)}" oninput="eqNc('poste',this.value)"></div>
    </div>
    <span class="eq-hint">Conditions reprises du contrat actuel : modifiez-les si elles changent avec le nouveau contrat.</span>
    <div class="eq-actions"><button class="btn btn-ghost" onclick="eqCloseDlg()">Annuler</button><button class="btn btn-primary" onclick="eqSaveContrat()" ${nc.busy ? 'disabled' : ''}>💾 Créer le contrat</button></div>`;
}
async function eqSaveContrat() {
  const e = eqEmp(), nc = EQ.dlg, db = window.SupabaseDB;
  if (!e || !nc || !db || nc.busy) return;
  if (!nc.debut) { ptgToast('La date de début est requise'); return; }
  if (nc.fin && nc.fin < nc.debut) { ptgToast('La date de fin est avant la date de début'); return; }
  if (!(nc.taux > 0)) { ptgToast('Le taux horaire est requis'); return; }
  const ouvert = !e.date_sortie || e.date_sortie >= nc.debut;
  nc.busy = true; eqRenderDlg();
  const { data, error } = await db.rpc('upsert_contrat_rh', {
    p_employe_id: e.id, p_date_debut: nc.debut, p_date_fin: nc.fin || null, p_type_contrat: nc.type,
    p_classe_num: nc.classe, p_taux_horaire: nc.taux, p_heures_semaine: nc.h || 35, p_heures_sup_semaine: nc.hs,
    p_poste: (nc.poste || '').trim(), p_clore_precedent: ouvert && nc.clore,
  });
  if (error || data?.ok === false) { nc.busy = false; eqRenderDlg(); ptgToast('Erreur : ' + (data?.message || error?.message || 'inconnue')); return; }
  ptgToast('✓ Nouveau contrat créé');
  eqCloseDlg();
  await syncEmployeesFromSupabase({ silent: true });
  eqReloadHist();
}

function closeModal() {
  document.getElementById('modal-overlay').classList.remove('open');
}

// Ouvre la modale pour compléter la fiche RH d'un compte sonotrad-pwa
// existant (id Supabase réel) qui n'a pas encore de données RH — nom/prénom
// verrouillés pour ne jamais introduire de casse/accents différents de la
// ligne `employes` déjà liée au pin_hash côté kiosque Pointage.
function openModalForUnlinked(id, prenom, nom) {
  openModal();
  document.getElementById('f-kind-row').style.display = 'none';
  document.getElementById('modal-title').innerHTML = '<span>🔗</span> Compléter la fiche RH';
  document.getElementById('edit-id').value = id;
  document.getElementById('f-nom').value = nom;
  document.getElementById('f-nom').readOnly = true;
  document.getElementById('f-prenom').value = prenom;
  document.getElementById('f-prenom').readOnly = true;
  document.getElementById('modal-linked-badge').style.display = 'inline-block';
}

function updateModalGroup() { updateModalCalc(); }

function updateModalCalc() {
  const rate = parseFloat(document.getElementById('f-taux').value)||0;
  const hSem = parseFloat(document.getElementById('f-heures').value)||35;
  const hSup = parseFloat(document.getElementById('f-hsup').value)||0;
  const classeNum = parseInt(document.getElementById('f-classe').value)||1;
  const cl = getCcmClass(classeNum);
  const groupe = cl.groupe;
  const ccmTaux = getCcmMinRate(classeNum);
  const effMin = getEffectiveMin(classeNum);
  const belowSmic = ccmTaux < settings.smic;
  const gColors = getGroupeColors();

  // Update groupe display
  const gDisp = document.getElementById('f-groupe-display');
  if (gDisp) {
    gDisp.textContent = groupe;
    gDisp.style.background = (gColors[groupe]||'#888')+'33';
    gDisp.style.color = gColors[groupe]||'#888';
  }
  document.getElementById('f-groupe').value = groupe;

  const contrat = document.getElementById('f-contrat')?.value || 'CDI';
  const fakeEmp = {taux_horaire:rate, heures_semaine:hSem, heures_sup_semaine:hSup, classe_num:classeNum, type_contrat:contrat};
  const exempt = isMinWageExempt(fakeEmp);
  const s = calcSalary(fakeEmp);

  document.getElementById('mc-smic').textContent = settings.smic.toFixed(2)+'€/h';
  document.getElementById('mc-ccm').textContent = ccmTaux.toFixed(2)+`€/h (${belowSmic?'⚠️ sous SMIC':''}SMH ${cl.smhMensuel.toLocaleString('fr-FR')}€/mois)`;
  document.getElementById('mc-base').textContent = fmt(s.basePay);
  document.getElementById('mc-hsup').textContent = s.supPay>0?fmt(s.supPay):'—';
  document.getElementById('mc-total').textContent = fmt(s.monthly);
  document.getElementById('mc-annual').textContent = fmt(s.annual);
  document.getElementById('mc-charged').textContent = fmt(s.costAnnual);

  let hint = '';
  if (exempt && rate>0) hint=`ℹ️ Apprenti/stagiaire — barème légal spécifique (% du SMIC selon âge/année), mini SMIC/CCM non applicable`;
  else if (rate>0 && rate<effMin) hint=`ℹ️ Taux d'embauche (${rate.toFixed(2)}€) sous le mini effectif (${effMin.toFixed(2)}€) — le SMIC/CCM s'applique automatiquement à la paie, aucune régularisation manuelle nécessaire`;
  else if (rate>0) hint=`✅ Mini effectif : ${effMin.toFixed(2)}€/h · Δ vs CCM/SMIC : +${(rate-effMin).toFixed(2)}€/h · SMH mensuel CCM : ${cl.smhMensuel.toLocaleString('fr-FR')}€`;
  document.getElementById('modal-hint').textContent = hint;
  document.getElementById('modal-hint').style.display = hint?'':'none';
}

function saveEmployee() {
  if (document.querySelector('#modal-overlay .modal').classList.contains('ext')) { saveExterne(); return; }
  const id = document.getElementById('edit-id').value;
  const classeNum = parseInt(document.getElementById('f-classe').value)||1;
  const cl = getCcmClass(classeNum);
  const emp = {
    id: id || Date.now().toString(),
    nom: document.getElementById('f-nom').value.trim(),
    prenom: document.getElementById('f-prenom').value.trim(),
    date_entree: document.getElementById('f-entree').value,
    date_sortie: document.getElementById('f-sortie').value||null,
    type_contrat: document.getElementById('f-contrat').value,
    poste: document.getElementById('f-poste').value.trim(),
    classe_num: classeNum,
    groupe: cl.groupe,
    heures_semaine: parseFloat(document.getElementById('f-heures').value)||35,
    heures_sup_semaine: parseFloat(document.getElementById('f-hsup').value)||0,
    taux_horaire: parseFloat(document.getElementById('f-taux').value)||0,
    notes: document.getElementById('f-notes').value.trim(),
    adresse: document.getElementById('f-adresse').value.trim(),
    telephone_perso: document.getElementById('f-tel-perso').value.trim(),
    email_perso: document.getElementById('f-email-perso').value.trim(),
  };
  if (!emp.nom) { alert('Le nom est requis'); return; }
  if (id) {
    // id peut désigner un salarié déjà local (édition) OU un compte
    // sonotrad-pwa "sans fiche RH" jamais encore ajouté à `employees`
    // (complété via openModalForUnlinked) — dans ce 2e cas on l'ajoute.
    const idx = employees.findIndex(e => e.id === id);
    if (idx >= 0) employees[idx] = emp; else employees.push(emp);
  } else {
    employees.push(emp);
  }
  saveData();
  closeModal();
  refresh();
  unlinkedPtgAccounts = unlinkedPtgAccounts.filter(e => e.id !== id);
  renderUnlinkedPtgAccounts();
  pushEmployeeToSupabase(emp).then(newId => {
    if (newId && newId !== emp.id) {
      // Adopte l'uuid généré par Supabase pour un salarié créé localement
      employees = employees.map(e => e.id === emp.id ? {...e, id: newId} : e);
      saveData();
      refresh();
    }
  });
}

// ═══════════════════════════════════════════
// BADGE NFC — association salarié <-> UID (lecteur USB clavier, voir _badgeKbd)
// ═══════════════════════════════════════════
const _badge = { timer: null };

function openBadgeModal(id) {
  const emp = employees.find(e => e.id === id);
  if (!emp) return;
  document.getElementById('badge-employe-id').value = id;
  document.getElementById('badge-modal-nom').textContent = `${emp.prenom} ${emp.nom}`;
  _badgeZoneMsg('');
  _badgeRefreshStatus(emp);
  document.getElementById('badge-modal-overlay').classList.add('open');
}

function closeBadgeModal() {
  _badgeStopListening();
  document.getElementById('badge-modal-overlay').classList.remove('open');
}

function _badgeZoneMsg(text) {
  const zone = document.getElementById('badge-listen-zone');
  zone.textContent = text;
  zone.style.display = text ? '' : 'none';
}

function _badgeRefreshStatus(emp) {
  const pill = document.getElementById('badge-status-pill');
  const dissocierBtn = document.getElementById('badge-dissocier-btn');
  if (emp.hasBadge) {
    pill.textContent = 'Badge associé';
    pill.className = 'badge-ok';
    dissocierBtn.style.display = '';
  } else {
    pill.textContent = 'Aucun badge';
    pill.className = 'badge-alert';
    dissocierBtn.style.display = 'none';
  }
}

function _badgeListen() {
  _badgeStopListening();
  document.getElementById('badge-listen-btn').disabled = true;
  _badgeZoneMsg('📡 En écoute… passez le badge sur le lecteur.');
  _badge.timer = setTimeout(() => {
    _badgeZoneMsg('⏱ Aucun scan détecté après 30s — réessaie.');
    _badgeStopListening();
  }, 30000);
}

function _badgeStopListening() {
  if (_badge.timer) { clearTimeout(_badge.timer); _badge.timer = null; }
  const btn = document.getElementById('badge-listen-btn');
  if (btn) btn.disabled = false;
}

async function associerBadgeConfirm(uid) {
  const db = window.SupabaseDB;
  const id = document.getElementById('badge-employe-id').value;
  if (!db) { ptgToast('⚠ Supabase non configuré'); return; }
  const { data, error } = await db.rpc('associer_badge_nfc', { p_employe_id: id, p_uid: uid });
  if (error || data?.ok === false) {
    _badgeZoneMsg('⚠ ' + (data?.message || error?.message || 'Association échouée.'));
    return;
  }
  const emp = employees.find(e => e.id === id);
  if (emp) emp.hasBadge = true;
  _badgeZoneMsg('✅ Badge associé.');
  _badgeRefreshStatus(emp || { hasBadge: true });
  ptgToast('✅ Badge NFC associé');
  refresh();
}

async function dissocierBadge() {
  const db = window.SupabaseDB;
  const id = document.getElementById('badge-employe-id').value;
  if (!confirm('Dissocier ce badge du salarié ?')) return;
  if (!db) { ptgToast('⚠ Supabase non configuré'); return; }
  const { data, error } = await db.rpc('dissocier_badge_nfc', { p_employe_id: id });
  if (error || data?.ok === false) {
    ptgToast('⚠ ' + (data?.message || error?.message || 'Dissociation échouée.'));
    return;
  }
  const emp = employees.find(e => e.id === id);
  if (emp) emp.hasBadge = false;
  _badgeRefreshStatus(emp || { hasBadge: false });
  _badgeZoneMsg('');
  ptgToast('Badge dissocié');
  refresh();
}

function filterAlerts() {
  document.getElementById('filter-status').value='alerts';
  renderTable();
}

// ═══════════════════════════════════════════
// EXPORT
// ═══════════════════════════════════════════
function exportCSV() {
  const headers = ['Nom','Prénom','Entrée','Sortie','Contrat','Poste','Groupe','Classe CCM','SMH mensuel CCM €','Taux salarié €/h','Mini CCM €/h','Mini effectif €/h','Δ vs effectif min','Brut mensuel €','H.Sup mensuel €','Brut annuel €','Coût emp. annuel €'];
  const rows = employees.map(e=>{
    const s=calcSalary(e);
    const cn=resolveClasse(e); const cl=getCcmClass(cn);
    const ccmTaux=getCcmMinRate(cn); const effMin=getEffectiveMin(cn);
    const rate=parseFloat(e.taux_horaire)||0;
    return [e.nom,e.prenom,e.date_entree||'',e.date_sortie||'',e.type_contrat,e.poste,cl.groupe,'Cl.'+cn,cl.smhMensuel,rate.toFixed(2),ccmTaux.toFixed(2),effMin.toFixed(2),(rate-effMin).toFixed(2),s.monthly.toFixed(2),s.supPay.toFixed(2),s.annual.toFixed(2),s.costAnnual.toFixed(2)].join(';');
  });
  const csv = [headers.join(';'),...rows].join('\n');
  const blob = new Blob(['﻿'+csv],{type:'text/csv;charset=utf-8'});
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href=url; a.download='equipe_rh_'+new Date().toISOString().split('T')[0]+'.csv';
  a.click(); URL.revokeObjectURL(url);
}

// ═══════════════════════════════════════════
// NAVIGATION
// ═══════════════════════════════════════════
function showTab(id) {
  // Mode kiosque (?kiosk=1, Raspberry Pi) : verrouillé sur Pointage, aucune
  // donnée RH ne doit jamais être accessible depuis cet écran. Défense en
  // profondeur en plus du masquage de la nav (voir applyKioskMode) — bloque
  // aussi un changement d'onglet forcé depuis la console navigateur.
  if (KIOSK_MODE && id !== 'pointage') id = 'pointage';
  document.querySelectorAll('.tab').forEach(t=>t.classList.remove('active'));
  document.querySelectorAll('[data-tab]').forEach(b=>b.classList.remove('active'));
  document.getElementById('tab-'+id).classList.add('active');
  document.querySelectorAll(`[data-tab="${id}"]`).forEach(b=>b.classList.add('active'));
  window.scrollTo({top:0,behavior:'instant'});
  if (id!=='team') eqCloseFiche(); // la fiche salarié ne reste pas ouverte sur les autres onglets
  if (id==='team') renderTable();
  if (id==='optim') renderOptim();
  if (id==='settings') renderSettings();
  if (id==='pointage') ptgShowSubView();
  if (id==='temps') taShow();
  taRenderDrawer(); // le panneau latéral de Temps & absences ne reste pas affiché sur les autres onglets
}

// ═══════════════════════════════════════════
// HELPERS
// ═══════════════════════════════════════════
function fmt(n) { return new Intl.NumberFormat('fr-FR',{style:'currency',currency:'EUR',maximumFractionDigits:0}).format(n||0); }
function fmtH(h) { return Math.round(h||0)+'h'; }
function pct(n) { return (n||0).toFixed(1)+'%'; }
function fmtDate(d) { if(!d)return'—'; try{return new Date(d).toLocaleDateString('fr-FR');}catch{return d;} }

function refresh() {
  renderDashboard();
  const activeTab = document.querySelector('.tab.active')?.id?.replace('tab-','');
  if (activeTab==='team') renderTable();
  if (activeTab==='optim') renderOptim();
}

// ═══════════════════════════════════════════
// SAMPLE DATA
// ═══════════════════════════════════════════
function SAMPLE_EMPLOYEES() {
  // Grille CCM IDCC 3248 — classes 1→18 (grille 2024, en vigueur en 2026)
  // SMIC : 12,31€/h au 1er juin 2026
  return [
    // Groupe A (classes 1-2) : SMH sous SMIC → SMIC s'applique
    {id:'s1',nom:'MARTIN',prenom:'Jean',date_entree:'2019-03-01',date_sortie:null,type_contrat:'CDI',poste:'Opérateur de production',classe_num:2,groupe:'A',heures_semaine:35,heures_sup_semaine:2,taux_horaire:12.50,notes:'Cl.2 — SMH 21850€/an, SMIC applicable'},
    // Groupe B (classes 3-4)
    {id:'s2',nom:'DUPONT',prenom:'Marie',date_entree:'2020-06-15',date_sortie:null,type_contrat:'CDI',poste:'Technicienne qualité',classe_num:5,groupe:'C',heures_semaine:35,heures_sup_semaine:0,taux_horaire:13.60,notes:'Cl.5 — SMH 24250€/an'},
    {id:'s3',nom:'BERNARD',prenom:'Thomas',date_entree:'2021-01-10',date_sortie:null,type_contrat:'CDI',poste:'Technicien méthodes',classe_num:7,groupe:'D',heures_semaine:39,heures_sup_semaine:0,taux_horaire:15.00,notes:'Cl.7 — SMH 26400€/an'},
    {id:'s4',nom:'LEROY',prenom:'Sophie',date_entree:'2022-09-01',date_sortie:null,type_contrat:'CDD',poste:'Assistante RH',classe_num:6,groupe:'C',heures_semaine:35,heures_sup_semaine:0,taux_horaire:14.10,notes:'Cl.6 — Seuil accueil Bac+2'},
    {id:'s5',nom:'MOREAU',prenom:'Pierre',date_entree:'2018-04-15',date_sortie:null,type_contrat:'CDI',poste:'Chef d\'atelier',classe_num:9,groupe:'E',heures_semaine:39,heures_sup_semaine:3,taux_horaire:17.80,notes:'Cl.9 — Maîtrise, SMH 30500€/an'},
    // Apprenti : taux horaire selon barème légal apprentissage (% du SMIC selon âge/année)
    {id:'s6',nom:'SIMON',prenom:'Alice',date_entree:'2023-02-20',date_sortie:null,type_contrat:'Apprentissage',poste:'Chargée de production',classe_num:3,groupe:'B',heures_semaine:35,heures_sup_semaine:0,taux_horaire:9.23,notes:'Apprentie 2e année — 75% SMIC (âge 21+)'},
    {id:'s7',nom:'GARCIA',prenom:'Roberto',date_entree:'2017-11-05',date_sortie:null,type_contrat:'CDI',poste:'Responsable maintenance',classe_num:12,groupe:'F',heures_semaine:39,heures_sup_semaine:4,taux_horaire:21.00,notes:'Cl.12 — SMH 36700€/an'},
    // Cadres (groupes F→I)
    {id:'s8',nom:'PETIT',prenom:'Nathalie',date_entree:'2016-07-01',date_sortie:null,type_contrat:'CDI',poste:'Directrice Commerciale',classe_num:15,groupe:'H',heures_semaine:39,heures_sup_semaine:0,taux_horaire:27.50,notes:'Cl.15 — SMH 47000€/an, Cadre Gpe H'},
    {id:'s9',nom:'ROBERT',prenom:'François',date_entree:'2022-03-14',date_sortie:'2023-12-31',type_contrat:'CDD',poste:'Technicien BE',classe_num:7,groupe:'D',heures_semaine:35,heures_sup_semaine:0,taux_horaire:14.60,notes:'CDD terminé — Cl.7'},
  ];
}

// ═══════════════════════════════════════════
// ACCORDÉON ONGLET OPTIMISATION
// ═══════════════════════════════════════════
function toggleCard(cardId) {
  const card = document.getElementById(cardId);
  if (card) card.classList.toggle('collapsed');
}
function toggleAllOptiCards(collapse) {
  document.querySelectorAll('.opti-card').forEach(c => {
    c.classList.toggle('collapsed', collapse);
  });
}

// ═══════════════════════════════════════════
// SIMULATION INDIVIDUELLE
// ═══════════════════════════════════════════
let simIndivOverrides = {}; // {empId: {taux_horaire?, heures_sup_semaine?}}
let hypoEmployees = [];     // [{nom, classe_num, heures_semaine, heures_sup_semaine, taux_horaire}]

function renderIndivSim() {
  const active = getActiveEmployees();
  const GC = getGroupeColors();
  const tbody = document.getElementById('sim-indiv-body');
  if (!tbody) return;

  const baseTotal = active.reduce((s,e) => s + calcSalary(e).monthly, 0);

  // Rows: existing employees
  let rows = active.map(e => {
    const cn = resolveClasse(e);
    const cl = getCcmClass(cn);
    const ov = simIndivOverrides[e.id] || {};
    const curTaux = parseFloat(e.taux_horaire) || 0;
    const curHsup = parseFloat(e.heures_sup_semaine) || 0;
    const newTaux = ov.taux_horaire !== undefined ? ov.taux_horaire : curTaux;
    const newHsup = ov.heures_sup_semaine !== undefined ? ov.heures_sup_semaine : curHsup;
    const curSal = calcSalary(e).monthly;
    const simSal = calcSalary({...e, taux_horaire: newTaux, heures_sup_semaine: newHsup}).monthly;
    const delta = simSal - curSal;
    const hasChange = ov.taux_horaire !== undefined || ov.heures_sup_semaine !== undefined;
    return `<tr style="${hasChange?'background:rgba(124,108,248,.04)':''}">
      <td><b>${e.nom}</b> ${e.prenom}<br><span style="font-size:10px;color:var(--muted)">${e.poste||''}</span></td>
      <td><div class="grp-badge grp-${cl.groupe}" style="display:inline-flex">${cl.groupe}</div> <span style="font-size:10px;color:var(--muted)">Cl.${cn}</span></td>
      <td class="num">${e.heures_semaine||35}h</td>
      <td class="num">${curHsup}h</td>
      <td class="num">${curTaux.toFixed(2)}€</td>
      <td><input class="sim-input ${ov.taux_horaire!==undefined?'changed':''}" type="number" step="0.01" value="${newTaux.toFixed(2)}"
          oninput="setSimOverride('${e.id}','taux',this.value)" title="Mini effectif : ${getEffectiveMin(cn).toFixed(2)}€/h"></td>
      <td><input class="sim-input ${ov.heures_sup_semaine!==undefined?'changed':''}" type="number" step="0.5" min="0" max="20" value="${newHsup}"
          oninput="setSimOverride('${e.id}','hsup',this.value)"></td>
      <td class="num">${fmt(curSal)}</td>
      <td class="num" style="${hasChange?'font-weight:700;color:var(--text)':''}">${fmt(simSal)}</td>
      <td class="num ${delta>0?'sim-delta-pos':delta<0?'sim-delta-neg':'sim-delta-zero'}">${delta>=0?'+':''}${fmt(delta)}</td>
      <td><button class="btn btn-ghost btn-xs" onclick="resetOneEmp('${e.id}')" title="Réinitialiser" style="opacity:.5">↺</button></td>
    </tr>`;
  });

  // Rows: hypothetical employees
  hypoEmployees.forEach((h, idx) => {
    const cn = h.classe_num;
    const cl = getCcmClass(cn);
    const simSal = calcSalary(h).monthly;
    rows.push(`<tr class="hypo-row">
      <td><b style="color:var(--teal)">${h.nom}</b> <span style="font-size:10px;background:rgba(0,201,167,.15);color:var(--teal);padding:1px 5px;border-radius:10px">hypothétique</span></td>
      <td><div class="grp-badge grp-${cl.groupe}" style="display:inline-flex">${cl.groupe}</div> <span style="font-size:10px;color:var(--muted)">Cl.${cn}</span></td>
      <td class="num">${h.heures_semaine}h</td>
      <td class="num">${h.heures_sup_semaine}h</td>
      <td class="num">—</td>
      <td><input class="sim-input changed" type="number" step="0.01" value="${h.taux_horaire.toFixed(2)}"
          oninput="updateHypo(${idx},'taux',this.value)"></td>
      <td><input class="sim-input changed" type="number" step="0.5" min="0" max="20" value="${h.heures_sup_semaine}"
          oninput="updateHypo(${idx},'hsup',this.value)"></td>
      <td class="num" style="color:var(--muted)">—</td>
      <td class="num" style="font-weight:700;color:var(--teal)">${fmt(simSal)}</td>
      <td class="num sim-delta-pos">+${fmt(simSal)}</td>
      <td><button class="btn btn-danger btn-xs" onclick="removeHypo(${idx})">✕</button></td>
    </tr>`);
  });

  tbody.innerHTML = rows.join('');
  updateIndivSimSummary();
}

function setSimOverride(empId, field, value) {
  if (!simIndivOverrides[empId]) simIndivOverrides[empId] = {};
  const num = parseFloat(value);
  if (field === 'taux') simIndivOverrides[empId].taux_horaire = isNaN(num) ? undefined : num;
  if (field === 'hsup') simIndivOverrides[empId].heures_sup_semaine = isNaN(num) ? undefined : num;
  // Don't re-render (would lose input focus), just update summary + style
  updateInputStyle(empId);
  updateIndivSimSummary();
}

function updateInputStyle(empId) {
  const ov = simIndivOverrides[empId] || {};
  const inputs = document.querySelectorAll(`[oninput*="'${empId}'"]`);
  inputs.forEach(inp => {
    const isTaux = inp.getAttribute('oninput').includes("'taux'");
    const hasChange = isTaux ? ov.taux_horaire !== undefined : ov.heures_sup_semaine !== undefined;
    inp.classList.toggle('changed', hasChange);
    // Update calculated cells in same row
    const emp = employees.find(e => e.id === empId);
    if (emp) {
      const tr = inp.closest('tr');
      if (tr) {
        const curTaux = parseFloat(emp.taux_horaire)||0;
        const curHsup = parseFloat(emp.heures_sup_semaine)||0;
        const newTaux = ov.taux_horaire !== undefined ? ov.taux_horaire : curTaux;
        const newHsup = ov.heures_sup_semaine !== undefined ? ov.heures_sup_semaine : curHsup;
        const curSal = calcSalary(emp).monthly;
        const simSal = calcSalary({...emp, taux_horaire: newTaux, heures_sup_semaine: newHsup}).monthly;
        const delta = simSal - curSal;
        const cells = tr.querySelectorAll('td');
        // cells[8] = brut simulé, cells[9] = delta
        if (cells[8]) { cells[8].textContent = new Intl.NumberFormat('fr-FR',{style:'currency',currency:'EUR',maximumFractionDigits:0}).format(simSal); cells[8].style.fontWeight = '700'; }
        if (cells[9]) {
          cells[9].textContent = (delta>=0?'+':'') + new Intl.NumberFormat('fr-FR',{style:'currency',currency:'EUR',maximumFractionDigits:0}).format(delta);
          cells[9].className = 'num ' + (delta>0?'sim-delta-pos':delta<0?'sim-delta-neg':'sim-delta-zero');
        }
      }
    }
  });
}

function updateIndivSimSummary() {
  const active = getActiveEmployees();
  const currentTotal = active.reduce((s,e) => s + calcSalary(e).monthly, 0);
  const simTotal = active.reduce((s,e) => {
    const ov = simIndivOverrides[e.id] || {};
    return s + calcSalary({
      ...e,
      taux_horaire: ov.taux_horaire !== undefined ? ov.taux_horaire : e.taux_horaire,
      heures_sup_semaine: ov.heures_sup_semaine !== undefined ? ov.heures_sup_semaine : e.heures_sup_semaine,
    }).monthly;
  }, 0) + hypoEmployees.reduce((s,h) => s + calcSalary(h).monthly, 0);

  const delta = simTotal - currentTotal;
  const deltaAnnual = delta * 12;
  const deltaCost = deltaAnnual * (1 + settings.charges/100);
  const GC = getGroupeColors();

  const sumEl = document.getElementById('sim-indiv-summary');
  if (!sumEl) return;
  sumEl.innerHTML = `
    <div class="sim-summary-item">
      <div class="sim-summary-lbl">Masse sal. actuelle / mois</div>
      <div class="sim-summary-val" style="color:var(--muted)">${fmt(currentTotal)}</div>
    </div>
    <div class="sim-summary-item">
      <div class="sim-summary-lbl">Masse sal. simulée / mois</div>
      <div class="sim-summary-val" style="color:var(--accent)">${fmt(simTotal)}</div>
    </div>
    <div class="sim-summary-item">
      <div class="sim-summary-lbl">Δ mensuel</div>
      <div class="sim-summary-val ${delta>0?'sim-delta-pos':delta<0?'sim-delta-neg':'sim-delta-zero'}">${delta>=0?'+':''}${fmt(delta)}</div>
    </div>
    <div class="sim-summary-item">
      <div class="sim-summary-lbl">Δ annuel (brut)</div>
      <div class="sim-summary-val ${deltaAnnual>0?'sim-delta-pos':deltaAnnual<0?'sim-delta-neg':'sim-delta-zero'}">${deltaAnnual>=0?'+':''}${fmt(deltaAnnual)}</div>
    </div>
    <div class="sim-summary-item">
      <div class="sim-summary-lbl">Δ coût employeur / an</div>
      <div class="sim-summary-val ${deltaCost>0?'sim-delta-pos':deltaCost<0?'sim-delta-neg':'sim-delta-zero'}">${deltaCost>=0?'+':''}${fmt(deltaCost)}</div>
    </div>
    <div class="sim-summary-item">
      <div class="sim-summary-lbl">Recrutements hypothétiques</div>
      <div class="sim-summary-val" style="color:var(--teal)">${hypoEmployees.length}</div>
    </div>
  `;
}

function addHypoEmployee() {
  const nom = document.getElementById('hypo-nom').value.trim() || 'Nouveau salarié';
  const cn = parseInt(document.getElementById('hypo-classe').value) || 1;
  const cl = getCcmClass(cn);
  const hSem = parseFloat(document.getElementById('hypo-heures').value) || 35;
  const hSup = parseFloat(document.getElementById('hypo-hsup').value) || 0;
  let taux = parseFloat(document.getElementById('hypo-taux').value);
  if (isNaN(taux) || taux <= 0) taux = getEffectiveMin(cn); // défaut = mini CCM
  hypoEmployees.push({ nom, classe_num: cn, groupe: cl.groupe, heures_semaine: hSem, heures_sup_semaine: hSup, taux_horaire: taux });
  // Reset form
  document.getElementById('hypo-nom').value = '';
  document.getElementById('hypo-taux').value = '';
  renderIndivSim();
}

function updateHypo(idx, field, value) {
  const num = parseFloat(value);
  if (field === 'taux' && !isNaN(num)) hypoEmployees[idx].taux_horaire = num;
  if (field === 'hsup' && !isNaN(num)) hypoEmployees[idx].heures_sup_semaine = num;
  updateIndivSimSummary();
}

function removeHypo(idx) {
  hypoEmployees.splice(idx, 1);
  renderIndivSim();
}

function resetOneEmp(empId) {
  delete simIndivOverrides[empId];
  renderIndivSim();
}

function resetIndivSim() {
  simIndivOverrides = {};
  hypoEmployees = [];
  renderIndivSim();
}

// ═══════════════════════════════════════════
// RACCOURCIS CLAVIER
// ═══════════════════════════════════════════
document.addEventListener('keydown',e=>{
  if ((e.ctrlKey||e.metaKey)&&e.key==='n'){e.preventDefault();openModal();}
  if (e.key==='Escape' && !document.querySelector('.overlay.open')) {
    if (EQ.dlg) eqCloseDlg(); else if (EQ.id) eqCloseFiche();
  }
});

// ═══════════════════════════════════════════
// BACKUP JSON — Export / Import complet
// ═══════════════════════════════════════════
const BACKUP_VERSION = 1;

function exportJSON() {
  const backup = {
    version: BACKUP_VERSION,
    exportDate: new Date().toISOString(),
    appName: 'RH Métallurgie Dashboard',
    data: { employees, settings, ccmClasses }
  };
  const blob = new Blob([JSON.stringify(backup, null, 2)], {type:'application/json;charset=utf-8'});
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'rh-metal-backup-' + new Date().toISOString().slice(0,10) + '.json';
  a.click(); URL.revokeObjectURL(a.href);
  localStorage.setItem('rh_last_backup_at', new Date().toISOString());
  renderLastBackupInfo();
}

// Pas de backup automatique côté Supabase (plan Free — ni PITR ni backups
// quotidiens, vérifié le 2026-08-21) : l'export JSON ci-dessus est la seule
// sauvegarde. Un unique export réalisé le 17/06 était resté figé faute de
// rappel — ce bandeau (Paramètres) rend la fraîcheur de la dernière
// sauvegarde visible à chaque visite au lieu de compter sur la mémoire.
function renderLastBackupInfo() {
  const el = document.getElementById('last-backup-info');
  if (!el) return;
  const iso = localStorage.getItem('rh_last_backup_at');
  if (!iso) {
    el.innerHTML = '⚠️ Aucune sauvegarde JSON enregistrée sur cet appareil.';
    el.style.color = 'var(--danger)';
    return;
  }
  const days = Math.floor((Date.now() - new Date(iso).getTime()) / 86400000);
  const dateTxt = new Date(iso).toLocaleDateString('fr-FR');
  el.textContent = `Dernière sauvegarde : ${dateTxt} (il y a ${days} j${days > 1 ? 'ours' : ''})`;
  el.style.color = days > 30 ? 'var(--danger)' : days > 14 ? 'var(--warn)' : 'var(--muted)';
}

function importJSON(input) {
  const file = input.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = function(e) {
    try {
      const backup = JSON.parse(e.target.result);
      if (!backup.data || !backup.data.employees) {
        alert('❌ Fichier invalide : structure non reconnue.');
        return;
      }
      const d = backup.exportDate ? new Date(backup.exportDate).toLocaleString('fr-FR') : '?';
      if (!confirm(`Importer la sauvegarde du ${d} ?\n\n${backup.data.employees.length} salarié(s) trouvé(s).\n\n⚠️ Toutes les données actuelles seront remplacées.`)) {
        input.value = ''; return;
      }
      employees = backup.data.employees || [];
      settings = {...DEFAULT_SETTINGS, ...(backup.data.settings || {})};
      ccmClasses = backup.data.ccmClasses || JSON.parse(JSON.stringify(DEFAULT_CCM));
      localStorage.setItem('rh_employees', JSON.stringify(employees));
      localStorage.setItem('rh_settings', JSON.stringify(settings));
      localStorage.setItem('rh_ccm', JSON.stringify(ccmClasses));
      clearSelection();
      refresh();
      renderSettings();
      alert(`✅ Import réussi : ${employees.length} salarié(s) chargé(s).`);
    } catch(err) {
      alert('❌ Erreur de lecture : ' + err.message);
    }
    input.value = '';
  };
  reader.readAsText(file);
}

// ═══════════════════════════════════════════
// THEME (clair / sombre)
// ═══════════════════════════════════════════
function applyTheme(t) {
  document.documentElement.setAttribute('data-theme', t);
  localStorage.setItem('rh_theme', t);
  const btn = document.getElementById('theme-toggle');
  if (btn) btn.textContent = t === 'light' ? '🌙' : '☀️';
  const meta = document.querySelector('meta[name="theme-color"]');
  if (meta) meta.setAttribute('content', t === 'light' ? '#f3f4fa' : '#7c6cf8');
}
function toggleTheme() {
  const current = document.documentElement.getAttribute('data-theme') || 'dark';
  applyTheme(current === 'light' ? 'dark' : 'light');
}

// ═══════════════════════════════════════════
// MODULE POINTAGE — Supabase
// ═══════════════════════════════════════════
const SUPABASE_URL = 'https://ajewxwxerrjnnervzjwm.supabase.co';
// Clé publique « publishable » (remplace l'ancienne clé anon, désactivée fin 2026)
const SUPABASE_ANON_KEY = 'sb_publishable_Bvglc1RUZsIFR7oMtmE_bQ_eOAohcQS';
window.SupabaseDB = window.supabase ? window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY) : null;

// _authRecoveryPending est d'abord déduit de façon SYNCHRONE du hash d'URL
// (présent dès le chargement de la page pour un lien de récupération/
// invitation, ex. "#access_token=...&type=recovery") — pas seulement de
// l'événement PASSWORD_RECOVERY, qui est asynchrone et peut arriver APRÈS
// que initAuthGate() (plus bas, appelé dans INIT) ait déjà résolu
// getSession() avec la session de récupération (une session valide comme
// une autre) et démarré l'app directement (bug réel constaté le
// 2026-08-25 : écran "définir le mot de passe" visible une fraction de
// seconde puis application ouverte sans mot de passe défini — la 1ère
// correction du 2026-08-24, basée uniquement sur l'événement, ne suffisait
// pas à éliminer cette race). L'abonnement reste en place en complément,
// pour le cas où le format du hash changerait.
let _authRecoveryPending = /type=recovery/.test(window.location.hash);
if (window.SupabaseDB) {
  window.SupabaseDB.auth.onAuthStateChange((event) => {
    if (event === 'PASSWORD_RECOVERY') {
      _authRecoveryPending = true;
      showAuthView('setpw');
    }
  });
}

function ptgToast(msg, ms = 2800) {
  const el = document.getElementById('ptg-toast');
  if (!el) return;
  el.textContent = msg;
  el.style.display = 'block';
  clearTimeout(ptgToast._t);
  ptgToast._t = setTimeout(() => { el.style.display = 'none'; }, ms);
}

// Onglet Pointage = kiosque seul (?kiosk=1). Le suivi admin est dans Temps & absences.
function ptgShowSubView() {
  _ptgSubscribeRealtime();
  ptgInit();
}

/* ─ Kiosque ─ */
// Depuis le 2026-10-16, le badge (lecteur USB) est le moyen principal : plus de choix
// Entrée/Sortie, le serveur déduit le type du dernier pointage du jour. « Badgeage
// manuel » = choisir son nom puis taper son PIN (pointer_par_pin_employe, même limite
// d'essais par écran). La liste du jour (kiosque_liste_jour) montre qui est présent,
// parti ou pas encore badgé.

const KQ_INACTIVITE_MS = 30000; // le panneau manuel se ferme seul après 30 s sans action

const _ptg = {
  pin: '', employe: null, liste: [], jour: '', submitting: false,
  feedbackTimer: null, realtimeSub: null, idleTimer: null, clockTimer: null,
};

function ptgInit() {
  kqManuelFermer();
  _ptgMsg('');
  _kqClock();
  clearInterval(_ptg.clockTimer);
  _ptg.clockTimer = setInterval(_kqClock, 10000);
  _ptgLoadEnService();
}

// Horloge ; au changement de jour, la liste repart de zéro.
function _kqClock() {
  const now = new Date();
  const el = document.getElementById('kq-clock');
  if (!el) return;
  el.textContent = now.toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' });
  document.getElementById('kq-date').textContent =
    now.toLocaleDateString('fr-FR', { weekday: 'long', day: 'numeric', month: 'long' });
  const jour = _ptgLocalDateStr(now);
  if (_ptg.jour && _ptg.jour !== jour) _ptgLoadEnService();
  _ptg.jour = jour;
}

/* Badgeage manuel : nom puis PIN */

function kqManuelOuvrir() {
  _ptg.employe = null;
  _kqAfficherNoms();
  document.getElementById('kq-manuel').classList.add('open');
  _kqActivite();
}

function kqManuelFermer() {
  clearTimeout(_ptg.idleTimer);
  _ptg.employe = null;
  _ptg.pin = '';
  _ptg.submitting = false;
  document.getElementById('kq-manuel')?.classList.remove('open');
}

function kqManuelRetour() {
  if (_ptg.submitting) return;
  if (_ptg.employe) { _ptg.employe = null; _kqAfficherNoms(); _kqActivite(); }
  else kqManuelFermer();
}

function _kqActivite() {
  clearTimeout(_ptg.idleTimer);
  _ptg.idleTimer = setTimeout(kqManuelFermer, KQ_INACTIVITE_MS);
}

function _kqAfficherNoms() {
  document.getElementById('kq-manuel-titre').textContent = 'Qui êtes-vous ?';
  document.getElementById('kq-step-pin').style.display = 'none';
  const box = document.getElementById('kq-step-nom');
  box.style.display = '';
  box.textContent = '';
  if (!_ptg.liste.length) {
    box.innerHTML = '<div class="kq-empty">Liste indisponible — utilisez votre badge.</div>';
    return;
  }
  _ptg.liste.forEach(emp => {
    const btn = document.createElement('button');
    btn.className = 'kq-nom-btn';
    btn.textContent = `${emp.prenom || ''} ${emp.nom || ''}`.trim();
    btn.onclick = () => _kqChoisir(emp);
    box.appendChild(btn);
  });
}

function _kqChoisir(emp) {
  _ptg.employe = emp;
  _ptg.pin = '';
  _ptg.submitting = false;
  document.getElementById('kq-manuel-titre').textContent = `${emp.prenom || ''} ${emp.nom || ''}`.trim();
  document.getElementById('kq-step-nom').style.display = 'none';
  document.getElementById('kq-step-pin').style.display = '';
  _ptgRenderDots();
  _kqPinMsg('');
  _kqActivite();
}

function ptgPress(digit) {
  if (!_ptg.employe || _ptg.submitting || _ptg.pin.length >= 4) return;
  _kqActivite();
  _ptg.pin += digit;
  _ptgRenderDots();
  if (_ptg.pin.length === 4) {
    _ptg.submitting = true;
    setTimeout(_ptgSubmit, 180);
  }
}

function ptgDel() {
  if (_ptg.submitting) return;
  _kqActivite();
  _ptg.pin = _ptg.pin.slice(0, -1);
  _ptgRenderDots();
  _kqPinMsg('');
}

function _ptgRenderDots() {
  for (let i = 0; i < 4; i++) {
    const dot = document.getElementById(`ptg-dot-${i}`);
    if (dot) dot.classList.toggle('filled', i < _ptg.pin.length);
  }
}

// Message de l'accueil (badge).
function _ptgMsg(msg, color = 'var(--muted)') {
  const el = document.getElementById('ptg-msg');
  if (el) { el.textContent = msg; el.style.color = color; }
}

// Message du pavé PIN.
function _kqPinMsg(msg, color = 'var(--muted)') {
  const el = document.getElementById('kq-pin-msg');
  if (el) { el.textContent = msg; el.style.color = color; }
}

async function _ptgSubmit() {
  const db = window.SupabaseDB;
  if (!db) {
    _kqPinMsg('⚠ Supabase non configuré', 'var(--danger)');
    _ptgReset(1800);
    return;
  }

  _kqPinMsg('Vérification…');

  const { data: res, error } = await db.rpc('pointer_par_pin_employe',
    { p_employe_id: _ptg.employe.id, p_pin: _ptg.pin });
  if (error) {
    _ptgShake();
    _kqPinMsg(error.code === '42501' ? 'Kiosque non connecté — reconnectez le compte kiosque.' : 'Erreur lors de l\'enregistrement.', 'var(--danger)');
    _ptgReset(2500);
    return;
  }
  if (!res?.ok) {
    _ptgShake();
    _kqPinMsg(res?.message || 'Pointage non autorisé.', 'var(--danger)');
    _ptgReset(res?.bloque ? 6000 : 2000); // message de blocage : laisser le temps de le lire
    return;
  }

  kqManuelFermer();
  _ptgShowFeedback(res.nom, res.prenom, res.type);
}

function _ptgReset(delayMs = 0) {
  setTimeout(() => {
    _ptg.pin = '';
    _ptg.submitting = false;
    _ptgRenderDots();
    _kqPinMsg('');
  }, delayMs);
}

function _ptgShake() {
  const row = document.getElementById('ptg-dots-row');
  if (!row) return;
  row.classList.add('shake');
  setTimeout(() => row.classList.remove('shake'), 420);
}

function _ptgShowFeedback(nom, prenom, type) {
  const el = document.getElementById('ptg-feedback');
  if (!el) return;

  const typeMeta = {
    ENTREE: { label: 'Entrée en service', icon: '✅' },
    SORTIE: { label: 'Sortie de service', icon: '👋' },
  };
  const meta = typeMeta[type] || { label: type, icon: '✓' };

  document.getElementById('ptg-feedback-name').textContent = `${prenom} ${nom}`;
  document.getElementById('ptg-feedback-type').textContent = meta.label;
  document.getElementById('ptg-feedback-icon').textContent = meta.icon;
  document.getElementById('ptg-feedback-time').textContent =
    new Date().toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' });

  el.classList.add('visible');
  _ptgLoadEnService();

  clearTimeout(_ptg.feedbackTimer);
  _ptg.feedbackTimer = setTimeout(() => {
    el.classList.remove('visible');
    _ptgMsg('');
  }, 3000);
}

// Liste du jour : les présents (prénom, nom), sans heure.
async function _ptgLoadEnService() {
  const db = window.SupabaseDB;
  const list  = document.getElementById('ptg-en-service-list');
  const count = document.getElementById('ptg-en-service-count');
  if (!list) return;

  if (!db) {
    list.innerHTML = '<div class="kq-empty">Supabase non configuré</div>';
    return;
  }

  const { data, error } = await db.rpc('kiosque_liste_jour');
  if (error) {
    list.innerHTML = '<div class="kq-empty">Liste indisponible</div>';
    if (count) count.textContent = '';
    return;
  }
  _ptg.liste = data || [];
  if (!_ptg.liste.length) {
    list.innerHTML = '<div class="kq-empty">Aucun salarié</div>';
    if (count) count.textContent = '';
    return;
  }

  // Seuls les présents sont affichés (la liste complète ne sert qu'au badgeage manuel) :
  // en fin de journée, on voit tout de suite qu'il n'y a plus personne.
  // Ni heure ni ordre d'arrivée affichés (discrétion entre collègues) : ordre alphabétique.
  const rows = _ptg.liste.filter(r => r.statut === 'present');
  if (count) count.textContent = `${rows.length} présent${rows.length > 1 ? 's' : ''} sur ${_ptg.liste.length}`;

  list.textContent = '';
  if (!rows.length) {
    list.innerHTML = '<div class="kq-empty">Personne sur place</div>';
    return;
  }
  rows.forEach(r => {
    const row = document.createElement('div');
    row.className = `kq-row ${r.statut}`;
    row.innerHTML = '<div class="kq-av"></div><div style="flex:1;min-width:0"><div class="kq-nom"></div></div>';
    row.querySelector('.kq-av').textContent = (r.prenom?.[0] || '?').toUpperCase();
    row.querySelector('.kq-nom').textContent = `${r.prenom || ''} ${r.nom || ''}`.trim();
    list.appendChild(row);
  });
}

// Un seul canal Supabase Realtime partagé entre les 4 sous-onglets Pointage
// (kiosk/admin/rapport/controle) — réabonné à chaque changement de
// sous-onglet (ptgShowSubView). Écoute les tables qui peuvent changer "de
// l'extérieur" (badge NFC ou PIN sur le kiosque, correction admin sur un
// autre poste) et relance le rechargement de la vue actuellement affichée.
// Avant le 2026-08-22, seuls Kiosque et Suivi du jour avaient cet
// abonnement (deux fonctions séparées, ptg-hj-kiosk/ptg-hj-admin) —
// Rapports et Contrôle nécessitaient de ressortir/revenir ou d'actualiser
// pour voir un badgeage récent.
function _ptgSubscribeRealtime() {
  const db = window.SupabaseDB;
  if (!db) return;
  if (_ptg.realtimeSub) {
    db.removeChannel(_ptg.realtimeSub);
    _ptg.realtimeSub = null;
  }
  const onChange = () => _ptgLoadEnService();
  _ptg.realtimeSub = db
    .channel('ptg-realtime')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'heures_journalieres' }, onChange)
    .subscribe();
}

/* ─ Badge NFC ─ */
// Le type Entrée/Sortie est déterminé côté serveur par pointer_par_nfc.
async function _ptgNfcOnScan(uid) {
  const db = window.SupabaseDB;
  if (!db) return;
  const { data, error } = await db.rpc('pointer_par_nfc', { p_uid: uid });
  if (error || !data?.ok) {
    _ptgMsg(data?.message || 'Badge non reconnu.', 'var(--danger)');
    setTimeout(() => _ptgMsg(''), 2000);
    return;
  }
  kqManuelFermer();
  _ptgShowFeedback(data.nom, data.prenom, data.type);
}

/* ─ Badge NFC — lecteur USB « clavier » (YARONGTECH 8H, 2026-10-16) ─ */
// Le lecteur tape l'UID en hexa puis Entrée, très vite. On lit event.code
// (touche physique) et non event.key : le lecteur tape en QWERTY, sur un
// poste AZERTY "5E2EA9FD" s'affiche "(eéeqçfd". Il envoie les octets dans
// l'ordre inverse de celui enregistré (nfc_uid = "FDA92E5E") → on les
// remet à l'endroit. Depuis le 2026-10-16 c'est le seul chemin du badge
// (l'ancien pont ACR122U + diffusion Supabase est retiré). Une frappe humaine est trop lente pour être prise
// pour un badge (> 80 ms entre deux touches).
const BADGE_KEY_GAP_MS = 80;
const _badgeKbd = { buf: '', last: 0 };

function _badgeKbdChar(code) {
  let m = /^(?:Digit|Numpad)([0-9])$/.exec(code);
  if (m) return m[1];
  m = /^Key([A-F])$/.exec(code);
  return m ? m[1] : null;
}

document.addEventListener('keydown', e => {
  const now = Date.now();
  if (now - _badgeKbd.last > BADGE_KEY_GAP_MS) _badgeKbd.buf = '';
  _badgeKbd.last = now;
  if (e.code === 'Enter' || e.code === 'NumpadEnter') {
    const hex = _badgeKbd.buf;
    _badgeKbd.buf = '';
    if (hex.length < 8 || hex.length % 2) return;
    e.preventDefault();
    const uid = hex.match(/../g).reverse().join('');
    if (_badge.timer) { _badgeStopListening(); associerBadgeConfirm(uid); }
    else if (document.getElementById('view-pointage')?.offsetParent && (settings.nfcEnabled || KIOSK_MODE)) {
      _ptgNfcOnScan(uid);
    }
    return;
  }
  const c = _badgeKbdChar(e.code);
  _badgeKbd.buf = c ? _badgeKbd.buf + c : '';
});

/* ─ Formats partagés (portail salarié, temps.js) ─ */

// "YYYY-MM-DD" à partir des champs LOCAUX du Date, jamais via toISOString()
// (qui convertit en UTC — décale d'un jour en arrière l'été en France,
// CEST = UTC+2, dès qu'on est proche de minuit local). Bug réel repéré le
// 2026-08-19 sur la grille Contrôle (vendredi affiché comme dimanche).
function _ptgLocalDateStr(d) {
  return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
}

// Regroupe les pointages bruts (Entrée/Sortie, + Pause si saisie admin) en
// intervalles début→fin appariés chronologiquement — un badge scanné seul
// (oubli, ou service en cours) ressort en intervalle sans fin ("…").
function _ptgIntervals(list) {
  if (!list || !list.length) return [];
  const pair = (startType, endType, isPause) => {
    const out = [];
    let open = null;
    list.forEach(p => {
      if (p.type === startType) { if (!open) open = p.horodatage; }
      else if (p.type === endType && open) { out.push({ start: open, end: p.horodatage, pause: isPause }); open = null; }
    });
    if (open) out.push({ start: open, end: null, pause: isPause });
    return out;
  };
  return [...pair('ENTREE', 'SORTIE', false), ...pair('PAUSE_DEBUT', 'PAUSE_FIN', true)]
    .sort((a, b) => new Date(a.start) - new Date(b.start));
}

function _ptgItvMin(iv) {
  if (!iv) return 0;
  const p = String(iv).split(':');
  return p.length >= 2 ? Math.abs(parseInt(p[0], 10)) * 60 + parseInt(p[1], 10) : 0;
}

function _ptgHM(min) {
  if (!min && min !== 0) return '—';
  return Math.floor(min / 60) + 'h' + String(min % 60).padStart(2, '0');
}

function _ptgFmtTime(ts) {
  if (!ts) return '—';
  return new Date(ts).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Paris' });
}

function _ptgFmtDate(d) {
  return new Date(d + 'T00:00:00').toLocaleDateString('fr-FR', { weekday: 'short', day: 'numeric', month: 'short' });
}

// Comme _ptgHM, mais gère le cas (rare) d'une durée nette négative après
// correction admin.
function _ptgHMAdj(min) {
  return min < 0 ? '-' + _ptgHM(-min) : _ptgHM(min);
}


// ═══════════════════════════════════════════
// AUTH GATE — RH admin / salarié, jamais un paramètre d'URL (chantier
// 2026-08-24 : le portail salarié à venir oblige à partager la même URL
// rh-metal.vercel.app avec tous les salariés, donc l'app RH ne peut plus
// se contenter d'être protégée par la seule confidentialité de son URL).
// ═══════════════════════════════════════════
async function initAuthGate() {
  const db = window.SupabaseDB;
  if (!db) { bootAppUnlocked(); return; } // pas de config Supabase (dev local) : comportement historique
  if (_authRecoveryPending) return; // déjà géré par l'abonnement enregistré juste après createClient()

  const { data: { session } } = await db.auth.getSession();
  if (!session) { showAuthView('login'); return; }
  // Kiosque (2026-10-06) : connecté une fois avec le compte dédié kiosque@sonotrad.fr (session
  // gardée sur l'appareil). Le serveur n'accepte les pointages que de ce compte ou d'un admin RH.
  if (KIOSK_MODE) { bootAppUnlocked(); return; }
  await resolveRoleAndBoot();
}

async function resolveRoleAndBoot() {
  const db = window.SupabaseDB;
  const { data, error } = await db.rpc('get_mon_role_rh');
  if (error || !data?.ok) { showAuthView('denied'); return; }
  if (data.is_rh_admin) { window._rhMoi = data; bootAppUnlocked(); return; }
  bootPortalSalarie(data);
}

// ═══════════════════════════════════════════
// PORTAIL SALARIÉ — consultation seule (heures, congés). Voir
// resolveRoleAndBoot() : un compte lié (auth_user_id) mais pas is_rh_admin
// atterrit ici, jamais dans l'app RH complète. Toutes les données passent
// par des RPC self-scoped (get_mes_heures_rh/get_mes_conges_rh, résolues
// via auth.uid() côté serveur) — jamais un id transmis par ce code, pour
// qu'un salarié ne puisse techniquement pas consulter les données d'un
// collègue même en modifiant les appels réseau depuis les devtools.
// ═══════════════════════════════════════════
let _monProfil = null;
let _portalHeuresOffset = 0;

function bootPortalSalarie(profil) {
  _monProfil = profil;
  document.getElementById('auth-gate').style.display = 'none';
  document.getElementById('portal-view').style.display = 'block';
  document.getElementById('portal-nom').textContent = `${profil.prenom} ${profil.nom}`;
  portalShowTab('heures');
}

function portalShowTab(tab) {
  document.getElementById('portal-heures').style.display = tab === 'heures' ? 'block' : 'none';
  document.getElementById('portal-conges').style.display = tab === 'conges' ? 'block' : 'none';
  document.querySelectorAll('.portal-tab-btn').forEach(b => b.classList.toggle('active', b.dataset.ptab === tab));
  if (tab === 'heures') portalLoadHeures(_portalHeuresOffset);
  else portalLoadConges();
}

function _portalMonthRange(offset) {
  const d = new Date();
  d.setDate(1);
  d.setMonth(d.getMonth() + offset);
  const start = new Date(d.getFullYear(), d.getMonth(), 1);
  const end = new Date(d.getFullYear(), d.getMonth() + 1, 0);
  const label = start.toLocaleDateString('fr-FR', { month: 'long', year: 'numeric' });
  return { start: _ptgLocalDateStr(start), end: _ptgLocalDateStr(end), label };
}

// Variante de _ptgFmtBadges() sans white-space:nowrap — le portail s'affiche
// dans une colonne étroite (mobile compris), contrairement à Rapports côté
// admin (desktop large) : forcer nowrap y ferait déborder le tableau hors de
// son conteneur (constaté en testant l'écran, voir commit correctif).
function _portalFmtBadges(list) {
  const intervals = _ptgIntervals(list);
  if (!intervals.length) return '—';
  return intervals.map(iv => {
    const s = _ptgFmtTime(iv.start);
    const e = iv.end ? _ptgFmtTime(iv.end) : '…';
    const durMin = iv.end ? Math.round((new Date(iv.end) - new Date(iv.start)) / 60000) : null;
    const dur = durMin !== null ? ` <span style="color:var(--muted)">(${_ptgHM(durMin)})</span>` : '';
    const prefix = iv.pause ? '<span title="Pause — correction admin" style="color:var(--warn)">⏸ </span>' : '';
    return `<div>${prefix}${s} → ${e}${dur}</div>`;
  }).join('');
}

async function portalLoadHeures(offset = 0) {
  _portalHeuresOffset = offset;
  const db = window.SupabaseDB;
  const content = document.getElementById('portal-heures-content');
  if (!db || !content) return;
  const { start, end, label } = _portalMonthRange(offset);
  document.getElementById('portal-heures-label').textContent = label;
  content.innerHTML = '<div style="text-align:center;padding:32px;color:var(--muted);font-size:13px">Chargement…</div>';

  const { data, error } = await db.rpc('get_mes_heures_rh', { p_debut: start, p_fin: end });
  if (error || !data?.ok) {
    content.innerHTML = '<div style="color:var(--danger);padding:16px;font-size:13px">Erreur de chargement.</div>';
    return;
  }
  const rows = (data.heures || []).slice().sort((a, b) => a.date < b.date ? -1 : 1);
  if (!rows.length) {
    content.innerHTML = '<div style="text-align:center;padding:40px;color:var(--muted);font-size:13px">Aucune donnée sur ce mois</div>';
    return;
  }
  const badgesByDate = new Map();
  (data.badges || []).forEach(p => {
    if (!badgesByDate.has(p.date)) badgesByDate.set(p.date, []);
    badgesByDate.get(p.date).push(p);
  });
  const corrByDate = new Map();
  (data.corrections || []).forEach(c => {
    if (!corrByDate.has(c.date)) corrByDate.set(c.date, []);
    corrByDate.get(c.date).push(c);
  });

  let total = 0;
  const body = rows.map((r, i) => {
    const corrections = corrByDate.get(r.date) || [];
    const correctionMin = corrections.reduce((s, c) => s + c.delta_min, 0);
    const nm = _ptgItvMin(r.duree_nette) + correctionMin;
    total += nm;
    const corrTxt = corrections.map(c =>
      `<div style="color:var(--warn);font-size:11px">${c.delta_min > 0 ? '+' : ''}${c.delta_min}min${c.commentaire ? ' — ' + c.commentaire : ''}</div>`
    ).join('');
    return `<tr style="background:${i % 2 ? 'var(--surface2)' : 'var(--surface)'};border-bottom:1px solid var(--border)">
      <td style="padding:7px 10px;font-weight:600;white-space:nowrap">${_ptgFmtDate(r.date)}</td>
      <td style="padding:7px 10px">${_portalFmtBadges(badgesByDate.get(r.date) || [])}${corrTxt}</td>
      <td style="padding:7px 10px;text-align:right;font-weight:700;white-space:nowrap">${_ptgHMAdj(nm)}</td>
    </tr>`;
  }).join('');
  content.innerHTML = `<table style="width:100%;min-width:0;border-collapse:collapse;font-size:12px">
    <thead><tr style="text-align:left;color:var(--muted);font-size:11px">
      <th style="padding:6px 10px">Date</th><th style="padding:6px 10px">Badgeages</th><th style="padding:6px 10px;text-align:right">Total</th>
    </tr></thead>
    <tbody>${body}</tbody>
    <tfoot><tr style="font-weight:800;border-top:2px solid var(--border)">
      <td style="padding:8px 10px" colspan="2">Total du mois</td><td style="padding:8px 10px;text-align:right">${_ptgHMAdj(total)}</td>
    </tr></tfoot>
  </table>`;
}

async function portalLoadConges() {
  const db = window.SupabaseDB;
  const content = document.getElementById('portal-conges-content');
  if (!db || !content || !_monProfil) return;
  content.innerHTML = '<div style="text-align:center;padding:32px;color:var(--muted);font-size:13px">Chargement…</div>';

  const { data, error } = await db.rpc('get_mes_conges_rh');
  if (error) {
    content.innerHTML = '<div style="color:var(--danger);padding:16px;font-size:13px">Erreur de chargement.</div>';
    return;
  }
  // Réutilise calcSoldeCP()/sommeConges() (global `conges`) : sans risque de
  // collision avec l'admin, le portail et l'app RH complète ne bootent
  // jamais dans la même session (voir resolveRoleAndBoot).
  conges = data || [];
  const solde = calcSoldeCP({ id: _monProfil.employe_id, date_entree: _monProfil.date_entree });
  const typeLabels = { cp: 'Congés payés', maladie: 'Maladie', evenement_familial: 'Événement familial', sans_solde: 'Sans solde' };
  const historique = conges.length
    ? conges.map(c => `<div style="display:flex;justify-content:space-between;gap:12px;padding:7px 0;border-bottom:1px solid var(--border);font-size:12px">
        <span>${typeLabels[c.type] || c.type}${c.motif ? ' — ' + c.motif : ''}</span>
        <span style="color:var(--muted);white-space:nowrap">${fmtDateFr(c.date_debut)} → ${fmtDateFr(c.date_fin)} (${c.jours}j)</span>
      </div>`).join('')
    : '<div style="color:var(--muted);font-size:13px;text-align:center;padding:20px 0">Aucun congé enregistré</div>';

  content.innerHTML = `
    <div class="mini-calc" style="margin-bottom:20px">
      <div class="row"><span>Acquis (période en cours)</span><span>${solde.acquis} j</span></div>
      <div class="row"><span>Pris</span><span>${solde.pris} j</span></div>
      <div class="row"><span>💰 Solde CP</span><span>${solde.solde} j</span></div>
    </div>
    <div style="font-weight:700;font-size:13px;margin-bottom:8px">Historique</div>
    ${historique}
  `;
}

function showAuthView(view) {
  document.body.classList.add('auth-pending');
  document.getElementById('auth-gate').style.display = 'flex';
  document.getElementById('auth-view-login').style.display = view === 'login' ? 'block' : 'none';
  document.getElementById('auth-view-setpw').style.display = view === 'setpw' ? 'block' : 'none';
  document.getElementById('auth-view-denied').style.display = view === 'denied' ? 'block' : 'none';
}

async function authLogin() {
  const db = window.SupabaseDB;
  const errEl = document.getElementById('auth-login-error');
  errEl.textContent = '';
  const { error } = await db.auth.signInWithPassword({
    email: document.getElementById('auth-email').value.trim(),
    password: document.getElementById('auth-password').value,
  });
  if (error) { errEl.textContent = 'Email ou mot de passe incorrect.'; return; }
  if (KIOSK_MODE) { bootAppUnlocked(); return; }
  await resolveRoleAndBoot();
}

// Mot de passe oublié : Supabase envoie un lien (type=recovery) qui ramène sur
// l'écran « nouveau mot de passe » (voir _authRecoveryPending). Même message
// que le compte existe ou non, pour ne pas révéler qui a un accès.
async function authForgotPassword() {
  const db = window.SupabaseDB;
  const msg = document.getElementById('auth-forgot-msg');
  const btn = document.getElementById('auth-forgot-btn');
  document.getElementById('auth-login-error').textContent = '';
  const email = document.getElementById('auth-email').value.trim();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    msg.style.color = 'var(--danger)';
    msg.textContent = 'Saisis ton adresse e-mail ci-dessus, puis clique à nouveau sur « Mot de passe oublié ? ».';
    return;
  }
  btn.disabled = true;
  const { error } = await db.auth.resetPasswordForEmail(email, { redirectTo: location.origin + location.pathname });
  btn.disabled = false;
  msg.style.color = 'var(--muted)';
  if (error && (error.status === 429 || /rate|seconds/i.test(error.message || ''))) {
    msg.textContent = 'Trop de demandes rapprochées : patiente une minute avant de réessayer.';
    return;
  }
  msg.textContent = `Si un compte existe pour ${email}, un e-mail avec un lien pour choisir un nouveau mot de passe vient d'être envoyé. Pense à regarder dans les indésirables.`;
}

async function authSetPassword() {
  const db = window.SupabaseDB;
  const errEl = document.getElementById('auth-setpw-error');
  errEl.textContent = '';
  const pw = document.getElementById('auth-newpw').value;
  if (!pw || pw.length < 6) { errEl.textContent = 'Minimum 6 caractères.'; return; }
  const { error } = await db.auth.updateUser({ password: pw });
  if (error) { errEl.textContent = error.message; return; }
  await resolveRoleAndBoot();
}

function authLogout() {
  const db = window.SupabaseDB;
  if (!db) return;
  db.auth.signOut().then(() => location.reload());
}

function bootAppUnlocked() {
  const gate = document.getElementById('auth-gate');
  if (gate) gate.style.display = 'none';
  document.body.classList.remove('auth-pending');
  loadData();
  refresh();
  renderSettings();
  // get_employes_rh (fiche RH complète) est réservée aux admins RH depuis le 2026-10-05 :
  // le kiosque, anonyme, n'en a pas besoin (PIN/NFC passent par leurs propres RPC).
  if (!KIOSK_MODE) {
    syncEmployeesFromSupabase({ silent: true });
    subscribeEmployesChanges();
  }
  document.body.classList.toggle('kiosk-mode', KIOSK_MODE);
  if (KIOSK_MODE) showTab('pointage');
}

// ═══════════════════════════════════════════
// INIT
// ═══════════════════════════════════════════
applyTheme(document.documentElement.getAttribute('data-theme') || 'dark');
initAuthGate();

// ═══════════════════════════════════════════
// SERVICE WORKER (PWA)
// ═══════════════════════════════════════════
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('./sw.js')
      .then(reg => console.log('[PWA] SW enregistré', reg.scope))
      .catch(err => console.warn('[PWA] SW échec :', err));
  });
}
