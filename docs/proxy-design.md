# Proxy Design

This document scopes the `9router` account-routing logic that should live inside `codex-oauth` without pulling in the full dashboard/router product.

## Goal

Keep `codex-oauth` as the source of truth for ChatGPT account snapshots under `~/.codex/accounts/`, then add a local proxy runtime that can:

- load multiple stored account snapshots
- choose an account per request
- rotate across accounts with sticky round-robin behavior
- lock only the failing model/account combination on quota/auth/provider errors
- retry the same request on the next eligible account

## What Is Already Ported

The pure routing policy now lives in `src/proxy_router.zig`.

Current scope:

- `fill_first` and `round_robin` account selection
- sticky round-robin limits
- per-model and account-wide locks
- exponential backoff for `429`
- cooldown handling for `401/402/403/404/5xx`
- success-path lock clearing
- all-locked retry timing

This is intentionally runtime-agnostic. It does not know about HTTP, JSON payloads, SSE, or provider-specific request translation yet.

## Next Runtime Slice

The next implementation step should add a dedicated proxy command, likely one of:

- `codex-oauth serve`
- `codex-oauth proxy --listen 127.0.0.1:NNNN`

That runtime should:

1. read account snapshots from `~/.codex/accounts/*.auth.json`
2. build upstream credentials from each snapshot
3. accept OpenAI-compatible requests from a local client
4. call `proxy_router` to choose the first account
5. forward the request upstream
6. on failure, call `markUnavailable(...)` and retry with the next eligible account
7. on success, call `clearSuccess(...)`

## Deliberate Non-Goals For This Slice

- no registry schema changes yet
- no persisted proxy lock state yet
- no CLI config surface yet
- no streaming translation/runtime server yet

Those pieces should be added only after the proxy runtime contract is stable.

## Managed Proxy Daemon

Once the runtime is stable, `codex-oauth proxy-daemon` can install a managed service for each platform (systemd user service on Linux, LaunchAgent on macOS, and a scheduled task on Windows) that wraps `codex-oauth serve`. This keeps the local proxy available without a dedicated terminal window while still respecting the existing proxy configuration (`codex-oauth config proxy`).
