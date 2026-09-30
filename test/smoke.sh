#!/usr/bin/env bash
# Smoke test for a built postgres-fontem image (run by CI before the push).
#   test/smoke.sh <image>
# 1. A fresh volume initialises: en_US.utf8, the extensions in template1.
# 2. A restart with the permissions a kubelet fsGroup leaves (group rwx +
#    setgid on PGDATA) starts: the 2026-09-30 prod crash loop.
set -euo pipefail
IMG=$1
C=pgf-smoke-$$
VOL=pgf-smoke-$$
ENV=(-e POSTGRES_PASSWORD=smoke -e POSTGRES_DB=app -e PGDATA=/var/lib/postgresql/data/pgdata)
cleanup() { docker rm -f "$C" >/dev/null 2>&1 || true; docker volume rm "$VOL" >/dev/null 2>&1 || true; }
trap cleanup EXIT
fail() { echo "FAIL: $*"; docker logs "$C" 2>&1 | tail -20; exit 1; }
wait_ready() {
  for _ in $(seq 1 60); do
    if docker exec "$C" psql -U postgres -d app -tAc 'select 1' >/dev/null 2>&1; then return 0; fi
    [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = true ] || fail "container exited"
    sleep 2
  done
  fail "not ready after 120 s"
}
q() { docker exec "$C" psql -U postgres -d "$1" -tAc "$2"; }

docker volume create "$VOL" >/dev/null
docker run -d --name "$C" "${ENV[@]}" -v "$VOL:/var/lib/postgresql/data" "$IMG" >/dev/null
wait_ready
[ "$(q template1 "select string_agg(extname, ' ' order by extname) from pg_extension")" = "citext fuzzystrmatch pg_trgm pgcrypto plpgsql vector" ] || fail "template1 extensions"
[ "$(q app "select datcollate from pg_database where datname='app'")" = "en_US.utf8" ] || fail "collation"
[ "$(docker exec "$C" id -u)" = 70 ] || fail "not running as uid 70"
echo "ok: fresh volume initialises (en_US.utf8, extensions, uid 70)"

docker stop -t 30 "$C" >/dev/null && docker rm "$C" >/dev/null
docker run --rm -u 0 -v "$VOL:/d" --entrypoint sh "$IMG" -c \
  'chgrp -R 70 /d && chmod -R g+rwX /d && find /d -type d -exec chmod g+s {} +'
docker run -d --name "$C" "${ENV[@]}" -v "$VOL:/var/lib/postgresql/data" "$IMG" >/dev/null
wait_ready
[ "$(q app "select 1")" = 1 ] || fail "query after restart"
echo "ok: starts on a data directory with fsGroup permissions"
