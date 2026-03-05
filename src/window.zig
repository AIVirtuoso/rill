const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const animation = @import("animation.zig");
const config = @import("config.zig");
const layout = @import("layout.zig");

pub const Window = struct {
    river_window: *river.WindowV1,
    river_node: *river.NodeV1,
    proportion: f32,
    fullscreen: bool,
    width: i32,
    height: i32,
    x: i32,
    y: i32,
    target: ?layout.Dimensions,
};

pub var pending: ?*river.WindowV1 = null;

fn addWindow(allocator: std.mem.Allocator, river_window: *river.WindowV1) void {
    const river_node = river_window.getNode() catch |err| {
        std.debug.print("Failed to get window's node: {}\n", .{err});
        return;
    };

    const output = &layout.output_list.items[layout.focused_output_index];
    const non_exclusive = output.non_exclusive orelse output.dimensions;
    const gap = config.config.horizontal_gap;
    const base_width: f32 = @floatFromInt(non_exclusive.width - gap);

    const proportion = config.config.window_width_proportion;
    const width_with_gap: i32 = @intFromFloat(base_width * proportion);
    const height = non_exclusive.height - 2 * config.config.vertical_gap;

    const window = Window{
        .river_window = river_window,
        .river_node = river_node,
        .proportion = proportion,
        .fullscreen = false,
        .width = width_with_gap - gap,
        .height = height,
        .x = output.dimensions.x + output.dimensions.width,
        .y = non_exclusive.y + config.config.vertical_gap,
        .target = null,
    };

    const workspace = &output.workspace_list[output.focused_workspace_index];
    var window_index: usize = 0;
    if (workspace.focused_window_index) |index| window_index = index + 1;

    workspace.window_list.insert(allocator, window_index, window) catch |err| {
        std.debug.print("Failed to add window: {}\n", .{err});
        return;
    };
    workspace.focused_window_index = window_index;

    layout.apply();
}

pub fn windowListener(
    river_window: *river.WindowV1,
    event: river.WindowV1.Event,
    allocator: *std.mem.Allocator,
) void {
    if (event == .dimensions and river_window == pending) {
        addWindow(allocator.*, pending.?);
        pending = null;
        return;
    }

    const output = &layout.output_list.items[layout.focused_output_index];
    for (&output.workspace_list) |*workspace_item| {
        const focused_window_index = workspace_item.focused_window_index orelse continue;

        for (workspace_item.window_list.items, 0..) |*window_item, idx| {
            if (window_item.river_window != river_window) continue;

            switch (event) {
                .closed => {
                    if (workspace_item.window_list.items.len == 1) {
                        workspace_item.focused_window_index = null;
                    } else if (idx <= focused_window_index and focused_window_index != 0) {
                        workspace_item.focused_window_index = focused_window_index - 1;
                    }

                    _ = workspace_item.window_list.orderedRemove(idx);
                    river_window.destroy();
                    layout.apply();
                },
                .fullscreen_requested => {
                    window_item.fullscreen = true;
                    layout.apply();
                },
                .exit_fullscreen_requested => {
                    window_item.fullscreen = false;
                    layout.apply();
                },
                else => {},
            }
            return;
        }
    }
}
