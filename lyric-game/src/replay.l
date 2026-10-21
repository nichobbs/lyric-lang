//! replay.l - Game.Replay: recorded input streams (docs/67 G7).
//!
//! A `Recording` holds, for each update step, the events that arrived before it, plus the seed the
//! game started from.  Replaying it through `Game.Input.next` rebuilds the very frames the live
//! session saw, so a deterministic `update(state, input, dt)` reaches the same states.  The text
//! form is line-based, diffable and stable, so a recording can be checked in as a test fixture:
//!
//!   lyric-replay 1
//!   seed 12345
//!   K+97;P160,80;B+1
//!   (an empty line is a step with no events)
//!   T104.105
package Game.Replay

import Std.Core
import Std.Collections
import Std.String
import Std.Parse
import Std.Encoding
import Game.Input

pub record Recording {
  seed: Long
  steps: List[List[InputEvent]]
}

pub func newRecording(seed: in Long): Recording {
  Recording(seed = seed, steps = newList())
}

/// Appends one step's events.
pub func record(r: in Recording, events: in List[InputEvent]): Unit {
  r.steps.add(events)
}

func encodeEvent(e: InputEvent): String {
  match e {
    case KeyPressed(key) -> "K+" + key.toString()
    case KeyReleased(key) -> "K-" + key.toString()
    case PointerMoved(x16, y16) -> "P" + x16.toString() + "," + y16.toString()
    case ButtonPressed(button) -> "B+" + button.toString()
    case ButtonReleased(button) -> "B-" + button.toString()
    case Scrolled(dx16, dy16) -> "S" + dx16.toString() + "," + dy16.toString()
    case TextTyped(text) -> {
      val points = codePoints(text)
      val parts: List[String] = newList()
      var i = 0
      while i < points.length {
        parts.add(points[i].toString())
        i = i + 1
      }
      "T" + joinList(".", parts)
    }
  }
}

/// The recording as text.
pub func encode(r: in Recording): String {
  val lines: List[String] = newList()
  lines.add("lyric-replay 1")
  lines.add("seed " + r.seed.toString())
  for step in r.steps {
    val parts: List[String] = newList()
    for e in step {
      parts.add(encodeEvent(e))
    }
    lines.add(joinList(";", parts))
  }
  joinList("\n", lines) + "\n"
}

func parsePair(s: String): Option[List[Int]] {
  val parts = split(s, ",")
  if parts.length != 2 {
    return None
  }
  val a = match parseOptInt(parts[0]) { case Some(v) -> v; case None -> return None }
  val b = match parseOptInt(parts[1]) { case Some(v) -> v; case None -> return None }
  val result: List[Int] = newList()
  result.add(a)
  result.add(b)
  Some(value = result)
}

func decodeEvent(s: String): Result[InputEvent, String] {
  val bad: Result[InputEvent, String] = Err(error = "unreadable event \"" + s + "\"")
  if startsWith(s, "K+") {
    return match parseOptInt(substring(s, 2)) { case Some(k) -> Ok(value = KeyPressed(key = k)); case None -> bad }
  }
  if startsWith(s, "K-") {
    return match parseOptInt(substring(s, 2)) { case Some(k) -> Ok(value = KeyReleased(key = k)); case None -> bad }
  }
  if startsWith(s, "B+") {
    return match parseOptInt(substring(s, 2)) { case Some(b) -> Ok(value = ButtonPressed(button = b)); case None -> bad }
  }
  if startsWith(s, "B-") {
    return match parseOptInt(substring(s, 2)) { case Some(b) -> Ok(value = ButtonReleased(button = b)); case None -> bad }
  }
  if startsWith(s, "P") {
    return match parsePair(substring(s, 1)) {
      case Some(p) -> Ok(value = PointerMoved(x16 = p[0], y16 = p[1]))
      case None -> bad
    }
  }
  if startsWith(s, "S") {
    return match parsePair(substring(s, 1)) {
      case Some(p) -> Ok(value = Scrolled(dx16 = p[0], dy16 = p[1]))
      case None -> bad
    }
  }
  if startsWith(s, "T") {
    val body = substring(s, 1)
    val sb = StringBuilder.new()
    if length(body) > 0 {
      for part in split(body, ".") {
        match parseOptInt(part) {
          case Some(cp) -> StringBuilder.append(sb, codepointToString(cp))
          case None -> return bad
        }
      }
    }
    return Ok(value = TextTyped(text = StringBuilder.toString(sb)))
  }
  bad
}

/// Reads text written by `encode`.  `Err` names the line that could not be read.
pub func decode(text: in String): Result[Recording, String] {
  val lines = split(text, "\n")
  if lines.length < 2 or lines[0] != "lyric-replay 1" {
    return Err(error = "not a lyric-replay 1 recording")
  }
  if not startsWith(lines[1], "seed ") {
    return Err(error = "line 2 should be the seed")
  }
  val seed = match parseOptLong(substring(lines[1], 5)) {
    case Some(s) -> s
    case None -> return Err(error = "line 2: unreadable seed")
  }
  val steps: List[List[InputEvent]] = newList()
  var i = 2
  val last = if lines.length > 2 and lines[lines.length - 1] == "" { lines.length - 1 } else { lines.length }
  while i < last {
    val events: List[InputEvent] = newList()
    if length(lines[i]) > 0 {
      for part in split(lines[i], ";") {
        match decodeEvent(part) {
          case Ok(e) -> events.add(e)
          case Err(m) -> return Err(error = "line " + (i + 1).toString() + ": " + m)
        }
      }
    }
    steps.add(events)
    i = i + 1
  }
  Ok(value = Recording(seed = seed, steps = steps))
}

/// The input frames a recording replays, one per step.
pub func frames(r: in Recording): List[InputFrame] {
  val result: List[InputFrame] = newList()
  var prev = initialFrame()
  for step in r.steps {
    prev = next(prev, step)
    result.add(prev)
  }
  result
}
