# lyric-window

Windows, input events, clipboard, timing and audio for `--target native`, over SDL3 (docs/67 G4).

- `Window.Kernel.Sdl` is `lyric bindgen` output from `<SDL3/SDL.h>`; never edit it. To bind more, add the symbol to
  `native/sdl.allow` and regenerate with the command in that file's header.
- `Window` is the safe surface: no `NativePtr` crosses it. A window is a record around an opaque handle, and input is a
  Lyric union (`Event`) decoded from SDL's event buffer. Call everything from the thread that called `init`.

## Build

SDL3 is found with pkg-config (`sdl3`): Homebrew `sdl3` on macOS, your distribution's package on Linux, or
`scripts/ci/build-sdl3.sh` (the pinned release tarball, what CI uses). On Windows `lyric restore` fetches the official
development archive pinned in `lyric.toml`.

## Windows and GPU surfaces

`createWindow` makes a hidden window; `show` it, then `raise` it (a window behind others is occluded and presents
nothing). `pixelSize` is the size to configure a GPU surface with (twice `windowSize` on a Retina display).

`nativeWindow` returns the window system's handles (`X11`, `Wayland`, `Cocoa` with the `NSWindow*`, `Win32`). On macOS
a window is created Metal-capable with a `CAMetalLayer` view that lives until `destroyWindow`; `metalLayer` returns the
layer. `lyric-gpu-window` turns a window into a `lyric-gpu` surface on every platform (`GpuWindow.surfaceFor`).

## Tests

`scripts/ci/window-examples-e2e.sh` runs the demo on SDL's `offscreen` video and `disk` audio drivers.
