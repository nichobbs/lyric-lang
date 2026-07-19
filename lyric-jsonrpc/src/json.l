//! src/json.l — JsonRpc.Json: strict RFC 8259 JSON value model.
//!
//! A cross-target JSON tree with both a parser and a writer. Neither
//! existing stdlib option fits the JSON-RPC framing use case:
//!   - `Std.Json` is a read-only cursor over the BCL `JsonDocument` —
//!     .NET-only, and cannot construct or serialize a document.
//!   - `Std.Yaml.parseJson` is cross-target but deliberately lenient
//!     (YAML 1.2 is a JSON superset): a malformed-JSON frame that
//!     happens to be valid YAML would parse instead of producing the
//!     JSON-RPC `-32700` parse error a conforming peer must return.
//!     It also has no writer, and rejects duplicate object keys where
//!     this module must preserve them (last-wins).
//!
//! So this module ships its own strict RFC 8259 parser and writer, pure
//! Lyric, identical on both targets. See docs/62-jsonrpc-mcp.md §2.
//!
//! Strictness relative to `Std.Yaml.parseJson`:
//!   - Only the four RFC 8259 insignificant-whitespace characters
//!     (space, tab, LF, CR) are skipped — not general Unicode
//!     whitespace.
//!   - Numbers follow the RFC 8259 grammar exactly: no leading zeros
//!     (`01` is rejected), a `.` must be followed by at least one
//!     digit, an exponent must be followed by at least one digit.
//!   - Strings reject raw (unescaped) control characters (`< 0x20`)
//!     and lone UTF-16 surrogates in `\uXXXX` escapes (a high
//!     surrogate not immediately followed by a matching low surrogate
//!     escape, or a low surrogate with no preceding high surrogate).
//!   - Object keys must be double-quoted strings; no unquoted or
//!     single-quoted forms.
//!   - Duplicate object keys are preserved in parse order (not
//!     rejected) — `getField` and friends resolve them last-wins,
//!     matching the common `JSON.parse` convention.
@runtime_checked
package JsonRpc.Json

import Std.Core
import Std.Collections
import Std.Char
import Std.Parse
import Std.Math

// ── Data model ──────────────────────────────────────────────────────────────
@stable(since = "0.1")
pub union JsonValue {
  case JNull
  case JBool(value: Bool)
  case JInt(value: Long)
  // integral numbers, i64 range
  case JFloat(value: Double)
  // non-integral, or integral but out of i64 range, or written with an
  // exponent — matches Std.Yaml's classification convention
  case JString(value: String)
  case JArray(items: List[JsonValue])
  case JObject(fields: List[JsonField])
  // insertion-ordered; duplicate names preserved
}

@stable(since = "0.1")
pub record JsonField {
  name: String
  value: JsonValue
}

/// Default recursion depth limit for `parseValue` — see `parseValueWithDepthLimit`
/// to override it. Guards against a hostile peer stack-crashing the process
/// with a deeply nested array/object.
@stable(since = "0.1")
pub val defaultMaxDepth: Int = 128

// ── Error type ─────────────────────────────────────────────────────────────
@stable(since = "0.1")
pub union JsonParseError {
  case UnexpectedChar(pos: Int, expected: String)
  case UnexpectedEof(pos: Int, expected: String)
  case InvalidNumber(pos: Int, raw: String)
  case InvalidEscape(pos: Int, detail: String)
  case LoneSurrogate(pos: Int, code: Int)
  case DepthExceeded(pos: Int, limit: Int)
  case TrailingContent(pos: Int)
  case EmptyInput
}

@stable(since = "0.1")
pub func JsonParseError.message(e: in JsonParseError): String {
  match e {
    case UnexpectedChar(pos, expected) -> "unexpected character at position " + pos.toString() + "; expected " + expected
    case UnexpectedEof(pos, expected) -> "unexpected end of input at position " + pos.toString() + "; expected " + expected
    case InvalidNumber(pos, raw) -> "invalid number at position " + pos.toString() + ": '" + raw + "'"
    case InvalidEscape(pos, detail) -> "invalid escape sequence at position " + pos.toString() + ": " + detail
    case LoneSurrogate(pos, code) -> "lone UTF-16 surrogate \\u" + hex4(code) + " at position " + pos.toString()
    case DepthExceeded(pos, limit) -> "document too deeply nested at position " + pos.toString() + " (max depth " + limit.toString() + ")"
    case TrailingContent(pos) -> "trailing content after JSON value at position " + pos.toString()
    case EmptyInput -> "empty input"
  }
}

