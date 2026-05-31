# Postgres 16 + pgvector built from source + the contrib
# extensions baked into postgres:16-alpine. Drop-in for the
# gmr/postgresql Deployment that community-api and linguistics
# share. Data layout is byte-identical to upstream
# postgres:16-alpine; this is a pod restart, not a migration.
#
# Versioning: tag is `<pg-version>-pgv<vector-version>`, e.g.
# `16.13-pgv0.8.1`. Both the upstream postgres tag and the
# pgvector source tag are pinned at build time; Renovate
# tracks both.
FROM postgres:18-alpine

ARG PGVECTOR_VERSION=v0.8.1

# Build pgvector from source. The Alpine apk
# `postgresql-pgvector` targets Alpine's own postgres install,
# which lives in a different prefix than upstream's source build
# under /usr/local — so we go straight to the source tarball.
# Build deps go in a virtual package that we drop after install
# to keep the runtime image lean.
RUN apk add --no-cache --virtual .build-deps \
        build-base clang19 llvm19-dev wget \
    && cd /tmp \
    && wget -qO- "https://github.com/pgvector/pgvector/archive/refs/tags/${PGVECTOR_VERSION}.tar.gz" | tar xz \
    && cd pgvector-* \
    && make OPTFLAGS="" \
    && make install \
    && cd / \
    && rm -rf /tmp/pgvector-* \
    && apk del .build-deps

# init script enables every extension we want available across
# all databases. Runs in template1 so every newly-created
# database inherits them; the pre-existing `gmr_app` and
# `linguistics` databases need a one-shot CREATE EXTENSION
# applied separately (see RUNBOOK.md).
COPY init/00-extensions.sql /docker-entrypoint-initdb.d/00-extensions.sql
