#!/bin/sh
set -e

if [ "$(id -u)" = "0" ]; then
    mkdir -p "$GF_PATHS_DATA"
    find "$GF_PATHS_DATA" \! -user 472 -exec chown -h 472:0 {} +
    exec su-exec 472:0 /run.sh "$@"
fi

exec /run.sh "$@"
