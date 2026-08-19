-- Corrige le calcul de heures_journalieres pour sommer chaque cycle
-- Entrée→Sortie de la journée, au lieu de ne prendre que la 1ère entrée et
-- la dernière sortie du jour.
--
-- Contexte : les boutons "Pause début"/"Pause fin" viennent d'être retirés
-- du kiosque PIN (index.html) — seul Entrée/Sortie reste, pour permettre des
-- allers-retours imprévus dans la journée sans que la notion de pause pose
-- problème (choix de Hugo, 2026-08-19). Mais l'ancien calcul (dernière
-- SORTIE − 1ère ENTREE) ne déduisait alors qu'un forfait de 20 min pour tout
-- écart, quelle que soit sa durée réelle : un aller-retour de 2h au milieu
-- de la journée n'était quasiment pas déduit du temps payé.
--
-- Le nouveau calcul additionne la durée de chaque paire ENTREE→SORTIE
-- rencontrée dans l'ordre chronologique du jour : tout ce qui se passe entre
-- une SORTIE et l'ENTREE suivante est donc automatiquement exclu du temps
-- travaillé, sans dépendre d'un pointage "Pause" explicite. Les pointages
-- PAUSE_DEBUT/PAUSE_FIN (encore possibles en correction manuelle admin,
-- onglet Suivi du jour) continuent d'être déduits en plus, à l'identique.
--
-- heure_entree/heure_sortie affichées restent la 1ère entrée / dernière
-- sortie du jour (inchangé) — seule la durée brute/nette calculée change.

CREATE OR REPLACE FUNCTION public._sync_heures_journalieres()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_tz            text        := 'Europe/Paris';
  v_date          date;
  v_entree        timestamptz;
  v_sortie        timestamptz;
  v_last_type     text;
  v_duree_pause   interval    := '0'::interval;
  v_duree_brute   interval;
  v_duree_nette   interval;
  v_statut        text;
  v_pause_legale  boolean     := false;
  r               record;
  v_fin_pause     timestamptz;
  v_session_debut timestamptz;
BEGIN
  v_date := (NEW.horodatage AT TIME ZONE v_tz)::date;

  SELECT horodatage INTO v_entree
  FROM pointages
  WHERE employe_id = NEW.employe_id AND valide = true
    AND (horodatage AT TIME ZONE v_tz)::date = v_date AND type = 'ENTREE'
  ORDER BY horodatage LIMIT 1;

  SELECT horodatage INTO v_sortie
  FROM pointages
  WHERE employe_id = NEW.employe_id AND valide = true
    AND (horodatage AT TIME ZONE v_tz)::date = v_date AND type = 'SORTIE'
  ORDER BY horodatage DESC LIMIT 1;

  SELECT type INTO v_last_type
  FROM pointages
  WHERE employe_id = NEW.employe_id AND valide = true
    AND (horodatage AT TIME ZONE v_tz)::date = v_date
  ORDER BY horodatage DESC LIMIT 1;

  -- Pauses pointées manuellement (admin, corrections) : somme de chaque paire PAUSE_DEBUT / PAUSE_FIN
  FOR r IN
    SELECT horodatage AS debut
    FROM pointages
    WHERE employe_id = NEW.employe_id AND valide = true
      AND (horodatage AT TIME ZONE v_tz)::date = v_date AND type = 'PAUSE_DEBUT'
    ORDER BY horodatage
  LOOP
    SELECT horodatage INTO v_fin_pause
    FROM pointages
    WHERE employe_id = NEW.employe_id AND valide = true
      AND (horodatage AT TIME ZONE v_tz)::date = v_date
      AND type = 'PAUSE_FIN' AND horodatage > r.debut
    ORDER BY horodatage LIMIT 1;
    IF v_fin_pause IS NOT NULL THEN
      v_duree_pause := v_duree_pause + (v_fin_pause - r.debut);
    END IF;
  END LOOP;

  IF v_entree IS NULL THEN
    v_statut := 'ABSENT';
    v_sortie  := NULL;

  ELSIF v_last_type = 'SORTIE' THEN
    -- Durée brute = somme de chaque cycle Entrée→Sortie de la journée (et non
    -- juste 1ère entrée/dernière sortie) : un aller-retour imprévu au milieu
    -- de la journée (parti puis revenu) n'est donc jamais compté comme du
    -- temps travaillé, sans avoir besoin d'un pointage "Pause" dédié.
    v_duree_brute := '0'::interval;
    v_session_debut := NULL;
    FOR r IN
      SELECT horodatage, type
      FROM pointages
      WHERE employe_id = NEW.employe_id AND valide = true
        AND (horodatage AT TIME ZONE v_tz)::date = v_date
        AND type IN ('ENTREE','SORTIE')
      ORDER BY horodatage
    LOOP
      IF r.type = 'ENTREE' THEN
        IF v_session_debut IS NULL THEN
          v_session_debut := r.horodatage;
        END IF;
      ELSIF v_session_debut IS NOT NULL THEN
        v_duree_brute := v_duree_brute + (r.horodatage - v_session_debut);
        v_session_debut := NULL;
      END IF;
    END LOOP;

    v_statut := 'SORTI';
    IF v_duree_brute > interval '6 hours' AND v_duree_pause = '0'::interval THEN
      v_duree_pause  := interval '20 minutes';
      v_pause_legale := true;
    END IF;
    v_duree_nette := v_duree_brute - v_duree_pause;

  ELSIF v_last_type = 'PAUSE_DEBUT' THEN
    v_statut := 'EN_PAUSE';
    v_sortie  := NULL;

  ELSE
    v_statut := 'EN_SERVICE';
    v_sortie  := NULL;
  END IF;

  INSERT INTO heures_journalieres (
    employe_id, date,
    heure_entree, heure_sortie,
    duree_brute, duree_pause, duree_nette,
    statut, pause_legale_appliquee, updated_at
  )
  VALUES (
    NEW.employe_id, v_date,
    v_entree, v_sortie,
    v_duree_brute, v_duree_pause, v_duree_nette,
    v_statut, v_pause_legale, now()
  )
  ON CONFLICT (employe_id, date) DO UPDATE SET
    heure_entree            = EXCLUDED.heure_entree,
    heure_sortie             = EXCLUDED.heure_sortie,
    duree_brute              = EXCLUDED.duree_brute,
    duree_pause              = EXCLUDED.duree_pause,
    duree_nette              = EXCLUDED.duree_nette,
    statut                   = EXCLUDED.statut,
    pause_legale_appliquee   = EXCLUDED.pause_legale_appliquee,
    updated_at               = EXCLUDED.updated_at;

  RETURN NEW;
END;
$function$;
