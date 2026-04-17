const std = @import("std");
const cli = @import("cli.zig");
const io_util = @import("io_util.zig");
const registry = @import("registry.zig");
const builtin = @import("builtin");
const managed_service = @import("managed_service.zig");

const manual_provider_id = "codex_oauth";
const manual_provider_name = "codex-oauth";
const manual_model = "gpt-5.4";
const manual_model_reasoning_effort = "high";
const package_root_env_name = "CODEX_OAUTH_PACKAGE_ROOT";

const proxy_service_exec_args = [_][]const u8{"serve"};
const proxy_service_spec = managed_service.ManagedServiceSpec{
    .description = "codex-oauth multi-account proxy",
    .linux_service_name = "codex-oauth-proxy.service",
    .linux_legacy_timer_name = null,
    .mac_label = "com.zenith139.codex-oauth.proxy",
    .windows_task_name = "CodexOAuthProxy",
    .windows_helper_name = "codex-oauth-proxy.exe",
    .exec_args = &proxy_service_exec_args,
    .requires_node_executable = true,
};

pub fn proxyServiceSpec() managed_service.ManagedServiceSpec {
    return proxy_service_spec;
}

pub fn strategyLabel(strategy: registry.ProxyStrategy) []const u8 {
    return switch (strategy) {
        .fill_first => "fill-first",
        .round_robin => "round-robin",
    };
}

pub fn writeMaskedApiKey(buf: []u8, api_key: ?[]const u8) []const u8 {
    const key = api_key orelse return "(not-generated)";
    if (key.len <= 8) return key;
    return std.fmt.bufPrint(buf, "{s}...{s}", .{ key[0..4], key[key.len - 4 ..] }) catch key;
}

pub fn baseUrlFormat(cfg: *const registry.ProxyConfig, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "http://{s}:{d}/v1", .{ cfg.listen_host, cfg.listen_port }) catch "http://127.0.0.1:4318/v1";
}

fn writeProxySummary(out: *std.Io.Writer, cfg: *const registry.ProxyConfig, reveal_api_key: bool) !void {
    var base_url_buf: [96]u8 = undefined;
    try out.print("proxy base-url: {s}\n", .{baseUrlFormat(cfg, &base_url_buf)});
    try out.print("proxy strategy: {s}\n", .{strategyLabel(cfg.strategy)});
    try out.print("proxy sticky-limit: {d}\n", .{cfg.sticky_round_robin_limit});

    if (reveal_api_key) {
        try out.print("proxy api-key: {s}\n", .{cfg.api_key orelse "(not-generated)"});
    } else {
        var mask_buf: [80]u8 = undefined;
        try out.print("proxy api-key: {s}\n", .{writeMaskedApiKey(&mask_buf, cfg.api_key)});
    }
}

fn writeManualConfig(out: *std.Io.Writer, cfg: *const registry.ProxyConfig) !void {
    var base_url_buf: [96]u8 = undefined;
    const base_url = baseUrlFormat(cfg, &base_url_buf);
    const api_key = cfg.api_key orelse "(not-generated)";

    try out.writeAll("Start the proxy in another terminal:\n");
    try out.writeAll("  codex-oauth serve\n\n");

    try out.writeAll("~/.codex/config.toml\n");
    try out.writeAll("```toml\n");
    try out.print(
        \\# codex-oauth local proxy configuration
        \\model = "{s}"
        \\model_provider = "{s}"
        \\model_reasoning_effort = "{s}"
        \\
        \\[model_providers.{s}]
        \\name = "{s}"
        \\base_url = "{s}"
        \\wire_api = "responses"
        \\
        \\[agents.subagent]
        \\model = "{s}"
        \\
    ,
        .{
            manual_model,
            manual_provider_id,
            manual_model_reasoning_effort,
            manual_provider_id,
            manual_provider_name,
            base_url,
            manual_model,
        },
    );
    try out.writeAll("```\n\n");

    try out.writeAll("~/.codex/auth.json\n");
    try out.writeAll("```json\n");
    try out.print(
        \\{{
        \\  "OPENAI_API_KEY": "{s}"
        \\}}
        \\
    ,
        .{api_key},
    );
    try out.writeAll("```\n");
}

fn configTomlPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "config.toml" });
}

