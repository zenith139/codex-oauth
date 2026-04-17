const std = @import("std");
const proxy_router = @import("../proxy_router.zig");

test "Scenario: Given fill-first strategy when first candidate is available then it selects the first account" {
    const gpa = std.testing.allocator;

    var runtime = proxy_router.Runtime{};
    defer runtime.deinit(gpa);

    const candidates = [_]proxy_router.Candidate{
        .{ .account_key = "acct-a" },
        .{ .account_key = "acct-b" },
    };

    const selected = try runtime.selectAccount(
        gpa,
        &candidates,
        .{ .strategy = .fill_first },
        .{ .now_ms = 1_000 },
    );

    try std.testing.expect(selected.account_key != null);
    try std.testing.expectEqualStrings("acct-a", selected.account_key.?);
    try std.testing.expect(!selected.all_rate_limited);

    const state = runtime.accountState("acct-a") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 1), state.consecutive_use_count);
    try std.testing.expectEqual(@as(?i64, 1_000), state.last_selected_at_ms);
}

test "Scenario: Given round-robin with sticky limit when the same account is reused then it rotates only after the limit" {
    const gpa = std.testing.allocator;

    var runtime = proxy_router.Runtime{};
    defer runtime.deinit(gpa);

    const config = proxy_router.Config{
        .strategy = .round_robin,
        .sticky_round_robin_limit = 2,
    };
    const candidates = [_]proxy_router.Candidate{
        .{ .account_key = "acct-a" },
        .{ .account_key = "acct-b" },
    };

    const first = try runtime.selectAccount(gpa, &candidates, config, .{ .now_ms = 1_000 });
    const second = try runtime.selectAccount(gpa, &candidates, config, .{ .now_ms = 2_000 });
    const third = try runtime.selectAccount(gpa, &candidates, config, .{ .now_ms = 3_000 });
    const fourth = try runtime.selectAccount(gpa, &candidates, config, .{ .now_ms = 4_000 });
    const fifth = try runtime.selectAccount(gpa, &candidates, config, .{ .now_ms = 5_000 });

    try std.testing.expectEqualStrings("acct-a", first.account_key.?);
    try std.testing.expectEqualStrings("acct-a", second.account_key.?);
    try std.testing.expectEqualStrings("acct-b", third.account_key.?);
    try std.testing.expectEqualStrings("acct-b", fourth.account_key.?);
    try std.testing.expectEqualStrings("acct-a", fifth.account_key.?);

    const state_a = runtime.accountState("acct-a") orelse return error.TestUnexpectedResult;
    const state_b = runtime.accountState("acct-b") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 1), state_a.consecutive_use_count);
    try std.testing.expectEqual(@as(u32, 2), state_b.consecutive_use_count);
}

test "Scenario: Given rate-limited account when selecting then the locked model is skipped and the retry window is tracked" {
    const gpa = std.testing.allocator;

    var runtime = proxy_router.Runtime{};
    defer runtime.deinit(gpa);

    const first_lock = try runtime.markUnavailable(
        gpa,
        "acct-a",
        proxy_router.HTTP_STATUS.rate_limited,
        "rate limit exceeded",
        "gpt-5",
        10_000,
    );
    try std.testing.expect(first_lock.should_fallback);
    try std.testing.expectEqual(@as(i64, 1_000), first_lock.cooldown_ms);
    try std.testing.expectEqual(@as(?i64, 11_000), first_lock.retry_until_ms);

    const candidates = [_]proxy_router.Candidate{
        .{ .account_key = "acct-a" },
        .{ .account_key = "acct-b" },
    };
    const selected = try runtime.selectAccount(
        gpa,
        &candidates,
        .{ .strategy = .fill_first },
        .{
            .model = "gpt-5",
            .now_ms = 10_500,
        },
    );
    try std.testing.expectEqualStrings("acct-b", selected.account_key.?);

    const second_lock = try runtime.markUnavailable(
        gpa,
        "acct-a",
        proxy_router.HTTP_STATUS.rate_limited,
        "rate limit exceeded",
        "gpt-5",
        11_100,
    );
    try std.testing.expect(second_lock.should_fallback);
    try std.testing.expectEqual(@as(i64, 2_000), second_lock.cooldown_ms);
    try std.testing.expectEqual(@as(?i64, 13_100), second_lock.retry_until_ms);

    const state = runtime.accountState("acct-a") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 2), state.backoff_level);
}

test "Scenario: Given all candidates locked for a model when selecting then it reports the earliest retry time" {
    const gpa = std.testing.allocator;

    var runtime = proxy_router.Runtime{};
    defer runtime.deinit(gpa);

    _ = try runtime.markUnavailable(gpa, "acct-a", proxy_router.HTTP_STATUS.forbidden, "plan inactive", "gpt-5", 1_000);
    _ = try runtime.markUnavailable(gpa, "acct-b", proxy_router.HTTP_STATUS.unauthorized, "token expired", "gpt-5", 2_000);

    const candidates = [_]proxy_router.Candidate{
        .{ .account_key = "acct-a" },
        .{ .account_key = "acct-b" },
    };
    const selected = try runtime.selectAccount(
        gpa,
        &candidates,
        .{ .strategy = .fill_first },
        .{
            .model = "gpt-5",
            .now_ms = 2_500,
        },
    );

    try std.testing.expect(selected.account_key == null);
    try std.testing.expect(selected.all_rate_limited);
    try std.testing.expectEqual(@as(?i64, 121_000), selected.retry_after_ms);
}

test "Scenario: Given a successful request after a model lock when clearing success then the account becomes eligible again" {
    const gpa = std.testing.allocator;

    var runtime = proxy_router.Runtime{};
    defer runtime.deinit(gpa);

    _ = try runtime.markUnavailable(
        gpa,
        "acct-a",
        proxy_router.HTTP_STATUS.unauthorized,
        "token invalid",
        "gpt-5",
        5_000,
    );

    runtime.clearSuccess(gpa, "acct-a", "gpt-5", 6_000);

    const state = runtime.accountState("acct-a") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 0), state.backoff_level);
    try std.testing.expect(!state.unavailable);
    try std.testing.expectEqual(@as(usize, 0), state.locks.items.len);

    const candidates = [_]proxy_router.Candidate{
        .{ .account_key = "acct-a" },
    };
    const selected = try runtime.selectAccount(
        gpa,
        &candidates,
        .{},
        .{
            .model = "gpt-5",
            .now_ms = 6_100,
        },
    );
    try std.testing.expectEqualStrings("acct-a", selected.account_key.?);
}
