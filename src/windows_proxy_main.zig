const std = @import("std");
const proxy = @import("proxy.zig");
const registry = @import("registry.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const codex_home = try registry.resolveCodexHome(allocator);
    defer allocator.free(codex_home);

    try proxy.runServe(allocator, codex_home);
}
