const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const main = @import("main.zig");
const config = @import("config.zig");
const window = @import("window.zig");
const layout = @import("layout.zig");

pub const Keybind = struct {
    key: []const u8,
    modifier: river.SeatV1.Modifiers,
    action: Action,
};

pub const Action = union(enum) {
    spawn: []const []const u8,
    focus_window_left: void,
    focus_window_right: void,
    move_window_left: void,
    move_window_right: void,
    adjust_window_width: i32,
    focus_workspace: usize,
    reload_config: void,
};

pub fn setupKeybinds(seat: *river.SeatV1, xkb_bindings: *river.XkbBindingsV1) void {
    for (config.config.keybinds) |*keybind| {
        const keysym = parseKey(keybind.key) orelse continue;

        const xkb_binding = xkb_bindings.getXkbBinding(
            seat,
            keysym,
            keybind.modifier,
        ) catch |err| {
            std.debug.print("Failed to get xkb binding for ", .{});
            switch (keybind.action) {
                .spawn => |command| {
                    std.debug.print("{s}", .{command[0]});
                },
                .focus_workspace => |number| {
                    std.debug.print("focus_workspace {}", .{number});
                },
                else => |tag| {
                    std.debug.print("{s}", .{@tagName(tag)});
                },
            }
            std.debug.print(": {}\n", .{err});
            continue;
        };

        std.debug.print("Successfully got xkb binding for ", .{});
        switch (keybind.action) {
            .spawn => |command| {
                std.debug.print("{s}\n", .{command[0]});
            },
            .focus_workspace => |number| {
                std.debug.print("focus_workspace {}\n", .{number});
            },
            else => |tag| {
                std.debug.print("{s}\n", .{@tagName(tag)});
            },
        }

        xkb_binding.setListener(
            ?*anyopaque,
            xkbBindingListener,
            @ptrCast(@constCast(&keybind.action)),
        );
        xkb_binding.enable();
    }
}

fn xkbBindingListener(
    xkb_binding: *river.XkbBindingV1,
    event: river.XkbBindingV1.Event,
    data: ?*anyopaque,
) void {
    _ = xkb_binding;
    const action: *Action = @ptrCast(@alignCast(data.?));
    switch (event) {
        .pressed => {
            const focused_workspace = &layout.workspace_list[layout.focused_workspace_index];

            switch (action.*) {
                .spawn => |command| {
                    var child = std.process.Child.init(command, main.allocator);
                    child.spawn() catch |err| {
                        std.debug.print("Failed to spawn {s}: {}\n", .{ command[0], err });
                    };
                    std.debug.print("Spawned {s}\n", .{command[0]});
                },
                .focus_window_left => {
                    const focused_window_index =
                        focused_workspace.focused_window_index orelse return;
                    if (focused_window_index == 0) return;

                    focused_workspace.focused_window_index = focused_window_index - 1;
                    std.debug.print("Set focus on window {}\n", .{focused_window_index - 1});

                    layout.applyLayout();
                },
                .focus_window_right => {
                    const focused_window_index =
                        focused_workspace.focused_window_index orelse return;
                    if (focused_window_index == focused_workspace.window_list.items.len - 1) return;

                    focused_workspace.focused_window_index = focused_window_index + 1;
                    std.debug.print("Set focus on window {}\n", .{focused_window_index + 1});

                    layout.applyLayout();
                },
                .move_window_left => {
                    const focused_window_index =
                        focused_workspace.focused_window_index orelse return;
                    if (focused_window_index == 0) return;

                    std.mem.swap(
                        window.Window,
                        &focused_workspace.window_list.items[focused_window_index],
                        &focused_workspace.window_list.items[focused_window_index - 1],
                    );
                    std.debug.print("Moved window {} to the left\n", .{focused_window_index});

                    focused_workspace.focused_window_index = focused_window_index - 1;
                    std.debug.print("Set focus on window {}\n", .{focused_window_index - 1});

                    layout.applyLayout();
                },
                .move_window_right => {
                    const focused_window_index =
                        focused_workspace.focused_window_index orelse return;
                    if (focused_window_index == focused_workspace.window_list.items.len - 1) return;

                    std.mem.swap(
                        window.Window,
                        &focused_workspace.window_list.items[focused_window_index],
                        &focused_workspace.window_list.items[focused_window_index + 1],
                    );
                    std.debug.print("Moved window {} to the right\n", .{focused_window_index});

                    focused_workspace.focused_window_index = focused_window_index + 1;
                    std.debug.print("Set focus on window {}\n", .{focused_window_index + 1});

                    layout.applyLayout();
                },
                .adjust_window_width => |percentage| {
                    const focused_window_index =
                        focused_workspace.focused_window_index orelse return;
                    var focused_window = &focused_workspace.window_list.items[focused_window_index];

                    focused_window.animation_info.width_start = focused_window.width;
                    focused_window.animation_info.width_finish = focused_window.width +
                        @divTrunc(layout.output.non_exclusive_width * percentage, 100);
                    std.debug.print("Adjusted width of window by {}%\n", .{percentage});

                    layout.applyLayout();
                },
                .focus_workspace => |number| {
                    layout.focused_workspace_index = number - 1;
                    std.debug.print(
                        "Set focus on workspace {}\n",
                        .{layout.focused_workspace_index + 1},
                    );

                    layout.applyLayout();
                },
                .reload_config => {
                    config.loadConfig(main.allocator);
                    layout.applyLayout();
                },
            }
        },
        else => {},
    }
}

fn parseKey(key: []const u8) ?u32 {
    if (key.len == 1) return @as(u32, key[0]);
    return null;
}