fn readFileIfExists(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return try allocator.dupe(u8, ""),
        else => return err,
    };
    defer file.close();
    return try file.readToEndAlloc(allocator, 1024 * 1024);
}

fn writeFile(path: []const u8, data: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
}

fn tomlLineSetsKey(line: []const u8, key: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    if (trimmed.len == 0 or trimmed[0] == '#') return false;
    if (!std.mem.startsWith(u8, trimmed, key)) return false;
    const rest = std.mem.trimLeft(u8, trimmed[key.len..], " \t");
    return rest.len > 0 and rest[0] == '=';
}

const TomlSection = enum { top, proxy_provider, subagent, other };

fn classifyTomlSection(line: []const u8) ?TomlSection {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "[") or !std.mem.endsWith(u8, trimmed, "]")) return null;
    if (std.mem.eql(u8, trimmed, "[model_providers." ++ manual_provider_id ++ "]")) return .proxy_provider;
    if (std.mem.eql(u8, trimmed, "[agents.subagent]")) return .subagent;
    return .other;
}

fn appendProxyTopLevelToml(out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try out.print(allocator,
        \\# codex-oauth local proxy configuration
        \\model = "{s}"
        \\model_provider = "{s}"
        \\model_reasoning_effort = "{s}"
        \\
        \\
    , .{ manual_model, manual_provider_id, manual_model_reasoning_effort });
}

fn appendSubagentModelToml(out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try out.print(allocator, "model = \"{s}\"\n", .{manual_model});
}

fn appendProxyProviderToml(out: *std.ArrayList(u8), allocator: std.mem.Allocator, cfg: *const registry.ProxyConfig) !void {
    var base_url_buf: [96]u8 = undefined;
    const base_url = baseUrlFormat(cfg, &base_url_buf);
    try out.print(allocator,
        \\
        \\[model_providers.{s}]
        \\name = "{s}"
        \\base_url = "{s}"
        \\wire_api = "responses"
        \\
    , .{ manual_provider_id, manual_provider_name, base_url });
}

fn appendLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, line: []const u8) !void {
    try out.appendSlice(allocator, line);
    try out.append(allocator, '\n');
}

fn applyProxyTomlConfigAlloc(allocator: std.mem.Allocator, existing: []const u8, cfg: *const registry.ProxyConfig) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try appendProxyTopLevelToml(&out, allocator);

    var section: TomlSection = .top;
    var saw_subagent = false;
    var subagent_model_written = false;
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (classifyTomlSection(line)) |next_section| {
            if (section == .subagent and !subagent_model_written) {
                try appendSubagentModelToml(&out, allocator);
                subagent_model_written = true;
            }
            section = next_section;
            if (section == .proxy_provider) continue;
            if (section == .subagent) {
                saw_subagent = true;
                subagent_model_written = false;
            }
            try appendLine(&out, allocator, line);
            continue;
        }

        switch (section) {
            .proxy_provider => continue,
            .top => {
                if (tomlLineSetsKey(line, "model") or
                    tomlLineSetsKey(line, "model_provider") or
                    tomlLineSetsKey(line, "model_reasoning_effort")) continue;
                try appendLine(&out, allocator, line);
            },
            .subagent => {
                if (tomlLineSetsKey(line, "model")) {
                    if (!subagent_model_written) {
                        try appendSubagentModelToml(&out, allocator);
                        subagent_model_written = true;
                    }
                    continue;
                }
                try appendLine(&out, allocator, line);
            },
            .other => try appendLine(&out, allocator, line),
        }
    }

    if (section == .subagent and !subagent_model_written) {
        try appendSubagentModelToml(&out, allocator);
    }
    if (!saw_subagent) {
        try out.print(allocator,
            \\
            \\[agents.subagent]
            \\model = "{s}"
            \\
        , .{manual_model});
    }
    try appendProxyProviderToml(&out, allocator, cfg);

    return try out.toOwnedSlice(allocator);
}

fn jsonStringEscapeAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (raw) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => if (ch < 0x20) {
                try out.print(allocator, "\\u{x:0>4}", .{ch});
            } else {
                try out.append(allocator, ch);
            },
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn authJsonConfigAlloc(allocator: std.mem.Allocator, api_key: []const u8) ![]u8 {
    const escaped = try jsonStringEscapeAlloc(allocator, api_key);
    defer allocator.free(escaped);
    return try std.fmt.allocPrint(allocator,
        \\{{
        \\  "OPENAI_API_KEY": "{s}"
        \\}}
        \\
    , .{escaped});
}

