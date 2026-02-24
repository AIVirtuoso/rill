const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const animation = @import("animation.zig");
const config = @import("config.zig");
const layout = @import("layout.zig");

pub const Window = struct {
    river_window: *river.WindowV1,
    river_node: *river.NodeV1,
    proportion: f32,
    width: i32,
    height: i32,
    x: i32,
    y: i32,
    fullscreen: bool,
    target: ?animation.Target,
};

pub fn addWindow(
    allocator: std.mem.Allocator,
    river_window: *river.WindowV1,
    seat: *river.SeatV1,
) void {
    const workspace = &layout.workspace_list[layout.focused_workspace_index];

    var window_index: usize = 0;
    if (workspace.focused_window_index) |index|
        window_index = index + 1;

    const river_node = river_window.getNode() catch |err| {
        std.debug.print("Failed to get window's node: {}\n", .{err});
        return;
    };

    const gap = config.config.horizontal_gap;
    const base_width: f32 = @floatFromInt(layout.output.non_exclusive_width - gap);
    const width_with_gap: i32 =
        @intFromFloat(base_width * config.config.window_width_proportion);
    const height = layout.output.non_exclusive_height - 2 * config.config.vertical_gap;

    const window = Window{
        .river_window = river_window,
        .river_node = river_node,
        .proportion = config.config.window_width_proportion,
        .width = width_with_gap - gap,
        .height = height,
        .x = layout.output.width,
        .y = layout.output.non_exclusive_y + config.config.vertical_gap,
        .fullscreen = false,
        .target = null,
    };

    workspace.window_list.insert(allocator, window_index, window) catch |err| {
        std.debug.print("Failed to add window: {}\n", .{err});
        return;
    };
    workspace.focused_window_index = window_index;

    river_window.setListener(*river.SeatV1, windowListener, seat);
    layout.applyLayout(seat);
}

fn windowListener(
    river_window: *river.WindowV1,
    event: river.WindowV1.Event,
    seat: *river.SeatV1,
) void {
    for (&layout.workspace_list) |*workspace_item| {
        const window_index = workspace_item.focused_window_index orelse continue;

        for (workspace_item.window_list.items, 0..) |*window_item, idx| {
            if (window_item.river_window != river_window) continue;

            switch (event) {
                .closed => {
                    if (idx == workspace_item.focused_window_index) {
                        if (workspace_item.window_list.items.len == 1) {
                            workspace_item.focused_window_index = null;
                        } else if (idx != 0) {
                            workspace_item.focused_window_index = window_index - 1;
                        }
                    }

                    _ = workspace_item.window_list.orderedRemove(idx);
                    river_window.destroy();
                    layout.applyLayout(seat);
                },
                .fullscreen_requested => {
                    window_item.fullscreen = true;
                    river_window.informFullscreen();
                    layout.applyLayout(seat);
                },
                .exit_fullscreen_requested => {
                    window_item.fullscreen = false;
                    river_window.informNotFullscreen();
                    layout.applyLayout(seat);
                },
                else => {},
            }

            return;
        }
    }
}
