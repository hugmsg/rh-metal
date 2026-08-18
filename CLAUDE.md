# RH Sonotrad — Tableau de bord RH Métallurgie

## C'est quoi

PWA mono-fichier (HTML+CSS+JS dans `index.html`, pas de build, pas de
framework, pas de `node_modules`) pour gérer l'équipe d'une entreprise relevant
de la **Convention Collective de la Métallurgie (IDCC 3248)**. Permet de
suivre l'effectif, calculer les salaires/coûts employeur, vérifier la
conformité aux minima de branche, simuler des scénarios RH, pointer les
horaires (kiosque PIN) et suivre les congés/absences. En transformation
progressive vers un SIRH complet (voir mémoire `project-supabase-migration`).

Titre affiché dans l'app : **RH Sonotrad** (logo bandeau). Titre HTML/PWA :
"Tableau de Bord RH — Convention Métallurgie" / "RH Métal".

## Fichiers

- `index.html` — toute l'app (HTML + CSS + JS inline, un seul fichier)
- `manifest.json` — config PWA (nom, icône, thème)
- `sw.js` — service worker (cache offline) — bumper la version si des assets cachés changent
- `icon.svg` — icône de l'app
- `supabase/migrations/` — migrations SQL appliquées au projet Supabase partagé (voir plus bas), historique/documentation — les migrations sont appliquées directement en base via MCP Supabase, ce dossier n'est pas rejoué automatiquement au déploiement
- `nfc-bridge/` — pont Python (lecteur PC/SC → Supabase Realtime Broadcast) à déployer manuellement sur le Raspberry Pi kiosque, voir son `README.md` et la section Module Pointage — Badge NFC plus bas
- `PROMPT_CLAUDE_CODE.md` — notes de setup initial (git/GitHub/Vercel), garder comme historique, ne pas dupliquer son contenu ici
- `rh-metal-backup-*.json` — exports de sauvegarde manuels (gitignorés, ne pas committer)

## Stockage des données

**Hybride localStorage + Supabase**, pas un simple stockage local :

