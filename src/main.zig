const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;
const wl = wayland.client.wl;

const animation = @import("animation.zig");
const config = @import("config.zig");
const keybinding = @import("keybinding.zig");
const layout = @import("layout.zig");
const types = @import("types.zig");
const window = @import("window.zig");

var gpa = std.heap.DebugAllocator(.{}).init;
var allocator = gpa.allocator();

var river_window_manager: ?*river.WindowManagerV1 = null;
var river_xkb_bindings: ?*river.XkbBindingsV1 = null;
var river_layer_shell: ?*river.LayerShellV1 = null;
var river_seat: ?*river.SeatV1 = null;

pub fn main() !void {
    defer _ = gpa.deinit();

    const display = try wl.Display.connect(null);
    defer display.disconnect();

    const registry = try display.getRegistry();
    defer registry.destroy();

    registry.setListener(?*anyopaque, registryListener, null);
    _ = display.roundtrip();

    const window_manager = river_window_manager orelse {
        std.debug.print("Failed to find window manager\n", .{});
        return;
    };
    window_manager.setListener(?*anyopaque, windowManagerListener, null);

    defer layout.output_list.deinit(allocator);
    defer for (layout.output_list.items) |*output|
        for (&output.workspace_list) |*item| item.window_list.deinit(allocator);
    defer keybinding.xkb_binding_list.deinit(allocator);

    config.loadConfig(allocator);
    defer std.zon.parse.free(allocator, config.config);

    for (config.config.spawn_at_startup) |command| {
        var child = std.process.Child.init(command, allocator);
        child.spawn() catch |err|
            std.debug.print("Failed to spawn {s}: {}\n", .{ command[0], err });
    }

    while (true) {
        const status = display.dispatch();
        if (@intFromEnum(status) != 0) {
            std.debug.print("Program stopped with status: {}\n", .{status});
            break;
        }
        if (animation.start_time) |_| window_manager.manageDirty();
    }
}

fn registryListener(
    registry: *wl.Registry,
    event: wl.Registry.Event,
    _: ?*anyopaque,
) void {
    switch (event) {
        .global => |global| {
            const interface_name = std.mem.span(global.interface);
            if (std.mem.eql(u8, interface_name, "river_window_manager_v1")) {
                river_window_manager = registry.bind(global.name, river.WindowManagerV1, 4) catch null;
            } else if (std.mem.eql(u8, interface_name, "river_xkb_bindings_v1")) {
                river_xkb_bindings = registry.bind(global.name, river.XkbBindingsV1, 2) catch null;
            } else if (std.mem.eql(u8, interface_name, "river_layer_shell_v1")) {
                river_layer_shell = registry.bind(global.name, river.LayerShellV1, 1) catch null;
            }
        },
        .global_remove => {},
    }
}

fn windowManagerListener(
    window_manager: *river.WindowManagerV1,
    event: river.WindowManagerV1.Event,
    _: ?*anyopaque,
) void {
    switch (event) {
        .output => |output_event| {
            const workspace_list = [_]types.Workspace{.{
                .window_list = std.ArrayList(types.Window){},
                .focused_window_index = null,
            }} ** 10;

            layout.output_list.append(allocator, .{
                .river_output = output_event.id,
                .workspace_list = workspace_list,
                .focused_workspace_index = 0,
                .dimensions = undefined,
                .non_exclusive = null,
            }) catch |err| {
                std.debug.print("Failed to add output: {}\n", .{err});
                return;
            };
            output_event.id.setListener(?*anyopaque, outputListener, null);

            const layer_shell = river_layer_shell orelse {
                std.debug.print("Failed to find layer shell\n", .{});
                return;
            };
            const layer_shell_output = layer_shell.getOutput(output_event.id) catch {
                std.debug.print("Failed to get layer shell output\n", .{});
                return;
            };

            layer_shell_output.setListener(
                *river.OutputV1,
                layerShellOutputListener,
                output_event.id,
            );
        },
        .seat => |seat_event| {
            river_seat = seat_event.id;
            const xkb_bindings = river_xkb_bindings orelse {
                std.debug.print("Failed to find xkb bindings\n", .{});
                return;
            };
            keybinding.setup(allocator, xkb_bindings, seat_event.id);
        },
        .window => |window_event| {
            window.pending = window_event.id;
            window_event.id.setListener(*std.mem.Allocator, window.windowListener, &allocator);
            window_event.id.hide();
            window_event.id.proposeDimensions(0, 0);
            if (config.config.no_csd) window_event.id.useSsd();
        },
        .manage_start => {
            const seat = river_seat orelse {
                std.debug.print("Failed to find seat\n", .{});
                return;
            };
            animation.apply(seat);
            window_manager.manageFinish();
        },
        .render_start => window_manager.renderFinish(),
        .finished => window_manager.destroy(),
        else => {},
    }
}

fn outputListener(
    river_output: *river.OutputV1,
    event: river.OutputV1.Event,
    _: ?*anyopaque,
) void {
    for (layout.output_list.items) |*item| {
        if (item.river_output != river_output) continue;
        switch (event) {
            .dimensions => |dimensions| {
                item.dimensions.width = dimensions.width;
                item.dimensions.height = dimensions.height;
            },
            .position => |position| {
                item.dimensions.x = position.x;
                item.dimensions.y = position.y;
            },
            else => {},
        }
    }
}

fn layerShellOutputListener(
    _: *river.LayerShellOutputV1,
    event: river.LayerShellOutputV1.Event,
    river_output: *river.OutputV1,
) void {
    for (layout.output_list.items) |*item| {
        if (item.river_output != river_output) continue;
        switch (event) {
            .non_exclusive_area => |area| {
                item.non_exclusive = .{
                    .width = area.width,
                    .height = area.height,
                    .x = area.x,
                    .y = area.y,
                };
                layout.apply();
            },
        }
    }
}
