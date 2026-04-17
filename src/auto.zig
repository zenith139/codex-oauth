const std = @import("std");
const account_api = @import("account_api.zig");
const account_name_refresh = @import("account_name_refresh.zig");
const auth = @import("auth.zig");
const builtin = @import("builtin");
const c_time = @cImport({
    @cInclude("time.h");
});
const cli = @import("cli.zig");
const io_util = @import("io_util.zig");
const registry = @import("registry.zig");
const sessions = @import("sessions.zig");
const usage_api = @import("usage_api.zig");
const version = @import("version.zig");
const managed_service = @import("managed_service.zig");
const proxy_module = @import("proxy.zig");

const auto_service_exec_args = [_][]const u8{ "daemon", "--watch" };
const auto_service_spec = managed_service.ManagedServiceSpec{
    .description = "codex-oauth auto-switch watcher",
    .linux_service_name = "codex-oauth-autoswitch.service",
    .linux_legacy_timer_name = "codex-oauth-autoswitch.timer",
    .mac_label = "com.zenith139.codex-oauth.auto",
    .windows_task_name = "CodexOAuthAutoSwitch",
    .windows_helper_name = "codex-oauth-auto.exe",
    .exec_args = &auto_service_exec_args,
};

pub fn autoServiceSpec() managed_service.ManagedServiceSpec {
    return auto_service_spec;
}
const lock_file_name = "auto-switch.lock";
const watch_poll_interval_ns = 1 * std.time.ns_per_s;
const api_refresh_interval_ns = 60 * std.time.ns_per_s;
const free_plan_realtime_guard_5h_percent: i64 = 35;
pub const RuntimeState = managed_service.RuntimeState;

pub const Status = struct {
    enabled: bool,
    runtime: RuntimeState,
    threshold_5h_percent: u8,
    threshold_weekly_percent: u8,
    api_usage_enabled: bool,
    api_account_enabled: bool,
    proxy_listen_host: []const u8,
    proxy_listen_port: u16,
    proxy_strategy: registry.ProxyStrategy,
    proxy_sticky_round_robin_limit: u32,
    proxy_api_key_masked: []const u8,
    proxy_daemon_enabled: bool,
    proxy_daemon_runtime: RuntimeState,
};

pub const AutoSwitchAttempt = struct {
    refreshed_candidates: bool,
    state_changed: bool = false,
    switched: bool,
};

const CandidateScore = struct {
    value: i64,
    last_usage_at: i64,
    created_at: i64,
};

const candidate_upkeep_refresh_limit: usize = 1;
const candidate_switch_validation_limit: usize = 3;

const CandidateEntry = struct {
    account_key: []const u8,
    score: CandidateScore,
};

const CandidateIndex = struct {
    heap: std.ArrayListUnmanaged(CandidateEntry) = .empty,
    positions: std.StringHashMapUnmanaged(usize) = .empty,
    next_score_change_at: ?i64 = null,

    fn deinit(self: *CandidateIndex, allocator: std.mem.Allocator) void {
        self.heap.deinit(allocator);
        self.positions.deinit(allocator);
        self.* = .{};
    }

    fn rebuild(self: *CandidateIndex, allocator: std.mem.Allocator, reg: *const registry.Registry, now: i64) !void {
        self.deinit(allocator);
        const active = reg.active_account_key;
        for (reg.accounts.items) |*rec| {
            if (active) |account_key| {
                if (std.mem.eql(u8, rec.account_key, account_key)) continue;
            }
            try self.insert(allocator, .{
                .account_key = rec.account_key,
                .score = candidateScore(rec, now),
            });
        }
        self.refreshNextScoreChangeAt(reg, now);
    }

    fn rebuildIfScoreExpired(
        self: *CandidateIndex,
        allocator: std.mem.Allocator,
        reg: *const registry.Registry,
        now: i64,
    ) !void {
        if (self.next_score_change_at) |deadline| {
            if (deadline <= now) {
                try self.rebuild(allocator, reg, now);
            }
        }
    }

    fn best(self: *const CandidateIndex) ?CandidateEntry {
        if (self.heap.items.len == 0) return null;
        return self.heap.items[0];
    }

    fn insert(self: *CandidateIndex, allocator: std.mem.Allocator, entry: CandidateEntry) !void {
        try self.heap.append(allocator, entry);
        const idx = self.heap.items.len - 1;
        try self.positions.put(allocator, entry.account_key, idx);
        _ = self.siftUp(idx);
    }

    fn remove(self: *CandidateIndex, account_key: []const u8) void {
        const idx = self.positions.get(account_key) orelse return;
        _ = self.positions.remove(account_key);
        const last_idx = self.heap.items.len - 1;
        if (idx != last_idx) {
            self.heap.items[idx] = self.heap.items[last_idx];
            if (self.positions.getPtr(self.heap.items[idx].account_key)) |ptr| {
                ptr.* = idx;
            }
        }
        self.heap.items.len = last_idx;
        if (idx < self.heap.items.len) {
            self.restore(idx);
        }
    }

    fn upsertFromRegistry(self: *CandidateIndex, allocator: std.mem.Allocator, reg: *registry.Registry, account_key: []const u8, now: i64) !void {
        if (reg.active_account_key) |active| {
            if (std.mem.eql(u8, active, account_key)) {
                self.remove(account_key);
                self.refreshNextScoreChangeAt(reg, now);
                return;
            }
        }

        const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse {
            self.remove(account_key);
            self.refreshNextScoreChangeAt(reg, now);
            return;
        };
        const entry: CandidateEntry = .{
            .account_key = reg.accounts.items[idx].account_key,
            .score = candidateScore(&reg.accounts.items[idx], now),
        };
        if (self.positions.get(entry.account_key)) |heap_idx| {
            self.heap.items[heap_idx] = entry;
            self.restore(heap_idx);
            self.refreshNextScoreChangeAt(reg, now);
            return;
        }
        try self.insert(allocator, entry);
        self.refreshNextScoreChangeAt(reg, now);
    }

    fn handleActiveSwitch(
        self: *CandidateIndex,
        allocator: std.mem.Allocator,
        reg: *registry.Registry,
        old_active_account_key: []const u8,
        new_active_account_key: []const u8,
        now: i64,
    ) !void {
        self.remove(new_active_account_key);
        try self.upsertFromRegistry(allocator, reg, old_active_account_key, now);
    }

    fn refreshNextScoreChangeAt(self: *CandidateIndex, reg: *const registry.Registry, now: i64) void {
        const active = reg.active_account_key;
        var next_score_change_at: ?i64 = null;
        for (reg.accounts.items) |*rec| {
            if (active) |account_key| {
                if (std.mem.eql(u8, rec.account_key, account_key)) continue;
            }
            next_score_change_at = earlierFutureTimestamp(
                next_score_change_at,
                candidateScoreChangeAt(rec.last_usage, now),
                now,
            );
        }
        self.next_score_change_at = next_score_change_at;
    }

    fn orderedKeys(self: *const CandidateIndex, allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
        var ordered = try std.ArrayList([]const u8).initCapacity(allocator, self.heap.items.len);
        for (self.heap.items) |entry| {
            try ordered.append(allocator, entry.account_key);
        }
        std.sort.block([]const u8, ordered.items, self, candidateEntryLessThan);
        return ordered;
    }

    fn candidateEntryLessThan(self: *const CandidateIndex, lhs: []const u8, rhs: []const u8) bool {
        const left_idx = self.positions.get(lhs) orelse return false;
        const right_idx = self.positions.get(rhs) orelse return false;
        const left = self.heap.items[left_idx].score;
        const right = self.heap.items[right_idx].score;
        return candidateBetter(left, right);
    }

    fn restore(self: *CandidateIndex, idx: usize) void {
        if (!self.siftUp(idx)) {
            self.siftDown(idx);
        }
    }

    fn siftUp(self: *CandidateIndex, start_idx: usize) bool {
        var idx = start_idx;
        var moved = false;
        while (idx > 0) {
            const parent_idx = (idx - 1) / 2;
            if (!candidateBetter(self.heap.items[idx].score, self.heap.items[parent_idx].score)) break;
            self.swap(idx, parent_idx);
            idx = parent_idx;
            moved = true;
        }
        return moved;
    }

    fn siftDown(self: *CandidateIndex, start_idx: usize) void {
        var idx = start_idx;
        while (true) {
            const left = idx * 2 + 1;
            if (left >= self.heap.items.len) break;
            const right = left + 1;
            var best_idx = left;
            if (right < self.heap.items.len and candidateBetter(self.heap.items[right].score, self.heap.items[left].score)) {
                best_idx = right;
            }
            if (!candidateBetter(self.heap.items[best_idx].score, self.heap.items[idx].score)) break;
            self.swap(idx, best_idx);
            idx = best_idx;
        }
    }

    fn swap(self: *CandidateIndex, a: usize, b: usize) void {
        if (a == b) return;
        std.mem.swap(CandidateEntry, &self.heap.items[a], &self.heap.items[b]);
        if (self.positions.getPtr(self.heap.items[a].account_key)) |ptr| ptr.* = a;
        if (self.positions.getPtr(self.heap.items[b].account_key)) |ptr| ptr.* = b;
    }
};

