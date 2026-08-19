#!/usr/bin/env python3
"""Pont NFC — lecteur USB PC/SC (ACR122U) vers RH-Metal (kiosque Pointage).

Détecte l'insertion d'un badge sur le lecteur, lit son UID via la pseudo-APDU
"Get Data" standard (FF CA 00 00 00, supportée nativement par l'ACR122U), et
le signale via la RPC Supabase `emettre_signal_nfc` (Realtime Broadcast,
canal "nfc-badge-scans") — un simple appel REST en HTTPS, comme n'importe
quel autre appel Supabase de cette appli.

Historique : la première version de ce pont exposait son propre serveur
WebSocket sur le réseau local, auquel le navigateur se connectait directement
en `ws://`. Ça marchait en local (`http://localhost:...`) mais restait bloqué
en prod (`https://rh-metal.vercel.app`) : une page HTTPS ne peut pas ouvrir de
WebSocket non chiffrée, même vers 127.0.0.1 (contenu mixte, confirmé le
2026-07-31). Cette version pousse les événements vers Supabase à la place —
le navigateur ne parle qu'à Supabase (déjà en WSS avec un vrai certificat),
jamais directement au pont. Conséquence pratique : plus besoin d'exposer un
port sur le réseau local, ni de renseigner une adresse IP côté RH-Metal.

Installation et lancement : voir README.md dans ce dossier.
"""

import logging
import sys
import threading
import time

# Certaines consoles Windows (codepage cp1252/cp850, notamment quand la
# sortie est redirigée vers un fichier) plantent sur les emoji/caractères ═.
# errors='replace' : au pire un caractère bizarre s'affiche, jamais un crash.
# line_buffering=True : sans ça, les print() peuvent rester coincés dans un
# tampon invisible tant que le programme tourne (surtout si la sortie n'est
# pas un vrai terminal — un exe empaqueté peut se comporter ainsi) — la
# personne devant l'écran ne verrait alors jamais les messages de statut.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace", line_buffering=True)
    except (AttributeError, ValueError):
        pass

import requests
from smartcard.CardMonitoring import CardMonitor, CardObserver
from smartcard.System import readers
from smartcard.util import toHexString

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("nfc-bridge")

READER_CHECK_INTERVAL_S = 3

# Mêmes identifiants Supabase que le reste de l'appli (index.html) — projet
# partagé avec sonotrad-pwa, clé anon publique (RLS/RPC protègent les données,
# voir sonotrad-pwa/supabase/migrations/20260818000000_pointage_nfc_broadcast.sql).
SUPABASE_URL = "https://ajewxwxerrjnnervzjwm.supabase.co"
SUPABASE_ANON_KEY = (
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFqZXd4d3hlcnJqbm5lcnZ6andtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODE1MDU5MDEsImV4cCI6MjA5NzA4MTkwMX0.NJcm1_tb4BcCSileiODYP0pKJ1LRVXFTIr2idQBrALg"
)
RPC_URL = f"{SUPABASE_URL}/rest/v1/rpc/emettre_signal_nfc"
HEADERS = {
    "apikey": SUPABASE_ANON_KEY,
    "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
    "Content-Type": "application/json",
}

HEARTBEAT_INTERVAL_S = 15

# Pseudo-APDU "Get UID" — standard PC/SC (pas spécifique ACR122U, mais c'est
# le lecteur visé ici). Réponse attendue : UID brut + SW 90 00.
GET_UID_APDU = [0xFF, 0xCA, 0x00, 0x00, 0x00]

# Mot-clés pour distinguer le vrai lecteur NFC (ACR122U/ACS) des lecteurs
# virtuels que Windows peut exposer sur le même bus PC/SC — ex. "Windows
# Hello for Business" (carte à puce virtuelle liée au TPM, sans rapport avec
# le badge). Repéré le 2026-08-18 : sans ce filtre, readers() renvoyait ce
# lecteur virtuel même l'ACR122U débranché, et le pont continuait donc à
# signaler "lecteur présent" à tort (heartbeat jamais coupé, kiosque resté
# sur "Lecteur connecté" malgré le débranchement réel).
READER_NAME_KEYWORDS = ("acr", "acs")


def _lecteur_nfc():
    """Renvoie le lecteur NFC réel (nom contenant un des READER_NAME_KEYWORDS)
    s'il est câblé et vu par le système, sinon None — ignore tout autre
    lecteur PC/SC que Windows pourrait exposer par ailleurs."""
    try:
        for r in readers():
            if any(k in str(r).lower() for k in READER_NAME_KEYWORDS):
                return r
    except Exception:
        pass
    return None


def _emettre(event, payload=None):
    try:
        r = requests.post(
            RPC_URL,
            headers=HEADERS,
            json={"p_event": event, "p_payload": payload or {}},
            timeout=5,
        )
        if r.status_code >= 300:
            log.warning("emettre_signal_nfc(%s) a répondu %s : %s", event, r.status_code, r.text)
    except requests.RequestException:
        log.exception("Erreur réseau en envoyant l'événement '%s' à Supabase", event)


