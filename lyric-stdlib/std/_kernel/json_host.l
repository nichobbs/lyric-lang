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

// Std.Collections import removed for bootstrap build (no longer using List[T])
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
@externTarget("System.Text.Json.JsonDocument.Dispose")
pub func hostDisposeJson(d: in JsonDoc): Unit = ()

@externTarget("System.Text.Json.JsonDocument.RootElement")
pub func hostRootElement(d: in JsonDoc): JsonElement = ()

// =====================================================================
// Walking the tree.
// =====================================================================
@externTarget("System.Text.Json.JsonElement.GetProperty")
pub func hostGetProperty(elem: in JsonElement, name: in String): JsonElement = ()

@externTarget("System.Text.Json.JsonElement.TryGetProperty")
pub func hostTryGetProperty(elem: in JsonElement, name: in String, out_: out JsonElement): Bool = ()

// =====================================================================
// Leaf accessors.  All `GetXyz` methods on `JsonElement` throw if the
// kind is wrong; the `tryGet*` family is the safe wrapper.
// =====================================================================
@externTarget("System.Text.Json.JsonElement.GetString")
pub func hostGetString(elem: in JsonElement): String = ()

@externTarget("System.Text.Json.JsonElement.GetInt32")
pub func hostGetInt32(elem: in JsonElement): Int = ()

@externTarget("System.Text.Json.JsonElement.GetInt64")
pub func hostGetInt64(elem: in JsonElement): Long = ()

@externTarget("System.Text.Json.JsonElement.GetBoolean")
pub func hostGetBoolean(elem: in JsonElement): Bool = ()

@externTarget("System.Text.Json.JsonElement.GetDouble")
pub func hostGetDouble(elem: in JsonElement): Double = ()

@externTarget("System.Text.Json.JsonElement.TryGetInt32")
pub func hostTryGetInt32(elem: in JsonElement, value: out Int): Bool = ()

@externTarget("System.Text.Json.JsonElement.TryGetInt64")
pub func hostTryGetInt64(elem: in JsonElement, value: out Long): Bool = ()

@externTarget("System.Text.Json.JsonElement.TryGetDouble")
pub func hostTryGetDouble(elem: in JsonElement, value: out Double): Bool = ()

@externTarget("System.Text.Json.JsonElement.GetRawText")
pub func hostGetRawText(elem: in JsonElement): String = ()

@externTarget("System.Text.Json.JsonElement.ValueKind")
pub func hostValueKind(elem: in JsonElement): Int = ()

// =====================================================================
// Array iteration — direct externs over `JsonElement.ArrayEnumerator`
// (the nested-CLR struct) so slice readers can stay in pure Lyric.
// MoveNext mutates the enumerator's internal index, so the Lyric
// param is `inout`; Current is a property getter and doesn't mutate
// but routes through `propGetter ()` in the FFI resolver.
// =====================================================================
@externTarget("System.Text.Json.JsonElement.EnumerateArray")
pub func hostEnumerateArray(elem: in JsonElement): JsonArrayEnumerator = ()

@externTarget("System.Text.Json.JsonElement+ArrayEnumerator.MoveNext")
pub func hostEnumMoveNext(en: inout JsonArrayEnumerator): Bool = ()

@externTarget("System.Text.Json.JsonElement+ArrayEnumerator.Current")
pub func hostEnumCurrent(en: inout JsonArrayEnumerator): JsonElement = ()

// =====================================================================
// Object iteration — direct externs over `JsonElement.ObjectEnumerator`
// (the nested-CLR struct) so object-walking code can stay in pure Lyric.
// =====================================================================
@externTarget("System.Text.Json.JsonElement.EnumerateObject")
pub func hostEnumerateObject(elem: in JsonElement): JsonObjectEnumerator = ()

@externTarget("System.Text.Json.JsonElement+ObjectEnumerator.MoveNext")
pub func hostEnumObjectMoveNext(en: inout JsonObjectEnumerator): Bool = ()

@externTarget("System.Text.Json.JsonElement+ObjectEnumerator.Current")
pub func hostEnumObjectCurrent(en: inout JsonObjectEnumerator): JsonProperty = ()

@externTarget("System.Text.Json.JsonProperty.Name")
pub func hostPropertyName(prop: in JsonProperty): String = ()

@externTarget("System.Text.Json.JsonProperty.Value")
pub func hostPropertyValue(prop: in JsonProperty): JsonElement = ()

// =====================================================================
// Manual serialization helpers.
//
// `JsonEncodedText.Encode(string)` returns a struct (`JsonEncodedText`)
// rather than a string, so the encode-and-quote operation is split
// into two extern calls plus a native-Lyric concat.  The struct's
// `ToString()` instance method renders the escaped UTF-16 form
// without the surrounding quotes; we add those in Lyric.
// =====================================================================
@externTarget("System.Text.Json.JsonEncodedText.Encode")
pub func hostEncodeText(s: in String): JsonEncodedText = ()

@externTarget("System.Text.Json.JsonEncodedText.ToString")
pub func hostEncodedTextToString(t: in JsonEncodedText): String = ()

/// Wrap `s` as a JSON string literal — escapes quotes / backslashes /
/// control characters via `JsonEncodedText.Encode` and surrounds the
/// result with `"` characters.
pub func hostEncodeString(s: in String): String {
  val encoded = hostEncodeText(s)
  return "\"" + hostEncodedTextToString(encoded) + "\""
}

// =====================================================================
// fromJson slice readers — DEFERRED to full stdlib build
// =====================================================================
// Bootstrap NOTE: These functions use List[T] generics which trigger
// a known issue in the F# project-mode emitter's generic type resolution.
// They are deferred to lyric-stdlib/lyric.full.toml for the self-hosted build.
// Stub implementations provided here for signature compatibility.
// =====================================================================
pub func lyricJsonGetIntSlice(s: in String, name: in String, value: out slice[Int]): Bool {
  // Stub for bootstrap build (deferred to full stdlib build)
  value = []
  return false
}

pub func lyricJsonGetLongSlice(s: in String, name: in String, value: out slice[Long]): Bool {
  // Stub for bootstrap build
  value = []
  return false
}

pub func lyricJsonGetDoubleSlice(s: in String, name: in String, value: out slice[Double]): Bool {
  // Stub for bootstrap build
  value = []
  return false
}

pub func lyricJsonGetBoolSlice(s: in String, name: in String, value: out slice[Bool]): Bool {
  // Stub for bootstrap build
  value = []
  return false
}

pub func lyricJsonGetStringSlice(s: in String, name: in String, value: out slice[String]): Bool {
  // Stub for bootstrap build
  value = []
  return false
}
