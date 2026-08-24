const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const wayland = @import("wayland");
const river = wayland.client.river;

const column = @import("column.zig");

pub const WindowManager = struct {
    allocator: Allocator,
    io: Io,
    environ_map: std.process.Environ.Map,
    registry: *wayland.client.wl.Registry,
    river_window_manager: ?*river.WindowManagerV1,
    river_xkb_bindings: ?*river.XkbBindingsV1,
    river_layer_shell: ?*river.LayerShellV1,
    river_seat: ?*river.SeatV1,
    output_list: std.ArrayList(Output),
    focused_output_idx: ?usize,
    previous_workspace: ?struct { output_idx: usize, workspace_idx: usize },
    status: Status,
    config: ?*Config,
    is_passthrough: bool = false,
    xkb_binding_list: std.ArrayList(struct {
        river_xkb_binding: *river.XkbBindingV1,
        action: KeybindingAction,
    }),
    pointer_binding_list: std.ArrayList(struct {
        river_pointer_binding: *river.PointerBindingV1,
        action: PointerAction,
    }),

    pub fn getConfig(self: *WindowManager) Config {
        return if (self.config) |cfg| cfg.* else .{};
    }

    pub fn deinit(self: *WindowManager) void {
        if (self.config) |cfg|
            std.zon.parse.free(self.allocator, cfg);

        self.xkb_binding_list.deinit(self.allocator);
        self.pointer_binding_list.deinit(self.allocator);

        for (self.output_list.items) |*output| {
            for (output.workspace_list.items) |*workspace| {
                workspace.window_list.deinit(self.allocator);
            }
            output.workspace_list.deinit(self.allocator);
        }
        self.output_list.deinit(self.allocator);

        self.registry.destroy();
    }
};

pub const Window = struct {
    river_window: *river.WindowV1,
    river_node: *river.NodeV1,
    proportion: f32,
    is_fullscreen: bool,
    is_closing: bool,
    is_floating: bool,
    /// Set when the rule that floated this window asked for `.client` sizing.
    /// Such a window keeps following the dimensions the client reports instead
    /// of being held at a fixed proportion of the output.
    float_client_size: bool,
    /// This window shares a column with the tiled window before it in the
    /// list, splitting that column's height rather than taking a slot of its
    /// own in the scroll chain. A column is therefore a run of consecutive
    /// tiled windows: a head with `stacked == false`, followed by its members.
    /// Floating windows belong to no column and are transparent to the run, so
    /// one sitting between two tiled windows does not split their column.
    stacked: bool,
    floating: Rectangle,
    current: Rectangle,
    start: ?Rectangle,
    finish: ?Rectangle,
};

pub const previousTiled = column.previousTiled;
pub const nextTiled = column.nextTiled;
pub const hasAbove = column.hasAbove;
pub const hasBelow = column.hasBelow;

/// The column arithmetic lives in `column.zig`, which knows nothing about
/// wayland and is unit-tested on its own. These are thin bindings of it to the
/// window list, so the tested code is the code that runs.
pub const Workspace = struct {
    window_list: std.ArrayList(Window) = .empty,
    focused_window_idx: ?usize = null,
    is_floating: bool = false,

    pub fn columnHead(self: Workspace, idx: usize) usize {
        return column.head(self.window_list.items, idx);
    }

    pub fn columnLen(self: Workspace, head_idx: usize) usize {
        return column.len(self.window_list.items, head_idx);
    }

    pub fn columnEnd(self: Workspace, idx: usize) usize {
        return column.end(self.window_list.items, idx);
    }

    pub fn previousColumn(self: Workspace, idx: usize) ?usize {
        return column.previous(self.window_list.items, idx);
    }

    pub fn nextColumn(self: Workspace, idx: usize) ?usize {
        return column.next(self.window_list.items, idx);
    }

    pub fn detachFromColumn(self: *Workspace, idx: usize) void {
        column.detach(self.window_list.items, idx);
    }

    /// Also rewrites `focused_window_idx` when repairing the list moves the
    /// window it names, so callers may set the focus first and normalise after.
    pub fn normalizeColumns(self: *Workspace) void {
        column.normalize(self.window_list.items, &self.focused_window_idx);
    }
};

pub const Output = struct {
    river_output: *river.OutputV1,
    river_layer_shell_output: ?*river.LayerShellOutputV1,
    workspace_list: std.ArrayList(Workspace) = .empty,
    focused_workspace_idx: usize,
    rectangle: Rectangle,
    non_exclusive: Rectangle,
    is_removed: bool,
};

pub const Rectangle = struct {
    width: i32,
    height: i32,
    x: i32,
    y: i32,
};

pub const Status = union(enum) {
    layout: void,
    animation: i64,
    pointer_action: PointerAction,
    setup_bindings: void,
    exit: void,
    none: void,
};

