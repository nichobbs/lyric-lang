# macOS Metal surface for lyric-gpu and lyric-window (G5, G7; #7946, #8563)

- `Window`: on macOS windows are created Metal-capable with a `CAMetalLayer` view that lives until `destroyWindow`;
  `Window.metalLayer` returns the layer. SDL symbols added to `native/sdl.allow` and `Window.Kernel.Sdl` regenerated with
  `lyric bindgen`.
- `Gpu.createMetalSurface`, `Gpu.tryAcquireFrame` (occluded windows skip the frame instead of reconfiguring).
- `lyric-gpu-window` (`GpuWindow.surfaceFor`) replaces the three copies in `Game.Run`, the window example and the UI
  native host.
- Native bundles: a dylib whose install name differs from its file name is staged under the install name
  (`cli_native_libs.l`); the graphics examples declare `[native.app]`.
- `Window.raise` after `show` in the three window loops (an occluded window presents nothing).
- CI: `scripts/ci/macos-graphics-e2e.sh` (probe, then triangle/quad goldens, window, Breakout, UI host) in `native-platforms.yml`.
- Test: `native_libs_self_test.l` covers a bundled dylib whose file name differs from its install name.
- Breakout: a font search list (DejaVu where installed, else Arial) so text shows on macOS.
- Verified on an Apple Silicon Mac (Metal): the `compute` example, Breakout replay check with DejaVu (0 pixels
  differing from the lavapipe golden), UI customers check against all golden frames (0 differing).
- Decision: D317.
