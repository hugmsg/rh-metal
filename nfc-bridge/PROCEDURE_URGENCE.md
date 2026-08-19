# Le pointage par badge ne fonctionne plus — que faire ?

Procédure à suivre par **n'importe qui**, même sans connaissance technique,
si l'écran du kiosque (Raspberry Pi) affiche "Lecteur hors ligne" ou ne
répond plus du tout. Pas besoin d'appeler Hugo pour ça — mais préviens-le
quand même dès que possible pour qu'il répare la solution définitive (le
Raspberry Pi).

## 1. Récupérer le lecteur de badge

Débrancher le petit boîtier USB blanc (le lecteur NFC) du Raspberry Pi en
panne et le brancher sur un PC Windows qui a accès à internet.

## 2. Lancer le pont sur ce PC

1. Ouvrir le dossier **Google Drive** partagé, puis aller dans :
   `Pro SONOTRAD > RH > RH-Metal > nfc-bridge > dist`
2. Double-cliquer sur `nfc_bridge.exe`.
3. Une fenêtre noire s'ouvre. Attendre qu'elle affiche :
   - `✅ Lecteur détecté`
   - `✅ Connecté à Supabase`
   - `🟢 Prêt`

   → Si à la place elle affiche `❌ Aucun lecteur NFC détecté`, patienter
   quelques secondes (le programme réessaie tout seul) — la première fois
   sur un nouveau PC, Windows installe parfois le pilote automatiquement,
   ça peut prendre une minute.

4. **Laisser cette fenêtre ouverte** tant que le badge doit fonctionner.
   La fermer arrête le pointage par badge (ce n'est pas une erreur, c'est
   normal).

## 3. Donner accès à l'écran de pointage

Sur ce même PC (ou un autre poste, peu importe), ouvrir dans un navigateur :

```
https://rh-metal.vercel.app/?kiosk=1
```

C'est l'écran que les salariés utilisent pour badger — code PIN ou badge.

## 4. Vérifier que ça fonctionne

Poser un badge sur le lecteur : le nom du salarié doit s'afficher à
l'écran avec "Entrée" ou "Sortie" enregistrée.

## En cas de blocage

- La fenêtre noire n'affiche jamais `🟢 Prêt` → contacter Hugo
  ([à compléter : téléphone/email]).
- Pas d'accès au dossier Google Drive sur ce PC → contacter Hugo, il peut
  envoyer le fichier `nfc_bridge.exe` autrement.
