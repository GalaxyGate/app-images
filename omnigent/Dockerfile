FROM node:22-slim@sha256:43ac6c60b8f89723f746e8a92ce91abd5017e627ce1ddfe4238355d3a30b772c AS node

FROM ghcr.io/omnigent-ai/omnigent-server:v0.16.0@sha256:e486e80a6a0428f740af4f36ea36b86e9c8dfc84dfa2aab1cdd0de60d74ce94c

# The upstream server image runs in external-runner mode and needs Postgres, so
# it serves the web UI but never runs a turn. This image runs the server on
# SQLite plus the bundled host in one container, and adds the host tools from
# upstream's `host` build stage: git, tmux, Node with the Claude Code and Codex
# CLIs, gh, and the GIT_TOKEN credential helper. The kiro-cli and agy binaries
# from that stage are left out. Bubblewrap is left out because an app container
# cannot create namespaces; agents run with `os_env.sandbox.type: none`.

ARG CLAUDE_CODE_VERSION=2.1.287
ARG CODEX_VERSION=0.160.0
ARG GH_VERSION=2.100.0
ARG GH_SHA256_AMD64=e4d4bb4498e8d007abe545b6568926793ace1b6447da598294a610018cb164be

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git tmux procps lsof curl ca-certificates unzip tini \
 && rm -rf /var/lib/apt/lists/*

RUN git config --system credential.helper \
      '!f() { [ "$1" = get ] || return 0; [ -n "$GIT_TOKEN" ] || return 0; printf "username=%s\npassword=%s\n" "${GIT_USERNAME:-x-access-token}" "$GIT_TOKEN"; }; f'

COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
 && npm install -g --no-audit --no-fund \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
      "@openai/codex@${CODEX_VERSION}" \
 && npm cache clean --force \
 && claude --version && codex --version

RUN set -eu; \
    asset="gh_${GH_VERSION}_linux_amd64.tar.gz"; \
    curl -fsSL -o /tmp/gh.tar.gz "https://github.com/cli/cli/releases/download/v${GH_VERSION}/${asset}"; \
    echo "${GH_SHA256_AMD64}  /tmp/gh.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/gh.tar.gz -C /tmp "gh_${GH_VERSION}_linux_amd64/bin/gh"; \
    install -m 0755 "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh; \
    rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_VERSION}_linux_amd64"; \
    gh --version

# Login shells reset PATH; put the venv back in front, as upstream's host stage does.
RUN echo 'export PATH="/opt/venv/bin:${PATH}"' > /etc/profile.d/omnigent-venv.sh

COPY --chmod=0755 entrypoint.sh /usr/local/bin/omnigent-app

# HOME is the data volume, so Omnigent's ~/.omnigent and the Claude Code and
# Codex sign-ins persist. IS_SANDBOX lets Claude Code run as root, as in
# upstream's host stage. Upgrades come from a new image tag.
ENV HOME=/data \
    PORT=22067 \
    IS_SANDBOX=1 \
    OMNIGENT_AUTH_ENABLED=1 \
    OMNIGENT_NO_UPDATE_CHECK=1

WORKDIR /data
EXPOSE 22067

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/omnigent-app"]
