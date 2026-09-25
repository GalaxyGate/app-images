#!/bin/sh
# Every nemoclaw run must see NEMOCLAW_DOCKER_HOST_GATEWAY_IP, including a
# `docker exec` shell. Without it NemoClaw regenerates the OpenShell gateway
# config without host_gateway_ip. The entrypoint records the address at start.
if [ -z "${NEMOCLAW_DOCKER_HOST_GATEWAY_IP:-}" ] && [ -r /run/nemoclaw/host-gateway-ip ]; then
  NEMOCLAW_DOCKER_HOST_GATEWAY_IP="$(cat /run/nemoclaw/host-gateway-ip)"
  export NEMOCLAW_DOCKER_HOST_GATEWAY_IP
fi
exec /usr/local/bin/nemoclaw "$@"
