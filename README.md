# Rill
A minimalist scrolling window manager implementing the [river](https://codeberg.org/river/river)-window-management-v1 protocol, written in Zig

## Features
* Scrolling layout
* Workspaces
* Animation
* Config with live reloading

<video src="https://codeberg.org/lzj15/rill/raw/branch/main/assets/recording.mp4" controls>
</video>

## Default Keybinds
| Keybind | Action |
|----------|--------|
| `Super q` | Close window |
| `Super h` | Focus to window on the left |
| `Super l` | Focus to window on the right |
| `Super Shift h` | Move window to the left |
| `Super Shift l` | Move window to the right |
| `Super -` | Decrease window's width by a proportion of 0.1 |
| `Super =` | Increase window's width by a proportion of 0.1 |
| `Super f` | Toggle fullscreen |
| `Super 1~0` | Focus to workspace 1~10 |
| `Super Shift 1~0` | Move window to workspace 1~10 |
| `Super r` | Reload config |
| `Super t` | Open alacritty |
| `XF86AudioRaiseVolume` | Raise volume of PipeWire default audio sink by 5% |
| `XF86AudioLowerVolume` | Lower volume of PipeWire default audio sink by 5% |
| `XF86AudioMute` | Toggle mute for PipeWire default audio sink |
| `XF86AudioMicMute` | Toggle mute for PipeWire default audio source |
| `Ctrl Alt Delete` | Exit River |

Keybinds for PipeWire require `wpctl` to work.

`Ctrl Alt Delete` is provided by River itself and always works.

## Dependencies
* zig 0.15
* river 0.4.x (supporting river-window-management-v1 protocol)
* wayland
* wayland-protocols

## Build
```bash
git clone https://codeberg.org/lzj15/rill.git
cd rill
zig build --release=safe
```

## Usage
Add `rill` to the river init file, or directly run `river -c rill`.

## Configuration
Rill is configured with a ZON file at `$XDG_CONFIG_HOME/rill/config.zon`, fallback to `$HOME/.config/rill/config.zon`. See [default config](https://codeberg.org/lzj15/rill/src/branch/main/assets/config.zon) as an example.
