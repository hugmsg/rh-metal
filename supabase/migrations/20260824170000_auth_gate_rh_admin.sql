-- Chantier 0 (2026-08-24, prérequis au portail salarié) : le portail
-- oblige à partager la même URL rh-metal.vercel.app avec tous les
-- salariés. Comme le côté RH n'a jamais eu d'authentification (protégé
-- uniquement par la confidentialité de l'URL), ça exposerait de fait toute
-- l'app RH à quiconque retire le paramètre d'URL. Ajoute une vraie
-- authentification (Supabase Auth) des deux côtés, avec un rôle qui
-- détermine ce qui s'affiche — jamais un paramètre d'URL.

ALTER TABLE public.employes ADD COLUMN auth_user_id uuid UNIQUE;
ALTER TABLE public.employes ADD COLUMN is_rh_admin boolean NOT NULL DEFAULT false;

-- Bootstrap : email de connexion de Hugo (nécessaire pour l'invitation
-- Supabase Auth, via l'Edge Function activer-portail) + statut admin RH.
UPDATE public.employes
SET email_perso = 'hugo.mesnager@gmail.com', is_rh_admin = true
WHERE id = '599f9bab-11d9-486d-86d8-b63e7ebfbc96';

-- get_mon_role_rh : résout l'identité et le rôle depuis auth.uid() —
-- jamais un id transmis par le client. Utilisé au boot de l'app pour
-- décider quoi afficher (RH complet / portail salarié / accès refusé).
CREATE OR REPLACE FUNCTION public.get_mon_role_rh()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_employe record;
BEGIN
  SELECT id, nom, prenom, is_rh_admin INTO v_employe
  FROM employes WHERE auth_user_id = auth.uid() AND supprime = false;

  IF v_employe.id IS NULL THEN
    RETURN jsonb_build_object('ok', false);
  END IF;

  RETURN jsonb_build_object('ok', true, 'employe_id', v_employe.id, 'nom', v_employe.nom, 'prenom', v_employe.prenom, 'is_rh_admin', v_employe.is_rh_admin);
END;
$function$;
