//! bindgen.l - `lyric bindgen` (docs/67 §5.3, D190): generates a `_kernel_native/`
//! binding file from `clang -Xclang -ast-dump=json` output for a C header.
//!
//! The output is `pub extern func` declarations (each carrying the library's
//! `@library` name), `foreign record` declarations for the structs the selected
//! functions use, and `pub val` constants for the selected enum constants.  What
//! is bound is chosen by an allow-list, so a large header (SDL3, webgpu.h) yields
//! only what a wrapper needs.  Anything the native backend cannot pass faithfully
//! (a 16-bit integer, a bit-field, a union by value, a variadic function, a
//! callback with no unambiguous userdata parameter) is reported and skipped, and
//! an explicitly named symbol that is skipped is an error.
//!
//! Pure: `generateBindings` takes the AST JSON text and returns the Lyric source
//! and the notes; the CLI (`cli_bindgen.l`) runs clang and writes the file.
@runtime_checked
package Lyric.Bindgen

import Std.Core
import Std.Collections
import Std.String as Str
import Std.JsonValue as J

/// What to bind and how.  `allow` entries are exact names or a prefix ending in
/// `*`, matched against function, record, typedef and enum-constant names.
/// `userdata` maps a callback typedef's name to the index of the parameter that
/// carries the user pointer, where the one-`void *` rule does not decide it.
pub record BindgenConfig {
  packageName: String
  library: String
  allow: List[String]
  userdata: Map[String, Int]
  longBits: Int
}

pub record BindgenResult {
  source: String
  notes: List[String]
  errors: List[String]
}

union CType {
  case CVoid
  case CInt(bits: Int)
  case CBool
  case CFloat
  case CDouble
  case CPtr(to: CType)
  case CRecordT(id: String)
  case CEnumT
  case CFuncPtr(name: String, ret: CType, params: List[CType])
  case CArr(elem: CType, count: Int)
  case CBad(why: String)
}

record FieldInfo {
  name: String
  ty: String
  isBitfield: Bool
}

record RecordInfo {
  id: String
  tag: String
  fields: List[FieldInfo]
  complete: Bool
  isUnion: Bool
}

record ParamInfo {
  name: String
  ty: String
}

record FuncInfo {
  name: String
  ret: String
  params: List[ParamInfo]
  variadic: Bool
}

record ConstInfo {
  name: String
  value: Long
  /// The declared C type of a `static const` integer ("" for an enum constant).
  ty: String = ""
}

record Index {
  typedefs: Map[String, String]
  typedefRecord: Map[String, String]
  records: Map[String, RecordInfo]
  tagToId: Map[String, String]
  recordNames: Map[String, String]
  enumTags: Map[String, Bool]
  consts: List[ConstInfo]
  funcs: List[FuncInfo]
  longBits: Int
}

record Emit {
  recordText: Map[String, String]
  recordOrder: List[String]
  recordState: Map[String, Int]
  recordNote: Map[String, String]
}

// ── Allow-list ───────────────────────────────────────────────────────────────
/// Parses an allow-list file: one pattern per line (`#` starts a comment), and
/// `userdata <callback> <index>` lines naming a callback's user pointer.
pub func parseAllowList(text: in String, cfg: in BindgenConfig): List[String] {
  val errs: List[String] = newList()
  val lines = Str.split(text, "\n")
  var i = 0
  while i < lines.length {
    var line = lines[i]
    val hash = Str.indexOfRaw(line, "#")
    if hash >= 0 {
      line = Str.substring(line, 0, hash)
    }
    line = Str.trim(line)
    i = i + 1
    if line.length == 0 {
      continue
    }
    if Str.startsWith(line, "userdata ") {
      val parts = Str.split(Str.trim(Str.substring(line, 9)), " ")
      if parts.length == 2 {
        match parseSmallInt(parts[1]) {
          case Some(n) -> cfg.userdata.add(parts[0], n)
          case None -> errs.add("allow-list line " + Str.fromInt(i) + ": the index of a userdata line must be a number")
        }
      } else {
        errs.add("allow-list line " + Str.fromInt(i) + ": expected `userdata <callback> <index>`")
      }
    } else {
      cfg.allow.add(line)
    }
  }
  errs
}