- **Salariés (`employees`)** : `localStorage.rh_employees` reste la source pour
  toute la logique RH en mémoire, mais synchronisé avec la table Supabase
  partagée `employes` (projet `ajewxwxerrjnnervzjwm`, **partagé avec l'app
  sonotrad-pwa** qui l'utilise pour son module Pointage/kiosque PIN). Chargé
  au démarrage via `syncEmployeesFromSupabase()` (repli sur localStorage si
  rien d'enrichi côté RH en base), chaque écriture répercutée vers Supabase.
  Rafraîchissement temps réel via un canal broadcast (`subscribeEmployesChanges()`)
  quand un salarié change côté sonotrad-pwa ou un autre appareil.
- **Congés (`conges`)** : **Supabase uniquement**, pas de copie localStorage —
  table dédiée `conges` (pas partagée avec sonotrad-pwa), chargée à l'ouverture
  de l'onglet via `syncCongesFromSupabase()`.
- **Pointages/heures journalières** : gérés côté Supabase par le module
  Pointage (tables `pointages`, `heures_journalieres`), voir section dédiée.
- `rh_settings` — paramètres généraux (SMIC, charges, etc.) — localStorage uniquement
- `rh_ccm` — grille des classes CCM (peut être personnalisée par l'utilisateur) — localStorage uniquement
- `rh_theme` — thème clair/sombre — localStorage uniquement

Le déploiement (git push / Vercel) ne touche jamais aux données utilisateur.
Sauvegarde/restauration des salariés/paramètres/CCM via export/import JSON
(`exportJSON()` / `importJSON()` dans `index.html`, `BACKUP_VERSION` à
incrémenter si le format change) — **ne couvre pas** les congés (Supabase
uniquement, pas de fallback local).

### Table Supabase partagée `employes` — contrat avec sonotrad-pwa

Voir mémoire `shared-employes-table-sonotrad-rhmetal` pour le détail complet.
Points essentiels à connaître avant de toucher à ce périmètre :

- **Division des colonnes** : sonotrad-pwa possède `pin_hash`/`nfc_uid`/`actif`
  (kiosque Pointage) ; rh-metal possède `classe_num`/`taux_horaire`/`heures_semaine`/
  `heures_sup_semaine`/`date_entree`/`date_sortie`/`type_contrat`/`poste`/`notes`/`supprime`.
- **Casse/accents** : convention retenue = **casse normale + accents** (ex.
  "Breteau"/"Anaïs"), pas de TOUT-MAJUSCULE. `saveEmployee()` ne doit **jamais**
  forcer `.toUpperCase()` sur le nom — ça a déjà cassé une donnée réelle en
  prod une fois (régression corrigée le 2026-07-28).
- **Clé de correspondance** : par `id` en priorité (`p_id` optionnel sur les
  RPC `upsert_employe_rh`/`upsert_employe_pointage`), comparaison nom/prénom
  normalisée (casse+accents ignorés) en repli uniquement — jamais de
  comparaison stricte `ON CONFLICT (nom, prenom)` seule, source de doublons.
- **Accès table** : RLS activé **sans aucune policy** sur `employes` (et
  `conges`) — tout accès direct (anon/authenticated) est refusé par défaut,
  seules les RPC `SECURITY DEFINER` (`get_employes_rh`, `upsert_employe_rh`,
  `supprimer_employe_rh`, `get_conges_rh`, `upsert_conge_rh`,
  `supprimer_conge_rh`, etc.) peuvent lire/écrire. Ne jamais ajouter de policy
  `SELECT` permissive sur `employes` sans y penser à deux fois : ça
  exposerait `pin_hash` (hash bcrypt du PIN kiosque) à la clé `anon`.
- **Temps réel** : pas de `postgres_changes` brut sur `employes` (justement à
  cause du point RLS ci-dessus) — **Realtime Broadcast from Database**
  (`realtime.send()` dans un trigger, canal public `employes-changes`,
  payload minimal `{op, id}` sans donnée sensible). Les deux apps s'abonnent
  et rappellent `get_employes_rh()` au reçu d'un événement.

## Logique métier clé (dans `index.html`)

- `DEFAULT_CCM` (~ligne 704) — grille des **18 classes CCM regroupées en 9
  groupes A→I**, avec SMH annuel/mensuel et taux horaire mini par classe.
  Source : UIMM / gestionsociale.fr, grille SMH 2024 toujours en vigueur en
  2026 (pas de revalorisation de branche signée en 2025 au moment de l'écriture).
- `DEFAULT_SETTINGS` (~ligne 691) — SMIC horaire (12,31 € au 1er juin 2026),
  charges patronales (42%), base 151,67h/mois (35h), quota H.Sup, majorations
  25%/50%.
- `getEffectiveMin(classeNum)` — le minimum légal réel = `max(taux CCM, SMIC)`
  car les classes 1-2 (Groupe A) ont un SMH historiquement sous le SMIC.
- `calcSalary()`, `aggregatePayroll()` — calculs de paie (brut, H.Sup
  majorées, coût employeur chargé).
- `getAlerts(emp)` — détecte les non-conformités (ex: taux salarié < minimum
  CCM/SMIC effectif).
- Onglets de l'app : **Dashboard** (KPIs, graphiques Chart.js), **Équipe**
  (table salariés, filtres, actions groupées + section "Comptes sonotrad-pwa
  sans fiche RH" pour les salariés créés côté kiosque Pointage sans données
  RH — bouton "Compléter la fiche" qui verrouille nom/prénom sur la valeur
  déjà en base), **Optimisation** (simulateurs : hausse SMIC, heures sup,
  effectif/ETP, analyse conformité CCM, scénarios comparatifs), **Pointage**
  (kiosque PIN, suivi du jour, rapports — connecté aux tables
  `pointages`/`heures_journalieres`), **Congés** (solde CP par salarié,
  historique des absences — voir plus bas), **Paramètres** (taux/grille CCM,
  sauvegarde JSON).
- PWA : thème clair/sombre, cartes mobile pour l'équipe (vs table desktop),
  gestion de la safe-area iOS (encoche/barre de statut) en mode standalone.

### Module Congés (onglet Congés)

- `countJoursOuvres(debut, fin)` — décompte lundi-vendredi inclus (convention
  **jours ouvrés**, pas jours ouvrables — choix explicite de l'utilisateur).
  Ne déduit **pas** les jours fériés (pas de calendrier géré) — limitation
  connue, à corriger manuellement si un congé chevauche un férié.
- `getCpPeriod()` — période de référence légale CP : 1er juin N-1 → 31 mai N.
- `calcSoldeCP(emp)` — acquisition **25j ouvrés/an** (équivalent légal des
  30j ouvrables), au prorata du temps de présence depuis `date_entree` dans
  la période en cours, moins les CP déjà pris sur la période. Limitation
  connue : n'exclut pas du calcul d'acquisition les longues absences
  maladie/sans solde (l'acquisition légale réelle peut différer dans ce cas
  au-delà d'un certain seuil — à ajuster manuellement si besoin).
- 4 types de congé : `cp` (avec solde/acquisition), `maladie`,
  `evenement_familial` (avec champ `motif` libre), `sans_solde` — ces 3
  derniers sont juste **déclarés** (dates + jours), pas de solde à calculer.
- Pas de demande côté salarié pour l'instant (choix explicite) — saisie
  RH uniquement dans cet onglet. Un futur portail salarié (Phase 3, pas
  commencé) pourrait changer ça — voir mémoire `project-supabase-migration`.

### Module Pointage — Badge NFC (kiosque, 2026-07-30)

Le kiosque Pointage (`_ptg*` dans `index.html`) gère désormais deux moyens
d'identification, en coexistence sur le même écran : le PIN existant, et un
badge NFC scanné sur un lecteur USB PC/SC (ACR122U) branché à un Raspberry
Pi dédié.

**Le badge ne gère que ENTREE/SORTIE** (bascule automatique selon le dernier
pointage du jour) — jamais de pause via badge, décision explicite de Hugo :
un scan pendant qu'un salarié est déjà en service ne permet pas de
distinguer sans ambiguïté "je pars en pause" de "je pars définitivement".
Les pauses restent saisies manuellement par un admin (`admin_add_pointage`,
onglet Suivi du jour), en plus de la déduction automatique de 20 min déjà en
place pour tout poste de +6h sans aucune pause pointée.

**Schéma Supabase** (projet partagé `ajewxwxerrjnnervzjwm`) :
- `sonotrad-pwa/supabase/migrations/20260730100000_pointage_nfc.sql` —
  `pointer_par_nfc(p_uid)` (authentifie ET enregistre le pointage en un seul
  appel, auto-détecte ENTREE/SORTIE, anti-doublon 5s), `associer_badge_nfc`/
  `dissocier_badge_nfc(p_employe_id, p_uid)` (gestion du lien badge ↔
  salarié, anti-collision d'UID).
- `sonotrad-pwa/supabase/migrations/20260818000000_pointage_nfc_broadcast.sql`
  — `emettre_signal_nfc(p_event, p_payload)` : diffuse un événement Realtime
  Broadcast sur le canal `nfc-badge-scans` (`nfc_scan` pour un scan,
  `heartbeat` toutes les 15s). C'est le **transport** entre le pont et les
  navigateurs — voir "Historique" ci-dessous pour pourquoi ce n'est pas un
  serveur WebSocket direct.
- `RH-Metal/supabase/migrations/20260730000000_get_employes_rh_has_badge.sql`
  — ajoute `has_badge` (booléen, jamais l'UID) au retour de
  `get_employes_rh()`.

**Associer un badge** (onglet Équipe) : bouton 📡/📶 par salarié →
`openBadgeModal(id)` → "Écouter le prochain scan" s'abonne au canal Supabase
`nfc-badge-scans` (`db.channel('nfc-badge-scans').on('broadcast', ...)`),
timeout 30s. Fonctionne depuis **n'importe quel poste connecté à internet**
— pas besoin d'être sur le même réseau que le Pi ni physiquement devant lui
(aucune adresse à connaître : tout transite par Supabase).

**Le pont** (`nfc-bridge/`, voir son `README.md`) est un service Python
(`pyscard` + `requests`) qui tourne en systemd sur le Raspberry Pi. Il ne
sert plus rien sur le réseau (pas de port ouvert) : à chaque badge scanné,
il appelle simplement la RPC `emettre_signal_nfc` en HTTPS (`p_event:
'nfc_scan', p_payload: {uid}`), comme n'importe quel autre appel Supabase de
l'appli. Il envoie aussi un `heartbeat` toutes les 15s (même RPC, `p_event:
'heartbeat'`) pour que le kiosque sache si le pont/lecteur est réellement en
vie (pastille "Lecteur connecté"/"Lecteur hors ligne", basée sur la
fraîcheur du dernier heartbeat reçu — pas juste sur l'abonnement au canal,
qui lui reste actif tant que Supabase répond, pont éteint ou non). Réglages
→ case à cocher "Activer le badge NFC sur le kiosque" (`settings.nfcEnabled`,
un simple booléen local au navigateur — plus d'adresse à saisir).
Déploiement du pont 100% manuel (pas d'accès SSH automatisé depuis
l'environnement de dev) — le dossier du repo est la copie source/traçabilité,
pas un mécanisme de déploiement.

**Historique — pourquoi Realtime Broadcast et pas un serveur WebSocket
direct** : la toute première version (2026-07-30) exposait son propre
serveur WebSocket sur le réseau local (`ws://<ip-du-pi>:8765`), auquel le
navigateur se connectait directement. Ça fonctionnait en local
(`http://localhost:...`) mais restait bloqué indéfiniment en prod
(`https://rh-metal.vercel.app`) : une page HTTPS ne peut pas ouvrir de
WebSocket non chiffrée, même vers `127.0.0.1` (contenu mixte — confirmé le
2026-07-31 par un test direct : `new WebSocket('ws://127.0.0.1:8765')`
exécuté dans la console de la page prod restait en `CONNECTING` sans jamais
s'ouvrir). Corrigé le 2026-08-18 en repassant par Supabase (déjà en
HTTPS/WSS avec un vrai certificat, même mécanisme que `employes-changes`,
voir [[project_shared_employes_table]]) — le navigateur ne parle plus
jamais directement au pont.

**Mode kiosque strict (`?kiosk=1`)** : le Raspberry Pi ne doit **jamais**
afficher autre chose que l'écran Pointage > Kiosque — aucune donnée RH
(salariés, congés, paramètres) ne doit être accessible depuis cet appareil
physique. `KIOSK_MODE` (déclaré en tête du `<script>`) verrouille `showTab()`
sur `'pointage'` et masque toute la navigation via la classe CSS
`body.kiosk-mode`. Le Pi doit être configuré en Chromium `--kiosk` pointé
sur `https://rh-metal.vercel.app/?kiosk=1` — jamais l'URL sans ce paramètre.
Le PC de Hugo garde l'accès admin complet via l'URL normale (sans
`?kiosk=1`).

#### Bug contenu mixte HTTPS/WS — CORRIGÉ le 2026-08-18

Voir "Historique" ci-dessus pour le détail du bug (diagnostiqué le 2026-07-31, badge NFC
inutilisable en prod à cause du contenu mixte HTTPS/WS) et du correctif (bascule vers Supabase
Realtime Broadcast, `emettre_signal_nfc`). **Code réécrit le 2026-08-18** (migration
`20260818000000_pointage_nfc_broadcast.sql`, `nfc-bridge/nfc_bridge.py`,
`_ptgNfcConnect`/`_badgeListen` dans `index.html`, champ Réglages remplacé par une case à cocher)
— **retester en conditions réelles (lecteur + prod HTTPS) avant de considérer ce chantier
terminé**, le correctif n'avait pas encore été validé au moment de la rédaction de cette section.

## Déploiement

- GitHub : `hugmsg/rh-metal` (remote `origin`)
- Vercel : projet `rh-metal` (org `team_uPmVcYzs3RdC3pi3qHQmQ6r0`, lié via `.vercel/project.json`)
- Chaque `git push` sur `main` redéploie automatiquement sur Vercel (30-60s)
- Pas de build command, pas de framework (`Other`), output dir = racine
- HTTPS fourni par Vercel (requis pour le service worker)

## Workflow habituel

```bash
cd "G:\Mon Drive\Pro SONOTRAD\RH\RH-Metal"
git add .
git commit -m "fix/feat: description"
git push
```

Tout est dans `index.html` : pour une modif, chercher la fonction JS ou la
section HTML concernée directement dans ce fichier (pas de fichiers séparés
à synchroniser).

## Points d'attention

- Toujours vérifier/incrémenter le SMIC dans `DEFAULT_SETTINGS` si une
  revalorisation officielle intervient — ne pas l'auto-ajuster sans confirmation.
  Les valeurs CCM (`DEFAULT_CCM`) ne doivent être mises à jour que sur preuve
  d'un accord de branche signé (sinon laisser tel quel, c'est la grille SMH 2024).
- Ne pas casser la rétrocompatibilité `resolveClasse()` (anciens employés
  stockés avec un champ `groupe` sans `classe_num`).
- Le service worker (`sw.js`) doit être versionné/invalidé si on change des
  assets cachés, sinon les utilisateurs PWA restent sur une vieille version
  (voir historique de fix "cache PWA").
- Ne pas committer les fichiers `rh-metal-backup-*.json` (données RH réelles).
- Ne jamais forcer `.toUpperCase()`/normaliser la casse du nom/prénom à la
  sauvegarde d'un salarié (voir convention de casse plus haut).
- Pour toute migration Supabase touchant `employes`, `conges`, ou une future
  table partagée : l'appliquer via MCP Supabase (`apply_migration`) **et**
  ajouter le fichier correspondant dans `supabase/migrations/` (traçabilité,
  pas de rejeu automatique). Vérifier si une modif de schéma affecte aussi
  sonotrad-pwa (repo séparé, voir mémoire `sonotrad-pwa-gas-deployment` pour
  les pièges de déploiement de ce côté-là si jamais il faut y toucher).
