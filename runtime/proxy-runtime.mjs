import http from "node:http";
import path from "node:path";
import { Readable } from "node:stream";
import { promises as fs } from "node:fs";

const DEFAULT_LISTEN_HOST = "127.0.0.1";
const DEFAULT_LISTEN_PORT = 4318;
const DEFAULT_STRATEGY = "round_robin";
const DEFAULT_STICKY_LIMIT = 3;
const DEFAULT_UPSTREAM_URL = "https://chatgpt.com/backend-api/codex/responses";
const DEFAULT_REFRESH_URL = "https://auth.openai.com/oauth/token";
const DEFAULT_USER_AGENT = "codex-cli/1.0.18 (macOS; arm64)";
const PROACTIVE_REFRESH_AGE_MS = 50 * 60 * 1000;
const MAX_BACKOFF_MS = 2 * 60 * 1000;
const MAX_BODY_BYTES = 20 * 1024 * 1024;
const MODEL_LOCK_ALL = "__all__";

const STATIC_MODEL_IDS = [
  "gpt-5-codex",
  "gpt-5.1-codex",
  "gpt-5.1-codex-mini",
  "gpt-5.1-codex-max",
  "gpt-5.2-codex",
  "gpt-5.3-codex",
  "gpt-5.3-codex-low",
  "gpt-5.3-codex-high",
  "gpt-5.3-codex-xhigh"
];

export function strategyLabel(strategy) {
  return strategy === "fill_first" ? "fill-first" : "round-robin";
}

export function maskApiKey(apiKey) {
  if (!apiKey) return "(not-generated)";
  if (apiKey.length <= 8) return apiKey;
  return `${apiKey.slice(0, 4)}...${apiKey.slice(-4)}`;
}

export function accountSnapshotFileName(accountKey) {
  const safe = needsFilenameEncoding(accountKey)
    ? Buffer.from(accountKey, "utf8").toString("base64url")
    : accountKey;
  return `${safe}.auth.json`;
}

function needsFilenameEncoding(key) {
  if (!key || key === "." || key === "..") return true;
  return /[^a-zA-Z0-9._-]/.test(key);
}

