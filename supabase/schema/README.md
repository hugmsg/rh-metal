# Schéma Supabase — photo de la structure réelle

Projet `ajewxwxerrjnnervzjwm` (partagé rh-metal / sonotrad-pwa), schéma `public`.
**Photo prise le 2026-10-16**, lue directement en base (pas reconstituée depuis les
migrations). Chaque fichier a été comparé à la base par empreinte md5 : identiques.

Ce dossier contient **la structure, pas les données** (les données sont sauvegardées à part,
voir l'export nocturne vers Drive).

## Contenu (ordre de rejeu)

| Fichier | Contenu |
|---|---|
| `00_extensions_sequences.sql` | extensions, séquences |
| `01_tables.sql` | 21 tables, clés primaires/uniques/contrôles, RLS activé |
| `02_cles_etrangeres.sql` | clés étrangères, rattachement des séquences |
| `03_fonctions_1..4.sql` | 91 fonctions (ordre alphabétique) |
| `04_vues_index_triggers.sql` | 5 vues, index, 5 triggers, publication Realtime |
| `05_droits.sql` | règles RLS (policies), droits tables/colonnes, droits d'exécution des fonctions — **hors Git** (dépôt public) : présent uniquement dans le dossier OneDrive `dev/rh-metal/supabase/schema/` |

## Restaurer sur un projet Supabase vierge

1. Créer le projet (même région eu-west-1 de préférence).
2. Dans l'éditeur SQL, exécuter `SET check_function_bodies = off;` puis les fichiers dans
   l'ordre ci-dessus (les fonctions s'appellent entre elles ; les vues et triggers ont besoin
   des fonctions, d'où leur place après).
3. Réimporter les données (export JSON du Drive).
4. Recréer à la main ce qui n'est pas dans ce dossier :
   - comptes de connexion Supabase Auth (admin RH, `kiosque@sonotrad.fr`) puis relier
     `employes.auth_user_id` / `comptes_kiosque` ;
   - lignes secrètes de `config_interne` et propriétés de script côté Apps Script
     (`SUPABASE_SERVICE_KEY`, `SUPABASE_HISTORY_SECRET`…) avec les nouvelles clés du projet ;
   - Edge Function `activer-portail` (`../functions/`) ;
   - URL et clé publique du nouveau projet dans rh-metal, la PWA et le portail transporteur.

## Rafraîchir la photo

À refaire **après chaque migration** (demander à Claude : « rafraîchis le schéma Supabase
dans rh-metal »). Les requêtes de lecture utilisées sont celles de la session du 2026-10-16 :
`pg_get_functiondef`, `pg_get_viewdef`, `pg_get_constraintdef`, `pg_get_triggerdef`,
`pg_policies`, `information_schema.role_table_grants` / `column_privileges`, `pg_proc.proacl`.

## Remarques

- Les fins de ligne Windows présentes dans quelques corps de fonction ont été normalisées
  (sans effet sur le SQL).
- `recalculer_journee` et `trigger_recalcul_journee` (mortes) supprimées le 2026-10-16
  (migration `20261016140000`), photo mise à jour et revérifiée.
- `pointer_par_pin(p_pin, p_type)` n'est plus appelée par le front : candidate au ménage.
