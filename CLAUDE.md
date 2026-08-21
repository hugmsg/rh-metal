# RH Sonotrad — Tableau de bord RH Métallurgie

## C'est quoi

PWA sans build (`index.html`/`app.js`/`style.css` en HTML+CSS+JS servis
tels quels, pas de framework, pas de `node_modules` — voir "Points
d'attention" pour l'historique mono-fichier) pour gérer l'équipe d'une entreprise relevant
de la **Convention Collective de la Métallurgie (IDCC 3248)**. Permet de
suivre l'effectif, calculer les salaires/coûts employeur, vérifier la
conformité aux minima de branche, simuler des scénarios RH, pointer les
horaires (kiosque PIN) et suivre les congés/absences. En transformation
progressive vers un SIRH complet (voir mémoire `project-supabase-migration`).

Titre affiché dans l'app : **RH Sonotrad** (logo bandeau). Titre HTML/PWA :
"Tableau de Bord RH — Convention Métallurgie" / "RH Métal".

## Fichiers

- `index.html` — structure HTML de l'app (markup des onglets/modales)
- `app.js` — toute la logique JS de l'app (extrait de `index.html` le
  2026-08-21 — toujours **pas de build** : simple `<script src="app.js">`,
  Vercel sert le fichier tel quel comme avant)
- `style.css` — tout le CSS (même extraction, `<link rel="stylesheet">`)
- `manifest.json` — config PWA (nom, icône, thème)
- `sw.js` — service worker (cache offline) — bumper `CACHE_NAME` si `app.js`,
  `style.css` ou tout autre asset listé dans `SHELL`/`STATIC_ASSETS` change
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
(`exportJSON()` / `importJSON()` dans `app.js`, `BACKUP_VERSION` à
incrémenter si le format change) — **ne couvre pas** les congés (Supabase
uniquement, pas de fallback local).

**Stratégie de secours (vérifié le 2026-08-21)** : le plan Supabase de ce
projet est **Free** — aucune sauvegarde automatique côté base (ni PITR ni
backup quotidien, ces deux fonctionnalités n'existent qu'à partir du plan
Pro). L'export JSON ci-dessus est donc la **seule** sauvegarde disponible
pour salariés/paramètres/CCM — et rien ne sauvegarde les congés/pointages
(uniquement en base, pas d'export). Un export unique du 17/06 était resté
figé faute de rappel ; `renderLastBackupInfo()` (appelé par `renderSettings()`)
affiche désormais "Dernière sauvegarde : il y a Xj" dans l'onglet
Paramètres (`localStorage.rh_last_backup_at`, mis à jour à chaque
`exportJSON()`), en rouge au-delà de 30 jours — export mensuel recommandé.
Si le volume de données ou la criticité augmente, reconsidérer un passage
au plan Pro (backups quotidiens inclus) plutôt que complexifier ce nudge.

### Table Supabase partagée `employes` — contrat avec sonotrad-pwa

Voir mémoire `shared-employes-table-sonotrad-rhmetal` pour le détail complet.
Points essentiels à connaître avant de toucher à ce périmètre :

- **Division des colonnes** : sonotrad-pwa possède `pin_hash`/`nfc_uid`/`actif`
  (kiosque Pointage) ; rh-metal possède `classe_num`/`taux_horaire`/`heures_semaine`/
  `heures_sup_semaine`/`date_entree`/`date_sortie`/`type_contrat`/`poste`/`notes`/`supprime`/
  `adresse`/`telephone_perso`/`email_perso` (coordonnées personnelles, ajoutées le
  2026-08-21, Phase 3 "profils complets" — voir plus bas).
- **Casse/accents** : convention retenue = **casse normale + accents** (ex.
  "Breteau"/"Anaïs"), pas de TOUT-MAJUSCULE. `saveEmployee()` ne doit **jamais**
  forcer `.toUpperCase()` sur le nom — ça a déjà cassé une donnée réelle en
  prod une fois (régression corrigée le 2026-07-28).
- **Clé de correspondance** : par `id` en priorité (`p_id` optionnel sur les
  RPC `upsert_employe_rh`/`upsert_employe_pointage`), comparaison nom/prénom
  normalisée (casse+accents ignorés) en repli uniquement (`unaccent(lower(...))`
  côté `upsert_employe_rh`, migration `20260821100838` — la fonction violait
  cette règle depuis sa création le 2026-07-27 jusqu'à ce correctif, trouvé
  lors d'un audit le 2026-08-21 ; `upsert_employe_pointage` côté sonotrad-pwa
  a le même défaut, pas corrigé, autre repo) — jamais de
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
- **Éligibilité au pointage = condition calculée, pas le seul flag `actif`**
  (corrigé le 2026-08-21, migration `20260821152633`, suite à un cas réel :
  Anaïs Breteau, CDD terminé le 31/07, pouvait encore badger 3 semaines
  après faute d'avoir `actif=false`). `authentifier_par_pin`,
  `pointer_par_nfc` et `employes_actifs_vue` filtrent désormais sur
  `actif = true AND supprime = false AND (date_sortie IS NULL OR
  date_sortie >= current_date)` — jamais `actif` seul. Avantage : un
  renouvellement de CDD, un passage en CDI ou une reprise saisonnière se
  traite en changeant juste `date_sortie` côté fiche RH, sans rien
  réactiver manuellement (PIN/badge/coordonnées jamais touchés). RPC
  partagées avec sonotrad-pwa — corrige le même trou côté leur kiosque.

### Phase 3 SIRH — Profils complets & portail salarié

**Profils complets, 1ère étape (2026-08-21) — coordonnées personnelles.**
Section dédiée dans la modale Équipe (`f-adresse`/`f-tel-perso`/
`f-email-perso`), optionnelle, jamais affichée dans le tableau/les cartes
de l'onglet (comme `notes`, modale uniquement). Étapes suivantes possibles
si le besoin se confirme : contact d'urgence (pas retenu pour l'instant),
documents RH — contrat/RIB/pièce d'identité (le plan Supabase Free offre
1 Go de stockage fichiers, largement suffisant pour cette taille d'équipe,
donc le coût de stockage n'est pas un frein ; ce qui reste à concevoir
avant de les ajouter, c'est le contrôle d'accès — bucket + policies RLS
sur `storage.objects` — un chantier à part, pas juste des colonnes texte).

