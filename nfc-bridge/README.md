# Pont NFC — Raspberry Pi kiosque RH-Metal (+ PC de secours)

Petit service Python qui fait le lien entre le lecteur USB PC/SC (ACR122U)
branché au Raspberry Pi et la PWA RH-Metal, qui elle ne peut pas parler
directement à un lecteur PC/SC depuis un navigateur. Le pont écoute le
lecteur, et signale l'UID de chaque badge scanné à Supabase (RPC
`emettre_signal_nfc`, Realtime Broadcast) — les navigateurs (kiosque +
postes admin qui associent un badge) s'abonnent au même canal Supabase, ils
ne parlent jamais directement au pont.

**Historique** : la première version exposait son propre serveur WebSocket
sur le réseau local (`ws://<ip-du-pi>:8765`), auquel le navigateur se
connectait en direct. Ça fonctionnait en local (`http://localhost:...`) mais
restait bloqué en prod (`https://rh-metal.vercel.app`) : une page HTTPS ne
peut pas ouvrir de WebSocket non chiffrée, même vers `127.0.0.1` (contenu
mixte, confirmé le 2026-07-31). Corrigé le 2026-08-18 en repassant par
Supabase (déjà en HTTPS/WSS avec un vrai certificat) — voir `CLAUDE.md` du
repo pour le détail du diagnostic.

Ce dossier est la copie source, versionnée dans le repo pour traçabilité.
**Le déploiement sur le Raspberry Pi reste manuel** — pas d'accès SSH
automatisé depuis l'environnement de développement.

**Le pont n'a rien de spécifique au Raspberry Pi** — c'est juste un
programme Python qui a besoin du lecteur branché en USB et d'un accès
internet. Il tourne aussi tel quel sur Windows (PC/SC est nativement
supporté, pas besoin de `pcscd`/`libccid`) : voir la section "PC de
secours" plus bas si le Pi tombe en panne un jour — pas besoin de moi
(Claude Code) pour le relancer ailleurs.

## 1. Prérequis système (Raspberry Pi OS)

Le Pi a juste besoin d'un accès internet sortant (vers `*.supabase.co`) —
plus aucun port entrant à ouvrir, plus d'IP à connaître ou à réserver.

```bash
sudo apt update
sudo apt install -y python3-pip python3-venv pcscd libpcsclite1 libccid
sudo systemctl enable --now pcscd
```

`pcscd` est le démon PC/SC qui gère le lecteur au niveau système ; `libccid`
fournit le pilote générique compatible ACR122U (pas de pilote propriétaire à
installer séparément).

