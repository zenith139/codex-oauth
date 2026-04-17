const std = @import("std");
const builtin = @import("builtin");
const registry = @import("registry.zig");
const version = @import("version.zig");

pub const RuntimeState = enum { running, stopped, unknown };

pub const ManagedServiceSpec = struct {
    description: []const u8,
    linux_service_name: []const u8,
    linux_legacy_timer_name: ?[]const u8 = null,
    mac_label: []const u8,
    windows_task_name: []const u8,
    windows_helper_name: []const u8,
    exec_args: []const []const u8,
    requires_node_executable: bool = false,
};

const service_version_env_name = "CODEX_OAUTH_VERSION";
const node_executable_env_name = "CODEX_OAUTH_NODE_EXECUTABLE";
const windows_task_trigger_kind = "LogonTrigger";
const windows_task_register_trigger_flag = "AtLogOn";
const windows_task_restart_count = "999";
const windows_task_restart_interval_xml = "PT1M";
const windows_task_execution_time_limit_xml = "PT0S";
const windows_task_restart_interval_expr = "New-TimeSpan -Minutes 1";
const windows_task_execution_time_limit_expr = "New-TimeSpan -Seconds 0";

pub fn supportsManagedServiceOnPlatform(os_tag: std.Target.Os.Tag) bool {
    return switch (os_tag) {
        .linux, .macos, .windows => true,
        else => false,
    };
}

pub fn linuxUserSystemdAvailable(allocator: std.mem.Allocator) bool {
    const result = runCapture(allocator, &[_][]const u8{ "systemctl", "--user", "show-environment" }) catch return false;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

pub fn managedServiceSelfExePath(allocator: std.mem.Allocator, self_exe: []const u8) ![]u8 {
    return managedServiceSelfExePathFromDir(allocator, std.fs.cwd(), self_exe);
}

pub fn managedServiceSelfExePathFromDir(allocator: std.mem.Allocator, cwd: std.fs.Dir, self_exe: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, self_exe, "/.zig-cache/") != null or std.mem.indexOf(u8, self_exe, "\\.zig-cache\\") != null) {
        const candidate_rel = try std.fs.path.join(allocator, &[_][]const u8{ "zig-out", "bin", std.fs.path.basename(self_exe) });
        defer allocator.free(candidate_rel);
        cwd.access(candidate_rel, .{}) catch return try allocator.dupe(u8, self_exe);
        return try cwd.realpathAlloc(allocator, candidate_rel);
    }
    return try allocator.dupe(u8, self_exe);
}

pub fn queryRuntimeState(allocator: std.mem.Allocator, spec: ManagedServiceSpec) RuntimeState {
    return switch (builtin.os.tag) {
        .linux => queryLinuxRuntimeState(allocator, spec),
        .macos => queryMacRuntimeState(allocator, spec),
        .windows => queryWindowsRuntimeState(allocator, spec),
        else => .unknown,
    };
}

pub fn installService(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    self_exe: []const u8,
    spec: ManagedServiceSpec,
) !void {
    switch (builtin.os.tag) {
        .linux => try installLinuxService(allocator, codex_home, self_exe, spec),
        .macos => try installMacService(allocator, codex_home, self_exe, spec),
        .windows => try installWindowsService(allocator, codex_home, self_exe, spec),
        else => return error.UnsupportedPlatform,
    }
}

pub fn uninstallService(allocator: std.mem.Allocator, codex_home: []const u8, spec: ManagedServiceSpec) !void {
    switch (builtin.os.tag) {
        .linux => try uninstallLinuxService(allocator, codex_home, spec),
        .macos => try uninstallMacService(allocator, codex_home, spec),
        .windows => try uninstallWindowsService(allocator, spec),
        else => return error.UnsupportedPlatform,
    }
}

