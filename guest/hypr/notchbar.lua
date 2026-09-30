-- omarchy-notch-bar: hidden output that renders the bar for the macOS notch helper.
--
-- It overlaps the top edge of the built-in display (Virtual-1), so it stays
-- inside the existing monitor layout: absolute pointers (the Parallels mouse,
-- UTM's USB tablet) keep their mapping, and the pointer never lands on it.
-- notchcast keeps its width equal to the built-in display and its height equal
-- to the Mac's strip (the menu bar height, which depends on the MacBook model
-- and its resolution).
-- install.sh fills in NOTCHBAR_OUTPUT / NOTCHBAR_SCREEN if they are set.
local NOTCH_OUTPUT = "NOTCH"
local BUILTIN_OUTPUT = "Virtual-1"

-- Start out right on a config reload: the built-in display's width, position
-- and scale, and the logical height notchcast last gave the output (it
-- corrects anything else within two seconds).
local function logical_height()
  local state = os.getenv("XDG_STATE_HOME") or ((os.getenv("HOME") or "") .. "/.local/state")
  local f = io.open(state .. "/omanotch/strip-height", "r")
  if not f then return 26 end
  local h = tonumber(f:read("l"))
  f:close()
  return (h and h >= 10 and h <= 200) and h or 26
end

local function notch_rule()
  for _, m in ipairs(hl.get_monitors()) do
    if m.name == BUILTIN_OUTPUT and m.width and m.width > 0 then
      local s = m.scale or 2
      local p = type(m.position) == "table" and m.position or {}
      -- A whole number of pixels at this scale, as notchcast does it.
      local lh = logical_height()
      for _ = 1, 120 do
        if math.abs(lh * s - math.floor(lh * s + 0.5)) <= 1e-3 then break end
        lh = lh + 1
      end
      return {
        output = NOTCH_OUTPUT,
        mode = string.format("%dx%d@60", m.width, math.floor(lh * s + 0.5)),
        position = string.format("%dx%d", p.x or p[1] or 0, p.y or p[2] or 0),
        scale = s,
      }
    end
  end
  -- Before the built-in display exists (first start): notchcast sizes it later.
  return { output = NOTCH_OUTPUT, mode = "1024x52@60", position = "0x0", scale = 2 }
end

hl.monitor(notch_rule())

-- Its own workspace, so no real workspace or window is ever moved onto it.
hl.workspace_rule({ workspace = "name:notch", monitor = NOTCH_OUTPUT, default = true, persistent = true })

-- Keyboard focus cycling could still select the hidden output; hand focus back
-- to the built-in display without moving the cursor (and without touching the
-- user's own cursor.no_warps setting).
hl.on("monitor.focused", function(m)
  if not m or m.name ~= NOTCH_OUTPUT then return end
  hl.timer(function()
    local ok, previous = pcall(hl.get_config, "cursor.no_warps")
    hl.config({ cursor = { no_warps = true } })
    hl.dispatch(hl.dsp.focus({ monitor = BUILTIN_OUTPUT }))
    hl.config({ cursor = { no_warps = ok and previous == true } })
  end, { timeout = 1, type = "oneshot" })
end)

-- The overlap with the built-in display is deliberate (see above), but
-- Hyprland warns about any overlapping monitors after every layout change
-- ("Your monitor layout is set up incorrectly. Monitor NOTCH overlaps …").
-- Dismiss that one warning, and only when it names the NOTCH output.
local function dismiss_notch_overlap_warning()
  for _, n in ipairs(hl.notification.get()) do
    local text = n:get_text()
    if type(text) == "string" and text:find(NOTCH_OUTPUT, 1, true) then n:dismiss() end
  end
end

local function schedule_dismiss()
  for _, ms in ipairs({ 1, 40, 200, 1000 }) do
    hl.timer(dismiss_notch_overlap_warning, { timeout = ms, type = "oneshot" })
  end
end

hl.on("monitor.layout_changed", schedule_dismiss)
hl.on("monitor.added", schedule_dismiss)
hl.on("config.reloaded", schedule_dismiss)
schedule_dismiss()
