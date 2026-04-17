const std = @import("std");

pub const request_timeout_secs: []const u8 = "5";
pub const request_timeout_ms: []const u8 = "5000";
pub const browser_user_agent: []const u8 = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36";
pub const node_executable_env = "CODEX_OAUTH_NODE_EXECUTABLE";
pub const node_requirement_hint = "Node.js 18+ is required for ChatGPT API refresh. Install Node.js 18+ or use the npm package.";

pub const HttpResult = struct {
    body: []u8,
    status_code: ?u16,
};

const NodeOutcome = enum {
    ok,
    timeout,
    failed,
    node_too_old,
};

const ParsedNodeHttpOutput = struct {
    body: []u8,
    status_code: ?u16,
    outcome: NodeOutcome,
};

const node_request_script =
    \\const endpoint = process.argv[1];
    \\const accessToken = process.argv[2];
    \\const accountId = process.argv[3];
    \\const timeoutMs = Number(process.argv[4]);
    \\const userAgent = process.argv[5];
    \\const encode = (value) => Buffer.from(value ?? "", "utf8").toString("base64");
    \\const emit = (body, status, outcome) => {
    \\  process.stdout.write(encode(body));
    \\  process.stdout.write("\n");
    \\  process.stdout.write(String(status));
    \\  process.stdout.write("\n");
    \\  process.stdout.write(outcome);
    \\};
    \\if (typeof fetch !== "function" || typeof AbortSignal?.timeout !== "function") {
    \\  emit("Node.js 18+ is required.", 0, "node-too-old");
    \\} else {
    \\  void (async () => {
    \\    try {
    \\      const response = await fetch(endpoint, {
    \\        method: "GET",
    \\        headers: {
    \\          "Authorization": "Bearer " + accessToken,
    \\          "ChatGPT-Account-Id": accountId,
    \\          "User-Agent": userAgent,
    \\        },
    \\        signal: AbortSignal.timeout(timeoutMs),
    \\      });
    \\      emit(await response.text(), response.status, "ok");
    \\    } catch (error) {
    \\      const isTimeout = error?.name === "TimeoutError" || error?.name === "AbortError";
    \\      emit(error?.message ?? "", 0, isTimeout ? "timeout" : "error");
    \\    }
    \\  })().catch((error) => {
    \\    emit(error?.message ?? "", 0, "error");
    \\  });
    \\}
;

pub fn runGetJsonCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    access_token: []const u8,
    account_id: []const u8,
) !HttpResult {
    return runNodeGetJsonCommand(allocator, endpoint, access_token, account_id);
}

fn runNodeGetJsonCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    access_token: []const u8,
    account_id: []const u8,
) !HttpResult {
    const node_executable = try resolveNodeExecutable(allocator);
    defer allocator.free(node_executable);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            node_executable,
            "-e",
            node_request_script,
            endpoint,
            access_token,
            account_id,
            request_timeout_ms,
            browser_user_agent,
        },
        .max_output_bytes = 1024 * 1024,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.FileNotFound => {
            logNodeRequirement();
            return error.NodeJsRequired;
        },
        else => return error.RequestFailed,
    };
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) {
            allocator.free(result.stdout);
            return error.RequestFailed;
        },
        else => {
            allocator.free(result.stdout);
            return error.RequestFailed;
        },
    }

    const parsed = parseNodeHttpOutput(allocator, result.stdout) orelse {
        allocator.free(result.stdout);
        return error.CommandFailed;
    };
    allocator.free(result.stdout);

    switch (parsed.outcome) {
        .ok => return .{
            .body = parsed.body,
            .status_code = parsed.status_code,
        },
        .timeout => {
            allocator.free(parsed.body);
            return error.TimedOut;
        },
        .failed => {
            allocator.free(parsed.body);
            return error.RequestFailed;
        },
        .node_too_old => {
            allocator.free(parsed.body);
            logNodeRequirement();
            return error.NodeJsRequired;
        },
    }
}

fn resolveNodeExecutable(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, node_executable_env) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, "node"),
        else => return err,
    };
}

fn logNodeRequirement() void {
    std.log.warn("{s}", .{node_requirement_hint});
}

fn parseNodeHttpOutput(allocator: std.mem.Allocator, output: []const u8) ?ParsedNodeHttpOutput {
    const trimmed = std.mem.trimRight(u8, output, "\r\n");
    const outcome_idx = std.mem.lastIndexOfScalar(u8, trimmed, '\n') orelse return null;
    const status_idx = std.mem.lastIndexOfScalar(u8, trimmed[0..outcome_idx], '\n') orelse return null;
    const encoded_body = std.mem.trim(u8, trimmed[0..status_idx], " \r\t");
    const status_slice = std.mem.trim(u8, trimmed[status_idx + 1 .. outcome_idx], " \r\t");
    const outcome_slice = std.mem.trim(u8, trimmed[outcome_idx + 1 ..], " \r\t");
    const status = std.fmt.parseInt(u16, status_slice, 10) catch return null;
    const decoded_body = decodeBase64Alloc(allocator, encoded_body) catch return null;
    return .{
        .body = decoded_body,
        .status_code = if (status == 0) null else status,
        .outcome = parseNodeOutcome(outcome_slice) orelse {
            allocator.free(decoded_body);
            return null;
        },
    };
}

fn parseNodeOutcome(input: []const u8) ?NodeOutcome {
    if (std.mem.eql(u8, input, "ok")) return .ok;
    if (std.mem.eql(u8, input, "timeout")) return .timeout;
    if (std.mem.eql(u8, input, "error")) return .failed;
    if (std.mem.eql(u8, input, "node-too-old")) return .node_too_old;
    return null;
}

fn decodeBase64Alloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const out_len = try decoder.calcSizeForSlice(input);
    const buf = try allocator.alloc(u8, out_len);
    errdefer allocator.free(buf);
    try decoder.decode(buf, input);
    return buf;
}

test "parse node http output decodes status and body" {
    const allocator = std.testing.allocator;
    const parsed = parseNodeHttpOutput(allocator, "aGVsbG8=\n200\nok\n") orelse return error.TestUnexpectedResult;
    defer allocator.free(parsed.body);

    try std.testing.expectEqual(NodeOutcome.ok, parsed.outcome);
    try std.testing.expectEqual(@as(?u16, 200), parsed.status_code);
    try std.testing.expectEqualStrings("hello", parsed.body);
}

test "parse node http output keeps timeout marker" {
    const allocator = std.testing.allocator;
    const parsed = parseNodeHttpOutput(allocator, "\n0\ntimeout\n") orelse return error.TestUnexpectedResult;
    defer allocator.free(parsed.body);

    try std.testing.expectEqual(NodeOutcome.timeout, parsed.outcome);
    try std.testing.expectEqual(@as(?u16, null), parsed.status_code);
    try std.testing.expectEqual(@as(usize, 0), parsed.body.len);
}
