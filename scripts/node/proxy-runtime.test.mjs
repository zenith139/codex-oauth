import test from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { promises as fs } from "node:fs";

import { ProxyRuntime, accountSnapshotFileName } from "../../runtime/proxy-runtime.mjs";

function jwtForAccount({ email, userId, accountId, plan = "pro" }) {
  const header = Buffer.from(JSON.stringify({ alg: "none", typ: "JWT" })).toString("base64url");
  const payload = Buffer.from(JSON.stringify({
    email,
    "https://api.openai.com/auth": {
      chatgpt_account_id: accountId,
      chatgpt_user_id: userId,
      user_id: userId,
      chatgpt_plan_type: plan
    }
  })).toString("base64url");
  return `${header}.${payload}.sig`;
}

function makeAccount({ email, userId, accountId, accessToken, refreshToken, lastRefresh = "2026-04-14T00:00:00.000Z" }) {
  const accountKey = `${userId}::${accountId}`;
  return {
    accountKey,
    record: {
      account_key: accountKey,
      chatgpt_account_id: accountId,
      chatgpt_user_id: userId,
      email,
      alias: "",
      account_name: null,
      plan: "pro",
      auth_mode: "chatgpt",
      created_at: 1,
      last_used_at: null,
      last_usage: null,
      last_usage_at: null,
      last_local_rollout: null
    },
    snapshot: {
      auth_mode: "chatgpt",
      tokens: {
        access_token: accessToken,
        refresh_token: refreshToken,
        account_id: accountId,
        id_token: jwtForAccount({ email, userId, accountId })
      },
      last_refresh: lastRefresh
    }
  };
}

async function getFreePort() {
  const server = http.createServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  return port;
}

async function startHttpServer(handler) {
  const server = http.createServer(handler);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  return {
    server,
    baseUrl: `http://127.0.0.1:${port}`,
    async close() {
      await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    }
  };
}

async function createCodexHome({
  accounts,
  proxyPort,
  proxyApiKey = "local-proxy-key",
  strategy = "round_robin",
  stickyLimit = 3,
  activeAccountKey = accounts[0]?.accountKey ?? null
}) {
  const codexHome = await fs.mkdtemp(path.join(os.tmpdir(), "codex-oauth-proxy-test-"));
  await fs.mkdir(path.join(codexHome, "accounts"), { recursive: true });

  for (const account of accounts) {
    const snapshotPath = path.join(codexHome, "accounts", accountSnapshotFileName(account.accountKey));
    await fs.writeFile(snapshotPath, `${JSON.stringify(account.snapshot, null, 2)}\n`);
  }

  if (activeAccountKey) {
    const activeAccount = accounts.find((account) => account.accountKey === activeAccountKey);
    await fs.writeFile(path.join(codexHome, "auth.json"), `${JSON.stringify(activeAccount.snapshot, null, 2)}\n`);
  }

  const registryJson = {
    schema_version: 4,
    active_account_key: activeAccountKey,
    active_account_activated_at_ms: 0,
    auto_switch: {
      enabled: false,
      threshold_5h_percent: 10,
      threshold_weekly_percent: 5
    },
    api: {
      usage: true,
      account: true
    },
    proxy: {
      listen_host: "127.0.0.1",
      listen_port: proxyPort,
      api_key: proxyApiKey,
      strategy,
      sticky_round_robin_limit: stickyLimit
    },
    accounts: accounts.map((account) => account.record)
  };
  await fs.writeFile(path.join(codexHome, "accounts", "registry.json"), `${JSON.stringify(registryJson, null, 2)}\n`);
  return codexHome;
}

