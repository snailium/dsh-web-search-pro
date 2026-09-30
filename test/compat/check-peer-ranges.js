#!/usr/bin/env node
// Assert that every gated peer range resolves for a given dsh version under BOTH
// resolvers that matter:
//
//   runtime — dsh's own gate calls semver.satisfies(runtime, range, {includePrerelease:true})
//   install — npm/pnpm resolve peers with DEFAULT semver
//
// A range can satisfy the first and still fail the second, and only the second
// stops `dsh plugin add` on a user's machine. By semver's prerelease rule a
// prerelease version only matches a comparator set carrying the same
// [major,minor,patch] tuple WITH a prerelease, so a single-branch range such as
// ">=0.1.7-rc.2 <0.3.0" is admitted by the runtime gate yet rejected by npm.
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
for (const [name, range] of gated) {
  const runtimeOk = semver.satisfies(runtime, range, { includePrerelease: true })
  const installOk = semver.satisfies(runtime, range)
  if (!runtimeOk) {
    console.error(`  FAIL(runtime) ${name} "${range}" does not satisfy ${runtime} at all`)
    bad++
  } else if (!installOk) {
    console.error(`  FAIL(install) ${name} "${range}" passes the dsh runtime gate but npm will reject it`)
    bad++
  }
}

if (bad > 0) {
  console.error(`\n  ${bad} peer(s) unusable on dsh ${runtime}.`)
  console.error('  For a prerelease host each dsh-* peer needs a range naming that line')
  console.error('  explicitly, e.g. ^0.1.7-rc.2 || ^0.2.0-rc.1 — a single branch whose')
  console.error('  prerelease tuple does not match is install-time poison.')
  process.exit(1)
}

console.log(`  ${gated.length} dsh peer(s) resolve on ${runtime} (runtime gate + npm)`)
