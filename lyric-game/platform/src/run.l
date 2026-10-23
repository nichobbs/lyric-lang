//! run.l - Game.Run: the frame loop of a `lyric-game` program on `--target native` (docs/67 G7).
//!
//! A game is a `Game[S]`: `init(seed)`, a pure `update(state, input, dt)`, a `render` that draws a
//! state, and `cues` that name the sounds a step asked for.  `run` opens the window, GPU surface
//! and sound device, then each frame turns the window's events into input, runs the whole
//! updates the `Game.Clock` accumulator earned, renders interpolated between the last two states,
//! and tops up the audio queue.  It can record every step's input to a file or play a recording
//! back instead of the keyboard.  `renderRecording` plays a recording with no window at all and
//! returns the final state and a picture of it, which is how CI checks a game on a machine
//! without a display.
//!
//! The game draws in its own coordinates (`Config.viewWidth` by `viewHeight`); the loop
//! letterboxes that area into the window and hands `render` the `Viewport` that maps one to the
//! other, and converts the pointer back.
@io
package Game.Run

import Std.Core
import Std.Collections
import Std.Buffer as Buf
import Std.Console as Console
import Std.File as File
import Std.Errors
import Window
import Gpu
import Draw
import Game.Input
import Game.Clock
import Game.Replay
import Game.Audio
import Game.Keys
import Game.Image
import Game.Sprites

/// How the game's coordinate space sits in the target: uniformly scaled and centred.
pub record Viewport {
  scale: Float
  offsetX: Float
  offsetY: Float
  width: Int
  height: Int
}

/// The viewport that fits a `viewWidth` by `viewHeight` area into a `width` by `height` target.
pub func fitViewport(width: Int, height: Int, viewWidth: Int, viewHeight: Int): Viewport {
  val sx = width.toFloat() / viewWidth.toFloat()
  val sy = height.toFloat() / viewHeight.toFloat()
  val scale = if sx < sy { sx } else { sy }
  Viewport(
    scale = scale,
    offsetX = (width.toFloat() - viewWidth.toFloat() * scale) / 2.0f32,
    offsetY = (height.toFloat() - viewHeight.toFloat() * scale) / 2.0f32,
    width = width,
    height = height
  )
}

/// A rectangle in game coordinates as pixels in the target.
pub func rect(v: Viewport, x: Float, y: Float, w: Float, h: Float): Draw.Rect {
  Draw.Rect(x = v.offsetX + x * v.scale, y = v.offsetY + y * v.scale, width = w * v.scale, height = h * v.scale)
}

/// A pixel position of the target as game coordinates.
pub func toGame(v: Viewport, px: Float, py: Float): Draw.Rect {
  Draw.Rect(x = (px - v.offsetX) / v.scale, y = (py - v.offsetY) / v.scale, width = 0.0f32, height = 0.0f32)
}

/// What a game program supplies.
pub record Game[S] {
  init: (Long) -> S
  update: (S, InputFrame, Float) -> S
  render: (S, S, Float, Draw.Painter, Viewport) -> Unit
  cues: (S) -> List[Int]
}

pub record Config {
  title: String
  windowWidth: Int
  windowHeight: Int
  viewWidth: Int
  viewHeight: Int
  hz: Int
  seed: Long
  clear: Draw.Color
  sounds: List[Sound]
  recordTo: Option[String]
  playback: Option[Recording]
}

val maxStepsPerFrame: Int = 8

val audioRate: Int = 48000

func fail(message: String): Int {
  Console.println("FAIL: " + message)
  1
}

func isQuit(e: Window.Event): Bool {
  match e {
    case Quit -> true
    case WindowCloseRequested(w) -> true
    case KeyDown(w, key, scancode, modifiers, repeat) -> key == escape
    case _ -> false
  }
}

// The game-side event for a window event, with pointer positions in game coordinates.
func translate(e: Window.Event, v: Viewport, pxScaleX: Float, pxScaleY: Float): Option[InputEvent] {
  match e {
    case KeyDown(w, key, scancode, modifiers, repeat) -> if repeat { None } else { Some(value = KeyPressed(key = key)) }
    case KeyUp(w, key, scancode, modifiers) -> Some(value = KeyReleased(key = key))
    case MouseMotion(w, x, y, dx, dy) -> {
      val g = toGame(v, x * pxScaleX, y * pxScaleY)
      Some(value = pointerMoved(g.x, g.y))
    }
    case MouseButtonDown(w, button, x, y, clicks) -> Some(value = ButtonPressed(button = button))
    case MouseButtonUp(w, button, x, y, clicks) -> Some(value = ButtonReleased(button = button))
    case MouseWheel(w, dx, dy) -> Some(value = scrolled(dx, dy))
    case TextInput(w, text) -> Some(value = TextTyped(text = text))
    case _ -> None
  }
}

