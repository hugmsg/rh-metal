-- Onglet « Temps & absences » (2026-10-07) — remplace Pointage + Congés côté admin.
-- Maquette validée par Hugo : https://claude.ai/artifact/PGzJcd9fPGz8ELKtFBDkY2
--
-- Ajoute : journal des modifications, clôture mensuelle + suivi d'export CSV,
-- ajustements de solde CP, jours fériés partagés, réglages temps de travail
-- (semaines à cheval, seuils heures sup), absence « autre » et demi-journées.
-- Durcit : modifier/annuler un pointage vérifie désormais le verrouillage de la
-- semaine (avant : seul l'ajout le vérifiait), modifier/annuler/ajouter exigent
-- un motif, l'heure d'origine d'un pointage modifié est conservée.

-- ── Helpers ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._est_admin_rh()
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT auth.uid() IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.employes WHERE auth_user_id = auth.uid() AND is_rh_admin AND supprime = false);
$$;

-- Prénom de l'admin connecté, pour le journal (« Hugo »).
CREATE OR REPLACE FUNCTION public._auteur_rh()
 RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT coalesce((SELECT prenom FROM public.employes WHERE auth_user_id = auth.uid() LIMIT 1), 'admin');
$$;

-- Lundi de la semaine d'une date.
CREATE OR REPLACE FUNCTION public._lundi(p_date date)
 RETURNS date LANGUAGE sql IMMUTABLE
AS $$ SELECT p_date - ((extract(dow from p_date)::int + 6) % 7); $$;

-- ── Tables ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.rh_journal (
  id          bigserial PRIMARY KEY,
  at          timestamptz NOT NULL DEFAULT now(),
  auteur      text NOT NULL,
  employe_id  uuid REFERENCES public.employes(id) ON DELETE SET NULL,
  action      text NOT NULL,
  motif       text
);
CREATE INDEX IF NOT EXISTS rh_journal_at_idx ON public.rh_journal (at DESC);
CREATE INDEX IF NOT EXISTS rh_journal_emp_idx ON public.rh_journal (employe_id, at DESC);

CREATE TABLE IF NOT EXISTS public.mois_clotures (
  mois           date PRIMARY KEY CHECK (extract(day from mois) = 1),
  cloture        boolean NOT NULL DEFAULT false,
  cloture_le     timestamptz,
  cloture_par    text,
  exporte_le     timestamptz,
  exporte_par    text,
  export_perime  boolean NOT NULL DEFAULT false
);

