
-- >>> OmacVM per-display workspaces
-- SUPER + 1..0 act on the focused display's own workspaces, like Spaces on the
-- Mac (an external display uses IDs 11..20, shown as 1..0; see
-- hypr/monitor_workspaces.lua). Keys by physical code (code:10..19 = the number
-- row), so the keyboard layout does not matter.
local monitor_workspaces = require("hypr.monitor_workspaces")
for workspace = 1, 10 do
  local key = "code:" .. tostring(workspace + 9)
  local function here() return monitor_workspaces.workspace(workspace) end
  hl.unbind("SUPER + " .. key)
  o.bind("SUPER + " .. key, "Switch to workspace " .. workspace,
    function() hl.dispatch(hl.dsp.focus({ workspace = here() })) end)
  hl.unbind("SUPER + SHIFT + " .. key)
  o.bind("SUPER + SHIFT + " .. key, "Move window to workspace " .. workspace,
    function() hl.dispatch(hl.dsp.window.move({ workspace = here() })) end)
  hl.unbind("SUPER + SHIFT + ALT + " .. key)
  o.bind("SUPER + SHIFT + ALT + " .. key, "Move window silently to workspace " .. workspace,
    function() hl.dispatch(hl.dsp.window.move({ workspace = here(), follow = false })) end)
end
-- <<< OmacVM per-display workspaces
