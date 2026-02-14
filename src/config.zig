const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;

const keybind = @import("keybind.zig");

const Config = struct {
    window_width_proportion: f32,
    keybinds: []keybind.Keybind,
};

pub fn loadConfig(allocator: std.mem.Allocator) void {
    const file_content = readConfig(allocator) orelse {
        std.debug.print("No config file loaded!\n", .{});
        return;
    };

    config = std.zon.parse.fromSlice(Config, allocator, file_content, null, .{}) catch |err| {
        std.debug.print("Failed to parse config file: {}\n", .{err});
        return;
    };
}

fn readConfig(allocator: std.mem.Allocator) ?[:0]u8 {
    xdg_config_home: {
        const xdg_config_home = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch |err| {
            std.debug.print("Failed to read $XDG_CONFIG_HOME: {}\n", .{err});
            break :xdg_config_home;
        };
        const config_path = std.fs.path.join(allocator, &.{ xdg_config_home, "rill", "config.zon" }) catch |err| {
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
        const config_path = std.fs.path.join(allocator, &.{ home, ".config", "rill", "config.zon" }) catch |err| {
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

    etc: {
        const config_path = std.fs.path.join(allocator, &.{ "/", "etc", "rill", "config.zon" }) catch |err| {
            std.debug.print("Failed to join paths: {}\n", .{err});
            break :etc;
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
            break :etc;
        };
        std.debug.print("Loaded config file from {s}\n", .{config_path});
        return file_content;
    }

    return null;
}

pub var config: Config = .{ .window_width_proportion = 0.5, .keybinds = &default_keybinds };

var default_keybinds = [_]keybind.Keybind{
    .{
        .keysym = 0x0074,
        .modifier = .{ .mod4 = true },
        .action = .{ .spawn = &[_][]const u8{"alacritty"} },
    },
    .{
        .keysym = 0xff51,
        .modifier = .{ .mod4 = true },
        .action = .focus_window_left,
    },
    .{
        .keysym = 0xff53,
        .modifier = .{ .mod4 = true },
        .action = .focus_window_right,
    },
    .{
        .keysym = 0xff51,
        .modifier = .{ .mod4 = true, .shift = true },
        .action = .move_window_left,
    },
    .{
        .keysym = 0xff53,
        .modifier = .{ .mod4 = true, .shift = true },
        .action = .move_window_right,
    },
};
