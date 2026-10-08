#!/usr/bin/env bash
# Runs the local Dependency-Track spike in the same order as the instance bootstrap (architecture §6):
# database first, then db-init (role and database "dtrack", ADR-022), then Dependency-Track.
#
# Usage: spike/run.sh up                   start everything and wait until the apiserver is ready
#        spike/run.sh first-run            configure Dependency-Track (deployment/scripts/dtrack-first-run.sh)
#        spike/run.sh rotate-db-password   new password for role dtrack via db-init, then a restart
#        spike/run.sh down                 stop the containers, keep the data
#        spike/run.sh destroy              remove containers AND volumes (the data is gone)
#
# Secrets live in spike/secrets/ (directory 0700, ignored by Git), one value per file, generated on first
# use. The containers run as non-root users, so the files themselves are world-readable inside that
# private directory. The CI API key that first-run creates is written to spike/secrets/ci-api-key.
set -euo pipefail

cd "$(dirname "$0")"
compose=(docker compose --file compose.yaml)
api_url=${DTRACK_API_URL:-http://localhost:8081}
secrets=secrets

ensure_secrets() {
  [[ -d $secrets ]] || { mkdir "$secrets"; chmod 700 "$secrets"; }
  local name
  for name in postgres-password db-password admin-password kek; do
    [[ -f $secrets/$name ]] && continue
    case $name in
      # Base64-encoded AES-256 key encryption key for Dependency-Track's secret manager.
      kek) openssl rand -base64 32 ;;
      *) openssl rand -hex 24 ;;
    esac | tr -d '\n' > "$secrets/$name"
    chmod 444 "$secrets/$name"
    echo "spike: generated $secrets/$name"
  done
}

wait_for_api() {
  local deadline=$((SECONDS + ${1:-300}))
  until curl -fs -o /dev/null "$api_url/api/version"; do
    if ((SECONDS > deadline)); then
      echo "spike: apiserver not ready in time; see: docker compose -f spike/compose.yaml logs apiserver" >&2
      return 1
    fi
    sleep 5
  done
  echo "spike: apiserver ready ($(curl -fsS "$api_url/api/version" | jq -r .version))"
}

db_init() {
  PGHOST=postgres PGUSER=postgres PGPASSWORD=$(cat "$secrets/postgres-password") \
    DTRACK_DB_PASSWORD=$1 PGSSLMODE=disable DOCKER_NETWORK=sssc-spike_default \
    POSTGRES_IMAGE=$("${compose[@]}" config --format json | jq -r .services.postgres.image) \
    ../deployment/scripts/db-init.sh
}

case "${1:-}" in
  up)
    ensure_secrets
    "${compose[@]}" up --detach --wait postgres
    db_init "$(cat "$secrets/db-password")"
    "${compose[@]}" up --detach apiserver frontend
    wait_for_api 600
    ;;
  first-run)
    DTRACK_URL=$api_url DTRACK_ADMIN_PASSWORD=$(cat "$secrets/admin-password") \
      ../deployment/scripts/dtrack-first-run.sh --api-key-file "$secrets/ci-api-key"
    ;;
  rotate-db-password)
    # The runbook procedure (§5) in miniature: new password, ALTER ROLE, store it, restart.
    new_password=$(openssl rand -hex 24)
    db_init "$new_password"
    chmod 644 "$secrets/db-password"
    printf '%s' "$new_password" > "$secrets/db-password"
    chmod 444 "$secrets/db-password"
    "${compose[@]}" up --detach --force-recreate apiserver
    wait_for_api 300
    ;;
  down)
    "${compose[@]}" down
    ;;
  destroy)
    "${compose[@]}" down --volumes
    ;;
  *)
    echo "usage: $(basename "$0") up|first-run|rotate-db-password|down|destroy" >&2
    exit 64
    ;;
esac
