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

    const non_exclusive = output.non_exclusive orelse output.rectangle;
    const base_width: f32 = @floatFromInt(non_exclusive.width - config.horizontal_gap);

    for (&output.workspace_list, 0..) |*workspace, workspace_idx| {
        const focused_window_idx = workspace.focused_window_idx orelse continue;
        const focused_window = &workspace.window_list.items[focused_window_idx];

        var width_with_gap: i32 = @intFromFloat(base_width * focused_window.proportion);
        const workspace_offset = @as(i32, @intCast(workspace_idx)) -
            @as(i32, @intCast(output.focused_workspace_idx));
        const y_offset = workspace_offset * output.rectangle.height;

        var rectangle = types.Rectangle{
            .width = width_with_gap - config.horizontal_gap,
            .height = non_exclusive.height - 2 * config.vertical_gap,
            .x = focused_window.rectangle.x,
            .y = non_exclusive.y + y_offset + config.vertical_gap,
        };

        const should_center = switch (config.center_focused_window) {
            .never => false,
            .always => true,
            .single => workspace.window_list.items.len == 1,
        };

        if (should_center) {
            rectangle.x = non_exclusive.x +
                @divTrunc(non_exclusive.width, 2) - @divTrunc(rectangle.width, 2);
        } else if (rectangle.x < non_exclusive.x + config.horizontal_gap) {
            rectangle.x = non_exclusive.x + config.horizontal_gap;
        } else if (rectangle.x + width_with_gap > non_exclusive.x + non_exclusive.width) {
            rectangle.x = @max(
                non_exclusive.x + non_exclusive.width - width_with_gap,
                non_exclusive.x + config.horizontal_gap,
            );
        }

        if (focused_window.is_fullscreen) {
            rectangle = output.rectangle;
            rectangle.y += y_offset;
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

        focused_window.target = rectangle;
        rectangle.x += rectangle.width + config.horizontal_gap;

        for (workspace.window_list.items[focused_window_idx + 1 ..]) |*window| {
            if (window.is_fullscreen) {
                rectangle.width = output.rectangle.width;
                rectangle.height = output.rectangle.height;
                rectangle.y = output.rectangle.y + y_offset;
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
                rectangle.width = width_with_gap - config.horizontal_gap;
                rectangle.height = non_exclusive.height - 2 * config.vertical_gap;
                rectangle.y = non_exclusive.y + y_offset + config.vertical_gap;
            }

            window.target = rectangle;
            rectangle.x += rectangle.width + config.horizontal_gap;
        }

        rectangle.x = focused_window.target.?.x;
        var window_idx = focused_window_idx;
        while (window_idx > 0) {
            window_idx -= 1;
            const window = &workspace.window_list.items[window_idx];

            if (window.is_fullscreen) {
                rectangle.width = output.rectangle.width;
                rectangle.height = output.rectangle.height;
                rectangle.y = output.rectangle.y + y_offset;
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
                rectangle.width = width_with_gap - config.horizontal_gap;
                rectangle.height = non_exclusive.height - 2 * config.vertical_gap;
                rectangle.y = non_exclusive.y + y_offset + config.vertical_gap;
            }

            rectangle.x -= config.horizontal_gap + rectangle.width;
            window.target = rectangle;
        }

        if (!should_center) snapToEdge(
            workspace.window_list.items,
            non_exclusive,
            config.horizontal_gap,
        );
    }
    animation.start_time = std.time.milliTimestamp();
}

fn snapToEdge(
    window_list: []types.Window,
    non_exclusive: types.Rectangle,
    gap: i32,
) void {
    var head_distance: ?i32 = null;
    const head = window_list[0].target.?.x;
    const screen_left = non_exclusive.x + gap;
    if (head > screen_left) head_distance = head - screen_left;

    var tail_distance: ?i32 = null;
    const tail_window = window_list[window_list.len - 1];
    const tail = tail_window.target.?.x + tail_window.target.?.width;
    const screen_right = non_exclusive.x + non_exclusive.width - gap;
    if (tail < screen_right)
        tail_distance = @min(screen_right - tail, screen_left - head);

    for (window_list) |*window| {
        const x = &window.target.?.x;
        if (head_distance) |distance| {
            x.* -= distance;
        } else if (tail_distance) |distance| {
            x.* += distance;
        }
    }
}