**Portail salarié — cadré mais pas commencé.** Décisions prises le
2026-08-21 pour quand ce chantier démarrera : authentification par email +
mot de passe (Supabase Auth, pas de réutilisation du PIN kiosque — trop
faible pour protéger des données personnelles) ; le salarié pourrait
consulter ses propres pointages, consulter son solde de congés, et poser
une demande de congé (romprait le modèle actuel "saisie RH uniquement" du
module Congés, voir plus bas — nécessitera un flux de validation RH).
Priorisé après les profils complets (plus petit chantier, aucune
authentification à concevoir).

## Logique métier clé (dans `app.js`)

- `DEFAULT_CCM` (~ligne 24) — grille des **18 classes CCM regroupées en 9
  groupes A→I**, avec SMH annuel/mensuel et taux horaire mini par classe.
  Source : UIMM / gestionsociale.fr, grille SMH 2024 toujours en vigueur en
  2026 (pas de revalorisation de branche signée en 2025 au moment de l'écriture).
- `DEFAULT_SETTINGS` (~ligne 10) — SMIC horaire (12,31 € au 1er juin 2026),
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
  (kiosque PIN — Entrée/Sortie uniquement, suivi du jour, rapports avec
  corrections d'heures, contrôle hebdomadaire verrouillable — connecté aux
  tables `pointages`/`heures_journalieres`/`heures_corrections`/
  `jours_statut`/`semaines_validees`, détail plus bas), **Congés** (solde CP par salarié,
  historique des absences — voir plus bas), **Paramètres** (taux/grille CCM,
  sauvegarde JSON).
- PWA : thème clair/sombre, cartes mobile pour l'équipe (vs table desktop),
  gestion de la safe-area iOS (encoche/barre de statut) en mode standalone.

### Module Congés (onglet Congés)

- `countJoursOuvres(debut, fin)` — décompte lundi-vendredi inclus (convention
  **jours ouvrés**, pas jours ouvrables — choix explicite de l'utilisateur).
  Ne déduit pas les jours fériés — voir "Limitations connues".
- `getCpPeriod()` — période de référence légale CP : 1er juin N-1 → 31 mai N.
- `calcSoldeCP(emp)` — acquisition **25j ouvrés/an** (équivalent légal des
  30j ouvrables), au prorata du temps de présence depuis `date_entree` dans
  la période en cours, moins les CP déjà pris sur la période — voir
  "Limitations connues" (absences longues non exclues du calcul).
- 4 types de congé : `cp` (avec solde/acquisition), `maladie`,
  `evenement_familial` (avec champ `motif` libre), `sans_solde` — ces 3
  derniers sont juste **déclarés** (dates + jours), pas de solde à calculer.
- Pas de demande côté salarié pour l'instant (choix explicite) — saisie
  RH uniquement dans cet onglet. Un futur portail salarié (cadré mais pas
  commencé, voir section "Phase 3 SIRH" plus haut) pourrait changer ça.

### Module Pointage — Badge NFC (kiosque, 2026-07-30)

Le kiosque Pointage (`_ptg*` dans `app.js`) gère désormais deux moyens
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

**PC de secours (2026-08-18)** : le pont n'a rien de spécifique au
Raspberry Pi (PC/SC nativement supporté par Windows). Un exécutable Windows
autonome (`nfc-bridge/dist/nfc_bridge.exe`, généré via PyInstaller, pas
committé dans git — voir `.gitignore` — mais synchronisé via Google Drive
comme tout le dossier `RH-Metal`) permet de faire tourner le pont sur
n'importe quel PC Windows sans installer Python : double-clic, console
avec messages explicites (détection lecteur en boucle avec pistes de
dépannage, vérification Supabase). Voir `nfc-bridge/README.md` section "PC
de secours" pour l'utilisation ponctuelle et le démarrage automatique
(raccourci dans `shell:startup`). Régénérer l'exe : `pip install
pyinstaller pyscard requests && python -m PyInstaller --onefile --console
--name nfc_bridge nfc_bridge.py`. Procédure en langage simple pour un
collègue non technique en cas de panne du Pi (Hugo absent) :
`nfc-bridge/PROCEDURE_URGENCE.md`.

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

#### Bug contenu mixte HTTPS/WS — CORRIGÉ ET VALIDÉ le 2026-08-18

Voir "Historique" ci-dessus pour le détail du bug (diagnostiqué le 2026-07-31, badge NFC
inutilisable en prod à cause du contenu mixte HTTPS/WS) et du correctif (bascule vers Supabase
Realtime Broadcast, `emettre_signal_nfc`). Code réécrit le 2026-08-18 (migration
`20260818000000_pointage_nfc_broadcast.sql`, `nfc-bridge/nfc_bridge.py`,
`_ptgNfcConnect`/`_badgeListen` dans `app.js`, champ Réglages remplacé par une case à cocher),
**puis testé en conditions réelles le même jour avec un vrai badge ACR122U** : heartbeat reçu en
local ET sur `https://rh-metal.vercel.app` (pastille "Lecteur connecté"), scan réel traité de bout
en bout (ENTREE/SORTIE enregistrées) sur les deux environnements. **Chantier terminé.**

**Bug annexe découvert et corrigé pendant ce test** : avec plusieurs clients abonnés en même
temps au canal `nfc-badge-scans` (kiosque + écran Équipe "Écouter", ou simplement plusieurs
onglets ouverts), un seul scan physique déclenchait un appel `pointer_par_nfc` concurrent par
client — la vérification anti-doublon (5s) n'étant pas atomique, 3 lignes `ENTREE` ont été créées
pour un seul scan lors du test. Corrigé par un verrou transactionnel par salarié
(`pg_advisory_xact_lock`, migration `20260818010000_pointage_nfc_lock.sql`) : re-testé avec 2
onglets simultanément abonnés (local + prod), une seule ligne créée après le correctif.

### Module Pointage — Kiosque simplifié, Rapports, Contrôle (2026-08-19)

**Kiosque** : le sélecteur "Type de pointage" (PIN) ne propose plus que
Entrée/Sortie (boutons Pause début/fin retirés, `index.html` ~ligne 476) —
décision explicite de Hugo : en cas de départs/retours imprévus dans la
journée, la notion de pause au pointage crée plus de problèmes qu'elle
n'en résout. Le badge NFC ne gérait déjà que Entrée/Sortie (voir plus
haut), le PIN s'aligne dessus. Les boutons Pause restent disponibles côté
admin (Suivi du jour > Ajouter) pour les corrections manuelles.

**Calcul des heures (`_sync_heures_journalieres`, trigger sur
`pointages`)** : la durée brute d'une journée est la **somme de chaque
cycle Entrée→Sortie** de la journée (pas juste 1ère entrée/dernière
sortie) — un aller-retour imprévu au milieu de la journée est donc
automatiquement exclu du temps travaillé, sans notion de pause. Corrigé
le 2026-08-19 (migration `20260819123847`) : l'ancien calcul ne déduisait
qu'un forfait de 20 min pour tout écart, quelle que soit sa durée réelle.

**Rapports** (sous-onglet) : colonne "Badgeages" liste chaque intervalle
Entrée→Sortie de la journée avec sa durée (`_ptgIntervals`), plus les
corrections admin. Admin peut ajouter/retirer des heures en correction sur
n'importe quel jour (bouton "✎ Corriger", table `heures_corrections`,
commentaire obligatoire — visible sur le PDF signé par le salarié). PDF :
la police standard jsPDF (WinAnsi) ne rend pas `→`/`⚖` → utilisé `->`/`*`
avec légende à la place (glyphe cassé sinon, type `!'`).