// ── Parser state ───────────────────────────────────────────────────────────
record JState {
  src: String
  pos: Int
  maxDepth: Int
}

// ── Low-level character utilities ─────────────────────────────────────────
func jAtEnd(st: in JState): Bool {
  st.pos >= st.src.length
}

func jEat(st: inout JState, c: in Char): Bool {
  if st.pos < st.src.length and st.src[st.pos] == c {
    st.pos = st.pos + 1
    true
  } else {
    false
  }
}

func jIsWs(c: in Char): Bool {
  c == ' ' or c == '\t' or c == '\n' or c == '\r'
}

func jSkipWs(st: inout JState): Unit {
  while st.pos < st.src.length and jIsWs(st.src[st.pos]) {
    st.pos = st.pos + 1
  }
}

func jStartsWith(st: in JState, s: in String): Bool {
  val remaining = st.src.length - st.pos
  if remaining < s.length {
    false
  } else {
    st.src.substring(st.pos, s.length) == s
  }
}

func jHexDigit(c: in Char): Int {
  if c >= '0' and c <= '9' {
    toInt(c) - toInt('0')
  } else if c >= 'a' and c <= 'f' {
    10 + toInt(c) - toInt('a')
  } else if c >= 'A' and c <= 'F' {
    10 + toInt(c) - toInt('A')
  } else {
    -1
  }
}

func hex4(n: in Int): String {
  val hexDigits = "0123456789abcdef"
  var result = ""
  var shift = 12
  while shift >= 0 {
    val d = n.shr(shift).and(15)
    result = result + "" + hexDigits[d]
    shift = shift - 4
  }
  result
}

// ── Unicode escape parsing ────────────────────────────────────────────────
// Parses exactly 4 hex digits into a raw UTF-16 code unit value (0..65535).
// Does not itself validate surrogate pairing — the caller (jParseStringBody)
// tracks pending high surrogates across escapes.
func jParseUnicode4(st: inout JState): Result[Int, JsonParseError] {
  var value = 0
  var i = 0
  while i < 4 {
    if jAtEnd(st) {
      return Err(error = UnexpectedEof(pos = st.pos, expected = "4 hex digits in \\uXXXX"))
    }
    val d = jHexDigit(st.src[st.pos])
    if d < 0 {
      return Err(error = InvalidEscape(pos = st.pos, detail = "invalid hex digit in \\uXXXX"))
    }
    value = value * 16 + d
    st.pos = st.pos + 1
    i = i + 1
  }
  Ok(value = value)
}