pub const DaemonRefreshState = struct {
    last_api_refresh_at_ns: i128 = 0,
    last_api_refresh_account_key: ?[]u8 = null,
    last_account_name_refresh_at_ns: i128 = 0,
    last_account_name_refresh_account_key: ?[]u8 = null,
    pending_bad_account_key: ?[]u8 = null,
    pending_bad_rollout: ?registry.RolloutSignature = null,
    current_reg: ?registry.Registry = null,
    registry_mtime_ns: i128 = 0,
    auth_mtime_ns: i128 = 0,
    candidate_index: CandidateIndex = .{},
    candidate_check_times: std.StringHashMapUnmanaged(i128) = .empty,
    candidate_rejections: std.StringHashMapUnmanaged(bool) = .empty,
    rollout_scan_cache: sessions.RolloutScanCache = .{},

    pub fn deinit(self: *DaemonRefreshState, allocator: std.mem.Allocator) void {
        self.clearApiRefresh(allocator);
        self.clearAccountNameRefresh(allocator);
        self.clearPending(allocator);
        if (self.current_reg) |*reg| {
            self.candidate_index.deinit(allocator);
            self.candidate_check_times.deinit(allocator);
            self.candidate_rejections.deinit(allocator);
            reg.deinit(allocator);
            self.current_reg = null;
        } else {
            self.candidate_index.deinit(allocator);
            self.candidate_check_times.deinit(allocator);
            self.candidate_rejections.deinit(allocator);
        }
        self.rollout_scan_cache.deinit(allocator);
    }

    fn clearApiRefresh(self: *DaemonRefreshState, allocator: std.mem.Allocator) void {
        if (self.last_api_refresh_account_key) |account_key| {
            allocator.free(account_key);
        }
        self.last_api_refresh_account_key = null;
        self.last_api_refresh_at_ns = 0;
    }

    fn clearAccountNameRefresh(self: *DaemonRefreshState, allocator: std.mem.Allocator) void {
        if (self.last_account_name_refresh_account_key) |account_key| {
            allocator.free(account_key);
        }
        self.last_account_name_refresh_account_key = null;
        self.last_account_name_refresh_at_ns = 0;
    }

    fn clearPending(self: *DaemonRefreshState, allocator: std.mem.Allocator) void {
        if (self.pending_bad_account_key) |account_key| {
            allocator.free(account_key);
        }
        if (self.pending_bad_rollout) |*signature| {
            registry.freeRolloutSignature(allocator, signature);
        }
        self.pending_bad_account_key = null;
        self.pending_bad_rollout = null;
    }

    fn clearPendingIfAccountChanged(
        self: *DaemonRefreshState,
        allocator: std.mem.Allocator,
        active_account_key: ?[]const u8,
    ) void {
        if (self.pending_bad_account_key == null) return;
        if (active_account_key) |account_key| {
            if (std.mem.eql(u8, self.pending_bad_account_key.?, account_key)) return;
        }
        self.clearPending(allocator);
    }

    fn pendingMatches(self: *const DaemonRefreshState, account_key: []const u8, signature: registry.RolloutSignature) bool {
        if (self.pending_bad_account_key == null or self.pending_bad_rollout == null) return false;
        return std.mem.eql(u8, self.pending_bad_account_key.?, account_key) and
            registry.rolloutSignaturesEqual(self.pending_bad_rollout, signature);
    }

    fn setPending(
        self: *DaemonRefreshState,
        allocator: std.mem.Allocator,
        account_key: []const u8,
        signature: registry.RolloutSignature,
    ) !void {
        if (self.pendingMatches(account_key, signature)) return;
        self.clearPending(allocator);
        self.pending_bad_account_key = try allocator.dupe(u8, account_key);
        errdefer {
            allocator.free(self.pending_bad_account_key.?);
            self.pending_bad_account_key = null;
        }
        self.pending_bad_rollout = try registry.cloneRolloutSignature(allocator, signature);
    }

    fn resetApiCooldownIfAccountChanged(
        self: *DaemonRefreshState,
        allocator: std.mem.Allocator,
        active_account_key: []const u8,
    ) !void {
        if (self.last_api_refresh_account_key) |account_key| {
            if (std.mem.eql(u8, account_key, active_account_key)) return;
        }
        self.clearApiRefresh(allocator);
        self.last_api_refresh_account_key = try allocator.dupe(u8, active_account_key);
    }

    fn resetAccountNameCooldownIfAccountChanged(
        self: *DaemonRefreshState,
        allocator: std.mem.Allocator,
        active_account_key: []const u8,
    ) !void {
        if (self.last_account_name_refresh_account_key) |account_key| {
            if (std.mem.eql(u8, account_key, active_account_key)) return;
        }
        self.clearAccountNameRefresh(allocator);
        self.last_account_name_refresh_account_key = try allocator.dupe(u8, active_account_key);
    }

    fn currentRegistry(self: *DaemonRefreshState) *registry.Registry {
        return &self.current_reg.?;
    }

    fn ensureRegistryLoaded(self: *DaemonRefreshState, allocator: std.mem.Allocator, codex_home: []const u8) !*registry.Registry {
        if (self.current_reg == null) {
            try self.reloadRegistryState(allocator, codex_home);
            // Force the first daemon cycle to sync auth.json into accounts/ snapshots
            // before grouped account-name refresh looks for stored auth contexts.
            self.auth_mtime_ns = -1;
        } else {
            try self.reloadRegistryStateIfChanged(allocator, codex_home);
        }
        return self.currentRegistry();
    }

    fn reloadRegistryStateIfChanged(self: *DaemonRefreshState, allocator: std.mem.Allocator, codex_home: []const u8) !void {
        const registry_path = try registry.registryPath(allocator, codex_home);
        defer allocator.free(registry_path);
        const current_mtime = (try fileMtimeNsIfExists(registry_path)) orelse 0;
        if (self.current_reg == null or current_mtime != self.registry_mtime_ns) {
            try self.reloadRegistryState(allocator, codex_home);
        }
    }

    fn reloadRegistryState(self: *DaemonRefreshState, allocator: std.mem.Allocator, codex_home: []const u8) !void {
        var loaded = try registry.loadRegistry(allocator, codex_home);
        errdefer loaded.deinit(allocator);

        self.candidate_index.deinit(allocator);
        self.candidate_check_times.deinit(allocator);
        self.candidate_check_times = .empty;
        self.candidate_rejections.deinit(allocator);
        self.candidate_rejections = .empty;
        if (self.current_reg) |*reg| {
            reg.deinit(allocator);
        }
        self.current_reg = loaded;
        try self.candidate_index.rebuild(allocator, &self.current_reg.?, std.time.timestamp());
        try self.refreshTrackedFileMtims(allocator, codex_home);
    }

    fn rebuildCandidateState(self: *DaemonRefreshState, allocator: std.mem.Allocator) !void {
        if (self.current_reg == null) return;
        self.candidate_index.deinit(allocator);
        self.candidate_check_times.deinit(allocator);
        self.candidate_check_times = .empty;
        self.candidate_rejections.deinit(allocator);
        self.candidate_rejections = .empty;
        try self.candidate_index.rebuild(allocator, &self.current_reg.?, std.time.timestamp());
    }

    fn refreshTrackedFileMtims(self: *DaemonRefreshState, allocator: std.mem.Allocator, codex_home: []const u8) !void {
        const registry_path = try registry.registryPath(allocator, codex_home);
        defer allocator.free(registry_path);
        self.registry_mtime_ns = (try fileMtimeNsIfExists(registry_path)) orelse 0;

        const auth_path = try registry.activeAuthPath(allocator, codex_home);
        defer allocator.free(auth_path);
        self.auth_mtime_ns = (try fileMtimeNsIfExists(auth_path)) orelse 0;
    }

    fn syncActiveAuthIfChanged(self: *DaemonRefreshState, allocator: std.mem.Allocator, codex_home: []const u8) !bool {
        const auth_path = try registry.activeAuthPath(allocator, codex_home);
        defer allocator.free(auth_path);
        const current_auth_mtime = (try fileMtimeNsIfExists(auth_path)) orelse 0;
        if (self.current_reg != null and current_auth_mtime == self.auth_mtime_ns) return false;
        self.auth_mtime_ns = current_auth_mtime;
        if (self.current_reg == null) return false;
        if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &self.current_reg.?)) {
            try self.rebuildCandidateState(allocator);
            return true;
        }
        return false;
    }

    fn markCandidateChecked(self: *DaemonRefreshState, allocator: std.mem.Allocator, account_key: []const u8, now_ns: i128) !void {
        try self.candidate_check_times.put(allocator, account_key, now_ns);
    }

    fn candidateCheckedAt(self: *const DaemonRefreshState, account_key: []const u8) ?i128 {
        return self.candidate_check_times.get(account_key);
    }

    fn clearCandidateChecked(self: *DaemonRefreshState, account_key: []const u8) void {
        _ = self.candidate_check_times.remove(account_key);
    }

    fn markCandidateRejected(self: *DaemonRefreshState, allocator: std.mem.Allocator, account_key: []const u8) !void {
        try self.candidate_rejections.put(allocator, account_key, true);
    }

    fn clearCandidateRejected(self: *DaemonRefreshState, account_key: []const u8) void {
        _ = self.candidate_rejections.remove(account_key);
    }

    fn candidateIsRejected(self: *DaemonRefreshState, account_key: []const u8, now_ns: i128) bool {
        if (!self.candidate_rejections.contains(account_key)) return false;
        if (self.candidateIsStale(account_key, now_ns)) {
            self.clearCandidateRejected(account_key);
            return false;
        }
        return true;
    }

    fn candidateIsStale(self: *const DaemonRefreshState, account_key: []const u8, now_ns: i128) bool {
        const checked_at = self.candidateCheckedAt(account_key) orelse return true;
        return (now_ns - checked_at) >= api_refresh_interval_ns;
    }
};