**Contrôle** (sous-onglet, nouveau) : répond au problème des jours
oubliés (Rapports ne montre que les jours avec au moins un pointage).
Quatre écrans (`_ptgControle.mode` : `apercu`/`detail`/`mois`/`jour`,
`_ptgControleReloadCurrent()` recharge celui affiché) :
- **Aperçu mensuel** (accueil) : grille salariés × jours ouvrés du mois,
  inspirée d'un outil du prestataire actuel de Hugo (capture partagée en
  session, pas conservée dans le repo une fois la vue construite). Case
  vide = rien à signaler, code court sinon (CP/MAL/EVT/SS depuis le module
  Congés, F=férié, **`!` rouge = jour ouvré passé sans aucune résolution**
  — le signal recherché pour repérer les trous d'un coup d'œil ; case
  **verte avec le total en petit** si travaillé). Colonne "Sem." (total +
  🔒 si verrouillée, encadrée des deux côtés, fond teinté accent pour ne
  pas ressembler à un jour collé au lundi suivant) après chaque semaine,
  colonne "Mois" à droite. Clic sur une semaine → écran détail ; **clic sur
  le nom d'un salarié → écran mois** (ce salarié, tout le mois) ; **clic
  sur une date en en-tête → écran jour** (tous les salariés, ce jour-là).