pub fn restartService(allocator: std.mem.Allocator, spec: ManagedServiceSpec) !void {
    switch (builtin.os.tag) {
        .linux => try runChecked(allocator, &[_][]const u8{ "systemctl", "--user", "restart", spec.linux_service_name }),
        .macos => {
            const plist_path = try macPlistPath(allocator, spec);
            defer allocator.free(plist_path);
            try runChecked(allocator, &[_][]const u8{ "launchctl", "unload", plist_path });
            try runChecked(allocator, &[_][]const u8{ "launchctl", "load", plist_path });
        },
        .windows => try runChecked(allocator, &[_][]const u8{ "schtasks", "/Run", "/TN", spec.windows_task_name }),
        else => return error.UnsupportedPlatform,
    }
}

pub fn currentServiceDefinitionMatches(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    self_exe: []const u8,
    spec: ManagedServiceSpec,
) !bool {
    return switch (builtin.os.tag) {
        .linux => try linuxUnitMatches(allocator, codex_home, self_exe, spec),
        .macos => try macPlistMatches(allocator, codex_home, self_exe, spec),
        .windows => try windowsTaskMatches(allocator, codex_home, self_exe, spec),
        else => true,
    };
}

pub fn deleteAbsoluteFileIfExists(path: []const u8) void {
    std.fs.deleteFileAbsolute(path) catch {};
}

pub fn parseWindowsTaskStateOutput(output: []const u8) RuntimeState {
    const trimmed = std.mem.trim(u8, output, " \n\r\t");
    if (trimmed.len == 0) return .unknown;
    const value = std.fmt.parseInt(u8, trimmed, 10) catch return .unknown;
    return switch (value) {
        4 => .running,
        0, 1, 2, 3 => .stopped,
        else => .unknown,
    };
}

fn installLinuxService(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8, spec: ManagedServiceSpec) !void {
    _ = codex_home;
    const unit_path = try linuxUnitPath(allocator, spec.linux_service_name);
    defer allocator.free(unit_path);
    const unit_text = try linuxUnitText(allocator, self_exe, spec);
    defer allocator.free(unit_text);

    const unit_dir = std.fs.path.dirname(unit_path).?;
    try std.fs.cwd().makePath(unit_dir);
    try std.fs.cwd().writeFile(.{ .sub_path = unit_path, .data = unit_text });
    if (spec.linux_legacy_timer_name) |legacy| {
        try removeLinuxUnit(allocator, legacy);
    }
    try runChecked(allocator, &[_][]const u8{ "systemctl", "--user", "daemon-reload" });
    try runChecked(allocator, &[_][]const u8{ "systemctl", "--user", "enable", spec.linux_service_name });
    switch (queryLinuxRuntimeState(allocator, spec)) {
        .running => try runChecked(allocator, &[_][]const u8{ "systemctl", "--user", "restart", spec.linux_service_name }),
        else => try runChecked(allocator, &[_][]const u8{ "systemctl", "--user", "start", spec.linux_service_name }),
    }
}

fn uninstallLinuxService(allocator: std.mem.Allocator, codex_home: []const u8, spec: ManagedServiceSpec) !void {
    _ = codex_home;
    if (spec.linux_legacy_timer_name) |legacy| try removeLinuxUnit(allocator, legacy);
    try removeLinuxUnit(allocator, spec.linux_service_name);
}

fn removeLinuxUnit(allocator: std.mem.Allocator, service_name: []const u8) !void {
    const unit_path = try linuxUnitPath(allocator, service_name);
    defer allocator.free(unit_path);
    runIgnoringFailure(allocator, &[_][]const u8{ "systemctl", "--user", "stop", service_name });
    runIgnoringFailure(allocator, &[_][]const u8{ "systemctl", "--user", "disable", service_name });
    runIgnoringFailure(allocator, &[_][]const u8{ "systemctl", "--user", "reset-failed", service_name });
    deleteAbsoluteFileIfExists(unit_path);
    runIgnoringFailure(allocator, &[_][]const u8{ "systemctl", "--user", "daemon-reload" });
}

