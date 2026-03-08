const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;
const wl = wayland.client.wl;

pub const WindowManager = struct {
    gpa: std.heap.DebugAllocator(.{}) = .init,
    registry: *wl.Registry = undefined,
    river_window_manager: ?*river.WindowManagerV1 = null,
    river_xkb_bindings: ?*river.XkbBindingsV1 = null,
    river_layer_shell: ?*river.LayerShellV1 = null,
    river_seat: ?*river.SeatV1 = null,
    output_list: std.ArrayList(Output) = .empty,
    focused_output_idx: ?usize = null,
    previous_workspace: ?struct { output_idx: usize, workspace_idx: usize } = null,
    config: Config = .{},
    xkb_binding_list: std.ArrayList(*river.XkbBindingV1) = .empty,

    pub fn deinit(self: *WindowManager) void {
        const allocator = self.gpa.allocator();

        std.zon.parse.free(allocator, self.config);
        self.xkb_binding_list.deinit(allocator);

        for (self.output_list.items) |*output|
            for (&output.workspace_list) |*workspace|
                workspace.window_list.deinit(allocator);
        self.output_list.deinit(allocator);

        self.registry.destroy();
        _ = self.gpa.deinit();
    }
};

pub const Window = struct {
    river_window: *river.WindowV1,
    river_node: *river.NodeV1,
    proportion: f32,
    fullscreen: bool,
    width: i32,
    height: i32,
    x: i32,
    y: i32,
    target: ?Dimensions,
};

pub const Workspace = struct {
    window_list: std.ArrayList(Window) = .empty,
    focused_window_idx: ?usize = null,
};

pub const Output = struct {
    river_output: *river.OutputV1,
    workspace_list: [10]Workspace,
    focused_workspace_idx: usize,
    dimensions: Dimensions,
    non_exclusive: ?Dimensions,
};

pub const Dimensions = struct {
    width: i32,
    height: i32,
    x: i32,
    y: i32,
};

pub const Config = struct {
    vertical_gap: i32 = 9,
    horizontal_gap: i32 = 9,
    window_width_proportion: f32 = 0.5,
    center_focused_window: enum { never, always, single } = .never,
    no_csd: bool = true,
    animation_duration: u32 = 200,
    border: struct {
        width: u8 = 3,
        focused_color: Color = .{ .r = 141, .g = 214, .b = 0, .a = 1.0 },
        unfocused_color: Color = .{ .r = 160, .g = 160, .b = 160, .a = 1.0 },
    } = .{},
    spawn_at_startup: []const []const []const u8 = &.{},
    keybindings: []Keybinding = &default_keybindings,
};

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
            .r = @intFromFloat(r * max),
            .g = @intFromFloat(g * max),
            .b = @intFromFloat(b * max),
            .a = @intFromFloat(self.a * max),
        };
    }
};

pub const Keybinding = struct {
    key: []const u8,
    modifiers: river.SeatV1.Modifiers,
    action: Action,
    id: u32 = undefined,
};

pub const Action = union(enum) {
    spawn: []const []const u8,
    reload_config: void,
    exit: void,
    close_window: void,
    focus_window_left: void,
    focus_window_right: void,
    move_window_left: void,
    move_window_right: void,
    adjust_window_width: f32,
    toggle_fullscreen: void,
    focus_workspace: usize,
    move_window_to_workspace: usize,
    focus_previous_workspace: void,
    focus_output_left: void,
    focus_output_right: void,
    focus_output_up: void,
    focus_output_down: void,
};

