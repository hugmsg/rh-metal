-- Sans ça, aucun postgres_changes ne part jamais pour ces tables : les
-- abonnements Realtime déjà existants côté Kiosque/Suivi du jour sur
-- heures_journalieres n'ont donc jamais réellement déclenché (le
-- rafraîchissement observé après un scan/PIN venait d'un appel direct côté
-- client sur le même poste, pas de Supabase Realtime — voir
-- _ptgShowFeedback dans app.js). RLS déjà correct (policy anon SELECT sur
-- les 4 tables) — il ne manquait que la publication.
--
-- Découvert le 2026-08-22 en câblant le rafraîchissement live de
-- Rapports/Contrôle (qui n'avaient encore aucun abonnement) : seule
-- `voyages` (repo sonotrad-scripts, sans rapport) était dans la
-- publication `supabase_realtime` avant ce correctif.
ALTER PUBLICATION supabase_realtime ADD TABLE heures_journalieres;
ALTER PUBLICATION supabase_realtime ADD TABLE heures_corrections;
ALTER PUBLICATION supabase_realtime ADD TABLE jours_statut;
ALTER PUBLICATION supabase_realtime ADD TABLE semaines_validees;
