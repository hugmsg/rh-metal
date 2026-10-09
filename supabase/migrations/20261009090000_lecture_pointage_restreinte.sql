-- 2026-10-09 : lecture des données de pointage réservée aux admins RH ; le compte kiosque
-- ne lit que ce qu'il affiche (qui est en service aujourd'hui). Le portail salarié passe
-- par ses RPC (get_mes_heures_rh…), la PWA et Apps Script ne lisent plus ces tables.

CREATE OR REPLACE FUNCTION public._est_kiosque()
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT auth.uid() IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.comptes_kiosque WHERE auth_user_id = auth.uid());
$$;
REVOKE EXECUTE ON FUNCTION public._est_kiosque() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._est_kiosque() TO authenticated;

-- Tables : admin RH uniquement (heures_journalieres : + kiosque, jour courant, pour le
-- temps réel de la liste « en service »).
DROP POLICY IF EXISTS anon_select_pointages ON public.pointages;
CREATE POLICY pointages_select ON public.pointages
  FOR SELECT TO authenticated USING (public._est_admin_rh());

DROP POLICY IF EXISTS anon_select_heures_corrections ON public.heures_corrections;
CREATE POLICY heures_corrections_select ON public.heures_corrections
  FOR SELECT TO authenticated USING (public._est_admin_rh());

DROP POLICY IF EXISTS anon_select_jours_statut ON public.jours_statut;
CREATE POLICY jours_statut_select ON public.jours_statut
  FOR SELECT TO authenticated USING (public._est_admin_rh());

DROP POLICY IF EXISTS anon_select_semaines_validees ON public.semaines_validees;
CREATE POLICY semaines_validees_select ON public.semaines_validees
  FOR SELECT TO authenticated USING (public._est_admin_rh());

DROP POLICY IF EXISTS anon_select_heures_journalieres ON public.heures_journalieres;
CREATE POLICY heures_journalieres_select ON public.heures_journalieres
  FOR SELECT TO authenticated USING (
    public._est_admin_rh()
    OR (public._est_kiosque() AND date = (now() AT TIME ZONE 'Europe/Paris')::date));

-- Vues (droits du propriétaire) : même filtre dans la vue, colonnes inchangées.
CREATE OR REPLACE VIEW public.en_service_vue AS
 SELECT hj.employe_id, e.nom, e.prenom, hj.statut, hj.heure_entree, hj.date
   FROM heures_journalieres hj
   JOIN employes e ON e.id = hj.employe_id
  WHERE e.actif = true
    AND (public._est_admin_rh()
         OR (public._est_kiosque() AND hj.date = (now() AT TIME ZONE 'Europe/Paris')::date));

CREATE OR REPLACE VIEW public.pointages_today_vue AS
 SELECT p.id, p.employe_id, e.nom, e.prenom, p.type, p.horodatage, p.source, p.valide
   FROM pointages p
   JOIN employes e ON e.id = p.employe_id
  WHERE (p.horodatage AT TIME ZONE 'Europe/Paris')::date = CURRENT_DATE
    AND public._est_admin_rh()
  ORDER BY p.horodatage DESC;

CREATE OR REPLACE VIEW public.pointages_rapport_vue AS
 SELECT employe_id, type, horodatage, (horodatage AT TIME ZONE 'Europe/Paris')::date AS date
   FROM pointages
  WHERE valide = true
    AND public._est_admin_rh()
  ORDER BY employe_id, horodatage;

CREATE OR REPLACE VIEW public.heures_rapport_vue AS
 SELECT hj.employe_id, e.nom, e.prenom, hj.date, hj.heure_entree, hj.heure_sortie,
        hj.duree_brute, hj.duree_pause, hj.duree_nette, hj.statut, hj.pause_legale_appliquee
   FROM heures_journalieres hj
   JOIN employes e ON e.id = hj.employe_id
  WHERE public._est_admin_rh()
  ORDER BY e.nom, e.prenom, hj.date;

CREATE OR REPLACE VIEW public.employes_actifs_vue AS
 SELECT id, nom, prenom
   FROM employes
  WHERE actif = true AND supprime = false
    AND (date_sortie IS NULL OR date_sortie >= CURRENT_DATE)
    AND public._est_admin_rh()
  ORDER BY nom, prenom;

-- Plus aucune lecture par la clé anon (tables et vues RH / pointage).
REVOKE SELECT ON
  public.pointages, public.heures_journalieres, public.heures_corrections,
  public.jours_statut, public.semaines_validees,
  public.en_service_vue, public.pointages_today_vue, public.pointages_rapport_vue,
  public.heures_rapport_vue, public.employes_actifs_vue,
  public.conges, public.contrats, public.cp_ajustements, public.mois_clotures,
  public.rh_parametres_temps, public.rh_journal
FROM anon;
