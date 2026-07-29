#!/usr/bin/env bash
# Nested rill test harness.
#
# Runs the rill in your working tree as a *client* of the live session: river's
# wayland backend puts the whole nested compositor in a window, so nothing is
# drawn on the real desktop and the real session is never restarted. Input is
# driven through river's zwp_virtual_keyboard_manager_v1, so a test is a shell
# script rather than a person pressing keys.
#
#   ./test/nested.sh up            build, then start nested rill in a window
#   ./test/nested.sh key alt Return   send a keystroke to it
#   ./test/nested.sh spawn NAME    open a labelled terminal inside it
#   ./test/nested.sh ls            list the windows it is managing
#   ./test/nested.sh shot FILE     screenshot the nested output
#   ./test/nested.sh log           show what the nested rill printed
#   ./test/nested.sh down          stop it
#
# The nested config binds Alt, not Super: the outer rill holds compositor-level
# grabs on Super, so a nested Super+J never reaches the compositor under test.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
run="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/rill-nested"
deps=${RILL_ZIG_DEPS:-/nix/store/5l8xnwqg9s50z75qz878jccpmpinym7j-rill-0.6.0-zig-deps}

# The nested display, written by the init script once river is up.
display_file="$run/display"

nested_env() {
	if [ ! -r "$display_file" ]; then
		echo "not running -- './test/nested.sh up' first" >&2
		exit 1
	fi
	export WAYLAND_DISPLAY
	WAYLAND_DISPLAY=$(cat "$display_file")
}

# wtype and lswt are not installed system-wide; fall back to nix run so the
# harness works from a bare checkout without touching the system profile.
tool() {
	local name=$1
	shift
	if command -v "$name" >/dev/null 2>&1; then
		"$name" "$@"
	else
		nix run "nixpkgs#$name" -- "$@"
	fi
}

case "${1:-}" in
build)
	nix develop --impure --expr \
		"with import <nixpkgs> {}; callPackage /etc/nixos/pkgs/rill.nix {}" \
		--command sh -c "cd '$root' && zig build --system '$deps' --prefix '$run/out'"
	;;

up)
	"$0" build
	mkdir -p "$run/config/rill"
	# Only what a test needs. Alt everywhere, see the note above.
	cat >"$run/config/rill/config.zon" <<'EOF'
.{
    .keybindings = .{
        .{ .key = "q", .modifiers = .{ .mod1 = true }, .action = .close_window },
        .{ .key = "Escape", .modifiers = .{ .mod1 = true }, .action = .exit },
        .{ .key = "h", .modifiers = .{ .mod1 = true }, .action = .focus_window_left },
        .{ .key = "l", .modifiers = .{ .mod1 = true }, .action = .focus_window_right },
        .{ .key = "k", .modifiers = .{ .mod1 = true }, .action = .focus_window_or_workspace_up },
        .{ .key = "j", .modifiers = .{ .mod1 = true }, .action = .focus_window_or_workspace_down },
        .{ .key = "u", .modifiers = .{ .mod1 = true }, .action = .toggle_window_stacked },
        .{ .key = "i", .modifiers = .{ .mod1 = true }, .action = .move_window_up },
        .{ .key = "o", .modifiers = .{ .mod1 = true }, .action = .move_window_down },
    },
}
EOF
	cat >"$run/init.sh" <<EOF
#!/bin/sh
printf '%s' "\$WAYLAND_DISPLAY" > '$display_file'
exec '$run/out/bin/rill'
EOF
	chmod +x "$run/init.sh"
	rm -f "$display_file"

	XDG_CONFIG_HOME="$run/config" \
	WLR_BACKENDS=wayland WLR_WL_OUTPUTS=1 \
		setsid river -c "$run/init.sh" >"$run/log" 2>&1 &

	for _ in $(seq 40); do
		[ -s "$display_file" ] && break
		sleep 0.25
	done
	nested_env
	echo "nested rill up on $WAYLAND_DISPLAY (config: $run/config/rill/config.zon)"
	;;

key)
	nested_env
	shift
	mod=$1
	key=$2
	tool wtype -M "$mod" -k "$key" -m "$mod"
	;;

spawn)
	nested_env
	# A distinct label per window, so a screenshot says which is which.
	foot -T "${2:-win}" sh -c "printf '\n  === %s ===\n' '${2:-win}'; exec sleep 9999" &
	sleep 1.5
	;;

ls)
	nested_env
	tool lswt
	;;

shot)
	nested_env
	tool grim "${2:-$run/shot.png}"
	echo "${2:-$run/shot.png}"
	;;

log)
	cat "$run/log"
	;;

down)
	pkill -f "river -c $run/init.sh" 2>/dev/null || true
	rm -f "$display_file"
	echo "stopped"
	;;

*)
	sed -n '2,20p' "$0"
	exit 2
	;;
esac
