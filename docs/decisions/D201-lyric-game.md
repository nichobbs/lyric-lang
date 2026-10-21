# D201 - `lyric-game`: a deterministic 2D game core, a native frame loop, and the Breakout sample

**Status:** accepted, implemented (docs/67 phase G7, #7946); builds on D195 to D200

## Decision

1. **Two projects, one contract.** `lyric-game/` (`Lyric.Game`) holds everything deterministic and
   host-free, so it builds and tests on every target: `Game.Clock` (fixed-timestep accumulator with
   an interpolation alpha and a step cap), `Game.Rng` (a 64-bit xorshift whose sequence this package
   defines, because `Std.Random` is host-backed and differs per target), `Game.Input`, `Game.Replay`,
   `Game.Program`, `Game.Keys`, `Game.Sprites`, `Game.Inflate`, `Game.Image` (PNG) and `Game.Audio`
   (WAV and a mixer). `lyric-game/platform/` (`Lyric.Game.Platform`, `Game.Run`) holds the window,
   GPU and sound-card half and is native only.
2. **Input is a pure fold.** Game logic sees an immutable `InputFrame` built by
   `next(prev, events)`; the live loop and a replay call the same function, so a recorded event
   stream reproduces a session exactly. Pointer positions and wheel deltas are fixed point (sixteenths),
   rounded once at the window boundary, so the recorded value is the value the game saw.
3. **A recording is per update step, in text.** `lyric-replay 1`, a `seed` line, then one line of
   `;`-separated events per step. It is diffable, can be checked in as a fixture, and round-trips
   through `encode`/`decode`.
4. **A game is `init(seed)`, a pure `update(state, input, dt)`, a `render`, and `cues`.** Sounds are
   returned as cue ids in the state (effects as data, as docs/65), and the loop plays them.
   `Game.Run.run` opens the window, GPU surface and audio device, runs the whole updates the clock
   earned, renders interpolated between the last two states, tops up the audio queue, and can record
   the input or play a recording instead of the keyboard. `renderRecording` plays a recording with
   no window at all and returns the final state and the last frame drawn offscreen.
5. **Decoders in Lyric.** `Game.Inflate` (RFC 1951/1950, with the Adler-32 check) and `Game.Image`
   (every PNG colour type and bit depth, `tRNS`, both interlace methods, CRC-checked chunks) are
   pure Lyric, so there is no native image dependency. They are tested against ten fixtures made by
   an independent encoder, covering all five filters and stored, fixed and dynamic DEFLATE blocks.
6. **`lyric-draw` changes.** `Image` carries its size and a `pixelArt` flag (nearest-neighbour
   sampling, one more sampler); `drawImageRegion` draws a rectangle of an image (a sprite-sheet
   cell). `createImage` takes the new flag. `lyric-gpu`'s `configureSurface` now prefers `RGBA8`,
   then `BGRA8`, over an sRGB twin, so shader colours appear as written on a window, as they do in an
   offscreen target.
7. **The sample is Breakout** (`lyric-game/examples/breakout`): `logic/` is the rules (pure, with
   a bot that records sessions), `app/` the program (PNG sprite sheets, HUD text, synthesised sound
   effects, `--record`, `--play`, `--check`). The tests pin a state digest for a checked-in 900-step
   recording; the native binary replays it headless and gets the identical digest (`Float` arithmetic
   is the same on every target) and a frame within the golden image's budget; a window under Xvfb is
   driven by the same recording, shows the playfield, and re-records the input it was given
   byte for byte (`scripts/ci/game-examples-e2e.sh`).

## Not in this slice

macOS: the sample uses `lyric-gpu` surfaces, which exist for X11 and Wayland only (Cocoa is the
open part of docs/67 G5), so it is playable on Linux and macOS is blocked on that surface; `lyric-game`
itself has no platform code. Gamepad and touch input, stereo panning, and an audio resampler better
than linear interpolation. A generic function called from another package must be `pub` for the
native backend to find it (`frameLoop` and `drawFrame` are `pub` for that reason; tracked as a
compiler bug, not a design: #8417).
