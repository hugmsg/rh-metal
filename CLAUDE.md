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
- `nfc-bridge/` — pont Python (lecteur PC/SC → WebSocket) à déployer manuellement sur le Raspberry Pi kiosque, voir son `README.md` et la section Module Pointage — Badge NFC plus bas
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
- `RH-Metal/supabase/migrations/20260730000000_get_employes_rh_has_badge.sql`
  — ajoute `has_badge` (booléen, jamais l'UID) au retour de
  `get_employes_rh()`.

**Associer un badge** (onglet Équipe) : bouton 📡/📶 par salarié →
`openBadgeModal(id)` → "Écouter le prochain scan" ouvre une WebSocket
temporaire vers `settings.nfcBridgeUrl` (Réglages → "Adresse du pont NFC"),
timeout 30s. Fonctionne depuis **n'importe quel poste du réseau local** —
pas besoin d'être physiquement devant le Pi (décision Hugo : le pont écoute
sur `0.0.0.0`, pas seulement en loopback).

**Le pont** (`nfc-bridge/`, voir son `README.md`) est un service Python
(`pyscard` + `websockets`) qui tourne en systemd sur le Raspberry Pi,
diffuse `{"uid": "..."}` à tous les navigateurs connectés dès qu'un badge
est scanné. Déploiement 100% manuel (pas d'accès SSH automatisé depuis
l'environnement de dev) — le dossier du repo est la copie source/traçabilité,
pas un mécanisme de déploiement.

**Mode kiosque strict (`?kiosk=1`)** : le Raspberry Pi ne doit **jamais**
afficher autre chose que l'écran Pointage > Kiosque — aucune donnée RH
(salariés, congés, paramètres) ne doit être accessible depuis cet appareil
physique. `KIOSK_MODE` (déclaré en tête du `<script>`) verrouille `showTab()`
sur `'pointage'` et masque toute la navigation via la classe CSS
`body.kiosk-mode`. Le Pi doit être configuré en Chromium `--kiosk` pointé
sur `https://rh-metal.vercel.app/?kiosk=1` — jamais l'URL sans ce paramètre.
Le PC de Hugo garde l'accès admin complet via l'URL normale (sans
`?kiosk=1`).

#### ⚠️ BUG CONNU (2026-07-31) — le badge NFC ne fonctionne PAS en prod (HTTPS)

**Statut : diagnostiqué, correctif proposé mais pas encore implémenté** (Hugo a demandé de
documenter et de ne rien changer pour l'instant — reprendre ce chantier à la prochaine session).

**Symptôme** : testé en conditions réelles le 2026-07-31 — lecteur ACR122U branché sur le PC de
Hugo (fonctionne très bien, aucun besoin du Raspberry Pi pour développer/tester : PC/SC est
nativement supporté par Windows, `pyscard` détecte le lecteur sans souci). Le pont
(`nfc_bridge.py`) tourne, lit bien les badges, diffuse l'UID correctement. **En local
(`http://localhost:...`), tout le flux marche de bout en bout** (validé avec un vrai badge :
scan → RPC `pointer_par_nfc` → "en service" affiché). **Mais en prod
(`https://rh-metal.vercel.app`), la connexion WebSocket kiosque → pont reste bloquée
indéfiniment en `CONNECTING`**, jamais d'ouverture — reproduit et confirmé via
`new WebSocket('ws://127.0.0.1:8765')` exécuté directement dans la page prod (4s de timeout,
`readyState` reste à 0, aucun événement `open`/`error`/`close`).

**Cause** : contenu mixte (*mixed content*). `https://rh-metal.vercel.app` est chargée en HTTPS ;
le pont écoute en `ws://` (non chiffré). Chrome bloque silencieusement ce type de connexion
active depuis une page HTTPS — **y compris vers `127.0.0.1`** (l'exemption "loopback = origine de
confiance" ne s'applique pas ici, contrairement à ce qu'on aurait pu supposer). Ça explique
pourquoi le test en local (page servie en `http://`, donc pas de contenu mixte) fonctionnait
parfaitement alors que la même adresse de pont échoue en prod.

**Correctif recommandé (pas encore fait)** : remplacer le serveur WebSocket maison du pont par un
canal **Supabase Realtime Broadcast** — même mécanisme déjà utilisé pour `employes-changes`
(voir [[project_shared_employes_table]]). Le pont Python pousserait chaque scan vers un canal
Supabase (ex. `nfc-badge-scans`) au lieu d'ouvrir son propre serveur ; le kiosque et l'écran
Équipe s'abonneraient à ce canal via le client `window.SupabaseDB` déjà chargé dans la page.
Avantages : Supabase est déjà en HTTPS/WSS avec un vrai certificat (aucun souci de contenu mixte,
comme pour toutes les autres souscriptions realtime déjà en place) ; plus besoin d'exposer un
port sur le réseau local ni de champ "Adresse du pont NFC" à maintenir (IP qui peut changer) ;
fonctionnerait même hors du réseau local, sans rien configurer de plus côté Pi.

**Ce que ça implique de changer** (à faire à la prochaine session, si Hugo confirme cette
direction) :
- `nfc-bridge/nfc_bridge.py` : remplacer `websockets.serve(...)` par un appel HTTP (ou le SDK
  `supabase-py`) qui pousse sur le canal Realtime Broadcast à chaque badge détecté — plus besoin
  de gérer une liste de clients connectés côté pont.
- `index.html` : `_ptgNfcConnect()`/`_ptgNfcOnScan()` (kiosque) et `_badgeListen()` (modale Équipe)
  à réécrire pour utiliser `db.channel('nfc-badge-scans').on('broadcast', ...)` au lieu d'un
  `new WebSocket(settings.nfcBridgeUrl)`.
- Réglages : le champ "Adresse du pont NFC" (`s-nfc-bridge`/`settings.nfcBridgeUrl`) devient
  obsolète, à retirer (plus rien à configurer côté adresse — seul le pont doit connaître l'URL/clé
  Supabase, déjà en dur dans le code comme le reste de l'app).
- `nfc-bridge/README.md` : mettre à jour les instructions en conséquence.
- Point de vigilance : garder le même anti-doublon/debounce qu'aujourd'hui côté pont (un badge
  qui reste posé sur le lecteur ne doit pas spammer le canal).

**Ce qui reste valable et n'a pas besoin d'être retouché** : les 3 RPC Supabase
(`pointer_par_nfc`, `associer_badge_nfc`, `dissocier_badge_nfc`), le mode `?kiosk=1`, la lecture
matérielle PC/SC elle-même (`pyscard`, déjà testée et fonctionnelle) — seul le **transport** entre
le pont et le navigateur doit changer.

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
