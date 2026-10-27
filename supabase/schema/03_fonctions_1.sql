CREATE OR REPLACE FUNCTION public._acces_applis(e employes)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  SELECT NOT e.supprime AND (e.acces_externe OR _employe_present(e));
$function$;

CREATE OR REPLACE FUNCTION public._appliquer_remunerations(p_contrat_id uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  UPDATE contrats c SET
    classe_num         = r.classe_num,
    taux_horaire       = r.taux_horaire,
    heures_semaine     = r.heures_semaine,
    heures_sup_semaine = r.heures_sup_semaine,
    poste              = r.poste
  FROM (
    SELECT DISTINCT ON (r.contrat_id) r.*
    FROM remunerations r
    JOIN contrats c2 ON c2.id = r.contrat_id
    CROSS JOIN LATERAL (SELECT r.date_effet <= GREATEST((now() AT TIME ZONE 'Europe/Paris')::date, c2.date_debut) AS en_vigueur) v
    WHERE p_contrat_id IS NULL OR r.contrat_id = p_contrat_id
    ORDER BY r.contrat_id, v.en_vigueur DESC,
             CASE WHEN v.en_vigueur THEN r.date_effet END DESC NULLS LAST,
             r.date_effet ASC, r.created_at DESC
  ) r
  WHERE c.id = r.contrat_id
    AND (c.classe_num, c.taux_horaire, c.heures_semaine, c.heures_sup_semaine, c.poste)
        IS DISTINCT FROM (r.classe_num, r.taux_horaire, r.heures_semaine, r.heures_sup_semaine, r.poste);
$function$;

CREATE OR REPLACE FUNCTION public._auteur_rh()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce((SELECT prenom FROM public.employes WHERE auth_user_id = auth.uid() LIMIT 1), 'admin');
$function$;

CREATE OR REPLACE FUNCTION public._conge_label(p_type text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$ SELECT CASE p_type WHEN 'cp' THEN 'Congé payé' WHEN 'maladie' THEN 'Maladie' WHEN 'evenement_familial' THEN 'Événement familial'
  WHEN 'sans_solde' THEN 'Sans solde' WHEN 'autre' THEN 'Autre absence' ELSE p_type END; $function$;

CREATE OR REPLACE FUNCTION public._connexion_pwa_blocage(p_compte uuid, OUT bloque_jusqua timestamp with time zone, OUT raison text, OUT echecs_jour integer)
 RETURNS record
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tz        text := 'Europe/Paris';
  v_jour      timestamptz := date_trunc('day', now() AT TIME ZONE v_tz) AT TIME ZONE v_tz;
  v_demain    timestamptz := (date_trunc('day', now() AT TIME ZONE v_tz) + interval '1 day') AT TIME ZONE v_tz;
  v_deblocage bigint;
  v_ok        bigint;
  v_court     int;
  v_derniere  timestamptz;
BEGIN
  SELECT max(id) INTO v_deblocage FROM connexion_pwa_essais
   WHERE compte_id = p_compte AND resultat = 'deblocage' AND at >= v_jour;
  SELECT max(id) INTO v_ok FROM connexion_pwa_essais
   WHERE compte_id = p_compte AND resultat = 'ok';

  SELECT count(*) INTO echecs_jour FROM connexion_pwa_essais
   WHERE compte_id = p_compte AND resultat = 'echec'
     AND at >= v_jour AND id > coalesce(v_deblocage, 0);
  IF echecs_jour >= 10 THEN
    bloque_jusqua := v_demain; raison := 'jour';
    RETURN;
  END IF;

  SELECT count(*), max(at) INTO v_court, v_derniere FROM connexion_pwa_essais
   WHERE compte_id = p_compte AND resultat = 'echec'
     AND at > now() - interval '10 minutes'
     AND id > greatest(coalesce(v_ok, 0), coalesce(v_deblocage, 0));
  IF v_court >= 3 THEN
    bloque_jusqua := v_derniere + interval '10 minutes'; raison := 'court';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public._contrat_remuneration_initiale()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO remunerations (contrat_id, employe_id, date_effet, classe_num, taux_horaire,
                             heures_semaine, heures_sup_semaine, poste, motif, saisi_par)
  VALUES (NEW.id, NEW.employe_id, NEW.date_debut, NEW.classe_num, NEW.taux_horaire,
          NEW.heures_semaine, NEW.heures_sup_semaine, NEW.poste, 'debut_contrat', public._auteur_rh());
  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public._employe_present(e employes)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  SELECT e.actif AND NOT e.supprime AND (e.date_sortie IS NULL OR e.date_sortie >= current_date);
$function$;

CREATE OR REPLACE FUNCTION public._est_admin_rh()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT auth.uid() IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.employes WHERE auth_user_id = auth.uid() AND is_rh_admin AND supprime = false);
$function$;

CREATE OR REPLACE FUNCTION public._est_kiosque()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT auth.uid() IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.comptes_kiosque WHERE auth_user_id = auth.uid());
$function$;

