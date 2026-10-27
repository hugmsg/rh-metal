CREATE OR REPLACE FUNCTION public.kiosque_liste_jour()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tz    text := 'Europe/Paris';
  v_today date := (now() AT TIME ZONE v_tz)::date;
BEGIN
  PERFORM _exiger_kiosque_ou_admin_rh();
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'id',      e.id,
             'prenom',  e.prenom,
             'nom',     e.nom,
             'statut',  CASE WHEN d.dernier IS NULL THEN 'absent'
                             WHEN d.dernier = 'SORTIE' THEN 'parti' ELSE 'present' END,
             'arrivee', d.arrivee,
             'depart',  CASE WHEN d.dernier = 'SORTIE' THEN d.dernier_ts END)
           ORDER BY e.prenom, e.nom)
    FROM employes e
    LEFT JOIN LATERAL (
      SELECT (array_agg(p.type ORDER BY p.horodatage DESC))[1]       AS dernier,
             max(p.horodatage)                                       AS dernier_ts,
             min(p.horodatage) FILTER (WHERE p.type = 'ENTREE')      AS arrivee
      FROM pointages p
      WHERE p.employe_id = e.id
        AND p.valide = true
        AND (p.horodatage AT TIME ZONE v_tz)::date = v_today
    ) d ON true
    WHERE e.actif = true
      AND e.supprime = false
      AND (e.date_sortie IS NULL OR e.date_sortie >= current_date)
  ), '[]'::jsonb);
END;
$function$;

CREATE OR REPLACE FUNCTION public.lier_remplacement_voyage(p_annulee text, p_remplacante text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(trim(p_annulee), '') = '' OR coalesce(trim(p_remplacante), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'numéros requis');
  END IF;
  IF p_annulee = p_remplacante THEN
    RETURN jsonb_build_object('ok', false, 'message', 'une LV ne peut pas se remplacer elle-même');
  END IF;
  UPDATE voyages_annules SET remplacee_par = p_remplacante
   WHERE numero_lv = p_annulee AND remplacee_par IS NULL;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'LV annulée introuvable ou déjà remplacée');
  END IF;
  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'message', sqlerrm);
END;
$function$;

