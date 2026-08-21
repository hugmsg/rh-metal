-- Expose/écrit les 3 nouvelles colonnes de coordonnées personnelles
-- (voir 20260821133512) dans get_employes_rh() / upsert_employe_rh().
-- get_employes_rh() doit être DROP avant recréation : Postgres refuse un
-- CREATE OR REPLACE qui change le type de retour (RETURNS TABLE).
DROP FUNCTION IF EXISTS public.get_employes_rh();

CREATE OR REPLACE FUNCTION public.get_employes_rh()
 RETURNS TABLE(id uuid, nom text, prenom text, classe_num smallint, taux_horaire numeric, heures_semaine numeric, heures_sup_semaine numeric, date_entree date, date_sortie date, type_contrat text, poste text, notes text, has_badge boolean, adresse text, telephone_perso text, email_perso text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  SELECT id, nom, prenom, classe_num, taux_horaire, heures_semaine, heures_sup_semaine,
         date_entree, date_sortie, type_contrat, poste, notes,
         nfc_uid IS NOT NULL,
         adresse, telephone_perso, email_perso
  FROM employes
  WHERE supprime = false
  ORDER BY nom, prenom;
$function$;

CREATE OR REPLACE FUNCTION public.upsert_employe_rh(p_id uuid, p_nom text, p_prenom text, p_classe_num smallint, p_taux_horaire numeric, p_heures_semaine numeric, p_heures_sup_semaine numeric, p_date_entree date, p_date_sortie date, p_type_contrat text, p_poste text, p_notes text, p_adresse text DEFAULT NULL, p_telephone_perso text DEFAULT NULL, p_email_perso text DEFAULT NULL)
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
      adresse            = p_adresse,
      telephone_perso    = p_telephone_perso,
      email_perso        = p_email_perso,
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
        adresse            = p_adresse,
        telephone_perso    = p_telephone_perso,
        email_perso        = p_email_perso,
        supprime           = false,
        updated_at         = now()
      WHERE id = v_id;
    ELSE
      INSERT INTO employes (
        nom, prenom, pin_hash, classe_num, taux_horaire, heures_semaine,
        heures_sup_semaine, date_entree, date_sortie, type_contrat, poste, notes,
        adresse, telephone_perso, email_perso
      )
      VALUES (
        p_nom, p_prenom, NULL, p_classe_num, p_taux_horaire, p_heures_semaine,
        p_heures_sup_semaine, p_date_entree, p_date_sortie, p_type_contrat, p_poste, p_notes,
        p_adresse, p_telephone_perso, p_email_perso
      )
      RETURNING id INTO v_id;
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;
