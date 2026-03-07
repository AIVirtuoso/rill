const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

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
    window_list: std.ArrayList(Window),
    focused_window_index: ?usize,
};

pub const Output = struct {
    river_output: *river.OutputV1,
    workspace_list: [10]Workspace,
    focused_workspace_index: usize,
    dimensions: Dimensions,
    non_exclusive: ?Dimensions,
};

pub const Dimensions = struct {
    width: i32,
    height: i32,
    x: i32,
    y: i32,
};

pub const Keybinding = struct {
    key: []const u8,
    modifiers: river.SeatV1.Modifiers,
    action: Action,
};

pub const Action = union(enum) {
    spawn: []const []const u8,
    reload_config: void,
    close_window: void,
    focus_window_left: void,
    focus_window_right: void,
    move_window_left: void,
    move_window_right: void,
    adjust_window_width: f32,
    toggle_fullscreen: void,
    focus_workspace: usize,
    move_window_to_workspace: usize,
    focus_output_left: void,
    focus_output_right: void,
    focus_output_up: void,
    focus_output_down: void,
};
