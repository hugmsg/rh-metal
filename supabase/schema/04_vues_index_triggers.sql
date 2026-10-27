CREATE VIEW public.employes_actifs_vue AS
 SELECT id,
    nom,
    prenom
   FROM employes
  WHERE ((actif = true) AND (supprime = false) AND ((date_sortie IS NULL) OR (date_sortie >= CURRENT_DATE)) AND _est_admin_rh())
  ORDER BY nom, prenom;

CREATE VIEW public.en_service_vue AS
 SELECT hj.employe_id,
    e.nom,
    e.prenom,
    hj.statut,
    hj.heure_entree,
    hj.date
   FROM (heures_journalieres hj
     JOIN employes e ON ((e.id = hj.employe_id)))
  WHERE ((e.actif = true) AND (_est_admin_rh() OR (_est_kiosque() AND (hj.date = ((now() AT TIME ZONE 'Europe/Paris'::text))::date))));

CREATE VIEW public.heures_rapport_vue AS
 SELECT hj.employe_id,
    e.nom,
    e.prenom,
    hj.date,
    hj.heure_entree,
    hj.heure_sortie,
    hj.duree_brute,
    hj.duree_pause,
    hj.duree_nette,
    hj.statut,
    hj.pause_legale_appliquee
   FROM (heures_journalieres hj
     JOIN employes e ON ((e.id = hj.employe_id)))
  WHERE _est_admin_rh()
  ORDER BY e.nom, e.prenom, hj.date;

CREATE VIEW public.pointages_rapport_vue AS
 SELECT employe_id,
    type,
    horodatage,
    ((horodatage AT TIME ZONE 'Europe/Paris'::text))::date AS date
   FROM pointages
  WHERE ((valide = true) AND _est_admin_rh())
  ORDER BY employe_id, horodatage;

CREATE VIEW public.pointages_today_vue AS
 SELECT p.id,
    p.employe_id,
    e.nom,
    e.prenom,
    p.type,
    p.horodatage,
    p.source,
    p.valide
   FROM (pointages p
     JOIN employes e ON ((e.id = p.employe_id)))
  WHERE ((((p.horodatage AT TIME ZONE 'Europe/Paris'::text))::date = CURRENT_DATE) AND _est_admin_rh())
  ORDER BY p.horodatage DESC;

CREATE INDEX connexion_pwa_essais_compte_idx ON public.connexion_pwa_essais USING btree (compte_id, at DESC);
CREATE INDEX contrats_employe_id_idx ON public.contrats USING btree (employe_id, date_debut DESC);
CREATE UNIQUE INDEX employes_nom_prenom_unique ON public.employes USING btree (nom, prenom);
CREATE INDEX idx_employes_actif ON public.employes USING btree (actif);
CREATE INDEX idx_hj_date_statut ON public.heures_journalieres USING btree (date, statut);
CREATE INDEX ot_fiches_code_planning ON public.ot_fiches USING btree (code_planning);
CREATE INDEX ot_fiches_statut ON public.ot_fiches USING btree (statut, cree_le DESC);
CREATE INDEX ot_lignes_fiche ON public.ot_lignes USING btree (fiche_id, ordre, id);
CREATE INDEX pin_essais_at_idx ON public.pin_essais USING btree (at DESC);
CREATE INDEX pin_essais_user_at_idx ON public.pin_essais USING btree (auth_user_id, at DESC);
CREATE INDEX idx_pointages_employe_date ON public.pointages USING btree (employe_id, horodatage DESC);
CREATE INDEX idx_pointages_valide ON public.pointages USING btree (valide) WHERE (valide = true);
CREATE INDEX remunerations_contrat_idx ON public.remunerations USING btree (contrat_id, date_effet DESC, created_at DESC);
CREATE INDEX remunerations_employe_idx ON public.remunerations USING btree (employe_id);
CREATE INDEX rh_journal_at_idx ON public.rh_journal USING btree (at DESC);
CREATE INDEX rh_journal_emp_idx ON public.rh_journal USING btree (employe_id, at DESC);
CREATE INDEX stock_mouvements_date ON public.stock_mouvements USING btree (date DESC, id DESC);
CREATE INDEX stock_mouvements_ref_date ON public.stock_mouvements USING btree (ref, date, id);
CREATE INDEX stock_prix_ref_date ON public.stock_prix USING btree (ref, date_effet, id);
CREATE INDEX idx_voyages_date_creation ON public.voyages USING btree (date_creation DESC);
CREATE INDEX idx_voyages_parti ON public.voyages USING btree (parti);

CREATE TRIGGER contrats_remuneration_initiale AFTER INSERT ON public.contrats FOR EACH ROW EXECUTE FUNCTION _contrat_remuneration_initiale();
CREATE TRIGGER contrats_sync_employe AFTER INSERT OR DELETE OR UPDATE ON public.contrats FOR EACH ROW EXECUTE FUNCTION sync_employe_depuis_contrats();
CREATE TRIGGER employes_broadcast_trigger AFTER INSERT OR DELETE OR UPDATE ON public.employes FOR EACH ROW EXECUTE FUNCTION employes_broadcast_change();
CREATE TRIGGER employes_garder_un_admin AFTER DELETE OR UPDATE ON public.employes FOR EACH STATEMENT EXECUTE FUNCTION _garder_un_admin_rh();
CREATE TRIGGER remunerations_vers_contrat AFTER INSERT OR DELETE OR UPDATE ON public.remunerations FOR EACH ROW EXECUTE FUNCTION _remuneration_vers_contrat();
CREATE TRIGGER trg_sync_heures_journalieres AFTER INSERT OR UPDATE ON public.pointages FOR EACH ROW EXECUTE FUNCTION _sync_heures_journalieres();
CREATE TRIGGER trg_voyages_touch BEFORE UPDATE ON public.voyages FOR EACH ROW EXECUTE FUNCTION _voyages_touch_updated_at();

ALTER PUBLICATION supabase_realtime ADD TABLE public.heures_corrections;
ALTER PUBLICATION supabase_realtime ADD TABLE public.heures_journalieres;
ALTER PUBLICATION supabase_realtime ADD TABLE public.jours_statut;
ALTER PUBLICATION supabase_realtime ADD TABLE public.pointages;
ALTER PUBLICATION supabase_realtime ADD TABLE public.semaines_validees;
ALTER PUBLICATION supabase_realtime ADD TABLE public.voyages;
