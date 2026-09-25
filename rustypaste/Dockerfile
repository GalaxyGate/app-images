FROM orhunp/rustypaste:0.16.1@sha256:b98098ac5053ec1b76c9f7b5afece9117d165c6e3eec8441e1564795ce62f811

# Image runs as uid 1000; set ownership on copied files so the process can write uploads.
COPY --chown=1000:1000 config.toml /app/config.toml

# Scratch-based image has no shell; create the upload dir by copying a placeholder.
# At runtime, mount /app/upload to a host volume for persistence.
COPY --chown=1000:1000 upload/ /app/upload/
