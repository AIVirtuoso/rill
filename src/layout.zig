const std = @import("std");
const Allocator = std.mem.Allocator;

const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");

const edges = river.WindowV1.Edges{
    .top = true,
    .bottom = true,
    .left = true,
    .right = true,
};

pub var pending_windows: std.ArrayList(*river.WindowV1) = .empty;

/// Per-window rule matching state, tracked between the app_id/title events and
/// the first dimensions event. Each mask holds one bit per configured rule,
/// set while that rule's corresponding pattern is satisfied; a rule applies
/// when its bit is set in both. Rules past the 64th are ignored. Drained by
/// window.add().
pub const max_window_rules = 64;

pub const PendingRules = struct {
    river_window: *river.WindowV1,
    app_id_mask: u64,
    title_mask: u64,
};

pub var pending_rules: std.ArrayList(PendingRules) = .empty;

pub fn update(output_list: std.ArrayList(types.Output), config: types.Config) void {
    for (output_list.items) |*output| {
        for (output.workspace_list.items, 0..) |workspace, workspace_idx| {
            const workspace_offset = @as(i32, @intCast(workspace_idx)) -
                @as(i32, @intCast(output.focused_workspace_idx));
            const y_offset = workspace_offset * output.rectangle.height;

            if (workspace.is_floating) {
                floatingLayout(workspace.window_list, output, y_offset);
                continue;
            }

            const focused_window_idx = workspace.focused_window_idx orelse continue;
            const focused_window = &workspace.window_list.items[focused_window_idx];
            var rectangle: types.Rectangle = undefined;

            // Rule-floated windows keep their own geometry and occupy no slot
            // in the scroll chain.
            var tiled_count: usize = 0;
            for (workspace.window_list.items) |*window| {
                if (!window.is_floating) {
                    tiled_count += 1;
                    continue;
                }
                window.start = window.current;
                window.finish = if (window.is_fullscreen)
                    output.rectangle
                else
                    window.floating;
                window.finish.?.y += y_offset;
            }

            const should_center = switch (config.center_focused_window) {
                .never => false,
                .always => true,
                .single => tiled_count == 1,
            };

            // The chain is anchored on the focused window, or on the nearest
            // tiled window when the focused one is floating.
            const anchor_idx = blk: {
                if (!focused_window.is_floating) break :blk focused_window_idx;

                var before = focused_window_idx;
                while (before > 0) {
                    before -= 1;
                    if (!workspace.window_list.items[before].is_floating) break :blk before;
                }
                var after = focused_window_idx + 1;
                while (after < workspace.window_list.items.len) : (after += 1) {
                    if (!workspace.window_list.items[after].is_floating) break :blk after;
                }
                break :blk null;
            } orelse continue;
            const anchor_window = &workspace.window_list.items[anchor_idx];

            focusedWindowLayout(
                anchor_window,
                &rectangle,
                output,
                config,
                y_offset,
                should_center,
            );
            anchor_window.finish = rectangle;

            rectangle.x += rectangle.width + config.horizontal_gap;
            for (workspace.window_list.items[anchor_idx + 1 ..]) |*window| {
                if (window.is_floating) continue;
                unfocusedWindowLayout(
                    window,
                    &rectangle,
                    output,
                    config,
                    y_offset,
                );
                window.finish = rectangle;
                rectangle.x += rectangle.width + config.horizontal_gap;
            }

            rectangle.x = anchor_window.finish.?.x;
            var window_idx = anchor_idx;
            while (window_idx > 0) {
                window_idx -= 1;
                const window = &workspace.window_list.items[window_idx];
                if (window.is_floating) continue;
                unfocusedWindowLayout(
                    window,
                    &rectangle,
                    output,
                    config,
                    y_offset,
                );
                rectangle.x -= config.horizontal_gap + rectangle.width;
                window.finish = rectangle;
            }

            if (!should_center) snapToEdge(
                workspace.window_list,
                output.non_exclusive,
                config.horizontal_gap,
            );
        }
    }
}

