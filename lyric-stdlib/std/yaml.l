//! std/yaml.l — Pure-Lyric YAML 1.2 / JSON parser.
//!
//! Parses a string containing JSON or YAML and returns a value tree.
//! YAML is a superset of JSON (YAML 1.2 §1.2 "JSON is YAML"), so the
//! same data model and parser handle both.
//!
//! Supported:
//!   JSON mode  — full JSON: objects, arrays, strings (with \uXXXX),
//!                numbers, booleans, null.
//!   YAML mode  — JSON flow style + YAML block mappings and sequences,
//!                unquoted / single-quoted / double-quoted scalars, and
//!                the YAML 1.2 null/bool literals (~, null, true, false).
//!                Multi-document, anchors/aliases are not yet supported;
//!                they return UnsupportedFeature.
//!
//! Cross-platform: no BCL/JVM externs. Works on both MSIL and JVM
//! targets without any kernel bridge.
@runtime_checked
package Std.Yaml

import Std.Core
import Std.Collections
import Std.String
import Std.Char
import Std.Parse

// ── Error type ─────────────────────────────────────────────────────────────────
pub union YamlError {
  case UnexpectedChar(pos: Int, expected: String)
  case UnexpectedEof(pos: Int, expected: String)
  case InvalidNumber(pos: Int, raw: String)
  case DuplicateKey(pos: Int, key: String)
  case UnsupportedFeature(pos: Int, feature: String)
  case InvalidDocument(message: String)
}

pub func YamlError.message(e: in YamlError): String {
  match e {
    case UnexpectedChar(pos, expected) -> "unexpected character at position " + toString(pos) + "; expected " + expected
    case UnexpectedEof(pos, expected) -> "unexpected end of input at position " + toString(pos) + "; expected " + expected
    case InvalidNumber(pos, raw) -> "invalid number at position " + toString(pos) + ": '" + raw + "'"
    case DuplicateKey(pos, key) -> "duplicate key at position " + toString(pos) + ": '" + key + "'"
    case UnsupportedFeature(pos, feature) -> "unsupported YAML feature at position " + toString(pos) + ": " + feature
    case InvalidDocument(message) -> "invalid document: " + message
  }
}

// ── Data model ─────────────────────────────────────────────────────────────────
pub record YamlPair {
  key: String
  value: YamlValue
}

pub union YamlValue {
  case YNull
  case YBool(value: Bool)
  case YInt(value: Long)
  case YFloat(value: Double)
  case YString(value: String)
  case YSequence(items: List[YamlValue])
  case YMapping(pairs: List[YamlPair])
}

// ── Parser state ───────────────────────────────────────────────────────────────
record YamlState {
  src: String
  pos: Int
  isJson: Bool
}

// ── Low-level character utilities ──────────────────────────────────────────────
func yAtEnd(st: in YamlState): Bool {
  st.pos >= st.src.length
}

func yPeek(st: in YamlState): Option[Char] {
  if st.pos < st.src.length {
    Some(value = st.src[st.pos])
  } else {
    None
  }
}

func yPeekAt(st: in YamlState, offset: in Int): Option[Char] {
  val i = st.pos + offset
  if i >= 0 and i < st.src.length {
    Some(value = st.src[i])
  } else {
    None
  }
}

func yEat(st: inout YamlState, c: in Char): Bool {
  if st.pos < st.src.length and st.src[st.pos] == c {
    st.pos = st.pos + 1
    true
  } else {
    false
  }
}

func ySkipWs(st: inout YamlState): Unit {
  while st.pos < st.src.length and isWhiteSpace(st.src[st.pos]) {
    st.pos = st.pos + 1
  }
}

func yStartsWith(st: in YamlState, s: in String): Bool {
  val remaining = st.src.length - st.pos
  if remaining < s.length {
    false
  } else {
    st.src.substring(st.pos, s.length) == s
  }
}

func yEatStr(st: inout YamlState, s: in String): Bool {
  if yStartsWith(st, s) {
    st.pos = st.pos + s.length
    true
  } else {
    false
  }
}

