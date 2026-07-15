# RH Sonotrad — Tableau de bord RH Métallurgie

## C'est quoi

PWA mono-fichier (HTML+CSS+JS dans `index.html`, ~98 Ko, pas de build, pas de
framework, pas de `node_modules`) pour gérer l'équipe d'une entreprise relevant
de la **Convention Collective de la Métallurgie (IDCC 3248)**. Permet de
suivre l'effectif, calculer les salaires/coûts employeur, vérifier la
conformité aux minima de branche et simuler des scénarios RH.

Titre affiché dans l'app : **RH Sonotrad** (logo bandeau). Titre HTML/PWA :
"Tableau de Bord RH — Convention Métallurgie" / "RH Métal".

## Fichiers

- `index.html` — toute l'app (HTML + CSS + JS inline, un seul fichier)
- `manifest.json` — config PWA (nom, icône, thème)
- `sw.js` — service worker (cache offline)
- `icon.svg` — icône de l'app
- `PROMPT_CLAUDE_CODE.md` — notes de setup initial (git/GitHub/Vercel), garder comme historique, ne pas dupliquer son contenu ici
- `rh-metal-backup-*.json` — exports de sauvegarde manuels (gitignorés, ne pas committer)

## Stockage des données

**Tout est en `localStorage` du navigateur**, rien côté serveur :
- `rh_employees` — liste des salariés
- `rh_settings` — paramètres généraux (SMIC, charges, etc.)
- `rh_ccm` — grille des classes CCM (peut être personnalisée par l'utilisateur)
- `rh_theme` — thème clair/sombre

Le déploiement (git push / Vercel) ne touche jamais aux données utilisateur.
Sauvegarde/restauration via export/import JSON (`exportJSON()` / `importJSON()`
dans `index.html`, `BACKUP_VERSION` à incrémenter si le format change).

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
  (table salariés, filtres, actions groupées), **Optimisation** (simulateurs :
  hausse SMIC, heures sup, effectif/ETP, analyse conformité CCM, scénarios
  comparatifs), **Paramètres** (taux/grille CCM, sauvegarde JSON).
- PWA : thème clair/sombre, cartes mobile pour l'équipe (vs table desktop),
  gestion de la safe-area iOS (encoche/barre de statut) en mode standalone.

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
