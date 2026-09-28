FROM nousresearch/hermes-agent:v2026.9.24@sha256:fca358f12efd65bfaaca05884166f15c0e2788375ca30d77061ac1ebc96452b7

ARG HERMES_WEBUI_TAG=exp-v0.52.379
ARG HERMES_WEBUI_COMMIT=ff26335b87610f70d74ff008608a321fb1281bd1

RUN curl -fsSL "https://github.com/nesquena/hermes-webui/archive/${HERMES_WEBUI_COMMIT}.tar.gz" \
        -o /tmp/hermes-webui.tar.gz \
    && mkdir -p /opt/hermes-webui \
    && tar -xzf /tmp/hermes-webui.tar.gz --strip-components=1 -C /opt/hermes-webui \
    && rm /tmp/hermes-webui.tar.gz \
    && printf "__version__ = '%s'\n" "${HERMES_WEBUI_TAG}" > /opt/hermes-webui/api/_version.py \
    && uv pip install --python /opt/hermes/.venv/bin/python --no-cache \
        -r /opt/hermes-webui/requirements.txt

COPY s6-hermes-webui-run /etc/s6-overlay/s6-rc.d/hermes-webui/run
COPY s6-hermes-webui-finish /etc/s6-overlay/s6-rc.d/hermes-webui/finish

RUN printf 'longrun\n' > /etc/s6-overlay/s6-rc.d/hermes-webui/type \
    && mkdir -p /etc/s6-overlay/s6-rc.d/hermes-webui/dependencies.d \
    && touch /etc/s6-overlay/s6-rc.d/hermes-webui/dependencies.d/base \
    && touch /etc/s6-overlay/s6-rc.d/user/contents.d/hermes-webui \
    && chmod 0755 /etc/s6-overlay/s6-rc.d/hermes-webui/run \
        /etc/s6-overlay/s6-rc.d/hermes-webui/finish

EXPOSE 22042

# Upstream ships an empty CMD, so the container runs the interactive `hermes`
# chat, which exits 0 with no TTY. The panel App model has no command field,
# so bake the documented container command. Inside the s6 image it starts the
# supervised gateway, dashboard, and Hermes WebUI services.
CMD ["gateway", "run"]