// ── Inline whitespace skip (correct approach, no sentinel) ─────────────────────
func ySkipSpaces(st: inout YamlState): Unit {
  var scanning = true
  while scanning and st.pos < st.src.length {
    val c = st.src[st.pos]
    if c == ' ' or c == '\t' {
      st.pos = st.pos + 1
    } else {
      scanning = false
    }
  }
}

// Count the column indent of the current line (0-based leading space count).
func yCurrentIndent(st: in YamlState): Int {
  var lineStart = st.pos
  while lineStart > 0 and st.src[lineStart - 1] != '\n' {
    lineStart -= 1
  }
  var indent = 0
  while lineStart + indent < st.pos and st.src[lineStart + indent] == ' ' {
    indent += 1
  }
  indent
}

// Skip any lines that are empty or YAML comments (#…) up to the next
// content line.  Leave pos at the start of the first content character.
func ySkipBlankAndComment(st: inout YamlState): Unit {
  var scanning = true
  while scanning and st.pos < st.src.length {
    ySkipSpaces(st)
    if st.pos < st.src.length and st.src[st.pos] == '#' {
      while st.pos < st.src.length and st.src[st.pos] != '\n' {
        st.pos = st.pos + 1
      }
    } else if st.pos < st.src.length and st.src[st.pos] == '\n' {
      st.pos = st.pos + 1
    } else {
      scanning = false
    }
  }
}

// ── JSON string parsing ────────────────────────────────────────────────────────
func yParseHexDigit(c: in Char): Int {
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

func yParseUnicode4(st: inout YamlState): Result[Char, YamlError] {
  var value = 0
  var hex1 = 0
  var hex2 = 0
  var hex3 = 0
  var hex4 = 0

  if yAtEnd(st) {
    return Err(error = UnexpectedEof(pos = st.pos, expected = "4 hex digits in \\uXXXX"))
  }
  hex1 = yParseHexDigit(st.src[st.pos])
  if hex1 < 0 {
    return Err(error = UnexpectedChar(pos = st.pos, expected = "hex digit in \\uXXXX"))
  }
  st.pos = st.pos + 1

  if yAtEnd(st) {
    return Err(error = UnexpectedEof(pos = st.pos, expected = "4 hex digits in \\uXXXX"))
  }
  hex2 = yParseHexDigit(st.src[st.pos])
  if hex2 < 0 {
    return Err(error = UnexpectedChar(pos = st.pos, expected = "hex digit in \\uXXXX"))
  }
  st.pos = st.pos + 1

  if yAtEnd(st) {
    return Err(error = UnexpectedEof(pos = st.pos, expected = "4 hex digits in \\uXXXX"))
  }
  hex3 = yParseHexDigit(st.src[st.pos])
  if hex3 < 0 {
    return Err(error = UnexpectedChar(pos = st.pos, expected = "hex digit in \\uXXXX"))
  }
  st.pos = st.pos + 1

  if yAtEnd(st) {
    return Err(error = UnexpectedEof(pos = st.pos, expected = "4 hex digits in \\uXXXX"))
  }
  hex4 = yParseHexDigit(st.src[st.pos])
  if hex4 < 0 {
    return Err(error = UnexpectedChar(pos = st.pos, expected = "hex digit in \\uXXXX"))
  }
  st.pos = st.pos + 1

  value = hex1 * 4096 + hex2 * 256 + hex3 * 16 + hex4
  Ok(value = fromInt(value))
}

// Parse a JSON/YAML double-quoted string (starting just after the opening '"').
func yParseDoubleQuoted(st: inout YamlState): Result[String, YamlError] {
  var result = ""
  var ok = true
  var err: YamlError = InvalidDocument(message = "")
  var done = false
  while ok and not done and not yAtEnd(st) {
    val c = st.src[st.pos]
    if c == '"' {
      st.pos = st.pos + 1
      done = true
    } else if c == '\\' {
      st.pos = st.pos + 1
      if yAtEnd(st) {
        ok = false
        err = UnexpectedEof(pos = st.pos, expected = "escape character")
      } else {
        val esc = st.src[st.pos]
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
        } else if esc == 'u' {
          match yParseUnicode4(st) {
            case Err(e) -> {
              ok = false
              err = e
            }
            case Ok(ch) -> {
              result = result + "" + ch
            }
          }
        } else {
          ok = false
          err = UnexpectedChar(pos = st.pos - 1, expected = "valid escape character")
        }
      }
    } else {
      result = result + "" + c
      st.pos = st.pos + 1
    }
  }
  if not done and ok {
    ok = false
    err = UnexpectedEof(pos = st.pos, expected = "'\"' to close string")
  }
  if ok {
    Ok(value = result)
  } else {
    Err(error = err)
  }
}

