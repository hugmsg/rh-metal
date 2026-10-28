CREATE OR REPLACE FUNCTION public.kiosque_liste_jour()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tz    text := 'Europe/Paris';
  v_today date := (now() AT TIME ZONE v_tz)::date;
BEGIN
  PERFORM _exiger_kiosque_ou_admin_rh();
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'id',      e.id,
             'prenom',  e.prenom,
             'nom',     e.nom,
             'statut',  CASE WHEN d.dernier IS NULL THEN 'absent'
                             WHEN d.dernier = 'SORTIE' THEN 'parti' ELSE 'present' END,
             'arrivee', d.arrivee,
             'depart',  CASE WHEN d.dernier = 'SORTIE' THEN d.dernier_ts END)
           ORDER BY e.prenom, e.nom)
    FROM employes e
    LEFT JOIN LATERAL (
      SELECT (array_agg(p.type ORDER BY p.horodatage DESC))[1]       AS dernier,
             max(p.horodatage)                                       AS dernier_ts,
             min(p.horodatage) FILTER (WHERE p.type = 'ENTREE')      AS arrivee
      FROM pointages p
      WHERE p.employe_id = e.id
        AND p.valide = true
        AND (p.horodatage AT TIME ZONE v_tz)::date = v_today
    ) d ON true
    WHERE e.actif = true
      AND e.supprime = false
      AND (e.date_sortie IS NULL OR e.date_sortie >= current_date)
  ), '[]'::jsonb);
END;
$function$;

CREATE OR REPLACE FUNCTION public.lier_remplacement_voyage(p_annulee text, p_remplacante text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(trim(p_annulee), '') = '' OR coalesce(trim(p_remplacante), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'numéros requis');
  END IF;
  IF p_annulee = p_remplacante THEN
    RETURN jsonb_build_object('ok', false, 'message', 'une LV ne peut pas se remplacer elle-même');
  END IF;
  UPDATE voyages_annules SET remplacee_par = p_remplacante
   WHERE numero_lv = p_annulee AND remplacee_par IS NULL;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'LV annulée introuvable ou déjà remplacée');
  END IF;
  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'message', sqlerrm);
END;
$function$;

