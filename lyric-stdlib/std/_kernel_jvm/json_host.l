//! std/_kernel_jvm/json_host.l — JVM backing for Std.Json.
//!
//! Mirrors `_kernel/json_host.l` function-for-function, but where the
//! .NET kernel binds `System.Text.Json`, the JVM has no JSON API in
//! `java.base` — so this file is **pure Lyric**: parsing delegates to
//! `Std.Yaml.parseJson` (the strict-JSON entry point of the pure-Lyric
//! YAML 1.2 / JSON parser, D065) and the `JsonDoc` / `JsonElement` /
//! enumerator handles are plain Lyric records over the parsed
//! `YamlValue` tree.  The previous version routed all 29 operations
//! through phantom `lyric.stdlib.jvm.JsonHost` classes that never
//! existed at runtime (same elimination as the file/console/math/uuid
//! kernel rewrites, D-progress-555) — every `Std.Json` consumer on the
//! JVM failed with NoClassDefFoundError, or worse, mis-stacked a
//! guessed `Object` return against a declared `Long` (VerifyError; hit
//! by `lyric-storage`'s sidecar reads, #1444).
//!
//! Semantics notes vs the .NET kernel:
//!   * `hostValueKind` returns the same `JsonValueKind` ordinals
//!     (0=Undefined, 1=Object, 2=Array, 3=String, 4=Number, 5=True,
//!     6=False, 7=Null) — `Std.Json` matches on these numbers.
//!   * `hostGetRawText` re-serialises the element to canonical JSON
//!     rather than returning the original input slice.  Consumers use
//!     it to capture sub-objects for later re-parsing
//!     (`lyricJsonGetSubObject`), for which an equivalent serialisation
//!     is sufficient.  String values include their quotes, matching
//!     `JsonElement.GetRawText`.
//!   * Failures follow the .NET contracts: `hostParseJson` panics on
//!     malformed input (JsonException → catchable `Bug`), `hostGet*`
//!     panic on a kind mismatch (InvalidOperationException → `Bug`),
//!     `hostTryGet*` return false.
//!   * `hostDisposeJson` is a no-op: the parsed tree is ordinary
//!     GC-managed data, not the pooled unmanaged buffer JsonDocument
//!     wraps on .NET.
//!
//! Internal: only Std.Json should import this.
package Std.JsonHost

import Std.Core
import Std.Collections
import Std.Char
import Std.Yaml

// ── Handle types ──────────────────────────────────────────────────────────────
// Plain records over the parsed tree; the names and shapes mirror the
// .NET kernel's extern types so `Std.Json` compiles unchanged.
pub record JsonDoc {
  root: JsonElement
}

pub record JsonElement {
  node: YamlValue
}

pub record JsonArrayEnumerator {
  items: List[YamlValue]
  idx: Int
}

pub record JsonObjectEnumerator {
  pairs: List[YamlPair]
  idx: Int
}

pub record JsonProperty {
  name: String
  value: JsonElement
}

// ── Parsing ───────────────────────────────────────────────────────────────────
pub func hostParseJson(s: in String): JsonDoc {
  match parseJson(s) {
    case Ok(v) -> JsonDoc(root = JsonElement(node = v))
    case Err(e) -> panic("Std.Json: parse error: " + jsonParseErrMessage(e))
  }
}

// Local mirror of `YamlError.message`: a cross-package dot-named function
// call on a match-bound payload does not yet resolve in the JVM backend's
// bundled compile, so the message text is built here.
func jsonParseErrMessage(e: in YamlError): String {
  match e {
    case UnexpectedChar(pos, expected) -> "unexpected character at position " + toString(pos) + "; expected " + expected
    case UnexpectedEof(pos, expected) -> "unexpected end of input at position " + toString(pos) + "; expected " + expected
    case InvalidNumber(pos, raw) -> "invalid number at position " + toString(pos) + ": '" + raw + "'"
    case DuplicateKey(pos, key) -> "duplicate key at position " + toString(pos) + ": '" + key + "'"
    case UnsupportedFeature(pos, feature) -> "unsupported YAML feature at position " + toString(pos) + ": " + feature
    case InvalidDocument(message) -> "invalid document: " + message
  }
}

pub func hostDisposeJson(d: in JsonDoc): Unit {
  ()
}

pub func hostRootElement(d: in JsonDoc): JsonElement {
  d.root
}

