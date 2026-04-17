# Codex OAuth

[![npm version](https://img.shields.io/npm/v/@zenith139/codex-oauth)](https://www.npmjs.com/package/@zenith139/codex-oauth)
[![npm downloads](https://img.shields.io/npm/dm/@zenith139/codex-oauth)](https://www.npmjs.com/package/@zenith139/codex-oauth)
[![license](https://img.shields.io/npm/l/@zenith139/codex-oauth)](./LICENSE)

![command list](https://github.com/user-attachments/assets/6c13a2d6-f9da-47ea-8ec8-0394fc072d40)

`codex-oauth` is a CLI for managing multiple Codex accounts, rotating between them, and exposing a stable local proxy for Codex-compatible clients.

It is designed around three practical jobs:

- keep a local registry of Codex auth snapshots
- switch or rotate accounts when usage gets tight
- provide one local proxy endpoint so your clients do not need to care which account is active

> [!IMPORTANT]
> After any account change, restart Codex CLI, the VS Code extension, or the Codex App so the new auth state is picked up.

## Table of Contents

- [Highlights](#highlights)
- [Supported Clients and Platforms](#supported-clients-and-platforms)
- [Install](#install)
- [Quick Start](#quick-start)
- [Command Reference](#command-reference)
- [Account Management](#account-management)
- [Importing Accounts](#importing-accounts)
- [Auto-Switching](#auto-switching)
- [Usage and Account API Refresh](#usage-and-account-api-refresh)
- [Local Proxy](#local-proxy)
- [Manual Client Configuration](#manual-client-configuration)
- [Proxy Test Examples](#proxy-test-examples)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Disclaimer](#disclaimer)

## Highlights

- add the currently logged-in Codex account into a managed local registry
- import auth files or CPA token exports in bulk
- remove accounts, clean stale files, and rebuild the registry index
- auto-switch accounts based on 5-hour and weekly usage thresholds
- run a local proxy with a stable base URL and API key
- install the proxy as a background service with `proxy-daemon`
- generate or apply local client configuration snippets

## Supported Clients and Platforms

Works well with:

- Codex CLI
- Codex VS Code extension
- Codex App

Published npm packages are available for:

- Linux x64
- Linux arm64
- macOS x64
- macOS arm64
- Windows x64
- Windows arm64

For the smoothest login flow, install the official Codex CLI too:

```shell
npm install -g @openai/codex
```

Then you can sign in with Codex and add the current account with `codex-oauth login`.

## Install

Install globally:

```shell
npm install -g @zenith139/codex-oauth
```

Or run it with `npx`:

```shell
npx @zenith139/codex-oauth list
```

Requirements:

- Node.js 18+

## Quick Start

### 1. Log into Codex

```shell
codex login
```

### 2. Add the current account into the managed registry

```shell
codex-oauth login
```

### 3. Check what is stored

```shell
codex-oauth list
codex-oauth status
```

### 4. Optional: enable background auto-switching

```shell
codex-oauth config auto enable
```

### 5. Optional: run the local proxy

Foreground mode:

```shell
codex-oauth serve
```

Background service:

```shell
codex-oauth proxy-daemon --enable
```

## Command Reference

### Core Commands

| Command | Description |
| --- | --- |
| `codex-oauth list` | List available accounts |
| `codex-oauth status` | Show auto-switch, API, and proxy status |
| `codex-oauth login` | Login and add the current account |
| `codex-oauth import <path> [--alias <alias>]` | Import one auth file or a directory |
| `codex-oauth import --cpa [<path>] [--alias <alias>]` | Import CPA flat token JSON |
| `codex-oauth import --purge [<path>]` | Rebuild `registry.json` from auth files |
| `codex-oauth remove [<query>\|--all]` | Remove one or more accounts |
| `codex-oauth clean` | Delete backup and stale files under `accounts/` |
| `codex-oauth serve` | Run the local Codex proxy |
| `codex-oauth proxy-daemon --enable\|--disable\|--status\|--restart` | Manage the proxy daemon service |

### Configuration Commands

| Command | Description |
| --- | --- |
| `codex-oauth config auto enable` | Enable background auto-switching |
| `codex-oauth config auto disable` | Disable background auto-switching |
| `codex-oauth config auto --5h <percent> [--weekly <percent>]` | Configure auto-switch thresholds |
| `codex-oauth config api enable` | Enable usage and account API refresh |
| `codex-oauth config api disable` | Disable usage and account API refresh |
| `codex-oauth config proxy` | Show current proxy settings |
| `codex-oauth config proxy --port <port>` | Set proxy listen port |
| `codex-oauth config proxy --api-key <value>` | Set the local proxy API key |
| `codex-oauth config proxy --strategy <fill-first\|round-robin>` | Set account selection strategy |
| `codex-oauth config proxy --sticky-limit <count>` | Set the round-robin stickiness limit |
| `codex-oauth config proxy --manual-config` | Print local client config snippets |
| `codex-oauth config proxy --apply-config` | Write local client config files |

## Account Management

### Add the Current Account

```shell
codex-oauth login
```

This reads the currently active Codex auth and stores it as a managed snapshot.

### List Accounts

```shell
codex-oauth list
```

### Remove Accounts

Interactive remove:

```shell
codex-oauth remove
```

Remove by query:

```shell
codex-oauth remove john@example.com
```

Remove everything:

```shell
codex-oauth remove --all
```

### Clean Backups and Stale Files

```shell
codex-oauth clean
```

This removes old backup files and stale account artifacts under `~/.codex/accounts/`.

## Importing Accounts

### Import a Single Auth File

```shell
codex-oauth import /path/to/auth.json --alias personal
```

### Import a Directory of Auth Files

```shell
codex-oauth import /path/to/auth-exports
```

Typical output:

```text
Scanning /path/to/auth-exports...
  ✓ imported  token_ryan.taylor.alpha@email.com
  ✓ updated   token_jane.smith.alpha@email.com
  ✗ skipped   token_invalid: MalformedJson
Import Summary: 1 imported, 1 updated, 1 skipped (total 3 files)
```

### Import CPA Token Exports

`codex-oauth` can import flat JSON token files from [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI):

```shell
codex-oauth import --cpa
codex-oauth import --cpa /path/to/cpa-dir
codex-oauth import --cpa /path/to/token.json --alias work
```

### Rebuild the Registry From Existing Auth Files

If the registry is out of sync with the files on disk:

```shell
codex-oauth import --purge
codex-oauth import --purge /path/to/auth-exports
```

This does not import new files. It re-indexes the auth files that already exist.

## Auto-Switching

Enable:

```shell
codex-oauth config auto enable
```

Disable:

```shell
codex-oauth config auto disable
```

Adjust thresholds:

```shell
codex-oauth config auto --5h 12
codex-oauth config auto --5h 12 --weekly 8
codex-oauth config auto --weekly 8
```

By default, auto-switching moves away from the current account when either:

- 5-hour remaining usage drops below `10%`
- weekly remaining usage drops below `5%`

Background worker model by platform:

- Linux and WSL: user-level `systemd`
- macOS: `LaunchAgent`
- Windows: scheduled task

## Usage and Account API Refresh

Enable API-backed refresh:

```shell
codex-oauth config api enable
```

Disable API-backed refresh and fall back to local-only data:

```shell
codex-oauth config api disable
```

When API mode is on:

- usage refresh uses the remote usage endpoint
- account metadata refresh uses the remote account endpoint

When API mode is off:

- usage is read from local rollout or session files when possible
- account API refresh is skipped

Check the current mode with:

```shell
codex-oauth status
```

## Local Proxy

### Show Current Proxy Settings

```shell
codex-oauth config proxy
```

Example output:

```text
proxy base-url: http://127.0.0.1:4318/v1
proxy strategy: round-robin
proxy sticky-limit: 3
proxy api-key: Q5qu...2EJ-
```

### Update Proxy Settings

```shell
codex-oauth config proxy --port 4318
codex-oauth config proxy --api-key my-local-key
codex-oauth config proxy --strategy round-robin
codex-oauth config proxy --sticky-limit 3
```

### Run the Proxy in the Foreground

```shell
codex-oauth serve
```

The proxy listens on `127.0.0.1:4318` by default and exposes:

- `GET /healthz`
- `GET /v1/models`
- `POST /v1/responses`
- `POST /v1/messages`
- `POST /v1/messages/count_tokens`

### Install the Proxy as a Background Service

```shell
codex-oauth proxy-daemon --enable
codex-oauth proxy-daemon --status
codex-oauth proxy-daemon --restart
codex-oauth proxy-daemon --disable
```

Platform-specific service type:

- Linux: user `systemd` service
- macOS: LaunchAgent
- Windows: scheduled task launching `codex-oauth-proxy.exe`

The daemon reuses the proxy listen host, port, strategy, and API key from `codex-oauth config proxy`.

## Manual Client Configuration

Print generated config snippets:

```shell
codex-oauth config proxy --manual-config
```

Apply generated config files automatically:

```shell
codex-oauth config proxy --apply-config
```

Current generated files:

- `~/.codex/config.toml`
- `~/.codex/auth.json`
- `~/.claude/settings.json`

For Codex, the generated config uses:

- model `gpt-5.4`
- `model_provider = "codex_oauth"`
- `model_reasoning_effort = "high"`
- `wire_api = "responses"`

## Proxy Test Examples

### Health Check

```shell
curl -sS http://127.0.0.1:4318/healthz
```

Expected response:

```json
{"ok":true}
```

### List Models

```shell
curl -sS http://127.0.0.1:4318/v1/models \
  -H 'Authorization: Bearer YOUR_PROXY_API_KEY'
```

### Send a Simple Codex Request

When calling `/v1/responses` directly, the upstream Codex backend expects `instructions` and `store: false`.

```shell
curl -sS http://127.0.0.1:4318/v1/responses \
  -H 'Authorization: Bearer YOUR_PROXY_API_KEY' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "gpt-5.4",
    "instructions": "You are a concise assistant.",
    "store": false,
    "input": [
      {
        "type": "message",
        "role": "user",
        "content": [
          {
            "type": "input_text",
            "text": "Say hello in Vietnamese in one short sentence."
          }
        ]
      }
    ],
    "stream": false
  }'
```

### Streaming Request

```shell
curl -N http://127.0.0.1:4318/v1/responses \
  -H 'Authorization: Bearer YOUR_PROXY_API_KEY' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "gpt-5.4",
    "instructions": "You are a concise assistant.",
    "store": false,
    "input": [
      {
        "type": "message",
        "role": "user",
        "content": [
          {
            "type": "input_text",
            "text": "Say hello in Vietnamese in one short sentence."
          }
        ]
      }
    ],
    "stream": true
  }'
```

## Troubleshooting

### My usage limit is stale

If `codex-oauth` is in local-only mode, it reads usage data from the newest rollout or session files under `~/.codex/sessions/`. Those files can lag behind the real usage state.

Switch back to API mode:

```shell
codex-oauth config api enable
codex-oauth status
```

`status` should show:

```text
usage: api
account: api
```

### I upgraded the proxy but behavior did not change

Restart the managed daemon after upgrades:

```shell
codex-oauth proxy-daemon --restart
```

If you run the proxy in the foreground, stop the old process and start `codex-oauth serve` again.

### Interactive remove says it needs a TTY

Use a non-interactive selector instead:

```shell
codex-oauth remove john@example.com
codex-oauth remove --all
```

## Uninstall

Remove the npm package:

```shell
npm uninstall -g @zenith139/codex-oauth
```

## Disclaimer

This project is provided as-is. Use it at your own risk.

When API mode is enabled, `codex-oauth` sends your account access token to OpenAI endpoints for usage and account refresh. Depending on your environment and OpenAI policy enforcement, this may create account risk. You are responsible for deciding whether to use that mode.