const DaemonLock = struct {
    file: std.fs.File,

    fn acquire(allocator: std.mem.Allocator, codex_home: []const u8) !?DaemonLock {
        const path = try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", lock_file_name });
        defer allocator.free(path);
        var file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = false });
        errdefer file.close();
        if (!(try tryExclusiveLock(file))) {
            file.close();
            return null;
        }
        return .{ .file = file };
    }

    fn release(self: *DaemonLock) void {
        self.file.unlock();
        self.file.close();
    }
};

fn tryExclusiveLock(file: std.fs.File) !bool {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const range_off: windows.LARGE_INTEGER = 0;
        const range_len: windows.LARGE_INTEGER = 1;
        var io_status_block: windows.IO_STATUS_BLOCK = undefined;
        windows.LockFile(
            file.handle,
            null,
            null,
            null,
            &io_status_block,
            &range_off,
            &range_len,
            null,
            windows.TRUE,
            windows.TRUE,
        ) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => |e| return e,
        };
        return true;
    }

    return try file.tryLock(.exclusive);
}

pub fn helpStateLabel(enabled: bool) []const u8 {
    return if (enabled) "ON" else "OFF";
}

fn colorEnabled() bool {
    return std.fs.File.stdout().isTty();
}

pub fn printStatus(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const status = try getStatus(allocator, codex_home);
    defer allocator.free(@constCast(status.proxy_api_key_masked));
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    try writeStatusWithColor(stdout.out(), status, colorEnabled());
}

pub fn getStatus(allocator: std.mem.Allocator, codex_home: []const u8) !Status {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    const proxy_api_key_masked = try maskedProxyApiKeyAlloc(allocator, reg.proxy.api_key);
    return .{
        .enabled = reg.auto_switch.enabled,
        .runtime = queryRuntimeState(allocator),
        .threshold_5h_percent = reg.auto_switch.threshold_5h_percent,
        .threshold_weekly_percent = reg.auto_switch.threshold_weekly_percent,
        .api_usage_enabled = reg.api.usage,
        .api_account_enabled = reg.api.account,
        .proxy_listen_host = reg.proxy.listen_host,
        .proxy_listen_port = reg.proxy.listen_port,
        .proxy_strategy = reg.proxy.strategy,
        .proxy_sticky_round_robin_limit = reg.proxy.sticky_round_robin_limit,
        .proxy_api_key_masked = proxy_api_key_masked,
        .proxy_daemon_enabled = reg.proxy.daemon_enabled,
        .proxy_daemon_runtime = proxy_module.proxyDaemonRuntimeState(allocator),
    };
}

pub fn writeStatus(out: *std.Io.Writer, status: Status) !void {
    try writeStatusWithColor(out, status, false);
}

fn writeStatusWithColor(out: *std.Io.Writer, status: Status, use_color: bool) !void {
    _ = use_color;
    try out.writeAll("auto-switch: ");
    try out.writeAll(helpStateLabel(status.enabled));
    try out.writeAll("\n");

    try out.writeAll("service: ");
    try out.writeAll(@tagName(status.runtime));
    try out.writeAll("\n");

    try out.writeAll("thresholds: ");
    try out.print(
        "5h<{d}%, weekly<{d}%",
        .{ status.threshold_5h_percent, status.threshold_weekly_percent },
    );
    try out.writeAll("\n");

    try out.writeAll("usage: ");
    try out.writeAll(if (status.api_usage_enabled) "api" else "local");
    try out.writeAll("\n");

    try out.writeAll("account: ");
    try out.writeAll(if (status.api_account_enabled) "api" else "disabled");
    try out.writeAll("\n");

    try out.writeAll("proxy base-url: ");
    try out.print("http://{s}:{d}/v1", .{ status.proxy_listen_host, status.proxy_listen_port });
    try out.writeAll("\n");

    try out.writeAll("proxy strategy: ");
    try out.writeAll(switch (status.proxy_strategy) {
        .fill_first => "fill-first",
        .round_robin => "round-robin",
    });
    try out.writeAll("\n");

    try out.writeAll("proxy sticky-limit: ");
    try out.print("{d}", .{status.proxy_sticky_round_robin_limit});
    try out.writeAll("\n");

    try out.writeAll("proxy api-key: ");
    try out.writeAll(status.proxy_api_key_masked);
    try out.writeAll("\n");

    try out.writeAll("proxy daemon: ");
    try out.writeAll(helpStateLabel(status.proxy_daemon_enabled));
    try out.writeAll("\n");

    try out.writeAll("proxy daemon service: ");
    try out.writeAll(@tagName(status.proxy_daemon_runtime));
    try out.writeAll("\n");

    try out.flush();
}

fn maskedProxyApiKeyAlloc(allocator: std.mem.Allocator, api_key: ?[]const u8) ![]u8 {
    const key = api_key orelse return allocator.dupe(u8, "(not-generated)");
    if (key.len <= 8) return allocator.dupe(u8, key);
    return std.fmt.allocPrint(allocator, "{s}...{s}", .{ key[0..4], key[key.len - 4 ..] });
}

pub fn writeAutoSwitchLogLine(
    out: *std.Io.Writer,
    from: *const registry.AccountRecord,
    to: *const registry.AccountRecord,
) !void {
    try out.print("[switch] {s} -> {s}\n", .{ from.email, to.email });
    try out.flush();
}

fn emitAutoSwitchLog(from: *const registry.AccountRecord, to: *const registry.AccountRecord) void {
    var stderr_buffer: [256]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&stderr_buffer);
    writeAutoSwitchLogLine(&writer.interface, from, to) catch {};
}

const DaemonLogPriority = enum {
    err,
    warning,
    notice,
    info,
    debug,
};

fn emitDaemonLog(priority: DaemonLogPriority, comptime fmt: []const u8, args: anytype) void {
    _ = priority;
    var stderr_buffer: [512]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&stderr_buffer);
    writer.interface.print(fmt ++ "\n", args) catch {};
    writer.interface.flush() catch {};
}

fn emitTaggedDaemonLog(
    priority: DaemonLogPriority,
    tag: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    _ = priority;
    var stderr_buffer: [1024]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&stderr_buffer);
    writer.interface.print("[{s}] ", .{tag}) catch {};
    writer.interface.print(fmt ++ "\n", args) catch {};
    writer.interface.flush() catch {};
}

fn percentLabel(buf: *[5]u8, value: ?i64) []const u8 {
    const percent = value orelse return "-";
    const clamped = @min(@max(percent, 0), 100);
    return std.fmt.bufPrint(buf, "{d}%", .{clamped}) catch "-";
}

fn localDateTimeLabel(buf: *[19]u8, timestamp_ms: i64) []const u8 {
    const seconds = @divTrunc(timestamp_ms, std.time.ms_per_s);
    var tm: c_time.struct_tm = undefined;
    if (!localtimeCompat(seconds, &tm)) return "-";
    const year: u32 = @intCast(tm.tm_year + 1900);
    const month: u32 = @intCast(tm.tm_mon + 1);
    const day: u32 = @intCast(tm.tm_mday);
    const hour: u32 = @intCast(tm.tm_hour);
    const minute: u32 = @intCast(tm.tm_min);
    const second: u32 = @intCast(tm.tm_sec);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year,
        month,
        day,
        hour,
        minute,
        second,
    }) catch "-";
}

fn rolloutFileLabel(buf: *[96]u8, path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    return std.fmt.bufPrint(buf, "{s}", .{basename}) catch basename;
}

fn localtimeCompat(ts: i64, out_tm: *c_time.struct_tm) bool {
    if (comptime builtin.os.tag == .windows) {
        if (comptime @hasDecl(c_time, "_localtime64_s") and @hasDecl(c_time, "__time64_t")) {
            var t64 = std.math.cast(c_time.__time64_t, ts) orelse return false;
            return c_time._localtime64_s(out_tm, &t64) == 0;
        }
        return false;
    }

    var t = std.math.cast(c_time.time_t, ts) orelse return false;
    if (comptime @hasDecl(c_time, "localtime_r")) {
        return c_time.localtime_r(&t, out_tm) != null;
    }

    if (comptime @hasDecl(c_time, "localtime")) {
        const tm_ptr = c_time.localtime(&t);
        if (tm_ptr == null) return false;
        out_tm.* = tm_ptr.*;
        return true;
    }

    return false;
}

fn windowDurationLabel(buf: *[16]u8, window_minutes: ?i64) []const u8 {
    const minutes = window_minutes orelse return "unlabeled";
    if (minutes <= 0) return "unlabeled";
    if (@mod(minutes, 24 * 60) == 0) {
        return std.fmt.bufPrint(buf, "{d}d", .{@divExact(minutes, 24 * 60)}) catch "unlabeled";
    }
    if (@mod(minutes, 60) == 0) {
        return std.fmt.bufPrint(buf, "{d}h", .{@divExact(minutes, 60)}) catch "unlabeled";
    }
    return std.fmt.bufPrint(buf, "{d}m", .{minutes}) catch "unlabeled";
}

