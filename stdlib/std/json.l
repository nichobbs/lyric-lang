// std/json.l - Minimal JSON parsing on top of `System.Text.Json`.
//
// Bootstrap-grade scope: parse a JSON string, walk fields, read
// string / integer / boolean leaves.  Serialization is hand-rolled
// for now (build the string yourself); a real `serialize` lands
// when generic `JsonSerializer.Serialize<T>` is wired through.
//
// Externs live in `_kernel/json_host.l` (`Std.JsonHost`); this file
// is pure trampolines + Option-returning safe wrappers.

package Std.Json

import Std.Core
import Std.JsonHost     // brings `JsonDoc`, `JsonElement`, and `host*` fns into scope

// =====================================================================
// Parsing.
// =====================================================================

@stable(since="1.0")
pub func parseJson(s: in String): JsonDoc { hostParseJson(s) }

@stable(since="1.0")
pub func rootElement(d: in JsonDoc): JsonElement { hostRootElement(d) }

// =====================================================================
// Walking the tree.
//
// `getProperty(elem, "name")` throws if the name doesn't exist; use
// `tryGetProperty` for the Option-returning variant.
// =====================================================================

@stable(since="1.0")
pub func getProperty(elem: in JsonElement, name: in String): JsonElement {
  hostGetProperty(elem, name)
}

@stable(since="1.0")
pub func tryGetProperty(elem: in JsonElement, name: in String): Option[JsonElement] {
  var v: JsonElement = default()
  if hostTryGetProperty(elem, name, v) { Some(value = v) } else { None }
}

// =====================================================================
// Leaf accessors.
//
// All `getXyz` methods on `JsonElement` throw if the kind is wrong.
// Use the `tryGet*` family for safer extraction.
// =====================================================================

@stable(since="1.0")
pub func getString(elem: in JsonElement): String   { hostGetString(elem) }
@stable(since="1.0")
pub func getInt32(elem: in JsonElement): Int       { hostGetInt32(elem) }
@stable(since="1.0")
pub func getInt64(elem: in JsonElement): Long      { hostGetInt64(elem) }
@stable(since="1.0")
pub func getBoolean(elem: in JsonElement): Bool    { hostGetBoolean(elem) }
@stable(since="1.0")
pub func getDouble(elem: in JsonElement): Double   { hostGetDouble(elem) }

@stable(since="1.0")
pub func tryGetInt(elem: in JsonElement): Option[Int] {
  var v: Int = default()
  if hostTryGetInt32(elem, v) { Some(value = v) } else { None }
}

@stable(since="1.0")
pub func tryGetLong(elem: in JsonElement): Option[Long] {
  var v: Long = default()
  if hostTryGetInt64(elem, v) { Some(value = v) } else { None }
}

// =====================================================================
// Manual serialization helpers — until `JsonSerializer.Serialize<T>`
// is wired up, building JSON output is a string-concat affair.  These
// helpers make it slightly less error-prone.
// =====================================================================

/// Wrap a string value as a JSON literal — escapes quotes and
/// backslashes, surrounds with `"` characters.
@stable(since="1.0")
pub func encodeString(s: in String): String { hostEncodeString(s) }

// =====================================================================
// fromJson scalar field readers — used by @derive(Json) synthesised stubs.
// Each re-parses the JSON string and walks to the named property.
// =====================================================================

pub func lyricJsonGetInt(s: in String, name: in String, value: out Int): Bool {
  val doc = hostParseJson(s)
  val root = hostRootElement(doc)
  var elem: JsonElement = default()
  if not hostTryGetProperty(root, name, elem) {
    value = default()
    return false
  }
  return hostTryGetInt32(elem, value)
}

pub func lyricJsonGetLong(s: in String, name: in String, value: out Long): Bool {
  val doc = hostParseJson(s)
  val root = hostRootElement(doc)
  var elem: JsonElement = default()
  if not hostTryGetProperty(root, name, elem) {
    value = default()
    return false
  }
  return hostTryGetInt64(elem, value)
}

pub func lyricJsonGetDouble(s: in String, name: in String, value: out Double): Bool {
  val doc = hostParseJson(s)
  val root = hostRootElement(doc)
  var elem: JsonElement = default()
  if not hostTryGetProperty(root, name, elem) {
    value = default()
    return false
  }
  return hostTryGetDouble(elem, value)
}

pub func lyricJsonGetBool(s: in String, name: in String, value: out Bool): Bool {
  val doc = hostParseJson(s)
  val root = hostRootElement(doc)
  var elem: JsonElement = default()
  if not hostTryGetProperty(root, name, elem) {
    value = default()
    return false
  }
  // JsonValueKind.True = 5, JsonValueKind.False = 6
  val kind = hostValueKind(elem)
  if kind == 5 or kind == 6 {
    value = hostGetBoolean(elem)
    return true
  }
  value = default()
  return false
}

pub func lyricJsonGetString(s: in String, name: in String, value: out String): Bool {
  val doc = hostParseJson(s)
  val root = hostRootElement(doc)
  var elem: JsonElement = default()
  if not hostTryGetProperty(root, name, elem) {
    value = default()
    return false
  }
  // JsonValueKind.String = 3
  if hostValueKind(elem) != 3 {
    value = default()
    return false
  }
  value = hostGetString(elem)
  return true
}

pub func lyricJsonGetSubObject(s: in String, name: in String, value: out String): Bool {
  val doc = hostParseJson(s)
  val root = hostRootElement(doc)
  var elem: JsonElement = default()
  if not hostTryGetProperty(root, name, elem) {
    value = "{}"
    return false
  }
  value = hostGetRawText(elem)
  return true
}
