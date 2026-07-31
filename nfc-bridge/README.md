# Pont NFC — Raspberry Pi kiosque RH-Metal

Petit service Python qui fait le lien entre le lecteur USB PC/SC (ACR122U)
branché au Raspberry Pi et la PWA RH-Metal, qui elle ne peut pas parler
directement à un lecteur PC/SC depuis un navigateur. Le pont écoute le
lecteur, et diffuse l'UID de chaque badge scanné à tous les navigateurs
connectés en WebSocket (kiosque + postes admin qui associent un badge).

Ce dossier est la copie source, versionnée dans le repo pour traçabilité.
**Le déploiement sur le Raspberry Pi reste manuel** — pas d'accès SSH
automatisé depuis l'environnement de développement.

## 1. Prérequis système (Raspberry Pi OS)

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
(`Badge détecté, UID = ...`). `Ctrl+C` pour arrêter.

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

## 5. Renseigner l'adresse dans RH-Metal

Trouver l'IP locale du Pi :

```bash
hostname -I
```

Dans RH-Metal (depuis n'importe quel poste admin, pas besoin d'être sur le
Pi) → onglet **Réglages** → "Adresse du pont NFC" → `ws://<IP-du-Pi>:8765`.

Le kiosque lui-même tourne dans Chromium en mode kiosque sur le Pi, pointé
sur `https://rh-metal.vercel.app/?kiosk=1` (voir CLAUDE.md, section Badge
NFC — **ne jamais** ouvrir l'URL sans `?kiosk=1` sur cet appareil, ça
afficherait les données RH complètes sur l'écran du kiosque).

## 6. Associer un badge à un salarié

Depuis RH-Metal (n'importe quel poste, une fois l'adresse renseignée) →
onglet Équipe → bouton 📡 sur la ligne du salarié → "Écouter le prochain
scan" → poser le badge sur le lecteur du Pi dans les 30 secondes.

## Dépannage

- **"Lecteur hors ligne" au kiosque** : vérifier `systemctl status
  nfc-bridge` sur le Pi, et que l'IP renseignée dans Réglages est toujours
  la bonne (une IP DHCP peut changer — envisager une réservation DHCP fixe
  sur la box/routeur pour ce Pi).
- **Badge scanné mais rien ne se passe** : vérifier `journalctl -u
  nfc-bridge -f` pendant le scan — si l'UID s'affiche côté Pi mais
  n'atteint jamais le navigateur, c'est un souci réseau/pare-feu entre le
  poste et le Pi (port 8765 à autoriser si un pare-feu est actif sur le Pi :
  `sudo ufw allow 8765/tcp` le cas échéant).
- **`pcsc_scan` ne voit pas le lecteur** : rebrancher l'USB, vérifier
  `lsusb` (l'ACR122U doit apparaître), `sudo systemctl restart pcscd`.