fn applyProxyConfigToCodexFiles(allocator: std.mem.Allocator, codex_home: []const u8, cfg: *const registry.ProxyConfig) !void {
    const api_key = cfg.api_key orelse return error.ProxyApiKeyMissing;
    try std.fs.cwd().makePath(codex_home);

    const config_path = try configTomlPath(allocator, codex_home);
    defer allocator.free(config_path);
    const existing_config = try readFileIfExists(allocator, config_path);
    defer allocator.free(existing_config);
    const next_config = try applyProxyTomlConfigAlloc(allocator, existing_config, cfg);
    defer allocator.free(next_config);
    try writeFile(config_path, next_config);

    const auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);
    const auth_json = try authJsonConfigAlloc(allocator, api_key);
    defer allocator.free(auth_json);
    try writeFile(auth_path, auth_json);
}

fn writeApplySummary(out: *std.Io.Writer, codex_home: []const u8) !void {
    try out.writeAll("Applied proxy configuration:\n");
    try out.print("  {s}/config.toml\n", .{codex_home});
    try out.print("  {s}/auth.json\n", .{codex_home});
}

fn generateApiKey(allocator: std.mem.Allocator) ![]u8 {
    var random_bytes: [24]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out_len = encoder.calcSize(random_bytes.len);
    const api_key = try allocator.alloc(u8, out_len);
    _ = encoder.encode(api_key, &random_bytes);
    return api_key;
}

fn ensureApiKey(allocator: std.mem.Allocator, reg: *registry.Registry) !bool {
    if (reg.proxy.api_key != null) return false;
    reg.proxy.api_key = try generateApiKey(allocator);
    return true;
}

fn replaceApiKey(allocator: std.mem.Allocator, reg: *registry.Registry, value: []const u8) !bool {
    if (reg.proxy.api_key) |existing| {
        if (std.mem.eql(u8, existing, value)) return false;
        allocator.free(existing);
    }
    reg.proxy.api_key = try allocator.dupe(u8, value);
    return true;
}

pub fn handleProxyCommand(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    opts: cli.ProxyConfigOptions,
) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    var changed = false;
    if (opts.port) |port| {
        if (reg.proxy.listen_port != port) {
            reg.proxy.listen_port = port;
            changed = true;
        }
    }
    if (opts.strategy) |strategy| {
        if (reg.proxy.strategy != strategy) {
            reg.proxy.strategy = strategy;
            changed = true;
        }
    }
    if (opts.sticky_limit) |sticky_limit| {
        if (reg.proxy.sticky_round_robin_limit != sticky_limit) {
            reg.proxy.sticky_round_robin_limit = sticky_limit;
            changed = true;
        }
    }
    if (opts.api_key) |api_key| {
        if (try replaceApiKey(allocator, &reg, api_key)) {
            changed = true;
        }
    }
    if (try ensureApiKey(allocator, &reg)) {
        changed = true;
    }
    if (changed) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }

    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    if (opts.apply_config) {
        try applyProxyConfigToCodexFiles(allocator, codex_home, &reg.proxy);
        try writeApplySummary(out, codex_home);
    } else if (opts.manual_config) {
        try writeManualConfig(out, &reg.proxy);
    } else {
        try writeProxySummary(out, &reg.proxy, true);
    }
    try out.flush();
}

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn runtimePathForRoot(allocator: std.mem.Allocator, root: []const u8) !?[]u8 {
    const candidate = try std.fs.path.join(allocator, &[_][]const u8{ root, "runtime", "serve.mjs" });
    if (pathExists(candidate)) return candidate;
    allocator.free(candidate);
    return null;
}

fn runtimePathForInstalledSiblingRoot(allocator: std.mem.Allocator, package_dir: []const u8) !?[]u8 {
    const package_name = std.fs.path.basename(package_dir);
    if (!std.mem.startsWith(u8, package_name, manual_provider_name)) return null;
    if (package_name.len <= manual_provider_name.len or package_name[manual_provider_name.len] != '-') return null;

    const scope_dir = std.fs.path.dirname(package_dir) orelse return null;
    const sibling_root = try std.fs.path.join(allocator, &[_][]const u8{ scope_dir, manual_provider_name });
    defer allocator.free(sibling_root);
    return try runtimePathForRoot(allocator, sibling_root);
}

