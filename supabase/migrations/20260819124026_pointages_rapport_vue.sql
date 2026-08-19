-- Autorise la lecture directe des pointages individuels (mêmes conditions
-- que heures_journalieres, déjà en anon_select_heures_journalieres qual=true)
-- pour permettre au rapport Pointage d'afficher le détail des badgeages de
-- la journée, pas seulement le premier/dernier. Aucune donnée sensible dans
-- pointages (employe_id/type/horodatage/source) — même niveau d'exposition
-- que heures_journalieres, déjà en lecture anon libre.
CREATE POLICY anon_select_pointages ON public.pointages
  FOR SELECT
  TO anon
  USING (true);

CREATE VIEW public.pointages_rapport_vue AS
SELECT
  employe_id,
  type,
  horodatage,
  (horodatage AT TIME ZONE 'Europe/Paris')::date AS date
FROM public.pointages
WHERE valide = true
ORDER BY employe_id, horodatage;
