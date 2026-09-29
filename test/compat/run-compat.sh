#!/usr/bin/env bash
# Compatibility check: boot a REAL dsh of a given version with dsh-web-search-pro
# installed as a profile bundle, drive it with a scripted mock model, and assert
# that the plugin activates and its tools actually execute.
#
# No API key and no real model are needed: test/compat/mock-llm.py speaks enough
# of the OpenAI streaming protocol to script a tool call and echo its result.
#
# What this catches that unit tests cannot:
#   - the loader refusing the plugin outright (`failed to import`), which is how
#     dsh 0.1.7-rc.2 + jsdom failed before the parser swap;
#   - the 0.2.0 plugin-compatibility gate rejecting the declared peer ranges;
#   - a tool that registers but throws when the runtime invokes it.
#
# Usage:
#   DSH_PREFIX=<dir> ./test/compat/run-compat.sh
#
# Environment:
#   DSH_PREFIX   npm prefix holding node_modules/@deepseek-ai/dsh
#                (default: <repo>/../.wsp-compat). Install dsh there first:
#                  mkdir -p "$DSH_PREFIX" && cd "$DSH_PREFIX" && npm init -y
#                  npm install --no-audit --no-fund @deepseek-ai/dsh@<version>
#   DSH_BIN      dsh executable (default: $DSH_PREFIX/node_modules/.bin/dsh)
#   COMPAT_HOME  throwaway DSH_HOME (default: $DSH_PREFIX/home)
#   MOCK_PORT    port for the mock model (default: 18997)
#   PLUGIN_SPEC  what to install into the profile (default: this checkout's path)
#   TOOL         tool the mock asks the agent to call (default: web_backend_status)
#   TOOL_ARGS    JSON arguments for that call (default: {})
#
# Exits non-zero on the first failed assertion.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PLUGIN_DIR=$(cd "$HERE/../.." && pwd)
# The dsh-under-test install lives in a throwaway prefix BESIDE this repo, so its
# ~300 MB node_modules tree never lands inside the working tree.
DSH_PREFIX=${DSH_PREFIX:-$(cd "$PLUGIN_DIR/.." && pwd)/.wsp-compat}
DSH_BIN=${DSH_BIN:-$DSH_PREFIX/node_modules/.bin/dsh}
COMPAT_HOME=${COMPAT_HOME:-$DSH_PREFIX/home}
MOCK_PORT=${MOCK_PORT:-18997}
PLUGIN_SPEC=${PLUGIN_SPEC:-$PLUGIN_DIR}
TOOL=${TOOL:-web_backend_status}
TOOL_ARGS=${TOOL_ARGS:-'{}'}
PROFILE=${PROFILE:-compat}

# The plugin declares @anweat/dsh-browser as a peer; the browser service is what
# `inject: ['browser']` waits for, so the browser bundle has to be present or the
# entry stays `pending` instead of activating.
BROWSER_SPEC=${BROWSER_SPEC:-@anweat/dsh-browser}

fail() { echo "compat: FAIL: $*" >&2; exit 1; }
step() { echo "== $*"; }

[[ -x "$DSH_BIN" ]] || fail "no dsh at $DSH_BIN — install it into DSH_PREFIX first"
step "dsh under test: $("$DSH_BIN" --version 2>/dev/null | tail -1)"

# npm runs the plugin's `prepare` script, which shells out to pnpm; a broken pnpm
# store would fail the install for reasons unrelated to compatibility.
export npm_config_store_dir=${npm_config_store_dir:-$DSH_PREFIX/pnpm-store}
mkdir -p "$npm_config_store_dir"

PROFILE_DIR="$COMPAT_HOME/profiles/$PROFILE"
mkdir -p "$COMPAT_HOME" "$PROFILE_DIR"

# npm runs the plugin's `prepare` script even with --ignore-scripts when the
# dependency is a local directory, and that script shells out to pnpm — a broken
# or read-only pnpm store would then fail the install for reasons unrelated to
# compatibility. Pack the checkout instead: a tarball dependency runs no prepare
# hook, which also mirrors how the plugin actually ships.
step "building and packing the plugin"
( cd "$PLUGIN_DIR" && npm run build >/dev/null 2>&1 \
    || pnpm --config.store-dir="$npm_config_store_dir" run build >/dev/null 2>&1 ) \
  || fail "plugin build failed"
[[ -f "$PLUGIN_DIR/lib/index.js" ]] || fail "plugin build produced no lib/index.js"

PLUGIN_TGZ="$DSH_PREFIX/dsh-web-search-pro-compat.tgz"
tar --transform 's,^,package/,' -czf "$PLUGIN_TGZ" -C "$PLUGIN_DIR" \
  package.json README.md LOGIN.md LICENSE cordis.patch.yml lib scripts \
  || fail "could not pack the plugin"

