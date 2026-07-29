# Rill
A minimalist scrolling window manager for [river](https://isaacfreund.com/software/river/), implementing the [river-window-management-v1](https://isaacfreund.com/docs/wayland/river-window-management-v1/) protocol

> **This is a fork.** Upstream is <https://codeberg.org/lzj15/rill>.
> See [Licence](#licence) — this fork is distributed under the GPLv3, while
> upstream rill is MIT.

## Features
* Scrolling layout
* Floating layout
* Workspaces
* Animations
* Live-reloading config
* Multi-output

<video src="https://pub-da8894d425e3482384b5adec2dcc2361.r2.dev/recording.mp4" controls> </video>

## Installation
You can download pre-built binary from [releases](https://codeberg.org/lzj15/rill/releases).

## Configuration
Rill searches for a config file at the following locations in order:  
`$XDG_CONFIG_HOME/rill/config.zon`  
`$HOME/.config/rill/config.zon`  
See the [default config](https://codeberg.org/lzj15/rill/src/branch/main/config.zon) as an example.

## Usage
[River](https://isaacfreund.com/software/river/) needs to be installed first.  
Run `rill` in [river's init file](https://codeberg.org/river/river#usage), or directly run `river -c rill`.

### Default Keybindings
| Keybinding | Action |
|----------|--------|
| `Super` `q` | Close window |
| `Super` `f` | Toggle fullscreen |
| `Super` `minus` | Decrease window's width by a proportion of 0.1 |
| `Super` `equal` | Increase window's width by a proportion of 0.1 |
| `Super` `BackSpace` | Set window's width to a proportion of 0.5 |
| `Super` `Left` | Focus on window left |
| `Super` `Right` | Focus on window right |
| `Super` `Shift` `Left` | Move window to the left |
| `Super` `Shift` `Right` | Move window to the right |
| `Super` `v` | Toggle workspace floating |
| `Super` `Up` | Focus on workspace above |
| `Super` `Down` | Focus on workspace below |
| `Super` `grave` | Focus on previous workspace |
| `Super` `1~0` | Focus on workspace 1~10 |
| `Super` `Shift` `Up` | Move window to workspace above |
| `Super` `Shift` `Down` | Move window to workspace below |
| `Super` `Shift` `1~0` | Move window to workspace 1~10 |
| `Super` `h` | Focus on output left |
| `Super` `l` | Focus on output right |
| `Super` `k` | Focus on output above |
| `Super` `j` | Focus on output below |
| `Super` `Shift` `h` | Move window to output left |
| `Super` `Shift` `l` | Move window to output right |
| `Super` `Shift` `k` | Move window to output above |
| `Super` `Shift` `j` | Move window to output below |
| `Super` `Escape` | Exit river |
| `Super` `r` | Reload config |
| `Super` `t` | Open alacritty |
| `XF86AudioRaiseVolume` | Raise volume of PipeWire default audio sink by 5% |
| `XF86AudioLowerVolume` | Lower volume of PipeWire default audio sink by 5% |
| `XF86AudioMute` | Toggle mute for PipeWire default audio sink |
| `XF86AudioMicMute` | Toggle mute for PipeWire default audio source |

### Default Pointer Bindings
| Pointer Binding | Action |
|----------|--------|
| `Super` `Left Click` | Move floating window |
| `Super` `Right Click` | Resize floating window |

## Build
### Dependencies
* zig 0.16
* wayland
* wayland-protocols
* xkbcommon
```sh
zig build --release=safe
```

## Licence

This is a fork of [rill](https://codeberg.org/lzj15/rill) by Zhijian Li.

The original work is Copyright 2026 Zhijian Li and is licensed under the MIT
licence, reproduced in full in [`LICENSE.MIT`](LICENSE.MIT). That notice is
retained as the MIT licence requires, and upstream rill remains available under
MIT from the link above.

Modifications in this fork are Copyright 2026 polonius-dev and are licensed
under the GNU General Public License version 3, and the combined work is
distributed under the GPLv3. See [`LICENSE`](LICENSE).

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