func parseSmallInt(s: in String): Option[Int] {
  if s.length == 0 or s.length > 6 {
    return None
  }
  var n = 0
  var i = 0
  while i < s.length {
    val c = Str.codeUnitAt(s, i)
    if c < 48 or c > 57 {
      return None
    }
    n = n * 10 + (c - 48)
    i = i + 1
  }
  Some(value = n)
}

func patternMatches(pattern: in String, name: in String): Bool {
  if Str.endsWith(pattern, "*") {
    return Str.startsWith(name, Str.substring(pattern, 0, pattern.length - 1))
  }
  pattern == name
}

func isAllowed(cfg: in BindgenConfig, name: in String): Bool {
  var i = 0
  while i < cfg.allow.count {
    if patternMatches(cfg.allow[i], name) {
      return true
    }
    i = i + 1
  }
  false
}

// ── AST indexing ─────────────────────────────────────────────────────────────
func jstr(v: in J.JsonValue, key: in String): String {
  match J.getString(v, key) {
    case Some(s) -> s
    case None -> ""
  }
}

func jtype(v: in J.JsonValue): String {
  match J.getField(v, "type") {
    case Some(t) -> jstr(t, "qualType")
    case None -> ""
  }
}

func jinner(v: in J.JsonValue): List[J.JsonValue] {
  match J.getArray(v, "inner") {
    case Some(xs) -> xs
    case None -> newList()
  }
}

func jbool(v: in J.JsonValue, key: in String): Bool {
  match J.getBool(v, key) {
    case Some(b) -> b
    case None -> false
  }
}

func addRecord(ix: in Index, node: in J.JsonValue): Unit {
  val id = jstr(node, "id")
  val tag = jstr(node, "name")
  val complete = jbool(node, "completeDefinition")
  val fields: List[FieldInfo] = newList()
  for ch in jinner(node) {
    if jstr(ch, "kind") == "FieldDecl" {
      fields.add(FieldInfo(name = jstr(ch, "name"), ty = jtype(ch), isBitfield = jbool(ch, "isBitfield")))
    }
  }
  val info = RecordInfo(
    id = id,
    tag = tag,
    fields = fields,
    complete = complete,
    isUnion = jstr(node, "tagUsed") == "union"
  )
  if tag.length > 0 {
    match mapGet(ix.tagToId, tag) {
      case Some(prev) -> {
        val prevComplete = match mapGet(ix.records, prev) { case Some(p) -> p.complete; case None -> false }
        if complete and not prevComplete {
          ix.tagToId.remove(tag)
          ix.tagToId.add(tag, id)
        }
      }
      case None -> ix.tagToId.add(tag, id)
    }
  }
  ix.records.add(id, info)
}

func addEnum(ix: in Index, node: in J.JsonValue): Unit {
  val tag = jstr(node, "name")
  if tag.length > 0 {
    ix.enumTags.add(tag, true)
  }
  var next = 0i64
  for ch in jinner(node) {
    if jstr(ch, "kind") == "EnumConstantDecl" {
      var value = next
      for e in jinner(ch) {
        match J.getString(e, "value") {
          case Some(vs) -> match parseLong(vs) { case Some(n) -> { value = n }; case None -> () }
          case None -> ()
        }
      }
      ix.consts.add(ConstInfo(name = jstr(ch, "name"), value = value))
      next = value + 1i64
    }
  }
}

func parseLong(s: in String): Option[Long] {
  if s.length == 0 {
    return None
  }
  var neg = false
  var i = 0
  if Str.codeUnitAt(s, 0) == 45 {
    neg = true
    i = 1
  }
  if i >= s.length {
    return None
  }
  var n = 0i64
  while i < s.length {
    val c = Str.codeUnitAt(s, i)
    if c < 48 or c > 57 {
      return None
    }
    n = n * 10i64 + (c - 48).toLong()
    i = i + 1
  }
  if neg {
    Some(value = 0i64 - n)
  } else {
    Some(value = n)
  }
}

