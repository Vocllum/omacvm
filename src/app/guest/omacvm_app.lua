-- OmacVM.app: Hyprland draws the pointer (Omarchy's cursor); QEMU shows it
-- over the VM window and hides the Mac's. Written by OmacVM; changes here are
-- overwritten.
-- A config reload brings back the cached mode; apply the window's again.
hl.on("config.reloaded", function()
  hl.exec_cmd("/usr/local/bin/omacvm-display-sync --once")
end)
