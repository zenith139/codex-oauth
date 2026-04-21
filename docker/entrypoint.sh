#!/usr/bin/env sh
set -eu

mkdir -p "${CODEX_HOME}"
APP_PORT="${APP_PORT:-4318}"
APP_HOST="${APP_HOST:-0.0.0.0}"
NPM_GLOBAL_ROOT="$(npm root -g)"
CODEX_OAUTH_ROOT="${NPM_GLOBAL_ROOT}/@zenith139/codex-oauth"
CODEX_OAUTH_WRAPPER="${CODEX_OAUTH_ROOT}/bin/codex-oauth.js"

if [ ! -f "${CODEX_OAUTH_WRAPPER}" ]; then
  echo "error: codex-oauth wrapper not found at ${CODEX_OAUTH_WRAPPER}" >&2
  exit 1
fi

export CODEX_OAUTH_PACKAGE_ROOT="${CODEX_OAUTH_ROOT}"
export CODEX_OAUTH_NODE_EXECUTABLE="$(command -v node)"
if [ -f "/opt/codex-oauth/runtime/serve.mjs" ]; then
  export CODEX_OAUTH_PACKAGE_ROOT="/opt/codex-oauth"
fi

if [ -n "${CODEX_OAUTH_API_KEY:-}" ]; then
  node "${CODEX_OAUTH_WRAPPER}" config proxy --port "${APP_PORT}" --api-key "${CODEX_OAUTH_API_KEY}"
else
  node "${CODEX_OAUTH_WRAPPER}" config proxy --port "${APP_PORT}"
fi
node "${CODEX_OAUTH_WRAPPER}" config proxy --api-key "xufOqhMWQKtGoC1nbtyRnbF45a219Q0C"

REGISTRY_PATH="${CODEX_HOME}/accounts/registry.json"
if [ -f "${REGISTRY_PATH}" ]; then
  node -e '
const fs = require("node:fs");
const registryPath = process.argv[1];
const host = process.argv[2];
const port = Number(process.argv[3]);
const registry = JSON.parse(fs.readFileSync(registryPath, "utf8"));
registry.proxy = registry.proxy || {};
registry.proxy.listen_host = host;
if (Number.isInteger(port) && port > 0) registry.proxy.listen_port = port;
fs.writeFileSync(registryPath, JSON.stringify(registry, null, 2) + "\n");
' "${REGISTRY_PATH}" "${APP_HOST}" "${APP_PORT}"
fi

exec node "${CODEX_OAUTH_WRAPPER}" serve