function safeJsonParse(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function lowerText(value) {
  return typeof value === "string" ? value.toLowerCase() : "";
}

function nowIso(nowMs) {
  return new Date(nowMs).toISOString();
}

function parseTimestampMs(value) {
  if (typeof value !== "string" || value.length === 0) return null;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function shouldAttemptProactiveRefresh(lastRefreshMs, nowMs) {
  if (!Number.isFinite(lastRefreshMs)) return true;
  return nowMs - lastRefreshMs >= PROACTIVE_REFRESH_AGE_MS;
}

function nextBackoff(backoffLevel) {
  const boundedLevel = Math.max(0, Number(backoffLevel) || 0);
  return {
    cooldownMs: Math.min(1000 * (2 ** boundedLevel), MAX_BACKOFF_MS),
    newBackoffLevel: Math.min(boundedLevel + 1, 8)
  };
}

export function computeFallback(status, errorText, backoffLevel = 0) {
  const text = lowerText(errorText);
  const quotaLike = text.includes("quota") ||
    text.includes("rate limit") ||
    text.includes("too many requests") ||
    text.includes("usage limit") ||
    text.includes("credit balance") ||
    text.includes("improperly formed request");

  if (status === 429 || quotaLike) {
    const backoff = nextBackoff(backoffLevel);
    return { shouldFallback: true, cooldownMs: backoff.cooldownMs, newBackoffLevel: backoff.newBackoffLevel };
  }
  if (text.includes("request not allowed")) {
    return { shouldFallback: true, cooldownMs: 5000, newBackoffLevel: null };
  }

  switch (status) {
    case 401:
    case 402:
    case 403:
    case 404:
      return { shouldFallback: true, cooldownMs: 2 * 60 * 1000, newBackoffLevel: null };
    case 406:
    case 408:
    case 500:
    case 502:
    case 503:
    case 504:
      return { shouldFallback: true, cooldownMs: 30 * 1000, newBackoffLevel: null };
    default:
      break;
  }

  if (status >= 400 || text.length > 0) {
    return { shouldFallback: true, cooldownMs: 10 * 1000, newBackoffLevel: null };
  }
  return { shouldFallback: false, cooldownMs: 0, newBackoffLevel: null };
}

function cleanupExpiredLocks(state, nowMs) {
  for (const [model, expiresAtMs] of state.locks.entries()) {
    if (expiresAtMs <= nowMs) {
      state.locks.delete(model);
    }
  }
  if (state.locks.size === 0) {
    state.unavailable = false;
  }
}

function earliestRetryMs(state, model, nowMs) {
  let earliest = null;
  for (const [lockModel, expiresAtMs] of state.locks.entries()) {
    const matches = lockModel === MODEL_LOCK_ALL || lockModel === model || (model == null && lockModel === MODEL_LOCK_ALL);
    if (!matches || expiresAtMs <= nowMs) continue;
    if (earliest == null || expiresAtMs < earliest) {
      earliest = expiresAtMs;
    }
  }
  return earliest;
}

function isLocked(state, model, nowMs) {
  const allLock = state.locks.get(MODEL_LOCK_ALL);
  if (typeof allLock === "number" && allLock > nowMs) return true;
  if (model == null) return false;
  const modelLock = state.locks.get(model);
  return typeof modelLock === "number" && modelLock > nowMs;
}

export class ProxyRouter {
  constructor({ now = () => Date.now() } = {}) {
    this.now = now;
    this.accounts = new Map();
  }

  stateFor(accountKey) {
    if (!this.accounts.has(accountKey)) {
      this.accounts.set(accountKey, {
        lastSelectedAtMs: null,
        consecutiveUseCount: 0,
        backoffLevel: 0,
        unavailable: false,
        locks: new Map()
      });
    }
    return this.accounts.get(accountKey);
  }

  selectAccount(candidates, config, { model = null, excludeAccountKeys = [], nowMs = this.now() } = {}) {
    const excluded = new Set(excludeAccountKeys);
    const available = [];
    let retryAfterMs = null;

    for (const candidate of candidates) {
      if (!candidate || !candidate.accountKey || excluded.has(candidate.accountKey)) continue;
      const state = this.stateFor(candidate.accountKey);
      cleanupExpiredLocks(state, nowMs);
      if (isLocked(state, model, nowMs)) {
        const retryAt = earliestRetryMs(state, model, nowMs);
        if (retryAt != null && (retryAfterMs == null || retryAt < retryAfterMs)) {
          retryAfterMs = retryAt;
        }
        continue;
      }
      available.push(candidate);
    }

    if (available.length === 0) {
      return { accountKey: null, allRateLimited: retryAfterMs != null, retryAfterMs };
    }

    const selected = config.strategy === "fill_first"
      ? available[0]
      : this.selectRoundRobin(available, config.stickyRoundRobinLimit ?? DEFAULT_STICKY_LIMIT);
    this.markSelected(selected.accountKey, config, available, nowMs);
    return { accountKey: selected.accountKey, allRateLimited: false, retryAfterMs: null };
  }

  selectRoundRobin(available, stickyLimit) {
    let mostRecent = null;
    for (const candidate of available) {
      const state = this.stateFor(candidate.accountKey);
      if (state.lastSelectedAtMs == null) continue;
      if (!mostRecent || state.lastSelectedAtMs > mostRecent.lastSelectedAtMs) {
        mostRecent = { candidate, lastSelectedAtMs: state.lastSelectedAtMs };
      }
    }

    if (mostRecent) {
      const state = this.stateFor(mostRecent.candidate.accountKey);
      if (state.consecutiveUseCount < stickyLimit) {
        return mostRecent.candidate;
      }
    }

    let oldest = available[0];
    for (const candidate of available.slice(1)) {
      const candidateState = this.stateFor(candidate.accountKey);
      const oldestState = this.stateFor(oldest.accountKey);
      if (oldestState.lastSelectedAtMs == null) continue;
      if (candidateState.lastSelectedAtMs == null || candidateState.lastSelectedAtMs < oldestState.lastSelectedAtMs) {
        oldest = candidate;
      }
    }
    return oldest;
  }

  markSelected(accountKey, config, available, nowMs) {
    const state = this.stateFor(accountKey);
    let reuseCurrent = false;
    if (config.strategy === "round_robin") {
      let mostRecent = null;
      for (const candidate of available) {
        const candidateState = this.stateFor(candidate.accountKey);
        if (candidateState.lastSelectedAtMs == null) continue;
        if (!mostRecent || candidateState.lastSelectedAtMs > mostRecent.lastSelectedAtMs) {
          mostRecent = { accountKey: candidate.accountKey, lastSelectedAtMs: candidateState.lastSelectedAtMs };
        }
      }
      if (mostRecent?.accountKey === accountKey && state.lastSelectedAtMs != null && state.consecutiveUseCount < (config.stickyRoundRobinLimit ?? DEFAULT_STICKY_LIMIT)) {
        reuseCurrent = true;
      }
    }

    state.consecutiveUseCount = reuseCurrent ? state.consecutiveUseCount + 1 : 1;
    state.lastSelectedAtMs = nowMs;
  }

  markUnavailable(accountKey, { status, errorText, model = null, nowMs = this.now() }) {
    const state = this.stateFor(accountKey);
    cleanupExpiredLocks(state, nowMs);

    const decision = computeFallback(status, errorText, state.backoffLevel);
    if (!decision.shouldFallback) {
      return { shouldFallback: false, cooldownMs: 0, retryUntilMs: null };
    }

    state.unavailable = true;
    if (typeof decision.newBackoffLevel === "number") {
      state.backoffLevel = decision.newBackoffLevel;
    }

    const retryUntilMs = nowMs + decision.cooldownMs;
    state.locks.set(model || MODEL_LOCK_ALL, retryUntilMs);
    return { shouldFallback: true, cooldownMs: decision.cooldownMs, retryUntilMs };
  }

  clearSuccess(accountKey, model = null, nowMs = this.now()) {
    const state = this.accounts.get(accountKey);
    if (!state) return;
    cleanupExpiredLocks(state, nowMs);

    state.backoffLevel = 0;
    state.unavailable = false;
    state.locks.delete(MODEL_LOCK_ALL);
    if (model) {
      state.locks.delete(model);
    }
  }
}

function decodeJwtPayload(jwt) {
  if (typeof jwt !== "string") return null;
  const parts = jwt.split(".");
  if (parts.length < 2) return null;
  try {
    return JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
  } catch {
    return null;
  }
}

export function parseAuthSnapshot(rawText, { accountKey = null, snapshotPath = null } = {}) {
  const parsed = safeJsonParse(rawText);
  if (!parsed || typeof parsed !== "object") return null;
  if (typeof parsed.OPENAI_API_KEY === "string" && parsed.OPENAI_API_KEY.length > 0) return null;
  const tokens = parsed.tokens;
  if (!tokens || typeof tokens !== "object") return null;

  const accessToken = typeof tokens.access_token === "string" && tokens.access_token.length > 0 ? tokens.access_token : null;
  const refreshToken = typeof tokens.refresh_token === "string" && tokens.refresh_token.length > 0 ? tokens.refresh_token : null;
  const accountId = typeof tokens.account_id === "string" && tokens.account_id.length > 0 ? tokens.account_id : null;
  const idToken = typeof tokens.id_token === "string" && tokens.id_token.length > 0 ? tokens.id_token : null;
  if (!accessToken || !refreshToken || !accountId) return null;

  const claims = decodeJwtPayload(idToken);
  const authClaims = claims?.["https://api.openai.com/auth"];
  const chatgptUserId = typeof authClaims?.chatgpt_user_id === "string" && authClaims.chatgpt_user_id.length > 0
    ? authClaims.chatgpt_user_id
    : typeof authClaims?.user_id === "string" && authClaims.user_id.length > 0
      ? authClaims.user_id
      : null;
  const recordKey = accountKey || (chatgptUserId && accountId ? `${chatgptUserId}::${accountId}` : null);

  return {
    rawText,
    json: parsed,
    snapshotPath,
    accountKey: recordKey,
    accountId,
    accessToken,
    refreshToken,
    idToken,
    lastRefreshRaw: typeof parsed.last_refresh === "string" ? parsed.last_refresh : null,
    lastRefreshMs: parseTimestampMs(parsed.last_refresh),
    email: typeof claims?.email === "string" ? claims.email.toLowerCase() : null,
    chatgptUserId
  };
}

async function readRegistry(codexHome) {
  const registryPath = path.join(codexHome, "accounts", "registry.json");
  let rawText;
  try {
    rawText = await fs.readFile(registryPath, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") {
      return { schema_version: 4, proxy: null, accounts: [] };
    }
    throw error;
  }
  return safeJsonParse(rawText) || { schema_version: 4, proxy: null, accounts: [] };
}

function normalizeProxyConfig(proxyConfig) {
  return {
    listen_host: typeof proxyConfig?.listen_host === "string" && proxyConfig.listen_host.length > 0 ? proxyConfig.listen_host : DEFAULT_LISTEN_HOST,
    listen_port: Number.isInteger(proxyConfig?.listen_port) && proxyConfig.listen_port > 0 ? proxyConfig.listen_port : DEFAULT_LISTEN_PORT,
    api_key: typeof proxyConfig?.api_key === "string" && proxyConfig.api_key.length > 0 ? proxyConfig.api_key : null,
    strategy: proxyConfig?.strategy === "fill_first" || proxyConfig?.strategy === "fill-first" ? "fill_first" : DEFAULT_STRATEGY,
    sticky_round_robin_limit: Number.isInteger(proxyConfig?.sticky_round_robin_limit) && proxyConfig.sticky_round_robin_limit > 0
      ? proxyConfig.sticky_round_robin_limit
      : DEFAULT_STICKY_LIMIT
  };
}

export async function loadChatgptAccounts(codexHome, registryObject) {
  const accounts = Array.isArray(registryObject?.accounts) ? registryObject.accounts : [];
  const loaded = [];

  for (const record of accounts) {
    if (!record || typeof record.account_key !== "string" || record.account_key.length === 0) continue;
    if (record.auth_mode === "apikey") continue;

    const snapshotPath = path.join(codexHome, "accounts", accountSnapshotFileName(record.account_key));
    let rawText;
    try {
      rawText = await fs.readFile(snapshotPath, "utf8");
    } catch (error) {
      if (error?.code === "ENOENT") continue;
      throw error;
    }

    const snapshot = parseAuthSnapshot(rawText, { accountKey: record.account_key, snapshotPath });
    if (!snapshot) continue;
    loaded.push({
      accountKey: record.account_key,
      email: typeof record.email === "string" ? record.email : snapshot.email,
      authMode: typeof record.auth_mode === "string" ? record.auth_mode : "chatgpt",
      snapshotPath,
      accessToken: snapshot.accessToken,
      refreshToken: snapshot.refreshToken,
      idToken: snapshot.idToken,
      accountId: snapshot.accountId,
      lastRefreshMs: snapshot.lastRefreshMs,
      lastRefreshRaw: snapshot.lastRefreshRaw,
      chatgptUserId: snapshot.chatgptUserId,
      json: snapshot.json
    });
  }

  return loaded;
}

async function updateSnapshotFile(snapshotPath, updater) {
  const rawText = await fs.readFile(snapshotPath, "utf8");
  const parsed = safeJsonParse(rawText) || {};
  const updated = updater(parsed) ?? parsed;
  await fs.writeFile(snapshotPath, `${JSON.stringify(updated, null, 2)}\n`, "utf8");
}

export async function persistRefreshedTokens(codexHome, accountKey, refreshedTokens) {
  const snapshotPath = path.join(codexHome, "accounts", accountSnapshotFileName(accountKey));
  const writeTokens = async (targetPath) => {
    await updateSnapshotFile(targetPath, (parsed) => {
      if (!parsed || typeof parsed !== "object") parsed = {};
      if (!parsed.tokens || typeof parsed.tokens !== "object") parsed.tokens = {};
      parsed.auth_mode = typeof parsed.auth_mode === "string" && parsed.auth_mode.length > 0 ? parsed.auth_mode : "chatgpt";
      parsed.tokens.access_token = refreshedTokens.accessToken;
      parsed.tokens.refresh_token = refreshedTokens.refreshToken;
      parsed.tokens.account_id = refreshedTokens.accountId;
      if (refreshedTokens.idToken) {
        parsed.tokens.id_token = refreshedTokens.idToken;
      }
      parsed.last_refresh = refreshedTokens.lastRefresh;
      return parsed;
    });
  };

  await writeTokens(snapshotPath);

  const activeAuthPath = path.join(codexHome, "auth.json");
  try {
    const activeRawText = await fs.readFile(activeAuthPath, "utf8");
    const activeSnapshot = parseAuthSnapshot(activeRawText);
    if (activeSnapshot?.accountKey === accountKey) {
      await writeTokens(activeAuthPath);
    }
  } catch (error) {
    if (error?.code !== "ENOENT") {
      throw error;
    }
  }
}

async function refreshAccountTokens(account, ctx) {
  const body = new URLSearchParams({
    grant_type: "refresh_token",
    refresh_token: account.refreshToken,
    client_id: "app_EMoamEEZ73f0CkXaXp7hrann",
    scope: "openid profile email offline_access"
  });

  const response = await ctx.fetchImpl(ctx.refreshUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      Accept: "application/json"
    },
    body
  });

  if (!response.ok) {
    const errorText = await response.text().catch(() => "");
    const message = extractErrorMessage(errorText, response.status);
    const error = new Error(`refresh failed (${response.status}): ${message}`);
    error.status = response.status;
    error.bodyText = errorText;
    throw error;
  }

  const tokens = await response.json();
  const refreshed = {
    accessToken: tokens.access_token,
    refreshToken: tokens.refresh_token || account.refreshToken,
    idToken: tokens.id_token || account.idToken,
    accountId: account.accountId,
    lastRefresh: nowIso(ctx.now())
  };
  await persistRefreshedTokens(ctx.codexHome, account.accountKey, refreshed);
  return {
    ...account,
    accessToken: refreshed.accessToken,
    refreshToken: refreshed.refreshToken,
    idToken: refreshed.idToken,
    lastRefreshMs: parseTimestampMs(refreshed.lastRefresh),
    lastRefreshRaw: refreshed.lastRefresh
  };
}

