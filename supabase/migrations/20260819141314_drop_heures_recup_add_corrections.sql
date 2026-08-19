-- Retire le module "Récup" (solde séparé, migration 20260819132904) —
-- pas ce que voulait Hugo : il veut corriger directement les heures dans
-- le rapport existant, pas gérer un compteur à part.
DROP TRIGGER IF EXISTS trg_sync_heures_recup_auto ON public.heures_journalieres;
DROP FUNCTION IF EXISTS public._sync_heures_recup_auto();
DROP FUNCTION IF EXISTS public.ajouter_mouvement_recup(uuid, integer, text);
DROP FUNCTION IF EXISTS public.supprimer_mouvement_recup(uuid);
DROP VIEW IF EXISTS public.heures_recup_vue;
DROP TABLE IF EXISTS public.heures_recup_mouvements;

-- Remplacé par : des corrections d'heures directement sur le rapport
-- Pointage, ajoutées/retirées par l'admin, visibles sur le relevé que le
-- salarié signe (transparence : commentaire obligatoire, apparaît sur le PDF).
CREATE TABLE public.heures_corrections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employe_id uuid NOT NULL REFERENCES public.employes(id) ON DELETE CASCADE,
  date date NOT NULL,
  delta_min integer NOT NULL,
  commentaire text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.heures_corrections ENABLE ROW LEVEL SECURITY;

CREATE POLICY anon_select_heures_corrections ON public.heures_corrections
  FOR SELECT TO anon USING (true);

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
  INSERT INTO public.heures_corrections (employe_id, date, delta_min, commentaire)
  VALUES (p_employe_id, p_date, p_delta_min, p_commentaire)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.supprimer_correction_heures(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  DELETE FROM public.heures_corrections WHERE id = p_id;
END;
$function$;
