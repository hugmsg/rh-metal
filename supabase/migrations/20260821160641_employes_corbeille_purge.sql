-- Chantier 2 (audit RH-Metal 2026-08-21) : la suppression actuelle
-- (supprimer_employe_rh) n'est qu'un soft-delete — les comptes de test
-- restent invisibles dans Équipe mais bien réels en base, sans aucun moyen
-- depuis l'app de finir le nettoyage. Ajoute une vraie corbeille + purge.

-- Liste les salariés déjà soft-deleted (supprime = true), pour la section
-- Corbeille de l'onglet Équipe.
CREATE OR REPLACE FUNCTION public.get_employes_supprimes_rh()
 RETURNS TABLE(id uuid, nom text, prenom text, date_entree date, date_sortie date, type_contrat text, poste text, updated_at timestamptz)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  SELECT id, nom, prenom, date_entree, date_sortie, type_contrat, poste, updated_at
  FROM employes
  WHERE supprime = true
  ORDER BY updated_at DESC;
$function$;

-- Suppression définitive et irréversible — refuse tout salarié qui n'est
-- pas déjà dans la corbeille (garde-fou : impossible de purger direct un
-- salarié actif en un seul appel). Nettoie explicitement les tables liées
-- avant de supprimer la ligne employes : les FK employe_id existantes sont
-- incohérentes (NO ACTION sur conges/heures_journalieres/pointages,
-- CASCADE sur heures_corrections/jours_statut/semaines_validees) — cette
-- fonction ne dépend d'aucune des deux, comportement explicite et prévisible.
CREATE OR REPLACE FUNCTION public.purger_employe_rh(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_supprime boolean;
BEGIN
  SELECT supprime INTO v_supprime FROM employes WHERE id = p_id;
  IF v_supprime IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Salarié introuvable.');
  END IF;
  IF NOT v_supprime THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Ce salarié doit d''abord être supprimé (corbeille) avant purge définitive.');
  END IF;

  DELETE FROM heures_corrections  WHERE employe_id = p_id;
  DELETE FROM jours_statut        WHERE employe_id = p_id;
  DELETE FROM semaines_validees   WHERE employe_id = p_id;
  DELETE FROM heures_journalieres WHERE employe_id = p_id;
  DELETE FROM pointages           WHERE employe_id = p_id;
  DELETE FROM conges              WHERE employe_id = p_id;
  DELETE FROM employes            WHERE id = p_id;

  RETURN jsonb_build_object('ok', true);
END;
$function$;
