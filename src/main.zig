const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const config = @import("config.zig");
const window = @import("window.zig");
const keybind = @import("keybind.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const allocator = gpa.allocator();

pub var river_window_manager: ?*river.WindowManagerV1 = null;
pub var river_xkb_bindings: ?*river.XkbBindingsV1 = null;
var river_output: ?*river.OutputV1 = null;
var river_seat: ?*river.SeatV1 = null;
var river_layer_shell: ?*river.LayerShellV1 = null;

pub const Workspace = struct {
    window_list: std.ArrayList(window.Window),
    focused_window_index: ?usize,
};

pub var workspace_list: [10]Workspace = undefined;
pub var focused_workspace_index: usize = 0;

var x_non_exclusive: i32 = 0;
var y_non_exclusive: i32 = 0;

pub fn main() !void {
    const display = try wl.Display.connect(null);
    defer display.disconnect();

    const registry = try display.getRegistry();
    defer registry.destroy();
    registry.setListener(?*anyopaque, registryListener, null);

    _ = display.roundtrip();

    if (river_window_manager) |window_manager| {
        std.debug.print("Successfully found River window manager\n", .{});
        window_manager.setListener(?*anyopaque, windowManagerListener, null);

        for (&workspace_list) |*workspace| {
            workspace.* = Workspace{
                .window_list = std.ArrayList(window.Window){},
                .focused_window_index = null,
            };
        }

        config.loadConfig(allocator);

        while (true) {
            const status = display.dispatch();
            if (@intFromEnum(status) != 0) {
                std.debug.print("Wayland loop stopped with status: {any}\n", .{status});
                break;
            }
        }
    } else {
        std.debug.print("Failed to find River window manager\n", .{});
        return;
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
            river_output = output_event.id;
            std.debug.print("Found an output\n", .{});

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

            layer_shell_output.setListener(?*anyopaque, layerShellOutputListener, null);
        },
        .seat => |seat_event| {
            river_seat = seat_event.id;
            std.debug.print("Found a seat\n", .{});

            keybind.setupKeybinds(seat_event.id);
        },
        .window => |window_event| {
            window.addWindow(window_event.id);
        },
        .manage_start => {
            for (workspace_list) |workspace| {
                for (workspace.window_list.items) |item| {
                    item.river_window.proposeDimensions(item.width, item.height);
                }
            }

            const focused_window_index = workspace_list[focused_workspace_index].focused_window_index orelse {
                window_manager.manageFinish();
                return;
            };
            const seat = river_seat orelse {
                std.debug.print("Failed to find a seat\n", .{});
                window_manager.manageFinish();
                return;
            };

            seat.focusWindow(workspace_list[focused_workspace_index].window_list.items[focused_window_index].river_window);
            window_manager.manageFinish();
        },
        .render_start => {
            for (&workspace_list, 0..) |*workspace, i_workspace| {
                const focused_window_index = workspace.focused_window_index orelse continue;
                const focused_window = &workspace.window_list.items[focused_window_index];

                var x_coordinate = @divTrunc(config.config.screen_width, 2) - @divTrunc(focused_window.width, 2) + x_non_exclusive;
                const y_coordinate = (@as(i32, @intCast(i_workspace)) - @as(i32, @intCast(focused_workspace_index))) * config.config.screen_height + y_non_exclusive;
                focused_window.river_node.setPosition(x_coordinate, y_coordinate);
                focused_window.x_coordinate = x_coordinate;
                focused_window.y_coordinate = y_coordinate;

                var i_window: usize = focused_window_index;
                while (i_window > 0) {
                    i_window -= 1;

                    const item = &workspace.window_list.items[i_window];
                    x_coordinate -= item.width;
                    item.river_node.setPosition(x_coordinate, y_coordinate);
                    item.x_coordinate = x_coordinate;
                    item.y_coordinate = y_coordinate;
                }

                x_coordinate = @divTrunc(config.config.screen_width, 2) + @divTrunc(focused_window.width, 2);
                for (workspace.window_list.items[focused_window_index + 1 ..]) |*item| {
                    item.river_node.setPosition(x_coordinate, y_coordinate);
                    item.x_coordinate = x_coordinate;
                    item.y_coordinate = y_coordinate;
                    x_coordinate += item.width;
                }
            }
            window_manager.renderFinish();
        },
        else => {},
    }
}

fn layerShellOutputListener(
    layer_shell: *river.LayerShellOutputV1,
    event: river.LayerShellOutputV1.Event,
    data: ?*anyopaque,
) void {
    _ = data;
    _ = layer_shell;

    switch (event) {
        .non_exclusive_area => |non_exclusive_area| {
            for (&workspace_list) |*workspace| {
                for (workspace.window_list.items) |*item| {
                    item.height = non_exclusive_area.height;
                }
            }
            x_non_exclusive = non_exclusive_area.x;
            y_non_exclusive = non_exclusive_area.y;
        },
    }
}