- **Détail** (un salarié, une semaine, cartes lundi→vendredi) : pour un
  jour vide, actions "🏖 Férié" / "🗓 Congé" (ouvre `upsert_conge_rh` —
  remplace un ancien statut "Non travaillé" jugé trop vague et déconnecté
  du module Congés, retiré le 2026-08-19) / "✎ Corriger". Un jour avec
  une correction mais sans pointage réel s'affiche comme un jour travaillé
  (Arrivée/Départ à "—"), jamais comme "Rien pointé" — sinon la correction
  restait invisible et les boutons Férié/Congé restaient proposés à tort
  sur un jour déjà traité (bug réel du 2026-08-19, corrigé dans
  `_ptgControleDayCard` **et** dans l'export PDF `ptgControleExport`, qui
  avait le même bug en double). **Verrouillage réel** : "☑ J'ai contrôlé —
  verrouiller cette semaine" (`valider_semaine`) bloque ensuite côté
  serveur toute correction/pointage admin/statut jour/congé qui chevauche
  cette semaine (`_semaine_est_verrouillee`, vérifié dans
  `ajouter_correction_heures`, `admin_add_pointage`, `definir_statut_jour`,
  `upsert_conge_rh`/`supprimer_conge_rh`) — `deverrouiller_semaine`
  toujours disponible, bouton dédié. Une fois verrouillée : export PDF
  dédié (même style que Rapports) + bouton "Salarié suivant".
- **Mois** (un salarié, toutes les semaines du mois à la suite,
  2026-08-21) : réutilise les cartes jour de la vue Détail, un bloc par
  semaine (`_ptgControleWeekBlock`), chacun avec ses propres actions et
  son propre verrouillage/PDF — pas de nouvel écran de saisie, juste
  plusieurs semaines empilées. Accessible en cliquant le nom d'un salarié
  dans l'aperçu mensuel.
