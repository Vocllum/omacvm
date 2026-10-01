-- Separate workspaces per monitor: SUPER + 1..0 always means "1..0 on the
-- monitor I'm on", instead of jumping to wherever workspace N happens to live.
--
-- Parallels VM: the main display is Virtual-1 (the VM window, or the first
-- display in full screen); further displays are Virtual-2, ... Omanotch's
-- hidden NOTCH output overlaps Virtual-1 and is never an external monitor.
--
-- Hyprland has one global list of workspace IDs, and each ID belongs to one
-- monitor, so two "workspace 2"s cannot share an ID. The notebook keeps the
-- real IDs 1..10; the external monitor uses 11..20 (offset 10). The keys and
-- the bar widget (plugin omacvm.workspaces) subtract the offset again,
-- so 11..20 never show up anywhere you look.
--
-- Used by hypr/bindings.lua (monitor_workspaces.workspace(n)).

local M = {}

M.LAPTOP = "Virtual-1"
M.OFFSET = 10

-- Outputs that are not real screens (Omanotch's hidden NOTCH output).
local function ignored(name)
  return name:find("^NOTCH") ~= nil
end

function M.offset(monitor)
  if not monitor or not monitor.name or monitor.name == M.LAPTOP or ignored(monitor.name) then
    return 0
  end
  return M.OFFSET
end

-- Workspace N (1..10) on the focused monitor, as a workspace selector string.
function M.workspace(n)
  return tostring(n + M.offset(hl.get_active_monitor()))
end

local function external_name()
  for _, monitor in ipairs(hl.get_monitors() or {}) do
    if monitor.name and monitor.name ~= M.LAPTOP and not ignored(monitor.name) and not monitor.is_mirror then
      return monitor.name
    end
  end
  return nil
end

local function workspace_ids()
  local ids = {}
  for _, ws in ipairs(hl.get_workspaces() or {}) do
    if ws.id and ws.id > 0 then
      ids[ws.id] = ws
    end
  end
  return ids
end

-- Parking: unplugging moves 11..20 to the notebook, where the keys and the bar
-- only reach 1..10. So each one is renumbered in place into a free notebook
-- slot (windows stay put), and the record "slot original" is kept in a file so
-- replugging can put it back. A file, not a Lua table, so it survives
-- `hyprctl reload` while unplugged. Cleared when Hyprland starts, because a
-- record from an earlier session would point at unrelated workspaces.
local PARKED = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/hypr-parked-workspaces"

local function read_parked()
  local parked = {}
  local f = io.open(PARKED, "r")
  if not f then
    return parked
  end
  for line in f:lines() do
    local slot, original = line:match("^(%d+) (%d+)$")
    if slot then
      parked[tonumber(slot)] = tonumber(original)
    end
  end
  f:close()
  return parked
end

local function write_parked(parked)
  if next(parked) == nil then
    os.remove(PARKED)
    return
  end
  local f = io.open(PARKED, "w")
  if not f then
    return
  end
  for slot, original in pairs(parked) do
    f:write(slot, " ", original, "\n")
  end
  f:close()
end

local function change_id(from, to)
  hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(from), id = to }))
end

-- Without an external: renumber every 11..20 into the lowest free 1..10, in
-- order. If the notebook is full, the rest keep their 11+ IDs.
local function park()
  if external_name() then
    return
  end

  local ids = workspace_ids()
  local stray = {}
  for id in pairs(ids) do
    if id > M.OFFSET and id <= 2 * M.OFFSET then
      table.insert(stray, id)
    end
  end
  if #stray == 0 then
    return
  end
  table.sort(stray)

  local parked = read_parked()
  local slot = 1
  for _, original in ipairs(stray) do
    while slot <= M.OFFSET and ids[slot] do
      slot = slot + 1
    end
    if slot > M.OFFSET then
      break
    end
    change_id(original, slot)
    parked[slot] = original
    ids[slot] = true
  end
  write_parked(parked)
end

-- With an external back: give each parked workspace that still exists its
-- original ID again. pin() then moves it to the external. An emptied parked
-- workspace is gone and simply dropped.
local function unpark()
  local parked = read_parked()
  if next(parked) == nil then
    return
  end

  local ids = workspace_ids()
  for slot, original in pairs(parked) do
    if ids[slot] and not ids[original] then
      change_id(slot, original)
    end
  end
  write_parked({})
end

-- Pin each range to its monitor, so a workspace created by moving a window to
-- it opens on the right screen. The external's name (DP-1, DP-2, ...) depends
-- on the port, so its rules are rewritten whenever a monitor appears.
local function pin()
  for n = 1, M.OFFSET do
    hl.workspace_rule({ workspace = tostring(n), monitor = M.LAPTOP })
  end

  local external = external_name()
  if not external then
    return
  end

  for n = M.OFFSET + 1, 2 * M.OFFSET do
    hl.workspace_rule({ workspace = tostring(n), monitor = external })
  end

  -- Unplugging parks 11..20 on the notebook. The rules above may land after
  -- Hyprland has already placed workspaces for the new monitor, so hand the
  -- external's range back explicitly.
  for _, ws in ipairs(hl.get_workspaces() or {}) do
    if ws.id and ws.id > M.OFFSET and ws.id <= 2 * M.OFFSET
        and ws.monitor and ws.monitor.name ~= external then
      hl.dispatch(hl.dsp.workspace.move({ workspace = tostring(ws.id), monitor = external }))
    end
  end
end

-- Deferred: while the event runs, the unplugged monitor may still be listed
-- and its workspaces not yet handed to the notebook.
local function later(fn)
  hl.timer(fn, { timeout = 300, type = "oneshot" })
end

-- Exposed for testing by hand: hyprctl eval 'require("hypr.monitor_workspaces").unpark()'
M.park, M.unpark = park, unpark

pin()
park() -- also covers a reload while unplugged
hl.on("monitor.added", function()
  pin()
  later(function()
    unpark()
    pin()
  end)
end)
hl.on("monitor.removed", function() later(park) end)
hl.on("hyprland.start", function() write_parked({}) end)

return M
