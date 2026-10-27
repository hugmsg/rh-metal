# Schéma Supabase — photo de la structure réelle

Projet `ajewxwxerrjnnervzjwm` (partagé rh-metal / sonotrad-pwa), schéma `public`.
**Photo prise le 2026-10-16, mise à jour le 2026-10-27**, lue directement en base (pas reconstituée depuis les
migrations). Chaque fichier a été comparé à la base par empreinte md5 : identiques.

Ce dossier contient **la structure, pas les données** (les données sont sauvegardées à part,
voir l'export nocturne vers Drive).

## Contenu (ordre de rejeu)

| Fichier | Contenu |
|---|---|
| `00_extensions_sequences.sql` | extensions, séquences |
| `01_tables.sql` | 35 tables (dont stock_* et ot_* depuis le 2026-10-27), clés primaires/uniques/contrôles, RLS activé |
| `02_cles_etrangeres.sql` | clés étrangères, rattachement des séquences |
| `03_fonctions_1..4.sql` | 123 fonctions (ordre alphabétique), dont `sauvegarde_export` / `sauvegarde_restaurer` / `sauvegarde_empreinte` (2026-10-23) |
| `04_vues_index_triggers.sql` | 5 vues, index, 7 triggers, publication Realtime |
| `05_droits.sql` | règles RLS (policies), droits tables/colonnes, droits d'exécution des fonctions — **pas dans ce dépôt** (public) : dans le dépôt privé `sonotrad-scripts/supabase/`, avec `manifeste.json` (empreinte attendue de la structure) |

## Restaurer sur un projet Supabase vierge

Procédure complète (données, comptes, secrets, clés à changer) : `sonotrad-scripts/docs/
restauration.md`. **Testée le 2026-10-23** sur le projet vierge `sonotrad-restauration-test` :
structure rejouée identique à la production (empreintes md5 des fonctions, vues, contraintes,
index, triggers, colonnes, policies, droits).

Le plus simple : l'outil **« Récupération SONOTRAD »** (dossier Drive « Sauvegarde Sonotrad /
Kit de reconstruction », source `sonotrad-scripts/recuperation/`) fait tout, y compris le
contrôle par empreinte. Chaque nuit, la sauvegarde recopie ces fichiers depuis GitHub dans le kit.

À la main : dans l'éditeur SQL, `SET check_function_bodies = off;` puis les fichiers dans l'ordre
ci-dessus (les fonctions s'appellent entre elles ; les vues et triggers ont besoin des
fonctions, d'où leur place après). **`05_droits.sql` commence par retirer les droits que
Supabase donne par défaut à anon/authenticated sur tout ce qui est créé dans `public`** : sans
ces lignes, la base restaurée serait plus ouverte que la production. Ensuite les données
(`sauvegarde_restaurer`, appelée par `restaurerSupabase()` côté Apps Script).

## Rafraîchir la photo

À refaire **après chaque migration** (demander à Claude : « rafraîchis le schéma Supabase
et le kit de reconstruction ») : fichiers d'ici + `05_droits.sql` et `manifeste.json` (valeur de
`select public.sauvegarde_empreinte()` sur la production) dans `sonotrad-scripts/supabase/`.
Si on l'oublie, la sauvegarde de nuit envoie un e-mail (empreinte différente). Les requêtes de lecture utilisées sont celles de la session du 2026-10-16 :
`pg_get_functiondef`, `pg_get_viewdef`, `pg_get_constraintdef`, `pg_get_triggerdef`,
`pg_policies`, `information_schema.role_table_grants` / `column_privileges`, `pg_proc.proacl`.

## Remarques

- Les fins de ligne Windows présentes dans quelques corps de fonction ont été normalisées
  (sans effet sur le SQL).
- `recalculer_journee` et `trigger_recalcul_journee` (mortes) supprimées le 2026-10-16
  (migration `20261016140000`), photo mise à jour et revérifiée.
- Mise à jour du 2026-10-22 après la migration `20261020152358_historique_remuneration` :
  table `remunerations`, 5 fonctions ajoutées, 3 modifiées, 2 triggers ; fonctions comparées à
  la base par empreinte md5 : identiques.
- `pointer_par_pin(p_pin, p_type)` n'est plus appelée par le front : candidate au ménage.