CREATE OR REPLACE FUNCTION public.lire_historique_voyages(p_secret text, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  result jsonb;
  expected text;
BEGIN
  SELECT valeur INTO expected FROM config_interne WHERE cle = 'historique_secret';
  IF expected IS NULL OR p_secret IS DISTINCT FROM expected THEN
    RETURN jsonb_build_object('ok', false, 'message', 'secret invalide');
  END IF;

  WITH dispo AS (
    SELECT v.numero_lv, v.type, v.date_creation, v.destination, v.destination_adresse,
           v.poids, v.ml, v.grutage, v.commentaire, v.marchandises_desc, v.livraison_prevue, v.parti, v.parti_le,
           i.doc_annexe, i.commande, i.conducteur, i.immat_moteur, i.immat_semi, i.expediteur, i.convoi, i.pdf_url,
           false AS annulee, NULL::timestamptz AS annulee_le, NULL::text AS annulee_par, NULL::text AS annulation_motif, NULL::text AS remplacee_par
    FROM voyages v
    LEFT JOIN voyages_internes i ON i.numero_lv = v.numero_lv
    WHERE v.parti = false
  ),
  recents_partis AS (
    SELECT v.numero_lv, v.type, v.date_creation, v.destination, v.destination_adresse,
           v.poids, v.ml, v.grutage, v.commentaire, v.marchandises_desc, v.livraison_prevue, v.parti, v.parti_le,
           i.doc_annexe, i.commande, i.conducteur, i.immat_moteur, i.immat_semi, i.expediteur, i.convoi, i.pdf_url,
           false AS annulee, NULL::timestamptz AS annulee_le, NULL::text AS annulee_par, NULL::text AS annulation_motif, NULL::text AS remplacee_par
    FROM voyages v
    LEFT JOIN voyages_internes i ON i.numero_lv = v.numero_lv
    WHERE v.parti = true
    ORDER BY v.numero_lv::int DESC
    LIMIT GREATEST(1, LEAST(p_limit, 500))
  ),
  annules AS (
    SELECT a.numero_lv, a.type, a.date_creation, a.destination, a.destination_adresse,
           a.poids, a.ml, a.grutage, a.commentaire, a.marchandises_desc, a.livraison_prevue, coalesce(a.parti, false), a.parti_le,
           a.doc_annexe, a.commande, a.conducteur, a.immat_moteur, a.immat_semi, a.expediteur, a.convoi, a.pdf_url,
           true, a.annulee_le, a.annulee_par, a.motif, a.remplacee_par
    FROM voyages_annules a
    WHERE a.annulee_le > now() - interval '90 days'
    ORDER BY a.annulee_le DESC
    LIMIT 100
  )
  SELECT jsonb_agg(row_to_json(t) ORDER BY t.numero_lv::int DESC)
  INTO result
  FROM (
    SELECT u.*, (SELECT string_agg(x.numero_lv, ', ' ORDER BY x.numero_lv) FROM voyages_annules x WHERE x.remplacee_par = u.numero_lv) AS remplace
    FROM (SELECT * FROM dispo UNION ALL SELECT * FROM recents_partis UNION ALL SELECT * FROM annules) u
  ) t;

  RETURN jsonb_build_object('ok', true, 'history', COALESCE(result, '[]'::jsonb));
END;
$function$;

CREATE OR REPLACE FUNCTION public.marquer_alerte_contrat_vue_rh(p_employe_id uuid, p_vue boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_contrat_id uuid;
BEGIN
  PERFORM public._exiger_admin_rh();
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

CREATE OR REPLACE FUNCTION public.marquer_export_mois(p_mois date, p_fichier text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE m date := date_trunc('month', p_mois)::date;
BEGIN
  PERFORM public._exiger_admin_rh();
  UPDATE public.mois_clotures SET exporte_le = now(), exporte_par = public._auteur_rh(), export_perime = false
  WHERE mois = m AND cloture;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Le mois doit être verrouillé avant l''export.');
  END IF;
  PERFORM public._journal(NULL, 'Export ' || p_fichier || ' téléchargé');
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.marquer_parti(p_numero_lv text, p_parti boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  UPDATE voyages
  SET parti    = p_parti,
      parti_le = CASE WHEN p_parti THEN now() ELSE NULL END
  WHERE numero_lv = p_numero_lv;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'numero_lv introuvable : ' || p_numero_lv);
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.modifier_voyage_note(p_numero_lv text, p_commentaire text, p_grutage boolean, p_livraison_prevue date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  IF p_numero_lv IS NULL OR length(trim(p_numero_lv)) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'numero_lv manquant');
  END IF;

  UPDATE voyages
  SET commentaire      = NULLIF(p_commentaire, ''),
      grutage          = COALESCE(p_grutage, false),
      livraison_prevue = p_livraison_prevue
  WHERE numero_lv = p_numero_lv;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'numero_lv introuvable : ' || p_numero_lv);
  END IF;

  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'message', sqlerrm);
END;
$function$;

CREATE OR REPLACE FUNCTION public.ot_fiche(p_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce(_ot_fiche_json(p_id), jsonb_build_object('ok', false, 'message', 'Fiche introuvable'));
$function$;

CREATE OR REPLACE FUNCTION public.ot_fiche_enregistrer(p_id bigint, p_lignes jsonb, p_notes text, p_par text, p_version text, p_admin boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_f ot_fiches;
BEGIN
  SELECT * INTO v_f FROM ot_fiches WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Fiche introuvable');
  END IF;
  IF _stock_iso(v_f.modifie_le) IS DISTINCT FROM p_version THEN
    RETURN jsonb_build_object('ok', false, 'conflit', true,
                              'message', 'La fiche a été modifiée par ailleurs : rechargez-la');
  END IF;
  IF NOT (v_f.statut = 'brouillon' OR (v_f.statut = 'a_valider' AND p_admin)) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Fiche non modifiable (' || v_f.statut || ')');
  END IF;
  IF jsonb_typeof(coalesce(p_lignes, 'null'::jsonb)) <> 'array' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Lignes manquantes');
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_lignes) e
              WHERE coalesce(e->>'bloc', '') NOT IN ('pieces', 'sanitaire', 'diverses', 'travaux')
                 OR coalesce(e->>'origine', 'atelier') NOT IN ('atelier', 'office', 'prevu', 'bureau')
                 OR (e ? 'quantite' AND jsonb_typeof(e->'quantite') NOT IN ('number', 'null'))
                 OR (jsonb_typeof(e->'quantite') = 'number' AND (e->>'quantite')::numeric < 0)
                 OR (btrim(coalesce(e->>'ref', '')) = '' AND btrim(coalesce(e->>'libelle', '')) = '')) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Ligne invalide (bloc, origine, quantité ou réf.)');
  END IF;

  DELETE FROM ot_lignes WHERE fiche_id = p_id;
  INSERT INTO ot_lignes (fiche_id, ordre, bloc, ref, libelle, quantite, unite, occasion,
                         mo_saisi, prix_piece_saisi, origine)
  SELECT p_id, e.n::integer, e.v->>'bloc', nullif(btrim(coalesce(e.v->>'ref', '')), ''),
         btrim(coalesce(e.v->>'libelle', '')),
         CASE WHEN jsonb_typeof(e.v->'quantite') = 'number' THEN (e.v->>'quantite')::numeric END,
         coalesce(nullif(btrim(e.v->>'unite'), ''), 'u'),
         coalesce((e.v->>'occasion')::boolean, false),
         CASE WHEN p_admin AND jsonb_typeof(e.v->'mo_saisi') = 'number' THEN (e.v->>'mo_saisi')::numeric END,
         CASE WHEN p_admin AND jsonb_typeof(e.v->'prix_piece_saisi') = 'number' THEN (e.v->>'prix_piece_saisi')::numeric END,
         coalesce(e.v->>'origine', 'atelier')
    FROM jsonb_array_elements(p_lignes) WITH ORDINALITY AS e(v, n);

  UPDATE ot_fiches
     SET notes = coalesce(p_notes, notes), modifie_le = clock_timestamp(),
         saisi_par = CASE WHEN saisi_par = '' THEN btrim(coalesce(p_par, '')) ELSE saisi_par END
   WHERE id = p_id;
  RETURN _ot_fiche_json(p_id) || jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.ot_fiche_ouvrir(p_code text, p_module jsonb, p_par text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_code text := upper(btrim(coalesce(p_code, '')));
  v_id   bigint;
BEGIN
  IF v_code = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Code planning manquant');
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('ot_fiche:' || v_code));

  SELECT id INTO v_id FROM ot_fiches
   WHERE code_planning = v_code AND statut IN ('brouillon', 'a_valider', 'validee')
   ORDER BY cree_le DESC LIMIT 1;
  IF v_id IS NOT NULL THEN
    RETURN _ot_fiche_json(v_id) || jsonb_build_object('ok', true, 'existante', true);
  END IF;

  INSERT INTO ot_fiches (code_planning, numero_module, agence, type_module, commentaire, saisi_par)
  VALUES (v_code, btrim(coalesce(p_module->>'numero_module', '')), btrim(coalesce(p_module->>'agence', '')),
          btrim(coalesce(p_module->>'type_module', '')), btrim(coalesce(p_module->>'commentaire', '')),
          btrim(coalesce(p_par, '')))
  RETURNING id INTO v_id;

  -- Lignes d'office (modèle « OPERATIONS (2) std » de la matrice) : le bureau retire ce qui ne s'applique pas.
  INSERT INTO ot_lignes (fiche_id, ordre, bloc, ref, libelle, quantite, unite, origine)
  SELECT v_id, o.ordre, 'diverses', o.ref,
         coalesce(f.intitule, r.description, o.ref), 1, 'u', 'office'
    FROM (VALUES (1000, 'E'), (1001, 'SON-0074'), (1002, 'SON-0072')) AS o(ordre, ref)
    LEFT JOIN ot_forfaits f ON f.lettre = o.ref
    LEFT JOIN ot_references r ON r.ref = o.ref;

  -- Poses 🔧 déjà enregistrées dans le stock pour ce code planning.
  INSERT INTO ot_lignes (fiche_id, ordre, bloc, ref, libelle, quantite, unite, origine)
  SELECT v_id, (row_number() OVER (ORDER BY min(m.date), m.ref))::integer, 'pieces', m.ref,
         coalesce(nullif(max(r.description), ''), nullif(max(a.description), ''), m.ref),
         sum(m.quantite), 'u', 'atelier'
    FROM stock_mouvements m
    LEFT JOIN ot_references r ON r.ref = m.ref
    LEFT JOIN stock_articles a ON a.ref = m.ref
   WHERE m.type = 'sortie' AND m.note ~ ('^\[Pose ' || v_code || '\]')
   GROUP BY m.ref
  HAVING sum(m.quantite) > 0;

  RETURN _ot_fiche_json(v_id) || jsonb_build_object('ok', true, 'existante', false);
END;
$function$;

CREATE OR REPLACE FUNCTION public.ot_fiche_statut(p_id bigint, p_statut text, p_par text, p_admin boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_f      ot_fiches;
  v_de     text;
  v_jour   text;
  v_prefix text;
  v_n      integer;
BEGIN
  SELECT * INTO v_f FROM ot_fiches WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Fiche introuvable');
  END IF;
  v_de := v_f.statut;

  IF NOT ((v_de = 'brouillon' AND p_statut = 'a_valider')
       OR (v_de = 'a_valider' AND p_statut = 'brouillon')
       OR (p_admin AND v_de = 'a_valider' AND p_statut = 'validee')
       OR (p_admin AND v_de = 'validee' AND p_statut IN ('a_valider', 'envoyee'))
       OR (p_admin AND v_de <> 'envoyee' AND v_de <> 'annulee' AND p_statut = 'annulee')) THEN
    RETURN jsonb_build_object('ok', false, 'message',
                              'Passage impossible : ' || v_de || ' → ' || coalesce(p_statut, '?'));
  END IF;

  IF p_statut = 'validee' THEN
    IF NOT EXISTS (SELECT 1 FROM ot_lignes WHERE fiche_id = p_id AND coalesce(quantite, 0) > 0) THEN
      RETURN jsonb_build_object('ok', false, 'message', 'Aucune ligne avec quantité');
    END IF;
    UPDATE ot_lignes l SET mo_unitaire = c.mo_unitaire, prix_piece_unitaire = c.prix_piece_unitaire
      FROM _ot_lignes_calcul(p_id) c WHERE c.id = l.id;
    IF v_f.numero_ot IS NULL THEN
      -- Numéro AAMMJJ-NNNN (compteur annuel), préfixé ESSAI- pendant l'essai.
      PERFORM pg_advisory_xact_lock(hashtext('ot_numero'));
      v_jour   := to_char(now() AT TIME ZONE 'Europe/Paris', 'YYMMDD');
      v_prefix := CASE WHEN _ot_parametre('essai') = 1 THEN 'ESSAI-' ELSE '' END;
      SELECT coalesce(max(substring(numero_ot FROM '-([0-9]{4})$')::integer), 0) + 1 INTO v_n
        FROM ot_fiches
       WHERE numero_ot LIKE v_prefix || left(v_jour, 2) || '____-____'
         AND (v_prefix <> '' OR numero_ot NOT LIKE 'ESSAI-%');
      v_f.numero_ot := v_prefix || v_jour || '-' || lpad(v_n::text, 4, '0');
    END IF;
    UPDATE ot_fiches
       SET statut = 'validee', numero_ot = v_f.numero_ot, total_ht = (_ot_totaux(p_id)->>'total')::numeric,
           valide_par = btrim(coalesce(p_par, '')), valide_le = now(), modifie_le = clock_timestamp()
     WHERE id = p_id;
  ELSIF v_de = 'validee' AND p_statut = 'a_valider' THEN
    UPDATE ot_lignes SET mo_unitaire = NULL, prix_piece_unitaire = NULL WHERE fiche_id = p_id;
    UPDATE ot_fiches SET statut = 'a_valider', total_ht = NULL, valide_par = NULL, valide_le = NULL,
                         modifie_le = clock_timestamp()
     WHERE id = p_id;
  ELSE
    UPDATE ot_fiches
       SET statut = p_statut, modifie_le = clock_timestamp(),
           envoye_le = CASE WHEN p_statut = 'envoyee' THEN now() ELSE envoye_le END
     WHERE id = p_id;
  END IF;
  RETURN _ot_fiche_json(p_id) || jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.ot_fiches_liste(p_statuts text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', f.id, 'code_planning', f.code_planning, 'numero_module', f.numero_module,
      'agence', f.agence, 'type_module', f.type_module, 'numero_ot', f.numero_ot, 'statut', f.statut,
      'total_ht', coalesce(f.total_ht, (_ot_totaux(f.id)->>'total')::numeric),
      'saisi_par', f.saisi_par, 'cree_le', _stock_iso(f.cree_le), 'modifie_le', _stock_iso(f.modifie_le),
      'valide_le', _stock_iso(f.valide_le), 'envoye_le', _stock_iso(f.envoye_le),
      'nb_lignes', (SELECT count(*) FROM ot_lignes l WHERE l.fiche_id = f.id AND coalesce(l.quantite, 0) > 0))
      ORDER BY f.modifie_le DESC, f.id DESC), '[]'::jsonb)
    FROM ot_fiches f
   WHERE CASE WHEN coalesce(array_length(p_statuts, 1), 0) = 0 THEN f.statut <> 'annulee'
              ELSE f.statut = ANY (p_statuts) END;