pub const Config = struct {
    vertical_gap: i32 = 9,
    horizontal_gap: i32 = 9,
    default_window_width: f32 = 0.5,
    center_focused_window: enum { never, always, single } = .never,
    no_csd: bool = true,
    dynamic_workspaces: bool = false,
    animation_duration: u32 = 200,
    border: Border = .{
        .width = 3,
        .focused_color = .{ .r = 141, .g = 214, .b = 0, .a = 1.0 },
        .unfocused_color = .{ .r = 160, .g = 160, .b = 160, .a = 1.0 },
    },
    cursor: ?struct { theme: [:0]const u8, size: u32 } = null,
    /// Proportion of the output a rule-floated window occupies. It is centred,
    /// so it reads as an overlay instead of filling a tile-shaped slot.
    float_width: f32 = 0.6,
    float_height: f32 = 0.6,
    window_rules: []const WindowRule = &.{},
    spawn_at_startup: []const []const []const u8 = &.{},
    keybindings: []const Keybinding = &default_keybindings,
    pointer_bindings: []const PointerBinding = &default_pointer_bindings,
};

/// How a floated window is sized. `proportion` uses float_width/float_height
/// of the output; `client` uses whatever dimensions the window picks for
/// itself, which is what a dialog that has a natural size wants.
pub const FloatSize = enum { proportion, client };

/// Matched against a window's app_id and title when it is first mapped. Both
/// patterns are optional and a null pattern is unconstrained, so a rule with
/// neither set is inert rather than applying to every window. When both are
/// set, both must match. Some windows set no app_id at all (hyprpolkitagent,
/// for one), which is why matching on title is supported.
pub const WindowRule = struct {
    app_id: ?[:0]const u8 = null,
    title: ?[:0]const u8 = null,
    float: bool = false,
    float_size: FloatSize = .proportion,

    pub fn isInert(self: WindowRule) bool {
        return self.app_id == null and self.title == null;
    }

    pub fn matchesAppId(self: WindowRule, app_id: ?[:0]const u8) bool {
        const pattern = self.app_id orelse return true;
        return std.mem.eql(u8, pattern, app_id orelse return false);
    }

    pub fn matchesTitle(self: WindowRule, title: ?[:0]const u8) bool {
        const pattern = self.title orelse return true;
        return std.mem.eql(u8, pattern, title orelse return false);
    }
};

const Border = struct { width: u8, focused_color: Color, unfocused_color: Color };

const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: f32,

    pub fn toRiverColor(self: Color) struct { r: u32, g: u32, b: u32, a: u32 } {
        var r: f32 = @floatFromInt(self.r);
        var g: f32 = @floatFromInt(self.g);
        var b: f32 = @floatFromInt(self.b);

        r = self.a * r / 255;
        g = self.a * g / 255;
        b = self.a * b / 255;

        const max: f64 = @floatFromInt(std.math.maxInt(u32));
        return .{
            .r = @trunc(r * max),
            .g = @trunc(g * max),
            .b = @trunc(b * max),
            .a = @trunc(self.a * max),
        };
    }
};

const Keybinding = struct {
    key: [:0]const u8,
    modifiers: river.SeatV1.Modifiers,
    action: KeybindingAction,
};

pub const KeybindingAction = union(enum) {
    close_window: void,
    toggle_fullscreen: void,
    toggle_maximize_column: void,
    toggle_passthrough: void,
    adjust_window_width: f32,
    set_window_width: f32,
    focus_window_left: void,
    focus_window_or_output_left: void,
    focus_window_right: void,
    focus_window_or_output_right: void,
    focus_window_up: void,
    focus_window_down: void,
    focus_window_or_workspace_up: void,
    focus_window_or_workspace_down: void,
    move_window_left: void,
    move_window_right: void,
    move_window_up: void,
    move_window_down: void,
    toggle_window_stacked: void,
    move_window_left_or_to_output_left: void,
    move_window_right_or_to_output_right: void,
    toggle_workspace_floating: void,
    focus_workspace_above: void,
    focus_workspace_below: void,
    focus_workspace_or_output_above: void,
    focus_workspace_or_output_below: void,
    focus_workspace_previous: void,
    focus_workspace_number: usize,
    move_window_to_workspace_above: void,
    move_window_to_workspace_below: void,
    move_window_to_workspace_or_output_above: void,
    move_window_to_workspace_or_output_below: void,
    move_window_to_workspace_number: usize,
    send_window_to_workspace_above: void,
    send_window_to_workspace_below: void,
    send_window_to_workspace_or_output_above: void,
    send_window_to_workspace_or_output_below: void,
    send_window_to_workspace_number: usize,
    focus_output_left: void,
    focus_output_right: void,
    focus_output_above: void,
    focus_output_below: void,
    move_window_to_output_left: void,
    move_window_to_output_right: void,
    move_window_to_output_above: void,
    move_window_to_output_below: void,
    send_window_to_output_left: void,
    send_window_to_output_right: void,
    send_window_to_output_above: void,
    send_window_to_output_below: void,
    exit: void,
    reload_config: void,
    spawn: []const []const u8,
};

