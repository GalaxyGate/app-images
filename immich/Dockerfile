# Immich in one container: the stock immich-server image plus the machine
# learning runtime from immich-machine-learning, PostgreSQL 17 with
# VectorChord, and Valkey, supervised by s6-overlay.
#
# Upstream runs these as four containers. The panel App model runs one
# container per app, so they are bundled here. Postgres and Valkey listen on
# 127.0.0.1 only; the web port is the Immich server on IMMICH_PORT.
#
# Data lives on three mounts:
#   /data                     uploads, thumbnails, encoded video, DB backups
#   /var/lib/postgresql/data  the Postgres 17 cluster
#   /cache                    machine learning models
FROM ghcr.io/immich-app/immich-machine-learning:v3.2.4@sha256:e16c2f166a8174901959fdf85e2e4c7bd1ebc4b37e0b6655de97c41408a260c4 AS ml

FROM ghcr.io/immich-app/immich-server:v3.2.4@sha256:d317916b28090c33eb36b308464ea391f8b7df1d850fcfea227a39ec879718c2

ARG S6_OVERLAY_VERSION=3.2.3.2
ARG VCHORD_VERSION=1.1.1

# Machine learning runtime, copied the way upstream's prod-cuda stage copies
# the Python runtime. The venv's python points at /usr/local/bin/python3.
COPY --from=ml /opt/venv /opt/venv
COPY --from=ml /usr/local/bin/python3.11 /usr/local/bin/python3.11
COPY --from=ml /usr/local/lib/python3.11 /usr/local/lib/python3.11
COPY --from=ml /usr/local/lib/libpython3.11.so.1.0 /usr/local/lib/libpython3.so /usr/local/lib/
COPY --from=ml /usr/src/immich_ml /usr/src/ml/immich_ml

ADD --checksum=sha256:5379750ed30a84bbd2e2dd74847ba6b5bd29cd0b2e3ea2ec58049b57eb2eda12 \
    https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp/
ADD --checksum=sha256:e6befcc96a437a3831386ecfc51808c5d3e939dc5fe3c02ae9284599e8aa2408 \
    https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-x86_64.tar.xz /tmp/
ADD --checksum=sha256:a48132c8d616c0d52a9811b32f12f88a8f6cc8542d7cc0180c8d0986bfbd03c5 \
    https://github.com/tensorchord/VectorChord/releases/download/${VCHORD_VERSION}/postgresql-17-vchord_${VCHORD_VERSION}-1_amd64.deb /tmp/

# Postgres gets a fixed uid and gid so ownership of the database folder stays
# the same across image rebuilds. The server image already carries the PGDG
# apt source but has ca-certificates removed, so apt cannot reach PGDG over
# HTTPS until ca-certificates is back.
RUN set -eux; \
    ln -s python3.11 /usr/local/bin/python3; \
    ln -s libpython3.11.so.1.0 /usr/local/lib/libpython3.11.so; \
    ldconfig; \
    groupadd -r -g 999 postgres; \
    useradd -r -g postgres -u 999 -d /var/lib/postgresql -s /bin/bash postgres; \
    export DEBIAN_FRONTEND=noninteractive; \
    mv /etc/apt/sources.list.d/pgdg.list /tmp/pgdg.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates; \
    mv /tmp/pgdg.list /etc/apt/sources.list.d/pgdg.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends postgresql-common xz-utils; \
    sed -ri 's/#?\s*create_main_cluster\s*=.*/create_main_cluster = false/' /etc/postgresql-common/createcluster.conf; \
    apt-get install -y --no-install-recommends \
        postgresql-17 postgresql-17-pgvector /tmp/postgresql-17-vchord_${VCHORD_VERSION}-1_amd64.deb \
        valkey-server libgl1 libglib2.0-0 libgomp1; \
    tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz; \
    tar -C / -Jxpf /tmp/s6-overlay-x86_64.tar.xz; \
    rm -rf /tmp/*.tar.xz /tmp/*.deb /var/lib/apt/lists/*; \
    test ! -d /var/lib/postgresql/17/main; \
    PYTHONPATH=/usr/src/ml /opt/venv/bin/python -c 'import onnxruntime, cv2, immich_ml.config'; \
    /usr/lib/postgresql/17/bin/postgres --version; \
    valkey-server --version

COPY rootfs/ /

RUN find /etc/s6-overlay/s6-rc.d \( -name run -o -name finish \) -exec chmod 0755 {} +

ENV IMMICH_MACHINE_LEARNING_URL=http://127.0.0.1:3003 \
    DB_HOSTNAME=127.0.0.1 \
    DB_PORT=5432 \
    DB_USERNAME=postgres \
    DB_DATABASE_NAME=immich \
    REDIS_HOSTNAME=127.0.0.1 \
    REDIS_PORT=6379 \
    MACHINE_LEARNING_CACHE_FOLDER=/cache \
    TRANSFORMERS_CACHE=/cache \
    HF_HOME=/cache/hf-cache \
    IMMICH_THIRD_PARTY_SOURCE_URL=https://github.com/GalaxyGate/app-images \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_SERVICES_GRACETIME=7000 \
    S6_KILL_GRACETIME=2000

VOLUME ["/var/lib/postgresql/data", "/cache"]

# The upstream HEALTHCHECK (immich-healthcheck, reads IMMICH_PORT) is kept.
ENTRYPOINT ["/init"]
CMD []