fn installMacService(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8, spec: ManagedServiceSpec) !void {
    _ = codex_home;
    const plist_path = try macPlistPath(allocator, spec);
    defer allocator.free(plist_path);
    const plist = try macPlistText(allocator, self_exe, spec);
    defer allocator.free(plist);

    const dir = std.fs.path.dirname(plist_path).?;
    try std.fs.cwd().makePath(dir);
    try std.fs.cwd().writeFile(.{ .sub_path = plist_path, .data = plist });
    _ = runChecked(allocator, &[_][]const u8{ "launchctl", "unload", plist_path }) catch {};
    try runChecked(allocator, &[_][]const u8{ "launchctl", "load", plist_path });
}

fn uninstallMacService(allocator: std.mem.Allocator, codex_home: []const u8, spec: ManagedServiceSpec) !void {
    _ = codex_home;
    const plist_path = try macPlistPath(allocator, spec);
    defer allocator.free(plist_path);
    _ = runChecked(allocator, &[_][]const u8{ "launchctl", "unload", plist_path }) catch {};
    deleteAbsoluteFileIfExists(plist_path);
}

fn installWindowsService(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8, spec: ManagedServiceSpec) !void {
    _ = codex_home;
    const helper_path = try windowsHelperPath(allocator, self_exe, spec);
    defer allocator.free(helper_path);
    try std.fs.cwd().access(helper_path, .{});

    const register_script = try windowsRegisterTaskScript(allocator, helper_path, spec);
    defer allocator.free(register_script);
    const end_script = try windowsEndTaskScript(allocator, spec);
    defer allocator.free(end_script);
    _ = runChecked(allocator, &[_][]const u8{ "powershell.exe", "-NoLogo", "-NoProfile", "-Command", end_script }) catch {};
    try runChecked(allocator, &[_][]const u8{ "powershell.exe", "-NoLogo", "-NoProfile", "-Command", register_script });
    try runChecked(allocator, &[_][]const u8{ "schtasks", "/Run", "/TN", spec.windows_task_name });
}

fn uninstallWindowsService(allocator: std.mem.Allocator, spec: ManagedServiceSpec) !void {
    const script = try windowsDeleteTaskScript(allocator, spec);
    defer allocator.free(script);
    try runChecked(allocator, &[_][]const u8{ "powershell.exe", "-NoLogo", "-NoProfile", "-Command", script });
}

fn queryLinuxRuntimeState(allocator: std.mem.Allocator, spec: ManagedServiceSpec) RuntimeState {
    const result = runCapture(allocator, &[_][]const u8{ "systemctl", "--user", "is-active", spec.linux_service_name }) catch return .unknown;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .Exited => |code| if (code == 0 and std.mem.startsWith(u8, std.mem.trim(u8, result.stdout, " \n\r\t"), "active")) .running else .stopped,
        else => .unknown,
    };
}

fn queryMacRuntimeState(allocator: std.mem.Allocator, spec: ManagedServiceSpec) RuntimeState {
    const result = runCapture(allocator, &[_][]const u8{ "launchctl", "list", spec.mac_label }) catch return .unknown;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .Exited => |code| if (code == 0) .running else .stopped,
        else => .unknown,
    };
}

fn queryWindowsRuntimeState(allocator: std.mem.Allocator, spec: ManagedServiceSpec) RuntimeState {
    const script = windowsTaskStateScript(allocator, spec) catch return .unknown;
    defer allocator.free(script);
    const result = runCapture(allocator, &[_][]const u8{ "powershell.exe", "-NoLogo", "-NoProfile", "-Command", script }) catch return .unknown;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .Exited => |code| if (code == 0) parseWindowsTaskStateOutput(result.stdout) else if (code == 1) .stopped else .unknown,
        else => .unknown,
    };
}

fn linuxUnitMatches(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8, spec: ManagedServiceSpec) !bool {
    _ = codex_home;
    const unit_path = try linuxUnitPath(allocator, spec.linux_service_name);
    defer allocator.free(unit_path);
    const expected = try linuxUnitText(allocator, self_exe, spec);
    defer allocator.free(expected);
    if (!(try fileEqualsBytes(allocator, unit_path, expected))) return false;
    if (spec.linux_legacy_timer_name) |legacy| {
        if (try linuxUnitHasLegacyResidue(allocator, legacy)) return false;
    }
    return true;
}

