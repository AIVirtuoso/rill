const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const animation = @import("animation.zig");
const types = @import("types.zig");

pub fn apply(output: *types.Output, config: types.Config) void {
    const edges = river.WindowV1.Edges{
        .top = true,
        .bottom = true,
        .left = true,
        .right = true,
    };
    const focused_color = config.border.focused_color.toRiverColor();
    const unfocused_color = config.border.unfocused_color.toRiverColor();

    const non_exclusive = output.non_exclusive orelse output.dimensions;

    const horizontal_gap = config.horizontal_gap;
    const base_width: f32 = @floatFromInt(non_exclusive.width - horizontal_gap);

    const vertical_gap = config.vertical_gap;
    var height = non_exclusive.height - 2 * vertical_gap;

    for (&output.workspace_list, 0..) |*workspace, workspace_idx| {
        const focused_window_idx = workspace.focused_window_idx orelse continue;
        const focused_window = &workspace.window_list.items[focused_window_idx];

        var width_with_gap: i32 = @intFromFloat(base_width * focused_window.proportion);
        var width = width_with_gap - horizontal_gap;

        const should_center = switch (config.center_focused_window) {
            .never => false,
            .always => true,
            .single => workspace.window_list.items.len == 1,
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
            @as(i32, @intCast(output.focused_workspace_idx));
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
                config.border.width,
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
        for (workspace.window_list.items[focused_window_idx + 1 ..]) |*window| {
            if (window.fullscreen) {
                width = output.dimensions.width;
                height = output.dimensions.height;
                y = output.dimensions.y + y_offset;
            } else {
                window.river_window.setBorders(
                    edges,
                    config.border.width,
                    unfocused_color.r,
                    unfocused_color.g,
                    unfocused_color.b,
                    unfocused_color.a,
                );

                width_with_gap = @intFromFloat(base_width * window.proportion);
                width = width_with_gap - horizontal_gap;
                height = non_exclusive.height - 2 * vertical_gap;
                y = non_exclusive.y + y_offset + vertical_gap;
            }

            window.target = .{
                .width = width,
                .height = height,
                .x = x,
                .y = y,
            };
            x += width + horizontal_gap;
        }

        x = focused_window.target.?.x;
        var window_idx = focused_window_idx;
        while (window_idx > 0) {
            window_idx -= 1;
            const window = &workspace.window_list.items[window_idx];

            if (window.fullscreen) {
                width = output.dimensions.width;
                height = output.dimensions.height;
                y = output.dimensions.y + y_offset;
            } else {
                window.river_window.setBorders(
                    edges,
                    config.border.width,
                    unfocused_color.r,
                    unfocused_color.g,
                    unfocused_color.b,
                    unfocused_color.a,
                );

                width_with_gap = @intFromFloat(base_width * window.proportion);
                width = width_with_gap - horizontal_gap;
                height = non_exclusive.height - 2 * vertical_gap;
                y = non_exclusive.y + y_offset + vertical_gap;
            }

            x -= horizontal_gap + width;
            window.target = .{
                .width = width,
                .height = height,
                .x = x,
                .y = y,
            };
        }

        if (!should_center) snapToEdge(
            workspace.window_list.items,
            non_exclusive,
            horizontal_gap,
        );
    }
    animation.start_time = std.time.milliTimestamp();
}

fn snapToEdge(
    window_list: []types.Window,
    non_exclusive: types.Dimensions,
    gap: i32,
) void {
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

    for (window_list) |*window| {
        const x = &window.target.?.x;
        if (head_distance) |distance| {
            x.* -= distance;
        } else if (tail_distance) |distance| {
            x.* += distance;
        }
    }
}