// ── String parsing ─────────────────────────────────────────────────────────
// Parses a double-quoted JSON string body, starting just after the opening
// '"'.  Rejects raw control characters and lone UTF-16 surrogates.
func jParseStringBody(st: inout JState): Result[String, JsonParseError] {
  var result = ""
  var pendingHigh = 0 - 1
  // -1 = no pending high surrogate awaiting its low pair
  var pendingHighPos = 0
  var ok = true
  var err: JsonParseError = EmptyInput
  var done = false
  while ok and not done {
    if jAtEnd(st) {
      ok = false
      err = UnexpectedEof(pos = st.pos, expected = "'\"' to close string")
    } else {
      val startCharPos = st.pos
      val c = st.src[st.pos]
      if c == '"' {
        if pendingHigh >= 0 {
          ok = false
          err = LoneSurrogate(pos = pendingHighPos, code = pendingHigh)
        } else {
          st.pos = st.pos + 1
          done = true
        }
      } else if c == '\\' {
        st.pos = st.pos + 1
        if jAtEnd(st) {
          ok = false
          err = UnexpectedEof(pos = st.pos, expected = "escape character")
        } else {
          val esc = st.src[st.pos]
          if esc == 'u' {
            st.pos = st.pos + 1
            match jParseUnicode4(st) {
              case Err(e) -> {
                ok = false
                err = e
              }
              case Ok(code) -> {
                if pendingHigh >= 0 {
                  if code >= 0xDC00 and code <= 0xDFFF {
                    result = result + "" + fromInt(pendingHigh) + "" + fromInt(code)
                    pendingHigh = 0 - 1
                  } else {
                    ok = false
                    err = LoneSurrogate(pos = pendingHighPos, code = pendingHigh)
                  }
                } else if code >= 0xD800 and code <= 0xDBFF {
                  pendingHigh = code
                  pendingHighPos = startCharPos
                } else if code >= 0xDC00 and code <= 0xDFFF {
                  ok = false
                  err = LoneSurrogate(pos = startCharPos, code = code)
                } else {
                  result = result + "" + fromInt(code)
                }
              }
            }
          } else if pendingHigh >= 0 {
            ok = false
            err = LoneSurrogate(pos = pendingHighPos, code = pendingHigh)
          } else {
            st.pos = st.pos + 1
            if esc == '"' {
              result = result + "\""
            } else if esc == '\\' {
              result = result + "\\"
            } else if esc == '/' {
              result = result + "/"
            } else if esc == 'n' {
              result = result + "\n"
            } else if esc == 'r' {
              result = result + "\r"
            } else if esc == 't' {
              result = result + "\t"
            } else if esc == 'b' {
              result = result + "\u{0008}"
            } else if esc == 'f' {
              result = result + "\u{000c}"
            } else {
              ok = false
              err = InvalidEscape(pos = startCharPos, detail = "\\" + ("" + esc))
            }
          }
        }
      } else if toInt(c) < 0x20 {
        ok = false
        err = UnexpectedChar(
          pos = st.pos,
          expected = "escaped control character (raw control characters are not permitted in JSON strings)"
        )
      } else if pendingHigh >= 0 {
        ok = false
        err = LoneSurrogate(pos = pendingHighPos, code = pendingHigh)
      } else {
        result = result + "" + c
        st.pos = st.pos + 1
      }
    }
  }
  if ok {
    Ok(value = result)
  } else {
    Err(error = err)
  }
}

// ── Number parsing (strict RFC 8259 grammar) ────────────────────────────────
func jParseNumber(st: inout JState): Result[JsonValue, JsonParseError] {
  val startPos = st.pos
  if st.pos < st.src.length and st.src[st.pos] == '-' {
    st.pos = st.pos + 1
  }
  if jAtEnd(st) or not (st.src[st.pos] >= '0' and st.src[st.pos] <= '9') {
    return Err(error = UnexpectedChar(pos = st.pos, expected = "digit in number"))
  }
  if st.src[st.pos] == '0' {
    st.pos = st.pos + 1
    if not jAtEnd(st) and st.src[st.pos] >= '0' and st.src[st.pos] <= '9' {
      return Err(error = InvalidNumber(pos = startPos, raw = st.src.substring(startPos, st.pos + 1 - startPos)))
    }
  } else {
    while not jAtEnd(st) and st.src[st.pos] >= '0' and st.src[st.pos] <= '9' {
      st.pos = st.pos + 1
    }
  }
  var isFloat = false
  if not jAtEnd(st) and st.src[st.pos] == '.' {
    isFloat = true
    st.pos = st.pos + 1
    if jAtEnd(st) or not (st.src[st.pos] >= '0' and st.src[st.pos] <= '9') {
      return Err(error = InvalidNumber(pos = startPos, raw = st.src.substring(startPos, st.pos - startPos)))
    }
    while not jAtEnd(st) and st.src[st.pos] >= '0' and st.src[st.pos] <= '9' {
      st.pos = st.pos + 1
    }
  }
  if not jAtEnd(st) and (st.src[st.pos] == 'e' or st.src[st.pos] == 'E') {
    isFloat = true
    st.pos = st.pos + 1
    if not jAtEnd(st) and (st.src[st.pos] == '+' or st.src[st.pos] == '-') {
      st.pos = st.pos + 1
    }
    if jAtEnd(st) or not (st.src[st.pos] >= '0' and st.src[st.pos] <= '9') {
      return Err(error = InvalidNumber(pos = startPos, raw = st.src.substring(startPos, st.pos - startPos)))
    }
    while not jAtEnd(st) and st.src[st.pos] >= '0' and st.src[st.pos] <= '9' {
      st.pos = st.pos + 1
    }
  }
  val raw = st.src.substring(startPos, st.pos - startPos)
  if isFloat {
    match parseOptDouble(raw) {
      case Some(f) -> Ok(value = JFloat(value = f))
      case None -> Err(error = InvalidNumber(pos = startPos, raw = raw))
    }
  } else {
    // Delegate to the overflow-checked parseOptLong; an integer literal beyond
    // Int64 range is preserved as a float rather than silently wrapping —
    // matches Std.Yaml's number classification convention.
    match parseOptLong(raw) {
      case Some(n) -> Ok(value = JInt(value = n))
      case None -> match parseOptDouble(raw) { case Some(f) -> Ok(value = JFloat(value = f)); case None -> Err(error = InvalidNumber(pos = startPos, raw = raw)) }
    }
  }
}

