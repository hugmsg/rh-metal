-- Corrige le trou de sécurité trouvé le 2026-08-21 (cas réel : Anaïs
-- Breteau, CDD terminé le 31/07, toujours actif = true, pouvait encore
-- badger 3 semaines après la fin de son contrat).
--
-- Remplace la condition "actif = true" par une éligibilité calculée à
-- chaque appel : actif ET pas supprimé côté RH ET (pas de date de fin ou
-- date de fin pas encore atteinte). Rien à réactiver manuellement en cas
-- de renouvellement/CDI/reprise saisonnière — décaler ou effacer
-- date_sortie suffit, le PIN/badge/coordonnées ne sont jamais touchés.
--
-- Ces RPC sont partagées avec sonotrad-pwa (même table, même kiosque
-- Pointage côté eux) — ce correctif s'applique donc aussi à leur kiosque.

CREATE OR REPLACE FUNCTION public.authentifier_par_pin(p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_employe employes%ROWTYPE;
BEGIN
  IF length(p_pin) <> 4 OR p_pin !~ '^[0-9]{4}$' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Format PIN invalide (4 chiffres attendus).');
  END IF;

  SELECT * INTO v_employe
  FROM employes
  WHERE actif = true
    AND supprime = false
    AND (date_sortie IS NULL OR date_sortie >= current_date)
    AND crypt(p_pin, pin_hash) = pin_hash
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Code PIN incorrect.');
  END IF;

  RETURN jsonb_build_object(
    'ok',     true,
    'id',     v_employe.id,
    'nom',    v_employe.nom,
    'prenom', v_employe.prenom
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.pointer_par_nfc(p_uid text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_employe      employes%ROWTYPE;
  v_dernier_type text;
  v_dernier_ts   timestamptz;
  v_tz           text := 'Europe/Paris';
  v_today        date := (now() AT TIME ZONE v_tz)::date;
  v_type         text;
BEGIN
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
$function$;

CREATE OR REPLACE VIEW public.employes_actifs_vue AS
SELECT id, nom, prenom
FROM public.employes
WHERE actif = true
  AND supprime = false
  AND (date_sortie IS NULL OR date_sortie >= current_date)
ORDER BY nom, prenom;
