//! Geometry for floating windows.
//!
//! A tiled window's rectangle is recomputed from its output on every layout
//! pass, so it can never be stale. A floating one is stored instead — it has
//! to be, or a drag would be undone by the next pass — and it is stored in the
//! *global* coordinate space that `Output.rectangle` lives in. Everything that
//! can invalidate such a rectangle therefore has to be handled explicitly, and
//! `fitted` is what handles it.
//!
//! Like `column.zig` this imports no wayland types and takes plain rectangles,
//! so it runs without a compositor or generated protocol bindings:
//! `zig test src/float.zig`. A rectangle only has to expose `width`, `height`,
//! `x` and `y`. `layout.zig` keeps the thin wrappers that unpack `Config`.

const std = @import("std");

/// A window occupying none of the output cannot be seen, and one larger than
/// the output can only be clipped, so a proportion outside this range
/// describes nothing that can be drawn.
pub const min_proportion: f32 = 0.05;
pub const max_proportion: f32 = 1.0;

/// Clamped rather than rejected. The value arrives from a hand-written config,
/// and rejecting the file means falling back to the built-in defaults, i.e.
/// losing every keybinding over a mistyped float — a far worse outcome than a
/// window of the nearest usable size. `config.zig` reports the correction.
///
/// NaN maps to `max_proportion`: `@min`/`@max` return the non-NaN operand, so
/// the clamp collapses to the upper bound. That matters because a NaN reaching
/// `@intFromFloat` is illegal behaviour, not merely a strange size.
pub fn clampProportion(proportion: f32) f32 {
    return std.math.clamp(proportion, min_proportion, max_proportion);
}

fn centred(bounds: anytype, width: i32, height: i32) @TypeOf(bounds) {
    return .{
        .width = width,
        .height = height,
        .x = bounds.x + @divTrunc(bounds.width - width, 2),
        .y = bounds.y + @divTrunc(bounds.height - height, 2),
    };
}

/// Geometry for a rule-floated window: centred on the output at a proportion
/// of the available area. Deliberately not a tile-shaped slot (half width,
/// full height), which would be pixel-identical to a tiled window and make the
/// feature look broken even when it works.
pub fn proportional(
    bounds: anytype,
    width_proportion: f32,
    height_proportion: f32,
) @TypeOf(bounds) {
    const available_width: f32 = @floatFromInt(bounds.width);
    const available_height: f32 = @floatFromInt(bounds.height);

    const width: i32 = @intFromFloat(available_width * clampProportion(width_proportion));
    const height: i32 = @intFromFloat(available_height * clampProportion(height_proportion));

    return centred(bounds, width, height);
}

/// Window size for a content size the client chose itself. The dimensions
/// event reports *content* size, which excludes the borders that the layout
/// subtracts again before proposing, so they have to be added back or the
/// window shrinks by 2*border on every round trip. Capped at the output, since
/// a clip box is the only thing rill can do with a window too big to fit.
pub fn clientSize(
    bounds: anytype,
    width: i32,
    height: i32,
    border: i32,
) struct { width: i32, height: i32 } {
    const total = 2 * border;
    return .{
        .width = @min(@max(width + total, 1), bounds.width),
        .height = @min(@max(height + total, 1), bounds.height),
    };
}

/// Initial placement for a self-sizing floated window: its own size, centred.
pub fn clientRectangle(
    bounds: anytype,
    width: i32,
    height: i32,
    border: i32,
) @TypeOf(bounds) {
    const size = clientSize(bounds, width, height, border);
    return centred(bounds, size.width, size.height);
}

