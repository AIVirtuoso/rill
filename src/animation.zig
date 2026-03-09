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

    const elapsed: f32 = @floatFromInt(std.time.milliTimestamp() - start);
    const progress = elapsed / @as(f32, @floatFromInt(duration));
    const eased = 1 - std.math.pow(f32, 1 - progress, 3);

    for (&output.workspace_list, 0..) |*workspace, workspace_idx| {
        for (workspace.window_list.items, 0..) |*window, window_idx| {
            const target = window.target orelse continue;
            const current = window.rectangle;

            const width_distance: f32 = @floatFromInt(target.width - current.width);
            const height_distance: f32 = @floatFromInt(target.height - current.height);
            const x_distance: f32 = @floatFromInt(target.x - current.x);
            const y_distance: f32 = @floatFromInt(target.y - current.y);

            const width_progress: i32 = @intFromFloat(width_distance * eased);
            const height_progress: i32 = @intFromFloat(height_distance * eased);
            const x_progress: i32 = @intFromFloat(x_distance * eased);
            const y_progress: i32 = @intFromFloat(y_distance * eased);

            if (std.time.milliTimestamp() - start < duration) {
                window.river_window.exitFullscreen();
                const rectangle = types.Rectangle{
                    .width = current.width + width_progress,
                    .height = current.height + height_progress,
                    .x = current.x + x_progress,
                    .y = current.y + y_progress,
                };
                placeWindow(window, rectangle, output.rectangle, config.border.width);
            } else {
                placeWindow(window, target, output.rectangle, config.border.width);

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

                window.rectangle = target;
                window.target = null;
            }
        }
    }
}

fn placeWindow(
    window: *types.Window,
    rectangle: types.Rectangle,
    screen: types.Rectangle,
    border: u8,
) void {
    var border_width = border;
    if (window.is_fullscreen) border_width = 0;

    window.river_window.proposeDimensions(
        rectangle.width - 2 * border_width,
        rectangle.height - 2 * border_width,
    );
    window.river_node.setPosition(
        rectangle.x + border_width,
        rectangle.y + border_width,
    );

    const left = rectangle.x;
    const right = rectangle.x + rectangle.width;
    const top = rectangle.y;
    const bottom = rectangle.y + rectangle.height;

    const screen_left = screen.x;
    const screen_right = screen.x + screen.width;
    const screen_top = screen.y;
    const screen_bottom = screen.y + screen.height;

    if (screen_left >= right or screen_right <= left or
        screen_top >= bottom or screen_bottom <= top)
    {
        window.river_window.hide();
    } else {
        window.river_window.show();
    }

    var clip_width = rectangle.width;
    var clip_height = rectangle.height;
    var clip_x: i32 = 0;
    var clip_y: i32 = 0;

    if (screen_left < right and screen_left > left) {
        clip_x = screen_left - left;
        clip_width = @min(right - screen_left, screen.width);
    } else if (screen_right > left and screen_right < right) {
        clip_width = screen_right - left;
    }

    if (screen_top < bottom and screen_top > top) {
        clip_y = screen_top - top;
        clip_height = bottom - screen_top;
    } else if (screen_bottom > top and screen_bottom < bottom) {
        clip_height = screen_bottom - top;
    }

    window.river_window.setClipBox(
        clip_x - border_width,
        clip_y - border_width,
        clip_width,
        clip_height,
    );
}
