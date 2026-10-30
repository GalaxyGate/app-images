FROM ghcr.io/openclaw/openclaw:2026.9.33@sha256:ced9bfaf2514f9ec6bb217261614907662322837667513328d8bc90222c41e0c

# The gateway exits with code 78 until its config sets gateway.mode to local,
# and it listens on the container's loopback until gateway.bind is lan.
# Upstream's Docker setup writes both with `config set` before the first start,
# plus the browser origin of the Control UI, which it inherits from
# gateway.publicOrigin when that is set. A panel template can only pass
# environment variables, so entrypoint.sh writes the same three settings on a
# volume with no config yet, taking the origin from OPENCLAW_PUBLIC_ORIGIN. It
# leaves an existing config alone and then runs upstream's entrypoint, which
# runs doctor before the gateway. test.sh checks that ENTRYPOINT ends with the
# base image's own ENTRYPOINT. The paths and port are the ones upstream's
# docker-compose.yml pins.
ENV OPENCLAW_STATE_DIR=/home/node/.openclaw \
    OPENCLAW_CONFIG_PATH=/home/node/.openclaw/openclaw.json \
    OPENCLAW_WORKSPACE_DIR=/home/node/.openclaw/workspace \
    OPENCLAW_GATEWAY_PORT=18789
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh", "tini", "-s", "--", "node", "/app/docker-entrypoint.mjs"]
CMD ["node", "openclaw.mjs", "gateway"]
