#!/usr/bin/env bash
#
# Recreates this niri desktop on an Arch Linux machine.
# Run as your normal user (it calls sudo where it needs root):  ./install.sh
# Safe to re-run; anything it would overwrite is backed up first.

set -euo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

SCALE="${SCALE:-}"
DO_PACKAGES=1
WITH_STEAM=0

usage() {
	cat <<'EOF'
Usage: ./install.sh [options]

  --scale N       display scaling for every monitor connected now: 1, 1.25, 1.5, 2...
                  Written to ~/.config/niri/local.kdl. Default: a re-run keeps that
                  file as it is; a first install converts Xft.dpi from an old
                  ~/.Xresources (144 -> 1.5), else uses 1.
  --steam         also install Steam (needs the [multilib] repo enabled in
                  /etc/pacman.conf) and the matching 32-bit graphics libraries
  --no-packages   skip the pacman step
  -h, --help      this text
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--scale)       SCALE="${2:?--scale needs a number}"; shift ;;
	--steam)       WITH_STEAM=1 ;;
	--no-packages) DO_PACKAGES=0 ;;
	-h|--help)     usage; exit 0 ;;
	*)             echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

say()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "run this as your normal user, not root (it uses sudo where needed)"
command -v pacman >/dev/null || die "this installer is for Arch Linux (pacman not found)"
command -v sudo   >/dev/null || die "sudo is required"

BACKUP="$HOME/.desktop-backup/$(date +%Y%m%d-%H%M%S)"
REPLACED=()

