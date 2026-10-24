//! main.l - Customers.Native: the customers example on the native host.
//!   customers-native                    a window
//!   customers-native --check <dir>      scripted headless run against the golden images in <dir>
//!   customers-native --check <dir> --update
//!                                       as above, writing the frames as the new golden images
//! Fonts: LYRIC_UI_FONT and LYRIC_UI_FONT_BOLD (DejaVu Sans by default).
package Customers.Native

import Std.Core
import Std.Collections
import Std.String
import Std.Buffer as Buf
import Std.Console as Console
import Std.Environment as Environment
import Std.File as File
import Window
import Ui.Native.Run as Native
import Ui.Native.Layout.{Box}
import Ui.Native.Interact as Interact
import Ui.Native.Bidi
import Ui.Native.LineBreak
import Ui.Native.UnicodeData
import Customers.Store
import Customers.App.{route}

val width: Int = 960

val height: Int = 640

val channelTolerance: Int = 24

val pixelBudget: Int = 1500

func fail(message: String): Int {
  Console.println("FAIL: " + message)
  1
}

func channelDiff(a: Byte, b: Byte): Int {
  val x = a.toInt()
  val y = b.toInt()
  if x > y then x - y else y - x
}

// Compares a frame with a golden image (or writes it): the number of pixels past the tolerance.
func compare(name: String, dir: String, update: Bool, pixels: buffer[Byte]): Result[Unit, String] {
  val path = dir + "/" + name + "-" + width.toString() + "x" + height.toString() + ".rgba"
  if update {
    match File.writeBytes(path, Buf.toSlice(pixels)) {
      case Ok(_) -> {
        Console.println("wrote " + path)
        return Ok(value = ())
      }
      case Err(_) -> return Err(error = "cannot write " + path)
    }
  }
  val golden = match File.readBytes(path) { case Ok(g) -> g; case Err(_) -> return Err(error = "cannot read " + path) }
  if golden.length != pixels.length {
    return Err(
      error = name + ": the golden image has " + golden.length.toString() + " bytes, the frame " +
        pixels.length.toString()
    )
  }
  var differing = 0
  var i = 0
  while i < golden.length {
    if channelDiff(golden[i], pixels[i]) > channelTolerance or channelDiff(golden[i + 1], pixels[i + 1]) > channelTolerance or channelDiff(golden[i + 2], pixels[i + 2]) > channelTolerance {
      differing = differing + 1
    }
    i = i + 4
  }
  Console.println(
    name + ": pixels differing from the golden image: " + differing.toString() + " (budget " + pixelBudget.toString() +
      ")"
  )
  if differing > pixelBudget {
    Err(error = name + ": the frame differs from its golden image")
  } else {
    Ok(value = ())
  }
}

func verify(cond: Bool, what: String): Result[Unit, String] {
  if cond {
    Console.println("ok: " + what)
    Ok(value = ())
  } else {
    Err(error = what)
  }
}

func click(hl: Native.Headless, b: Box): Unit {
  val x = b.x + b.w / 2.0f32
  val y = b.y + b.h / 2.0f32
  val events: List[Window.Event] = newList()
  events.add(Window.MouseMotion(window = 0, x = x, y = y, dx = 0.0f32, dy = 0.0f32))
  events.add(Window.MouseButtonDown(window = 0, button = 1, x = x, y = y, clicks = 1))
  events.add(Window.MouseButtonUp(window = 0, button = 1, x = x, y = y, clicks = 1))
  Native.script(hl, events)
}

func key(hl: Native.Headless, code: Int, mods: Int): Unit {
  val events: List[Window.Event] = newList()
  events.add(Window.KeyDown(window = 0, key = code, scancode = 0, modifiers = mods, repeat = false))
  events.add(Window.KeyUp(window = 0, key = code, scancode = 0, modifiers = mods))
  Native.script(hl, events)
}

func typed(hl: Native.Headless, text: String): Unit {
  val events: List[Window.Event] = newList()
  events.add(Window.TextInput(window = 0, text = text))
  Native.script(hl, events)
}

// Lays the current tree out so boxes can be found before the first snapshot.
func frameOf(hl: Native.Headless): Result[buffer[Byte], String] {
  Native.snapshot(hl)
}

