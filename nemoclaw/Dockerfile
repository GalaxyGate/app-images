# NemoClaw controller: the NemoClaw CLI plus the OpenShell gateway it pins.
# NVIDIA publishes no image for the NemoClaw CLI (the ghcr.io/nvidia/nemoclaw
# images are sandbox images), so this builds NemoClaw from its release tag.
#
# It runs as a controller. Through the server's Docker socket it starts the
# OpenShell sandbox that holds OpenClaw as a sibling container, and removes it
# again when this container stops.
#
# One GalaxyGate patch is applied at build time: host-gateway-ip.patch. It lets
# NEMOCLAW_DOCKER_HOST_GATEWAY_IP set OpenShell's host_gateway_ip, so the
# gateway, which runs inside this bridged container, binds its sandbox
# callback listener on an address this container owns.
FROM node:22.23.3-bookworm@sha256:363e1587494626837fa7f9a23bdb453d13b0ff3c67c705c2805cfc69c2d2fad7

ARG NEMOCLAW_TAG=v0.0.129
ARG NEMOCLAW_COMMIT=26922313bba96184e65c3663b351683ebae9504d
ARG OPENSHELL_VERSION=0.0.116
ARG DOCKER_CLI_VERSION=5:29.8.1-1~debian.12~bookworm
ARG DOCKER_BUILDX_VERSION=0.37.1-1~debian.12~bookworm
ARG DOCKER_APT_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88

# Docker CLI and buildx: NemoClaw builds the sandbox image with BuildKit.
RUN set -eux; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc; \
    gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc | grep -q "^fpr:::::::::${DOCKER_APT_KEY_FPR}:"; \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      "docker-ce-cli=${DOCKER_CLI_VERSION}" "docker-buildx-plugin=${DOCKER_BUILDX_VERSION}" \
      iproute2 lsof procps; \
    rm -rf /var/lib/apt/lists/*

# OpenShell release binaries, checksums from the v0.0.116 release assets.
RUN set -eux; \
    base="https://github.com/NVIDIA/OpenShell/releases/download/v${OPENSHELL_VERSION}"; \
    cd /tmp; \
    for f in openshell-x86_64-unknown-linux-musl openshell-gateway-x86_64-unknown-linux-gnu openshell-sandbox-x86_64-unknown-linux-musl; do \
      curl -fsSLO "${base}/${f}.tar.gz"; \
    done; \
    printf '%s\n' \
      "4fb4476d80a1875a0b83547ec3aba999cf0a2e2d75f95f2f709b622e2103520e  openshell-x86_64-unknown-linux-musl.tar.gz" \
      "59c6da724eae7a00c28826f9191efbdf4fbaa5c768afdc8dea6a80a949ebcc89  openshell-gateway-x86_64-unknown-linux-gnu.tar.gz" \
      "0bb160f73e5007338b94e3c868f66f50c71cd65c27c932ed9a4fa67c49e6d423  openshell-sandbox-x86_64-unknown-linux-musl.tar.gz" \
      | sha256sum -c -; \
    for f in /tmp/openshell-*.tar.gz; do tar -xzf "$f" -C /usr/local/bin; done; \
    rm -f /tmp/openshell-*.tar.gz; \
    openshell --version

# NemoClaw from source, the same steps its installer runs for a source checkout.
COPY host-gateway-ip.patch /opt/nemoclaw-patches/host-gateway-ip.patch
WORKDIR /opt/nemoclaw
RUN set -eux; \
    export NEMOCLAW_INSTALLING=1; \
    git clone --depth 1 --branch "${NEMOCLAW_TAG}" https://github.com/NVIDIA/NemoClaw.git /opt/nemoclaw; \
    test "$(git rev-parse HEAD)" = "${NEMOCLAW_COMMIT}"; \
    git apply /opt/nemoclaw-patches/host-gateway-ip.patch; \
    printf '%s' "${NEMOCLAW_TAG#v}" > .version; \
    node scripts/lib/openshell-sdk-install.mts prepare; \
    npm install --ignore-scripts --prefer-offline --include=optional --@nvidia:registry=https://npm.pkg.github.com; \
    node scripts/lib/openshell-sdk-install.mts check; \
    npm run --if-present build:cli; \
    (cd nemoclaw && npm ci --ignore-scripts && npm run build); \
    npm link --ignore-scripts; \
    npm cache clean --force; \
    nemoclaw --version

COPY --chmod=0755 nemoclaw-cli.sh /usr/local/sbin/nemoclaw
COPY --chmod=0755 entrypoint.sh /usr/local/bin/galaxygate-nemoclaw

# /data/nemoclaw must be mounted at the same path on the server: the server's
# Docker daemon bind-mounts the sandbox supervisor binary and the gateway's TLS
# and JWT files from there into the sandbox.
ENV HOME=/data/nemoclaw/home \
    NEMOCLAW_SANDBOX_NAME=my-assistant \
    NEMOCLAW_AGENT=openclaw \
    NEMOCLAW_GATEWAY_PORT=22043 \
    NEMOCLAW_DASHBOARD_BIND=0.0.0.0 \
    NEMOCLAW_OPENSHELL_SANDBOX_BIN=/data/nemoclaw/bin/openshell-sandbox
WORKDIR /data/nemoclaw
EXPOSE 18789
ENTRYPOINT ["/usr/local/bin/galaxygate-nemoclaw"]