fn windowSnapshotLabel(buf: *[32]u8, window: ?registry.RateLimitWindow, now: i64) []const u8 {
    const resolved = window orelse return "-";
    var percent_buf: [5]u8 = undefined;
    var duration_buf: [16]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}@{s}", .{
        percentLabel(&percent_buf, registry.remainingPercentAt(resolved, now)),
        windowDurationLabel(&duration_buf, resolved.window_minutes),
    }) catch "-";
}

fn windowUsageEntryLabel(buf: *[24]u8, window: ?registry.RateLimitWindow, now: i64) []const u8 {
    const resolved = window orelse return "";
    var percent_buf: [5]u8 = undefined;
    var duration_buf: [16]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}={s}", .{
        windowDurationLabel(&duration_buf, resolved.window_minutes),
        percentLabel(&percent_buf, registry.remainingPercentAt(resolved, now)),
    }) catch "";
}

fn rolloutWindowsLabel(buf: *[64]u8, snapshot: registry.RateLimitSnapshot, now: i64) []const u8 {
    var primary_buf: [24]u8 = undefined;
    var secondary_buf: [24]u8 = undefined;
    const primary = windowUsageEntryLabel(&primary_buf, snapshot.primary, now);
    const secondary = windowUsageEntryLabel(&secondary_buf, snapshot.secondary, now);

    if (primary.len != 0 and secondary.len != 0) {
        return std.fmt.bufPrint(buf, "{s} {s}", .{ primary, secondary }) catch primary;
    }
    if (primary.len != 0) {
        return std.fmt.bufPrint(buf, "{s}", .{primary}) catch "no-usage-limits-window";
    }
    if (secondary.len != 0) {
        return std.fmt.bufPrint(buf, "{s}", .{secondary}) catch "no-usage-limits-window";
    }
    return "no-usage-limits-window";
}

fn fileMtimeNsIfExists(path: []const u8) !?i128 {
    const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return @as(i128, stat.mtime);
}

fn apiStatusLabel(buf: *[24]u8, status_code: ?u16, has_usage_windows: bool, missing_auth: bool) []const u8 {
    if (missing_auth) return "MissingAuth";
    if (status_code) |status| {
        if (status == 200 and !has_usage_windows) return "NoUsageLimitsWindow";
        return std.fmt.bufPrint(buf, "{d}", .{status}) catch "-";
    }
    return if (has_usage_windows) "-" else "NoUsageLimitsWindow";
}

fn fieldSeparator() []const u8 {
    return " | ";
}

pub fn handleAutoCommand(allocator: std.mem.Allocator, codex_home: []const u8, cmd: cli.AutoOptions) !void {
    switch (cmd) {
        .action => |action| switch (action) {
            .enable => try enable(allocator, codex_home),
            .disable => try disable(allocator, codex_home),
        },
        .configure => |opts| try configureThresholds(allocator, codex_home, opts),
    }
}

pub fn handleApiCommand(allocator: std.mem.Allocator, codex_home: []const u8, action: cli.ApiAction) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    const enabled = action == .enable;
    reg.api.usage = enabled;
    reg.api.account = enabled;
    try registry.saveRegistry(allocator, codex_home, &reg);
}

pub fn shouldEnsureManagedService(enabled: bool, runtime: RuntimeState, definition_matches: bool) bool {
    if (!enabled) return false;
    return runtime != .running or !definition_matches;
}

pub fn supportsManagedServiceOnPlatform(os_tag: std.Target.Os.Tag) bool {
    return managed_service.supportsManagedServiceOnPlatform(os_tag);
}

pub fn reconcileManagedService(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    if (!supportsManagedServiceOnPlatform(builtin.os.tag)) return;

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    if (!reg.auto_switch.enabled) {
        try managed_service.uninstallService(allocator, codex_home, auto_service_spec);
        return;
    }

    if (builtin.os.tag == .linux and !managed_service.linuxUserSystemdAvailable(allocator)) return;

    const runtime = managed_service.queryRuntimeState(allocator, auto_service_spec);
    const self_exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_exe);
    const managed_self_exe = try managed_service.managedServiceSelfExePath(allocator, self_exe);
    defer allocator.free(managed_self_exe);
    const definition_matches = try managed_service.currentServiceDefinitionMatches(allocator, codex_home, managed_self_exe, auto_service_spec);
    if (!shouldEnsureManagedService(reg.auto_switch.enabled, runtime, definition_matches)) return;

    try managed_service.installService(allocator, codex_home, managed_self_exe, auto_service_spec);
}

pub fn runDaemon(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    try registry.ensureAccountsDir(allocator, codex_home);
    var daemon_lock = (try DaemonLock.acquire(allocator, codex_home)) orelse return;
    defer daemon_lock.release();
    var refresh_state = DaemonRefreshState{};
    defer refresh_state.deinit(allocator);

    while (true) {
        const keep_running = daemonCycle(allocator, codex_home, &refresh_state) catch |err| blk: {
            std.log.err("auto daemon cycle failed: {s}", .{@errorName(err)});
            break :blk true;
        };
        if (!keep_running) return;
        std.Thread.sleep(watch_poll_interval_ns);
    }
}

pub fn runDaemonOnce(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    try registry.ensureAccountsDir(allocator, codex_home);
    var daemon_lock = (try DaemonLock.acquire(allocator, codex_home)) orelse return;
    defer daemon_lock.release();

    var refresh_state = DaemonRefreshState{};
    defer refresh_state.deinit(allocator);
    _ = try daemonCycle(allocator, codex_home, &refresh_state);
}

pub fn refreshActiveUsage(allocator: std.mem.Allocator, codex_home: []const u8, reg: *registry.Registry) !bool {
    return refreshActiveUsageWithApiFetcher(allocator, codex_home, reg, usage_api.fetchActiveUsage);
}

pub fn refreshListUsage(allocator: std.mem.Allocator, codex_home: []const u8, reg: *registry.Registry) !bool {
    return refreshListUsageWithDetailedApiFetcher(
        allocator,
        codex_home,
        reg,
        usage_api.fetchUsageForAuthPathDetailed,
    );
}

fn fetchActiveAccountNames(
    allocator: std.mem.Allocator,
    access_token: []const u8,
    account_id: []const u8,
) !account_api.FetchResult {
    return try account_api.fetchAccountsForTokenDetailed(
        allocator,
        account_api.default_account_endpoint,
        access_token,
        account_id,
    );
}

fn applyDaemonAccountNameEntriesToLatestRegistry(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    chatgpt_user_id: []const u8,
    entries: []const account_api.AccountEntry,
) !bool {
    var latest = try registry.loadRegistry(allocator, codex_home);
    defer latest.deinit(allocator);

    if (!latest.auto_switch.enabled or !latest.api.account) return false;
    if (!registry.shouldFetchTeamAccountNamesForUser(&latest, chatgpt_user_id)) return false;
    if (!try registry.applyAccountNamesForUser(allocator, &latest, chatgpt_user_id, entries)) return false;

    try registry.saveRegistry(allocator, codex_home, &latest);
    return true;
}

fn refreshActiveAccountNamesForDaemon(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
) !bool {
    return refreshActiveAccountNamesForDaemonWithFetcher(
        allocator,
        codex_home,
        reg,
        refresh_state,
        fetchActiveAccountNames,
    );
}

pub fn refreshActiveAccountNamesForDaemonWithFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
    fetcher: anytype,
) !bool {
    if (!reg.auto_switch.enabled) return false;
    if (!reg.api.account) return false;
    const account_key = reg.active_account_key orelse return false;
    try refresh_state.resetAccountNameCooldownIfAccountChanged(allocator, account_key);

    const now_ns = std.time.nanoTimestamp();
    if (refresh_state.last_account_name_refresh_at_ns != 0 and
        (now_ns - refresh_state.last_account_name_refresh_at_ns) < api_refresh_interval_ns)
    {
        return false;
    }

    var candidates = try account_name_refresh.collectCandidates(allocator, reg);
    defer {
        for (candidates.items) |*candidate| candidate.deinit(allocator);
        candidates.deinit(allocator);
    }
    if (candidates.items.len == 0) return false;

    var attempted = false;
    var changed = false;

    for (candidates.items) |candidate| {
        var latest = try registry.loadRegistry(allocator, codex_home);
        defer latest.deinit(allocator);

        if (!latest.auto_switch.enabled or !latest.api.account) continue;
        if (!registry.shouldFetchTeamAccountNamesForUser(&latest, candidate.chatgpt_user_id)) continue;

        var info = (try account_name_refresh.loadStoredAuthInfoForUser(
            allocator,
            codex_home,
            &latest,
            candidate.chatgpt_user_id,
        )) orelse continue;
        defer info.deinit(allocator);

        const access_token = info.access_token orelse continue;
        const chatgpt_account_id = info.chatgpt_account_id orelse continue;
        if (!attempted) {
            refresh_state.last_account_name_refresh_at_ns = now_ns;
            attempted = true;
        }

        const result = fetcher(allocator, access_token, chatgpt_account_id) catch |err| {
            std.log.warn("account metadata refresh skipped: {s}", .{@errorName(err)});
            continue;
        };
        defer result.deinit(allocator);

        const entries = result.entries orelse continue;
        if (try applyDaemonAccountNameEntriesToLatestRegistry(allocator, codex_home, candidate.chatgpt_user_id, entries)) {
            changed = true;
        }
    }

    return changed;
}

pub fn refreshActiveUsageWithApiFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    api_fetcher: anytype,
) !bool {
    if (reg.api.usage) {
        return switch (try refreshActiveUsageFromApi(allocator, codex_home, reg, api_fetcher)) {
            .updated => true,
            .unchanged, .unavailable => false,
        };
    }
    return refreshActiveUsageFromSessions(allocator, codex_home, reg);
}

pub fn refreshListUsageWithDetailedApiFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    api_fetcher: anytype,
) !bool {
    if (!reg.api.usage) {
        return refreshActiveUsageFromSessions(allocator, codex_home, reg);
    }

    var changed = false;
    for (reg.accounts.items) |rec| {
        const auth_path = registry.accountAuthPath(allocator, codex_home, rec.account_key) catch continue;
        defer allocator.free(auth_path);

        const fetch_result = api_fetcher(allocator, auth_path) catch continue;
        if (fetch_result.missing_auth) continue;
        if (fetch_result.status_code) |status_code| {
            if (status_code != 200) continue;
        }

        const latest_usage = fetch_result.snapshot orelse continue;
        var latest = latest_usage;
        var snapshot_consumed = false;
        defer if (!snapshot_consumed) registry.freeRateLimitSnapshot(allocator, &latest);

        if (registry.rateLimitSnapshotsEqual(rec.last_usage, latest)) continue;
        registry.updateUsage(allocator, reg, rec.account_key, latest);
        snapshot_consumed = true;
        changed = true;
    }

    return changed;
}

const ApiRefreshResult = enum { unavailable, unchanged, updated };

fn refreshActiveUsageFromApi(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    api_fetcher: anytype,
) !ApiRefreshResult {
    const latest_usage = api_fetcher(allocator, codex_home) catch return .unavailable;
    if (latest_usage == null) return .unavailable;

    var latest = latest_usage.?;
    var snapshot_consumed = false;
    defer if (!snapshot_consumed) registry.freeRateLimitSnapshot(allocator, &latest);

    const account_key = reg.active_account_key orelse return .unchanged;
    const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return .unchanged;
    if (registry.rateLimitSnapshotsEqual(reg.accounts.items[idx].last_usage, latest)) return .unchanged;

    registry.updateUsage(allocator, reg, account_key, latest);
    snapshot_consumed = true;
    return .updated;
}

fn refreshActiveUsageFromSessions(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
) !bool {
    const latest_usage = sessions.scanLatestUsageWithSource(allocator, codex_home) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (latest_usage == null) return false;
    var latest = latest_usage.?;
    var snapshot_consumed = false;
    defer {
        allocator.free(latest.path);
        if (!snapshot_consumed) {
            registry.freeRateLimitSnapshot(allocator, &latest.snapshot);
        }
    }
    const signature: registry.RolloutSignature = .{
        .path = latest.path,
        .event_timestamp_ms = latest.event_timestamp_ms,
    };
    const account_key = reg.active_account_key orelse return false;
    const activated_at_ms = reg.active_account_activated_at_ms orelse 0;
    if (latest.event_timestamp_ms < activated_at_ms) return false;
    const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return false;
    if (registry.rolloutSignaturesEqual(reg.accounts.items[idx].last_local_rollout, signature)) return false;
    registry.updateUsage(allocator, reg, account_key, latest.snapshot);
    snapshot_consumed = true;
    try registry.setAccountLastLocalRollout(allocator, &reg.accounts.items[idx], latest.path, latest.event_timestamp_ms);
    return true;
}

fn refreshActiveUsageForDaemon(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
) !bool {
    return refreshActiveUsageForDaemonWithDetailedApiFetcher(
        allocator,
        codex_home,
        reg,
        refresh_state,
        usage_api.fetchActiveUsageDetailed,
    );
}

fn refreshActiveUsageForDaemonWithDetailedApiFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
    api_fetcher: anytype,
) !bool {
    const account_key = reg.active_account_key orelse return false;
    refresh_state.clearPendingIfAccountChanged(allocator, account_key);
    try refresh_state.resetApiCooldownIfAccountChanged(allocator, account_key);
    const active_idx = registry.findAccountIndexByAccountKey(reg, account_key);

    if (try refreshActiveUsageFromSessionsForDaemon(allocator, codex_home, reg, refresh_state)) {
        return true;
    }
    if (!reg.api.usage) return false;

    const now_ns = std.time.nanoTimestamp();
    if (refresh_state.last_api_refresh_at_ns != 0 and (now_ns - refresh_state.last_api_refresh_at_ns) < api_refresh_interval_ns) {
        return false;
    }
    refresh_state.last_api_refresh_at_ns = now_ns;

    const fetch_result = api_fetcher(allocator, codex_home) catch |err| {
        emitTaggedDaemonLog(.warning, "api", "refresh usage{s}status={s}", .{
            fieldSeparator(),
            @errorName(err),
        });
        return false;
    };

    const latest_usage = fetch_result.snapshot;
    const status_code = fetch_result.status_code;
    const missing_auth = fetch_result.missing_auth;
    var status_buf: [24]u8 = undefined;
    if (latest_usage == null) {
        emitTaggedDaemonLog(.warning, "api", "refresh usage{s}status={s}", .{
            fieldSeparator(),
            apiStatusLabel(&status_buf, status_code, false, missing_auth),
        });
        return false;
    }

    var latest = latest_usage.?;
    var snapshot_consumed = false;
    defer if (!snapshot_consumed) registry.freeRateLimitSnapshot(allocator, &latest);

    if (active_idx == null) {
        emitTaggedDaemonLog(.debug, "api", "refresh usage{s}status={s}", .{
            fieldSeparator(),
            apiStatusLabel(&status_buf, status_code, true, missing_auth),
        });
        return false;
    }
    if (registry.rateLimitSnapshotsEqual(reg.accounts.items[active_idx.?].last_usage, latest)) {
        emitTaggedDaemonLog(.debug, "api", "refresh usage{s}status={s}", .{
            fieldSeparator(),
            apiStatusLabel(&status_buf, status_code, true, missing_auth),
        });
        refresh_state.clearPending(allocator);
        return false;
    }

    registry.updateUsage(allocator, reg, account_key, latest);
    snapshot_consumed = true;
    emitTaggedDaemonLog(.info, "api", "refresh usage{s}status={s}", .{
        fieldSeparator(),
        apiStatusLabel(&status_buf, status_code, true, missing_auth),
    });
    refresh_state.clearPending(allocator);
    return true;
}

pub fn refreshActiveUsageForDaemonWithApiFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
    api_fetcher: anytype,
) !bool {
    const account_key = reg.active_account_key orelse return false;
    refresh_state.clearPendingIfAccountChanged(allocator, account_key);
    try refresh_state.resetApiCooldownIfAccountChanged(allocator, account_key);
    if (try refreshActiveUsageFromSessionsForDaemon(allocator, codex_home, reg, refresh_state)) {
        return true;
    }
    if (!reg.api.usage) return false;

    const now_ns = std.time.nanoTimestamp();
    if (refresh_state.last_api_refresh_at_ns != 0 and (now_ns - refresh_state.last_api_refresh_at_ns) < api_refresh_interval_ns) {
        return false;
    }
    refresh_state.last_api_refresh_at_ns = now_ns;

    return switch (try refreshActiveUsageFromApi(allocator, codex_home, reg, api_fetcher)) {
        .updated => blk: {
            emitTaggedDaemonLog(.info, "api", "refresh usage{s}status=200", .{fieldSeparator()});
            refresh_state.clearPending(allocator);
            break :blk true;
        },
        .unchanged => blk: {
            emitTaggedDaemonLog(.debug, "api", "refresh usage{s}status=200", .{fieldSeparator()});
            refresh_state.clearPending(allocator);
            break :blk false;
        },
        .unavailable => blk: {
            emitTaggedDaemonLog(.warning, "api", "refresh usage{s}status=NoUsageLimitsWindow", .{fieldSeparator()});
            break :blk false;
        },
    };
}

fn refreshActiveUsageFromSessionsForDaemon(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
) !bool {
    var latest_event = (sessions.scanLatestRolloutEventWithCache(allocator, codex_home, &refresh_state.rollout_scan_cache) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    }) orelse return false;
    defer latest_event.deinit(allocator);

    const account_key = reg.active_account_key orelse return false;
    const activated_at_ms = reg.active_account_activated_at_ms orelse 0;
    if (latest_event.event_timestamp_ms < activated_at_ms) return false;

    const signature: registry.RolloutSignature = .{
        .path = latest_event.path,
        .event_timestamp_ms = latest_event.event_timestamp_ms,
    };
    const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return false;
    if (registry.rolloutSignaturesEqual(reg.accounts.items[idx].last_local_rollout, signature)) {
        refresh_state.clearPending(allocator);
        return false;
    }

    var event_time_buf: [19]u8 = undefined;
    const event_time = localDateTimeLabel(&event_time_buf, latest_event.event_timestamp_ms);
    var file_buf: [96]u8 = undefined;
    const file_label = rolloutFileLabel(&file_buf, latest_event.path);

    if (!latest_event.hasUsableWindows()) {
        if (try applyLatestUsableSnapshotFromRolloutFile(
            allocator,
            reg,
            account_key,
            idx,
            latest_event.path,
            latest_event.mtime,
            activated_at_ms,
        )) {
            refresh_state.clearPending(allocator);
            return true;
        }
        if (refresh_state.pendingMatches(account_key, signature)) {
            return false;
        }
        emitTaggedDaemonLog(.warning, "local", "no usage limits window{s}fallback-to-api{s}event={s}{s}file={s}", .{
            fieldSeparator(),
            fieldSeparator(),
            event_time,
            fieldSeparator(),
            file_label,
        });
        try refresh_state.setPending(allocator, account_key, signature);
        return false;
    }

    const now = std.time.timestamp();
    var windows_buf: [64]u8 = undefined;
    emitTaggedDaemonLog(.notice, "local", "{s}{s}event={s}{s}file={s}", .{
        rolloutWindowsLabel(&windows_buf, latest_event.snapshot.?, now),
        fieldSeparator(),
        event_time,
        fieldSeparator(),
        file_label,
    });
    registry.updateUsage(allocator, reg, account_key, latest_event.snapshot.?);
    latest_event.snapshot = null;
    try registry.setAccountLastLocalRollout(allocator, &reg.accounts.items[idx], latest_event.path, latest_event.event_timestamp_ms);
    refresh_state.clearPending(allocator);
    return true;
}

