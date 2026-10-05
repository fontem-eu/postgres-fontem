# PostgreSQL 16 + pgvector, on Docker Hardened Images (dhi.io, mirrored at
# dhi.void42.internal). Drop-in for every `postgresql` Deployment that runs
# postgres-fontem (testing, staging, dast, shared, prod, linguistics-service).
#
# Why this base: the Alpine variant keeps musl, so the text collation our
# databases were created with (en_US.utf8, libc provider) sorts exactly as
# before and no index needs rebuilding; a glibc base would change the sort
# order under every text index. The runtime runs as postgres (uid 70, the
# owner of every existing data directory) from the start: no gosu, no root,
# no apk. What it keeps is the entrypoint's shell (bash + busybox, whose
# applets include wget), which initdb on an empty volume and the psql client
# Jobs (events-bootstrap, search migrations) need.
#
# Versioning: tag is `<pg-version>-pgv<vector-version>`, e.g. 16.15-pgv0.8.1.
# The base is pinned by digest (Renovate tracks it); pgvector by version and
# checksum.
FROM dhi.void42.internal/postgres:16-alpine3.23-dev@sha256:c74ef4945710d0e1fd994c7579248d16679cb7401c06cec877ca37a5182c70f1 AS build
ARG PGVECTOR_VERSION=0.8.1
ARG PGVECTOR_SHA256=a9094dfb85ccdde3cbb295f1086d4c71a20db1d26bf1d6c39f07a7d164033eb4
# /usr/bin/pg_config belongs to libpq and answers for PostgreSQL 18; the
# server's own is under /usr/libexec/postgresql16. with_llvm=no: no JIT
# bitcode for the extension (it would need a clang matching the server's
# LLVM), which only means vector functions are not inlined by the JIT.
ARG PG_CONFIG=/usr/libexec/postgresql16/pg_config
RUN apk add --no-cache build-base postgresql16-dev \
 && cd /tmp \
 && wget -qO pgvector.tgz "https://github.com/pgvector/pgvector/archive/refs/tags/v${PGVECTOR_VERSION}.tar.gz" \
 && echo "${PGVECTOR_SHA256}  pgvector.tgz" | sha256sum -c - \
 && tar xzf pgvector.tgz \
 && cd "pgvector-${PGVECTOR_VERSION}" \
 && make PG_CONFIG="$PG_CONFIG" OPTFLAGS="" with_llvm=no \
 && make PG_CONFIG="$PG_CONFIG" with_llvm=no install DESTDIR=/pgvector \
 && mkdir -p /pgdata-root

FROM dhi.void42.internal/postgres:16-alpine3.23@sha256:17c502265401bd4f224428d28caf6644c5693832fefb70c6939ecee5f3c55b8d
COPY --from=build /pgvector/usr/lib/postgresql16/ /usr/lib/postgresql16/
COPY --from=build /pgvector/usr/share/postgresql16/extension/ /usr/share/postgresql16/extension/
# Every Deployment mounts its volume at /var/lib/postgresql/data and puts
# PGDATA one level below; initdb, running as uid 70, has to be able to create
# it on an empty volume. (In the cluster fsGroup: 70 already gives it that.)
COPY --from=build --chown=70:70 /pgdata-root /var/lib/postgresql/data
# The locale the previous image (postgres:16-alpine) initialised clusters
# with. The existing databases carry en_US.utf8; new ones should too, and on
# musl it sorts byte-wise, as C does.
ENV LANG=en_US.utf8

# init script enables every extension we want available across
# all databases. Runs in template1 so every newly-created
# database inherits them; the pre-existing `gmr_app` and
# `linguistics` databases need a one-shot CREATE EXTENSION
# applied separately (see RUNBOOK.md).
COPY init/00-extensions.sql /docker-entrypoint-initdb.d/00-extensions.sql
# DHI's entrypoint does not run /docker-entrypoint-initdb.d; ours does, once,
# on a fresh cluster (see the script). Executable in git: CI builds with the
# classic builder, which has no COPY --chmod.
COPY docker-entrypoint.sh /usr/local/bin/postgres-fontem-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/postgres-fontem-entrypoint.sh"]
