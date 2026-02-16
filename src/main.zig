const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const config = @import("config.zig");
const window = @import("window.zig");
const layout = @import("layout.zig");
const keybind = @import("keybind.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const allocator = gpa.allocator();

pub var river_window_manager: ?*river.WindowManagerV1 = null;
pub var river_xkb_bindings: ?*river.XkbBindingsV1 = null;
pub var river_seat: ?*river.SeatV1 = null;
var river_layer_shell: ?*river.LayerShellV1 = null;

pub fn main() !void {
    const display = try wl.Display.connect(null);
    defer display.disconnect();

    const registry = try display.getRegistry();
    defer registry.destroy();
    registry.setListener(?*anyopaque, registryListener, null);

    _ = display.roundtrip();

    const window_manager = river_window_manager orelse {
        std.debug.print("Failed to find River window manager\n", .{});
        return;
    };
    std.debug.print("Successfully found River window manager\n", .{});
    window_manager.setListener(?*anyopaque, windowManagerListener, null);

    for (&layout.workspace_list) |*workspace| {
        workspace.* = layout.Workspace{
            .window_list = std.ArrayList(window.Window){},
            .focused_window_index = null,
        };
    }

    config.loadConfig(allocator);
    config.spawnAtStartup(allocator);

    while (true) {
        const status = display.dispatch();
        if (@intFromEnum(status) != 0) {
            std.debug.print("Wayland loop stopped with status: {}\n", .{status});
            break;
        }

        if (layout.animation_progress) |_| {
            window_manager.manageDirty();
        }
    }
}

fn registryListener(
    registry: *wl.Registry,
    event: wl.Registry.Event,
    data: ?*anyopaque,
) void {
    _ = data;
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
        .global_remove => |_| {},
    }
}

fn windowManagerListener(
    window_manager: *river.WindowManagerV1,
    event: river.WindowManagerV1.Event,
    data: ?*anyopaque,
) void {
    _ = data;

    switch (event) {
        .output => |output_event| {
            std.debug.print("Found an output\n", .{});

            output_event.id.setListener(?*anyopaque, layout.outputListener, null);

            const layer_shell = river_layer_shell orelse {
                std.debug.print("Failed to find a layer shell\n", .{});
                return;
            };
            std.debug.print("Successfully found River layer shell\n", .{});

            const layer_shell_output = layer_shell.getOutput(output_event.id) catch {
                std.debug.print("Failed to get layer shell output\n", .{});
                return;
            };
            std.debug.print("Successfully got layer shell output\n", .{});

            layer_shell_output.setListener(?*anyopaque, layout.layerShellOutputListener, null);
        },
        .seat => |seat_event| {
            river_seat = seat_event.id;
            std.debug.print("Found a seat\n", .{});

            keybind.setupKeybinds(seat_event.id);
        },
        .window => |window_event| {
            window.addWindow(allocator, window_event.id);
        },
        .manage_start => {
            window_manager.manageFinish();
        },
        .render_start => {
            layout.animate();

            for (layout.workspace_list) |workspace| {
                for (workspace.window_list.items) |item| {
                    item.river_node.setPosition(item.x, item.y);
                }
            }

            window_manager.renderFinish();
        },
        else => {},
    }
}
