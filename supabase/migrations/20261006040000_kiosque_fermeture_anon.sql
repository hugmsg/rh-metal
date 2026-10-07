-- 2026-10-06 : le kiosque se connecte avec son compte dédié (20261006030000_compte_kiosque).
-- Les fonctions du kiosque ne sont plus accessibles à la clé anon, et plus aucune écriture
-- directe dans pointages : tout passe par les RPC (pointer_par_pin, pointer_par_nfc, admin_*).

-- Remplacées côté client par pointer_par_pin (verifier_pointage reste appelée en interne).
REVOKE EXECUTE ON FUNCTION public.authentifier_par_pin(text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.verifier_pointage(uuid, text) FROM PUBLIC, anon, authenticated;

-- Badge : même corps, contrôle d'accès ajouté en tête.
CREATE OR REPLACE FUNCTION public.pointer_par_nfc(p_uid text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_employe      employes%ROWTYPE;
  v_dernier_type text;
  v_dernier_ts   timestamptz;
  v_tz           text := 'Europe/Paris';
  v_today        date := (now() AT TIME ZONE v_tz)::date;
  v_type         text;
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

  PERFORM pg_advisory_xact_lock(hashtext(v_employe.id::text));

  SELECT type, horodatage INTO v_dernier_type, v_dernier_ts
  FROM pointages
  WHERE employe_id = v_employe.id
    AND valide = true
    AND (horodatage AT TIME ZONE v_tz)::date = v_today
  ORDER BY horodatage DESC
  LIMIT 1;

  IF v_dernier_ts IS NOT NULL AND v_dernier_ts > now() - interval '5 seconds' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Badge déjà pris en compte.');
  END IF;

  v_type := CASE
    WHEN v_dernier_type IS NULL OR v_dernier_type = 'SORTIE' THEN 'ENTREE'
    ELSE 'SORTIE'
  END;

  INSERT INTO pointages (employe_id, type, source)
  VALUES (v_employe.id, v_type, 'nfc');

  RETURN jsonb_build_object(
    'ok',     true,
    'id',     v_employe.id,
    'nom',    v_employe.nom,
    'prenom', v_employe.prenom,
    'type',   v_type
  );
END;
$$;
REVOKE EXECUTE ON FUNCTION public.pointer_par_nfc(text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.pointer_par_nfc(text) TO authenticated;

-- Plus d'insertion directe : la policy laissait anon créer un pointage pour n'importe qui.
DROP POLICY IF EXISTS anon_insert_pointages ON public.pointages;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.pointages FROM anon, authenticated;
