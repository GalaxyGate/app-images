#!/bin/sh
set -e

if [ "$(id -u)" = "0" ]; then
    mkdir -p /app/upload
    find /app/upload \! -user 1000 -exec chown -h 1000:1000 {} +
    exec su-exec 1000:1000 "$@"
fi

exec "$@"
