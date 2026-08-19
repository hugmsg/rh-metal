-- Contrôle hebdomadaire : grille fixe lundi-vendredi par salarié, statut des
-- jours vides (férié / non travaillé confirmé), et verrouillage réel d'une
-- semaine une fois contrôlée (bloque corrections/pointages admin tant que
-- non déverrouillée explicitement, déverrouillage possible).
--
-- Contexte (2026-08-19) : la vue Rapports ne montrait que les jours avec au
-- moins un pointage — un jour totalement oublié (rien pointé) restait
-- invisible, sans façon de le corriger ni de le clore explicitement. Hugo
-- veut une revue salarié par salarié, semaine par semaine, où les 5 jours
-- ouvrés sont toujours affichés (même vides), avec possibilité de les
-- marquer férié ou confirmer qu'ils ne sont pas travaillés, puis verrouiller
-- la semaine une fois contrôlée avant impression/signature.

CREATE TABLE public.jours_statut (
  employe_id  uuid NOT NULL REFERENCES public.employes(id) ON DELETE CASCADE,
  date        date NOT NULL,
  statut      text NOT NULL CHECK (statut IN ('ferie', 'non_travaille')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (employe_id, date)
);

ALTER TABLE public.jours_statut ENABLE ROW LEVEL SECURITY;
CREATE POLICY anon_select_jours_statut ON public.jours_statut FOR SELECT TO anon USING (true);

CREATE TABLE public.semaines_validees (
  employe_id     uuid NOT NULL REFERENCES public.employes(id) ON DELETE CASCADE,
  semaine_debut  date NOT NULL,
  valide_le      timestamptz NOT NULL DEFAULT now(),
  valide_par     text,
  PRIMARY KEY (employe_id, semaine_debut)
);

ALTER TABLE public.semaines_validees ENABLE ROW LEVEL SECURITY;
CREATE POLICY anon_select_semaines_validees ON public.semaines_validees FOR SELECT TO anon USING (true);

CREATE OR REPLACE FUNCTION public._semaine_est_verrouillee(p_employe_id uuid, p_date date)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.semaines_validees
    WHERE employe_id = p_employe_id
      AND semaine_debut = p_date - ((extract(dow from p_date)::int + 6) % 7)
  );
$$;

CREATE OR REPLACE FUNCTION public.valider_semaine(p_employe_id uuid, p_semaine_debut date, p_valide_par text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  INSERT INTO public.semaines_validees (employe_id, semaine_debut, valide_par)
  VALUES (p_employe_id, p_semaine_debut, p_valide_par)
  ON CONFLICT (employe_id, semaine_debut) DO UPDATE SET valide_le = now(), valide_par = EXCLUDED.valide_par;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.deverrouiller_semaine(p_employe_id uuid, p_semaine_debut date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  DELETE FROM public.semaines_validees WHERE employe_id = p_employe_id AND semaine_debut = p_semaine_debut;
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

CREATE OR REPLACE FUNCTION public.effacer_statut_jour(p_employe_id uuid, p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  IF public._semaine_est_verrouillee(p_employe_id, p_date) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Semaine verrouillée — déverrouillez-la avant de modifier ce jour.');
  END IF;
  DELETE FROM public.jours_statut WHERE employe_id = p_employe_id AND date = p_date;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

-- Corrections et pointages admin : refusés si la semaine du jour concerné est verrouillée
CREATE OR REPLACE FUNCTION public.ajouter_correction_heures(p_employe_id uuid, p_date date, p_delta_min integer, p_commentaire text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_id uuid;
BEGIN
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
  VALUES (p_employe_id, p_date, p_delta_min, p_commentaire)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_add_pointage(p_employe_id uuid, p_type text, p_horodatage timestamp with time zone, p_modifie_par text DEFAULT 'admin'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  IF p_type NOT IN ('ENTREE','SORTIE','PAUSE_DEBUT','PAUSE_FIN') THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Type invalide.');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.employes WHERE id = p_employe_id AND actif = true) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Employe introuvable.');
  END IF;
  IF public._semaine_est_verrouillee(p_employe_id, (p_horodatage AT TIME ZONE 'Europe/Paris')::date) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Semaine verrouillée — déverrouillez-la avant de modifier ce pointage.');
  END IF;
  INSERT INTO public.pointages (employe_id, type, horodatage, source, valide, raison_modif, modifie_par)
  VALUES (p_employe_id, p_type, p_horodatage, 'admin', true, 'Ajout manuel', p_modifie_par);
  RETURN jsonb_build_object('ok', true);
END;
$function$;