async function maybeRefreshProactively(account, ctx) {
  if (!shouldAttemptProactiveRefresh(account.lastRefreshMs, ctx.now())) {
    return account;
  }
  try {
    return await refreshAccountTokens(account, ctx);
  } catch {
    return account;
  }
}

async function drainResponse(response) {
  try {
    await response.arrayBuffer();
  } catch {
    // ignore body drain errors
  }
}

function extractErrorMessage(errorText, status) {
  const parsed = safeJsonParse(errorText);
  if (typeof parsed?.error?.message === "string" && parsed.error.message.length > 0) {
    return parsed.error.message;
  }
  if (typeof parsed?.message === "string" && parsed.message.length > 0) {
    return parsed.message;
  }
  if (typeof errorText === "string" && errorText.trim().length > 0) {
    return errorText.trim();
  }
  return `Upstream request failed (${status})`;
}

function openAIError(message, code = null, type = "proxy_error") {
  return {
    error: {
      message,
      type,
      param: null,
      code
    }
  };
}

function writeJson(res, statusCode, body, headers = {}) {
  const payload = `${JSON.stringify(body)}\n`;
  res.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(payload),
    ...headers
  });
  res.end(payload);
}

async function readBody(req, limit = MAX_BODY_BYTES) {
  const chunks = [];
  let total = 0;
  for await (const chunk of req) {
    const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    total += buf.length;
    if (total > limit) {
      throw new Error(`request body exceeded ${limit} bytes`);
    }
    chunks.push(buf);
  }
  return Buffer.concat(chunks);
}

