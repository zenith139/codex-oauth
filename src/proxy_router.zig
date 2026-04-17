const std = @import("std");

pub const HTTP_STATUS = struct {
    pub const unauthorized: u16 = 401;
    pub const payment_required: u16 = 402;
    pub const forbidden: u16 = 403;
    pub const not_found: u16 = 404;
    pub const not_acceptable: u16 = 406;
    pub const request_timeout: u16 = 408;
    pub const rate_limited: u16 = 429;
    pub const server_error: u16 = 500;
    pub const bad_gateway: u16 = 502;
    pub const service_unavailable: u16 = 503;
    pub const gateway_timeout: u16 = 504;
};

pub const Strategy = enum {
    fill_first,
    round_robin,
};

pub const Config = struct {
    strategy: Strategy = .fill_first,
    sticky_round_robin_limit: u32 = 3,
};

pub const Candidate = struct {
    account_key: []const u8,
    enabled: bool = true,
};

pub const SelectionOptions = struct {
    model: ?[]const u8 = null,
    exclude_account_keys: []const []const u8 = &.{},
    now_ms: i64,
};

pub const SelectionResult = struct {
    account_key: ?[]const u8,
    all_rate_limited: bool = false,
    retry_after_ms: ?i64 = null,
};

pub const FallbackDecision = struct {
    should_fallback: bool,
    cooldown_ms: i64,
    new_backoff_level: ?u8 = null,
};

pub const MarkUnavailableResult = struct {
    should_fallback: bool,
    cooldown_ms: i64,
    retry_until_ms: ?i64 = null,
};

pub const ModelLock = struct {
    model: []u8,
    expires_at_ms: i64,
};

pub const AccountState = struct {
    account_key: []u8,
    last_selected_at_ms: ?i64 = null,
    consecutive_use_count: u32 = 0,
    backoff_level: u8 = 0,
    unavailable: bool = false,
    last_error_status: ?u16 = null,
    last_error_at_ms: ?i64 = null,
    locks: std.ArrayListUnmanaged(ModelLock) = .empty,

    fn deinit(self: *AccountState, allocator: std.mem.Allocator) void {
        allocator.free(self.account_key);
        for (self.locks.items) |lock| {
            allocator.free(lock.model);
        }
        self.locks.deinit(allocator);
    }
};

