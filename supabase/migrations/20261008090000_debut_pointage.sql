-- Date de mise en service du pointage (fixée avec le prestataire de paie).
-- Les jours antérieurs ne comptent ni dans les heures, ni dans les points à régler, ni dans l'export.
-- Tant qu'elle n'est pas fixée, l'onglet Temps & absences est en phase de test.

ALTER TABLE public.rh_parametres_temps ADD COLUMN IF NOT EXISTS debut_pointage date;

CREATE OR REPLACE FUNCTION public.definir_debut_pointage(p_date date, p_motif text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
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
  -- Le changement ne doit toucher aucun mois verrouillé (tout mois qui finit après la plus ancienne des deux dates).
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
$$;

REVOKE ALL ON FUNCTION public.definir_debut_pointage(date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.definir_debut_pointage(date, text) TO authenticated;

-- Pas de clôture d'un mois entièrement antérieur à la mise en service.
CREATE OR REPLACE FUNCTION public.cloturer_mois(p_mois date, p_resume text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
DECLARE m date := date_trunc('month', p_mois)::date; d date;
BEGIN
  PERFORM public._exiger_admin_rh();
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
$$;