// Parse a YAML single-quoted string (starting just after the opening "'").
// No escape sequences except '' → '.
func yParseSingleQuoted(st: inout YamlState): Result[String, YamlError] {
  var result = ""
  var done = false
  while not done and not yAtEnd(st) {
    val c = st.src[st.pos]
    if c == '\'' {
      st.pos = st.pos + 1
      if st.pos < st.src.length and st.src[st.pos] == '\'' {
        result = result + "'"
        st.pos = st.pos + 1
      } else {
        done = true
      }
    } else {
      result = result + "" + c
      st.pos = st.pos + 1
    }
  }
  if done {
    Ok(value = result)
  } else {
    Err(error = UnexpectedEof(pos = st.pos, expected = "' to close single-quoted string"))
  }
}

// ── YAML scalar classification ──────────────────────────────────────────────────
// Returns true for characters that can start/continue an unquoted scalar.
func yIsScalarChar(c: in Char): Bool {
  not (c == ':' or c == '#' or c == '[' or c == ']' or c == '{' or c == '}' or c == ',' or c == '\n' or c == '\r')
}

// Interpret a raw unquoted string as a YAML 1.2 scalar value.
// Only `true`/`false` (case-insensitive) are booleans — YAML 1.1
// aliases `yes/no/on/off` are not recognised per YAML 1.2 §10.3.2.
func yInterpretScalar(raw: in String): YamlValue {
  val t = raw.trim()
  if t == "null" or t == "~" or t == "" {
    YNull
  } else if t == "true" or t == "True" or t == "TRUE" {
    YBool(value = true)
  } else if t == "false" or t == "False" or t == "FALSE" {
    YBool(value = false)
  } else {
    // Try integer parse (simple: optional '-', then digits)
    val start = if t.length > 0 and t[0] == '-' { 1 } else { 0 }
    var allDigits = t.length > start
    var di = start
    while di < t.length and allDigits {
      if not isDigit(t[di]) {
        allDigits = false
      }
      di += 1
    }
    if allDigits and t.length > start {
      // Parse as Long
      var value = 0i64
      var neg = t[0] == '-'
      var ii = start
      while ii < t.length {
        val d = toInt(t[ii]) - toInt('0')
        value = value * 10i64 + d.toLong()
        ii += 1
      }
      if neg {
        YInt(value = 0i64 - value)
      } else {
        YInt(value = value)
      }
    } else {
      match parseOptDouble(t) {
        case Some(f) -> YFloat(value = f)
        case None -> YString(value = t)
      }
    }
  }
}

