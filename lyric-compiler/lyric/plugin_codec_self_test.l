//! plugin_codec_self_test.l — runtime test of the encoders and decoders
//! `Lyric.PluginExpand` generates for plugin boundary types (D207
//! Decision 4), on every managed target:
//!
//!   lyric test lyric-compiler/lyric/plugin_codec_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/plugin_codec_self_test.l
//!
//! The capability below exists only to make the types boundary types; the
//! tests call the generated `pluginEncode<T>` / `pluginDecode<T>` directly,
//! and check the JSON text, the round trip, and the decoders' rejection of
//! missing members, unknown cases and wrong kinds.
@test_module
package Lyric.PluginCodecSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.JsonValue

@plugin_handle
pub type DocId = Long

pub enum Severity {
  case Info
  case Warning
}

pub record Position {
  line: Int
  col: Int
}

pub union Edit {
  case Insert(at: Position, text: String)
  case Delete(start: Position, stop: Position)
  case Clear
}

pub record Note {
  doc: DocId
  severity: Severity
  tags: Map[String, Long]
  data: List[Byte]
  raw: slice[Byte]
  extra: Option[String]
  missing: Option[Int]
  edits: List[Edit]
  pair: (Int, Bool)
  outcome: Result[Int, String]
  ratio: Double
  small: Float
  count: UInt
  big: ULong
  initial: Char
  octet: Byte
  free: JsonValue
}

@capability
pub interface Notes {
  func put(note: in Note): Result[Unit, Severity]
}

func sampleNote(): Note {
  val tags: Map[String, Long] = newMap()
  tags["a"] = 1i64
  val data: List[Byte] = newList()
  data.add(0u8)
  data.add(255u8)
  data.add(16u8)
  val edits: List[Edit] = newList()
  edits.add(Edit.Insert(at = Position(line = 1, col = 2), text = "hi \"there\""))
  edits.add(Edit.Delete(start = Position(line = 3, col = 4), stop = Position(line = 5, col = 6)))
  edits.add(Edit.Clear)
  Note(
    doc = DocId.from(42i64),
    severity = Severity.Warning,
    tags = tags,
    data = data,
    raw = [1u8, 2u8],
    extra = Some(value = "x"),
    missing = None,
    edits = edits,
    pair = (7, true),
    outcome = Err(error = "bad"),
    ratio = 2.5,
    small = 1.5f32,
    count = 4000000000u32,
    big = 18000000000000000000u64,
    initial = 'q',
    octet = 200u8,
    free = JsonValue.JBool(value = true)
  )
}

func decodeText(text: in String): Result[Note, String] {
  match parseValue(text) {
    case Ok(j) -> pluginDecodeNote(j)
    case Err(e) -> Err(error = "json: " + e.message())
  }
}

func errOf(r: in Result[Note, String]): String {
  match r {
    case Ok(_) -> "<decoded>"
    case Err(m) -> m
  }
}

test "a record encodes in declaration order with Decision 4's shapes" {
  val text = writeValue(pluginEncodeNote(sampleNote()))
  assertTrue(
    text.startsWith("{\"doc\":42,\"severity\":\"Warning\",\"tags\":{\"a\":1},\"data\":\"AP8Q\",\"raw\":\"AQI=\","),
    "head: " + text
  )
  assertTrue(text.contains("\"extra\":\"x\",\"missing\":null,"), "options: " + text)
  assertTrue(
    text.contains("{\"case\":\"Insert\",\"at\":{\"line\":1,\"col\":2},\"text\":\"hi \\\"there\\\"\"}"),
    "union case: " + text
  )
  assertTrue(text.contains("{\"case\":\"Clear\"}"), "nullary case: " + text)
  assertTrue(text.contains("\"pair\":[7,true],\"outcome\":{\"err\":\"bad\"},"), "tuple and result: " + text)
  assertTrue(text.contains("\"count\":4000000000,"), "UInt: " + text)
  assertTrue(text.contains("\"initial\":\"q\",\"octet\":200,\"free\":true}"), "tail: " + text)
}

test "a record round-trips" {
  val n = sampleNote()
  val text = writeValue(pluginEncodeNote(n))
  match decodeText(text) {
    case Ok(d) -> {
      assertEqual(writeValue(pluginEncodeNote(d)), text, "re-encoding the decoded value gives the same JSON")
      assertTrue(d.doc == n.doc, "handle")
      assertTrue(d.severity == Severity.Warning, "enum")
      assertEqualInt(d.data.count, 3, "bytes")
      assertEqualInt(d.data[1].toInt(), 255, "byte value")
      assertEqualInt(d.edits.count, 3, "edits")
      assertTrue(d.edits[0] == n.edits[0], "union value")
      assertTrue(d.count == 4000000000u32, "UInt value")
      assertTrue(d.big == 18000000000000000000u64, "ULong above Long.MaxValue")
      assertTrue(d.initial == 'q', "Char")
      assertTrue(d.small == 1.5f32, "Float")
      match d.missing {
        case None -> ()
        case Some(_) -> panic("None decodes as None")
      }
    }
    case Err(m) -> panic("decode failed: " + m)
  }
}

test "unknown members are ignored and a missing Option member is None" {
  val full = writeValue(pluginEncodeNote(sampleNote()))
  val extended = "{\"future\":[1,2]," + full.substring(1)
  match decodeText(extended) {
    case Ok(_) -> ()
    case Err(m) -> panic("an unknown member must be ignored: " + m)
  }
  val withoutMissing = full.replace("\"missing\":null,", "")
  match decodeText(withoutMissing) {
    case Ok(d) -> match d.missing { case None -> (); case Some(_) -> panic("absent Option member decodes as None") }
    case Err(m) -> panic("an absent Option member must decode: " + m)
  }
}

test "a missing required member is rejected" {
  val full = writeValue(pluginEncodeNote(sampleNote()))
  val text = full.replace("\"ratio\":2.5,", "")
  assertEqual(errOf(decodeText(text)), "Note.ratio: the member is missing", "missing member")
}

test "an unknown union case or enum name is rejected" {
  val full = writeValue(pluginEncodeNote(sampleNote()))
  val badCase = full.replace("\"case\":\"Clear\"", "\"case\":\"Wipe\"")
  assertEqual(errOf(decodeText(badCase)), "Note.edits: [2]: Edit: unknown case \"Wipe\"", "unknown case")
  val badEnum = full.replace("\"severity\":\"Warning\"", "\"severity\":\"Fatal\"")
  assertEqual(errOf(decodeText(badEnum)), "Note.severity: Severity: unknown case \"Fatal\"", "unknown enum")
}

test "a wrong JSON kind is rejected" {
  val full = writeValue(pluginEncodeNote(sampleNote()))
  val badKind = full.replace("\"line\":1,", "\"line\":\"one\",")
  assertEqual(
    errOf(decodeText(badKind)),
    "Note.edits: [0]: Edit.Insert.at: Position.line: expected an integer, got a string",
    "wrong kind"
  )
  assertEqual(errOf(decodeText("[1]")), "Note: expected an object, got an array", "not an object")
  val badRange = full.replace("\"octet\":200", "\"octet\":300")
  assertEqual(errOf(decodeText(badRange)), "Note.octet: the integer 300 is out of range for Byte", "out of range")
  val badBytes = full.replace("\"AP8Q\"", "\"!!\"")
  assertEqual(
    errOf(decodeText(badBytes)),
    "Note.data: expected base64-encoded bytes, got a string that is not base64",
    "bad base64"
  )
}