fn floatingLayout(
    window_list: std.ArrayList(types.Window),
    output: *types.Output,
    y_offset: i32,
) void {
    for (window_list.items) |*window| {
        if (window.is_fullscreen) {
            window.finish = output.rectangle;
        } else {
            window.finish = window.floating;
        }
        window.start = window.current;
        window.finish.?.y += y_offset;
    }
}

fn focusedWindowLayout(
    window: *types.Window,
    rectangle: *types.Rectangle,
    output: *types.Output,
    config: types.Config,
    y_offset: i32,
    should_center: bool,
) void {
    const non_exclusive = output.non_exclusive;
    const base_width: f32 = @floatFromInt(non_exclusive.width - config.horizontal_gap);
    const width_with_gap: i32 = @trunc(base_width * window.proportion);

    rectangle.* = .{
        .width = width_with_gap - config.horizontal_gap,
        .height = non_exclusive.height - 2 * config.vertical_gap,
        .x = window.current.x,
        .y = non_exclusive.y + config.vertical_gap + y_offset,
    };

    if (should_center) {
        rectangle.x = non_exclusive.x +
            @divTrunc(non_exclusive.width, 2) - @divTrunc(rectangle.width, 2);
    } else if (rectangle.x < non_exclusive.x + config.horizontal_gap) {
        rectangle.x = non_exclusive.x + config.horizontal_gap;
    } else if (rectangle.x + width_with_gap > non_exclusive.x + non_exclusive.width) {
        rectangle.x = @max(
            non_exclusive.x + non_exclusive.width - width_with_gap,
            non_exclusive.x + config.horizontal_gap,
        );
    }

    if (window.is_fullscreen) {
        rectangle.* = output.rectangle;
        rectangle.y += y_offset;
    }

    window.start = window.current;
}

fn unfocusedWindowLayout(
    window: *types.Window,
    rectangle: *types.Rectangle,
    output: *types.Output,
    config: types.Config,
    y_offset: i32,
) void {
    if (window.is_fullscreen) {
        rectangle.width = output.rectangle.width;
        rectangle.height = output.rectangle.height;
        rectangle.y = output.rectangle.y + y_offset;
    } else {
        const non_exclusive = output.non_exclusive;
        const base_width: f32 = @floatFromInt(non_exclusive.width - config.horizontal_gap);
        const width_with_gap: i32 = @trunc(base_width * window.proportion);

        rectangle.width = width_with_gap - config.horizontal_gap;
        rectangle.height = non_exclusive.height - 2 * config.vertical_gap;
        rectangle.y = non_exclusive.y + config.vertical_gap + y_offset;
    }
    window.start = window.current;
}

fn snapToEdge(
    window_list: std.ArrayList(types.Window),
    non_exclusive: types.Rectangle,
    gap: i32,
) void {
    // Floating windows are not part of the chain, so the edges are the first
    // and last tiled windows rather than the first and last in the list.
    var head_window: ?types.Window = null;
    var tail_window: ?types.Window = null;
    for (window_list.items) |window| {
        if (window.is_floating) continue;
        if (head_window == null) head_window = window;
        tail_window = window;
    }
    const head = (head_window orelse return).finish.?.x;

    var head_distance: ?i32 = null;
    const left = non_exclusive.x + gap;
    if (head > left) head_distance = head - left;

    var tail_distance: ?i32 = null;
    const tail = tail_window.?.finish.?.x + tail_window.?.finish.?.width;
    const right = non_exclusive.x + non_exclusive.width - gap;
    if (tail < right) tail_distance = @min(right - tail, left - head);

    for (window_list.items) |*window| {
        if (window.is_floating) continue;
        const x = &window.finish.?.x;
        if (head_distance) |distance| {
            x.* -= distance;
        } else if (tail_distance) |distance| {
            x.* += distance;
        }
    }
}

