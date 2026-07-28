-- Phase 3 — module Congés. Table dédiée (pas de partage avec sonotrad-pwa,
-- contrairement à employes) : CP, maladie, événement familial, sans solde.
-- Même pattern que employes : RLS activé sans policy, accès uniquement via
-- RPC SECURITY DEFINER.
CREATE TABLE public.conges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employe_id uuid NOT NULL REFERENCES public.employes(id),
  type text NOT NULL CHECK (type IN ('cp','maladie','evenement_familial','sans_solde')),
  date_debut date NOT NULL,
  date_fin date NOT NULL,
  jours numeric NOT NULL,
  motif text,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT conges_dates_check CHECK (date_fin >= date_debut)
);

ALTER TABLE public.conges ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.get_conges_rh()
RETURNS SETOF public.conges
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $function$
  SELECT * FROM conges ORDER BY date_debut DESC;
$function$;

CREATE OR REPLACE FUNCTION public.upsert_conge_rh(
  p_id uuid,
  p_employe_id uuid,
  p_type text,
  p_date_debut date,
  p_date_fin date,
  p_jours numeric,
  p_motif text,
  p_notes text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_id uuid;
BEGIN
  IF p_employe_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Salarié requis.');
  END IF;
  IF p_type NOT IN ('cp','maladie','evenement_familial','sans_solde') THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Type de congé invalide.');
  END IF;
  IF p_date_fin < p_date_debut THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Date de fin avant la date de début.');
  END IF;

  IF p_id IS NOT NULL THEN
    UPDATE conges SET
      employe_id = p_employe_id,
      type       = p_type,
      date_debut = p_date_debut,
      date_fin   = p_date_fin,
      jours      = p_jours,
      motif      = p_motif,
      notes      = p_notes,
      updated_at = now()
    WHERE id = p_id
    RETURNING id INTO v_id;
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO conges (employe_id, type, date_debut, date_fin, jours, motif, notes)
    VALUES (p_employe_id, p_type, p_date_debut, p_date_fin, p_jours, p_motif, p_notes)
    RETURNING id INTO v_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.supprimer_conge_rh(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  DELETE FROM conges WHERE id = p_id;
  RETURN jsonb_build_object('ok', true);
END;
$function$;
