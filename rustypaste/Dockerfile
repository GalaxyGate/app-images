FROM orhunp/rustypaste:0.18.1@sha256:5c1692cc1fa2c9722f39d46e54455ab8f71ec86f5da9639769f8bd92fc6b882a AS upstream

# The upstream image is FROM scratch and runs as uid 1000. Docker creates a
# missing bind-mount source directory as root:root, and uid 1000 cannot write
# to it, so the app exits with "Permission denied" on a fresh host. Alpine
# gives a shell for an entrypoint that hands the upload directory to uid 1000
# and then drops root with su-exec. It needs no capabilities beyond Docker's
# default set.
FROM alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
RUN apk add --no-cache su-exec
WORKDIR /app
COPY --from=upstream /app/rustypaste /app/rustypaste
COPY config.toml /app/config.toml
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
RUN install -d -o 1000 -g 1000 /app/upload
ENV SERVER__ADDRESS=0.0.0.0:8000
EXPOSE 8000
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["./rustypaste"]
