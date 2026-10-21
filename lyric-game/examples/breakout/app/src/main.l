//! main.l - Breakout.App: the Breakout sample as a program.
//!   breakout                          play
//!   breakout --record <file>          play and record the input to <file>
//!   breakout --play <file> [--record <file>]
//!                                     watch a recording in a window (optionally re-recording it)
//!   breakout --check <file> <digest> <golden.rgba>
//!                                     replay headless; the final state's digest must be <digest>
//!                                     and the last frame must match <golden.rgba>
//!   breakout --check <file> <digest> --update <golden.rgba>
//!                                     as above, writing the frame as the new golden image
//! Assets are read from $LYRIC_GAME_ASSETS (default lyric-game/examples/breakout/assets) and the HUD
//! font from $LYRIC_TEXT_FONT_LATIN (default DejaVu Sans); the game draws without text if absent.
package Breakout.App

import Std.Core
import Std.Collections
import Std.Buffer as Buf
import Std.Console as Console
import Std.Environment as Environment
import Std.File as File
import Std.Parse
import Std.Errors
import Draw
import Game.Audio
import Game.Replay
import Game.Run
import Game.Input
import Breakout
import Breakout.View

val fieldW: Int = 320

val fieldH: Int = 240

val checkWidth: Int = 320

val checkHeight: Int = 240

val channelTolerance: Int = 24

val pixelBudget: Int = 400

func fail(message: String): Int {
  Console.println("FAIL: " + message)
  1
}

func sounds(): List[Sound] {
  val s: List[Sound] = newList()
  s.add(tone(330.0f32, 0.08f32, 48000, 0.5f32))
  s.add(tone(520.0f32, 0.10f32, 48000, 0.5f32))
  s.add(tone(260.0f32, 0.06f32, 48000, 0.4f32))
  s.add(tone(110.0f32, 0.45f32, 48000, 0.6f32))
  s.add(tone(660.0f32, 0.60f32, 48000, 0.5f32))
  s
}

func program(art: Art): Game[State] {
  Game(
    init = { seed: Long -> start(seed) },
    update = { s: State, f: InputFrame, dt: Float -> update(s, f, dt) },
    render = { prev: State, cur: State, alpha: Float, p: Draw.Painter, vp: Viewport ->
      drawState(art, prev, cur, alpha, p, vp)
    },
    cues = { s: State -> s.cues }
  )
}

func config(recordTo: Option[String], playback: Option[Recording]): Config {
  val seed = match playback { case Some(r) -> r.seed; case None -> 1i64 }
  Config(
    title = "Lyric Breakout",
    windowWidth = fieldW * 3,
    windowHeight = fieldH * 3,
    viewWidth = fieldW,
    viewHeight = fieldH,
    hz = 60,
    seed = seed,
    clear = Draw.rgb(0.02f32, 0.02f32, 0.05f32),
    sounds = sounds(),
    recordTo = recordTo,
    playback = playback
  )
}

func channelDiff(a: Byte, b: Byte): Int {
  val x = a.toInt()
  val y = b.toInt()
  if x > y then x - y else y - x
}

func loadRecording(path: String): Result[Recording, String] {
  match File.readText(path) {
    case Err(_) -> Err(error = "cannot read " + path)
    case Ok(text) -> decode(text)
  }
}

func check(art: Art, recordingPath: String, digestText: String, goldenArgs: slice[String]): Int {
  val recording = match loadRecording(recordingPath) { case Ok(r) -> r; case Err(m) -> return fail(m) }
  val expected = match parseOptLong(digestText) {
    case Some(d) -> d
    case None -> return fail("the digest must be a number")
  }
  val updating = goldenArgs.length == 2 and goldenArgs[0] == "--update"
  val goldenPath = if updating { goldenArgs[1] } else { goldenArgs[0] }
  val rendered = match renderRecording(config(None, Some(value = recording)), program(art), recording, checkWidth, checkHeight) {
    case Ok(r) -> r
    case Err(m) -> return fail(m)
  }
  val actual = digest(rendered.state)
  Console.println(
    "steps " + recording.steps.count.toString() + ", digest " + actual.toString() + ", score " +
      rendered.state.score.toString()
  )
  if actual != expected {
    return fail("the replay ends in digest " + actual.toString() + ", expected " + expected.toString())
  }
  if updating {
    match File.writeBytes(goldenPath, Buf.toSlice(rendered.pixels)) {
      case Ok(_) -> {
        Console.println("wrote " + goldenPath)
        return 0
      }
      case Err(_) -> return fail("cannot write " + goldenPath)
    }
  }
  val golden = match File.readBytes(goldenPath) {
    case Ok(g) -> g
    case Err(_) -> return fail("cannot read " + goldenPath)
  }
  if golden.length != rendered.pixels.length {
    return fail(
      "the golden image has " + golden.length.toString() + " bytes, the frame " + rendered.pixels.length.toString()
    )
  }
  var differing = 0
  var i = 0
  while i < golden.length {
    if channelDiff(golden[i], rendered.pixels[i]) > channelTolerance or channelDiff(golden[i + 1], rendered.pixels[i + 1]) > channelTolerance or channelDiff(golden[i + 2], rendered.pixels[i + 2]) > channelTolerance {
      differing = differing + 1
    }
    i = i + 4
  }
  Console.println(
    "pixels differing from the golden image: " + differing.toString() + " (budget " + pixelBudget.toString() + ")"
  )
  if differing > pixelBudget then 1 else 0
}

func main(): Int {
  val args = Environment.args()
  val assets = Environment.getVarOrDefault("LYRIC_GAME_ASSETS", "lyric-game/examples/breakout/assets")
  val font = Environment.getVarOrDefault("LYRIC_TEXT_FONT_LATIN", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")
  val art = newArt(assets, font)
  var rc = 0
  if args.length >= 5 and args[1] == "--check" {
    rc = check(art, args[2], args[3], args.slice(4, args.length))
  } else if args.length >= 3 and args[1] == "--record" {
    rc = run(config(Some(value = args[2]), None), program(art))
  } else if args.length >= 3 and args[1] == "--play" {
    val again: Option[String] = if args.length >= 5 and args[3] == "--record" { Some(value = args[4]) } else { None }
    rc = match loadRecording(args[2]) {
      case Ok(r) -> run(config(again, Some(value = r)), program(art))
      case Err(m) -> fail(m)
    }
  } else if args.length == 1 {
    rc = run(config(None, None), program(art))
  } else {
    rc = fail("usage: breakout [--record <file> | --play <file> | --check <file> <digest> [--update] <golden.rgba>]")
  }
  release(art)
  rc
}
