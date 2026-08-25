-- Portail salarié — écrans de consultation (2026-08-25). Périmètre cadré le
-- 2026-08-24 (CLAUDE.md "Portail salarié") : un salarié lié (auth_user_id
-- non null, is_rh_admin=false) doit pouvoir consulter UNIQUEMENT ses
-- propres heures/pointages et son solde de congés — jamais ceux d'un
-- collègue. pointages/heures_journalieres/heures_corrections ont une
-- policy anon SELECT true (voulue pour le kiosque, sans login) — un accès
-- direct depuis le portail exposerait donc les heures de tout le monde à
-- n'importe quel salarié connecté (filtrage client contournable via les
-- devtools). D'où des RPC SECURITY DEFINER dédiées, résolvant l'identité
-- via auth.uid() côté serveur, même pattern que get_mon_role_rh().

-- get_mon_role_rh : ajoute date_entree (nécessaire au calcul du solde CP
-- côté portail, réutilise calcSoldeCP() déjà existant côté client) — pas
-- de DROP requis, retour jsonb (pas RETURNS TABLE).
CREATE OR REPLACE FUNCTION public.get_mon_role_rh()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_employe record;
BEGIN
  SELECT id, nom, prenom, is_rh_admin, date_entree INTO v_employe
  FROM employes WHERE auth_user_id = auth.uid() AND supprime = false;

  IF v_employe.id IS NULL THEN
    RETURN jsonb_build_object('ok', false);
  END IF;

  RETURN jsonb_build_object('ok', true, 'employe_id', v_employe.id, 'nom', v_employe.nom,
    'prenom', v_employe.prenom, 'is_rh_admin', v_employe.is_rh_admin, 'date_entree', v_employe.date_entree);
END;
$function$;

-- get_mes_conges_rh : équivalent get_conges_rh (admin, toute la table) mais
-- filtré sur le salarié connecté uniquement.
CREATE OR REPLACE FUNCTION public.get_mes_conges_rh()
 RETURNS SETOF public.conges
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  SELECT c.* FROM conges c
  JOIN employes e ON e.id = c.employe_id
  WHERE e.auth_user_id = auth.uid() AND e.supprime = false
  ORDER BY c.date_debut DESC;
$function$;

-- get_mes_heures_rh : équivalent du triptyque de requêtes de _ptgRapportLoad
-- (heures_rapport_vue + pointages_rapport_vue + heures_corrections) côté
-- admin, combiné en un seul appel jsonb et filtré sur le salarié connecté.
CREATE OR REPLACE FUNCTION public.get_mes_heures_rh(p_debut date, p_fin date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_employe_id uuid;
BEGIN
  SELECT id INTO v_employe_id FROM employes WHERE auth_user_id = auth.uid() AND supprime = false;
  IF v_employe_id IS NULL THEN
    RETURN jsonb_build_object('ok', false);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'heures', COALESCE((SELECT jsonb_agg(h) FROM heures_rapport_vue h
                         WHERE h.employe_id = v_employe_id AND h.date BETWEEN p_debut AND p_fin), '[]'::jsonb),
    'badges', COALESCE((SELECT jsonb_agg(p) FROM pointages_rapport_vue p
                         WHERE p.employe_id = v_employe_id AND p.date BETWEEN p_debut AND p_fin), '[]'::jsonb),
    'corrections', COALESCE((SELECT jsonb_agg(c) FROM heures_corrections c
                              WHERE c.employe_id = v_employe_id AND c.date BETWEEN p_debut AND p_fin), '[]'::jsonb)
  );
END;
$function$;

-- get_employes_rh : expose portail_actif (auth_user_id IS NOT NULL) pour
-- que la fiche salarié sache afficher "Activer l'accès portail" ou
-- "Accès déjà activé" — jamais l'UID/id auth lui-même, juste le booléen.
DROP FUNCTION IF EXISTS public.get_employes_rh();

CREATE OR REPLACE FUNCTION public.get_employes_rh()
 RETURNS TABLE(id uuid, nom text, prenom text, classe_num smallint, taux_horaire numeric, heures_semaine numeric, heures_sup_semaine numeric, date_entree date, date_sortie date, type_contrat text, poste text, notes text, has_badge boolean, adresse text, telephone_perso text, email_perso text, alerte_vue boolean, portail_actif boolean)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  SELECT id, nom, prenom, classe_num, taux_horaire, heures_semaine, heures_sup_semaine,
         date_entree, date_sortie, type_contrat, poste, notes,
         nfc_uid IS NOT NULL,
         adresse, telephone_perso, email_perso,
         COALESCE((SELECT c.alerte_vue FROM contrats c
                   WHERE c.employe_id = employes.id
                   ORDER BY c.date_debut DESC, c.created_at DESC LIMIT 1), false),
         auth_user_id IS NOT NULL
  FROM employes
  WHERE supprime = false
  ORDER BY nom, prenom;
$function$;