CREATE OR REPLACE FUNCTION public._exiger_admin_rh()
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.employes
    WHERE auth_user_id = auth.uid() AND is_rh_admin AND supprime = false
  ) THEN
    RAISE EXCEPTION 'Accès réservé aux administrateurs RH' USING ERRCODE = '42501';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public._exiger_kiosque_ou_admin_rh()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.uid() IS NULL OR NOT (
    EXISTS (SELECT 1 FROM public.comptes_kiosque WHERE auth_user_id = auth.uid())
    OR EXISTS (SELECT 1 FROM public.employes WHERE auth_user_id = auth.uid() AND is_rh_admin AND supprime = false)
  ) THEN
    RAISE EXCEPTION 'Réservé au kiosque de pointage' USING ERRCODE = '42501';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public._fmt_jour(p_date date)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT (ARRAY['dimanche','lundi','mardi','mercredi','jeudi','vendredi','samedi'])[extract(dow from p_date)::int + 1]
    || ' ' || extract(day from p_date)::int || ' '
    || (ARRAY['janv.','févr.','mars','avr.','mai','juin','juil.','août','sept.','oct.','nov.','déc.'])[extract(month from p_date)::int];
$function$;

CREATE OR REPLACE FUNCTION public._fmt_num(p numeric)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$ SELECT replace(CASE WHEN p = trunc(p) THEN trunc(p)::text ELSE rtrim(round(p, 2)::text, '0') END, '.', ','); $function$;

