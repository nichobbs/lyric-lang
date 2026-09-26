//! std/json.l - Minimal JSON parsing on top of `System.Text.Json`.
//!
//! Bootstrap-grade scope: parse a JSON string, walk fields, read
//! string / integer / boolean leaves.  Serialization is hand-rolled
//! for now (build the string yourself); a real `serialize` lands
//! when generic `JsonSerializer.Serialize<T>` is wired through.
//!
//! Externs live in `_kernel/json_host.l` (`Std.JsonHost`); this file
//! is pure trampolines + Option-returning safe wrappers.
//!
//! The `get*` accessors and `getProperty` require the element to have the
//! right kind (`isJsonString`, `isJsonInt32`, `hasProperty`, ...): calling
//! one on the wrong shape is a contract violation, not a host exception.
//! JSON that came from outside the program should be read with the
//! `tryGet*` family instead (#7251).
@runtime_checked
package Std.Json

import Std.Core
import Std.JsonHost

// brings `JsonDoc`, `JsonElement`, and `host*` fns into scope
// =====================================================================
// Parsing.
// =====================================================================
@stable(since = "1.0")
pub func parseJson(s: in String): JsonDoc {
  hostParseJson(s)
}

/// Try to parse a string as a JSON document.
/// Returns `Ok(JsonDoc)` if successful, or `Err(String)` containing the parsing
/// failure message if parsing throws a host-level exception.
@stable(since = "1.0")
pub func tryParseJson(s: in String): Result[JsonDoc, String] {
  try {
    Ok(value = hostParseJson(s))
  } catch Bug as b {
    Err(error = b.message)
  }
}

/// Release the unmanaged memory held by a `JsonDoc`.  Call this when you
/// are done walking the document — typically via `defer { disposeJson(doc) }`.
/// The `lyricJsonGet*` helpers do this automatically; only needed for code
/// that calls `parseJson` directly.
@stable(since = "1.0")
pub func disposeJson(d: in JsonDoc): Unit {
  hostDisposeJson(d)
}

@stable(since = "1.0")
pub func rootElement(d: in JsonDoc): JsonElement {
  hostRootElement(d)
}

// =====================================================================
// Walking the tree.
//
// `getProperty(elem, "name")` requires the name to exist; use
// `tryGetProperty` for the Option-returning variant.
// =====================================================================
@stable(since = "1.0")
pub func getProperty(elem: in JsonElement, name: in String): JsonElement
  requires: hasProperty(elem, name)
{
  hostGetProperty(elem, name)
}

@stable(since = "1.0")
pub func tryGetProperty(elem: in JsonElement, name: in String): Option[JsonElement] {
  // The host throws for a non-object receiver (JsonValueKind.Object = 1).
  if hostValueKind(elem) != 1 {
    return None
  }
  var v: JsonElement = default()
  if hostTryGetProperty(elem, name, v) {
    Some(value = v)
  } else {
    None
  }
}

// =====================================================================
// Leaf accessors.
//
// Each `getXyz` requires the matching `isJsonXyz`. Use the `tryGet*`
// family for data whose shape is not already known.
// =====================================================================
@stable(since = "1.0")
pub func getString(elem: in JsonElement): String
  requires: isJsonString(elem)
{
  hostGetString(elem)
}

@stable(since = "1.0")
pub func getInt32(elem: in JsonElement): Int
  requires: isJsonInt32(elem)
{
  hostGetInt32(elem)
}

@stable(since = "1.0")
pub func getInt64(elem: in JsonElement): Long
  requires: isJsonInt64(elem)
{
  hostGetInt64(elem)
}

@stable(since = "1.0")
pub func getBoolean(elem: in JsonElement): Bool
  requires: isJsonBool(elem)
{
  hostGetBoolean(elem)
}

@stable(since = "1.0")
pub func getDouble(elem: in JsonElement): Double
  requires: isJsonDouble(elem)
{
  hostGetDouble(elem)
}

/// True when `elem` is an object with a property called `name`.
@stable(since = "1.2")
@pure
pub func hasProperty(elem: in JsonElement, name: in String): Bool {
  match tryGetProperty(elem, name) {
    case Some(_) -> true
    case None -> false
  }
}

/// True when `elem` is a JSON string (`getString`'s precondition).
@stable(since = "1.2")
@pure
pub func isJsonString(elem: in JsonElement): Bool {
  hostValueKind(elem) == 3
}

/// True when `elem` is a number that fits an `Int` (`getInt32`'s precondition).
@stable(since = "1.2")
@pure
pub func isJsonInt32(elem: in JsonElement): Bool {
  match tryGetInt(elem) {
    case Some(_) -> true
    case None -> false
  }
}

