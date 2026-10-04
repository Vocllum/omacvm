# 0010: Show the guest's frames as IOSurfaces

## Context

OmacVM.app's QEMU shows the guest's GL scanout with the Cocoa display. It drew
the scanout in a `CAOpenGLLayer` on the AppKit main thread, holding QEMU's
big lock (BQL) while it drew, and only on QEMU's 30 ms GUI refresh tick. The
window showed at most 33 frames a second, and the main thread and QEMU's
thread waited on each other every frame.

## Options

1. Keep `CAOpenGLLayer`, redraw on each flush. Simple, but GL drawing and the
   BQL stay on the main thread.
2. Blit the scanout into IOSurfaces on QEMU's thread and set them as a plain
   `CALayer`'s contents. One GPU copy, no GL and no BQL on the main thread,
   Core Animation composites the surface directly.
3. Make the guest's scanout textures IOSurfaces (no copy at all). CGL binds
   IOSurfaces only as `GL_TEXTURE_RECTANGLE`; the guest samples its textures
   as 2D, so virglrenderer would need a rectangle-aware path for every
   shader that reads a scanout (screencopy, blur). Too invasive for now.
4. A Metal layer (`CAMetalLayer`) fed from GL through IOSurfaces: same copy
   as 2, plus a Metal device and command queue, no gain over 2.

## Decision

Option 2, after option 1 as a separate patch (redraw on flush), so either can
be taken alone. Three surfaces, reused only when `IOSurfaceIsInUse` says Core
Animation is done; a serial queue waits for the blit's fence before the main
thread gets the surface; at most one surface per display refresh.

## Consequences

- The window follows the guest's frame rate up to the display's refresh.
- The main thread never waits for the BQL to draw.
- `OMACVM_GL_PRESENT=layer` keeps the old layer for comparison or if an
  IOSurface problem appears; failure to create the contexts falls back by
  itself.
- Option 3 stays open if the copy ever shows up in profiles.
