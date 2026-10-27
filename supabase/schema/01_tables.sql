CREATE TABLE public.comptes_kiosque (
  auth_user_id uuid NOT NULL,
  libelle text NOT NULL,
  cree_le timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT comptes_kiosque_pkey PRIMARY KEY (auth_user_id)
);
ALTER TABLE public.comptes_kiosque ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.comptes_pwa (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  employe_id uuid NOT NULL,
  role text DEFAULT 'utilisateur'::text NOT NULL,
  activites text[] DEFAULT ARRAY['loxam'::text] NOT NULL,
  actif boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT comptes_pwa_employe_id_key UNIQUE (employe_id),
  CONSTRAINT comptes_pwa_pkey PRIMARY KEY (id),
  CONSTRAINT comptes_pwa_role_check CHECK ((role = ANY (ARRAY['admin'::text, 'utilisateur'::text])))
);
ALTER TABLE public.comptes_pwa ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.config_interne (
  cle text NOT NULL,
  valeur text NOT NULL,
  CONSTRAINT config_interne_pkey PRIMARY KEY (cle)
);
ALTER TABLE public.config_interne ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.conges (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  employe_id uuid NOT NULL,
  type text NOT NULL,
  date_debut date NOT NULL,
  date_fin date NOT NULL,
  jours numeric NOT NULL,
  motif text,
  notes text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  demi_journee text,
  CONSTRAINT conges_pkey PRIMARY KEY (id),
  CONSTRAINT conges_dates_check CHECK ((date_fin >= date_debut)),
  CONSTRAINT conges_demi_journee_check CHECK ((demi_journee = ANY (ARRAY['am'::text, 'pm'::text]))),
  CONSTRAINT conges_type_check CHECK ((type = ANY (ARRAY['cp'::text, 'maladie'::text, 'evenement_familial'::text, 'sans_solde'::text, 'autre'::text])))
);
ALTER TABLE public.conges ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.connexion_pwa_essais (
  id bigint DEFAULT nextval('connexion_pwa_essais_id_seq'::regclass) NOT NULL,
  at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
  compte_id uuid NOT NULL,
  resultat text NOT NULL,
  CONSTRAINT connexion_pwa_essais_pkey PRIMARY KEY (id),
  CONSTRAINT connexion_pwa_essais_resultat_check CHECK ((resultat = ANY (ARRAY['echec'::text, 'ok'::text, 'deblocage'::text])))
);
ALTER TABLE public.connexion_pwa_essais ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.contrats (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  employe_id uuid NOT NULL,
  date_debut date NOT NULL,
  date_fin date,
  type_contrat text DEFAULT 'CDI'::text NOT NULL,
  classe_num smallint DEFAULT 1 NOT NULL,
  taux_horaire numeric DEFAULT 0 NOT NULL,
  heures_semaine numeric DEFAULT 35 NOT NULL,
  heures_sup_semaine numeric DEFAULT 0 NOT NULL,
  poste text,
  forfait_jour boolean DEFAULT false NOT NULL,
  forfait_jours_an smallint,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  alerte_vue boolean DEFAULT false NOT NULL,
  CONSTRAINT contrats_pkey PRIMARY KEY (id)
);
ALTER TABLE public.contrats ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.cp_ajustements (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  employe_id uuid NOT NULL,
  jours numeric NOT NULL,
  raison text NOT NULL,
  motif text NOT NULL,
  cree_par text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT cp_ajustements_pkey PRIMARY KEY (id),
  CONSTRAINT cp_ajustements_jours_check CHECK ((jours <> (0)::numeric)),
  CONSTRAINT cp_ajustements_raison_check CHECK ((raison = ANY (ARRAY['report'::text, 'correction'::text])))
);
ALTER TABLE public.cp_ajustements ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.employes (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  nom text NOT NULL,
  prenom text NOT NULL,
  pin_hash text,
  nfc_uid text,
  actif boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  classe_num smallint,
  taux_horaire numeric(10,2),
  heures_semaine numeric(5,2) DEFAULT 35 NOT NULL,
  heures_sup_semaine numeric(5,2) DEFAULT 0 NOT NULL,
  date_entree date,
  date_sortie date,
  type_contrat text,
  poste text,
  notes text,
  supprime boolean DEFAULT false NOT NULL,
  adresse text,
  telephone_perso text,
  email_perso text,
  auth_user_id uuid,
  is_rh_admin boolean DEFAULT false NOT NULL,
  acces_externe boolean DEFAULT false NOT NULL,
  CONSTRAINT employes_auth_user_id_key UNIQUE (auth_user_id),
  CONSTRAINT employes_nfc_uid_key UNIQUE (nfc_uid),
  CONSTRAINT employes_pkey PRIMARY KEY (id),
  CONSTRAINT employes_classe_num_check CHECK (((classe_num >= 1) AND (classe_num <= 18)))
);
ALTER TABLE public.employes ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.heures_corrections (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  employe_id uuid NOT NULL,
  date date NOT NULL,
  delta_min integer NOT NULL,
  commentaire text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT heures_corrections_pkey PRIMARY KEY (id)
);
ALTER TABLE public.heures_corrections ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.heures_journalieres (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  employe_id uuid NOT NULL,
  date date NOT NULL,
  heure_entree timestamp with time zone,
  heure_sortie timestamp with time zone,
  duree_brute interval,
  duree_pause interval DEFAULT '00:00:00'::interval NOT NULL,
  duree_nette interval,
  statut text DEFAULT 'ABSENT'::text NOT NULL,
  pause_legale_appliquee boolean DEFAULT false NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT heures_journalieres_employe_id_date_key UNIQUE (employe_id, date),
  CONSTRAINT heures_journalieres_pkey PRIMARY KEY (id),
  CONSTRAINT heures_journalieres_statut_check CHECK ((statut = ANY (ARRAY['EN_SERVICE'::text, 'EN_PAUSE'::text, 'SORTI'::text, 'ANOMALIE'::text, 'ABSENT'::text])))
);
ALTER TABLE public.heures_journalieres ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.jours_feries (
  date date NOT NULL,
  libelle text NOT NULL,
  CONSTRAINT jours_feries_pkey PRIMARY KEY (date)
);
ALTER TABLE public.jours_feries ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.jours_feries_annees (
  annee integer NOT NULL,
  genere_le timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT jours_feries_annees_pkey PRIMARY KEY (annee)
);
ALTER TABLE public.jours_feries_annees ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.jours_statut (
  employe_id uuid NOT NULL,
  date date NOT NULL,
  statut text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT jours_statut_pkey PRIMARY KEY (employe_id, date),
  CONSTRAINT jours_statut_statut_check CHECK ((statut = ANY (ARRAY['ferie'::text, 'non_travaille'::text])))
);
ALTER TABLE public.jours_statut ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.mois_clotures (
  mois date NOT NULL,
  cloture boolean DEFAULT false NOT NULL,
  cloture_le timestamp with time zone,
  cloture_par text,
  exporte_le timestamp with time zone,
  exporte_par text,
  export_perime boolean DEFAULT false NOT NULL,
  CONSTRAINT mois_clotures_pkey PRIMARY KEY (mois),
  CONSTRAINT mois_clotures_mois_check CHECK ((EXTRACT(day FROM mois) = (1)::numeric))
);
ALTER TABLE public.mois_clotures ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.pin_essais (
  id bigint DEFAULT nextval('pin_essais_id_seq'::regclass) NOT NULL,
  at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
  auth_user_id uuid NOT NULL,
  resultat text NOT NULL,
  CONSTRAINT pin_essais_pkey PRIMARY KEY (id),
  CONSTRAINT pin_essais_resultat_check CHECK ((resultat = ANY (ARRAY['echec'::text, 'ok'::text, 'deblocage'::text])))
);
ALTER TABLE public.pin_essais ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.pointages (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  employe_id uuid NOT NULL,
  type text NOT NULL,
  horodatage timestamp with time zone DEFAULT now() NOT NULL,
  source text DEFAULT 'kiosque'::text NOT NULL,
  valide boolean DEFAULT true NOT NULL,
  raison_modif text,
  modifie_par text,
  modifie_le timestamp with time zone,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  horodatage_origine timestamp with time zone,
  CONSTRAINT pointages_pkey PRIMARY KEY (id),
  CONSTRAINT pointages_source_check CHECK ((source = ANY (ARRAY['kiosque'::text, 'nfc'::text, 'admin'::text, 'auto'::text]))),
  CONSTRAINT pointages_type_check CHECK ((type = ANY (ARRAY['ENTREE'::text, 'SORTIE'::text, 'PAUSE_DEBUT'::text, 'PAUSE_FIN'::text])))
);
ALTER TABLE public.pointages ENABLE ROW LEVEL SECURITY;

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
  CONSTRAINT remunerations_classe_num_check CHECK (((classe_num >= 1) AND (classe_num <= 18))),
  CONSTRAINT remunerations_motif_check CHECK ((motif = ANY (ARRAY['debut_contrat'::text, 'augmentation_individuelle'::text, 'augmentation_generale'::text, 'changement_classe'::text, 'avenant'::text, 'minimum_conventionnel'::text, 'correction'::text]))),
  CONSTRAINT remunerations_taux_horaire_check CHECK ((taux_horaire >= (0)::numeric))
);
ALTER TABLE public.remunerations ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.rh_journal (
  id bigint DEFAULT nextval('rh_journal_id_seq'::regclass) NOT NULL,
  at timestamp with time zone DEFAULT now() NOT NULL,
  auteur text NOT NULL,
  employe_id uuid,
  action text NOT NULL,
  motif text,
  CONSTRAINT rh_journal_pkey PRIMARY KEY (id)
);
ALTER TABLE public.rh_journal ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.rh_parametres_temps (
  id boolean DEFAULT true NOT NULL,
  semaine_cheval text DEFAULT 'fin'::text NOT NULL,
  heures_ref numeric DEFAULT 35 NOT NULL,
  heures_25 numeric DEFAULT 8 NOT NULL,
  cp_annuels numeric DEFAULT 25 NOT NULL,
  debut_pointage date,
  CONSTRAINT rh_parametres_temps_pkey PRIMARY KEY (id),
  CONSTRAINT rh_parametres_temps_id_check CHECK (id),
  CONSTRAINT rh_parametres_temps_semaine_cheval_check CHECK ((semaine_cheval = ANY (ARRAY['fin'::text, 'debut'::text])))
);
ALTER TABLE public.rh_parametres_temps ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.semaines_validees (
  employe_id uuid NOT NULL,
  semaine_debut date NOT NULL,
  valide_le timestamp with time zone DEFAULT now() NOT NULL,
  valide_par text,
  CONSTRAINT semaines_validees_pkey PRIMARY KEY (employe_id, semaine_debut)
);
ALTER TABLE public.semaines_validees ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.voyages (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  numero_lv text NOT NULL,
  type text DEFAULT 'LV'::text NOT NULL,
  date_creation timestamp with time zone DEFAULT now() NOT NULL,
  destination text NOT NULL,
  poids numeric,
  ml numeric,
  grutage boolean DEFAULT false NOT NULL,
  commentaire text,
  transporteur text,
  parti boolean DEFAULT false NOT NULL,
  parti_le timestamp with time zone,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  marchandises_desc text,
  destination_adresse text,
  destination_lat numeric,
  destination_lon numeric,
  livraison_prevue date,
  CONSTRAINT voyages_numero_lv_key UNIQUE (numero_lv),
  CONSTRAINT voyages_pkey PRIMARY KEY (id),
  CONSTRAINT voyages_type_check CHECK ((type = ANY (ARRAY['LV'::text, 'CMR'::text])))
);
ALTER TABLE public.voyages ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.voyages_annules (
  numero_lv text NOT NULL,
  type text,
  date_creation timestamp with time zone,
  destination text,
  destination_adresse text,
  poids numeric,
  ml numeric,
  grutage boolean,
  commentaire text,
  marchandises_desc text,
  livraison_prevue date,
  parti boolean,
  parti_le timestamp with time zone,
  doc_annexe text,
  commande text,
  conducteur text,
  immat_moteur text,
  immat_semi text,
  expediteur text,
  convoi boolean,
  pdf_url text,
  annulee_le timestamp with time zone DEFAULT now() NOT NULL,
  annulee_par text,
  motif text NOT NULL,
  remplacee_par text,
  CONSTRAINT voyages_annules_pkey PRIMARY KEY (numero_lv)
);
ALTER TABLE public.voyages_annules ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.voyages_internes (
  numero_lv text NOT NULL,
  doc_annexe text,
  commande text,
  conducteur text,
  immat_moteur text,
  immat_semi text,
  expediteur text,
  convoi boolean DEFAULT false NOT NULL,
  pdf_url text,
  CONSTRAINT voyages_internes_pkey PRIMARY KEY (numero_lv)
);
ALTER TABLE public.voyages_internes ENABLE ROW LEVEL SECURITY;
