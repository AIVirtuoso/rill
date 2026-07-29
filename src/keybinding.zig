const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const wayland = @import("wayland");
const xkbcommon = @import("xkbcommon");
const river = wayland.client.river;

const config = @import("config.zig");
const layout = @import("layout.zig");
const types = @import("types.zig");

pub fn setupKeybindings(allocator: Allocator, wm: *types.WindowManager) !void {
    for (wm.xkb_binding_list.items) |binding| binding.river_xkb_binding.destroy();
    wm.xkb_binding_list.clearRetainingCapacity();

    const xkb_bindings = wm.river_xkb_bindings orelse {
        std.debug.print("Failed to find xkb bindings\n", .{});
        return;
    };

    for (wm.getConfig().keybindings) |keybinding| {
        const keysym = parseKey(keybinding.key) orelse {
            std.debug.print("Failed to parse key\n", .{});
            continue;
        };
        const xkb_binding = try xkb_bindings.getXkbBinding(
            wm.river_seat.?,
            @intFromEnum(keysym),
            keybinding.modifiers,
        );

        try wm.xkb_binding_list.append(
            allocator,
            .{ .river_xkb_binding = xkb_binding, .action = keybinding.action },
        );
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
    for (types.default_keybindings) |keybinding| {
        if (parseKey(keybinding.key) == null) {
            std.debug.print("Keysym '{s}' is not valid\n", .{keybinding.key});
        }
        try std.testing.expect(parseKey(keybinding.key) != null);
    }
}

fn xkbBindingListener(
    xkb_binding: *river.XkbBindingV1,
    event: river.XkbBindingV1.Event,
    wm: *types.WindowManager,
) void {
    if (wm.status == .pointer_action) return;
    for (wm.xkb_binding_list.items) |binding| {
        if (binding.river_xkb_binding != xkb_binding) continue;
        switch (event) {
            .pressed => {
                const action = binding.action;

                // if we are in passthrough mode and we are not trying to toggle it then
                // go ahead and forego checking the action.
                if (wm.is_passthrough and action != .toggle_passthrough) continue;

                keybindingPressed(
                    wm.allocator,
                    wm.io,
                    action,
                    wm,
                    wm.environ_map,
                ) catch |err| {
                    std.debug.print("Keybinding's action failed: {}\n", .{err});
                };
            },
            else => {},
        }
        return;
    }
}

fn keybindingPressed(
    allocator: Allocator,
    io: Io,
    action: types.KeybindingAction,
    wm: *types.WindowManager,
    environ_map: std.process.Environ.Map,
) !void {
    const output_idx = wm.focused_output_idx orelse return;
    const output = &wm.output_list.items[output_idx];
    const workspace_idx = output.focused_workspace_idx;
    const workspace = &output.workspace_list.items[workspace_idx];

    action_switch: switch (action) {
        .close_window => {
            const window_idx = workspace.focused_window_idx orelse return;
            const window = &workspace.window_list.items[window_idx];
            window.is_closing = true;
        },
        .toggle_fullscreen => {
            const window_idx = workspace.focused_window_idx orelse return;
            const window = &workspace.window_list.items[window_idx];
            window.is_fullscreen = !window.is_fullscreen;
        },
        .toggle_maximize_column => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            var window = &workspace.window_list.items[window_idx];
            window.proportion = if (window.proportion == 1.0) 0.5 else 1.0;
        },
        .toggle_passthrough => wm.is_passthrough = !wm.is_passthrough,
        .adjust_window_width => |increment| {
            if (workspace.is_floating) return;
            const focused_idx = workspace.focused_window_idx orelse return;
            // A column's width comes from its head, so widening any member has
            // to widen the head or the change is invisible.
            const window_idx = workspace.columnHead(focused_idx);
            var window = &workspace.window_list.items[window_idx];
            if (window.is_fullscreen) return;

            const gap = wm.getConfig().horizontal_gap;
            const base_width: f32 = @floatFromInt(output.non_exclusive.width - gap);
            const width_with_gap: i32 = @trunc(base_width * (window.proportion + increment));
            if (width_with_gap - gap < 2 * wm.getConfig().border.width) return;

            window.proportion += increment;
        },
        .set_window_width => |proportion| {
            if (workspace.is_floating) return;
            const focused_idx = workspace.focused_window_idx orelse return;
            var window = &workspace.window_list.items[workspace.columnHead(focused_idx)];
            window.proportion = proportion;
        },
        .focus_window_left => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            // Horizontal movement steps over a whole column; focus_window_up
            // and focus_window_down move inside one. Stepping from the column
            // head rather than from the focused window means leaving a column
            // lands on the neighbour, not on the top of the column just left.
            // A floating window is its own head, so it stays reachable here.
            const head_idx = workspace.columnHead(window_idx);
            if (head_idx == 0) return;
            workspace.focused_window_idx = workspace.columnHead(head_idx - 1);
        },
        .focus_window_or_output_left => {
            const window_idx = workspace.focused_window_idx orelse return;
            // The edge of the chain is the edge of the leftmost *column*: a
            // member of it is at the edge too, even though its index is not 0.
            if (workspace.is_floating or workspace.columnHead(window_idx) == 0) {
                continue :action_switch .focus_output_left;
            }
            continue :action_switch .focus_window_left;
        },
        .focus_window_right => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const next_idx = workspace.columnEnd(window_idx);
            if (next_idx >= workspace.window_list.items.len) return;
            workspace.focused_window_idx = next_idx;
        },
        .focus_window_or_output_right => {
            const window_idx = workspace.focused_window_idx orelse return;
            if (workspace.is_floating or
                workspace.columnEnd(window_idx) >= workspace.window_list.items.len)
            {
                continue :action_switch .focus_output_right;
            }
            continue :action_switch .focus_window_right;
        },
        .focus_window_up => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const items = workspace.window_list.items;
            if (!types.hasAbove(items, window_idx)) return;
            workspace.focused_window_idx =
                types.previousTiled(items, window_idx) orelse return;
        },
        .focus_window_down => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const items = workspace.window_list.items;
            if (!types.hasBelow(items, window_idx)) return;
            workspace.focused_window_idx =
                types.nextTiled(items, window_idx) orelse return;
        },
        // Vertical movement that falls out of the column at its ends: inside a
        // stack these step between members, and at the top or bottom member
        // they carry on to the workspace above or below. A window that is not
        // stacked has neither, so this is plain workspace switching until a
        // column is built - which is what makes it safe to put on Super+J/K.
        .focus_window_or_workspace_up => {
            if (workspace.is_floating) continue :action_switch .focus_workspace_above;
            const window_idx = workspace.focused_window_idx orelse
                continue :action_switch .focus_workspace_above;
            if (!types.hasAbove(workspace.window_list.items, window_idx)) {
                continue :action_switch .focus_workspace_above;
            }
            continue :action_switch .focus_window_up;
        },
        .focus_window_or_workspace_down => {
            if (workspace.is_floating) continue :action_switch .focus_workspace_below;
            const window_idx = workspace.focused_window_idx orelse
                continue :action_switch .focus_workspace_below;
            if (!types.hasBelow(workspace.window_list.items, window_idx)) {
                continue :action_switch .focus_workspace_below;
            }
            continue :action_switch .focus_window_down;
        },
        .move_window_up => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const items = workspace.window_list.items;
            if (!types.hasAbove(items, window_idx)) return;
            const above_idx = types.previousTiled(items, window_idx) orelse return;
            swapWindows(items, window_idx, above_idx);
            workspace.focused_window_idx = above_idx;
        },
        .move_window_down => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const items = workspace.window_list.items;
            if (!types.hasBelow(items, window_idx)) return;
            const below_idx = types.nextTiled(items, window_idx) orelse return;
            swapWindows(items, window_idx, below_idx);
            workspace.focused_window_idx = below_idx;
        },
        .toggle_window_stacked => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const window = &workspace.window_list.items[window_idx];
            // A floating window has no slot in the chain to share.
            if (window.is_floating) return;
            if (window.stacked) {
                // Leaving a column mid-way starts a new one here; the members
                // below follow this window into it.
                window.stacked = false;
            } else {
                // Nothing to the left to stack onto.
                if (types.previousTiled(workspace.window_list.items, window_idx) == null) return;
                window.stacked = true;
            }
        },
        .move_window_left => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == 0) return;
            swapWindows(workspace.window_list.items, window_idx, window_idx - 1);
            workspace.focused_window_idx = window_idx - 1;
            workspace.normalizeColumns();
        },
        .move_window_right => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == workspace.window_list.items.len - 1) return;
            swapWindows(workspace.window_list.items, window_idx, window_idx + 1);
            workspace.focused_window_idx = window_idx + 1;
            workspace.normalizeColumns();
        },
        .move_window_left_or_to_output_left => {
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == 0) {
                continue :action_switch .move_window_to_output_left;
            }
            continue :action_switch .move_window_left;
        },
        .move_window_right_or_to_output_right => {
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == workspace.window_list.items.len - 1) {
                continue :action_switch .move_window_to_output_right;
            }
            continue :action_switch .move_window_right;
        },
        .toggle_workspace_floating => workspace.is_floating = !workspace.is_floating,
        .focus_workspace_above => {
            if (workspace_idx == 0) return;
            try focusWindowToWorkspace(
                wm,
                null,
                output_idx,
                output.focused_workspace_idx - 1,
            );
        },
        .focus_workspace_below => {
            if (workspace_idx == output.workspace_list.items.len - 1) return;
            try focusWindowToWorkspace(
                wm,
                null,
                output_idx,
                output.focused_workspace_idx + 1,
            );
        },
        .focus_workspace_or_output_above => {
            if (workspace_idx == 0) {
                continue :action_switch .focus_output_above;
            }
            continue :action_switch .focus_workspace_above;
        },
        .focus_workspace_or_output_below => {
            if (workspace_idx == output.workspace_list.items.len - 1) {
                continue :action_switch .focus_output_below;
            }
            continue :action_switch .focus_workspace_below;
        },
        .focus_workspace_previous => {
            const previous = wm.previous_workspace orelse return;
            try focusWindowToWorkspace(
                wm,
                null,
                previous.output_idx,
                previous.workspace_idx,
            );
        },
        .focus_workspace_number => |number| {
            if (number == 0 or number > output.workspace_list.items.len) return;
            if (workspace_idx == number - 1) return;
            try focusWindowToWorkspace(
                wm,
                null,
                output_idx,
                number - 1,
            );
        },
        .move_window_to_workspace_above => {
            if (workspace_idx == 0) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const target_window_idx = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                output_idx,
                workspace_idx - 1,
            );
            try focusWindowToWorkspace(
                wm,
                target_window_idx,
                output_idx,
                workspace_idx - 1,
            );
        },
        .move_window_to_workspace_below => {
            if (workspace_idx == output.workspace_list.items.len - 1) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const target_window_idx = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                output_idx,
                workspace_idx + 1,
            );
            try focusWindowToWorkspace(
                wm,
                target_window_idx,
                output_idx,
                workspace_idx + 1,
            );
        },
        .move_window_to_workspace_or_output_above => {
            if (workspace_idx == 0) {
                continue :action_switch .move_window_to_output_above;
            }
            continue :action_switch .move_window_to_workspace_above;
        },
        .move_window_to_workspace_or_output_below => {
            if (workspace_idx == output.workspace_list.items.len - 1) {
                continue :action_switch .move_window_to_output_below;
            }
            continue :action_switch .move_window_to_workspace_below;
        },
        .move_window_to_workspace_number => |number| {
            if (number == 0 or number > output.workspace_list.items.len or number - 1 == workspace_idx) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const target_window_idx = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                output_idx,
                number - 1,
            );
            try focusWindowToWorkspace(
                wm,
                target_window_idx,
                output_idx,
                number - 1,
            );
        },
        .send_window_to_workspace_above => {
            if (workspace_idx == 0) return;
            const window_idx = workspace.focused_window_idx orelse return;
            _ = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                output_idx,
                workspace_idx - 1,
            );
        },
        .send_window_to_workspace_below => {
            if (workspace_idx == output.workspace_list.items.len - 1) return;
            const window_idx = workspace.focused_window_idx orelse return;
            _ = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                output_idx,
                workspace_idx + 1,
            );
        },
        .send_window_to_workspace_or_output_above => {
            if (workspace_idx == 0) {
                continue :action_switch .send_window_to_output_above;
            }
            continue :action_switch .send_window_to_workspace_above;
        },
        .send_window_to_workspace_or_output_below => {
            if (workspace_idx == output.workspace_list.items.len - 1) {
                continue :action_switch .send_window_to_output_below;
            }
            continue :action_switch .send_window_to_workspace_below;
        },
        .send_window_to_workspace_number => |number| {
            if (number == 0 or number > output.workspace_list.items.len or number - 1 == workspace_idx) return;
            const window_idx = workspace.focused_window_idx orelse return;
            _ = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                output_idx,
                number - 1,
            );
        },
        .focus_output_left => {
            const target = getOutputLeft(wm);
            try focusWindowToWorkspace(
                wm,
                null,
                target.index,
                null,
            );
        },
        .focus_output_right => {
            const target = getOutputRight(wm);
            try focusWindowToWorkspace(
                wm,
                null,
                target.index,
                null,
            );
        },
        .focus_output_above => {
            const target = getOutputAbove(wm);
            try focusWindowToWorkspace(
                wm,
                null,
                target.index,
                null,
            );
        },
        .focus_output_below => {
            const target = getOutputBelow(wm);
            try focusWindowToWorkspace(
                wm,
                null,
                target.index,
                null,
            );
        },
        .move_window_to_output_left => {
            const window_idx = workspace.focused_window_idx orelse return;
            const target = getOutputLeft(wm);
            const target_window_idx = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                target.index,
                target.output.focused_workspace_idx,
            );
            try focusWindowToWorkspace(
                wm,
                target_window_idx,
                target.index,
                target.output.focused_workspace_idx,
            );
        },
        .move_window_to_output_right => {
            const window_idx = workspace.focused_window_idx orelse return;
            const target = getOutputRight(wm);
            const target_window_idx = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                target.index,
                target.output.focused_workspace_idx,
            );
            try focusWindowToWorkspace(
                wm,
                target_window_idx,
                target.index,
                target.output.focused_workspace_idx,
            );
        },
        .move_window_to_output_above => {
            const window_idx = workspace.focused_window_idx orelse return;
            const target = getOutputAbove(wm);
            const target_window_idx = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                target.index,
                target.output.focused_workspace_idx,
            );
            try focusWindowToWorkspace(
                wm,
                target_window_idx,
                target.index,
                target.output.focused_workspace_idx,
            );
        },
        .move_window_to_output_below => {
            const window_idx = workspace.focused_window_idx orelse return;
            const target = getOutputBelow(wm);
            const target_window_idx = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                target.index,
                target.output.focused_workspace_idx,
            );
            try focusWindowToWorkspace(
                wm,
                target_window_idx,
                target.index,
                target.output.focused_workspace_idx,
            );
        },
        .send_window_to_output_left => {
            const window_idx = workspace.focused_window_idx orelse return;
            const target = getOutputLeft(wm);
            _ = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                target.index,
                target.output.focused_workspace_idx,
            );
        },
        .send_window_to_output_right => {
            const window_idx = workspace.focused_window_idx orelse return;
            const target = getOutputRight(wm);
            _ = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                target.index,
                target.output.focused_workspace_idx,
            );
        },
        .send_window_to_output_above => {
            const window_idx = workspace.focused_window_idx orelse return;
            const target = getOutputAbove(wm);
            _ = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                target.index,
                target.output.focused_workspace_idx,
            );
        },
        .send_window_to_output_below => {
            const window_idx = workspace.focused_window_idx orelse return;
            const target = getOutputBelow(wm);
            _ = try sendWindowToWorkspace(
                allocator,
                wm,
                window_idx,
                target.index,
                target.output.focused_workspace_idx,
            );
        },
        .exit => {
            wm.status = .exit;
            return;
        },
        .reload_config => {
            const old_config = wm.config;
            const new_config = config.load(allocator, io, environ_map) orelse return;

            wm.config = new_config;

            if (old_config) |cfg|
                std.zon.parse.free(wm.allocator, cfg);

            if (wm.getConfig().cursor) |cursor| {
                wm.river_seat.?.setXcursorTheme(cursor.theme, cursor.size);
            }
            layout.update(wm.output_list, wm.getConfig());

            wm.status = .setup_bindings;
            return;
        },
        .spawn => |command| {
            const pid = std.posix.system.fork();
            if (pid < 0) {
                return error.ForkFailed;
            } else if (pid == 0) {
                _ = std.process.spawn(io, .{ .argv = command }) catch |err| {
                    // basename, not the full argv[0]: commands are routinely
                    // absolute paths under $HOME, which puts the user's name in
                    // the log.
                    std.debug.print("Failed to spawn {s}: {}\n", .{
                        Io.Dir.path.basename(command[0]),
                        err,
                    });
                };
                std.process.exit(0);
            }
            _ = std.posix.system.waitpid(pid, null, 0);
            return;
        },
    }

    layout.update(wm.output_list, wm.getConfig());
    wm.status = .layout;
}

