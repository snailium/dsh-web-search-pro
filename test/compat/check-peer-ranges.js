#!/usr/bin/env node
// Assert that every gated peer range resolves for a given dsh version.
//
// The gate that actually decides whether a bundle loads is dsh's own:
// dsh-app-boot's `evaluatePluginCompatibility` calls semver.satisfies with
// {includePrerelease:true} and SKIPS a bundle whose dsh peers do not match,
// and dsh-plugin-manager runs the same check as a preflight before installing
// anything. That is the hard requirement, and a range failing it means the
// plugin's tools silently never register.
//
// npm's default resolver is reported as a WARNING, not a failure. npm resolves
// optional peers strictly, but dsh installs plugins with pnpm, and pnpm does
// not resolve optional peers at all -- every @deepseek-ai/dsh* peer here is
// optional, so npm's stricter view is not the gate a user hits. It is still
// worth seeing: a range that npm rejects is one that a user installing with
// npm, or with a non-optional peer, would trip over.
//
// Usage: node check-peer-ranges.js <semver-module> <plugin-package.json> <dsh-version>
import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const semver = require(process.argv[2])
const manifest = JSON.parse(readFileSync(process.argv[3], 'utf8'))
const runtime = process.argv[4]

const gated = Object.entries(manifest.peerDependencies || {})
  .filter(([name]) => name === '@deepseek-ai/dsh' || name.startsWith('@deepseek-ai/dsh-'))

let bad = 0
let warned = 0
for (const [name, range] of gated) {
  const runtimeOk = semver.satisfies(runtime, range, { includePrerelease: true })
  const installOk = semver.satisfies(runtime, range)
  if (!runtimeOk) {
    console.error(`  FAIL(runtime) ${name} "${range}" does not satisfy ${runtime} at all`)
    console.error('    dsh would skip this bundle and its tools would never register.')
    bad++
  } else if (!installOk) {
    console.warn(`  WARN(npm) ${name} "${range}" passes dsh's runtime gate but npm's default resolver rejects ${runtime}`)
    warned++
  }
}

if (bad > 0) {
  console.error(`\n  ${bad} peer(s) unusable on dsh ${runtime}.`)
  console.error('  For a prerelease host each dsh-* peer needs a range naming that line')
  console.error('  explicitly, e.g. ^0.1.7-rc.2 || >=0.2.0-rc.1 <0.2.2-0 -- a single branch whose')
  console.error('  prerelease tuple does not match is skipped by the Host at composition time.')
  process.exit(1)
}

const extra = warned > 0 ? ` (${warned} npm-only warning(s))` : ''
console.log(`  ${gated.length} dsh peer(s) resolve on ${runtime} (dsh runtime gate)${extra}`)