fn resolveRuntimePathFromHints(
    allocator: std.mem.Allocator,
    package_root_override: ?[]const u8,
    cwd: []const u8,
    self_exe: []const u8,
) ![]u8 {
    if (package_root_override) |package_root| {
        if (try runtimePathForRoot(allocator, package_root)) |candidate| return candidate;
    }

    if (try runtimePathForRoot(allocator, cwd)) |candidate| return candidate;

    var dir_slice_opt = std.fs.path.dirname(self_exe);
    var depth: usize = 0;
    while (dir_slice_opt != null and depth < 6) : (depth += 1) {
        const dir_slice = dir_slice_opt.?;
        if (try runtimePathForRoot(allocator, dir_slice)) |candidate| return candidate;
        if (try runtimePathForInstalledSiblingRoot(allocator, dir_slice)) |candidate| return candidate;
        dir_slice_opt = std.fs.path.dirname(dir_slice);
    }

    return error.ProxyRuntimeNotFound;
}

fn resolveRuntimePath(allocator: std.mem.Allocator) ![]u8 {
    const package_root = std.process.getEnvVarOwned(allocator, package_root_env_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (package_root) |root| allocator.free(root);

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    const self_exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_exe);

    return try resolveRuntimePathFromHints(allocator, package_root, cwd, self_exe);
}

test "resolve runtime path finds the root package next to an installed platform package" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(cwd);

    try tmp.dir.makePath("global/node_modules/@zenith139/codex-oauth/runtime");
    try tmp.dir.makePath("global/node_modules/@zenith139/codex-oauth-win32-x64/bin");
    try tmp.dir.writeFile(.{
        .sub_path = "global/node_modules/@zenith139/codex-oauth/runtime/serve.mjs",
        .data = "console.log('ok');\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "global/node_modules/@zenith139/codex-oauth-win32-x64/bin/codex-oauth-proxy.exe",
        .data = "",
    });

    const self_exe = try tmp.dir.realpathAlloc(gpa, "global/node_modules/@zenith139/codex-oauth-win32-x64/bin/codex-oauth-proxy.exe");
    defer gpa.free(self_exe);

    const runtime_path = try resolveRuntimePathFromHints(gpa, null, cwd, self_exe);
    defer gpa.free(runtime_path);

    const expected = try tmp.dir.realpathAlloc(gpa, "global/node_modules/@zenith139/codex-oauth/runtime/serve.mjs");
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, runtime_path);
}

test "resolve runtime path still honors an explicit package root override" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("custom-root/runtime");
    try tmp.dir.writeFile(.{
        .sub_path = "custom-root/runtime/serve.mjs",
        .data = "console.log('ok');\n",
    });

    const package_root = try tmp.dir.realpathAlloc(gpa, "custom-root");
    defer gpa.free(package_root);
    const cwd = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(cwd);
    try tmp.dir.writeFile(.{
        .sub_path = "custom-root/codex-oauth-proxy.exe",
        .data = "",
    });
    const self_exe = try tmp.dir.realpathAlloc(gpa, "custom-root/codex-oauth-proxy.exe");
    defer gpa.free(self_exe);

    const runtime_path = try resolveRuntimePathFromHints(gpa, package_root, cwd, self_exe);
    defer gpa.free(runtime_path);

    const expected = try tmp.dir.realpathAlloc(gpa, "custom-root/runtime/serve.mjs");
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, runtime_path);
}

fn resolveNodeExecutable(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "CODEX_OAUTH_NODE_EXECUTABLE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, "node"),
        else => return err,
    };
}

pub const ServeLaunchOptions = struct {
    node_executable_override: ?[]const u8 = null,
    use_service_stdio: bool = false,
};

fn ensureServeExitedSuccessfully(term: std.process.Child.Term) !void {
    switch (term) {
        .Exited => |code| {
            if (code == 0) return;
            return error.ProxyServeFailed;
        },
        else => return error.ProxyServeFailed,
    }
}

