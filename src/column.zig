//! Column arithmetic for the scroll chain.
//!
//! A column is a run of consecutive tiled windows: a head with `stacked`
//! clear, followed by its members with `stacked` set. The members divide the
//! head's slot vertically instead of taking slots of their own. Floating
//! windows belong to no column and are skipped, so one sitting between two
//! tiled windows does not split their column.
//!
//! Everything here is deliberately free of wayland types and takes a plain
//! slice, so it can be tested without a compositor or generated protocol
//! bindings: `zig test src/column.zig`. The window type only has to expose
//! `is_floating` and `stacked`.

const std = @import("std");

/// Nearest tiled window before `idx`.
pub fn previousTiled(items: anytype, idx: usize) ?usize {
    var i = idx;
    while (i > 0) {
        i -= 1;
        if (!items[i].is_floating) return i;
    }
    return null;
}

/// Nearest tiled window after `idx`.
pub fn nextTiled(items: anytype, idx: usize) ?usize {
    var i = idx + 1;
    while (i < items.len) : (i += 1) {
        if (!items[i].is_floating) return i;
    }
    return null;
}

/// Head of the column containing `idx`. A window that is `stacked` with no
/// tiled window before it is treated as its own head, so a list that has not
/// been normalised still lays out sensibly instead of looping forever.
pub fn head(items: anytype, idx: usize) usize {
    var i = idx;
    while (items[i].stacked) {
        i = previousTiled(items, i) orelse return i;
    }
    return i;
}

/// Number of windows sharing the column headed by `head_idx`.
pub fn len(items: anytype, head_idx: usize) usize {
    var count: usize = 1;
    var i = head_idx;
    while (nextTiled(items, i)) |j| {
        if (!items[j].stacked) break;
        count += 1;
        i = j;
    }
    return count;
}

/// Index one past the last member of the column containing `idx`: where a
/// window has to be inserted for it to start a new column. Landing anywhere
/// inside an existing column would make the members after the insertion point
/// adopt the newcomer as their head, silently splitting the column in two.
/// With nothing stacked this is just `idx + 1`.
pub fn end(items: anytype, idx: usize) usize {
    var i = head(items, idx);
    while (nextTiled(items, i)) |j| {
        if (!items[j].stacked) break;
        i = j;
    }
    return i + 1;
}

/// Head of the column before the one containing `idx`.
pub fn previous(items: anytype, idx: usize) ?usize {
    const before = previousTiled(items, head(items, idx)) orelse return null;
    return head(items, before);
}

/// Head of the column after the one containing `idx`.
pub fn next(items: anytype, idx: usize) ?usize {
    var i = head(items, idx);
    while (nextTiled(items, i)) |j| {
        if (!items[j].stacked) return j;
        i = j;
    }
    return null;
}

/// Detach the window at `idx` from its column, promoting the member below it
/// when it was the head. Call this *before* removing a window: without it the
/// orphaned members keep `stacked` set and are adopted by whatever column now
/// precedes them, so closing a column head would merge its contents into the
/// column on its left.
pub fn detach(items: anytype, idx: usize) void {
    if (items[idx].is_floating or items[idx].stacked) return;
    const next_idx = nextTiled(items, idx) orelse return;
    if (items[next_idx].stacked) items[next_idx].stacked = false;
}

