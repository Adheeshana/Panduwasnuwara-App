-- SRS §19 step 1 / §2: PostGIS for distance, PGroonga for Sinhala+English search.
-- pgcrypto provides digest() for nic_hash (SRS §5.2).

CREATE SCHEMA IF NOT EXISTS extensions;

CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgroonga;
