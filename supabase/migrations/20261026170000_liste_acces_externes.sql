-- Tableau « Accès externes » sous la liste Équipe : qui garde l'accès à la PWA
-- sans contrat en cours, avec son compte PWA, son droit admin RH et la dernière
-- inscription au journal (date, auteur, motif). Admin RH seul.

CREATE OR REPLACE FUNCTION public.get_acces_externes_rh()
 RETURNS TABLE(id uuid, nom text, prenom text, date_sortie date, contrat_en_cours boolean, compte_pwa text, compte_actif boolean, is_rh_admin boolean, accorde_le timestamp with time zone, accorde_par text, motif text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  SELECT public._exiger_admin_rh();
  SELECT e.id, e.nom, e.prenom, e.date_sortie, public._employe_present(e),
         c.role, c.actif, e.is_rh_admin,
         j.at, j.auteur, j.motif
  FROM employes e
  LEFT JOIN LATERAL (
    SELECT c.role, c.actif FROM comptes_pwa c
    WHERE c.employe_id = e.id
    ORDER BY c.actif DESC LIMIT 1
  ) c ON true
  LEFT JOIN LATERAL (
    SELECT j.at, j.auteur, j.motif FROM rh_journal j
    WHERE j.employe_id = e.id AND j.action LIKE 'Accès externe accordé%'
    ORDER BY j.id DESC LIMIT 1
  ) j ON true
  WHERE e.acces_externe AND NOT e.supprime
  ORDER BY e.nom, e.prenom;
$function$;

REVOKE ALL ON FUNCTION public.get_acces_externes_rh() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_acces_externes_rh() TO authenticated, service_role;
