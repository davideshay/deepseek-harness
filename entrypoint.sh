#!/bin/sh
set -eu

# The webserver bind is a deployment knob, but the CLI refuses --host 0.0.0.0
# (a guardrail against accidental exposure, not a capability limit). The
# webserver schema accepts a non-loopback bind, so seed it via config.
#
# VERIFY BEFORE TRUSTING: run `dsh web --dump-config` and confirm both the
# path and the list shape below. DSH_CONFIG_DIR overrides the location.
if [ -n "${DSH_WEB_HOST:-}" ]; then
  CFG_DIR="${DSH_CONFIG_DIR:-$DSH_HOME/config}"
  mkdir -p "$CFG_DIR"
  cat > "$CFG_DIR/webserver.yml" <<YAML
- id: webserver
  config:
    host: ${DSH_WEB_HOST}
    port: ${DSH_WEB_PORT:-3080}
YAML
  echo "entrypoint: wrote $CFG_DIR/webserver.yml (host=${DSH_WEB_HOST})"
fi

exec dsh "$@"