async function startProxyRuntime({
  accounts,
  strategy = "round_robin",
  stickyLimit = 3,
  proxyApiKey = "local-proxy-key",
  upstreamHandler,
  refreshHandler
}) {
  const proxyPort = await getFreePort();
  const upstream = await startHttpServer(async (req, res) => {
    const url = new URL(req.url, "http://127.0.0.1");
    if (url.pathname === "/responses") {
      await upstreamHandler(req, res);
      return;
    }
    if (url.pathname === "/oauth/token") {
      await refreshHandler(req, res);
      return;
    }
    res.writeHead(404);
    res.end();
  });

  const codexHome = await createCodexHome({
    accounts,
    proxyPort,
    proxyApiKey,
    strategy,
    stickyLimit
  });
  const runtime = new ProxyRuntime({
    codexHome,
    upstreamUrl: `${upstream.baseUrl}/responses`,
    refreshUrl: `${upstream.baseUrl}/oauth/token`,
    logger: { error() {} }
  });
  const started = await runtime.start();

  return {
    codexHome,
    runtime,
    upstream,
    baseUrl: started.baseUrl,
    apiKey: started.apiKey,
    async cleanup() {
      await runtime.stop();
      await upstream.close();
      await fs.rm(codexHome, { recursive: true, force: true });
    }
  };
}

function jsonResponse(res, statusCode, body, headers = {}) {
  const payload = `${JSON.stringify(body)}\n`;
  res.writeHead(statusCode, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(payload),
    ...headers
  });
  res.end(payload);
}

function textResponse(res, statusCode, body, headers = {}) {
  res.writeHead(statusCode, headers);
  res.end(body);
}

async function proxyRequest(baseUrl, apiKey, model = "gpt-5-codex") {
  return fetch(`${baseUrl}/responses`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      model,
      input: "hello"
    })
  });
}

test("proxy runtime enforces local API key auth", async () => {
  const account = makeAccount({
    email: "alpha@example.com",
    userId: "user-alpha",
    accountId: "acct-alpha",
    accessToken: "token-alpha",
    refreshToken: "refresh-alpha"
  });
  const harness = await startProxyRuntime({
    accounts: [account],
    upstreamHandler(req, res) {
      jsonResponse(res, 200, { ok: true, account: req.headers["chatgpt-account-id"] });
    },
    refreshHandler(req, res) {
      jsonResponse(res, 500, { error: "unexpected" });
    }
  });
  try {
    const missing = await fetch(`${harness.baseUrl}/responses`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ model: "gpt-5-codex", input: "hello" })
    });
    assert.equal(missing.status, 401);

    const wrong = await fetch(`${harness.baseUrl}/responses`, {
      method: "POST",
      headers: {
        Authorization: "Bearer wrong-key",
        "Content-Type": "application/json"
      },
      body: JSON.stringify({ model: "gpt-5-codex", input: "hello" })
    });
    assert.equal(wrong.status, 401);

    const ok = await proxyRequest(harness.baseUrl, harness.apiKey);
    assert.equal(ok.status, 200);
    assert.deepEqual(await ok.json(), { ok: true, account: "acct-alpha" });
  } finally {
    await harness.cleanup();
  }
});

test("proxy runtime rotates accounts with sticky round robin", async () => {
  const seen = [];
  const harness = await startProxyRuntime({
    accounts: [
      makeAccount({ email: "a@example.com", userId: "user-a", accountId: "acct-a", accessToken: "token-a", refreshToken: "refresh-a" }),
      makeAccount({ email: "b@example.com", userId: "user-b", accountId: "acct-b", accessToken: "token-b", refreshToken: "refresh-b" })
    ],
    strategy: "round_robin",
    stickyLimit: 3,
    upstreamHandler(req, res) {
      seen.push(req.headers["chatgpt-account-id"]);
      jsonResponse(res, 200, { ok: true });
    },
    refreshHandler(req, res) {
      jsonResponse(res, 500, { error: "unexpected" });
    }
  });
  try {
    for (let i = 0; i < 5; i += 1) {
      const response = await proxyRequest(harness.baseUrl, harness.apiKey);
      assert.equal(response.status, 200);
      await response.text();
    }
    assert.deepEqual(seen, ["acct-a", "acct-a", "acct-a", "acct-b", "acct-b"]);
  } finally {
    await harness.cleanup();
  }
});

