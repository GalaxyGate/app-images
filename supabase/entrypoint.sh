#!/bin/bash
# Runs upstream's self-hosted Supabase compose stack on the server whose Docker
# socket is mounted, and removes it again when this container stops.
#
# First start: copy upstream's docker/ folder to /data/supabase/stack and run
# upstream's utils/generate-keys.sh and utils/add-new-auth-keys.sh, the steps
# upstream setup.sh runs. The generated JWT secret, API keys and encryption keys
# stay in stack/.env on the mount, so they survive restarts and redeploys.
# Every start: the app's environment overrides stack/.env (compose gives shell
# variables precedence over .env), a changed POSTGRES_PASSWORD is applied to the
# database roles the way utils/db-passwd.sh does, and docker compose brings the
# stack up with one override file. socat relays container ports 22800, 22432
# and 22543 to api-gw:8000, supavisor:5432 and supavisor:6543.
# Stop (SIGTERM): kill the stateless services, stop Postgres with its fast
# shutdown signal, and remove every stack container and the stack network.
set -uo pipefail

DATA_DIR=/data/supabase
STACK="$DATA_DIR/stack"
UPSTREAM=/opt/supabase/docker
OVERRIDE=docker-compose.galaxygate.yml
NETWORK=supabase_default
LOCK="$DATA_DIR/.controller"
STATELESS=(studio api-gw auth rest realtime storage imgproxy meta functions supavisor)
export COMPOSE_FILE="docker-compose.yml:$OVERRIDE"

log() { printf '[galaxygate] %s\n' "$*"; }
fail() {
  log "ERROR: $*"
  exit 1
}

self_id() {
  sed -n 's|.*/docker/containers/\([0-9a-f]\{64\}\)/.*|\1|p' /proc/self/mountinfo | head -n1
}

env_get() {
  grep "^$1=" "$STACK/.env" | tail -n1 | cut -d= -f2-
}

env_put() {
  local tmp="$STACK/.env.galaxygate"
  if grep -q "^$1=" "$STACK/.env"; then
    K="$1" V="$2" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"] } index($0, k "=") == 1 { print k "=" v; next } { print }' \
      "$STACK/.env" >"$tmp" && cat "$tmp" >"$STACK/.env" && rm -f "$tmp"
  else
    printf '%s=%s\n' "$1" "$2" >>"$STACK/.env"
  fi
}

compose() {
  docker compose --progress quiet "$@"
}

# Long commands run in the background so the TERM trap fires while they run.
run() {
  "$@" &
  wait $!
}

on_stop() {
  trap - TERM INT
  log "stopping: removing the Supabase containers this app started"
  local jobs_left
  jobs_left="$(jobs -p)"
  # shellcheck disable=SC2086
  [ -n "$jobs_left" ] && kill $jobs_left 2>/dev/null
  cd "$STACK" 2>/dev/null || exit 0
  compose kill "${STATELESS[@]}" >/dev/null 2>&1
  compose stop -t 6 db >/dev/null 2>&1
  docker network disconnect -f "$NETWORK" "$SELF" >/dev/null 2>&1
  compose down --remove-orphans -t 1 >/dev/null 2>&1
  local left
  left="$(docker ps -aq --filter label=com.docker.compose.project=supabase | wc -l)"
  log "stack removed; supabase containers left: $left"
  rm -f "$LOCK"
  exit 0
}

first_start() {
  log "first start: copying upstream's docker folder ($(cat "$UPSTREAM/.galaxygate-upstream")) to $STACK"
  mkdir -p "$STACK"
  cp -a "$UPSTREAM/." "$STACK/" || fail "cannot copy the stack files to $STACK"
  cd "$STACK" || fail "cannot enter $STACK"
  cp .env.example .env
  log "generating the JWT secret, API keys and encryption keys with upstream utils/generate-keys.sh and utils/add-new-auth-keys.sh"
  sh utils/generate-keys.sh --update-env >/dev/null || fail "utils/generate-keys.sh failed"
  sh utils/add-new-auth-keys.sh --update-env >/dev/null || fail "utils/add-new-auth-keys.sh failed"
  rm -f .env.old docker-compose.yml.old
  chmod 600 .env
}

