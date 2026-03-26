const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");

pub var begin_time: ?i64 = null;
pub fn apply(
    output: *types.Output,
    config: types.Config,
    seat: *river.SeatV1,
) void {
    const begin = begin_time orelse return;
    const duration = config.animation_duration;
    if (std.time.milliTimestamp() - begin >= duration) begin_time = null;

    const elapsed: f32 = @floatFromInt(std.time.milliTimestamp() - begin);
    const progress = elapsed / @as(f32, @floatFromInt(duration));
    const eased = 1 - std.math.pow(f32, 1 - progress, 3);

    for (&output.workspace_list, 0..) |*workspace, workspace_idx| {
        for (workspace.window_list.items, 0..) |*window, window_idx| {
            const start = window.start orelse continue;
            const finish = window.finish orelse continue;

            if (std.time.milliTimestamp() - begin < duration) {
                const width_distance: f32 = @floatFromInt(finish.width - start.width);
                const height_distance: f32 = @floatFromInt(finish.height - start.height);
                const x_distance: f32 = @floatFromInt(finish.x - start.x);
                const y_distance: f32 = @floatFromInt(finish.y - start.y);

                const width_progress: i32 = @intFromFloat(width_distance * eased);
                const height_progress: i32 = @intFromFloat(height_distance * eased);
                const x_progress: i32 = @intFromFloat(x_distance * eased);
                const y_progress: i32 = @intFromFloat(y_distance * eased);

                window.rectangle = .{
                    .width = start.width + width_progress,
                    .height = start.height + height_progress,
                    .x = start.x + x_progress,
                    .y = start.y + y_progress,
                };

                window.river_window.exitFullscreen();
                placeWindow(window, output.rectangle, config.border.width);
            } else {
                window.rectangle = finish;
                placeWindow(window, output.rectangle, config.border.width);

                if (workspace_idx == output.focused_workspace_idx and
                    window_idx == workspace.focused_window_idx)
                {
                    seat.focusWindow(window.river_window);
                    window.river_node.placeTop();
                    if (window.is_fullscreen)
                        window.river_window.fullscreen(output.river_output);
                }

                if (window.is_fullscreen) {
                    window.river_window.informFullscreen();
                    window.river_window.setBorders(.{}, 0, 0, 0, 0, 0);
                } else {
                    window.river_window.informNotFullscreen();
                }

                window.rectangle = finish;
                window.start = null;
                window.finish = null;
            }
        }
    }
}

fn placeWindow(
    window: *types.Window,
    output: types.Rectangle,
    border: u8,
) void {
    var border_width = border;
    if (window.is_fullscreen) border_width = 0;

    window.river_window.proposeDimensions(
        window.rectangle.width - 2 * border_width,
        window.rectangle.height - 2 * border_width,
    );
    window.river_node.setPosition(
        window.rectangle.x + border_width,
        window.rectangle.y + border_width,
    );

    const window_left = window.rectangle.x;
    const window_right = window.rectangle.x + window.rectangle.width;
    const window_top = window.rectangle.y;
    const window_bottom = window.rectangle.y + window.rectangle.height;

    const output_left = output.x;
    const output_right = output.x + output.width;
    const output_top = output.y;
    const output_bottom = output.y + output.height;

    if (output_left >= window_right or output_right <= window_left or
        output_top >= window_bottom or output_bottom <= window_top)
    {
        window.river_window.hide();
    } else {
        window.river_window.show();
    }

    var clip_width = window.rectangle.width;
    var clip_height = window.rectangle.height;
    var clip_x: i32 = 0;
    var clip_y: i32 = 0;

    if (output_left < window_right and output_left > window_left) {
        clip_x = output_left - window_left;
        clip_width = @min(window_right - output_left, output.width);
    } else if (output_right > window_left and output_right < window_right) {
        clip_width = output_right - window_left;
    }

    if (output_top < window_bottom and output_top > window_top) {
        clip_y = output_top - window_top;
        clip_height = window_bottom - output_top;
    } else if (output_bottom > window_top and output_bottom < window_bottom) {
        clip_height = output_bottom - window_top;
    }

    window.river_window.setClipBox(
        clip_x - border_width,
        clip_y - border_width,
        clip_width,
        clip_height,
    );
}
