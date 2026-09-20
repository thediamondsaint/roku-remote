#!/usr/bin/env bash
# Optional helper: puts the bundled `roku` CLI on your PATH and shows the Hyprland snippets.
# The plugin itself works without this (it uses bin/roku directly); this is for the terminal
# command and the TV-volume keybinds.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$HOME/.local/bin"
ln -sf "$here/bin/roku" "$HOME/.local/bin/roku"
echo "Linked: ~/.local/bin/roku -> $here/bin/roku"
echo
echo "Add the window rule and keybinds from:"
echo "  $here/extras/hyprland.lua"
echo "into ~/.config/hypr/hyprland.lua and ~/.config/hypr/bindings.lua, then:"
echo "  hyprctl reload && hyprctl configerrors"
echo
echo "Then run:  roku list   # find your Rokus,   roku default <name>   # pick your TV"
