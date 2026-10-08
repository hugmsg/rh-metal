-- Gestion des administrateurs RH depuis Paramètres (motif obligatoire, inscrit au journal).
-- Règle : il reste toujours au moins un administrateur RH utilisable
-- (fiche non supprimée + compte de connexion lié).

-- Liste des comptes liés : administrateurs actuels et candidats possibles.
CREATE OR REPLACE FUNCTION public.get_admins_rh()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
BEGIN
  PERFORM public._exiger_admin_rh();
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'id', e.id, 'nom', e.nom, 'prenom', e.prenom, 'is_rh_admin', e.is_rh_admin,
             'compte', e.auth_user_id IS NOT NULL, 'moi', e.auth_user_id = auth.uid(),
             'date_sortie', e.date_sortie)
           ORDER BY e.is_rh_admin DESC, e.nom, e.prenom)
    FROM public.employes e
    WHERE e.supprime = false AND (e.is_rh_admin OR e.auth_user_id IS NOT NULL)), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION public.definir_admin_rh(p_employe_id uuid, p_admin boolean, p_motif text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
DECLARE e record;
BEGIN
  PERFORM public._exiger_admin_rh();
  IF coalesce(trim(p_motif), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Le motif est obligatoire.');
  END IF;
  SELECT id, prenom, nom, is_rh_admin, auth_user_id, supprime INTO e FROM public.employes WHERE id = p_employe_id FOR UPDATE;
  IF e.id IS NULL OR e.supprime THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Salarié introuvable.');
  END IF;
  IF e.is_rh_admin = p_admin THEN
    RETURN jsonb_build_object('ok', false, 'message', CASE WHEN p_admin THEN 'Déjà administrateur RH.' ELSE 'N''est pas administrateur RH.' END);
  END IF;
  IF p_admin AND e.auth_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Pas de compte de connexion : active d''abord l''accès portail dans sa fiche.');
  END IF;
  IF NOT p_admin AND NOT EXISTS (
    SELECT 1 FROM public.employes
    WHERE id <> p_employe_id AND is_rh_admin AND supprime = false AND auth_user_id IS NOT NULL) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Il doit toujours rester au moins un administrateur RH : nommes-en un autre avant de retirer celui-ci.');
  END IF;
  -- Journal avant la mise à jour : l'auteur est encore résolu si l'admin se retire lui-même.
  PERFORM public._journal(p_employe_id,
    CASE WHEN p_admin THEN 'Droit administrateur RH accordé à ' ELSE 'Droit administrateur RH retiré à ' END || e.prenom || ' ' || e.nom, p_motif);
  UPDATE public.employes SET is_rh_admin = p_admin, updated_at = now() WHERE id = p_employe_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION public.get_admins_rh() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_admins_rh() TO authenticated;
REVOKE ALL ON FUNCTION public.definir_admin_rh(uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.definir_admin_rh(uuid, boolean, text) TO authenticated;

-- La fiche d'un administrateur ne part pas à la corbeille : retirer le droit d'abord.
CREATE OR REPLACE FUNCTION public.supprimer_employe_rh(p_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
BEGIN
  IF coalesce(auth.jwt() ->> 'role', '') <> 'service_role' THEN
    PERFORM _exiger_admin_rh();
  END IF;
  IF EXISTS (SELECT 1 FROM employes WHERE id = p_id AND is_rh_admin) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Administrateur RH : retire-lui d''abord ce droit dans Paramètres.');
  END IF;
  UPDATE employes SET supprime = true, updated_at = now() WHERE id = p_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- Filet de sécurité, quel que soit le chemin (RPC, SQL direct) : jamais zéro administrateur.
CREATE OR REPLACE FUNCTION public._garder_un_admin_rh()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.employes WHERE is_rh_admin AND supprime = false AND auth_user_id IS NOT NULL) THEN
    RAISE EXCEPTION 'Il doit toujours rester au moins un administrateur RH.' USING ERRCODE = '23514';
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS employes_garder_un_admin ON public.employes;
CREATE TRIGGER employes_garder_un_admin AFTER UPDATE OR DELETE ON public.employes
  FOR EACH STATEMENT EXECUTE FUNCTION public._garder_un_admin_rh();
