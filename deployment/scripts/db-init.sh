#!/usr/bin/env bash
# Creates the Dependency-Track database role and database, idempotently (ADR-022).
#
# Connects as the PostgreSQL master user, which is used for nothing else, and makes sure that:
#   - role "dtrack" exists: LOGIN, not a superuser, no CREATEDB/CREATEROLE, with the given password
#   - database "dtrack" exists, is owned by "dtrack", and other roles can't connect to it
# Running it again changes nothing except re-applying the same password, so the database always matches
# the password stored in Secrets Manager.
#
# psql runs from the official postgres image, so the host needs nothing but Docker. Passwords are passed
# as environment variables (never as command-line arguments, which other processes can read).
#
# Environment:
#   PGHOST, PGPORT       database endpoint (PGPORT defaults to 5432)
#   PGUSER, PGPASSWORD   master user, read by the caller at the moment of use
#   DTRACK_DB_PASSWORD   password for role "dtrack"
#   PGSSLMODE            "require" against RDS (the default here); "disable" for the local spike
#   POSTGRES_IMAGE       pinned postgres image that provides psql
#   DOCKER_NETWORK       optional Docker network to join (local spike)
set -euo pipefail

: "${PGHOST:?PGHOST is required}"
: "${PGUSER:?PGUSER is required}"
: "${PGPASSWORD:?PGPASSWORD is required}"
: "${DTRACK_DB_PASSWORD:?DTRACK_DB_PASSWORD is required}"
: "${POSTGRES_IMAGE:?POSTGRES_IMAGE is required}"
export PGPORT="${PGPORT:-5432}" PGSSLMODE="${PGSSLMODE:-require}" PGDATABASE=postgres

network_args=()
if [[ -n ${DOCKER_NETWORK:-} ]]; then
  network_args=(--network "$DOCKER_NETWORK")
fi

docker run --rm -i "${network_args[@]}" \
  -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGSSLMODE -e PGDATABASE -e DTRACK_DB_PASSWORD \
  "$POSTGRES_IMAGE" psql --no-psqlrc --quiet -v ON_ERROR_STOP=1 <<'SQL'
\getenv dtrack_password DTRACK_DB_PASSWORD

-- Role: create it once, then (re)apply the attributes and the current password.
SELECT 'CREATE ROLE dtrack'
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'dtrack') \gexec
SELECT format('ALTER ROLE dtrack WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD %L',
              :'dtrack_password') \gexec

-- On RDS the master user is not a real superuser: to create a database owned by "dtrack" it must be
-- allowed to SET ROLE dtrack. Harmless where it is a superuser.
SELECT format('GRANT dtrack TO %I', current_user)
 WHERE NOT pg_has_role(current_user, 'dtrack', 'SET') \gexec

SELECT 'CREATE DATABASE dtrack OWNER dtrack'
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'dtrack') \gexec
REVOKE ALL ON DATABASE dtrack FROM PUBLIC;
SQL

echo "db-init: role and database \"dtrack\" are in place"
