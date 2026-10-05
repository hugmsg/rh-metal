-- 2026-10-05 — get_employes_rh() (fiche RH complète : adresse, téléphone et email
-- perso, taux horaire, notes, type de contrat…) réservée aux admins RH.
-- Elle était lisible par n'importe qui muni de la clé anon (publique).
-- Préalables déployés le même jour : la PWA et Apps Script lisent désormais
-- get_employes_annuaire() (identité seule) ; le kiosque rh-metal ne l'appelle
-- plus ; le portail salarié ne l'a jamais appelée. Seul l'espace admin de
-- rh-metal (Supabase Auth + is_rh_admin) l'utilise.

CREATE OR REPLACE FUNCTION public.get_employes_rh()
 RETURNS TABLE(id uuid, nom text, prenom text, classe_num smallint, taux_horaire numeric, heures_semaine numeric, heures_sup_semaine numeric, date_entree date, date_sortie date, type_contrat text, poste text, notes text, has_badge boolean, adresse text, telephone_perso text, email_perso text, alerte_vue boolean, portail_actif boolean)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  SELECT public._exiger_admin_rh();
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
