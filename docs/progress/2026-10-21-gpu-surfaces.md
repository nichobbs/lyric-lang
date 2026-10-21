# lyric-gpu: window surfaces (docs/67 G4 + G5, #7944, D197)

- `Gpu`: `Surface`, `createXlibSurface`, `createWaylandSurface`, `configureSurface`, `acquireFrame`,
  `presentFrame`, `releaseSurface`; `RenderTarget.format` and a target-format parameter on
  `createRenderPipeline`.
- `examples/window`: an SDL3 window with a wgpu surface presenting a triangle.
- CI: `scripts/ci/gpu-window-e2e.sh` runs it under Xvfb with lavapipe and checks a screenshot;
  `scripts/ci/build-sdl3.sh --x11` builds SDL3 with its X11 driver.
- Docs: D197, docs/67, CLAUDE.md.