backup_if_different() { # dest src
	local dest=$1 src=$2 rel
	if [ -e "$dest" ] && ! cmp -s "$src" "$dest"; then
		rel=${dest#"$HOME"/}
		mkdir -p "$BACKUP/$(dirname "$rel")"
		cp -a "$dest" "$BACKUP/$rel"
		REPLACED+=("$rel")
	fi
}

place() { # src dest
	local src=$1 dest=$2 mode=644
	[ -x "$src" ] && mode=755
	backup_if_different "$dest" "$src"
	install -Dm"$mode" "$src" "$dest"
}

# Root-owned files: an existing different one is kept next to it as .bak-<date>.
sudo_place() { # src dest
	cmp -s "$1" "$2" 2>/dev/null && return
	[ -e "$2" ] && sudo cp -a "$2" "$2.bak-$(date +%Y%m%d-%H%M%S)"
	sudo install -Dm644 "$1" "$2"
	echo "Installed $2"
}

# ---------------------------------------------------------------- passwordless sudo
# niri-update re-runs this installer unattended when a commit is pushed, so its sudo calls cannot
# ask for a password. This makes the user root-equivalent without one: anything running as this
# user, and anyone who can push to the repo, gets root. Undo: sudo rm /etc/sudoers.d/10-niri-update
SUDOERS=/etc/sudoers.d/10-niri-update
if ! sudo test -e "$SUDOERS"; then
	say "Passwordless sudo for $(id -un) (lets niri-update run this installer unattended)"
	tmp="$(mktemp)"
	echo "$(id -un) ALL=(ALL) NOPASSWD: ALL" > "$tmp"
	sudo visudo -cqf "$tmp" && sudo install -m440 "$tmp" "$SUDOERS"
	rm -f "$tmp"
fi
sudo rm -f /etc/sudoers.d/10-dwm-update   # its name before the rename

# ---------------------------------------------------------------- packages
if [ "$DO_PACKAGES" -eq 1 ]; then
	say "Installing packages (sudo password may be requested)"
	mapfile -t PKGS < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' packages.txt | grep -v '^$')
	# Only packages not installed yet. Naming an installed one to `pacman -S` upgrades it alone (a
	# partial upgrade), and --noconfirm even overrides IgnorePkg: that pulled a pinned xorg-server
	# forward and Xorg then crashed in the amdgpu driver. Upgrades stay with pacman -Syu.
	mapfile -t MISSING < <(pacman -T "${PKGS[@]}" || true)
	[ ${#MISSING[@]} -eq 0 ] || sudo pacman -S --noconfirm "${MISSING[@]}"
fi

# ---------------------------------------------------------------- dotfiles + scripts
say "Installing config files and scripts into $HOME"
while IFS= read -r -d '' f; do
	place "$f" "$HOME/${f#home/}"
done < <(find home -type f -print0)

# Files from the X11/dwm version of this setup that now get in the way (moved into the backup):
# the old portals.conf forced the GTK portal, which cannot share the screen under niri.
# The dwm- helpers and their timer and Anki add-on were renamed niri-: the old copies go too, or the old
# timer would keep running the old updater.
systemctl --user disable --now dwm-update.timer 2>/dev/null || true
for rel in .config/xdg-desktop-portal/portals.conf .config/systemd/user/dwm-mouse.service \
	.local/bin/dwm-blank .local/bin/dwm-shot .local/bin/keepassxc \
	.local/bin/dwm-audio .local/bin/dwm-mouse .local/bin/dwm-net .local/bin/dwm-power .local/bin/dwm-status.sh \
	.local/bin/dwm-todo .local/bin/dwm-tray .local/bin/dwm-update \
	.config/systemd/user/dwm-update.service .config/systemd/user/dwm-update.timer \
	.local/share/Anki2/addons21/dwm_todo; do
	[ -e "$HOME/$rel" ] || continue
	mkdir -p "$BACKUP/$(dirname "$rel")"
	mv "$HOME/$rel" "$BACKUP/$rel"
	REPLACED+=("$rel")
done

# The mouse speed saved with Mod+Shift+M goes into niri's config (mouse.kdl).
[ ! -e "$HOME/.config/dwm-mouse" ] || [ -e "$HOME/.config/niri-mouse" ] || mv "$HOME/.config/dwm-mouse" "$HOME/.config/niri-mouse"
"$HOME/.local/bin/niri-mouse" apply

# The todo daemon outlives niri restarts (niri starts apps in scopes of their own), so a running one
# would keep the old code: restart it. niri's own start of it at the next login then finds it running.
todo_daemon='/\.local/bin/(dwm|niri)-todo daemon'
if pkill -f "$todo_daemon"; then
	for _ in $(seq 50); do pgrep -f "$todo_daemon" >/dev/null || break; sleep 0.1; done
	systemd-run --user --collect -q "$HOME/.local/bin/niri-todo" daemon || warn "could not restart niri-todo; run: niri-todo daemon &"
fi

# ---------------------------------------------------------------- display scaling + refresh rate
# Monitors differ per machine, so their settings live in ~/.config/niri/local.kdl, not in the repo's
# config.kdl. Written on the first install (or with --scale) for every monitor connected now; after
# that a re-run leaves it alone, so edits made by hand stay put. Each monitor gets its native
# resolution without a refresh rate, which makes niri pick the fastest one: a monitor's "preferred"
# mode is often 60 Hz even on a 240 Hz panel, and fullscreen games then only offer 60 Hz.
LOCAL_KDL="$HOME/.config/niri/local.kdl"
if [ -n "$SCALE" ] || [ ! -e "$LOCAL_KDL" ]; then
	if [ -z "$SCALE" ]; then
		dpi="$(awk '/^Xft\.dpi:/{ if (int($2) > 0) print int($2); exit }' "$HOME/.Xresources" 2>/dev/null || true)"
		SCALE="$(awk -v d="${dpi:-96}" 'BEGIN { print d / 96 }')"
	fi
	awk -v s="$SCALE" 'BEGIN { exit !(s ~ /^[0-9]*\.?[0-9]+$/ && s >= 0.5 && s <= 4) }' \
		|| die "--scale must be a number from 0.5 to 4, got '$SCALE'"
	say "Display scaling: $SCALE"
	tmp="$(mktemp)"
	{
		echo "// This machine's monitors; niri applies changes on save. Names and modes: niri msg outputs"
		echo "// Other options: mode \"2560x1440@143.912\", variable-refresh-rate, position x=0 y=0"
		for s in /sys/class/drm/card*-*/status; do
			[ "$(cat "$s")" = connected ] || continue
			d="${s%/status}"; name="${d##*/}"; name="${name#card*-}"; mode="$(head -n1 "$d/modes")"
			printf 'output "%s" {\n' "$name"
			[ -z "$mode" ] || printf '    mode "%s"\n' "$mode"
			printf '    scale %s\n}\n' "$SCALE"
		done
	} > "$tmp"
	place "$tmp" "$LOCAL_KDL"
	rm -f "$tmp"
fi

# ---------------------------------------------------------------- Firefox
find_ff_profile() {
	local base d
	for base in "$HOME/.config/mozilla/firefox" "$HOME/.mozilla/firefox"; do
		for d in "$base"/*.default-release; do
			[ -d "$d" ] && { printf '%s\n' "$d"; return 0; }
		done
	done
	return 1
}

say "Firefox settings"
if command -v firefox >/dev/null; then
	FF_PROFILE="$(find_ff_profile || true)"
	if [ -z "$FF_PROFILE" ]; then
		echo "No Firefox profile yet; starting Firefox headless once to create it..."
		timeout 20 firefox --headless --no-remote about:blank >/dev/null 2>&1 || true
		FF_PROFILE="$(find_ff_profile || true)"
	fi
	if [ -n "$FF_PROFILE" ]; then
		place firefox/user.js "$FF_PROFILE/user.js"
		echo "Installed user.js into $FF_PROFILE (restart Firefox to apply)"
	else
		warn "could not find/create a Firefox profile. Start Firefox once, close it, then run:"
		warn "  ./install.sh --no-packages --no-build"
	fi
	# Extensions (uBlock Origin, Violentmonkey) come from a system-wide Firefox policy, so they are
	# installed automatically the next time Firefox starts. Needs root because it lives in /etc.
	# The Always-visible userscript ships in this repo, but Violentmonkey keeps its scripts in its
	# own storage, which a policy cannot seed, so it is imported by hand once (see the line printed).
	sudo_place firefox/policies.json /etc/firefox/policies/policies.json
	# Links opened from other programs (niri-todo, chat apps) go to Firefox, not another installed browser.
	{ xdg-settings set default-web-browser firefox.desktop && xdg-mime default firefox.desktop text/html; } \
		|| warn "could not make Firefox the default browser; run: xdg-settings set default-web-browser firefox.desktop"
	echo "Violentmonkey will auto-install; import the userscript once by opening this in Firefox:"
	echo "  file://$PWD/firefox/always-visible.user.js   (Violentmonkey shows an install page)"
else
	warn "firefox is not installed; skipping its settings"
fi

# The 70- rule lets the mouse menu (Mod+Shift+M) read a Razer mouse's DPI without root. The 90- rule
# from the X11 version re-applied mouse settings on replug; niri does that itself now.
say "udev: Razer DPI access"
sudo_place etc/udev/rules.d/70-niri-mouse-dpi.rules /etc/udev/rules.d/70-niri-mouse-dpi.rules
sudo rm -f /etc/udev/rules.d/90-dwm-mouse.rules /etc/udev/rules.d/70-dwm-mouse-dpi.rules   # older names
sudo udevadm control --reload || warn "could not reload udev rules; they take effect after a reboot"
sudo udevadm trigger --subsystem-match=hidraw --action=change 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true

# ---------------------------------------------------------------- local hostnames (mDNS)
# Avahi announces this machine as <hostname>.local, and nss-mdns lets ssh, ping, etc.
# look up other machines' .local names. Adds mdns_minimal to the hosts: line only once.
say "mDNS: .local hostnames"
if [ -e /usr/lib/libnss_mdns_minimal.so.2 ]; then
	if ! grep -q '^hosts:.*mdns' /etc/nsswitch.conf; then
		sudo cp -a /etc/nsswitch.conf "/etc/nsswitch.conf.bak-$(date +%Y%m%d-%H%M%S)"
		sudo sed -Ei '/^hosts:/s/ (resolve|files)/ mdns_minimal [NOTFOUND=return] \1/' /etc/nsswitch.conf
	fi
	sudo systemctl enable --now avahi-daemon \
		|| warn "could not start avahi; run: sudo systemctl enable --now avahi-daemon"
else
	warn "nss-mdns is not installed; skipping .local hostnames"
fi

# ---------------------------------------------------------------- printing (Canon MX920)
# The MX920's driverless (IPP Everywhere) setup fails: its firmware leaves out the attributes CUPS
# needs ("PPD creation failed"), so the queue uses Gutenprint's driver instead. The printer is reached
# by its mDNS name, so a new IP from the router does not break it. Added only if the queue is missing.
# The queue takes the name CUPS gives the discovered printer, which hides that broken driverless
# entry from print dialogs (Firefox had remembered it, so its jobs went nowhere).
say "Printing: CUPS and the Canon MX920"
if command -v lpadmin >/dev/null; then
	sudo systemctl enable --now cups || warn "could not start CUPS; run: sudo systemctl enable --now cups"
	if ! lpstat -p Canon_MX920_series >/dev/null 2>&1; then
		sudo lpadmin -p Canon_MX920_series -E -v ipp://488E78000000.local/ipp/print -m gutenprint.5.3://bjc-MX920-series/expert \
			&& lpoptions -d Canon_MX920_series >/dev/null \
			|| warn "could not add the MX920 printer; run the lpadmin line above by hand to see why"
	fi
else
	warn "cups is not installed; skipping the printer"
fi

# ---------------------------------------------------------------- Syncthing (KeePassXC sync)
# Only the service is set up here. Device keys and the folder/device pairing live in
# ~/.local/state/syncthing and are never in this repo; pair devices at http://127.0.0.1:8384.
say "Tailscale and ssh arch-server"
# ~/.ssh/config stays this machine's own file; the repo's host entries come in through an Include.
SSH_INCLUDE='Include ~/.ssh/config.d/*.conf'
touch "$HOME/.ssh/config" && chmod 600 "$HOME/.ssh/config"
if ! grep -qxF "$SSH_INCLUDE" "$HOME/.ssh/config"; then
	if [ -s "$HOME/.ssh/config" ]; then sed -i "1i $SSH_INCLUDE" "$HOME/.ssh/config"; else echo "$SSH_INCLUDE" > "$HOME/.ssh/config"; fi
fi
if command -v tailscale >/dev/null; then
	sudo systemctl enable --now tailscaled || warn "could not start tailscaled; run: sudo systemctl enable --now tailscaled"
	tailscale status >/dev/null 2>&1 || warn "Tailscale is not logged in yet; run once: sudo tailscale up"
fi

say "Syncthing: start now and at every login"
if command -v syncthing >/dev/null; then
	systemctl --user enable --now syncthing \
		|| warn "could not start syncthing; after logging in run: systemctl --user enable --now syncthing"
else
	warn "syncthing is not installed; skipping"
fi

# ---------------------------------------------------------------- auto-update
# niri-update.timer pulls this clone every 5 minutes and re-runs this installer on new commits.
say "Auto-update: pull and reinstall on new commits"
ln -sfn "$PWD" "$HOME/.local/share/arch-dwm-desktop"
systemctl --user enable --now niri-update.timer \
	|| warn "could not start the auto-update timer; after logging in run: systemctl --user enable --now niri-update.timer"

# ---------------------------------------------------------------- git identity
# GitHub noreply address, so commits work and push without exposing an email.
say "git: commit name and email"
git config --global user.name 5TN1rcZRS79VAEFuUCRB
git config --global user.email 327155685+5TN1rcZRS79VAEFuUCRB@users.noreply.github.com

# ---------------------------------------------------------------- Claude Code add-ons
# ponytail + caveman plugins, and the caveman proxy routed in front of Claude Code
# (caveman's SessionStart hook starts the proxy each session). Undo: caveman disable claude
say "Claude Code: ponytail and caveman plugins, caveman proxy"
if command -v claude >/dev/null; then
	{
		claude plugin marketplace add DietrichGebert/ponytail \
			&& claude plugin install ponytail@ponytail \
			&& claude plugin marketplace add JuliusBrussee/caveman \
			&& claude plugin install caveman@caveman \
			&& npm install -g --prefix "$HOME/.local" @caveman-ai/cli \
			&& "$HOME/.local/bin/caveman" setup --install \
			&& "$HOME/.local/bin/caveman" enable claude
	} || warn "Claude add-ons failed (often a download hiccup); rerun: ./install.sh --no-packages --no-build"
else
	warn "Claude Code is not installed; skipping. Install it (curl -fsSL https://claude.ai/install.sh | bash), then rerun"
fi

# ---------------------------------------------------------------- GTK dark preference (dconf)
say "GTK/desktop dark preference"
dconf_write() {
	if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
		dconf write "$1" "$2"
	else
		dbus-run-session -- dconf write "$1" "$2"
	fi
}
if command -v dconf >/dev/null; then
	dconf_write /org/gnome/desktop/interface/color-scheme "'prefer-dark'" \
		|| warn "could not write the dark preference; run: gsettings set org.gnome.desktop.interface color-scheme prefer-dark"
else
	warn "dconf is not installed; skipping the desktop dark preference"
fi

# ---------------------------------------------------------------- Steam (optional)
if [ "$WITH_STEAM" -eq 1 ]; then
	say "Steam"
	if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
		warn "[multilib] is not enabled in /etc/pacman.conf. Uncomment the [multilib] section"
		warn "(and its Include line), run 'sudo pacman -Sy', then rerun with --steam."
	else
		gpu="$(lspci 2>/dev/null | grep -Ei 'vga|3d' || true)"
		libs=()
		case "$gpu" in
		*[Nn][Vv][Ii][Dd][Ii][Aa]*) libs+=(lib32-nvidia-utils) ;;
		*AMD*|*ATI*|*Radeon*)      libs+=(lib32-vulkan-radeon) ;;
		*Intel*)                   libs+=(lib32-vulkan-intel) ;;
		esac
		[ ${#libs[@]} -gt 0 ] || warn "unrecognised GPU; you may be asked to pick a 32-bit Vulkan driver"
		sudo pacman -S --needed --noconfirm "${libs[@]}" steam
	fi
fi

# ---------------------------------------------------------------- done
say "Done"
# niri-update compares this with the pulled commit to know whether to install again.
mkdir -p "$HOME/.local/state"
git rev-parse HEAD > "$HOME/.local/state/arch-dwm-desktop-installed"
# Hand edits to these files are gone from the live copies; copy back into the repo any worth keeping.
if [ ${#REPLACED[@]} -gt 0 ]; then
	warn "these files differed from the repo and were replaced or removed (old copies in $BACKUP):"
	printf '  ~/%s\n' "${REPLACED[@]}" >&2
fi
cat <<EOF

Next steps:
  1. Log out, then log in on the first text console (Ctrl+Alt+F1): niri starts automatically.
     (On another console, or after quitting niri, run:  niri-session)
  2. Mod is the Super/Windows key. Mod+Shift+Enter opens a terminal, Mod+P a launcher,
     Mod+Shift+/ lists every key. See README.md.
  3. NVIDIA card? Install the driver yourself first (e.g. 'sudo pacman -S nvidia-open'),
     since the right package depends on your GPU and kernel. It is not part of this repo.
  4. Display too big/small?  ./install.sh --no-packages --scale 1.25   (or 1.5, 2...),
     or edit ~/.config/niri/local.kdl, which applies the moment you save it.
EOF