step "installing the plugin into $PROFILE_DIR"
cat > "$PROFILE_DIR/package.json" <<JSON
{
  "name": "dsh-compat-profile",
  "private": true,
  "dependencies": {
    "dsh-web-search-pro": "file:$PLUGIN_TGZ"
  },
  "dsh": {
    "profile": {
      "bundles": [
        "@deepseek-ai/dsh-base",
        "@deepseek-ai/dsh-headless",
        "dsh-web-search-pro",
        "$BROWSER_SPEC"
      ],
      "patchReload": "startup"
    }
  }
}
JSON
( cd "$PROFILE_DIR" && npm install --no-audit --no-fund \
    --legacy-peer-deps --cache "$DSH_PREFIX/npm-cache" --loglevel=error ) \
  || fail "profile install failed"

# The browser service comes from a separate bundle, and the plugin waits for it:
# without the package installed the entry stays `pending` and none of its tools
# register, so a compat run must install it to observe anything.
step "installing the browser bundle ($BROWSER_SPEC)"
( cd "$PROFILE_DIR" && npm install --no-audit --no-fund \
    --legacy-peer-deps --cache "$DSH_PREFIX/npm-cache" --loglevel=error "$BROWSER_SPEC" ) \
  || fail "browser bundle install failed"

# 0.2.0 gates profile bundles on their declared peer ranges and SKIPS an
# incompatible one with a warning. @anweat/dsh-browser still pins 0.1.7-rc.2
# peers, so on 0.2.0 it needs an explicit exact-version exemption or the browser
# service never comes up. Granting it is the difference between testing our
# plugin and testing the browser plugin's release cadence.
DSH_VERSION=$("$DSH_BIN" --version 2>/dev/null | tail -1)
BROWSER_PKG=$(cd "$PROFILE_DIR" && node -p "require('./node_modules/$BROWSER_SPEC/package.json').name + '@' + require('./node_modules/$BROWSER_SPEC/package.json').version" 2>/dev/null || true)
if [[ -n "$BROWSER_PKG" ]]; then
  ( cd "$DSH_PREFIX" && DSH_HOME="$COMPAT_HOME" "$DSH_BIN" plugin --profile "$PROFILE" \
      allow-version "$BROWSER_PKG" --dsh-version "$DSH_VERSION" --accept-risk >/dev/null 2>&1 ) || true
fi

# A version-incompatible bundle is skipped, not fatal: dsh warns and the entry
# never activates. Detect that up front so the failure is attributed correctly.
step "checking bundle acceptance"
DUMP=$(cd "$DSH_PREFIX" && DSH_HOME="$COMPAT_HOME" "$DSH_BIN" --profile "$PROFILE" --dump-config 2>&1 || true)
echo "$DUMP" | grep -q "web-search-pro" || fail "profile composition dropped web-search-pro"
if echo "$DUMP" | grep -q "is incompatible with dsh"; then
  echo "$DUMP" | grep -o "Plugin [^ ]* is incompatible with dsh [^:]*" | head -1 >&2
  fail "a profile bundle was rejected by the compatibility gate"
fi

step "starting the scripted model on port $MOCK_PORT"
python3 "$HERE/mock-llm.py" "$MOCK_PORT" "$TOOL" "$TOOL_ARGS" > "$DSH_PREFIX/mock.log" 2>&1 &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 40); do
  curl -sf -o /dev/null "http://127.0.0.1:$MOCK_PORT/v1/models" && break
  sleep 0.25
done

# The route must be declared in the PATCH layer: on 0.2.0 a home-level
# settings.yaml does not by itself point the default route at this provider.
cat > "$PROFILE_DIR/compat.patch.yml" <<'YAML'
- id: llm-pi-ai
  name: "@deepseek-ai/dsh-llm-pi-ai"
  config:
    providers:
      mock:
        apiKeyEnv: MOCK_API_KEY
        api: openai-completions
        baseURL: http://127.0.0.1:18997/v1
        models:
          - id: mock-model
            contextWindow: 65536
            maxTokens: 4096
            input: [text]
- id: agent-default-model
  name: "@deepseek-ai/dsh-agent-default-model"
  config:
    provider: mock
    model: mock-model
YAML
# Keep the patch's port in step with MOCK_PORT.
sed -i "s|127.0.0.1:18997|127.0.0.1:$MOCK_PORT|" "$PROFILE_DIR/compat.patch.yml"

step "running one headless turn that must call $TOOL"
set +e
OUT=$(cd "$DSH_PREFIX" && DSH_HOME="$COMPAT_HOME" MOCK_API_KEY=mock timeout 240 \
  "$DSH_BIN" --profile "$PROFILE" --patch "$PROFILE_DIR/compat.patch.yml" --json "compat run" 2>&1)
STATUS=$?
set -e
echo "$OUT" | grep -vE "ExperimentalWarning|trace-warnings" | tail -20

[[ $STATUS -eq 0 ]] || fail "headless run exited $STATUS"
echo "$OUT" | grep -q "\"tool\":\"$TOOL\"" || fail "$TOOL was never called by the runtime"
echo "$OUT" | grep -qi "pending (waiting for service: browser)" \
  && fail "the plugin never activated — still waiting for the browser service"
echo "$OUT" | grep -qi "failed to import" && fail "the loader refused the plugin"

step "PASS — $TOOL executed on dsh $("$DSH_BIN" --version 2>/dev/null | tail -1)"
