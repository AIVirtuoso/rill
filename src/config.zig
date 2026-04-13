const std = @import("std");
const types = @import("types.zig");

const Location = enum { XDG_CONFIG_HOME, HOME };
pub var is_parsed: bool = false;

fn find(allocator: std.mem.Allocator, location: Location) !types.Config {
    const env = try std.process.getEnvVarOwned(allocator, @tagName(location));
    defer allocator.free(env);

    const path = switch (location) {
        .XDG_CONFIG_HOME => try std.fs.path.join(allocator, &.{
            env,
            "rill",
            "config.zon",
        }),
        .HOME => try std.fs.path.join(allocator, &.{
            env,
            ".config",
            "rill",
            "config.zon",
        }),
    };
    defer allocator.free(path);

    const content = try std.fs.cwd().readFileAllocOptions(
        allocator,
        path,
        1024 * 1024,
        null,
        std.mem.Alignment.@"1",
        0,
    );
    defer allocator.free(content);

    return try std.zon.parse.fromSlice(
        types.Config,
        allocator,
        content,
        null,
        .{},
    );
}

pub fn load(allocator: std.mem.Allocator) types.Config {
    xdg_config_home: {
        const config = find(allocator, Location.XDG_CONFIG_HOME) catch |err| {
            std.debug.print("Failed to load config from $XDG_CONFIG_HOME: {}\n", .{err});
            break :xdg_config_home;
        };
        is_parsed = true;
        return config;
    }

    const config = find(allocator, Location.HOME) catch |err| {
        std.debug.print("Failed to load config from $HOME: {}\n", .{err});
        return .{};
    };
    is_parsed = true;
    return config;
}

test "validate default config file" {
    const fields = std.meta.fields(types.Config);
    const config_struct = types.Config{};
    const config_file: types.Config = @import("default_config");

    inline for (fields) |field| {
        const has_field = @hasField(@TypeOf(@import("default_config")), field.name);
        if (!has_field) {
            std.debug.print("Default config file is missing field '{s}'\n", .{field.name});
            try std.testing.expect(has_field);
        }

        const struct_value = @field(config_struct, field.name);
        const file_value = @field(config_file, field.name);
        std.testing.expectEqualDeep(struct_value, file_value) catch |err| {
            std.debug.print("Value of '{s}' doesn't match\n", .{field.name});
            return err;
        };
    }
}