fn macPlistMatches(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8, spec: ManagedServiceSpec) !bool {
    _ = codex_home;
    const plist_path = try macPlistPath(allocator, spec);
    defer allocator.free(plist_path);
    const expected = try macPlistText(allocator, self_exe, spec);
    defer allocator.free(expected);
    return try fileEqualsBytes(allocator, plist_path, expected);
}

fn windowsTaskMatches(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8, spec: ManagedServiceSpec) !bool {
    _ = codex_home;
    const helper_path = try windowsHelperPath(allocator, self_exe, spec);
    defer allocator.free(helper_path);
    const expected_action = try windowsExpectedTaskFingerprint(allocator, helper_path);
    defer allocator.free(expected_action);
    const expected_fingerprint = try windowsExpectedTaskDefinitionFingerprint(allocator, expected_action);
    defer allocator.free(expected_fingerprint);
    const script = try windowsTaskMatchScript(allocator, spec);
    defer allocator.free(script);
    const result = runCapture(allocator, &[_][]const u8{ "powershell.exe", "-NoLogo", "-NoProfile", "-Command", script }) catch return false;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .Exited => |code| code == 0 and std.mem.eql(u8, std.mem.trim(u8, result.stdout, " \n\r\t"), expected_fingerprint),
        else => false,
    };
}

fn resolveServiceNodeExecutable(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, node_executable_env_name)) |configured| {
        if (std.fs.path.isAbsolute(configured)) return configured;
        defer allocator.free(configured);
        return try findExecutableInPath(allocator, configured);
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    return try findExecutableInPath(allocator, "node");
}

fn findExecutableInPath(allocator: std.mem.Allocator, executable_name: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(executable_name)) {
        try std.fs.cwd().access(executable_name, .{});
        return try allocator.dupe(u8, executable_name);
    }

    const path_env = try std.process.getEnvVarOwned(allocator, "PATH");
    defer allocator.free(path_env);

    var dirs = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fs.path.join(allocator, &[_][]const u8{ dir, executable_name });
        std.fs.cwd().access(candidate, .{}) catch |err| {
            allocator.free(candidate);
            switch (err) {
                error.FileNotFound => continue,
                else => continue,
            }
        };
        return candidate;
    }
    return error.FileNotFound;
}

fn linuxEnvironmentText(allocator: std.mem.Allocator, spec: ManagedServiceSpec) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    const escaped_version = try escapeSystemdValue(allocator, version.app_version);
    defer allocator.free(escaped_version);
    try out.print(allocator, "Environment=\"{s}={s}\"\n", .{ service_version_env_name, escaped_version });

    if (spec.requires_node_executable) {
        const node_executable = try resolveServiceNodeExecutable(allocator);
        defer allocator.free(node_executable);
        const escaped_node = try escapeSystemdValue(allocator, node_executable);
        defer allocator.free(escaped_node);
        try out.print(allocator, "Environment=\"{s}={s}\"\n", .{ node_executable_env_name, escaped_node });
    }

    return try out.toOwnedSlice(allocator);
}

fn macEnvironmentText(allocator: std.mem.Allocator, spec: ManagedServiceSpec) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    const current_version = try escapeXml(allocator, version.app_version);
    defer allocator.free(current_version);
    try out.print(allocator, "    <key>{s}</key>\n    <string>{s}</string>\n", .{ service_version_env_name, current_version });

    if (spec.requires_node_executable) {
        const node_executable = try resolveServiceNodeExecutable(allocator);
        defer allocator.free(node_executable);
        const escaped_node = try escapeXml(allocator, node_executable);
        defer allocator.free(escaped_node);
        try out.print(allocator, "    <key>{s}</key>\n    <string>{s}</string>\n", .{ node_executable_env_name, escaped_node });
    }

    return try out.toOwnedSlice(allocator);
}

