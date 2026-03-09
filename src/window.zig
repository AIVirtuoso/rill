const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const layout = @import("layout.zig");
const types = @import("types.zig");

pub var pending: ?*river.WindowV1 = null;

fn addWindow(
    river_window: *river.WindowV1,
    output: *types.Output,
    config: types.Config,
    allocator: std.mem.Allocator,
) void {
    const river_node = river_window.getNode() catch |err| {
        std.debug.print("Failed to get window's node: {}\n", .{err});
        return;
    };

    const non_exclusive = output.non_exclusive orelse output.rectangle;
    const gap = config.horizontal_gap;
    const base_width: f32 = @floatFromInt(non_exclusive.width - gap);

    const proportion = config.window_width_proportion;
    const width_with_gap: i32 = @intFromFloat(base_width * proportion);
    const height = non_exclusive.height - 2 * config.vertical_gap;

    const window = types.Window{
        .river_window = river_window,
        .river_node = river_node,
        .proportion = proportion,
        .is_fullscreen = false,
        .rectangle = .{
            .width = width_with_gap - gap,
            .height = height,
            .x = output.rectangle.x + output.rectangle.width,
            .y = non_exclusive.y + config.vertical_gap,
        },
        .target = null,
    };

    const workspace = &output.workspace_list[output.focused_workspace_idx];
    var target_idx: usize = 0;
    if (workspace.focused_window_idx) |idx| target_idx = idx + 1;

    workspace.window_list.insert(allocator, target_idx, window) catch |err| {
        std.debug.print("Failed to add window: {}\n", .{err});
        return;
    };
    workspace.focused_window_idx = target_idx;

    layout.apply(output, config);
}

pub fn windowListener(
    river_window: *river.WindowV1,
    event: river.WindowV1.Event,
    wm: *types.WindowManager,
) void {
    const output_idx = wm.focused_output_idx orelse return;
    const output = &wm.output_list.items[output_idx];

    if (event == .dimensions and river_window == pending) {
        addWindow(pending.?, output, wm.config, wm.gpa.allocator());
        pending = null;
        return;
    }

    for (&output.workspace_list) |*workspace| {
        const focused_window_idx = workspace.focused_window_idx orelse continue;

        for (workspace.window_list.items, 0..) |*window, idx| {
            if (window.river_window != river_window) continue;

            switch (event) {
                .closed => {
                    if (workspace.window_list.items.len == 1) {
                        workspace.focused_window_idx = null;
                    } else if (idx <= focused_window_idx and focused_window_idx != 0) {
                        workspace.focused_window_idx = focused_window_idx - 1;
                    }

                    _ = workspace.window_list.orderedRemove(idx);
                    river_window.destroy();
                    layout.apply(output, wm.config);
                },
                .fullscreen_requested => {
                    window.is_fullscreen = true;
                    layout.apply(output, wm.config);
                },
                .exit_fullscreen_requested => {
                    window.is_fullscreen = false;
                    layout.apply(output, wm.config);
                },
                else => {},
            }
            return;
        }
    }
}
