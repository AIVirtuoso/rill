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

    for (&layout.workspace_list) |*workspace| {
        for (workspace.window_list.items) |*item| {
            const x_start = item.animation_info.x_start orelse continue;
            const x_finish = item.animation_info.x_finish orelse continue;
            const y_start = item.animation_info.y_start orelse continue;
            const y_finish = item.animation_info.y_finish orelse continue;

            const x_distance: f32 = @floatFromInt(x_finish - x_start);
            const y_distance: f32 = @floatFromInt(y_finish - y_start);

            const x_progress: i32 = @intFromFloat(x_distance * eased);
            const y_progress: i32 = @intFromFloat(y_distance * eased);

            if (std.time.milliTimestamp() - start_time < duration) {
                item.x = x_start + x_progress;
                item.y = y_start + y_progress;
            } else {
                item.x = x_finish;
                item.y = y_finish;

                item.animation_info.x_start = null;
                item.animation_info.x_finish = null;
                item.animation_info.y_start = null;
                item.animation_info.y_finish = null;
            }

            const width_start = item.animation_info.width_start orelse continue;
            const width_finish = item.animation_info.width_finish orelse continue;

            const width_distance: f32 = @floatFromInt(width_finish - width_start);
            const width_progress: i32 = @intFromFloat(width_distance * eased);

            if (std.time.milliTimestamp() - start_time < duration) {
                item.width = width_start + width_progress;
            } else {
                item.width = width_finish;

                item.animation_info.width_start = null;
                item.animation_info.width_finish = null;
            }
        }
    }

    if (std.time.milliTimestamp() - start_time >= duration) {
        animation_start_time = null;
    }
}
