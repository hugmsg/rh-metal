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
  UPDATE comptes_pwa SET updated_at = now() WHERE id = p_compte;
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

CREATE OR REPLACE FUNCTION public.stock_ajouter(p_type text, p_user text, p_note text, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_type text := btrim(coalesce(p_type, ''));
  v_note text := btrim(coalesce(p_note, ''));
  v_date timestamptz := now();
  v_op   uuid := gen_random_uuid();
  v_n    integer;
BEGIN
  IF v_type NOT IN ('entrée', 'sortie', 'inventaire') THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Type invalide : ' || v_type);
  END IF;
  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Aucun article dans le batch');
  END IF;

  WITH lignes AS (
    SELECT btrim(coalesce(i->>'ref', '')) AS ref, _stock_nombre(i->'qty') AS qty,
           v_note || CASE WHEN coalesce(i->>'note', '') <> ''
                          THEN CASE WHEN v_note <> '' THEN ' · ' ELSE '' END || (i->>'note') ELSE '' END AS note,
           n
      FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(i, n)
  ), ok AS (
    INSERT INTO stock_mouvements (date, ref, type, quantite, utilisateur, note, operation)
    SELECT v_date, l.ref, v_type, l.qty, btrim(coalesce(p_user, '')), l.note, v_op
      FROM lignes l
     WHERE l.ref <> '' AND CASE WHEN v_type = 'inventaire' THEN l.qty >= 0 ELSE l.qty > 0 END
     ORDER BY l.n
    RETURNING 1
  )
  SELECT count(*) INTO v_n FROM ok;

  IF v_n = 0 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Aucun mouvement valide');
  END IF;
  RETURN jsonb_build_object('ok', true, 'count', v_n, 'type', v_type, 'date', _stock_iso(v_date),
    'mouvements', (SELECT jsonb_agg(_stock_mouvement_json(m) ORDER BY m.id)
                     FROM stock_mouvements m WHERE m.operation = v_op));
END;
$function$;

CREATE OR REPLACE FUNCTION public.stock_analytique()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH s AS (
    SELECT m.ref,
      coalesce(sum(m.quantite) FILTER (WHERE m.type = 'sortie' AND m.date >= now() - interval '30 days'), 0) AS s30,
      coalesce(sum(m.quantite) FILTER (WHERE m.type = 'entrée' AND m.date >= now() - interval '30 days'), 0) AS e30,
      coalesce(sum(m.quantite) FILTER (WHERE m.type = 'sortie' AND m.date >= now() - interval '14 days'), 0) AS p1,
      coalesce(sum(m.quantite) FILTER (WHERE m.type = 'sortie' AND m.date >= now() - interval '28 days'
                                         AND m.date < now() - interval '14 days'), 0) AS p2,
      max(m.date) AS derniere
    FROM stock_mouvements m WHERE m.quantite <> 0
    GROUP BY m.ref
  )
  SELECT coalesce(jsonb_object_agg(s.ref, jsonb_build_object(
    'avgPerWeek', CASE WHEN s.s30 > 0 THEN trim_scale(round(s.s30 / 30 * 7, 1)) ELSE 0 END,
    'trend', CASE WHEN s.p2 = 0 AND s.p1 > 0 THEN 'up'
                  WHEN s.p1 = 0 AND s.p2 > 0 THEN 'down'
                  WHEN s.p2 > 0 AND s.p1 / s.p2 >= 1.3 THEN 'up'
                  WHEN s.p2 > 0 AND s.p1 / s.p2 <= 0.7 THEN 'down'
                  ELSE 'stable' END,
    'exits30d', s.s30, 'entries30d', s.e30, 'lastDate', _stock_iso(s.derniere))), '{}'::jsonb)
  FROM s;
$function$;

CREATE OR REPLACE FUNCTION public.stock_annuler_operation(p_ids bigint[], p_par text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_supprimes jsonb;
BEGIN
  IF coalesce(array_length(p_ids, 1), 0) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Aucun mouvement à annuler');
  END IF;
  IF (SELECT count(*) FROM stock_mouvements WHERE id = ANY (p_ids)) <> (SELECT count(DISTINCT x) FROM unnest(p_ids) x) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Opération déjà annulée ou modifiée : rechargez l''historique');
  END IF;
  WITH sup AS (
    DELETE FROM stock_mouvements WHERE id = ANY (p_ids) RETURNING *
  ), trace AS (
    INSERT INTO stock_mouvements_supprimes (mouvement, supprime_par)
    SELECT to_jsonb(s), btrim(coalesce(p_par, '')) FROM sup s ORDER BY s.id
    RETURNING mouvement
  )
  SELECT jsonb_agg(jsonb_build_object('id', (t.mouvement->>'id')::bigint, 'ref', t.mouvement->>'ref',
                                      'type', t.mouvement->>'type', 'qty', (t.mouvement->>'quantite')::numeric))
    INTO v_supprimes FROM trace t;
  RETURN jsonb_build_object('ok', true, 'count', jsonb_array_length(v_supprimes), 'supprimes', v_supprimes);
END;
$function$;

CREATE OR REPLACE FUNCTION public.stock_articles_actifs()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT jsonb_build_object(
    'refs', coalesce((SELECT jsonb_object_agg(a.ref, jsonb_build_object('description', a.description,
              'famille', a.famille, 'fournisseur', a.fournisseur, 'refFourn', a.ref_fourn))
              FROM stock_articles a WHERE a.actif), '{}'::jsonb),
    'total', (SELECT count(*) FROM stock_articles));
$function$;

CREATE OR REPLACE FUNCTION public.stock_catalogue()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH tout AS (
    SELECT a.*, CASE WHEN e.ref IS NULL THEN NULL
                     WHEN e.inv_qty IS NOT NULL THEN e.inv_qty + e.delta
                     ELSE e.delta END AS qte
      FROM stock_articles a LEFT JOIN _stock_etat() e ON e.ref = a.ref
  ), lignes AS (
    SELECT * FROM tout WHERE actif OR coalesce(qte, 0) <> 0
  )
  SELECT jsonb_build_object(
    'data', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'ref', l.ref, 'description', l.description, 'famille', l.famille,
        'fournisseur', l.fournisseur, 'refFourn', l.ref_fourn,
        'prixHT', nullif(l.prix_ht, 0), 'qte', l.qte, 'seuil', l.seuil,
        'stockStatus', CASE WHEN l.qte IS NOT NULL AND l.seuil IS NOT NULL
                            THEN CASE WHEN l.qte >= l.seuil THEN 'ok' ELSE 'low' END
                            WHEN l.qte IS NOT NULL THEN 'ok' ELSE 'unknown' END)
        || CASE WHEN l.actif THEN '{}'::jsonb ELSE '{"retiree": true}'::jsonb END
        ORDER BY l.actif DESC, l.ordre) FROM lignes l), '[]'::jsonb),
    'count', (SELECT count(*) FROM lignes),
    'familles', coalesce((SELECT jsonb_agg(f ORDER BY f COLLATE "C")
                            FROM (SELECT DISTINCT famille AS f FROM lignes WHERE famille <> '') x), '[]'::jsonb));
