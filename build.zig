const std = @import("std");
const wayland = @import("wayland");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scanner = wayland.Scanner.create(b, .{});
    scanner.addCustomProtocol(b.path("protocol/river-window-management-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-xkb-bindings-v1.xml"));
    scanner.generate("river_window_manager_v1", 3);
    scanner.generate("river_xkb_bindings_v1", 2);

    const wayland_module = b.createModule(.{
        .root_source_file = scanner.result,
    });

    const exe = b.addExecutable(.{
        .name = "wm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wayland", .module = wayland_module },
            },
            .link_libc = true,
        }),
    });
    exe.root_module.linkSystemLibrary("wayland-client", .{});

    b.installArtifact(exe);
}
