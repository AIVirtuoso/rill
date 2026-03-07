const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");

const Config = struct {
    vertical_gap: i32,
    horizontal_gap: i32,
    window_width_proportion: f32,
    center_focused_window: enum { never, always, single },
    no_csd: bool,
    animation_duration: u32,
    border: struct { width: u8, focused_color: Color, unfocused_color: Color },
    spawn_at_startup: []const []const []const u8,
    keybindings: []types.Keybinding,
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

fn findConfig(allocator: std.mem.Allocator) ?[]u8 {
    xdg_config_home: {
        const xdg_config_home =
            std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch |err| {
                std.debug.print("Failed to read $XDG_CONFIG_HOME: {}\n", .{err});
                break :xdg_config_home;
            };
        defer allocator.free(xdg_config_home);

        const path = std.fs.path.join(allocator, &.{
            xdg_config_home,
            "rill",
            "config.zon",
        }) catch |err| {
            std.debug.print("Failed to join paths: {}\n", .{err});
            break :xdg_config_home;
        };
        return path;
    }

    home: {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| {
            std.debug.print("Failed to read $HOME: {}\n", .{err});
            break :home;
        };
        defer allocator.free(home);

        const path = std.fs.path.join(allocator, &.{
            home,
            ".config",
            "rill",
            "config.zon",
        }) catch |err| {
            std.debug.print("Failed to join paths: {}\n", .{err});
            break :home;
        };
        return path;
    }

    std.debug.print("No config file found\n", .{});
    return null;
}

pub fn loadConfig(allocator: std.mem.Allocator) void {
    const path = findConfig(allocator) orelse return;
    defer allocator.free(path);

    const content = std.fs.cwd().readFileAllocOptions(
        allocator,
        path,
        1024 * 1024,
        null,
        std.mem.Alignment.@"1",
        0,
    ) catch |err| {
        std.debug.print("Failed to read {s}: {}\n", .{ path, err });
        return;
    };
    defer allocator.free(content);

    config = std.zon.parse.fromSlice(Config, allocator, content, null, .{}) catch |err| {
        std.debug.print("Failed to parse {s}: {}\n", .{ path, err });
        return;
    };
    std.debug.print("Loaded config file: {s}\n", .{path});
}

pub var config: Config = .{
    .vertical_gap = 9,
    .horizontal_gap = 9,
    .window_width_proportion = 0.5,
    .center_focused_window = .never,
    .no_csd = true,
    .animation_duration = 200,
    .border = .{
        .width = 3,
        .focused_color = .{ .r = 141, .g = 214, .b = 0, .a = 1.0 },
        .unfocused_color = .{ .r = 160, .g = 160, .b = 160, .a = 1.0 },
    },
    .spawn_at_startup = &.{},
    .keybindings = &default_keybindings,
};

var default_keybindings = [_]types.Keybinding{
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
