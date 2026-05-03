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

pub func parseJson(s: in String): JsonDoc { hostParseJson(s) }

pub func rootElement(d: in JsonDoc): JsonElement { hostRootElement(d) }

// =====================================================================
// Walking the tree.
//
// `getProperty(elem, "name")` throws if the name doesn't exist; use
// `tryGetProperty` for the Option-returning variant.
// =====================================================================

pub func getProperty(elem: in JsonElement, name: in String): JsonElement {
  hostGetProperty(elem, name)
}

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

pub func getString(elem: in JsonElement): String   { hostGetString(elem) }
pub func getInt32(elem: in JsonElement): Int       { hostGetInt32(elem) }
pub func getInt64(elem: in JsonElement): Long      { hostGetInt64(elem) }
pub func getBoolean(elem: in JsonElement): Bool    { hostGetBoolean(elem) }
pub func getDouble(elem: in JsonElement): Double   { hostGetDouble(elem) }

pub func tryGetInt(elem: in JsonElement): Option[Int] {
  var v: Int = default()
  if hostTryGetInt32(elem, v) { Some(value = v) } else { None }
}

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
pub func encodeString(s: in String): String { hostEncodeString(s) }
