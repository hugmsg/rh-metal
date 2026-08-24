-- Chantier "Historique des contrats" (2026-08-24, cadré avec Hugo) :
-- jusqu'ici un renouvellement de CDD/passage CDI se traitait en écrasant
-- date_sortie sur employes — pas d'historique, pas de distinction entre
-- "corriger une date" et "nouveau contrat". Ajoute une vraie table
-- d'historique contractuel, synchronisée automatiquement vers employes
-- (source lue partout ailleurs : paie, dashboard, RPC de pointage
-- partagées avec sonotrad-pwa — rien d'autre à modifier côté lecture).

CREATE TABLE public.contrats (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employe_id uuid NOT NULL REFERENCES public.employes(id) ON DELETE CASCADE,
  date_debut date NOT NULL,
  date_fin date,
  type_contrat text NOT NULL DEFAULT 'CDI',
  classe_num smallint NOT NULL DEFAULT 1,
  taux_horaire numeric NOT NULL DEFAULT 0,
  heures_semaine numeric NOT NULL DEFAULT 35,
  heures_sup_semaine numeric NOT NULL DEFAULT 0,
  poste text,
  -- Régime forfait jour (cadres) : colonnes réservées maintenant sur
  -- demande explicite de Hugo, calcul de paie associé pas implémenté —
  -- aucun salarié actuel n'y est soumis (modèle heures/semaine partout).
  forfait_jour boolean NOT NULL DEFAULT false,
  forfait_jours_an smallint,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.contrats ENABLE ROW LEVEL SECURITY;
-- Pas de policy, comme employes/conges : accès uniquement via RPC
-- SECURITY DEFINER (get_contrats_rh / upsert_contrat_rh / upsert_employe_rh
-- / purger_employe_rh).

CREATE INDEX contrats_employe_id_idx ON public.contrats (employe_id, date_debut DESC);

-- Bootstrap : une ligne par salarié existant à partir de ses valeurs
-- employes actuelles — aucun changement de comportement tant qu'aucun
-- nouvel événement contractuel n'est créé.
INSERT INTO public.contrats (employe_id, date_debut, date_fin, type_contrat, classe_num, taux_horaire, heures_semaine, heures_sup_semaine, poste)
SELECT id, COALESCE(date_entree, current_date), date_sortie, COALESCE(type_contrat, 'CDI'),
       COALESCE(classe_num, 1), COALESCE(taux_horaire, 0), COALESCE(heures_semaine, 35),
       COALESCE(heures_sup_semaine, 0), poste
FROM public.employes;

-- Trigger : recopie le contrat courant (date_debut la plus récente) sur
-- employes après chaque insert/update/delete sur contrats. date_entree
-- fait exception : c'est le MIN(date_debut) sur tout l'historique
-- (ancienneté réelle), pas la date du contrat courant — sinon un
-- renouvellement casserait le calcul du solde CP (calcSoldeCP, module
-- Congés, se base sur date_entree pour le prorata).
CREATE OR REPLACE FUNCTION public.sync_employe_depuis_contrats()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_employe_id uuid := COALESCE(NEW.employe_id, OLD.employe_id);
  v_min_debut date;
  v_courant record;
BEGIN
  SELECT min(date_debut) INTO v_min_debut FROM contrats WHERE employe_id = v_employe_id;

  IF v_min_debut IS NULL THEN
    -- Plus aucun contrat (purge) : purger_employe_rh gère la suppression
    -- complète de la ligne employes, rien à synchroniser ici.
    RETURN COALESCE(NEW, OLD);
  END IF;

  SELECT * INTO v_courant FROM contrats
  WHERE employe_id = v_employe_id
  ORDER BY date_debut DESC, created_at DESC
  LIMIT 1;

  UPDATE employes SET
    date_entree        = v_min_debut,
    date_sortie         = v_courant.date_fin,
    type_contrat        = v_courant.type_contrat,
    classe_num          = v_courant.classe_num,
    taux_horaire        = v_courant.taux_horaire,
    heures_semaine      = v_courant.heures_semaine,
    heures_sup_semaine  = v_courant.heures_sup_semaine,
    poste               = v_courant.poste,
    updated_at          = now()
  WHERE id = v_employe_id;

  RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE TRIGGER contrats_sync_employe
AFTER INSERT OR UPDATE OR DELETE ON public.contrats
FOR EACH ROW EXECUTE FUNCTION public.sync_employe_depuis_contrats();

-- get_contrats_rh : historique complet d'un salarié (le plus récent en 1er).
CREATE OR REPLACE FUNCTION public.get_contrats_rh(p_employe_id uuid)
 RETURNS TABLE(id uuid, date_debut date, date_fin date, type_contrat text, classe_num smallint, taux_horaire numeric, heures_semaine numeric, heures_sup_semaine numeric, poste text, forfait_jour boolean, forfait_jours_an smallint)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  SELECT id, date_debut, date_fin, type_contrat, classe_num, taux_horaire, heures_semaine, heures_sup_semaine, poste, forfait_jour, forfait_jours_an
  FROM contrats
  WHERE employe_id = p_employe_id
  ORDER BY date_debut DESC, created_at DESC;
$function$;

-- upsert_contrat_rh : action explicite "Nouveau contrat" (renouvellement,
-- passage CDI, reprise saisonnière) — crée TOUJOURS une nouvelle ligne,
-- l'ancienne reste intacte comme historique réel (contrairement à
-- upsert_employe_rh qui met à jour le contrat courant en place).
CREATE OR REPLACE FUNCTION public.upsert_contrat_rh(
  p_employe_id uuid, p_date_debut date, p_date_fin date, p_type_contrat text,
  p_classe_num smallint, p_taux_horaire numeric, p_heures_semaine numeric,
  p_heures_sup_semaine numeric, p_poste text,
  p_forfait_jour boolean DEFAULT false, p_forfait_jours_an smallint DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_id uuid;
BEGIN
  IF p_employe_id IS NULL OR p_date_debut IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Salarié et date de début requis.');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM employes WHERE id = p_employe_id AND supprime = false) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Salarié introuvable ou supprimé.');
  END IF;

  INSERT INTO contrats (employe_id, date_debut, date_fin, type_contrat, classe_num, taux_horaire, heures_semaine, heures_sup_semaine, poste, forfait_jour, forfait_jours_an)
  VALUES (p_employe_id, p_date_debut, p_date_fin, p_type_contrat, p_classe_num, p_taux_horaire, p_heures_semaine, p_heures_sup_semaine, p_poste, p_forfait_jour, p_forfait_jours_an)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;

-- upsert_employe_rh : supprime l'ancien doublon à 12 arguments (mort —
-- laissé par le CREATE OR REPLACE de la Phase 3 "profils complets", qui a
-- créé un nouvel overload à 15 arguments au lieu de remplacer l'existant
-- puisque la signature avait changé ; app.js n'appelle que la version à 15
-- arguments). Réécrit la version restante : les champs contrat (classe/
-- taux/heures/poste/type) ne sont plus écrits directement sur employes,
-- ils passent désormais par contrats (mise à jour en place du contrat
-- courant — PAS un nouvel événement contractuel, voir upsert_contrat_rh
-- ci-dessus pour ça). date_sortie reste éditable ici (clôturer/corriger la
-- fin du contrat courant, ex. bulkSetSortie) ; date_entree n'est plus prise
-- en compte une fois qu'un contrat existe déjà (ancienneté réelle, gérée
-- uniquement par le trigger de synchronisation).
DROP FUNCTION IF EXISTS public.upsert_employe_rh(uuid, text, text, smallint, numeric, numeric, numeric, date, date, text, text, text);

