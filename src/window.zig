const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const animation = @import("animation.zig");
const config = @import("config.zig");
const layout = @import("layout.zig");
const main = @import("main.zig");

pub const Window = struct {
    river_window: *river.WindowV1,
    river_node: *river.NodeV1,
    proportion: f32,
    width: i32,
    x: i32,
    y: i32,
    fullscreen_when_focused: bool,
    animation_info: animation.AnimationInfo,
};

pub fn addWindow(allocator: std.mem.Allocator, river_window: *river.WindowV1) void {
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

    const animation_info = animation.AnimationInfo{
        .width_start = null,
        .width_finish = null,
        .x_start = null,
        .y_start = null,
        .x_finish = null,
        .y_finish = null,
    };

    const window = Window{
        .river_window = river_window,
        .river_node = river_node,
        .proportion = config.config.window_width_proportion,
        .width = width_with_gap - gap,
        .x = layout.output.width,
        .y = layout.output.non_exclusive_y + config.config.vertical_gap,
        .fullscreen_when_focused = false,
        .animation_info = animation_info,
    };

    workspace.window_list.insert(allocator, window_index, window) catch |err| {
        std.debug.print("Failed to add window: {}\n", .{err});
        return;
    };
    workspace.focused_window_index = window_index;

    river_window.setListener(?*anyopaque, windowListener, null);
    layout.applyLayout();
}

fn windowListener(
    river_window: *river.WindowV1,
    event: river.WindowV1.Event,
    data: ?*anyopaque,
) void {
    _ = data;

    for (&layout.workspace_list) |*workspace_item| {
        const window_index = workspace_item.focused_window_index orelse continue;

        for (workspace_item.window_list.items, 0..) |*window_item, i| {
            if (window_item.river_window != river_window) continue;

            switch (event) {
                .closed => {
                    if (i == workspace_item.focused_window_index) {
                        if (workspace_item.window_list.items.len == 1) {
                            workspace_item.focused_window_index = null;
                        } else if (i != 0) {
                            workspace_item.focused_window_index = window_index - 1;
                        }
                    }

                    _ = workspace_item.window_list.orderedRemove(i);
                    river_window.destroy();
                    layout.applyLayout();
                },
                .fullscreen_requested => {
                    window_item.fullscreen_when_focused = true;
                    river_window.informFullscreen();
                    layout.applyLayout();
                },
                .exit_fullscreen_requested => {
                    window_item.fullscreen_when_focused = false;
                    river_window.informNotFullscreen();
                    river_window.exitFullscreen();
                },
                else => {},
            }

            return;
        }
    }
}
