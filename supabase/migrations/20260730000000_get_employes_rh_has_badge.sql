-- ═══════════════════════════════════════════════════════════════════════════
-- RH Sonotrad (rh-metal) — Badge NFC : indicateur has_badge sur get_employes_rh
-- ═══════════════════════════════════════════════════════════════════════════
--
-- À exécuter manuellement dans Supabase Dashboard → SQL Editor (ou via MCP).
-- Idempotent : peut être relancé sans risque.
--
-- Ajoute has_badge (booléen — jamais nfc_uid lui-même) au retour de
-- get_employes_rh(), pour que l'écran Équipe sache afficher "Badge associé"
-- sans exposer l'UID. Changer les colonnes de retour d'une fonction
-- RETURNS TABLE nécessite un DROP FUNCTION avant le CREATE (Postgres refuse
-- un CREATE OR REPLACE qui change la liste de colonnes de sortie).

DROP FUNCTION IF EXISTS get_employes_rh();

CREATE FUNCTION get_employes_rh()
RETURNS TABLE (
  id                 uuid,
  nom                text,
  prenom             text,
  classe_num         smallint,
  taux_horaire       numeric,
  heures_semaine     numeric,
  heures_sup_semaine numeric,
  date_entree        date,
  date_sortie        date,
  type_contrat       text,
  poste              text,
  notes              text,
  has_badge          boolean
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT id, nom, prenom, classe_num, taux_horaire, heures_semaine, heures_sup_semaine,
         date_entree, date_sortie, type_contrat, poste, notes,
         nfc_uid IS NOT NULL
  FROM employes
  WHERE supprime = false
  ORDER BY nom, prenom;
$$;

GRANT EXECUTE ON FUNCTION get_employes_rh() TO anon;
