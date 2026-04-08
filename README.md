# Rill
A minimalist scrolling window manager for [river](https://isaacfreund.com/software/river/), implementing the [river-window-management-v1](https://isaacfreund.com/docs/wayland/river-window-management-v1/) protocol

## Features
* Scrolling layout
* Workspaces
* Animations
* Live-reloading config

<video src="https://pub-da8894d425e3482384b5adec2dcc2361.r2.dev/recording.mp4" controls> </video>

## Installation
You can download pre-built binary from [releases](https://codeberg.org/lzj15/rill/releases).

## Usage
[River](https://isaacfreund.com/software/river/) needs to be installed first.  
Run `rill` in [river's init file](https://codeberg.org/river/river#usage), or directly run `river -c rill`.

## Configuration
Rill searches for a config file at the following locations in order:  
`$XDG_CONFIG_HOME/rill/config.zon`  
`$HOME/.config/rill/config.zon`  
See the [default config](https://codeberg.org/lzj15/rill/src/branch/main/config.zon) as an example.

## Default Keybindings
| Keybinding | Action |
|----------|--------|
| `Super` `q` | Close window |
| `Super` `f` | Toggle fullscreen |
| `Super` `minus` | Decrease window's width by a proportion of 0.1 |
| `Super` `equal` | Increase window's width by a proportion of 0.1 |
| `Super` `BackSpace` | Set window's width to a proportion of 0.5 |
| `Super` `Left` | Focus on the left window |
| `Super` `Right` | Focus on the right window |
| `Super` `Shift` `Left` | Move window to the left |
| `Super` `Shift` `Right` | Move window to the right |
| `Super` `Up` | Focus on the workspace above |
| `Super` `Down` | Focus on the workspace below |
| `Super` `grave` | Focus on previous workspace |
| `Super` `1~0` | Focus on workspace 1~10 |
| `Super` `Shift` `Up` | Move window to the workspace above |
| `Super` `Shift` `Down` | Move window to the workspace below |
| `Super` `Shift` `1~0` | Move window to workspace 1~10 |
| `Super` `h` | Focus on the left output |
| `Super` `l` | Focus on the right output |
| `Super` `k` | Focus on the output above |
| `Super` `j` | Focus on the output below |
| `Super` `Shift` `h` | Move window to the left output |
| `Super` `Shift` `l` | Move window to the right output |
| `Super` `Shift` `k` | Move window to the output above |
| `Super` `Shift` `j` | Move window to the output below |
| `Super` `Escape` | Exit river |
| `Super` `r` | Reload config |
| `Super` `t` | Open alacritty |
| `XF86AudioRaiseVolume` | Raise volume of PipeWire default audio sink by 5% |
| `XF86AudioLowerVolume` | Lower volume of PipeWire default audio sink by 5% |
| `XF86AudioMute` | Toggle mute for PipeWire default audio sink |
| `XF86AudioMicMute` | Toggle mute for PipeWire default audio source |

## Build
### Dependencies
* zig 0.15
* wayland
* wayland-protocols
* xkbcommon
```sh
zig build --release=safe
```
