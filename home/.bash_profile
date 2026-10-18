#
# ~/.bash_profile
#

# Put ~/.local/bin (claude, launcher wrappers) on PATH for every login, including SSH.
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac

[[ -f ~/.bashrc ]] && . ~/.bashrc

# Start niri automatically when logging in on the first text console (not over SSH, not on
# other consoles, not from a terminal that is already inside a desktop). Not exec'd on purpose:
# if niri exits or fails to start you land back at a shell instead of a login loop.
# niri is started again only when dwm-update asked for a restart (swayidle then ended the session).
# -l: this already is a login shell, so niri-session must not start another (it would run this file again).
if [[ -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" && "${XDG_VTNR:-}" == 1 ]]; then
	while :; do
		rm -f "$XDG_RUNTIME_DIR/dwm-restart-session"
		niri-session -l
		[[ -e $XDG_RUNTIME_DIR/dwm-restart-session ]] || break
	done
fi
