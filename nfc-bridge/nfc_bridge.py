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
import threading
import time

import requests
from smartcard.CardMonitoring import CardMonitor, CardObserver
from smartcard.util import toHexString

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("nfc-bridge")

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
    while not stop_event.is_set():
        _emettre("heartbeat")
        stop_event.wait(HEARTBEAT_INTERVAL_S)


def main():
    monitor = CardMonitor()
    observer = BadgeObserver()
    monitor.addObserver(observer)
    log.info("Surveillance du lecteur PC/SC démarrée")

    stop_event = threading.Event()
    hb_thread = threading.Thread(target=_heartbeat_loop, args=(stop_event,), daemon=True)
    hb_thread.start()
    log.info("Heartbeat démarré (toutes les %ds) — canal nfc-badge-scans", HEARTBEAT_INTERVAL_S)

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
