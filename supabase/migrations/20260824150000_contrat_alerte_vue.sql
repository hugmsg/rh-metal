-- "Vu" sur le bandeau contrats expirés (2026-08-24, suite au chantier
-- contrats) : un salarié non renouvelé mais susceptible de revenir ne doit
-- pas être supprimé (Corbeille = départ définitif) — juste laissé tel quel.
-- Mais le bandeau rouge nagait indéfiniment sans action possible. Ajout
-- d'un simple accusé de réception par contrat (pas un nouveau statut,
-- juste une case à cocher) : "👁 Vu" retire l'alerte de ce salarié du
-- bandeau tant qu'aucun nouveau contrat n'est créé (alerte_vue redémarre
-- à false sur toute nouvelle ligne contrats, cf. son DEFAULT).

ALTER TABLE public.contrats ADD COLUMN alerte_vue boolean NOT NULL DEFAULT false;

-- get_employes_rh : expose alerte_vue du contrat courant (le bandeau lit
-- employees côté client, pas contrats directement) — DROP requis, la
-- liste de colonnes de retour change.
DROP FUNCTION IF EXISTS public.get_employes_rh();

CREATE OR REPLACE FUNCTION public.get_employes_rh()
 RETURNS TABLE(id uuid, nom text, prenom text, classe_num smallint, taux_horaire numeric, heures_semaine numeric, heures_sup_semaine numeric, date_entree date, date_sortie date, type_contrat text, poste text, notes text, has_badge boolean, adresse text, telephone_perso text, email_perso text, alerte_vue boolean)
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
                   ORDER BY c.date_debut DESC, c.created_at DESC LIMIT 1), false)
  FROM employes
  WHERE supprime = false
  ORDER BY nom, prenom;
$function$;

-- marquer_alerte_contrat_vue_rh : bascule alerte_vue sur le contrat
-- courant du salarié (true = accusé réception, false = "dé-voir" — même
-- bouton, réutilisable dans les deux sens).
CREATE OR REPLACE FUNCTION public.marquer_alerte_contrat_vue_rh(p_employe_id uuid, p_vue boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_contrat_id uuid;
BEGIN
  SELECT id INTO v_contrat_id FROM contrats
  WHERE employe_id = p_employe_id
  ORDER BY date_debut DESC, created_at DESC
  LIMIT 1;

  IF v_contrat_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Aucun contrat trouvé.');
  END IF;

  UPDATE contrats SET alerte_vue = p_vue WHERE id = v_contrat_id;

  RETURN jsonb_build_object('ok', true);
END;
$function$;