// ── Number parsing (JSON-style) ────────────────────────────────────────────────
func yParseNumber(st: inout YamlState): Result[YamlValue, YamlError] {
  val startPos = st.pos
  if st.pos < st.src.length and st.src[st.pos] == '-' {
    st.pos = st.pos + 1
  }
  if yAtEnd(st) or not isDigit(st.src[st.pos]) {
    return Err(error = UnexpectedChar(pos = st.pos, expected = "digit in number"))
  }
  while st.pos < st.src.length and isDigit(st.src[st.pos]) {
    st.pos = st.pos + 1
  }
  var isFloat = false
  if st.pos < st.src.length and st.src[st.pos] == '.' {
    isFloat = true
    st.pos = st.pos + 1
    while st.pos < st.src.length and isDigit(st.src[st.pos]) {
      st.pos = st.pos + 1
    }
  }
  if st.pos < st.src.length and (st.src[st.pos] == 'e' or st.src[st.pos] == 'E') {
    isFloat = true
    st.pos = st.pos + 1
    if st.pos < st.src.length and (st.src[st.pos] == '+' or st.src[st.pos] == '-') {
      st.pos = st.pos + 1
    }
    while st.pos < st.src.length and isDigit(st.src[st.pos]) {
      st.pos = st.pos + 1
    }
  }
  val raw = st.src.substring(startPos, st.pos - startPos)
  if isFloat {
    match parseOptDouble(raw) {
      case Some(f) -> Ok(value = YFloat(value = f))
      case None -> Err(error = InvalidNumber(pos = startPos, raw = raw))
    }
  } else {
    // Parse integer
    var neg = raw[0] == '-'
    var ii = if neg { 1 } else { 0 }
    var value = 0i64
    while ii < raw.length {
      val d = toInt(raw[ii]) - toInt('0')
      value = value * 10i64 + d.toLong()
      ii += 1
    }
    if neg {
      Ok(value = YInt(value = 0i64 - value))
    } else {
      Ok(value = YInt(value = value))
    }
  }
}

// ── JSON flow value parsing ────────────────────────────────────────────────────
func yParseArray(st: inout YamlState, depth: in Int): Result[YamlValue, YamlError] {
  if depth > 1024 {
    return Err(error = InvalidDocument(message = "document too deeply nested (max depth 1024)"))
  }
  // Called after consuming '['
  val items: List[YamlValue] = newList()
  ySkipWs(st)
  if yEat(st, ']') {
    return Ok(value = YSequence(items = items))
  }
  var ok = true
  var err: YamlError = InvalidDocument(message = "")
  var done = false
  while ok and not done {
    match yParseValue(st, depth + 1) {
      case Err(e) -> {
        ok = false
        err = e
      }
      case Ok(v) -> {
        items.add(v)
        ySkipWs(st)
        if yEat(st, ']') {
          done = true
        } else if not yEat(st, ',') {
          ok = false
          err = UnexpectedChar(pos = st.pos, expected = "',' or ']' in array")
        } else {
          ySkipWs(st)
        }
      }
    }
  }
  if ok {
    Ok(value = YSequence(items = items))
  } else {
    Err(error = err)
  }
}

func yParseObject(st: inout YamlState, depth: in Int): Result[YamlValue, YamlError] {
  if depth > 1024 {
    return Err(error = InvalidDocument(message = "document too deeply nested (max depth 1024)"))
  }
  // Called after consuming '{'
  val pairs: List[YamlPair] = newList()
  // O(N²) for N keys: List.contains is O(N). Replace with Set when available.
  val seenKeys: List[String] = newList()
  ySkipWs(st)
  if yEat(st, '}') {
    return Ok(value = YMapping(pairs = pairs))
  }
  var ok = true
  var err: YamlError = InvalidDocument(message = "")
  var done = false
  while ok and not done {
    ySkipWs(st)
    val keyStartPos = st.pos
    // Key: JSON requires quoted string; YAML flow allows unquoted.
    var keyResult: Result[String, YamlError] = Err(error = InvalidDocument(message = "no key"))
    if st.pos < st.src.length and st.src[st.pos] == '"' {
      st.pos = st.pos + 1
      keyResult = yParseDoubleQuoted(st)
    } else if not st.isJson and st.pos < st.src.length and st.src[st.pos] == '\'' {
      st.pos = st.pos + 1
      match yParseSingleQuoted(st) {
        case Err(e) -> {
          keyResult = Err(error = e)
        }
        case Ok(s) -> {
          keyResult = Ok(value = s)
        }
      }
    } else if not st.isJson {
      // Unquoted flow key: collect until ':' or '}'
      val kStart = st.pos
      var scanning = true
      while scanning and st.pos < st.src.length {
        val c = st.src[st.pos]
        if c == ':' or c == '}' or c == '\n' {
          scanning = false
        } else {
          st.pos = st.pos + 1
        }
      }
      val kRaw = st.src.substring(kStart, st.pos - kStart).trim()
      keyResult = Ok(value = kRaw)
    } else {
      ok = false
      err = UnexpectedChar(pos = st.pos, expected = "quoted string key")
    }
    if ok {
      match keyResult {
        case Err(e) -> {
          ok = false
          err = e
        }
        case Ok(key) -> {
          ySkipWs(st)
          if not yEat(st, ':') {
            ok = false
            err = UnexpectedChar(pos = st.pos, expected = "':' after object key")
          } else {
            ySkipWs(st)
            match yParseValue(st, depth + 1) {
              case Err(e) -> {
                ok = false
                err = e
              }
              case Ok(v) -> {
                if seenKeys.contains(key) {
                  ok = false
                  err = DuplicateKey(pos = keyStartPos, key = key)
                } else {
                  seenKeys.add(key)
                  pairs.add(YamlPair(key = key, value = v))
                  ySkipWs(st)
                  if yEat(st, '}') {
                    done = true
                  } else if not yEat(st, ',') {
                    ok = false
                    err = UnexpectedChar(pos = st.pos, expected = "',' or '}' in object")
                  } else {
                    ySkipWs(st)
                  }
                }
              }
            }
          }
        }
      }
    }
  }
  if ok {
    Ok(value = YMapping(pairs = pairs))
  } else {
    Err(error = err)
  }
}

