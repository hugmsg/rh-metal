-- 2026-10-06 : le kiosque de pointage (rh-metal ?kiosk=1) se connecte avec un compte
-- Supabase dédié au lieu de la clé anon. Étape 1, additive : l'ancien chemin anon reste
-- ouvert jusqu'à la bascule (migration suivante).

CREATE TABLE IF NOT EXISTS public.comptes_kiosque (
  auth_user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  libelle      text NOT NULL,
  cree_le      timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.comptes_kiosque ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.comptes_kiosque FROM anon, authenticated;

INSERT INTO public.comptes_kiosque (auth_user_id, libelle)
SELECT id, 'Kiosque pointage' FROM auth.users WHERE email = 'kiosque@sonotrad.fr'
ON CONFLICT (auth_user_id) DO NOTHING;

-- Compte kiosque ou admin RH connecté (l'onglet Pointage de l'app RH sert aussi de kiosque).
CREATE OR REPLACE FUNCTION public._exiger_kiosque_ou_admin_rh()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT (
    EXISTS (SELECT 1 FROM public.comptes_kiosque WHERE auth_user_id = auth.uid())
    OR EXISTS (SELECT 1 FROM public.employes WHERE auth_user_id = auth.uid() AND is_rh_admin AND supprime = false)
  ) THEN
    RAISE EXCEPTION 'Réservé au kiosque de pointage' USING ERRCODE = '42501';
  END IF;
END;
$$;
REVOKE EXECUTE ON FUNCTION public._exiger_kiosque_ou_admin_rh() FROM PUBLIC, anon, authenticated;

-- Pointage par PIN en une seule opération : identifie le salarié, contrôle l'enchaînement
-- (verifier_pointage) et enregistre. Remplace authentifier_par_pin + verifier_pointage +
-- insert direct dans pointages.
CREATE OR REPLACE FUNCTION public.pointer_par_pin(p_pin text, p_type text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_employe employes%ROWTYPE;
  v_verif   jsonb;
BEGIN
  PERFORM _exiger_kiosque_ou_admin_rh();

  IF coalesce(p_pin, '') !~ '^[0-9]{4}$' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Format PIN invalide (4 chiffres attendus).');
  END IF;

  SELECT * INTO v_employe
  FROM employes
  WHERE actif = true
    AND supprime = false
    AND (date_sortie IS NULL OR date_sortie >= current_date)
    AND crypt(p_pin, pin_hash) = pin_hash
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Code PIN incorrect.');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(v_employe.id::text));

  v_verif := verifier_pointage(v_employe.id, p_type);
  IF NOT (v_verif ->> 'ok')::boolean THEN
    RETURN v_verif;
  END IF;

  INSERT INTO pointages (employe_id, type, source)
  VALUES (v_employe.id, p_type, 'kiosque');

  RETURN jsonb_build_object(
    'ok',     true,
    'id',     v_employe.id,
    'nom',    v_employe.nom,
    'prenom', v_employe.prenom,
    'type',   p_type
  );
END;
$$;
REVOKE EXECUTE ON FUNCTION public.pointer_par_pin(text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.pointer_par_pin(text, text) TO authenticated;
