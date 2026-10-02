FROM docker.io/netboxcommunity/netbox:v4.7.2-5.1.1@sha256:6f7177d3ff4db2d65212420a4d8dffab22e15de0d767c2bf3b06d36e588df5e9

ARG S6_OVERLAY_VERSION=3.2.3.2

# PostgreSQL 18 and Valkey from the Ubuntu 26.04 archive. The packaged default
# cluster is turned off because the image creates its own cluster under /data.
RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update -qq \
    && apt-get install --yes -qq --no-install-recommends postgresql-common \
    && sed -ri 's/^#?[[:space:]]*create_main_cluster.*/create_main_cluster = false/' \
        /etc/postgresql-common/createcluster.conf \
    && apt-get install --yes -qq --no-install-recommends \
        postgresql-18 valkey-server xz-utils util-linux \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/s6-overlay-noarch.tar.xz \
        "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz" \
    && curl -fsSL -o /tmp/s6-overlay-x86_64.tar.xz \
        "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-x86_64.tar.xz" \
    && echo "5379750ed30a84bbd2e2dd74847ba6b5bd29cd0b2e3ea2ec58049b57eb2eda12  /tmp/s6-overlay-noarch.tar.xz" | sha256sum -c - \
    && echo "e6befcc96a437a3831386ecfc51808c5d3e939dc5fe3c02ae9284599e8aa2408  /tmp/s6-overlay-x86_64.tar.xz" | sha256sum -c - \
    && tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz \
    && tar -C / -Jxpf /tmp/s6-overlay-x86_64.tar.xz \
    && rm /tmp/s6-overlay-*.tar.xz

COPY rootfs/ /

# rootfs also replaces netbox-docker's granian.py with a copy that marks
# /media/ responses Cache-Control: private.
RUN chmod 0755 /etc/s6-overlay/scripts/* /etc/s6-overlay/s6-rc.d/*/run \
    && chmod 0644 /etc/galaxygate/* /etc/netbox/config/zz-galaxygate.py \
        /opt/netbox/netbox/netbox/granian.py

# One container runs PostgreSQL, Valkey, the Granian web server and the RQ
# worker under s6. NetBox reaches PostgreSQL over its Unix socket with peer
# auth and Valkey on 127.0.0.1. Everything persistent lives under /data.
# DB_WAIT_DEBUG prints the whole startup error, such as a short SECRET_KEY,
# instead of only its last line.
ENV PATH=/command:/opt/netbox/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    S6_VERBOSITY=1 \
    DB_WAIT_DEBUG=1 \
    DB_HOST=/run/postgresql \
    DB_NAME=netbox \
    DB_USER=netbox \
    REDIS_HOST=127.0.0.1 \
    REDIS_PORT=6379 \
    REDIS_DATABASE=0 \
    REDIS_CACHE_HOST=127.0.0.1 \
    REDIS_CACHE_PORT=6379 \
    REDIS_CACHE_DATABASE=1 \
    MEDIA_ROOT=/data/media \
    GRANIAN_PORT=22180 \
    GRANIAN_WORKERS=2

EXPOSE 22180

HEALTHCHECK --start-period=600s --interval=30s --timeout=5s CMD ["/opt/netbox/health.sh"]

ENTRYPOINT ["/init"]
CMD []
