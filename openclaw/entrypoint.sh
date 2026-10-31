#!/bin/sh
set -eu

trusted=$(printf '%s' "${OPENCLAW_TRUSTED_PROXIES:-}" | tr -d ' ')
case $trusted in
    *[!0-9A-Fa-f.:/,]*)
        echo "OPENCLAW_TRUSTED_PROXIES must be IP addresses or CIDR ranges separated by commas" >&2
        exit 78
        ;;
esac
proxies=
for proxy in $(printf '%s' "$trusted" | tr ',' ' '); do
    proxies="$proxies${proxies:+,}\"$proxy\""
done

if [ ! -e "$OPENCLAW_CONFIG_PATH" ]; then
    case ${OPENCLAW_PUBLIC_ORIGIN:-} in
        '' | *[!A-Za-z0-9.:/-]*)
            echo "Set OPENCLAW_PUBLIC_ORIGIN to the app's address, for example https://my-openclaw.galaxygate.app" >&2
            exit 78
            ;;
    esac
    settings="{\"path\":\"gateway.mode\",\"value\":\"local\"},{\"path\":\"gateway.bind\",\"value\":\"lan\"},{\"path\":\"gateway.publicOrigin\",\"value\":\"$OPENCLAW_PUBLIC_ORIGIN\"}"
    if [ -n "$proxies" ]; then
        settings="$settings,{\"path\":\"gateway.trustedProxies\",\"value\":[$proxies]}"
    fi
    node /app/dist/index.js config set --batch-json "[$settings]"
elif [ -n "$proxies" ]; then
    node /app/dist/index.js config set --batch-json "[{\"path\":\"gateway.trustedProxies\",\"value\":[$proxies]}]"
fi

exec "$@"
