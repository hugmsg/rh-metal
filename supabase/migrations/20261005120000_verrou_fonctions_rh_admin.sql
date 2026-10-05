-- Phase A de la sécurisation RH (audit 2026-10-02, appliquée le 2026-10-05).
--
-- Constat : depuis le 2026-08-24 rh-metal a un écran de connexion (Supabase Auth,
-- rôle is_rh_admin), mais les fonctions de la base ne vérifiaient pas l'appelant.
-- N'importe qui muni de la clé anon (publique, dans le code des deux fronts)
-- pouvait lire les congés/contrats, purger un salarié, valider une semaine…
--
-- Correctif : _exiger_admin_rh() en première instruction des fonctions que SEUL
-- l'espace admin de rh-metal appelle (vérifié par grep sur rh-metal, sonotrad-pwa,
-- sonotrad-scripts et nfc-bridge le 2026-10-05). Hors périmètre, volontairement :
--   - kiosques (PIN/NFC) : authentifier_par_pin, verifier_pointage, pointer_par_nfc,
--     emettre_signal_nfc — doivent rester anonymes ;
--   - portail salarié : get_mes_*_rh, get_mon_role_rh — déjà contrôlés par auth.uid() ;
--   - appelées aussi par la PWA ou Apps Script (pas d'identité Supabase) : admin_*_pointage,
--     get_employes_rh, supprimer_employe_rh, upsert_employe_pointage, voyages → phase B.
--
-- Rejouable : une fonction qui contient déjà l'appel n'est pas retouchée.

CREATE OR REPLACE FUNCTION public._exiger_admin_rh()
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.employes
    WHERE auth_user_id = auth.uid() AND is_rh_admin AND supprime = false
  ) THEN
    RAISE EXCEPTION 'Accès réservé aux administrateurs RH' USING ERRCODE = '42501';
  END IF;
END;
$function$;

-- Appelée uniquement depuis des fonctions SECURITY DEFINER (droits du propriétaire).
REVOKE ALL ON FUNCTION public._exiger_admin_rh() FROM PUBLIC, anon, authenticated;

DO $migration$
DECLARE
  r     record;
  v_def text;
  v_new text;
BEGIN
  FOR r IN
    SELECT p.oid, p.proname, l.lanname
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    JOIN pg_language  l ON l.oid = p.prolang
    WHERE n.nspname = 'public'
      AND p.proname = ANY (ARRAY[
        'ajouter_correction_heures', 'supprimer_correction_heures',
        'associer_badge_nfc', 'dissocier_badge_nfc',
        'definir_statut_jour', 'effacer_statut_jour',
        'valider_semaine', 'deverrouiller_semaine', 'detecter_anomalies_oubli_sortie',
        'get_conges_rh', 'upsert_conge_rh', 'supprimer_conge_rh',
        'get_contrats_rh', 'upsert_contrat_rh', 'marquer_alerte_contrat_vue_rh',
        'upsert_employe_rh', 'get_employes_supprimes_rh', 'purger_employe_rh'
      ])
  LOOP
    v_def := pg_get_functiondef(r.oid);
    CONTINUE WHEN v_def LIKE '%_exiger_admin_rh%';
    IF r.lanname = 'plpgsql' THEN
      -- juste après le BEGIN du corps
      v_new := regexp_replace(v_def, '(\$function\$.*?\mBEGIN\M)',
                              '\1' || E'\n  PERFORM public._exiger_admin_rh();', 'i');
    ELSE
      -- fonction SQL : instruction préalable, le résultat reste celui de la dernière requête
      v_new := regexp_replace(v_def, '(AS \$function\$)',
                              '\1' || E'\n  SELECT public._exiger_admin_rh();', 'i');
    END IF;
    IF v_new = v_def THEN
      RAISE EXCEPTION 'Injection du contrôle impossible dans %', r.proname;
    END IF;
    EXECUTE v_new;
  END LOOP;
END;
$migration$;

-- Fonctions de déclencheur : jamais appelées directement par un client.
-- (Un déclencheur ne vérifie pas le droit EXECUTE au moment où il se déclenche.)
REVOKE EXECUTE ON FUNCTION public._sync_heures_journalieres()     FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.employes_broadcast_change()     FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.sync_employe_depuis_contrats()  FROM PUBLIC, anon, authenticated;