function filteredResponseHeaders(responseHeaders) {
  const hopByHop = new Set([
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "content-length"
  ]);
  const headers = {};
  for (const [name, value] of responseHeaders.entries()) {
    if (hopByHop.has(name.toLowerCase())) continue;
    headers[name] = value;
  }
  return headers;
}

async function relayUpstreamResponse(res, upstreamResponse) {
  const headers = filteredResponseHeaders(upstreamResponse.headers);

  res.writeHead(upstreamResponse.status, headers);
  if (!upstreamResponse.body) {
    res.end();
    return;
  }

  const bodyStream = Readable.fromWeb(upstreamResponse.body);
  bodyStream.on("error", () => {
    if (!res.destroyed) {
      res.destroy();
    }
  });
  res.on("close", () => {
    bodyStream.destroy();
  });

  let pending = "";
  bodyStream.on("data", (chunk) => {
    pending += Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk);
    let lineBreakIdx = pending.indexOf("\n");
    while (lineBreakIdx !== -1) {
      const line = pending.slice(0, lineBreakIdx);
      pending = pending.slice(lineBreakIdx + 1);
      if (!res.destroyed) {
        res.write(`${normalizeSseLineForLiteLLM(line)}\n`);
      }
      lineBreakIdx = pending.indexOf("\n");
    }
  });
  bodyStream.on("end", () => {
    if (!res.destroyed) {
      if (pending.length > 0) {
        res.write(normalizeSseLineForLiteLLM(pending));
      }
      res.end();
    }
  });
}

function normalizeResponsesEventForLiteLLM(event) {
  if (!event || typeof event !== "object") return event;
  if (event.response && typeof event.response === "object" && event.response.reasoning && typeof event.response.reasoning === "object") {
    if (event.response.reasoning.effort === "none") {
      event.response.reasoning.effort = "minimal";
    }
  }
  return event;
}

function normalizeSseLineForLiteLLM(line) {
  if (!line.startsWith("data: ")) return line;
  const payload = line.slice(6);
  if (payload === "[DONE]") return line;
  let parsed;
  try {
    parsed = JSON.parse(payload);
  } catch {
    return line;
  }
  const normalized = normalizeResponsesEventForLiteLLM(parsed);
  return `data: ${JSON.stringify(normalized)}`;
}

function buildModelList() {
  return {
    object: "list",
    data: STATIC_MODEL_IDS.map((id) => ({
      id,
      object: "model",
      created: 0,
      owned_by: "openai"
    }))
  };
}

function getHeader(req, name) {
  const value = req.headers[name];
  if (Array.isArray(value)) return value[0] || "";
  return value || "";
}

