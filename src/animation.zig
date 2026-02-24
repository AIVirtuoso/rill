const std = @import("std");

const config = @import("config.zig");
const layout = @import("layout.zig");

pub const Target = struct {
    width: i32,
    height: i32,
    x: i32,
    y: i32,
};
pub var start_time: ?i64 = null;

pub fn animate() void {
    const start = start_time orelse return;
    const duration = config.config.animation_duration;
    if (std.time.milliTimestamp() - start >= duration) start_time = null;

    const progress = @as(f32, @floatFromInt(std.time.milliTimestamp() - start)) /
        @as(f32, @floatFromInt(duration));
    const eased = 1 - std.math.pow(f32, 1 - progress, 3);

    for (&layout.workspace_list, 0..) |*workspace_item, workspace_idx| {
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

            var border_width = config.config.border.width;
            if (window_item.fullscreen) border_width = 0;

            if (std.time.milliTimestamp() - start < duration) {
                window_item.river_window.proposeDimensions(
                    window_item.width + width_progress - 2 * border_width,
                    window_item.height + height_progress - 2 * border_width,
                );
                window_item.river_node.setPosition(
                    window_item.x + x_progress + border_width,
                    window_item.y + y_progress + border_width,
                );
            } else {
                window_item.river_window.proposeDimensions(
                    target.width - 2 * border_width,
                    target.height - 2 * border_width,
                );
                window_item.river_node.setPosition(
                    target.x + border_width,
                    target.y + border_width,
                );

                if (window_item.fullscreen) {
                    window_item.river_window.setBorders(.{}, 0, 0, 0, 0, 0);

                    if (workspace_idx == layout.focused_workspace_index and
                        window_idx == workspace_item.focused_window_index)
                        window_item.river_window.fullscreen(layout.output.river_output);
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
