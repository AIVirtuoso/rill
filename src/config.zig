const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const keybind = @import("keybind.zig");

const Config = struct {
    inner_gap: i32,
    outer_gap: i32,
    window_width_proportion: f32,
    animation_duration: u32,
    border: struct { width: u8, focused_color: Color, unfocused_color: Color },
    spawn_at_startup: []const []const []const u8,
    keybinds: []keybind.Keybind,
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

        const max_32bit: f64 = @floatFromInt(std.math.maxInt(u32));

        return .{
            .r = @intFromFloat(r * max_32bit),
            .g = @intFromFloat(g * max_32bit),
            .b = @intFromFloat(b * max_32bit),
            .a = @intFromFloat(self.a * max_32bit),
        };
    }
};

pub fn loadConfig(allocator: std.mem.Allocator) void {
    const file_content = readConfig(allocator) orelse {
        std.debug.print("No config file loaded\n", .{});
        return;
    };

    config = std.zon.parse.fromSlice(Config, allocator, file_content, null, .{}) catch |err| {
        std.debug.print("Failed to parse config file: {}\n", .{err});
        std.debug.print("No config file loaded\n", .{});
        return;
    };
}

fn readConfig(allocator: std.mem.Allocator) ?[:0]u8 {
    xdg_config_home: {
        const xdg_config_home =
            std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch |err| {
                std.debug.print("Failed to read $XDG_CONFIG_HOME: {}\n", .{err});
                break :xdg_config_home;
            };
        const config_path =
            std.fs.path.join(allocator, &.{ xdg_config_home, "rill", "config.zon" }) catch |err| {
                std.debug.print("Failed to join paths: {}\n", .{err});
                break :xdg_config_home;
            };
        const file_content = std.fs.cwd().readFileAllocOptions(
            allocator,
            config_path,
            1024 * 1024,
            null,
            std.mem.Alignment.@"1",
            0,
        ) catch |err| {
            std.debug.print("Failed to read {s}: {}\n", .{ config_path, err });
            break :xdg_config_home;
        };
        std.debug.print("Loaded config file from {s}\n", .{config_path});
        return file_content;
    }

    home: {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| {
            std.debug.print("Failed to read $HOME: {}\n", .{err});
            break :home;
        };
        const config_path =
            std.fs.path.join(allocator, &.{ home, ".config", "rill", "config.zon" }) catch |err| {
                std.debug.print("Failed to join paths: {}\n", .{err});
                break :home;
            };
        const file_content = std.fs.cwd().readFileAllocOptions(
            allocator,
            config_path,
            1024 * 1024,
            null,
            std.mem.Alignment.@"1",
            0,
        ) catch |err| {
            std.debug.print("Failed to read {s}: {}\n", .{ config_path, err });
            break :home;
        };
        std.debug.print("Loaded config file from {s}\n", .{config_path});
        return file_content;
    }

    return null;
}

pub fn spawnAtStartup(allocator: std.mem.Allocator) void {
    for (config.spawn_at_startup) |command| {
        var child = std.process.Child.init(command, allocator);
        child.spawn() catch |err| {
            std.debug.print("Failed to spawn {s}: {}\n", .{ command[0], err });
        };
    }
}

pub var config: Config = .{
    .inner_gap = 15,
    .outer_gap = 12,
    .window_width_proportion = 0.5,
    .animation_duration = 150,
    .border = .{
        .width = 3,
        .focused_color = .{ .r = 141, .g = 214, .b = 0, .a = 1.0 },
        .unfocused_color = .{ .r = 204, .g = 204, .b = 204, .a = 1.0 },
    },
    .spawn_at_startup = &.{},
    .keybinds = &default_keybinds,
};

