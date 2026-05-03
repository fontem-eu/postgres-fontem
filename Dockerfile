# Postgres 16 + pgvector + a few extensions the gmr/postgresql
# Deployment will need (community-api `gmr_app` and linguistics
# `linguistics` databases). Built on alpine because the live
# deployment is alpine; data layout is forward/backward
# compatible so this is a drop-in image swap.
#
# Versioning: tag is `<pg-version>-pgv<vector-version>`, e.g.
# `16.4-pgv0.7.4`. Bumping pgvector or postgres bumps the tag.
# Renovate watches both upstream pkgs.
FROM postgres:16-alpine

# pgvector — the only non-core extension we need to install.
# `postgresql16-pgvector` is in Alpine community since 3.20;
# stays in lockstep with the postgres major version. The other
# extensions (pg_trgm, fuzzystrmatch, citext, pgcrypto) are part
# of postgres-contrib and ship inside the base image.
RUN apk add --no-cache postgresql16-pgvector

# init script enables every extension we want available across
# all databases. Runs in template1 so every newly-created
# database inherits them; the live `gmr_app` and `linguistics`
# databases are pre-existing and need a one-shot CREATE EXTENSION
# applied separately (documented in RUNBOOK.md).
COPY init/00-extensions.sql /docker-entrypoint-initdb.d/00-extensions.sql
