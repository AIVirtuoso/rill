const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const animation = @import("animation.zig");
const config = @import("config.zig");
const window = @import("window.zig");

pub const Workspace = struct {
    window_list: std.ArrayList(window.Window),
    focused_window_index: ?usize,
};

pub var workspace_list: [10]Workspace = undefined;
pub var focused_workspace_index: usize = 0;

pub fn applyLayout(seat: *river.SeatV1) void {
    const edges = river.WindowV1.Edges{
        .top = true,
        .bottom = true,
        .left = true,
        .right = true,
    };
    const focused_color = config.config.border.focused_color.toRiverColor();
    const unfocused_color = config.config.border.unfocused_color.toRiverColor();

    focused_window: {
        const workspace = workspace_list[focused_workspace_index];
        const window_index = workspace.focused_window_index orelse
            break :focused_window;
        const focused_window = workspace.window_list.items[window_index];

        seat.focusWindow(focused_window.river_window);

        focused_window.river_node.placeTop();
        focused_window.river_window.setBorders(
            edges,
            config.config.border.width,
            focused_color.r,
            focused_color.g,
            focused_color.b,
            focused_color.a,
        );

        if (focused_window.fullscreen_when_focused)
            focused_window.river_window.fullscreen(output.river_output);
    }

    for (&workspace_list, 0..) |*workspace_item, i_workspace| {
        const focused_window_index = workspace_item.focused_window_index orelse continue;
        const focused_window = &workspace_item.window_list.items[focused_window_index];

        if (i_workspace != focused_workspace_index)
            focused_window.river_window.exitFullscreen();
        if (config.config.no_csd) focused_window.river_window.useSsd();

        const gap = config.config.horizontal_gap;
        const base_width: f32 = @floatFromInt(output.non_exclusive_width - gap);
        var width_with_gap: i32 = @intFromFloat(base_width * focused_window.proportion);

        var x = focused_window.x;
        if (config.config.center_focused_window) {
            x = output.non_exclusive_x +
                @divTrunc(output.non_exclusive_width, 2) - @divTrunc(width_with_gap - gap, 2);
        } else if (focused_window.x - gap < output.non_exclusive_x) {
            x = output.non_exclusive_x + gap;
        } else if (focused_window.x + width_with_gap > output.width) {
            x = @max(output.width - width_with_gap, output.non_exclusive_x + gap);
        }

        const workspace_offset = @as(i32, @intCast(i_workspace)) -
            @as(i32, @intCast(focused_workspace_index));
        const y = workspace_offset * output.height +
            output.non_exclusive_y + config.config.vertical_gap;

        focused_window.animation_info = .{
            .width_start = focused_window.width,
            .x_start = focused_window.x,
            .y_start = focused_window.y,
            .width_finish = width_with_gap - gap,
            .x_finish = x,
            .y_finish = y,
        };

        x += width_with_gap;
        for (workspace_item.window_list.items[focused_window_index + 1 ..]) |*window_item| {
            window_item.river_window.exitFullscreen();
            if (config.config.no_csd) window_item.river_window.useSsd();
            window_item.river_window.setBorders(
                edges,
                config.config.border.width,
                unfocused_color.r,
                unfocused_color.g,
                unfocused_color.b,
                unfocused_color.a,
            );

            width_with_gap = @intFromFloat(base_width * window_item.proportion);
            window_item.animation_info = .{
                .width_start = window_item.width,
                .x_start = window_item.x,
                .y_start = window_item.y,
                .width_finish = width_with_gap - gap,
                .x_finish = x,
                .y_finish = y,
            };

            x += width_with_gap;
        }

        x = focused_window.animation_info.?.x_finish;
        var i_window = focused_window_index;
        while (i_window > 0) {
            i_window -= 1;
            const window_item = &workspace_item.window_list.items[i_window];

            window_item.river_window.exitFullscreen();
            if (config.config.no_csd) window_item.river_window.useSsd();
            window_item.river_window.setBorders(
                edges,
                config.config.border.width,
                unfocused_color.r,
                unfocused_color.g,
                unfocused_color.b,
                unfocused_color.a,
            );

            width_with_gap = @intFromFloat(base_width * window_item.proportion);
            x -= width_with_gap;

            window_item.animation_info = .{
                .width_start = window_item.width,
                .x_start = window_item.x,
                .y_start = window_item.y,
                .width_finish = width_with_gap - gap,
                .x_finish = x,
                .y_finish = y,
            };
        }

        if (!config.config.center_focused_window) snapToEdge(workspace_item);
    }
    animation.start_time = std.time.milliTimestamp();
}

fn snapToEdge(workspace: *Workspace) void {
    const window_list = workspace.window_list.items;

    var front_distance: ?i32 = null;
    const x_front = window_list[0].animation_info.?.x_finish;
    const x_origin = output.non_exclusive_x + config.config.horizontal_gap;
    if (x_front > x_origin) front_distance = x_front - x_origin;

    var tail_distance: ?i32 = null;
    const window_tail = window_list[window_list.len - 1];
    const x_tail = window_tail.animation_info.?.x_finish;
    const x_end = output.width - config.config.horizontal_gap;
    const width = window_tail.animation_info.?.width_finish;
    if (x_tail + width < x_end)
        tail_distance = @min(x_end - x_tail - width, x_origin - x_front);

    for (window_list) |*item| {
        const x_finish = &item.animation_info.?.x_finish;
        if (front_distance) |distance| {
            x_finish.* -= distance;
        } else if (tail_distance) |distance| {
            x_finish.* += distance;
        }
    }
}

const Output = struct {
    river_output: *river.OutputV1,
    width: i32,
    height: i32,
    non_exclusive_width: i32,
    non_exclusive_height: i32,
    non_exclusive_x: i32,
    non_exclusive_y: i32,
};
pub var output: Output = undefined;

pub fn outputListener(
    river_output: *river.OutputV1,
    event: river.OutputV1.Event,
    _: ?*anyopaque,
) void {
    switch (event) {
        .dimensions => |dimensions| {
            output = .{
                .river_output = river_output,
                .width = dimensions.width,
                .height = dimensions.height,
                .non_exclusive_width = dimensions.width,
                .non_exclusive_height = dimensions.height,
                .non_exclusive_x = 0,
                .non_exclusive_y = 0,
            };
        },
        else => {},
    }
}

pub fn layerShellOutputListener(
    _: *river.LayerShellOutputV1,
    event: river.LayerShellOutputV1.Event,
    seat: *river.SeatV1,
) void {
    switch (event) {
        .non_exclusive_area => |non_exclusive_area| {
            output.non_exclusive_width = non_exclusive_area.width;
            output.non_exclusive_height = non_exclusive_area.height;
            output.non_exclusive_x = non_exclusive_area.x;
            output.non_exclusive_y = non_exclusive_area.y;
            applyLayout(seat);
        },
    }
}