// ── Container parsing ──────────────────────────────────────────────────────
func jParseArray(st: inout JState, depth: in Int): Result[JsonValue, JsonParseError] {
  if depth > st.maxDepth {
    return Err(error = DepthExceeded(pos = st.pos, limit = st.maxDepth))
  }
  val items: List[JsonValue] = newList()
  jSkipWs(st)
  if jEat(st, ']') {
    return Ok(value = JArray(items = items))
  }
  var ok = true
  var err: JsonParseError = EmptyInput
  var done = false
  while ok and not done {
    match jParseValue(st, depth + 1) {
      case Err(e) -> {
        ok = false
        err = e
      }
      case Ok(v) -> {
        items.add(v)
        jSkipWs(st)
        if jEat(st, ']') {
          done = true
        } else if not jEat(st, ',') {
          ok = false
          err = UnexpectedChar(pos = st.pos, expected = "',' or ']' in array")
        } else {
          jSkipWs(st)
        }
      }
    }
  }
  if ok {
    Ok(value = JArray(items = items))
  } else {
    Err(error = err)
  }
}

func jParseObject(st: inout JState, depth: in Int): Result[JsonValue, JsonParseError] {
  if depth > st.maxDepth {
    return Err(error = DepthExceeded(pos = st.pos, limit = st.maxDepth))
  }
  val fields: List[JsonField] = newList()
  jSkipWs(st)
  if jEat(st, '}') {
    return Ok(value = JObject(fields = fields))
  }
  var ok = true
  var err: JsonParseError = EmptyInput
  var done = false
  while ok and not done {
    jSkipWs(st)
    if jAtEnd(st) or st.src[st.pos] != '"' {
      ok = false
      err = UnexpectedChar(pos = st.pos, expected = "'\"' to start object key")
    } else {
      st.pos = st.pos + 1
      match jParseStringBody(st) {
        case Err(e) -> {
          ok = false
          err = e
        }
        case Ok(key) -> {
          jSkipWs(st)
          if not jEat(st, ':') {
            ok = false
            err = UnexpectedChar(pos = st.pos, expected = "':' after object key")
          } else {
            jSkipWs(st)
            match jParseValue(st, depth + 1) {
              case Err(e) -> {
                ok = false
                err = e
              }
              case Ok(v) -> {
                fields.add(JsonField(name = key, value = v))
                jSkipWs(st)
                if jEat(st, '}') {
                  done = true
                } else if not jEat(st, ',') {
                  ok = false
                  err = UnexpectedChar(pos = st.pos, expected = "',' or '}' in object")
                } else {
                  jSkipWs(st)
                }
              }
            }
          }
        }
      }
    }
  }
  if ok {
    Ok(value = JObject(fields = fields))
  } else {
    Err(error = err)
  }
}