pub fn apply(
    allocator: Allocator,
    output_list: *std.ArrayList(types.Output),
    focused_output_idx: usize,
    config: types.Config,
    river_seat: *river.SeatV1,
) void {
    river_seat.clearFocus();

    for (pending_windows.items) |window| {
        if (config.no_csd) window.useSsd();
        window.setTiled(edges);
        window.hide();
        window.proposeDimensions(0, 0);
    }

    var output_idx = output_list.items.len;
    while (output_idx > 0) {
        output_idx -= 1;
        const output = &output_list.items[output_idx];

        if (output.is_removed) {
            for (output.workspace_list.items) |*workspace| {
                for (workspace.window_list.items) |window| {
                    window.river_window.close();
                }
                workspace.window_list.deinit(allocator);
            }
            _ = output_list.swapRemove(output_idx);
            continue;
        }

        for (output.workspace_list.items, 0..) |workspace, workspace_idx| {
            for (workspace.window_list.items, 0..) |window, window_idx| {
                window.river_window.exitFullscreen();

                const unfocused_color = config.border.unfocused_color.toRiverColor();
                window.river_window.setBorders(
                    edges,
                    config.border.width,
                    unfocused_color.r,
                    unfocused_color.g,
                    unfocused_color.b,
                    unfocused_color.a,
                );

                if (window.is_closing) window.river_window.close();

                if (output_idx != focused_output_idx) continue;
                if (workspace_idx != output.focused_workspace_idx) continue;
                if (window_idx != workspace.focused_window_idx) continue;

                const focused_color = config.border.focused_color.toRiverColor();
                window.river_window.setBorders(
                    edges,
                    config.border.width,
                    focused_color.r,
                    focused_color.g,
                    focused_color.b,
                    focused_color.a,
                );

                window.river_node.placeTop();
                river_seat.focusWindow(window.river_window);
            }
        }

        // if dynamic workspaces are enabled then we go through and remove any workspaces
        // currently with no windows.
        if (config.dynamic_workspaces) {
            // remove empty workspaces in reverse order
            var i = output.workspace_list.items.len;
            while (i > 0) : (i -= 1) {
                const workspace = output.workspace_list.items[i - 1];
                const window_count = workspace.window_list.items.len;
                if (window_count > 0) continue;
                if (output.focused_workspace_idx == i - 1) continue;

                // remove the empty workspace from the array
                _ = output.workspace_list.orderedRemove(i - 1);

                // make sure to keep track which workspace is focused
                if (i - 1 < output.focused_workspace_idx and output.focused_workspace_idx != 0) {
                    output.focused_workspace_idx -= 1;
                }
            }

            // always leave one empty workspace at the end
            const final_workspace = types.Workspace{
                .window_list = .empty,
                .focused_window_idx = null,
                .is_floating = false,
            };
            output.workspace_list.append(allocator, final_workspace) catch |err| {
                std.debug.print("could not add empty workspace for dynamic workspaces: {}\n", .{err});
            };
        }

        // A floating window overlaps tiled windows by design, so it has to be
        // raised even when it is not focused - the loop above only raises the
        // focused window, which would leave a floating window buried under the
        // windows it overlaps as soon as anything else takes focus. The focused
        // floating window is raised last so it stays on top of the others.
        const visible_workspace = &output.workspace_list.items[output.focused_workspace_idx];
        for (visible_workspace.window_list.items, 0..) |window, window_idx| {
            if (!window.is_floating) continue;
            if (visible_workspace.focused_window_idx == window_idx) continue;
            window.river_node.placeTop();
        }
        if (visible_workspace.focused_window_idx) |window_idx| {
            const window = visible_workspace.window_list.items[window_idx];
            if (window.is_floating) window.river_node.placeTop();
        }

        if (output_idx != focused_output_idx) continue;
        if (output.river_layer_shell_output) |layer_shell_output| {
            layer_shell_output.setDefault();
        }
    }
}

