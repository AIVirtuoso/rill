const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

pub const WindowManager = struct {
    gpa: std.heap.DebugAllocator(.{}) = .init,
    registry: *wayland.client.wl.Registry = undefined,
    river_window_manager: ?*river.WindowManagerV1 = null,
    river_xkb_bindings: ?*river.XkbBindingsV1 = null,
    river_layer_shell: ?*river.LayerShellV1 = null,
    river_seat: ?*river.SeatV1 = null,
    output_list: std.ArrayList(Output) = .empty,
    focused_output_idx: ?usize = null,
    previous_workspace: ?struct { output_idx: usize, workspace_idx: usize } = null,
    config: Config = undefined,
    xkb_binding_list: std.ArrayList(struct {
        river_xkb_binding: *river.XkbBindingV1,
        keybinding: Keybinding,
    }) = .empty,

    pub fn deinit(self: *WindowManager, config_is_parsed: bool) void {
        const allocator = self.gpa.allocator();

        if (config_is_parsed) std.zon.parse.free(allocator, self.config);
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
    is_fullscreen: bool,
    rectangle: Rectangle,
    start: ?Rectangle,
    finish: ?Rectangle,
};

pub const Workspace = struct {
    window_list: std.ArrayList(Window) = .empty,
    focused_window_idx: ?usize = null,
};

pub const Output = struct {
    river_output: *river.OutputV1,
    river_layer_shell_output: ?*river.LayerShellOutputV1,
    workspace_list: [10]Workspace,
    focused_workspace_idx: usize,
    rectangle: Rectangle,
    non_exclusive: ?Rectangle,
};

pub const Rectangle = struct {
    width: i32,
    height: i32,
    x: i32,
    y: i32,
};

pub const Config = struct {
    vertical_gap: i32,
    horizontal_gap: i32,
    default_window_width: f32,
    center_focused_window: enum { never, always, single },
    no_csd: bool,
    animation_duration: u32,
    border: struct { width: u8, focused_color: Color, unfocused_color: Color },
    spawn_at_startup: []const []const []const u8,
    keybindings: []const Keybinding,
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
    key: [:0]const u8,
    modifiers: river.SeatV1.Modifiers,
    action: Action,
};

pub const Action = union(enum) {
    close_window: void,
    toggle_fullscreen: void,
    adjust_window_width: f32,
    set_window_width: f32,
    focus_window_left: void,
    focus_window_right: void,
    move_window_left: void,
    move_window_right: void,
    focus_workspace_above: void,
    focus_workspace_below: void,
    focus_workspace_previous: void,
    focus_workspace_number: usize,
    move_window_to_workspace_above: void,
    move_window_to_workspace_below: void,
    move_window_to_workspace_number: usize,
    focus_output_left: void,
    focus_output_right: void,
    focus_output_above: void,
    focus_output_below: void,
    move_window_to_output_left: void,
    move_window_to_output_right: void,
    move_window_to_output_above: void,
    move_window_to_output_below: void,
    exit: void,
    reload_config: void,
    spawn: []const []const u8,
};
