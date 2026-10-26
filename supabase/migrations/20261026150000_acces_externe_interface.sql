-- Case « Accès externe » dans la fiche (onglet Accès & badge).
-- definir_acces_externe : admin RH seul, motif obligatoire, inscrit au journal.
-- get_employes_rh renvoie acces_externe (nouvelle colonne en fin de liste).

CREATE OR REPLACE FUNCTION public.definir_acces_externe(p_employe_id uuid, p_externe boolean, p_motif text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE e record;
BEGIN
  PERFORM public._exiger_admin_rh();
  IF coalesce(trim(p_motif), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Le motif est obligatoire.');
  END IF;
  SELECT id, prenom, nom, acces_externe, supprime INTO e FROM public.employes WHERE id = p_employe_id FOR UPDATE;
  IF e.id IS NULL OR e.supprime THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Salarié introuvable.');
  END IF;
  IF e.acces_externe = p_externe THEN
    RETURN jsonb_build_object('ok', false, 'message', CASE WHEN p_externe THEN 'L''accès externe est déjà accordé.' ELSE 'Pas d''accès externe à retirer.' END);
  END IF;
  PERFORM public._journal(p_employe_id,
    CASE WHEN p_externe THEN 'Accès externe accordé à ' ELSE 'Accès externe retiré à ' END || e.prenom || ' ' || e.nom, p_motif);
  UPDATE public.employes SET acces_externe = p_externe, updated_at = now() WHERE id = p_employe_id;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.definir_acces_externe(uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.definir_acces_externe(uuid, boolean, text) TO authenticated, service_role;

DROP FUNCTION public.get_employes_rh();
CREATE FUNCTION public.get_employes_rh()
 RETURNS TABLE(id uuid, nom text, prenom text, classe_num smallint, taux_horaire numeric, heures_semaine numeric, heures_sup_semaine numeric, date_entree date, date_sortie date, type_contrat text, poste text, notes text, has_badge boolean, adresse text, telephone_perso text, email_perso text, alerte_vue boolean, portail_actif boolean, hausse_date date, hausse_taux numeric, acces_externe boolean)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  SELECT public._exiger_admin_rh();
  SELECT public._appliquer_remunerations();
  SELECT e.id, e.nom, e.prenom, e.classe_num, e.taux_horaire, e.heures_semaine, e.heures_sup_semaine,
         e.date_entree, e.date_sortie, e.type_contrat, e.poste, e.notes,
         e.nfc_uid IS NOT NULL,
         e.adresse, e.telephone_perso, e.email_perso,
         COALESCE(c.alerte_vue, false),
         e.auth_user_id IS NOT NULL,
         h.date_effet, h.taux_horaire,
         e.acces_externe
  FROM employes e
  LEFT JOIN LATERAL (
    SELECT c.id, c.date_debut, c.alerte_vue FROM contrats c
    WHERE c.employe_id = e.id
    ORDER BY c.date_debut DESC, c.created_at DESC LIMIT 1
  ) c ON true
  LEFT JOIN LATERAL (
    SELECT r.date_effet, r.taux_horaire FROM remunerations r
    WHERE r.contrat_id = c.id
      AND r.date_effet > GREATEST((now() AT TIME ZONE 'Europe/Paris')::date, c.date_debut)
    ORDER BY r.date_effet, r.created_at LIMIT 1
  ) h ON true
  WHERE e.supprime = false
  ORDER BY e.nom, e.prenom;
$function$;

REVOKE ALL ON FUNCTION public.get_employes_rh() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_employes_rh() TO authenticated, service_role;
