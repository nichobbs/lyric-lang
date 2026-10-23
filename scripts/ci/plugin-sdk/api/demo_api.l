//! The sample plugin API package the plugin SDK end-to-end test generates
//! SDKs for (scripts/ci/plugin-sdk-e2e.sh, D207).
package Demo.Api

import Std.Core
import Std.Collections
import Std.JsonValue

pub enum Mood {
  case Happy
  case Sad
}

pub union Shape {
  case Circle(radius: Double)
  case Rect(w: Double, h: Double)
  case Empty
}

@plugin_handle
pub type DocRef = Long

pub exposed record Greeting {
  text: String
  count: Int
  big: Long
  huge: ULong
  ratio: Float
  initial: Char
  tags: List[String]
  mood: Mood
  note: Option[String]
  data: List[Byte]
  scores: Map[String, Long]
  pair: (Int, String)
  extra: JsonValue
  shapes: List[Shape] = []
}

pub union GreetError {
  case BadName(name: String)
  case Failed(detail: String)
}

pub exposed record GreeterContributions {
  commands: List[String] = []
  priority: Int = 0
}

pub exposed record FilesGrant {
  roots: List[String]
}

@capability(grant = FilesGrant)
pub interface Files {
  func readFile(path: in String): Result[String, GreetError]
  func listFiles(dir: in String): Result[List[String], GreetError]
}

@capability
pub interface Notify {
  func show(text: in String, level: in Int): Result[Unit, GreetError]
}

@plugin_point(version = "1.2", contributions = GreeterContributions, allows(Files, Notify))
pub interface Greeter {
  func greet(name: in String, times: in Int): Result[Greeting, GreetError]
  func area(s: in Shape): Result[Double, GreetError]
  func open(doc: in DocRef, counts: in Map[String, Long]): Result[List[DocRef], GreetError]
  func echo(g: in Greeting): Result[Greeting, GreetError]
  func readVia(path: in String): Result[String, GreetError]
}
