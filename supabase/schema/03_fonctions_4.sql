CREATE OR REPLACE FUNCTION public.pwa_definir_pin(p_compte uuid, p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_employe uuid;
BEGIN
  IF coalesce(p_pin, '') !~ '^[0-9]{4}$' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'PIN invalide (4 chiffres attendus).');
  END IF;
  SELECT employe_id INTO v_employe FROM comptes_pwa WHERE id = p_compte;
  IF v_employe IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Compte introuvable.');
  END IF;
  IF _pin_deja_pris(p_pin, v_employe) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Ce PIN est déjà utilisé par un collègue : choisissez-en un autre.');
  END IF;
  UPDATE employes SET pin_hash = crypt(p_pin, gen_salt('bf', 12)), updated_at = now() WHERE id = v_employe;
  UPDATE comptes_pwa SET pin_migre = true, updated_at = now() WHERE id = p_compte;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rouvrir_mois(p_mois date, p_motif text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE m date := date_trunc('month', p_mois)::date;
BEGIN
  PERFORM public._exiger_admin_rh();
  IF coalesce(trim(p_motif), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Un motif est obligatoire.');
  END IF;
  UPDATE public.mois_clotures SET cloture = false, export_perime = (exporte_le IS NOT NULL) WHERE mois = m;
  PERFORM public._journal(NULL, 'Mois de ' || to_char(m, 'MM/YYYY') || ' déverrouillé (les semaines restent verrouillées)', p_motif);
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.sauvegarde_empreinte()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
with parts(k, n, h) as (
  select 'tables', count(*), md5(coalesce(string_agg(c.relname, ',' order by c.relname), ''))
    from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
  union all
  select 'colonnes', count(*), md5(coalesce(string_agg(table_name||'.'||column_name||':'||data_type||':'||coalesce(column_default,'')||':'||is_nullable, ',' order by table_name, ordinal_position), ''))
    from information_schema.columns where table_schema = 'public'
  union all
  select 'contraintes', count(*), md5(coalesce(string_agg(conrelid::regclass::text||'.'||conname||':'||pg_get_constraintdef(oid), ',' order by conrelid::regclass::text, conname), ''))
    from pg_constraint where connamespace = 'public'::regnamespace
  union all
  select 'fonctions', count(*), md5(coalesce(string_agg(md5(replace(pg_get_functiondef(p.oid), chr(13), '')), ',' order by p.proname, pg_get_function_identity_arguments(p.oid)), ''))
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  union all
  select 'vues', count(*), md5(coalesce(string_agg(c.relname||':'||pg_get_viewdef(c.oid), ',' order by c.relname), ''))
    from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'v'
  union all
  select 'index', count(*), md5(coalesce(string_agg(indexdef, ',' order by indexname), ''))
    from pg_indexes where schemaname = 'public'
  union all
  select 'triggers', count(*), md5(coalesce(string_agg(pg_get_triggerdef(t.oid), ',' order by c.relname, t.tgname), ''))
    from pg_trigger t join pg_class c on c.oid = t.tgrelid
   where c.relnamespace = 'public'::regnamespace and not t.tgisinternal
  union all
  select 'policies', count(*), md5(coalesce(string_agg(tablename||'.'||policyname||':'||cmd||':'||coalesce(qual,'')||':'||coalesce(with_check,'')||':'||array_to_string(roles,','), ',' order by tablename, policyname), ''))
    from pg_policies where schemaname = 'public'
  union all
  select 'realtime', count(*), md5(coalesce(string_agg(tablename, ',' order by tablename), ''))
    from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public'
  union all
  select 'droits_tables', count(*), md5(coalesce(string_agg(table_name||':'||grantee||':'||privilege_type, ',' order by table_name, grantee, privilege_type), ''))
    from information_schema.role_table_grants
   where table_schema = 'public' and grantee in ('anon', 'authenticated', 'service_role', 'PUBLIC')
  union all
  select 'droits_colonnes', count(*), md5(coalesce(string_agg(table_name||'.'||column_name||':'||grantee||':'||privilege_type, ',' order by table_name, column_name, grantee, privilege_type), ''))
    from information_schema.column_privileges
   where table_schema = 'public' and grantee in ('anon', 'authenticated')
  union all
  select 'droits_fonctions', count(*), md5(coalesce(string_agg(p.proname||'('||pg_get_function_identity_arguments(p.oid)||'):'||r.rolname||':'||has_function_privilege(r.oid, p.oid, 'EXECUTE')::text, ',' order by p.proname, pg_get_function_identity_arguments(p.oid), r.rolname), ''))
    from pg_proc p cross join pg_roles r
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and r.rolname in ('anon', 'authenticated', 'service_role')
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  union all
  select 'droits_sequences', count(*), md5(coalesce(string_agg(c.relname||':'||r.rolname||':'||has_sequence_privilege(r.oid, c.oid, 'USAGE')::text||has_sequence_privilege(r.oid, c.oid, 'SELECT')::text||has_sequence_privilege(r.oid, c.oid, 'UPDATE')::text, ',' order by c.relname, r.rolname), ''))
    from pg_class c cross join pg_roles r
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'S' and r.rolname in ('anon', 'authenticated')
)
select jsonb_build_object(
  'empreinte', md5(string_agg(k||'='||n||':'||h, '|' order by k)),
  'detail', jsonb_object_agg(k, jsonb_build_object('n', n, 'h', h))
) from parts;
$function$;

CREATE OR REPLACE FUNCTION public.sauvegarde_export()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  t      record;
  lignes jsonb;
  res    jsonb := '{}'::jsonb;
begin
  for t in
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind in ('r', 'p')
      and c.relname <> 'config_interne'
    order by c.relname
  loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from public.%I x', t.relname)
      into lignes;
    res := res || jsonb_build_object(t.relname, lignes);
  end loop;
  return jsonb_build_object(
    'genere_le', now(),
    'tables', res,
    'auth_utilisateurs', (select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'email', u.email)), '[]'::jsonb)
                          from auth.users u),
    'stockage_fichiers', (select count(*) from storage.objects)
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.sauvegarde_restaurer(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  t        text;
  n        bigint;
  lignes   jsonb;
  cols     text;
  restant  text[];
  ordre    text[] := '{}';
  pris     boolean;
  auth_map jsonb := '{}'::jsonb;
  manquant text;
  s        record;
  res      jsonb := '{}'::jsonb;
begin
  if p is null or p->'tables' is null then
    raise exception 'Sauvegarde illisible (pas de clé "tables")';
  end if;

  for t in select key from jsonb_each(p->'tables') loop
    if to_regclass(format('public.%I', t)) is null then
      raise exception 'Table % absente : rejouer d''abord la structure', t;
    end if;
    execute format('select count(*) from public.%I', t) into n;
    if n > 0 then
      raise exception 'Table % non vide : restauration refusée', t;
    end if;
  end loop;

  select coalesce(jsonb_object_agg(e->>'id', a.id::text), '{}'::jsonb)
    into auth_map
    from jsonb_array_elements(coalesce(p->'auth_utilisateurs', '[]'::jsonb)) e
    join auth.users a on lower(a.email) = lower(e->>'email');
  select string_agg(e->>'email', ', ')
    into manquant
    from jsonb_array_elements(coalesce(p->'auth_utilisateurs', '[]'::jsonb)) e
    where not exists (select 1 from auth.users a where lower(a.email) = lower(e->>'email'));
  if manquant is not null then
    raise exception 'Comptes de connexion à recréer d''abord (Authentication > Users) : %', manquant;
  end if;

  select array_agg(key order by key) into restant from jsonb_each(p->'tables');
  while coalesce(array_length(restant, 1), 0) > 0 loop
    pris := false;
    foreach t in array restant loop
      if not exists (
        select 1 from pg_constraint c
        where c.contype = 'f'
          and c.conrelid = format('public.%I', t)::regclass
          and c.confrelid <> c.conrelid
          and c.confrelid::regclass::text = any (
                select format('public.%I', r)::regclass::text from unnest(restant) r)
      ) then
        ordre   := ordre || t;
        restant := array_remove(restant, t);
        pris    := true;
      end if;
    end loop;
    if not pris then
      raise exception 'Dépendances circulaires entre : %', restant;
    end if;
  end loop;

  foreach t in array ordre loop
    lignes := p->'tables'->t;
    if lignes is null or jsonb_array_length(lignes) = 0 then
      res := res || jsonb_build_object(t, 0);
      continue;
    end if;
    select coalesce(jsonb_agg(
             case when r ? 'auth_user_id' and auth_map ? (r->>'auth_user_id')
                  then jsonb_set(r, '{auth_user_id}', to_jsonb(auth_map->>(r->>'auth_user_id')))
                  else r end), '[]'::jsonb)
      into lignes
      from jsonb_array_elements(lignes) r;
    select string_agg(quote_ident(a.attname), ', ' order by a.attnum)
      into cols
      from pg_attribute a
      where a.attrelid = format('public.%I', t)::regclass
        and a.attnum > 0 and not a.attisdropped and a.attgenerated = '';
    execute format('alter table public.%I disable trigger user', t);
    execute format(
      'insert into public.%1$I (%2$s) overriding system value select %2$s from jsonb_populate_recordset(null::public.%1$I, $1)',
      t, cols) using lignes;
    execute format('alter table public.%I enable trigger user', t);
    execute format('select count(*) from public.%I', t) into n;
    res := res || jsonb_build_object(t, n);
  end loop;

  for s in
    select d.objid::regclass::text as seq, c.relname as tbl, a.attname as col
    from pg_depend d
    join pg_class c     on c.oid = d.refobjid
    join pg_namespace ns on ns.oid = c.relnamespace and ns.nspname = 'public'
    join pg_attribute a on a.attrelid = d.refobjid and a.attnum = d.refobjsubid
    where d.classid = 'pg_class'::regclass and d.deptype in ('a', 'i')
      and (select relkind from pg_class where oid = d.objid) = 'S'
  loop
    execute format('select setval(%L, coalesce((select max(%I) from public.%I), 0) + 1, false)', s.seq, s.col, s.tbl);
  end loop;

  return jsonb_build_object('restaure_le', now(), 'lignes', res);
end;
$function$;

CREATE OR REPLACE FUNCTION public.supprimer_conge_rh(p_id uuid, p_motif text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE c public.conges%ROWTYPE;
BEGIN
  PERFORM public._exiger_admin_rh();
  SELECT * INTO c FROM public.conges WHERE id = p_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Congé introuvable.');
  END IF;
  IF public._periode_verrouillee(c.employe_id, c.date_debut, c.date_fin) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Une semaine verrouillée est concernée par ce congé — déverrouillez-la avant de le supprimer.');
  END IF;
  DELETE FROM public.conges WHERE id = p_id;
  PERFORM public._journal(c.employe_id, 'Absence supprimée — ' || public._conge_label(c.type)
    || CASE WHEN c.date_debut = c.date_fin THEN ' le ' || public._fmt_jour(c.date_debut)
       ELSE ' du ' || public._fmt_jour(c.date_debut) || ' au ' || public._fmt_jour(c.date_fin) END, p_motif);
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.supprimer_correction_heures(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE c public.heures_corrections%ROWTYPE;
BEGIN
  PERFORM public._exiger_admin_rh();
  SELECT * INTO c FROM public.heures_corrections WHERE id = p_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Correction introuvable.');
  END IF;
  IF public._semaine_est_verrouillee(c.employe_id, c.date) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Semaine verrouillée — déverrouillez-la avant de supprimer cette correction.');
  END IF;
  DELETE FROM public.heures_corrections WHERE id = p_id;
  PERFORM public._journal(c.employe_id, 'Correction supprimée (' || CASE WHEN c.delta_min > 0 THEN '+' ELSE '−' END
    || public._fmt_num(abs(c.delta_min) / 60.0) || ' h le ' || public._fmt_jour(c.date) || ')', c.commentaire);
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.supprimer_employe_rh(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.supprimer_jour_ferie(p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE l text;
BEGIN
  PERFORM public._exiger_admin_rh();
  DELETE FROM public.jours_feries WHERE date = p_date RETURNING libelle INTO l;
  IF l IS NOT NULL THEN PERFORM public._journal(NULL, 'Jour férié supprimé — ' || l || ' le ' || public._fmt_jour(p_date)); END IF;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.supprimer_voyage(p_secret text, p_numero_lv text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  expected text;
BEGIN
  SELECT valeur INTO expected FROM config_interne WHERE cle = 'historique_secret';
  IF expected IS NULL OR p_secret IS DISTINCT FROM expected THEN
    RETURN jsonb_build_object('ok', false, 'message', 'secret invalide');
  END IF;

  IF p_numero_lv IS NULL OR length(trim(p_numero_lv)) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'numero_lv manquant');
  END IF;

  DELETE FROM voyages WHERE numero_lv = p_numero_lv;

  RETURN jsonb_build_object('ok', true, 'deleted', FOUND);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'message', sqlerrm);
END;
$function$;

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

CREATE OR REPLACE FUNCTION public.upsert_conge_rh(p_id uuid, p_employe_id uuid, p_type text, p_date_debut date, p_date_fin date, p_jours numeric, p_motif text, p_notes text, p_demi_journee text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE v_id uuid; v_old public.conges%ROWTYPE; v_txt text;
BEGIN
  PERFORM public._exiger_admin_rh();
  IF p_employe_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Salarié requis.');
  END IF;
  IF p_type NOT IN ('cp','maladie','evenement_familial','sans_solde','autre') THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Type de congé invalide.');
  END IF;
  IF p_type = 'autre' AND coalesce(trim(p_motif), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Précisez le motif pour « Autre ».');
  END IF;
  IF p_date_fin < p_date_debut THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Date de fin avant la date de début.');
  END IF;
  IF p_demi_journee IS NOT NULL AND (p_demi_journee NOT IN ('am','pm') OR p_date_debut <> p_date_fin) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Une demi-journée ne porte que sur un seul jour.');
  END IF;
  IF public._periode_verrouillee(p_employe_id, p_date_debut, p_date_fin) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Une semaine verrouillée est concernée par cette période — déverrouillez-la avant de modifier ce congé.');
  END IF;
  IF p_id IS NOT NULL THEN
    SELECT * INTO v_old FROM public.conges WHERE id = p_id;
    IF FOUND AND public._periode_verrouillee(v_old.employe_id, v_old.date_debut, v_old.date_fin) THEN
      RETURN jsonb_build_object('ok', false, 'message', 'L''absence actuelle touche une semaine verrouillée — déverrouillez-la d''abord.');
    END IF;
    UPDATE public.conges SET employe_id = p_employe_id, type = p_type, date_debut = p_date_debut, date_fin = p_date_fin,
      jours = p_jours, motif = p_motif, notes = p_notes, demi_journee = p_demi_journee, updated_at = now()
    WHERE id = p_id RETURNING id INTO v_id;
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO public.conges (employe_id, type, date_debut, date_fin, jours, motif, notes, demi_journee)
    VALUES (p_employe_id, p_type, p_date_debut, p_date_fin, p_jours, p_motif, p_notes, p_demi_journee)
    RETURNING id INTO v_id;
  END IF;
  v_txt := public._conge_label(p_type)
    || CASE WHEN p_date_debut = p_date_fin THEN ' le ' || public._fmt_jour(p_date_debut)
            || CASE p_demi_journee WHEN 'am' THEN ' (matin)' WHEN 'pm' THEN ' (après-midi)' ELSE '' END
       ELSE ' du ' || public._fmt_jour(p_date_debut) || ' au ' || public._fmt_jour(p_date_fin) END
    || ' (' || public._fmt_num(p_jours) || ' j)';
  PERFORM public._journal(p_employe_id, CASE WHEN v_old.id IS NOT NULL THEN 'Absence modifiée — ' ELSE 'Absence — ' END || v_txt, coalesce(p_motif, p_notes));
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.upsert_contrat_rh(p_employe_id uuid, p_date_debut date, p_date_fin date, p_type_contrat text, p_classe_num smallint, p_taux_horaire numeric, p_heures_semaine numeric, p_heures_sup_semaine numeric, p_poste text, p_forfait_jour boolean DEFAULT false, p_forfait_jours_an smallint DEFAULT NULL::smallint, p_clore_precedent boolean DEFAULT false)
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

CREATE OR REPLACE FUNCTION public.upsert_employe_pointage(p_nom text, p_prenom text, p_pin text, p_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_id uuid;
BEGIN
  IF length(p_pin) <> 4 OR p_pin !~ '^[0-9]{4}$' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'PIN invalide (4 chiffres attendus).');
  END IF;

  IF trim(p_nom) = '' OR trim(p_prenom) = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Nom et prenom requis.');
  END IF;

  IF p_id IS NOT NULL THEN
    UPDATE employes SET
      nom        = p_nom,
      prenom     = p_prenom,
      pin_hash   = crypt(p_pin, gen_salt('bf', 12)),
      actif      = true,
      updated_at = now()
    WHERE id = p_id
    RETURNING id INTO v_id;
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO employes (nom, prenom, pin_hash)
    VALUES (p_nom, p_prenom, crypt(p_pin, gen_salt('bf', 12)))
    ON CONFLICT (nom, prenom) DO UPDATE SET
      pin_hash   = EXCLUDED.pin_hash,
      actif      = true,
      updated_at = now()
    RETURNING id INTO v_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;

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

CREATE OR REPLACE FUNCTION public.valider_semaine(p_employe_id uuid, p_semaine_debut date, p_valide_par text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$ BEGIN RETURN public.verrouiller_semaine_pour(ARRAY[p_employe_id], p_semaine_debut); END; $function$;

CREATE OR REPLACE FUNCTION public.verifier_pointage(p_employe_id uuid, p_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_dernier_type text;
  v_tz           text := 'Europe/Paris';
  v_today        date := (now() AT TIME ZONE v_tz)::date;
BEGIN
  -- Dernier type de pointage valide de l'employé aujourd'hui
  SELECT type INTO v_dernier_type
  FROM pointages
  WHERE employe_id = p_employe_id
    AND valide = true
    AND (horodatage AT TIME ZONE v_tz)::date = v_today
  ORDER BY horodatage DESC
  LIMIT 1;

  CASE p_type
    WHEN 'ENTREE' THEN
      IF v_dernier_type IS NOT NULL AND v_dernier_type <> 'SORTIE' THEN
        RETURN jsonb_build_object(
          'ok', false,
          'message', 'Déjà en service — pointez votre sortie d''abord.'
        );
      END IF;

    WHEN 'SORTIE' THEN
      IF v_dernier_type IS NULL OR v_dernier_type NOT IN ('ENTREE', 'PAUSE_FIN') THEN
        RETURN jsonb_build_object(
          'ok', false,
          'message', 'Aucune entrée en cours — impossible de pointer une sortie.'
        );
      END IF;

    WHEN 'PAUSE_DEBUT' THEN
      IF v_dernier_type IS NULL OR v_dernier_type NOT IN ('ENTREE', 'PAUSE_FIN') THEN
        RETURN jsonb_build_object(
          'ok', false,
          'message', 'Pointez d''abord votre entrée avant de déclarer une pause.'
        );
      END IF;

    WHEN 'PAUSE_FIN' THEN
      IF v_dernier_type IS NULL OR v_dernier_type <> 'PAUSE_DEBUT' THEN
        RETURN jsonb_build_object(
          'ok', false,
          'message', 'Aucune pause en cours à terminer.'
        );
      END IF;

    ELSE
      RETURN jsonb_build_object(
        'ok', false,
        'message', 'Type de pointage inconnu : ' || p_type
      );
  END CASE;

  RETURN jsonb_build_object('ok', true, 'message', 'OK');
END;
$function$;

CREATE OR REPLACE FUNCTION public.verrouiller_semaine_pour(p_employes uuid[], p_semaine_debut date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE n int;
BEGIN
  PERFORM public._exiger_admin_rh();
  IF p_semaine_debut <> public._lundi(p_semaine_debut) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'La semaine doit commencer un lundi.');
  END IF;
  INSERT INTO public.semaines_validees (employe_id, semaine_debut, valide_par)
  SELECT unnest(p_employes), p_semaine_debut, public._auteur_rh()
  ON CONFLICT (employe_id, semaine_debut) DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n > 0 THEN
    PERFORM public._journal(CASE WHEN array_length(p_employes, 1) = 1 THEN p_employes[1] END,
      'Semaine S' || extract(week from p_semaine_debut)::int || ' verrouillée'
      || CASE WHEN array_length(p_employes, 1) = 1 THEN '' ELSE ' pour ' || n || ' salarié(s)' END);
  END IF;
  RETURN jsonb_build_object('ok', true, 'n', n);
END;
$function$;
