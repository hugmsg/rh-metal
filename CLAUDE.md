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
- `supabase/functions/` — Edge Functions (première depuis le 2026-08-24 : `activer-portail`, création de comptes Supabase Auth), même logique que les migrations : copie source/traçabilité, déployées directement via MCP Supabase (`deploy_edge_function`), ce dossier n'est pas rejoué automatiquement
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
- **Distinct du compte "Sonotrad-Utilisateurs"** (connexion à l'appli
  sonotrad-pwa elle-même — logistique/stock/BCB/LOXAM, onglet
  Administration) : ce compte-là vit dans une feuille Google Sheets
  séparée (`sonotrad-scripts/masterfile/pwa_master.js`), reliée à
  `employes` seulement via `employeId` pour affichage, **sans aucune
  synchro** avec `date_sortie`/`actif`. Vérifié le 2026-08-21 (cas Anaïs
  Breteau : contrat terminé mais toujours "activé" côté Administration,
  malgré le correctif ci-dessus qui ne concerne que le badge/PIN de
  pointage). Désactiver ce compte-là reste manuel et non destructif
  (`_toggleUser` ne touche jamais le PIN) — amélioration envisagée mais
  pas commencée : documentée dans `sonotrad-scripts/CLAUDE.md`.
- **Corbeille + purge définitive** (2026-08-21, migration
  `20260821160641`) : `supprimer_employe_rh` ne faisait qu'un soft-delete
  (`supprime=true`) — un salarié supprimé devenait invisible dans Équipe
  (`get_employes_rh` filtre `supprime=false`) mais restait bien réel en
  base, sans aucun moyen depuis l'app de finir le nettoyage (cas réel :
  2 comptes "test" trouvés uniquement visibles dans Contrôle, sans trace
  côté Équipe). Ajout de `get_employes_supprimes_rh()` (liste les
  `supprime=true`, section "🗑 Corbeille" dans Équipe, chargée à la
  demande) et `purger_employe_rh(p_id)` — refuse tout salarié pas déjà
  dans la corbeille (garde-fou anti-purge-directe d'un actif), puis
  nettoie explicitement `heures_corrections`/`jours_statut`/
  `semaines_validees`/`heures_journalieres`/`pointages`/`conges` avant de
  supprimer la ligne `employes` (ne dépend pas des FK `employe_id`
  incohérentes en base — voir migration pour le détail). Irréversible,
  confirmation explicite côté UI.
- **Bandeau contrats expirés + statut visuel** (2026-08-24) : l'éligibilité
  au badge/PIN était déjà bloquée côté Supabase (point ci-dessus), mais
  rien côté Équipe ne signalait qu'un contrat était arrivé à échéance —
  le cas Breteau n'avait été repéré que par hasard. `renderEquipeAlertesContrats()`
  (`app.js`, appelée en fin de `renderTable()`, purement local — aucun appel
  Supabase de plus) affiche un bandeau rouge listant les salariés dont
  `date_sortie` est passée mais toujours présents dans Équipe (pas encore
  archivés via la Corbeille), avec un bouton "Traiter" qui ouvre directement
  le formulaire "Nouveau contrat" (voir section dédiée ci-dessous) pour
  renouveler, passer en CDI, ou — supprimer si la fin est définitive (via
  la Corbeille, pas depuis ce bandeau). Colonne "Sortie" : une date passée
  s'affiche en rouge gras avec ⛔, une date future reste en gris neutre
  (avant : les deux étaient rendues identiquement en rouge).

### Historique des contrats (2026-08-24)

Jusqu'ici un renouvellement de CDD ou un passage en CDI se traitait en
écrasant `date_sortie` sur `employes` — pas d'historique, et le même geste
servait aussi bien à corriger une date qu'à changer réellement de contrat
(cadré avec Hugo avant de coder, cf. le cas concret Breteau discuté pour le
chantier éligibilité ci-dessus).

**Table `contrats`** (rh-metal uniquement, pas partagée avec sonotrad-pwa) :
`id, employe_id, date_debut, date_fin (NULL = en cours), type_contrat,
classe_num, taux_horaire, heures_semaine, heures_sup_semaine, poste,
forfait_jour, forfait_jours_an, created_at`. Même pattern RLS que
`employes`/`conges` (activé, aucune policy — accès uniquement via RPC
`SECURITY DEFINER`). `forfait_jour`/`forfait_jours_an` : colonnes réservées
sur demande explicite de Hugo, **calcul de paie associé pas implémenté** —
aucun salarié actuel n'est au forfait jour (modèle heures/semaine partout).

**Synchronisation vers `employes`** : un trigger (`sync_employe_depuis_contrats`,
`AFTER INSERT OR UPDATE OR DELETE ON contrats`) recopie le "contrat courant"
(celui dont `date_debut` est la plus récente) sur les colonnes
correspondantes de `employes` à chaque changement. `employes` reste donc la
seule table lue ailleurs dans l'app (paie, dashboard, RPC de pointage
partagées avec sonotrad-pwa) — rien d'autre à modifier côté lecture.
**Exception : `date_entree`** n'est pas la date du contrat courant mais le
**MIN(date_debut)** sur tout l'historique (ancienneté réelle) — sinon un
renouvellement casserait le prorata de `calcSoldeCP` (module Congés).

