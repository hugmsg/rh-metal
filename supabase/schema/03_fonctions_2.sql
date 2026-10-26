CREATE OR REPLACE FUNCTION public.assurer_jours_feries(p_annee integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE p date;
BEGIN
  PERFORM public._exiger_admin_rh();
  IF p_annee < 2026 OR p_annee > extract(year from current_date)::int + 3 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Année hors limites.');
  END IF;
  IF EXISTS (SELECT 1 FROM public.jours_feries_annees WHERE annee = p_annee) THEN
    RETURN jsonb_build_object('ok', true, 'nouveau', false);
  END IF;
  p := public._paques(p_annee);
  INSERT INTO public.jours_feries (date, libelle) VALUES
    (make_date(p_annee, 1, 1), 'Jour de l''an'), (p + 1, 'Lundi de Pâques'), (make_date(p_annee, 5, 1), 'Fête du travail'),
    (make_date(p_annee, 5, 8), 'Victoire 1945'), (p + 39, 'Ascension'), (p + 50, 'Lundi de Pentecôte'),
    (make_date(p_annee, 7, 14), 'Fête nationale'), (make_date(p_annee, 8, 15), 'Assomption'), (make_date(p_annee, 11, 1), 'Toussaint'),
    (make_date(p_annee, 11, 11), 'Armistice'), (make_date(p_annee, 12, 25), 'Noël')
  ON CONFLICT DO NOTHING;
  INSERT INTO public.jours_feries_annees (annee) VALUES (p_annee);
  PERFORM public._journal(NULL, 'Jours fériés ' || p_annee || ' ajoutés automatiquement');
  RETURN jsonb_build_object('ok', true, 'nouveau', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.authentifier_par_pin(p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_employe employes%ROWTYPE;
BEGIN
  IF length(p_pin) <> 4 OR p_pin !~ '^[0-9]{4}$' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Format PIN invalide (4 chiffres attendus).');
  END IF;

  SELECT * INTO v_employe
  FROM employes
  WHERE actif = true
    AND supprime = false
    AND (date_sortie IS NULL OR date_sortie >= current_date)
    AND crypt(p_pin, pin_hash) = pin_hash
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Code PIN incorrect.');
  END IF;

  RETURN jsonb_build_object(
    'ok',     true,
    'id',     v_employe.id,
    'nom',    v_employe.nom,
    'prenom', v_employe.prenom
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.cloturer_mois(p_mois date, p_resume text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE m date := date_trunc('month', p_mois)::date; d date;
BEGIN
  PERFORM public._exiger_admin_rh();
  IF (m + interval '1 month')::date > current_date THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Ce mois n''est pas terminé : il pourra être clôturé à partir du ' || to_char(m + interval '1 month', 'DD/MM/YYYY') || '.');
  END IF;
  SELECT debut_pointage INTO d FROM public.rh_parametres_temps WHERE id;
  IF d IS NOT NULL AND (m + interval '1 month' - interval '1 day')::date < d THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Ce mois est antérieur à la mise en service du pointage : rien à clôturer.');
  END IF;
  INSERT INTO public.mois_clotures (mois, cloture, cloture_le, cloture_par)
  VALUES (m, true, now(), public._auteur_rh())
  ON CONFLICT (mois) DO UPDATE SET cloture = true, cloture_le = now(), cloture_par = EXCLUDED.cloture_par;
  PERFORM public._journal(NULL, 'Mois de ' || to_char(m, 'MM/YYYY') || ' verrouillé' || coalesce(' — ' || p_resume, ''));
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.debloquer_pin_kiosque()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM _exiger_admin_rh();
  INSERT INTO pin_essais (auth_user_id, resultat)
  SELECT DISTINCT auth_user_id, 'deblocage' FROM pin_essais WHERE at >= now() - interval '1 day';
  PERFORM _journal(NULL, 'PIN kiosque débloqué', NULL);
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.definir_acces_externe(p_employe_id uuid, p_externe boolean, p_motif text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE e record;
BEGIN
  PERFORM public._exiger_admin_rh();
  IF coalesce(trim(p_motif), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Le motif est obligatoire.');
  END IF;
  SELECT id, prenom, nom, acces_externe, supprime INTO e FROM public.employes WHERE id = p_employe_id FOR UPDATE;
  IF e.id IS NULL OR e.supprime THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Salarié introuvable.');
  END IF;
  IF e.acces_externe = p_externe THEN
    RETURN jsonb_build_object('ok', false, 'message', CASE WHEN p_externe THEN 'L''accès externe est déjà accordé.' ELSE 'Pas d''accès externe à retirer.' END);
  END IF;
  PERFORM public._journal(p_employe_id,
    CASE WHEN p_externe THEN 'Accès externe accordé à ' ELSE 'Accès externe retiré à ' END || e.prenom || ' ' || e.nom, p_motif);
  UPDATE public.employes SET acces_externe = p_externe, updated_at = now() WHERE id = p_employe_id;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.definir_admin_rh(p_employe_id uuid, p_admin boolean, p_motif text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE e record;
BEGIN
  PERFORM public._exiger_admin_rh();
  IF coalesce(trim(p_motif), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Le motif est obligatoire.');
  END IF;
  SELECT id, prenom, nom, is_rh_admin, auth_user_id, supprime INTO e FROM public.employes WHERE id = p_employe_id FOR UPDATE;
  IF e.id IS NULL OR e.supprime THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Salarié introuvable.');
  END IF;
  IF e.is_rh_admin = p_admin THEN
    RETURN jsonb_build_object('ok', false, 'message', CASE WHEN p_admin THEN 'Déjà administrateur RH.' ELSE 'N''est pas administrateur RH.' END);
  END IF;
  IF p_admin AND e.auth_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Pas de compte de connexion : active d''abord l''accès portail dans sa fiche.');
  END IF;
  IF NOT p_admin AND NOT EXISTS (
    SELECT 1 FROM public.employes
    WHERE id <> p_employe_id AND is_rh_admin AND supprime = false AND auth_user_id IS NOT NULL) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Il doit toujours rester au moins un administrateur RH : nommes-en un autre avant de retirer celui-ci.');
  END IF;
  -- Journal avant la mise à jour : l'auteur est encore résolu si l'admin se retire lui-même.
  PERFORM public._journal(p_employe_id,
    CASE WHEN p_admin THEN 'Droit administrateur RH accordé à ' ELSE 'Droit administrateur RH retiré à ' END || e.prenom || ' ' || e.nom, p_motif);
  UPDATE public.employes SET is_rh_admin = p_admin, updated_at = now() WHERE id = p_employe_id;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.definir_debut_pointage(p_date date, p_motif text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE o date; m date;
BEGIN
  PERFORM public._exiger_admin_rh();
  IF coalesce(trim(p_motif), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Le motif est obligatoire.');
  END IF;
  IF p_date IS NOT NULL AND (p_date < date '2026-01-01' OR p_date > current_date + 365) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Date hors limites.');
  END IF;
  SELECT debut_pointage INTO o FROM public.rh_parametres_temps WHERE id;
  SELECT min(mois) INTO m FROM public.mois_clotures
   WHERE cloture AND (mois + interval '1 month' - interval '1 day')::date
         >= coalesce(least(o, p_date), o, p_date, date '2000-01-01');
  IF m IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'message',
      'Le mois de ' || to_char(m, 'MM/YYYY') || ' est verrouillé : changer la date modifierait ses heures. Déverrouille-le d''abord.');
  END IF;
  IF o IS NOT DISTINCT FROM p_date THEN
    RETURN jsonb_build_object('ok', false, 'message', 'La date n''a pas changé.');
  END IF;
  UPDATE public.rh_parametres_temps SET debut_pointage = p_date WHERE id;
  PERFORM public._journal(NULL, 'Mise en service du pointage : '
    || coalesce(public._fmt_jour(o), 'non fixée') || ' → ' || coalesce(public._fmt_jour(p_date), 'non fixée'), p_motif);
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.definir_statut_jour(p_employe_id uuid, p_date date, p_statut text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  PERFORM public._exiger_admin_rh();
  IF p_statut NOT IN ('ferie', 'non_travaille') THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Statut invalide.');
  END IF;
  IF public._semaine_est_verrouillee(p_employe_id, p_date) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Semaine verrouillée — déverrouillez-la avant de modifier ce jour.');
  END IF;
  INSERT INTO public.jours_statut (employe_id, date, statut)
  VALUES (p_employe_id, p_date, p_statut)
  ON CONFLICT (employe_id, date) DO UPDATE SET statut = EXCLUDED.statut, created_at = now();
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.detecter_anomalies_oubli_sortie()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_count integer;
BEGIN
  PERFORM public._exiger_admin_rh();
  UPDATE heures_journalieres
  SET statut     = 'ANOMALIE',
      updated_at = now()
  WHERE date = current_date - 1
    AND statut IN ('EN_SERVICE', 'EN_PAUSE')
    AND heure_sortie IS NULL;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;  -- nombre d'anomalies créées
END;
$function$;

CREATE OR REPLACE FUNCTION public.deverrouiller_semaine(p_employe_id uuid, p_semaine_debut date, p_motif text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$ BEGIN RETURN public.deverrouiller_semaine_pour(ARRAY[p_employe_id], p_semaine_debut, coalesce(nullif(trim(p_motif), ''), 'Déverrouillage depuis l''ancien onglet Contrôle')); END; $function$;

CREATE OR REPLACE FUNCTION public.deverrouiller_semaine_pour(p_employes uuid[], p_semaine_debut date, p_motif text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE n int;
BEGIN
  PERFORM public._exiger_admin_rh();
  IF coalesce(trim(p_motif), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Un motif est obligatoire pour déverrouiller.');
  END IF;
  DELETE FROM public.semaines_validees WHERE employe_id = ANY (p_employes) AND semaine_debut = p_semaine_debut;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n > 0 THEN
    PERFORM public._rouvrir_mois_de_semaine(p_semaine_debut, p_motif);
    PERFORM public._journal(CASE WHEN array_length(p_employes, 1) = 1 THEN p_employes[1] END,
      'Semaine S' || extract(week from p_semaine_debut)::int || ' déverrouillée'
      || CASE WHEN array_length(p_employes, 1) = 1 THEN '' ELSE ' pour ' || n || ' salarié(s)' END, p_motif);
  END IF;
  RETURN jsonb_build_object('ok', true, 'n', n);
END;
$function$;

CREATE OR REPLACE FUNCTION public.dissocier_badge_nfc(p_employe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  PERFORM public._exiger_admin_rh();
  UPDATE employes SET nfc_uid = NULL, updated_at = now() WHERE id = p_employe_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Salarié introuvable.');
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.effacer_statut_jour(p_employe_id uuid, p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  PERFORM public._exiger_admin_rh();
  IF public._semaine_est_verrouillee(p_employe_id, p_date) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Semaine verrouillée — déverrouillez-la avant de modifier ce jour.');
  END IF;
  DELETE FROM public.jours_statut WHERE employe_id = p_employe_id AND date = p_date;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.emettre_signal_nfc(p_event text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  PERFORM realtime.send(p_payload, p_event, 'nfc-badge-scans', false);
END;
$function$;

CREATE OR REPLACE FUNCTION public.employes_broadcast_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_row employes;
BEGIN
  v_row := COALESCE(NEW, OLD);
  PERFORM realtime.send(
    jsonb_build_object('op', TG_OP, 'id', v_row.id),
    'employes_changed',
    'employes-changes',
    false
  );
  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.enregistrer_jour_ferie(p_date date, p_libelle text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  PERFORM public._exiger_admin_rh();
  IF coalesce(trim(p_libelle), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Nom du jour férié requis.');
  END IF;
  INSERT INTO public.jours_feries (date, libelle) VALUES (p_date, trim(p_libelle))
  ON CONFLICT (date) DO UPDATE SET libelle = EXCLUDED.libelle;
  PERFORM public._journal(NULL, 'Jour férié ajouté — ' || trim(p_libelle) || ' le ' || public._fmt_jour(p_date));
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.enregistrer_parametres_temps(p_semaine_cheval text, p_heures_ref numeric, p_heures_25 numeric, p_cp_annuels numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE o public.rh_parametres_temps%ROWTYPE; v text := '';
BEGIN
  PERFORM public._exiger_admin_rh();
  IF p_semaine_cheval NOT IN ('fin','debut') OR p_heures_ref <= 0 OR p_heures_25 < 0 OR p_cp_annuels <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Valeurs invalides.');
  END IF;
  SELECT * INTO o FROM public.rh_parametres_temps WHERE id;
  UPDATE public.rh_parametres_temps SET semaine_cheval = p_semaine_cheval, heures_ref = p_heures_ref,
    heures_25 = p_heures_25, cp_annuels = p_cp_annuels WHERE id;
  IF o.semaine_cheval <> p_semaine_cheval THEN v := v || 'semaines à cheval → mois de ' || CASE p_semaine_cheval WHEN 'fin' THEN 'fin' ELSE 'début' END || '; '; END IF;
  IF o.heures_ref <> p_heures_ref THEN v := v || 'durée de référence ' || o.heures_ref || ' → ' || p_heures_ref || ' h; '; END IF;
  IF o.heures_25 <> p_heures_25 THEN v := v || 'heures à 25 % ' || o.heures_25 || ' → ' || p_heures_25 || ' h; '; END IF;
  IF o.cp_annuels <> p_cp_annuels THEN v := v || 'CP acquis ' || o.cp_annuels || ' → ' || p_cp_annuels || ' j/an; '; END IF;
  IF v <> '' THEN PERFORM public._journal(NULL, 'Paramètres temps de travail : ' || rtrim(v, '; ')); END IF;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.enregistrer_voyage(p_numero_lv text, p_type text, p_destination text, p_doc_annexe text, p_commande text, p_commentaire text, p_poids numeric, p_ml numeric, p_grutage boolean, p_transporteur text, p_parti boolean DEFAULT false, p_marchandises_desc text DEFAULT NULL::text, p_destination_adresse text DEFAULT NULL::text, p_conducteur text DEFAULT NULL::text, p_immat_moteur text DEFAULT NULL::text, p_immat_semi text DEFAULT NULL::text, p_expediteur text DEFAULT NULL::text, p_convoi boolean DEFAULT false, p_pdf_url text DEFAULT NULL::text, p_date_creation timestamp with time zone DEFAULT NULL::timestamp with time zone, p_destination_lat numeric DEFAULT NULL::numeric, p_destination_lon numeric DEFAULT NULL::numeric, p_livraison_prevue date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  IF p_numero_lv IS NULL OR length(trim(p_numero_lv)) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'numero_lv manquant');
  END IF;

  INSERT INTO voyages (numero_lv, type, date_creation, destination, commentaire, poids, ml, grutage, transporteur, parti, parti_le, marchandises_desc, destination_adresse, destination_lat, destination_lon, livraison_prevue)
  VALUES (p_numero_lv, COALESCE(NULLIF(p_type, ''), 'LV'), COALESCE(p_date_creation, now()), p_destination, NULLIF(p_commentaire, ''),
          p_poids, p_ml, COALESCE(p_grutage, false), NULLIF(p_transporteur, ''),
          COALESCE(p_parti, false), CASE WHEN COALESCE(p_parti, false) THEN now() ELSE NULL END,
          NULLIF(p_marchandises_desc, ''), NULLIF(p_destination_adresse, ''), p_destination_lat, p_destination_lon, p_livraison_prevue)
  ON CONFLICT (numero_lv) DO UPDATE SET
    type                = EXCLUDED.type,
    date_creation       = EXCLUDED.date_creation,
    destination         = EXCLUDED.destination,
    commentaire         = EXCLUDED.commentaire,
    poids               = EXCLUDED.poids,
    ml                  = EXCLUDED.ml,
    grutage             = EXCLUDED.grutage,
    transporteur        = EXCLUDED.transporteur,
    marchandises_desc   = EXCLUDED.marchandises_desc,
    destination_adresse = EXCLUDED.destination_adresse,
    destination_lat     = EXCLUDED.destination_lat,
    destination_lon     = EXCLUDED.destination_lon,
    livraison_prevue    = EXCLUDED.livraison_prevue;

  INSERT INTO voyages_internes (numero_lv, doc_annexe, commande, conducteur, immat_moteur, immat_semi, expediteur, convoi, pdf_url)
  VALUES (p_numero_lv, NULLIF(p_doc_annexe, ''), NULLIF(p_commande, ''), NULLIF(p_conducteur, ''),
          NULLIF(p_immat_moteur, ''), NULLIF(p_immat_semi, ''), NULLIF(p_expediteur, ''),
          COALESCE(p_convoi, false), NULLIF(p_pdf_url, ''))
  ON CONFLICT (numero_lv) DO UPDATE SET
    doc_annexe   = EXCLUDED.doc_annexe,
    commande     = EXCLUDED.commande,
    conducteur   = EXCLUDED.conducteur,
    immat_moteur = EXCLUDED.immat_moteur,
    immat_semi   = EXCLUDED.immat_semi,
    expediteur   = EXCLUDED.expediteur,
    convoi       = EXCLUDED.convoi,
    pdf_url      = EXCLUDED.pdf_url;

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'message', sqlerrm);
END;
$function$;

CREATE OR REPLACE FUNCTION public.etat_pin_kiosque()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_res jsonb := '[]'::jsonb;
  r record;
  b record;
BEGIN
  PERFORM _exiger_admin_rh();
  FOR r IN SELECT DISTINCT auth_user_id FROM pin_essais WHERE at >= now() - interval '1 day' LOOP
    SELECT * INTO b FROM _pin_blocage(r.auth_user_id);
    IF b.echecs_jour > 0 OR b.bloque_jusqua IS NOT NULL THEN
      v_res := v_res || jsonb_build_object(
        'compte', CASE WHEN EXISTS (SELECT 1 FROM comptes_kiosque WHERE auth_user_id = r.auth_user_id)
                       THEN 'Kiosque' ELSE coalesce((SELECT prenom || ' ' || nom FROM employes WHERE auth_user_id = r.auth_user_id LIMIT 1), 'Autre compte') END,
        'echecs_jour', b.echecs_jour,
        'bloque_jusqua', b.bloque_jusqua,
        'raison', b.raison);
    END IF;
  END LOOP;
  RETURN v_res;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_admins_rh()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  PERFORM public._exiger_admin_rh();
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'id', e.id, 'nom', e.nom, 'prenom', e.prenom, 'is_rh_admin', e.is_rh_admin,
             'compte', e.auth_user_id IS NOT NULL, 'moi', e.auth_user_id = auth.uid(),
             'date_sortie', e.date_sortie)
           ORDER BY e.is_rh_admin DESC, e.nom, e.prenom)
    FROM public.employes e
    WHERE e.supprime = false AND (e.is_rh_admin OR e.auth_user_id IS NOT NULL)), '[]'::jsonb);
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_conges_rh()
 RETURNS SETOF conges
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  SELECT public._exiger_admin_rh();
  SELECT * FROM conges ORDER BY date_debut DESC;
$function$;

CREATE OR REPLACE FUNCTION public.get_contrats_rh(p_employe_id uuid)
 RETURNS TABLE(id uuid, date_debut date, date_fin date, type_contrat text, classe_num smallint, taux_horaire numeric, heures_semaine numeric, heures_sup_semaine numeric, poste text, forfait_jour boolean, forfait_jours_an smallint)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  SELECT public._exiger_admin_rh();
  SELECT id, date_debut, date_fin, type_contrat, classe_num, taux_horaire, heures_semaine, heures_sup_semaine, poste, forfait_jour, forfait_jours_an
  FROM contrats
  WHERE employe_id = p_employe_id
  ORDER BY date_debut DESC, created_at DESC;
$function$;

CREATE OR REPLACE FUNCTION public.get_employes_annuaire()
 RETURNS TABLE(id uuid, nom text, prenom text, poste text, a_fiche_rh boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT id, nom, prenom, poste, classe_num IS NOT NULL
  FROM employes
  WHERE actif = true
    AND supprime = false
    AND (date_sortie IS NULL OR date_sortie >= current_date)
  ORDER BY nom, prenom;
$function$;

CREATE OR REPLACE FUNCTION public.get_employes_rh()
 RETURNS TABLE(id uuid, nom text, prenom text, classe_num smallint, taux_horaire numeric, heures_semaine numeric, heures_sup_semaine numeric, date_entree date, date_sortie date, type_contrat text, poste text, notes text, has_badge boolean, adresse text, telephone_perso text, email_perso text, alerte_vue boolean, portail_actif boolean, hausse_date date, hausse_taux numeric, acces_externe boolean)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  SELECT public._exiger_admin_rh();
  SELECT public._appliquer_remunerations();
  SELECT e.id, e.nom, e.prenom, e.classe_num, e.taux_horaire, e.heures_semaine, e.heures_sup_semaine,
         e.date_entree, e.date_sortie, e.type_contrat, e.poste, e.notes,
         e.nfc_uid IS NOT NULL,
         e.adresse, e.telephone_perso, e.email_perso,
         COALESCE(c.alerte_vue, false),
         e.auth_user_id IS NOT NULL,
         h.date_effet, h.taux_horaire,
         e.acces_externe
  FROM employes e
  LEFT JOIN LATERAL (
    SELECT c.id, c.date_debut, c.alerte_vue FROM contrats c
    WHERE c.employe_id = e.id
    ORDER BY c.date_debut DESC, c.created_at DESC LIMIT 1
  ) c ON true
  LEFT JOIN LATERAL (
    SELECT r.date_effet, r.taux_horaire FROM remunerations r
    WHERE r.contrat_id = c.id
      AND r.date_effet > GREATEST((now() AT TIME ZONE 'Europe/Paris')::date, c.date_debut)
    ORDER BY r.date_effet, r.created_at LIMIT 1
  ) h ON true
  WHERE e.supprime = false
  ORDER BY e.nom, e.prenom;
$function$;

CREATE OR REPLACE FUNCTION public.get_employes_supprimes_rh()
 RETURNS TABLE(id uuid, nom text, prenom text, date_entree date, date_sortie date, type_contrat text, poste text, updated_at timestamp with time zone)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  SELECT public._exiger_admin_rh();
  SELECT id, nom, prenom, date_entree, date_sortie, type_contrat, poste, updated_at
  FROM employes
  WHERE supprime = true
  ORDER BY updated_at DESC;
$function$;

CREATE OR REPLACE FUNCTION public.get_mes_conges_rh()
 RETURNS SETOF conges
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  SELECT c.* FROM conges c
  JOIN employes e ON e.id = c.employe_id
  WHERE e.auth_user_id = auth.uid() AND e.supprime = false
  ORDER BY c.date_debut DESC;
$function$;

CREATE OR REPLACE FUNCTION public.get_mes_heures_rh(p_debut date, p_fin date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_employe_id uuid;
BEGIN
  SELECT id INTO v_employe_id FROM employes WHERE auth_user_id = auth.uid() AND supprime = false;
  IF v_employe_id IS NULL THEN
    RETURN jsonb_build_object('ok', false);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'heures', COALESCE((SELECT jsonb_agg(h) FROM heures_rapport_vue h
                         WHERE h.employe_id = v_employe_id AND h.date BETWEEN p_debut AND p_fin), '[]'::jsonb),
    'badges', COALESCE((SELECT jsonb_agg(p) FROM pointages_rapport_vue p
                         WHERE p.employe_id = v_employe_id AND p.date BETWEEN p_debut AND p_fin), '[]'::jsonb),
    'corrections', COALESCE((SELECT jsonb_agg(c) FROM heures_corrections c
                              WHERE c.employe_id = v_employe_id AND c.date BETWEEN p_debut AND p_fin), '[]'::jsonb)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_mon_role_rh()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_employe record;
BEGIN
  SELECT id, nom, prenom, is_rh_admin, date_entree INTO v_employe
  FROM employes WHERE auth_user_id = auth.uid() AND supprime = false;

  IF v_employe.id IS NULL THEN
    RETURN jsonb_build_object('ok', false);
  END IF;

  RETURN jsonb_build_object('ok', true, 'employe_id', v_employe.id, 'nom', v_employe.nom,
    'prenom', v_employe.prenom, 'is_rh_admin', v_employe.is_rh_admin, 'date_entree', v_employe.date_entree);
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_pointages_periode_rh(p_debut date, p_fin date)
 RETURNS TABLE(id uuid, employe_id uuid, type text, horodatage timestamp with time zone, date date, source text, valide boolean, raison_modif text, modifie_par text, horodatage_origine timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public._exiger_admin_rh();
  RETURN QUERY
    SELECT p.id, p.employe_id, p.type, p.horodatage, (p.horodatage AT TIME ZONE 'Europe/Paris')::date,
           p.source, p.valide, p.raison_modif, p.modifie_par, p.horodatage_origine
    FROM public.pointages p
    WHERE (p.horodatage AT TIME ZONE 'Europe/Paris')::date BETWEEN p_debut AND p_fin
    ORDER BY p.horodatage;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_remunerations_rh(p_employe_id uuid)
 RETURNS TABLE(id uuid, contrat_id uuid, contrat_debut date, contrat_fin date, type_contrat text, date_effet date, classe_num smallint, taux_horaire numeric, heures_semaine numeric, heures_sup_semaine numeric, poste text, motif text, note text, saisi_par text, created_at timestamp with time zone, a_venir boolean)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT public._exiger_admin_rh();
  SELECT r.id, c.id, c.date_debut, c.date_fin, c.type_contrat,
         r.date_effet, r.classe_num, r.taux_horaire, r.heures_semaine, r.heures_sup_semaine,
         r.poste, r.motif, r.note, r.saisi_par, r.created_at,
         r.date_effet > GREATEST((now() AT TIME ZONE 'Europe/Paris')::date, c.date_debut)
  FROM remunerations r
  JOIN contrats c ON c.id = r.contrat_id
  WHERE r.employe_id = p_employe_id
  ORDER BY c.date_debut DESC, c.created_at DESC, r.date_effet DESC, r.created_at DESC;
$function$;
