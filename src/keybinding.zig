const std = @import("std");
const wayland = @import("wayland");
const xkbcommon = @import("xkbcommon");
const river = wayland.client.river;

const config = @import("config.zig");
const layout = @import("layout.zig");
const types = @import("types.zig");

pub fn setup(wm: *types.WindowManager) void {
    const xkb_bindings = wm.river_xkb_bindings orelse {
        std.debug.print("Failed to find xkb bindings\n", .{});
        return;
    };

    for (wm.xkb_binding_list.items) |item| item.river_xkb_binding.destroy();
    wm.xkb_binding_list.clearRetainingCapacity();

    for (wm.config.keybindings) |keybinding| {
        const keysym = parseKey(keybinding.key) orelse {
            std.debug.print("Failed to parse key\n", .{});
            continue;
        };
        const xkb_binding = xkb_bindings.getXkbBinding(
            wm.river_seat.?,
            @intFromEnum(keysym),
            keybinding.modifiers,
        ) catch |err| {
            std.debug.print("Failed to get xkb binding: {}\n", .{err});
            continue;
        };

        wm.xkb_binding_list.append(
            wm.gpa.allocator(),
            .{ .river_xkb_binding = xkb_binding, .keybinding = keybinding },
        ) catch |err| {
            std.debug.print("Failed to add xkb binding: {}\n", .{err});
            return;
        };
        xkb_binding.setListener(*types.WindowManager, xkbBindingListener, wm);
        xkb_binding.enable();
    }
}

fn parseKey(key: [:0]const u8) ?xkbcommon.Keysym {
    const keysym = xkbcommon.Keysym.fromName(key, .case_insensitive);
    if (keysym != .NoSymbol) return keysym;
    return null;
}

test "validate default keybindings" {
    const default_config: types.Config = @import("default_config");
    for (default_config.keybindings) |keybinding| {
        if (parseKey(keybinding.key) == null)
            std.debug.print("Keysym '{s}' is not valid\n", .{keybinding.key});
        try std.testing.expect(parseKey(keybinding.key) != null);
    }
}

