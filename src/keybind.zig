const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const main = @import("main.zig");
const config = @import("config.zig");
const window = @import("window.zig");

pub const Keybind = struct {
    keysym: u32,
    modifier: river.SeatV1.Modifiers,
    action: Action,
};

pub const Action = union(enum) {
    spawn: []const []const u8,
    focus_window_left: void,
    focus_window_right: void,
    move_window_left: void,
    move_window_right: void,
    focus_workspace: usize,
    reload_config: void,
};

pub fn setupKeybinds(seat: *river.SeatV1) void {
    const xkb_bindings = main.river_xkb_bindings orelse {
        std.debug.print("Failed to find River xkb bindings\n", .{});
        return;
    };
    std.debug.print("Successfully bound to River xkb bindings\n", .{});

    for (config.config.keybinds) |*keybind| {
        const river_xkb_binding: ?*river.XkbBindingV1 = xkb_bindings.getXkbBinding(seat, keybind.keysym, keybind.modifier) catch null;
        const xkb_binding = river_xkb_binding orelse {
            std.debug.print("Failed to get xkb binding\n", .{});
            continue;
        };
        std.debug.print("Successfully got xkb binding\n", .{});

        xkb_binding.setListener(?*anyopaque, keyboardBindingListener, @ptrCast(@constCast(&keybind.action)));
        xkb_binding.enable();
    }
}

fn keyboardBindingListener(
    binding: *river.XkbBindingV1,
    event: river.XkbBindingV1.Event,
    data: ?*anyopaque,
) void {
    _ = binding;
    const action: *Action = @ptrCast(@alignCast(data.?));
    switch (event) {
        .pressed => {
            const window_manager = main.river_window_manager orelse return;
            const focused_workspace = &main.workspace_list[main.focused_workspace_index];

            switch (action.*) {
                .spawn => |command| {
                    var child = std.process.Child.init(command, main.allocator);
                    child.spawn() catch |err| {
                        std.debug.print("Failed to spawn {s}: {}\n", .{ command[0], err });
                    };
                    std.debug.print("Spawned {s}\n", .{command[0]});
                },
                .focus_window_left => {
                    const focused_window_index = focused_workspace.focused_window_index orelse return;
                    if (focused_window_index == 0) return;

                    focused_workspace.focused_window_index = focused_window_index - 1;
                    std.debug.print("Set focus in workspace {} on window {}\n", .{ main.focused_workspace_index + 1, focused_window_index - 1 });

                    window_manager.manageDirty();
                },
                .focus_window_right => {
                    const focused_window_index = focused_workspace.focused_window_index orelse return;
                    if (focused_window_index == focused_workspace.window_list.items.len - 1) return;

                    focused_workspace.focused_window_index = focused_window_index + 1;
                    std.debug.print("Set focus in workspace {} on window {}\n", .{ main.focused_workspace_index + 1, focused_window_index + 1 });

                    window_manager.manageDirty();
                },
                .move_window_left => {
                    const focused_window_index = focused_workspace.focused_window_index orelse return;
                    if (focused_window_index == 0) return;

                    std.mem.swap(window.Window, &focused_workspace.window_list.items[focused_window_index], &focused_workspace.window_list.items[focused_window_index - 1]);
                    std.debug.print("Moved window at workspace {}, window {} to the left\n", .{ main.focused_workspace_index + 1, focused_window_index });

                    focused_workspace.focused_window_index = focused_window_index - 1;
                    std.debug.print("Set focus in workspace {} on window {}\n", .{ main.focused_workspace_index + 1, focused_window_index - 1 });

                    window_manager.manageDirty();
                },
                .move_window_right => {
                    const focused_window_index = focused_workspace.focused_window_index orelse return;
                    if (focused_window_index == focused_workspace.window_list.items.len - 1) return;

                    std.mem.swap(window.Window, &focused_workspace.window_list.items[focused_window_index], &focused_workspace.window_list.items[focused_window_index + 1]);
                    std.debug.print("Moved window at workspace {}, window {} to the right\n", .{ main.focused_workspace_index + 1, focused_window_index });

                    focused_workspace.focused_window_index = focused_window_index + 1;
                    std.debug.print("Set focus in workspace {} on window {}\n", .{ main.focused_workspace_index + 1, focused_window_index + 1 });

                    window_manager.manageDirty();
                },
                .focus_workspace => |number| {
                    main.focused_workspace_index = number - 1;
                    std.debug.print("Set focus on workspace {}\n", .{main.focused_workspace_index + 1});
                    window_manager.manageDirty();
                },
                .reload_config => {
                    config.loadConfig(main.allocator);
                },
            }
        },
        else => {},
    }
}
