const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const config = @import("config.zig");
const layout = @import("layout.zig");
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
    adjust_window_width: f32,
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

pub var xkb_binding_list: std.ArrayList(*river.XkbBindingV1) = .{};

const Data = struct {
    allocator: std.mem.Allocator,
    xkb_bindings: *river.XkbBindingsV1,
    seat: *river.SeatV1,
};
var data: Data = undefined;

pub fn setupKeybinds(
    allocator: std.mem.Allocator,
    xkb_bindings: *river.XkbBindingsV1,
    seat: *river.SeatV1,
) void {
    for (xkb_binding_list.items) |item| item.destroy();
    xkb_binding_list.clearRetainingCapacity();

    for (config.config.keybinds) |*item| {
        const keysym = parseKey(item.key) orelse {
            std.debug.print("Failed to parse key\n", .{});
            continue;
        };
        const xkb_binding = xkb_bindings.getXkbBinding(seat, keysym, item.modifier) catch |err| {
            std.debug.print("Failed to get xkb binding: {}\n", .{err});
            continue;
        };

        xkb_binding_list.append(allocator, xkb_binding) catch |err| {
            std.debug.print("Failed to add xkb binding: {}\n", .{err});
            return;
        };

        xkb_binding.setListener(*Action, xkbBindingListener, @constCast(&item.action));
        xkb_binding.enable();
    }

    data = .{
        .allocator = allocator,
        .xkb_bindings = xkb_bindings,
        .seat = seat,
    };
}

fn xkbBindingListener(
    _: *river.XkbBindingV1,
    event: river.XkbBindingV1.Event,
    action: *Action,
) void {
    switch (event) {
        .pressed => {
            const workspace = &layout.workspace_list[layout.focused_workspace_index];

            switch (action.*) {
                .spawn => |command| {
                    var child = std.process.Child.init(command, data.allocator);
                    child.spawn() catch |err|
                        std.debug.print("Failed to spawn {s}: {}\n", .{ command[0], err });
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
                    layout.apply();
                },
                .focus_window_right => {
                    const window_index = workspace.focused_window_index orelse return;
                    if (window_index == workspace.window_list.items.len - 1) return;
                    workspace.focused_window_index = window_index + 1;
                    layout.apply();
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

                    layout.apply();
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

                    layout.apply();
                },
                .adjust_window_width => |increment| {
                    const window_index = workspace.focused_window_index orelse return;
                    var focused_window = &workspace.window_list.items[window_index];
                    if (focused_window.fullscreen) return;

                    const gap = config.config.horizontal_gap;
                    const base_width: f32 = @floatFromInt(layout.output.non_exclusive_width - gap);
                    const width_with_gap: i32 =
                        @intFromFloat(base_width * (focused_window.proportion + increment));

                    if (width_with_gap - gap < 2 * config.config.border.width) return;
                    focused_window.proportion += increment;

                    layout.apply();
                },
                .toggle_fullscreen => {
                    const window_index = workspace.focused_window_index orelse return;
                    const focused_window = &workspace.window_list.items[window_index];
                    focused_window.fullscreen = !focused_window.fullscreen;
                    layout.apply();
                },
                .focus_workspace => |number| {
                    if (layout.focused_workspace_index == number - 1) return;
                    layout.focused_workspace_index = number - 1;
                    layout.apply();
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
                        data.allocator,
                        target_window_index,
                        moved_window,
                    ) catch |err| {
                        std.debug.print("Failed to add window: {}\n", .{err});
                        return;
                    };
                    target_workspace.focused_window_index = target_window_index;
                    layout.focused_workspace_index = number - 1;

                    layout.apply();
                },
                .reload_config => {
                    config.loadConfig(data.allocator);
                    setupKeybinds(data.allocator, data.xkb_bindings, data.seat);
                    layout.apply();
                },
            }
        },
        else => {},
    }
}
