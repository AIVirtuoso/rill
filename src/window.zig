const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const main = @import("main.zig");
const config = @import("config.zig");

pub const Window = struct {
    river_window: *river.WindowV1,
    river_node: *river.NodeV1,
    width: i32,
};

pub fn addWindow(window: *river.WindowV1) void {
    const width: i32 = @intFromFloat(main.screen_width * config.config.window_width_proportion);
    const height = main.screen_height;

    window.proposeDimensions(width, height);
    window.setListener(?*anyopaque, windowListener, null);

    const node = window.getNode() catch |err| {
        std.debug.print("Failed to get window's node: {}\n", .{err});
        return;
    };

    var window_index: usize = 0;
    if (main.focused_window_index) |focused_index| {
        window_index = focused_index + 1;
    }
    main.window_list.insert(main.allocator, window_index, .{
        .river_window = window,
        .river_node = node,
        .width = width,
    }) catch |err| {
        std.debug.print("Failed to add window: {}\n", .{err});
        return;
    };
    std.debug.print("Added a window! Total windows: {d}\n", .{main.window_list.items.len});

    main.focused_window_index = window_index;
    std.debug.print("Focused on window with index {d}!\n", .{window_index});
}

fn windowListener(
    window: *river.WindowV1,
    event: river.WindowV1.Event,
    data: ?*anyopaque,
) void {
    _ = data;
    switch (event) {
        .closed => {
            const focused_index = main.focused_window_index orelse return;

            for (main.window_list.items, 0..) |item, i| {
                if (item.river_window == window) {
                    if (i == focused_index) {
                        if (main.window_list.items.len == 1) {
                            main.focused_window_index = null;
                        } else if (i == main.window_list.items.len - 1) {
                            main.focused_window_index = focused_index - 1;
                            std.debug.print("Focused on window with index {d}!\n", .{focused_index - 1});
                        }
                    }

                    _ = main.window_list.orderedRemove(i);
                    window.destroy();
                    std.debug.print("Destroyed a window! Remaining: {d}\n", .{main.window_list.items.len});
                    break;
                }
            }
        },
        else => {},
    }
}
