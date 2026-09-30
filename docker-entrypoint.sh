#!/usr/bin/env bash
# postgres-fontem entrypoint.
#
# The Docker Hardened Images postgres entrypoint, with the one thing it
# leaves out and the upstream postgres image did: run
# /docker-entrypoint-initdb.d/*.sql once, while a freshly initialised
# cluster is up. That is where postgres-fontem enables its extensions in
# template1 (init/00-extensions.sql). An initialised cluster goes straight
# to `postgres`, which stays PID 1.
set -Eeu -o pipefail

if [ "$(id -u)" -eq 0 ]; then
	echo >&2 "ENTRYPOINT: this image runs as postgres (uid 70), not root; drop runAsUser: 0"
	exit 1
fi

file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local default="${2:-}"

	if [ -n "${!var:-}" ] && [ -n "${!fileVar:-}" ]; then
		echo >&2 "ERROR: Both ${var} and ${fileVar} are set, but they are mutually exclusive options."
		exit 1
	fi

	local value="$default"
	if [ -n "${!fileVar:-}" ]; then
		value="$(< "${!fileVar}")"
	elif [ -n "${!var:-}" ]; then
		value="${!var}"
	fi
	export "$var"="$value"
	unset "$fileVar"
}

file_env 'POSTGRES_USER' 'postgres'
file_env 'POSTGRES_PASSWORD'
file_env 'POSTGRES_DB' "$POSTGRES_USER"
file_env 'POSTGRES_INITDB_ARGS'

if [ ! -s "$PGDATA/PG_VERSION" ]; then
	echo "ENTRYPOINT: Initializing database..."

	# Prevent insecure configurations.
	case "${POSTGRES_HOST_AUTH_METHOD:-}" in
		md5|scram-sha-256|'')
			if [ -z "$POSTGRES_PASSWORD" ]; then
				echo >&2 "ERROR: Database is uninitialized and the superuser password is not specified."
				echo >&2 "       POSTGRES_PASSWORD or POSTGRES_PASSWORD_FILE must be set to a non-empty value."
				exit 1
			fi
			;;
		*)
			echo >&2 "ERROR: POSTGRES_HOST_AUTH_METHOD=${POSTGRES_HOST_AUTH_METHOD} is not allowed; use md5 or scram-sha-256."
			exit 1
			;;
	esac

	waldir_args=()
	if [ -n "${POSTGRES_INITDB_WALDIR:-}" ]; then
		waldir_args=(--waldir "$POSTGRES_INITDB_WALDIR")
	fi

	# --pwfile refuses a properly-empty file (hence the "\n"): https://github.com/docker-library/postgres/issues/1025.
	# POSTGRES_INITDB_ARGS is word-split on purpose, as upstream does.
	# shellcheck disable=SC2086
	initdb --username="${POSTGRES_USER}" --pwfile=<(printf "%s\n" "$POSTGRES_PASSWORD") "${waldir_args[@]}" ${POSTGRES_INITDB_ARGS}

	# Allow remote hosts to connect with POSTGRES_HOST_AUTH_METHOD, or the server's password_encryption.
	default_auth="$(postgres -C password_encryption "$@")"
	printf '\nhost all all all %s\n' "${POSTGRES_HOST_AUTH_METHOD:-$default_auth}" >> "$PGDATA/pg_hba.conf"

	# Start the cluster on its socket only, create the default database, run the init scripts, stop.
	export PGUSER="${POSTGRES_USER}" PGPASSWORD="${POSTGRES_PASSWORD}"
	pg_ctl -D "$PGDATA" -o "-c listen_addresses=''" -w start
	if [ "$POSTGRES_DB" != 'postgres' ]; then
		createdb --no-password "$POSTGRES_DB"
	fi
	for f in /docker-entrypoint-initdb.d/*.sql; do
		[ -e "$f" ] || continue
		echo "ENTRYPOINT: running $f"
		psql -v ON_ERROR_STOP=1 --no-password --no-psqlrc --dbname "$POSTGRES_DB" -f "$f"
	done
	pg_ctl -D "$PGDATA" -m fast -w stop
	unset PGUSER PGPASSWORD
fi

# Postgres refuses a data directory with group write, and a volume mounted
# with an fsGroup (prod's local-path volume, fsGroup 70) gets group
# rwx+setgid from the kubelet at every mount. The upstream entrypoint resets
# the mode at each start, and so does this one: the server owns PGDATA. On
# 2026-09-30 the first 16.15 start in prod crash-looped on exactly this.
chmod 0700 "$PGDATA" || :

echo "ENTRYPOINT: Starting database..."
exec postgres "$@"