CREATE OR REPLACE FUNCTION public.lire_historique_voyages(p_secret text, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  result jsonb;
  expected text;
BEGIN
  SELECT valeur INTO expected FROM config_interne WHERE cle = 'historique_secret';
  IF expected IS NULL OR p_secret IS DISTINCT FROM expected THEN
    RETURN jsonb_build_object('ok', false, 'message', 'secret invalide');
  END IF;

  WITH dispo AS (
    SELECT v.numero_lv, v.type, v.date_creation, v.destination, v.destination_adresse,
           v.poids, v.ml, v.grutage, v.commentaire, v.marchandises_desc, v.livraison_prevue, v.parti, v.parti_le,
           i.doc_annexe, i.commande, i.conducteur, i.immat_moteur, i.immat_semi, i.expediteur, i.convoi, i.pdf_url,
           false AS annulee, NULL::timestamptz AS annulee_le, NULL::text AS annulee_par, NULL::text AS annulation_motif, NULL::text AS remplacee_par
    FROM voyages v
    LEFT JOIN voyages_internes i ON i.numero_lv = v.numero_lv
    WHERE v.parti = false
  ),
  recents_partis AS (
    SELECT v.numero_lv, v.type, v.date_creation, v.destination, v.destination_adresse,
           v.poids, v.ml, v.grutage, v.commentaire, v.marchandises_desc, v.livraison_prevue, v.parti, v.parti_le,
           i.doc_annexe, i.commande, i.conducteur, i.immat_moteur, i.immat_semi, i.expediteur, i.convoi, i.pdf_url,
           false AS annulee, NULL::timestamptz AS annulee_le, NULL::text AS annulee_par, NULL::text AS annulation_motif, NULL::text AS remplacee_par
    FROM voyages v
    LEFT JOIN voyages_internes i ON i.numero_lv = v.numero_lv
    WHERE v.parti = true
    ORDER BY v.numero_lv::int DESC
    LIMIT GREATEST(1, LEAST(p_limit, 500))
  ),
  annules AS (
    SELECT a.numero_lv, a.type, a.date_creation, a.destination, a.destination_adresse,
           a.poids, a.ml, a.grutage, a.commentaire, a.marchandises_desc, a.livraison_prevue, coalesce(a.parti, false), a.parti_le,
           a.doc_annexe, a.commande, a.conducteur, a.immat_moteur, a.immat_semi, a.expediteur, a.convoi, a.pdf_url,
           true, a.annulee_le, a.annulee_par, a.motif, a.remplacee_par
    FROM voyages_annules a
    WHERE a.annulee_le > now() - interval '90 days'
    ORDER BY a.annulee_le DESC
    LIMIT 100
  )
  SELECT jsonb_agg(row_to_json(t) ORDER BY t.numero_lv::int DESC)
  INTO result
  FROM (
    SELECT u.*, (SELECT string_agg(x.numero_lv, ', ' ORDER BY x.numero_lv) FROM voyages_annules x WHERE x.remplacee_par = u.numero_lv) AS remplace
    FROM (SELECT * FROM dispo UNION ALL SELECT * FROM recents_partis UNION ALL SELECT * FROM annules) u
  ) t;

  RETURN jsonb_build_object('ok', true, 'history', COALESCE(result, '[]'::jsonb));
END;
$function$;

CREATE OR REPLACE FUNCTION public.marquer_alerte_contrat_vue_rh(p_employe_id uuid, p_vue boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_contrat_id uuid;
BEGIN
  PERFORM public._exiger_admin_rh();
  SELECT id INTO v_contrat_id FROM contrats
  WHERE employe_id = p_employe_id
  ORDER BY date_debut DESC, created_at DESC
  LIMIT 1;

  IF v_contrat_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Aucun contrat trouvé.');
  END IF;

  UPDATE contrats SET alerte_vue = p_vue WHERE id = v_contrat_id;

  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.marquer_export_mois(p_mois date, p_fichier text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE m date := date_trunc('month', p_mois)::date;
BEGIN
  PERFORM public._exiger_admin_rh();
  UPDATE public.mois_clotures SET exporte_le = now(), exporte_par = public._auteur_rh(), export_perime = false
  WHERE mois = m AND cloture;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Le mois doit être verrouillé avant l''export.');
  END IF;
  PERFORM public._journal(NULL, 'Export ' || p_fichier || ' téléchargé');
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.marquer_parti(p_numero_lv text, p_parti boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  UPDATE voyages
  SET parti    = p_parti,
      parti_le = CASE WHEN p_parti THEN now() ELSE NULL END
  WHERE numero_lv = p_numero_lv;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'numero_lv introuvable : ' || p_numero_lv);
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.modifier_voyage_note(p_numero_lv text, p_commentaire text, p_grutage boolean, p_livraison_prevue date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  IF p_numero_lv IS NULL OR length(trim(p_numero_lv)) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'numero_lv manquant');
  END IF;

  UPDATE voyages
  SET commentaire      = NULLIF(p_commentaire, ''),
      grutage          = COALESCE(p_grutage, false),
      livraison_prevue = p_livraison_prevue
  WHERE numero_lv = p_numero_lv;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'numero_lv introuvable : ' || p_numero_lv);
  END IF;

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'message', sqlerrm);
END;
$function$;

CREATE OR REPLACE FUNCTION public.pointer_par_nfc(p_uid text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_employe employes%ROWTYPE;
  v_res     jsonb;
BEGIN
  PERFORM _exiger_kiosque_ou_admin_rh();

  IF trim(coalesce(p_uid, '')) = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Badge illisible.');
  END IF;

  SELECT * INTO v_employe
  FROM employes
  WHERE actif = true
    AND supprime = false
    AND (date_sortie IS NULL OR date_sortie >= current_date)
    AND nfc_uid = p_uid
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Badge non reconnu.');
  END IF;

  v_res := _pointer_auto(v_employe.id, 'nfc');
  IF NOT (v_res ->> 'ok')::boolean THEN
    RETURN v_res;
  END IF;
  RETURN v_res || jsonb_build_object('id', v_employe.id, 'nom', v_employe.nom, 'prenom', v_employe.prenom);
END;
$function$;

CREATE OR REPLACE FUNCTION public.pointer_par_pin_employe(p_employe_id uuid, p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_employe employes%ROWTYPE;
  v_bloc    record;
  v_heure   text;
  v_res     jsonb;
BEGIN
  PERFORM _exiger_kiosque_ou_admin_rh();

  PERFORM pg_advisory_xact_lock(hashtext('pin_essais:' || auth.uid()::text));

  SELECT * INTO v_bloc FROM _pin_blocage(auth.uid());
  IF v_bloc.bloque_jusqua IS NOT NULL THEN
    IF v_bloc.raison = 'jour' THEN
      RETURN jsonb_build_object('ok', false, 'bloque', true,
        'message', 'Code PIN bloqué jusqu''à demain (trop d''erreurs). Utilisez votre badge ou prévenez un responsable.');
    END IF;
    v_heure := to_char(v_bloc.bloque_jusqua AT TIME ZONE 'Europe/Paris', 'HH24"h"MI');
    RETURN jsonb_build_object('ok', false, 'bloque', true,
      'message', 'Trop d''erreurs : code PIN bloqué jusqu''à ' || v_heure || '. Utilisez votre badge en attendant.');
  END IF;

  IF coalesce(p_pin, '') !~ '^[0-9]{4}$' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Format PIN invalide (4 chiffres attendus).');
  END IF;

  SELECT * INTO v_employe
  FROM employes
  WHERE id = p_employe_id
    AND actif = true
    AND supprime = false
    AND (date_sortie IS NULL OR date_sortie >= current_date);
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Salarié introuvable.');
  END IF;
  IF v_employe.pin_hash IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Aucun code PIN défini : utilisez votre badge ou prévenez un responsable.');
  END IF;

  IF crypt(p_pin, v_employe.pin_hash) <> v_employe.pin_hash THEN
    INSERT INTO pin_essais (auth_user_id, resultat) VALUES (auth.uid(), 'echec');
    SELECT * INTO v_bloc FROM _pin_blocage(auth.uid());
    IF v_bloc.bloque_jusqua IS NOT NULL THEN
      INSERT INTO rh_journal (auteur, action, motif)
      VALUES ('Kiosque', 'PIN kiosque bloqué',
              CASE v_bloc.raison WHEN 'jour' THEN '10 erreurs dans la journée — bloqué jusqu''à demain'
                                 ELSE '3 erreurs en 10 min — bloqué 10 min' END);
      RETURN jsonb_build_object('ok', false, 'bloque', true,
        'message', 'Code PIN incorrect. Trop d''erreurs : code PIN bloqué '
          || CASE v_bloc.raison WHEN 'jour' THEN 'jusqu''à demain.' ELSE 'pendant 10 minutes.' END
          || ' Utilisez votre badge.');
    END IF;
    RETURN jsonb_build_object('ok', false, 'message', 'Code PIN incorrect.');
  END IF;

  v_res := _pointer_auto(v_employe.id, 'kiosque');
  IF NOT (v_res ->> 'ok')::boolean THEN
    RETURN v_res;
  END IF;
  INSERT INTO pin_essais (auth_user_id, resultat) VALUES (auth.uid(), 'ok');
  DELETE FROM pin_essais WHERE at < now() - interval '90 days';

  RETURN v_res || jsonb_build_object('id', v_employe.id, 'nom', v_employe.nom, 'prenom', v_employe.prenom);
END;
$function$;

CREATE OR REPLACE FUNCTION public.purger_employe_rh(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_supprime boolean;
BEGIN
  PERFORM public._exiger_admin_rh();
  SELECT supprime INTO v_supprime FROM employes WHERE id = p_id;
  IF v_supprime IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Salarié introuvable.');
  END IF;
  IF NOT v_supprime THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Ce salarié doit d''abord être supprimé (corbeille) avant purge définitive.');
  END IF;

  DELETE FROM heures_corrections  WHERE employe_id = p_id;
  DELETE FROM jours_statut        WHERE employe_id = p_id;
  DELETE FROM semaines_validees   WHERE employe_id = p_id;
  DELETE FROM heures_journalieres WHERE employe_id = p_id;
  DELETE FROM pointages           WHERE employe_id = p_id;
  DELETE FROM conges              WHERE employe_id = p_id;
  DELETE FROM contrats            WHERE employe_id = p_id;
  DELETE FROM employes            WHERE id = p_id;

  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.pwa_compte_creer(p_prenom text, p_nom text, p_role text, p_activites text[], p_pin text, p_employe uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  e    employes;
  v_id uuid;
BEGIN
  IF coalesce(p_role, '') NOT IN ('admin', 'utilisateur') THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Rôle invalide.');
  END IF;
  IF coalesce(array_length(p_activites, 1), 0) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Au moins une activité requise.');
  END IF;
  IF coalesce(p_pin, '') !~ '^[0-9]{4}$' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'PIN invalide (4 chiffres attendus).');
  END IF;

  -- Toute personne est créée dans rh-metal (salarié ou personne externe) ; ici on n'active qu'un compte.
  SELECT * INTO e FROM employes WHERE id = p_employe;
  IF e.id IS NULL OR NOT _acces_applis(e) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Personne inconnue ou sans accès : créez-la d''abord dans rh-metal (salarié ou personne externe).');
  END IF;
  IF EXISTS (SELECT 1 FROM comptes_pwa WHERE employe_id = e.id) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Cet utilisateur a déjà un compte.');
  END IF;
  IF _pin_deja_pris(p_pin, e.id) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Ce PIN est déjà utilisé par un collègue : choisissez-en un autre.');
  END IF;

  UPDATE employes SET pin_hash = crypt(p_pin, gen_salt('bf', 12)), updated_at = now() WHERE id = e.id;
  INSERT INTO comptes_pwa (employe_id, role, activites)
  VALUES (e.id, p_role, p_activites)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'employeId', e.id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.pwa_compte_debloquer(p_compte uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO connexion_pwa_essais (compte_id, resultat) VALUES (p_compte, 'deblocage');
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.pwa_compte_modifier(p_compte uuid, p_role text DEFAULT NULL::text, p_activites text[] DEFAULT NULL::text[], p_actif boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF p_role IS NOT NULL AND p_role NOT IN ('admin', 'utilisateur') THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Rôle invalide.');
  END IF;
  IF p_activites IS NOT NULL AND coalesce(array_length(p_activites, 1), 0) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Au moins une activité requise.');
  END IF;
  UPDATE comptes_pwa SET
    role      = coalesce(p_role, role),
    activites = coalesce(p_activites, activites),
    actif     = coalesce(p_actif, actif),
    updated_at = now()
  WHERE id = p_compte;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Compte introuvable.');
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.pwa_compte_supprimer(p_compte uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_employe uuid;
BEGIN
  DELETE FROM comptes_pwa WHERE id = p_compte RETURNING employe_id INTO v_employe;
  IF v_employe IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Compte introuvable.');
  END IF;
  UPDATE employes SET supprime = true, updated_at = now()
   WHERE id = v_employe AND classe_num IS NULL AND NOT is_rh_admin AND auth_user_id IS NULL;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.pwa_comptes_connexion()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH c AS (
    SELECT c.id, e.prenom, e.nom,
           e.prenom || ' ' || upper(left(e.nom, 1)) || '.' AS court
      FROM comptes_pwa c JOIN employes e ON e.id = c.employe_id
     WHERE c.actif AND _acces_applis(e)
  ), n AS (
    SELECT *, count(*) OVER (PARTITION BY court) AS homonymes FROM c
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', id,
           'nom', CASE WHEN homonymes > 1 THEN prenom || ' ' || nom ELSE court END)
           ORDER BY prenom, nom), '[]'::jsonb)
    FROM n;
$function$;

CREATE OR REPLACE FUNCTION public.pwa_comptes_liste()
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
  FOR r IN
    SELECT c.*, e.prenom, e.nom, e.pin_hash IS NOT NULL AS a_pin, e.classe_num IS NOT NULL AS a_fiche_rh,
           _acces_applis(e) AS present, e.acces_externe
      FROM comptes_pwa c JOIN employes e ON e.id = c.employe_id
     ORDER BY e.prenom, e.nom
  LOOP
    SELECT * INTO b FROM _connexion_pwa_blocage(r.id);
    v_res := v_res || jsonb_build_object(
      'id', r.id, 'prenom', r.prenom, 'nom', r.nom, 'role', r.role, 'actif', r.actif,
      'activites', to_jsonb(r.activites), 'employeId', r.employe_id, 'aFicheRh', r.a_fiche_rh,
      'present', r.present, 'externe', r.acces_externe, 'hasPIN', r.a_pin,
      'bloqueJusqua', b.bloque_jusqua, 'echecsJour', b.echecs_jour);
  END LOOP;
  RETURN v_res;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pwa_connexion(p_compte uuid, p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  c        comptes_pwa%ROWTYPE;
  e        employes%ROWTYPE;
  v_bloc   record;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('connexion_pwa:' || coalesce(p_compte::text, '')));

  SELECT * INTO c FROM comptes_pwa WHERE id = p_compte;
  IF NOT FOUND OR NOT c.actif THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Compte inconnu ou désactivé.');
  END IF;
  SELECT * INTO e FROM employes WHERE id = c.employe_id;
  IF NOT _acces_applis(e) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Accès fermé. Voir avec l''administrateur.');
  END IF;

  SELECT * INTO v_bloc FROM _connexion_pwa_blocage(c.id);
  IF v_bloc.bloque_jusqua IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'bloque', true, 'message',
      CASE v_bloc.raison WHEN 'jour'
        THEN 'Trop d''erreurs : connexion bloquée jusqu''à demain. Un administrateur peut débloquer.'
        ELSE 'Trop d''erreurs : réessayez à ' || to_char(v_bloc.bloque_jusqua AT TIME ZONE 'Europe/Paris', 'HH24"h"MI') || '.' END);
  END IF;

  IF coalesce(p_pin, '') !~ '^[0-9]{4}$' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Format PIN invalide (4 chiffres attendus).');
  END IF;

  IF e.pin_hash IS NULL OR crypt(p_pin, e.pin_hash) <> e.pin_hash THEN
    INSERT INTO connexion_pwa_essais (compte_id, resultat) VALUES (c.id, 'echec');
    SELECT * INTO v_bloc FROM _connexion_pwa_blocage(c.id);
    IF v_bloc.bloque_jusqua IS NOT NULL THEN
      INSERT INTO rh_journal (auteur, employe_id, action, motif)
      VALUES ('PWA', e.id, 'Connexion PWA bloquée',
              CASE v_bloc.raison WHEN 'jour' THEN '10 erreurs dans la journée — bloquée jusqu''à demain'
                                 ELSE '3 erreurs en 10 min — bloquée 10 min' END);
      RETURN jsonb_build_object('ok', false, 'bloque', true, 'message',
        'Code PIN incorrect. Trop d''erreurs : connexion bloquée '
        || CASE v_bloc.raison WHEN 'jour' THEN 'jusqu''à demain.' ELSE 'pendant 10 minutes.' END);
    END IF;
    RETURN jsonb_build_object('ok', false, 'message', 'Code PIN incorrect.');
  END IF;

  INSERT INTO connexion_pwa_essais (compte_id, resultat) VALUES (c.id, 'ok');
  DELETE FROM connexion_pwa_essais WHERE at < now() - interval '90 days';

  RETURN jsonb_build_object('ok', true, 'compte', c.id, 'prenom', e.prenom, 'nom', e.nom,
    'role', c.role, 'activites', to_jsonb(c.activites), 'pin_a_changer', false);
END;
$function$;
