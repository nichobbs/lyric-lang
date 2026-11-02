# D317 - Metal surfaces for macOS windows, and the `GpuWindow` bridge

**Status:** accepted, implemented for `--target native` on macOS (docs/67 phases G5 and G7, #7946, #8563)

## Decision

1. **A macOS `lyric-window` window owns a Metal view.** `Window.createWindow` asks for `SDL_WINDOW_METAL` when
   the video driver (`SDL_GetCurrentVideoDriver()`) is `cocoa` (the offscreen and dummy drivers cannot make Metal windows,
   even on macOS, and the macOS CI demo runs on them), creates the `SDL_Metal_CreateView` view straight away, and `Window.destroyWindow`
   destroys that view before the window. `Window` gains a `metalView` field (0 off macOS). Tying the view to the window
   record, not to a lazily created handle, gives it exactly the window's lifetime without a second thing to release.
2. **`Window.metalLayer(w): Result[Long, String]`** returns the view's `CAMetalLayer*`. `Window.nativeWindow` still
   returns `Cocoa(window)` with the `NSWindow*`: that is what the window system calls its handle and what other
   consumers (menus, full-screen, accessibility) want, while a surface wants the layer. Returning the layer from
   `nativeWindow` would make the `NativeWindow` union stop describing the window.
3. **`Gpu.createMetalSurface(d, layer)`** builds the surface from `WGPUSurfaceSourceMetalLayer`, with the error handling
   of the other surface constructors.
4. **One `surfaceFor`.** The three copies (`Game.Run`, the `lyric-gpu` window example, the `lyric-ui` native host) become
   `GpuWindow.surfaceFor` in a new library, `lyric-gpu-window`, which depends on both `lyric-gpu` and `lyric-window`. It
   is its own library because `lyric-gpu` must not depend on `lyric-window`: the headless compute, triangle and quad
   examples build without SDL.
5. **Occluded frames are skipped, not repaired.** wgpu-native reports `Occluded` (its own status, 0x00030001) for a
   surface with no visible window, which on macOS includes the first frames after `show`. `Gpu.tryAcquireFrame` returns
   `Ok(None)` for `Occluded` and `Timeout` and `Err` only when the surface needs reconfiguring; the frame loops of the
   window example, `Game.Run` and the native UI host use it. A loop that reconfigured on every failed acquire (as
   `acquireFrame` invited) reset the surface each frame and never presented. `acquireFrame` keeps its behaviour.
6. **Surfaces are configured in pixels.** Loops configure `Window.pixelSize`, not `windowSize`: the drawable of a
   Retina window is twice its size in points.
7. **Bundles carry the dylib under its install name.** `stageDarwinDylib` copies a dylib that names itself
   `@rpath/<name>` under `<name>` when its file is named otherwise (wgpu-native ships
   `libwgpu_native-release.dylib` naming itself `@rpath/libwgpu_native.dylib`), so a `[native.app]` bundle can load it.
   The graphics examples declare `[native.app]`.
8. **`Window.raise`.** A window behind other windows is occluded and presents nothing, and a program started from a
   terminal does not come to the front by itself, so the window loops call `Window.raise` (`SDL_RaiseWindow`) after
   `show`.

## Verification

On Apple Silicon (Metal): the `compute`, `triangle` and `quad` examples (the goldens match with 0 differing pixels), the
window example and Breakout present frames in Cocoa windows, the Breakout replay check and the UI native host check
match the lavapipe goldens with 0 differing pixels (with DejaVu Sans, which the goldens were drawn with).
`scripts/ci/macos-graphics-e2e.sh` runs these on a `macos-latest` runner behind a Metal adapter probe.
The lyric-text shape and lyric-draw scene examples need WenQuanYi Zen Hei, which Homebrew does not ship, and stay on Linux.