pub fn linuxUnitText(allocator: std.mem.Allocator, self_exe: []const u8, spec: ManagedServiceSpec) ![]u8 {
    const exec = try formatExecString(allocator, self_exe, spec.exec_args);
    defer allocator.free(exec);
    const env_text = try linuxEnvironmentText(allocator, spec);
    defer allocator.free(env_text);
    return try std.fmt.allocPrint(
        allocator,
        "[Unit]\nDescription={s}\n\n[Service]\nType=simple\nRestart=always\nRestartSec=1\n{s}ExecStart={s}\n\n[Install]\nWantedBy=default.target\n",
        .{ spec.description, env_text, exec },
    );
}

pub fn macPlistText(allocator: std.mem.Allocator, self_exe: []const u8, spec: ManagedServiceSpec) ![]u8 {
    const exe = try escapeXml(allocator, self_exe);
    defer allocator.free(exe);
    const env_text = try macEnvironmentText(allocator, spec);
    defer allocator.free(env_text);
    var args_builder = std.ArrayList(u8).empty;
    defer args_builder.deinit(allocator);
    try args_builder.appendSlice(allocator,
        "  <key>ProgramArguments</key>\n  <array>\n    <string>"
    );
    try args_builder.appendSlice(allocator, exe);
    try args_builder.appendSlice(allocator, "</string>\n");
    for (spec.exec_args) |arg| {
        const escaped = try escapeXml(allocator, arg);
        try args_builder.appendSlice(allocator, "    <string>");
        try args_builder.appendSlice(allocator, escaped);
        try args_builder.appendSlice(allocator, "</string>\n");
        allocator.free(escaped);
    }
    try args_builder.appendSlice(allocator, "  </array>\n");
    return try std.fmt.allocPrint(
        allocator,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n  <key>Label</key>\n  <string>{s}</string>\n{s}  <key>EnvironmentVariables</key>\n  <dict>\n{s}  </dict>\n  <key>RunAtLoad</key>\n  <true/>\n  <key>KeepAlive</key>\n  <true/>\n</dict>\n</plist>\n",
        .{ spec.mac_label, args_builder.items, env_text },
    );
}

fn windowsHelperPath(allocator: std.mem.Allocator, self_exe: []const u8, spec: ManagedServiceSpec) ![]u8 {
    const dir = std.fs.path.dirname(self_exe) orelse return error.FileNotFound;
    return try std.fs.path.join(allocator, &[_][]const u8{ dir, spec.windows_helper_name });
}

fn windowsExpectedTaskFingerprint(allocator: std.mem.Allocator, helper_path: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s} --service-version {s}", .{ helper_path, version.app_version });
}

fn windowsExpectedTaskDefinitionFingerprint(allocator: std.mem.Allocator, action: []const u8) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "{s}|TRIGGER:{s}|RESTART:{s},{s}|LIMIT:{s}",
        .{ action, windows_task_trigger_kind, windows_task_restart_count, windows_task_restart_interval_xml, windows_task_execution_time_limit_xml },
    );
}

pub fn windowsTaskAction(allocator: std.mem.Allocator, helper_path: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "\"{s}\" --service-version {s}", .{ helper_path, version.app_version });
}

pub fn windowsRegisterTaskScript(allocator: std.mem.Allocator, helper_path: []const u8, spec: ManagedServiceSpec) ![]u8 {
    const escaped_helper_path = try escapePowerShellSingleQuoted(allocator, helper_path);
    defer allocator.free(escaped_helper_path);
    const escaped_version = try escapePowerShellSingleQuoted(allocator, version.app_version);
    defer allocator.free(escaped_version);
    const escaped_task_name = try escapePowerShellSingleQuoted(allocator, spec.windows_task_name);
    defer allocator.free(escaped_task_name);
    return try std.fmt.allocPrint(
        allocator,
        "$action = New-ScheduledTaskAction -Execute '{s}' -Argument '--service-version {s}'; $trigger = New-ScheduledTaskTrigger -{s}; $settings = New-ScheduledTaskSettingsSet -RestartCount {s} -RestartInterval ({s}) -ExecutionTimeLimit ({s}); Register-ScheduledTask -TaskName '{s}' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null",
        .{ escaped_helper_path, escaped_version, windows_task_register_trigger_flag, windows_task_restart_count, windows_task_restart_interval_expr, windows_task_execution_time_limit_expr, escaped_task_name },
    );
}

