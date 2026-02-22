const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;
const wl = wayland.client.wl;

const animation = @import("animation.zig");
const config = @import("config.zig");
const keybind = @import("keybind.zig");
const layout = @import("layout.zig");
const window = @import("window.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const allocator = gpa.allocator();

var river_window_manager: ?*river.WindowManagerV1 = null;
var river_xkb_bindings: ?*river.XkbBindingsV1 = null;
var river_layer_shell: ?*river.LayerShellV1 = null;
var river_seat: ?*river.SeatV1 = null;

pub fn main() !void {
    defer _ = gpa.deinit();

    const display = try wl.Display.connect(null);
    defer display.disconnect();

    const registry = try display.getRegistry();
    defer registry.destroy();
    registry.setListener(?*anyopaque, registryListener, null);

    _ = display.roundtrip();

    const window_manager = river_window_manager orelse {
        std.debug.print("Failed to find window manager\n", .{});
        return;
    };
    window_manager.setListener(?*anyopaque, windowManagerListener, null);

    defer keybind.xkb_binding_list.deinit(allocator);

    for (&layout.workspace_list) |*item| item.* = layout.Workspace{
        .window_list = std.ArrayList(window.Window){},
        .focused_window_index = null,
    };
    defer for (&layout.workspace_list) |*item| item.window_list.deinit(allocator);

    config.loadConfig(allocator);
    config.spawnAtStartup(allocator);

    while (true) {
        const status = display.dispatch();
        if (@intFromEnum(status) != 0) {
            std.debug.print("Program stopped with status: {}\n", .{status});
            break;
        }

        if (animation.start_time) |_| window_manager.manageDirty();
    }
}

fn registryListener(
    registry: *wl.Registry,
    event: wl.Registry.Event,
    _: ?*anyopaque,
) void {
    switch (event) {
        .global => |global| {
            const interface_name = std.mem.span(global.interface);
            if (std.mem.eql(u8, interface_name, "river_window_manager_v1")) {
                river_window_manager = registry.bind(global.name, river.WindowManagerV1, 3) catch null;
            } else if (std.mem.eql(u8, interface_name, "river_xkb_bindings_v1")) {
                river_xkb_bindings = registry.bind(global.name, river.XkbBindingsV1, 2) catch null;
            } else if (std.mem.eql(u8, interface_name, "river_layer_shell_v1")) {
                river_layer_shell = registry.bind(global.name, river.LayerShellV1, 1) catch null;
            }
        },
        .global_remove => {},
    }
}

fn windowManagerListener(
    window_manager: *river.WindowManagerV1,
    event: river.WindowManagerV1.Event,
    _: ?*anyopaque,
) void {
    switch (event) {
        .output => |output_event| {
            output_event.id.setListener(?*anyopaque, layout.outputListener, null);
        },
        .seat => |seat_event| {
            river_seat = seat_event.id;

            const xkb_bindings = river_xkb_bindings orelse {
                std.debug.print("Failed to find xkb bindings\n", .{});
                return;
            };
            keybind.setupKeybinds(allocator, xkb_bindings, seat_event.id);

            const layer_shell = river_layer_shell orelse {
                std.debug.print("Failed to find layer shell\n", .{});
                return;
            };
            const layer_shell_output = layer_shell.getOutput(layout.output.river_output) catch {
                std.debug.print("Failed to get layer shell output\n", .{});
                return;
            };
            layer_shell_output.setListener(
                *river.SeatV1,
                layout.layerShellOutputListener,
                seat_event.id,
            );
        },
        .window => |window_event| {
            const seat = river_seat orelse {
                std.debug.print("Failed to find seat\n", .{});
                return;
            };
            window.addWindow(allocator, window_event.id, seat);
        },
        .manage_start => {
            animation.animate();
            window_manager.manageFinish();
        },
        .render_start => window_manager.renderFinish(),
        else => {},
    }
}
