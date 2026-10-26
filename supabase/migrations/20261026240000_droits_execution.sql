-- Droits d'exécution alignés sur la règle des fonctions RH : comptes connectés et
-- service_role uniquement. _journal n'est appelée que depuis d'autres fonctions.

REVOKE EXECUTE ON FUNCTION public._journal(uuid, text, text) FROM authenticated;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.ajouter_correction_heures(uuid, date, integer, text)',
    'public.associer_badge_nfc(uuid, text)',
    'public.definir_statut_jour(uuid, date, text)',
    'public.detecter_anomalies_oubli_sortie()',
    'public.dissocier_badge_nfc(uuid)',
    'public.effacer_statut_jour(uuid, date)',
    'public.get_conges_rh()',
    'public.get_contrats_rh(uuid)',
    'public.get_employes_supprimes_rh()',
    'public.get_mes_conges_rh()',
    'public.get_mes_heures_rh(date, date)',
    'public.get_mon_role_rh()',
    'public.marquer_alerte_contrat_vue_rh(uuid, boolean)',
    'public.purger_employe_rh(uuid)',
    'public.supprimer_correction_heures(uuid)',
    'public.valider_semaine(uuid, date, text)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f);
  END LOOP;
END $$;