class BadgeObserver(CardObserver):
    """Callback pyscard — s'exécute dans le thread de monitoring de pyscard.
    Pas besoin de bufferiser/relayer vers une autre boucle ici (contrairement
    à l'ancienne version avec asyncio) : un simple appel HTTP synchrone dans
    ce thread suffit, un scan de badge est un événement peu fréquent."""

    def update(self, observable, actions):
        (added_cards, _removed_cards) = actions
        for card in added_cards:
            try:
                connection = card.createConnection()
                connection.connect()
                data, sw1, sw2 = connection.transmit(GET_UID_APDU)
                if sw1 == 0x90 and sw2 == 0x00:
                    uid = toHexString(data).replace(" ", "")
                    log.info("Badge détecté, UID = %s", uid)
                    _emettre("nfc_scan", {"uid": uid})
                else:
                    log.warning("Lecture UID échouée (SW=%02X%02X)", sw1, sw2)
            except Exception:
                log.exception("Erreur lors de la lecture du badge")


def _heartbeat_loop(stop_event: threading.Event):
    """Le heartbeat ne doit pas juste dire 'le programme tourne et a internet'
    — il doit dire 'le lecteur physique répond toujours à cet instant'. Sans
    revérifier readers() à chaque tour, débrancher le lecteur en cours de
    route n'aurait jamais fait passer le kiosque à 'hors ligne' (repéré par
    Hugo le 2026-08-18 : pastille restée verte lecteur débranché)."""
    lecteur_signale_absent = False
    while not stop_event.is_set():
        if _lecteur_nfc() is not None:
            _emettre("heartbeat")
            lecteur_signale_absent = False
        elif not lecteur_signale_absent:
            log.warning("Lecteur non détecté — heartbeat suspendu (le kiosque va afficher 'hors ligne').")
            lecteur_signale_absent = True
        stop_event.wait(HEARTBEAT_INTERVAL_S)


def _attendre_lecteur():
    """Boucle bloquante avec messages explicites tant qu'aucun lecteur PC/SC
    n'est vu par le système — pensé pour quelqu'un qui lance ce programme sans
    connaître Python : pas un plantage silencieux, un message clair à chaque
    tentative, avec des pistes concrètes."""
    tentative = 0
    while True:
        r = _lecteur_nfc()
        if r is not None:
            print(f"✅ Lecteur détecté : {r}")
            return
        tentative += 1
        if tentative == 1:
            print("❌ Aucun lecteur NFC détecté.")
            print("   Vérifie que :")
            print("   1. Le lecteur (ACR122U) est bien branché sur un port USB.")
            print("   2. S'il vient d'être branché, patiente une minute — Windows installe")
            print("      parfois un pilote automatiquement la première fois.")
            print("   3. Essaie de le débrancher puis rebrancher.")
            print("   Nouvelle tentative toutes les 3 secondes (laisse cette fenêtre ouverte)...")
        elif tentative % 10 == 0:
            print(f"   ... toujours aucun lecteur détecté après {tentative * READER_CHECK_INTERVAL_S}s.")
        time.sleep(READER_CHECK_INTERVAL_S)


def _verifier_supabase():
    """Un aller-retour heartbeat au démarrage pour confirmer que ce PC a bien
    accès à internet/Supabase — plutôt que de laisser l'utilisateur deviner
    pourquoi le kiosque n'affiche jamais 'Lecteur connecté'."""
    try:
        r = requests.post(
            RPC_URL,
            headers=HEADERS,
            json={"p_event": "heartbeat", "p_payload": {}},
            timeout=8,
        )
        if r.status_code < 300:
            print("✅ Connecté à Supabase (internet OK).")
            return True
        print(f"❌ Supabase a répondu une erreur ({r.status_code}) — signale ce message.")
        return False
    except requests.RequestException as e:
        print("❌ Impossible de contacter Supabase — vérifie que ce PC a accès à internet.")
        print(f"   Détail technique : {e}")
        return False


def main():
    print("═" * 60)
    print("  PONT NFC — RH SONOTRAD")
    print("  Laisse cette fenêtre ouverte tant que le badge doit fonctionner.")
    print("═" * 60)

    _attendre_lecteur()
    _verifier_supabase()

    monitor = CardMonitor()
    observer = BadgeObserver()
    monitor.addObserver(observer)
    log.info("Surveillance du lecteur PC/SC démarrée")

    stop_event = threading.Event()
    hb_thread = threading.Thread(target=_heartbeat_loop, args=(stop_event,), daemon=True)
    hb_thread.start()
    log.info("Heartbeat démarré (toutes les %ds) — canal nfc-badge-scans", HEARTBEAT_INTERVAL_S)
    print("🟢 Prêt — en attente de badges (le kiosque doit afficher 'Lecteur connecté' sous 30s).")

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        stop_event.set()
        monitor.deleteObserver(observer)


if __name__ == "__main__":
    main()
