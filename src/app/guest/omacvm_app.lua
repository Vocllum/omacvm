-- OmacVM.app: macOS draws the pointer over the VM window, so hide Hyprland's.
-- Written by OmacVM; changes here are overwritten.
hl.config({ cursor = { invisible = true } })
-- A config reload brings back the cached mode; apply the window's again.
hl.on("config.reloaded", function()
  hl.exec_cmd("/usr/local/bin/omacvm-display-sync --once")
end)
