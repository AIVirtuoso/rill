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
) !void {
    const river_node = try river_window.getNode();

    const non_exclusive = output.non_exclusive orelse output.rectangle;
    const gap = config.horizontal_gap;
    const base_width: f32 = @floatFromInt(non_exclusive.width - gap);

    const proportion = config.default_window_width;
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
        .start = null,
        .finish = null,
    };

    const workspace = &output.workspace_list[output.focused_workspace_idx];
    var window_idx: usize = 0;
    if (workspace.focused_window_idx) |idx| window_idx = idx + 1;
    try workspace.window_list.insert(allocator, window_idx, window);

    workspace.focused_window_idx = window_idx;
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
        addWindow(pending.?, output, wm.config, wm.gpa.allocator()) catch |err| {
            std.debug.print("Failed to add window: {}\n", .{err});
            return;
        };
        pending = null;
        return;
    }

    for (&output.workspace_list) |*workspace| {
        const window_idx = workspace.focused_window_idx orelse continue;

        for (workspace.window_list.items, 0..) |*window, idx| {
            if (window.river_window != river_window) continue;

            switch (event) {
                .closed => {
                    _ = workspace.window_list.orderedRemove(idx);
                    river_window.destroy();

                    if (workspace.window_list.items.len == 0) {
                        workspace.focused_window_idx = null;
                    } else if (idx <= window_idx and window_idx != 0) {
                        workspace.focused_window_idx = window_idx - 1;
                    }
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