func yParseValue(st: inout YamlState, depth: in Int): Result[YamlValue, YamlError] {
  if depth > 1024 {
    return Err(error = InvalidDocument(message = "document too deeply nested (max depth 1024)"))
  }
  ySkipWs(st)
  if yAtEnd(st) {
    return Err(error = UnexpectedEof(pos = st.pos, expected = "a value"))
  }
  if not st.isJson {
    match yCheckUnsupported(st) {
      case Some(e) -> return Err(error = e)
      case None -> ()
    }
  }
  val c = st.src[st.pos]
  if c == '"' {
    st.pos = st.pos + 1
    match yParseDoubleQuoted(st) {
      case Err(e) -> Err(error = e)
      case Ok(s) -> Ok(value = YString(value = s))
    }
  } else if c == '\'' and not st.isJson {
    st.pos = st.pos + 1
    match yParseSingleQuoted(st) {
      case Err(e) -> Err(error = e)
      case Ok(s) -> Ok(value = YString(value = s))
    }
  } else if c == '[' {
    st.pos = st.pos + 1
    yParseArray(st, depth + 1)
  } else if c == '{' {
    st.pos = st.pos + 1
    yParseObject(st, depth + 1)
  } else if c == 'n' and yStartsWith(st, "null") {
    st.pos = st.pos + 4
    Ok(value = YNull)
  } else if c == 't' and yStartsWith(st, "true") {
    st.pos = st.pos + 4
    Ok(value = YBool(value = true))
  } else if c == 'f' and yStartsWith(st, "false") {
    st.pos = st.pos + 5
    Ok(value = YBool(value = false))
  } else if (c >= '0' and c <= '9') or c == '-' {
    yParseNumber(st)
  } else if not st.isJson {
    // YAML unquoted scalar
    val scalarStart = st.pos
    var scanning = true
    while scanning and st.pos < st.src.length {
      val sc = st.src[st.pos]
      if sc == '\n' or sc == '\r' or sc == ',' or sc == ']' or sc == '}' or sc == '#' {
        scanning = false
      } else {
        st.pos = st.pos + 1
      }
    }
    val raw = st.src.substring(scalarStart, st.pos - scalarStart)
    Ok(value = yInterpretScalar(raw))
  } else {
    Err(error = UnexpectedChar(pos = st.pos, expected = "a JSON value"))
  }
}

