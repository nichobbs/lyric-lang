# D197 - `lyric-gpu`: window surfaces and presentation

**Status:** accepted, implemented for `--target native` on X11 and Wayland handles (docs/67 phases G4 and G5, #7944); extends D194, D195 and D196

## Decision

1. **Surfaces.** `createXlibSurface(device, display, window)` and `createWaylandSurface(device,
   display, surface)` take the raw window-system handles `Window.nativeWindow` returns as `Long`s,
   so `lyric-gpu` does not depend on `lyric-window`; an application passes one to the other.
   `configureSurface` sets the size (call it again after a resize), picks RGBA8 when the surface
   offers it and its first format otherwise, and presents vsynced (FIFO).
2. **Frames.** `acquireFrame` returns a `RenderTarget` for the surface's current texture (an `Err`
   means reconfigure and retry next frame); `render` draws into it like into an offscreen target;
   `presentFrame` presents it and releases the frame's view and texture.
3. **Target format.** `RenderTarget` carries its `format`, and `createRenderPipeline` takes the
   target format (`formatRgba8` for offscreen targets, `Surface.format` for surfaces), because a
   surface's format is the window system's choice (BGRA, sRGB) and a pipeline must match it.
   This changes D196's `createRenderPipeline` signature.
4. **Adapter compatibility.** `withDevice` still picks the first adapter without a compatible
   surface, which holds on a single-GPU machine and a software Vulkan device; selecting an adapter
   by surface for multi-GPU machines is tracked in #8404.
5. **Test.** `lyric-gpu/examples/window` opens an SDL3 window on the X11 video driver, presents a
   red triangle on blue through a wgpu surface, and `scripts/ci/gpu-window-e2e.sh` screenshots the
   Xvfb display and counts the two colours. CI builds SDL3 once with its X11 driver
   (`scripts/ci/build-sdl3.sh --x11`) for this and the headless window demo.

## Not in this slice

Cocoa (`CAMetalLayer`) and Win32 surfaces, adapter selection by surface, present modes other than
FIFO, and multi-window.