CREATE OR REPLACE FUNCTION public.upsert_employe_rh(
  p_id uuid, p_nom text, p_prenom text, p_classe_num smallint,
  p_taux_horaire numeric, p_heures_semaine numeric, p_heures_sup_semaine numeric,
  p_date_entree date, p_date_sortie date, p_type_contrat text, p_poste text, p_notes text,
  p_adresse text DEFAULT NULL, p_telephone_perso text DEFAULT NULL, p_email_perso text DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_id uuid;
  v_contrat_id uuid;
BEGIN
  IF trim(coalesce(p_nom, '')) = '' OR trim(coalesce(p_prenom, '')) = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Nom et prénom requis.');
  END IF;

  IF p_id IS NOT NULL THEN
    UPDATE employes SET
      nom = p_nom, prenom = p_prenom, notes = p_notes,
      adresse = p_adresse, telephone_perso = p_telephone_perso, email_perso = p_email_perso,
      supprime = false, updated_at = now()
    WHERE id = p_id
    RETURNING id INTO v_id;
  END IF;

  IF v_id IS NULL THEN
    SELECT id INTO v_id FROM employes
    WHERE unaccent(lower(nom)) = unaccent(lower(p_nom))
      AND unaccent(lower(prenom)) = unaccent(lower(p_prenom))
    LIMIT 1;

    IF v_id IS NOT NULL THEN
      UPDATE employes SET
        nom = p_nom, prenom = p_prenom, notes = p_notes,
        adresse = p_adresse, telephone_perso = p_telephone_perso, email_perso = p_email_perso,
        supprime = false, updated_at = now()
      WHERE id = v_id;
    ELSE
      INSERT INTO employes (nom, prenom, pin_hash, notes, adresse, telephone_perso, email_perso)
      VALUES (p_nom, p_prenom, NULL, p_notes, p_adresse, p_telephone_perso, p_email_perso)
      RETURNING id INTO v_id;
    END IF;
  END IF;

  SELECT id INTO v_contrat_id FROM contrats
  WHERE employe_id = v_id
  ORDER BY date_debut DESC, created_at DESC
  LIMIT 1;

  IF v_contrat_id IS NULL THEN
    INSERT INTO contrats (employe_id, date_debut, date_fin, type_contrat, classe_num, taux_horaire, heures_semaine, heures_sup_semaine, poste)
    VALUES (v_id, COALESCE(p_date_entree, current_date), p_date_sortie, p_type_contrat, p_classe_num, p_taux_horaire, p_heures_semaine, p_heures_sup_semaine, p_poste);
  ELSE
    UPDATE contrats SET
      type_contrat = p_type_contrat,
      classe_num = p_classe_num,
      taux_horaire = p_taux_horaire,
      heures_semaine = p_heures_semaine,
      heures_sup_semaine = p_heures_sup_semaine,
      poste = p_poste,
      date_fin = p_date_sortie
    WHERE id = v_contrat_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;

-- purger_employe_rh : nettoie aussi contrats avant de supprimer employes
-- (ON DELETE CASCADE le ferait déjà, mais cette fonction nettoie tout
-- explicitement par choix — voir son commentaire d'origine, migration
-- 20260821160641).
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
  DELETE FROM contrats            WHERE employe_id = p_id;
  DELETE FROM employes            WHERE id = p_id;

  RETURN jsonb_build_object('ok', true);
END;
$function$;
