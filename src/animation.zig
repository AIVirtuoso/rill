const std = @import("std");

const config = @import("config.zig");
const layout = @import("layout.zig");

pub const AnimationInfo = struct {
    x_start: ?i32,
    x_finish: ?i32,
    y_start: ?i32,
    y_finish: ?i32,
    width_start: ?i32,
    width_finish: ?i32,
};
pub var animation_start_time: ?i64 = null;

pub fn animate() void {
    const start_time = animation_start_time orelse return;

    const duration = config.config.animation_duration;
    const progress = @as(f32, @floatFromInt(std.time.milliTimestamp() - start_time)) /
        @as(f32, @floatFromInt(duration));
    const eased = 1 - std.math.pow(f32, 1 - progress, 3);

    for (&layout.workspace_list) |*workspace_item| {
        for (workspace_item.window_list.items) |*window_item| {
            const x_start = window_item.animation_info.x_start orelse continue;
            const x_finish = window_item.animation_info.x_finish orelse continue;
            const y_start = window_item.animation_info.y_start orelse continue;
            const y_finish = window_item.animation_info.y_finish orelse continue;

            const x_distance: f32 = @floatFromInt(x_finish - x_start);
            const y_distance: f32 = @floatFromInt(y_finish - y_start);

            const x_progress: i32 = @intFromFloat(x_distance * eased);
            const y_progress: i32 = @intFromFloat(y_distance * eased);

            if (std.time.milliTimestamp() - start_time < duration) {
                window_item.x = x_start + x_progress;
                window_item.y = y_start + y_progress;
            } else {
                window_item.x = x_finish;
                window_item.y = y_finish;

                window_item.animation_info.x_start = null;
                window_item.animation_info.x_finish = null;
                window_item.animation_info.y_start = null;
                window_item.animation_info.y_finish = null;
            }

            const width_start = window_item.animation_info.width_start orelse continue;
            const width_finish = window_item.animation_info.width_finish orelse continue;

            const width_distance: f32 = @floatFromInt(width_finish - width_start);
            const width_progress: i32 = @intFromFloat(width_distance * eased);

            if (std.time.milliTimestamp() - start_time < duration) {
                window_item.width = width_start + width_progress;
            } else {
                window_item.width = width_finish;
                window_item.animation_info.width_start = null;
                window_item.animation_info.width_finish = null;
            }
        }
    }

    if (std.time.milliTimestamp() - start_time >= duration) {
        animation_start_time = null;
    }
}