fn xkbBindingListener(
    xkb_binding: *river.XkbBindingV1,
    event: river.XkbBindingV1.Event,
    wm: *types.WindowManager,
) void {
    for (wm.xkb_binding_list.items) |item| {
        if (item.river_xkb_binding != xkb_binding) continue;
        switch (event) {
            .pressed => keybindingPressed(item.keybinding.action, wm),
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
        .close_window => {
            const window_idx = workspace.focused_window_idx orelse return;
            const window = workspace.window_list.items[window_idx];
            window.river_window.close();
            return;
        },
        .toggle_fullscreen => {
            const window_idx = workspace.focused_window_idx orelse return;
            const window = &workspace.window_list.items[window_idx];
            window.is_fullscreen = !window.is_fullscreen;
            if (window.is_fullscreen) {
                window.river_window.informFullscreen();
            } else {
                window.river_window.informNotFullscreen();
            }
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
        },
        .set_window_width => |proportion| {
            const window_idx = workspace.focused_window_idx orelse return;
            var window = &workspace.window_list.items[window_idx];
            window.proportion = proportion;
        },
        .focus_window_left => {
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == 0) return;
            workspace.focused_window_idx = window_idx - 1;
        },
        .focus_window_right => {
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == workspace.window_list.items.len - 1) return;
            workspace.focused_window_idx = window_idx + 1;
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
        },
        .focus_workspace_above => {
            if (workspace_idx == 0) return;
            output.focused_workspace_idx -= 1;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .focus_workspace_below => {
            if (workspace_idx == 9) return;
            output.focused_workspace_idx += 1;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .focus_workspace_previous => {
            const previous = wm.previous_workspace orelse return;
            wm.focused_output_idx = previous.output_idx;
            const target_output = &wm.output_list.items[previous.output_idx];
            target_output.focused_workspace_idx = previous.workspace_idx;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .focus_workspace_number => |number| {
            if (number == 0 or number > 10) return;
            if (workspace_idx == number - 1) return;

            output.focused_workspace_idx = number - 1;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .move_window_to_workspace_above => {
            if (workspace_idx == 0) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const target_workspace = &output.workspace_list[workspace_idx - 1];

            move_window_to_workspace(
                window_idx,
                workspace,
                target_workspace,
                allocator,
            ) catch |err| {
                std.debug.print("Failed to move window: {}\n", .{err});
                return;
            };
            output.focused_workspace_idx = workspace_idx - 1;

            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .move_window_to_workspace_below => {
            if (workspace_idx == 9) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const target_workspace = &output.workspace_list[workspace_idx + 1];

            move_window_to_workspace(
                window_idx,
                workspace,
                target_workspace,
                allocator,
            ) catch |err| {
                std.debug.print("Failed to move window: {}\n", .{err});
                return;
            };
            output.focused_workspace_idx = workspace_idx + 1;

            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .move_window_to_workspace_number => |number| {
            if (number == 0 or number > 10 or number - 1 == workspace_idx) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const target_workspace = &output.workspace_list[number - 1];

            move_window_to_workspace(
                window_idx,
                workspace,
                target_workspace,
                allocator,
            ) catch |err| {
                std.debug.print("Failed to move window: {}\n", .{err});
                return;
            };
            output.focused_workspace_idx = number - 1;

            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .focus_output_left => {
            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                if (target_output.rectangle.x + target_output.rectangle.width !=
                    output.rectangle.x) continue;

                focus_output(target_output, wm.river_seat);
                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };
                return;
            }
        },
        .focus_output_right => {
            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                if (target_output.rectangle.x !=
                    output.rectangle.x + output.rectangle.width) continue;

                focus_output(target_output, wm.river_seat);
                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };
                return;
            }
        },
        .focus_output_above => {
            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                if (target_output.rectangle.y + target_output.rectangle.height !=
                    output.rectangle.y) continue;

                focus_output(target_output, wm.river_seat);
                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };
                return;
            }
        },
        .focus_output_below => {
            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                if (target_output.rectangle.y !=
                    output.rectangle.y + output.rectangle.height) continue;

                focus_output(target_output, wm.river_seat);
                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };
                return;
            }
        },
        .move_window_to_output_left => {
            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                if (target_output.rectangle.x + target_output.rectangle.width !=
                    output.rectangle.x) continue;

                const window_idx = workspace.focused_window_idx orelse return;
                const target_workspace =
                    &target_output.workspace_list[target_output.focused_workspace_idx];

                move_window_to_workspace(
                    window_idx,
                    workspace,
                    target_workspace,
                    allocator,
                ) catch |err| {
                    std.debug.print("Failed to move window: {}\n", .{err});
                    return;
                };

                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };
            }
        },
        .move_window_to_output_right => {
            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                if (target_output.rectangle.x !=
                    output.rectangle.x + output.rectangle.width) continue;

                const window_idx = workspace.focused_window_idx orelse return;
                const target_workspace =
                    &target_output.workspace_list[target_output.focused_workspace_idx];

                move_window_to_workspace(
                    window_idx,
                    workspace,
                    target_workspace,
                    allocator,
                ) catch |err| {
                    std.debug.print("Failed to move window: {}\n", .{err});
                    return;
                };

                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };
            }
        },
        .move_window_to_output_above => {
            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                if (target_output.rectangle.y + target_output.rectangle.height !=
                    output.rectangle.y) continue;

                const window_idx = workspace.focused_window_idx orelse return;
                const target_workspace =
                    &target_output.workspace_list[target_output.focused_workspace_idx];

                move_window_to_workspace(
                    window_idx,
                    workspace,
                    target_workspace,
                    allocator,
                ) catch |err| {
                    std.debug.print("Failed to move window: {}\n", .{err});
                    return;
                };

                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };
            }
        },
        .move_window_to_output_below => {
            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                if (target_output.rectangle.y !=
                    output.rectangle.y + output.rectangle.height) continue;

                const window_idx = workspace.focused_window_idx orelse return;
                const target_workspace =
                    &target_output.workspace_list[target_output.focused_workspace_idx];

                move_window_to_workspace(
                    window_idx,
                    workspace,
                    target_workspace,
                    allocator,
                ) catch |err| {
                    std.debug.print("Failed to move window: {}\n", .{err});
                    return;
                };

                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };
            }
        },
        .exit => {
            wm.deinit(config.is_parsed);
            wm.river_window_manager.?.exitSession();
            return;
        },
        .reload_config => {
            wm.config = config.load(allocator);
            setup(wm);
        },
        .spawn => |command| {
            spawn(command, allocator) catch |err|
                std.debug.print("Failed to spawn {s}: {}\n", .{ command[0], err });
            return;
        },
    }
    layout.apply(&wm.output_list, wm.config);
}

fn move_window_to_workspace(
    window_idx: usize,
    workspace: *types.Workspace,
    target_workspace: *types.Workspace,
    allocator: std.mem.Allocator,
) !void {
    const window = workspace.window_list.orderedRemove(window_idx);

    if (workspace.window_list.items.len == 0) {
        workspace.focused_window_idx = null;
    } else if (window_idx != 0) {
        workspace.focused_window_idx = window_idx - 1;
    }

    var target_window_idx: usize = 0;
    if (target_workspace.focused_window_idx) |idx| target_window_idx = idx + 1;

    try target_workspace.window_list.insert(allocator, target_window_idx, window);
    target_workspace.focused_window_idx = target_window_idx;
}

fn focus_output(output: *types.Output, river_seat: ?*river.SeatV1) void {
    if (output.river_layer_shell_output) |layer_shell_output|
        layer_shell_output.setDefault();

    const seat = river_seat orelse {
        std.debug.print("Failed to find seat\n", .{});
        return;
    };
    const workspace = output.workspace_list[output.focused_workspace_idx];
    const window_idx = workspace.focused_window_idx orelse return;
    seat.focusWindow(workspace.window_list.items[window_idx].river_window);
}

fn spawn(command: []const []const u8, allocator: std.mem.Allocator) !void {
    const child = try allocator.create(std.process.Child);
    errdefer allocator.destroy(child);

    child.* = std.process.Child.init(command, allocator);
    try child.spawn();

    const thread = try std.Thread.spawn(.{}, wait, .{ child, allocator });
    thread.detach();
}

fn wait(child: *std.process.Child, allocator: std.mem.Allocator) void {
    _ = child.wait() catch {};
    allocator.destroy(child);
}
