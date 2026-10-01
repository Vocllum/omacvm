
-- Omaparallels: Parallels Tools briefly opens an invisible helper window to sync
-- the clipboard whenever the VM gains focus. Keep it out of the tiling layout.
o.window({ title = "^Parallels Shared Clipboard$" }, {
  float = true,
  size = { 1, 1 },
  move = { 0, 0 },
  border_size = 0,
  no_anim = true,
  no_shadow = true,
  no_blur = true,
  opacity = "0 0",
})