/// Restore the three invariants the layout and the keybindings rely on: a
/// floating window is never a column member, the first tiled window is always
/// a head, and no floating window sits between two windows of the same column.
/// Cheap enough to call after any reordering rather than reasoning about which
/// swaps can break which invariant.
///
/// `focused_idx` is carried through because the third invariant moves windows:
/// it is rewritten to keep naming the same window, so callers can set the
/// focus before normalising and still be pointing at what they meant.
pub fn normalize(items: anytype, focused_idx: *?usize) void {
    var seen_tiled = false;
    for (items) |*window| {
        if (window.is_floating) {
            window.stacked = false;
            continue;
        }
        if (!seen_tiled) {
            window.stacked = false;
            seen_tiled = true;
        }
    }

    // A column is a run of consecutive tiled windows and the walks skip
    // floating ones, so a float whose *index* falls inside a run is invisible
    // to both `end` (which steps past it) and `head` (which resolves the tiled
    // window after it back to the head before it). Such a window cannot be
    // reached with focus_window_left or focus_window_right at all - only by
    // clicking it. Lifting it to just past the column restores contiguity
    // without disturbing the column: `stacked` travels with the tiled windows
    // here, because the run's composition is unchanged and only the float is
    // leaving it.
    var idx: usize = 0;
    while (idx < items.len) {
        if (!items[idx].is_floating) {
            idx += 1;
            continue;
        }

        var last = idx;
        while (nextTiled(items, last)) |next_idx| {
            if (!items[next_idx].stacked) break;
            last = next_idx;
        }
        if (last == idx) {
            idx += 1;
            continue;
        }

        std.mem.rotate(std.meta.Elem(@TypeOf(items)), items[idx .. last + 1], 1);
        if (focused_idx.*) |focused| {
            if (focused == idx) {
                focused_idx.* = last;
            } else if (focused > idx and focused <= last) {
                focused_idx.* = focused - 1;
            }
        }
        // `idx` is deliberately not advanced: the slot now holds whatever
        // followed the float, which may be another float embedded in the same
        // column. Every rotation moves one float strictly later and none ever
        // moves earlier, so this terminates.
    }
}

/// Whether the window at `idx` has another window above it inside its own
/// column. False for a head, which is already the top, and for a floating
/// window, which is in no column. This is what decides whether vertical
/// movement stays in the stack or falls through to the workspace above.
pub fn hasAbove(items: anytype, idx: usize) bool {
    return !items[idx].is_floating and items[idx].stacked;
}

/// Whether the window at `idx` has another window below it inside its own
/// column. The next tiled window starts a new column unless it is stacked.
pub fn hasBelow(items: anytype, idx: usize) bool {
    if (items[idx].is_floating) return false;
    const below = nextTiled(items, idx) orelse return false;
    return items[below].stacked;
}

/// Height of the next slot when `remaining` windows still have to fit into
/// `remaining_height`, with `gap` between each pair.
///
/// Recomputed from the space still unassigned on every step rather than taken
/// as a single `height / count`: that spreads the rounding error over the
/// members instead of accumulating it, and makes the last slot land exactly on
/// the bottom edge of the column rather than leaving a stray pixel.
pub fn slotHeight(remaining_height: i32, gap: i32, remaining: i32) i32 {
    return @divTrunc(remaining_height - gap * (remaining - 1), remaining);
}

// -- tests -------------------------------------------------------------------

const TestWindow = struct { is_floating: bool = false, stacked: bool = false };

/// Build a list from a compact spec, one character per window:
///   'h' tiled column head, 's' tiled stacked member, 'f' floating
fn build(comptime spec: []const u8) [spec.len]TestWindow {
    var items: [spec.len]TestWindow = undefined;
    for (spec, 0..) |c, i| {
        items[i] = switch (c) {
            'h' => .{},
            's' => .{ .stacked = true },
            'f' => .{ .is_floating = true },
            else => unreachable,
        };
    }
    return items;
}

test "a list with nothing stacked is one column per window" {
    var items = build("hhh");
    for (0..3) |i| {
        try std.testing.expectEqual(i, head(&items, i));
        try std.testing.expectEqual(@as(usize, 1), len(&items, i));
        try std.testing.expectEqual(i + 1, end(&items, i));
    }
    try std.testing.expectEqual(@as(?usize, 1), next(&items, 0));
    try std.testing.expectEqual(@as(?usize, null), next(&items, 2));
    try std.testing.expectEqual(@as(?usize, 1), previous(&items, 2));
    try std.testing.expectEqual(@as(?usize, null), previous(&items, 0));
}

test "members resolve to their head and are counted" {
    // column A = {0,1,2}, column B = {3}
    var items = build("hssh");
    for (0..3) |i| try std.testing.expectEqual(@as(usize, 0), head(&items, i));
    try std.testing.expectEqual(@as(usize, 3), head(&items, 3));
    try std.testing.expectEqual(@as(usize, 3), len(&items, 0));
    try std.testing.expectEqual(@as(usize, 1), len(&items, 3));
}

