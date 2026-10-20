-- Historique de rémunération (2026-10-19)
--
-- Une évolution de salaire n'est pas un nouveau contrat : un contrat (CDI…) garde
-- ses dates, et ses conditions (taux horaire, classe, heures, poste) évoluent dans
-- le temps. Chaque évolution est une ligne datée de `remunerations`, jamais
-- modifiée ensuite (une erreur se corrige par une nouvelle ligne « correction »).
--
-- Les colonnes taux/classe/heures/poste de `contrats` (et donc de `employes`, via
-- `sync_employe_depuis_contrats`) restent en place : elles reflètent la ligne en
-- vigueur, recopiée par `_appliquer_remunerations`. Une évolution saisie à
-- l'avance s'applique à la première lecture de la liste des salariés à partir de
-- sa date d'effet (pas de tâche planifiée sur le projet).

CREATE TABLE public.remunerations (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  contrat_id uuid NOT NULL,
  employe_id uuid NOT NULL,
  date_effet date NOT NULL,
  classe_num smallint NOT NULL,
  taux_horaire numeric(10,2) NOT NULL,
  heures_semaine numeric NOT NULL,
  heures_sup_semaine numeric DEFAULT 0 NOT NULL,
  poste text,
  motif text NOT NULL,
  note text,
  saisi_par text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT remunerations_pkey PRIMARY KEY (id),
  CONSTRAINT remunerations_contrat_id_fkey FOREIGN KEY (contrat_id) REFERENCES public.contrats(id) ON DELETE CASCADE,
  CONSTRAINT remunerations_employe_id_fkey FOREIGN KEY (employe_id) REFERENCES public.employes(id) ON DELETE CASCADE,
  CONSTRAINT remunerations_classe_num_check CHECK (classe_num BETWEEN 1 AND 18),
  CONSTRAINT remunerations_taux_horaire_check CHECK (taux_horaire >= 0),
  CONSTRAINT remunerations_motif_check CHECK (motif = ANY (ARRAY[
    'debut_contrat', 'augmentation_individuelle', 'augmentation_generale',
    'changement_classe', 'avenant', 'minimum_conventionnel', 'correction'
  ]))
);
CREATE INDEX remunerations_contrat_idx ON public.remunerations (contrat_id, date_effet DESC, created_at DESC);
CREATE INDEX remunerations_employe_idx ON public.remunerations (employe_id);
ALTER TABLE public.remunerations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.remunerations FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.remunerations TO service_role;

-- Reprise de l'existant : une ligne « début de contrat » par contrat, avec les
-- valeurs actuelles du contrat.
INSERT INTO public.remunerations (contrat_id, employe_id, date_effet, classe_num, taux_horaire,
                                  heures_semaine, heures_sup_semaine, poste, motif, saisi_par, created_at)
SELECT id, employe_id, date_debut, classe_num, taux_horaire, heures_semaine, heures_sup_semaine,
       poste, 'debut_contrat', 'reprise', created_at
FROM public.contrats;

-- Recopie dans `contrats` la ligne en vigueur : la plus récente dont la date
-- d'effet est passée (à la date du jour, ou au début du contrat s'il est à venir) ;
-- à défaut, la plus ancienne. NULL = tous les contrats.
CREATE OR REPLACE FUNCTION public._appliquer_remunerations(p_contrat_id uuid DEFAULT NULL)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  UPDATE contrats c SET
    classe_num         = r.classe_num,
    taux_horaire       = r.taux_horaire,
    heures_semaine     = r.heures_semaine,
    heures_sup_semaine = r.heures_sup_semaine,
    poste              = r.poste
  FROM (
    SELECT DISTINCT ON (r.contrat_id) r.*
    FROM remunerations r
    JOIN contrats c2 ON c2.id = r.contrat_id
    CROSS JOIN LATERAL (SELECT r.date_effet <= GREATEST((now() AT TIME ZONE 'Europe/Paris')::date, c2.date_debut) AS en_vigueur) v
    WHERE p_contrat_id IS NULL OR r.contrat_id = p_contrat_id
    ORDER BY r.contrat_id, v.en_vigueur DESC,
             CASE WHEN v.en_vigueur THEN r.date_effet END DESC NULLS LAST,
             r.date_effet ASC, r.created_at DESC
  ) r
  WHERE c.id = r.contrat_id
    AND (c.classe_num, c.taux_horaire, c.heures_semaine, c.heures_sup_semaine, c.poste)
        IS DISTINCT FROM (r.classe_num, r.taux_horaire, r.heures_semaine, r.heures_sup_semaine, r.poste);
$function$;

CREATE OR REPLACE FUNCTION public._remuneration_vers_contrat()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public._appliquer_remunerations(COALESCE(NEW.contrat_id, OLD.contrat_id));
  RETURN NULL;
END;
$function$;

CREATE TRIGGER remunerations_vers_contrat AFTER INSERT OR UPDATE OR DELETE ON public.remunerations
  FOR EACH ROW EXECUTE FUNCTION public._remuneration_vers_contrat();

