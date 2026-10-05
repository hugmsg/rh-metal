-- 2026-10-05 — L'annuaire minimal ne doit lister que les salariés PRÉSENTS dans
-- l'entreprise. Signalé par Hugo : Chloe Lechat (CDD terminé le 31/07/2026)
-- apparaissait dans la PWA Admin avec un bouton « Activer l'accès ».
--
-- Même règle que le kiosque (authentifier_par_pin / pointer_par_nfc, migration
-- 20260821152633) : actif ET non supprimé ET (pas de date de sortie OU date de
-- sortie pas encore atteinte). Rien à désactiver à la main : la date de sortie
-- suffit, et la décaler (renouvellement) fait réapparaître le salarié.
--
-- Effet sur la PWA : la liste « fiche RH sans compte » n'affiche plus les anciens
-- salariés ; la suppression d'un compte d'ancien salarié ne touche jamais sa fiche
-- RH (il n'est plus dans l'annuaire, donc pas de supprimer_employe_rh).

CREATE OR REPLACE FUNCTION public.get_employes_annuaire()
 RETURNS TABLE(id uuid, nom text, prenom text, poste text, a_fiche_rh boolean)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT id, nom, prenom, poste, classe_num IS NOT NULL
  FROM employes
  WHERE actif = true
    AND supprime = false
    AND (date_sortie IS NULL OR date_sortie >= current_date)
  ORDER BY nom, prenom;
$function$;