$function$;

CREATE OR REPLACE FUNCTION public.ot_tarif_modifier(p_type text, p_cle text, p_valeurs jsonb, p_par text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cle   text := btrim(coalesce(p_cle, ''));
  v       jsonb := coalesce(p_valeurs, '{}'::jsonb);
  v_avant jsonb;
  v_apres jsonb;
  v_n     integer := 0;
  v_photo bigint;
BEGIN
  IF v_cle = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Clé manquante');
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_each(v) e
              WHERE e.key IN ('mo', 'mo_base', 'temps_min', 'prix_piece', 'mo_plafond', 'valeur')
                AND (jsonb_typeof(e.value) NOT IN ('number', 'null')
                     OR (jsonb_typeof(e.value) = 'number' AND (e.value #>> '{}')::numeric < 0))) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Montant invalide');
  END IF;
  IF v ? 'mode' AND jsonb_typeof(v->'mode') <> 'null'
     AND v->>'mode' NOT IN ('temps', 'base', 'heure', 'minute', 'impose') THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Mode inconnu');
  END IF;

  IF p_type = 'reference' THEN
    SELECT to_jsonb(r) INTO v_avant FROM ot_references r WHERE r.ref = v_cle;
    INSERT INTO ot_references (ref, description)
    VALUES (v_cle, coalesce(v->>'description', (SELECT description FROM stock_articles WHERE ref = v_cle), ''))
    ON CONFLICT (ref) DO NOTHING;
    UPDATE ot_references SET
      description = CASE WHEN v ? 'description' THEN btrim(coalesce(v->>'description', '')) ELSE description END,
      categorie   = CASE WHEN v ? 'categorie' THEN btrim(coalesce(v->>'categorie', '')) ELSE categorie END,
      unite       = CASE WHEN v ? 'unite' THEN coalesce(nullif(btrim(v->>'unite'), ''), 'unité') ELSE unite END,
      mode        = CASE WHEN v ? 'mode' THEN v->>'mode' ELSE mode END,
      temps_min   = CASE WHEN v ? 'temps_min' THEN (v->>'temps_min')::numeric ELSE temps_min END,
      mo_base     = CASE WHEN v ? 'mo_base' THEN (v->>'mo_base')::numeric ELSE mo_base END,
      mo          = CASE WHEN v ? 'mo' THEN (v->>'mo')::numeric ELSE mo END,
      prix_piece  = CASE WHEN v ? 'prix_piece' THEN (v->>'prix_piece')::numeric ELSE prix_piece END,
      mo_plafond  = CASE WHEN v ? 'mo_plafond' THEN (v->>'mo_plafond')::numeric ELSE mo_plafond END,
      modifie_le  = now()
     WHERE ref = v_cle;
    -- Cohérence du mode choisi : ce qu'il faut pour calculer, sinon refus (tout est annulé).
    IF EXISTS (SELECT 1 FROM ot_references WHERE ref = v_cle AND (
         (mode = 'temps' AND NOT coalesce(temps_min, 0) > 0) OR
         (mode = 'base'  AND mo_base IS NULL) OR
         (mode = 'impose' AND mo IS NULL))) THEN
      RAISE EXCEPTION USING MESSAGE = 'Mode incomplet : indiquez le temps, le montant de base ou le prix';
    END IF;
    UPDATE ot_references SET
      mo_base = CASE WHEN mode = 'temps' THEN ceil(temps_min * _ot_parametre('taux_base') / 60) ELSE mo_base END,
      mo = CASE WHEN mode IN ('temps', 'base', 'heure', 'minute')
                THEN _ot_mo_calculee(mode, temps_min, mo_base, _ot_parametre('taux_horaire'), _ot_parametre('taux_base'))
                WHEN mode IS NULL THEN NULL ELSE mo END
     WHERE ref = v_cle;
    SELECT to_jsonb(r) INTO v_apres FROM ot_references r WHERE r.ref = v_cle;
  ELSIF p_type = 'forfait' THEN
    SELECT to_jsonb(f) INTO v_avant FROM ot_forfaits f WHERE f.lettre = v_cle;
    IF v_avant IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'message', 'Forfait inconnu : ' || v_cle);
    END IF;
    UPDATE ot_forfaits SET
      intitule   = CASE WHEN v ? 'intitule' AND btrim(coalesce(v->>'intitule', '')) <> '' THEN btrim(v->>'intitule') ELSE intitule END,
      mo_base    = CASE WHEN v ? 'mo' THEN coalesce((v->>'mo')::numeric, 0) * _ot_parametre('taux_base') / _ot_parametre('taux_horaire')
                        WHEN v ? 'mo_base' THEN coalesce((v->>'mo_base')::numeric, 0) ELSE mo_base END,
      prix_piece = CASE WHEN v ? 'prix_piece' THEN coalesce((v->>'prix_piece')::numeric, 0) ELSE prix_piece END,
      modifie_le = now()
     WHERE lettre = v_cle;
    UPDATE ot_forfaits SET mo = _ot_arrondi_sup(mo_base * _ot_parametre('taux_horaire') / _ot_parametre('taux_base'))
     WHERE lettre = v_cle;
    SELECT to_jsonb(f) INTO v_apres FROM ot_forfaits f WHERE f.lettre = v_cle;
  ELSIF p_type = 'parametre' THEN
    SELECT to_jsonb(p) INTO v_avant FROM ot_parametres p WHERE p.cle = v_cle;
    IF v_avant IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'message', 'Paramètre inconnu : ' || v_cle);
    END IF;
    IF jsonb_typeof(v->'valeur') <> 'number' OR (v->>'valeur')::numeric <= 0 THEN
      RETURN jsonb_build_object('ok', false, 'message', 'Valeur invalide');
    END IF;
    IF v_cle IN ('taux_horaire', 'taux_base') THEN
      v_photo := _ot_photo_tarifs(p_par, 'Avant le passage du ' || CASE v_cle WHEN 'taux_horaire' THEN 'taux horaire' ELSE 'taux de base' END
                 || ' de ' || (v_avant->>'valeur') || ' à ' || (v->>'valeur') || ' €/h');
    END IF;
    UPDATE ot_parametres SET valeur = (v->>'valeur')::numeric WHERE cle = v_cle;
    IF v_cle IN ('taux_horaire', 'taux_base') THEN
      v_n := _ot_recalculer_tarifs();
    END IF;
    SELECT to_jsonb(p) INTO v_apres FROM ot_parametres p WHERE p.cle = v_cle;
    v_apres := v_apres || jsonb_build_object('tarifs_recalcules', v_n, 'photo', v_photo);
  ELSE
    RETURN jsonb_build_object('ok', false, 'message', 'Type inconnu : ' || coalesce(p_type, '?'));
  END IF;

  INSERT INTO ot_tarifs_journal (par, type, cle, avant, apres)
  VALUES (btrim(coalesce(p_par, '')), p_type, v_cle, v_avant, v_apres);
  RETURN jsonb_build_object('ok', true, 'avant', v_avant, 'apres', v_apres, 'recalcules', v_n);
EXCEPTION WHEN raise_exception THEN
  RETURN jsonb_build_object('ok', false, 'message', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.ot_tarifs()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT jsonb_build_object(
    'parametres', (SELECT jsonb_object_agg(cle, valeur) FROM ot_parametres),
    'forfaits', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'lettre', f.lettre, 'intitule', f.intitule, 'mo', f.mo, 'mo_base', f.mo_base, 'prix_piece', f.prix_piece,
        'pieces', coalesce((SELECT jsonb_agg(jsonb_build_object('ref', p.ref, 'qte', p.qte) ORDER BY p.ref)
                              FROM ot_forfait_pieces p WHERE p.lettre = f.lettre), '[]'::jsonb))
        ORDER BY f.lettre) FROM ot_forfaits f), '[]'::jsonb),
    'references', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'ref', r.ref, 'description', r.description, 'categorie', r.categorie, 'unite', r.unite,
        'op_code', r.op_code, 'mode', r.mode, 'temps_min', r.temps_min, 'mo_base', r.mo_base, 'mo', r.mo,
        'prix_piece', r.prix_piece, 'mo_plafond', r.mo_plafond) ORDER BY r.ref) FROM ot_references r), '[]'::jsonb));