- **Jour** (tous les salariés, une date précise, 2026-08-21) : une carte
  par salarié pour ce jour-là (même `_ptgControleDayCard`, titre remplacé
  par le nom du salarié), avec un mini bouton 🔒/🔓 pour verrouiller/
  déverrouiller la semaine de ce salarié directement depuis cette vue
  transversale. **Piège évité à la conception** : la requête charge les
  données de tous les salariés pour la date (pas de filtre `employe_id`
  côté SQL) — sans filtrer par salarié avant de construire chaque carte,
  la fonction de construction des dayRows (indexée par date seule)
  aurait mélangé les pointages/corrections de tout le monde sur la même
  clé.
- Verrouillage/déverrouillage généralisés (`ptgControleValiderFor`/
  `ptgControleDeverrouillerFor`, prennent employé+semaine en paramètre)
  pour fonctionner depuis Mois/Jour, en plus de `ptgControleValider`/
  `ptgControleDeverrouiller` (vue Détail, lisent `_ptgControle.data`).

Nouvelles tables : `heures_corrections`, `jours_statut` (statut manuel —
seul `'ferie'` est encore proposé dans l'UI ; `'non_travaille'` reste
accepté par le schéma pour les lignes déjà créées avant le retrait du
bouton), `semaines_validees` (verrouillage). Pattern RLS identique à
`pointages`/`heures_journalieres` (anon SELECT libre, écritures
uniquement via RPC `SECURITY DEFINER`).

**Piège daté résolu** : `toISOString().slice(0,10)` convertit en UTC avant
de formater — en France l'été (CEST = UTC+2), une date construite à
minuit local tombe la veille en UTC, donc la chaîne "YYYY-MM-DD" obtenue
était décalée d'un jour en arrière (un vendredi affiché comme un
dimanche). Utiliser `_ptgLocalDateStr(d)` (champs locaux du `Date`,
jamais `toISOString()`) pour toute date-string dérivée d'un `Date` local
dans le module Pointage — corrigé dans `_ptgRapportDates`,
`_ptgControleSemaine`, `_ptgControleMoisInfo`, `_ptgMondayStr`,
`_ptgTodayStr`. Le même piège subsiste ailleurs dans `app.js` — voir
"Limitations connues".

**Cadre légal vérifié (CCM IDCC 3248, recherche web du 2026-08-19)** : pas
de dispositif individuel pour "faire des heures pour compenser une
absence future" — seulement une modulation pluriannuelle formelle
(accord d'entreprise, lissage de rémunération). D'où le choix des
corrections/Contrôle en pur suivi interne, sans requalification
automatique en heures supplémentaires ni valeur légale.

**Rafraîchissement live généralisé (2026-08-21)** : un seul canal Supabase
Realtime (`ptg-realtime`, `_ptgSubscribeRealtime()` dans `app.js`, appelé
depuis `ptgShowSubView()` à chaque changement de sous-onglet) écoute
`heures_journalieres`/`heures_corrections`/`jours_statut`/`semaines_validees`
et relance le rechargement du sous-onglet Pointage actuellement affiché —
les 4 (Kiosque/Suivi du jour/Rapports/Contrôle) sont désormais concernés,
avant seuls Kiosque et Suivi du jour l'étaient. Pour Contrôle, le
rechargement live est **ignoré** tant qu'une fenêtre Corriger/Congé est
ouverte (`#ptg-correction-modal`/`#ptg-conge-modal` visibles), pour ne pas
perdre une saisie en cours ni la position à l'écran.

**Bug racine trouvé en vérifiant que ça marchait vraiment** : aucune table
du module Pointage n'était dans la publication `supabase_realtime` (seule
`voyages`, sans rapport, y était) — RLS correct (policy `anon` SELECT sur
les 4 tables) mais sans la publication, `postgres_changes` ne part jamais.
**Les abonnements Realtime déjà existants sur `heures_journalieres`
(Kiosque, Suivi du jour, depuis leur création) n'ont donc jamais réellement
déclenché** : le rafraîchissement observé après un scan/PIN venait
uniquement de `_ptgShowFeedback()` rappelant `_ptgLoadEnService()`
directement côté client, sur le même poste — jamais de Supabase Realtime.
Corrigé par la migration `20260821125311` (`ALTER PUBLICATION
supabase_realtime ADD TABLE ...` sur les 4 tables). Vérifié en prod par un
test direct (écriture/suppression SQL pendant qu'un onglet Contrôle était
ouvert sans y toucher — la cellule s'est mise à jour toute seule dans les
deux sens). **Si un futur ajout Realtime sur une table Pointage/RH semble
ne "rien faire"**, vérifier d'abord `pg_publication_tables` avant de
suspecter le code client — c'est passé inaperçu pendant ~3 semaines ici.

