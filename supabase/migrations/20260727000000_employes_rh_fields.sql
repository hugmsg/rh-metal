-- ═══════════════════════════════════════════════════════════════════════════
-- RH Sonotrad (rh-metal) — Phase 2 : champs RH sur la table employes partagée
-- Base : même projet Supabase que le module Pointage (sonotrad-pwa)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- À exécuter manuellement dans Supabase Dashboard → SQL Editor.
-- Idempotent : peut être relancé sans risque.

-- pin_hash devient optionnel : un salarié créé/importé depuis rh-metal n'a
-- pas forcément de PIN kiosque (celui-ci reste géré côté admin Pointage).
ALTER TABLE employes
  ALTER COLUMN pin_hash DROP NOT NULL;

ALTER TABLE employes
  ADD COLUMN IF NOT EXISTS classe_num         smallint CHECK (classe_num BETWEEN 1 AND 18),
  ADD COLUMN IF NOT EXISTS taux_horaire       numeric(10,2),
  ADD COLUMN IF NOT EXISTS heures_semaine     numeric(5,2)  NOT NULL DEFAULT 35,
  ADD COLUMN IF NOT EXISTS heures_sup_semaine numeric(5,2)  NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS date_entree        date,
  ADD COLUMN IF NOT EXISTS date_sortie        date,
  ADD COLUMN IF NOT EXISTS type_contrat       text,
  ADD COLUMN IF NOT EXISTS poste              text,
  ADD COLUMN IF NOT EXISTS notes              text,
  -- Suppression douce : préserve l'intégrité de l'historique légal des
  -- pointages (FK pointages.employe_id -> employes.id). Distinct du champ
  -- `actif` déjà utilisé par le module Pointage (autorisation de badger),
  -- pour ne pas mélanger les deux logiques métier.
  ADD COLUMN IF NOT EXISTS supprime           boolean NOT NULL DEFAULT false;


-- ─────────────────────────────────────────────────────────────────────────────
-- FONCTION : get_employes_rh
-- Lecture des salariés (hors soft-deleted) pour rh-metal. N'expose jamais
-- pin_hash/nfc_uid. SECURITY DEFINER car employes a RLS activé sans policy
-- anon (tout accès direct à la table est bloqué pour anon).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_employes_rh()
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
  notes              text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT id, nom, prenom, classe_num, taux_horaire, heures_semaine, heures_sup_semaine,
         date_entree, date_sortie, type_contrat, poste, notes
  FROM employes
  WHERE supprime = false
  ORDER BY nom, prenom;
$$;

GRANT EXECUTE ON FUNCTION get_employes_rh() TO anon;


-- ─────────────────────────────────────────────────────────────────────────────
-- FONCTION : upsert_employe_rh
-- Créer/mettre à jour un salarié depuis rh-metal. Si p_id est fourni et
-- existe, UPDATE ; sinon INSERT avec ON CONFLICT (nom, prenom) — même clé
-- naturelle que upsert_employe_pointage, pour fusionner avec un salarié déjà
-- créé côté kiosque Pointage plutôt que le dupliquer.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION upsert_employe_rh(
  p_id                 uuid,
  p_nom                text,
  p_prenom             text,
  p_classe_num         smallint,
  p_taux_horaire       numeric,
  p_heures_semaine     numeric,
  p_heures_sup_semaine numeric,
  p_date_entree        date,
  p_date_sortie        date,
  p_type_contrat       text,
  p_poste              text,
  p_notes              text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF trim(coalesce(p_nom, '')) = '' OR trim(coalesce(p_prenom, '')) = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Nom et prénom requis.');
  END IF;

  IF p_id IS NOT NULL THEN
    UPDATE employes SET
      nom                = p_nom,
      prenom             = p_prenom,
      classe_num         = p_classe_num,
      taux_horaire       = p_taux_horaire,
      heures_semaine     = p_heures_semaine,
      heures_sup_semaine = p_heures_sup_semaine,
      date_entree        = p_date_entree,
      date_sortie        = p_date_sortie,
      type_contrat       = p_type_contrat,
      poste              = p_poste,
      notes              = p_notes,
      supprime           = false,
      updated_at         = now()
    WHERE id = p_id
    RETURNING id INTO v_id;
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO employes (
      nom, prenom, pin_hash, classe_num, taux_horaire, heures_semaine,
      heures_sup_semaine, date_entree, date_sortie, type_contrat, poste, notes
    )
    VALUES (
      p_nom, p_prenom, NULL, p_classe_num, p_taux_horaire, p_heures_semaine,
      p_heures_sup_semaine, p_date_entree, p_date_sortie, p_type_contrat, p_poste, p_notes
    )
    ON CONFLICT (nom, prenom) DO UPDATE SET
      classe_num         = EXCLUDED.classe_num,
      taux_horaire       = EXCLUDED.taux_horaire,
      heures_semaine     = EXCLUDED.heures_semaine,
      heures_sup_semaine = EXCLUDED.heures_sup_semaine,
      date_entree        = EXCLUDED.date_entree,
      date_sortie        = EXCLUDED.date_sortie,
      type_contrat       = EXCLUDED.type_contrat,
      poste              = EXCLUDED.poste,
      notes              = EXCLUDED.notes,
      supprime           = false,
      updated_at         = now()
    RETURNING id INTO v_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$$;

GRANT EXECUTE ON FUNCTION upsert_employe_rh(
  uuid, text, text, smallint, numeric, numeric, numeric, date, date, text, text, text
) TO anon;


-- ─────────────────────────────────────────────────────────────────────────────
-- FONCTION : supprimer_employe_rh
-- Suppression douce (supprime = true) — jamais de DELETE, pour ne pas casser
-- la contrainte de clé étrangère pointages.employe_id -> employes.id ni
-- perdre l'historique légal si ce salarié a déjà pointé.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION supprimer_employe_rh(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  UPDATE employes SET supprime = true, updated_at = now() WHERE id = p_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION supprimer_employe_rh(uuid) TO anon;
