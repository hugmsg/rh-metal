-- 2026-10-15 : limite d'essais du PIN au kiosque (règle choisie par Hugo).
-- Le kiosque ne demande que le PIN (pas d'identifiant) : les erreurs sont comptées par
-- compte connecté (le compte kiosque, ou un admin RH qui pointe depuis son poste).
--   - 3 erreurs depuis le dernier pointage réussi, dans les 10 dernières minutes
--     → PIN refusé pendant 10 min après la dernière erreur ;
--   - 10 erreurs dans la journée → PIN refusé jusqu'au lendemain.
-- Le badge n'est pas concerné. Un admin RH peut débloquer depuis Paramètres.

CREATE TABLE IF NOT EXISTS public.pin_essais (
  id            bigserial PRIMARY KEY,
  at            timestamptz NOT NULL DEFAULT clock_timestamp(),
  auth_user_id  uuid NOT NULL,
  resultat      text NOT NULL CHECK (resultat IN ('echec', 'ok', 'deblocage'))
);
CREATE INDEX IF NOT EXISTS pin_essais_user_at_idx ON public.pin_essais (auth_user_id, at DESC);
CREATE INDEX IF NOT EXISTS pin_essais_at_idx ON public.pin_essais (at DESC);
ALTER TABLE public.pin_essais ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pin_essais FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.pin_essais_id_seq FROM PUBLIC, anon, authenticated;

-- État du compteur pour un compte : NULL si le PIN est utilisable, sinon l'heure de fin
-- du blocage (et sa raison).
CREATE OR REPLACE FUNCTION public._pin_blocage(p_user uuid,
  OUT bloque_jusqua timestamptz, OUT raison text, OUT echecs_jour int)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_tz        text := 'Europe/Paris';
  v_jour      timestamptz := date_trunc('day', now() AT TIME ZONE v_tz) AT TIME ZONE v_tz;
  v_demain    timestamptz := (date_trunc('day', now() AT TIME ZONE v_tz) + interval '1 day') AT TIME ZONE v_tz;
  v_deblocage bigint;
  v_ok        bigint;
  v_court     int;
  v_derniere  timestamptz;
BEGIN
  -- Repères par ordre d'enregistrement (id), pas par heure : deux essais peuvent avoir la
  -- même heure.
  SELECT max(id) INTO v_deblocage FROM pin_essais
   WHERE auth_user_id = p_user AND resultat = 'deblocage' AND at >= v_jour;
  SELECT max(id) INTO v_ok FROM pin_essais
   WHERE auth_user_id = p_user AND resultat = 'ok';

  SELECT count(*) INTO echecs_jour FROM pin_essais
   WHERE auth_user_id = p_user AND resultat = 'echec'
     AND at >= v_jour AND id > coalesce(v_deblocage, 0);
  IF echecs_jour >= 10 THEN
    bloque_jusqua := v_demain; raison := 'jour';
    RETURN;
  END IF;

  SELECT count(*), max(at) INTO v_court, v_derniere FROM pin_essais
   WHERE auth_user_id = p_user AND resultat = 'echec'
     AND at > now() - interval '10 minutes'
     AND id > greatest(coalesce(v_ok, 0), coalesce(v_deblocage, 0));
  IF v_court >= 3 THEN
    bloque_jusqua := v_derniere + interval '10 minutes'; raison := 'court';
  END IF;
END;
$$;
REVOKE EXECUTE ON FUNCTION public._pin_blocage(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.pointer_par_pin(p_pin text, p_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_employe employes%ROWTYPE;
  v_verif   jsonb;
  v_bloc    record;
  v_heure   text;
BEGIN
  PERFORM _exiger_kiosque_ou_admin_rh();

  -- Un seul essai à la fois par compte, pour que le compteur soit exact.
  PERFORM pg_advisory_xact_lock(hashtext('pin_essais:' || auth.uid()::text));

  SELECT * INTO v_bloc FROM _pin_blocage(auth.uid());
  IF v_bloc.bloque_jusqua IS NOT NULL THEN
    IF v_bloc.raison = 'jour' THEN
      RETURN jsonb_build_object('ok', false, 'bloque', true,
        'message', 'Code PIN bloqué jusqu''à demain (trop d''erreurs). Utilisez votre badge ou prévenez un responsable.');
    END IF;
    v_heure := to_char(v_bloc.bloque_jusqua AT TIME ZONE 'Europe/Paris', 'HH24"h"MI');
    RETURN jsonb_build_object('ok', false, 'bloque', true,
      'message', 'Trop d''erreurs : code PIN bloqué jusqu''à ' || v_heure || '. Utilisez votre badge en attendant.');
  END IF;

  IF coalesce(p_pin, '') !~ '^[0-9]{4}$' THEN
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
    INSERT INTO pin_essais (auth_user_id, resultat) VALUES (auth.uid(), 'echec');
    SELECT * INTO v_bloc FROM _pin_blocage(auth.uid());
    IF v_bloc.bloque_jusqua IS NOT NULL THEN
      INSERT INTO rh_journal (auteur, action, motif)
      VALUES ('Kiosque', 'PIN kiosque bloqué',
              CASE v_bloc.raison WHEN 'jour' THEN '10 erreurs dans la journée — bloqué jusqu''à demain'
                                 ELSE '3 erreurs en 10 min — bloqué 10 min' END);
      RETURN jsonb_build_object('ok', false, 'bloque', true,
        'message', 'Code PIN incorrect. Trop d''erreurs : code PIN bloqué '
          || CASE v_bloc.raison WHEN 'jour' THEN 'jusqu''à demain.' ELSE 'pendant 10 minutes.' END
          || ' Utilisez votre badge.');
    END IF;
    RETURN jsonb_build_object('ok', false, 'message', 'Code PIN incorrect.');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(v_employe.id::text));

  v_verif := verifier_pointage(v_employe.id, p_type);
  IF NOT (v_verif ->> 'ok')::boolean THEN
    RETURN v_verif;
  END IF;

  INSERT INTO pointages (employe_id, type, source)
  VALUES (v_employe.id, p_type, 'kiosque');
  INSERT INTO pin_essais (auth_user_id, resultat) VALUES (auth.uid(), 'ok');
  DELETE FROM pin_essais WHERE at < now() - interval '90 days';

  RETURN jsonb_build_object(
    'ok',     true,
    'id',     v_employe.id,
    'nom',    v_employe.nom,
    'prenom', v_employe.prenom,
    'type',   p_type
  );
END;
$function$;

-- Admin RH : état du PIN des kiosques (Paramètres).
CREATE OR REPLACE FUNCTION public.etat_pin_kiosque()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_res jsonb := '[]'::jsonb;
  r record;
  b record;
BEGIN
  PERFORM _exiger_admin_rh();
  FOR r IN SELECT DISTINCT auth_user_id FROM pin_essais WHERE at >= now() - interval '1 day' LOOP
    SELECT * INTO b FROM _pin_blocage(r.auth_user_id);
    IF b.echecs_jour > 0 OR b.bloque_jusqua IS NOT NULL THEN
      v_res := v_res || jsonb_build_object(
        'compte', CASE WHEN EXISTS (SELECT 1 FROM comptes_kiosque WHERE auth_user_id = r.auth_user_id)
                       THEN 'Kiosque' ELSE coalesce((SELECT prenom || ' ' || nom FROM employes WHERE auth_user_id = r.auth_user_id LIMIT 1), 'Autre compte') END,
        'echecs_jour', b.echecs_jour,
        'bloque_jusqua', b.bloque_jusqua,
        'raison', b.raison);
    END IF;
  END LOOP;
  RETURN v_res;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.etat_pin_kiosque() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.etat_pin_kiosque() TO authenticated;

-- Admin RH : remet les compteurs à zéro (tous les comptes).
CREATE OR REPLACE FUNCTION public.debloquer_pin_kiosque()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
BEGIN
  PERFORM _exiger_admin_rh();
  INSERT INTO pin_essais (auth_user_id, resultat)
  SELECT DISTINCT auth_user_id, 'deblocage' FROM pin_essais WHERE at >= now() - interval '1 day';
  PERFORM _journal(NULL, 'PIN kiosque débloqué', NULL);
  RETURN jsonb_build_object('ok', true);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.debloquer_pin_kiosque() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.debloquer_pin_kiosque() TO authenticated;