$function$;

CREATE OR REPLACE FUNCTION public.ot_tarifs_journal_liste(p_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce(jsonb_agg(jsonb_build_object('le', _stock_iso(j.le), 'par', j.par, 'type', j.type,
                                               'cle', j.cle, 'avant', j.avant, 'apres', j.apres)
                            ORDER BY j.le DESC, j.id DESC), '[]'::jsonb)
    FROM (SELECT * FROM ot_tarifs_journal ORDER BY le DESC, id DESC LIMIT greatest(coalesce(p_limit, 200), 1)) j;
$function$;

CREATE OR REPLACE FUNCTION public.ot_tarifs_photo(p_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce((SELECT jsonb_build_object('id', id, 'le', _stock_iso(le), 'par', par, 'motif', motif,
           'taux_horaire', taux_horaire, 'taux_base', taux_base, 'references', refs, 'forfaits', forfaits)
           FROM ot_tarifs_photos WHERE id = p_id),
         jsonb_build_object('ok', false, 'message', 'Photo introuvable'));
$function$;

CREATE OR REPLACE FUNCTION public.ot_tarifs_photos_liste()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'le', _stock_iso(le), 'par', par, 'motif', motif,
           'taux_horaire', taux_horaire, 'nb_refs', jsonb_array_length(refs), 'nb_forfaits', jsonb_array_length(forfaits))
           ORDER BY le DESC, id DESC), '[]'::jsonb)
    FROM ot_tarifs_photos;
