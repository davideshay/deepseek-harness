# syntax=docker/dockerfile:1
FROM node:24-slim

# Developer preview with promised breaking changes -- pin deliberately.
# `latest` is only a bring-up default; replace with the version you verified.
ARG DSH_VERSION=latest

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g "@deepseek-ai/dsh@${DSH_VERSION}" \
 && npm cache clean --force \
 && dsh --version

# Preserve the base image's home dotfiles so the /home/node mount can
# restore them onto a fresh volume (the mount hides the image's /home/node).
RUN cp -a /home/node/. /etc/skel/

# Bake in the model/endpoint defaults so a fresh volume needs no UI
# reconfiguration. The API key is not in the image — it lives in
# $DSH_HOME/.credentials.yaml (Models page) or, if you prefer, as an
# env var from a Secret (see dsh.yaml.diff).
COPY --chmod=644 settings.defaults.yaml /usr/local/share/dsh/settings.defaults.yaml

# Upstream #5829 workaround: see patch-ui-settings.mjs for the rationale.
# Fails the build if the pattern is absent, so a dsh upgrade that changes or
# fixes this code breaks the build instead of silently shipping a regression.
COPY --chmod=644 patch-ui-settings.mjs /tmp/patch-ui-settings.mjs
RUN node /tmp/patch-ui-settings.mjs \
 && node /tmp/patch-ui-settings.mjs --check \
 && rm /tmp/patch-ui-settings.mjs
 
# Entrypoint seeds the webserver bind from env. The dsh CLI rejects
# --host 0.0.0.0 on purpose; the webserver *schema* accepts it, so the bind
# is applied through config instead of a flag.
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

# $DSH_HOME is the state root: settings, .credentials.yaml (holds the session
# signing key), profile dirs, skills. The Longhorn PVC mounts here.
ENV DSH_HOME=/data \
    HOME=/home/node

# dsh uses its invoking directory as the default workspace root.
WORKDIR /workspace

RUN mkdir -p /data /workspace && chown -R node:node /data /workspace
USER node

EXPOSE 3080

# No /healthz exists and the app root 401s without a session cookie, so
# "the socket is answering" is the correct signal. curl exits 0 on 401.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s \
  CMD curl -s -o /dev/null http://127.0.0.1:3080/ || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["web", "--no-open"]