/// The first integer literal under `node` (an initializer is wrapped in implicit casts).
func findLiteralValue(node: in J.JsonValue, depth: in Int): Option[Long] {
  if depth > 6 {
    return None
  }
  val kind = jstr(node, "kind")
  if kind == "IntegerLiteral" or kind == "ConstantExpr" {
    match J.getString(node, "value") {
      case Some(vs) -> return parseLong(vs)
      case None -> ()
    }
  }
  for ch in jinner(node) {
    if jstr(ch, "kind") != "FullComment" {
      match findLiteralValue(ch, depth + 1) {
        case Some(n) -> return Some(value = n)
        case None -> ()
      }
    }
  }
  None
}

/// A `static const <integer type> NAME = <literal>;` (webgpu.h's flag bits are these,
/// not enumerators).
func addConstVar(ix: in Index, node: in J.JsonValue): Unit {
  val ty = jtype(node)
  if not Str.startsWith(ty, "const ") {
    return
  }
  for ch in jinner(node) {
    if jstr(ch, "kind") != "FullComment" {
      match findLiteralValue(ch, 0) {
        case Some(n) -> {
          ix.consts.add(ConstInfo(name = jstr(node, "name"), value = n, ty = Str.substring(ty, 6)))
          return
        }
        case None -> ()
      }
    }
  }
}

func addTypedef(ix: in Index, node: in J.JsonValue): Unit {
  val name = jstr(node, "name")
  ix.typedefs.add(name, jtype(node))
  for ch in jinner(node) {
    if jstr(ch, "kind") == "ElaboratedType" {
      match J.getField(ch, "ownedTagDecl") {
        case Some(owned) -> {
          if jstr(owned, "kind") == "RecordDecl" and not ix.typedefRecord.containsKey(name) {
            ix.typedefRecord.add(name, jstr(owned, "id"))
          }
        }
        case None -> ()
      }
    }
  }
}

func addFunc(ix: in Index, node: in J.JsonValue): Unit {
  if jstr(node, "storageClass") == "static" or jbool(node, "inline") {
    return
  }
  val params: List[ParamInfo] = newList()
  for ch in jinner(node) {
    if jstr(ch, "kind") == "ParmVarDecl" {
      params.add(ParamInfo(name = jstr(ch, "name"), ty = jtype(ch)))
    }
  }
  val full = jtype(node)
  ix.funcs.add(
    FuncInfo(name = jstr(node, "name"), ret = returnTypeOf(full), params = params, variadic = Str.contains(full, "..."))
  )
}

/// The return type of a function type string `R (P1, P2)`: everything before the
/// parameter list's opening parenthesis, which is the last top-level `(`.
func returnTypeOf(full: in String): String {
  var depth = 0
  var i = full.length - 1
  while i >= 0 {
    val c = Str.codeUnitAt(full, i)
    if c == 41 {
      depth = depth + 1
    } else if c == 40 {
      depth = depth - 1
      if depth == 0 {
        return Str.trim(Str.substring(full, 0, i))
      }
    }
    i = i - 1
  }
  Str.trim(full)
}

func buildIndex(root: in J.JsonValue, longBits: in Int): Index {
  val ix = Index(
    typedefs = newMap(),
    typedefRecord = newMap(),
    records = newMap(),
    tagToId = newMap(),
    recordNames = newMap(),
    enumTags = newMap(),
    consts = newList(),
    funcs = newList(),
    longBits = longBits
  )
  for node in jinner(root) {
    val kind = jstr(node, "kind")
    if kind == "RecordDecl" {
      addRecord(ix, node)
    } else if kind == "EnumDecl" {
      addEnum(ix, node)
    } else if kind == "TypedefDecl" {
      addTypedef(ix, node)
    } else if kind == "FunctionDecl" {
      addFunc(ix, node)
    } else if kind == "VarDecl" {
      addConstVar(ix, node)
    }
  }
  // A record's Lyric name: the typedef that names it, else its tag.
  for k in mapKeys(ix.typedefRecord) {
    val id = ix.typedefRecord[k]
    if not ix.recordNames.containsKey(id) {
      ix.recordNames.add(id, k)
    }
  }
  for id in mapKeys(ix.records) {
    if not ix.recordNames.containsKey(id) {
      val r = ix.records[id]
      if r.tag.length > 0 {
        ix.recordNames.add(id, r.tag)
      }
    }
  }
  ix
}