$function$;

CREATE OR REPLACE FUNCTION public.ot_taux_apercu(p_taux numeric)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH p AS (SELECT _ot_parametre('taux_horaire') AS t, _ot_parametre('taux_base') AS tb),
  ch AS (
    SELECT 'reference' AS type, r.ref AS cle, r.description, r.mo AS avant,
           _ot_mo_calculee(r.mode, r.temps_min, r.mo_base, p_taux, p.tb) AS apres
      FROM ot_references r, p WHERE r.mode IN ('temps', 'base', 'heure', 'minute')
    UNION ALL
    SELECT 'forfait', f.lettre, f.intitule, f.mo, _ot_arrondi_sup(f.mo_base * p_taux / p.tb)
      FROM ot_forfaits f, p WHERE f.mo_base IS NOT NULL
  )
  SELECT jsonb_build_object(
    'taux_actuel', (SELECT t FROM p), 'taux_nouveau', p_taux,
    'nb', (SELECT count(*) FROM ch WHERE avant IS DISTINCT FROM apres),
    'changements', coalesce((SELECT jsonb_agg(jsonb_build_object('type', type, 'cle', cle, 'description', description,
                     'avant', avant, 'apres', apres) ORDER BY type DESC, cle) FROM ch WHERE avant IS DISTINCT FROM apres), '[]'::jsonb),
    'imposes', coalesce((SELECT jsonb_agg(jsonb_build_object('ref', ref, 'description', description, 'mo', mo, 'temps_min', temps_min)
                     ORDER BY ref) FROM ot_references WHERE mode = 'impose'), '[]'::jsonb));
