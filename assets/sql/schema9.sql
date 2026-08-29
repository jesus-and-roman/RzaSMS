-- ============================================================
-- RzaSMS / Pluriportail — SCHEMA 9 (additif)
-- Roule après schema8-final.sql.
-- Corrige le préset de déguisement par défaut pour les comptes
-- déjà créés, selon la règle : @eleve.smrc.qc.ca -> Pluriportail,
-- sinon -> Gmail. (Si tu as déjà changé ton préset manuellement,
-- ça va l'écraser une seule fois -- va le re-choisir dans tes
-- paramètres après ce script si besoin.)
-- ============================================================

update profiles
set favicon_preset = case
  when email ilike '%@eleve.smrc.qc.ca' or email ilike '%@smrc.eleve.qc.ca' then 'pluriportail'
  else 'gmail'
end;

notify pgrst, 'reload schema';
