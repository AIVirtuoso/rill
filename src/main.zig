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

pub var window_list = std.ArrayList(window.Window){};
pub var focused_window_index: ?usize = null;

pub fn main() !void {
    defer window_list.deinit(allocator);

    const display = try wl.Display.connect(null);
    defer display.disconnect();

    const registry = try display.getRegistry();
    defer registry.destroy();
    registry.setListener(?*anyopaque, registryListener, null);

    _ = display.roundtrip();

    if (river_window_manager) |window_manager| {
        std.debug.print("Successfully bound to River window manager!\n", .{});
        window_manager.setListener(?*anyopaque, windowManagerListener, null);

        config.loadConfig(allocator);

        while (true) {
            const status = display.dispatch();
            if (@intFromEnum(status) != 0) {
                std.debug.print("Wayland loop stopped with status: {any}\n", .{status});
                break;
            }
        }
    } else {
        std.debug.print("Failed to find River window manager!\n", .{});
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

pub const screen_width: i32 = 2560;
pub const screen_height: i32 = 1440;

fn windowManagerListener(
    window_manager: *river.WindowManagerV1,
    event: river.WindowManagerV1.Event,
    data: ?*anyopaque,
) void {
    _ = data;

    switch (event) {
        .output => |_| {
            std.debug.print("Found an output!\n", .{});
        },
        .seat => |seat_event| {
            river_seat = seat_event.id;
            std.debug.print("Found a seat!\n", .{});

            keybind.setupKeybinds(seat_event.id);
        },
        .window => |window_event| {
            window.addWindow(window_event.id);
        },
        .manage_start => {
            const focused_index = focused_window_index orelse {
                window_manager.manageFinish();
                return;
            };

            const seat = river_seat orelse {
                std.debug.print("Failed to find a seat!\n", .{});
                return;
            };
            seat.focusWindow(window_list.items[focused_index].river_window);

            window_manager.manageFinish();
        },
        .render_start => {
            const focused_index = focused_window_index orelse {
                window_manager.renderFinish();
                return;
            };

            const focused_window = window_list.items[focused_index];
            var x_position = @divTrunc(screen_width, 2) - @divTrunc(focused_window.width, 2);
            focused_window.river_node.setPosition(x_position, 0);

            var iter = std.mem.reverseIterator(window_list.items[0..focused_index]);
            while (iter.next()) |item| {
                x_position -= item.width;
                item.river_node.setPosition(x_position, 0);
            }

            x_position = @divTrunc(screen_width, 2) + @divTrunc(focused_window.width, 2);
            for (window_list.items[focused_index + 1 ..]) |item| {
                item.river_node.setPosition(x_position, 0);
                x_position += item.width;
            }

            window_manager.renderFinish();
        },
        else => {},
    }
}
