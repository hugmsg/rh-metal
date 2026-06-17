# Prompt Claude Code — Setup GitHub + Vercel pour RH-Metal

## Contexte du projet

Application web statique (single-page HTML/CSS/JS) de gestion RH pour une entreprise du secteur métallurgie. PWA installable (manifest.json + service worker). Pas de build step, pas de framework, pas de node_modules — juste 4 fichiers statiques.

**Dossier local :** `G:\Mon Drive\Pro SONOTRAD\RH\RH-Metal\`

**Fichiers présents :**
- `index.html` — l'application complète (~88 Ko)
- `manifest.json` — config PWA
- `sw.js` — service worker offline
- `icon.svg` — icône de l'app

## Ce que tu dois faire

### 1. Initialiser le dépôt Git local

Dans le dossier `G:\Mon Drive\Pro SONOTRAD\RH\RH-Metal\` :

```bash
git init
git add .
git commit -m "feat: initial commit — RH Métallurgie dashboard v1"
```

### 2. Créer le dépôt GitHub et pousser

Utilise le GitHub CLI (`gh`). Si `gh` n'est pas installé, installe-le et guide-moi pour l'authentification.

Nom du dépôt : `rh-metal`
Visibilité : **public** (requis pour GitHub Pages gratuit) OU **private** si l'utilisateur a GitHub Pro/Team.

```bash
gh repo create rh-metal --public --source=. --remote=origin --push
```

Si `gh` n'est pas disponible, fournis les instructions Git classiques avec l'URL du repo à créer manuellement sur github.com, et les commandes :
```bash
git remote add origin https://github.com/PSEUDO/rh-metal.git
git branch -M main
git push -u origin main
```

### 3. Déployer sur Vercel

Utilise le Vercel CLI. Si non installé :
```bash
npm install -g vercel
```

Puis dans le dossier du projet :
```bash
vercel --prod
```

**Paramètres à utiliser lors de la configuration Vercel interactive :**
- Project name : `rh-metal`
- Framework : `Other` (pas de framework)
- Build command : laisser vide (pas de build)
- Output directory : `.` (dossier racine)
- Override settings : Non

L'URL finale sera du type : `https://rh-metal.vercel.app`

### 4. Connecter GitHub ↔ Vercel (déploiement automatique)

Après le premier déploiement Vercel, connecte le projet GitHub au projet Vercel pour que chaque `git push` déclenche automatiquement un nouveau déploiement :

```bash
vercel link
```

Ou via l'interface Vercel : Settings → Git → Connect Git Repository → sélectionner `rh-metal`.

### 5. Créer un fichier .gitignore

Crée un `.gitignore` adapté :

```
# OS
.DS_Store
Thumbs.db
desktop.ini

# Editors
.vscode/
*.swp

# Vercel
.vercel/

# Backup files (ne pas versionner les backups JSON)
rh-metal-backup-*.json
```

### 6. Vérifications finales

- [ ] `git status` → dépôt propre, rien en attente
- [ ] `git log --oneline` → au moins 1 commit
- [ ] URL GitHub accessible : `https://github.com/PSEUDO/rh-metal`
- [ ] URL Vercel accessible et app fonctionnelle : `https://rh-metal.vercel.app`
- [ ] Ouvrir l'URL Vercel dans Chrome et vérifier que l'app charge correctement

### 7. Pour les mises à jour futures

À chaque fois que des fichiers sont modifiés (par Claude ou manuellement) :

```bash
cd "G:\Mon Drive\Pro SONOTRAD\RH\RH-Metal"
git add .
git commit -m "fix: description de la modification"
git push
```

Vercel redéploiera automatiquement en 30-60 secondes.

## Notes importantes

- Les données des salariés sont stockées dans le **localStorage du navigateur**, pas dans les fichiers. Le déploiement ne touche pas aux données.
- Le service worker (`sw.js`) nécessite HTTPS pour fonctionner — Vercel fournit HTTPS automatiquement ✅
- Pour l'installation PWA sur mobile, utiliser l'URL Vercel (pas `file://`)
- Si le nom `rh-metal` est déjà pris sur Vercel, utiliser `rh-metal-sonotrad` ou similaire

## Prérequis utilisateur (à vérifier avant de commencer)

1. Avoir un compte GitHub (gratuit) → https://github.com
2. Avoir un compte Vercel (gratuit, connexion avec GitHub) → https://vercel.com
3. Avoir Node.js installé (pour `npm install -g vercel`) — déjà installé sur cette machine
4. Avoir Git installé — déjà installé sur cette machine
