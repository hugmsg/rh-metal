-- Jours fériés générés automatiquement par année (11 fériés légaux, Pâques calculé).
-- Une année générée est mémorisée : un férié supprimé dans Paramètres ne revient pas.
-- + un mois ne peut être clôturé qu'une fois terminé.

CREATE TABLE IF NOT EXISTS public.jours_feries_annees (
  annee    int PRIMARY KEY,
  genere_le timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.jours_feries_annees ENABLE ROW LEVEL SECURITY;
CREATE POLICY jours_feries_annees_select ON public.jours_feries_annees FOR SELECT TO authenticated USING (true);
-- 2026 et 2027 ont été saisies par la migration temps_absences.
INSERT INTO public.jours_feries_annees (annee) VALUES (2026), (2027) ON CONFLICT DO NOTHING;

-- Dimanche de Pâques (calendrier grégorien, algorithme de Meeus/Jones/Butcher).
CREATE OR REPLACE FUNCTION public._paques(p_annee int)
 RETURNS date LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE a int; b int; c int; d int; e int; f int; g int; h int; i int; k int; l int; m int;
BEGIN
  a := p_annee % 19; b := p_annee / 100; c := p_annee % 100; d := b / 4; e := b % 4;
  f := (b + 8) / 25; g := (b - f + 1) / 3; h := (19 * a + b - d - g + 15) % 30;
  i := c / 4; k := c % 4; l := (32 + 2 * e + 2 * i - h - k) % 7; m := (a + 11 * h + 22 * l) / 451;
  RETURN make_date(p_annee, (h + l - 7 * m + 114) / 31, ((h + l - 7 * m + 114) % 31) + 1);
END;
$$;

CREATE OR REPLACE FUNCTION public.assurer_jours_feries(p_annee int)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
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
$$;

REVOKE ALL ON FUNCTION public.assurer_jours_feries(int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.assurer_jours_feries(int) TO authenticated;

-- Clôture : mois terminé uniquement, et pas avant la mise en service.
CREATE OR REPLACE FUNCTION public.cloturer_mois(p_mois date, p_resume text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
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
$$;