var default_keybinds = [_]keybind.Keybind{
    .{
        .key = "t",
        .modifier = .{ .mod4 = true },
        .action = .{ .spawn = &[_][]const u8{"alacritty"} },
    },
    .{
        .key = "XF86AudioRaiseVolume",
        .modifier = .{},
        .action = .{ .spawn = &[_][]const u8{ "wpctl", "set-volume", "--limit", "1.0", "@DEFAULT_AUDIO_SINK@", "0.05+" } },
    },
    .{
        .key = "XF86AudioLowerVolume",
        .modifier = .{},
        .action = .{ .spawn = &[_][]const u8{ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "0.05-" } },
    },
    .{
        .key = "XF86AudioMute",
        .modifier = .{},
        .action = .{ .spawn = &[_][]const u8{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle" } },
    },
    .{
        .key = "XF86AudioMicMute",
        .modifier = .{},
        .action = .{ .spawn = &[_][]const u8{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle" } },
    },

    .{
        .key = "q",
        .modifier = .{ .mod4 = true },
        .action = .close_window,
    },
    .{
        .key = "h",
        .modifier = .{ .mod4 = true },
        .action = .focus_window_left,
    },
    .{
        .key = "l",
        .modifier = .{ .mod4 = true },
        .action = .focus_window_right,
    },
    .{
        .key = "h",
        .modifier = .{ .mod4 = true, .shift = true },
        .action = .move_window_left,
    },
    .{
        .key = "l",
        .modifier = .{ .mod4 = true, .shift = true },
        .action = .move_window_right,
    },
    .{
        .key = "-",
        .modifier = .{ .mod4 = true },
        .action = .{ .adjust_window_width = -10 },
    },
    .{
        .key = "=",
        .modifier = .{ .mod4 = true },
        .action = .{ .adjust_window_width = 10 },
    },
    .{
        .key = "f",
        .modifier = .{ .mod4 = true },
        .action = .toggle_fullscreen,
    },

    .{
        .key = "1",
        .modifier = .{ .mod4 = true },
        .action = .{ .focus_workspace = 1 },
    },
    .{
        .key = "2",
        .modifier = .{ .mod4 = true },
        .action = .{ .focus_workspace = 2 },
    },
    .{
        .key = "3",
        .modifier = .{ .mod4 = true },
        .action = .{ .focus_workspace = 3 },
    },
    .{
        .key = "4",
        .modifier = .{ .mod4 = true },
        .action = .{ .focus_workspace = 4 },
    },
    .{
        .key = "5",
        .modifier = .{ .mod4 = true },
        .action = .{ .focus_workspace = 5 },
    },
    .{
        .key = "6",
        .modifier = .{ .mod4 = true },
        .action = .{ .focus_workspace = 6 },
    },
    .{
        .key = "7",
        .modifier = .{ .mod4 = true },
        .action = .{ .focus_workspace = 7 },
    },
    .{
        .key = "8",
        .modifier = .{ .mod4 = true },
        .action = .{ .focus_workspace = 8 },
    },
    .{
        .key = "9",
        .modifier = .{ .mod4 = true },
        .action = .{ .focus_workspace = 9 },
    },
    .{
        .key = "0",
        .modifier = .{ .mod4 = true },
        .action = .{ .focus_workspace = 10 },
    },

    .{
        .key = "1",
        .modifier = .{ .mod4 = true, .shift = true },
        .action = .{ .move_window_to_workspace = 1 },
    },
    .{
        .key = "2",
        .modifier = .{ .mod4 = true, .shift = true },
        .action = .{ .move_window_to_workspace = 2 },
    },
    .{
        .key = "3",
        .modifier = .{ .mod4 = true, .shift = true },
        .action = .{ .move_window_to_workspace = 3 },
    },
    .{
        .key = "4",
        .modifier = .{ .mod4 = true, .shift = true },
        .action = .{ .move_window_to_workspace = 4 },
    },
    .{
        .key = "5",
        .modifier = .{ .mod4 = true, .shift = true },
        .action = .{ .move_window_to_workspace = 5 },
    },
    .{
        .key = "6",
        .modifier = .{ .mod4 = true, .shift = true },
        .action = .{ .move_window_to_workspace = 6 },
    },
    .{
        .key = "7",
        .modifier = .{ .mod4 = true, .shift = true },
        .action = .{ .move_window_to_workspace = 7 },
    },
    .{
        .key = "8",
        .modifier = .{ .mod4 = true, .shift = true },
        .action = .{ .move_window_to_workspace = 8 },
    },
    .{
        .key = "9",
        .modifier = .{ .mod4 = true, .shift = true },
        .action = .{ .move_window_to_workspace = 9 },
    },
    .{
        .key = "0",
        .modifier = .{ .mod4 = true, .shift = true },
        .action = .{ .move_window_to_workspace = 10 },
    },

    .{
        .key = "r",
        .modifier = .{ .mod4 = true },
        .action = .reload_config,
    },
};