// ── YAML block parsing ─────────────────────────────────────────────────────────
// Parse the indented content after a block sequence or mapping key.
func yParseBlockSequence(st: inout YamlState, seqIndent: in Int, depth: in Int): Result[YamlValue, YamlError] {
  if depth > 1024 {
    return Err(error = InvalidDocument(message = "document too deeply nested (max depth 1024)"))
  }
  val items: List[YamlValue] = newList()
  var ok = true
  var err: YamlError = InvalidDocument(message = "")
  var done = false
  while ok and not done {
    ySkipBlankAndComment(st)
    if yAtEnd(st) {
      done = true
    } else {
      val indent = yCurrentIndent(st)
      if indent < seqIndent {
        done = true
      } else if indent == seqIndent and (yStartsWith(st, "- ") or yStartsWith(st, "-\n") or (yAtEnd(st) == false and st.src[st.pos] == '-' and st.pos + 1 >= st.src.length)) {
        st.pos = st.pos + 1  // consume "-"
        if st.pos < st.src.length and st.src[st.pos] == ' ' {
          st.pos = st.pos + 1  // consume the space
        }
        // Inline content on the same line, or block content on next line(s)
        if yAtEnd(st) or st.src[st.pos] == '\n' or st.src[st.pos] == '\r' {
          match yParseBlockNode(st, seqIndent + 1, depth + 1) {
            case Err(e) -> {
              ok = false
              err = e
            }
            case Ok(v) -> {
              items.add(v)
            }
          }
        } else {
          // Inline value (scalar or flow collection on the same line)
          match yParseValue(st, depth + 1) {
            case Err(e) -> {
              ok = false
              err = e
            }
            case Ok(v) -> {
              items.add(v)
              // Skip the rest of the line
              while st.pos < st.src.length and st.src[st.pos] != '\n' and st.src[st.pos] != '\r' {
                st.pos = st.pos + 1
              }
            }
          }
        }
      } else {
        done = true
      }
    }
  }
  if ok {
    Ok(value = YSequence(items = items))
  } else {
    Err(error = err)
  }
}

func yParseBlockMapping(st: inout YamlState, mapIndent: in Int, depth: in Int): Result[YamlValue, YamlError] {
  if depth > 1024 {
    return Err(error = InvalidDocument(message = "document too deeply nested (max depth 1024)"))
  }
  val pairs: List[YamlPair] = newList()
  // O(N²) for N keys: List.contains is O(N). Replace with Set when available.
  val seenKeys: List[String] = newList()
  var ok = true
  var err: YamlError = InvalidDocument(message = "")
  var done = false
  while ok and not done {
    ySkipBlankAndComment(st)
    if yAtEnd(st) {
      done = true
    } else {
      val indent = yCurrentIndent(st)
      if indent < mapIndent {
        done = true
      } else if indent == mapIndent {
        // Parse key: value
        val keyStart = st.pos
        var colonFound = false
        var scanning = true
        while scanning and st.pos < st.src.length {
          val kc = st.src[st.pos]
          if kc == ':' and (st.pos + 1 >= st.src.length or st.src[st.pos + 1] == ' ' or st.src[st.pos + 1] == '\n') {
            colonFound = true
            scanning = false
          } else if kc == '\n' {
            scanning = false
          } else {
            st.pos = st.pos + 1
          }
        }
        if not colonFound {
          done = true
        } else {
          val rawKey = st.src.substring(keyStart, st.pos - keyStart).trim()
          if seenKeys.contains(rawKey) {
            ok = false
            err = DuplicateKey(pos = st.pos, key = rawKey)
          } else {
            seenKeys.add(rawKey)
            st.pos = st.pos + 1  // consume ':'
            ySkipSpaces(st)
            if st.pos < st.src.length and st.src[st.pos] == '\n' {
              // Block value on next line(s)
              match yParseBlockNode(st, mapIndent + 1, depth + 1) {
                case Err(e) -> {
                  ok = false
                  err = e
                }
                case Ok(v) -> {
                  pairs.add(YamlPair(key = rawKey, value = v))
                }
              }
            } else {
              // Inline value
              match yParseValue(st, depth + 1) {
                case Err(e) -> {
                  ok = false
                  err = e
                }
                case Ok(v) -> {
                  pairs.add(YamlPair(key = rawKey, value = v))
                  // Skip to end of line
                  while st.pos < st.src.length and st.src[st.pos] != '\n' {
                    st.pos = st.pos + 1
                  }
                }
              }
            }
          }
        }
      } else {
        done = true
      }
    }
  }
  if ok {
    Ok(value = YMapping(pairs = pairs))
  } else {
    Err(error = err)
  }
}

