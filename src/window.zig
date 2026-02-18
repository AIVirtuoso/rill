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
    width: i32,
    x: i32,
    y: i32,
    is_fullscreen: bool,
    animation_info: animation.AnimationInfo,
};

pub fn addWindow(allocator: std.mem.Allocator, window: *river.WindowV1) void {
    const focused_workspace = &layout.workspace_list[layout.focused_workspace_index];
    var window_index: usize = 0;
    if (focused_workspace.focused_window_index) |focused_window_index| {
        window_index = focused_window_index + 1;
    }

    const node = window.getNode() catch |err| {
        std.debug.print("Failed to get window's node: {}\n", .{err});
        return;
    };

    const width = @as(f32, @floatFromInt(layout.output.non_exclusive_width)) *
        config.config.window_width_proportion;

    const animation_info = animation.AnimationInfo{
        .width_start = null,
        .width_finish = null,
        .x_start = null,
        .y_start = null,
        .x_finish = null,
        .y_finish = null,
    };

    focused_workspace.window_list.insert(allocator, window_index, .{
        .river_window = window,
        .river_node = node,
        .width = @intFromFloat(width),
        .x = layout.output.width,
        .y = layout.output.non_exclusive_y + config.config.outer_gap,
        .is_fullscreen = false,
        .animation_info = animation_info,
    }) catch |err| {
        std.debug.print("Failed to add window: {}\n", .{err});
        return;
    };
    focused_workspace.focused_window_index = window_index;

    window.setListener(?*anyopaque, windowListener, null);
    layout.applyLayout();
}

fn windowListener(
    river_window: *river.WindowV1,
    event: river.WindowV1.Event,
    data: ?*anyopaque,
) void {
    _ = data;

    for (&layout.workspace_list) |*workspace| {
        const focused_window_index = workspace.focused_window_index orelse continue;

        for (workspace.window_list.items, 0..) |*window, i| {
            if (window.river_window != river_window) continue;

            switch (event) {
                .closed => {
                    if (i == workspace.focused_window_index) {
                        if (workspace.window_list.items.len == 1) {
                            workspace.focused_window_index = null;
                        } else if (i != 0) {
                            workspace.focused_window_index = focused_window_index - 1;
                        }
                    }

                    _ = workspace.window_list.orderedRemove(i);
                    river_window.destroy();
                    layout.applyLayout();
                },
                .fullscreen_requested => {
                    river_window.fullscreen(layout.output.river_output);
                    river_window.informFullscreen();
                    window.is_fullscreen = true;
                },
                .exit_fullscreen_requested => {
                    river_window.exitFullscreen();
                    river_window.informNotFullscreen();
                    window.is_fullscreen = false;
                },
                else => {},
            }

            return;
        }
    }
}