check_inputs() {
  [ -n "${SUPABASE_PUBLIC_URL:-}" ] || fail "set SUPABASE_PUBLIC_URL to the URL customers open, for example https://your-domain"
  SUPABASE_PUBLIC_URL="${SUPABASE_PUBLIC_URL%/}"
  [[ "$SUPABASE_PUBLIC_URL" =~ ^https?://[^/]+$ ]] ||
    fail "SUPABASE_PUBLIC_URL must be http(s)://host or http(s)://host:port with no path, got '$SUPABASE_PUBLIC_URL'"
  export SUPABASE_PUBLIC_URL
  # setup.sh derives API_EXTERNAL_URL the same way.
  export API_EXTERNAL_URL="$SUPABASE_PUBLIC_URL/auth/v1"
  [ -n "${SITE_URL:-}" ] || export SITE_URL="$SUPABASE_PUBLIC_URL"
  # GoTrue parses these as integers and refuses to start on an empty value.
  local k
  for k in JWT_EXPIRY SMTP_PORT; do
    if [ -n "${!k+x}" ] && ! [[ "${!k}" =~ ^[0-9]+$ ]]; then
      fail "$k must be a whole number, got '${!k}'"
    fi
  done
  # The password goes into postgres:// URLs; upstream says to avoid @/?#:& in it.
  if [ -n "${POSTGRES_PASSWORD+x}" ] && ! [[ "$POSTGRES_PASSWORD" =~ ^[A-Za-z0-9._~-]+$ ]]; then
    fail "POSTGRES_PASSWORD may use only letters, digits and . _ ~ - (it is placed in connection URLs)"
  fi
}

# Upstream's role-password change, utils/db-passwd.sh lines 110-147.
apply_password() {
  local new="${POSTGRES_PASSWORD:-}" old
  old="$(env_get POSTGRES_PASSWORD)"
  [ -n "$new" ] || return 0
  [ "$new" = "$old" ] && return 0
  if [ ! -s volumes/db/data/PG_VERSION ]; then
    env_put POSTGRES_PASSWORD "$new"
    return 0
  fi
  log "POSTGRES_PASSWORD changed: setting the new password on the database roles (upstream utils/db-passwd.sh)"
  POSTGRES_PASSWORD="$old" run compose up -d --wait --wait-timeout 300 db || fail "Postgres did not start with the previous password"
  compose exec -T -e PGOPTIONS="-c client_min_messages=warning" db psql -q -U supabase_admin -d _supabase -v ON_ERROR_STOP=1 >/dev/null <<EOF || fail "changing the database role passwords failed"
alter user anon with password '${new}';
alter user authenticated with password '${new}';
alter user authenticator with password '${new}';
alter user dashboard_user with password '${new}';
alter user pgbouncer with password '${new}';
alter user postgres with password '${new}';
alter user service_role with password '${new}';
alter user supabase_admin with password '${new}';
alter user supabase_auth_admin with password '${new}';
alter user supabase_functions_admin with password '${new}';
alter user supabase_replication_admin with password '${new}';
alter user supabase_storage_admin with password '${new}';

DROP SCHEMA _supavisor CASCADE;
create schema if not exists _supavisor;
alter schema _supavisor owner to supabase_admin;

DO \$\$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = '_analytics'
      AND table_name = 'source_backends'
  ) THEN
    UPDATE _analytics.source_backends
    SET config = jsonb_set(
      config,
      '{url}',
      '"postgresql://supabase_admin:${new}@db:5432/postgres"',
      false
    )
    WHERE type = 'postgres';
  END IF;
END
\$\$;
EOF
  env_put POSTGRES_PASSWORD "$new"
  log "database role passwords updated"
}

# Host ports come from the panel's allocation, so the stack publishes none.
# restart "no": the stack runs only while this controller runs.
write_override() {
  {
    echo "# Written by the GalaxyGate controller at every start; edits are lost."
    echo "services:"
    local s
    for s in "${STATELESS[@]}" db; do
      echo "  $s:"
      echo "    restart: \"no\""
      case "$s" in
        api-gw | supavisor) echo "    ports: !reset []" ;;
      esac
    done
  } >"$OVERRIDE"
}

