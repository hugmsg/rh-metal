-- Connexion PWA refusée faute d'accès : message neutre, valable pour un salarié
-- sorti comme pour une personne externe.

CREATE OR REPLACE FUNCTION public.pwa_connexion(p_compte uuid, p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  c        comptes_pwa%ROWTYPE;
  e        employes%ROWTYPE;
  v_bloc   record;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('connexion_pwa:' || coalesce(p_compte::text, '')));

  SELECT * INTO c FROM comptes_pwa WHERE id = p_compte;
  IF NOT FOUND OR NOT c.actif THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Compte inconnu ou désactivé.');
  END IF;
  SELECT * INTO e FROM employes WHERE id = c.employe_id;
  IF NOT _acces_applis(e) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Accès fermé. Voir avec l''administrateur.');
  END IF;

  SELECT * INTO v_bloc FROM _connexion_pwa_blocage(c.id);
  IF v_bloc.bloque_jusqua IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'bloque', true, 'message',
      CASE v_bloc.raison WHEN 'jour'
        THEN 'Trop d''erreurs : connexion bloquée jusqu''à demain. Un administrateur peut débloquer.'
        ELSE 'Trop d''erreurs : réessayez à ' || to_char(v_bloc.bloque_jusqua AT TIME ZONE 'Europe/Paris', 'HH24"h"MI') || '.' END);
  END IF;

  IF coalesce(p_pin, '') !~ '^[0-9]{4}$' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Format PIN invalide (4 chiffres attendus).');
  END IF;

  IF e.pin_hash IS NULL OR crypt(p_pin, e.pin_hash) <> e.pin_hash THEN
    INSERT INTO connexion_pwa_essais (compte_id, resultat) VALUES (c.id, 'echec');
    SELECT * INTO v_bloc FROM _connexion_pwa_blocage(c.id);
    IF v_bloc.bloque_jusqua IS NOT NULL THEN
      INSERT INTO rh_journal (auteur, employe_id, action, motif)
      VALUES ('PWA', e.id, 'Connexion PWA bloquée',
              CASE v_bloc.raison WHEN 'jour' THEN '10 erreurs dans la journée — bloquée jusqu''à demain'
                                 ELSE '3 erreurs en 10 min — bloquée 10 min' END);
      RETURN jsonb_build_object('ok', false, 'bloque', true, 'message',
        'Code PIN incorrect. Trop d''erreurs : connexion bloquée '
        || CASE v_bloc.raison WHEN 'jour' THEN 'jusqu''à demain.' ELSE 'pendant 10 minutes.' END);
    END IF;
    RETURN jsonb_build_object('ok', false, 'message', 'Code PIN incorrect.');
  END IF;

  INSERT INTO connexion_pwa_essais (compte_id, resultat) VALUES (c.id, 'ok');
  DELETE FROM connexion_pwa_essais WHERE at < now() - interval '90 days';

  RETURN jsonb_build_object('ok', true, 'compte', c.id, 'prenom', e.prenom, 'nom', e.nom,
    'role', c.role, 'activites', to_jsonb(c.activites), 'pin_a_changer', false);
END;
$function$;