// Sixty short words: long enough to wrap onto several lines of the notes area.
func longText(): String {
  var s = ""
  var i = 0
  while i < 60 {
    s = s + "word" + i.toString() + " "
    i = i + 1
  }
  s
}

// The notes field is a text area: it wraps long text, grows with it, and the caret moves by visual
// line with the keys and the mouse.
func notesScenario(hl: Native.Headless, dir: String, update: Bool): Result[Unit, String] {
  val area0 = match Native.firstOfKind(hl, "textArea") {
    case Some(b) -> b
    case None -> return Err(error = "no notes area")
  }
  click(hl, area0)
  typed(hl, "First line")
  key(hl, 13, 0)
  typed(hl, longText())
  val area1 = match Native.firstOfKind(hl, "textArea") {
    case Some(b) -> b
    case None -> return Err(error = "no notes area after typing")
  }
  val rows = Native.areaRows(hl, area1)
  match verify(rows >= 4, "the long text wraps onto several lines (" + rows.toString() + ")") {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }
  match verify(area1.h > area0.h, "the notes area grew with its text (" + area0.h.toString() + " to " + area1.h.toString() + ")") {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }
  val total = Native.caretOf(hl)
  match verify(Native.caretRow(hl) == rows - 1, "the caret is on the last line after typing") {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }
  key(hl, 1073741906, 0)
  match verify(Native.caretRow(hl) == rows - 2 and Native.caretOf(hl) < total, "Up moves to the line above") {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }
  key(hl, 1073741905, 0)
  match verify(Native.caretRow(hl) == rows - 1 and Native.caretOf(hl) == total, "Down comes back to the same column") {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }
  key(hl, 1073741898, 0)
  match verify(Native.caretRow(hl) == rows - 1 and Native.caretOf(hl) < total, "Home goes to the start of the visual line") {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }
  key(hl, 1073741901, 0)
  match verify(Native.caretOf(hl) == total, "End goes to the end of the line") {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }
  val events: List[Window.Event] = newList()
  val x = area1.x + 60.0f32
  val y = area1.y + 7.0f32 + 27.0f32
  events.add(Window.MouseMotion(window = 0, x = x, y = y, dx = 0.0f32, dy = 0.0f32))
  events.add(Window.MouseButtonDown(window = 0, button = 1, x = x, y = y, clicks = 1))
  events.add(Window.MouseButtonUp(window = 0, button = 1, x = x, y = y, clicks = 1))
  Native.script(hl, events)
  match verify(Native.caretRow(hl) == 1, "a click places the caret on the line under it") {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }
  key(hl, 1073741901, 0)
  key(hl, 1073741905, 1)
  key(hl, 1073741905, 1)
  val selectedFrame = match frameOf(hl) { case Ok(p) -> p; case Err(m) -> return Err(error = m) }
  compare("notes", dir, update, selectedFrame)
}

// Hebrew and Arabic, by code point.
val hebrewA: String = "אבג"

val hebrewB: String = "דהו"

val shalom: String = "שלום"

val marhaba: String = "مرحبا"

// The text algorithms on the native backend, where their tables (strings in lists, searched by
// bisection) and their buffers are native code: the same answers as in the `lyric test` suites.
func algorithmChecks(): Result[Unit, String] {
  val mixed = codePoints("abc " + hebrewA + " def")
  val levels = Bidi.resolveLevels(mixed, 0, mixed.length, Bidi.paragraphLevelOf(mixed, 0, mixed.length))
  var shown = ""
  for l in levels {
    shown = shown + l.toString()
  }
  match verify(shown == "00001110000", "UAX #9 levels of a Hebrew word in an English sentence (" + shown + ")") {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }
  val runs = Bidi.lineRuns(mixed, 0, levels, 0, mixed.length, 0)
  match verify(runs.count == 3 and runs[1].level == 1 and runs[1].from == 4 and runs[1].to == 7, "UAX #9 runs of that line") {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }
  val text = codePoints("well-known fact, 10% of $5.00")
  val breaks = LineBreak.breaksIn(text, 0, text.length)
  match verify(breaks[5] == LineBreak.breakAllowed and breaks[3] == LineBreak.noBreak and breaks[11] == LineBreak.breakAllowed and breaks[16] == LineBreak.noBreak and breaks[26] == LineBreak.noBreak, "UAX #14 breaks after a hyphen and a space, not inside a number or before a percent sign") {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }
  verify(UnicodeData.mirrorOf(40) == 41 and UnicodeData.bidiClassOf(1488) == 1, "Unicode properties")
}

