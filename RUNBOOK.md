# postgres-fontem runbook

Custom Postgres 16 image for every `postgresql` Deployment in the fontem
environments (testing, staging, dast, shared, prod, linguistics-service).
It adds `pgvector` to the Docker Hardened Images postgres (Alpine) and
pre-enables the contrib extensions we use cluster-wide.

## What it carries

| Extension | Version | Why |
|---|---|---|
| vector | built from the pinned source tarball (checksum in the Dockerfile) | LaBSE embeddings (Phase 4 sweep, dimensions=768) |
| pg_trgm | core contrib | trigram similarity for fuzzy authority-name matching |
| fuzzystrmatch | core contrib | levenshtein/soundex helpers for the same |
| citext | core contrib | case-insensitive identifiers (emails, slugs) |
| pgcrypto | core contrib | `gen_random_uuid()`, password hashing |

## The base

- **Image:** `dhi.void42.internal/postgres:16-alpine3.23`, the Docker Hardened
  Images build of Alpine's `postgresql16`, pinned by digest (Renovate tracks it).
  The `-dev` variant compiles pgvector; only its files reach the runtime.
- **Runs as `postgres` (uid 70)** from the start. That uid already owns every
  existing data directory, so there's no gosu and no root. The entrypoint
  refuses to run as root.
- **Alpine, i.e. musl.** Our clusters use the libc collation `en_US.utf8`,
  which musl sorts byte-wise. A glibc base would change the sort order under
  every text index; this one does not.
- **What the runtime keeps:** a shell (bash + busybox). Initialising an empty
  volume needs it, and so do the psql client Jobs (events-bootstrap, the
  search migrations). There is no apk and no compiler.
- **`docker-entrypoint.sh`** is DHI's entrypoint plus the one thing DHI leaves
  out: running `/docker-entrypoint-initdb.d/*.sql` once, on a fresh cluster.
  That is where `init/00-extensions.sql` enables the extensions in `template1`.

## Tag scheme

`<pg-version>-pgv<vector-version>`, e.g. `16.15-pgv0.8.1`. The base is
pinned by digest and pgvector by version and checksum, so a tag is
immutable.

## Building a new version

```
git tag v16.15-pgv0.8.1
git push --tags
# OR fire the workflow manually with `tag=16.15-pgv0.8.1`
```

The workflow uses void42/ci-actions' docker-build-sign, the same build path
as every other image. It:
- builds and pushes `contribute.void42.internal/fontem/postgres-fontem:<tag>`;
- checks that the runtime image carries nothing beyond its shell;
- signs the digest;
- attests an image-derived CycloneDX SBOM and SLSA v1 provenance.

Verify externally:
```
cosign verify --key <pubkey> --insecure-ignore-tlog contribute.void42.internal/fontem/postgres-fontem:<tag>
cosign verify-attestation --key <pubkey> --insecure-ignore-tlog --type cyclonedx \
    contribute.void42.internal/fontem/postgres-fontem:<tag>
cosign verify-attestation --key <pubkey> --insecure-ignore-tlog --type slsaprovenance1 \
    contribute.void42.internal/fontem/postgres-fontem:<tag>
```

## Rolling a new image out

Change the image pin in fontem/gitops (`infra/<env>.yaml`), one environment
at a time: testing, staging, dast, shared, linguistics-service, then prod.
A minor Postgres version and a pgvector patch release need no data
migration, so each environment is a pod restart. The Deployments use
`Recreate`.

Moving from 16.13 (upstream `postgres:16-alpine` build) to this image was
tested on 2026-09-29. A cluster initialised and indexed by the old image
started on the new one with:
- identical `ORDER BY` output over 20k rows;
- `amcheck` `bt_index_check(..., heapallindexed)` clean on every B-tree;
- pgvector's HNSW index returning the same neighbours.

A fresh volume initialises with `en_US.utf8`, and `template1` carries all
five extensions.

Smoke after each environment:
```
kubectl exec -n <ns> deploy/postgresql -c postgres -- psql -U postgres -d gmr_app -tAc \
    "SELECT version(), (SELECT extversion FROM pg_extension WHERE extname='vector')"
```

## fsGroup volumes (2026-09-30)

A pod with an `fsGroup` on a volume the kubelet manages ownership for
(prod's local-path volume, `fsGroup: 70`) gets group rwx and setgid on
PGDATA at every mount. Postgres refuses to start on a data directory with
group write. The upstream image reset the mode as root at each start. The
first 16.15 image, running as uid 70, did not, and prod crash-looped for
16 minutes until it was rolled back. The NFS-backed environments ignore
`fsGroup`, which is why they passed.

The entrypoint now runs `chmod 0700 "$PGDATA"` before starting; the server
owns the directory. `test/smoke.sh`, which runs in CI before the push,
restarts a cluster on fsGroup-style permissions and fails without that
line.

## Rollback

Pin the previous image again. Across minor versions of 16 the data
directory is the same format, both ways, and the pgvector version is
unchanged.

## Bumping pgvector

pgvector ships ABI-compatible patch releases; minor/major bumps
sometimes need an `ALTER EXTENSION vector UPDATE`. Check the
upstream changelog before flipping the tag. Update `PGVECTOR_VERSION`
and `PGVECTOR_SHA256` together.
