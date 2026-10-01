
-- OmacVM: Cmd+V pastes everywhere, like on the Mac. Terminals get
-- Ctrl+Shift+V, other apps Ctrl+V (Shift+Insert does not get through reliably
-- with a Mac keyboard in Parallels).
hl.unbind("SUPER + V")
o.bind("SUPER + V", "Universal paste", function()
  local window = hl.get_active_window()
  local is_terminal = false
  for _, tag in ipairs((window and window.tags) or {}) do
    if tag:gsub("%*$", "") == "terminal" then is_terminal = true end
  end
  local mods = is_terminal and "CTRL + SHIFT" or "CTRL"
  hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = "V", state = "down" }))
  hl.timer(function()
    hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = "V", state = "up" }))
  end, { timeout = 50, type = "oneshot" })
end)