Vérifier que le lecteur est détecté (brancher l'ACR122U avant) :

```bash
pcsc_scan
```
→ doit afficher le nom du lecteur. `Ctrl+C` pour quitter.

## 2. Installation du pont

```bash
mkdir -p ~/nfc-bridge
cd ~/nfc-bridge
# copier nfc_bridge.py et requirements.txt depuis ce dossier du repo
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

## 3. Test manuel (avant d'installer le service)

```bash
source venv/bin/activate
python3 nfc_bridge.py
```

Poser un badge sur le lecteur → l'UID doit s'afficher dans la console
(`Badge détecté, UID = ...`). Un message "Heartbeat démarré" confirme
l'envoi périodique (toutes les 15s) qui permet au kiosque d'afficher
"Lecteur connecté". `Ctrl+C` pour arrêter.

## 4. Service systemd (démarrage automatique)

Le fichier `nfc-bridge.service` fourni suppose un utilisateur `pi` et un
dossier `/home/pi/nfc-bridge` — adapter si différent. **Si le venv est
utilisé**, changer `ExecStart` pour pointer vers
`/home/pi/nfc-bridge/venv/bin/python3` au lieu de `/usr/bin/python3`.

```bash
sudo cp nfc-bridge.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nfc-bridge
sudo systemctl status nfc-bridge   # doit afficher "active (running)"
```

Logs en direct : `journalctl -u nfc-bridge -f`

## 5. Activer le badge NFC dans RH-Metal

Aucune adresse à renseigner. Dans RH-Metal → onglet **Réglages** → cocher
"Activer le badge NFC sur le kiosque" (uniquement sur l'appareil qui sert de
kiosque — ce réglage est local au navigateur, pas partagé entre postes).

Le kiosque lui-même tourne dans Chromium en mode kiosque sur le Pi, pointé
sur `https://rh-metal.vercel.app/?kiosk=1` (voir CLAUDE.md, section Badge
NFC — **ne jamais** ouvrir l'URL sans `?kiosk=1` sur cet appareil, ça
afficherait les données RH complètes sur l'écran du kiosque).

## 6. Associer un badge à un salarié

Depuis RH-Metal (n'importe quel poste, connecté à internet — pas besoin
d'être sur le même réseau que le Pi ni d'avoir coché "Activer le badge NFC")
→ onglet Équipe → bouton 📡 sur la ligne du salarié → "Écouter le prochain
scan" → poser le badge sur le lecteur du Pi dans les 30 secondes.

## PC de secours (Windows, si le Raspberry Pi est en panne)

Pas besoin de Claude Code, ni d'installer Python : un exécutable Windows
autonome (`nfc_bridge.exe`) est déjà généré dans `nfc-bridge/dist/` — ce
dossier fait partie de `RH-Metal`, donc il se synchronise automatiquement
sur Google Drive partout où ce Drive est monté (`G:\Mon Drive\Pro
SONOTRAD\RH\RH-Metal\nfc-bridge\dist\nfc_bridge.exe`).

### Utilisation ponctuelle (dépannage rapide)

1. Brancher le lecteur ACR122U en USB sur le PC.
2. Ouvrir le dossier `nfc-bridge\dist` (via Google Drive) et double-cliquer
   sur `nfc_bridge.exe`.
3. Une fenêtre noire (console) s'ouvre et affiche l'état en clair :
   - `✅ Lecteur détecté : ...` puis `✅ Connecté à Supabase` puis
     `🟢 Prêt` → tout fonctionne, **laisser cette fenêtre ouverte**.
   - `❌ Aucun lecteur NFC détecté` → le programme réessaie tout seul
     toutes les 3 secondes et affiche des pistes de dépannage directement
     dans la fenêtre (rebrancher le lecteur, patienter si c'est la
     première fois sur ce PC — Windows installe parfois un pilote
     automatiquement). Pas besoin d'aller chercher un fichier de log.
   - `❌ Impossible de contacter Supabase` → ce PC n'a pas accès à
     internet (vérifier le Wi-Fi/câble réseau).
4. Fermer la fenêtre = arrête le pont (normal, pas une erreur).
5. Dans RH-Metal → Réglages → cocher "Activer le badge NFC sur le kiosque"
   si ce n'est pas déjà fait sur le navigateur utilisé.

### Rendre ce PC "toujours prêt" (démarrage automatique)

Si un PC est désigné comme secours permanent (allumé en continu, lecteur
toujours branché), autant que le pont démarre seul sans que personne n'ait
à double-cliquer quoi que ce soit :

1. `Win + R` → taper `shell:startup` → Entrée (ouvre le dossier Démarrage
   de Windows).
2. Faire un raccourci de `nfc_bridge.exe` (clic droit sur le fichier →
   Envoyer vers → Bureau, ou clic droit → Créer un raccourci) et déposer ce
   raccourci dans le dossier Démarrage ouvert à l'étape 1.
3. Redémarrer le PC pour vérifier : la fenêtre du pont doit s'ouvrir seule
   à la connexion, sans action.

À partir de là : PC allumé + lecteur branché = badge NFC opérationnel,
aucun clic nécessaire.

### Régénérer l'exécutable (si `dist/nfc_bridge.exe` a été supprimé/modifié)

Depuis un PC qui a Python installé (pas nécessaire sur le PC de secours
final, seulement pour fabriquer le fichier) :

```powershell
pip install pyinstaller pyscard requests
cd nfc-bridge
python -m PyInstaller --onefile --console --name nfc_bridge nfc_bridge.py
# → génère dist/nfc_bridge.exe
```

## Dépannage

- **"Lecteur hors ligne" au kiosque** : vérifier `systemctl status
  nfc-bridge` sur le Pi (`journalctl -u nfc-bridge -f` pour voir si le
  heartbeat part bien toutes les 15s) et que le Pi a bien un accès internet
  sortant.
- **Badge scanné mais rien ne se passe** : vérifier `journalctl -u
  nfc-bridge -f` pendant le scan — si l'UID s'affiche côté Pi
  (`Badge détecté, UID = ...`) mais que la réponse HTTP n'est pas 2xx
  (`emettre_signal_nfc(...) a répondu ...` dans les logs), vérifier que la
  migration `sonotrad-pwa/supabase/migrations/20260818000000_pointage_nfc_broadcast.sql`
  est bien appliquée sur le projet Supabase.
- **`pcsc_scan` ne voit pas le lecteur** : rebrancher l'USB, vérifier
  `lsusb` (l'ACR122U doit apparaître), `sudo systemctl restart pcscd`.