// ── C type strings ───────────────────────────────────────────────────────────
func isQualifierWord(w: in String): Bool {
  w == "const" or w == "volatile" or w == "restrict" or w == "__restrict" or w == "struct" or w == "union" or
    w == "enum" or
    w == "_Atomic"
}

func tokensOf(s: in String): List[String] {
  val spaced = Str.replace(Str.replace(Str.replace(s, "*", " * "), "(", " ( "), ")", " ) ")
  val chunks: List[String] = newList()
  val parts = Str.split(spaced, " ")
  var i = 0
  while i < parts.length {
    if parts[i].length > 0 and not isQualifierWord(parts[i]) {
      chunks.add(parts[i])
    }
    i = i + 1
  }
  chunks
}

/// The comma-separated top-level parts of `s`.
func splitTopLevel(s: in String): List[String] {
  val chunks: List[String] = newList()
  var depth = 0
  var start = 0
  var i = 0
  while i < s.length {
    val c = Str.codeUnitAt(s, i)
    if c == 40 {
      depth = depth + 1
    } else if c == 41 {
      depth = depth - 1
    } else if c == 44 and depth == 0 {
      chunks.add(Str.trim(Str.substring(s, start, i - start)))
      start = i + 1
    }
    i = i + 1
  }
  val last = Str.trim(Str.substring(s, start))
  if last.length > 0 {
    chunks.add(last)
  }
  chunks
}

func builtinOf(ix: in Index, toks: in List[String]): Option[CType] {
  var longs = 0
  var hasChar = false
  var hasShort = false
  var hasInt = false
  var other = false
  for t in toks {
    if t == "long" {
      longs = longs + 1
    } else if t == "char" {
      hasChar = true
    } else if t == "short" {
      hasShort = true
    } else if t == "int" {
      hasInt = true
    } else if t == "unsigned" or t == "signed" {
      hasInt = hasInt
    } else {
      other = true
    }
  }
  if toks.count == 1 {
    val t = toks[0]
    if t == "void" {
      return Some(value = CVoid)
    }
    if t == "float" {
      return Some(value = CFloat)
    }
    if t == "double" {
      return Some(value = CDouble)
    }
    if t == "_Bool" or t == "bool" {
      return Some(value = CBool)
    }
  }
  if other {
    return None
  }
  if hasChar {
    return Some(value = CInt(bits = 8))
  }
  if hasShort {
    return Some(value = CInt(bits = 16))
  }
  if longs >= 2 {
    return Some(value = CInt(bits = 64))
  }
  if longs == 1 {
    return Some(value = CInt(bits = ix.longBits))
  }
  if hasInt or toks.count > 0 {
    return Some(value = CInt(bits = 32))
  }
  None
}

func parseCType(ix: in Index, s0: in String, typedefName: in String, depth: in Int): CType {
  if depth > 16 {
    return CBad(why = "type nests too deeply: " + s0)
  }
  val s = Str.trim(s0)
  val fp = Str.indexOfRaw(s, "(*)")
  if fp >= 0 {
    val ret = parseCType(ix, Str.substring(s, 0, fp), "", depth + 1)
    val rest = Str.trim(Str.substring(s, fp + 3))
    if not Str.startsWith(rest, "(") or not Str.endsWith(rest, ")") {
      return CBad(why = "unsupported function pointer type: " + s)
    }
    val inside = Str.substring(rest, 1, rest.length - 2)
    val params: List[CType] = newList()
    for p in splitTopLevel(inside) {
      if p != "void" {
        params.add(parseCType(ix, p, "", depth + 1))
      }
    }
    return CFuncPtr(name = typedefName, ret = ret, params = params)
  }
  if Str.endsWith(s, "]") {
    val lb = Str.lastIndexOfRaw(s, "[")
    if lb < 0 {
      return CBad(why = "unsupported array type: " + s)
    }
    val elemStr = Str.substring(s, 0, lb)
    if Str.contains(elemStr, "[") {
      return CBad(why = "a multi-dimensional array has no layout here: " + s)
    }
    match parseSmallInt(Str.trim(Str.substring(s, lb + 1, s.length - lb - 2))) {
      case Some(n) -> return CArr(elem = parseCType(ix, elemStr, "", depth + 1), count = n)
      case None -> return CBad(why = "an array with a non-constant length: " + s)
    }
  }
  val toks = tokensOf(s)
  var stars = 0
  val base: List[String] = newList()
  for t in toks {
    if t == "*" {
      stars = stars + 1
    } else {
      base.add(t)
    }
  }
  var ct = parseBase(ix, base, s, depth)
  var k = 0
  while k < stars {
    ct = CPtr(to = ct)
    k = k + 1
  }
  ct
}