func yParseBlockNode(st: inout YamlState, minIndent: in Int, depth: in Int): Result[YamlValue, YamlError] {
  if depth > 1024 {
    return Err(error = InvalidDocument(message = "document too deeply nested (max depth 1024)"))
  }
  ySkipBlankAndComment(st)
  if yAtEnd(st) {
    return Ok(value = YNull)
  }
  val indent = yCurrentIndent(st)
  if indent < minIndent {
    return Ok(value = YNull)
  }
  match yCheckUnsupported(st) {
    case Some(e) -> return Err(error = e)
    case None -> ()
  }
  val c = st.src[st.pos]
  // Flow nodes inline
  if c == '[' or c == '{' or c == '"' or c == '\'' {
    yParseValue(st, depth + 1)
  } else if yStartsWith(st, "- ") or yStartsWith(st, "-\n") {
    yParseBlockSequence(st, indent, depth + 1)
  } else {
    // Peek ahead: if this line contains "key: ", it's a mapping; else scalar.
    val lineStart = st.pos
    var colonPos = -1
    var lineEnd = lineStart
    var scanning = true
    while scanning and lineEnd < st.src.length {
      val lc = st.src[lineEnd]
      if lc == '\n' {
        scanning = false
      } else if lc == ':' and (lineEnd + 1 >= st.src.length or st.src[lineEnd + 1] == ' ' or st.src[lineEnd + 1] == '\n') {
        colonPos = lineEnd
        scanning = false
      } else {
        lineEnd = lineEnd + 1
      }
    }
    if colonPos >= 0 {
      yParseBlockMapping(st, indent, depth + 1)
    } else {
      // Plain scalar (rest of line)
      val scStart = st.pos
      var scEnd = st.pos
      while scEnd < st.src.length and st.src[scEnd] != '\n' {
        if st.src[scEnd] == '#' {
          scEnd = st.src.length  // break sentinel
        } else {
          scEnd = scEnd + 1
        }
      }
      if scEnd > st.src.length {
        scEnd = st.src.length
      }
      val raw = st.src.substring(scStart, scEnd - scStart)
      st.pos = scEnd
      Ok(value = yInterpretScalar(raw))
    }
  }
}

// ── Anchor / alias guard ───────────────────────────────────────────────────────
func yCheckUnsupported(st: inout YamlState): Option[YamlError] {
  if yStartsWith(st, "&") or yStartsWith(st, "*") or yStartsWith(st, "---") or yStartsWith(st, "!") {
    Some(value = UnsupportedFeature(pos = st.pos, feature = "anchors/aliases/directives/tags"))
  } else {
    None
  }
}

// ── Public API ─────────────────────────────────────────────────────────────────
/// Parse a strict JSON string.
@stable(since = "0.1")
pub func parseJson(src: in String): Result[YamlValue, YamlError] {
  var st = YamlState(src = src, pos = 0, isJson = true)
  ySkipWs(st)
  if yAtEnd(st) {
    return Err(error = InvalidDocument(message = "empty input"))
  }
  match yParseValue(st, 0) {
    case Err(e) -> Err(error = e)
    case Ok(v) -> {
      ySkipWs(st)
      if not yAtEnd(st) {
        Err(error = UnexpectedChar(pos = st.pos, expected = "end of input after JSON value"))
      } else {
        Ok(value = v)
      }
    }
  }
}

