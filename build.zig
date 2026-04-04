const std = @import("std");
const wayland = @import("wayland");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const pie = b.option(bool, "pie", "Build with PIE") orelse false;
    const scanner = wayland.Scanner.create(b, .{});
    scanner.addCustomProtocol(b.path("protocol/river-window-management-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-xkb-bindings-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-layer-shell-v1.xml"));
    scanner.generate("river_window_manager_v1", 4);
    scanner.generate("river_xkb_bindings_v1", 2);
    scanner.generate("river_layer_shell_v1", 1);

    const wayland_module = b.createModule(.{
        .root_source_file = scanner.result,
    });
    const xkbcommon_module = b.dependency("xkbcommon", .{}).module("xkbcommon");

    const imports = [_]std.Build.Module.Import{
        .{ .name = "wayland", .module = wayland_module },
        .{ .name = "xkbcommon", .module = xkbcommon_module },
    };
    const exe = b.addExecutable(.{
        .name = "rill",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &imports,
        }),
    });
    exe.pie = pie;
    exe.root_module.linkSystemLibrary("wayland-client", .{});
    exe.root_module.linkSystemLibrary("xkbcommon", .{});

    b.installArtifact(exe);

    const keybinding_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/keybinding.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &imports,
        }),
    });
    keybinding_tests.root_module.linkSystemLibrary("wayland-client", .{});
    keybinding_tests.root_module.linkSystemLibrary("xkbcommon", .{});
    const run_tests = b.addRunArtifact(keybinding_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
