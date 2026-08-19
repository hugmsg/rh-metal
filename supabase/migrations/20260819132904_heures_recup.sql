-- Solde d'heures informel ("récup") — suivi interne, sans valeur légale
-- automatique, ne touche jamais la paie ni les heures sup existantes.
--
-- Contexte (2026-08-19) : pratique informelle chez Sonotrad — un salarié
-- peut faire des heures en plus une semaine pour compenser une absence la
-- semaine suivante. La CCM (IDCC 3248) ne prévoit aucun dispositif
-- individuel ad hoc pour ça (seulement la modulation pluriannuelle,
-- collective et formelle) — Hugo a confirmé vouloir juste un outil de
-- suivi/traçabilité, sans requalification légale automatique en heures sup.
CREATE TABLE public.heures_recup_mouvements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employe_id uuid NOT NULL REFERENCES public.employes(id) ON DELETE CASCADE,
  semaine_debut date NOT NULL,
  delta_min integer NOT NULL,
  type text NOT NULL CHECK (type IN ('auto','manuel')),
  commentaire text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX heures_recup_mouvements_auto_unique
  ON public.heures_recup_mouvements (employe_id, semaine_debut)
  WHERE type = 'auto';

ALTER TABLE public.heures_recup_mouvements ENABLE ROW LEVEL SECURITY;

CREATE POLICY anon_select_heures_recup ON public.heures_recup_mouvements
  FOR SELECT TO anon USING (true);

CREATE VIEW public.heures_recup_vue AS
SELECT m.id, m.employe_id, e.nom, e.prenom, m.semaine_debut, m.delta_min, m.type, m.commentaire, m.created_at
FROM public.heures_recup_mouvements m
JOIN public.employes e ON e.id = m.employe_id
ORDER BY e.nom, e.prenom, m.semaine_debut;

-- Recalcule automatiquement l'écart hebdo (heures pointées vs contrat)
-- à chaque fois qu'une journée est (re)calculée par _sync_heures_journalieres.
-- Volontairement simple : ne tient pas compte des congés posés dans la
-- semaine (une semaine avec des CP dedans ressort "en dessous" du contrat)
-- — à corriger au cas par cas via une ligne manuelle plutôt que de coupler
-- ce module au module Congés.
CREATE OR REPLACE FUNCTION public._sync_heures_recup_auto()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_lundi          date;
  v_dimanche       date;
  v_travaille_min  integer;
  v_contrat_min    integer;
BEGIN
  v_lundi    := NEW.date - ((extract(dow from NEW.date)::int + 6) % 7);
  v_dimanche := v_lundi + 6;

  SELECT round(extract(epoch from coalesce(sum(duree_nette), '0'::interval)) / 60)::integer
    INTO v_travaille_min
  FROM public.heures_journalieres
  WHERE employe_id = NEW.employe_id
    AND date BETWEEN v_lundi AND v_dimanche;

  SELECT round(heures_semaine * 60)::integer INTO v_contrat_min
  FROM public.employes WHERE id = NEW.employe_id;

  IF v_contrat_min IS NULL THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.heures_recup_mouvements (employe_id, semaine_debut, delta_min, type)
  VALUES (NEW.employe_id, v_lundi, v_travaille_min - v_contrat_min, 'auto')
  ON CONFLICT (employe_id, semaine_debut) WHERE type = 'auto'
  DO UPDATE SET delta_min = EXCLUDED.delta_min;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_sync_heures_recup_auto
AFTER INSERT OR UPDATE ON public.heures_journalieres
FOR EACH ROW EXECUTE FUNCTION public._sync_heures_recup_auto();

-- Correction manuelle admin (RPC, cohérent avec admin_add_pointage) — seul
-- moyen d'écrire dans la table côté client, pas de policy INSERT anon.
CREATE OR REPLACE FUNCTION public.ajouter_mouvement_recup(p_employe_id uuid, p_delta_min integer, p_commentaire text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_id uuid;
BEGIN
  IF p_delta_min = 0 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Le nombre d''heures ne peut pas être nul.');
  END IF;
  INSERT INTO public.heures_recup_mouvements (employe_id, semaine_debut, delta_min, type, commentaire)
  VALUES (p_employe_id, current_date, p_delta_min, 'manuel', p_commentaire)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.supprimer_mouvement_recup(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  DELETE FROM public.heures_recup_mouvements WHERE id = p_id AND type = 'manuel';
END;
$function$;

-- Backfill : génère les lignes "auto" pour les semaines déjà pointées avant ce correctif
INSERT INTO public.heures_recup_mouvements (employe_id, semaine_debut, delta_min, type)
SELECT
  hj.employe_id,
  (hj.date - ((extract(dow from hj.date)::int + 6) % 7))::date AS semaine_debut,
  round(extract(epoch from sum(hj.duree_nette)) / 60)::integer - round(e.heures_semaine * 60)::integer,
  'auto'
FROM public.heures_journalieres hj
JOIN public.employes e ON e.id = hj.employe_id
WHERE hj.duree_nette IS NOT NULL AND e.heures_semaine IS NOT NULL
GROUP BY hj.employe_id, (hj.date - ((extract(dow from hj.date)::int + 6) % 7))::date, e.heures_semaine
ON CONFLICT (employe_id, semaine_debut) WHERE type = 'auto'
DO UPDATE SET delta_min = EXCLUDED.delta_min;