test("proxy runtime forwards reasoning effort and injects default instructions when missing", async () => {
  let upstreamBody = null;
  const account = makeAccount({
    email: "alpha@example.com",
    userId: "user-alpha",
    accountId: "acct-alpha",
    accessToken: "token-alpha",
    refreshToken: "refresh-alpha"
  });
  const harness = await startProxyRuntime({
    accounts: [account],
    upstreamHandler(req, res) {
      let body = "";
      req.on("data", (chunk) => { body += chunk; });
      req.on("end", () => {
        upstreamBody = JSON.parse(body);
        jsonResponse(res, 200, { ok: true });
      });
    },
    refreshHandler(req, res) {
      jsonResponse(res, 500, { error: "unexpected" });
    }
  });
  try {
    const requestBody = {
      model: "gpt-5.3-codex",
      input: "hello",
      reasoning: {
        effort: "high",
        summary: "auto"
      },
      reasoning_effort: "high"
    };
    const response = await fetch(`${harness.baseUrl}/responses`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${harness.apiKey}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify(requestBody)
    });

    assert.equal(response.status, 200);
    assert.equal(upstreamBody.model, requestBody.model);
    assert.deepEqual(upstreamBody.input, [
      {
        type: "message",
        role: "user",
        content: [
          {
            type: "input_text",
            text: requestBody.input
          }
        ]
      }
    ]);
    assert.equal(upstreamBody.reasoning?.effort, "high");
    assert.equal(upstreamBody.reasoning_effort, "high");
    assert.equal(upstreamBody.instructions, "You are a helpful assistant.");
  } finally {
    await harness.cleanup();
  }
});

test("proxy runtime maps chat completions payloads into responses format for LiteLLM clients", async () => {
  let upstreamBody = null;
  const account = makeAccount({
    email: "alpha@example.com",
    userId: "user-alpha",
    accountId: "acct-alpha",
    accessToken: "token-alpha",
    refreshToken: "refresh-alpha"
  });
  const harness = await startProxyRuntime({
    accounts: [account],
    upstreamHandler(req, res) {
      let body = "";
      req.on("data", (chunk) => { body += chunk; });
      req.on("end", () => {
        upstreamBody = JSON.parse(body);
        jsonResponse(res, 200, {
          id: "resp-123",
          usage: { input_tokens: 5, output_tokens: 7, total_tokens: 12 },
          output: [
            {
              content: [
                { type: "output_text", text: "hello from codex-oauth" }
              ]
            }
          ]
        });
      });
    },
    refreshHandler(req, res) {
      jsonResponse(res, 500, { error: "unexpected" });
    }
  });
  try {
    const response = await fetch(`${harness.baseUrl}/chat/completions`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${harness.apiKey}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        model: "gpt-5.3-codex",
        messages: [
          { role: "system", content: "Keep answers concise." },
          { role: "user", content: "Say hello." }
        ]
      })
    });

    assert.equal(response.status, 200);
    assert.equal(upstreamBody.instructions, "Keep answers concise.");
    assert.deepEqual(upstreamBody.input, [
      {
        type: "message",
        role: "user",
        content: [
          {
            type: "input_text",
            text: "[user] Say hello."
          }
        ]
      }
    ]);
    assert.equal(upstreamBody.store, false);
    const body = await response.json();
    assert.equal(body.object, "chat.completion");
    assert.equal(body.model, "gpt-5.3-codex");
    assert.equal(body.choices[0].message.role, "assistant");
    assert.equal(body.choices[0].message.content, "hello from codex-oauth");
    assert.equal(body.usage.prompt_tokens, 5);
    assert.equal(body.usage.completion_tokens, 7);
    assert.equal(body.usage.total_tokens, 12);
  } finally {
    await harness.cleanup();
  }
});

