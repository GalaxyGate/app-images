#!/usr/bin/env bash
# Runs the image the way the panel does, with fresh volumes and only environment
# variables, and checks the first-start config, a trusted and an untrusted proxy,
# a Control UI sign-in from another host, restarts, a replaced container, a new
# proxy list on a replaced container, and the refusals.
#   openclaw/test.sh <image>
set -euo pipefail

image=$1
here=$(cd "$(dirname "$0")" && pwd)
name=openclaw-test-$$
origin=https://openclaw-ci.example.com
token=$(openssl rand -hex 32)
ids=$(mktemp -d)
# Requests to the published port on 127.0.0.1 reach the container from the
# bridge gateway, so the host plays the trusted proxy and other containers do not.
proxy=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')

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

# start <origin> [<proxy list>], with OPENCLAW_TRUSTED_PROXIES unset when no list is given.
start() {
    local env=(-e OPENCLAW_GATEWAY_TOKEN="$token" -e OPENCLAW_PUBLIC_ORIGIN="$1")
    [ $# -lt 2 ] || env+=(-e OPENCLAW_TRUSTED_PROXIES="$2")
    docker run -d --name "$name" --restart unless-stopped -p 127.0.0.1::18789 \
        -v "$name-state:/home/node/.openclaw" \
        -v "$name-workspace:/home/node/.openclaw/workspace" \
        -v "$name-secrets:/home/node/.config/openclaw" \
        "${env[@]}" "$image" >/dev/null
    wait_ready
}

# Stops the gateway cleanly so the next container gets its state lease at once.
remove() {
    docker stop "$name" >/dev/null
    docker rm "$name" >/dev/null
}

# Waits through restarts too: a gateway killed without a clean stop holds its
# state lease for up to five minutes, and the restart policy retries meanwhile.
wait_ready() {
    for _ in $(seq 240); do
        if [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ]; then
            port=$(docker port "$name" 18789/tcp | head -1 | sed 's/.*://')
            if curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then
                gateway=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name")
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

start "$origin" "$proxy"
config | jq -e --arg origin "$origin" --arg proxy "$proxy" \
    '.gateway.mode == "local" and .gateway.bind == "lan" and .gateway.publicOrigin == $origin
     and .gateway.trustedProxies == [$proxy]' >/dev/null ||
    fail "first-start config: $(config)"
echo "PASS: first start wrote gateway.mode, gateway.bind, gateway.publicOrigin and gateway.trustedProxies, and the published port answers"

forwarded=(-H "X-Forwarded-For: 203.0.113.7" -H "X-Forwarded-Proto: https" -H "X-Forwarded-Host: openclaw-ci.example.com")
code=$(curl -s -o /dev/null -w '%{http_code}' "${forwarded[@]}" "http://127.0.0.1:$port/")
[ "$code" = 200 ] || fail "the Control UI page through the trusted proxy returned $code"
code=$(curl -s -o /dev/null -w '%{http_code}' "${forwarded[@]}" -X POST -H "Content-Type: application/json" \
    -d '{"tool":"sessions_list","args":{}}' "http://127.0.0.1:$port/tools/invoke")
[ "$code" = 401 ] || fail "the API through the trusted proxy without a token returned $code"
code=$(curl -s -o /dev/null -w '%{http_code}' "${forwarded[@]}" -X POST -H "Content-Type: application/json" \
    -H "Authorization: Bearer $token" -d '{"tool":"sessions_list","args":{}}' "http://127.0.0.1:$port/tools/invoke")
[ "$code" = 200 ] || fail "the API through the trusted proxy with the token returned $code"
out=$(docker run --rm --network bridge --entrypoint node "$image" --input-type=module -e '
    const res = await fetch(process.argv[1], { headers: { "X-Forwarded-For": "203.0.113.7", "X-Forwarded-Proto": "https" } });
    console.log(res.status, await res.text());' "http://$gateway:18789/")
grep -q '^403 .*proxy_attribution_required' <<<"$out" || fail "an untrusted proxy was not refused: ${out:0:300}"
echo "PASS: the trusted proxy reaches the page and the token-checked API, an untrusted proxy gets 403"

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
remove
start https://ignored.example.com "$proxy"
config | jq -e '.gateway.publicOrigin == "https://changed.example.com"' >/dev/null ||
    fail "a replaced container overwrote the existing config: $(config)"
[ "$(read_note https://changed.example.com)" = "$note" ] || fail "USER.md after replacing the container"
echo "PASS: a replaced container keeps the customer's config, the pairing and the note"

remove
start https://ignored.example.com "$proxy, 198.51.100.7"
config | jq -e --arg proxy "$proxy" '.gateway.trustedProxies == [$proxy, "198.51.100.7"]
     and .gateway.publicOrigin == "https://changed.example.com"' >/dev/null ||
    fail "a replaced container with a new proxy list: $(config)"
code=$(curl -s -o /dev/null -w '%{http_code}' "${forwarded[@]}" "http://127.0.0.1:$port/")
[ "$code" = 200 ] || fail "the Control UI page through the trusted proxy returned $code after the new list"
[ "$(read_note https://changed.example.com)" = "$note" ] || fail "USER.md after the new proxy list"
echo "PASS: a replaced container with a new OPENCLAW_TRUSTED_PROXIES list writes it to the existing config and keeps the rest"

remove
start https://ignored.example.com
config | jq -e --arg proxy "$proxy" '.gateway.trustedProxies == [$proxy, "198.51.100.7"]' >/dev/null ||
    fail "a replaced container without OPENCLAW_TRUSTED_PROXIES changed the list: $(config)"
echo "PASS: a replaced container without OPENCLAW_TRUSTED_PROXIES keeps the existing list"

remove
rc=0
timeout 180 docker run --rm -v "$name-state:/home/node/.openclaw" -e OPENCLAW_GATEWAY_TOKEN="$token" \
    -e OPENCLAW_TRUSTED_PROXIES=proxy.example.com "$image" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ] || [ "$rc" -eq 124 ]; then
    fail "a malformed proxy list on an existing config ended with $rc"
fi
docker run --rm -v "$name-state:/v" --entrypoint cat "$image" /v/openclaw.json |
    jq -e --arg proxy "$proxy" '.gateway.trustedProxies == [$proxy, "198.51.100.7"]' >/dev/null ||
    fail "a malformed proxy list changed the existing config"
echo "PASS: a malformed proxy list stops a start on an existing config and leaves the list alone"

for bad in "OPENCLAW_PUBLIC_ORIGIN=" "OPENCLAW_PUBLIC_ORIGIN=http://203.0.113.10:18789" \
    "OPENCLAW_TRUSTED_PROXIES=proxy.example.com"; do
    docker volume rm -f "$name-fresh" >/dev/null
    rc=0
    timeout 180 docker run --rm -v "$name-fresh:/home/node/.openclaw" -e OPENCLAW_GATEWAY_TOKEN="$token" \
        -e OPENCLAW_PUBLIC_ORIGIN="$origin" -e "$bad" "$image" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 124 ]; then
        fail "$bad on a fresh volume ended with $rc"
    fi
    left=$(docker run --rm -v "$name-fresh:/v" --entrypoint ls "$image" -A /v)
    ! grep -qx 'openclaw.json' <<<"$left" || fail "$bad left a config behind"
done
echo "PASS: a missing or plain-HTTP origin and a malformed proxy list stop the first start and write no config"
