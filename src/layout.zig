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
        for (workspace.window_list.items) |item| {
            item.river_window.proposeDimensions(item.width, item.height);
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

        var x_coordinate = non_exclusive_area.x + @divTrunc(non_exclusive_area.width, 2) - @divTrunc(focused_window.width, 2);
        const y_coordinate = (@as(i32, @intCast(i_workspace)) - @as(i32, @intCast(focused_workspace_index))) * config.config.screen_height + non_exclusive_area.y;

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

        x_coordinate = @divTrunc(config.config.screen_width, 2) + @divTrunc(focused_window.width, 2);
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

var non_exclusive_area: std.meta.TagPayload(river.LayerShellOutputV1.Event, .non_exclusive_area) = undefined;

pub fn layerShellOutputListener(
    layer_shell_output: *river.LayerShellOutputV1,
    event: river.LayerShellOutputV1.Event,
    data: ?*anyopaque,
) void {
    _ = data;
    _ = layer_shell_output;

    switch (event) {
        .non_exclusive_area => |area| {
            for (&workspace_list) |*workspace| {
                for (workspace.window_list.items) |*item| {
                    item.height = area.height;
                }
            }
            non_exclusive_area = area;

            applyLayout();
        },
    }
}
