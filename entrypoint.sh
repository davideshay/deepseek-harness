#!/bin/sh
set -eu

# dsh refuses to boot if $DSH_HOME/.credentials.yaml is readable beyond its
# owner (mode 660 is fatal). fsGroup: 1000 in the manifest is required for
# uid 1000 to write a fresh Longhorn volume, but it makes new files
# group-owned -- so tighten the umask before dsh creates anything, and repair
# the file if it already exists.
umask 077

# Fresh volume: seed the baked-in model/endpoint defaults exactly once.
# Once the file exists, the user's (or the Models UI's) copy is
# authoritative — dsh-settings-file hot-reloads it.
if [ ! -f "$DSH_HOME/settings.yaml" ] && [ -f /usr/local/share/dsh/settings.defaults.yaml ]; then
  cp /usr/local/share/dsh/settings.defaults.yaml "$DSH_HOME/settings.yaml"
  echo "entrypoint: seeded settings.yaml from baked-in defaults"
fi

# If the PVC subPath is mounted at $HOME, it hides the image's dotfiles;
# restore them only where missing. Harmless no-op when $HOME is not a
# mount (the files already exist).
if [ -d /etc/skel ]; then
  cp -Rn /etc/skel/. "$HOME/" 2>/dev/null || true
fi


if [ -f "${DSH_HOME}/.credentials.yaml" ]; then
  chmod 600 "${DSH_HOME}/.credentials.yaml"
fi

# The webserver bind cannot be set the obvious ways:
#   - the CLI hard-rejects --host 0.0.0.0 (a guard, not a schema limit), and
#   - the schema is a literal union of "127.0.0.1" | "0.0.0.0", so a specific
#     pod IP is not a legal value either.
# The profile patch layer is applied AFTER every bundle layer, so setting the
# bind there beats the bundle's `!!js ctx.webStartup.host` expression.
#
# Two traps, both verified the hard way:
#   - the merge is SHALLOW at the config level: overriding `host` alone
#     deletes `port` entirely, so both keys must be present.
#   - the file scaffolds as `[]`; appending a block sequence to that is a
#     YAML syntax error, so the whole file must be written.
#
# Written unconditionally (no grep guard) so a stale value from a previous
# deploy can never survive.
PATCH="${DSH_CONFIG_PATCH:-$DSH_HOME/profiles/web/cordis.patch.yml}"

if [ -n "${DSH_WEB_HOST:-}" ]; then
  mkdir -p "$(dirname "$PATCH")"
  cat > "$PATCH" <<YAML
# Managed by the container entrypoint. Applied after every bundle layer.
- id: webserver
  config:
    host: ${DSH_WEB_HOST}
    port: ${DSH_WEB_PORT:-3080}
YAML
  echo "entrypoint: webserver bind -> $PATCH (host=${DSH_WEB_HOST} port=${DSH_WEB_PORT:-3080})"
fi

# Earlier revisions wrote this path; it is inert, the patch layer wins.
rm -f "$DSH_HOME/config/webserver.yml"

exec dsh "$@"