test("proxy runtime supports /v1/messages as a chat completions compatibility alias", async () => {
  let upstreamBody = null;
  const account = makeAccount({
    email: "alpha@example.com",
    userId: "user-alpha",
    accountId: "acct-alpha",
    accessToken: "token-alpha",
    refreshToken: "refresh-alpha"
  });
  const harness = await startProxyRuntime({
    accounts: [account],
    upstreamHandler(req, res) {
      let body = "";
      req.on("data", (chunk) => { body += chunk; });
      req.on("end", () => {
        upstreamBody = JSON.parse(body);
        jsonResponse(res, 200, {
          id: "resp-messages-1",
          usage: { input_tokens: 3, output_tokens: 4, total_tokens: 7 },
          output: [
            {
              content: [
                { type: "output_text", text: "hello from messages endpoint" }
              ]
            }
          ]
        });
      });
    },
    refreshHandler(req, res) {
      jsonResponse(res, 500, { error: "unexpected" });
    }
  });
  try {
    const response = await fetch(`${harness.baseUrl.replace("/v1", "")}/v1/messages`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${harness.apiKey}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        model: "gpt-5.3-codex",
        max_tokens: 256,
        tool_choice: "auto",
        tools: [
          {
            type: "function",
            function: {
              name: "get_weather",
              description: "Get weather by city",
              parameters: {
                type: "object",
                properties: {
                  city: { type: "string" }
                },
                required: ["city"]
              }
            }
          }
        ],
        messages: [
          { role: "system", content: "Be concise." },
          { role: "user", content: "Say hello." }
        ]
      })
    });

    assert.equal(response.status, 200);
    assert.equal(upstreamBody.max_output_tokens, 256);
    assert.equal(upstreamBody.tool_choice, "auto");
    assert.equal(Array.isArray(upstreamBody.tools), true);
    assert.equal(upstreamBody.tools[0].function.name, "get_weather");
    const body = await response.json();
    assert.equal(body.object, "chat.completion");
    assert.equal(body.choices[0].message.content, "hello from messages endpoint");
  } finally {
    await harness.cleanup();
  }
});

test("proxy runtime supports /v1/messages with stream=true", async () => {
  const account = makeAccount({
    email: "alpha@example.com",
    userId: "user-alpha",
    accountId: "acct-alpha",
    accessToken: "token-alpha",
    refreshToken: "refresh-alpha"
  });
  const harness = await startProxyRuntime({
    accounts: [account],
    upstreamHandler(req, res) {
      let body = "";
      req.on("data", (chunk) => { body += chunk; });
      req.on("end", () => {
        const parsed = JSON.parse(body);
        assert.equal(parsed.stream, true);
        res.writeHead(200, { "Content-Type": "text/event-stream; charset=utf-8" });
        res.write("event: response.created\n");
        res.write("data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp-stream-1\"}}\n\n");
        res.write("event: response.output_text.delta\n");
        res.write("data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n\n");
        res.write("event: response.output_text.delta\n");
        res.write("data: {\"type\":\"response.output_text.delta\",\"delta\":\"!\"}\n\n");
        res.end("data: {\"type\":\"response.completed\"}\n\n");
      });
    },
    refreshHandler(req, res) {
      jsonResponse(res, 500, { error: "unexpected" });
    }
  });
  try {
    const response = await fetch(`${harness.baseUrl.replace("/v1", "")}/v1/messages`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${harness.apiKey}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        model: "gpt-5.3-codex",
        stream: true,
        messages: [
          { role: "user", content: "Say hello." }
        ]
      })
    });

    assert.equal(response.status, 200);
    assert.match(response.headers.get("content-type") || "", /text\/event-stream/);
    const body = await response.text();
    assert.ok(body.includes("\"object\":\"chat.completion.chunk\""));
    assert.ok(body.includes("\"role\":\"assistant\""));
    assert.ok(body.includes("\"content\":\"Hello\""));
    assert.ok(body.includes("\"content\":\"!\""));
    assert.ok(body.includes("data: [DONE]"));
  } finally {
    await harness.cleanup();
  }
});

