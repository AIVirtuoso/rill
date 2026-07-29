const std = @import("std");
const Allocator = std.mem.Allocator;

const wayland = @import("wayland");
const river = wayland.client.river;

const layout = @import("layout.zig");
const types = @import("types.zig");

pub fn windowListener(
    river_window: *river.WindowV1,
    event: river.WindowV1.Event,
    wm: *types.WindowManager,
) void {
    const output_idx = wm.focused_output_idx orelse return;

    // Both events precede the first dimensions event, so rule state is always
    // complete before add() places the window. They may also fire again later
    // if the window changes its app_id or title, so each recomputes its whole
    // mask rather than only setting bits.
    if (event == .app_id or event == .title) {
        const entry = ruleState(wm, river_window) orelse return;

        const value: ?[:0]const u8 = switch (event) {
            .app_id => |ev| if (ev.app_id) |ptr| std.mem.span(ptr) else null,
            .title => |ev| if (ev.title) |ptr| std.mem.span(ptr) else null,
            else => unreachable,
        };

        var mask: u64 = 0;
        for (wm.getConfig().window_rules, 0..) |rule, idx| {
            if (idx >= layout.max_window_rules) break;
            const matched = switch (event) {
                .app_id => rule.matchesAppId(value),
                .title => rule.matchesTitle(value),
                else => unreachable,
            };
            if (matched) mask |= @as(u64, 1) << @intCast(idx);
        }

        switch (event) {
            .app_id => entry.app_id_mask = mask,
            .title => entry.title_mask = mask,
            else => unreachable,
        }
        return;
    }

    // Drop rule state for a window that closed before it was ever mapped, so a
    // recycled pointer can't inherit it. Mapped windows have no entry left.
    if (event == .closed) {
        for (layout.pending_rules.items, 0..) |entry, idx| {
            if (entry.river_window != river_window) continue;
            _ = layout.pending_rules.swapRemove(idx);
            break;
        }
    }

    if (event == .dimensions) {
        for (layout.pending_windows.items, 0..) |window, idx| {
            if (window != river_window) continue;

            const output = &wm.output_list.items[output_idx];
            // apply() proposes 0x0 for pending windows, which the protocol
            // defines as letting the window pick its own dimensions, so this
            // first event carries the size the client actually wants.
            add(
                wm.allocator,
                window,
                output,
                wm.getConfig(),
                event.dimensions.width,
                event.dimensions.height,
            ) catch |err| {
                std.debug.print("Failed to add window: {}\n", .{err});
                return;
            };
            _ = layout.pending_windows.swapRemove(idx);

            layout.update(wm.output_list, wm.getConfig());
            wm.status = .layout;
            wm.river_window_manager.?.manageDirty();
            return;
        }
    }

    for (wm.output_list.items) |*output| {
        for (&output.workspace_list) |*workspace| {
            const window_idx = workspace.focused_window_idx orelse continue;

            for (workspace.window_list.items, 0..) |*window, idx| {
                if (window.river_window != river_window) continue;

                switch (event) {
                    .closed => {
                        if (workspace.window_list.items.len == 1) {
                            workspace.focused_window_idx = null;
                        } else if (idx <= window_idx and window_idx != 0) {
                            workspace.focused_window_idx = window_idx - 1;
                        }

                        workspace.detachFromColumn(idx);
                        _ = workspace.window_list.orderedRemove(idx);
                        river_window.destroy();
                    },
                    .fullscreen_requested => {
                        if (wm.status != .none) return;
                        window.is_fullscreen = true;
                    },
                    .exit_fullscreen_requested => {
                        if (wm.status != .none) return;
                        window.is_fullscreen = false;
                    },
                    // A window that sizes itself may change size later, e.g. a
                    // dialog growing to fit its content. Follow it, otherwise
                    // the clip box in placeWindow cuts off the difference.
                    // Only once nothing is in flight: mid-animation the client
                    // is reporting sizes rill proposed for intermediate frames,
                    // and adopting those would drag the rect along with them.
                    .dimensions => |dimensions| {
                        if (!window.float_client_size) return;
                        if (window.is_fullscreen) return;
                        if (wm.status != .none) return;

                        const resized = layout.floatRectangleResize(
                            window.floating,
                            output.non_exclusive,
                            dimensions.width,
                            dimensions.height,
                            wm.getConfig(),
                        );
                        // Without this the proposal in the resulting layout
                        // pass echoes straight back as another dimensions
                        // event and the two bounce off each other forever.
                        if (std.meta.eql(resized, window.floating)) return;
                        window.floating = resized;
                    },
                    else => return,
                }

                layout.update(wm.output_list, wm.getConfig());
                wm.status = .layout;
                return;
            }
        }
    }
}

/// Rule state for a window, created on first use. A pattern that is null in a
/// rule is unconstrained, so its bit starts set and stays set unless a later
/// event clears it.
fn ruleState(
    wm: *types.WindowManager,
    river_window: *river.WindowV1,
) ?*layout.PendingRules {
    for (layout.pending_rules.items) |*entry| {
        if (entry.river_window == river_window) return entry;
    }

    var app_id_mask: u64 = 0;
    var title_mask: u64 = 0;
    for (wm.getConfig().window_rules, 0..) |rule, idx| {
        if (idx >= layout.max_window_rules) break;
        const bit = @as(u64, 1) << @intCast(idx);
        if (rule.app_id == null) app_id_mask |= bit;
        if (rule.title == null) title_mask |= bit;
    }

    layout.pending_rules.append(wm.allocator, .{
        .river_window = river_window,
        .app_id_mask = app_id_mask,
        .title_mask = title_mask,
    }) catch |err| {
        std.debug.print("Failed to track window rules: {}\n", .{err});
        return null;
    };
    return &layout.pending_rules.items[layout.pending_rules.items.len - 1];
}

fn add(
    allocator: Allocator,
    river_window: *river.WindowV1,
    output: *types.Output,
    config: types.Config,
    width: i32,
    height: i32,
) !void {
    var is_floating = false;
    var float_client_size = false;
    for (layout.pending_rules.items, 0..) |entry, idx| {
        if (entry.river_window != river_window) continue;

        const matched = entry.app_id_mask & entry.title_mask;
        for (config.window_rules, 0..) |rule, rule_idx| {
            if (rule_idx >= layout.max_window_rules) break;
            if (rule.isInert()) continue;
            if (matched & (@as(u64, 1) << @intCast(rule_idx)) == 0) continue;
            if (rule.float) {
                is_floating = true;
                if (rule.float_size == .client) float_client_size = true;
            }
        }

        _ = layout.pending_rules.swapRemove(idx);
        break;
    }

    const rectangle = if (!is_floating)
        layout.initialRectangle(output.non_exclusive, config)
    else if (float_client_size)
        layout.floatRectangleClient(output.non_exclusive, width, height, config)
    else
        layout.floatRectangle(output.non_exclusive, config);

    const window = types.Window{
        .river_window = river_window,
        .river_node = try river_window.getNode(),
        .proportion = config.default_window_width,
        .is_fullscreen = false,
        .is_closing = false,
        .is_floating = is_floating,
        .float_client_size = float_client_size,
        // A new window always opens as its own column; stacking is explicit.
        .stacked = false,
        .floating = rectangle,
        .current = rectangle,
        .start = null,
        .finish = null,
    };

    const workspace = &output.workspace_list[output.focused_workspace_idx];
    var window_idx: usize = 0;
    if (workspace.focused_window_idx) |idx| window_idx = workspace.columnEnd(idx);
    try workspace.window_list.insert(allocator, window_idx, window);
    workspace.focused_window_idx = window_idx;
}