$function$;

CREATE OR REPLACE FUNCTION public.pointer_par_nfc(p_uid text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_employe employes%ROWTYPE;
  v_res     jsonb;
BEGIN
  PERFORM _exiger_kiosque_ou_admin_rh();

  IF trim(coalesce(p_uid, '')) = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Badge illisible.');
  END IF;

  SELECT * INTO v_employe
  FROM employes
  WHERE actif = true
    AND supprime = false
    AND (date_sortie IS NULL OR date_sortie >= current_date)
    AND nfc_uid = p_uid
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Badge non reconnu.');
  END IF;

  v_res := _pointer_auto(v_employe.id, 'nfc');
  IF NOT (v_res ->> 'ok')::boolean THEN
    RETURN v_res;
  END IF;
  RETURN v_res || jsonb_build_object('id', v_employe.id, 'nom', v_employe.nom, 'prenom', v_employe.prenom);
END;
$function$;

CREATE OR REPLACE FUNCTION public.pointer_par_pin_employe(p_employe_id uuid, p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_employe employes%ROWTYPE;
  v_bloc    record;
  v_heure   text;
  v_res     jsonb;
BEGIN
  PERFORM _exiger_kiosque_ou_admin_rh();

  PERFORM pg_advisory_xact_lock(hashtext('pin_essais:' || auth.uid()::text));

  SELECT * INTO v_bloc FROM _pin_blocage(auth.uid());
  IF v_bloc.bloque_jusqua IS NOT NULL THEN
    IF v_bloc.raison = 'jour' THEN
      RETURN jsonb_build_object('ok', false, 'bloque', true,
        'message', 'Code PIN bloqué jusqu''à demain (trop d''erreurs). Utilisez votre badge ou prévenez un responsable.');
    END IF;
    v_heure := to_char(v_bloc.bloque_jusqua AT TIME ZONE 'Europe/Paris', 'HH24"h"MI');
    RETURN jsonb_build_object('ok', false, 'bloque', true,
      'message', 'Trop d''erreurs : code PIN bloqué jusqu''à ' || v_heure || '. Utilisez votre badge en attendant.');
  END IF;

  IF coalesce(p_pin, '') !~ '^[0-9]{4}$' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Format PIN invalide (4 chiffres attendus).');
  END IF;

  SELECT * INTO v_employe
  FROM employes
  WHERE id = p_employe_id
    AND actif = true
    AND supprime = false
    AND (date_sortie IS NULL OR date_sortie >= current_date);
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Salarié introuvable.');
  END IF;
  IF v_employe.pin_hash IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Aucun code PIN défini : utilisez votre badge ou prévenez un responsable.');
  END IF;

  IF crypt(p_pin, v_employe.pin_hash) <> v_employe.pin_hash THEN
    INSERT INTO pin_essais (auth_user_id, resultat) VALUES (auth.uid(), 'echec');
    SELECT * INTO v_bloc FROM _pin_blocage(auth.uid());
    IF v_bloc.bloque_jusqua IS NOT NULL THEN
      INSERT INTO rh_journal (auteur, action, motif)
      VALUES ('Kiosque', 'PIN kiosque bloqué',
              CASE v_bloc.raison WHEN 'jour' THEN '10 erreurs dans la journée — bloqué jusqu''à demain'
                                 ELSE '3 erreurs en 10 min — bloqué 10 min' END);
      RETURN jsonb_build_object('ok', false, 'bloque', true,
        'message', 'Code PIN incorrect. Trop d''erreurs : code PIN bloqué '
          || CASE v_bloc.raison WHEN 'jour' THEN 'jusqu''à demain.' ELSE 'pendant 10 minutes.' END
          || ' Utilisez votre badge.');
    END IF;
    RETURN jsonb_build_object('ok', false, 'message', 'Code PIN incorrect.');
  END IF;

  v_res := _pointer_auto(v_employe.id, 'kiosque');
  IF NOT (v_res ->> 'ok')::boolean THEN
    RETURN v_res;
  END IF;
  INSERT INTO pin_essais (auth_user_id, resultat) VALUES (auth.uid(), 'ok');
  DELETE FROM pin_essais WHERE at < now() - interval '90 days';

  RETURN v_res || jsonb_build_object('id', v_employe.id, 'nom', v_employe.nom, 'prenom', v_employe.prenom);
END;
$function$;

CREATE OR REPLACE FUNCTION public.purger_employe_rh(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_supprime boolean;
BEGIN
  PERFORM public._exiger_admin_rh();
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
  INSERT INTO comptes_pwa (employe_id, role, activites)
  VALUES (e.id, p_role, p_activites)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'employeId', e.id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.pwa_compte_debloquer(p_compte uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO connexion_pwa_essais (compte_id, resultat) VALUES (p_compte, 'deblocage');
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.pwa_compte_modifier(p_compte uuid, p_role text DEFAULT NULL::text, p_activites text[] DEFAULT NULL::text[], p_actif boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF p_role IS NOT NULL AND p_role NOT IN ('admin', 'utilisateur') THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Rôle invalide.');
  END IF;
  IF p_activites IS NOT NULL AND coalesce(array_length(p_activites, 1), 0) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Au moins une activité requise.');
  END IF;
  UPDATE comptes_pwa SET
    role      = coalesce(p_role, role),
    activites = coalesce(p_activites, activites),
    actif     = coalesce(p_actif, actif),
    updated_at = now()
  WHERE id = p_compte;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Compte introuvable.');
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.pwa_compte_supprimer(p_compte uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_employe uuid;
BEGIN
  DELETE FROM comptes_pwa WHERE id = p_compte RETURNING employe_id INTO v_employe;
  IF v_employe IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Compte introuvable.');
  END IF;
  UPDATE employes SET supprime = true, updated_at = now()
   WHERE id = v_employe AND classe_num IS NULL AND NOT is_rh_admin AND auth_user_id IS NULL;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.pwa_comptes_connexion()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH c AS (
    SELECT c.id, e.prenom, e.nom,
           e.prenom || ' ' || upper(left(e.nom, 1)) || '.' AS court
      FROM comptes_pwa c JOIN employes e ON e.id = c.employe_id
     WHERE c.actif AND _acces_applis(e)
  ), n AS (
    SELECT *, count(*) OVER (PARTITION BY court) AS homonymes FROM c
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', id,
           'nom', CASE WHEN homonymes > 1 THEN prenom || ' ' || nom ELSE court END)
           ORDER BY prenom, nom), '[]'::jsonb)
    FROM n;
$function$;

CREATE OR REPLACE FUNCTION public.pwa_comptes_liste()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_res jsonb := '[]'::jsonb;
  r record;
  b record;
BEGIN
  FOR r IN
    SELECT c.*, e.prenom, e.nom, e.pin_hash IS NOT NULL AS a_pin, e.classe_num IS NOT NULL AS a_fiche_rh,
           _acces_applis(e) AS present, e.acces_externe
      FROM comptes_pwa c JOIN employes e ON e.id = c.employe_id
     ORDER BY e.prenom, e.nom
  LOOP
    SELECT * INTO b FROM _connexion_pwa_blocage(r.id);
    v_res := v_res || jsonb_build_object(
      'id', r.id, 'prenom', r.prenom, 'nom', r.nom, 'role', r.role, 'actif', r.actif,
      'activites', to_jsonb(r.activites), 'employeId', r.employe_id, 'aFicheRh', r.a_fiche_rh,
      'present', r.present, 'externe', r.acces_externe, 'hasPIN', r.a_pin,
      'bloqueJusqua', b.bloque_jusqua, 'echecsJour', b.echecs_jour);
  END LOOP;
  RETURN v_res;
END;
$function$;

CREATE OR REPLACE FUNCTION public.pwa_connexion(p_compte uuid, p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  c        comptes_pwa%ROWTYPE;
  e        employes%ROWTYPE;
  v_bloc   record;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('connexion_pwa:' || coalesce(p_compte::text, '')));

  SELECT * INTO c FROM comptes_pwa WHERE id = p_compte;
  IF NOT FOUND OR NOT c.actif THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Compte inconnu ou désactivé.');
  END IF;
  SELECT * INTO e FROM employes WHERE id = c.employe_id;
  IF NOT _acces_applis(e) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Accès fermé. Voir avec l''administrateur.');
  END IF;

  SELECT * INTO v_bloc FROM _connexion_pwa_blocage(c.id);
  IF v_bloc.bloque_jusqua IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'bloque', true, 'message',
      CASE v_bloc.raison WHEN 'jour'
        THEN 'Trop d''erreurs : connexion bloquée jusqu''à demain. Un administrateur peut débloquer.'
        ELSE 'Trop d''erreurs : réessayez à ' || to_char(v_bloc.bloque_jusqua AT TIME ZONE 'Europe/Paris', 'HH24"h"MI') || '.' END);
  END IF;

  IF coalesce(p_pin, '') !~ '^[0-9]{4}$' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Format PIN invalide (4 chiffres attendus).');
  END IF;

  IF e.pin_hash IS NULL OR crypt(p_pin, e.pin_hash) <> e.pin_hash THEN
    INSERT INTO connexion_pwa_essais (compte_id, resultat) VALUES (c.id, 'echec');
    SELECT * INTO v_bloc FROM _connexion_pwa_blocage(c.id);
    IF v_bloc.bloque_jusqua IS NOT NULL THEN
      INSERT INTO rh_journal (auteur, employe_id, action, motif)
      VALUES ('PWA', e.id, 'Connexion PWA bloquée',
              CASE v_bloc.raison WHEN 'jour' THEN '10 erreurs dans la journée — bloquée jusqu''à demain'
                                 ELSE '3 erreurs en 10 min — bloquée 10 min' END);
      RETURN jsonb_build_object('ok', false, 'bloque', true, 'message',
        'Code PIN incorrect. Trop d''erreurs : connexion bloquée '
        || CASE v_bloc.raison WHEN 'jour' THEN 'jusqu''à demain.' ELSE 'pendant 10 minutes.' END);
    END IF;
    RETURN jsonb_build_object('ok', false, 'message', 'Code PIN incorrect.');
  END IF;

  INSERT INTO connexion_pwa_essais (compte_id, resultat) VALUES (c.id, 'ok');
  DELETE FROM connexion_pwa_essais WHERE at < now() - interval '90 days';

  RETURN jsonb_build_object('ok', true, 'compte', c.id, 'prenom', e.prenom, 'nom', e.nom,
    'role', c.role, 'activites', to_jsonb(c.activites), 'pin_a_changer', false);
END;
$function$;