/// Geometry for a rule-floated window: centred on the output at a proportion
/// of the available area. Deliberately not `initialRectangle`, which is a
/// tile-shaped slot (half width, full height) and therefore indistinguishable
/// from a tiled window. `initialRectangle` still backs the per-workspace
/// floating mode, which is left as upstream had it.
pub fn floatRectangle(
    non_exclusive: types.Rectangle,
    config: types.Config,
) types.Rectangle {
    const available_width: f32 = @floatFromInt(non_exclusive.width);
    const available_height: f32 = @floatFromInt(non_exclusive.height);

    const width: i32 = @intFromFloat(available_width * config.float_width);
    const height: i32 = @intFromFloat(available_height * config.float_height);

    return .{
        .width = width,
        .height = height,
        .x = non_exclusive.x + @divTrunc(non_exclusive.width - width, 2),
        .y = non_exclusive.y + @divTrunc(non_exclusive.height - height, 2),
    };
}

/// Window rect for a content size the client chose itself. The dimensions
/// event reports *content* size, which excludes the borders that
/// `placeWindow` subtracts before proposing, so they have to be added back or
/// the window shrinks by 2*border on every round trip. Capped at the output,
/// since a clip box is the only thing rill can do with a window too big to fit.
fn clientSize(
    non_exclusive: types.Rectangle,
    width: i32,
    height: i32,
    config: types.Config,
) struct { width: i32, height: i32 } {
    const border: i32 = 2 * @as(i32, config.border.width);
    return .{
        .width = @min(@max(width + border, 1), non_exclusive.width),
        .height = @min(@max(height + border, 1), non_exclusive.height),
    };
}

/// Initial placement for a self-sizing floated window: its own size, centred.
pub fn floatRectangleClient(
    non_exclusive: types.Rectangle,
    width: i32,
    height: i32,
    config: types.Config,
) types.Rectangle {
    const size = clientSize(non_exclusive, width, height, config);
    return .{
        .width = size.width,
        .height = size.height,
        .x = non_exclusive.x + @divTrunc(non_exclusive.width - size.width, 2),
        .y = non_exclusive.y + @divTrunc(non_exclusive.height - size.height, 2),
    };
}

/// Re-size a self-sizing floated window that has already been placed. The
/// centre is preserved rather than re-centring on the output, so a window the
/// user has dragged somewhere stays where they put it when the client resizes
/// itself. The result is nudged back inside the output if it would overhang.
pub fn floatRectangleResize(
    current: types.Rectangle,
    non_exclusive: types.Rectangle,
    width: i32,
    height: i32,
    config: types.Config,
) types.Rectangle {
    const size = clientSize(non_exclusive, width, height, config);

    const center_x = current.x + @divTrunc(current.width, 2);
    const center_y = current.y + @divTrunc(current.height, 2);

    return .{
        .width = size.width,
        .height = size.height,
        .x = std.math.clamp(
            center_x - @divTrunc(size.width, 2),
            non_exclusive.x,
            non_exclusive.x + non_exclusive.width - size.width,
        ),
        .y = std.math.clamp(
            center_y - @divTrunc(size.height, 2),
            non_exclusive.y,
            non_exclusive.y + non_exclusive.height - size.height,
        ),
    };
}

pub fn initialRectangle(
    non_exclusive: types.Rectangle,
    config: types.Config,
) types.Rectangle {
    const base_width: f32 = @floatFromInt(non_exclusive.width - config.horizontal_gap);
    const width_with_gap: i32 = @trunc(base_width * config.default_window_width);
    return .{
        .width = width_with_gap - config.horizontal_gap,
        .height = non_exclusive.height - 2 * config.vertical_gap,
        .x = non_exclusive.x + non_exclusive.width - width_with_gap,
        .y = non_exclusive.y + config.vertical_gap,
    };
}
