#!/usr/bin/env node

import process from "node:process";
import { ProxyRuntime } from "./proxy-runtime.mjs";

function parseArgs(argv) {
  let codexHome = null;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--codex-home") {
      codexHome = argv[i + 1] || null;
      i += 1;
      continue;
    }
    if (arg === "--help" || arg === "-h") {
      process.stdout.write("Usage: node runtime/serve.mjs --codex-home <path>\n");
      process.exit(0);
    }
  }
  if (!codexHome) {
    throw new Error("missing required --codex-home argument");
  }
  return { codexHome };
}

const { codexHome } = parseArgs(process.argv.slice(2));
const runtime = new ProxyRuntime({ codexHome });
const started = await runtime.start();

process.stdout.write(`proxy base-url: ${started.baseUrl}\n`);
process.stdout.write(`proxy api-key: ${started.apiKey}\n`);

const shutdown = async (signal) => {
  try {
    await runtime.stop();
  } finally {
    process.exit(signal === "SIGINT" ? 130 : 0);
  }
};

process.on("SIGINT", () => {
  shutdown("SIGINT").catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exit(1);
  });
});

process.on("SIGTERM", () => {
  shutdown("SIGTERM").catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exit(1);
  });
});
