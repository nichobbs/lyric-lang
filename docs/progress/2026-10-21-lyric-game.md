# `lyric-game`: deterministic core, native frame loop and the Breakout sample (docs/67 G7, #7946, D201)

- `lyric-game/`: `Game.Clock`, `Game.Rng`, `Game.Input`, `Game.Replay`, `Game.Program`, `Game.Keys`,
  `Game.Sprites`, `Game.Inflate`, `Game.Image` (PNG), `Game.Audio` (WAV, `tone`, `Mixer`); 18 tests
  (`lyric test --manifest lyric-game/lyric.toml`) including ten PNG fixtures from an independent encoder.
- `lyric-game/platform/`: `Game.Run` (`run`, `renderRecording`, `Viewport`, sprite cells) on lyric-window,
  lyric-gpu and lyric-draw.
- `lyric-game/examples/breakout/`: `logic/` (rules, bot, 9 tests including a checked-in recording pinned
  by digest) and `app/` (PNG sprites, HUD text, synthesised sound, `--record`/`--play`/`--check`).
- `lyric-draw`: `Image` size and `pixelArt`, `drawImageRegion`; `lyric-gpu`: surface format preference.
- `scripts/ci/game-examples-e2e.sh`, wired into `native-backend-self-tests.sh`: tests, headless native replay
  (digest equal to the managed targets', golden frame), and a window under Xvfb replaying and re-recording.
- Docs: D201, docs/67, book chapter 13, CLAUDE.md. Open: a Cocoa surface for macOS (G5), the cross-package
  private-generic-helper bug in the native backend.
