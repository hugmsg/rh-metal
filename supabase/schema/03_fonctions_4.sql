CREATE OR REPLACE FUNCTION public.pwa_definir_pin(p_compte uuid, p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_employe uuid;
BEGIN
  IF coalesce(p_pin, '') !~ '^[0-9]{4}$' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'PIN invalide (4 chiffres attendus).');
  END IF;
  SELECT employe_id INTO v_employe FROM comptes_pwa WHERE id = p_compte;
  IF v_employe IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Compte introuvable.');
  END IF;
  IF _pin_deja_pris(p_pin, v_employe) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Ce PIN est déjà utilisé par un collègue : choisissez-en un autre.');
  END IF;
  UPDATE employes SET pin_hash = crypt(p_pin, gen_salt('bf', 12)), updated_at = now() WHERE id = v_employe;
  UPDATE comptes_pwa SET pin_migre = true, updated_at = now() WHERE id = p_compte;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rouvrir_mois(p_mois date, p_motif text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE m date := date_trunc('month', p_mois)::date;
BEGIN
  PERFORM public._exiger_admin_rh();
  IF coalesce(trim(p_motif), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Un motif est obligatoire.');
  END IF;
  UPDATE public.mois_clotures SET cloture = false, export_perime = (exporte_le IS NOT NULL) WHERE mois = m;
  PERFORM public._journal(NULL, 'Mois de ' || to_char(m, 'MM/YYYY') || ' déverrouillé (les semaines restent verrouillées)', p_motif);
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.supprimer_conge_rh(p_id uuid, p_motif text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE c public.conges%ROWTYPE;
BEGIN
  PERFORM public._exiger_admin_rh();
  SELECT * INTO c FROM public.conges WHERE id = p_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Congé introuvable.');
  END IF;
  IF public._periode_verrouillee(c.employe_id, c.date_debut, c.date_fin) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Une semaine verrouillée est concernée par ce congé — déverrouillez-la avant de le supprimer.');
  END IF;
  DELETE FROM public.conges WHERE id = p_id;
  PERFORM public._journal(c.employe_id, 'Absence supprimée — ' || public._conge_label(c.type)
    || CASE WHEN c.date_debut = c.date_fin THEN ' le ' || public._fmt_jour(c.date_debut)
       ELSE ' du ' || public._fmt_jour(c.date_debut) || ' au ' || public._fmt_jour(c.date_fin) END, p_motif);
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.supprimer_correction_heures(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE c public.heures_corrections%ROWTYPE;
BEGIN
  PERFORM public._exiger_admin_rh();
  SELECT * INTO c FROM public.heures_corrections WHERE id = p_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Correction introuvable.');
  END IF;
  IF public._semaine_est_verrouillee(c.employe_id, c.date) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Semaine verrouillée — déverrouillez-la avant de supprimer cette correction.');
  END IF;
  DELETE FROM public.heures_corrections WHERE id = p_id;
  PERFORM public._journal(c.employe_id, 'Correction supprimée (' || CASE WHEN c.delta_min > 0 THEN '+' ELSE '−' END
    || public._fmt_num(abs(c.delta_min) / 60.0) || ' h le ' || public._fmt_jour(c.date) || ')', c.commentaire);
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.supprimer_employe_rh(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  IF coalesce(auth.jwt() ->> 'role', '') <> 'service_role' THEN
    PERFORM _exiger_admin_rh();
  END IF;
  IF EXISTS (SELECT 1 FROM employes WHERE id = p_id AND is_rh_admin) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Administrateur RH : retire-lui d''abord ce droit dans Paramètres.');
  END IF;
  UPDATE employes SET supprime = true, updated_at = now() WHERE id = p_id;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.supprimer_jour_ferie(p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE l text;
BEGIN
  PERFORM public._exiger_admin_rh();
  DELETE FROM public.jours_feries WHERE date = p_date RETURNING libelle INTO l;
  IF l IS NOT NULL THEN PERFORM public._journal(NULL, 'Jour férié supprimé — ' || l || ' le ' || public._fmt_jour(p_date)); END IF;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.supprimer_voyage(p_secret text, p_numero_lv text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  expected text;
BEGIN
  SELECT valeur INTO expected FROM config_interne WHERE cle = 'historique_secret';
  IF expected IS NULL OR p_secret IS DISTINCT FROM expected THEN
    RETURN jsonb_build_object('ok', false, 'message', 'secret invalide');
  END IF;

  IF p_numero_lv IS NULL OR length(trim(p_numero_lv)) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'numero_lv manquant');
  END IF;

  DELETE FROM voyages WHERE numero_lv = p_numero_lv;

  RETURN jsonb_build_object('ok', true, 'deleted', FOUND);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'message', sqlerrm);
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_employe_depuis_contrats()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_employe_id uuid := COALESCE(NEW.employe_id, OLD.employe_id);
  v_min_debut date;
  v_courant record;
BEGIN
  SELECT min(date_debut) INTO v_min_debut FROM contrats WHERE employe_id = v_employe_id;

  IF v_min_debut IS NULL THEN
    -- Plus aucun contrat (purge) : purger_employe_rh gère la suppression
    -- complète de la ligne employes, rien à synchroniser ici.
    RETURN COALESCE(NEW, OLD);
  END IF;

  SELECT * INTO v_courant FROM contrats
  WHERE employe_id = v_employe_id
  ORDER BY date_debut DESC, created_at DESC
  LIMIT 1;

  UPDATE employes SET
    date_entree        = v_min_debut,
    date_sortie         = v_courant.date_fin,
    type_contrat        = v_courant.type_contrat,
    classe_num          = v_courant.classe_num,
    taux_horaire        = v_courant.taux_horaire,
    heures_semaine      = v_courant.heures_semaine,
    heures_sup_semaine  = v_courant.heures_sup_semaine,
    poste               = v_courant.poste,
    updated_at          = now()
  WHERE id = v_employe_id;

  RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE OR REPLACE FUNCTION public.upsert_conge_rh(p_id uuid, p_employe_id uuid, p_type text, p_date_debut date, p_date_fin date, p_jours numeric, p_motif text, p_notes text, p_demi_journee text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE v_id uuid; v_old public.conges%ROWTYPE; v_txt text;
BEGIN
  PERFORM public._exiger_admin_rh();
  IF p_employe_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Salarié requis.');
  END IF;
  IF p_type NOT IN ('cp','maladie','evenement_familial','sans_solde','autre') THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Type de congé invalide.');
  END IF;
  IF p_type = 'autre' AND coalesce(trim(p_motif), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Précisez le motif pour « Autre ».');
  END IF;
  IF p_date_fin < p_date_debut THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Date de fin avant la date de début.');
  END IF;
  IF p_demi_journee IS NOT NULL AND (p_demi_journee NOT IN ('am','pm') OR p_date_debut <> p_date_fin) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Une demi-journée ne porte que sur un seul jour.');
  END IF;
  IF public._periode_verrouillee(p_employe_id, p_date_debut, p_date_fin) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Une semaine verrouillée est concernée par cette période — déverrouillez-la avant de modifier ce congé.');
  END IF;
  IF p_id IS NOT NULL THEN
    SELECT * INTO v_old FROM public.conges WHERE id = p_id;
    IF FOUND AND public._periode_verrouillee(v_old.employe_id, v_old.date_debut, v_old.date_fin) THEN
      RETURN jsonb_build_object('ok', false, 'message', 'L''absence actuelle touche une semaine verrouillée — déverrouillez-la d''abord.');
    END IF;
    UPDATE public.conges SET employe_id = p_employe_id, type = p_type, date_debut = p_date_debut, date_fin = p_date_fin,
      jours = p_jours, motif = p_motif, notes = p_notes, demi_journee = p_demi_journee, updated_at = now()
    WHERE id = p_id RETURNING id INTO v_id;
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO public.conges (employe_id, type, date_debut, date_fin, jours, motif, notes, demi_journee)
    VALUES (p_employe_id, p_type, p_date_debut, p_date_fin, p_jours, p_motif, p_notes, p_demi_journee)
    RETURNING id INTO v_id;
  END IF;
  v_txt := public._conge_label(p_type)
    || CASE WHEN p_date_debut = p_date_fin THEN ' le ' || public._fmt_jour(p_date_debut)
            || CASE p_demi_journee WHEN 'am' THEN ' (matin)' WHEN 'pm' THEN ' (après-midi)' ELSE '' END
       ELSE ' du ' || public._fmt_jour(p_date_debut) || ' au ' || public._fmt_jour(p_date_fin) END
    || ' (' || public._fmt_num(p_jours) || ' j)';
  PERFORM public._journal(p_employe_id, CASE WHEN v_old.id IS NOT NULL THEN 'Absence modifiée — ' ELSE 'Absence — ' END || v_txt, coalesce(p_motif, p_notes));
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.upsert_contrat_rh(p_employe_id uuid, p_date_debut date, p_date_fin date, p_type_contrat text, p_classe_num smallint, p_taux_horaire numeric, p_heures_semaine numeric, p_heures_sup_semaine numeric, p_poste text, p_forfait_jour boolean DEFAULT false, p_forfait_jours_an smallint DEFAULT NULL::smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_id uuid;
BEGIN
  PERFORM public._exiger_admin_rh();
  IF p_employe_id IS NULL OR p_date_debut IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Salarié et date de début requis.');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM employes WHERE id = p_employe_id AND supprime = false) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Salarié introuvable ou supprimé.');
  END IF;

  INSERT INTO contrats (employe_id, date_debut, date_fin, type_contrat, classe_num, taux_horaire, heures_semaine, heures_sup_semaine, poste, forfait_jour, forfait_jours_an)
  VALUES (p_employe_id, p_date_debut, p_date_fin, p_type_contrat, p_classe_num, p_taux_horaire, p_heures_semaine, p_heures_sup_semaine, p_poste, p_forfait_jour, p_forfait_jours_an)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.upsert_employe_pointage(p_nom text, p_prenom text, p_pin text, p_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_id uuid;
BEGIN
  IF length(p_pin) <> 4 OR p_pin !~ '^[0-9]{4}$' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'PIN invalide (4 chiffres attendus).');
  END IF;

  IF trim(p_nom) = '' OR trim(p_prenom) = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Nom et prenom requis.');
  END IF;

  IF p_id IS NOT NULL THEN
    UPDATE employes SET
      nom        = p_nom,
      prenom     = p_prenom,
      pin_hash   = crypt(p_pin, gen_salt('bf', 12)),
      actif      = true,
      updated_at = now()
    WHERE id = p_id
    RETURNING id INTO v_id;
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO employes (nom, prenom, pin_hash)
    VALUES (p_nom, p_prenom, crypt(p_pin, gen_salt('bf', 12)))
    ON CONFLICT (nom, prenom) DO UPDATE SET
      pin_hash   = EXCLUDED.pin_hash,
      actif      = true,
      updated_at = now()
    RETURNING id INTO v_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.upsert_employe_rh(p_id uuid, p_nom text, p_prenom text, p_classe_num smallint, p_taux_horaire numeric, p_heures_semaine numeric, p_heures_sup_semaine numeric, p_date_entree date, p_date_sortie date, p_type_contrat text, p_poste text, p_notes text, p_adresse text DEFAULT NULL::text, p_telephone_perso text DEFAULT NULL::text, p_email_perso text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_id uuid;
  v_contrat_id uuid;
BEGIN
  PERFORM public._exiger_admin_rh();
  IF trim(coalesce(p_nom, '')) = '' OR trim(coalesce(p_prenom, '')) = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Nom et prénom requis.');
  END IF;

  IF p_id IS NOT NULL THEN
    UPDATE employes SET
      nom = p_nom, prenom = p_prenom, notes = p_notes,
      adresse = p_adresse, telephone_perso = p_telephone_perso, email_perso = p_email_perso,
      supprime = false, updated_at = now()
    WHERE id = p_id
    RETURNING id INTO v_id;
  END IF;

  IF v_id IS NULL THEN
    SELECT id INTO v_id FROM employes
    WHERE unaccent(lower(nom)) = unaccent(lower(p_nom))
      AND unaccent(lower(prenom)) = unaccent(lower(p_prenom))
    LIMIT 1;

    IF v_id IS NOT NULL THEN
      UPDATE employes SET
        nom = p_nom, prenom = p_prenom, notes = p_notes,
        adresse = p_adresse, telephone_perso = p_telephone_perso, email_perso = p_email_perso,
        supprime = false, updated_at = now()
      WHERE id = v_id;
    ELSE
      INSERT INTO employes (nom, prenom, pin_hash, notes, adresse, telephone_perso, email_perso)
      VALUES (p_nom, p_prenom, NULL, p_notes, p_adresse, p_telephone_perso, p_email_perso)
      RETURNING id INTO v_id;
    END IF;
  END IF;

  SELECT id INTO v_contrat_id FROM contrats
  WHERE employe_id = v_id
  ORDER BY date_debut DESC, created_at DESC
  LIMIT 1;

  IF v_contrat_id IS NULL THEN
    INSERT INTO contrats (employe_id, date_debut, date_fin, type_contrat, classe_num, taux_horaire, heures_semaine, heures_sup_semaine, poste)
    VALUES (v_id, COALESCE(p_date_entree, current_date), p_date_sortie, p_type_contrat, p_classe_num, p_taux_horaire, p_heures_semaine, p_heures_sup_semaine, p_poste);
  ELSE
    UPDATE contrats SET
      type_contrat = p_type_contrat,
      classe_num = p_classe_num,
      taux_horaire = p_taux_horaire,
      heures_semaine = p_heures_semaine,
      heures_sup_semaine = p_heures_sup_semaine,
      poste = p_poste,
      date_fin = p_date_sortie
    WHERE id = v_contrat_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.valider_semaine(p_employe_id uuid, p_semaine_debut date, p_valide_par text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$ BEGIN RETURN public.verrouiller_semaine_pour(ARRAY[p_employe_id], p_semaine_debut); END; $function$;

CREATE OR REPLACE FUNCTION public.verifier_pointage(p_employe_id uuid, p_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_dernier_type text;
  v_tz           text := 'Europe/Paris';
  v_today        date := (now() AT TIME ZONE v_tz)::date;
BEGIN
  -- Dernier type de pointage valide de l'employé aujourd'hui
  SELECT type INTO v_dernier_type
  FROM pointages
  WHERE employe_id = p_employe_id
    AND valide = true
    AND (horodatage AT TIME ZONE v_tz)::date = v_today
  ORDER BY horodatage DESC
  LIMIT 1;

  CASE p_type
    WHEN 'ENTREE' THEN
      IF v_dernier_type IS NOT NULL AND v_dernier_type <> 'SORTIE' THEN
        RETURN jsonb_build_object(
          'ok', false,
          'message', 'Déjà en service — pointez votre sortie d''abord.'
        );
      END IF;

    WHEN 'SORTIE' THEN
      IF v_dernier_type IS NULL OR v_dernier_type NOT IN ('ENTREE', 'PAUSE_FIN') THEN
        RETURN jsonb_build_object(
          'ok', false,
          'message', 'Aucune entrée en cours — impossible de pointer une sortie.'
        );
      END IF;

    WHEN 'PAUSE_DEBUT' THEN
      IF v_dernier_type IS NULL OR v_dernier_type NOT IN ('ENTREE', 'PAUSE_FIN') THEN
        RETURN jsonb_build_object(
          'ok', false,
          'message', 'Pointez d''abord votre entrée avant de déclarer une pause.'
        );
      END IF;

    WHEN 'PAUSE_FIN' THEN
      IF v_dernier_type IS NULL OR v_dernier_type <> 'PAUSE_DEBUT' THEN
        RETURN jsonb_build_object(
          'ok', false,
          'message', 'Aucune pause en cours à terminer.'
        );
      END IF;

    ELSE
      RETURN jsonb_build_object(
        'ok', false,
        'message', 'Type de pointage inconnu : ' || p_type
      );
  END CASE;

  RETURN jsonb_build_object('ok', true, 'message', 'OK');
END;
$function$;

CREATE OR REPLACE FUNCTION public.verrouiller_semaine_pour(p_employes uuid[], p_semaine_debut date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE n int;
BEGIN
  PERFORM public._exiger_admin_rh();
  IF p_semaine_debut <> public._lundi(p_semaine_debut) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'La semaine doit commencer un lundi.');
  END IF;
  INSERT INTO public.semaines_validees (employe_id, semaine_debut, valide_par)
  SELECT unnest(p_employes), p_semaine_debut, public._auteur_rh()
  ON CONFLICT (employe_id, semaine_debut) DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n > 0 THEN
    PERFORM public._journal(CASE WHEN array_length(p_employes, 1) = 1 THEN p_employes[1] END,
      'Semaine S' || extract(week from p_semaine_debut)::int || ' verrouillée'
      || CASE WHEN array_length(p_employes, 1) = 1 THEN '' ELSE ' pour ' || n || ' salarié(s)' END);
  END IF;
  RETURN jsonb_build_object('ok', true, 'n', n);
END;
$function$;
