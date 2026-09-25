FROM nousresearch/hermes-agent:v2026.9.24@sha256:fca358f12efd65bfaaca05884166f15c0e2788375ca30d77061ac1ebc96452b7

# Upstream ships an empty CMD, so the container runs the interactive `hermes`
# chat, which exits 1 with no TTY. The panel App model has no command field,
# so bake the documented container command. Inside the s6 image it starts the
# supervised gateway (and the dashboard when HERMES_DASHBOARD=1).
CMD ["gateway", "run"]
