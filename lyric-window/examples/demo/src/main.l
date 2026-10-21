//! demo: a window, input and a sound.  Run with SDL's `offscreen` video driver and `disk`
//! audio driver it needs no display or sound card: CI posts events to the window's queue,
//! reads them back, and checks the samples the audio driver wrote.
//!   SDL_VIDEODRIVER=offscreen SDL_AUDIODRIVER=disk SDL_DISKAUDIOFILE=out.raw demo
package Window.Examples.Demo

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.Buffer as Buf
import Window

val sampleRate: Int = 48000

val toneFrames: Int = 12000

func fail(message: String): Int {
  Console.println("FAIL: " + message)
  1
}

func describe(e: Window.Event): String {
  match e {
    case Quit -> "quit"
    case WindowCloseRequested(w) -> "close-requested"
    case WindowResized(w, width, height) -> "resized " + width.toString() + "x" + height.toString()
    case KeyDown(w, key, scancode, modifiers, repeat) -> "key-down " + key.toString() + " scancode " +
      scancode.toString() +
      " mods " +
      modifiers.toString() +
      " repeat " +
      repeat.toString()
    case KeyUp(w, key, scancode, modifiers) -> "key-up " + key.toString()
    case TextInput(w, text) -> "text " + text
    case TextEditing(w, text, start, length) -> "composing " + text
    case MouseMotion(w, x, y, dx, dy) -> "motion " + x.toString() + "," + y.toString() + " rel " + dx.toString() + "," +
      dy.toString()
    case MouseButtonDown(w, button, x, y, clicks) -> "button-down " + button.toString() + " at " + x.toString() + "," +
      y.toString() +
      " clicks " +
      clicks.toString()
    case MouseButtonUp(w, button, x, y, clicks) -> "button-up " + button.toString()
    case MouseWheel(w, dx, dy) -> "wheel " + dx.toString() + "," + dy.toString()
    case Other(kind) -> "other " + kind.toString()
  }
}

func isNothing(e: Window.Event): Bool {
  false
}

func isQuit(e: Window.Event): Bool {
  match e {
    case Quit -> true
    case _ -> false
  }
}

func postAll(events: List[Window.Event]): Result[Unit, String] {
  for e in events {
    match Window.post(e) {
      case Ok(_) -> ()
      case Err(message) -> return Err(error = message)
    }
  }
  Ok(value = ())
}

// Prints every queued event up to the first one `stop` accepts (or until the queue is empty).
func drain(stop: (Window.Event) -> Bool): Unit {
  var running = true
  while running {
    match Window.pollEvent() {
      case None -> {
        running = false
      }
      case Some(e) -> {
        Console.println("event: " + describe(e))
        if stop(e) {
          running = false
        }
      }
    }
  }
}

func tone(): buffer[Float] {
  val silence: Float = 0.0f32
  var samples = Buf.filled(toneFrames, silence)
  val loud: Float = 0.25f32
  val quiet: Float = 0.0f32 - 0.25f32
  var i = 0
  while i < toneFrames {
    // A square wave of about 480 Hz at a moderate volume: no libm needed.
    samples[i] = if (i / 50) % 2 == 0 then loud else quiet
    i = i + 1
  }
  samples
}

func run(): Int {
  match Window.init(Window.initVideo + Window.initAudio) {
    case Err(message) -> return fail(message)
    case Ok(_) -> ()
  }
  val win = match Window.createWindow("Lyric demo", 320, 200, true) {
    case Ok(w) -> w
    case Err(message) -> return fail(message)
  }
  Window.show(win)
  val size = Window.windowSize(win)
  Console.println("window: " + size.width.toString() + "x" + size.height.toString())

  val scripted: List[Window.Event] = newList()
  scripted.add(KeyDown(window = win.id, key = 97, scancode = 4, modifiers = 1, repeat = false))
  scripted.add(KeyUp(window = win.id, key = 97, scancode = 4, modifiers = 1))
  scripted.add(MouseMotion(window = win.id, x = 10.5f32, y = 20.25f32, dx = 1.5f32, dy = 0.0f32 - 2.0f32))
  scripted.add(MouseButtonDown(window = win.id, button = 1, x = 10.5f32, y = 20.25f32, clicks = 2))
  scripted.add(MouseWheel(window = win.id, dx = 0.0f32, dy = 3.0f32))
  scripted.add(Quit)
  match postAll(scripted) {
    case Ok(_) -> ()
    case Err(message) -> return fail(message)
  }
  drain(isQuit)

  Window.setSize(win, 400, 300)
  drain(isNothing)
  val resized = Window.windowSize(win)
  Console.println("window now: " + resized.width.toString() + "x" + resized.height.toString())
  Console.println(
    "native window: " + (match Window.nativeWindow(win) { case Unavailable -> "unavailable"; case _ -> "available" })
  )

  match Window.setClipboardText("héllo clipboard") {
    case Ok(_) -> ()
    case Err(message) -> return fail(message)
  }
  Console.println("clipboard: " + (match Window.clipboardText() { case Some(text) -> text; case None -> "(empty)" }))

  val before = Window.nowNanos()
  Window.delayNanos(2000000)
  Console.println("time advanced: " + ((Window.nowNanos() - before) >= 2000000).toString())

  val audio = match Window.openAudio(sampleRate, 1) { case Ok(a) -> a; case Err(message) -> return fail(message) }
  match Window.queueSamples(audio, tone()) {
    case Ok(_) -> ()
    case Err(message) -> return fail(message)
  }
  Window.flushAudio(audio)
  var waits = 0
  while Window.queuedBytes(audio) > 0 and waits < 500 {
    Window.delayNanos(10000000)
    waits = waits + 1
  }
  Console.println("audio queued after playback: " + Window.queuedBytes(audio).toString())
  Window.closeAudio(audio)
  Window.destroyWindow(win)
  Window.quit()
  Console.println("done")
  0
}

func main(): Int {
  run()
}
