const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const float = @import("float.zig");
const types = @import("types.zig");

const Location = enum { XDG_CONFIG_HOME, HOME };

pub fn load(
    allocator: Allocator,
    io: Io,
    environ_map: std.process.Environ.Map,
) ?*types.Config {
    if(find(allocator, io, .XDG_CONFIG_HOME, environ_map)) |config| {
        return config;
    } else |err|
        std.debug.print("Failed to load config from $XDG_CONFIG_HOME: {}\n", .{err});

    if(find(allocator, io, .HOME, environ_map)) |config| {
        return config;
    } else |err|
        std.debug.print("Failed to load config from $HOME: {}\n", .{err});

    return null;
}

fn find(
    allocator: Allocator,
    io: Io,
    location: Location,
    environ_map: std.process.Environ.Map,
) !*types.Config {
    const env = environ_map.get(@tagName(location)) orelse return error.FileNotFound;

    const path = switch (location) {
        .XDG_CONFIG_HOME => try Io.Dir.path.join(allocator, &.{
            env,
            "rill",
            "config.zon",
        }),
        .HOME => try Io.Dir.path.join(allocator, &.{
            env,
            ".config",
            "rill",
            "config.zon",
        }),
    };
    defer allocator.free(path);

    const content = try Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        allocator,
        .unlimited,
        .@"16",
        0,
    );
    defer allocator.free(content);

    // Without diagnostics a malformed config is reported as a bare
    // error.ParseZon, and since load() then falls back to the built-in
    // defaults the user silently loses every keybinding with no clue which
    // field was at fault. Diagnostics report only line, column, field name
    // and the supported alternatives, so this is safe to paste into a bug
    // report.
    var diagnostics: std.zon.parse.Diagnostics = .{};
    defer diagnostics.deinit(allocator);

    const config = std.zon.parse.fromSliceAlloc(
        *types.Config,
        allocator,
        content,
        &diagnostics,
        .{},
    ) catch |err| {
        std.debug.print("{f}", .{&diagnostics});
        return err;
    };

    validate(config);
    return config;
}

/// Values the parser accepts but the layout cannot use. These are corrected
/// rather than rejected: a rejected config means falling back to the built-in
/// defaults, i.e. losing every keybinding, which is a far worse outcome than a
/// window of the nearest usable size. Both are reported, since a silent
/// correction is indistinguishable from the setting having no effect.
fn validate(config: *types.Config) void {
    const proportions = .{ "float_width", "float_height" };
    inline for (proportions) |name| {
        const given = @field(config, name);
        const clamped = float.clampProportion(given);
        // NaN is caught here too: it compares unequal to everything,
        // including the bound `clampProportion` collapses it to.
        if (given != clamped) {
            std.debug.print(
                "{s} of {d} is outside {d}..{d}, using {d}\n",
                .{ name, given, float.min_proportion, float.max_proportion, clamped },
            );
            @field(config, name) = clamped;
        }
    }
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
