-- Enable extensions in template1 so every freshly-created
-- database inherits them. Existing databases (gmr_app,
-- linguistics) need a one-shot `CREATE EXTENSION` per
-- database after the image swap — see RUNBOOK.md.

\c template1

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
