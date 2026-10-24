//! sdk_common.l - Lyric.PluginSdk: what the C#, Java and TypeScript SDK
//! generators share: output files, the compound-type registry that gives each
//! compound boundary type one named encoder and decoder, string quoting and
//! default-value checks.
package Lyric.PluginSdk

import Std.Core
import Std.Collections
import Std.String as Str

/// One generated file: `path` is relative to the output directory.
pub record SdkFile {
  path: String
  content: String
}

pub record SdkOutput {
  files: List[SdkFile]
  errors: List[String]
}

/// The languages `lyric plugin sdk` generates for.
pub func sdkLanguages(): List[String] {
  val langs: List[String] = newList()
  langs.add("csharp")
  langs.add("java")
  langs.add("typescript")
  langs
}

// ── Lines ────────────────────────────────────────────────────────────────────
record Out {
  lines: List[String]
}

func newOut(): Out = Out(lines = newList())

func emit(o: in Out, line: in String): Unit {
  o.lines.add(line)
}

func outText(o: in Out): String = Str.joinList("\n", o.lines) + "\n"

// ── Names ────────────────────────────────────────────────────────────────────
pub func upperFirst(s: in String): String {
  if s.length == 0 {
    return s
  }
  Str.toUpper(Str.substring(s, 0, 1)) + Str.substring(s, 1)
}

pub func lowerFirst(s: in String): String {
  if s.length == 0 {
    return s
  }
  Str.toLower(Str.substring(s, 0, 1)) + Str.substring(s, 1)
}

func hex4(n: in Int): String {
  val digits = "0123456789abcdef"
  var s = ""
  var v = n
  var i = 0
  while i < 4 {
    s = Str.substring(digits, v % 16, 1) + s
    v = v / 16
    i = i + 1
  }
  s
}

/// A double-quoted string literal valid in C#, Java and TypeScript (and JSON):
/// control characters use short escapes or `\uXXXX`, never a raw newline, so
/// Java's early Unicode-escape processing cannot break the literal.
pub func quoteString(s: in String): String {
  val parts: List[String] = newList()
  parts.add("\"")
  var i = 0
  while i < s.length {
    val c = Str.codeUnitAt(s, i)
    if c == 34 {
      parts.add("\\\"")
    } else if c == 92 {
      parts.add("\\\\")
    } else if c == 10 {
      parts.add("\\n")
    } else if c == 13 {
      parts.add("\\r")
    } else if c == 9 {
      parts.add("\\t")
    } else if c < 32 or c == 127 or c == 8232 or c == 8233 {
      parts.add("\\u" + hex4(c))
    } else {
      parts.add(Str.substring(s, i, 1))
    }
    i = i + 1
  }
  parts.add("\"")
  Str.joinList("", parts)
}

// ── Compound types ───────────────────────────────────────────────────────────
pub func isCompound(t: in BType): Bool {
  match t {
    case BOption(_) -> true
    case BResult(_, _) -> true
    case BList(_) -> true
    case BMap(_) -> true
    case BTuple(_) -> true
    case _ -> false
  }
}

/// A canonical spelling of a boundary type, unique per type.
pub func canonType(t: in BType): String {
  match t {
    case BBool -> "Bool"
    case BByte -> "Byte"
    case BInt -> "Int"
    case BLong -> "Long"
    case BUInt -> "UInt"
    case BULong -> "ULong"
    case BFloat -> "Float"
    case BDouble -> "Double"
    case BChar -> "Char"
    case BString -> "String"
    case BUnit -> "Unit"
    case BJson -> "JsonValue"
    case BBytes -> "List[Byte]"
    case BOption(i) -> "Option[" + canonType(i) + "]"
    case BResult(o, e) -> "Result[" + canonType(o) + ", " + canonType(e) + "]"
    case BList(e) -> "List[" + canonType(e) + "]"
    case BMap(v) -> "Map[String, " + canonType(v) + "]"
    case BTuple(items) -> {
      val parts: List[String] = newList()
      for x in items {
        parts.add(canonType(x))
      }
      "(" + Str.joinList(", ", parts) + ")"
    }
    case BNamed(n) -> n
  }
}

func mangleType(t: in BType): String {
  match t {
    case BBytes -> "Bytes"
    case BJson -> "Json"
    case BOption(i) -> "OptionOf" + mangleType(i)
    case BResult(o, e) -> "ResultOf" + mangleType(o) + "And" + mangleType(e)
    case BList(e) -> "ListOf" + mangleType(e)
    case BMap(v) -> "MapOf" + mangleType(v)
    case BTuple(items) -> {
      val parts: List[String] = newList()
      for x in items {
        parts.add(mangleType(x))
      }
      "TupleOf" + Str.joinList("And", parts)
    }
    case _ -> canonType(t)
  }
}

