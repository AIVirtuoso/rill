const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const config = @import("config.zig");
const layout = @import("layout.zig");
const types = @import("types.zig");

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

pub fn setup(wm: *types.WindowManager) void {
    const xkb_bindings = wm.river_xkb_bindings orelse {
        std.debug.print("Failed to find xkb bindings\n", .{});
        return;
    };

    for (wm.xkb_binding_list.items) |item| item.destroy();
    wm.xkb_binding_list.clearRetainingCapacity();

    for (wm.config.keybindings) |*keybinding| {
        const keysym = parseKey(keybinding.key) orelse {
            std.debug.print("Failed to parse key\n", .{});
            continue;
        };
        const xkb_binding = xkb_bindings.getXkbBinding(
            wm.river_seat.?,
            keysym,
            keybinding.modifiers,
        ) catch |err| {
            std.debug.print("Failed to get xkb binding: {}\n", .{err});
            continue;
        };

        keybinding.id = xkb_binding.getId();
        wm.xkb_binding_list.append(wm.gpa.allocator(), xkb_binding) catch |err| {
            std.debug.print("Failed to add xkb binding: {}\n", .{err});
            return;
        };
        xkb_binding.setListener(*types.WindowManager, xkbBindingListener, wm);
        xkb_binding.enable();
    }
}

fn xkbBindingListener(
    xkb_binding: *river.XkbBindingV1,
    event: river.XkbBindingV1.Event,
    wm: *types.WindowManager,
) void {
    for (wm.config.keybindings) |keybinding| {
        if (keybinding.id != xkb_binding.getId()) continue;

        switch (event) {
            .pressed => {
                const output = &wm.output_list.items[wm.focused_output_idx];
                const workspace = &output.workspace_list[output.focused_workspace_idx];
                const allocator = wm.gpa.allocator();

                switch (keybinding.action) {
                    .spawn => |command| {
                        var child = std.process.Child.init(command, allocator);
                        child.spawn() catch |err|
                            std.debug.print("Failed to spawn {s}: {}\n", .{ command[0], err });
                    },
                    .reload_config => {
                        if (config.loadConfig(allocator)) |loaded_config|
                            wm.config = loaded_config;
                        setup(wm);
                        layout.apply(output, wm.config);
                    },
                    .exit => {
                        wm.deinit();
                        wm.river_window_manager.?.exitSession();
                    },
                    .close_window => {
                        const idx = workspace.focused_window_idx orelse return;
                        const window = workspace.window_list.items[idx];
                        window.river_window.close();
                    },
                    .focus_window_left => {
                        const idx = workspace.focused_window_idx orelse return;
                        if (idx == 0) return;
                        workspace.focused_window_idx = idx - 1;
                        layout.apply(output, wm.config);
                    },
                    .focus_window_right => {
                        const idx = workspace.focused_window_idx orelse return;
                        if (idx == workspace.window_list.items.len - 1) return;
                        workspace.focused_window_idx = idx + 1;
                        layout.apply(output, wm.config);
                    },
                    .move_window_left => {
                        const idx = workspace.focused_window_idx orelse return;
                        if (idx == 0) return;

                        std.mem.swap(
                            types.Window,
                            &workspace.window_list.items[idx],
                            &workspace.window_list.items[idx - 1],
                        );
                        workspace.focused_window_idx = idx - 1;

                        layout.apply(output, wm.config);
                    },
                    .move_window_right => {
                        const idx = workspace.focused_window_idx orelse return;
                        if (idx == workspace.window_list.items.len - 1) return;

                        std.mem.swap(
                            types.Window,
                            &workspace.window_list.items[idx],
                            &workspace.window_list.items[idx + 1],
                        );
                        workspace.focused_window_idx = idx + 1;

                        layout.apply(output, wm.config);
                    },
                    .adjust_window_width => |increment| {
                        const idx = workspace.focused_window_idx orelse return;
                        var window = &workspace.window_list.items[idx];
                        if (window.fullscreen) return;

                        const non_exclusive = output.non_exclusive orelse output.dimensions;
                        const gap = wm.config.horizontal_gap;
                        const base_width: f32 = @floatFromInt(non_exclusive.width - gap);
                        const width_with_gap: i32 =
                            @intFromFloat(base_width * (window.proportion + increment));

                        if (width_with_gap - gap < 2 * wm.config.border.width) return;
                        window.proportion += increment;

                        layout.apply(output, wm.config);
                    },
                    .toggle_fullscreen => {
                        const idx = workspace.focused_window_idx orelse return;
                        const window = &workspace.window_list.items[idx];
                        window.fullscreen = !window.fullscreen;
                        layout.apply(output, wm.config);
                    },
                    .focus_workspace => |number| {
                        if (number == 0 or number > 10) return;
                        if (output.focused_workspace_idx == number - 1) return;
                        output.focused_workspace_idx = number - 1;
                        layout.apply(output, wm.config);
                    },
                    .move_window_to_workspace => |number| {
                        if (number == 0 or number > 10) return;
                        if (output.focused_workspace_idx == number - 1) return;
                        const current_idx = workspace.focused_window_idx orelse return;

                        if (workspace.window_list.items.len == 1) {
                            workspace.focused_window_idx = null;
                        } else if (current_idx != 0) {
                            workspace.focused_window_idx = current_idx - 1;
                        }

                        const window = workspace.window_list.orderedRemove(current_idx);

                        const target_workspace = &output.workspace_list[number - 1];
                        var target_idx: usize = 0;
                        if (target_workspace.focused_window_idx) |idx|
                            target_idx = idx + 1;

                        target_workspace.window_list.insert(
                            allocator,
                            target_idx,
                            window,
                        ) catch |err| {
                            std.debug.print("Failed to add window: {}\n", .{err});
                            return;
                        };
                        target_workspace.focused_window_idx = target_idx;
                        output.focused_workspace_idx = number - 1;

                        layout.apply(output, wm.config);
                    },
                    .focus_output_left => {
                        for (wm.output_list.items, 0..) |item, idx| {
                            if (item.dimensions.x + item.dimensions.width ==
                                output.dimensions.x)
                                wm.focused_output_idx = idx;
                        }
                        layout.apply(output, wm.config);
                    },
                    .focus_output_right => {
                        for (wm.output_list.items, 0..) |item, idx| {
                            if (item.dimensions.x ==
                                output.dimensions.x + output.dimensions.width)
                                wm.focused_output_idx = idx;
                        }
                        layout.apply(output, wm.config);
                    },
                    .focus_output_up => {
                        for (wm.output_list.items, 0..) |item, idx| {
                            if (item.dimensions.y + item.dimensions.height ==
                                output.dimensions.y)
                                wm.focused_output_idx = idx;
                        }
                        layout.apply(output, wm.config);
                    },
                    .focus_output_down => {
                        for (wm.output_list.items, 0..) |item, idx| {
                            if (item.dimensions.y ==
                                output.dimensions.y + output.dimensions.height)
                                wm.focused_output_idx = idx;
                        }
                        layout.apply(output, wm.config);
                    },
                }
            },
            else => {},
        }
        return;
    }
}