test("proxy runtime falls through to another account on 429 within the same request", async () => {
  const seen = [];
  const harness = await startProxyRuntime({
    accounts: [
      makeAccount({ email: "a@example.com", userId: "user-a", accountId: "acct-a", accessToken: "token-a", refreshToken: "refresh-a" }),
      makeAccount({ email: "b@example.com", userId: "user-b", accountId: "acct-b", accessToken: "token-b", refreshToken: "refresh-b" })
    ],
    strategy: "fill_first",
    stickyLimit: 3,
    upstreamHandler(req, res) {
      const accountId = req.headers["chatgpt-account-id"];
      seen.push(accountId);
      if (accountId === "acct-a") {
        textResponse(res, 429, "rate limit exceeded", { "Content-Type": "text/plain" });
        return;
      }
      jsonResponse(res, 200, { ok: true, accountId });
    },
    refreshHandler(req, res) {
      jsonResponse(res, 500, { error: "unexpected" });
    }
  });
  try {
    const response = await proxyRequest(harness.baseUrl, harness.apiKey);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { ok: true, accountId: "acct-b" });
    assert.deepEqual(seen, ["acct-a", "acct-b"]);
  } finally {
    await harness.cleanup();
  }
});

test("proxy runtime refreshes tokens on upstream 401 and persists the new snapshot", async () => {
  let refreshCount = 0;
  const account = makeAccount({
    email: "alpha@example.com",
    userId: "user-alpha",
    accountId: "acct-alpha",
    accessToken: "expired-token",
    refreshToken: "refresh-alpha"
  });
  const harness = await startProxyRuntime({
    accounts: [account],
    upstreamHandler(req, res) {
      const auth = req.headers.authorization;
      if (auth === "Bearer expired-token") {
        textResponse(res, 401, "token expired", { "Content-Type": "text/plain" });
        return;
      }
      assert.equal(auth, "Bearer refreshed-token");
      jsonResponse(res, 200, { ok: true });
    },
    refreshHandler(req, res) {
      refreshCount += 1;
      jsonResponse(res, 200, {
        access_token: "refreshed-token",
        refresh_token: "refreshed-refresh-token"
      });
    }
  });
  try {
    const response = await proxyRequest(harness.baseUrl, harness.apiKey);
    assert.equal(response.status, 200);
    assert.equal(refreshCount, 1);

    const snapshotPath = path.join(harness.codexHome, "accounts", accountSnapshotFileName(account.accountKey));
    const snapshot = JSON.parse(await fs.readFile(snapshotPath, "utf8"));
    assert.equal(snapshot.tokens.access_token, "refreshed-token");
    assert.equal(snapshot.tokens.refresh_token, "refreshed-refresh-token");

    const activeAuth = JSON.parse(await fs.readFile(path.join(harness.codexHome, "auth.json"), "utf8"));
    assert.equal(activeAuth.tokens.access_token, "refreshed-token");
    assert.equal(activeAuth.tokens.refresh_token, "refreshed-refresh-token");
  } finally {
    await harness.cleanup();
  }
});

test("proxy runtime keeps model locks scoped to the failing model", async () => {
  const seen = [];
  const harness = await startProxyRuntime({
    accounts: [
      makeAccount({ email: "a@example.com", userId: "user-a", accountId: "acct-a", accessToken: "token-a", refreshToken: "refresh-a" }),
      makeAccount({ email: "b@example.com", userId: "user-b", accountId: "acct-b", accessToken: "token-b", refreshToken: "refresh-b" })
    ],
    strategy: "fill_first",
    stickyLimit: 3,
    upstreamHandler(req, res) {
      const accountId = req.headers["chatgpt-account-id"];
      seen.push(accountId);
      let body = "";
      req.on("data", (chunk) => { body += chunk; });
      req.on("end", () => {
        const model = JSON.parse(body).model;
        if (accountId === "acct-a" && model === "gpt-5-codex") {
          textResponse(res, 403, "quota exceeded", { "Content-Type": "text/plain" });
          return;
        }
        jsonResponse(res, 200, { ok: true, accountId, model });
      });
    },
    refreshHandler(req, res) {
      jsonResponse(res, 500, { error: "unexpected" });
    }
  });
  try {
    const first = await proxyRequest(harness.baseUrl, harness.apiKey, "gpt-5-codex");
    assert.equal(first.status, 200);
    assert.deepEqual(await first.json(), { ok: true, accountId: "acct-b", model: "gpt-5-codex" });

    const second = await proxyRequest(harness.baseUrl, harness.apiKey, "gpt-4.1");
    assert.equal(second.status, 200);
    assert.deepEqual(await second.json(), { ok: true, accountId: "acct-a", model: "gpt-4.1" });

    assert.deepEqual(seen, ["acct-a", "acct-b", "acct-a"]);
  } finally {
    await harness.cleanup();
  }
});

