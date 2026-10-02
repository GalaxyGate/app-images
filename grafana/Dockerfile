FROM grafana/grafana:13.2.3@sha256:b28bae15e219c998fb0e0424ed724930cc61b1f61fb404d47c862f9a23f9e572

# The upstream image runs as uid 472 and needs /var/lib/grafana writable.
# Docker creates a missing bind-mount source directory as root:root 755, so on
# a fresh host Grafana exits with "GF_PATHS_DATA='/var/lib/grafana' is not
# writable". The entrypoint starts as root, hands the data directory to
# 472:0, then drops to 472:0 with su-exec and runs the upstream /run.sh. It
# needs no capabilities beyond Docker's default set.
USER root
RUN apk add --no-cache su-exec
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