func surfaceFor(d: Gpu.Device, w: Window.Window): Result[Gpu.Surface, String] {
  match Window.nativeWindow(w) {
    case X11(display, window) -> Gpu.createXlibSurface(d, display, window)
    case Wayland(display, surface) -> Gpu.createWaylandSurface(d, display, surface)
    case _ -> Err(error = "this window system has no GPU surface support yet")
  }
}

// Plays the cues a step asked for.
func playCues(mixer: Mixer, sounds: List[Sound], cues: List[Int]): Unit {
  for c in cues {
    if c >= 0 and c < sounds.count {
      val _ = play(mixer, sounds[c], 0.6f32, false)
    }
  }
}

func topUpAudio(audio: Option[Window.Audio], mixer: Mixer): Unit {
  match audio {
    case None -> ()
    case Some(a) -> {
      val chunk = audioRate / 60
      while Window.queuedBytes(a) < chunk * 8 * 4 {
        val _ = Window.queueSamples(a, Game.Audio.render(mixer, chunk))
      }
    }
  }
}

// One rendered frame: acquire, draw, present.  An unavailable frame means reconfigure and retry.
func drawFrame[S](
  d: Gpu.Device,
  surface: Gpu.Surface,
  painter: Draw.Painter,
  config: Config,
  game: Game[S],
  prev: S,
  cur: S,
  alpha: Float,
): Result[Unit, String] {
  val target = match Gpu.acquireFrame(d, surface) { case Ok(t) -> t; case Err(m) -> return Err(error = m) }
  val v = fitViewport(target.width, target.height, config.viewWidth, config.viewHeight)
  Draw.beginFrame(painter, target.width, target.height)
  game.render(prev, cur, alpha, painter, v)
  match Draw.finish(painter, target, config.clear) {
    case Err(m) -> {
      Gpu.discardFrame(target)
      Err(error = m)
    }
    case Ok(_) -> Gpu.presentFrame(surface, target)
  }
}

func frameLoop[S](d: Gpu.Device, win: Window.Window, surface0: Gpu.Surface, config: Config, game: Game[S]): Int {
  var surface = surface0
  val painter = match Draw.newPainter(d, surface.format) { case Ok(p) -> p; case Err(m) -> return fail(m) }
  val mixer = newMixer(audioRate)
  val audio: Option[Window.Audio] = match Window.openAudio(audioRate, 2) {
    case Ok(a) -> Some(value = a)
    case Err(_) -> None
  }
  val clock = newClock(config.hz, maxStepsPerFrame)
  val dt = stepSeconds(clock)
  val recording = newRecording(config.seed)
  var cur = game.init(config.seed)
  var prev = cur
  var frame = initialFrame()
  var pending: List[InputEvent] = newList()
  var playbackAt = 0
  var running = true
  var announced = false
  var failure = ""
  var last = Window.counter()
  val freq = Window.counterFrequency()
  Window.startTextInput(win)
  while running and failure == "" {
    val size = Window.pixelSize(surface_window(win))
    val vp = fitViewport(surface.width, surface.height, config.viewWidth, config.viewHeight)
    val ws = Window.windowSize(win)
    val sx = if ws.width > 0 { surface.width.toFloat() / ws.width.toFloat() } else { 1.0f32 }
    val sy = if ws.height > 0 { surface.height.toFloat() / ws.height.toFloat() } else { 1.0f32 }
    var polling = true
    while polling {
      match Window.pollEvent() {
        case None -> {
          polling = false
        }
        case Some(e) -> {
          if isQuit(e) {
            running = false
          }
          match e {
            case WindowResized(w, width, height) -> match Gpu.configureSurface(d, surface, size.width, size.height) {
              case Ok(s) -> {
                surface = s
              }
              case Err(m) -> {
                failure = m
              }
            }
            case _ -> ()
          }
          match config.playback {
            case Some(_) -> ()
            case None -> match translate(e, vp, sx, sy) { case Some(ie) -> pending.add(ie); case None -> () }
          }
        }
      }
    }
    val now = Window.counter()
    val elapsed = (now - last) * 1000000000i64 / freq
    last = now
    val ticks = advance(clock, if elapsed < 0i64 { 0i64 } else { elapsed })
    var s = 0
    while s < ticks.steps and running {
      var events = pending
      match config.playback {
        case Some(r) -> {
          if playbackAt >= r.steps.count {
            running = false
          } else {
            events = r.steps[playbackAt]
            playbackAt = playbackAt + 1
          }
        }
        case None -> ()
      }
      if running {
        pending = newList()
        record(recording, events)
        frame = next(frame, events)
        prev = cur
        cur = game.update(cur, frame, dt)
        playCues(mixer, config.sounds, game.cues(cur))
      }
      s = s + 1
    }
    topUpAudio(audio, mixer)
    match drawFrame(d, surface, painter, config, game, prev, cur, ticks.alpha) {
      case Ok(_) -> {
        if not announced {
          announced = true
          Console.println("presented")
        }
      }
      case Err(_) -> match Gpu.configureSurface(d, surface, size.width, size.height) {
        case Ok(s2) -> {
          surface = s2
        }
        case Err(m) -> {
          failure = m
        }
      }
    }
  }
  Window.stopTextInput(win)
  match audio {
    case Some(a) -> Window.closeAudio(a)
    case None -> ()
  }
  Draw.releasePainter(painter)
  if failure != "" {
    return fail(failure)
  }
  match config.recordTo {
    case Some(path) -> match File.writeText(path, encode(recording)) {
      case Ok(_) -> Console.println(
        "recorded " + recording.steps.count.toString() + " steps to " + path
      )
      case Err(e) -> return fail("cannot write " + path)
    }
    case None -> ()
  }
  0
}

