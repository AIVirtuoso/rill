const std = @import("std");
const wayland = @import("wayland");
const river = wayland.client.river;
const wl = wayland.client.wl;

const animation = @import("animation.zig");
const config = @import("config.zig");
const keybinding = @import("keybinding.zig");
const layout = @import("layout.zig");
const output = @import("output.zig");
const seat = @import("seat.zig");
const types = @import("types.zig");
const window = @import("window.zig");

pub fn main() !void {
    const display = try wl.Display.connect(null);
    defer display.disconnect();

    var wm = types.WindowManager{
        .gpa = .init,
        .registry = try display.getRegistry(),
        .river_window_manager = null,
        .river_xkb_bindings = null,
        .river_layer_shell = null,
        .river_seat = null,
        .output_list = .empty,
        .focused_output_idx = null,
        .previous_workspace = null,
        .config = .{},
        .xkb_binding_list = .empty,
        .pointer_binding_list = .empty,
        .status = .none,
    };
    defer wm.deinit(config.is_parsed);

    wm.registry.setListener(*types.WindowManager, registryListener, &wm);
    _ = display.roundtrip();

    const window_manager = wm.river_window_manager orelse {
        std.debug.print("Failed to find window manager\n", .{});
        return;
    };
    window_manager.setListener(*types.WindowManager, windowManagerListener, &wm);

    const allocator = wm.gpa.allocator();
    wm.config = config.load(allocator);

    for (wm.config.spawn_at_startup) |command| {
        var child = std.process.Child.init(command, allocator);
        child.spawn() catch |err|
            std.debug.print("Failed to spawn {s}: {}\n", .{ command[0], err });
    }

    while (true) {
        const status = display.dispatch();
        if (status != .SUCCESS) {
            std.debug.print("Window manager stopped with status: {}\n", .{status});
            break;
        }
        if (wm.status == .animation) window_manager.manageDirty();
    }
}

fn registryListener(
    registry: *wl.Registry,
    event: wl.Registry.Event,
    wm: *types.WindowManager,
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
    wm: *types.WindowManager,
) void {
    switch (event) {
        .output => |output_event| output.add(output_event.id, wm) catch |err|
            std.debug.print("Failed to add output: {}\n", .{err}),
        .seat => |seat_event| {
            wm.river_seat = seat_event.id;
            seat_event.id.setListener(*types.WindowManager, seat.seatListener, wm);
            wm.status = .setup_bindings;

            const layer_shell = wm.river_layer_shell orelse {
                std.debug.print("Failed to find layer shell\n", .{});
                return;
            };
            const layer_shell_seat = layer_shell.getSeat(seat_event.id) catch {
                std.debug.print("Failed to get layer shell seat\n", .{});
                return;
            };
            layer_shell_seat.setListener(*types.WindowManager, seat.layerShellSeatListener, wm);
        },
        .window => |window_event| {
            layout.pending_windows.append(wm.gpa.allocator(), window_event.id) catch |err| {
                std.debug.print("Failed to add window: {}\n", .{err});
                return;
            };
            window_event.id.setListener(*types.WindowManager, window.windowListener, wm);
            wm.status = .layout;
        },
        .manage_start => {
            manage(wm);
            window_manager.manageFinish();
        },
        .render_start => window_manager.renderFinish(),
        .finished => window_manager.destroy(),
        else => {},
    }
}

fn manage(wm: *types.WindowManager) void {
    const focused_output_idx = wm.focused_output_idx orelse return;
    const river_seat = wm.river_seat orelse {
        std.debug.print("Failed to find seat\n", .{});
        return;
    };

    switch (wm.status) {
        .layout => {
            layout.apply(
                &wm.output_list,
                focused_output_idx,
                wm.config,
                river_seat,
                wm.gpa.allocator(),
            );
            wm.status = .{ .animation = std.time.milliTimestamp() };
        },
        .animation => |start_time| wm.status = animation.apply(
            wm.output_list,
            focused_output_idx,
            wm.config,
            start_time,
        ),
        .pointer_action => |_| {
            river_seat.opStartPointer();
            seat.pointerAction(wm.output_list, focused_output_idx, wm.config);
        },
        .setup_bindings => {
            keybinding.setupKeybindings(wm) catch |err|
                std.debug.print("Failed to setup keybindings: {}\n", .{err});
            seat.setupPointerBindings(wm) catch |err|
                std.debug.print("Failed to setup pointer bindings: {}\n", .{err});
            layout.update(wm.output_list, wm.config);
            wm.status = .layout;
            wm.river_window_manager.?.manageDirty();
        },
        .exit => {
            wm.deinit(config.is_parsed);
            wm.river_window_manager.?.exitSession();
        },
        .none => river_seat.opEnd(),
    }
}

test {
    std.testing.refAllDecls(@This());
}
