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
    move_window_to_workspace: usize,
    reload_config: void,
};

const SpecialKeyMap = std.StaticStringMap(u32).initComptime(.{
    .{ "Left", 0xFF51 },
    .{ "Up", 0xFF52 },
    .{ "Right", 0xFF53 },
    .{ "Down", 0xFF54 },

    .{ "BackSpace", 0xFF08 },
    .{ "Tab", 0xFF09 },
    .{ "Return", 0xFF0D },
    .{ "Escape", 0xFF1B },
    .{ "Delete", 0xFFFF },

    .{ "XF86MonBrightnessUp", 0x1008FF02 },
    .{ "XF86MonBrightnessDown", 0x1008FF03 },

    .{ "XF86AudioLowerVolume", 0x1008FF11 },
    .{ "XF86AudioMute", 0x1008FF12 },
    .{ "XF86AudioRaiseVolume", 0x1008FF13 },
    .{ "XF86AudioMicMute", 0x1008FFB2 },
});

fn parseKey(key: []const u8) ?u32 {
    if (SpecialKeyMap.get(key)) |keysym| return keysym;
    if (key.len == 1) return @as(u32, key[0]);
    return null;
}

var xkb_binding_list: std.ArrayList(*river.XkbBindingV1) = .{};

pub fn setupKeybinds(
    allocator: std.mem.Allocator,
    seat: *river.SeatV1,
    xkb_bindings: *river.XkbBindingsV1,
) void {
    for (xkb_binding_list.items) |item| item.destroy();
    xkb_binding_list.clearRetainingCapacity();

    for (config.config.keybinds) |*item| {
        const keysym = parseKey(item.key) orelse continue;

        const xkb_binding = xkb_bindings.getXkbBinding(
            seat,
            keysym,
            item.modifier,
        ) catch |err| {
            std.debug.print("Failed to get xkb binding: {}\n", .{err});
            continue;
        };

        xkb_binding_list.append(allocator, xkb_binding) catch |err| {
            std.debug.print("Failed to add xkb binding: {}\n", .{err});
            return;
        };

        xkb_binding.setListener(
            ?*anyopaque,
            xkbBindingListener,
            @ptrCast(@constCast(&item.action)),
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
            const workspace = &layout.workspace_list[layout.focused_workspace_index];

            switch (action.*) {
                .spawn => |command| {
                    var child = std.process.Child.init(command, main.allocator);
                    child.spawn() catch |err| {
                        std.debug.print("Failed to spawn {s}: {}\n", .{ command[0], err });
                    };
                },
                .close_window => {
                    const window_index = workspace.focused_window_index orelse return;
                    const focused_window = workspace.window_list.items[window_index];

                    focused_window.river_window.close();
                },
                .focus_window_left => {
                    const window_index = workspace.focused_window_index orelse return;
                    if (window_index == 0) return;

                    workspace.focused_window_index = window_index - 1;
                    layout.applyLayout();
                },
                .focus_window_right => {
                    const window_index = workspace.focused_window_index orelse return;
                    if (window_index == workspace.window_list.items.len - 1)
                        return;

                    workspace.focused_window_index = window_index + 1;
                    layout.applyLayout();
                },
                .move_window_left => {
                    const window_index = workspace.focused_window_index orelse return;
                    if (window_index == 0) return;

                    std.mem.swap(
                        window.Window,
                        &workspace.window_list.items[window_index],
                        &workspace.window_list.items[window_index - 1],
                    );
                    workspace.focused_window_index = window_index - 1;

                    layout.applyLayout();
                },
                .move_window_right => {
                    const window_index = workspace.focused_window_index orelse return;
                    if (window_index == workspace.window_list.items.len - 1) return;

                    std.mem.swap(
                        window.Window,
                        &workspace.window_list.items[window_index],
                        &workspace.window_list.items[window_index + 1],
                    );
                    workspace.focused_window_index = window_index + 1;

                    layout.applyLayout();
                },
                .adjust_window_width => |percentage| {
                    const window_index = workspace.focused_window_index orelse return;
                    var focused_window = &workspace.window_list.items[window_index];
                    if (focused_window.fullscreen_when_focused) return;

                    const gap = config.config.horizontal_gap;
                    const width = focused_window.width +
                        @divTrunc((layout.output.non_exclusive_width - gap) * percentage, 100);
                    if (width < 2 * config.config.border.width) return;

                    focused_window.animation_info.width_start = focused_window.width;
                    focused_window.animation_info.width_finish = width;

                    layout.applyLayout();
                },
                .toggle_fullscreen => {
                    const window_index = workspace.focused_window_index orelse return;
                    const focused_window = &workspace.window_list.items[window_index];

                    if (!focused_window.fullscreen_when_focused) {
                        focused_window.fullscreen_when_focused = true;
                        focused_window.river_window.informFullscreen();
                        focused_window.river_window.fullscreen(layout.output.river_output);
                    } else if (focused_window.fullscreen_when_focused) {
                        focused_window.fullscreen_when_focused = false;
                        focused_window.river_window.informNotFullscreen();
                        focused_window.river_window.exitFullscreen();
                    }
                },
                .focus_workspace => |number| {
                    layout.focused_workspace_index = number - 1;
                    layout.applyLayout();
                },
                .move_window_to_workspace => |number| {
                    const window_index = workspace.focused_window_index orelse return;

                    if (workspace.window_list.items.len == 1) {
                        workspace.focused_window_index = null;
                    } else if (window_index != 0) {
                        workspace.focused_window_index = window_index - 1;
                    }

                    const moved_window = workspace.window_list.orderedRemove(window_index);

                    const target_workspace = &layout.workspace_list[number - 1];
                    var target_window_index: usize = 0;
                    if (target_workspace.focused_window_index) |index|
                        target_window_index = index + 1;

                    target_workspace.window_list.insert(
                        main.allocator,
                        target_window_index,
                        moved_window,
                    ) catch |err| {
                        std.debug.print("Failed to add window: {}\n", .{err});
                        return;
                    };
                    target_workspace.focused_window_index = target_window_index;
                    layout.focused_workspace_index = number - 1;

                    layout.applyLayout();
                },
                .reload_config => {
                    config.loadConfig(main.allocator);

                    const seat = main.river_seat orelse return;
                    const xkb_bindings = main.river_xkb_bindings orelse return;
                    setupKeybinds(main.allocator, seat, xkb_bindings);

                    layout.applyLayout();
                },
            }
        },
        else => {},
    }
}
