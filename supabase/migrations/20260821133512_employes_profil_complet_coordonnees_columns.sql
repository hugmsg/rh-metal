-- Phase 3 SIRH — "profils complets" (1ère étape, coordonnées personnelles).
-- Colonnes rh-metal (comme classe_num/taux_horaire/etc.), pas partagées
-- avec sonotrad-pwa, remplies uniquement côté fiche RH.
ALTER TABLE public.employes
  ADD COLUMN adresse text,
  ADD COLUMN telephone_perso text,
  ADD COLUMN email_perso text;
