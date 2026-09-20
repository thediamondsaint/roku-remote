-- Roku remote: paste into ~/.config/hypr/hyprland.lua (window rule) and ~/.config/hypr/bindings.lua (binds).
-- Then run: hyprctl reload && hyprctl configerrors

-- Window rule: small floating remote pinned to the right edge, no border/shadow (the remote draws its own body).
o.window({ title = "^Roku Remote$" }, {
  float = true,
  pin = true,
  border_size = 0,
  no_shadow = true,
  no_blur = true,
  tag = "-default-opacity",
  opacity = "1 1",
  move = { "(monitor_w-window_w-20)", "(monitor_h/2-window_h/2)" },
})

-- Keybinds: SUPER+ALT+R toggles the remote; SUPER+CTRL + volume keys control the TV's volume.
o.bind("SUPER + ALT + R", "Roku remote", "omarchy-shell shell toggle charles.roku-remote '{}'")
o.bind("SUPER + CTRL + XF86AudioRaiseVolume", "TV volume up", "roku volup", { locked = true, repeating = true })
o.bind("SUPER + CTRL + XF86AudioLowerVolume", "TV volume down", "roku voldown", { locked = true, repeating = true })
o.bind("SUPER + CTRL + XF86AudioMute", "TV mute", "roku mute", { locked = true })