fn applyLatestUsableSnapshotFromRolloutFile(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    account_key: []const u8,
    idx: usize,
    rollout_path: []const u8,
    rollout_mtime: i64,
    activated_at_ms: i64,
) !bool {
    const latest_usage = sessions.scanLatestUsableUsageInFile(allocator, rollout_path, rollout_mtime) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (latest_usage == null) return false;

    var usable = latest_usage.?;
    var snapshot_consumed = false;
    defer {
        allocator.free(usable.path);
        if (!snapshot_consumed) {
            registry.freeRateLimitSnapshot(allocator, &usable.snapshot);
        }
    }

    if (usable.event_timestamp_ms < activated_at_ms) return false;

    const usable_signature: registry.RolloutSignature = .{
        .path = usable.path,
        .event_timestamp_ms = usable.event_timestamp_ms,
    };
    if (registry.rolloutSignaturesEqual(reg.accounts.items[idx].last_local_rollout, usable_signature)) {
        return false;
    }

    registry.updateUsage(allocator, reg, account_key, usable.snapshot);
    snapshot_consumed = true;
    try registry.setAccountLastLocalRollout(allocator, &reg.accounts.items[idx], usable.path, usable.event_timestamp_ms);
    return true;
}

pub fn bestAutoSwitchCandidateIndex(reg: *registry.Registry, now: i64) ?usize {
    const active = reg.active_account_key orelse return null;
    var best_idx: ?usize = null;
    var best: ?CandidateScore = null;
    for (reg.accounts.items, 0..) |*rec, idx| {
        if (std.mem.eql(u8, rec.account_key, active)) continue;
        const score = candidateScore(rec, now);
        if (best == null or candidateBetter(score, best.?)) {
            best = score;
            best_idx = idx;
        }
    }
    return best_idx;
}

pub fn shouldSwitchCurrent(reg: *registry.Registry, now: i64) bool {
    const account_key = reg.active_account_key orelse return false;
    const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return false;
    const rec = &reg.accounts.items[idx];
    const resolved_5h = resolve5hTriggerWindow(rec.last_usage);
    const threshold_5h_percent = effective5hThresholdPercent(reg, rec, resolved_5h.allow_free_guard);
    const rem_5h = registry.remainingPercentAt(resolved_5h.window, now);
    const rem_week = registry.remainingPercentAt(registry.resolveRateWindow(rec.last_usage, 10080, false), now);
    return (rem_5h != null and rem_5h.? < threshold_5h_percent) or
        (rem_week != null and rem_week.? < @as(i64, reg.auto_switch.threshold_weekly_percent));
}

fn effective5hThresholdPercent(reg: *registry.Registry, rec: *const registry.AccountRecord, allow_free_guard: bool) i64 {
    var threshold = @as(i64, reg.auto_switch.threshold_5h_percent);
    if (allow_free_guard and registry.resolvePlan(rec) == .free) {
        threshold = @max(threshold, free_plan_realtime_guard_5h_percent);
    }
    return threshold;
}

pub fn maybeAutoSwitch(allocator: std.mem.Allocator, codex_home: []const u8, reg: *registry.Registry) !bool {
    const attempt = try maybeAutoSwitchWithUsageFetcher(allocator, codex_home, reg, usage_api.fetchUsageForAuthPath);
    return attempt.switched;
}

pub fn maybeAutoSwitchWithUsageFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_fetcher: anytype,
) !AutoSwitchAttempt {
    return maybeAutoSwitchWithUsageFetcherAndRefreshState(allocator, codex_home, reg, null, usage_fetcher);
}

pub fn maybeAutoSwitchForDaemonWithUsageFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
    usage_fetcher: anytype,
) !AutoSwitchAttempt {
    if (!reg.auto_switch.enabled) return .{ .refreshed_candidates = false, .switched = false };
    const now = std.time.timestamp();
    if (refresh_state.current_reg == null and refresh_state.candidate_index.heap.items.len == 0) {
        try refresh_state.candidate_index.rebuild(allocator, reg, now);
    } else {
        try refresh_state.candidate_index.rebuildIfScoreExpired(allocator, reg, now);
    }
    const active = reg.active_account_key orelse return .{ .refreshed_candidates = false, .switched = false };
    const now_ns = std.time.nanoTimestamp();
    const active_idx = registry.findAccountIndexByAccountKey(reg, active) orelse return .{
        .refreshed_candidates = false,
        .switched = false,
    };
    const current = candidateScore(&reg.accounts.items[active_idx], now);
    const should_switch_current = shouldSwitchCurrent(reg, now);

    var changed = false;
    var refreshed_candidates = false;

    if (reg.api.usage and !should_switch_current) {
        const upkeep = try refreshDaemonCandidateUpkeepWithUsageFetcher(
            allocator,
            codex_home,
            reg,
            refresh_state,
            usage_fetcher,
            now,
            now_ns,
        );
        refreshed_candidates = upkeep.attempted != 0;
        changed = upkeep.updated != 0;
    }

    if (!should_switch_current) {
        return .{
            .refreshed_candidates = refreshed_candidates,
            .state_changed = changed,
            .switched = false,
        };
    }

    if (reg.api.usage) {
        var skipped_candidates = std.ArrayListUnmanaged([]const u8).empty;
        defer skipped_candidates.deinit(allocator);
        const validation = try refreshDaemonSwitchCandidatesWithUsageFetcher(
            allocator,
            codex_home,
            reg,
            refresh_state,
            usage_fetcher,
            now,
            now_ns,
            &skipped_candidates,
        );
        refreshed_candidates = refreshed_candidates or validation.attempted != 0;
        changed = changed or validation.updated != 0;

        const best_candidate_key = (try bestDaemonCandidateForSwitch(allocator, refresh_state, skipped_candidates.items, now_ns)) orelse return .{
            .refreshed_candidates = refreshed_candidates,
            .state_changed = changed,
            .switched = false,
        };
        const candidate_idx = registry.findAccountIndexByAccountKey(reg, best_candidate_key) orelse return .{
            .refreshed_candidates = refreshed_candidates,
            .state_changed = changed,
            .switched = false,
        };
        const candidate = candidateScore(&reg.accounts.items[candidate_idx], now);
        if (candidate.value <= current.value) {
            return .{
                .refreshed_candidates = refreshed_candidates,
                .state_changed = changed,
                .switched = false,
            };
        }

        const previous_active_key = reg.accounts.items[active_idx].account_key;
        const next_active_key = reg.accounts.items[candidate_idx].account_key;
        try registry.activateAccountByKey(allocator, codex_home, reg, next_active_key);
        try refresh_state.candidate_index.handleActiveSwitch(
            allocator,
            reg,
            previous_active_key,
            next_active_key,
            std.time.timestamp(),
        );
        try refresh_state.markCandidateChecked(allocator, previous_active_key, now_ns);
        refresh_state.clearCandidateChecked(next_active_key);
        return .{
            .refreshed_candidates = refreshed_candidates,
            .state_changed = true,
            .switched = true,
        };
    }

    const candidate_entry = refresh_state.candidate_index.best() orelse return .{
        .refreshed_candidates = refreshed_candidates,
        .state_changed = changed,
        .switched = false,
    };
    const candidate_idx = registry.findAccountIndexByAccountKey(reg, candidate_entry.account_key) orelse return .{
        .refreshed_candidates = refreshed_candidates,
        .state_changed = changed,
        .switched = false,
    };
    const candidate = candidateScore(&reg.accounts.items[candidate_idx], now);
    if (candidate.value <= current.value) {
        return .{
            .refreshed_candidates = refreshed_candidates,
            .state_changed = changed,
            .switched = false,
        };
    }

    const previous_active_key = reg.accounts.items[active_idx].account_key;
    const next_active_key = reg.accounts.items[candidate_idx].account_key;
    try registry.activateAccountByKey(allocator, codex_home, reg, next_active_key);
    try refresh_state.candidate_index.handleActiveSwitch(
        allocator,
        reg,
        previous_active_key,
        next_active_key,
        std.time.timestamp(),
    );
    try refresh_state.markCandidateChecked(allocator, previous_active_key, now_ns);
    refresh_state.clearCandidateChecked(next_active_key);
    return .{
        .refreshed_candidates = refreshed_candidates,
        .state_changed = true,
        .switched = true,
    };
}