pub fn runServe(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    return try runServeWithOptions(allocator, codex_home, .{});
}

pub fn runServeWithOptions(allocator: std.mem.Allocator, codex_home: []const u8, options: ServeLaunchOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (try ensureApiKey(allocator, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }

    const node_executable = if (options.node_executable_override) |override|
        try allocator.dupe(u8, override)
    else
        try resolveNodeExecutable(allocator);
    defer allocator.free(node_executable);
    const runtime_path = try resolveRuntimePath(allocator);
    defer allocator.free(runtime_path);

    var child = std.process.Child.init(&[_][]const u8{
        node_executable,
        runtime_path,
        "--codex-home",
        codex_home,
    }, allocator);
    child.stdin_behavior = if (options.use_service_stdio) .Ignore else .Inherit;
    child.stdout_behavior = if (options.use_service_stdio) .Ignore else .Inherit;
    child.stderr_behavior = if (options.use_service_stdio) .Ignore else .Inherit;

    const term = try child.spawnAndWait();
    try ensureServeExitedSuccessfully(term);
}

test "manual config rendering includes Codex snippets" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    const cfg = registry.ProxyConfig{
        .listen_host = "127.0.0.1",
        .listen_port = 4318,
        .api_key = "local-proxy-key",
        .strategy = .round_robin,
        .sticky_round_robin_limit = 3,
    };

    try writeManualConfig(&aw.writer, &cfg);

    const output = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "codex-oauth serve") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "~/.codex/config.toml") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "model = \"gpt-5.4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "model_provider = \"codex_oauth\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "model_reasoning_effort = \"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "base_url = \"http://127.0.0.1:4318/v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "~/.codex/auth.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"OPENAI_API_KEY\": \"local-proxy-key\"") != null);
}

test "apply proxy toml config updates managed keys and preserves unrelated sections" {
    const gpa = std.testing.allocator;
    const cfg = registry.ProxyConfig{
        .listen_host = "127.0.0.1",
        .listen_port = 4319,
        .api_key = "local-proxy-key",
        .strategy = .round_robin,
        .sticky_round_robin_limit = 3,
    };
    const existing =
        \\model = "old-model"
        \\model_provider = "old_provider"
        \\model_reasoning_effort = "medium"
        \\approval_policy = "on-request"
        \\
        \\[agents.subagent]
        \\model = "old-subagent"
        \\reasoning_effort = "medium"
        \\
        \\[model_providers.codex_oauth]
        \\name = "old"
        \\base_url = "http://127.0.0.1:1/v1"
        \\
        \\[model_providers.other]
        \\name = "other"
        \\
    ;

    const output = try applyProxyTomlConfigAlloc(gpa, existing, &cfg);
    defer gpa.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "model = \"gpt-5.4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "model_provider = \"codex_oauth\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "model_reasoning_effort = \"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "model_reasoning_effort = \"medium\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "approval_policy = \"on-request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "reasoning_effort = \"medium\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "base_url = \"http://127.0.0.1:4319/v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "http://127.0.0.1:1/v1") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[model_providers.other]") != null);
}

test "auth json config escapes API key" {
    const gpa = std.testing.allocator;
    const output = try authJsonConfigAlloc(gpa, "key\"with\\chars");
    defer gpa.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\"OPENAI_API_KEY\": \"key\\\"with\\\\chars\"") != null);
}

test "proxy service spec exposes expected task names" {
    const spec = proxyServiceSpec();
    try std.testing.expectEqualStrings("codex-oauth-proxy.service", spec.linux_service_name);
    try std.testing.expect(spec.linux_legacy_timer_name == null);
    try std.testing.expectEqualStrings("com.zenith139.codex-oauth.proxy", spec.mac_label);
    try std.testing.expectEqualStrings("CodexOAuthProxy", spec.windows_task_name);
    try std.testing.expectEqualStrings("codex-oauth-proxy.exe", spec.windows_helper_name);
    try std.testing.expectEqual(@as(usize, 1), spec.exec_args.len);
    try std.testing.expectEqualStrings("serve", spec.exec_args[0]);
}

fn proxyDaemonEnabledLabel(enabled: bool) []const u8 {
    return if (enabled) "ON" else "OFF";
}