func parseBase(ix: in Index, base: in List[String], whole: in String, depth: in Int): CType {
  match builtinOf(ix, base) {
    case Some(b) -> return b
    case None -> ()
  }
  if base.count != 1 {
    return CBad(why = "unsupported type: " + whole)
  }
  val name = base[0]
  match mapGet(ix.typedefRecord, name) {
    case Some(id) -> return CRecordT(id = id)
    case None -> ()
  }
  match mapGet(ix.typedefs, name) {
    case Some(under) -> {
      // `typedef enum {...} Mode` and `typedef struct Tag Name` resolve by the
      // underlying spelling; a typedef of a function pointer keeps its name.
      if Str.startsWith(under, "enum ") {
        return CEnumT
      }
      return parseCType(ix, under, name, depth + 1)
    }
    case None -> ()
  }
  match mapGet(ix.tagToId, name) {
    case Some(id) -> return CRecordT(id = id)
    case None -> ()
  }
  if ix.enumTags.containsKey(name) {
    return CEnumT
  }
  CBad(why = "unknown type '" + name + "'")
}

// ── Lyric types ──────────────────────────────────────────────────────────────
val reservedWords: List[String] = ["alias", "and", "as", "async", "await", "bind", "break", "case", "continue", "defer", "do", "else", "end", "ensures", "entry", "enum", "exposed", "extern", "false", "fixture", "for", "foreign", "from", "func", "generic", "if", "impl", "import", "in", "inout", "interface", "internal", "invariant", "is", "let", "match", "mut", "not", "old", "opaque", "or", "chunks", "package", "property", "protected", "pub", "record", "requires", "result", "return", "satisfies", "scope", "scoped", "self", "singleton", "spawn", "test", "then", "throw", "true", "try", "type", "union", "use", "val", "var", "when", "where", "while", "wire", "with", "xor", "yield"]

func identOf(name: in String, fallback: in String): String {
  if name.length == 0 {
    return fallback
  }
  var i = 0
  while i < reservedWords.length {
    if reservedWords[i] == name {
      return name + "_"
    }
    i = i + 1
  }
  name
}

/// A mapped type, or why there is none.
union Mapped {
  case Ok(text: String)
  case No(why: String)
}

func recordNameOf(ix: in Index, id: in String): String {
  match mapGet(ix.recordNames, id) {
    case Some(n) -> n
    case None -> ""
  }
}