CREATE OR REPLACE FUNCTION public._garder_un_admin_rh()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.employes WHERE is_rh_admin AND supprime = false AND auth_user_id IS NOT NULL) THEN
    RAISE EXCEPTION 'Il doit toujours rester au moins un administrateur RH.' USING ERRCODE = '23514';
  END IF;
  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public._journal(p_employe_id uuid, p_action text, p_motif text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  INSERT INTO public.rh_journal (auteur, employe_id, action, motif)
  VALUES (public._auteur_rh(), p_employe_id, p_action, nullif(trim(coalesce(p_motif,'')), ''));
$function$;

CREATE OR REPLACE FUNCTION public._lundi(p_date date)
 RETURNS date
 LANGUAGE sql
 IMMUTABLE
AS $function$ SELECT p_date - ((extract(dow from p_date)::int + 6) % 7); $function$;

CREATE OR REPLACE FUNCTION public._paques(p_annee integer)
 RETURNS date
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE a int; b int; c int; d int; e int; f int; g int; h int; i int; k int; l int; m int;
BEGIN
  a := p_annee % 19; b := p_annee / 100; c := p_annee % 100; d := b / 4; e := b % 4;
  f := (b + 8) / 25; g := (b - f + 1) / 3; h := (19 * a + b - d - g + 15) % 30;
  i := c / 4; k := c % 4; l := (32 + 2 * e + 2 * i - h - k) % 7; m := (a + 11 * h + 22 * l) / 451;
  RETURN make_date(p_annee, (h + l - 7 * m + 114) / 31, ((h + l - 7 * m + 114) % 31) + 1);
END;
$function$;

CREATE OR REPLACE FUNCTION public._periode_verrouillee(p_employe_id uuid, p_debut date, p_fin date)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (SELECT 1 FROM public.semaines_validees sv
    WHERE sv.employe_id = p_employe_id AND sv.semaine_debut <= p_fin AND (sv.semaine_debut + 6) >= p_debut);
$function$;

CREATE OR REPLACE FUNCTION public._pin_blocage(p_user uuid, OUT bloque_jusqua timestamp with time zone, OUT raison text, OUT echecs_jour integer)
 RETURNS record
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tz        text := 'Europe/Paris';
  v_jour      timestamptz := date_trunc('day', now() AT TIME ZONE v_tz) AT TIME ZONE v_tz;
  v_demain    timestamptz := (date_trunc('day', now() AT TIME ZONE v_tz) + interval '1 day') AT TIME ZONE v_tz;
  v_deblocage bigint;
  v_ok        bigint;
  v_court     int;
  v_derniere  timestamptz;
BEGIN
  SELECT max(id) INTO v_deblocage FROM pin_essais
   WHERE auth_user_id = p_user AND resultat = 'deblocage' AND at >= v_jour;
  SELECT max(id) INTO v_ok FROM pin_essais
   WHERE auth_user_id = p_user AND resultat = 'ok';

  SELECT count(*) INTO echecs_jour FROM pin_essais
   WHERE auth_user_id = p_user AND resultat = 'echec'
     AND at >= v_jour AND id > coalesce(v_deblocage, 0);
  IF echecs_jour >= 10 THEN
    bloque_jusqua := v_demain; raison := 'jour';
    RETURN;
  END IF;

  SELECT count(*), max(at) INTO v_court, v_derniere FROM pin_essais
   WHERE auth_user_id = p_user AND resultat = 'echec'
     AND at > now() - interval '10 minutes'
     AND id > greatest(coalesce(v_ok, 0), coalesce(v_deblocage, 0));
  IF v_court >= 3 THEN
    bloque_jusqua := v_derniere + interval '10 minutes'; raison := 'court';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public._pin_deja_pris(p_pin text, p_sauf uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM employes
     WHERE supprime = false AND pin_hash IS NOT NULL
       AND id IS DISTINCT FROM p_sauf
       AND crypt(p_pin, pin_hash) = pin_hash);
$function$;

CREATE OR REPLACE FUNCTION public._pointer_auto(p_employe_id uuid, p_source text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tz           text := 'Europe/Paris';
  v_today        date := (now() AT TIME ZONE v_tz)::date;
  v_dernier_type text;
  v_dernier_ts   timestamptz;
  v_type         text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext(p_employe_id::text));

  SELECT type, horodatage INTO v_dernier_type, v_dernier_ts
  FROM pointages
  WHERE employe_id = p_employe_id
    AND valide = true
    AND (horodatage AT TIME ZONE v_tz)::date = v_today
  ORDER BY horodatage DESC
  LIMIT 1;

  IF v_dernier_ts IS NOT NULL AND v_dernier_ts > now() - interval '5 seconds' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Pointage déjà pris en compte.');
  END IF;

  v_type := CASE WHEN v_dernier_type IS NULL OR v_dernier_type = 'SORTIE' THEN 'ENTREE' ELSE 'SORTIE' END;

  INSERT INTO pointages (employe_id, type, source) VALUES (p_employe_id, v_type, p_source);
  RETURN jsonb_build_object('ok', true, 'type', v_type);
END;
$function$;

CREATE OR REPLACE FUNCTION public._remuneration_vers_contrat()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public._appliquer_remunerations(COALESCE(NEW.contrat_id, OLD.contrat_id));
  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public._rouvrir_mois_de_semaine(p_semaine_debut date, p_motif text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE m date;
BEGIN
  FOR m IN SELECT DISTINCT date_trunc('month', d)::date FROM generate_series(p_semaine_debut, p_semaine_debut + 4, interval '1 day') d LOOP
    UPDATE public.mois_clotures SET cloture = false, export_perime = (exporte_le IS NOT NULL)
    WHERE mois = m AND cloture;
    IF FOUND THEN
      PERFORM public._journal(NULL, 'Mois de ' || to_char(m, 'MM/YYYY') || ' rouvert (semaine déverrouillée)', p_motif);
    END IF;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public._semaine_est_verrouillee(p_employe_id uuid, p_date date)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.semaines_validees
    WHERE employe_id = p_employe_id
      AND semaine_debut = p_date - ((extract(dow from p_date)::int + 6) % 7)
  );
$function$;

CREATE OR REPLACE FUNCTION public._stock_etat()
 RETURNS TABLE(ref text, inv_qty numeric, delta numeric, derniere_date timestamp with time zone)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH inv AS (
    SELECT DISTINCT ON (m.ref) m.ref, m.date, m.id, m.quantite
      FROM stock_mouvements m WHERE m.type = 'inventaire'
     ORDER BY m.ref, m.date DESC, m.id DESC
  )
  SELECT m.ref,
         max(inv.quantite),
         coalesce(sum(CASE WHEN inv.ref IS NULL OR (m.date, m.id) > (inv.date, inv.id)
                           THEN CASE m.type WHEN 'entrée' THEN m.quantite WHEN 'sortie' THEN -m.quantite ELSE 0 END
                           ELSE 0 END), 0),
         max(m.date)
    FROM stock_mouvements m LEFT JOIN inv ON inv.ref = m.ref
   GROUP BY m.ref;
$function$;

CREATE OR REPLACE FUNCTION public._stock_iso(d timestamp with time zone)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  SELECT to_char(d AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
$function$;

CREATE OR REPLACE FUNCTION public._stock_mouvement_json(m stock_mouvements)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT jsonb_build_object('id', m.id, 'date', _stock_iso(m.date), 'ref', m.ref, 'type', m.type,
                            'qty', m.quantite, 'user', m.utilisateur, 'note', m.note);
$function$;

CREATE OR REPLACE FUNCTION public._stock_nombre(v jsonb)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  SELECT CASE
    WHEN jsonb_typeof(v) = 'number' THEN (v #>> '{}')::numeric
    WHEN jsonb_typeof(v) = 'string' AND btrim(v #>> '{}') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN btrim(v #>> '{}')::numeric
    WHEN jsonb_typeof(v) = 'string' AND btrim(v #>> '{}') = '' THEN 0
    ELSE 0 END;
$function$;

CREATE OR REPLACE FUNCTION public._sync_heures_journalieres()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_tz            text        := 'Europe/Paris';
  v_date          date;
  v_entree        timestamptz;
  v_sortie        timestamptz;
  v_last_type     text;
  v_duree_pause   interval    := '0'::interval;
  v_duree_brute   interval;
  v_duree_nette   interval;
  v_statut        text;
  r               record;
  v_fin_pause     timestamptz;
  v_session_debut timestamptz;
BEGIN
  v_date := (NEW.horodatage AT TIME ZONE v_tz)::date;

  SELECT horodatage INTO v_entree FROM pointages
  WHERE employe_id = NEW.employe_id AND valide = true AND (horodatage AT TIME ZONE v_tz)::date = v_date AND type = 'ENTREE'
  ORDER BY horodatage LIMIT 1;

  SELECT horodatage INTO v_sortie FROM pointages
  WHERE employe_id = NEW.employe_id AND valide = true AND (horodatage AT TIME ZONE v_tz)::date = v_date AND type = 'SORTIE'
  ORDER BY horodatage DESC LIMIT 1;

  SELECT type INTO v_last_type FROM pointages
  WHERE employe_id = NEW.employe_id AND valide = true AND (horodatage AT TIME ZONE v_tz)::date = v_date
  ORDER BY horodatage DESC LIMIT 1;

  FOR r IN
    SELECT horodatage AS debut FROM pointages
    WHERE employe_id = NEW.employe_id AND valide = true AND (horodatage AT TIME ZONE v_tz)::date = v_date AND type = 'PAUSE_DEBUT'
    ORDER BY horodatage
  LOOP
    SELECT horodatage INTO v_fin_pause FROM pointages
    WHERE employe_id = NEW.employe_id AND valide = true AND (horodatage AT TIME ZONE v_tz)::date = v_date
      AND type = 'PAUSE_FIN' AND horodatage > r.debut
    ORDER BY horodatage LIMIT 1;
    IF v_fin_pause IS NOT NULL THEN
      v_duree_pause := v_duree_pause + (v_fin_pause - r.debut);
    END IF;
  END LOOP;

  IF v_entree IS NULL THEN
    v_statut := 'ABSENT';
    v_sortie := NULL;
  ELSIF v_last_type = 'SORTIE' THEN
    v_duree_brute := '0'::interval;
    v_session_debut := NULL;
    FOR r IN
      SELECT horodatage, type FROM pointages
      WHERE employe_id = NEW.employe_id AND valide = true AND (horodatage AT TIME ZONE v_tz)::date = v_date
        AND type IN ('ENTREE','SORTIE')
      ORDER BY horodatage
    LOOP
      IF r.type = 'ENTREE' THEN
        IF v_session_debut IS NULL THEN v_session_debut := r.horodatage; END IF;
      ELSIF v_session_debut IS NOT NULL THEN
        v_duree_brute := v_duree_brute + (r.horodatage - v_session_debut);
        v_session_debut := NULL;
      END IF;
    END LOOP;
    v_statut := 'SORTI';
    v_duree_nette := v_duree_brute - v_duree_pause;
  ELSIF v_last_type = 'PAUSE_DEBUT' THEN
    v_statut := 'EN_PAUSE';
    v_sortie := NULL;
  ELSE
    v_statut := 'EN_SERVICE';
    v_sortie := NULL;
  END IF;

  INSERT INTO heures_journalieres (employe_id, date, heure_entree, heure_sortie, duree_brute, duree_pause, duree_nette,
    statut, pause_legale_appliquee, updated_at)
  VALUES (NEW.employe_id, v_date, v_entree, v_sortie, v_duree_brute, v_duree_pause, v_duree_nette, v_statut, false, now())
  ON CONFLICT (employe_id, date) DO UPDATE SET
    heure_entree = EXCLUDED.heure_entree, heure_sortie = EXCLUDED.heure_sortie,
    duree_brute = EXCLUDED.duree_brute, duree_pause = EXCLUDED.duree_pause, duree_nette = EXCLUDED.duree_nette,
    statut = EXCLUDED.statut, pause_legale_appliquee = false, updated_at = EXCLUDED.updated_at;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public._voyages_touch_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_add_pointage(p_employe_id uuid, p_type text, p_horodatage timestamp with time zone, p_modifie_par text DEFAULT 'admin'::text, p_motif text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE v_date date := (p_horodatage AT TIME ZONE 'Europe/Paris')::date;
BEGIN
  IF coalesce(auth.jwt() ->> 'role', '') <> 'service_role' THEN
    PERFORM _exiger_admin_rh();
  END IF;
  IF p_type NOT IN ('ENTREE','SORTIE','PAUSE_DEBUT','PAUSE_FIN') THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Type invalide.');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.employes WHERE id = p_employe_id AND actif = true) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Employe introuvable.');
  END IF;
  IF public._semaine_est_verrouillee(p_employe_id, v_date) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Semaine verrouillée — déverrouillez-la avant de modifier ce pointage.');
  END IF;
  INSERT INTO public.pointages (employe_id, type, horodatage, source, valide, raison_modif, modifie_par)
  VALUES (p_employe_id, p_type, p_horodatage, 'admin', true, coalesce(nullif(trim(p_motif), ''), 'Ajout manuel'), p_modifie_par);
  PERFORM public._journal(p_employe_id,
    'Pointage ajouté — ' || CASE p_type WHEN 'ENTREE' THEN 'Entrée' WHEN 'SORTIE' THEN 'Sortie' ELSE p_type END
    || ' ' || to_char(p_horodatage AT TIME ZONE 'Europe/Paris', 'HH24:MI') || ' le ' || public._fmt_jour(v_date), p_motif);
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_annuler_pointage(p_pointage_id uuid, p_motif text, p_modifie_par text DEFAULT 'admin'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE p public.pointages%ROWTYPE;
BEGIN
  IF coalesce(auth.jwt() ->> 'role', '') <> 'service_role' THEN
    PERFORM _exiger_admin_rh();
  END IF;
  IF coalesce(trim(p_motif), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Motif obligatoire.');
  END IF;
  SELECT * INTO p FROM public.pointages WHERE id = p_pointage_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Pointage introuvable.');
  END IF;
  IF public._semaine_est_verrouillee(p.employe_id, (p.horodatage AT TIME ZONE 'Europe/Paris')::date) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Semaine verrouillée — déverrouillez-la avant d''annuler ce pointage.');
  END IF;
  UPDATE public.pointages SET valide = false, raison_modif = p_motif, modifie_par = p_modifie_par, modifie_le = now()
  WHERE id = p_pointage_id;
  PERFORM public._journal(p.employe_id,
    'Pointage annulé — ' || CASE p.type WHEN 'ENTREE' THEN 'Entrée' WHEN 'SORTIE' THEN 'Sortie' ELSE p.type END || ' '
    || to_char(p.horodatage AT TIME ZONE 'Europe/Paris', 'HH24:MI') || ' le ' || public._fmt_jour((p.horodatage AT TIME ZONE 'Europe/Paris')::date), p_motif);
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_modifier_pointage(p_pointage_id uuid, p_horodatage timestamp with time zone, p_modifie_par text DEFAULT 'admin'::text, p_motif text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE p public.pointages%ROWTYPE;
BEGIN
  IF coalesce(auth.jwt() ->> 'role', '') <> 'service_role' THEN
    PERFORM _exiger_admin_rh();
  END IF;
  SELECT * INTO p FROM public.pointages WHERE id = p_pointage_id AND valide = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Pointage introuvable ou déjà annulé.');
  END IF;
  IF public._semaine_est_verrouillee(p.employe_id, (p.horodatage AT TIME ZONE 'Europe/Paris')::date)
     OR public._semaine_est_verrouillee(p.employe_id, (p_horodatage AT TIME ZONE 'Europe/Paris')::date) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Semaine verrouillée — déverrouillez-la avant de modifier ce pointage.');
  END IF;
  UPDATE public.pointages
  SET horodatage = p_horodatage, modifie_par = p_modifie_par, modifie_le = now(),
      horodatage_origine = coalesce(horodatage_origine, p.horodatage),
      raison_modif = coalesce(nullif(trim(p_motif), ''), 'Correction heure')
  WHERE id = p_pointage_id;
  IF (p.horodatage AT TIME ZONE 'Europe/Paris')::date <> (p_horodatage AT TIME ZONE 'Europe/Paris')::date THEN
    UPDATE public.pointages SET valide = valide
    WHERE id = (SELECT id FROM public.pointages WHERE employe_id = p.employe_id
                  AND (horodatage AT TIME ZONE 'Europe/Paris')::date = (p.horodatage AT TIME ZONE 'Europe/Paris')::date LIMIT 1);
  END IF;
  PERFORM public._journal(p.employe_id,
    'Heure modifiée — ' || CASE p.type WHEN 'ENTREE' THEN 'Entrée' WHEN 'SORTIE' THEN 'Sortie' ELSE p.type END || ' '
    || to_char(p.horodatage AT TIME ZONE 'Europe/Paris', 'HH24:MI') || ' → ' || to_char(p_horodatage AT TIME ZONE 'Europe/Paris', 'HH24:MI')
    || ' le ' || public._fmt_jour((p_horodatage AT TIME ZONE 'Europe/Paris')::date), p_motif);
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.ajouter_correction_heures(p_employe_id uuid, p_date date, p_delta_min integer, p_commentaire text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE v_id uuid;
BEGIN
  PERFORM public._exiger_admin_rh();
  IF p_delta_min = 0 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Le nombre de minutes ne peut pas être nul.');
  END IF;
  IF coalesce(trim(p_commentaire), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Un commentaire est requis.');
  END IF;
  IF public._semaine_est_verrouillee(p_employe_id, p_date) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Semaine verrouillée — déverrouillez-la avant de corriger.');
  END IF;
  INSERT INTO public.heures_corrections (employe_id, date, delta_min, commentaire)
  VALUES (p_employe_id, p_date, p_delta_min, p_commentaire) RETURNING id INTO v_id;
  PERFORM public._journal(p_employe_id, 'Correction ' || CASE WHEN p_delta_min > 0 THEN '+' ELSE '−' END
    || public._fmt_num(abs(p_delta_min) / 60.0) || ' h le ' || public._fmt_jour(p_date), p_commentaire);
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.ajouter_remuneration_rh(p_employe_id uuid, p_date_effet date, p_classe_num smallint, p_taux_horaire numeric, p_heures_semaine numeric, p_heures_sup_semaine numeric, p_poste text, p_motif text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_contrat_id uuid;
  v_avant numeric;
  v_id uuid;
BEGIN
  PERFORM public._exiger_admin_rh();
  IF p_employe_id IS NULL OR p_date_effet IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Salarié et date d''effet requis.');
  END IF;
  IF p_motif IS NULL OR p_motif = 'debut_contrat' OR p_motif <> ALL (ARRAY[
       'augmentation_individuelle', 'augmentation_generale', 'changement_classe',
       'avenant', 'minimum_conventionnel', 'correction']) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Motif requis.');
  END IF;
  IF coalesce(p_taux_horaire, 0) <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Taux horaire requis.');
  END IF;
  IF coalesce(p_heures_semaine, 0) <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Heures par semaine requises.');
  END IF;
  IF p_classe_num IS NULL OR p_classe_num NOT BETWEEN 1 AND 18 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Classe invalide.');
  END IF;

  SELECT id INTO v_contrat_id FROM contrats
  WHERE employe_id = p_employe_id
    AND date_debut <= p_date_effet
    AND (date_fin IS NULL OR date_fin >= p_date_effet)
  ORDER BY date_debut DESC, created_at DESC
  LIMIT 1;
  IF v_contrat_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Aucun contrat en cours à cette date.');
  END IF;

  SELECT taux_horaire INTO v_avant FROM remunerations
  WHERE contrat_id = v_contrat_id AND date_effet <= p_date_effet
  ORDER BY date_effet DESC, created_at DESC LIMIT 1;

  INSERT INTO remunerations (contrat_id, employe_id, date_effet, classe_num, taux_horaire,
                             heures_semaine, heures_sup_semaine, poste, motif, note, saisi_par)
  VALUES (v_contrat_id, p_employe_id, p_date_effet, p_classe_num, p_taux_horaire,
          p_heures_semaine, coalesce(p_heures_sup_semaine, 0), nullif(trim(coalesce(p_poste, '')), ''),
          p_motif, nullif(trim(coalesce(p_note, '')), ''), public._auteur_rh())
  RETURNING id INTO v_id;

  PERFORM public._journal(p_employe_id,
    'Rémunération au ' || to_char(p_date_effet, 'DD/MM/YYYY') || ' : '
      || coalesce(public._fmt_num(v_avant) || ' → ', '') || public._fmt_num(p_taux_horaire) || ' €/h, classe ' || p_classe_num,
    p_note);

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.ajuster_solde_cp(p_employe_id uuid, p_jours numeric, p_raison text, p_motif text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  PERFORM public._exiger_admin_rh();
  IF coalesce(p_jours, 0) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Indiquez un nombre de jours.');
  END IF;
  IF coalesce(trim(p_motif), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Le motif est obligatoire.');
  END IF;
  IF p_raison NOT IN ('report','correction') THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Raison invalide.');
  END IF;
  INSERT INTO public.cp_ajustements (employe_id, jours, raison, motif, cree_par)
  VALUES (p_employe_id, p_jours, p_raison, p_motif, public._auteur_rh());
  PERFORM public._journal(p_employe_id, 'Solde CP ajusté ' || CASE WHEN p_jours > 0 THEN '+' ELSE '−' END
    || public._fmt_num(abs(p_jours)) || ' j ('
    || CASE p_raison WHEN 'report' THEN 'report N-1' ELSE 'correction' END || ')', p_motif);
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.annuler_voyage(p_numero_lv text, p_motif text, p_par text, p_remplacee_par text DEFAULT NULL::text, p_type text DEFAULT NULL::text, p_destination text DEFAULT NULL::text, p_pdf_url text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(trim(p_numero_lv), '') = '' OR coalesce(trim(p_motif), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'numéro et motif requis');
  END IF;

  INSERT INTO voyages_annules (numero_lv, type, date_creation, destination, destination_adresse, poids, ml, grutage,
         commentaire, marchandises_desc, livraison_prevue, parti, parti_le, doc_annexe, commande, conducteur,
         immat_moteur, immat_semi, expediteur, convoi, pdf_url, annulee_par, motif, remplacee_par)
  SELECT v.numero_lv, v.type, v.date_creation, v.destination, v.destination_adresse, v.poids, v.ml, v.grutage,
         v.commentaire, v.marchandises_desc, v.livraison_prevue, v.parti, v.parti_le, i.doc_annexe, i.commande, i.conducteur,
         i.immat_moteur, i.immat_semi, i.expediteur, i.convoi, i.pdf_url,
         NULLIF(p_par, ''), trim(p_motif), NULLIF(trim(coalesce(p_remplacee_par, '')), '')
  FROM voyages v LEFT JOIN voyages_internes i ON i.numero_lv = v.numero_lv
  WHERE v.numero_lv = p_numero_lv
  ON CONFLICT (numero_lv) DO NOTHING;

  -- Fiche absente de Supabase (synchro jamais faite) : on garde au moins l'essentiel.
  IF NOT FOUND THEN
    INSERT INTO voyages_annules (numero_lv, type, destination, pdf_url, annulee_par, motif, remplacee_par)
    VALUES (p_numero_lv, NULLIF(p_type, ''), NULLIF(p_destination, ''), NULLIF(p_pdf_url, ''),
            NULLIF(p_par, ''), trim(p_motif), NULLIF(trim(coalesce(p_remplacee_par, '')), ''))
    ON CONFLICT (numero_lv) DO NOTHING;
  END IF;

  DELETE FROM voyages WHERE numero_lv = p_numero_lv;
  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'message', sqlerrm);
END;
$function$;

CREATE OR REPLACE FUNCTION public.associer_badge_nfc(p_employe_id uuid, p_uid text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  PERFORM public._exiger_admin_rh();
  IF trim(coalesce(p_uid, '')) = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'UID vide.');
  END IF;

  IF EXISTS (SELECT 1 FROM employes WHERE nfc_uid = p_uid AND id <> p_employe_id) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Ce badge est déjà associé à un autre salarié.');
  END IF;

  UPDATE employes SET nfc_uid = p_uid, updated_at = now() WHERE id = p_employe_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Salarié introuvable.');
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$function$;