$function$;

CREATE OR REPLACE FUNCTION public.stock_definir_favoris(p_refs jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  DELETE FROM stock_favoris WHERE true;
  INSERT INTO stock_favoris (ref)
  SELECT r FROM (SELECT DISTINCT ON (btrim(x)) btrim(x) AS r, n
                   FROM jsonb_array_elements_text(coalesce(p_refs, '[]'::jsonb)) WITH ORDINALITY AS t(x, n)
                  WHERE btrim(x) <> '' ORDER BY btrim(x), n) y
   ORDER BY n;
  RETURN jsonb_build_object('ok', true, 'count', jsonb_array_length(coalesce(p_refs, '[]'::jsonb)));
END;
$function$;

CREATE OR REPLACE FUNCTION public.stock_definir_seuil(p_ref text, p_seuil numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF p_seuil < 0 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Seuil invalide');
  END IF;
  UPDATE stock_articles SET seuil = p_seuil, date_modif = current_date WHERE ref = btrim(coalesce(p_ref, ''));
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Référence introuvable : ' || btrim(coalesce(p_ref, '')));
  END IF;
  RETURN jsonb_build_object('ok', true, 'ref', btrim(p_ref), 'seuil', p_seuil);
END;
$function$;

CREATE OR REPLACE FUNCTION public.stock_favoris_liste()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce(jsonb_agg(f.ref ORDER BY f.ordre), '[]'::jsonb) FROM stock_favoris f;
$function$;

CREATE OR REPLACE FUNCTION public.stock_importer_catalogue(p_refs jsonb, p_source text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_ajout integer; v_maj integer; v_desact integer; v_inchange integer; v_prix integer;
  v_retirees jsonb;
BEGIN
  IF jsonb_typeof(p_refs) <> 'array' OR jsonb_array_length(p_refs) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Aucune référence reçue');
  END IF;

  DROP TABLE IF EXISTS _import;
  CREATE TEMP TABLE _import ON COMMIT DROP AS
  SELECT DISTINCT ON (ref) ref, description, famille, fournisseur, ref_fourn, prix_ht, n FROM (
    SELECT btrim(coalesce(r->>'ref', '')) AS ref,
           btrim(coalesce(r->>'description', '')) AS description,
           btrim(coalesce(r->>'famille', '')) AS famille,
           btrim(coalesce(r->>'fournisseur', '')) AS fournisseur,
           btrim(coalesce(r->>'refFourn', '')) AS ref_fourn,
           nullif(_stock_nombre(r->'prixHT'), 0) AS prix_ht, n
      FROM jsonb_array_elements(p_refs) WITH ORDINALITY AS t(r, n)) x
   WHERE ref <> ''
   ORDER BY ref, n DESC;

  -- Historique : nouvelle réf avec prix, ou prix différent du prix actuel.
  INSERT INTO stock_prix (ref, prix_ht, source)
  SELECT i.ref, i.prix_ht, coalesce(p_source, '')
    FROM _import i LEFT JOIN stock_articles a ON a.ref = i.ref
   WHERE (a.ref IS NULL AND i.prix_ht IS NOT NULL)
      OR (a.ref IS NOT NULL AND nullif(a.prix_ht, 0) IS DISTINCT FROM i.prix_ht)
   ORDER BY i.n;
  GET DIAGNOSTICS v_prix = ROW_COUNT;

  SELECT count(*) INTO v_inchange FROM _import i JOIN stock_articles a USING (ref)
   WHERE a.actif AND (a.description, a.famille, a.fournisseur, a.ref_fourn) = (i.description, i.famille, i.fournisseur, i.ref_fourn)
     AND nullif(a.prix_ht, 0) IS NOT DISTINCT FROM i.prix_ht;

  UPDATE stock_articles a SET description = i.description, famille = i.famille, fournisseur = i.fournisseur,
         ref_fourn = i.ref_fourn, prix_ht = i.prix_ht, actif = true, date_modif = current_date
    FROM _import i
   WHERE a.ref = i.ref
     AND (NOT a.actif OR (a.description, a.famille, a.fournisseur, a.ref_fourn) IS DISTINCT FROM (i.description, i.famille, i.fournisseur, i.ref_fourn)
          OR nullif(a.prix_ht, 0) IS DISTINCT FROM i.prix_ht);
  GET DIAGNOSTICS v_maj = ROW_COUNT;

  INSERT INTO stock_articles (ref, description, famille, fournisseur, ref_fourn, prix_ht, date_import, date_modif)
  SELECT i.ref, i.description, i.famille, i.fournisseur, i.ref_fourn, i.prix_ht, current_date, current_date
    FROM _import i WHERE NOT EXISTS (SELECT 1 FROM stock_articles a WHERE a.ref = i.ref)
   ORDER BY i.n;
  GET DIAGNOSTICS v_ajout = ROW_COUNT;

  UPDATE stock_articles a SET actif = false
   WHERE a.actif AND NOT EXISTS (SELECT 1 FROM _import i WHERE i.ref = a.ref);
  GET DIAGNOSTICS v_desact = ROW_COUNT;

  -- Ordre du catalogue = ordre du fichier (numéros au-dessus des anciens, puis compteur recalé).
  UPDATE stock_articles a SET ordre = o.base + i.rang
    FROM (SELECT ref, row_number() OVER (ORDER BY n) AS rang FROM _import) i,
         (SELECT max(ordre) AS base FROM stock_articles) o
   WHERE a.ref = i.ref;
  PERFORM setval(pg_get_serial_sequence('public.stock_articles', 'ordre'), (SELECT max(ordre) FROM stock_articles));

  SELECT coalesce(jsonb_agg(d->>'ref'), '[]'::jsonb) INTO v_retirees
    FROM jsonb_array_elements(stock_catalogue()->'data') d WHERE (d->>'retiree')::boolean;

  RETURN jsonb_build_object('ok', true, 'added', v_ajout, 'updated', v_maj, 'deactivated', v_desact,
                            'unchanged', v_inchange, 'total', jsonb_array_length(p_refs),
                            'prixModifies', v_prix, 'retireesEnStock', v_retirees);
END;
$function$;

CREATE OR REPLACE FUNCTION public.stock_lier_lv(p_op_key text, p_numero text, p_display text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(p_op_key, '') = '' OR coalesce(p_numero, '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'opKey ou numero manquant');
  END IF;
  INSERT INTO stock_lv_liens (op_key, numero, display, date)
  VALUES (p_op_key, p_numero, coalesce(nullif(p_display, ''), p_numero), now())
  ON CONFLICT (op_key) DO UPDATE SET numero = excluded.numero, display = excluded.display, date = excluded.date;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.stock_lv_liens_liste()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce(jsonb_object_agg(l.op_key, jsonb_build_object(
           'numero', l.numero, 'display', l.display, 'date', _stock_iso(l.date))), '{}'::jsonb)
    FROM stock_lv_liens l;
$function$;

CREATE OR REPLACE FUNCTION public.stock_mouvements_recents(p_limit integer)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce(jsonb_agg(_stock_mouvement_json(m) ORDER BY m.date DESC, m.id DESC), '[]'::jsonb)
    FROM (SELECT * FROM stock_mouvements ORDER BY date DESC, id DESC
           LIMIT greatest(coalesce(p_limit, 50), 0)) m;
$function$;

CREATE OR REPLACE FUNCTION public.stock_mouvements_ref(p_ref text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce(jsonb_agg(_stock_mouvement_json(m) ORDER BY m.date, m.id), '[]'::jsonb)
    FROM stock_mouvements m WHERE m.ref = btrim(p_ref);
$function$;

CREATE OR REPLACE FUNCTION public.stock_prix_ref(p_ref text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce(jsonb_agg(jsonb_build_object('prixHT', p.prix_ht, 'dateEffet', p.date_effet, 'source', p.source)
                            ORDER BY p.date_effet DESC, p.id DESC), '[]'::jsonb)
    FROM stock_prix p WHERE p.ref = btrim(p_ref);
$function$;

CREATE OR REPLACE FUNCTION public.stock_reprise(p jsonb, p_remplacer boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF p_remplacer THEN
    TRUNCATE stock_articles, stock_mouvements, stock_mouvements_supprimes, stock_favoris, stock_lv_liens, stock_prix RESTART IDENTITY;
  ELSIF EXISTS (SELECT 1 FROM stock_articles) OR EXISTS (SELECT 1 FROM stock_mouvements) THEN
    RAISE EXCEPTION 'Tables stock non vides : reprise refusée';
  END IF;

  INSERT INTO stock_articles (ref, description, famille, fournisseur, ref_fourn, prix_ht, seuil, actif, date_import, date_modif)
  SELECT btrim(a->>'ref'), coalesce(btrim(a->>'description'), ''), coalesce(btrim(a->>'famille'), ''),
         coalesce(btrim(a->>'fournisseur'), ''), coalesce(btrim(a->>'refFourn'), ''),
         nullif(_stock_nombre(a->'prixHT'), 0), (a->>'seuil')::numeric, coalesce((a->>'actif')::boolean, true),
         (a->>'dateImport')::date, (a->>'dateModif')::date
    FROM jsonb_array_elements(p->'articles') WITH ORDINALITY AS t(a, n)
   ORDER BY n;

  INSERT INTO stock_prix (ref, prix_ht, date_effet, source)
  SELECT ref, prix_ht, coalesce(date_modif, date_import, current_date), 'reprise classeur'
    FROM stock_articles WHERE prix_ht IS NOT NULL ORDER BY ordre;

  INSERT INTO stock_mouvements (date, ref, type, quantite, utilisateur, note)
  SELECT (m->>'date')::timestamptz, btrim(m->>'ref'), m->>'type', _stock_nombre(m->'qty'),
         coalesce(m->>'user', ''), coalesce(m->>'note', '')
    FROM jsonb_array_elements(p->'mouvements') WITH ORDINALITY AS t(m, n)
   ORDER BY n;

  PERFORM stock_definir_favoris(coalesce(p->'favoris', '[]'::jsonb));

  INSERT INTO stock_lv_liens (op_key, numero, display, date)
  SELECT k, v->>'numero', coalesce(v->>'display', v->>'numero'), coalesce((v->>'date')::timestamptz, now())
    FROM jsonb_each(coalesce(p->'liens', '{}'::jsonb)) AS t(k, v);

  RETURN jsonb_build_object('articles', (SELECT count(*) FROM stock_articles),
                            'mouvements', (SELECT count(*) FROM stock_mouvements),
                            'favoris', (SELECT count(*) FROM stock_favoris),
                            'liens', (SELECT count(*) FROM stock_lv_liens));
END;
$function$;

CREATE OR REPLACE FUNCTION public.stock_resume()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce(jsonb_object_agg(e.ref, jsonb_build_object(
           'delta', e.delta, 'invQty', e.inv_qty, 'lastDate', _stock_iso(e.derniere_date))), '{}'::jsonb)
    FROM _stock_etat() e;
$function$;

CREATE OR REPLACE FUNCTION public.stock_supprimer_mouvement(p_ref text, p_type text, p_qty numeric, p_note text, p_date timestamp with time zone, p_par text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  m stock_mouvements;
BEGIN
  SELECT * INTO m FROM stock_mouvements
   WHERE ref = btrim(coalesce(p_ref, '')) AND type = btrim(coalesce(p_type, ''))
     AND note = btrim(coalesce(p_note, '')) AND abs(quantite - p_qty) < 0.001
     AND abs(extract(epoch FROM date - p_date)) < 2
   ORDER BY id LIMIT 1
   FOR UPDATE;
  IF m.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Mouvement non trouvé');
  END IF;
  INSERT INTO stock_mouvements_supprimes (mouvement, supprime_par)
  VALUES (to_jsonb(m), btrim(coalesce(p_par, '')));
  DELETE FROM stock_mouvements WHERE id = m.id;
  RETURN jsonb_build_object('ok', true, 'ref', m.ref, 'qty', m.quantite);
END;
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