start_relays() {
  socat TCP-LISTEN:22800,fork,reuseaddr TCP:api-gw:8000 &
  socat TCP-LISTEN:22432,fork,reuseaddr TCP:supavisor:5432 &
  socat TCP-LISTEN:22543,fork,reuseaddr TCP:supavisor:6543 &
}

print_access() {
  log "Supabase is up. Studio and every API: $SUPABASE_PUBLIC_URL"
  log "Studio sign-in: user ${DASHBOARD_USERNAME:-$(env_get DASHBOARD_USERNAME)} and the DASHBOARD_PASSWORD from the app's environment"
  log "anon key: $(env_get ANON_KEY)"
  log "service_role key: $(env_get SERVICE_ROLE_KEY)"
  log "publishable key: $(env_get SUPABASE_PUBLISHABLE_KEY)"
  log "secret key: $(env_get SUPABASE_SECRET_KEY)"
  log "Postgres: user postgres.${POOLER_TENANT_ID:-$(env_get POOLER_TENANT_ID)}, session pooler on container port 22432, transaction pooler on 22543"
}

docker info >/dev/null 2>&1 || fail "cannot reach Docker; mount the server's /var/run/docker.sock into the app"
SELF="$(self_id)"
[ -n "$SELF" ] || fail "cannot find this container's ID in /proc/self/mountinfo"
src="$(docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$DATA_DIR\"}}{{.Source}}{{end}}{{end}}" "$SELF")"
[ "$src" = "$DATA_DIR" ] || fail "mount the server directory $DATA_DIR at the same path $DATA_DIR in the app (found '${src:-no mount}')"

if [ -s "$LOCK" ]; then
  other="$(cat "$LOCK")"
  if [ "$other" != "$SELF" ] && [ "$(docker inspect -f '{{.State.Running}}' "$other" 2>/dev/null)" = "true" ]; then
    fail "another Supabase app ($(docker inspect -f '{{.Name}}' "$other")) already runs on this server; run one Supabase app per server"
  fi
fi
for id in $(docker ps -aq --filter label=com.docker.compose.project=supabase); do
  dir="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$id" 2>/dev/null)"
  [ "$dir" = "$STACK" ] || fail "a compose project named supabase from '$dir' already runs on this server; run one Supabase per server"
done
printf '%s\n' "$SELF" >"$LOCK"

trap on_stop TERM INT

[ -s "$STACK/.env" ] || first_start
cd "$STACK" || fail "cannot enter $STACK"
check_inputs
write_override

log "pulling the stack images (the first start downloads about 2.1 GB)"
run compose pull || fail "docker compose pull failed"
apply_password

compose up -d --no-start || fail "docker compose could not create the stack"
docker network connect "$NETWORK" "$SELF" >/dev/null 2>&1
docker inspect -f "{{with index .NetworkSettings.Networks \"$NETWORK\"}}ok{{end}}" "$SELF" | grep -q ok ||
  fail "could not join the $NETWORK network"
start_relays

log "starting the stack: docker compose up -d --wait"
if run compose up -d --wait --wait-timeout 900; then
  compose ps --format '{{.Name}} {{.Status}}' | sed 's/^/[galaxygate]   /'
  print_access
else
  log "the stack did not become healthy; container states:"
  compose ps -a --format '{{.Name}} {{.Status}}' | sed 's/^/[galaxygate]   /'
  log "fix the app's environment and restart the app"
fi

sleep infinity &
wait $!