// ── Property access ───────────────────────────────────────────────────────────
pub func hostGetProperty(elem: in JsonElement, name: in String): JsonElement {
  var found: JsonElement = default()
  if hostTryGetProperty(elem, name, found) {
    found
  } else {
    panic("Std.Json: property '" + name + "' not found")
  }
}

pub func hostTryGetProperty(elem: in JsonElement, name: in String, out_: out JsonElement): Bool {
  match elem.node {
    case YMapping(pairs) -> {
      val idx = findPairIdx(pairs, name)
      if idx >= 0 {
        val hit: YamlPair = pairs[idx]
        out_ = JsonElement(node = hit.value)
        true
      } else {
        out_ = JsonElement(node = YNull)
        false
      }
    }
    case _ -> {
      out_ = JsonElement(node = YNull)
      false
    }
  }
}

// Index of the pair whose key equals `name`, or -1.  List elements are
// erased to Object on the JVM; the explicitly-annotated binding restores
// the concrete type so the `.key` field access resolves.
func findPairIdx(pairs: in List[YamlPair], name: in String): Int {
  var i = 0
  while i < pairs.count {
    val p: YamlPair = pairs[i]
    if p.key == name {
      return i
    }
    i = i + 1
  }
  0 - 1
}

// ── Leaf accessors ────────────────────────────────────────────────────────────
pub func hostGetString(elem: in JsonElement): String {
  match elem.node {
    case YString(v) -> v
    case _ -> panic("Std.Json: element is not a string")
  }
}

pub func hostGetInt32(elem: in JsonElement): Int {
  match elem.node {
    case YInt(v) -> {
      // Explicit range check (#4797): matches the .NET kernel's
      // OverflowException contract (a catchable Bug) instead of silently
      // truncating; also keeps this kernel free of Std.Parse (#4799).
      if v > 2147483647i64 or v < 0i64 - 2147483648i64 {
        panic("Std.Json: integer value out of Int32 range: " + toString(v))
      }
      v.toInt()
    }
    case _ -> panic("Std.Json: element is not an integer")
  }
}

pub func hostGetInt64(elem: in JsonElement): Long {
  match elem.node {
    case YInt(v) -> v
    case _ -> panic("Std.Json: element is not an integer")
  }
}

pub func hostGetBoolean(elem: in JsonElement): Bool {
  match elem.node {
    case YBool(v) -> v
    case _ -> panic("Std.Json: element is not a boolean")
  }
}

pub func hostGetDouble(elem: in JsonElement): Double {
  match elem.node {
    case YFloat(v) -> v
    // Distinct binding name: a Long and a Double payload sharing one local
    // slot across arms gives the slot two widths — the join's stackmap
    // frame cannot merge them (VerifyError).
    case YInt(vi) -> vi.toDouble()
    case _ -> panic("Std.Json: element is not a number")
  }
}

pub func hostTryGetInt32(elem: in JsonElement, value: out Int): Bool {
  match elem.node {
    case YInt(v) -> {
      // Out-of-range reports false (the .NET TryGetInt32 contract) rather
      // than truncating (#4797); no Std.Parse round-trip (#4799).
      if v > 2147483647i64 or v < 0i64 - 2147483648i64 {
        value = 0
        false
      } else {
        value = v.toInt()
        true
      }
    }
    case _ -> {
      value = 0
      false
    }
  }
}

pub func hostTryGetInt64(elem: in JsonElement, value: out Long): Bool {
  match elem.node {
    case YInt(v) -> {
      value = v
      true
    }
    case _ -> {
      value = 0
      false
    }
  }
}

pub func hostTryGetDouble(elem: in JsonElement, value: out Double): Bool {
  match elem.node {
    case YFloat(v) -> {
      value = v
      true
    }
    // Distinct binding name — see hostGetDouble.
    case YInt(vi) -> {
      value = vi.toDouble()
      true
    }
    case _ -> {
      value = 0.0
      false
    }
  }
}

// Re-serialise the element as canonical JSON (see the header note on the
// divergence from .NET's raw-input-slice semantics).
pub func hostGetRawText(elem: in JsonElement): String {
  writeJsonValue(elem.node)
}

// Returns the JsonValueKind ordinal of `elem`:
// 0=Undefined, 1=Object, 2=Array, 3=String, 4=Number, 5=True, 6=False, 7=Null.
pub func hostValueKind(elem: in JsonElement): Int {
  match elem.node {
    case YMapping(_) -> 1
    case YSequence(_) -> 2
    case YString(_) -> 3
    case YInt(_) -> 4
    case YFloat(_) -> 4
    case YBool(v) -> {
      if v {
        5
      } else {
        6
      }
    }
    case YNull -> 7
  }
}