fn ensureProxyDaemonCanEnable(allocator: std.mem.Allocator) !void {
    if (builtin.os.tag == .linux and !managed_service.linuxUserSystemdAvailable(allocator)) {
        std.log.err("cannot enable proxy daemon: systemd --user is unavailable", .{});
        return error.CommandFailed;
    }
}

fn proxyServiceRuntimeState(allocator: std.mem.Allocator) managed_service.RuntimeState {
    if (!managed_service.supportsManagedServiceOnPlatform(builtin.os.tag)) return .unknown;
    if (builtin.os.tag == .linux and !managed_service.linuxUserSystemdAvailable(allocator)) return .unknown;
    return managed_service.queryRuntimeState(allocator, proxy_service_spec);
}

pub fn proxyDaemonRuntimeState(allocator: std.mem.Allocator) managed_service.RuntimeState {
    return proxyServiceRuntimeState(allocator);
}

fn installProxyService(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !void {
    try managed_service.installService(allocator, codex_home, self_exe, proxy_service_spec);
}

fn uninstallProxyService(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    try managed_service.uninstallService(allocator, codex_home, proxy_service_spec);
}

fn enableProxyDaemon(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    try ensureProxyDaemonCanEnable(allocator);
    const self_exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_exe);
    const managed_self_exe = try managed_service.managedServiceSelfExePath(allocator, self_exe);
    defer allocator.free(managed_self_exe);

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    var changed = try ensureApiKey(allocator, &reg);
    if (!reg.proxy.daemon_enabled) {
        reg.proxy.daemon_enabled = true;
        changed = true;
    }
    if (changed) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }

    try installProxyService(allocator, codex_home, managed_self_exe);
}

fn disableProxyDaemon(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    if (reg.proxy.daemon_enabled) {
        reg.proxy.daemon_enabled = false;
        try registry.saveRegistry(allocator, codex_home, &reg);
    }

    try uninstallProxyService(allocator, codex_home);
}

fn restartProxyDaemon(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    _ = codex_home;
    if (!managed_service.supportsManagedServiceOnPlatform(builtin.os.tag)) return error.UnsupportedPlatform;
    if (builtin.os.tag == .linux and !managed_service.linuxUserSystemdAvailable(allocator)) {
        std.log.err("cannot restart proxy daemon: systemd --user is unavailable", .{});
        return error.CommandFailed;
    }
    try managed_service.restartService(allocator, proxy_service_spec);
}

fn printProxyDaemonStatus(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    const runtime = proxyDaemonRuntimeState(allocator);
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try out.writeAll("proxy daemon: ");
    try out.writeAll(proxyDaemonEnabledLabel(reg.proxy.daemon_enabled));
    try out.writeAll("\n");
    try out.writeAll("proxy daemon service: ");
    try out.writeAll(@tagName(runtime));
    try out.writeAll("\n");
    try out.flush();
}

pub fn handleProxyDaemonCommand(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    opts: cli.ProxyDaemonOptions,
) !void {
    switch (opts.action) {
        .enable => try enableProxyDaemon(allocator, codex_home),
        .disable => try disableProxyDaemon(allocator, codex_home),
        .status => try printProxyDaemonStatus(allocator, codex_home),
        .restart => try restartProxyDaemon(allocator, codex_home),
    }
}

pub fn shouldReconcileProxyService(cmd: cli.Command) bool {
    return switch (cmd) {
        .help, .version, .status, .serve, .daemon, .proxy_daemon => false,
        else => true,
    };
}

pub fn reconcileProxyService(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    if (!managed_service.supportsManagedServiceOnPlatform(builtin.os.tag)) return;

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    if (!reg.proxy.daemon_enabled) {
        try uninstallProxyService(allocator, codex_home);
        return;
    }

    if (builtin.os.tag == .linux and !managed_service.linuxUserSystemdAvailable(allocator)) return;

    const runtime = proxyServiceRuntimeState(allocator);
    const self_exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_exe);
    const managed_self_exe = try managed_service.managedServiceSelfExePath(allocator, self_exe);
    defer allocator.free(managed_self_exe);
    const definition_matches = try managed_service.currentServiceDefinitionMatches(allocator, codex_home, managed_self_exe, proxy_service_spec);
    if (runtime == .running and definition_matches) return;

    try installProxyService(allocator, codex_home, managed_self_exe);
}
