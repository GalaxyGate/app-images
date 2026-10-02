# Supabase controller: upstream's self-hosted Docker Compose stack, run through
# the server's Docker socket. Supabase publishes no all-in-one image; its only
# supported self-hosted form is the docker/ folder of supabase/supabase, a
# compose project of 11 official images. This image carries that folder at the
# self-hosted release tag, unchanged, plus the Docker CLI and compose plugin.
#
# At start the controller runs the stack as sibling containers and relays the
# API gateway and the two pooler ports to its own container ports. When the
# app stops it removes every container it started.
FROM debian:bookworm-20260918-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251 AS upstream

ARG SUPABASE_TAG=self-hosted/v0.8.2
ARG SUPABASE_COMMIT=564eab8ad7840b13324f68b1bfac074ef8d51c21

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates git; \
    git clone --depth 1 --filter=blob:none --sparse --branch "${SUPABASE_TAG}" \
      https://github.com/supabase/supabase.git /src; \
    cd /src; \
    test "$(git rev-parse HEAD)" = "${SUPABASE_COMMIT}"; \
    git sparse-checkout set docker; \
    printf '%s %s\n' "${SUPABASE_TAG}" "${SUPABASE_COMMIT}" > /src/docker/.galaxygate-upstream

# Node.js runs upstream's key scripts. Debian's nodejs 18 can deadlock in
# add-new-auth-keys.sh: a garbage collection during the JWK export of the
# generated EC key destroys the key generation job, whose destructor locks the
# key mutex the export already holds. Node 24 removed that lock (nodejs/node
# c21d576579), so the official Node 24 LTS binary is used instead.
FROM node:24.21.0-bookworm-slim@sha256:0e0ff40c39bc087845bfb27465a0df4ea419520094bc35842ff83dd8cbe6f9b6 AS node

FROM debian:bookworm-20260918-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251

ARG DOCKER_CLI_VERSION=5:29.8.1-1~debian.12~bookworm
ARG DOCKER_COMPOSE_VERSION=5.5.1-1~debian.12~bookworm
ARG DOCKER_APT_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88

COPY --from=node /usr/local/bin/node /usr/local/bin/node

# openssl and node run upstream's utils/generate-keys.sh and
# utils/add-new-auth-keys.sh; socat relays the container ports into the stack.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gpg; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc; \
    gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc | grep -q "^fpr:::::::::${DOCKER_APT_KEY_FPR}:"; \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      "docker-ce-cli=${DOCKER_CLI_VERSION}" "docker-compose-plugin=${DOCKER_COMPOSE_VERSION}" \
      openssl socat procps; \
    apt-get purge -y gpg; \
    apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*; \
    docker compose version; \
    node --version

COPY --from=upstream /src/docker /opt/supabase/docker
COPY --chmod=0755 entrypoint.sh /usr/local/bin/galaxygate-supabase

# /data/supabase must be mounted at the same path on the server: compose
# resolves the stack's ./volumes bind sources here, and the server's Docker
# daemon mounts the same absolute paths into the stack containers.
WORKDIR /data/supabase
EXPOSE 22800 22432 22543
ENTRYPOINT ["/usr/local/bin/galaxygate-supabase"]