// Replaces the notes with text in both directions: a Hebrew word in an English line, a Hebrew line
// with English, a number and brackets in it, an Arabic line, and a long Hebrew paragraph that wraps.
// A right to left paragraph is aligned to the right of the area, a word in the other direction keeps
// its own order inside it, and Left and Right move by screen position.
func bidiScenario(hl: Native.Headless, dir: String, update: Bool): Result[Unit, String] {
  match algorithmChecks() {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }
  val area0 = match Native.firstOfKind(hl, "textArea") {
    case Some(b) -> b
    case None -> return Err(error = "no notes area")
  }
  click(hl, area0)
  key(hl, 97, 0x40)
  val first = "Hello " + shalom + " world 123"
  typed(hl, first)
  key(hl, 13, 0)
  typed(hl, hebrewA + " abc 123 (" + hebrewB + ") " + hebrewA)
  key(hl, 13, 0)
  typed(hl, marhaba + " 2026 " + marhaba + " (test)")
  key(hl, 13, 0)
  var long = ""
  var i = 0
  while i < 16 {
    long = long + hebrewA + " " + hebrewB + " " + shalom + " "
    i = i + 1
  }
  typed(hl, long)
  val area = match Native.firstOfKind(hl, "textArea") {
    case Some(b) -> b
    case None -> return Err(error = "no notes area after typing")
  }
  val rows = Native.areaRows(hl, area)
  match verify(rows >= 5, "the long Hebrew paragraph wraps (" + rows.toString() + " lines)") {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }
  // A click at the right edge of the Hebrew line puts the caret at the start of its text.
  val lh = Native.areaLineHeight(hl)
  val events: List[Window.Event] = newList()
  val x = area.x + area.w - 14.0f32
  val y = area.y + 7.0f32 + lh * 1.5f32
  events.add(Window.MouseMotion(window = 0, x = x, y = y, dx = 0.0f32, dy = 0.0f32))
  events.add(Window.MouseButtonDown(window = 0, button = 1, x = x, y = y, clicks = 1))
  events.add(Window.MouseButtonUp(window = 0, button = 1, x = x, y = y, clicks = 1))
  Native.script(hl, events)
  val start = Interact.cpCount(first) + 1
  match verify(Native.caretRow(hl) == 1 and Native.caretOf(hl) == start, "a click at the right edge of a Hebrew line is at its start") {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m + " (caret " + Native.caretOf(hl).toString() + ", wanted " + start.toString() + ")")
  }
  match Native.caretArea(hl.host) {
    case Some(c) -> {
      match verify(c.x > area.x + area.w / 2.0f32, "and the caret is drawn at the right of the area") {
        case Ok(_) -> ()
        case Err(m) -> return Err(error = m)
      }
    }
    case None -> return Err(error = "no caret")
  }
  key(hl, 1073741904, 0)
  match verify(Native.caretOf(hl) == start + 1, "Left moves to the next letter of a right to left line") {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }
  key(hl, 1073741903, 0)
  key(hl, 1073741903, 0)
  match verify(Native.caretOf(hl) == start - 1, "Right at the right edge goes on to the line before") {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }
  // Select across the English words and the number of the Hebrew line, from its start.
  key(hl, 1073741905, 0)
  key(hl, 1073741898, 0)
  var n = 0
  while n < 9 {
    key(hl, 1073741904, 1)
    n = n + 1
  }
  val frame = match frameOf(hl) { case Ok(p) -> p; case Err(m) -> return Err(error = m) }
  compare("bidi", dir, update, frame)
}

