#!/usr/bin/env bash
# Runs the image the way the panel does, with fresh volumes and only environment
# variables, and checks the first-start config, a Control UI sign-in from another
# host, restarts, a replaced container, and the refusals.
#   openclaw/test.sh <image>
set -euo pipefail

image=$1
here=$(cd "$(dirname "$0")" && pwd)
name=openclaw-test-$$
origin=https://openclaw-ci.example.com
token=$(openssl rand -hex 32)
ids=$(mktemp -d)

cleanup() {
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker volume rm -f "$name-state" "$name-workspace" "$name-secrets" "$name-fresh" >/dev/null 2>&1 || true
    rm -rf "$ids"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    docker logs --tail 80 "$name" >&2 2>&1 || true
    exit 1
}

start() {
    docker run -d --name "$name" --restart unless-stopped -p 127.0.0.1::18789 \
        -v "$name-state:/home/node/.openclaw" \
        -v "$name-workspace:/home/node/.openclaw/workspace" \
        -v "$name-secrets:/home/node/.config/openclaw" \
        -e OPENCLAW_GATEWAY_TOKEN="$token" -e OPENCLAW_PUBLIC_ORIGIN="$1" "$image" >/dev/null
    wait_ready
}

# Waits through restarts too: a gateway killed without a clean stop holds its
# state lease for up to five minutes, and the restart policy retries meanwhile.
wait_ready() {
    for _ in $(seq 240); do
        if [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ]; then
            port=$(docker port "$name" 18789/tcp | head -1 | sed 's/.*://')
            if curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then
                gateway=$(docker inspect -f '{{.NetworkSettings.IPAddress}}' "$name")
                echo "gateway ready after $(docker inspect -f '{{.RestartCount}}' "$name") restarts"
                return 0
            fi
        fi
        sleep 2
    done
    fail "gateway did not answer on the published port within 480 seconds"
}

config() {
    docker exec "$name" cat /home/node/.openclaw/openclaw.json
}

# connect <token> <origin> [<method> <params-json>], from another container like a remote browser.
connect() {
    local client_token=$1
    shift
    docker run --rm --network bridge --user "$(id -u):$(id -g)" \
        -e OPENCLAW_GATEWAY_TOKEN="$client_token" \
        -v "$here/gateway-connect.mjs:/test/gateway-connect.mjs:ro" -v "$ids:/ids" \
        --entrypoint node "$image" /test/gateway-connect.mjs "ws://$gateway:18789" "$1" /ids/device.pem "${@:2}"
}

base=$(sed -n 's/^FROM //p' "$here/Dockerfile")
docker pull -q "$base" >/dev/null
want=$(docker inspect -f '{{json .Config.Entrypoint}}' "$base" | jq -c '["/usr/local/bin/entrypoint.sh"] + .')
got=$(docker inspect -f '{{json .Config.Entrypoint}}' "$image")
[ "$got" = "$want" ] || fail "ENTRYPOINT is $got, wrapping upstream's would be $want"
want=$(docker inspect -f '{{json .Config.Cmd}}' "$base")
got=$(docker inspect -f '{{json .Config.Cmd}}' "$image")
[ "$got" = "$want" ] || fail "CMD is $got, upstream's is $want"
echo "PASS: the entrypoint hands over to upstream's entrypoint and command"

start "$origin"
config | jq -e --arg origin "$origin" \
    '.gateway.mode == "local" and .gateway.bind == "lan" and .gateway.publicOrigin == $origin' >/dev/null ||
    fail "first-start config: $(config)"
echo "PASS: first start wrote gateway.mode, gateway.bind and gateway.publicOrigin, and the published port answers"

out=$(connect "$token" https://elsewhere.example.com || true)
grep -q 'origin not allowed' <<<"$out" || fail "a foreign browser origin was not refused: $out"
out=$(connect wrong-token "$origin" || true)
jq -e 'select(.step == "connect") | .ok == false' <<<"$out" >/dev/null || fail "a wrong token was not refused: $out"
grep -qi 'token' <<<"$out" || fail "a wrong token was refused for another reason: $out"
out=$(connect "$token" "$origin" || true)
request=$(jq -r 'select(.step == "connect") | .error.details.requestId // empty' <<<"$out")
[ -n "$request" ] || fail "the app origin and token did not reach device pairing: $out"
docker exec "$name" openclaw devices approve "$request" >/dev/null || fail "openclaw devices approve $request"
note="GalaxyGate CI note $(openssl rand -hex 8)"
out=$(connect "$token" "$origin" agents.files.set \
    "$(jq -nc --arg c "$note" '{agentId: "main", name: "USER.md", content: $c}')") ||
    fail "sign-in and write after approval: $out"
echo "PASS: foreign origin and wrong token refused, the app origin signed in after pairing and wrote USER.md"

read_note() {
    connect "$token" "$1" agents.files.get '{"agentId":"main","name":"USER.md"}' |
        jq -r 'select(.step == "agents.files.get") | .payload.file.content'
}

before=$(config | jq -c .gateway)
docker restart "$name" >/dev/null
wait_ready
[ "$(config | jq -c .gateway)" = "$before" ] || fail "restart changed the gateway config: $before -> $(config | jq -c .gateway)"
[ "$(read_note "$origin")" = "$note" ] || fail "USER.md after restart"
echo "PASS: after a restart the config is unchanged and the paired browser reads its note"

docker exec "$name" openclaw config set gateway.publicOrigin https://changed.example.com >/dev/null
docker stop "$name" >/dev/null
docker rm "$name" >/dev/null
start https://ignored.example.com
config | jq -e '.gateway.publicOrigin == "https://changed.example.com"' >/dev/null ||
    fail "a replaced container overwrote the existing config: $(config)"
[ "$(read_note https://changed.example.com)" = "$note" ] || fail "USER.md after replacing the container"
echo "PASS: a replaced container keeps the customer's config, the pairing and the note"

docker rm -f "$name" >/dev/null
for bad in "" "http://203.0.113.10:18789"; do
    docker volume rm -f "$name-fresh" >/dev/null
    rc=0
    timeout 180 docker run --rm -v "$name-fresh:/home/node/.openclaw" \
        -e OPENCLAW_GATEWAY_TOKEN="$token" -e OPENCLAW_PUBLIC_ORIGIN="$bad" "$image" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 124 ]; then
        fail "OPENCLAW_PUBLIC_ORIGIN='$bad' on a fresh volume ended with $rc"
    fi
    left=$(docker run --rm -v "$name-fresh:/v" --entrypoint ls "$image" -A /v)
    ! grep -qx 'openclaw.json' <<<"$left" || fail "OPENCLAW_PUBLIC_ORIGIN='$bad' left a config behind"
done
echo "PASS: a missing or plain-HTTP origin stops the first start and writes no config"
