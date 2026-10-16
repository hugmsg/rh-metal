-- Ménage : anciennes fonctions de calcul des heures, remplacées depuis l'été par le trigger
-- _sync_heures_journalieres. Aucun trigger ni appelant (base, PWA, rh-metal, Apps Script).
DROP FUNCTION IF EXISTS public.trigger_recalcul_journee();
DROP FUNCTION IF EXISTS public.recalculer_journee(uuid, date);