pub const Runtime = struct {
    accounts: std.ArrayListUnmanaged(AccountState) = .empty,

    pub fn deinit(self: *Runtime, allocator: std.mem.Allocator) void {
        for (self.accounts.items) |*account| {
            account.deinit(allocator);
        }
        self.accounts.deinit(allocator);
    }

    pub fn accountState(self: *const Runtime, account_key: []const u8) ?*const AccountState {
        for (self.accounts.items) |*account| {
            if (std.mem.eql(u8, account.account_key, account_key)) return account;
        }
        return null;
    }

    fn accountStateMut(self: *Runtime, account_key: []const u8) ?*AccountState {
        for (self.accounts.items) |*account| {
            if (std.mem.eql(u8, account.account_key, account_key)) return account;
        }
        return null;
    }

    fn getOrCreateAccount(self: *Runtime, allocator: std.mem.Allocator, account_key: []const u8) !*AccountState {
        if (self.accountStateMut(account_key)) |account| return account;

        try self.accounts.append(allocator, .{
            .account_key = try allocator.dupe(u8, account_key),
        });
        return &self.accounts.items[self.accounts.items.len - 1];
    }

    pub fn selectAccount(
        self: *Runtime,
        allocator: std.mem.Allocator,
        candidates: []const Candidate,
        config: Config,
        opts: SelectionOptions,
    ) !SelectionResult {
        var available = std.ArrayListUnmanaged(usize).empty;
        defer available.deinit(allocator);

        var earliest_retry_after_ms: ?i64 = null;
        for (candidates, 0..) |candidate, idx| {
            if (!candidate.enabled) continue;
            if (isExcluded(candidate.account_key, opts.exclude_account_keys)) continue;

            if (self.accountStateMut(candidate.account_key)) |account| {
                self.cleanExpiredLocks(allocator, account, opts.now_ms);
                if (self.isModelLocked(account, opts.model, opts.now_ms)) {
                    const retry_after_ms = self.earliestLockExpiry(account, opts.model, opts.now_ms);
                    if (retry_after_ms) |retry_at| {
                        if (earliest_retry_after_ms == null or retry_at < earliest_retry_after_ms.?) {
                            earliest_retry_after_ms = retry_at;
                        }
                    }
                    continue;
                }
            }

            try available.append(allocator, idx);
        }

        if (available.items.len == 0) {
            return .{
                .account_key = null,
                .all_rate_limited = earliest_retry_after_ms != null,
                .retry_after_ms = earliest_retry_after_ms,
            };
        }

        const selected_idx = switch (config.strategy) {
            .fill_first => available.items[0],
            .round_robin => self.selectRoundRobinCandidate(candidates, available.items, config),
        };
        const selected_key = candidates[selected_idx].account_key;
        try self.markSelected(allocator, selected_key, opts.now_ms, config, candidates, available.items);
        return .{
            .account_key = selected_key,
        };
    }

    fn selectRoundRobinCandidate(
        self: *Runtime,
        candidates: []const Candidate,
        available_indices: []const usize,
        config: Config,
    ) usize {
        var current_idx: ?usize = null;
        var current_selected_at_ms: ?i64 = null;

        for (available_indices) |candidate_idx| {
            const state = self.accountState(candidates[candidate_idx].account_key);
            const selected_at_ms = if (state) |account| account.last_selected_at_ms else null;
            if (selected_at_ms == null) continue;
            if (current_selected_at_ms == null or selected_at_ms.? > current_selected_at_ms.?) {
                current_selected_at_ms = selected_at_ms;
                current_idx = candidate_idx;
            }
        }

        if (current_idx) |idx| {
            if (self.accountState(candidates[idx].account_key)) |account| {
                if (account.last_selected_at_ms != null and account.consecutive_use_count < config.sticky_round_robin_limit) {
                    return idx;
                }
            }
        }

        var oldest_idx = available_indices[0];
        var oldest_selected_at_ms: ?i64 = if (self.accountState(candidates[oldest_idx].account_key)) |account|
            account.last_selected_at_ms
        else
            null;

        for (available_indices[1..]) |candidate_idx| {
            const state = self.accountState(candidates[candidate_idx].account_key);
            const selected_at_ms = if (state) |account| account.last_selected_at_ms else null;

            if (oldest_selected_at_ms == null) continue;
            if (selected_at_ms == null or selected_at_ms.? < oldest_selected_at_ms.?) {
                oldest_idx = candidate_idx;
                oldest_selected_at_ms = selected_at_ms;
            }
        }

        return oldest_idx;
    }

    fn markSelected(
        self: *Runtime,
        allocator: std.mem.Allocator,
        account_key: []const u8,
        now_ms: i64,
        config: Config,
        candidates: []const Candidate,
        available_indices: []const usize,
    ) !void {
        const account = try self.getOrCreateAccount(allocator, account_key);
        const should_increment = blk: {
            if (config.strategy != .round_robin) break :blk false;

            const current_idx = self.selectMostRecentCandidate(candidates, available_indices);
            if (current_idx == null) break :blk false;
            if (!std.mem.eql(u8, candidates[current_idx.?].account_key, account_key)) break :blk false;
            break :blk account.last_selected_at_ms != null and account.consecutive_use_count < config.sticky_round_robin_limit;
        };

        if (should_increment) {
            account.consecutive_use_count += 1;
        } else {
            account.consecutive_use_count = 1;
        }
        account.last_selected_at_ms = now_ms;
    }

    fn selectMostRecentCandidate(
        self: *const Runtime,
        candidates: []const Candidate,
        available_indices: []const usize,
    ) ?usize {
        var current_idx: ?usize = null;
        var current_selected_at_ms: ?i64 = null;

        for (available_indices) |candidate_idx| {
            const state = self.accountState(candidates[candidate_idx].account_key);
            const selected_at_ms = if (state) |account| account.last_selected_at_ms else null;
            if (selected_at_ms == null) continue;
            if (current_selected_at_ms == null or selected_at_ms.? > current_selected_at_ms.?) {
                current_selected_at_ms = selected_at_ms;
                current_idx = candidate_idx;
            }
        }

        return current_idx;
    }

    pub fn markUnavailable(
        self: *Runtime,
        allocator: std.mem.Allocator,
        account_key: []const u8,
        status: u16,
        error_text: []const u8,
        model: ?[]const u8,
        now_ms: i64,
    ) !MarkUnavailableResult {
        const account = try self.getOrCreateAccount(allocator, account_key);
        self.cleanExpiredLocks(allocator, account, now_ms);

        const decision = checkFallbackError(status, error_text, account.backoff_level);
        if (!decision.should_fallback) {
            return .{
                .should_fallback = false,
                .cooldown_ms = 0,
                .retry_until_ms = null,
            };
        }

        account.unavailable = true;
        account.last_error_status = status;
        account.last_error_at_ms = now_ms;
        account.backoff_level = decision.new_backoff_level orelse account.backoff_level;

        const retry_until_ms = now_ms + decision.cooldown_ms;
        try self.setModelLock(allocator, account, model, retry_until_ms);
        return .{
            .should_fallback = true,
            .cooldown_ms = decision.cooldown_ms,
            .retry_until_ms = retry_until_ms,
        };
    }

    pub fn clearSuccess(
        self: *Runtime,
        allocator: std.mem.Allocator,
        account_key: []const u8,
        model: ?[]const u8,
        now_ms: i64,
    ) void {
        const account = self.accountStateMut(account_key) orelse return;
        self.cleanExpiredLocks(allocator, account, now_ms);

        var write_idx: usize = 0;
        for (account.locks.items, 0..) |lock, idx| {
            const is_model_lock = model != null and std.mem.eql(u8, lock.model, model.?);
            const is_all_lock = std.mem.eql(u8, lock.model, model_lock_all);
            const is_expired = lock.expires_at_ms <= now_ms;
            if (is_model_lock or is_all_lock or is_expired) {
                allocator.free(lock.model);
                continue;
            }
            if (write_idx != idx) {
                account.locks.items[write_idx] = lock;
            }
            write_idx += 1;
        }
        account.locks.items.len = write_idx;

        if (account.locks.items.len == 0) {
            account.unavailable = false;
            account.backoff_level = 0;
            account.last_error_status = null;
            account.last_error_at_ms = null;
        }
    }

    fn setModelLock(
        self: *Runtime,
        allocator: std.mem.Allocator,
        account: *AccountState,
        model: ?[]const u8,
        expires_at_ms: i64,
    ) !void {
        _ = self;
        const key = model orelse model_lock_all;
        for (account.locks.items) |*lock| {
            if (!std.mem.eql(u8, lock.model, key)) continue;
            lock.expires_at_ms = expires_at_ms;
            return;
        }

        try account.locks.append(allocator, .{
            .model = try allocator.dupe(u8, key),
            .expires_at_ms = expires_at_ms,
        });
    }

    fn cleanExpiredLocks(self: *Runtime, allocator: std.mem.Allocator, account: *AccountState, now_ms: i64) void {
        _ = self;
        var write_idx: usize = 0;
        for (account.locks.items, 0..) |lock, idx| {
            if (lock.expires_at_ms <= now_ms) {
                allocator.free(lock.model);
                continue;
            }
            if (write_idx != idx) {
                account.locks.items[write_idx] = lock;
            }
            write_idx += 1;
        }
        account.locks.items.len = write_idx;
    }

    fn isModelLocked(self: *const Runtime, account: *const AccountState, model: ?[]const u8, now_ms: i64) bool {
        _ = self;
        for (account.locks.items) |lock| {
            if (lock.expires_at_ms <= now_ms) continue;
            if (std.mem.eql(u8, lock.model, model_lock_all)) return true;
            if (model != null and std.mem.eql(u8, lock.model, model.?)) return true;
        }
        return false;
    }

    fn earliestLockExpiry(self: *const Runtime, account: *const AccountState, model: ?[]const u8, now_ms: i64) ?i64 {
        _ = self;
        var earliest: ?i64 = null;
        for (account.locks.items) |lock| {
            if (lock.expires_at_ms <= now_ms) continue;
            if (!std.mem.eql(u8, lock.model, model_lock_all) and !(model != null and std.mem.eql(u8, lock.model, model.?))) {
                continue;
            }
            if (earliest == null or lock.expires_at_ms < earliest.?) {
                earliest = lock.expires_at_ms;
            }
        }
        return earliest;
    }
};