/// Parse a YAML (or JSON) string.
@stable(since = "0.1")
pub func parseYaml(src: in String): Result[YamlValue, YamlError] {
  var st = YamlState(src = src, pos = 0, isJson = false)
  ySkipBlankAndComment(st)
  if yAtEnd(st) {
    return Ok(value = YNull)
  }
  match yCheckUnsupported(st) {
    case Some(e) -> Err(error = e)
    case None -> {
      val c = st.src[st.pos]
      // Use flow mode for explicit flow starts and plain numbers; '-' is only
      // a number prefix when immediately followed by a digit (not "- " which
      // starts a block sequence entry).
      val nextIsDigit = if st.pos + 1 < st.src.length {
        val nc = st.src[st.pos + 1]
        nc >= '0' and nc <= '9'
      } else {
        false
      }
      val goFlow = if c == '[' or c == '{' or c == '"' or c == '\'' {
        true
      } else if c >= '0' and c <= '9' {
        true
      } else if c == '-' and nextIsDigit {
        true
      } else {
        false
      }
      if goFlow {
        yParseValue(st, 0)
      } else {
        yParseBlockNode(st, 0, 0)
      }
    }
  }
}

// ── Query helpers ──────────────────────────────────────────────────────────────
/// True if the value is null.
@stable(since = "0.1")
pub func isNull(v: in YamlValue): Bool {
  match v {
    case YNull -> true
    case _ -> false
  }
}

/// Extract a string value, or None.
@stable(since = "0.1")
pub func asString(v: in YamlValue): Option[String] {
  match v {
    case YString(s) -> Some(value = s)
    case _ -> None
  }
}

/// Extract a boolean value, or None.
@stable(since = "0.1")
pub func asBool(v: in YamlValue): Option[Bool] {
  match v {
    case YBool(b) -> Some(value = b)
    case _ -> None
  }
}

/// Extract an integer value, or None.
@stable(since = "0.1")
pub func asInt(v: in YamlValue): Option[Long] {
  match v {
    case YInt(n) -> Some(value = n)
    case _ -> None
  }
}

/// Extract a float value, or None.
@stable(since = "0.1")
pub func asFloat(v: in YamlValue): Option[Double] {
  match v {
    case YFloat(f) -> Some(value = f)
    case _ -> None
  }
}

/// Extract a sequence, or None.
@stable(since = "0.1")
pub func asSequence(v: in YamlValue): Option[List[YamlValue]] {
  match v {
    case YSequence(items) -> Some(value = items)
    case _ -> None
  }
}

/// Extract a mapping, or None.
@stable(since = "0.1")
pub func asMapping(v: in YamlValue): Option[List[YamlPair]] {
  match v {
    case YMapping(pairs) -> Some(value = pairs)
    case _ -> None
  }
}

/// Look up a key in a mapping, or None if absent.
@stable(since = "0.1")
pub func getField(v: in YamlValue, key: in String): Option[YamlValue] {
  match asMapping(v) {
    case None -> None
    case Some(pairs) -> {
      var i = 0
      var found: Option[YamlValue] = None
      while i < pairs.count and isNone(found) {
        if pairs[i].key == key {
          found = Some(value = pairs[i].value)
        }
        i += 1
      }
      found
    }
  }
}

/// Return the string at the given key in a mapping, or None.
@stable(since = "0.1")
pub func getString(v: in YamlValue, key: in String): Option[String] {
  match getField(v, key) {
    case None -> None
    case Some(f) -> asString(f)
  }
}

/// Return the integer at the given key in a mapping, or None.
@stable(since = "0.1")
pub func getInt(v: in YamlValue, key: in String): Option[Long] {
  match getField(v, key) {
    case None -> None
    case Some(f) -> asInt(f)
  }
}

/// Return the boolean at the given key in a mapping, or None.
@stable(since = "0.1")
pub func getBool(v: in YamlValue, key: in String): Option[Bool] {
  match getField(v, key) {
    case None -> None
    case Some(f) -> asBool(f)
  }
}

/// Return the float at the given key in a mapping, or None.
@stable(since = "0.1")
pub func getFloat(v: in YamlValue, key: in String): Option[Double] {
  match getField(v, key) {
    case None -> None
    case Some(f) -> asFloat(f)
  }
}