/// True when `elem` is a number that fits a `Long` (`getInt64`'s precondition).
@stable(since = "1.2")
@pure
pub func isJsonInt64(elem: in JsonElement): Bool {
  match tryGetLong(elem) {
    case Some(_) -> true
    case None -> false
  }
}

/// True when `elem` is `true` or `false` (`getBoolean`'s precondition).
@stable(since = "1.2")
@pure
pub func isJsonBool(elem: in JsonElement): Bool {
  val kind = hostValueKind(elem)
  kind == 5 or kind == 6
}

/// True when `elem` is a number readable as a `Double` (`getDouble`'s
/// precondition).
@stable(since = "1.2")
@pure
pub func isJsonDouble(elem: in JsonElement): Bool {
  match tryGetDouble(elem) {
    case Some(_) -> true
    case None -> false
  }
}

@stable(since = "1.0")
pub func tryGetInt(elem: in JsonElement): Option[Int] {
  // JsonValueKind.Number = 4. Check the kind first to avoid the BCL
  // throwing an exception on non-numeric values (#3824).
  if hostValueKind(elem) != 4 {
    return None
  }
  var v: Int = default()
  if hostTryGetInt32(elem, v) {
    Some(value = v)
  } else {
    None
  }
}

@stable(since = "1.0")
pub func tryGetLong(elem: in JsonElement): Option[Long] {
  // JsonValueKind.Number = 4. Check the kind first to avoid the BCL
  // throwing an exception on non-numeric values (#3824).
  if hostValueKind(elem) != 4 {
    return None
  }
  var v: Long = default()
  if hostTryGetInt64(elem, v) {
    Some(value = v)
  } else {
    None
  }
}

@stable(since = "1.0")
pub func tryGetDouble(elem: in JsonElement): Option[Double] {
  // JsonValueKind.Number = 4. Check the kind first to avoid the BCL
  // throwing an exception on non-numeric values (#3824).
  if hostValueKind(elem) != 4 {
    return None
  }
  var v: Double = default()
  if hostTryGetDouble(elem, v) {
    Some(value = v)
  } else {
    None
  }
}

// =====================================================================
// Manual serialization helpers — until `JsonSerializer.Serialize<T>`
// is wired up, building JSON output is a string-concat affair.  These
// helpers make it slightly less error-prone.
// =====================================================================
/// Wrap a string value as a JSON literal — escapes quotes and
/// backslashes, surrounds with `"` characters.
@stable(since = "1.0")
pub func encodeString(s: in String): String {
  hostEncodeString(s)
}

/// Return the raw text of a `JsonElement` as produced by
/// `JsonElement.GetRawText()`.  Useful for capturing sub-objects or
/// arrays as opaque strings.
@stable(since = "1.0")
pub func getRawText(elem: in JsonElement): String {
  hostGetRawText(elem)
}

/// Return the `JsonValueKind` ordinal of a `JsonElement`:
/// 0=Undefined, 1=Object, 2=Array, 3=String, 4=Number, 5=True, 6=False, 7=Null.
@stable(since = "1.0")
pub func valueKind(elem: in JsonElement): Int {
  hostValueKind(elem)
}

// =====================================================================
// Array enumeration — lower-level wrappers so callers can iterate
// `JsonElement` arrays without going through the slice-reader helpers.
//
// The raw BCL enumerator struct (`JsonElement+ArrayEnumerator`) is a kernel
// FFI type; exposing it directly in this public, non-kernel API leaked the FFI
// boundary into every consumer's emitted IL.  `JsonArrayCursor` wraps it in an
// opaque Lyric record so callers iterate without naming (or emitting) the BCL
// type.  Callers don't change: `var c = enumerateArray(e)` infers the cursor.
// =====================================================================
pub record JsonArrayCursor {
  var en: JsonArrayEnumerator
}

@stable(since = "1.0")
pub func enumerateArray(elem: in JsonElement): JsonArrayCursor {
  JsonArrayCursor(en = hostEnumerateArray(elem))
}

@stable(since = "1.0")
pub func arrayMoveNext(cur: inout JsonArrayCursor): Bool {
  hostEnumMoveNext(cur.en)
}

@stable(since = "1.0")
pub func arrayCurrent(cur: inout JsonArrayCursor): JsonElement {
  hostEnumCurrent(cur.en)
}