## Limitations connues

Comportements volontairement non gérés ou pas encore corrigés partout — pas
des bugs, mais à garder en tête et à ajuster manuellement au cas par cas si
besoin :

- **`countJoursOuvres(debut, fin)`** (module Congés) ne déduit pas les jours
  fériés (pas de calendrier géré) — si un congé chevauche un férié, ajuster
  le nombre de jours manuellement.
- **`calcSoldeCP(emp)`** (module Congés) n'exclut pas du calcul d'acquisition
  les longues absences maladie/sans solde — l'acquisition légale réelle peut
  différer au-delà d'un certain seuil, à ajuster manuellement si besoin.
- **Rapports** (Pointage) ne liste que les jours ayant au moins une ligne
  `heures_journalieres` — un jour totalement vide (rien pointé, jamais
  résolu) n'y apparaît pas ; utiliser Contrôle pour ces cas.
- **Piège timezone résiduel** : `toISOString().slice(0,10)` décale d'un jour
  en arrière l'été en France (CEST = UTC+2) — corrigé partout dans le module
  Pointage via `_ptgLocalDateStr()` (voir plus haut), mais subsiste ailleurs
  dans `app.js` (noms de fichiers export CSV/sauvegarde JSON, quelques
  dates par défaut, ex. `ptgAddModalShow`). Impact cosmétique seulement (le
  nom du fichier téléchargé) — pas corrigé faute de demande.

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

La logique JS est dans `app.js`, le markup dans `index.html`, le CSS dans
`style.css` (extraits d'un seul `index.html` monolithique le 2026-08-21,
voir "Points d'attention") : pour une modif, chercher la fonction ou la
section directement dans le fichier concerné.

## Points d'attention

- Toujours vérifier/incrémenter le SMIC dans `DEFAULT_SETTINGS` si une
  revalorisation officielle intervient — ne pas l'auto-ajuster sans confirmation.
  Les valeurs CCM (`DEFAULT_CCM`) ne doivent être mises à jour que sur preuve
  d'un accord de branche signé (sinon laisser tel quel, c'est la grille SMH 2024).
- Ne pas casser la rétrocompatibilité `resolveClasse()` (anciens employés
  stockés avec un champ `groupe` sans `classe_num`).
- Le service worker (`sw.js`) doit être versionné/invalidé si on change des
  assets cachés, sinon les utilisateurs PWA restent sur une vieille version
  (voir historique de fix "cache PWA"). `app.js`/`style.css` sont dans
  `SHELL` (réseau-first, comme `index.html`) depuis leur extraction — pas
  dans `STATIC_ASSETS` (cache-first), car ils changent à chaque déploiement.
- **Historique mono-fichier (jusqu'au 2026-08-21)** : jusqu'à cette date,
  tout (HTML+CSS+JS) vivait dans un seul `index.html` de ~5000 lignes —
  choix initial pour la simplicité de déploiement (voir "C'est quoi").
  Extrait en `app.js`/`style.css` le 2026-08-21 (audit RH-Metal, point
  "fichier à surveiller") une fois la taille devenue gênante pour la
  navigation/l'édition — **toujours sans build** : `<link>`/`<script src>`
  classiques, Vercel sert les 3 fichiers tels quels comme avant. Les
  références `~ligne N` dans ce document pointent désormais vers `app.js`
  (logique) ou `index.html` (markup) selon le contexte — si un futur
  découpage plus fin (plusieurs fichiers JS par module) a lieu, les revérifier.
- Ne pas committer les fichiers `rh-metal-backup-*.json` (données RH réelles).
- Ne jamais forcer `.toUpperCase()`/normaliser la casse du nom/prénom à la
  sauvegarde d'un salarié (voir convention de casse plus haut).
- Pour toute migration Supabase touchant `employes`, `conges`, ou une future
  table partagée : l'appliquer via MCP Supabase (`apply_migration`) **et**
  ajouter le fichier correspondant dans `supabase/migrations/` (traçabilité,
  pas de rejeu automatique). Vérifier si une modif de schéma affecte aussi
  sonotrad-pwa (repo séparé, voir mémoire `sonotrad-pwa-gas-deployment` pour
  les pièges de déploiement de ce côté-là si jamais il faut y toucher).