func surface_window(w: Window.Window): Window.Window {
  w
}

/// Runs `game` in a window until it is closed or Escape is pressed (or a playback ends).
/// Returns a process exit code.
pub func run[S](config: Config, game: Game[S]): Int {
  match Window.init(Window.initVideo + Window.initAudio) {
    case Err(m) -> return fail(m)
    case Ok(_) -> ()
  }
  val win = match Window.createWindow(config.title, config.windowWidth, config.windowHeight, true) {
    case Ok(w) -> w
    case Err(m) -> return fail(m)
  }
  Window.show(win)
  val body: (Gpu.Device) -> Int = { d: Gpu.Device ->
    match surfaceFor(d, win) {
      case Err(m) -> fail(m)
      case Ok(created) -> {
        val px = Window.pixelSize(win)
        match Gpu.configureSurface(d, created, px.width, px.height) {
          case Err(m) -> fail(m)
          case Ok(surface) -> {
            val rc = frameLoop(d, win, surface, config, game)
            Gpu.releaseSurface(surface)
            rc
          }
        }
      }
    }
  }
  val rc = match Gpu.withDevice(body) { case Err(m) -> fail(m); case Ok(code) -> code }
  Window.destroyWindow(win)
  Window.quit()
  rc
}

/// The result of `renderRecording`.
pub record Rendered[S] {
  state: S
  pixels: buffer[Byte]
  width: Int
  height: Int
}

/// Plays `recording` through `game` with no window and draws the final state into an offscreen
/// `width` by `height` target.  Needs a GPU device (a software one will do), not a display.
pub func renderRecording[S](
  config: Config, game: Game[S], recording: Recording, width: Int, height: Int
): Result[Rendered[S], String] {
  val body: (Gpu.Device) -> Result[Rendered[S], String] = { d: Gpu.Device ->
    val dt = 1.0f32 / config.hz.toFloat()
    var prev = game.init(recording.seed)
    var cur = prev
    for f in frames(recording) {
      prev = cur
      cur = game.update(cur, f, dt)
    }
    val target = Gpu.createRenderTarget(d, width, height)
    val painter = match Draw.newPainter(d, Gpu.formatRgba8) { case Ok(p) -> p; case Err(m) -> return Err(error = m) }
    val v = fitViewport(width, height, config.viewWidth, config.viewHeight)
    Draw.beginFrame(painter, width, height)
    game.render(prev, cur, 1.0f32, painter, v)
    val drawn = Draw.finish(painter, target, config.clear)
    val pixels = match drawn { case Ok(_) -> Gpu.readPixels(d, target); case Err(m) -> Err(error = m) }
    Draw.releasePainter(painter)
    Gpu.releaseRenderTarget(target)
    match pixels {
      case Ok(p) -> Ok(value = Rendered(state = cur, pixels = p, width = width, height = height))
      case Err(m) -> Err(error = m)
    }
  }
  match Gpu.withDevice(body) {
    case Err(m) -> Err(error = m)
    case Ok(r) -> r
  }
}

/// Loads a PNG file as a `Draw.Image` for `painter`.
pub func loadImage(painter: Draw.Painter, decoded: Game.Image.Image, pixelArt: Bool): Result[Draw.Image, String] {
  Draw.createImage(painter, decoded.width, decoded.height, decoded.pixels, pixelArt)
}

/// Draws one cell of a sprite sheet stretched over `dest`.
pub func drawCell(
  painter: Draw.Painter, image: Draw.Image, cell: Game.Sprites.Cell, dest: Draw.Rect, tint: Draw.Color
): Unit {
  Draw.drawImageRegion(
    painter,
    image,
    Draw.Rect(x = cell.x.toFloat(), y = cell.y.toFloat(), width = cell.width.toFloat(), height = cell.height.toFloat()),
    dest,
    tint
  )
}