CREATE TABLE IF NOT EXISTS public.cp_ajustements (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employe_id  uuid NOT NULL REFERENCES public.employes(id) ON DELETE CASCADE,
  jours       numeric NOT NULL CHECK (jours <> 0),
  raison      text NOT NULL CHECK (raison IN ('report','correction')),
  motif       text NOT NULL,
  cree_par    text,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.jours_feries (
  date     date PRIMARY KEY,
  libelle  text NOT NULL
);

CREATE TABLE IF NOT EXISTS public.rh_parametres_temps (
  id              boolean PRIMARY KEY DEFAULT true CHECK (id),
  semaine_cheval  text NOT NULL DEFAULT 'fin' CHECK (semaine_cheval IN ('fin','debut')),
  heures_ref      numeric NOT NULL DEFAULT 35,
  heures_25       numeric NOT NULL DEFAULT 8,
  cp_annuels      numeric NOT NULL DEFAULT 25
);
INSERT INTO public.rh_parametres_temps (id) VALUES (true) ON CONFLICT DO NOTHING;

INSERT INTO public.jours_feries (date, libelle) VALUES
  ('2026-01-01','Jour de l''an'), ('2026-04-06','Lundi de Pâques'), ('2026-05-01','Fête du travail'),
  ('2026-05-08','Victoire 1945'), ('2026-05-14','Ascension'), ('2026-05-25','Lundi de Pentecôte'),
  ('2026-07-14','Fête nationale'), ('2026-08-15','Assomption'), ('2026-11-01','Toussaint'),
  ('2026-11-11','Armistice'), ('2026-12-25','Noël'),
  ('2027-01-01','Jour de l''an'), ('2027-03-29','Lundi de Pâques'), ('2027-05-01','Fête du travail'),
  ('2027-05-06','Ascension'), ('2027-05-08','Victoire 1945'), ('2027-05-17','Lundi de Pentecôte'),
  ('2027-07-14','Fête nationale'), ('2027-08-15','Assomption'), ('2027-11-01','Toussaint'),
  ('2027-11-11','Armistice'), ('2027-12-25','Noël')
ON CONFLICT DO NOTHING;

-- Lecture admin RH uniquement, écritures uniquement via RPC.
ALTER TABLE public.rh_journal          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mois_clotures       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cp_ajustements      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.jours_feries        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rh_parametres_temps ENABLE ROW LEVEL SECURITY;
CREATE POLICY rh_journal_select          ON public.rh_journal          FOR SELECT TO authenticated USING (public._est_admin_rh());
CREATE POLICY mois_clotures_select       ON public.mois_clotures       FOR SELECT TO authenticated USING (public._est_admin_rh());
CREATE POLICY cp_ajustements_select      ON public.cp_ajustements      FOR SELECT TO authenticated USING (public._est_admin_rh());
CREATE POLICY jours_feries_select        ON public.jours_feries        FOR SELECT TO authenticated USING (true);
CREATE POLICY rh_parametres_temps_select ON public.rh_parametres_temps FOR SELECT TO authenticated USING (public._est_admin_rh());

-- Heure d'origine d'un pointage modifié (gardée à la 1re modification).
ALTER TABLE public.pointages ADD COLUMN IF NOT EXISTS horodatage_origine timestamptz;

-- Absence « autre » + demi-journée.
ALTER TABLE public.conges DROP CONSTRAINT IF EXISTS conges_type_check;
ALTER TABLE public.conges ADD CONSTRAINT conges_type_check
  CHECK (type IN ('cp','maladie','evenement_familial','sans_solde','autre'));
ALTER TABLE public.conges ADD COLUMN IF NOT EXISTS demi_journee text CHECK (demi_journee IN ('am','pm'));

CREATE OR REPLACE FUNCTION public._journal(p_employe_id uuid, p_action text, p_motif text DEFAULT NULL)
 RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $$
  INSERT INTO public.rh_journal (auteur, employe_id, action, motif)
  VALUES (public._auteur_rh(), p_employe_id, p_action, nullif(trim(coalesce(p_motif,'')), ''));
$$;

CREATE OR REPLACE FUNCTION public._fmt_num(p numeric)
 RETURNS text LANGUAGE sql IMMUTABLE
AS $$ SELECT replace(CASE WHEN p = trunc(p) THEN trunc(p)::text ELSE rtrim(round(p, 2)::text, '0') END, '.', ','); $$;

CREATE OR REPLACE FUNCTION public._fmt_jour(p_date date)
 RETURNS text LANGUAGE sql IMMUTABLE
AS $$
  SELECT (ARRAY['dimanche','lundi','mardi','mercredi','jeudi','vendredi','samedi'])[extract(dow from p_date)::int + 1]
    || ' ' || extract(day from p_date)::int || ' '
    || (ARRAY['janv.','févr.','mars','avr.','mai','juin','juil.','août','sept.','oct.','nov.','déc.'])[extract(month from p_date)::int];
$$;

-- ── Pointages ───────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.admin_add_pointage(uuid, text, timestamptz, text);
CREATE OR REPLACE FUNCTION public.admin_add_pointage(p_employe_id uuid, p_type text, p_horodatage timestamptz,
  p_modifie_par text DEFAULT 'admin', p_motif text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
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
$$;

DROP FUNCTION IF EXISTS public.admin_modifier_pointage(uuid, timestamptz, text);
CREATE OR REPLACE FUNCTION public.admin_modifier_pointage(p_pointage_id uuid, p_horodatage timestamptz,
  p_modifie_par text DEFAULT 'admin', p_motif text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
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
  -- Le trigger ne recalcule que le jour de la nouvelle heure : si le pointage change de
  -- jour, l'ancien jour garde son ancien total. Re-déclenche le calcul sur l'ancien jour.
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
$$;

CREATE OR REPLACE FUNCTION public.admin_annuler_pointage(p_pointage_id uuid, p_motif text, p_modifie_par text DEFAULT 'admin')
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
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
$$;

-- Pointages d'une période, annulés compris (le détail d'un jour les affiche barrés).
CREATE OR REPLACE FUNCTION public.get_pointages_periode_rh(p_debut date, p_fin date)
 RETURNS TABLE (id uuid, employe_id uuid, type text, horodatage timestamptz, date date, source text, valide boolean,
                raison_modif text, modifie_par text, horodatage_origine timestamptz)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  PERFORM public._exiger_admin_rh();
  RETURN QUERY
    SELECT p.id, p.employe_id, p.type, p.horodatage, (p.horodatage AT TIME ZONE 'Europe/Paris')::date,
           p.source, p.valide, p.raison_modif, p.modifie_par, p.horodatage_origine
    FROM public.pointages p
    WHERE (p.horodatage AT TIME ZONE 'Europe/Paris')::date BETWEEN p_debut AND p_fin
    ORDER BY p.horodatage;
END;
$$;

-- ── Corrections ± h ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.ajouter_correction_heures(p_employe_id uuid, p_date date, p_delta_min integer, p_commentaire text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
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
$$;

CREATE OR REPLACE FUNCTION public.supprimer_correction_heures(p_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
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
$$;

-- ── Absences ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._conge_label(p_type text)
 RETURNS text LANGUAGE sql IMMUTABLE
AS $$ SELECT CASE p_type WHEN 'cp' THEN 'Congé payé' WHEN 'maladie' THEN 'Maladie' WHEN 'evenement_familial' THEN 'Événement familial'
  WHEN 'sans_solde' THEN 'Sans solde' WHEN 'autre' THEN 'Autre absence' ELSE p_type END; $$;

CREATE OR REPLACE FUNCTION public._periode_verrouillee(p_employe_id uuid, p_debut date, p_fin date)
 RETURNS boolean LANGUAGE sql STABLE SET search_path TO 'public'
AS $$
  SELECT EXISTS (SELECT 1 FROM public.semaines_validees sv
    WHERE sv.employe_id = p_employe_id AND sv.semaine_debut <= p_fin AND (sv.semaine_debut + 6) >= p_debut);
$$;

DROP FUNCTION IF EXISTS public.upsert_conge_rh(uuid, uuid, text, date, date, numeric, text, text);
CREATE OR REPLACE FUNCTION public.upsert_conge_rh(p_id uuid, p_employe_id uuid, p_type text, p_date_debut date, p_date_fin date,
  p_jours numeric, p_motif text, p_notes text, p_demi_journee text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
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
$$;

DROP FUNCTION IF EXISTS public.supprimer_conge_rh(uuid);
CREATE OR REPLACE FUNCTION public.supprimer_conge_rh(p_id uuid, p_motif text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
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
$$;

-- ── Semaines ────────────────────────────────────────────────────────────────
-- Mois rattachés à une semaine : tous les mois qu'elle touche (lun → ven).
-- Déverrouiller une semaine rouvre ces mois s'ils étaient clôturés (export périmé).
CREATE OR REPLACE FUNCTION public._rouvrir_mois_de_semaine(p_semaine_debut date, p_motif text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
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
$$;

CREATE OR REPLACE FUNCTION public.verrouiller_semaine_pour(p_employes uuid[], p_semaine_debut date)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
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
$$;

CREATE OR REPLACE FUNCTION public.deverrouiller_semaine_pour(p_employes uuid[], p_semaine_debut date, p_motif text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
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
$$;

-- Les anciennes fonctions (onglet Pointage › Contrôle, gardé pendant la validation)
-- passent par les nouvelles pour tenir le journal et la clôture à jour.
CREATE OR REPLACE FUNCTION public.valider_semaine(p_employe_id uuid, p_semaine_debut date, p_valide_par text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$ BEGIN RETURN public.verrouiller_semaine_pour(ARRAY[p_employe_id], p_semaine_debut); END; $$;

DROP FUNCTION IF EXISTS public.deverrouiller_semaine(uuid, date);
CREATE OR REPLACE FUNCTION public.deverrouiller_semaine(p_employe_id uuid, p_semaine_debut date, p_motif text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$ BEGIN RETURN public.deverrouiller_semaine_pour(ARRAY[p_employe_id], p_semaine_debut, coalesce(nullif(trim(p_motif), ''), 'Déverrouillage depuis l''ancien onglet Contrôle')); END; $$;

-- ── Mois ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.cloturer_mois(p_mois date, p_resume text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
DECLARE m date := date_trunc('month', p_mois)::date;
BEGIN
  PERFORM public._exiger_admin_rh();
  INSERT INTO public.mois_clotures (mois, cloture, cloture_le, cloture_par)
  VALUES (m, true, now(), public._auteur_rh())
  ON CONFLICT (mois) DO UPDATE SET cloture = true, cloture_le = now(), cloture_par = EXCLUDED.cloture_par;
  PERFORM public._journal(NULL, 'Mois de ' || to_char(m, 'MM/YYYY') || ' verrouillé' || coalesce(' — ' || p_resume, ''));
  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.rouvrir_mois(p_mois date, p_motif text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
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
$$;

CREATE OR REPLACE FUNCTION public.marquer_export_mois(p_mois date, p_fichier text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
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
$$;

-- ── CP ──────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.ajuster_solde_cp(p_employe_id uuid, p_jours numeric, p_raison text, p_motif text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
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
$$;

-- ── Paramètres ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.enregistrer_parametres_temps(p_semaine_cheval text, p_heures_ref numeric, p_heures_25 numeric, p_cp_annuels numeric)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
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
$$;

CREATE OR REPLACE FUNCTION public.enregistrer_jour_ferie(p_date date, p_libelle text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
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
$$;

CREATE OR REPLACE FUNCTION public.supprimer_jour_ferie(p_date date)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
DECLARE l text;
BEGIN
  PERFORM public._exiger_admin_rh();
  DELETE FROM public.jours_feries WHERE date = p_date RETURNING libelle INTO l;
  IF l IS NOT NULL THEN PERFORM public._journal(NULL, 'Jour férié supprimé — ' || l || ' le ' || public._fmt_jour(p_date)); END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- Droits : rien pour anon sur les nouvelles fonctions.
REVOKE ALL ON FUNCTION public.get_pointages_periode_rh(date, date), public.verrouiller_semaine_pour(uuid[], date),
  public.deverrouiller_semaine_pour(uuid[], date, text), public.cloturer_mois(date, text), public.rouvrir_mois(date, text),
  public.marquer_export_mois(date, text), public.ajuster_solde_cp(uuid, numeric, text, text),
  public.enregistrer_parametres_temps(text, numeric, numeric, numeric), public.enregistrer_jour_ferie(date, text),
  public.supprimer_jour_ferie(date), public.admin_add_pointage(uuid, text, timestamptz, text, text),
  public.admin_modifier_pointage(uuid, timestamptz, text, text), public.upsert_conge_rh(uuid, uuid, text, date, date, numeric, text, text, text),
  public.supprimer_conge_rh(uuid, text), public.deverrouiller_semaine(uuid, date, text),
  public._journal(uuid, text, text), public._rouvrir_mois_de_semaine(date, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_pointages_periode_rh(date, date), public.verrouiller_semaine_pour(uuid[], date),
  public.deverrouiller_semaine_pour(uuid[], date, text), public.cloturer_mois(date, text), public.rouvrir_mois(date, text),
  public.marquer_export_mois(date, text), public.ajuster_solde_cp(uuid, numeric, text, text),
  public.enregistrer_parametres_temps(text, numeric, numeric, numeric), public.enregistrer_jour_ferie(date, text),
  public.supprimer_jour_ferie(date), public.admin_add_pointage(uuid, text, timestamptz, text, text),
  public.admin_modifier_pointage(uuid, timestamptz, text, text), public.upsert_conge_rh(uuid, uuid, text, date, date, numeric, text, text, text),
  public.supprimer_conge_rh(uuid, text), public.deverrouiller_semaine(uuid, date, text)
  TO authenticated;

-- Fil des badgeages en direct (conges : pas de policy SELECT, Realtime n'y livrerait rien).
ALTER PUBLICATION supabase_realtime ADD TABLE public.pointages;

-- ── Calcul des heures : plus de pause forfaitaire de 20 min (décision Hugo, 2026-10-07) ──
-- L'ancien trigger enlevait 20 min à toute journée de plus de 6 h sans pause « pointée »,
-- même quand la pause déjeuner était badgée (sortie puis entrée) : double déduction.
-- Seules les pauses réellement pointées (PAUSE_DEBUT/PAUSE_FIN, ajout admin) sont déduites.
CREATE OR REPLACE FUNCTION public._sync_heures_journalieres()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
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
    -- Somme de chaque cycle Entrée→Sortie (un aller-retour au milieu de la journée n'est pas compté).
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

-- Recalcule les journées où la pause forfaitaire avait été appliquée (relance le trigger sur un pointage du jour).
UPDATE public.pointages p SET valide = p.valide
WHERE p.id IN (
  SELECT DISTINCT ON (hj.employe_id, hj.date) pt.id
  FROM public.heures_journalieres hj
  JOIN public.pointages pt ON pt.employe_id = hj.employe_id AND (pt.horodatage AT TIME ZONE 'Europe/Paris')::date = hj.date
  WHERE hj.pause_legale_appliquee
  ORDER BY hj.employe_id, hj.date, pt.horodatage);