var default_keybindings = [_]Keybinding{
    .{
        .key = "t",
        .modifiers = .{ .mod4 = true },
        .action = .{ .spawn = &[_][]const u8{"alacritty"} },
    },
    .{
        .key = "XF86AudioRaiseVolume",
        .modifiers = .{},
        .action = .{ .spawn = &[_][]const u8{ "wpctl", "set-volume", "--limit", "1.0", "@DEFAULT_AUDIO_SINK@", "0.05+" } },
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

    .{
        .key = "r",
        .modifiers = .{ .mod4 = true },
        .action = .reload_config,
    },
    .{
        .key = "Delete",
        .modifiers = .{ .ctrl = true, .mod1 = true },
        .action = .exit,
    },

    .{
        .key = "q",
        .modifiers = .{ .mod4 = true },
        .action = .close_window,
    },
    .{
        .key = "h",
        .modifiers = .{ .mod4 = true },
        .action = .focus_window_left,
    },
    .{
        .key = "l",
        .modifiers = .{ .mod4 = true },
        .action = .focus_window_right,
    },
    .{
        .key = "h",
        .modifiers = .{ .mod4 = true, .shift = true },
        .action = .move_window_left,
    },
    .{
        .key = "l",
        .modifiers = .{ .mod4 = true, .shift = true },
        .action = .move_window_right,
    },

    .{
        .key = "-",
        .modifiers = .{ .mod4 = true },
        .action = .{ .adjust_window_width = -0.1 },
    },
    .{
        .key = "=",
        .modifiers = .{ .mod4 = true },
        .action = .{ .adjust_window_width = 0.1 },
    },
    .{
        .key = "f",
        .modifiers = .{ .mod4 = true },
        .action = .toggle_fullscreen,
    },

    .{
        .key = "1",
        .modifiers = .{ .mod4 = true },
        .action = .{ .focus_workspace = 1 },
    },
    .{
        .key = "2",
        .modifiers = .{ .mod4 = true },
        .action = .{ .focus_workspace = 2 },
    },
    .{
        .key = "3",
        .modifiers = .{ .mod4 = true },
        .action = .{ .focus_workspace = 3 },
    },
    .{
        .key = "4",
        .modifiers = .{ .mod4 = true },
        .action = .{ .focus_workspace = 4 },
    },
    .{
        .key = "5",
        .modifiers = .{ .mod4 = true },
        .action = .{ .focus_workspace = 5 },
    },
    .{
        .key = "6",
        .modifiers = .{ .mod4 = true },
        .action = .{ .focus_workspace = 6 },
    },
    .{
        .key = "7",
        .modifiers = .{ .mod4 = true },
        .action = .{ .focus_workspace = 7 },
    },
    .{
        .key = "8",
        .modifiers = .{ .mod4 = true },
        .action = .{ .focus_workspace = 8 },
    },
    .{
        .key = "9",
        .modifiers = .{ .mod4 = true },
        .action = .{ .focus_workspace = 9 },
    },
    .{
        .key = "0",
        .modifiers = .{ .mod4 = true },
        .action = .{ .focus_workspace = 10 },
    },

    .{
        .key = "1",
        .modifiers = .{ .mod4 = true, .shift = true },
        .action = .{ .move_window_to_workspace = 1 },
    },
    .{
        .key = "2",
        .modifiers = .{ .mod4 = true, .shift = true },
        .action = .{ .move_window_to_workspace = 2 },
    },
    .{
        .key = "3",
        .modifiers = .{ .mod4 = true, .shift = true },
        .action = .{ .move_window_to_workspace = 3 },
    },
    .{
        .key = "4",
        .modifiers = .{ .mod4 = true, .shift = true },
        .action = .{ .move_window_to_workspace = 4 },
    },
    .{
        .key = "5",
        .modifiers = .{ .mod4 = true, .shift = true },
        .action = .{ .move_window_to_workspace = 5 },
    },
    .{
        .key = "6",
        .modifiers = .{ .mod4 = true, .shift = true },
        .action = .{ .move_window_to_workspace = 6 },
    },
    .{
        .key = "7",
        .modifiers = .{ .mod4 = true, .shift = true },
        .action = .{ .move_window_to_workspace = 7 },
    },
    .{
        .key = "8",
        .modifiers = .{ .mod4 = true, .shift = true },
        .action = .{ .move_window_to_workspace = 8 },
    },
    .{
        .key = "9",
        .modifiers = .{ .mod4 = true, .shift = true },
        .action = .{ .move_window_to_workspace = 9 },
    },
    .{
        .key = "0",
        .modifiers = .{ .mod4 = true, .shift = true },
        .action = .{ .move_window_to_workspace = 10 },
    },

    .{
        .key = "`",
        .modifiers = .{ .mod4 = true },
        .action = .focus_previous_workspace,
    },

    .{
        .key = "Left",
        .modifiers = .{ .mod4 = true },
        .action = .focus_output_left,
    },
    .{
        .key = "Right",
        .modifiers = .{ .mod4 = true },
        .action = .focus_output_right,
    },
    .{
        .key = "Up",
        .modifiers = .{ .mod4 = true },
        .action = .focus_output_up,
    },
    .{
        .key = "Down",
        .modifiers = .{ .mod4 = true },
        .action = .focus_output_down,
    },
};