test "a new window inserts after the whole column, never inside it" {
    var items = build("hssh");
    // Focus anywhere in the first column: insertion point is past its members.
    for (0..3) |i| try std.testing.expectEqual(@as(usize, 3), end(&items, i));
    try std.testing.expectEqual(@as(usize, 4), end(&items, 3));
}

test "floating windows are transparent to a column" {
    // A floating window sits between two members of the same column.
    var items = build("hfsh");
    try std.testing.expectEqual(@as(usize, 0), head(&items, 2));
    try std.testing.expectEqual(@as(usize, 2), len(&items, 0));
    try std.testing.expectEqual(@as(usize, 3), end(&items, 0));
    // It is its own head, so it stays individually reachable.
    try std.testing.expectEqual(@as(usize, 1), head(&items, 1));
}

test "horizontal movement steps over a whole column" {
    var items = build("hssh");
    try std.testing.expectEqual(@as(?usize, 3), next(&items, 0));
    try std.testing.expectEqual(@as(?usize, 3), next(&items, 2));
    try std.testing.expectEqual(@as(?usize, 0), previous(&items, 3));
}

test "detaching a head promotes the member below it" {
    var items = build("hhss");
    // Column {1,2,3}; removing window 1 must promote 2, or 2 and 3 would be
    // adopted by the column at 0.
    detach(&items, 1);
    try std.testing.expect(!items[2].stacked);
    try std.testing.expect(items[3].stacked);
    // With window 1 gone, {2,3} is a column of its own.
    var after = build("hhs");
    try std.testing.expectEqual(@as(usize, 1), head(&after, 2));
    try std.testing.expectEqual(@as(usize, 2), len(&after, 1));
}

test "detaching a member leaves the column alone" {
    var items = build("hss");
    detach(&items, 1);
    try std.testing.expect(items[1].stacked);
    try std.testing.expect(items[2].stacked);
}

test "normalize repairs an orphaned member and a stacked floating window" {
    var items = build("shf");
    items[2].stacked = true;
    var focused: ?usize = null;
    normalize(&items, &focused);
    try std.testing.expect(!items[0].stacked); // first tiled window is a head
    try std.testing.expect(!items[2].stacked); // floating is never a member
}

/// What `focus_window_right` computes, so the reachability claim below is
/// tested against the arithmetic the keybinding actually runs rather than
/// against `next`, which walks the *layout's* column chain and ignores
/// floating windows by design.
fn focusRight(items: anytype, idx: usize) ?usize {
    const next_idx = end(items, idx);
    if (next_idx >= items.len) return null;
    return next_idx;
}

/// What `focus_window_left` computes.
fn focusLeft(items: anytype, idx: usize) ?usize {
    const head_idx = head(items, idx);
    if (head_idx == 0) return null;
    return head(items, head_idx - 1);
}

test "a floating window buried in a column is unreachable until normalized" {
    // "hfs": the float sits between a head and its member. Horizontal focus
    // steps over the whole column, and the column's indices straddle the
    // float, so neither direction can ever land on it.
    var items = build("hfs");
    // Both directions dead-end: right runs past the end of the list, and left
    // from the member resolves to the head, which is already the leftmost
    // column. Nothing ever names index 1.
    try std.testing.expectEqual(@as(?usize, null), focusRight(&items, 0));
    try std.testing.expectEqual(@as(?usize, null), focusLeft(&items, 2));

    var focused: ?usize = 1;
    normalize(&items, &focused);

    try std.testing.expect(items[2].is_floating);
    // The column survives the move intact: head, then its member.
    try std.testing.expect(!items[0].stacked);
    try std.testing.expect(items[1].stacked);
    try std.testing.expectEqual(@as(usize, 2), len(&items, 0));
    // And the float is reachable from both sides now.
    try std.testing.expectEqual(@as(?usize, 2), focusRight(&items, 0));
    try std.testing.expectEqual(@as(?usize, 0), focusLeft(&items, 2));
    // The focus followed the window it was naming.
    try std.testing.expectEqual(@as(?usize, 2), focused);
}