/// Registers the foreign record `id` (and the records it holds by value or by
/// pointer) and returns its name, or why it has none.
func useRecord(ix: in Index, em: in Emit, cfg: in BindgenConfig, id: in String): Mapped {
  val name = recordNameOf(ix, id)
  match mapGet(ix.records, id) {
    case None -> return No(why = "record has no definition")
    case Some(r) -> {
      if name.length == 0 {
        return No(why = "an anonymous struct with no typedef name")
      }
      if not r.complete {
        return No(why = "'" + name + "' is an incomplete type")
      }
      if r.isUnion {
        return No(why = "'" + name + "' is a union")
      }
      match mapGet(em.recordState, id) {
        case Some(st) -> {
          if st == 2 {
            match mapGet(em.recordNote, id) {
              case Some(why) -> return No(why = why)
              case None -> ()
            }
          }
          return Ok(text = name)
        }
        case None -> ()
      }
      em.recordState.add(id, 1)
      val lines: List[String] = newList()
      var failure = ""
      var fi = 0
      while fi < r.fields.count and failure.length == 0 {
        val f = r.fields[fi]
        if f.isBitfield {
          failure = "'" + name + "' has a bit-field"
        } else {
          match fieldType(ix, em, cfg, parseCType(ix, f.ty, "", 0)) {
            case Ok(t) -> lines.add("  " + identOf(f.name, "f" + Str.fromInt(fi)) + ": " + t)
            case No(why) -> {
              failure = "field '" + f.name + "' of '" + name + "': " + why
            }
          }
        }
        fi = fi + 1
      }
      if failure.length > 0 {
        em.recordState.remove(id)
        em.recordState.add(id, 2)
        em.recordNote.add(id, failure)
        return No(why = failure)
      }
      if lines.count == 0 {
        em.recordState.remove(id)
        em.recordState.add(id, 2)
        em.recordNote.add(id, "'" + name + "' has no fields")
        return No(why = "'" + name + "' has no fields")
      }
      em.recordText.add(id, "pub foreign record " + name + " {\n" + Str.joinList("\n", lines) + "\n}\n")
      em.recordOrder.add(id)
      Ok(text = name)
    }
  }
}

func scalarName(ct: in CType): Mapped {
  match ct {
    case CInt(bits) -> {
      if bits == 8 {
        return Ok(text = "Byte")
      }
      if bits == 32 {
        return Ok(text = "Int")
      }
      if bits == 64 {
        return Ok(text = "Long")
      }
      No(why = "a " + Str.fromInt(bits) + "-bit integer has no Lyric type")
    }
    case CBool -> Ok(text = "Byte")
    case CFloat -> Ok(text = "Float")
    case CDouble -> Ok(text = "Double")
    case CEnumT -> Ok(text = "Int")
    case _ -> No(why = "not a scalar")
  }
}

func pointeeName(ix: in Index, em: in Emit, cfg: in BindgenConfig, to: in CType): Mapped {
  match to {
    case CVoid -> Ok(text = "Byte")
    case CRecordT(id) -> match useRecord(ix, em, cfg, id) {
      case Ok(n) -> Ok(text = n)
      case No(_) -> Ok(text = "Byte")
    }
    case CPtr(inner) -> match pointeeName(ix, em, cfg, inner) {
      case Ok(n) -> Ok(text = "NativePtr[" + n + "]")
      case No(why) -> No(why = why)
    }
    case CFuncPtr(_, _, _) -> No(why = "a pointer to a function pointer")
    case CArr(_, _) -> No(why = "a pointer to an array")
    case CBad(why) -> No(why = why)
    case _ -> scalarName(to)
  }
}

/// A record field's type: scalars, pointers, other records by value, and arrays
/// of scalars or records.
func fieldType(ix: in Index, em: in Emit, cfg: in BindgenConfig, ct: in CType): Mapped {
  match ct {
    case CPtr(to) -> match pointeeName(ix, em, cfg, to) {
      case Ok(n) -> Ok(text = "NativePtr[" + n + "]")
      case No(why) -> No(why = why)
    }
    case CRecordT(id) -> useRecord(ix, em, cfg, id)
    case CArr(elem, count) -> match elem {
      case CPtr(_) -> No(why = "an array of pointers has no layout here")
      case CArr(_, _) -> No(why = "a multi-dimensional array")
      case _ -> match fieldType(ix, em, cfg, elem) {
        case Ok(t) -> Ok(text = "array[" + Str.fromInt(count) + ", " + t + "]")
        case No(why) -> No(why = why)
      }
    }
    case CFuncPtr(name, ret, params) -> callbackType(ix, em, cfg, name, ret, params)
    case CVoid -> No(why = "a void field")
    case CBad(why) -> No(why = why)
    case _ -> scalarName(ct)
  }
}

func isVoidPtr(ct: in CType): Bool {
  match ct {
    case CPtr(to) -> match to { case CVoid -> true; case _ -> false }
    case _ -> false
  }
}

