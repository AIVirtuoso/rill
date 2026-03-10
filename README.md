# Rill
A minimalist scrolling window manager for [river](https://isaacfreund.com/software/river/), implementing the [river-window-management-v1](https://isaacfreund.com/docs/wayland/river-window-management-v1/) protocol

## Features
* Scrolling layout
* Workspaces
* Animations
* Live-reloading config

<video src="https://codeberg.org/lzj15/rill/raw/branch/main/assets/recording.mp4" controls>
</video>

## Default Keybindings
| Keybinding | Action |
|----------|--------|
| `Super q` | Close window |
| `Super h` | Focus on the left window |
| `Super l` | Focus on the right window |
| `Super Shift h` | Move window to the left |
| `Super Shift l` | Move window to the right |
| `Super -` | Decrease window's width by a proportion of 0.1 |
| `Super =` | Increase window's width by a proportion of 0.1 |
| `Super f` | Toggle fullscreen |
| `Super 1~0` | Focus on workspace 1~10 |
| `Super Shift 1~0` | Move window to workspace 1~10 |
| `` Super ` `` | Focus on previous workspace |
| `Super Left` | Focus on the left output |
| `Super Right` | Focus on the right output |
| `Super Up` | Focus on the output above |
| `Super Down` | Focus on the output below |
| `Ctrl Alt Delete` | Exit River |
| `Super r` | Reload config |
| `Super t` | Open alacritty |
| `XF86AudioRaiseVolume` | Raise volume of PipeWire default audio sink by 5% |
| `XF86AudioLowerVolume` | Lower volume of PipeWire default audio sink by 5% |
| `XF86AudioMute` | Toggle mute for PipeWire default audio sink |
| `XF86AudioMicMute` | Toggle mute for PipeWire default audio source |

## Dependencies
* zig 0.15
* river 0.4
* wayland
* wayland-protocols

## Build
```bash
zig build --release=safe
```

## Usage
Run `rill` in [river's init file](https://codeberg.org/river/river#usage), or directly run `river -c rill`.

## Configuration
Rill searches for a config file at the following locations in order:  
`$XDG_CONFIG_HOME/rill/config.zon`  
`$HOME/.config/rill/config.zon`  
See the [default config](https://codeberg.org/lzj15/rill/src/branch/main/assets/config.zon) as an example.
