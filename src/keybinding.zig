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
            .pressed => keybindingPressed(keybinding.action, wm),
            else => {},
        }
        return;
    }
}

fn keybindingPressed(action: types.Action, wm: *types.WindowManager) void {
    const output_idx = wm.focused_output_idx orelse return;
    const output = &wm.output_list.items[output_idx];
    const workspace_idx = output.focused_workspace_idx;
    const workspace = &output.workspace_list[workspace_idx];
    const allocator = wm.gpa.allocator();

    switch (action) {
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
            const window_idx = workspace.focused_window_idx orelse return;
            const window = workspace.window_list.items[window_idx];
            window.river_window.close();
        },
        .focus_window_left => {
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == 0) return;
            workspace.focused_window_idx = window_idx - 1;
            layout.apply(output, wm.config);
        },
        .focus_window_right => {
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == workspace.window_list.items.len - 1) return;
            workspace.focused_window_idx = window_idx + 1;
            layout.apply(output, wm.config);
        },
        .move_window_left => {
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == 0) return;

            std.mem.swap(
                types.Window,
                &workspace.window_list.items[window_idx],
                &workspace.window_list.items[window_idx - 1],
            );

            workspace.focused_window_idx = window_idx - 1;
            layout.apply(output, wm.config);
        },
        .move_window_right => {
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == workspace.window_list.items.len - 1) return;

            std.mem.swap(
                types.Window,
                &workspace.window_list.items[window_idx],
                &workspace.window_list.items[window_idx + 1],
            );

            workspace.focused_window_idx = window_idx + 1;
            layout.apply(output, wm.config);
        },
        .adjust_window_width => |increment| {
            const window_idx = workspace.focused_window_idx orelse return;
            var window = &workspace.window_list.items[window_idx];
            if (window.is_fullscreen) return;

            const non_exclusive = output.non_exclusive orelse output.rectangle;
            const gap = wm.config.horizontal_gap;
            const base_width: f32 = @floatFromInt(non_exclusive.width - gap);
            const width_with_gap: i32 =
                @intFromFloat(base_width * (window.proportion + increment));
            if (width_with_gap - gap < 2 * wm.config.border.width) return;

            window.proportion += increment;
            layout.apply(output, wm.config);
        },
        .toggle_fullscreen => {
            const window_idx = workspace.focused_window_idx orelse return;
            const window = &workspace.window_list.items[window_idx];
            window.is_fullscreen = !window.is_fullscreen;
            layout.apply(output, wm.config);
        },
        .focus_workspace => |number| {
            if (number == 0 or number > 10) return;
            if (workspace_idx == number - 1) return;

            output.focused_workspace_idx = number - 1;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
            layout.apply(output, wm.config);
        },
        .move_window_to_workspace => |number| {
            if (number == 0 or number > 10) return;
            if (workspace_idx == number - 1) return;
            const window_idx = workspace.focused_window_idx orelse return;

            const window = workspace.window_list.orderedRemove(window_idx);

            if (workspace.window_list.items.len == 0) {
                workspace.focused_window_idx = null;
            } else if (window_idx != 0) {
                workspace.focused_window_idx = window_idx - 1;
            }

            const target_workspace = &output.workspace_list[number - 1];
            var target_window_idx: usize = 0;
            if (target_workspace.focused_window_idx) |idx| target_window_idx = idx + 1;

            target_workspace.window_list.insert(
                allocator,
                target_window_idx,
                window,
            ) catch |err| {
                std.debug.print("Failed to add window: {}\n", .{err});
                return;
            };

            target_workspace.focused_window_idx = target_window_idx;
            output.focused_workspace_idx = number - 1;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };

            layout.apply(output, wm.config);
        },
        .focus_previous_workspace => {
            const previous = wm.previous_workspace orelse return;

            wm.focused_output_idx = previous.output_idx;
            output.focused_workspace_idx = previous.workspace_idx;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
            layout.apply(output, wm.config);
        },
        .focus_output_left => {
            for (wm.output_list.items, 0..) |target_output, target_output_idx| {
                if (target_output.rectangle.x + target_output.rectangle.width !=
                    output.rectangle.x) continue;

                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };

                return;
            }
        },
        .focus_output_right => {
            for (wm.output_list.items, 0..) |target_output, target_output_idx| {
                if (target_output.rectangle.x !=
                    output.rectangle.x + output.rectangle.width) continue;

                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };

                return;
            }
        },
        .focus_output_up => {
            for (wm.output_list.items, 0..) |target_output, target_output_idx| {
                if (target_output.rectangle.y + target_output.rectangle.height !=
                    output.rectangle.y) continue;

                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };

                return;
            }
        },
        .focus_output_down => {
            for (wm.output_list.items, 0..) |target_output, target_output_idx| {
                if (target_output.rectangle.y !=
                    output.rectangle.y + output.rectangle.height) continue;

                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };

                return;
            }
        },
    }
}