test("proxy runtime returns Retry-After when every account is locked", async () => {
  const harness = await startProxyRuntime({
    accounts: [
      makeAccount({ email: "a@example.com", userId: "user-a", accountId: "acct-a", accessToken: "token-a", refreshToken: "refresh-a" }),
      makeAccount({ email: "b@example.com", userId: "user-b", accountId: "acct-b", accessToken: "token-b", refreshToken: "refresh-b" })
    ],
    strategy: "fill_first",
    stickyLimit: 3,
    upstreamHandler(req, res) {
      const accountId = req.headers["chatgpt-account-id"];
      if (accountId === "acct-a") {
        textResponse(res, 403, "quota exceeded", { "Content-Type": "text/plain" });
        return;
      }
      textResponse(res, 401, "token expired", { "Content-Type": "text/plain" });
    },
    refreshHandler(req, res) {
      textResponse(res, 401, "refresh denied", { "Content-Type": "text/plain" });
    }
  });
  try {
    const response = await proxyRequest(harness.baseUrl, harness.apiKey);
    assert.equal(response.status, 429);
    assert.ok(Number(response.headers.get("retry-after")) >= 1);
    const body = await response.json();
    assert.equal(body.error.code, "all_accounts_unavailable");
  } finally {
    await harness.cleanup();
  }
});

test("proxy runtime relays SSE responses end to end", async () => {
  const account = makeAccount({
    email: "alpha@example.com",
    userId: "user-alpha",
    accountId: "acct-alpha",
    accessToken: "token-alpha",
    refreshToken: "refresh-alpha"
  });
  const harness = await startProxyRuntime({
    accounts: [account],
    upstreamHandler(req, res) {
      res.writeHead(200, { "Content-Type": "text/event-stream; charset=utf-8" });
      res.write("data: first\n\n");
      res.write("data: second\n\n");
      res.end("data: [DONE]\n\n");
    },
    refreshHandler(req, res) {
      jsonResponse(res, 500, { error: "unexpected" });
    }
  });
  try {
    const response = await proxyRequest(harness.baseUrl, harness.apiKey);
    assert.equal(response.status, 200);
    assert.match(response.headers.get("content-type"), /text\/event-stream/);
    const body = await response.text();
    assert.ok(body.includes("data: first"));
    assert.ok(body.includes("data: second"));
    assert.ok(body.includes("data: [DONE]"));
  } finally {
    await harness.cleanup();
  }
});

test("proxy runtime normalizes SSE reasoning effort for LiteLLM compatibility", async () => {
  const account = makeAccount({
    email: "alpha@example.com",
    userId: "user-alpha",
    accountId: "acct-alpha",
    accessToken: "token-alpha",
    refreshToken: "refresh-alpha"
  });
  const harness = await startProxyRuntime({
    accounts: [account],
    upstreamHandler(req, res) {
      res.writeHead(200, { "Content-Type": "text/event-stream; charset=utf-8" });
      res.write("event: response.created\n");
      res.write("data: {\"type\":\"response.created\",\"response\":{\"reasoning\":{\"effort\":\"none\"}}}\n\n");
      res.end("data: [DONE]\n\n");
    },
    refreshHandler(req, res) {
      jsonResponse(res, 500, { error: "unexpected" });
    }
  });
  try {
    const response = await proxyRequest(harness.baseUrl, harness.apiKey);
    assert.equal(response.status, 200);
    const body = await response.text();
    assert.ok(body.includes("\"effort\":\"minimal\""));
    assert.ok(!body.includes("\"effort\":\"none\""));
  } finally {
    await harness.cleanup();
  }
});
