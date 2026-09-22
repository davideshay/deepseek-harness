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

# ---------------------------------------------------------------------------
# Upstream #5829: the settings client picks persistence with
#     ctx.remote.$host.isLoopback ? 'host' : 'memory'
# and 'memory' short-circuits the settings mirror (load() returns without a
# wire read), so every non-loopback browser loses Settings -> Models with
# "Loading the provider directory failed: settings are unavailable in this
# browser". Intended for deployments where the network and the gateway do the
# authentication, which is exactly what this image is.
#
# The fix is a build-time rewrite of the ternary, not a config field: the
# field was proposed and endorsed upstream but has not shipped.
#
# The pattern is deliberately narrow -- it matches the *string literal pair*
# rather than `isLoopback`. Property names survive minification, variable
# names do not, and the "host"/"memory" literals are the only thing that
# identifies this specific decision. That also means it cannot touch the
# /api trust fence, which keys on isLoopbackHostname() and returns booleans.
#
# It exits non-zero when the pattern is absent, so a dsh upgrade that changes
# or fixes this code breaks the build instead of silently shipping a regression.
RUN <<'NODEJS' node /tmp/patch-ui-settings.mjs
import { readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const ROOT = '/usr/local/lib/node_modules'
const RX = /\?\s*(['"])host\1\s*:\s*\1memory\1/g

const files = []
const walk = (dir) => {
  let entries
  try { entries = readdirSync(dir, { withFileTypes: true }) } catch { return }
  for (const e of entries) {
    const p = join(dir, e.name)
    if (e.isDirectory()) walk(p)
    else if (/\.(?:js|mjs|cjs)$/u.test(e.name)) files.push(p)
  }
}
walk(ROOT)

let patched = 0
for (const file of files) {
  const src = readFileSync(file, 'utf8')
  const hits = src.match(RX)
  if (hits === null) continue
  writeFileSync(file, src.replace(RX, (_m, q) => `? ${q}host${q} : ${q}host${q}`))
  patched += hits.length
  console.log(`patch-ui-settings: ${hits.length} occurrence(s) in ${file}`)
}

if (patched === 0) {
  console.error(`patch-ui-settings: FATAL -- no "host" : "memory" ternary found in ${files.length} file(s).`)
  console.error('This code changed upstream. Either the fix shipped as a config field (check the')
  console.error('dsh-client-ui-settings config schema) or the patch needs a new pattern. Do not')
  console.error('remove this step: without it, remote browsers silently lose the Settings surface.')
  process.exit(1)
}
console.log(`patch-ui-settings: ${patched} occurrence(s) patched`)
NODEJS

# Prove the rewrite landed, and that the trust fence is untouched.
RUN grep -rl 'isLoopback' /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-client-connection/ \
    && echo "trust fence: intact" \
 && grep -rn '? "host" : "memory"\|? .host. : .memory.' /usr/local/lib/node_modules 2>/dev/null; \
    test $? -eq 1 && echo "no residual memory-mode ternaries"

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
