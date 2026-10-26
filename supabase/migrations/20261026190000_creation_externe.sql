-- Création d'une personne externe depuis rh-metal (« Nouveau salarié » → Personne externe).
-- Toute personne naît dans rh-metal ; la PWA ne fait plus qu'activer un compte.
--  * creer_externe_rh : fiche sans contrat, accès externe, hors kiosque (actif = false).
--  * definir_acces_externe : retirer l'accès d'une personne sans fiche RH la met à la corbeille.
--  * get_employes_annuaire : salariés présents + externes (liste « Activer l'accès » de la PWA).
--  * pwa_compte_creer : exige une personne connue de rh-metal, ne touche plus à actif.
--  * _pwa_resoudre_employe : plus appelée, supprimée.

CREATE OR REPLACE FUNCTION public.creer_externe_rh(p_nom text, p_prenom text, p_notes text, p_adresse text, p_telephone_perso text, p_email_perso text, p_motif text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE v_id uuid; v_doublon text;
BEGIN
  PERFORM public._exiger_admin_rh();
  p_nom := trim(coalesce(p_nom, '')); p_prenom := trim(coalesce(p_prenom, ''));
  IF p_nom = '' OR p_prenom = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Nom et prénom requis.');
  END IF;
  IF coalesce(trim(p_motif), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Le motif est obligatoire.');
  END IF;
  SELECT prenom || ' ' || nom INTO v_doublon FROM public.employes
   WHERE NOT supprime AND unaccent(lower(nom)) = unaccent(lower(p_nom)) AND unaccent(lower(prenom)) = unaccent(lower(p_prenom))
   LIMIT 1;
  IF v_doublon IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', v_doublon || ' existe déjà : ouvrez sa fiche, onglet Accès & badge.');
  END IF;
  INSERT INTO public.employes (nom, prenom, notes, adresse, telephone_perso, email_perso, actif, acces_externe)
  VALUES (p_nom, p_prenom, nullif(trim(coalesce(p_notes, '')), ''), nullif(trim(coalesce(p_adresse, '')), ''),
          nullif(trim(coalesce(p_telephone_perso, '')), ''), nullif(trim(coalesce(p_email_perso, '')), ''), false, true)
  RETURNING id INTO v_id;
  PERFORM public._journal(v_id, 'Accès externe accordé à ' || p_prenom || ' ' || p_nom || ' (personne externe créée)', p_motif);
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.creer_externe_rh(text, text, text, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.creer_externe_rh(text, text, text, text, text, text, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.definir_acces_externe(p_employe_id uuid, p_externe boolean, p_motif text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE e record; v_corbeille boolean;
BEGIN
  PERFORM public._exiger_admin_rh();
  IF coalesce(trim(p_motif), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Le motif est obligatoire.');
  END IF;
  SELECT id, prenom, nom, acces_externe, supprime, classe_num, is_rh_admin INTO e FROM public.employes WHERE id = p_employe_id FOR UPDATE;
  IF e.id IS NULL OR e.supprime THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Salarié introuvable.');
  END IF;
  IF e.acces_externe = p_externe THEN
    RETURN jsonb_build_object('ok', false, 'message', CASE WHEN p_externe THEN 'L''accès externe est déjà accordé.' ELSE 'Pas d''accès externe à retirer.' END);
  END IF;
  -- Sans fiche RH, une personne externe n'a plus de raison d'être une fois l'accès retiré.
  v_corbeille := NOT p_externe AND e.classe_num IS NULL AND NOT e.is_rh_admin;
  PERFORM public._journal(p_employe_id,
    CASE WHEN p_externe THEN 'Accès externe accordé à ' ELSE 'Accès externe retiré à ' END || e.prenom || ' ' || e.nom
    || CASE WHEN v_corbeille THEN ' (mis à la corbeille)' ELSE '' END, p_motif);
  UPDATE public.employes SET acces_externe = p_externe, supprime = supprime OR v_corbeille, updated_at = now() WHERE id = p_employe_id;
  RETURN jsonb_build_object('ok', true, 'corbeille', v_corbeille);
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_employes_annuaire()
 RETURNS TABLE(id uuid, nom text, prenom text, poste text, a_fiche_rh boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT e.id, e.nom, e.prenom, CASE WHEN e.acces_externe AND NOT public._employe_present(e) THEN 'Personne externe' ELSE e.poste END,
         e.classe_num IS NOT NULL
  FROM employes e
  WHERE public._acces_applis(e)
  ORDER BY e.nom, e.prenom;
$function$;

CREATE OR REPLACE FUNCTION public.pwa_compte_creer(p_prenom text, p_nom text, p_role text, p_activites text[], p_pin text, p_employe uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  e    employes;
  v_id uuid;
BEGIN
  IF coalesce(p_role, '') NOT IN ('admin', 'utilisateur') THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Rôle invalide.');
  END IF;
  IF coalesce(array_length(p_activites, 1), 0) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Au moins une activité requise.');
  END IF;
  IF coalesce(p_pin, '') !~ '^[0-9]{4}$' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'PIN invalide (4 chiffres attendus).');
  END IF;

  -- Toute personne est créée dans rh-metal (salarié ou personne externe) ; ici on n'active qu'un compte.
  SELECT * INTO e FROM employes WHERE id = p_employe;
  IF e.id IS NULL OR NOT _acces_applis(e) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Personne inconnue ou sans accès : créez-la d''abord dans rh-metal (salarié ou personne externe).');
  END IF;
  IF EXISTS (SELECT 1 FROM comptes_pwa WHERE employe_id = e.id) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Cet utilisateur a déjà un compte.');
  END IF;
  IF _pin_deja_pris(p_pin, e.id) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Ce PIN est déjà utilisé par un collègue : choisissez-en un autre.');
  END IF;

  UPDATE employes SET pin_hash = crypt(p_pin, gen_salt('bf', 12)), updated_at = now() WHERE id = e.id;
  INSERT INTO comptes_pwa (employe_id, role, activites, pin_migre)
  VALUES (e.id, p_role, p_activites, true)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'employeId', e.id);
END;
$function$;

DROP FUNCTION public._pwa_resoudre_employe(text, text, uuid);
