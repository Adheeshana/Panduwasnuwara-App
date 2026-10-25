Panduwasnuwara App
Local services app (Android + iOS) for Panduwasnuwara East, Sri Lanka, plus a web admin panel.
Requirements live in `docs/SRS.md` — read it before any feature work. It is the source of truth.
Repo layout
`apps/mobile` — React Native + Expo (TypeScript, Expo Router), react-i18next (si, en)
`apps/admin` — React + Vite + TypeScript admin panel (owner / super admin / admin only; officers have no web access)
`supabase/` — migrations, seed, Edge Functions (Supabase CLI)
`docs/SRS.md` — requirements
Rules
All database changes go through migration files in `supabase/migrations`. Never edit the database by hand.
Every table has RLS enabled with explicit policies. Never use the service-role key in `apps/mobile` or `apps/admin`.
Limits, counts and switches come from the `app_settings` table, not constants in code.
All UI text goes through i18n keys with both Sinhala and English strings. Use Noto Sans Sinhala.
Search uses PGroonga; distance uses PostGIS. Don't add paid Google APIs (no Places/Directions API — directions open the Google Maps app by URL).
NIC numbers: only the user, the GN of their village and office staff may read them (RLS). Uniqueness via `nic_hash`.
Build one SRS §19 step at a time; finish and test a step before starting the next.
If the SRS doesn't cover something, ask; don't invent behaviour.