/// Exchange two windows, leaving the column structure where it is. `stacked`
/// describes a *position* in the chain rather than a property of the window
/// that happens to sit there, so swapping it along with the window would move
/// a column head into the middle of a column and split it. Pinning the flags
/// to their slots means windows move through a fixed arrangement of columns.
fn swapWindows(items: []types.Window, a_idx: usize, b_idx: usize) void {
    const a_stacked = items[a_idx].stacked;
    const b_stacked = items[b_idx].stacked;
    std.mem.swap(types.Window, &items[a_idx], &items[b_idx]);
    items[a_idx].stacked = a_stacked;
    items[b_idx].stacked = b_stacked;
}

// Move a window to a target workspace.
fn moveWindowToWorkspace(
    allocator: Allocator,
    window_idx: usize,
    workspace: *types.Workspace,
    target_workspace: *types.Workspace,
) !usize {
    workspace.detachFromColumn(window_idx);
    var window = workspace.window_list.orderedRemove(window_idx);
    // The column it belonged to does not exist on the target workspace.
    window.stacked = false;

    if (workspace.window_list.items.len == 0) {
        workspace.focused_window_idx = null;
    } else if (window_idx != 0) {
        workspace.focused_window_idx = window_idx - 1;
    }

    var target_window_idx: usize = 0;
    if (target_workspace.focused_window_idx) |idx|
        target_window_idx = target_workspace.columnEnd(idx);

    try target_workspace.window_list.insert(allocator, target_window_idx, window);
    target_workspace.focused_window_idx = target_window_idx;
    return target_window_idx;
}

