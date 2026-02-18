const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const config = @import("config.zig");
const layout = @import("layout.zig");
const main = @import("main.zig");
const window = @import("window.zig");

pub const Keybind = struct {
    key: []const u8,
    modifier: river.SeatV1.Modifiers,
    action: Action,
};

pub const Action = union(enum) {
    spawn: []const []const u8,
    close_window: void,
    focus_window_left: void,
    focus_window_right: void,
    move_window_left: void,
    move_window_right: void,
    adjust_window_width: i32,
    toggle_fullscreen: void,
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
            std.debug.print("Failed to get xkb binding: {}\n", .{err});
            continue;
        };

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
                },
                .close_window => {
                    const focused_window_index =
                        focused_workspace.focused_window_index orelse return;
                    const focused_window =
                        &focused_workspace.window_list.items[focused_window_index];

                    focused_window.river_window.close();
                },
                .focus_window_left => {
                    const focused_window_index =
                        focused_workspace.focused_window_index orelse return;
                    if (focused_window_index == 0) return;

                    focused_workspace.focused_window_index = focused_window_index - 1;
                    layout.applyLayout();
                },
                .focus_window_right => {
                    const focused_window_index =
                        focused_workspace.focused_window_index orelse return;
                    if (focused_window_index == focused_workspace.window_list.items.len - 1) return;

                    focused_workspace.focused_window_index = focused_window_index + 1;
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
                    focused_workspace.focused_window_index = focused_window_index - 1;

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
                    focused_workspace.focused_window_index = focused_window_index + 1;

                    layout.applyLayout();
                },
                .adjust_window_width => |percentage| {
                    const focused_window_index =
                        focused_workspace.focused_window_index orelse return;
                    var focused_window =
                        &focused_workspace.window_list.items[focused_window_index];

                    focused_window.animation_info.width_start = focused_window.width;
                    focused_window.animation_info.width_finish = focused_window.width +
                        @divTrunc(layout.output.non_exclusive_width * percentage, 100);

                    layout.applyLayout();
                },
                .toggle_fullscreen => {
                    const focused_window_index =
                        focused_workspace.focused_window_index orelse return;
                    const focused_window =
                        &focused_workspace.window_list.items[focused_window_index];

                    if (!focused_window.is_fullscreen) {
                        focused_window.river_window.fullscreen(layout.output.river_output);
                        focused_window.river_window.informFullscreen();
                        focused_window.is_fullscreen = true;
                    } else if (focused_window.is_fullscreen) {
                        focused_window.river_window.exitFullscreen();
                        focused_window.river_window.informNotFullscreen();
                        focused_window.is_fullscreen = false;
                    }
                },
                .focus_workspace => |number| {
                    layout.focused_workspace_index = number - 1;
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
