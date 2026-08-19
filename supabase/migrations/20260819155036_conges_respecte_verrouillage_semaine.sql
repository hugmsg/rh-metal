-- Le sous-onglet Contrôle permet désormais de déclarer un congé directement
-- sur un jour vide (upsert_conge_rh, depuis la nouvelle fenêtre "🗓 Congé"
-- qui remplace le bouton "Non travaillé"). Pour que le verrouillage de
-- semaine reste réel (pas contournable via l'onglet Congés classique),
-- upsert/suppression refusent toute période qui chevauche une semaine déjà
-- verrouillée pour ce salarié.
CREATE OR REPLACE FUNCTION public.upsert_conge_rh(p_id uuid, p_employe_id uuid, p_type text, p_date_debut date, p_date_fin date, p_jours numeric, p_motif text, p_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_id uuid;
BEGIN
  IF p_employe_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Salarié requis.');
  END IF;
  IF p_type NOT IN ('cp','maladie','evenement_familial','sans_solde') THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Type de congé invalide.');
  END IF;
  IF p_date_fin < p_date_debut THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Date de fin avant la date de début.');
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.semaines_validees sv
    WHERE sv.employe_id = p_employe_id
      AND sv.semaine_debut <= p_date_fin
      AND (sv.semaine_debut + 4) >= p_date_debut
  ) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Une semaine verrouillée est concernée par cette période — déverrouillez-la avant de modifier ce congé.');
  END IF;

  IF p_id IS NOT NULL THEN
    UPDATE conges SET
      employe_id = p_employe_id,
      type       = p_type,
      date_debut = p_date_debut,
      date_fin   = p_date_fin,
      jours      = p_jours,
      motif      = p_motif,
      notes      = p_notes,
      updated_at = now()
    WHERE id = p_id
    RETURNING id INTO v_id;
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO conges (employe_id, type, date_debut, date_fin, jours, motif, notes)
    VALUES (p_employe_id, p_type, p_date_debut, p_date_fin, p_jours, p_motif, p_notes)
    RETURNING id INTO v_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.supprimer_conge_rh(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_emp uuid;
  v_debut date;
  v_fin date;
BEGIN
  SELECT employe_id, date_debut, date_fin INTO v_emp, v_debut, v_fin FROM conges WHERE id = p_id;
  IF v_emp IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Congé introuvable.');
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.semaines_validees sv
    WHERE sv.employe_id = v_emp
      AND sv.semaine_debut <= v_fin
      AND (sv.semaine_debut + 4) >= v_debut
  ) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Une semaine verrouillée est concernée par ce congé — déverrouillez-la avant de le supprimer.');
  END IF;
  DELETE FROM conges WHERE id = p_id;
  RETURN jsonb_build_object('ok', true);
END;
$function$;