// ── Array enumeration ─────────────────────────────────────────────────────────
// Mirrors JsonElement.EnumerateArray's MoveNext/Current protocol: the
// cursor starts before the first element; MoveNext advances and reports
// whether an element is available.  The enumerator records are
// re-assigned through the `inout` parameter on each advance.
pub func hostEnumerateArray(elem: in JsonElement): JsonArrayEnumerator {
  match elem.node {
    case YSequence(items) -> JsonArrayEnumerator(items = items, idx = 0 - 1)
    case _ -> panic("Std.Json: element is not an array")
  }
}

pub func hostEnumMoveNext(en: inout JsonArrayEnumerator): Bool {
  if en.idx + 1 < en.items.count {
    en = JsonArrayEnumerator(items = en.items, idx = en.idx + 1)
    true
  } else {
    false
  }
}

pub func hostEnumCurrent(en: inout JsonArrayEnumerator): JsonElement {
  val cur: YamlValue = en.items[en.idx]
  JsonElement(node = cur)
}

// ── Object enumeration ────────────────────────────────────────────────────────
pub func hostEnumerateObject(elem: in JsonElement): JsonObjectEnumerator {
  match elem.node {
    case YMapping(pairs) -> JsonObjectEnumerator(pairs = pairs, idx = 0 - 1)
    case _ -> panic("Std.Json: element is not an object")
  }
}

pub func hostEnumObjectMoveNext(en: inout JsonObjectEnumerator): Bool {
  if en.idx + 1 < en.pairs.count {
    en = JsonObjectEnumerator(pairs = en.pairs, idx = en.idx + 1)
    true
  } else {
    false
  }
}

pub func hostEnumObjectCurrent(en: inout JsonObjectEnumerator): JsonProperty {
  val pair: YamlPair = en.pairs[en.idx]
  JsonProperty(name = pair.key, value = JsonElement(node = pair.value))
}

pub func hostPropertyName(prop: in JsonProperty): String {
  prop.name
}

pub func hostPropertyValue(prop: in JsonProperty): JsonElement {
  prop.value
}

// ── Serialisation helpers ─────────────────────────────────────────────────────
// JSON-escape a string value, surrounding quotes included — equivalent to
// .NET's JsonEncodedText.Encode with the quotes added, matching the .NET
// kernel's documented contract.
pub func hostEncodeString(s: in String): String {
  var result = "\""
  var i = 0
  while i < s.length {
    val c = s[i]
    if c == '"' {
      result = result + "\\\""
    } else if c == '\\' {
      result = result + "\\\\"
    } else if c == '\n' {
      result = result + "\\n"
    } else if c == '\r' {
      result = result + "\\r"
    } else if c == '\t' {
      result = result + "\\t"
    } else if c < ' ' {
      // Remaining control characters (U+0000..U+001F) as \u00XX.
      val cp = toInt(c)
      result = result + "\\u00" + jsonHexDigit(cp / 16) + jsonHexDigit(cp % 16)
    } else {
      result = result + "" + c
    }
    i = i + 1
  }
  result + "\""
}

func jsonHexDigit(n: in Int): String {
  if n < 10 {
    toString(n)
  } else if n == 10 {
    "a"
  } else if n == 11 {
    "b"
  } else if n == 12 {
    "c"
  } else if n == 13 {
    "d"
  } else if n == 14 {
    "e"
  } else {
    "f"
  }
}

// Canonical-JSON writer for hostGetRawText.
func writeJsonValue(v: in YamlValue): String {
  match v {
    case YNull -> "null"
    case YBool(b) -> {
      if b {
        "true"
      } else {
        "false"
      }
    }
    case YInt(n) -> toString(n)
    case YFloat(f) -> toString(f)
    case YString(s) -> hostEncodeString(s)
    case YSequence(items) -> {
      var out2 = "["
      var i = 0
      while i < items.count {
        if i > 0 {
          out2 = out2 + ","
        }
        val el: YamlValue = items[i]
        out2 = out2 + writeJsonValue(el)
        i = i + 1
      }
      out2 + "]"
    }
    case YMapping(pairs) -> {
      var out3 = "{"
      var j = 0
      while j < pairs.count {
        if j > 0 {
          out3 = out3 + ","
        }
        val pj: YamlPair = pairs[j]
        out3 = out3 + hostEncodeString(pj.key) + ":" + writeJsonValue(pj.value)
        j = j + 1
      }
      out3 + "}"
    }
  }
}

