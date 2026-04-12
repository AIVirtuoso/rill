const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const animation = @import("animation.zig");
const types = @import("types.zig");

const edges = river.WindowV1.Edges{
    .top = true,
    .bottom = true,
    .left = true,
    .right = true,
};

pub fn apply(output_list: *std.ArrayList(types.Output), config: types.Config) void {
    for (output_list.items) |*output| {
        for (&output.workspace_list, 0..) |*workspace, workspace_idx| {
            const focused_window_idx = workspace.focused_window_idx orelse continue;
            const focused_window = &workspace.window_list.items[focused_window_idx];
            var rectangle: types.Rectangle = undefined;

            const should_center = switch (config.center_focused_window) {
                .never => false,
                .always => true,
                .single => workspace.window_list.items.len == 1,
            };

            const workspace_offset = @as(i32, @intCast(workspace_idx)) -
                @as(i32, @intCast(output.focused_workspace_idx));
            const y_offset = workspace_offset * output.rectangle.height;

            focused_window_layout(
                focused_window,
                &rectangle,
                output,
                config,
                should_center,
                y_offset,
            );
            focused_window.finish = rectangle;

            rectangle.x += rectangle.width + config.horizontal_gap;
            for (workspace.window_list.items[focused_window_idx + 1 ..]) |*window| {
                unfocused_window_layout(window, &rectangle, output, config, y_offset);
                window.finish = rectangle;
                rectangle.x += rectangle.width + config.horizontal_gap;
            }

            rectangle.x = focused_window.finish.?.x;
            var window_idx = focused_window_idx;
            while (window_idx > 0) {
                window_idx -= 1;
                const window = &workspace.window_list.items[window_idx];
                unfocused_window_layout(window, &rectangle, output, config, y_offset);
                rectangle.x -= config.horizontal_gap + rectangle.width;
                window.finish = rectangle;
            }

            if (!should_center) snapToEdge(
                workspace.window_list.items,
                output.non_exclusive,
                config.horizontal_gap,
            );
        }
    }
    animation.begin_time = std.time.milliTimestamp();
}

fn focused_window_layout(
    window: *types.Window,
    rectangle: *types.Rectangle,
    output: *types.Output,
    config: types.Config,
    should_center: bool,
    y_offset: i32,
) void {
    const non_exclusive = output.non_exclusive;
    const base_width: f32 = @floatFromInt(non_exclusive.width - config.horizontal_gap);
    const width_with_gap: i32 = @intFromFloat(base_width * window.proportion);

    rectangle.* = .{
        .width = width_with_gap - config.horizontal_gap,
        .height = non_exclusive.height - 2 * config.vertical_gap,
        .x = window.rectangle.x,
        .y = non_exclusive.y + y_offset + config.vertical_gap,
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

    if (window.is_fullscreen) {
        rectangle.* = output.rectangle;
        rectangle.y += y_offset;
    } else {
        const focused_color = config.border.focused_color.toRiverColor();
        window.river_window.setBorders(
            edges,
            config.border.width,
            focused_color.r,
            focused_color.g,
            focused_color.b,
            focused_color.a,
        );
    }

    window.river_node.placeTop();
    window.start = window.rectangle;
}

fn unfocused_window_layout(
    window: *types.Window,
    rectangle: *types.Rectangle,
    output: *types.Output,
    config: types.Config,
    y_offset: i32,
) void {
    if (window.is_fullscreen) {
        rectangle.width = output.rectangle.width;
        rectangle.height = output.rectangle.height;
        rectangle.y = output.rectangle.y + y_offset;
    } else {
        const unfocused_color = config.border.unfocused_color.toRiverColor();
        window.river_window.setBorders(
            edges,
            config.border.width,
            unfocused_color.r,
            unfocused_color.g,
            unfocused_color.b,
            unfocused_color.a,
        );

        const non_exclusive = output.non_exclusive;
        const base_width: f32 = @floatFromInt(non_exclusive.width - config.horizontal_gap);
        const width_with_gap: i32 = @intFromFloat(base_width * window.proportion);

        rectangle.width = width_with_gap - config.horizontal_gap;
        rectangle.height = non_exclusive.height - 2 * config.vertical_gap;
        rectangle.y = non_exclusive.y + y_offset + config.vertical_gap;
    }
    window.start = window.rectangle;
}

fn snapToEdge(
    window_list: []types.Window,
    non_exclusive: types.Rectangle,
    gap: i32,
) void {
    var head_distance: ?i32 = null;
    const head = window_list[0].finish.?.x;
    const left = non_exclusive.x + gap;
    if (head > left) head_distance = head - left;

    var tail_distance: ?i32 = null;
    const tail_window = window_list[window_list.len - 1];
    const tail = tail_window.finish.?.x + tail_window.finish.?.width;
    const right = non_exclusive.x + non_exclusive.width - gap;
    if (tail < right) tail_distance = @min(right - tail, left - head);

    for (window_list) |*window| {
        const x = &window.finish.?.x;
        if (head_distance) |distance| {
            x.* -= distance;
        } else if (tail_distance) |distance| {
            x.* += distance;
        }
    }
}
