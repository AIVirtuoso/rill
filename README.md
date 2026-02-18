# Rill
A minimalist scrolling window manager implementing the [river](https://codeberg.org/river/river)-window-management-v1 protocol, written in Zig

## Features
* Scrolling layout
* Workspaces
* Animation
* Config with live reload

<video src="https://codeberg.org/lzj15/rill/raw/branch/main/assets/recording.mp4" controls>
</video>

## Default key bindings
| Binding | Action |
|----------|--------|
| `Super t` | Open alacritty |
| `Super q` | Close window |
| `Super h` | Focus to window on the left |
| `Super l` | Focus to window on the right |
| `Super Shift h` | Move window to the left |
| `Super Shift l` | Move window to the right |
| `Super -` | Increase window's width by 10% |
| `Super =` | Decrease window's width by 10% |
| `Super Shift f` | Toggle fullscreen |
| `Super 1~0` | Focus to workspace 1~10 |
| `Super Shift r` | Reload config |
| `Ctrl Alt Delete` | Exit River |

## Dependencies
* Zig 0.15
* River 0.4.x (supporting river-window-management-v1 protocol)
* wayland-client
* wayland-protocols

## Build
```bash
git clone https://codeberg.org/lzj15/rill.git
cd rill
zig build -Doptimize=ReleaseSafe
```

## Usage
Add `rill` to the river init file, or directly run `river -c rill`.

## Configuration
Rill is configured with a ZON file at `$XDG_CONFIG_HOME/rill/config.zon`, fallback to `$HOME/rill/config.zon`. See [default config](https://codeberg.org/lzj15/rill/src/branch/main/assets/config.zon) as an example.