fn maybeAutoSwitchWithUsageFetcherAndRefreshState(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: ?*DaemonRefreshState,
    usage_fetcher: anytype,
) !AutoSwitchAttempt {
    if (!reg.auto_switch.enabled) return .{ .refreshed_candidates = false, .switched = false };
    const active = reg.active_account_key orelse return .{ .refreshed_candidates = false, .switched = false };
    const now = std.time.timestamp();
    if (!shouldSwitchCurrent(reg, now)) return .{ .refreshed_candidates = false, .switched = false };

    _ = refresh_state;
    const should_refresh_candidates = reg.api.usage;

    const refreshed_candidates = if (should_refresh_candidates)
        try refreshAutoSwitchCandidatesWithUsageFetcher(allocator, codex_home, reg, usage_fetcher)
    else
        false;

    const active_idx = registry.findAccountIndexByAccountKey(reg, active) orelse return .{
        .refreshed_candidates = refreshed_candidates,
        .switched = false,
    };
    const current = candidateScore(&reg.accounts.items[active_idx], now);
    const candidate_idx = bestAutoSwitchCandidateIndex(reg, now) orelse return .{
        .refreshed_candidates = refreshed_candidates,
        .switched = false,
    };
    const candidate = candidateScore(&reg.accounts.items[candidate_idx], now);
    if (candidate.value <= current.value) {
        return .{
            .refreshed_candidates = refreshed_candidates,
            .switched = false,
        };
    }

    try registry.activateAccountByKey(allocator, codex_home, reg, reg.accounts.items[candidate_idx].account_key);
    return .{ .refreshed_candidates = refreshed_candidates, .state_changed = true, .switched = true };
}

fn refreshAutoSwitchCandidatesWithUsageFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    usage_fetcher: anytype,
) !bool {
    const active = reg.active_account_key orelse return false;
    var changed = false;
    var attempted: usize = 0;
    var updated: usize = 0;

    for (reg.accounts.items) |rec| {
        if (std.mem.eql(u8, rec.account_key, active)) continue;
        if (rec.auth_mode != null and rec.auth_mode.? != .chatgpt) continue;
        attempted += 1;

        const auth_path = registry.accountAuthPath(allocator, codex_home, rec.account_key) catch continue;
        defer allocator.free(auth_path);

        const latest_usage = usage_fetcher(allocator, auth_path) catch continue;
        if (latest_usage == null) continue;

        var latest = latest_usage.?;
        var snapshot_consumed = false;
        defer if (!snapshot_consumed) registry.freeRateLimitSnapshot(allocator, &latest);

        if (registry.rateLimitSnapshotsEqual(rec.last_usage, latest)) continue;
        registry.updateUsage(allocator, reg, rec.account_key, latest);
        snapshot_consumed = true;
        changed = true;
        updated += 1;
    }

    return changed;
}

const CandidateRefreshSummary = struct {
    attempted: usize = 0,
    updated: usize = 0,
};

fn keyIsSkipped(skipped_keys: []const []const u8, account_key: []const u8) bool {
    for (skipped_keys) |skipped| {
        if (std.mem.eql(u8, skipped, account_key)) return true;
    }
    return false;
}

fn bestDaemonCandidateForSwitch(
    allocator: std.mem.Allocator,
    refresh_state: *DaemonRefreshState,
    skipped_keys: []const []const u8,
    now_ns: i128,
) !?[]const u8 {
    var ordered = try refresh_state.candidate_index.orderedKeys(allocator);
    defer ordered.deinit(allocator);

    for (ordered.items) |account_key| {
        if (refresh_state.candidateIsRejected(account_key, now_ns)) continue;
        if (!keyIsSkipped(skipped_keys, account_key)) return account_key;
    }
    return null;
}

fn refreshDaemonCandidateUpkeepWithUsageFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
    usage_fetcher: anytype,
    now: i64,
    now_ns: i128,
) !CandidateRefreshSummary {
    var ordered = try refresh_state.candidate_index.orderedKeys(allocator);
    defer ordered.deinit(allocator);

    var summary: CandidateRefreshSummary = .{};
    for (ordered.items) |account_key| {
        if (!refresh_state.candidateIsStale(account_key, now_ns)) break;
        const result = try refreshDaemonCandidateUsageByKeyWithFetcher(
            allocator,
            codex_home,
            reg,
            refresh_state,
            account_key,
            usage_fetcher,
            now_ns,
        );
        summary.attempted += result.attempted;
        summary.updated += result.updated;
        if (result.visited) break;
    }

    _ = now;
    return summary;
}

fn refreshDaemonSwitchCandidatesWithUsageFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
    usage_fetcher: anytype,
    now: i64,
    now_ns: i128,
    skipped_keys: *std.ArrayListUnmanaged([]const u8),
) !CandidateRefreshSummary {
    var summary: CandidateRefreshSummary = .{};
    var visited: usize = 0;
    while (visited < candidate_switch_validation_limit) : (visited += 1) {
        const best_account_key = (try bestDaemonCandidateForSwitch(allocator, refresh_state, skipped_keys.items, now_ns)) orelse break;
        if (!refresh_state.candidateIsStale(best_account_key, now_ns)) break;

        const result = try refreshDaemonCandidateUsageByKeyWithFetcher(
            allocator,
            codex_home,
            reg,
            refresh_state,
            best_account_key,
            usage_fetcher,
            now_ns,
        );
        summary.attempted += result.attempted;
        summary.updated += result.updated;
        if (result.disqualify_for_switch) {
            try skipped_keys.append(allocator, best_account_key);
        }
        if (!result.visited) break;
    }

    _ = now;
    return summary;
}

const SingleCandidateRefreshResult = struct {
    visited: bool = false,
    attempted: usize = 0,
    updated: usize = 0,
    disqualify_for_switch: bool = false,
};

fn refreshDaemonCandidateUsageByKeyWithFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    refresh_state: *DaemonRefreshState,
    account_key: []const u8,
    usage_fetcher: anytype,
    now_ns: i128,
) !SingleCandidateRefreshResult {
    const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return .{};
    const rec = &reg.accounts.items[idx];

    if (rec.auth_mode != null and rec.auth_mode.? != .chatgpt) {
        try refresh_state.markCandidateChecked(allocator, account_key, now_ns);
        refresh_state.clearCandidateRejected(account_key);
        return .{ .visited = true };
    }

    const auth_path = registry.accountAuthPath(allocator, codex_home, account_key) catch {
        try refresh_state.markCandidateChecked(allocator, account_key, now_ns);
        return .{ .visited = true };
    };
    defer allocator.free(auth_path);

    try refresh_state.markCandidateChecked(allocator, account_key, now_ns);
    const fetch_result = usage_fetcher(allocator, auth_path) catch {
        return .{
            .visited = true,
            .attempted = 1,
        };
    };
    if (fetch_result.missing_auth) {
        try refresh_state.markCandidateRejected(allocator, account_key);
        return .{
            .visited = true,
            .attempted = 1,
            .disqualify_for_switch = true,
        };
    }
    if (fetch_result.status_code) |status_code| {
        if (status_code != 200) {
            try refresh_state.markCandidateRejected(allocator, account_key);
            return .{
                .visited = true,
                .attempted = 1,
                .disqualify_for_switch = true,
            };
        }
    }

    const latest_usage = fetch_result.snapshot;
    if (latest_usage == null) {
        if (fetch_result.status_code != null) {
            try refresh_state.markCandidateRejected(allocator, account_key);
        }
        return .{
            .visited = true,
            .attempted = 1,
            .disqualify_for_switch = fetch_result.status_code != null,
        };
    }

    var latest = latest_usage.?;
    var snapshot_consumed = false;
    defer if (!snapshot_consumed) registry.freeRateLimitSnapshot(allocator, &latest);

    refresh_state.clearCandidateRejected(account_key);

    if (registry.rateLimitSnapshotsEqual(rec.last_usage, latest)) {
        return .{ .visited = true, .attempted = 1 };
    }

    registry.updateUsage(allocator, reg, account_key, latest);
    snapshot_consumed = true;
    try refresh_state.candidate_index.upsertFromRegistry(allocator, reg, account_key, std.time.timestamp());
    return .{ .visited = true, .attempted = 1, .updated = 1 };
}

const Resolved5hWindow = struct {
    window: ?registry.RateLimitWindow,
    allow_free_guard: bool,
};

fn resolve5hTriggerWindow(usage: ?registry.RateLimitSnapshot) Resolved5hWindow {
    if (usage == null) return .{ .window = null, .allow_free_guard = false };
    if (usage.?.primary) |primary| {
        if (primary.window_minutes == null) {
            return .{ .window = primary, .allow_free_guard = true };
        }
        if (primary.window_minutes.? == 300) {
            return .{ .window = primary, .allow_free_guard = true };
        }
    }
    if (usage.?.secondary) |secondary| {
        if (secondary.window_minutes != null and secondary.window_minutes.? == 300) {
            return .{ .window = secondary, .allow_free_guard = true };
        }
    }
    if (usage.?.primary) |primary| {
        return .{ .window = primary, .allow_free_guard = false };
    }
    return .{ .window = null, .allow_free_guard = false };
}

fn daemonCycleWithAccountNameFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    refresh_state: *DaemonRefreshState,
    account_name_fetcher: anytype,
) !bool {
    var reg = try refresh_state.ensureRegistryLoaded(allocator, codex_home);
    if (!reg.auto_switch.enabled) return false;

    var changed = false;
    if (try refresh_state.syncActiveAuthIfChanged(allocator, codex_home)) {
        changed = true;
    }

    if (changed) {
        try registry.saveRegistry(allocator, codex_home, reg);
        try refresh_state.refreshTrackedFileMtims(allocator, codex_home);
        changed = false;
    }

    if (try refreshActiveAccountNamesForDaemonWithFetcher(allocator, codex_home, reg, refresh_state, account_name_fetcher)) {
        changed = true;
    }
    try refresh_state.reloadRegistryStateIfChanged(allocator, codex_home);
    reg = refresh_state.currentRegistry();
    if (!reg.auto_switch.enabled) return true;

    if (try refreshActiveUsageForDaemon(allocator, codex_home, reg, refresh_state)) {
        changed = true;
    }
    const active_idx_before = if (reg.active_account_key) |account_key|
        registry.findAccountIndexByAccountKey(reg, account_key)
    else
        null;
    const auto_switch_attempt = try maybeAutoSwitchForDaemonWithUsageFetcher(allocator, codex_home, reg, refresh_state, usage_api.fetchUsageForAuthPathDetailed);
    if (auto_switch_attempt.state_changed or auto_switch_attempt.switched) {
        changed = true;
    }
    if (auto_switch_attempt.switched) {
        if (active_idx_before) |from_idx| {
            if (reg.active_account_key) |account_key| {
                if (registry.findAccountIndexByAccountKey(reg, account_key)) |to_idx| {
                    emitAutoSwitchLog(&reg.accounts.items[from_idx], &reg.accounts.items[to_idx]);
                }
            }
        }
    }

    if (changed) {
        try registry.saveRegistry(allocator, codex_home, reg);
        try refresh_state.refreshTrackedFileMtims(allocator, codex_home);
    }
    return true;
}

fn daemonCycle(allocator: std.mem.Allocator, codex_home: []const u8, refresh_state: *DaemonRefreshState) !bool {
    return daemonCycleWithAccountNameFetcher(allocator, codex_home, refresh_state, fetchActiveAccountNames);
}

pub fn daemonCycleWithAccountNameFetcherForTest(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    refresh_state: *DaemonRefreshState,
    account_name_fetcher: anytype,
) !bool {
    return daemonCycleWithAccountNameFetcher(allocator, codex_home, refresh_state, account_name_fetcher);
}

fn enable(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const self_exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_exe);
    const managed_self_exe = try managed_service.managedServiceSelfExePath(allocator, self_exe);
    defer allocator.free(managed_self_exe);
    try enableWithServiceHooks(allocator, codex_home, managed_self_exe, installService, uninstallService);
}

fn ensureAutoSwitchCanEnable(allocator: std.mem.Allocator) !void {
    if (builtin.os.tag == .linux and !managed_service.linuxUserSystemdAvailable(allocator)) {
        std.log.err("cannot enable auto-switch: systemd --user is unavailable", .{});
        return error.CommandFailed;
    }
}

pub fn enableWithServiceHooks(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    self_exe: []const u8,
    installer: anytype,
    uninstaller: anytype,
) !void {
    try enableWithServiceHooksAndPreflight(
        allocator,
        codex_home,
        self_exe,
        installer,
        uninstaller,
        ensureAutoSwitchCanEnable,
    );
}

pub fn enableWithServiceHooksAndPreflight(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    self_exe: []const u8,
    installer: anytype,
    uninstaller: anytype,
    preflight: anytype,
) !void {
    try preflight(allocator);

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    reg.auto_switch.enabled = true;
    try registry.saveRegistry(allocator, codex_home, &reg);
    errdefer {
        reg.auto_switch.enabled = false;
        registry.saveRegistry(allocator, codex_home, &reg) catch {};
    }
    // Service installation can partially succeed on some platforms, so clean up
    // any managed artifacts before persisting the disabled rollback state.
    errdefer uninstaller(allocator, codex_home) catch {};
    try installer(allocator, codex_home, self_exe);
    printAutoEnableUsageNote(reg.api.usage) catch |err| {
        std.log.warn("failed to print auto-enable usage note: {}", .{err});
    };
}

fn printAutoEnableUsageNote(api_enabled: bool) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    if (api_enabled) {
        try out.writeAll("auto-switch enabled; usage mode: api (default, most accurate for switching decisions)\n");
    } else {
        try out.writeAll("auto-switch enabled; usage mode: local-only (switching still works, but candidate validation is less accurate)\n");
        try out.writeAll("Tip: run `codex-oauth config api enable` for the most accurate switching decisions.\n");
    }
    try out.flush();
}

fn disable(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    reg.auto_switch.enabled = false;
    try registry.saveRegistry(allocator, codex_home, &reg);
    try uninstallService(allocator, codex_home);
}

pub fn applyThresholdConfig(cfg: *registry.AutoSwitchConfig, opts: cli.AutoThresholdOptions) void {
    if (opts.threshold_5h_percent) |value| {
        cfg.threshold_5h_percent = value;
    }
    if (opts.threshold_weekly_percent) |value| {
        cfg.threshold_weekly_percent = value;
    }
}

fn configureThresholds(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.AutoThresholdOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    applyThresholdConfig(&reg.auto_switch, opts);
    try registry.saveRegistry(allocator, codex_home, &reg);
    try printStatus(allocator, codex_home);
}

fn candidateScore(rec: *const registry.AccountRecord, now: i64) CandidateScore {
    const usage_score = registry.usageScoreAt(rec.last_usage, now) orelse 100;
    return .{
        .value = usage_score,
        .last_usage_at = rec.last_usage_at orelse -1,
        .created_at = rec.created_at,
    };
}

fn candidateBetter(a: CandidateScore, b: CandidateScore) bool {
    if (a.value != b.value) return a.value > b.value;
    if (a.last_usage_at != b.last_usage_at) return a.last_usage_at > b.last_usage_at;
    return a.created_at > b.created_at;
}

fn candidateScoreChangeAt(usage: ?registry.RateLimitSnapshot, now: i64) ?i64 {
    if (usage == null) return null;
    var next_change_at: ?i64 = null;
    if (usage.?.primary) |window| {
        next_change_at = earlierFutureTimestamp(next_change_at, window.resets_at, now);
    }
    if (usage.?.secondary) |window| {
        next_change_at = earlierFutureTimestamp(next_change_at, window.resets_at, now);
    }
    return next_change_at;
}

fn earlierFutureTimestamp(current: ?i64, candidate: ?i64, now: i64) ?i64 {
    if (candidate == null or candidate.? <= now) return current;
    if (current == null) return candidate.?;
    return @min(current.?, candidate.?);
}

fn queryRuntimeState(allocator: std.mem.Allocator) RuntimeState {
    return managed_service.queryRuntimeState(allocator, auto_service_spec);
}

fn installService(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !void {
    try managed_service.installService(allocator, codex_home, self_exe, auto_service_spec);
}

fn uninstallService(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    try managed_service.uninstallService(allocator, codex_home, auto_service_spec);
}

fn escapeXml(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (raw) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            else => try out.append(allocator, ch),
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn escapeSystemdValue(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (raw) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            else => try out.append(allocator, ch),
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn escapePowerShellSingleQuoted(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, input, "'", "''");
}

test "candidate index refreshes cached ranking after a reset window expires" {
    const bdd = @import("tests/bdd_helpers.zig");
    const gpa = std.testing.allocator;

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);

    try bdd.appendAccount(gpa, &reg, "active@example.com", "", null);
    try bdd.appendAccount(gpa, &reg, "reset@example.com", "", null);
    try bdd.appendAccount(gpa, &reg, "steady@example.com", "", null);

    const active_account_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_key);
    const reset_account_key = try bdd.accountKeyForEmailAlloc(gpa, "reset@example.com");
    defer gpa.free(reset_account_key);
    const steady_account_key = try bdd.accountKeyForEmailAlloc(gpa, "steady@example.com");
    defer gpa.free(steady_account_key);

    try registry.setActiveAccountKey(gpa, &reg, active_account_key);

    const reset_idx = registry.findAccountIndexByAccountKey(&reg, reset_account_key) orelse return error.TestExpectedEqual;
    reg.accounts.items[reset_idx].last_usage = .{
        .primary = .{ .used_percent = 95.0, .window_minutes = 300, .resets_at = 1010 },
        .secondary = null,
        .credits = null,
        .plan_type = .pro,
    };
    reg.accounts.items[reset_idx].last_usage_at = 100;

    const steady_idx = registry.findAccountIndexByAccountKey(&reg, steady_account_key) orelse return error.TestExpectedEqual;
    reg.accounts.items[steady_idx].last_usage = .{
        .primary = .{ .used_percent = 60.0, .window_minutes = 300, .resets_at = null },
        .secondary = null,
        .credits = null,
        .plan_type = .pro,
    };
    reg.accounts.items[steady_idx].last_usage_at = 50;

    var index = CandidateIndex{};
    defer index.deinit(gpa);

    try index.rebuild(gpa, &reg, 1000);
    try std.testing.expect(index.best() != null);
    try std.testing.expect(std.mem.eql(u8, index.best().?.account_key, steady_account_key));

    try index.rebuildIfScoreExpired(gpa, &reg, 1011);
    try std.testing.expect(index.best() != null);
    try std.testing.expect(std.mem.eql(u8, index.best().?.account_key, reset_account_key));
}
