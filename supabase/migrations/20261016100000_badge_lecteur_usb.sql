-- Badge : lecteur USB branché sur le poste du kiosque (2026-10-16), plus de pont.
-- emettre_signal_nfc ne sert plus : réservée au serveur.
REVOKE EXECUTE ON FUNCTION public.emettre_signal_nfc(text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.emettre_signal_nfc(text, jsonb) TO service_role;
