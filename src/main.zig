const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const config = @import("config.zig");
const window = @import("window.zig");
const keybind = @import("keybind.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const allocator = gpa.allocator();

pub var river_window_manager: ?*river.WindowManagerV1 = null;
pub var river_xkb_bindings: ?*river.XkbBindingsV1 = null;
var river_output: ?*river.OutputV1 = null;
var river_seat: ?*river.SeatV1 = null;
var river_layer_shell: ?*river.LayerShellV1 = null;

pub const Workspace = struct {
    window_list: std.ArrayList(window.Window),
    focused_window_index: ?usize,
};

pub var workspace_list: [10]Workspace = undefined;
pub var focused_workspace_index: usize = 0;

var x_non_exclusive: i32 = 0;
var y_non_exclusive: i32 = 0;

var animation_progress: ?usize = null;

pub fn main() !void {
    const display = try wl.Display.connect(null);
    defer display.disconnect();

    const registry = try display.getRegistry();
    defer registry.destroy();
    registry.setListener(?*anyopaque, registryListener, null);

    _ = display.roundtrip();

    if (river_window_manager) |window_manager| {
        std.debug.print("Successfully found River window manager\n", .{});
        window_manager.setListener(?*anyopaque, windowManagerListener, null);

        for (&workspace_list) |*workspace| {
            workspace.* = Workspace{
                .window_list = std.ArrayList(window.Window){},
                .focused_window_index = null,
            };
        }

        config.loadConfig(allocator);
        config.spawnAtStartup(allocator);

        while (true) {
            const status = display.dispatch();
            if (@intFromEnum(status) != 0) {
                std.debug.print("Wayland loop stopped with status: {any}\n", .{status});
                break;
            }

            if (animation_progress) |_| {
                window_manager.manageDirty();
            }
        }
    } else {
        std.debug.print("Failed to find River window manager\n", .{});
        return;
    }
}

fn registryListener(
    registry: *wl.Registry,
    event: wl.Registry.Event,
    data: ?*anyopaque,
) void {
    _ = data;
    switch (event) {
        .global => |global| {
            const interface_name = std.mem.span(global.interface);
            if (std.mem.eql(u8, interface_name, "river_window_manager_v1")) {
                river_window_manager = registry.bind(global.name, river.WindowManagerV1, 3) catch null;
            } else if (std.mem.eql(u8, interface_name, "river_xkb_bindings_v1")) {
                river_xkb_bindings = registry.bind(global.name, river.XkbBindingsV1, 2) catch null;
            } else if (std.mem.eql(u8, interface_name, "river_layer_shell_v1")) {
                river_layer_shell = registry.bind(global.name, river.LayerShellV1, 1) catch null;
            }
        },
        .global_remove => |_| {},
    }
}

fn windowManagerListener(
    window_manager: *river.WindowManagerV1,
    event: river.WindowManagerV1.Event,
    data: ?*anyopaque,
) void {
    _ = data;

    switch (event) {
        .output => |output_event| {
            river_output = output_event.id;
            std.debug.print("Found an output\n", .{});

            const layer_shell = river_layer_shell orelse {
                std.debug.print("Failed to find a layer shell\n", .{});
                return;
            };
            std.debug.print("Successfully found River layer shell\n", .{});

            const layer_shell_output = layer_shell.getOutput(output_event.id) catch {
                std.debug.print("Failed to get layer shell output\n", .{});
                return;
            };
            std.debug.print("Successfully got layer shell output\n", .{});

            layer_shell_output.setListener(?*anyopaque, layerShellOutputListener, null);
        },
        .seat => |seat_event| {
            river_seat = seat_event.id;
            std.debug.print("Found a seat\n", .{});

            keybind.setupKeybinds(seat_event.id);
        },
        .window => |window_event| {
            window.addWindow(window_event.id);
        },
        .manage_start => {
            window_manager.manageFinish();
        },
        .render_start => {
            if (animation_progress) |progress| {
                const steps = 20;

                for (animation_node_list.items) |*item| {
                    const x_step: i32 = @divTrunc((item.x_finish - item.x_start), steps);
                    const y_step: i32 = @divTrunc((item.y_finish - item.y_start), steps);

                    if (progress < steps - 1) {
                        item.x.* += x_step;
                        item.y.* += y_step;

                        std.Thread.sleep(2 * std.time.ns_per_ms);

                        animation_progress = progress + 1;
                    } else if (progress == steps - 1) {
                        item.x.* = item.x_finish;
                        item.y.* = item.y_finish;

                        animation_progress = null;
                    }
                }
            }

            for (animation_node_list.items) |animation_node| {
                animation_node.river_node.setPosition(animation_node.x.*, animation_node.y.*);
            }
            window_manager.renderFinish();
        },
        else => {},
    }
}

const AnimationNode = struct {
    river_node: *river.NodeV1,
    x: *i32,
    y: *i32,
    x_start: i32,
    y_start: i32,
    x_finish: i32,
    y_finish: i32,
};
var animation_node_list = std.ArrayList(AnimationNode){};

pub fn applyLayout() void {
    for (workspace_list) |workspace| {
        for (workspace.window_list.items) |item| {
            item.river_window.proposeDimensions(item.width, item.height);
        }
    }

    seat: {
        const focused_window_index = workspace_list[focused_workspace_index].focused_window_index orelse {
            break :seat;
        };
        const seat = river_seat orelse {
            std.debug.print("Failed to find a seat\n", .{});
            break :seat;
        };

        seat.focusWindow(workspace_list[focused_workspace_index].window_list.items[focused_window_index].river_window);
        std.debug.print("Set focus of seat at workspace {}, window {}\n", .{ focused_workspace_index + 1, focused_window_index });
    }

    animation_node_list.clearRetainingCapacity();

    for (&workspace_list, 0..) |*workspace, i_workspace| {
        const focused_window_index = workspace.focused_window_index orelse continue;
        const focused_window = &workspace.window_list.items[focused_window_index];

        var x_coordinate = @divTrunc(config.config.screen_width, 2) - @divTrunc(focused_window.width, 2) + x_non_exclusive;
        const y_coordinate = (@as(i32, @intCast(i_workspace)) - @as(i32, @intCast(focused_workspace_index))) * config.config.screen_height + y_non_exclusive;

        animation_node_list.append(allocator, .{
            .river_node = focused_window.river_node,
            .x = &focused_window.x,
            .y = &focused_window.y,
            .x_start = focused_window.x,
            .y_start = focused_window.y,
            .x_finish = x_coordinate,
            .y_finish = y_coordinate,
        }) catch |err| {
            std.debug.print("Failed to add animation node: {}\n", .{err});
            return;
        };

        var i_window: usize = focused_window_index;
        while (i_window > 0) {
            i_window -= 1;
            const item = &workspace.window_list.items[i_window];

            x_coordinate -= item.width;

            animation_node_list.append(allocator, .{
                .river_node = item.river_node,
                .x = &item.x,
                .y = &item.y,
                .x_start = item.x,
                .y_start = item.y,
                .x_finish = x_coordinate,
                .y_finish = y_coordinate,
            }) catch |err| {
                std.debug.print("Failed to add animation node: {}\n", .{err});
                return;
            };
        }

        x_coordinate = @divTrunc(config.config.screen_width, 2) + @divTrunc(focused_window.width, 2);
        for (workspace.window_list.items[focused_window_index + 1 ..]) |*item| {
            animation_node_list.append(allocator, .{
                .river_node = item.river_node,
                .x = &item.x,
                .y = &item.y,
                .x_start = item.x,
                .y_start = item.y,
                .x_finish = x_coordinate,
                .y_finish = y_coordinate,
            }) catch |err| {
                std.debug.print("Failed to add animation node: {}\n", .{err});
                return;
            };

            x_coordinate += item.width;
        }

        animation_progress = 0;
    }
}

// fn animate(progress: usize) void {
// const window_manager = river_window_manager orelse return;

// const steps = 20;

// for (animation_node_list.items, 0..) |*item, i| {
//     const x_step: i32 = @divTrunc((item.x_finish - item.x_start), steps);
//     const y_step: i32 = @divTrunc((item.y_finish - item.y_start), steps);

//     if (progress < steps - 1) {
//         item.window.x += x_step;
//         item.window.y += y_step;

//         if (i == 0) {
//             std.debug.print("animation gives {}\n", .{item.window.x});
//         }

//         window_manager.manageDirty();

//         std.Thread.sleep(50 * std.time.ns_per_ms);

//         animation_progress = progress + 1;
//     } else if (progress == steps - 1) {
//         item.window.x = item.x_finish;
//         item.window.y = item.y_finish;

//         std.debug.print("animation gives {}\n", .{item.window.x});

//         window_manager.manageDirty();

//         animation_progress = null;
//     }
// }
// }

fn layerShellOutputListener(
    layer_shell: *river.LayerShellOutputV1,
    event: river.LayerShellOutputV1.Event,
    data: ?*anyopaque,
) void {
    _ = data;
    _ = layer_shell;

    switch (event) {
        .non_exclusive_area => |non_exclusive_area| {
            for (&workspace_list) |*workspace| {
                for (workspace.window_list.items) |*item| {
                    item.height = non_exclusive_area.height;
                }
            }
            x_non_exclusive = non_exclusive_area.x;
            y_non_exclusive = non_exclusive_area.y;
        },
    }
}
