-- Omaparallels: Parallels (virtio-gpu) monitors, kept in sync by parallels-dynres.
-- "preferred" = the mode Parallels pushes for the current window / display size.
local omarchy_gdk_scale = 2
local omarchy_monitor_scale = 2

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))

-- parallels-dynres saves the layout it has applied. Using it here means a
-- config reload (every theme switch) keeps the current resolution, instead
-- of dropping to "preferred" (1024x768) until parallels-dynres catches up.
local layout = (os.getenv("XDG_STATE_HOME") or ((os.getenv("HOME") or "") .. "/.local/state"))
  .. "/parallels-dynres/monitors"
local saved = {}
local f = io.open(layout, "r")
if f then
  for line in f:lines() do
    local name, mode, position, scale = line:match("^(%S+) (%S+) (%S+) (%S+)$")
    if name and tonumber(scale) then
      -- The built-in display keeps the scale chosen in Omarchy's menu.
      if name == "Virtual-1" then scale = omarchy_monitor_scale end
      hl.monitor({ output = name, mode = mode, position = position, scale = tonumber(scale) })
      saved[name] = true
    end
  end
  f:close()
end

-- Primary head (Parallels window, or the first display in full screen)
if not saved["Virtual-1"] then
  hl.monitor({ output = "Virtual-1", mode = "preferred", position = "0x0", scale = omarchy_monitor_scale })
end
-- Any further head (external monitors when "use all displays in full screen" is on).
-- parallels-dynres corrects the scale per display (2 for HiDPI, 1 otherwise).
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 2 })
