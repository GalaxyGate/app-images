#!/bin/bash
# Starts NemoClaw as a controller on a server whose Docker socket is mounted.
#
# Start: join the openshell-docker network, record this container's address on
# it for OpenShell's host_gateway_ip, and run non-interactive onboarding. That
# starts the OpenShell gateway in this container and one OpenClaw sandbox as a
# sibling container, and forwards the dashboard to port 18789 here.
# Stop (SIGTERM): remove the sandbox containers, delete the sandbox from the
# OpenShell gateway, stop the gateway, and remove the network. The OpenClaw
# state volume stays, so the next start creates the sandbox again on it.
set -uo pipefail

DATA_DIR=/data/nemoclaw
NETWORK=openshell-docker
GATEWAY_STATE="$HOME/.local/state/nemoclaw/openshell-docker-gateway-${NEMOCLAW_GATEWAY_PORT}"
CLEAN_STOP="$DATA_DIR/.clean-stop"

log() { printf '[galaxygate] %s\n' "$*"; }
fail() {
  log "ERROR: $*"
  exit 1
}

self_id() {
  sed -n 's|.*/docker/containers/\([0-9a-f]\{64\}\)/.*|\1|p' /proc/self/mountinfo | head -n1
}

sandbox_namespace() {
  sed -n 's/^sandbox_namespace = "\(.*\)"$/\1/p' "$GATEWAY_STATE/openshell-gateway.toml" 2>/dev/null | head -n1
}

remove_sandboxes() {
  local ns ids
  ns="$(sandbox_namespace)"
  [ -n "$ns" ] || return 0
  ids="$(docker ps -aq --filter label=openshell.ai/managed-by=openshell --filter "label=openshell.ai/sandbox-namespace=$ns")"
  [ -n "$ids" ] || return 0
  # shellcheck disable=SC2086
  docker rm -f $ids >/dev/null && log "removed sandbox containers: ${ids//$'\n'/ }"
}

remove_network() {
  docker network disconnect -f "$NETWORK" "$SELF" >/dev/null 2>&1
  if [ "$(docker network inspect -f '{{len .Containers}}' "$NETWORK" 2>/dev/null)" = "0" ]; then
    docker network rm "$NETWORK" >/dev/null && log "removed network $NETWORK"
  fi
}

# The gateway keeps its sandbox record in its state on the mount. With the
# record gone the next onboarding creates the sandbox; with a stale record it
# tries to back up a container that no longer exists and stops.
delete_sandbox_record() {
  pgrep -f '^openshell-gateway' >/dev/null || return 0
  timeout 3 openshell sandbox delete "$NEMOCLAW_SANDBOX_NAME" >/dev/null 2>&1
  if timeout 3 openshell sandbox list >/run/nemoclaw/sandboxes.txt 2>&1 &&
    ! grep -qw "$NEMOCLAW_SANDBOX_NAME" /run/nemoclaw/sandboxes.txt; then
    log "deleted sandbox '$NEMOCLAW_SANDBOX_NAME' from the OpenShell gateway"
  fi
}

on_stop() {
  trap - TERM INT
  log "stopping: removing the containers this app started"
  remove_sandboxes
  delete_sandbox_record
  # PID 1 is this script; -1 reaches every other process in the container.
  kill -TERM -1 2>/dev/null
  sleep 1
  kill -KILL -1 2>/dev/null
  remove_sandboxes
  remove_network
  touch "$CLEAN_STOP"
  exit 0
}

onboard() {
  nemoclaw onboard --non-interactive &
  wait $!
}

SELF="$(self_id)"
[ -n "$SELF" ] || fail "cannot find this container's ID in /proc/self/mountinfo"
docker info >/dev/null 2>&1 || fail "cannot reach Docker; mount the server's /var/run/docker.sock into the app"

src="$(docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$DATA_DIR\"}}{{.Source}}{{end}}{{end}}" "$SELF")"
[ "$src" = "$DATA_DIR" ] || fail "mount the server directory $DATA_DIR at the same path $DATA_DIR in the app (found '${src:-no mount}')"

if docker network inspect "$NETWORK" >/dev/null 2>&1; then
  for id in $(docker network inspect -f '{{range $id, $c := .Containers}}{{$id}} {{end}}' "$NETWORK"); do
    [ "$id" = "$SELF" ] && continue
    [ "$(docker inspect -f '{{index .Config.Labels "openshell.ai/managed-by"}}' "$id" 2>/dev/null)" = "openshell" ] && continue
    fail "another container ($(docker inspect -f '{{.Name}}' "$id")) already uses the $NETWORK network; run one NemoClaw app per server"
  done
fi

trap on_stop TERM INT

# A run killed without a clean stop leaves its sandbox container and the
# gateway's record of it. Onboarding rebuilds the gateway database, and with a
# stale record it would try to back up the missing container and stop.
remove_sandboxes
if [ -e "$GATEWAY_STATE/openshell.db" ] && [ ! -e "$CLEAN_STOP" ]; then
  log "the previous run did not stop cleanly; resetting the OpenShell gateway database"
  rm -f "$GATEWAY_STATE"/openshell.db*
fi
rm -f "$CLEAN_STOP"

mkdir -p "$DATA_DIR/bin" "$HOME" /run/nemoclaw
install -m 0755 /usr/local/bin/openshell-sandbox "$NEMOCLAW_OPENSHELL_SANDBOX_BIN"

docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK" >/dev/null ||
  fail "cannot create the $NETWORK network"
docker network connect "$NETWORK" "$SELF" >/dev/null 2>&1
ip="$(docker inspect -f "{{with index .NetworkSettings.Networks \"$NETWORK\"}}{{.IPAddress}}{{end}}" "$SELF")"
[ -n "$ip" ] || fail "this container has no address on the $NETWORK network"
export NEMOCLAW_DOCKER_HOST_GATEWAY_IP="$ip"
printf '%s\n' "$ip" >/run/nemoclaw/host-gateway-ip
log "controller address on $NETWORK: $ip"

log "running nemoclaw onboard --non-interactive for sandbox '$NEMOCLAW_SANDBOX_NAME'"
onboard
rc=$?
if [ "$rc" -eq 0 ]; then
  log "onboarding finished; the dashboard is on container port 18789"
  nemoclaw "$NEMOCLAW_SANDBOX_NAME" dashboard-url 2>&1 | sed 's/^/[galaxygate] /'
else
  log "onboarding failed with exit code $rc; see the lines above"
  log "fix the app's environment and restart the app to onboard again"
fi

sleep infinity &
wait $!
