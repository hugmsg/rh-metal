-- Corrige la signature de supprimer_correction_heures avant de pouvoir la
-- redéfinir avec un retour jsonb (nécessaire pour vérifier le verrouillage
-- de semaine ci-dessous) — Postgres refuse un CREATE OR REPLACE qui change
-- le type de retour.
DROP FUNCTION IF EXISTS public.supprimer_correction_heures(uuid);

CREATE OR REPLACE FUNCTION public.supprimer_correction_heures(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_emp uuid;
  v_date date;
BEGIN
  SELECT employe_id, date INTO v_emp, v_date FROM public.heures_corrections WHERE id = p_id;
  IF v_emp IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Correction introuvable.');
  END IF;
  IF public._semaine_est_verrouillee(v_emp, v_date) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Semaine verrouillée — déverrouillez-la avant de supprimer cette correction.');
  END IF;
  DELETE FROM public.heures_corrections WHERE id = p_id;
  RETURN jsonb_build_object('ok', true);
END;
$function$;
