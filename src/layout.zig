const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const main = @import("main.zig");
const config = @import("config.zig");
const window = @import("window.zig");

pub const Workspace = struct {
    window_list: std.ArrayList(window.Window),
    focused_window_index: ?usize,
};

pub var workspace_list: [10]Workspace = undefined;
pub var focused_workspace_index: usize = 0;

const AnimationNode = struct {
    river_node: *river.NodeV1,
    x: *i32,
    y: *i32,
    x_start: i32,
    y_start: i32,
    x_finish: i32,
    y_finish: i32,
};
var animation_node_list = std.ArrayList(AnimationNode){};
pub var animation_progress: ?usize = null;

pub fn applyLayout() void {
    for (workspace_list) |workspace| {
        const height = output.non_exclusive_height - 2 * config.config.outer_gap;
        for (workspace.window_list.items) |item| {
            item.river_window.proposeDimensions(item.width, height);
        }
    }

    seat: {
        const focused_window_index = workspace_list[focused_workspace_index].focused_window_index orelse {
            break :seat;
        };
        const seat = main.river_seat orelse {
            std.debug.print("Failed to find a seat\n", .{});
            break :seat;
        };

        seat.focusWindow(workspace_list[focused_workspace_index].window_list.items[focused_window_index].river_window);
        std.debug.print("Set focus of seat at workspace {}, window {}\n", .{
            focused_workspace_index + 1,
            focused_window_index,
        });
    }

    animation_node_list.clearRetainingCapacity();

    for (&workspace_list, 0..) |*workspace, i_workspace| {
        const focused_window_index = workspace.focused_window_index orelse continue;
        const focused_window = &workspace.window_list.items[focused_window_index];

        var x_coordinate = output.non_exclusive_x +
            @divTrunc(output.non_exclusive_width, 2) -
            @divTrunc(focused_window.width, 2);
        const y_coordinate = output.height *
            (@as(i32, @intCast(i_workspace)) -
                @as(i32, @intCast(focused_workspace_index))) +
            output.non_exclusive_y +
            config.config.outer_gap;

        animation_node_list.append(main.allocator, .{
            .river_node = focused_window.river_node,
            .x = &focused_window.x,
            .y = &focused_window.y,
            .x_start = focused_window.x,
            .y_start = focused_window.y,
            .x_finish = x_coordinate,
            .y_finish = y_coordinate,
        }) catch |err| {
            std.debug.print("Failed to add animation node: {}\n", .{err});
            return;
        };

        var i_window: usize = focused_window_index;
        while (i_window > 0) {
            i_window -= 1;
            const item = &workspace.window_list.items[i_window];

            x_coordinate -= config.config.inner_gap;
            x_coordinate -= item.width;

            animation_node_list.append(main.allocator, .{
                .river_node = item.river_node,
                .x = &item.x,
                .y = &item.y,
                .x_start = item.x,
                .y_start = item.y,
                .x_finish = x_coordinate,
                .y_finish = y_coordinate,
            }) catch |err| {
                std.debug.print("Failed to add animation node: {}\n", .{err});
                return;
            };
        }

        x_coordinate = output.non_exclusive_x +
            @divTrunc(output.non_exclusive_width, 2) +
            @divTrunc(focused_window.width, 2) +
            config.config.inner_gap;

        for (workspace.window_list.items[focused_window_index + 1 ..]) |*item| {
            animation_node_list.append(main.allocator, .{
                .river_node = item.river_node,
                .x = &item.x,
                .y = &item.y,
                .x_start = item.x,
                .y_start = item.y,
                .x_finish = x_coordinate,
                .y_finish = y_coordinate,
            }) catch |err| {
                std.debug.print("Failed to add animation node: {}\n", .{err});
                return;
            };

            x_coordinate += item.width;
            x_coordinate += config.config.inner_gap;
        }

        animation_progress = 0;
    }
}

pub fn animate() void {
    const progress = animation_progress orelse return;

    const steps = 50;
    for (animation_node_list.items) |*item| {
        const x_step: i32 = @divTrunc((item.x_finish - item.x_start), steps);
        const y_step: i32 = @divTrunc((item.y_finish - item.y_start), steps);

        if (progress < steps - 1) {
            item.x.* += x_step;
            item.y.* += y_step;
            animation_progress = progress + 1;

            std.Thread.sleep(1 * std.time.ns_per_ms);
        } else if (progress == steps - 1) {
            item.x.* = item.x_finish;
            item.y.* = item.y_finish;
            animation_progress = null;
        }
    }
}

const Output = struct {
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
            output = .{
                .width = dimensions.width,
                .height = dimensions.height,
                .non_exclusive_width = dimensions.width,
                .non_exclusive_height = dimensions.height,
                .non_exclusive_x = 0,
                .non_exclusive_y = 0,
            };
            std.debug.print("Output dimension: {}x{}\n", .{ output.width, output.height });
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