**Deux façons de faire évoluer un contrat**, distinguées explicitement pour
ne pas reproduire l'ambiguïté qui a causé le bug Breteau :
- **✏️ Modifier** (fiche existante) → `upsert_employe_rh` met à jour le
  contrat courant **en place** (classe, taux, heures, poste, type, et
  `date_sortie` pour clôturer/corriger la fin — jamais `date_entree`, plus
  pris en compte dès qu'un contrat existe). Pour une augmentation, un
  changement de classe/poste : **pas** un nouvel événement contractuel,
  aucune nouvelle ligne. `date_entree` devient en lecture seule dans la
  modale dès qu'un salarié a un id réel (ancienneté gérée uniquement par le
  trigger) — éditable seulement à la création (1er contrat).
- **🔄 Nouveau contrat** (icône dédiée sur chaque ligne Équipe, bouton dans
  la modale, et bouton "Traiter" du bandeau contrats expirés) →
  `upsert_contrat_rh` **insère toujours une nouvelle ligne** ; l'ancien
  contrat reste intact dans l'historique. C'est le seul chemin pour un
  vrai renouvellement, un passage CDD→CDI, ou une reprise saisonnière.

`get_contrats_rh(p_employe_id)` alimente la section "📄 Historique des
contrats" de la modale (le plus récent en premier, "Actuel" sur la 1ère
ligne). `purger_employe_rh` nettoie aussi `contrats` avant de supprimer
`employes` (en plus de la contrainte `ON DELETE CASCADE`, par choix
explicite de tout nettoyer soi-même, comme les autres tables liées).

**"👁 Vu" sur le bandeau contrats expirés (2026-08-24, même session).**
Un salarié non renouvelé mais susceptible de revenir (saisonnier...) ne
doit **pas** passer par la Corbeille (= départ définitif, irréversible une
fois purgé) — juste rester tel quel, prêt pour un "🔄 Nouveau contrat" le
jour venu. Mais le bandeau chantier 3 nagait indéfiniment sans option
intermédiaire. Plutôt qu'un nouveau statut (jugé inutilement complexe),
simple accusé de réception par contrat : colonne `contrats.alerte_vue`
(migration `20260824150000`), bouton "👁 Vu" dans le bandeau
(`marquerAlerteContratVue`, RPC `marquer_alerte_contrat_vue_rh`) qui
retire ce salarié du bandeau sans toucher à son contrat — un petit 👁
cliquable apparaît alors dans la colonne "Sortie" pour annuler
(re-signaler). Se réinitialise tout seul dès qu'un nouveau contrat est créé
(`alerte_vue` redémarre à `false` par défaut sur chaque nouvelle ligne).