pub fn windowsDeleteTaskScript(allocator: std.mem.Allocator, spec: ManagedServiceSpec) ![]u8 {
    const escaped_task_name = try escapePowerShellSingleQuoted(allocator, spec.windows_task_name);
    defer allocator.free(escaped_task_name);
    return try std.fmt.allocPrint(
        allocator,
        "$task = Get-ScheduledTask -TaskName '{s}' -ErrorAction SilentlyContinue; if ($null -eq $task) {{ exit 0 }}; Unregister-ScheduledTask -TaskName '{s}' -Confirm:$false",
        .{ escaped_task_name, escaped_task_name },
    );
}

fn windowsEndTaskScript(allocator: std.mem.Allocator, spec: ManagedServiceSpec) ![]u8 {
    const escaped_task_name = try escapePowerShellSingleQuoted(allocator, spec.windows_task_name);
    defer allocator.free(escaped_task_name);
    return try std.fmt.allocPrint(
        allocator,
        "$task = Get-ScheduledTask -TaskName '{s}' -ErrorAction SilentlyContinue; if ($null -eq $task) {{ exit 0 }}; if ($task.State -eq 4) {{ Stop-ScheduledTask -TaskName '{s}' -ErrorAction SilentlyContinue }}",
        .{ escaped_task_name, escaped_task_name },
    );
}

fn windowsTaskStateScript(allocator: std.mem.Allocator, spec: ManagedServiceSpec) ![]u8 {
    const escaped_task_name = try escapePowerShellSingleQuoted(allocator, spec.windows_task_name);
    defer allocator.free(escaped_task_name);
    return try std.fmt.allocPrint(
        allocator,
        "$task = Get-ScheduledTask -TaskName '{s}' -ErrorAction SilentlyContinue; if ($null -eq $task) {{ exit 1 }}; Write-Output ([int]$task.State)",
        .{escaped_task_name},
    );
}

pub fn windowsTaskMatchScript(allocator: std.mem.Allocator, spec: ManagedServiceSpec) ![]u8 {
    const escaped_task_name = try escapePowerShellSingleQuoted(allocator, spec.windows_task_name);
    defer allocator.free(escaped_task_name);
    return try std.fmt.allocPrint(
        allocator,
        "$task = Get-ScheduledTask -TaskName '{s}' -ErrorAction SilentlyContinue; if ($null -eq $task) {{ exit 1 }}; $action = $task.Actions | Select-Object -First 1; if ($null -eq $action) {{ exit 2 }}; $xml = [xml](Export-ScheduledTask -TaskName '{s}'); $triggers = @($xml.Task.Triggers.ChildNodes | Where-Object {{ $_.NodeType -eq [System.Xml.XmlNodeType]::Element }}); if ($triggers.Count -ne 1) {{ exit 3 }}; $triggerKind = [string]$triggers[0].LocalName; if ([string]::IsNullOrWhiteSpace($triggerKind)) {{ exit 4 }}; $restartNode = $xml.Task.Settings.RestartOnFailure; if ($null -eq $restartNode) {{ exit 5 }}; $restartCount = [string]$restartNode.Count; $restartInterval = [string]$restartNode.Interval; if ([string]::IsNullOrWhiteSpace($restartCount) -or [string]::IsNullOrWhiteSpace($restartInterval)) {{ exit 6 }}; $executionLimit = [string]$xml.Task.Settings.ExecutionTimeLimit; if ([string]::IsNullOrWhiteSpace($executionLimit)) {{ exit 7 }}; $args = if ([string]::IsNullOrWhiteSpace($action.Arguments)) {{ '' }} else {{ ' ' + $action.Arguments }}; Write-Output ($action.Execute + $args + '|TRIGGER:' + $triggerKind + '|RESTART:' + $restartCount + ',' + $restartInterval + '|LIMIT:' + $executionLimit)",
        .{ escaped_task_name, escaped_task_name },
    );
}

