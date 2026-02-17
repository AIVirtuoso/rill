const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const main = @import("main.zig");
const config = @import("config.zig");
const layout = @import("layout.zig");

pub const Window = struct {
    river_window: *river.WindowV1,
    river_node: *river.NodeV1,
    width: i32,
    x: i32,
    y: i32,
};

pub fn addWindow(allocator: std.mem.Allocator, window: *river.WindowV1) void {
    const node = window.getNode() catch |err| {
        std.debug.print("Failed to get window's node: {}\n", .{err});
        return;
    };

    const width = @as(f32, @floatFromInt(layout.output.non_exclusive_width)) * config.config.window_width_proportion;

    const focused_workspace = &layout.workspace_list[layout.focused_workspace_index];
    var window_index: usize = 0;
    if (focused_workspace.focused_window_index) |focused_window_index| {
        window_index = focused_window_index + 1;
    }

    focused_workspace.window_list.insert(allocator, window_index, .{
        .river_window = window,
        .river_node = node,
        .width = @intFromFloat(width),
        .x = layout.output.width,
        .y = 0,
    }) catch |err| {
        std.debug.print("Failed to add window: {}\n", .{err});
        return;
    };
    std.debug.print("Added a window at index {}\n", .{window_index});

    focused_workspace.focused_window_index = window_index;
    std.debug.print("Set focus on window {}\n", .{window_index});

    window.setListener(?*anyopaque, windowListener, null);

    layout.applyLayout();
}

fn windowListener(
    river_window: *river.WindowV1,
    event: river.WindowV1.Event,
    data: ?*anyopaque,
) void {
    _ = data;
    switch (event) {
        .closed => {
            for (&layout.workspace_list, 0..) |*workspace, i_workspace| {
                const focused_window_index = workspace.focused_window_index orelse continue;
                for (workspace.window_list.items, 0..) |item, i_window| {
                    if (item.river_window == river_window) {
                        std.debug.print("Window at workspace {}, window {} is closed\n", .{ i_workspace + 1, i_window });

                        if (i_window == workspace.focused_window_index) {
                            if (workspace.window_list.items.len == 1) {
                                workspace.focused_window_index = null;
                                std.debug.print("Workspace {} becomes empty\n", .{i_workspace + 1});
                            } else if (i_window != 0) {
                                workspace.focused_window_index = focused_window_index - 1;
                                std.debug.print("Set focus in workspace {} on window {}\n", .{ i_workspace + 1, focused_window_index - 1 });
                            }
                        }

                        _ = workspace.window_list.orderedRemove(i_window);
                        river_window.destroy();

                        layout.applyLayout();
                        return;
                    }
                }
            }
        },
        else => {},
    }
}
