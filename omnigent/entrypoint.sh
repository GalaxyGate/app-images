#!/usr/bin/env bash
# Runs the Omnigent server and the bundled host daemon in one container and
# restarts either one if it exits. Panel apps have no restart policy, so this
# script is the supervisor. On stop it signals the host and the server and
# waits for them; anything they leave behind ends with the container.
set -u

# The panel passes a field left blank as an empty variable. Omnigent, Claude
# Code and Codex read an empty value differently from an unset one, so a blank
# field is unset here and the app's own default applies.
for var in $(compgen -e); do
  case "$var" in
    OMNIGENT_*|ANTHROPIC_API_KEY|OPENAI_API_KEY|GIT_TOKEN|GIT_USERNAME)
      [ -z "${!var}" ] && unset "$var" ;;
  esac
done

PORT="${PORT:-22067}"
SERVER_URL="http://127.0.0.1:${PORT}"
export OMNIGENT_ACCOUNTS_INIT_ADMIN_USERNAME="${OMNIGENT_ACCOUNTS_INIT_ADMIN_USERNAME:-admin}"

mkdir -p "${HOME}/.omnigent" "${HOME}/work"

stopping=0
server_pid=""
host_pid=""
host_retry_at=0

log() { echo "omnigent-app: $*" >&2; }

on_stop() {
  stopping=1
  [ -n "$host_pid" ] && kill -TERM "$host_pid" 2>/dev/null
  [ -n "$server_pid" ] && kill -TERM "$server_pid" 2>/dev/null
}
trap on_stop TERM INT

start_server() {
  omnigent server --host 0.0.0.0 --port "$PORT" --no-open &
  server_pid=$!
}

server_healthy() {
  curl -fsS -m 5 "${SERVER_URL}/health" >/dev/null 2>&1
}

# The host signs in with the admin account. A 0.0.0.0 server does not hand
# the host a token the way a loopback-only server does.
start_host() {
  local i
  for i in $(seq 1 120); do
    server_healthy && break
    [ "$stopping" = 1 ] && return 1
    kill -0 "$server_pid" 2>/dev/null || return 1
    sleep 1
  done
  server_healthy || return 1
  local out
  if ! out=$(printf '%s\n%s\n' "$OMNIGENT_ACCOUNTS_INIT_ADMIN_USERNAME" "${OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD:-}" \
             | omnigent login "$SERVER_URL" 2>&1); then
    out=$(echo "$out" | grep -i error | tail -1)
    log "the bundled host could not sign in as '${OMNIGENT_ACCOUNTS_INIT_ADMIN_USERNAME}' (${out%.})." \
        "If you changed the admin password in Omnigent, set OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD to it and restart the app."
    return 1
  fi
  (cd "${HOME}/work" && exec omnigent host --server "$SERVER_URL" --non-interactive --no-open) &
  host_pid=$!
  log "bundled host started"
}

start_server
start_host || host_retry_at=$(( $(date +%s) + 15 ))

while [ "$stopping" = 0 ]; do
  sleep 2 &
  wait $! 2>/dev/null
  [ "$stopping" = 1 ] && break
  if ! kill -0 "$server_pid" 2>/dev/null; then
    wait "$server_pid" 2>/dev/null
    log "server exited with status $?, restarting"
    sleep 2
    start_server
  fi
  if [ -z "$host_pid" ] || ! kill -0 "$host_pid" 2>/dev/null; then
    if [ -n "$host_pid" ]; then
      wait "$host_pid" 2>/dev/null
      log "host exited with status $?, restarting"
      host_pid=""
    fi
    if [ "$(date +%s)" -ge "$host_retry_at" ]; then
      start_host || host_retry_at=$(( $(date +%s) + 15 ))
    fi
  fi
done

[ -n "$host_pid" ] && wait "$host_pid" 2>/dev/null
[ -n "$server_pid" ] && wait "$server_pid" 2>/dev/null
exit 0