// =====================================================================
// fromJson slice readers — pure-Lyric implementations identical to the
// .NET kernel (`_kernel/json_host.l`); kept here so a JVM-target build
// can link `Std.Json`'s `lyricJsonGet*Slice` calls.  See #322.
// =====================================================================
pub func lyricJsonGetIntSlice(s: in String, name: in String, value: out slice[Int]): Bool {
  val list: List[Int] = newList()
  val doc = hostParseJson(s)
  defer {
    hostDisposeJson(doc)
  }
  val root = hostRootElement(doc)
  var elem: JsonElement = default()
  if not hostTryGetProperty(root, name, elem) {
    value = list.toArray()
    return false
  }
  if hostValueKind(elem) != 2 {
    value = list.toArray()
    return false
  }
  var en: JsonArrayEnumerator = hostEnumerateArray(elem)
  while hostEnumMoveNext(en) {
    val curr = hostEnumCurrent(en)
    var v: Int = default()
    if hostTryGetInt32(curr, v) {
      list.add(v)
    }
  }
  value = list.toArray()
  return true
}

pub func lyricJsonGetLongSlice(s: in String, name: in String, value: out slice[Long]): Bool {
  val list: List[Long] = newList()
  val doc = hostParseJson(s)
  defer {
    hostDisposeJson(doc)
  }
  val root = hostRootElement(doc)
  var elem: JsonElement = default()
  if not hostTryGetProperty(root, name, elem) {
    value = list.toArray()
    return false
  }
  if hostValueKind(elem) != 2 {
    value = list.toArray()
    return false
  }
  var en: JsonArrayEnumerator = hostEnumerateArray(elem)
  while hostEnumMoveNext(en) {
    val curr = hostEnumCurrent(en)
    var v: Long = default()
    if hostTryGetInt64(curr, v) {
      list.add(v)
    }
  }
  value = list.toArray()
  return true
}

pub func lyricJsonGetDoubleSlice(s: in String, name: in String, value: out slice[Double]): Bool {
  val list: List[Double] = newList()
  val doc = hostParseJson(s)
  defer {
    hostDisposeJson(doc)
  }
  val root = hostRootElement(doc)
  var elem: JsonElement = default()
  if not hostTryGetProperty(root, name, elem) {
    value = list.toArray()
    return false
  }
  if hostValueKind(elem) != 2 {
    value = list.toArray()
    return false
  }
  var en: JsonArrayEnumerator = hostEnumerateArray(elem)
  while hostEnumMoveNext(en) {
    val curr = hostEnumCurrent(en)
    var v: Double = default()
    if hostTryGetDouble(curr, v) {
      list.add(v)
    }
  }
  value = list.toArray()
  return true
}

pub func lyricJsonGetBoolSlice(s: in String, name: in String, value: out slice[Bool]): Bool {
  val list: List[Bool] = newList()
  val doc = hostParseJson(s)
  defer {
    hostDisposeJson(doc)
  }
  val root = hostRootElement(doc)
  var elem: JsonElement = default()
  if not hostTryGetProperty(root, name, elem) {
    value = list.toArray()
    return false
  }
  if hostValueKind(elem) != 2 {
    value = list.toArray()
    return false
  }
  var en: JsonArrayEnumerator = hostEnumerateArray(elem)
  while hostEnumMoveNext(en) {
    val curr = hostEnumCurrent(en)
    val k = hostValueKind(curr)
    if k == 5 {
      list.add(true)
    } else if k == 6 {
      list.add(false)
    }
  }
  value = list.toArray()
  return true
}

pub func lyricJsonGetStringSlice(s: in String, name: in String, value: out slice[String]): Bool {
  val list: List[String] = newList()
  val doc = hostParseJson(s)
  defer {
    hostDisposeJson(doc)
  }
  val root = hostRootElement(doc)
  var elem: JsonElement = default()
  if not hostTryGetProperty(root, name, elem) {
    value = list.toArray()
    return false
  }
  if hostValueKind(elem) != 2 {
    value = list.toArray()
    return false
  }
  var en: JsonArrayEnumerator = hostEnumerateArray(elem)
  while hostEnumMoveNext(en) {
    val curr = hostEnumCurrent(en)
    if hostValueKind(curr) == 3 {
      list.add(hostGetString(curr))
    }
  }
  value = list.toArray()
  return true
}
