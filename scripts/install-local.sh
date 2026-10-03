#!/usr/bin/env sh
set -eu

# Install the locally built bridge and the user-level SSH watcher unit. Run on
# the desktop machine from which SSH connections are opened, not on the server.
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
install -Dm755 "$root/target/release/jet-interactive" "$HOME/.local/bin/jet-interactive"
install -Dm644 "$root/contrib/jet-interactive-watch@.service" \
  "$HOME/.config/systemd/user/jet-interactive-watch@.service"
systemctl --user daemon-reload

printf '%s\n' 'Installed jet-interactive and its watcher unit.'
printf '%s\n' 'Enable a host with: systemctl --user enable --now jet-interactive-watch@odisseo.service'
