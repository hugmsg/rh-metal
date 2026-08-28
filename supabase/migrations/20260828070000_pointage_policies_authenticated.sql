-- Régression trouvée le 2026-08-28 : depuis le chantier authentification RH
-- (2026-08-24, migration 20260824170000_auth_gate_rh_admin), un admin RH
-- utilise une vraie session Supabase Auth (rôle Postgres "authenticated"),
-- plus "anon" comme avant. Les policies SELECT de heures_corrections/
-- jours_statut/semaines_validees ne visaient que "anon" (seul rôle qui
-- existait quand elles ont été écrites, avant l'auth) — un admin connecté
-- ne peut donc plus lire ces 3 tables en accès direct (db.from(...), pas
-- via RPC), alors que Rapports et les 4 vues de Contrôle les interrogent
-- directement. Aucun risque de sécurité (les RPC d'écriture, SECURITY
-- DEFINER, appliquent bien _semaine_est_verrouillee() côté serveur
-- indépendamment de RLS — c'est d'ailleurs comme ça que le bug a été
-- repéré : un admin voyait "non verrouillée" mais se faisait quand même
-- bloquer à l'écriture), juste un vrai bug d'affichage depuis le 24/08 :
-- corrections invisibles (absentes aussi des totaux Rapports), jours
-- fériés/non-travaillés invisibles, statut de verrouillage jamais reflété.
--
-- pointages/heures_journalieres ont la même policy anon-only mais restent
-- lisibles admin via les vues heures_rapport_vue/pointages_rapport_vue
-- (une vue Postgres s'exécute par défaut avec les droits de son
-- propriétaire, pas de l'appelant — elle contourne donc cette RLS sans
-- l'avoir prévu). Étendu ici aussi à "authenticated" par cohérence/défense
-- en profondeur, pour ne pas dépendre de cet effet de bord si un futur
-- code interroge un jour la table brute au lieu de la vue.
ALTER POLICY anon_select_heures_corrections ON public.heures_corrections TO anon, authenticated;
ALTER POLICY anon_select_jours_statut ON public.jours_statut TO anon, authenticated;
ALTER POLICY anon_select_semaines_validees ON public.semaines_validees TO anon, authenticated;
ALTER POLICY anon_select_heures_journalieres ON public.heures_journalieres TO anon, authenticated;
ALTER POLICY anon_select_pointages ON public.pointages TO anon, authenticated;
