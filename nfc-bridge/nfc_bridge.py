#!/usr/bin/env python3
"""Pont NFC — lecteur USB PC/SC (ACR122U) vers RH-Metal (kiosque Pointage).

Détecte l'insertion d'un badge sur le lecteur, lit son UID via la pseudo-APDU
"Get Data" standard (FF CA 00 00 00, supportée nativement par l'ACR122U), et
diffuse {"uid": "<hex>"} à tous les navigateurs connectés via WebSocket.

Le serveur écoute sur toutes les interfaces (pas seulement 127.0.0.1 — voir
HOST ci-dessous) : un admin peut associer un badge à un salarié depuis
n'importe quel poste du réseau local SONOTRAD, sans être physiquement devant
le Raspberry Pi (décision Hugo 2026-07-30, voir CLAUDE.md).

Installation et lancement : voir README.md dans ce dossier.
"""

import asyncio
import json
import logging

from smartcard.CardMonitoring import CardMonitor, CardObserver
from smartcard.util import toHexString
import websockets

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("nfc-bridge")

HOST = "0.0.0.0"
PORT = 8765

# Pseudo-APDU "Get UID" — standard PC/SC (pas spécifique ACR122U, mais c'est
# le lecteur visé ici). Réponse attendue : UID brut + SW 90 00.
GET_UID_APDU = [0xFF, 0xCA, 0x00, 0x00, 0x00]

connected_clients = set()
main_loop = None  # rempli au démarrage — sert à repasser du thread pyscard vers la boucle asyncio


async def register(websocket):
    connected_clients.add(websocket)
    log.info("Client connecté (%d au total)", len(connected_clients))
    try:
        async for _ in websocket:
            pass  # ce pont n'attend rien du navigateur, juste une connexion ouverte
    finally:
        connected_clients.discard(websocket)
        log.info("Client déconnecté (%d au total)", len(connected_clients))


async def broadcast_uid(uid: str):
    if not connected_clients:
        log.info("Badge lu (%s) mais aucun client connecté — ignoré", uid)
        return
    message = json.dumps({"uid": uid})
    results = await asyncio.gather(
        *(ws.send(message) for ws in connected_clients), return_exceptions=True
    )
    for r in results:
        if isinstance(r, Exception):
            log.warning("Envoi à un client échoué : %s", r)
    log.info("UID diffusé à %d client(s) : %s", len(connected_clients), uid)


class BadgeObserver(CardObserver):
    """Callback pyscard — s'exécute dans le thread de monitoring de pyscard,
    PAS dans la boucle asyncio : on repasse donc explicitement via
    run_coroutine_threadsafe plutôt que d'appeler broadcast_uid() directement
    (qui planterait, appelée hors de la boucle événementielle)."""

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
                    if main_loop:
                        asyncio.run_coroutine_threadsafe(broadcast_uid(uid), main_loop)
                else:
                    log.warning("Lecture UID échouée (SW=%02X%02X)", sw1, sw2)
            except Exception:
                log.exception("Erreur lors de la lecture du badge")


async def main():
    global main_loop
    main_loop = asyncio.get_running_loop()

    monitor = CardMonitor()
    observer = BadgeObserver()
    monitor.addObserver(observer)
    log.info("Surveillance du lecteur PC/SC démarrée")

    async with websockets.serve(register, HOST, PORT):
        log.info("Pont NFC en écoute sur ws://%s:%d", HOST, PORT)
        await asyncio.Future()  # tourne indéfiniment


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
