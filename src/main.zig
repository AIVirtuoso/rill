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
var river_seat: ?*river.SeatV1 = null;

pub const Workspace = struct {
    window_list: std.ArrayList(window.Window),
    focused_window_index: ?usize,
};

pub var workspace_list: [10]Workspace = undefined;
pub var focused_workspace_index: usize = 0;

pub fn main() !void {
    const display = try wl.Display.connect(null);
    defer display.disconnect();

    const registry = try display.getRegistry();
    defer registry.destroy();
    registry.setListener(?*anyopaque, registryListener, null);

    _ = display.roundtrip();

    if (river_window_manager) |window_manager| {
        std.debug.print("Successfully bound to River window manager\n", .{});
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
        .output => |_| {
            std.debug.print("Found an output\n", .{});
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
            for (workspace_list, 0..) |workspace, i| {
                const focused_window_index = workspace.focused_window_index orelse continue;

                const focused_window = workspace.window_list.items[focused_window_index];
                var x_position = @divTrunc(config.config.screen_width, 2) - @divTrunc(focused_window.width, 2);
                const y_position = (@as(i32, @intCast(i)) - @as(i32, @intCast(focused_workspace_index))) * config.config.screen_height;
                focused_window.river_node.setPosition(x_position, y_position);

                var iter = std.mem.reverseIterator(workspace.window_list.items[0..focused_window_index]);
                while (iter.next()) |item| {
                    x_position -= item.width;
                    item.river_node.setPosition(x_position, y_position);
                }

                x_position = @divTrunc(config.config.screen_width, 2) + @divTrunc(focused_window.width, 2);
                for (workspace.window_list.items[focused_window_index + 1 ..]) |item| {
                    item.river_node.setPosition(x_position, y_position);
                    x_position += item.width;
                }
            }
            window_manager.renderFinish();
        },
        else => {},
    }
}