/// The compound types a generator has named an encoder/decoder pair for.
/// Emitting one compound's codec can register the compounds it contains, so
/// generators drain the registry until `emitted == types.count`.
record Registry {
  keys: List[String]
  names: List[String]
  types: List[BType]
  declNames: List[String]
}

func newRegistry(m: in ApiModel): Registry {
  val declNames: List[String] = newList()
  for d in m.decls {
    declNames.add(d.name)
  }
  Registry(keys = newList(), names = newList(), types = newList(), declNames = declNames)
}

/// The codec suffix of compound type `t`, registering it on first use.
func registerCompound(reg: in Registry, t: in BType): String {
  val key = canonType(t)
  var i = 0
  while i < reg.keys.count {
    if reg.keys[i] == key {
      return reg.names[i]
    }
    i = i + 1
  }
  var name = mangleType(t)
  if listContains(reg.names, name) or listContains(reg.declNames, name) {
    name = name + "_" + reg.keys.count.toString()
  }
  reg.keys.add(key)
  reg.names.add(name)
  reg.types.add(t)
  name
}

// ── Defaults ─────────────────────────────────────────────────────────────────
func declOf(m: in ApiModel, name: in String): Option[BDecl] = findDecl(m, name)

func isIntegral(t: in BType): Bool {
  match t {
    case BByte -> true
    case BInt -> true
    case BLong -> true
    case BUInt -> true
    case BULong -> true
    case _ -> false
  }
}

func isFloating(t: in BType): Bool {
  match t {
    case BFloat -> true
    case BDouble -> true
    case _ -> false
  }
}

func intFits(t: in BType, v: in Long): Bool {
  match t {
    case BByte -> v >= 0 and v <= 255
    case BInt -> v >= -2147483648i64 and v <= 2147483647i64
    case BUInt -> v >= 0i64 and v <= 4294967295i64
    case BULong -> v >= 0
    case _ -> true
  }
}

/// The nullary union case or enum case `caseName` of type `typeName`, checked.
func caseIsNullary(m: in ApiModel, typeName: in String, caseName: in String): Bool {
  match declOf(m, typeName) {
    case Some(d) -> match d.kind {
      case KEnum(cases) -> listContains(cases, caseName)
      case KUnion(cases) -> {
        for c in cases {
          if c.name == caseName {
            return c.fields.count == 0
          }
        }
        false
      }
      case _ -> false
    }
    case None -> false
  }
}

/// Whether a field default fits its type; the generators emit only defaults
/// that pass this check.
func defaultFits(m: in ApiModel, t: in BType, d: in BDefault): Bool {
  match t {
    case BOption(inner) -> match d { case DefNone -> true; case _ -> defaultFits(m, inner, d) }
    case _ -> match d {
      case DefInt(v) -> (isIntegral(t) and intFits(t, v)) or isFloating(t)
      case DefFloat(_) -> isFloating(t)
      case DefString(s) -> match t { case BString -> true; case BChar -> s.length == 1; case _ -> false }
      case DefBool(_) -> match t { case BBool -> true; case _ -> false }
      case DefNone -> false
      case DefEmptyList -> match t { case BList(_) -> true; case BBytes -> true; case _ -> false }
      case DefEmptyMap -> match t { case BMap(_) -> true; case _ -> false }
      case DefEnum(typeName, caseName) -> match t {
        case BNamed(n) -> n == typeName and
          caseIsNullary(m, typeName, caseName)
        case _ -> false
      }
    }
  }
}

/// Reports every record field whose default does not fit its type.
func checkDefaults(m: in ApiModel, errors: in List[String]): Unit {
  for d in m.decls {
    match d.kind {
      case KRecord(fields) -> {
        for f in fields {
          match f.dflt {
            case Some(df) -> {
              if not defaultFits(m, f.ty, df) {
                errors.add("error: the default of " + d.name + "." + f.name + " does not fit its type " + canonType(f.ty))
              }
            }
            case None -> ()
          }
        }
      }
      case _ -> ()
    }
  }
}

/// Reports a declared type whose name a generator reserves for itself.
func checkReservedNames(m: in ApiModel, reserved: in List[String], lang: in String, errors: in List[String]): Unit {
  val generated: List[String] = newList()
  for r in reserved {
    generated.add(r)
  }
  for p in m.points {
    generated.add(p.name + "Point")
    generated.add(p.name + "Dispatcher")
  }
  for c in m.capabilities {
    generated.add(c.name + "Client")
    generated.add(c.name + "Capability")
  }
  for d in m.decls {
    if listContains(generated, d.name) {
      errors.add("error: the boundary type " + d.name + " has a name the " + lang + " SDK generates for itself; rename it")
    }
  }
}

func joinWith(sep: in String, parts: in List[String]): String = Str.joinList(sep, parts)
