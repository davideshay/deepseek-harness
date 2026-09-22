// Upstream #5829: the settings client picks persistence with
//     ctx.remote.$host.isLoopback ? 'host' : 'memory'
// and 'memory' short-circuits the settings mirror (load() returns without a
// wire read), so every non-loopback browser loses Settings -> Models with
// "Loading the provider directory failed: settings are unavailable in this
// browser". Intended for deployments where the network and the gateway do the
// authentication -- which is what this image is.
//
// The pattern matches the *string literal pair* rather than the identifier
// `isLoopback`: property names survive minification, variable names do not,
// and the 'host'/'memory' literals are the only thing that identifies this
// specific decision. It also means the patch cannot touch the /api trust
// fence, which keys on isLoopbackHostname() and returns booleans.
//
// `--check` is a read-only verification pass: it fails the build if a
// 'host' : 'memory' ternary is still present.
import { readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const ROOT = '/usr/local/lib/node_modules'
const CHECK = process.argv.includes('--check')
const PATCH_RX = /\?\s*(['"])host\1\s*:\s*\1memory\1/g
const RESIDUAL_RX = /\?\s*(['"])host\1\s*:\s*(['"])memory\2/g

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
let residual = 0

for (const file of files) {
  const src = readFileSync(file, 'utf8')
  if (CHECK) {
    const hits = src.match(RESIDUAL_RX)
    if (hits !== null) { residual += hits.length; console.error(`residual: ${file}`) }
    continue
  }
  const hits = src.match(PATCH_RX)
  if (hits === null) continue
  writeFileSync(file, src.replace(PATCH_RX, (_m, q) => `? ${q}host${q} : ${q}host${q}`))
  patched += hits.length
  console.log(`patch-ui-settings: ${hits.length} occurrence(s) in ${file}`)
}

if (CHECK) {
  if (residual > 0) { console.error(`patch-ui-settings: CHECK FAILED -- ${residual} unpatched ternary(ies)`); process.exit(1) }
  console.log(`patch-ui-settings: CHECK OK -- no residual memory-mode ternaries in ${files.length} file(s)`)
  process.exit(0)
}

if (patched === 0) {
  console.error(`patch-ui-settings: FATAL -- no "host" : "memory" ternary found in ${files.length} file(s).`)
  console.error('This code changed upstream. Either the fix shipped as a config field (check the')
  console.error('dsh-client-ui-settings config schema) or the pattern needs updating. Do not')
  console.error('remove this step: without it, remote browsers silently lose the Settings surface.')
  process.exit(1)
}
console.log(`patch-ui-settings: ${patched} occurrence(s) patched`)