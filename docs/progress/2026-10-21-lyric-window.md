# lyric-window: SDL3 windows, input, clipboard, timing, audio (docs/67 G4, #7943, D195)

- `lyric-window/`: bindgen-generated `Window.Kernel.Sdl` over SDL3 (pkg-config `sdl3`) and the safe
  `Window` package: init, windows (size, pixel size, display scale, title, native handles),
  an `Event` union decoded from SDL's event buffer, `pollEvent`/`waitEvent`/`post`, text input,
  clipboard, nanosecond and high-resolution timing, float-sample audio streams.
- `native/sdl_layout_check.c`: `_Static_assert`s for every offset and flag constant `window.l` uses.
- `examples/demo`: window, posted input events, resize, clipboard, timing, and a tone checked
  through SDL's `disk` audio driver, all headless (`offscreen` video driver).
- CI: `scripts/ci/build-sdl3.sh` builds the pinned 3.4.18 tarball (about a minute);
  `scripts/ci/window-examples-e2e.sh` runs the layout check, `bindgen --check` and the demo in the
  native-backend job.
- Docs: D195, book chapter 13, docs/67.
