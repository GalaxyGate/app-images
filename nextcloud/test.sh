#!/usr/bin/env bash
# Runs the image the way the panel does, with a fresh volume and only environment
# variables, behind an nginx that ends TLS like the GalaxyGate domain proxy. Checks
# the links, redirects and sign-in through the proxy and straight to the port.
#   nextcloud/test.sh <image>
set -euo pipefail

image=$1
here=$(cd "$(dirname "$0")" && pwd)
proxy_image=nginx:1.30.6-alpine@sha256:0e52bd054126cdc040b1276c0af347aeb02a41b9cfe305d6094767ac30e97949
name=nextcloud-test-$$
domain=nextcloud-ci.example.com
password=$(openssl rand -hex 16)
work=$(mktemp -d)

cleanup() {
    docker rm -f "$name" "$name-proxy" >/dev/null 2>&1 || true
    docker volume rm -f "$name-html" >/dev/null 2>&1 || true
    docker network rm "$name" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    docker logs --tail 60 "$name" >&2 2>&1 || true
    exit 1
}

base=$(sed -n 's/^FROM //p' "$here/Dockerfile")
docker pull -q "$base" >/dev/null
for field in Entrypoint Cmd; do
    want=$(docker inspect -f "{{json .Config.$field}}" "$base")
    got=$(docker inspect -f "{{json .Config.$field}}" "$image")
    [ "$got" = "$want" ] || fail "$field is $got, upstream's is $want"
done
echo "PASS: ENTRYPOINT and CMD are upstream's"

docker network create "$name" >/dev/null
docker run -d --name "$name" --network "$name" -p 127.0.0.1::80 -v "$name-html:/var/www/html" \
    -e SQLITE_DATABASE=nextcloud -e NEXTCLOUD_ADMIN_USER=admin -e NEXTCLOUD_ADMIN_PASSWORD="$password" \
    -e NEXTCLOUD_TRUSTED_DOMAINS="127.0.0.1 $domain" "$image" >/dev/null

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$domain" \
    -keyout "$work/tls.key" -out "$work/tls.crt" >/dev/null 2>&1
cat >"$work/default.conf" <<EOF
server {
    listen 443 ssl;
    ssl_certificate /etc/nginx/tls.crt;
    ssl_certificate_key /etc/nginx/tls.key;
    location / {
        proxy_pass http://$name:80;
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
chmod 0644 "$work"/*
docker run -d -q --name "$name-proxy" --network "$name" -p 127.0.0.1::443 \
    -v "$work/default.conf:/etc/nginx/conf.d/default.conf:ro" \
    -v "$work/tls.crt:/etc/nginx/tls.crt:ro" -v "$work/tls.key:/etc/nginx/tls.key:ro" "$proxy_image" >/dev/null

for _ in $(seq 200); do
    port=$(docker port "$name" 80/tcp | head -1 | sed 's/.*://')
    if curl -fsS "http://127.0.0.1:$port/status.php" 2>/dev/null | jq -e '.installed == true' >/dev/null; then
        break
    fi
    sleep 3
done
curl -fsS "http://127.0.0.1:$port/status.php" | jq -e '.installed == true' >/dev/null ||
    fail "NextCloud did not finish installing within 600 seconds"
tls_port=$(docker port "$name-proxy" 443/tcp | head -1 | sed 's/.*://')
echo "PASS: first start installed NextCloud from environment variables"

# req <path> <curl args...>: one request through the proxy or straight to the port,
# picked by $via. Prints "<status> <Location>".
req() {
    local path=$1
    shift
    if [ "$via" = proxy ]; then
        curl -sk -o "$work/body" -w '%{http_code} %header{location}' --resolve "$domain:$tls_port:127.0.0.1" \
            "https://$domain:$tls_port$path" "$@"
    else
        curl -s -o "$work/body" -w '%{http_code} %header{location}' "http://127.0.0.1:$port$path" "$@"
    fi
}

expect() {
    local what=$1 got=$2 want=$3
    [ "$got" = "$want" ] || fail "$via: $what answered '$got', want '$want'"
}

for via in proxy direct; do
    if [ $via = proxy ]; then
        url=https://$domain
    else
        url=http://127.0.0.1:$port
    fi
    expect "/" "$(req /)" "302 $url/login"
    expect "/.well-known/caldav" "$(req /.well-known/caldav)" "301 $url/remote.php/dav/"
    expect "/.well-known/carddav" "$(req /.well-known/carddav)" "301 $url/remote.php/dav/"
    expect "/ for DavClnt" "$(req / -A 'Microsoft-WebDAV-MiniRedir/10.0.19045 DavClnt')" "302 $url/remote.php/webdav/"
    req /index.php/login/v2 -X POST >/dev/null
    jq -e --arg url "$url" '(.login | startswith($url + "/login/v2/flow/")) and .poll.endpoint == $url + "/login/v2/poll"' \
        "$work/body" >/dev/null || fail "$via: desktop login flow links: $(cat "$work/body")"

    rm -f "$work/jar"
    req /login -c "$work/jar" >/dev/null
    token=$(sed -n 's/.*data-requesttoken="\([^"]*\)".*/\1/p' "$work/body" | head -1)
    [ -n "$token" ] || fail "$via: the sign-in page has no request token"
    expect "sign-in" "$(req /login -b "$work/jar" -c "$work/jar" -H "Origin: $url" \
        --data-urlencode user=admin --data-urlencode "password=$password" --data-urlencode "requesttoken=$token" \
        --data-urlencode timezone=UTC --data-urlencode timezone_offset=0)" "303 $url/apps/dashboard/"
    req '/ocs/v2.php/cloud/user?format=json' -b "$work/jar" -H 'OCS-APIRequest: true' >/dev/null
    jq -e '.ocs.data.id == "admin"' "$work/body" >/dev/null || fail "$via: signed-in user: $(head -c 300 "$work/body")"
    echo "PASS: $via: redirects, discovery URLs, desktop login links and sign-in all use $url"
done

via=direct
expect "/ with X-Forwarded-Proto: http" "$(req / -H "Host: $domain" -H 'X-Forwarded-Proto: http')" "302 http://$domain/login"
echo "PASS: X-Forwarded-Proto: http keeps http links"