/// Re-size a self-sizing floated window that has already been placed. The
/// centre is preserved rather than re-centring on the output, so a window the
/// user has dragged somewhere stays where they put it when the client resizes
/// itself. The result is nudged back inside the output if it would overhang.
pub fn resized(
    current: anytype,
    bounds: @TypeOf(current),
    width: i32,
    height: i32,
    border: i32,
) @TypeOf(current) {
    const size = clientSize(bounds, width, height, border);

    const center_x = current.x + @divTrunc(current.width, 2);
    const center_y = current.y + @divTrunc(current.height, 2);

    return .{
        .width = size.width,
        .height = size.height,
        .x = std.math.clamp(
            center_x - @divTrunc(size.width, 2),
            bounds.x,
            bounds.x + bounds.width - size.width,
        ),
        .y = std.math.clamp(
            center_y - @divTrunc(size.height, 2),
            bounds.y,
            bounds.y + bounds.height - size.height,
        ),
    };
}

/// Re-anchor a stored floating rectangle onto the output that is about to draw
/// it. Sending a floating window to another output moves it in the window
/// list, but its rectangle is in global coordinates and nothing recomputes it,
/// so without this the window keeps being drawn over the output it came from.
/// An output that changes resolution, or grows a bar, invalidates the
/// rectangle the same way.
///
/// A rectangle that still overlaps is only nudged back inside, which leaves a
/// window the user dragged towards an edge roughly where they left it. One
/// that overlaps nothing came from somewhere else entirely and is re-centred:
/// clamping it would pin it to whichever edge it happened to approach from.
pub fn fitted(current: anytype, bounds: @TypeOf(current)) @TypeOf(current) {
    const width = @min(@max(current.width, 1), bounds.width);
    const height = @min(@max(current.height, 1), bounds.height);

    const overlaps = current.x < bounds.x + bounds.width and
        current.x + width > bounds.x and
        current.y < bounds.y + bounds.height and
        current.y + height > bounds.y;
    if (!overlaps) return centred(bounds, width, height);

    return .{
        .width = width,
        .height = height,
        .x = std.math.clamp(current.x, bounds.x, bounds.x + bounds.width - width),
        .y = std.math.clamp(current.y, bounds.y, bounds.y + bounds.height - height),
    };
}

// -- tests -------------------------------------------------------------------

const Rectangle = struct { width: i32, height: i32, x: i32, y: i32 };

/// Two outputs side by side, as on the machine this was written for: the
/// second one starts where the first ends, so a rectangle belonging to it is
/// entirely outside the first.
const left_output: Rectangle = .{ .width = 1920, .height = 1080, .x = 0, .y = 0 };
const right_output: Rectangle = .{ .width = 1280, .height = 720, .x = 1920, .y = 0 };

test "a proportional rectangle is centred at the requested fraction" {
    const rectangle = proportional(left_output, 0.5, 0.5);
    try std.testing.expectEqual(Rectangle{
        .width = 960,
        .height = 540,
        .x = 480,
        .y = 270,
    }, rectangle);
}

test "a proportion outside the usable range is clamped, never used raw" {
    try std.testing.expectEqual(max_proportion, clampProportion(4.0));
    try std.testing.expectEqual(min_proportion, clampProportion(-1.0));
    try std.testing.expectEqual(min_proportion, clampProportion(0.0));
    // NaN would be illegal behaviour at @intFromFloat rather than just odd.
    try std.testing.expectEqual(max_proportion, clampProportion(std.math.nan(f32)));

    // A clamped proportion still yields a rectangle on the output.
    const rectangle = proportional(left_output, 4.0, -1.0);
    try std.testing.expectEqual(@as(i32, 1920), rectangle.width);
    try std.testing.expectEqual(@as(i32, 0), rectangle.x);
    try std.testing.expect(rectangle.height > 0);
    try std.testing.expect(rectangle.y > 0);
}

test "a client-sized rectangle adds both borders back and caps at the output" {
    // The client reports content size; the window is that plus 2*border.
    const rectangle = clientRectangle(left_output, 400, 300, 3);
    try std.testing.expectEqual(@as(i32, 406), rectangle.width);
    try std.testing.expectEqual(@as(i32, 306), rectangle.height);
    try std.testing.expectEqual(@as(i32, 757), rectangle.x);

    // A client asking for more than the output gets the output, not more.
    const capped = clientRectangle(left_output, 4000, 4000, 3);
    try std.testing.expectEqual(@as(i32, 1920), capped.width);
    try std.testing.expectEqual(@as(i32, 1080), capped.height);
}