-- Tout nouveau contrat ouvre son historique avec une ligne « début de contrat ».
CREATE OR REPLACE FUNCTION public._contrat_remuneration_initiale()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO remunerations (contrat_id, employe_id, date_effet, classe_num, taux_horaire,
                             heures_semaine, heures_sup_semaine, poste, motif, saisi_par)
  VALUES (NEW.id, NEW.employe_id, NEW.date_debut, NEW.classe_num, NEW.taux_horaire,
          NEW.heures_semaine, NEW.heures_sup_semaine, NEW.poste, 'debut_contrat', public._auteur_rh());
  RETURN NULL;
END;
$function$;

CREATE TRIGGER contrats_remuneration_initiale AFTER INSERT ON public.contrats
  FOR EACH ROW EXECUTE FUNCTION public._contrat_remuneration_initiale();

-- Nouvelle évolution (augmentation, changement de classe, avenant, correction…).
CREATE OR REPLACE FUNCTION public.ajouter_remuneration_rh(
  p_employe_id uuid, p_date_effet date, p_classe_num smallint, p_taux_horaire numeric,
  p_heures_semaine numeric, p_heures_sup_semaine numeric, p_poste text, p_motif text,
  p_note text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_contrat_id uuid;
  v_avant numeric;
  v_id uuid;
BEGIN
  PERFORM public._exiger_admin_rh();
  IF p_employe_id IS NULL OR p_date_effet IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Salarié et date d''effet requis.');
  END IF;
  IF p_motif IS NULL OR p_motif = 'debut_contrat' OR p_motif <> ALL (ARRAY[
       'augmentation_individuelle', 'augmentation_generale', 'changement_classe',
       'avenant', 'minimum_conventionnel', 'correction']) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Motif requis.');
  END IF;
  IF coalesce(p_taux_horaire, 0) <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Taux horaire requis.');
  END IF;
  IF coalesce(p_heures_semaine, 0) <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Heures par semaine requises.');
  END IF;
  IF p_classe_num IS NULL OR p_classe_num NOT BETWEEN 1 AND 18 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Classe invalide.');
  END IF;

  SELECT id INTO v_contrat_id FROM contrats
  WHERE employe_id = p_employe_id
    AND date_debut <= p_date_effet
    AND (date_fin IS NULL OR date_fin >= p_date_effet)
  ORDER BY date_debut DESC, created_at DESC
  LIMIT 1;
  IF v_contrat_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Aucun contrat en cours à cette date.');
  END IF;

  SELECT taux_horaire INTO v_avant FROM remunerations
  WHERE contrat_id = v_contrat_id AND date_effet <= p_date_effet
  ORDER BY date_effet DESC, created_at DESC LIMIT 1;

  INSERT INTO remunerations (contrat_id, employe_id, date_effet, classe_num, taux_horaire,
                             heures_semaine, heures_sup_semaine, poste, motif, note, saisi_par)
  VALUES (v_contrat_id, p_employe_id, p_date_effet, p_classe_num, p_taux_horaire,
          p_heures_semaine, coalesce(p_heures_sup_semaine, 0), nullif(trim(coalesce(p_poste, '')), ''),
          p_motif, nullif(trim(coalesce(p_note, '')), ''), public._auteur_rh())
  RETURNING id INTO v_id;

  PERFORM public._journal(p_employe_id,
    'Rémunération au ' || to_char(p_date_effet, 'DD/MM/YYYY') || ' : '
      || coalesce(public._fmt_num(v_avant) || ' → ', '') || public._fmt_num(p_taux_horaire) || ' €/h, classe ' || p_classe_num,
    p_note);

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_remunerations_rh(p_employe_id uuid)
 RETURNS TABLE(id uuid, contrat_id uuid, contrat_debut date, contrat_fin date, type_contrat text,
               date_effet date, classe_num smallint, taux_horaire numeric, heures_semaine numeric,
               heures_sup_semaine numeric, poste text, motif text, note text, saisi_par text,
               created_at timestamp with time zone, a_venir boolean)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT public._exiger_admin_rh();
  SELECT r.id, c.id, c.date_debut, c.date_fin, c.type_contrat,
         r.date_effet, r.classe_num, r.taux_horaire, r.heures_semaine, r.heures_sup_semaine,
         r.poste, r.motif, r.note, r.saisi_par, r.created_at,
         r.date_effet > GREATEST((now() AT TIME ZONE 'Europe/Paris')::date, c.date_debut)
  FROM remunerations r
  JOIN contrats c ON c.id = r.contrat_id
  WHERE r.employe_id = p_employe_id
  ORDER BY c.date_debut DESC, c.created_at DESC, r.date_effet DESC, r.created_at DESC;
$function$;

-- La liste des salariés applique d'abord les évolutions arrivées à date, et
-- annonce la prochaine évolution déjà saisie sur le contrat courant.
DROP FUNCTION public.get_employes_rh();
CREATE FUNCTION public.get_employes_rh()
 RETURNS TABLE(id uuid, nom text, prenom text, classe_num smallint, taux_horaire numeric, heures_semaine numeric, heures_sup_semaine numeric, date_entree date, date_sortie date, type_contrat text, poste text, notes text, has_badge boolean, adresse text, telephone_perso text, email_perso text, alerte_vue boolean, portail_actif boolean, hausse_date date, hausse_taux numeric)
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
         h.date_effet, h.taux_horaire
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

-- Nouveau contrat (renouvellement, passage en CDI, reprise). Avec
-- p_clore_precedent, le contrat précédent encore ouvert se termine la veille.
DROP FUNCTION public.upsert_contrat_rh(uuid, date, date, text, smallint, numeric, numeric, numeric, text, boolean, smallint);
CREATE FUNCTION public.upsert_contrat_rh(p_employe_id uuid, p_date_debut date, p_date_fin date, p_type_contrat text, p_classe_num smallint, p_taux_horaire numeric, p_heures_semaine numeric, p_heures_sup_semaine numeric, p_poste text, p_forfait_jour boolean DEFAULT false, p_forfait_jours_an smallint DEFAULT NULL::smallint, p_clore_precedent boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_id uuid;
  v_prec record;
BEGIN
  PERFORM public._exiger_admin_rh();
  IF p_employe_id IS NULL OR p_date_debut IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Salarié et date de début requis.');
  END IF;
  IF p_date_fin IS NOT NULL AND p_date_fin < p_date_debut THEN
    RETURN jsonb_build_object('ok', false, 'message', 'La date de fin est avant la date de début.');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM employes WHERE id = p_employe_id AND supprime = false) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Salarié introuvable ou supprimé.');
  END IF;

  IF p_clore_precedent THEN
    SELECT id, date_debut, date_fin INTO v_prec FROM contrats
    WHERE employe_id = p_employe_id
    ORDER BY date_debut DESC, created_at DESC
    LIMIT 1;
    IF v_prec.id IS NOT NULL AND (v_prec.date_fin IS NULL OR v_prec.date_fin >= p_date_debut) THEN
      IF v_prec.date_debut >= p_date_debut THEN
        RETURN jsonb_build_object('ok', false, 'message', 'Le nouveau contrat doit commencer après le début du contrat actuel.');
      END IF;
      UPDATE contrats SET date_fin = p_date_debut - 1 WHERE id = v_prec.id;
    END IF;
  END IF;

  INSERT INTO contrats (employe_id, date_debut, date_fin, type_contrat, classe_num, taux_horaire, heures_semaine, heures_sup_semaine, poste, forfait_jour, forfait_jours_an)
  VALUES (p_employe_id, p_date_debut, p_date_fin, p_type_contrat, p_classe_num, p_taux_horaire, p_heures_semaine, p_heures_sup_semaine, p_poste, p_forfait_jour, p_forfait_jours_an)
  RETURNING id INTO v_id;

  PERFORM public._journal(p_employe_id,
    'Nouveau contrat ' || coalesce(p_type_contrat, '') || ' au ' || to_char(p_date_debut, 'DD/MM/YYYY')
      || CASE WHEN p_date_fin IS NOT NULL THEN ' jusqu''au ' || to_char(p_date_fin, 'DD/MM/YYYY') ELSE '' END,
    NULL);

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;

-- La fiche ne modifie plus les conditions (taux, classe, heures, poste) d'un
-- contrat existant : elles passent par `ajouter_remuneration_rh`. Elle les fixe
-- seulement à la création du premier contrat.
CREATE OR REPLACE FUNCTION public.upsert_employe_rh(p_id uuid, p_nom text, p_prenom text, p_classe_num smallint, p_taux_horaire numeric, p_heures_semaine numeric, p_heures_sup_semaine numeric, p_date_entree date, p_date_sortie date, p_type_contrat text, p_poste text, p_notes text, p_adresse text DEFAULT NULL::text, p_telephone_perso text DEFAULT NULL::text, p_email_perso text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_id uuid;
  v_contrat_id uuid;
BEGIN
  PERFORM public._exiger_admin_rh();
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
      date_fin = p_date_sortie
    WHERE id = v_contrat_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;

REVOKE ALL ON FUNCTION public._appliquer_remunerations(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._remuneration_vers_contrat() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._contrat_remuneration_initiale() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._appliquer_remunerations(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public._remuneration_vers_contrat() TO service_role;
GRANT EXECUTE ON FUNCTION public._contrat_remuneration_initiale() TO service_role;

REVOKE ALL ON FUNCTION public.ajouter_remuneration_rh(uuid, date, smallint, numeric, numeric, numeric, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_remunerations_rh(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ajouter_remuneration_rh(uuid, date, smallint, numeric, numeric, numeric, text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_remunerations_rh(uuid) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.get_employes_rh() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_employes_rh() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.upsert_contrat_rh(uuid, date, date, text, smallint, numeric, numeric, numeric, text, boolean, smallint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_contrat_rh(uuid, date, date, text, smallint, numeric, numeric, numeric, text, boolean, smallint, boolean) TO authenticated, service_role;