// =====================================================================
// Object enumeration — iterate `JsonElement` object properties.  Wrapped the
// same way as the array cursor above (the BCL `ObjectEnumerator` struct stays
// behind `JsonObjectCursor`).
// =====================================================================
pub record JsonObjectCursor {
  var en: JsonObjectEnumerator
}

@stable(since = "1.0")
pub func enumerateObject(elem: in JsonElement): JsonObjectCursor {
  JsonObjectCursor(en = hostEnumerateObject(elem))
}

@stable(since = "1.0")
pub func objectMoveNext(cur: inout JsonObjectCursor): Bool {
  hostEnumObjectMoveNext(cur.en)
}

@stable(since = "1.0")
pub func objectCurrent(cur: inout JsonObjectCursor): JsonProperty {
  hostEnumObjectCurrent(cur.en)
}

@stable(since = "1.0")
pub func propertyName(prop: in JsonProperty): String {
  hostPropertyName(prop)
}

@stable(since = "1.0")
pub func propertyValue(prop: in JsonProperty): JsonElement {
  hostPropertyValue(prop)
}

// =====================================================================
// fromJson scalar field readers — used by @generate(Json) synthesised stubs.
// Each re-parses the JSON string and walks to the named property. The body
// is untrusted, so every reader fails closed: malformed JSON, a non-object
// root, a missing property or a value of the wrong kind or range all return
// `false` with a default `value`, never a host exception (#7251).
// =====================================================================
func lyricJsonParseObject(s: in String): Option[JsonDoc] {
  match tryParseJson(s) {
    case Err(_) -> None
    case Ok(doc) -> {
      if hostValueKind(hostRootElement(doc)) == 1 {
        Some(value = doc)
      } else {
        hostDisposeJson(doc)
        None
      }
    }
  }
}

pub func lyricJsonGetInt(s: in String, name: in String, value: out Int): Bool {
  value = default()
  match lyricJsonParseObject(s) {
    case None -> false
    case Some(doc) -> {
      defer {
        hostDisposeJson(doc)
      }
      match tryGetProperty(hostRootElement(doc), name) {
        case None -> false
        case Some(elem) -> match tryGetInt(elem) { case Some(v) -> { value = v; true }; case None -> false }
      }
    }
  }
}

pub func lyricJsonGetLong(s: in String, name: in String, value: out Long): Bool {
  value = default()
  match lyricJsonParseObject(s) {
    case None -> false
    case Some(doc) -> {
      defer {
        hostDisposeJson(doc)
      }
      match tryGetProperty(hostRootElement(doc), name) {
        case None -> false
        case Some(elem) -> match tryGetLong(elem) { case Some(v) -> { value = v; true }; case None -> false }
      }
    }
  }
}

pub func lyricJsonGetDouble(s: in String, name: in String, value: out Double): Bool {
  value = default()
  match lyricJsonParseObject(s) {
    case None -> false
    case Some(doc) -> {
      defer {
        hostDisposeJson(doc)
      }
      match tryGetProperty(hostRootElement(doc), name) {
        case None -> false
        case Some(elem) -> match tryGetDouble(elem) { case Some(v) -> { value = v; true }; case None -> false }
      }
    }
  }
}

pub func lyricJsonGetBool(s: in String, name: in String, value: out Bool): Bool {
  value = default()
  match lyricJsonParseObject(s) {
    case None -> false
    case Some(doc) -> {
      defer {
        hostDisposeJson(doc)
      }
      match tryGetProperty(hostRootElement(doc), name) {
        case None -> false
        case Some(elem) -> {
          if isJsonBool(elem) {
            value = hostGetBoolean(elem)
            true
          } else {
            false
          }
        }
      }
    }
  }
}

pub func lyricJsonGetString(s: in String, name: in String, value: out String): Bool {
  value = default()
  match lyricJsonParseObject(s) {
    case None -> false
    case Some(doc) -> {
      defer {
        hostDisposeJson(doc)
      }
      match tryGetProperty(hostRootElement(doc), name) {
        case None -> false
        case Some(elem) -> {
          if isJsonString(elem) {
            value = hostGetString(elem)
            true
          } else {
            false
          }
        }
      }
    }
  }
}

pub func lyricJsonGetSubObject(s: in String, name: in String, value: out String): Bool {
  value = "{}"
  match lyricJsonParseObject(s) {
    case None -> false
    case Some(doc) -> {
      defer {
        hostDisposeJson(doc)
      }
      match tryGetProperty(hostRootElement(doc), name) {
        case None -> false
        case Some(elem) -> {
          if hostValueKind(elem) == 1 {
            value = hostGetRawText(elem)
            true
          } else {
            false
          }
        }
      }
    }
  }
}
