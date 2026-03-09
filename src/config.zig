const std = @import("std");
const types = @import("types.zig");

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

pub fn loadConfig(allocator: std.mem.Allocator) ?types.Config {
    const path = findConfig(allocator) orelse return null;
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
        return null;
    };
    defer allocator.free(content);

    var config = std.zon.parse.fromSlice(
        types.Config,
        allocator,
        content,
        null,
        .{},
    ) catch |err| {
        std.debug.print("Failed to parse {s}: {}\n", .{ path, err });
        return null;
    };
    std.debug.print("Loaded config file: {s}\n", .{path});
    config.is_parsed_from_file = true;
    return config;
}