func jParseValue(st: inout JState, depth: in Int): Result[JsonValue, JsonParseError] {
  if depth > st.maxDepth {
    return Err(error = DepthExceeded(pos = st.pos, limit = st.maxDepth))
  }
  jSkipWs(st)
  if jAtEnd(st) {
    return Err(error = UnexpectedEof(pos = st.pos, expected = "a value"))
  }
  val c = st.src[st.pos]
  if c == '"' {
    st.pos = st.pos + 1
    match jParseStringBody(st) {
      case Err(e) -> Err(error = e)
      case Ok(s) -> Ok(value = JString(value = s))
    }
  } else if c == '[' {
    st.pos = st.pos + 1
    jParseArray(st, depth + 1)
  } else if c == '{' {
    st.pos = st.pos + 1
    jParseObject(st, depth + 1)
  } else if c == 'n' and jStartsWith(st, "null") {
    st.pos = st.pos + 4
    Ok(value = JNull)
  } else if c == 't' and jStartsWith(st, "true") {
    st.pos = st.pos + 4
    Ok(value = JBool(value = true))
  } else if c == 'f' and jStartsWith(st, "false") {
    st.pos = st.pos + 5
    Ok(value = JBool(value = false))
  } else if c == '-' or (c >= '0' and c <= '9') {
    jParseNumber(st)
  } else {
    Err(error = UnexpectedChar(pos = st.pos, expected = "a JSON value"))
  }
}

// ── Public parse API ───────────────────────────────────────────────────────
/// Parse a strict RFC 8259 JSON document, with the default recursion depth
/// limit (`defaultMaxDepth`, 128).
@stable(since = "0.1")
pub func parseValue(src: in String): Result[JsonValue, JsonParseError] {
  parseValueWithDepthLimit(src, defaultMaxDepth)
}

/// As `parseValue`, with an explicit maximum array/object nesting depth.
@stable(since = "0.1")
pub func parseValueWithDepthLimit(src: in String, maxDepth: in Int): Result[JsonValue, JsonParseError] {
  var st = JState(src = src, pos = 0, maxDepth = maxDepth)
  jSkipWs(st)
  if jAtEnd(st) {
    return Err(error = EmptyInput)
  }
  match jParseValue(st, 0) {
    case Err(e) -> Err(error = e)
    case Ok(v) -> {
      jSkipWs(st)
      if not jAtEnd(st) {
        Err(error = TrailingContent(pos = st.pos))
      } else {
        Ok(value = v)
      }
    }
  }
}

// ── Writer ──────────────────────────────────────────────────────────────────
func writeJsonString(s: in String): String {
  var result = "\""
  var i = 0
  while i < s.length {
    val c = s[i]
    val code = toInt(c)
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
    } else if code == 0x08 {
      result = result + "\\b"
    } else if code == 0x0c {
      result = result + "\\f"
    } else if code < 0x20 {
      result = result + "\\u" + hex4(code)
    } else {
      result = result + "" + c
    }
    i = i + 1
  }
  result + "\""
}

func writeDouble(f: in Double): String {
  if isNaN(f) or isInfinity(f) {
    panic(
      "JsonRpc.Json.writeValue: cannot represent a NaN or Infinity Double as a JSON number (RFC 8259 has no such literal)"
    )
  }
  f.toString()
}

func writeArrayItems(items: in List[JsonValue]): String {
  var result = "["
  var i = 0
  while i < items.count {
    if i > 0 {
      result = result + ","
    }
    result = result + writeValue(items[i])
    i = i + 1
  }
  result + "]"
}

func writeObjectFields(fields: in List[JsonField]): String {
  var result = "{"
  var i = 0
  while i < fields.count {
    if i > 0 {
      result = result + ","
    }
    result = result + writeJsonString(fields[i].name) + ":" + writeValue(fields[i].value)
    i = i + 1
  }
  result + "}"
}

/// Serialize a `JsonValue` to compact JSON text (no insignificant
/// whitespace, no trailing newline). Object field insertion order is
/// preserved.
@stable(since = "0.1")
pub func writeValue(v: in JsonValue): String {
  match v {
    case JNull -> "null"
    case JBool(b) -> if b { "true" } else { "false" }
    case JInt(n) -> n.toString()
    case JFloat(f) -> writeDouble(f)
    case JString(s) -> writeJsonString(s)
    case JArray(items) -> writeArrayItems(items)
    case JObject(fields) -> writeObjectFields(fields)
  }
}