function bearerTokenFromHeader(headerValue) {
  if (typeof headerValue !== "string") return null;
  const match = headerValue.match(/^Bearer\s+(.+)$/i);
  return match ? match[1] : null;
}

function coerceText(value) {
  if (typeof value === "string") return value;
  if (value == null) return "";
  return String(value);
}

function messageContentToText(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  const parts = [];
  for (const item of content) {
    if (typeof item === "string") {
      parts.push(item);
      continue;
    }
    if (!item || typeof item !== "object") continue;
    if (item.type === "text" || item.type === "output_text" || item.type === "input_text") {
      const text = coerceText(item.text).trim();
      if (text) parts.push(text);
    }
  }
  return parts.join("\n").trim();
}

function messagesToInput(messages) {
  if (!Array.isArray(messages)) return "";
  const blocks = [];
  for (const message of messages) {
    if (!message || typeof message !== "object") continue;
    if (message.role === "system") continue;
    const role = typeof message.role === "string" && message.role.length > 0 ? message.role : "user";
    const text = messageContentToText(message.content).trim();
    if (!text) continue;
    blocks.push(`[${role}] ${text}`);
  }
  return blocks.join("\n\n").trim();
}

function normalizeInputField(input) {
  if (Array.isArray(input)) return input;
  if (typeof input === "string" && input.trim().length > 0) {
    return [
      {
        type: "message",
        role: "user",
        content: [
          {
            type: "input_text",
            text: input
          }
        ]
      }
    ];
  }
  return input;
}

function collectSystemInstructions(messages) {
  if (!Array.isArray(messages)) return "";
  const parts = [];
  for (const message of messages) {
    if (!message || typeof message !== "object" || message.role !== "system") continue;
    const text = messageContentToText(message.content).trim();
    if (text) parts.push(text);
  }
  return parts.join("\n\n").trim();
}

function normalizeResponsesRequest(requestJson) {
  const normalized = { ...requestJson };
  if (typeof normalized.instructions !== "string" || normalized.instructions.trim().length === 0) {
    const fromMessages = collectSystemInstructions(normalized.messages);
    normalized.instructions = fromMessages || "You are a helpful assistant.";
  }
  if (normalized.input == null || (typeof normalized.input === "string" && normalized.input.trim().length === 0)) {
    const mappedInput = messagesToInput(normalized.messages);
    if (mappedInput) normalized.input = mappedInput;
  }
  normalized.input = normalizeInputField(normalized.input);
  if (normalized.max_output_tokens == null && Number.isInteger(normalized.max_tokens) && normalized.max_tokens > 0) {
    normalized.max_output_tokens = normalized.max_tokens;
  }
  normalized.store = false;
  delete normalized.metadata;
  delete normalized.user;
  delete normalized.n;
  delete normalized.messages;
  return normalized;
}

function extractResponseOutputText(responseJson) {
  if (!responseJson || typeof responseJson !== "object") return "";
  if (typeof responseJson.output_text === "string") return responseJson.output_text;
  const outputs = Array.isArray(responseJson.output) ? responseJson.output : [];
  const texts = [];
  for (const output of outputs) {
    if (!output || typeof output !== "object") continue;
    const content = Array.isArray(output.content) ? output.content : [];
    for (const item of content) {
      if (!item || typeof item !== "object") continue;
      if (item.type === "output_text" || item.type === "text") {
        const text = coerceText(item.text).trim();
        if (text) texts.push(text);
      }
    }
  }
  return texts.join("\n").trim();
}

function buildChatCompletionResponse(responseJson, model, nowMs) {
  const outputText = extractResponseOutputText(responseJson);
  const usage = responseJson?.usage && typeof responseJson.usage === "object"
    ? {
        prompt_tokens: Number.isInteger(responseJson.usage.input_tokens) ? responseJson.usage.input_tokens : 0,
        completion_tokens: Number.isInteger(responseJson.usage.output_tokens) ? responseJson.usage.output_tokens : 0,
        total_tokens: Number.isInteger(responseJson.usage.total_tokens)
          ? responseJson.usage.total_tokens
          : (Number.isInteger(responseJson.usage.input_tokens) ? responseJson.usage.input_tokens : 0) +
            (Number.isInteger(responseJson.usage.output_tokens) ? responseJson.usage.output_tokens : 0)
      }
    : undefined;

  const body = {
    id: typeof responseJson?.id === "string" && responseJson.id.length > 0 ? responseJson.id : `chatcmpl-${nowMs}`,
    object: "chat.completion",
    created: Math.floor(nowMs / 1000),
    model: typeof model === "string" && model.length > 0 ? model : "gpt-5.3-codex",
    choices: [
      {
        index: 0,
        message: {
          role: "assistant",
          content: outputText
        },
        finish_reason: "stop"
      }
    ]
  };
  if (usage) {
    body.usage = usage;
  }
  return body;
}

function encodeJsonBuffer(value) {
  return Buffer.from(JSON.stringify(value), "utf8");
}

function buildChatCompletionChunk({ id, model, created, delta = {}, finishReason = null }) {
  return {
    id,
    object: "chat.completion.chunk",
    created,
    model,
    choices: [
      {
        index: 0,
        delta,
        finish_reason: finishReason
      }
    ]
  };
}