/// Which parameter of a callback carries the user pointer: the configured index,
/// else the only `void *` parameter; -1 with `why` set when neither decides.
func userdataIndex(cfg: in BindgenConfig, name: in String, params: in List[CType]): Int {
  if name.length > 0 {
    match mapGet(cfg.userdata, name) {
      case Some(i) -> return i
      case None -> ()
    }
  }
  var found = -1
  var count = 0
  var i = 0
  while i < params.count {
    if isVoidPtr(params[i]) {
      found = i
      count = count + 1
    }
    i = i + 1
  }
  if count == 1 {
    return found
  }
  -1
}

/// A parameter or result type of an extern function.
func externType(ix: in Index, em: in Emit, cfg: in BindgenConfig, ct: in CType, isResult: in Bool): Mapped {
  match ct {
    case CVoid -> if isResult { Ok(text = "Unit") } else { No(why = "a void parameter") }
    case CPtr(to) -> match to {
      case CFuncPtr(_, _, _) -> No(why = "a pointer to a function pointer")
      case _ -> match pointeeName(ix, em, cfg, to) {
        case Ok(n) -> Ok(text = "NativePtr[" + n + "]")
        case No(why) -> No(why = why)
      }
    }
    case CRecordT(id) -> useRecord(ix, em, cfg, id)
    case CFuncPtr(name, ret, params) -> callbackType(ix, em, cfg, name, ret, params)
    case CArr(_, _) -> No(why = "an array parameter")
    case CBad(why) -> No(why = why)
    case _ -> scalarName(ct)
  }
}

func callbackType(
  ix: in Index,
  em: in Emit,
  cfg: in BindgenConfig,
  name: in String,
  ret: in CType,
  params: in List[CType],
): Mapped {
  val ud = userdataIndex(cfg, name, params)
  val label = if name.length > 0 { "callback '" + name + "'" } else { "an unnamed callback" }
  if ud < 0 {
    return No(
      why = label +
        " has no unambiguous void* userdata parameter; add `userdata <callback> <index>` to the allow-list"
    )
  }
  val parts: List[String] = newList()
  var i = 0
  while i < params.count {
    if i == ud {
      parts.add("NativeUserdata")
    } else {
      match externType(ix, em, cfg, params[i], false) {
        case Ok(t) -> parts.add(t)
        case No(why) -> return No(why = label + ": " + why)
      }
    }
    i = i + 1
  }
  match externType(ix, em, cfg, ret, true) {
    case Ok(r) -> Ok(text = "(" + Str.joinList(", ", parts) + ") -> " + r)
    case No(why) -> No(why = label + ": " + why)
  }
}

// ── Generation ───────────────────────────────────────────────────────────────
func bindFunc(ix: in Index, em: in Emit, cfg: in BindgenConfig, f: in FuncInfo): Mapped {
  if f.variadic {
    return No(why = "'" + f.name + "' is variadic")
  }
  val params: List[String] = newList()
  var i = 0
  while i < f.params.count {
    val p = f.params[i]
    match externType(ix, em, cfg, parseCType(ix, p.ty, "", 0), false) {
      case Ok(t) -> params.add(identOf(p.name, "a" + Str.fromInt(i)) + ": " + t)
      case No(why) -> return No(why = "'" + f.name + "' parameter " + Str.fromInt(i) + ": " + why)
    }
    i = i + 1
  }
  match externType(ix, em, cfg, parseCType(ix, f.ret, "", 0), true) {
    case Ok(r) -> {
      val lib = if cfg.library.length > 0 { "@library(\"" + cfg.library + "\")\n" } else { "" }
      Ok(
        text = lib + "pub extern func " + identOf(f.name, f.name) + "(" + Str.joinList(", ", params) + "): " + r + " = \"" +
          f.name +
          "\"\n"
      )
    }
    case No(why) -> No(why = "'" + f.name + "' result: " + why)
  }
}

func isWideInt(ct: in CType): Bool {
  match ct {
    case CInt(bits) -> bits == 64
    case _ -> false
  }
}