// ── Query helpers ───────────────────────────────────────────────────────────
/// True if the value is `JNull`.
@stable(since = "0.1")
pub func isNull(v: in JsonValue): Bool {
  match v {
    case JNull -> true
    case _ -> false
  }
}

/// Extract a boolean value, or `None`.
@stable(since = "0.1")
pub func asBool(v: in JsonValue): Option[Bool] {
  match v {
    case JBool(b) -> Some(value = b)
    case _ -> None
  }
}

/// Extract an integral value, or `None`.
@stable(since = "0.1")
pub func asInt(v: in JsonValue): Option[Long] {
  match v {
    case JInt(n) -> Some(value = n)
    case _ -> None
  }
}

/// Extract a float value, or `None`. Does not coerce `JInt` — see the module
/// doc comment on the `JInt`/`JFloat` classification convention.
@stable(since = "0.1")
pub func asFloat(v: in JsonValue): Option[Double] {
  match v {
    case JFloat(f) -> Some(value = f)
    case _ -> None
  }
}

/// Extract a string value, or `None`.
@stable(since = "0.1")
pub func asString(v: in JsonValue): Option[String] {
  match v {
    case JString(s) -> Some(value = s)
    case _ -> None
  }
}

/// Extract an array's items, or `None`.
@stable(since = "0.1")
pub func asArray(v: in JsonValue): Option[List[JsonValue]] {
  match v {
    case JArray(items) -> Some(value = items)
    case _ -> None
  }
}

/// Extract an object's fields, or `None`.
@stable(since = "0.1")
pub func asObject(v: in JsonValue): Option[List[JsonField]] {
  match v {
    case JObject(fields) -> Some(value = fields)
    case _ -> None
  }
}

/// Look up a key in an object, or `None` if `v` is not an object or the key
/// is absent. When the key appears more than once, the *last* occurrence
/// wins (matches the common `JSON.parse` convention) — `parseValue` itself
/// never rejects or collapses duplicate keys.
@stable(since = "0.1")
pub func getField(v: in JsonValue, key: in String): Option[JsonValue] {
  match asObject(v) {
    case None -> None
    case Some(fields) -> {
      var i = 0
      var found: Option[JsonValue] = None
      while i < fields.count {
        if fields[i].name == key {
          found = Some(value = fields[i].value)
        }
        i = i + 1
      }
      found
    }
  }
}

/// Return the string at the given key in an object, or `None`.
@stable(since = "0.1")
pub func getString(v: in JsonValue, key: in String): Option[String] {
  match getField(v, key) {
    case None -> None
    case Some(f) -> asString(f)
  }
}

/// Return the integral value at the given key in an object, or `None`.
@stable(since = "0.1")
pub func getInt(v: in JsonValue, key: in String): Option[Long] {
  match getField(v, key) {
    case None -> None
    case Some(f) -> asInt(f)
  }
}

/// Return the boolean at the given key in an object, or `None`.
@stable(since = "0.1")
pub func getBool(v: in JsonValue, key: in String): Option[Bool] {
  match getField(v, key) {
    case None -> None
    case Some(f) -> asBool(f)
  }
}

/// Return the float at the given key in an object, or `None`.
@stable(since = "0.1")
pub func getFloat(v: in JsonValue, key: in String): Option[Double] {
  match getField(v, key) {
    case None -> None
    case Some(f) -> asFloat(f)
  }
}

/// Return the array items at the given key in an object, or `None`.
@stable(since = "0.1")
pub func getArray(v: in JsonValue, key: in String): Option[List[JsonValue]] {
  match getField(v, key) {
    case None -> None
    case Some(f) -> asArray(f)
  }
}

/// Return the object fields at the given key in an object, or `None`.
@stable(since = "0.1")
pub func getObject(v: in JsonValue, key: in String): Option[List[JsonField]] {
  match getField(v, key) {
    case None -> None
    case Some(f) -> asObject(f)
  }
}