async function relayResponsesStreamAsChatCompletions(res, upstreamResponse, model, nowMs) {
  res.writeHead(upstreamResponse.status, {
    "Content-Type": "text/event-stream; charset=utf-8",
    "Cache-Control": "no-cache",
    Connection: "keep-alive"
  });

  if (!upstreamResponse.body) {
    res.write("data: [DONE]\n\n");
    res.end();
    return;
  }

  const streamModel = typeof model === "string" && model.length > 0 ? model : "gpt-5.3-codex";
  const created = Math.floor(nowMs / 1000);
  const bodyStream = Readable.fromWeb(upstreamResponse.body);
  let pending = "";
  let chunkId = `chatcmpl-${nowMs}`;
  let emittedRole = false;
  let emittedDone = false;

  const emitChunk = (delta, finishReason = null) => {
    if (res.destroyed) return;
    const chunk = buildChatCompletionChunk({
      id: chunkId,
      model: streamModel,
      created,
      delta,
      finishReason
    });
    res.write(`data: ${JSON.stringify(chunk)}\n\n`);
  };

  bodyStream.on("error", () => {
    if (!res.destroyed) {
      res.destroy();
    }
  });
  res.on("close", () => {
    bodyStream.destroy();
  });

  const processSseLine = (line) => {
    if (!line.startsWith("data: ")) return;
    const payload = line.slice(6);
    if (payload === "[DONE]") return;
    let parsed;
    try {
      parsed = JSON.parse(payload);
    } catch {
      return;
    }
    parsed = normalizeResponsesEventForLiteLLM(parsed);
    if (typeof parsed?.response?.id === "string" && parsed.response.id.length > 0) {
      chunkId = parsed.response.id;
    }
    if (parsed?.type === "response.output_text.delta") {
      const deltaText = coerceText(parsed.delta);
      if (!deltaText) return;
      if (!emittedRole) {
        emittedRole = true;
        emitChunk({ role: "assistant", content: deltaText }, null);
      } else {
        emitChunk({ content: deltaText }, null);
      }
      return;
    }
    if (parsed?.type === "response.completed") {
      emitChunk({}, "stop");
      if (!res.destroyed) {
        res.write("data: [DONE]\n\n");
        res.end();
      }
      emittedDone = true;
    }
  };

  bodyStream.on("data", (chunk) => {
    pending += Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk);
    let lineBreakIdx = pending.indexOf("\n");
    while (lineBreakIdx !== -1) {
      const line = pending.slice(0, lineBreakIdx);
      pending = pending.slice(lineBreakIdx + 1);
      processSseLine(line);
      lineBreakIdx = pending.indexOf("\n");
    }
  });

  bodyStream.on("end", () => {
    if (emittedDone || res.destroyed) return;
    if (pending.length > 0) {
      processSseLine(pending);
    }
    if (!emittedDone && !res.destroyed) {
      emitChunk({}, "stop");
      res.write("data: [DONE]\n\n");
      res.end();
    }
  });
}

async function forwardUpstreamRequest(account, req, bodyBuffer, ctx) {
  const headers = {
    Authorization: `Bearer ${account.accessToken}`,
    "ChatGPT-Account-Id": account.accountId,
    originator: "codex-cli",
    "User-Agent": ctx.userAgent
  };

  const contentType = getHeader(req, "content-type");
  if (contentType) {
    headers["Content-Type"] = contentType;
  } else {
    headers["Content-Type"] = "application/json";
  }
  const accept = getHeader(req, "accept");
  if (accept) {
    headers.Accept = accept;
  }

  return ctx.fetchImpl(ctx.upstreamUrl, {
    method: "POST",
    headers,
    body: bodyBuffer
  });
}

export class ProxyRuntime {
  constructor({
    codexHome,
    router = new ProxyRouter(),
    fetchImpl = globalThis.fetch,
    now = () => Date.now(),
    upstreamUrl = DEFAULT_UPSTREAM_URL,
    refreshUrl = DEFAULT_REFRESH_URL,
    userAgent = DEFAULT_USER_AGENT,
    logger = console
  }) {
    this.codexHome = codexHome;
    this.router = router;
    this.fetchImpl = fetchImpl;
    this.now = now;
    this.upstreamUrl = upstreamUrl;
    this.refreshUrl = refreshUrl;
    this.userAgent = userAgent;
    this.logger = logger;
    this.server = null;
  }

  async loadConfig() {
    const registryObject = await readRegistry(this.codexHome);
    return {
      registry: registryObject,
      proxy: normalizeProxyConfig(registryObject.proxy)
    };
  }

  async authenticate(req, res, proxyConfig) {
    const provided = bearerTokenFromHeader(getHeader(req, "authorization"));
    if (!proxyConfig.api_key || provided !== proxyConfig.api_key) {
      writeJson(res, 401, openAIError("Invalid local proxy API key.", "invalid_api_key", "invalid_request_error"));
      return false;
    }
    return true;
  }

