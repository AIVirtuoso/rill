const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

var river_window_manager: ?*river.WindowManagerV1 = null;
var river_xkb_bindings: ?*river.XkbBindingsV1 = null;
var river_seat: ?*river.SeatV1 = null;

const Window = struct {
    river_window: *river.WindowV1,
    river_node: *river.NodeV1,
    width: i32,
};
var window_list = std.ArrayList(Window){};
var focused_window_index: ?usize = null;

const Keybind = struct {
    keysym: u32,
    modifier: river.SeatV1.Modifiers,
    action: Action,
};
const Action = union(enum) {
    spawn: []const []const u8,
    focus_window_left: void,
    focus_window_right: void,
    move_window_left: void,
    move_window_right: void,
};
var keybinds = [_]Keybind{
    .{
        .keysym = 0x0063,
        .modifier = .{ .mod4 = true },
        .action = .{ .spawn = &[_][]const u8{"alacritty"} },
    },
    .{
        .keysym = 0x0062,
        .modifier = .{ .mod4 = true },
        .action = .{ .spawn = &[_][]const u8{"firefox"} },
    },
    .{
        .keysym = 0x0061,
        .modifier = .{ .mod4 = true },
        .action = .focus_window_left,
    },
    .{
        .keysym = 0x0064,
        .modifier = .{ .mod4 = true },
        .action = .focus_window_right,
    },
    .{
        .keysym = 0x0061,
        .modifier = .{ .mod4 = true, .shift = true },
        .action = .move_window_left,
    },
    .{
        .keysym = 0x0064,
        .modifier = .{ .mod4 = true, .shift = true },
        .action = .move_window_right,
    },
};

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

fn windowManagerListener(
    window_manager: *river.WindowManagerV1,
    event: river.WindowManagerV1.Event,
    data: ?*anyopaque,
) void {
    _ = data;
    const screen_width: i32 = 2560;
    const screen_height: i32 = 1440;

    switch (event) {
        .output => |_| {
            std.debug.print("Found an output!\n", .{});
        },
        .seat => |seat_event| {
            river_seat = seat_event.id;
            std.debug.print("Found a seat!\n", .{});

            const xkb_bindings = river_xkb_bindings orelse {
                std.debug.print("Failed to find River xkb bindings!\n", .{});
                return;
            };
            std.debug.print("Successfully bound to River xkb bindings!\n", .{});

            for (&keybinds) |*keybind| {
                const river_xkb_binding: ?*river.XkbBindingV1 = xkb_bindings.getXkbBinding(seat_event.id, keybind.keysym, keybind.modifier) catch null;
                const xkb_binding = river_xkb_binding orelse {
                    std.debug.print("Failed to get xkb binding!\n", .{});
                    continue;
                };
                std.debug.print("Successfully got xkb binding!\n", .{});
                xkb_binding.setListener(?*anyopaque, keyboardBindingListener, @ptrCast(@constCast(&keybind.action)));
                xkb_binding.enable();
            }
        },
        .window => |window_event| {
            const width = screen_width * 9 / 10;
            const height = screen_height;

            const window = window_event.id;
            window.proposeDimensions(width, height);
            window.setListener(?*anyopaque, windowListener, null);

            const node = window_event.id.getNode() catch |err| {
                std.debug.print("Failed to get window's node: {}\n", .{err});
                return;
            };

            var window_index: usize = 0;
            if (focused_window_index) |focused_index| {
                window_index = focused_index + 1;
            }
            window_list.insert(allocator, window_index, .{
                .river_window = window,
                .river_node = node,
                .width = width,
            }) catch |err| {
                std.debug.print("Failed to add window: {}\n", .{err});
                return;
            };
            std.debug.print("Added a window! Total windows: {d}\n", .{window_list.items.len});

            focused_window_index = window_index;
            std.debug.print("Focused on window with index {d}!\n", .{window_index});
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

fn windowListener(
    window: *river.WindowV1,
    event: river.WindowV1.Event,
    data: ?*anyopaque,
) void {
    _ = data;
    switch (event) {
        .closed => {
            const focused_index = focused_window_index orelse return;

            for (window_list.items, 0..) |item, i| {
                if (item.river_window == window) {
                    if (i == focused_index) {
                        if (window_list.items.len == 1) {
                            focused_window_index = null;
                        } else if (i == window_list.items.len - 1) {
                            focused_window_index = focused_index - 1;
                            std.debug.print("Focused on window with index {d}!\n", .{focused_index - 1});
                        }
                    }

                    _ = window_list.orderedRemove(i);
                    window.destroy();
                    std.debug.print("Destroyed a window! Remaining: {d}\n", .{window_list.items.len});
                    break;
                }
            }
        },
        else => {},
    }
}

fn keyboardBindingListener(
    binding: *river.XkbBindingV1,
    event: river.XkbBindingV1.Event,
    data: ?*anyopaque,
) void {
    _ = binding;
    const action: *Action = @ptrCast(@alignCast(data.?));
    switch (event) {
        .pressed => {
            switch (action.*) {
                .spawn => |command| {
                    std.debug.print("Keybind pressed! Spawning {s}...\n", .{command[0]});
                    var child = std.process.Child.init(command, allocator);
                    child.spawn() catch |err| {
                        std.debug.print("Failed to spawn {s}: {}\n", .{ command[0], err });
                    };
                },
                .focus_window_left => {
                    const window_manager = river_window_manager orelse return;
                    const focused_index = focused_window_index orelse return;

                    if (focused_index != 0) {
                        focused_window_index = focused_index - 1;
                        std.debug.print("Focused on window with index {d}!\n", .{focused_index - 1});
                        window_manager.manageDirty();
                    }
                },
                .focus_window_right => {
                    const window_manager = river_window_manager orelse return;
                    const focused_index = focused_window_index orelse return;

                    if (focused_index != window_list.items.len - 1) {
                        focused_window_index = focused_index + 1;
                        std.debug.print("Focused on window with index {d}!\n", .{focused_index + 1});
                        window_manager.manageDirty();
                    }
                },
                .move_window_left => {
                    const window_manager = river_window_manager orelse return;
                    const focused_index = focused_window_index orelse return;

                    if (focused_index != 0) {
                        std.mem.swap(Window, &window_list.items[focused_index], &window_list.items[focused_index - 1]);
                        focused_window_index = focused_index - 1;
                        std.debug.print("Focused on window with index {d}!\n", .{focused_index - 1});
                        window_manager.manageDirty();
                    }
                },
                .move_window_right => {
                    const window_manager = river_window_manager orelse return;
                    const focused_index = focused_window_index orelse return;

                    if (focused_index != window_list.items.len - 1) {
                        std.mem.swap(Window, &window_list.items[focused_index], &window_list.items[focused_index + 1]);
                        focused_window_index = focused_index + 1;
                        std.debug.print("Focused on window with index {d}!\n", .{focused_index + 1});
                        window_manager.manageDirty();
                    }
                },
            }
        },
        else => {},
    }
}
