-- 2026-10-16 : kiosque centré sur le badge (lecteur USB). Plus de choix Entrée/Sortie :
-- le type est déduit du dernier pointage du jour, pour le badge comme pour le PIN.
--   - _pointer_auto      : enregistre le pointage suivant (ENTREE ou SORTIE) d'un salarié ;
--   - pointer_par_nfc    : utilise _pointer_auto (comportement inchangé) ;
--   - pointer_par_pin_employe : « badgeage manuel » = choisir son nom puis taper son PIN,
--                          même limite d'essais que pointer_par_pin (par écran connecté) ;
--   - kiosque_liste_jour : salariés présents dans l'effectif + leur état du jour
--                          (présent / parti / pas encore badgé), pour l'écran du kiosque.

CREATE OR REPLACE FUNCTION public._pointer_auto(p_employe_id uuid, p_source text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tz           text := 'Europe/Paris';
  v_today        date := (now() AT TIME ZONE v_tz)::date;
  v_dernier_type text;
  v_dernier_ts   timestamptz;
  v_type         text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext(p_employe_id::text));

  SELECT type, horodatage INTO v_dernier_type, v_dernier_ts
  FROM pointages
  WHERE employe_id = p_employe_id
    AND valide = true
    AND (horodatage AT TIME ZONE v_tz)::date = v_today
  ORDER BY horodatage DESC
  LIMIT 1;

  IF v_dernier_ts IS NOT NULL AND v_dernier_ts > now() - interval '5 seconds' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Pointage déjà pris en compte.');
  END IF;

  v_type := CASE WHEN v_dernier_type IS NULL OR v_dernier_type = 'SORTIE' THEN 'ENTREE' ELSE 'SORTIE' END;

  INSERT INTO pointages (employe_id, type, source) VALUES (p_employe_id, v_type, p_source);
  RETURN jsonb_build_object('ok', true, 'type', v_type);
END;
$function$;
REVOKE EXECUTE ON FUNCTION public._pointer_auto(uuid, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.pointer_par_nfc(p_uid text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_employe employes%ROWTYPE;
  v_res     jsonb;
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

  v_res := _pointer_auto(v_employe.id, 'nfc');
  IF NOT (v_res ->> 'ok')::boolean THEN
    RETURN v_res;
  END IF;
  RETURN v_res || jsonb_build_object('id', v_employe.id, 'nom', v_employe.nom, 'prenom', v_employe.prenom);
END;
$function$;

CREATE OR REPLACE FUNCTION public.pointer_par_pin_employe(p_employe_id uuid, p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_employe employes%ROWTYPE;
  v_bloc    record;
  v_heure   text;
  v_res     jsonb;
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
  WHERE id = p_employe_id
    AND actif = true
    AND supprime = false
    AND (date_sortie IS NULL OR date_sortie >= current_date);
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Salarié introuvable.');
  END IF;
  IF v_employe.pin_hash IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Aucun code PIN défini : utilisez votre badge ou prévenez un responsable.');
  END IF;

  IF crypt(p_pin, v_employe.pin_hash) <> v_employe.pin_hash THEN
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

  v_res := _pointer_auto(v_employe.id, 'kiosque');
  IF NOT (v_res ->> 'ok')::boolean THEN
    RETURN v_res;
  END IF;
  INSERT INTO pin_essais (auth_user_id, resultat) VALUES (auth.uid(), 'ok');
  DELETE FROM pin_essais WHERE at < now() - interval '90 days';

  RETURN v_res || jsonb_build_object('id', v_employe.id, 'nom', v_employe.nom, 'prenom', v_employe.prenom);
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.pointer_par_pin_employe(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.pointer_par_pin_employe(uuid, text) TO authenticated;

-- Liste du jour : uniquement les champs affichés au kiosque (id, prénom, nom, état, heures).
CREATE OR REPLACE FUNCTION public.kiosque_liste_jour()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tz    text := 'Europe/Paris';
  v_today date := (now() AT TIME ZONE v_tz)::date;
BEGIN
  PERFORM _exiger_kiosque_ou_admin_rh();
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'id',      e.id,
             'prenom',  e.prenom,
             'nom',     e.nom,
             'statut',  CASE WHEN d.dernier IS NULL THEN 'absent'
                             WHEN d.dernier = 'SORTIE' THEN 'parti' ELSE 'present' END,
             'arrivee', d.arrivee,
             'depart',  CASE WHEN d.dernier = 'SORTIE' THEN d.dernier_ts END)
           ORDER BY e.prenom, e.nom)
    FROM employes e
    LEFT JOIN LATERAL (
      SELECT (array_agg(p.type ORDER BY p.horodatage DESC))[1]       AS dernier,
             max(p.horodatage)                                       AS dernier_ts,
             min(p.horodatage) FILTER (WHERE p.type = 'ENTREE')      AS arrivee
      FROM pointages p
      WHERE p.employe_id = e.id
        AND p.valide = true
        AND (p.horodatage AT TIME ZONE v_tz)::date = v_today
    ) d ON true
    WHERE e.actif = true
      AND e.supprime = false
      AND (e.date_sortie IS NULL OR e.date_sortie >= current_date)
  ), '[]'::jsonb);
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.kiosque_liste_jour() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.kiosque_liste_jour() TO authenticated;