test "resizing preserves the centre and stays on the output" {
    const dragged: Rectangle = .{ .width = 400, .height = 300, .x = 100, .y = 100 };
    const grown = resized(dragged, left_output, 594, 494, 3);
    // Centre was (300, 250); the window grew by 200 on each axis.
    try std.testing.expectEqual(@as(i32, 600), grown.width);
    try std.testing.expectEqual(@as(i32, 0), grown.x);
    try std.testing.expectEqual(@as(i32, 500), grown.height);
    try std.testing.expectEqual(@as(i32, 0), grown.y);

    // A window against the right edge is pushed back in rather than off.
    const at_edge: Rectangle = .{ .width = 400, .height = 300, .x = 1500, .y = 100 };
    const widened = resized(at_edge, left_output, 794, 294, 3);
    try std.testing.expectEqual(@as(i32, 1120), widened.x);
    try std.testing.expectEqual(@as(i32, 1920), widened.x + widened.width);
}

test "a rectangle from another output is re-centred on the one drawing it" {
    // The exact case of sending a floating window to the next output: without
    // this the window keeps its old x and is drawn over the output it left.
    const on_left = proportional(left_output, 0.6, 0.6);
    const moved = fitted(on_left, right_output);

    try std.testing.expect(moved.x >= right_output.x);
    try std.testing.expectEqual(
        @as(i32, right_output.x + right_output.width),
        @max(moved.x + moved.width, right_output.x + right_output.width),
    );
    // Size is kept, since it still fits; only the anchor changes.
    try std.testing.expectEqual(@as(i32, 1152), moved.width);
    try std.testing.expectEqual(@as(i32, 648), moved.height);
    try std.testing.expectEqual(@as(i32, 1984), moved.x);

    // One that no longer fits is capped to the smaller output as well.
    const tall = fitted(proportional(left_output, 0.9, 0.9), right_output);
    try std.testing.expectEqual(@as(i32, 1280), tall.width);
    try std.testing.expectEqual(@as(i32, 720), tall.height);
    try std.testing.expectEqual(@as(i32, 1920), tall.x);
}

test "a rectangle that still overlaps is nudged, not re-centred" {
    // A window dragged against the left edge, then the output loses width to
    // a bar on the right: it must stay where the user put it.
    const dragged: Rectangle = .{ .width = 400, .height = 300, .x = 20, .y = 40 };
    const narrowed: Rectangle = .{ .width = 300, .height = 1080, .x = 0, .y = 0 };
    const nudged = fitted(dragged, narrowed);

    try std.testing.expectEqual(@as(i32, 300), nudged.width);
    try std.testing.expectEqual(@as(i32, 0), nudged.x);
    try std.testing.expectEqual(@as(i32, 40), nudged.y); // untouched
}

test "a rectangle that already fits is left exactly alone" {
    const rectangle = proportional(left_output, 0.6, 0.6);
    try std.testing.expectEqual(rectangle, fitted(rectangle, left_output));

    const dragged: Rectangle = .{ .width = 400, .height = 300, .x = 17, .y = 23 };
    try std.testing.expectEqual(dragged, fitted(dragged, left_output));
}

test "fitting is idempotent, so repeating it every layout pass is free" {
    const cases = [_]Rectangle{
        .{ .width = 400, .height = 300, .x = 5000, .y = 5000 },
        .{ .width = 400, .height = 300, .x = -200, .y = -200 },
        .{ .width = 9000, .height = 9000, .x = 0, .y = 0 },
        .{ .width = 1, .height = 1, .x = 1919, .y = 1079 },
    };
    for (cases) |case| {
        const once = fitted(case, left_output);
        try std.testing.expectEqual(once, fitted(once, left_output));
        try std.testing.expect(once.x >= left_output.x);
        try std.testing.expect(once.y >= left_output.y);
        try std.testing.expect(once.x + once.width <= left_output.x + left_output.width);
        try std.testing.expect(once.y + once.height <= left_output.y + left_output.height);
    }
}