// Sends a window to a workspace found on an output.
fn sendWindowToWorkspace(
    allocator: Allocator,
    wm: *types.WindowManager,
    window_idx: usize,
    target_output_idx: usize,
    target_workspace_idx: usize,
) !usize {
    const output_idx = wm.focused_output_idx orelse return 0;
    const output = &wm.output_list.items[output_idx];
    const workspace_idx = output.focused_workspace_idx;
    const workspace = &output.workspace_list.items[workspace_idx];

    // ensure the target output is available
    if (target_output_idx >= wm.output_list.items.len) return 0;
    const target_output = &wm.output_list.items[target_output_idx];

    // ensure the target workspace is available
    if (target_workspace_idx >= target_output.workspace_list.items.len) return 0;
    const target_workspace = &target_output.workspace_list.items[target_workspace_idx];

    // move the window to the target workspace
    const target_window_idx = try moveWindowToWorkspace(
        allocator,
        window_idx,
        workspace,
        target_workspace,
    );
    return target_window_idx;
}

// Sets the focus of an output, workspace, and optionally the window.
fn focusWindowToWorkspace(
    wm: *types.WindowManager,
    target_window_idx: ?usize,
    target_output_idx: usize,
    target_workspace_idx: ?usize,
) !void {
    const output_idx = wm.focused_output_idx orelse return;
    const output = &wm.output_list.items[output_idx];
    const workspace_idx = output.focused_workspace_idx;

    // ensure the target output is available
    if (target_output_idx >= wm.output_list.items.len) return;
    const target_output = &wm.output_list.items[target_output_idx];

    // ensure the target workspace is available
    const next_workspace_idx: usize = target_workspace_idx orelse target_output.focused_workspace_idx;
    if (next_workspace_idx >= target_output.workspace_list.items.len) return;
    const target_workspace = &target_output.workspace_list.items[next_workspace_idx];

    var next_window_idx: ?usize = target_window_idx orelse target_workspace.focused_window_idx;
    if (next_window_idx) |idx| {
        if (idx >= target_workspace.window_list.items.len) {
            // if the window index is out of bounds then select the last one
            next_window_idx = target_workspace.window_list.items.len - 1;
        }
    }

    // set the focus
    wm.focused_output_idx = target_output_idx;
    target_output.focused_workspace_idx = next_workspace_idx;
    target_workspace.focused_window_idx = next_window_idx;

    // set the previous
    wm.previous_workspace = .{
        .output_idx = output_idx,
        .workspace_idx = workspace_idx,
    };
}

