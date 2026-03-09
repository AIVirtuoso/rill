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

var wm: types.WindowManager = .{};

pub fn main() !void {
    const allocator = wm.gpa.allocator();

    const display = try wl.Display.connect(null);
    defer display.disconnect();

    wm.registry = try display.getRegistry();
    wm.registry.setListener(?*anyopaque, registryListener, null);
    _ = display.roundtrip();

    const window_manager = wm.river_window_manager orelse {
        std.debug.print("Failed to find window manager\n", .{});
        return;
    };
    window_manager.setListener(?*anyopaque, windowManagerListener, null);

    if (config.loadConfig(allocator)) |loaded_config| wm.config = loaded_config;
    for (wm.config.spawn_at_startup) |command| {
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

    wm.deinit();
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
                wm.river_window_manager =
                    registry.bind(global.name, river.WindowManagerV1, 4) catch null;
            } else if (std.mem.eql(u8, interface_name, "river_xkb_bindings_v1")) {
                wm.river_xkb_bindings =
                    registry.bind(global.name, river.XkbBindingsV1, 2) catch null;
            } else if (std.mem.eql(u8, interface_name, "river_layer_shell_v1")) {
                wm.river_layer_shell =
                    registry.bind(global.name, river.LayerShellV1, 1) catch null;
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
            const output = types.Output{
                .river_output = output_event.id,
                .workspace_list = [_]types.Workspace{.{}} ** 10,
                .focused_workspace_idx = 0,
                .rectangle = undefined,
                .non_exclusive = null,
            };
            wm.output_list.append(wm.gpa.allocator(), output) catch |err| {
                std.debug.print("Failed to add output: {}\n", .{err});
                return;
            };
            wm.focused_output_idx = wm.output_list.items.len - 1;
            output_event.id.setListener(?*anyopaque, outputListener, null);

            const layer_shell = wm.river_layer_shell orelse {
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
            wm.river_seat = seat_event.id;
            keybinding.setup(&wm);
        },
        .window => |window_event| {
            window.pending = window_event.id;
            window_event.id.setListener(*types.WindowManager, window.windowListener, &wm);
            window_event.id.hide();
            window_event.id.proposeDimensions(0, 0);
            if (wm.config.no_csd) window_event.id.useSsd();
        },
        .manage_start => {
            const idx = wm.focused_output_idx orelse return;
            const seat = wm.river_seat orelse {
                std.debug.print("Failed to find seat\n", .{});
                return;
            };

            animation.apply(&wm.output_list.items[idx], wm.config, seat);
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
    for (wm.output_list.items) |*output| {
        if (output.river_output != river_output) continue;
        switch (event) {
            .dimensions => |dimensions| {
                output.rectangle.width = dimensions.width;
                output.rectangle.height = dimensions.height;
            },
            .position => |position| {
                output.rectangle.x = position.x;
                output.rectangle.y = position.y;
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
    for (wm.output_list.items, 0..) |*output, idx| {
        if (output.river_output != river_output) continue;
        switch (event) {
            .non_exclusive_area => |area| {
                output.non_exclusive = .{
                    .width = area.width,
                    .height = area.height,
                    .x = area.x,
                    .y = area.y,
                };
                if (idx == wm.focused_output_idx) layout.apply(output, wm.config);
            },
        }
    }
}
