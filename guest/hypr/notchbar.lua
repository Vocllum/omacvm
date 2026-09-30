-- omarchy-notch-bar: hidden output that renders the bar for the macOS notch helper.
--
-- It overlaps the top edge of the built-in display (Virtual-1), so it stays
-- inside the existing monitor layout: absolute pointers such as the Parallels
-- mouse keep their mapping, and the pointer never lands on it. notchcast keeps
-- its width equal to the built-in display and its height equal to the bar.
hl.monitor({ output = "NOTCH", mode = "4112x52@60", position = "0x0", scale = 2 })

-- Its own workspace, so no real workspace or window is ever moved onto it.
hl.workspace_rule({ workspace = "name:notch", monitor = "NOTCH", default = true, persistent = true })

-- Keyboard focus cycling could still select the hidden output; hand focus back
-- to the built-in display without moving the cursor.
hl.on("monitor.focused", function(m)
  if not m or m.name ~= "NOTCH" then return end
  hl.timer(function()
    hl.config({ cursor = { no_warps = true } })
    hl.dispatch(hl.dsp.focus({ monitor = "Virtual-1" }))
    hl.config({ cursor = { no_warps = false } })
  end, { timeout = 1, type = "oneshot" })
end)
