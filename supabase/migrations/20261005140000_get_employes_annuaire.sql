-- 2026-10-05 — Minimisation des données (idée de Hugo) : la PWA et Apps Script
-- appelaient get_employes_rh(), qui renvoie la fiche RH complète (adresse,
-- téléphone et email perso, taux horaire, notes…), alors qu'ils n'utilisent que
-- l'identité. Cette fonction ne renvoie que le strict nécessaire :
--   - PWA écran Admin : liste des fiches RH sans compte (id, prénom, nom, poste)
--   - PWA suppression d'un compte : « a-t-il une fiche RH ? » (a_fiche_rh)
--   - Apps Script backfillEmployeIds : id, prénom, nom
-- get_employes_rh() est ensuite réservée aux admins RH (migration suivante).
-- Même périmètre que get_employes_rh : salariés non supprimés, triés nom/prénom.

CREATE OR REPLACE FUNCTION public.get_employes_annuaire()
 RETURNS TABLE(id uuid, nom text, prenom text, poste text, a_fiche_rh boolean)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT id, nom, prenom, poste, classe_num IS NOT NULL
  FROM employes
  WHERE supprime = false
  ORDER BY nom, prenom;
$function$;
