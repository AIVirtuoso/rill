const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");

pub var start_time: ?i64 = null;
pub fn apply(
    output: *types.Output,
    config: types.Config,
    seat: *river.SeatV1,
) void {
    const start = start_time orelse return;
    const duration = config.animation_duration;
    if (std.time.milliTimestamp() - start >= duration) start_time = null;

    const progress = @as(f32, @floatFromInt(std.time.milliTimestamp() - start)) /
        @as(f32, @floatFromInt(duration));
    const eased = 1 - std.math.pow(f32, 1 - progress, 3);

    for (&output.workspace_list, 0..) |*workspace, workspace_idx| {
        for (workspace.window_list.items, 0..) |*window, window_idx| {
            const target = window.target orelse continue;

            const width_distance: f32 = @floatFromInt(target.width - window.width);
            const height_distance: f32 = @floatFromInt(target.height - window.height);
            const x_distance: f32 = @floatFromInt(target.x - window.x);
            const y_distance: f32 = @floatFromInt(target.y - window.y);

            const width_progress: i32 = @intFromFloat(width_distance * eased);
            const height_progress: i32 = @intFromFloat(height_distance * eased);
            const x_progress: i32 = @intFromFloat(x_distance * eased);
            const y_progress: i32 = @intFromFloat(y_distance * eased);

            if (std.time.milliTimestamp() - start < duration) {
                window.river_window.exitFullscreen();
                placeWindow(
                    window,
                    window.width + width_progress,
                    window.height + height_progress,
                    window.x + x_progress,
                    window.y + y_progress,
                    output.dimensions,
                    config.border.width,
                );
            } else {
                placeWindow(
                    window,
                    target.width,
                    target.height,
                    target.x,
                    target.y,
                    output.dimensions,
                    config.border.width,
                );

                if (workspace_idx == output.focused_workspace_idx and
                    window_idx == workspace.focused_window_idx)
                {
                    seat.focusWindow(window.river_window);
                    window.river_node.placeTop();
                    if (window.fullscreen)
                        window.river_window.fullscreen(output.river_output);
                }

                if (window.fullscreen) {
                    window.river_window.informFullscreen();
                    window.river_window.setBorders(.{}, 0, 0, 0, 0, 0);
                } else {
                    window.river_window.informNotFullscreen();
                }

                window.width = target.width;
                window.height = target.height;
                window.x = target.x;
                window.y = target.y;
                window.target = null;
            }
        }
    }
}

fn placeWindow(
    window: *types.Window,
    width: i32,
    height: i32,
    x: i32,
    y: i32,
    screen: types.Dimensions,
    border: u8,
) void {
    var border_width = border;
    if (window.fullscreen) border_width = 0;

    window.river_window.proposeDimensions(
        width - 2 * border_width,
        height - 2 * border_width,
    );
    window.river_node.setPosition(
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
        window.river_window.hide();
    } else {
        window.river_window.show();
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

    window.river_window.setClipBox(
        clip_x - border_width,
        clip_y - border_width,
        clip_width,
        clip_height,
    );
}
