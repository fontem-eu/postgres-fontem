# postgres-fontem runbook

Custom Postgres 16 image for the `gmr/postgresql` Deployment.
Adds `pgvector` to upstream `postgres:16-alpine` and pre-enables
the contrib extensions we use cluster-wide.

## What it carries

| Extension | Version | Why |
|---|---|---|
| vector | tracks Alpine community | LaBSE embeddings (Phase 4 sweep, dimensions=768) |
| pg_trgm | core contrib | trigram similarity for fuzzy authority-name matching |
| fuzzystrmatch | core contrib | levenshtein/soundex helpers for the same |
| citext | core contrib | case-insensitive identifiers (emails, slugs) |
| pgcrypto | core contrib | `gen_random_uuid()`, password hashing |

## Tag scheme

`<pg-version>-pgv<vector-version>`, e.g. `16.4-pgv0.7.4`. Both
the upstream Postgres tag and the pgvector apk are pinned at
build time; the resulting image is immutable.

## Building a new version

```
git tag v16.4-pgv0.7.4
git push --tags
# OR fire the workflow manually with `tag=16.4-pgv0.7.4`
```

The Gitea Actions workflow builds, pushes, signs (cosign), and
attaches a CycloneDX SBOM attestation.

Verify externally:
```
cosign verify --key <pubkey> contribute.void42.internal/golden/postgres-fontem:16.4-pgv0.7.4
cosign verify-attestation --key <pubkey> --type cyclonedx \
    contribute.void42.internal/golden/postgres-fontem:16.4-pgv0.7.4
```

## Cutting the live `gmr/postgresql` over

Existing data layout is identical, so this is a pod-restart, not
a data migration. Order matters because we want extensions
available before downstream code references them.

1. Patch the Deployment image:
   ```
   kubectl set image deployment/postgresql postgresql=contribute.void42.internal/golden/postgres-fontem:<tag> -n gmr
   ```
   (or update whatever helm chart owns the Deployment).
2. Wait for the new pod to come up.
3. Apply `CREATE EXTENSION` to the existing databases — they
   pre-date the image so they don't inherit from `template1`:
   ```
   for db in gmr_app linguistics; do
       kubectl exec -n gmr deploy/postgresql -- psql -U postgres -d $db -c '
           CREATE EXTENSION IF NOT EXISTS vector;
           CREATE EXTENSION IF NOT EXISTS pg_trgm;
           CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
           CREATE EXTENSION IF NOT EXISTS citext;
           CREATE EXTENSION IF NOT EXISTS pgcrypto;'
   done
   ```
4. Smoke:
   ```
   kubectl exec -n gmr deploy/postgresql -- psql -U postgres -d gmr_app -c \
       "SELECT '[1,2,3]'::vector;"
   ```

## Rollback

The data files are forward/backward compatible **as long as no
table actually uses the `vector` type**. If rollback is needed
after vector tables exist:
1. Drop the vector tables (or `pg_dump` them out first if you
   want to preserve content).
2. `kubectl set image deployment/postgresql postgresql=postgres:16-alpine -n gmr`.
3. Restart pod.

## Bumping pgvector

pgvector ships ABI-compatible patch releases; minor/major bumps
sometimes need an `ALTER EXTENSION vector UPDATE`. Check the
upstream changelog before flipping the tag.
