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

        if (focused_window.fullscreen_when_focused)
            focused_window.river_window.fullscreen(output.river_output);
    }

    for (&workspace_list, 0..) |*workspace_item, i_workspace| {
        const focused_window_index = workspace_item.focused_window_index orelse continue;
        const focused_window = &workspace_item.window_list.items[focused_window_index];

        if (i_workspace != focused_workspace_index)
            focused_window.river_window.exitFullscreen();

        var width = focused_window.animation_info.width_finish orelse focused_window.width;
        var x_finish = output.non_exclusive_x +
            @divTrunc(output.non_exclusive_width, 2) - @divTrunc(width, 2);

        const workspace_distance = @as(i32, @intCast(i_workspace)) -
            @as(i32, @intCast(focused_workspace_index));
        const y_finish = workspace_distance * output.height +
            output.non_exclusive_y + config.config.outer_gap;

        focused_window.animation_info.x_start = focused_window.x;
        focused_window.animation_info.x_finish = x_finish;
        focused_window.animation_info.y_start = focused_window.y;
        focused_window.animation_info.y_finish = y_finish;

        var i_window = focused_window_index;
        while (i_window > 0) {
            i_window -= 1;
            const window_item = &workspace_item.window_list.items[i_window];

            window_item.river_window.exitFullscreen();

            width = window_item.animation_info.width_finish orelse window_item.width;
            x_finish -= config.config.inner_gap;
            x_finish -= width;

            window_item.animation_info.x_start = window_item.x;
            window_item.animation_info.x_finish = x_finish;
            window_item.animation_info.y_start = window_item.y;
            window_item.animation_info.y_finish = y_finish;
        }

        width = focused_window.animation_info.width_finish orelse focused_window.width;
        x_finish = output.non_exclusive_x +
            @divTrunc(output.non_exclusive_width, 2) + @divTrunc(width, 2) +
            config.config.inner_gap;

        for (workspace_item.window_list.items[focused_window_index + 1 ..]) |*window_item| {
            window_item.river_window.exitFullscreen();

            window_item.animation_info.x_start = window_item.x;
            window_item.animation_info.x_finish = x_finish;
            window_item.animation_info.y_start = window_item.y;
            window_item.animation_info.y_finish = y_finish;

            width = window_item.animation_info.width_finish orelse window_item.width;
            x_finish += width;
            x_finish += config.config.inner_gap;
        }

        animation.animation_start_time = std.time.milliTimestamp();
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