  async handleResponses(req, res, config) {
    let bodyBuffer;
    try {
      bodyBuffer = await readBody(req);
    } catch (error) {
      writeJson(res, 413, openAIError(error.message, "request_too_large", "invalid_request_error"));
      return;
    }

    const requestJson = safeJsonParse(bodyBuffer.toString("utf8"));
    if (!requestJson || typeof requestJson !== "object") {
      writeJson(res, 400, openAIError("Request body must be valid JSON.", "invalid_json", "invalid_request_error"));
      return;
    }
    const normalizedRequest = normalizeResponsesRequest(requestJson);
    const normalizedBodyBuffer = encodeJsonBuffer(normalizedRequest);
    const model = typeof normalizedRequest.model === "string" && normalizedRequest.model.length > 0 ? normalizedRequest.model : null;

    const accounts = await loadChatgptAccounts(this.codexHome, config.registry);
    if (accounts.length === 0) {
      writeJson(res, 503, openAIError("No stored ChatGPT OAuth accounts are available for proxy routing.", "no_accounts"));
      return;
    }

    const excluded = new Set();
    let lastError = null;
    let lastSelection = null;
    while (excluded.size < accounts.length) {
      const selection = this.router.selectAccount(accounts, {
        strategy: config.proxy.strategy,
        stickyRoundRobinLimit: config.proxy.sticky_round_robin_limit
      }, {
        model,
        excludeAccountKeys: [...excluded],
        nowMs: this.now()
      });
      lastSelection = selection;
      if (!selection.accountKey) break;

      const account = accounts.find((entry) => entry.accountKey === selection.accountKey);
      if (!account) {
        excluded.add(selection.accountKey);
        continue;
      }
      excluded.add(account.accountKey);

      let activeAccount = await maybeRefreshProactively(account, this);
      try {
        let upstreamResponse = await forwardUpstreamRequest(activeAccount, req, normalizedBodyBuffer, this);
        if (upstreamResponse.status === 401 && activeAccount.refreshToken) {
          await drainResponse(upstreamResponse);
          try {
            activeAccount = await refreshAccountTokens(activeAccount, this);
            upstreamResponse = await forwardUpstreamRequest(activeAccount, req, normalizedBodyBuffer, this);
          } catch (refreshError) {
            const errorText = typeof refreshError?.bodyText === "string" ? refreshError.bodyText : refreshError?.message || "token refresh failed";
            const fallback = this.router.markUnavailable(account.accountKey, {
              status: refreshError?.status || 401,
              errorText,
              model,
              nowMs: this.now()
            });
            lastError = {
              status: refreshError?.status || 401,
              message: extractErrorMessage(errorText, refreshError?.status || 401),
              retryAfterMs: fallback.retryUntilMs != null ? Math.max(fallback.retryUntilMs - this.now(), 0) : null
            };
            continue;
          }
        }

        if (upstreamResponse.ok) {
          this.router.clearSuccess(account.accountKey, model, this.now());
          await relayUpstreamResponse(res, upstreamResponse);
          return;
        }

        const errorText = await upstreamResponse.text().catch(() => "");
        const fallback = this.router.markUnavailable(account.accountKey, {
          status: upstreamResponse.status,
          errorText,
          model,
          nowMs: this.now()
        });
        lastError = {
          status: upstreamResponse.status,
          message: extractErrorMessage(errorText, upstreamResponse.status),
          retryAfterMs: fallback.retryUntilMs != null ? Math.max(fallback.retryUntilMs - this.now(), 0) : null
        };

        if (!fallback.shouldFallback) {
          writeJson(res, upstreamResponse.status, openAIError(lastError.message, null, "upstream_error"));
          return;
        }
      } catch (error) {
        const fallback = this.router.markUnavailable(account.accountKey, {
          status: 503,
          errorText: error?.message || "network error",
          model,
          nowMs: this.now()
        });
        lastError = {
          status: 503,
          message: error?.message || "network error",
          retryAfterMs: fallback.retryUntilMs != null ? Math.max(fallback.retryUntilMs - this.now(), 0) : null
        };
      }
    }

    const retryAfterMs = lastSelection?.retryAfterMs != null
      ? Math.max(lastSelection.retryAfterMs - this.now(), 0)
      : lastError?.retryAfterMs ?? null;
    const statusCode = retryAfterMs != null ? 429 : (lastError?.status || 503);
    const headers = {};
    if (retryAfterMs != null) {
      headers["Retry-After"] = String(Math.max(1, Math.ceil(retryAfterMs / 1000)));
    }
    writeJson(
      res,
      statusCode,
      openAIError(lastError?.message || "All accounts are temporarily unavailable.", "all_accounts_unavailable", "upstream_error"),
      headers
    );
  }