pub fn checkFallbackError(status: u16, error_text: []const u8, backoff_level: u8) FallbackDecision {
    if (error_text.len != 0) {
        if (containsIgnoreCase(error_text, "no credentials")) {
            return .{ .should_fallback = true, .cooldown_ms = cooldown_not_found };
        }

        if (containsIgnoreCase(error_text, "request not allowed")) {
            return .{ .should_fallback = true, .cooldown_ms = cooldown_request_not_allowed };
        }

        if (containsIgnoreCase(error_text, "improperly formed request")) {
            return .{ .should_fallback = true, .cooldown_ms = cooldown_payment_required };
        }

        if (containsIgnoreCase(error_text, "rate limit") or
            containsIgnoreCase(error_text, "too many requests") or
            containsIgnoreCase(error_text, "quota exceeded") or
            containsIgnoreCase(error_text, "capacity") or
            containsIgnoreCase(error_text, "overloaded"))
        {
            return .{
                .should_fallback = true,
                .cooldown_ms = quotaCooldown(backoff_level),
                .new_backoff_level = @min(backoff_level + 1, backoff_max_level),
            };
        }
    }

    if (status == HTTP_STATUS.unauthorized) {
        return .{ .should_fallback = true, .cooldown_ms = cooldown_unauthorized };
    }

    if (status == HTTP_STATUS.payment_required or status == HTTP_STATUS.forbidden) {
        return .{ .should_fallback = true, .cooldown_ms = cooldown_payment_required };
    }

    if (status == HTTP_STATUS.not_found) {
        return .{ .should_fallback = true, .cooldown_ms = cooldown_not_found };
    }

    if (status == HTTP_STATUS.rate_limited) {
        return .{
            .should_fallback = true,
            .cooldown_ms = quotaCooldown(backoff_level),
            .new_backoff_level = @min(backoff_level + 1, backoff_max_level),
        };
    }

    if (status == HTTP_STATUS.not_acceptable or
        status == HTTP_STATUS.request_timeout or
        status == HTTP_STATUS.server_error or
        status == HTTP_STATUS.bad_gateway or
        status == HTTP_STATUS.service_unavailable or
        status == HTTP_STATUS.gateway_timeout)
    {
        return .{ .should_fallback = true, .cooldown_ms = cooldown_transient };
    }

    return .{ .should_fallback = true, .cooldown_ms = cooldown_transient };
}

pub fn quotaCooldown(backoff_level: u8) i64 {
    const shift = @as(u6, @intCast(@min(backoff_level, @as(u8, 20))));
    const raw = backoff_base_ms * (@as(i64, 1) << shift);
    return @min(raw, backoff_max_ms);
}

fn isExcluded(account_key: []const u8, excluded_keys: []const []const u8) bool {
    for (excluded_keys) |excluded_key| {
        if (std.mem.eql(u8, account_key, excluded_key)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matched = true;
        for (needle, 0..) |needle_ch, idx| {
            if (std.ascii.toLower(haystack[start + idx]) != std.ascii.toLower(needle_ch)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

const model_lock_all = "__all";
const backoff_base_ms: i64 = 1000;
const backoff_max_ms: i64 = 2 * 60 * 1000;
const backoff_max_level: u8 = 15;
const cooldown_unauthorized: i64 = 2 * 60 * 1000;
const cooldown_payment_required: i64 = 2 * 60 * 1000;
const cooldown_not_found: i64 = 2 * 60 * 1000;
const cooldown_transient: i64 = 30 * 1000;
const cooldown_request_not_allowed: i64 = 5 * 1000;
