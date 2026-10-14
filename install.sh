#!/usr/bin/env bash
# Optional helper: puts the bundled `roku` CLI on your PATH and shows the Hyprland snippets.
# The plugin itself works without this (it uses bin/roku directly); this is for the terminal
# command and the TV-volume keybinds.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$HOME/.local/bin"
ln -sf "$here/bin/roku" "$HOME/.local/bin/roku"
ln -sf "$here/bin/roku-inventory" "$HOME/.local/bin/roku-inventory"
mkdir -p "$HOME/.local/share/applications"
cat > "$HOME/.local/share/applications/roku-inventory.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Roku Inventory
Comment=Browse Roku devices, apps, and playback details on your local network
Exec="$HOME/.local/bin/roku-inventory"
Icon=video-display
Terminal=false
Categories=Utility;Network;
EOF
echo "Installed Roku CLI, inventory viewer, and Roku Inventory launcher"
echo
echo "Add the window rule and keybinds from:"
echo "  $here/extras/hyprland.lua"
echo "into ~/.config/hypr/hyprland.lua and ~/.config/hypr/bindings.lua, then:"
echo "  hyprctl reload && hyprctl configerrors"
echo
echo "Then run:  roku list   # find your Rokus,   roku default <name>   # pick your TV"