fn linuxUnitPath(allocator: std.mem.Allocator, service_name: []const u8) ![]u8 {
    const home = try registry.resolveUserHome(allocator);
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &[_][]const u8{ home, ".config", "systemd", "user", service_name });
}

fn macPlistPath(allocator: std.mem.Allocator, spec: ManagedServiceSpec) ![]u8 {
    const home = try registry.resolveUserHome(allocator);
    defer allocator.free(home);
    const filename = try std.fmt.allocPrint(allocator, "{s}.plist", .{spec.mac_label});
    defer allocator.free(filename);
    return try std.fs.path.join(allocator, &[_][]const u8{ home, "Library", "LaunchAgents", filename });
}

fn readFileIfExists(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    var file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();
    return try file.readToEndAlloc(allocator, 1024 * 1024);
}

fn fileEqualsBytes(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !bool {
    const data = try readFileIfExists(allocator, path);
    defer if (data) |buf| allocator.free(buf);
    if (data == null) return false;
    return std.mem.eql(u8, data.?, bytes);
}

fn linuxUnitHasLegacyResidue(allocator: std.mem.Allocator, service_name: []const u8) !bool {
    const unit_path = try linuxUnitPath(allocator, service_name);
    defer allocator.free(unit_path);
    const legacy_unit = try readFileIfExists(allocator, unit_path);
    defer if (legacy_unit) |bytes| allocator.free(bytes);
    if (legacy_unit != null) return true;

    const result = runCapture(allocator, &[_][]const u8{ "systemctl", "--user", "show", service_name, "--property=LoadState,ActiveState,UnitFileState" }) catch return false;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .Exited => |code| code == 0 and linuxShowUnitHasResidue(result.stdout),
        else => false,
    };
}

fn linuxShowUnitHasResidue(output: []const u8) bool {
    const load_state = linuxShowProperty(output, "LoadState") orelse return false;
    const active_state = linuxShowProperty(output, "ActiveState") orelse return false;
    const unit_file_state = linuxShowProperty(output, "UnitFileState") orelse return false;

    if (!std.mem.eql(u8, load_state, "not-found")) return true;
    if (!std.mem.eql(u8, active_state, "inactive")) return true;
    if (unit_file_state.len != 0 and !std.mem.eql(u8, unit_file_state, "not-found") and !std.mem.eql(u8, unit_file_state, "disabled")) {
        return true;
    }
    return false;
}

fn linuxShowProperty(output: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, key)) continue;
        if (line.len <= key.len or line[key.len] != '=') continue;
        return std.mem.trim(u8, line[key.len + 1 ..], " \r\t");
    }
    return null;
}

fn formatExecString(allocator: std.mem.Allocator, self_exe: []const u8, args: []const []const u8) ![]u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);
    try list.appendSlice(allocator, "\"");
    try list.appendSlice(allocator, self_exe);
    try list.appendSlice(allocator, "\"");
    for (args) |arg| {
        try list.append(allocator, ' ');
        try list.appendSlice(allocator, arg);
    }
    return try list.toOwnedSlice(allocator);
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

fn runChecked(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = try runCapture(allocator, argv);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    switch (result.term) {
        .Exited => |code| {
            if (code == 0) return;
        },
        else => {},
    }
    if (result.stderr.len > 0) {
        std.log.err("{s}", .{std.mem.trim(u8, result.stderr, " \n\r\t")});
    }
    return error.CommandFailed;
}

fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8) !std.process.Child.RunResult {
    return try std.process.Child.run(.{ .allocator = allocator, .argv = argv, .max_output_bytes = 1024 * 1024 });
}

fn runIgnoringFailure(allocator: std.mem.Allocator, argv: []const []const u8) void {
    const result = runCapture(allocator, argv) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}
