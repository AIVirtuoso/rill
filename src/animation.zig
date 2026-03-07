const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const config = @import("config.zig");
const layout = @import("layout.zig");
const types = @import("types.zig");

pub var start_time: ?i64 = null;

pub fn apply(seat: *river.SeatV1) void {
    const start = start_time orelse return;
    const duration = config.config.animation_duration;
    if (std.time.milliTimestamp() - start >= duration) start_time = null;

    const progress = @as(f32, @floatFromInt(std.time.milliTimestamp() - start)) /
        @as(f32, @floatFromInt(duration));
    const eased = 1 - std.math.pow(f32, 1 - progress, 3);

    const output = &layout.output_list.items[layout.focused_output_index];
    for (&output.workspace_list, 0..) |*workspace_item, workspace_idx| {
        for (workspace_item.window_list.items, 0..) |*window_item, window_idx| {
            const target = window_item.target orelse continue;

            const width_distance: f32 = @floatFromInt(target.width - window_item.width);
            const height_distance: f32 = @floatFromInt(target.height - window_item.height);
            const x_distance: f32 = @floatFromInt(target.x - window_item.x);
            const y_distance: f32 = @floatFromInt(target.y - window_item.y);

            const width_progress: i32 = @intFromFloat(width_distance * eased);
            const height_progress: i32 = @intFromFloat(height_distance * eased);
            const x_progress: i32 = @intFromFloat(x_distance * eased);
            const y_progress: i32 = @intFromFloat(y_distance * eased);

            if (std.time.milliTimestamp() - start < duration) {
                window_item.river_window.exitFullscreen();
                placeWindow(
                    window_item,
                    window_item.width + width_progress,
                    window_item.height + height_progress,
                    window_item.x + x_progress,
                    window_item.y + y_progress,
                    output.dimensions,
                );
            } else {
                placeWindow(
                    window_item,
                    target.width,
                    target.height,
                    target.x,
                    target.y,
                    output.dimensions,
                );

                if (workspace_idx == output.focused_workspace_index and
                    window_idx == workspace_item.focused_window_index)
                {
                    seat.focusWindow(window_item.river_window);
                    window_item.river_node.placeTop();
                    if (window_item.fullscreen)
                        window_item.river_window.fullscreen(output.river_output);
                }

                if (window_item.fullscreen) {
                    window_item.river_window.informFullscreen();
                    window_item.river_window.setBorders(.{}, 0, 0, 0, 0, 0);
                } else {
                    window_item.river_window.informNotFullscreen();
                }

                window_item.width = target.width;
                window_item.height = target.height;
                window_item.x = target.x;
                window_item.y = target.y;
                window_item.target = null;
            }
        }
    }
}

fn placeWindow(
    window_item: *types.Window,
    width: i32,
    height: i32,
    x: i32,
    y: i32,
    screen: types.Dimensions,
) void {
    var border_width = config.config.border.width;
    if (window_item.fullscreen) border_width = 0;

    window_item.river_window.proposeDimensions(
        width - 2 * border_width,
        height - 2 * border_width,
    );
    window_item.river_node.setPosition(
        x + border_width,
        y + border_width,
    );

    const left_edge = screen.x;
    const right_edge = screen.x + screen.width;
    const top_edge = screen.y;
    const bottom_edge = screen.y + screen.height;

    if (left_edge >= x + width or right_edge <= x or
        top_edge >= y + height or bottom_edge <= y)
    {
        window_item.river_window.hide();
    } else {
        window_item.river_window.show();
    }

    var clip_width = width;
    var clip_height = height;
    var clip_x: i32 = 0;
    var clip_y: i32 = 0;

    if (left_edge < x + width and left_edge > x) {
        clip_x = left_edge - x;
        clip_width = @min(x + width - left_edge, screen.width);
    } else if (right_edge > x and right_edge < x + width) {
        clip_width = right_edge - x;
    }

    if (top_edge < y + height and top_edge > y) {
        clip_y = top_edge - y;
        clip_height = y + height - top_edge;
    } else if (bottom_edge > y and bottom_edge < y + height) {
        clip_height = bottom_edge - y;
    }

    window_item.river_window.setClipBox(
        clip_x - border_width,
        clip_y - border_width,
        clip_width,
        clip_height,
    );
}
