const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const animation = @import("animation.zig");
const config = @import("config.zig");
const main = @import("main.zig");
const window = @import("window.zig");

pub const Workspace = struct {
    window_list: std.ArrayList(window.Window),
    focused_window_index: ?usize,
};

pub var workspace_list: [10]Workspace = undefined;
pub var focused_workspace_index: usize = 0;

pub fn applyLayout() void {
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

        const seat = main.river_seat orelse {
            std.debug.print("Failed to find a seat\n", .{});
            break :focused_window;
        };
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

        var x_focused = focused_window.x;
        var width = focused_window.animation_info.width_finish orelse focused_window.width;
        const gap = config.config.horizontal_gap;
        if (config.config.center_focused_window) {
            x_focused = output.non_exclusive_x +
                @divTrunc(output.non_exclusive_width, 2) - @divTrunc(width, 2);
        } else if (focused_window.x - gap < output.non_exclusive_x) {
            x_focused = output.non_exclusive_x + gap;
        } else if (focused_window.x + width + gap > output.width) {
            x_focused = @max(output.width - gap - width, output.non_exclusive_x + gap);
        }

        var x = x_focused;
        const workspace_offset = @as(i32, @intCast(i_workspace)) -
            @as(i32, @intCast(focused_workspace_index));
        const y = workspace_offset * output.height +
            output.non_exclusive_y + config.config.vertical_gap;

        focused_window.animation_info.x_start = focused_window.x;
        focused_window.animation_info.x_finish = x;
        focused_window.animation_info.y_start = focused_window.y;
        focused_window.animation_info.y_finish = y;

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

            width = window_item.animation_info.width_finish orelse window_item.width;
            x -= gap + width;

            window_item.animation_info.x_start = window_item.x;
            window_item.animation_info.x_finish = x;
            window_item.animation_info.y_start = window_item.y;
            window_item.animation_info.y_finish = y;
        }

        width = focused_window.animation_info.width_finish orelse focused_window.width;
        x = x_focused + width + gap;

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

            window_item.animation_info.x_start = window_item.x;
            window_item.animation_info.x_finish = x;
            window_item.animation_info.y_start = window_item.y;
            window_item.animation_info.y_finish = y;

            width = window_item.animation_info.width_finish orelse window_item.width;
            x += width + gap;
        }
        if (!config.config.center_focused_window) snapToEdge(workspace_item);
    }
    animation.animation_start_time = std.time.milliTimestamp();
}

fn snapToEdge(workspace: *Workspace) void {
    const window_list = workspace.window_list.items;

    var front_distance: ?i32 = null;
    const x_front = window_list[0].animation_info.x_finish orelse return;
    const x_origin = output.non_exclusive_x + config.config.horizontal_gap;
    if (x_front > x_origin) front_distance = x_front - x_origin;

    var tail_distance: ?i32 = null;
    const window_tail = window_list[window_list.len - 1];
    const x_tail = window_tail.animation_info.x_finish orelse return;
    const x_end = output.width - config.config.horizontal_gap;
    const width = window_tail.animation_info.width_finish orelse window_tail.width;
    if (x_tail + width < x_end)
        tail_distance = @min(x_end - x_tail - width, x_origin - x_front);

    for (window_list) |*item| {
        const x_finish = item.animation_info.x_finish orelse continue;
        if (front_distance) |distance| {
            item.animation_info.x_finish = x_finish - distance;
        } else if (tail_distance) |distance| {
            item.animation_info.x_finish = x_finish + distance;
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
    data: ?*anyopaque,
) void {
    _ = river_output;
    _ = data;

    switch (event) {
        .dimensions => |dimensions| {
            output.width = dimensions.width;
            output.height = dimensions.height;
            output.non_exclusive_width = dimensions.width;
            output.non_exclusive_height = dimensions.height;
            output.non_exclusive_x = 0;
            output.non_exclusive_y = 0;
        },
        else => {},
    }
}

pub fn layerShellOutputListener(
    layer_shell_output: *river.LayerShellOutputV1,
    event: river.LayerShellOutputV1.Event,
    data: ?*anyopaque,
) void {
    _ = layer_shell_output;
    _ = data;

    switch (event) {
        .non_exclusive_area => |non_exclusive_area| {
            output.non_exclusive_width = non_exclusive_area.width;
            output.non_exclusive_height = non_exclusive_area.height;
            output.non_exclusive_x = non_exclusive_area.x;
            output.non_exclusive_y = non_exclusive_area.y;

            applyLayout();
        },
    }
}
