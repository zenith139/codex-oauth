const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_windows = target.result.os.tag == .windows;

    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const exe = b.addExecutable(.{
        .name = "codex-oauth",
        .root_module = main_module,
    });
    b.installArtifact(exe);

    if (is_windows) {
        const auto_module = b.createModule(.{
            .root_source_file = b.path("src/windows_auto_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const auto_exe = b.addExecutable(.{
            .name = "codex-oauth-auto",
            .root_module = auto_module,
        });
        auto_exe.subsystem = .Windows;
        b.installArtifact(auto_exe);

        const proxy_module = b.createModule(.{
            .root_source_file = b.path("src/windows_proxy_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const proxy_exe = b.addExecutable(.{
            .name = "codex-oauth-proxy",
            .root_module = proxy_module,
        });
        proxy_exe.subsystem = .Windows;
        b.installArtifact(proxy_exe);
    }

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run codex-oauth");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const tests = b.addTest(.{
        .name = "codex-oauth-test",
        .root_module = test_module,
    });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests.step);
}
