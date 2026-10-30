#!/bin/sh
set -eu

if [ ! -e "$OPENCLAW_CONFIG_PATH" ]; then
    case ${OPENCLAW_PUBLIC_ORIGIN:-} in
        '' | *[!A-Za-z0-9.:/-]*)
            echo "Set OPENCLAW_PUBLIC_ORIGIN to the app's address, for example https://my-openclaw.galaxygate.app" >&2
            exit 78
            ;;
    esac
    node /app/dist/index.js config set --batch-json \
        "[{\"path\":\"gateway.mode\",\"value\":\"local\"},{\"path\":\"gateway.bind\",\"value\":\"lan\"},{\"path\":\"gateway.publicOrigin\",\"value\":\"$OPENCLAW_PUBLIC_ORIGIN\"}]"
fi

exec "$@"