**Migration** a aussi supprimé un doublon mort de `upsert_employe_rh`
(ancien overload à 12 arguments, laissé par le `CREATE OR REPLACE` de
Phase 3 "profils complets" qui avait créé un nouvel overload à 15
arguments au lieu de remplacer l'existant, la signature ayant changé —
`app.js` n'appelait déjà que la version à 15 arguments).

### Phase 3 SIRH — Profils complets & portail salarié

**Profils complets, 1ère étape (2026-08-21) — coordonnées personnelles.**
Section dédiée dans la modale Équipe (`f-adresse`/`f-tel-perso`/
`f-email-perso`), optionnelle, jamais affichée dans le tableau/les cartes
de l'onglet (comme `notes`, modale uniquement). Contact d'urgence pas
retenu. **Documents RH (contrat/RIB/pièce d'identité) : écarté (décision
Hugo, 2026-08-24)** — l'espace de stockage fichiers du plan Supabase Free
(1 Go) est jugé trop limité pour ce chantier ; à reconsidérer seulement en
cas de passage à un plan payant.

**Chantier 0 — authentification RH (2026-08-24) : livré, prérequis au
portail.** Jusqu'ici la partie RH n'avait aucune authentification —
protégée uniquement par la confidentialité de l'URL. Le portail salarié
oblige à partager cette même URL avec tous les salariés, ce qui aurait
exposé de fait toute l'app RH à quiconque retire un simple paramètre
`?portail=1` de la barre d'adresse (trivial). Ajout d'une vraie session
Supabase Auth des deux côtés (`initAuthGate()`, `app.js`) : rien ne
s'affiche (`#header`/`.bottom-nav`/`.main` masqués via `body.auth-pending`)
tant que la session n'est pas résolue. Ce qui s'affiche ensuite dépend du
**rôle résolu côté serveur** (`get_mon_role_rh()`, via `auth.uid()` →
`employes.auth_user_id`/`is_rh_admin` — jamais un paramètre d'URL) :
RH complet si `is_rh_admin`, sinon écran "accès non autorisé" en
attendant que le portail lui-même soit construit. **Le mode kiosque
(`?kiosk=1`) n'est pas concerné** : il contourne entièrement cet écran
(`KIOSK_MODE` court-circuite `initAuthGate`), il utilise déjà des RPC
anonymes dédiées (`authentifier_par_pin`/`pointer_par_nfc`) — un
Raspberry Pi en salle de pause ne peut pas rester connecté en
permanence avec un compte personnel.

Nouvelle brique technique : une **Edge Function** (`activer-portail`,
`supabase/functions/activer-portail/`, déployée via MCP Supabase) crée le
compte Supabase Auth d'un salarié et lui envoie l'invitation par email
(`email_perso`) — impossible depuis une RPC SQL classique (nécessite la
clé `service_role`, l'API Admin Auth n'est pas accessible en SQL). Premier
provisioning côté projet : compte de Hugo bootstrappé par un appel direct
à l'Edge Function (avant que l'app ne soit protégée, seul cas où l'appel
est autorisé sans authentification — l'Edge Function vérifie elle-même
qu'aucun admin n'a encore de compte lié avant d'accepter un appel anonyme ;
ensuite tout appel doit prouver un rôle `is_rh_admin` via son JWT).
**Bouton "Activer l'accès portail" (2026-08-25, livré)** : section "🔑
Portail salarié" dans la fiche salarié (`app.js`, `renderPortailStatus()`/
`activerPortailAccess()`), affichée seulement en édition. Trois états :
email personnel manquant (bouton désactivé, message d'aide) / non activé
(bouton, appelle `activer-portail` avec le JWT admin courant en
`Authorization: Bearer`) / déjà activé (`portail_actif`, badge ✅) — ce
booléen est exposé par `get_employes_rh()` (`auth_user_id IS NOT NULL`,
jamais l'UID lui-même) et **doit être recopié explicitement** dans
`mapSupabaseRowToEmployee()` comme tout autre champ Supabase consommé
côté client (bug réel du 2026-08-25 : champ oublié dans l'allowlist de
cette fonction, bouton "Activer" restait affiché même une fois le compte
déjà activé — corrigé le jour même).

**Portail salarié — écrans de consultation (2026-08-25, livré).**
Authentification par email + mot de passe (Supabase Auth, pas de
réutilisation du PIN kiosque — trop faible pour protéger des données
personnelles). **Périmètre fixé le 2026-08-24** : consultation
uniquement — ses propres pointages/heures et son solde de congés. La
demande de congé en ligne (romprait le modèle actuel "saisie RH
uniquement" du module Congés, voir plus bas — nécessiterait un flux de
validation RH) reste une évolution possible mais **pas dans le périmètre
de départ**.

Un compte lié (`auth_user_id`) mais pas `is_rh_admin` est routé par
`resolveRoleAndBoot()` vers `bootPortalSalarie()` (`app.js`) — un écran
séparé (`#portal-view`, `index.html`), jamais l'app RH complète ni son
`showTab()`. Deux sous-onglets :
- **Mes heures** (`portalLoadHeures`) — navigation mois par mois, appelle
  `get_mes_heures_rh(p_debut, p_fin)`, équivalent lecture seule de
  Rapports (badgeages groupés par intervalles via `_ptgIntervals`,
  corrections admin affichées avec leur commentaire, total du mois).
- **Mes congés** (`portalLoadConges`) — appelle `get_mes_conges_rh()` puis
  réutilise directement `calcSoldeCP()`/`sommeConges()` (variable globale
  `conges`, sans risque de collision : le portail et l'app RH complète ne
  bootent jamais dans la même session) pour le solde CP + historique des
  demandes.

**Sécurité — pourquoi des RPC dédiées plutôt qu'un accès direct aux
tables.** `pointages`/`heures_journalieres`/`heures_corrections` ont une
policy `anon SELECT true` (voulue pour le kiosque, sans login, voir
section Pointage plus bas) — un accès direct depuis le portail aurait
exposé les heures de **tous** les salariés à n'importe quel compte
portail connecté (un filtrage uniquement côté client se contourne
trivialement depuis les devtools). D'où `get_mes_heures_rh`/
`get_mes_conges_rh`, `SECURITY DEFINER`, qui résolvent l'employé appelant
via `auth.uid()` côté serveur — jamais un id transmis par le client, même
principe que `get_mon_role_rh()`.

**Piège CSS découvert en testant l'écran (2026-08-25)** : la règle
globale `table{min-width:1100px}` (`style.css`, pensée pour le tableau
Équipe en desktop, où chaque colonne a besoin de place) cible **toute**
balise `<table>` de la page — elle forçait aussi le tableau "Mes heures"
du portail (pensé pour un écran étroit/mobile) à déborder de son
conteneur. Corrigé en ajoutant `min-width:0` à l'inline style de ce
tableau spécifique (l'inline style gagne sur la règle globale). Si un
futur tableau hors du contexte Équipe déborde inexplicablement, vérifier
cette règle globale avant de chercher ailleurs.

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

**Régression RLS anon-only trouvée le 2026-08-28** (repérée par Hugo :
"la semaine n'est pas verrouillée" alors qu'un ajout de pointage se
faisait bloquer par "semaine verrouillée"). Cause : le chantier
authentification (24/08, voir "Chantier 0" plus haut) fait qu'un admin RH
connecté utilise le rôle Postgres `authenticated`, plus seulement `anon`
comme avant — mais les policies SELECT de `heures_corrections`/
`jours_statut`/`semaines_validees` ne visaient que `anon` (seul rôle qui
existait quand elles ont été écrites). Un admin connecté obtenait donc
silencieusement 0 ligne sur un accès direct (`db.from(...)`, pas via RPC)
à ces 3 tables — utilisées justement en accès direct par Rapports et les
4 vues de Contrôle. Aucun risque de sécurité : les RPC d'écriture
(`SECURITY DEFINER`) appliquent `_semaine_est_verrouillee()` côté serveur
indépendamment de RLS, d'où le symptôme révélateur (blocage réel à
l'écriture, mais bandeau affichant "non verrouillée" puisque la lecture
du statut, elle, était silencieusement vide). Corrigé (migration
`20260828070000`, `ALTER POLICY ... TO anon, authenticated`) sur ces 3
tables, plus `heures_journalieres`/`pointages` par cohérence (celles-ci
restaient lisibles admin via les vues `heures_rapport_vue`/
`pointages_rapport_vue` — une vue Postgres s'exécute par défaut avec les
droits de son propriétaire, pas de l'appelant, donc contournait RLS sans
que ce soit voulu ; mieux vaut ne pas dépendre de cet effet de bord).
**Piège pour toute future table RH accédée en direct (`db.from`, pas
RPC)** : si elle doit être lisible à la fois par le kiosque (anon, sans
login) et par l'admin RH (authenticated, depuis le chantier auth du
24/08), sa policy SELECT doit explicitement viser `TO anon, authenticated`
— `anon` seul ne suffit plus pour l'admin.

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