func scenario(hl: Native.Headless, dir: String, update: Bool): Result[Unit, String] {
  Native.settle(hl, 150, 5000)
  val listFrame = match frameOf(hl) { case Ok(p) -> p; case Err(m) -> return Err(error = m) }
  val listText = Native.screenText(hl)
  match verify(contains(listText, "Customers") and contains(listText, "Acme Pty Ltd") and contains(listText, "Birchwood Joinery"), "the list shows the customers") {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m + "\n" + listText)
  }
  match compare("list", dir, update, listFrame) {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }

  // Open the first customer by clicking its link.
  match Native.findByText(hl, "link", "Acme Pty Ltd") {
    case None -> return Err(error = "no link for Acme Pty Ltd")
    case Some(link) -> click(hl, link)
  }
  Native.settle(hl, 150, 5000)
  val editFrame = match frameOf(hl) { case Ok(p) -> p; case Err(m) -> return Err(error = m) }
  val editText = Native.screenText(hl)
  match verify(contains(editText, "Customer 1") and contains(editText, "<Acme Pty Ltd>"), "the link opened the edit screen") {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m + "\n" + editText)
  }
  match compare("edit", dir, update, editFrame) {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }

  // Replace the name: focus the input, select all, type.
  match Native.findByText(hl, "textInput", "Acme Pty Ltd") {
    case None -> return Err(error = "no name input")
    case Some(input) -> click(hl, input)
  }
  key(hl, 97, 0x40)
  typed(hl, "Zed Industries")
  match verify(contains(Native.screenText(hl), "<Zed Industries>"), "typing replaced the selected name") {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }

  // Clipboard: select all, copy, move to the end, paste.
  key(hl, 97, 0x40)
  key(hl, 99, 0x40)
  key(hl, 1073741901, 0)
  key(hl, 118, 0x40)
  match verify(contains(Native.screenText(hl), "<Zed IndustriesZed Industries>"), "copy and paste through the clipboard") {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m + "\n" + Native.screenText(hl))
  }
  // Undo that with backspaces, and finish composing text through the input method.
  key(hl, 97, 0x40)
  typed(hl, "Zed Industries")
  val composing: List[Window.Event] = newList()
  composing.add(Window.TextEditing(window = 0, text = "ni", start = 0, length = 2))
  Native.script(hl, composing)
  match verify(Native.composing(hl) == "ni", "an input method's composition is held while it lasts") {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }
  typed(hl, "n")
  match verify(Native.composing(hl) == "" and contains(Native.screenText(hl), "<Zed Industriesn>"), "the committed text ends the composition") {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }
  key(hl, 8, 0)
  val editedFrame = match frameOf(hl) { case Ok(p) -> p; case Err(m) -> return Err(error = m) }
  match compare("edited", dir, update, editedFrame) {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }

  match notesScenario(hl, dir, update) {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }
  match bidiScenario(hl, dir, update) {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }

  // Tab to the Save button and press Enter, then see the list and the toast.
  match Native.findByText(hl, "button", "Save") {
    case None -> return Err(error = "no Save button")
    case Some(save) -> click(hl, save)
  }
  Native.settle(hl, 200, 5000)
  val savedText = Native.screenText(hl)
  match verify(contains(savedText, "Zed Industries") and not contains(savedText, "Customer 1"), "saving returned to the list with the new name") {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m + "\n" + savedText)
  }
  var toasted = false
  for t in Native.toastTexts(hl) {
    if t == "Customer saved" {
      toasted = true
    }
  }
  match verify(toasted, "a toast reported the save") {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }
  val savedFrame = match frameOf(hl) { case Ok(p) -> p; case Err(m) -> return Err(error = m) }
  compare("saved", dir, update, savedFrame)
}

func check(dir: String, update: Bool): Int {
  match Window.init(Window.initVideo) {
    case Err(m) -> return fail(m)
    case Ok(_) -> ()
  }
  val repo = Store.seeded()
  val cfg = Native.defaultConfig("Customers")
  val outcome = Native.withHeadless(
    cfg,
    { url: String -> route(repo, url) },
    "/customers",
    width,
    height,
    1.0f32,
    { hl: Native.Headless -> scenario(hl, dir, update) }
  )
  Window.quit()
  match outcome {
    case Err(m) -> fail(m)
    case Ok(Err(m)) -> fail(m)
    case Ok(Ok(_)) -> {
      Console.println("native ui check passed")
      0
    }
  }
}

func main(): Int {
  val args = Environment.args()
  if args.length >= 3 and args[1] == "--check" {
    return check(args[2], args.length >= 4 and args[3] == "--update")
  }
  val repo = Store.seeded()
  val cfg = Native.defaultConfig("Customers").copy(startPath = "/customers")
  Native.run(cfg, { url: String -> route(repo, url) })
}