  async handleChatCompletions(req, res, config) {
    let bodyBuffer;
    try {
      bodyBuffer = await readBody(req);
    } catch (error) {
      writeJson(res, 413, openAIError(error.message, "request_too_large", "invalid_request_error"));
      return;
    }

    const requestJson = safeJsonParse(bodyBuffer.toString("utf8"));
    if (!requestJson || typeof requestJson !== "object") {
      writeJson(res, 400, openAIError("Request body must be valid JSON.", "invalid_json", "invalid_request_error"));
      return;
    }
    const normalizedResponseRequest = normalizeResponsesRequest({
      model: requestJson.model,
      instructions: collectSystemInstructions(requestJson.messages),
      input: messagesToInput(requestJson.messages),
      stream: requestJson.stream === true,
      max_output_tokens: requestJson.max_completion_tokens,
      max_tokens: requestJson.max_tokens,
      reasoning: requestJson.reasoning,
      reasoning_effort: requestJson.reasoning_effort,
      temperature: requestJson.temperature,
      top_p: requestJson.top_p,
      metadata: requestJson.metadata
    });
    const responseBodyBuffer = encodeJsonBuffer(normalizedResponseRequest);
    const model = typeof normalizedResponseRequest.model === "string" && normalizedResponseRequest.model.length > 0
      ? normalizedResponseRequest.model
      : null;

    const accounts = await loadChatgptAccounts(this.codexHome, config.registry);
    if (accounts.length === 0) {
      writeJson(res, 503, openAIError("No stored ChatGPT OAuth accounts are available for proxy routing.", "no_accounts"));
      return;
    }

    const excluded = new Set();
    let lastError = null;
    let lastSelection = null;
    while (excluded.size < accounts.length) {
      const selection = this.router.selectAccount(accounts, {
        strategy: config.proxy.strategy,
        stickyRoundRobinLimit: config.proxy.sticky_round_robin_limit
      }, {
        model,
        excludeAccountKeys: [...excluded],
        nowMs: this.now()
      });
      lastSelection = selection;
      if (!selection.accountKey) break;

      const account = accounts.find((entry) => entry.accountKey === selection.accountKey);
      if (!account) {
        excluded.add(selection.accountKey);
        continue;
      }
      excluded.add(account.accountKey);

      let activeAccount = await maybeRefreshProactively(account, this);
      try {
        let upstreamResponse = await forwardUpstreamRequest(activeAccount, req, responseBodyBuffer, this);
        if (upstreamResponse.status === 401 && activeAccount.refreshToken) {
          await drainResponse(upstreamResponse);
          try {
            activeAccount = await refreshAccountTokens(activeAccount, this);
            upstreamResponse = await forwardUpstreamRequest(activeAccount, req, responseBodyBuffer, this);
          } catch (refreshError) {
            const errorText = typeof refreshError?.bodyText === "string" ? refreshError.bodyText : refreshError?.message || "token refresh failed";
            const fallback = this.router.markUnavailable(account.accountKey, {
              status: refreshError?.status || 401,
              errorText,
              model,
              nowMs: this.now()
            });
            lastError = {
              status: refreshError?.status || 401,
              message: extractErrorMessage(errorText, refreshError?.status || 401),
              retryAfterMs: fallback.retryUntilMs != null ? Math.max(fallback.retryUntilMs - this.now(), 0) : null
            };
            continue;
          }
        }

        if (upstreamResponse.ok) {
          this.router.clearSuccess(account.accountKey, model, this.now());
          if (requestJson.stream === true) {
            await relayResponsesStreamAsChatCompletions(res, upstreamResponse, model, this.now());
            return;
          }
          const responseJson = await upstreamResponse.json().catch(() => null);
          if (!responseJson) {
            writeJson(res, 502, openAIError("Upstream returned non-JSON response.", null, "upstream_error"));
            return;
          }
          writeJson(res, 200, buildChatCompletionResponse(responseJson, model, this.now()));
          return;
        }

        const errorText = await upstreamResponse.text().catch(() => "");
        const fallback = this.router.markUnavailable(account.accountKey, {
          status: upstreamResponse.status,
          errorText,
          model,
          nowMs: this.now()
        });
        lastError = {
          status: upstreamResponse.status,
          message: extractErrorMessage(errorText, upstreamResponse.status),
          retryAfterMs: fallback.retryUntilMs != null ? Math.max(fallback.retryUntilMs - this.now(), 0) : null
        };

        if (!fallback.shouldFallback) {
          writeJson(res, upstreamResponse.status, openAIError(lastError.message, null, "upstream_error"));
          return;
        }
      } catch (error) {
        const fallback = this.router.markUnavailable(account.accountKey, {
          status: 503,
          errorText: error?.message || "network error",
          model,
          nowMs: this.now()
        });
        lastError = {
          status: 503,
          message: error?.message || "network error",
          retryAfterMs: fallback.retryUntilMs != null ? Math.max(fallback.retryUntilMs - this.now(), 0) : null
        };
      }
    }

    const retryAfterMs = lastSelection?.retryAfterMs != null
      ? Math.max(lastSelection.retryAfterMs - this.now(), 0)
      : lastError?.retryAfterMs ?? null;
    const statusCode = retryAfterMs != null ? 429 : (lastError?.status || 503);
    const headers = {};
    if (retryAfterMs != null) {
      headers["Retry-After"] = String(Math.max(1, Math.ceil(retryAfterMs / 1000)));
    }
    writeJson(
      res,
      statusCode,
      openAIError(lastError?.message || "All accounts are temporarily unavailable.", "all_accounts_unavailable", "upstream_error"),
      headers
    );
  }

  async handleRequest(req, res) {
    const url = new URL(req.url || "/", "http://127.0.0.1");
    const config = await this.loadConfig();

    if (req.method === "GET" && url.pathname === "/healthz") {
      writeJson(res, 200, { ok: true });
      return;
    }

    if (url.pathname.startsWith("/v1/")) {
      const authorized = await this.authenticate(req, res, config.proxy);
      if (!authorized) return;
    }

    if (req.method === "GET" && url.pathname === "/v1/models") {
      writeJson(res, 200, buildModelList());
      return;
    }

    if (req.method === "POST" && url.pathname === "/v1/responses") {
      await this.handleResponses(req, res, config);
      return;
    }

    if (req.method === "POST" && url.pathname === "/v1/chat/completions") {
      await this.handleChatCompletions(req, res, config);
      return;
    }

    if (req.method === "POST" && url.pathname === "/v1/messages") {
      await this.handleChatCompletions(req, res, config);
      return;
    }

    writeJson(res, 404, openAIError("Not found.", "not_found", "invalid_request_error"));
  }

  async start() {
    const config = await this.loadConfig();
    if (!config.proxy.api_key) {
      throw new Error("proxy api_key is missing from registry.json");
    }

    this.server = http.createServer((req, res) => {
      this.handleRequest(req, res).catch((error) => {
        this.logger?.error?.("proxy request failed", error);
        if (res.headersSent) {
          res.destroy(error);
          return;
        }
        writeJson(res, 500, openAIError(error?.message || "internal proxy error", "internal_error"));
      });
    });

    await new Promise((resolve, reject) => {
      this.server.once("error", reject);
      this.server.listen(config.proxy.listen_port, config.proxy.listen_host, () => {
        this.server.off("error", reject);
        resolve();
      });
    });

    return {
      server: this.server,
      host: config.proxy.listen_host,
      port: config.proxy.listen_port,
      baseUrl: `http://${config.proxy.listen_host}:${config.proxy.listen_port}/v1`,
      apiKey: config.proxy.api_key
    };
  }

  async stop() {
    if (!this.server) return;
    const server = this.server;
    this.server = null;
    await new Promise((resolve, reject) => {
      server.close((error) => {
        if (error) reject(error);
        else resolve();
      });
    });
  }
}