// TargetOutput represents the next output to target.
const TargetOutput = struct {
    output: *types.Output,
    index: usize,
};

// Get the output above the currently focused output.
fn getOutputAbove(
    wm: *types.WindowManager,
) TargetOutput {
    const output_idx = wm.focused_output_idx orelse 0;
    const output = &wm.output_list.items[output_idx];

    for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
        const edge = target_output.rectangle.y + target_output.rectangle.height;
        if (edge != output.rectangle.y) continue;
        return .{
            .output = target_output,
            .index = target_output_idx,
        };
    }

    return .{
        .output = output,
        .index = output_idx,
    };
}

// Get the output below the currently focused output.
fn getOutputBelow(
    wm: *types.WindowManager,
) TargetOutput {
    const output_idx = wm.focused_output_idx orelse 0;
    const output = &wm.output_list.items[output_idx];

    for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
        const edge = output.rectangle.y + target_output.rectangle.height;
        if (edge != target_output.rectangle.y) continue;
        return .{
            .output = target_output,
            .index = target_output_idx,
        };
    }

    return .{
        .output = output,
        .index = output_idx,
    };
}

// Get the output left of the currently focused output.
fn getOutputLeft(
    wm: *types.WindowManager,
) TargetOutput {
    const output_idx = wm.focused_output_idx orelse 0;
    const output = &wm.output_list.items[output_idx];

    for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
        const edge = target_output.rectangle.x + target_output.rectangle.width;
        if (edge != output.rectangle.x) continue;
        return .{
            .output = target_output,
            .index = target_output_idx,
        };
    }

    return .{
        .output = output,
        .index = output_idx,
    };
}

// Get the output right of the currently focused output.
fn getOutputRight(
    wm: *types.WindowManager,
) TargetOutput {
    const output_idx = wm.focused_output_idx orelse 0;
    const output = &wm.output_list.items[output_idx];

    for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
        const edge = output.rectangle.x + target_output.rectangle.width;
        if (edge != target_output.rectangle.x) continue;
        return .{
            .output = target_output,
            .index = target_output_idx,
        };
    }

    return .{
        .output = output,
        .index = output_idx,
    };
}