const PointerBinding = struct {
    button: Button,
    modifiers: river.SeatV1.Modifiers,
    action: PointerAction,
};

const Button = enum(u32) {
    left = 0x110,
    right = 0x111,
    middle = 0x112,
};

const PointerAction = enum { move_window, resize_window };

pub const default_keybindings = [_]Keybinding{
    .{ .key = "q", .modifiers = .{ .mod4 = true }, .action = .close_window },
    .{ .key = "f", .modifiers = .{ .mod4 = true }, .action = .toggle_fullscreen },

    .{ .key = "minus", .modifiers = .{ .mod4 = true }, .action = .{ .adjust_window_width = -0.1 } },
    .{ .key = "equal", .modifiers = .{ .mod4 = true }, .action = .{ .adjust_window_width = 0.1 } },
    .{ .key = "BackSpace", .modifiers = .{ .mod4 = true }, .action = .{ .set_window_width = 0.5 } },

    .{ .key = "Left", .modifiers = .{ .mod4 = true }, .action = .focus_window_left },
    .{ .key = "Right", .modifiers = .{ .mod4 = true }, .action = .focus_window_right },
    .{ .key = "Left", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_left },
    .{ .key = "Right", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_right },

    .{ .key = "v", .modifiers = .{ .mod4 = true }, .action = .toggle_workspace_floating },

    .{ .key = "Up", .modifiers = .{ .mod4 = true }, .action = .focus_workspace_above },
    .{ .key = "Down", .modifiers = .{ .mod4 = true }, .action = .focus_workspace_below },
    .{ .key = "grave", .modifiers = .{ .mod4 = true }, .action = .focus_workspace_previous },

    .{ .key = "1", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 1 } },
    .{ .key = "2", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 2 } },
    .{ .key = "3", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 3 } },
    .{ .key = "4", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 4 } },
    .{ .key = "5", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 5 } },
    .{ .key = "6", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 6 } },
    .{ .key = "7", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 7 } },
    .{ .key = "8", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 8 } },
    .{ .key = "9", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 9 } },
    .{ .key = "0", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 10 } },

    .{ .key = "Up", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_to_workspace_above },
    .{ .key = "Down", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_to_workspace_below },

    .{ .key = "1", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 1 } },
    .{ .key = "2", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 2 } },
    .{ .key = "3", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 3 } },
    .{ .key = "4", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 4 } },
    .{ .key = "5", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 5 } },
    .{ .key = "6", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 6 } },
    .{ .key = "7", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 7 } },
    .{ .key = "8", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 8 } },
    .{ .key = "9", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 9 } },
    .{ .key = "0", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 10 } },

    .{ .key = "h", .modifiers = .{ .mod4 = true }, .action = .focus_output_left },
    .{ .key = "l", .modifiers = .{ .mod4 = true }, .action = .focus_output_right },
    .{ .key = "k", .modifiers = .{ .mod4 = true }, .action = .focus_output_above },
    .{ .key = "j", .modifiers = .{ .mod4 = true }, .action = .focus_output_below },

    .{ .key = "h", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_to_output_left },
    .{ .key = "l", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_to_output_right },
    .{ .key = "k", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_to_output_above },
    .{ .key = "j", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_to_output_below },

    .{ .key = "Escape", .modifiers = .{ .mod4 = true }, .action = .exit },
    .{ .key = "r", .modifiers = .{ .mod4 = true }, .action = .reload_config },

    .{ .key = "t", .modifiers = .{ .mod4 = true }, .action = .{ .spawn = &[_][]const u8{"alacritty"} } },

    .{
        .key = "XF86AudioRaiseVolume",
        .modifiers = .{},
        .action = .{ .spawn = &[_][]const u8{ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "0.05+", "--limit", "1.0" } },
    },
    .{
        .key = "XF86AudioLowerVolume",
        .modifiers = .{},
        .action = .{ .spawn = &[_][]const u8{ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "0.05-" } },
    },
    .{
        .key = "XF86AudioMute",
        .modifiers = .{},
        .action = .{ .spawn = &[_][]const u8{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle" } },
    },
    .{
        .key = "XF86AudioMicMute",
        .modifiers = .{},
        .action = .{ .spawn = &[_][]const u8{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle" } },
    },
};

const default_pointer_bindings = [_]PointerBinding{
    .{ .button = .left, .modifiers = .{ .mod4 = true }, .action = .move_window },
    .{ .button = .right, .modifiers = .{ .mod4 = true }, .action = .resize_window },
};
