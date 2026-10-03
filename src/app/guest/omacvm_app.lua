-- OmacVM.app: Hyprland draws the pointer (Omarchy's cursor) into the picture;
-- QEMU hides the Mac's over the VM window. Software cursor: virtio-gpu's cursor
-- plane stayed empty here. Written by OmacVM; changes here are overwritten.
hl.config({ cursor = { no_hardware_cursors = 1 } })
-- A config reload brings back the cached mode; apply the window's again.
hl.on("config.reloaded", function()
  hl.exec_cmd("/usr/local/bin/omacvm-display-sync --once")
end)
