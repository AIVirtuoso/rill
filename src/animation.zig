const std = @import("std");

const config = @import("config.zig");
const layout = @import("layout.zig");

pub const AnimationInfo = struct {
    width_start: i32,
    x_start: i32,
    y_start: i32,
    width_finish: i32,
    x_finish: i32,
    y_finish: i32,
};
pub var start_time: ?i64 = null;

pub fn animate() void {
    const start = start_time orelse return;

    const duration = config.config.animation_duration;
    const progress = @as(f32, @floatFromInt(std.time.milliTimestamp() - start)) /
        @as(f32, @floatFromInt(duration));
    const eased = 1 - std.math.pow(f32, 1 - progress, 3);

    for (&layout.workspace_list) |*workspace_item| {
        for (workspace_item.window_list.items) |*window_item| {
            const info = window_item.animation_info orelse continue;

            const width_distance: f32 = @floatFromInt(info.width_finish - info.width_start);
            const x_distance: f32 = @floatFromInt(info.x_finish - info.x_start);
            const y_distance: f32 = @floatFromInt(info.y_finish - info.y_start);

            const width_progress: i32 = @intFromFloat(width_distance * eased);
            const x_progress: i32 = @intFromFloat(x_distance * eased);
            const y_progress: i32 = @intFromFloat(y_distance * eased);

            if (std.time.milliTimestamp() - start < duration) {
                window_item.width = info.width_start + width_progress;
                window_item.x = info.x_start + x_progress;
                window_item.y = info.y_start + y_progress;
            } else {
                window_item.width = info.width_finish;
                window_item.x = info.x_finish;
                window_item.y = info.y_finish;

                window_item.animation_info = null;
            }
        }
    }

    if (std.time.milliTimestamp() - start >= duration) start_time = null;
}
