// std/json.l - Minimal JSON parsing on top of `System.Text.Json`.
//
// Bootstrap-grade scope: parse a JSON string, walk fields, read
// string / integer / boolean leaves.  Serialization is hand-rolled
// for now (build the string yourself); a real `serialize` lands
// when generic `JsonSerializer.Serialize<T>` is wired through.
package Std.Json

import Std.Core

extern type JsonDoc     = "System.Text.Json.JsonDocument"
extern type JsonElement = "System.Text.Json.JsonElement"

// =====================================================================
// Parsing.
// =====================================================================

// Routed through `Lyric.Stdlib.JsonHost.Parse` instead of the BCL
// `JsonDocument.Parse(string, JsonDocumentOptions = default)`
// directly: the FFI default-arg emit for `JsonDocumentOptions` still
// produces invalid IL.  The host wrapper is a one-liner and the
// indirection collapses if/when default-arg emit is fixed for
// arbitrary structs.
@externTarget("Lyric.Stdlib.JsonHost.Parse")
pub func parseJson(s: in String): JsonDoc = ()

@externTarget("System.Text.Json.JsonDocument.RootElement")
pub func rootElement(d: in JsonDoc): JsonElement = ()

// =====================================================================
// Walking the tree.
//
// `getProperty(elem, "name")` returns the named property's element;
// throws if the name doesn't exist (use `tryGetProperty` for the
// safe variant).
// =====================================================================

@externTarget("System.Text.Json.JsonElement.GetProperty")
pub func getProperty(elem: in JsonElement, name: in String): JsonElement = ()

@externTarget("System.Text.Json.JsonElement.TryGetProperty")
pub func hostTryGetProperty(elem: in JsonElement, name: in String, out_: out JsonElement): Bool = ()

pub func tryGetProperty(elem: in JsonElement, name: in String): Option[JsonElement] {
  var v: JsonElement = default()
  if hostTryGetProperty(elem, name, v) { Some(value = v) } else { None }
}

// =====================================================================
// Leaf accessors.
//
// All `GetXyz` methods on `JsonElement` throw if the kind is wrong.
// Use the `tryGet*` family for safer extraction.
// =====================================================================

@externTarget("System.Text.Json.JsonElement.GetString")
pub func getString(elem: in JsonElement): String = ()

@externTarget("System.Text.Json.JsonElement.GetInt32")
pub func getInt32(elem: in JsonElement): Int = ()

@externTarget("System.Text.Json.JsonElement.GetInt64")
pub func getInt64(elem: in JsonElement): Long = ()

@externTarget("System.Text.Json.JsonElement.GetBoolean")
pub func getBoolean(elem: in JsonElement): Bool = ()

@externTarget("System.Text.Json.JsonElement.GetDouble")
pub func getDouble(elem: in JsonElement): Double = ()

@externTarget("System.Text.Json.JsonElement.TryGetInt32")
pub func hostTryGetInt32(elem: in JsonElement, value: out Int): Bool = ()

pub func tryGetInt(elem: in JsonElement): Option[Int] {
  var v: Int = default()
  if hostTryGetInt32(elem, v) { Some(value = v) } else { None }
}

@externTarget("System.Text.Json.JsonElement.TryGetInt64")
pub func hostTryGetInt64(elem: in JsonElement, value: out Long): Bool = ()

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
/// backslashes, surrounds with `"` characters.  Routes through
/// `Lyric.Stdlib.JsonHost.EncodeString` (the BCL's
/// `JsonEncodedText.Encode` returns a struct that's awkward to
/// bridge directly).
@externTarget("Lyric.Stdlib.JsonHost.EncodeString")
pub func encodeString(s: in String): String = ()
