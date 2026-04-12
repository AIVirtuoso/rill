const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const layout = @import("layout.zig");
const types = @import("types.zig");

var pending_windows: std.ArrayList(*river.WindowV1) = .empty;

pub fn prepare(wm: *types.WindowManager, window: *river.WindowV1) !void {
    try pending_windows.append(wm.gpa.allocator(), window);
    window.setListener(*types.WindowManager, windowListener, wm);
    window.hide();
    window.proposeDimensions(0, 0);
    window.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
    if (wm.config.no_csd) window.useSsd();
}

fn addWindow(
    river_window: *river.WindowV1,
    output: *types.Output,
    config: types.Config,
    allocator: std.mem.Allocator,
) !void {
    const river_node = try river_window.getNode();

    const gap = config.horizontal_gap;
    const base_width: f32 = @floatFromInt(output.non_exclusive.width - gap);
    const proportion = config.default_window_width;
    const width_with_gap: i32 = @intFromFloat(base_width * proportion);
    const height = output.non_exclusive.height - 2 * config.vertical_gap;

    const window = types.Window{
        .river_window = river_window,
        .river_node = river_node,
        .proportion = proportion,
        .is_fullscreen = false,
        .rectangle = .{
            .width = width_with_gap - gap,
            .height = height,
            .x = output.rectangle.x + output.rectangle.width,
            .y = output.non_exclusive.y + config.vertical_gap,
        },
        .start = null,
        .finish = null,
    };

    const workspace = &output.workspace_list[output.focused_workspace_idx];
    var window_idx: usize = 0;
    if (workspace.focused_window_idx) |idx| window_idx = idx + 1;
    try workspace.window_list.insert(allocator, window_idx, window);
    workspace.focused_window_idx = window_idx;
}

fn windowListener(
    river_window: *river.WindowV1,
    event: river.WindowV1.Event,
    wm: *types.WindowManager,
) void {
    const output_idx = wm.focused_output_idx orelse return;
    const output = &wm.output_list.items[output_idx];

    if (event == .dimensions) {
        for (pending_windows.items, 0..) |window, idx| {
            if (window != river_window) continue;
            addWindow(window, output, wm.config, wm.gpa.allocator()) catch |err| {
                std.debug.print("Failed to add window: {}\n", .{err});
                return;
            };
            _ = pending_windows.swapRemove(idx);
            layout.apply(&wm.output_list, wm.config);
            return;
        }
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
                },
                .fullscreen_requested => {
                    window.is_fullscreen = true;
                    window.river_window.informFullscreen();
                },
                .exit_fullscreen_requested => {
                    window.is_fullscreen = false;
                    window.river_window.informNotFullscreen();
                },
                else => return,
            }
            layout.apply(&wm.output_list, wm.config);
            return;
        }
    }
}
