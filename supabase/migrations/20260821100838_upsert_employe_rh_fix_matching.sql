-- Corrige upsert_employe_rh (audit RH-Metal du 2026-08-21, point 1) : le
-- repli quand p_id est absent (ou introuvable) utilisait
-- INSERT ... ON CONFLICT (nom, prenom) DO UPDATE — comparaison stricte
-- casse+accents, exactement le pattern que CLAUDE.md interdit ("jamais de
-- comparaison stricte ON CONFLICT (nom, prenom) seule, source de doublons").
-- Cette version était en base depuis la migration 20260727000000
-- (employes_rh_fields.sql), jamais corrigée depuis malgré la convention déjà
-- documentée à ce moment-là — confirmé via pg_get_functiondef avant ce
-- correctif. Un index unique employes_nom_prenom_unique (nom, prenom)
-- existait aussi en base sans être jamais tracé en migration ; laissé tel
-- quel (le retirer n'est pas nécessaire pour ce correctif et sort du
-- périmètre demandé).
--
-- Remplacé par la logique documentée : id en priorité, puis correspondance
-- nom/prénom normalisée (casse+accents ignorés via unaccent) en repli
-- uniquement.
CREATE EXTENSION IF NOT EXISTS unaccent;

CREATE OR REPLACE FUNCTION public.upsert_employe_rh(p_id uuid, p_nom text, p_prenom text, p_classe_num smallint, p_taux_horaire numeric, p_heures_semaine numeric, p_heures_sup_semaine numeric, p_date_entree date, p_date_sortie date, p_type_contrat text, p_poste text, p_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
    -- Pas de p_id (nouvel employé côté RH), ou id fourni introuvable :
    -- repli sur la correspondance nom/prénom normalisée, jamais une
    -- comparaison stricte.
    SELECT id INTO v_id FROM employes
    WHERE unaccent(lower(nom)) = unaccent(lower(p_nom))
      AND unaccent(lower(prenom)) = unaccent(lower(p_prenom))
    LIMIT 1;

    IF v_id IS NOT NULL THEN
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
      WHERE id = v_id;
    ELSE
      INSERT INTO employes (
        nom, prenom, pin_hash, classe_num, taux_horaire, heures_semaine,
        heures_sup_semaine, date_entree, date_sortie, type_contrat, poste, notes
      )
      VALUES (
        p_nom, p_prenom, NULL, p_classe_num, p_taux_horaire, p_heures_semaine,
        p_heures_sup_semaine, p_date_entree, p_date_sortie, p_type_contrat, p_poste, p_notes
      )
      RETURNING id INTO v_id;
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;
