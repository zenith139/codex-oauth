#!/usr/bin/env sh
set -eu

mkdir -p "${CODEX_HOME}"
APP_PORT="${APP_PORT:-4318}"
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

exec node "${CODEX_OAUTH_WRAPPER}" serve
