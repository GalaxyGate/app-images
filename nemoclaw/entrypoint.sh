#!/bin/bash
# Starts NemoClaw as a controller on a server whose Docker socket is mounted.
#
# Start: join the openshell-docker network, record this container's address on
# it for OpenShell's host_gateway_ip, and run non-interactive onboarding. That
# starts the OpenShell gateway in this container and one OpenClaw sandbox as a
# sibling container, and forwards the dashboard to port 18789 here.
# Stop (SIGTERM): stop the gateway, remove the sandbox containers it started,
# and remove the network.
set -uo pipefail

DATA_DIR=/data/nemoclaw
NETWORK=openshell-docker
GATEWAY_STATE="$HOME/.local/state/nemoclaw/openshell-docker-gateway-${NEMOCLAW_GATEWAY_PORT}"

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

on_stop() {
  trap - TERM INT
  log "stopping: removing the containers this app started"
  # PID 1 is this script; -1 reaches every other process in the container,
  # so the gateway cannot recreate a sandbox while it is being removed.
  kill -TERM -1 2>/dev/null
  sleep 1
  kill -KILL -1 2>/dev/null
  remove_sandboxes
  remove_network
  exit 0
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

# Sandboxes left by a previous run that was killed without a clean stop.
remove_sandboxes

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
nemoclaw onboard --non-interactive &
wait $!
rc=$?
if [ "$rc" -eq 0 ]; then
  log "onboarding finished; the dashboard is on container port 18789"
  nemoclaw "$NEMOCLAW_SANDBOX_NAME" dashboard-url 2>&1 | sed 's/^/[galaxygate] /'
else
  log "onboarding failed with exit code $rc; see the lines above"
  log "fix the app's environment and restart the app, or run: docker exec -it <app> nemoclaw onboard --resume"
fi

sleep infinity &
wait $!