func unwrapJson(v: in Option[J.JsonValue]): J.JsonValue {
  match v {
    case Some(x) -> x
    case None -> J.JNull
  }
}

func hasWildcard(p: in String): Bool = Str.endsWith(p, "*")

/// Generates the binding source for the selected symbols.
pub func generateBindings(astJson: in String, cfg: in BindgenConfig): BindgenResult {
  val notes: List[String] = newList()
  val errors: List[String] = newList()
  var parsed: Option[J.JsonValue] = None
  match J.parseValue(astJson) {
    case Ok(v) -> {
      parsed = Some(value = v)
    }
    case Err(e) -> errors.add("the clang AST is not valid JSON: " + e.message())
  }
  if errors.count > 0 {
    return BindgenResult(source = "", notes = notes, errors = errors)
  }
  val ix = buildIndex(unwrapJson(parsed), cfg.longBits)
  val em = Emit(recordText = newMap(), recordOrder = newList(), recordState = newMap(), recordNote = newMap())
  val matched: Map[String, Bool] = newMap()
  val funcText: List[String] = newList()
  for f in ix.funcs {
    if isAllowed(cfg, f.name) {
      matched.add(f.name, true)
      match bindFunc(ix, em, cfg, f) {
        case Ok(t) -> funcText.add(t)
        case No(why) -> notes.add("skipped " + why)
      }
    }
  }
  val constText: List[String] = newList()
  for c in ix.consts {
    if isAllowed(cfg, c.name) {
      matched.add(c.name, true)
      val wide = c.ty.length > 0 and isWideInt(parseCType(ix, c.ty, "", 0))
      if wide {
        constText.add("pub val " + identOf(c.name, c.name) + ": Long = " + c.value.toString() + "\n")
      } else if c.value > 2147483647i64 or c.value < (0i64 - 2147483648i64) {
        notes.add("skipped constant '" + c.name + "': " + c.value.toString() + " does not fit an Int")
      } else {
        constText.add("pub val " + identOf(c.name, c.name) + ": Int = " + c.value.toString() + "\n")
      }
    }
  }
  // A record or typedef named in the allow-list is bound even when no selected
  // function uses it.
  for id in mapKeys(ix.records) {
    val name = recordNameOf(ix, id)
    if name.length > 0 and isAllowed(cfg, name) {
      matched.add(name, true)
      match useRecord(ix, em, cfg, id) {
        case Ok(_) -> ()
        case No(why) -> notes.add("skipped record " + why)
      }
    }
  }
  var pi = 0
  while pi < cfg.allow.count {
    val pat = cfg.allow[pi]
    pi = pi + 1
    var hit = false
    for k in mapKeys(matched) {
      if patternMatches(pat, k) {
        hit = true
      }
    }
    if not hit {
      if hasWildcard(pat) {
        notes.add("the pattern '" + pat + "' matched nothing")
      } else {
        errors.add("'" + pat + "' is not declared by the header")
      }
    }
  }
  // A named (non-wildcard) symbol that was skipped is an error, not a note.
  for n in notes {
    var ni = 0
    while ni < cfg.allow.count {
      if not hasWildcard(cfg.allow[ni]) and Str.contains(n, "'" + cfg.allow[ni] + "'") and Str.startsWith(n, "skipped") {
        errors.add(n)
      }
      ni = ni + 1
    }
  }
  val chunks: List[String] = newList()
  chunks.add("//! Generated by `lyric bindgen` from a C header. Do not edit; regenerate instead.\n")
  chunks.add("@axiom(\"" + cfg.packageName + " bindings conform to the C header they were generated from\")\n")
  chunks.add("@io\n")
  chunks.add("@unsafe_ffi\n")
  chunks.add("package " + cfg.packageName + "\n\n")
  for t in constText {
    chunks.add(t)
  }
  if constText.count > 0 {
    chunks.add("\n")
  }
  for id in em.recordOrder {
    chunks.add(em.recordText[id])
    chunks.add("\n")
  }
  for t in funcText {
    chunks.add(t)
    chunks.add("\n")
  }
  BindgenResult(source = Str.joinList("", chunks), notes = notes, errors = errors)
}
