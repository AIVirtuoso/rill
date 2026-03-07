const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const animation = @import("animation.zig");
const config = @import("config.zig");
const types = @import("types.zig");

pub var output_list = std.ArrayList(types.Output){};
pub var focused_output_index: usize = 0;

pub fn apply() void {
    const edges = river.WindowV1.Edges{
        .top = true,
        .bottom = true,
        .left = true,
        .right = true,
    };
    const focused_color = config.config.border.focused_color.toRiverColor();
    const unfocused_color = config.config.border.unfocused_color.toRiverColor();

    const output = &output_list.items[focused_output_index];
    const non_exclusive = output.non_exclusive orelse output.dimensions;

    const horizontal_gap = config.config.horizontal_gap;
    const base_width: f32 = @floatFromInt(non_exclusive.width - horizontal_gap);

    const vertical_gap = config.config.vertical_gap;
    var height = non_exclusive.height - 2 * vertical_gap;

    for (&output.workspace_list, 0..) |*workspace_item, workspace_idx| {
        const focused_window_index = workspace_item.focused_window_index orelse continue;
        const focused_window = &workspace_item.window_list.items[focused_window_index];

        var width_with_gap: i32 = @intFromFloat(base_width * focused_window.proportion);
        var width = width_with_gap - horizontal_gap;

        const should_center = switch (config.config.center_focused_window) {
            .never => false,
            .always => true,
            .single => workspace_item.window_list.items.len == 1,
        };

        var x = focused_window.x;
        if (should_center) {
            x = non_exclusive.x + @divTrunc(non_exclusive.width, 2) - @divTrunc(width, 2);
        } else if (focused_window.x < non_exclusive.x + horizontal_gap) {
            x = non_exclusive.x + horizontal_gap;
        } else if (focused_window.x + width_with_gap > non_exclusive.x + non_exclusive.width) {
            x = @max(
                non_exclusive.x + non_exclusive.width - width_with_gap,
                non_exclusive.x + horizontal_gap,
            );
        }

        const workspace_offset = @as(i32, @intCast(workspace_idx)) -
            @as(i32, @intCast(output.focused_workspace_index));
        const y_offset = workspace_offset * output.dimensions.height;
        var y = non_exclusive.y + y_offset + vertical_gap;

        if (focused_window.fullscreen) {
            width = output.dimensions.width;
            height = output.dimensions.height;
            x = output.dimensions.x;
            y = output.dimensions.y + y_offset;
        } else {
            focused_window.river_window.setBorders(
                edges,
                config.config.border.width,
                focused_color.r,
                focused_color.g,
                focused_color.b,
                focused_color.a,
            );
        }

        focused_window.target = .{
            .width = width,
            .height = height,
            .x = x,
            .y = y,
        };

        x += width + horizontal_gap;
        for (workspace_item.window_list.items[focused_window_index + 1 ..]) |*window_item| {
            if (window_item.fullscreen) {
                width = output.dimensions.width;
                height = output.dimensions.height;
                y = output.dimensions.y + y_offset;
            } else {
                window_item.river_window.setBorders(
                    edges,
                    config.config.border.width,
                    unfocused_color.r,
                    unfocused_color.g,
                    unfocused_color.b,
                    unfocused_color.a,
                );

                width_with_gap = @intFromFloat(base_width * window_item.proportion);
                width = width_with_gap - horizontal_gap;
                height = non_exclusive.height - 2 * vertical_gap;
                y = non_exclusive.y + y_offset + vertical_gap;
            }

            window_item.target = .{
                .width = width,
                .height = height,
                .x = x,
                .y = y,
            };
            x += width + horizontal_gap;
        }

        x = focused_window.target.?.x;
        var window_idx = focused_window_index;
        while (window_idx > 0) {
            window_idx -= 1;
            const window_item = &workspace_item.window_list.items[window_idx];

            if (window_item.fullscreen) {
                width = output.dimensions.width;
                height = output.dimensions.height;
                y = output.dimensions.y + y_offset;
            } else {
                window_item.river_window.setBorders(
                    edges,
                    config.config.border.width,
                    unfocused_color.r,
                    unfocused_color.g,
                    unfocused_color.b,
                    unfocused_color.a,
                );

                width_with_gap = @intFromFloat(base_width * window_item.proportion);
                width = width_with_gap - horizontal_gap;
                height = non_exclusive.height - 2 * vertical_gap;
                y = non_exclusive.y + y_offset + vertical_gap;
            }

            x -= horizontal_gap + width;
            window_item.target = .{
                .width = width,
                .height = height,
                .x = x,
                .y = y,
            };
        }

        if (!should_center) snapToEdge(workspace_item.window_list.items, non_exclusive);
    }
    animation.start_time = std.time.milliTimestamp();
}

fn snapToEdge(window_list: []types.Window, non_exclusive: types.Dimensions) void {
    const gap = config.config.horizontal_gap;

    var head_distance: ?i32 = null;
    const head = window_list[0].target.?.x;
    const left_edge = non_exclusive.x + gap;
    if (head > left_edge) head_distance = head - left_edge;

    var tail_distance: ?i32 = null;
    const tail_window = window_list[window_list.len - 1];
    const tail = tail_window.target.?.x + tail_window.target.?.width;
    const right_edge = non_exclusive.x + non_exclusive.width - gap;
    if (tail < right_edge)
        tail_distance = @min(right_edge - tail, left_edge - head);

    for (window_list) |*item| {
        const x = &item.target.?.x;
        if (head_distance) |distance| {
            x.* -= distance;
        } else if (tail_distance) |distance| {
            x.* += distance;
        }
    }
}
