//! std/_kernel/json_host.l - host boundary for System.Text.Json.
//!
//! Holds every `@externTarget` and `extern type` declaration that
//! `Std.Json` formerly declared inline.  Kernel function names carry
//! a `host` prefix so they don't collide with the user-facing names
//! in `Std.Json` when the test inliner merges every stdlib file into
//! one user package.
//!
//! Internal: only `Std.Json` should import this; per
//! `compiler/lyric/std/_kernel/README.md` the kernel is the audited
//! extern boundary, not a general-purpose API.
@axiom("System.Text.Json operations conform to their documented .NET contracts")
package Std.JsonHost

import Std.Collections

// brings `List[T]` into scope for the slice readers
extern type JsonDoc = "System.Text.Json.JsonDocument"

extern type JsonElement = "System.Text.Json.JsonElement"

// Nested CLR type — `+` separates the outer type from the nested
// `ArrayEnumerator` struct.  Used by the slice-reader helpers to
// iterate `JsonElement.EnumerateArray()` without an F#-side shim.
extern type JsonArrayEnumerator = "System.Text.Json.JsonElement+ArrayEnumerator"

extern type JsonObjectEnumerator = "System.Text.Json.JsonElement+ObjectEnumerator"

extern type JsonProperty = "System.Text.Json.JsonProperty"

extern type JsonEncodedText = "System.Text.Json.JsonEncodedText"

// =====================================================================
// Parsing.
//
// Resolves to `JsonDocument.Parse(string, JsonDocumentOptions = default)`
// via the FFI default-arg emit (the BCL overload is reachable as 1-arg
// from C# because the second parameter has a default value).
// =====================================================================
@externTarget("System.Text.Json.JsonDocument.Parse")
pub func hostParseJson(s: in String): JsonDoc = ()

/// Release the unmanaged memory held by a JsonDocument.
/// `JsonDocument` implements `IDisposable`; calling `Dispose()` immediately
/// returns the pooled `byte[]` backing the JSON to the array pool instead
/// of waiting for the GC.  Every `lyricJsonGet*` helper in `Std.Json` calls
/// this via `defer` so documents are released at the earliest opportunity.
pub func hostDisposeJson(d: in JsonDoc): Unit {
  d.Dispose()
}

pub func hostRootElement(d: in JsonDoc): JsonElement {
  d.RootElement
}

// =====================================================================
// Walking the tree.
// =====================================================================
pub func hostGetProperty(elem: in JsonElement, name: in String): JsonElement {
  elem.GetProperty(name)
}

@externInstance
@externTarget("System.Text.Json.JsonElement.TryGetProperty")
pub func hostTryGetProperty(elem: in JsonElement, name: in String, out_: out JsonElement): Bool = ()

// =====================================================================
// Leaf accessors.  All `GetXyz` methods on `JsonElement` throw if the
// kind is wrong; the `tryGet*` family is the safe wrapper.
// =====================================================================
pub func hostGetString(elem: in JsonElement): String {
  elem.GetString()
}

pub func hostGetInt32(elem: in JsonElement): Int {
  elem.GetInt32()
}

pub func hostGetInt64(elem: in JsonElement): Long {
  elem.GetInt64()
}

pub func hostGetBoolean(elem: in JsonElement): Bool {
  elem.GetBoolean()
}

pub func hostGetDouble(elem: in JsonElement): Double {
  elem.GetDouble()
}

@externInstance
@externTarget("System.Text.Json.JsonElement.TryGetInt32")
pub func hostTryGetInt32(elem: in JsonElement, value: out Int): Bool = ()

@externInstance
@externTarget("System.Text.Json.JsonElement.TryGetInt64")
pub func hostTryGetInt64(elem: in JsonElement, value: out Long): Bool = ()

@externInstance
@externTarget("System.Text.Json.JsonElement.TryGetDouble")
pub func hostTryGetDouble(elem: in JsonElement, value: out Double): Bool = ()

pub func hostGetRawText(elem: in JsonElement): String {
  elem.GetRawText()
}

pub func hostValueKind(elem: in JsonElement): Int {
  elem.ValueKind
}

// =====================================================================
// Array iteration — direct externs over `JsonElement.ArrayEnumerator`
// (the nested-CLR struct) so slice readers can stay in pure Lyric.
// MoveNext mutates the enumerator's internal index, so the Lyric
// param is `inout`; Current is a property getter and doesn't mutate
// but routes through `propGetter ()` in the FFI resolver.
// =====================================================================
pub func hostEnumerateArray(elem: in JsonElement): JsonArrayEnumerator {
  elem.EnumerateArray()
}

@externInstance
@externTarget("System.Text.Json.JsonElement+ArrayEnumerator.MoveNext")
pub func hostEnumMoveNext(en: inout JsonArrayEnumerator): Bool = ()

@externInstance
@externTarget("System.Text.Json.JsonElement+ArrayEnumerator.get_Current")
pub func hostEnumCurrent(en: inout JsonArrayEnumerator): JsonElement = ()

// =====================================================================
// Object iteration — direct externs over `JsonElement.ObjectEnumerator`
// (the nested-CLR struct) so object-walking code can stay in pure Lyric.
// =====================================================================
pub func hostEnumerateObject(elem: in JsonElement): JsonObjectEnumerator {
  elem.EnumerateObject()
}

@externInstance
@externTarget("System.Text.Json.JsonElement+ObjectEnumerator.MoveNext")
pub func hostEnumObjectMoveNext(en: inout JsonObjectEnumerator): Bool = ()

@externInstance
@externTarget("System.Text.Json.JsonElement+ObjectEnumerator.get_Current")
pub func hostEnumObjectCurrent(en: inout JsonObjectEnumerator): JsonProperty = ()

pub func hostPropertyName(prop: in JsonProperty): String {
  prop.Name
}

pub func hostPropertyValue(prop: in JsonProperty): JsonElement {
  prop.Value
}

// =====================================================================
// Manual serialization helpers.
//
// `JsonEncodedText.Encode(string)` returns a struct (`JsonEncodedText`)
// rather than a string, so the encode-and-quote operation is split
// into two extern calls plus a native-Lyric concat.  The struct's
// `ToString()` instance method renders the escaped UTF-16 form
// without the surrounding quotes; we add those in Lyric.
// =====================================================================
pub func hostEncodeText(s: in String): JsonEncodedText {
  JsonEncodedText.Encode(s)
}

pub func hostEncodedTextToString(t: in JsonEncodedText): String {
  t.ToString()
}

/// Wrap `s` as a JSON string literal — escapes quotes / backslashes /
/// control characters via `JsonEncodedText.Encode` and surrounds the
/// result with `"` characters.
pub func hostEncodeString(s: in String): String {
  val encoded = hostEncodeText(s)
  return "\"" + hostEncodedTextToString(encoded) + "\""
}
