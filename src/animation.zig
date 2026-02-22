const std = @import("std");

const config = @import("config.zig");
const layout = @import("layout.zig");

pub const AnimationInfo = struct {
    width_start: i32,
    height_start: i32,
    x_start: i32,
    y_start: i32,
    width_finish: i32,
    height_finish: i32,
    x_finish: i32,
    y_finish: i32,
};
pub var start_time: ?i64 = null;

pub fn animate() void {
    const start = start_time orelse return;
    const duration = config.config.animation_duration;
    if (std.time.milliTimestamp() - start >= duration) start_time = null;

    const progress = @as(f32, @floatFromInt(std.time.milliTimestamp() - start)) /
        @as(f32, @floatFromInt(duration));
    const eased = 1 - std.math.pow(f32, 1 - progress, 3);
    const border_width = config.config.border.width;

    for (&layout.workspace_list, 0..) |*workspace_item, workspace_idx| {
        for (workspace_item.window_list.items, 0..) |*window_item, window_idx| {
            const info = window_item.animation_info orelse continue;

            const width_distance: f32 = @floatFromInt(info.width_finish - info.width_start);
            const height_distance: f32 = @floatFromInt(info.height_finish - info.height_start);
            const x_distance: f32 = @floatFromInt(info.x_finish - info.x_start);
            const y_distance: f32 = @floatFromInt(info.y_finish - info.y_start);

            const width_progress: i32 = @intFromFloat(width_distance * eased);
            const height_progress: i32 = @intFromFloat(height_distance * eased);
            const x_progress: i32 = @intFromFloat(x_distance * eased);
            const y_progress: i32 = @intFromFloat(y_distance * eased);

            if (std.time.milliTimestamp() - start < duration) {
                if (window_item.fullscreen) {
                    window_item.river_window.proposeDimensions(
                        info.width_start + width_progress,
                        info.height_start + height_progress,
                    );
                    window_item.river_node.setPosition(
                        info.x_start + x_progress,
                        info.y_start + y_progress,
                    );
                } else {
                    window_item.river_window.proposeDimensions(
                        info.width_start + width_progress - 2 * border_width,
                        info.height_start + height_progress - 2 * border_width,
                    );
                    window_item.river_node.setPosition(
                        info.x_start + x_progress + border_width,
                        info.y_start + y_progress + border_width,
                    );
                }
            } else {
                if (window_item.fullscreen) {
                    window_item.river_window.setBorders(.{}, 0, 0, 0, 0, 0);

                    if (workspace_idx == layout.focused_workspace_index and
                        window_idx == workspace_item.focused_window_index)
                    {
                        window_item.river_window.fullscreen(layout.output.river_output);
                    } else {
                        window_item.river_window.proposeDimensions(
                            info.width_finish,
                            info.height_finish,
                        );
                        window_item.river_node.setPosition(info.x_finish, info.y_finish);
                    }
                } else {
                    window_item.river_window.proposeDimensions(
                        info.width_finish - 2 * border_width,
                        info.height_finish - 2 * border_width,
                    );
                    window_item.river_node.setPosition(
                        info.x_finish + border_width,
                        info.y_finish + border_width,
                    );
                }

                window_item.animation_info = null;
            }
        }
    }
}
