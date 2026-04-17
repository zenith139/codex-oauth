const std = @import("std");
const proxy = @import("proxy.zig");
const registry = @import("registry.zig");

const service_version_flag = "--service-version";
const node_executable_flag = "--node-executable";

const ServiceLaunchOptions = struct {
    node_executable: ?[]u8 = null,
    use_service_stdio: bool = false,

    fn deinit(self: *ServiceLaunchOptions, allocator: std.mem.Allocator) void {
        if (self.node_executable) |value| allocator.free(value);
    }
};

fn parseServiceLaunchOptions(allocator: std.mem.Allocator) !ServiceLaunchOptions {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var options = ServiceLaunchOptions{};
    var idx: usize = 1;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, service_version_flag)) {
            options.use_service_stdio = true;
            if (idx + 1 < args.len) idx += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, node_executable_flag)) {
            if (idx + 1 >= args.len) return error.InvalidArgs;
            idx += 1;
            options.node_executable = try allocator.dupe(u8, args[idx]);
            continue;
        }
    }

    return options;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var options = try parseServiceLaunchOptions(allocator);
    defer options.deinit(allocator);

    const codex_home = try registry.resolveCodexHome(allocator);
    defer allocator.free(codex_home);

    try proxy.runServeWithOptions(allocator, codex_home, .{
        .node_executable_override = options.node_executable,
        .use_service_stdio = options.use_service_stdio,
    });
}