test "normalize lifts several floats out of one column" {
    // Two floats buried in a three-window column, which a single forward pass
    // would leave half-repaired.
    var items = build("hffss");
    var focused: ?usize = 3;
    normalize(&items, &focused);

    try std.testing.expectEqual(@as(usize, 3), len(&items, 0));
    for (0..3) |i| try std.testing.expect(!items[i].is_floating);
    for (3..5) |i| try std.testing.expect(items[i].is_floating);

    // Stepping right from the head visits both floats and then stops.
    try std.testing.expectEqual(@as(?usize, 3), focusRight(&items, 0));
    try std.testing.expectEqual(@as(?usize, 4), focusRight(&items, 3));
    try std.testing.expectEqual(@as(?usize, null), focusRight(&items, 4));
    // And stepping back gets to the column head from either of them.
    try std.testing.expectEqual(@as(?usize, 3), focusLeft(&items, 4));
    try std.testing.expectEqual(@as(?usize, 0), focusLeft(&items, 3));

    // Focus was on the first stacked member, which moved down two slots.
    try std.testing.expectEqual(@as(?usize, 1), focused);
}

test "normalize leaves a float that is not buried exactly where it is" {
    // Between two columns, and after the last one: both are legal positions.
    var items = build("hsfhf");
    var focused: ?usize = 2;
    const before = items;
    normalize(&items, &focused);
    try std.testing.expectEqualSlices(TestWindow, &before, &items);
    try std.testing.expectEqual(@as(?usize, 2), focused);
}

test "vertical movement falls through only at the ends of a column" {
    // column A = {0,1,2}, column B = {3}
    var items = build("hssh");

    // Top member: nothing above, so up leaves the workspace; down stays.
    try std.testing.expect(!hasAbove(&items, 0));
    try std.testing.expect(hasBelow(&items, 0));
    // Middle member: stays in the column both ways.
    try std.testing.expect(hasAbove(&items, 1));
    try std.testing.expect(hasBelow(&items, 1));
    // Bottom member: down leaves the workspace.
    try std.testing.expect(hasAbove(&items, 2));
    try std.testing.expect(!hasBelow(&items, 2));
    // A column of one falls through in both directions, which is what makes
    // this safe to bind over plain workspace switching.
    try std.testing.expect(!hasAbove(&items, 3));
    try std.testing.expect(!hasBelow(&items, 3));
}

test "an unstacked workspace always falls through" {
    var items = build("hhh");
    for (0..3) |i| {
        try std.testing.expect(!hasAbove(&items, i));
        try std.testing.expect(!hasBelow(&items, i));
    }
}

test "a floating window never traps vertical movement" {
    // Floating window between two members of one column.
    var items = build("hfsh");
    try std.testing.expect(!hasAbove(&items, 1));
    try std.testing.expect(!hasBelow(&items, 1));
    // ...and it does not hide the member below from the head.
    try std.testing.expect(hasBelow(&items, 0));
}

test "a split column tiles its slot exactly, whatever the rounding" {
    // The property that matters: the members plus the gaps between them fill
    // the column exactly -- no overlap, no stray pixel at the bottom.
    const heights = [_]i32{ 1080, 1081, 1000, 997, 100 };
    const gaps = [_]i32{ 0, 5, 8, 13 };
    const counts = [_]i32{ 2, 3, 4, 7 };

    for (heights) |total| {
        for (gaps) |gap| {
            for (counts) |count| {
                if (total < count * (gap + 1)) continue;

                var y: i32 = 0;
                var placed: i32 = 0;
                while (placed < count) : (placed += 1) {
                    const remaining = count - placed;
                    const height = slotHeight(total - y, gap, remaining);
                    try std.testing.expect(height > 0);
                    y += height;
                    if (placed + 1 < count) y += gap;
                }
                try std.testing.expectEqual(total, y);
            }
        }
    }
}

test "head terminates on an unnormalised list" {
    // Leading member with nothing before it: must resolve to itself, not loop.
    var items = build("ss");
    try std.testing.expectEqual(@as(usize, 0), head(&items, 0));
    try std.testing.expectEqual(@as(usize, 0), head(&items, 1));
}
