//! component_glue.l — Lyric.ComponentGlue: the WIT and canonical-ABI layer of
//! the wasm32 `component` shape (docs/35 §7, phase W4).
//!
//! The component shape lifts and lowers every export in Lyric, not in C.  For
//! each `pub func` of a package it can carry, `componentRewriteFile` appends
//! generated Lyric shims to that package's AST before type checking:
//!
//!   * `__cabi_lift_<n>` / `__cabi_load_<n>` read a value of a WIT type from
//!     the flat core-argument stream or from linear memory;
//!   * `__cabi_store_<n>` / `__cabi_free_<n>` write one to memory and release
//!     what a stored value allocated (`cabi_post_*`);
//!   * `__cabi_ex_<i>` runs one export: lift the arguments, call the function,
//!     lower the result.
//!
//! The shims reach linear memory and the argument/result slots only through a
//! handful of C helpers (`lyric_cabi_*`) that `renderCabi` writes into the
//! generated `<stem>.cabi.c`, next to the per-export core wrappers (a wrapper
//! pushes its flat core parameters into the slot array, calls the shim and
//! returns the result slot or the return-area pointer).  Because the type
//! knowledge lives in Lyric, no heap value, by-value record or inline union
//! ever crosses the C boundary, so the wrappers need no knowledge of the native
//! layouts.  `renderWit` writes the matching WIT package.
package Lyric.ComponentGlue

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Char as Ch
import Lyric.Parser

/// WIT's reserved words, which a Lyric name must escape with `%`.
func isWitKeyword(w: in String): Bool {
  w == "use" or w == "type" or w == "func" or w == "u8" or w == "u16" or w == "u32" or w == "u64" or w == "s8" or
    w == "s16" or
    w == "s32" or
    w == "s64" or
    w == "f32" or
    w == "f64" or
    w == "char" or
    w == "record" or
    w == "flags" or
    w == "variant" or
    w == "enum" or
    w == "bool" or
    w == "string" or
    w == "option" or
    w == "result" or
    w == "list" or
    w == "tuple" or
    w == "as" or
    w == "from" or
    w == "static" or
    w == "interface" or
    w == "world" or
    w == "import" or
    w == "export" or
    w == "package" or
    w == "constructor" or
    w == "include" or
    w == "with" or
    w == "resource" or
    w == "own" or
    w == "borrow" or
    w == "future" or
    w == "stream"
}

func isUpperCh(c: in Char): Bool {
  c >= 'A' and c <= 'Z'
}

func isLowerCh(c: in Char): Bool {
  c >= 'a' and c <= 'z'
}

func isAlnumCh(c: in Char): Bool {
  isLowerCh(c) or isUpperCh(c) or isDigitCh(c)
}

func isDigitCh(c: in Char): Bool {
  c >= '0' and c <= '9'
}

func lowerCh(c: in Char): String {
  if isUpperCh(c) {
    Ch.asciiToLower(c).toString()
  } else {
    c.toString()
  }
}

/// A Lyric identifier as a WIT kebab-case name: `customerId`, `customer_id` and
/// `CustomerId` become `customer-id`; an acronym stays one word (`IOError` is
/// `io-error`).  A name that is a WIT keyword is escaped with `%`.
pub func witName(s: in String): String {
  var acc = ""
  var i = 0
  while i < s.length {
    val c = Str.charAtOrReplacement(s, i)
    val prev = if i > 0 { Str.charAtOrReplacement(s, i - 1) } else { ' ' }
    val next = if i + 1 < s.length { Str.charAtOrReplacement(s, i + 1) } else { ' ' }
    if c == '_' or c == '.' or c == '-' {
      if acc.length > 0 and not Str.endsWith(acc, "-") {
        acc = acc + "-"
      }
    } else if isUpperCh(c) {
      val boundary = isLowerCh(prev) or isDigitCh(prev) or (isUpperCh(prev) and isLowerCh(next))
      if boundary and acc.length > 0 and not Str.endsWith(acc, "-") {
        acc = acc + "-"
      }
      acc = acc + lowerCh(c)
    } else {
      acc = acc + c.toString()
    }
    i = i + 1
  }
  if isWitKeyword(acc) {
    "%" + acc
  } else {
    acc
  }
}

// ─── The WIT type model ──────────────────────────────────────────────────────
pub union WitTy {
  case WBool
  case WByte
  case WInt
  case WLong
  case WFloat
  case WDouble
  case WString
  case WUnit
  case WOption(inner: WitTy)
  case WResult(ok: WitTy, err: WitTy)
  case WList(elem: WitTy)
  case WTuple(elems: List[WitTy])
  case WRecord(name: String, fields: List[WitField])
  case WVariant(name: String, cases: List[WitCase])
  case WEnum(name: String, cases: List[String])
}

pub record WitField {
  name: String
  ty: WitTy
}

/// One variant case: its Lyric name, its payload (`WUnit` when none) and how a
/// value is built or matched (`fieldName` is "" for a positional payload).
pub record WitCase {
  name: String
  payload: WitTy
  fieldName: String
}

func isUnit(t: in WitTy): Bool {
  match t {
    case WUnit -> true
    case _ -> false
  }
}

/// The Lyric source spelling of a type.
func lyricTy(t: in WitTy): String {
  match t {
    case WBool -> "Bool"
    case WByte -> "Byte"
    case WInt -> "Int"
    case WLong -> "Long"
    case WFloat -> "Float"
    case WDouble -> "Double"
    case WString -> "String"
    case WUnit -> "Unit"
    case WOption(inner) -> "Option[" + lyricTy(inner) + "]"
    case WResult(ok, err) -> "Result[" + lyricTy(ok) + ", " + lyricTy(err) + "]"
    case WList(elem) -> "List[" + lyricTy(elem) + "]"
    case WTuple(elems) -> {
      val parts: List[String] = newList()
      for e in elems {
        parts.add(lyricTy(e))
      }
      "(" + Str.joinList(", ", parts) + ")"
    }
    case WRecord(name, _) -> name
    case WVariant(name, _) -> name
    case WEnum(name, _) -> name
  }
}

/// A structural key: equal keys are the same WIT type.
func tyKey(t: in WitTy): String {
  match t {
    case WRecord(name, _) -> "R:" + name
    case WVariant(name, _) -> "V:" + name
    case WEnum(name, _) -> "E:" + name
    case WTuple(_) -> "T:" + lyricTy(t)
    case _ -> lyricTy(t)
  }
}

/// A type that is a single canonical-ABI scalar with no generated shim.
func isPrim(t: in WitTy): Bool {
  match t {
    case WBool -> true
    case WByte -> true
    case WInt -> true
    case WLong -> true
    case WFloat -> true
    case WDouble -> true
    case _ -> false
  }
}

// ─── Resolving Lyric types ───────────────────────────────────────────────────
record TypeTable {
  records: List[RecordDecl]
  unions: List[UnionDecl]
  enums: List[EnumDecl]
}

func tableOf(file: in SourceFile): TypeTable {
  val records: List[RecordDecl] = newList()
  val unions: List[UnionDecl] = newList()
  val enums: List[EnumDecl] = newList()
  for it in file.items {
    match it.kind {
      case IRecord(d) -> records.add(d)
      case IUnion(d) -> unions.add(d)
      case IEnum(d) -> enums.add(d)
      case _ -> ()
    }
  }
  TypeTable(records = records, unions = unions, enums = enums)
}

func hasGenerics(g: in Option[GenericParams]): Bool {
  match g {
    case Some(_) -> true
    case None -> false
  }
}

func okTy(t: in WitTy): Result[WitTy, String] {
  Ok(value = t)
}

func failTy(msg: in String): Result[WitTy, String] {
  Err(error = msg)
}

/// `Unit` is a valid result and a valid `result<_, E>` side, but not a parameter,
/// field or element.
func resolveValueTy(te: in TypeExpr, tbl: in TypeTable, depth: in Int): Result[WitTy, String] {
  match resolveTy(te, tbl, depth) {
    case Ok(t) -> {
      if isUnit(t) {
        failTy("a Unit value cannot be a parameter, field or element")
      } else {
        okTy(t)
      }
    }
    case Err(e) -> failTy(e)
  }
}

func resolveTy(te: in TypeExpr, tbl: in TypeTable, depth: in Int): Result[WitTy, String] {
  if depth > 8 {
    return failTy("the type is recursive or nested too deeply")
  }
  match te.kind {
    case TUnit -> okTy(WUnit)
    case TParen(inner) -> resolveTy(inner, tbl, depth)
    case TNullable(inner) -> match resolveValueTy(inner, tbl, depth + 1) {
      case Ok(t) -> okTy(WOption(inner = t))
      case Err(e) -> failTy(e)
    }
    case TTuple(types) -> {
      if types.count < 2 {
        return failTy("a tuple needs at least two elements")
      }
      val elems: List[WitTy] = newList()
      for te2 in types {
        match resolveValueTy(te2, tbl, depth + 1) {
          case Ok(t) -> elems.add(t)
          case Err(e) -> return failTy("tuple element: " + e)
        }
      }
      okTy(WTuple(elems = elems))
    }
    case TRef(path) -> {
      if path.segments.count != 1 {
        return failTy("a qualified type name is not resolvable here")
      }
      resolveName(path.segments[0], tbl, depth)
    }
    case TGenericApp(head, args) -> {
      if head.segments.count != 1 {
        return failTy("a qualified generic type is not resolvable here")
      }
      resolveGeneric(head.segments[0], args, tbl, depth)
    }
    case _ -> failTy("this type has no WIT equivalent")
  }
}

func typeArgAt(args: in List[TypeArg], i: in Int): Option[TypeExpr] {
  if i >= args.count {
    return None
  }
  match args[i] {
    case TAType(t) -> Some(value = t)
    case TAValue(_) -> None
  }
}

func resolveGeneric(head: in String, args: in List[TypeArg], tbl: in TypeTable, depth: in Int): Result[WitTy, String] {
  if head == "Option" or head == "List" {
    match typeArgAt(args, 0) {
      case None -> return failTy(head + " needs a type argument")
      case Some(te) -> match resolveValueTy(te, tbl, depth + 1) {
        case Err(e) -> return failTy(e)
        case Ok(t) -> return okTy(if head == "Option" { WOption(inner = t) } else { WList(elem = t) })
      }
    }
  }
  if head == "Result" {
    match typeArgAt(args, 0) {
      case None -> return failTy("Result needs two type arguments")
      case Some(okTe) -> match typeArgAt(args, 1) {
        case None -> return failTy("Result needs two type arguments")
        case Some(errTe) -> match resolveTy(okTe, tbl, depth + 1) {
          case Err(e) -> return failTy(e)
          case Ok(okT) -> match resolveTy(errTe, tbl, depth + 1) {
            case Err(e) -> return failTy(e)
            case Ok(errT) -> return okTy(WResult(ok = okT, err = errT))
          }
        }
      }
    }
  }
  failTy("the generic type " + head + " has no WIT equivalent")
}

func resolveName(name: in String, tbl: in TypeTable, depth: in Int): Result[WitTy, String] {
  match name {
    case "Int" -> return okTy(WInt)
    case "Long" -> return okTy(WLong)
    case "Bool" -> return okTy(WBool)
    case "Byte" -> return okTy(WByte)
    case "Float" -> return okTy(WFloat)
    case "Double" -> return okTy(WDouble)
    case "String" -> return okTy(WString)
    case "Unit" -> return okTy(WUnit)
    case _ -> ()
  }
  for d in tbl.records {
    if d.name == name {
      return resolveRecord(d, tbl, depth)
    }
  }
  for d in tbl.unions {
    if d.name == name {
      return resolveUnion(d, tbl, depth)
    }
  }
  for d in tbl.enums {
    if d.name == name {
      val names: List[String] = newList()
      for c in d.cases {
        names.add(c.name)
      }
      if names.count > 256 {
        return failTy("enum " + name + " has more than 256 cases")
      }
      return okTy(WEnum(name = name, cases = names))
    }
  }
  failTy("the type " + name + " is not a record, union or enum of this package")
}

func resolveRecord(d: in RecordDecl, tbl: in TypeTable, depth: in Int): Result[WitTy, String] {
  if hasGenerics(d.generics) {
    return failTy("the generic record " + d.name + " has no WIT equivalent")
  }
  val fields: List[WitField] = newList()
  for m in d.members {
    match m {
      case RMField(f) -> match resolveValueTy(f.ty, tbl, depth + 1) {
        case Ok(t) -> fields.add(WitField(name = f.name, ty = t))
        case Err(e) -> return failTy("field " + d.name + "." + f.name + ": " + e)
      }
      case _ -> ()
    }
  }
  if fields.count == 0 {
    return failTy("the record " + d.name + " has no fields")
  }
  okTy(WRecord(name = d.name, fields = fields))
}

func resolveUnion(d: in UnionDecl, tbl: in TypeTable, depth: in Int): Result[WitTy, String] {
  if hasGenerics(d.generics) {
    return failTy("the generic union " + d.name + " has no WIT equivalent")
  }
  val cases: List[WitCase] = newList()
  for c in d.cases {
    if c.fields.count == 0 {
      cases.add(WitCase(name = c.name, payload = WUnit, fieldName = ""))
    } else if c.fields.count == 1 {
      val (te, fname) = match c.fields[0] { case UFNamed(n, ty, _) -> (ty, n); case UFPos(ty, _) -> (ty, "") }
      match resolveValueTy(te, tbl, depth + 1) {
        case Ok(t) -> cases.add(WitCase(name = c.name, payload = t, fieldName = fname))
        case Err(e) -> return failTy("case " + d.name + "." + c.name + ": " + e)
      }
    } else {
      return failTy("case " + d.name + "." + c.name + " has several fields; a WIT variant case carries one payload")
    }
  }
  if cases.count == 0 or cases.count > 256 {
    return failTy("the union " + d.name + " must have between 1 and 256 cases")
  }
  okTy(WVariant(name = d.name, cases = cases))
}

// ─── Canonical ABI layout ────────────────────────────────────────────────────
/// The payload types of a sum type, indexed by discriminant (`WUnit` = none).
func caseTys(t: in WitTy): List[WitTy] {
  val r: List[WitTy] = newList()
  match t {
    case WOption(inner) -> {
      r.add(WUnit)
      r.add(inner)
    }
    case WResult(ok, err) -> {
      r.add(ok)
      r.add(err)
    }
    case WVariant(_, cases) -> {
      for c in cases {
        r.add(c.payload)
      }
    }
    case _ -> ()
  }
  r
}

func isSum(t: in WitTy): Bool {
  match t {
    case WOption(_) -> true
    case WResult(_, _) -> true
    case WVariant(_, _) -> true
    case _ -> false
  }
}

func alignUp(n: in Int, a: in Int): Int {
  ((n + a - 1) / a) * a
}

func maxInt(a: in Int, b: in Int): Int {
  if a > b {
    a
  } else {
    b
  }
}

/// A tuple's elements as the positional fields its record-shaped layout uses.
func tupleFields(elems: in List[WitTy]): List[WitField] {
  val fields: List[WitField] = newList()
  var i = 0
  while i < elems.count {
    fields.add(WitField(name = "f" + i.toString(), ty = elems[i]))
    i = i + 1
  }
  fields
}

func alignOf(t: in WitTy): Int {
  match t {
    case WBool -> 1
    case WByte -> 1
    case WInt -> 4
    case WLong -> 8
    case WFloat -> 4
    case WDouble -> 8
    case WString -> 4
    case WList(_) -> 4
    case WUnit -> 1
    case WEnum(_, _) -> 1
    case WTuple(elems) -> alignOf(WRecord(name = "tuple", fields = tupleFields(elems)))
    case WRecord(_, fields) -> {
      var a = 1
      for f in fields {
        a = maxInt(a, alignOf(f.ty))
      }
      a
    }
    case _ -> {
      var a = 1
      for c in caseTys(t) {
        a = maxInt(a, alignOf(c))
      }
      a
    }
  }
}

func sizeOf(t: in WitTy): Int {
  match t {
    case WBool -> 1
    case WByte -> 1
    case WInt -> 4
    case WLong -> 8
    case WFloat -> 4
    case WDouble -> 8
    case WString -> 8
    case WList(_) -> 8
    case WUnit -> 0
    case WEnum(_, _) -> 1
    case WTuple(elems) -> sizeOf(WRecord(name = "tuple", fields = tupleFields(elems)))
    case WRecord(_, fields) -> {
      var off = 0
      for f in fields {
        off = alignUp(off, alignOf(f.ty)) + sizeOf(f.ty)
      }
      alignUp(off, alignOf(t))
    }
    case _ -> {
      var payload = 0
      for c in caseTys(t) {
        payload = maxInt(payload, sizeOf(c))
      }
      alignUp(payloadOffset(t) + payload, alignOf(t))
    }
  }
}

/// Where a sum type's payload starts: after the 1-byte discriminant.
func payloadOffset(t: in WitTy): Int {
  alignUp(1, alignOf(t))
}

/// The byte offset of field `i` of a record.
func fieldOffset(fields: in List[WitField], i: in Int): Int {
  var off = 0
  var k = 0
  while k < fields.count {
    off = alignUp(off, alignOf(fields[k].ty))
    if k == i {
      return off
    }
    off = off + sizeOf(fields[k].ty)
    k = k + 1
  }
  off
}

/// The core value a flat slot of two cases shares (the canonical `join`).
func joinKind(a: in String, b: in String): String {
  if a == b {
    return a
  }
  if (a == "i32" or a == "f32") and (b == "i32" or b == "f32") {
    return "i32"
  }
  "i64"
}

func flatOf(t: in WitTy): List[String] {
  val r: List[String] = newList()
  match t {
    case WBool -> r.add("i32")
    case WByte -> r.add("i32")
    case WInt -> r.add("i32")
    case WEnum(_, _) -> r.add("i32")
    case WLong -> r.add("i64")
    case WFloat -> r.add("f32")
    case WDouble -> r.add("f64")
    case WUnit -> ()
    case WString -> {
      r.add("i32")
      r.add("i32")
    }
    case WList(_) -> {
      r.add("i32")
      r.add("i32")
    }
    case WTuple(elems) -> {
      for e in elems {
        for k in flatOf(e) {
          r.add(k)
        }
      }
    }
    case WRecord(_, fields) -> {
      for f in fields {
        for k in flatOf(f.ty) {
          r.add(k)
        }
      }
    }
    case _ -> {
      r.add("i32")
      for k in joinedPayloadFlat(t) {
        r.add(k)
      }
    }
  }
  r
}

/// The joined flat slots of a sum type's payloads.
func joinedPayloadFlat(t: in WitTy): List[String] {
  val joined: List[String] = newList()
  for c in caseTys(t) {
    val fl = flatOf(c)
    var i = 0
    while i < fl.count {
      if i < joined.count {
        joined[i] = joinKind(joined[i], fl[i])
      } else {
        joined.add(fl[i])
      }
      i = i + 1
    }
  }
  joined
}

/// True when dropping a value of `t` out of memory must free something.
func needsFree(t: in WitTy): Bool {
  match t {
    case WString -> true
    case WList(_) -> true
    case WTuple(elems) -> needsFree(WRecord(name = "tuple", fields = tupleFields(elems)))
    case WRecord(_, fields) -> {
      for f in fields {
        if needsFree(f.ty) {
          return true
        }
      }
      false
    }
    case WOption(_) -> casesNeedFree(t)
    case WResult(_, _) -> casesNeedFree(t)
    case WVariant(_, _) -> casesNeedFree(t)
    case _ -> false
  }
}

func casesNeedFree(t: in WitTy): Bool {
  for c in caseTys(t) {
    if needsFree(c) {
      return true
    }
  }
  false
}

// ─── Shim generation ─────────────────────────────────────────────────────────
record Gen {
  keys: List[String]
  tys: List[WitTy]
  chunks: List[String]
}

func newGen(): Gen {
  val keys: List[String] = newList()
  val tys: List[WitTy] = newList()
  val chunks: List[String] = newList()
  Gen(keys = keys, tys = tys, chunks = chunks)
}

func idStr(i: in Int): String {
  i.toString()
}

/// The shim id of a compound type, generating its shims on first use.
func idOf(g: in Gen, t: in WitTy): Int {
  val key = tyKey(t)
  var i = 0
  while i < g.keys.count {
    if g.keys[i] == key {
      return i
    }
    i = i + 1
  }
  val id = g.keys.count
  g.keys.add(key)
  g.tys.add(t)
  emitType(g, t, id)
  id
}

func liftExpr(g: in Gen, t: in WitTy): String {
  match t {
    case WBool -> "(cabiNextI32() != 0)"
    case WByte -> "cabiNextI32().toByte()"
    case WInt -> "cabiNextI32()"
    case WLong -> "cabiNextI64()"
    case WFloat -> "cabiNextF32()"
    case WDouble -> "cabiNextF64()"
    case WUnit -> "()"
    case _ -> "__cabi_lift_" + idStr(idOf(g, t)) + "()"
  }
}

func loadExpr(g: in Gen, t: in WitTy, ptr: in String): String {
  match t {
    case WBool -> "(cabiLoadU8(" + ptr + ") != 0)"
    case WByte -> "cabiLoadU8(" + ptr + ").toByte()"
    case WInt -> "cabiLoadI32(" + ptr + ")"
    case WLong -> "cabiLoadI64(" + ptr + ")"
    case WFloat -> "cabiLoadF32(" + ptr + ")"
    case WDouble -> "cabiLoadF64(" + ptr + ")"
    case WUnit -> "()"
    case _ -> "__cabi_load_" + idStr(idOf(g, t)) + "(" + ptr + ")"
  }
}

func storeStmt(g: in Gen, t: in WitTy, ptr: in String, v: in String): String {
  match t {
    case WBool -> "cabiStoreU8(" + ptr + ", if " + v + " { 1 } else { 0 })"
    case WByte -> "cabiStoreU8(" + ptr + ", " + v + ".toInt())"
    case WInt -> "cabiStoreI32(" + ptr + ", " + v + ")"
    case WLong -> "cabiStoreI64(" + ptr + ", " + v + ")"
    case WFloat -> "cabiStoreF32(" + ptr + ", " + v + ")"
    case WDouble -> "cabiStoreF64(" + ptr + ", " + v + ")"
    case WUnit -> "()"
    case _ -> "__cabi_store_" + idStr(idOf(g, t)) + "(" + ptr + ", " + v + ")"
  }
}

/// A statement releasing what the value of `t` stored at `ptr` allocated.
func freeStmt(g: in Gen, t: in WitTy, ptr: in String): String {
  if not needsFree(t) {
    return "()"
  }
  "__cabi_free_" + idStr(idOf(g, t)) + "(" + ptr + ")"
}

/// A statement setting the single flat result slot from the value `v` of `t`.
func lowerFlatStmt(g: in Gen, t: in WitTy, v: in String): String {
  match t {
    case WBool -> "cabiSetRetI32(if " + v + " { 1 } else { 0 })"
    case WByte -> "cabiSetRetI32(" + v + ".toInt())"
    case WInt -> "cabiSetRetI32(" + v + ")"
    case WLong -> "cabiSetRetI64(" + v + ")"
    case WFloat -> "cabiSetRetF32(" + v + ")"
    case WDouble -> "cabiSetRetF64(" + v + ")"
    case WUnit -> "()"
    case _ -> "__cabi_lowerflat_" + idStr(idOf(g, t)) + "(" + v + ")"
  }
}

/// The pattern that matches case `i` of the sum type `t`, binding its payload to `x`.
func armPattern(t: in WitTy, i: in Int): String {
  match t {
    case WOption(_) -> if i == 0 { "None" } else { "Some(x)" }
    case WResult(ok, err) -> {
      val unit = if i == 0 { isUnit(ok) } else { isUnit(err) }
      val head = if i == 0 { "Ok" } else { "Err" }
      if unit {
        head + "(_)"
      } else {
        head + "(x)"
      }
    }
    case WVariant(_, cases) -> {
      val c = cases[i]
      if isUnit(c.payload) {
        c.name
      } else {
        c.name + "(x)"
      }
    }
    case _ -> "_"
  }
}

/// The expression building case `i` of `t` around the payload expression `x`.
func armBuild(t: in WitTy, i: in Int, x: in String): String {
  match t {
    case WOption(_) -> if i == 0 { "None" } else { "Some(value = " + x + ")" }
    case WResult(ok, err) -> {
      val unit = if i == 0 { isUnit(ok) } else { isUnit(err) }
      val arg = if unit { "()" } else { x }
      if i == 0 {
        "Ok(value = " + arg + ")"
      } else {
        "Err(error = " + arg + ")"
      }
    }
    case WVariant(_, cases) -> {
      val c = cases[i]
      if isUnit(c.payload) {
        c.name
      } else if c.fieldName.length > 0 {
        c.name + "(" + c.fieldName + " = " + x + ")"
      } else {
        c.name + "(" + x + ")"
      }
    }
    case _ -> ""
  }
}

/// `if d == 0 { .. } else if d == 1 { .. } else { panic }` over `blocks`.
func discChain(blocks: in List[String]): String {
  var s = ""
  var i = 0
  while i < blocks.count {
    s = s + (if i == 0 { "if" } else { " else if" }) + " d == " + idStr(i) + " {\n" + blocks[i] + "\n}"
    i = i + 1
  }
  s + " else {\n  panic(\"invalid canonical ABI discriminant\")\n}"
}

func emitType(g: in Gen, t: in WitTy, id: in Int) {
  val n = idStr(id)
  val lt = lyricTy(t)
  val lines: List[String] = newList()
  match t {
    case WString -> {
      lines.add("func __cabi_lift_" + n + "(): String {")
      lines.add("  val a = cabiNextI32()")
      lines.add("  val b = cabiNextI32()")
      lines.add("  cabiStringLift(a, b)")
      lines.add("}")
      lines.add("func __cabi_load_" + n + "(ptr: Int): String {")
      lines.add("  cabiStringLift(cabiLoadI32(ptr), cabiLoadI32(ptr + 4))")
      lines.add("}")
      lines.add("func __cabi_store_" + n + "(ptr: Int, v: String): Unit {")
      lines.add("  cabiStoreI32(ptr, cabiStringLower(v))")
      lines.add("  cabiStoreI32(ptr + 4, cabiStringByteLen(v))")
      lines.add("}")
      lines.add("func __cabi_free_" + n + "(ptr: Int): Unit {")
      lines.add("  cabiFree(cabiLoadI32(ptr), cabiLoadI32(ptr + 4), 1)")
      lines.add("}")
    }
    case WEnum(name, cases) -> {
      lines.add("func __cabi_tag_" + n + "(v: " + name + "): Int {")
      lines.add("  match v {")
      var i = 0
      while i < cases.count {
        lines.add("    case " + name + "." + cases[i] + " -> " + idStr(i))
        i = i + 1
      }
      lines.add("  }")
      lines.add("}")
      lines.add("func __cabi_from_tag_" + n + "(d: Int): " + name + " {")
      val blocks: List[String] = newList()
      i = 0
      while i < cases.count {
        blocks.add("  " + name + "." + cases[i])
        i = i + 1
      }
      lines.add(discChain(blocks))
      lines.add("}")
      lines.add("func __cabi_lift_" + n + "(): " + name + " {")
      lines.add("  __cabi_from_tag_" + n + "(cabiNextI32())")
      lines.add("}")
      lines.add("func __cabi_load_" + n + "(ptr: Int): " + name + " {")
      lines.add("  __cabi_from_tag_" + n + "(cabiLoadU8(ptr))")
      lines.add("}")
      lines.add("func __cabi_store_" + n + "(ptr: Int, v: " + name + "): Unit {")
      lines.add("  cabiStoreU8(ptr, __cabi_tag_" + n + "(v))")
      lines.add("}")
      lines.add("func __cabi_lowerflat_" + n + "(v: " + name + "): Unit {")
      lines.add("  cabiSetRetI32(__cabi_tag_" + n + "(v))")
      lines.add("}")
    }
    case WTuple(elems) -> {
      val fields = tupleFields(elems)
      lines.add("func __cabi_lift_" + n + "(): " + lt + " {")
      var i = 0
      while i < elems.count {
        lines.add("  val f" + idStr(i) + " = " + liftExpr(g, elems[i]))
        i = i + 1
      }
      val names: List[String] = newList()
      i = 0
      while i < elems.count {
        names.add("f" + idStr(i))
        i = i + 1
      }
      lines.add("  (" + Str.joinList(", ", names) + ")")
      lines.add("}")
      lines.add("func __cabi_load_" + n + "(ptr: Int): " + lt + " {")
      i = 0
      while i < elems.count {
        lines.add("  val f" + idStr(i) + " = " + loadExpr(g, elems[i], "ptr + " + idStr(fieldOffset(fields, i))))
        i = i + 1
      }
      lines.add("  (" + Str.joinList(", ", names) + ")")
      lines.add("}")
      lines.add("func __cabi_store_" + n + "(ptr: Int, v: " + lt + "): Unit {")
      lines.add("  val (" + Str.joinList(", ", names) + ") = v")
      i = 0
      while i < elems.count {
        lines.add("  " + storeStmt(g, elems[i], "ptr + " + idStr(fieldOffset(fields, i)), names[i]))
        i = i + 1
      }
      lines.add("}")
      if needsFree(t) {
        lines.add("func __cabi_free_" + n + "(ptr: Int): Unit {")
        i = 0
        while i < elems.count {
          lines.add("  " + freeStmt(g, elems[i], "ptr + " + idStr(fieldOffset(fields, i))))
          i = i + 1
        }
        lines.add("}")
      }
    }
    case WRecord(name, fields) -> {
      lines.add("func __cabi_lift_" + n + "(): " + name + " {")
      var i = 0
      while i < fields.count {
        lines.add("  val f" + idStr(i) + " = " + liftExpr(g, fields[i].ty))
        i = i + 1
      }
      val args: List[String] = newList()
      i = 0
      while i < fields.count {
        args.add(fields[i].name + " = f" + idStr(i))
        i = i + 1
      }
      lines.add("  " + name + "(" + Str.joinList(", ", args) + ")")
      lines.add("}")
      lines.add("func __cabi_load_" + n + "(ptr: Int): " + name + " {")
      i = 0
      while i < fields.count {
        lines.add("  val f" + idStr(i) + " = " + loadExpr(g, fields[i].ty, "ptr + " + idStr(fieldOffset(fields, i))))
        i = i + 1
      }
      lines.add("  " + name + "(" + Str.joinList(", ", args) + ")")
      lines.add("}")
      lines.add("func __cabi_store_" + n + "(ptr: Int, v: " + name + "): Unit {")
      i = 0
      while i < fields.count {
        lines.add("  " + storeStmt(g, fields[i].ty, "ptr + " + idStr(fieldOffset(fields, i)), "v." + fields[i].name))
        i = i + 1
      }
      lines.add("}")
      if needsFree(t) {
        lines.add("func __cabi_free_" + n + "(ptr: Int): Unit {")
        i = 0
        while i < fields.count {
          lines.add("  " + freeStmt(g, fields[i].ty, "ptr + " + idStr(fieldOffset(fields, i))))
          i = i + 1
        }
        lines.add("}")
      }
      if flatOf(t).count == 1 {
        lines.add("func __cabi_lowerflat_" + n + "(v: " + name + "): Unit {")
        i = 0
        while i < fields.count {
          if flatOf(fields[i].ty).count == 1 {
            lines.add("  " + lowerFlatStmt(g, fields[i].ty, "v." + fields[i].name))
          }
          i = i + 1
        }
        lines.add("}")
      }
    }
    case WList(elem) -> {
      val size = sizeOf(elem)
      val align = alignOf(elem)
      lines.add("func __cabi_loadlist_" + n + "(ptr: Int, n: Int): " + lt + " {")
      lines.add("  val l: " + lt + " = newList()")
      lines.add("  var i = 0")
      lines.add("  while i < n {")
      lines.add("    l.add(" + loadExpr(g, elem, "ptr + i * " + idStr(size)) + ")")
      lines.add("    i = i + 1")
      lines.add("  }")
      lines.add("  if n > 0 {")
      lines.add("    cabiFree(ptr, n * " + idStr(size) + ", " + idStr(align) + ")")
      lines.add("  }")
      lines.add("  l")
      lines.add("}")
      lines.add("func __cabi_lift_" + n + "(): " + lt + " {")
      lines.add("  val a = cabiNextI32()")
      lines.add("  val b = cabiNextI32()")
      lines.add("  __cabi_loadlist_" + n + "(a, b)")
      lines.add("}")
      lines.add("func __cabi_load_" + n + "(ptr: Int): " + lt + " {")
      lines.add("  __cabi_loadlist_" + n + "(cabiLoadI32(ptr), cabiLoadI32(ptr + 4))")
      lines.add("}")
      lines.add("func __cabi_store_" + n + "(ptr: Int, v: " + lt + "): Unit {")
      lines.add("  val n = v.count")
      lines.add("  if n == 0 {")
      lines.add("    cabiStoreI32(ptr, " + idStr(align) + ")")
      lines.add("  } else {")
      lines.add("    val buf = cabiAlloc(n * " + idStr(size) + ", " + idStr(align) + ")")
      lines.add("    var i = 0")
      lines.add("    while i < n {")
      lines.add("      " + storeStmt(g, elem, "buf + i * " + idStr(size), "v[i]"))
      lines.add("      i = i + 1")
      lines.add("    }")
      lines.add("    cabiStoreI32(ptr, buf)")
      lines.add("  }")
      lines.add("  cabiStoreI32(ptr + 4, n)")
      lines.add("}")
      if needsFree(t) {
        lines.add("func __cabi_free_" + n + "(ptr: Int): Unit {")
        lines.add("  val a = cabiLoadI32(ptr)")
        lines.add("  val n = cabiLoadI32(ptr + 4)")
        if needsFree(elem) {
          lines.add("  var i = 0")
          lines.add("  while i < n {")
          lines.add("    " + freeStmt(g, elem, "a + i * " + idStr(size)))
          lines.add("    i = i + 1")
          lines.add("  }")
        }
        lines.add("  if n > 0 {")
        lines.add("    cabiFree(a, n * " + idStr(size) + ", " + idStr(align) + ")")
        lines.add("  }")
        lines.add("}")
      }
    }
    case _ -> emitSum(g, t, id, lines)
  }
  g.chunks.add(Str.joinList("\n", lines))
}

func emitSum(g: in Gen, t: in WitTy, id: in Int, lines: in List[String]): Unit {
  val n = idStr(id)
  val lt = lyricTy(t)
  val tys = caseTys(t)
  val joinedCount = joinedPayloadFlat(t).count
  val off = payloadOffset(t)
  val liftBlocks: List[String] = newList()
  val loadBlocks: List[String] = newList()
  val freeBlocks: List[String] = newList()
  var i = 0
  while i < tys.count {
    val pt = tys[i]
    if isUnit(pt) {
      val build = armBuild(t, i, "()")
      val skip = if joinedCount > 0 { "  cabiSkip(" + idStr(joinedCount) + ")\n" } else { "" }
      liftBlocks.add(skip + "  " + build)
      loadBlocks.add("  " + build)
    } else {
      val skipN = joinedCount - flatOf(pt).count
      val skip = if skipN > 0 { "  cabiSkip(" + idStr(skipN) + ")\n" } else { "" }
      liftBlocks.add("  val x = " + liftExpr(g, pt) + "\n" + skip + "  " + armBuild(t, i, "x"))
      loadBlocks.add("  val x = " + loadExpr(g, pt, "ptr + " + idStr(off)) + "\n  " + armBuild(t, i, "x"))
    }
    freeBlocks.add("  " + freeStmt(g, pt, "ptr + " + idStr(off)))
    i = i + 1
  }
  lines.add("func __cabi_lift_" + n + "(): " + lt + " {")
  lines.add("  val d = cabiNextI32()")
  lines.add(discChain(liftBlocks))
  lines.add("}")
  lines.add("func __cabi_load_" + n + "(ptr: Int): " + lt + " {")
  lines.add("  val d = cabiLoadU8(ptr)")
  lines.add(discChain(loadBlocks))
  lines.add("}")
  lines.add("func __cabi_store_" + n + "(ptr: Int, v: " + lt + "): Unit {")
  lines.add("  match v {")
  i = 0
  while i < tys.count {
    lines.add("    case " + armPattern(t, i) + " -> {")
    lines.add("      cabiStoreU8(ptr, " + idStr(i) + ")")
    if not isUnit(tys[i]) {
      lines.add("      " + storeStmt(g, tys[i], "ptr + " + idStr(off), "x"))
    }
    lines.add("    }")
    i = i + 1
  }
  lines.add("  }")
  lines.add("}")
  if needsFree(t) {
    lines.add("func __cabi_free_" + n + "(ptr: Int): Unit {")
    lines.add("  val d = cabiLoadU8(ptr)")
    lines.add(discChain(freeBlocks))
    lines.add("}")
  }
  if flatOf(t).count == 1 {
    lines.add("func __cabi_lowerflat_" + n + "(v: " + lt + "): Unit {")
    lines.add("  match v {")
    i = 0
    while i < tys.count {
      lines.add("    case " + armPattern(t, i) + " -> cabiSetRetI32(" + idStr(i) + ")")
      i = i + 1
    }
    lines.add("  }")
    lines.add("}")
  }
}

// ─── Exports ─────────────────────────────────────────────────────────────────
/// One lifted export: the Lyric function, its generated shim and its core signature.
pub record CExport {
  pkg: String
  jsName: String
  wasmName: String
  postName: String
  params: List[WitField]
  ret: WitTy
  flat: List[String]
  retKind: String
  /// An `async func`: the generated shim is an async function whose task the C
  /// wrapper drives to completion before returning.
  isAsync: Bool
}

/// An `extern func` marked `@wasmImport("module")`, lowered to a WIT import: the
/// Lyric extern is rewritten to the generated C function `cSym`, which calls the
/// real core import with the canonical flat arguments.
pub record HostImport {
  module: String
  /// The `@wasmImport` module string as written (`npm:node-fetch`, `ui`);
  /// `module` is the WIT interface name it becomes.
  source: String
  name: String
  cSym: String
  params: List[WitField]
  ret: WitTy
}

pub record ComponentPkg {
  pkg: String
  exports: List[CExport]
  defs: List[WitTy]
  notes: List[String]
  imports: List[HostImport]
}

pub record ComponentRewrite {
  file: SourceFile
  info: ComponentPkg
  error: String
}

func pkgNameOf(file: in SourceFile): String {
  Str.joinList(".", file.packageDecl.path.segments)
}

func isPubDecl(d: in FunctionDecl): Bool {
  match d.visibility {
    case Some(VisPub(_)) -> true
    case _ -> false
  }
}

/// The C-extern preamble every shimmed package declares.
func externPreamble(): String {
  val l: List[String] = newList()
  l.add("extern func cabiNextI32(): Int = \"lyric_cabi_next_i32\"")
  l.add("extern func cabiNextI64(): Long = \"lyric_cabi_next_i64\"")
  l.add("extern func cabiNextF32(): Float = \"lyric_cabi_next_f32\"")
  l.add("extern func cabiNextF64(): Double = \"lyric_cabi_next_f64\"")
  l.add("extern func cabiSkip(n: Int): Unit = \"lyric_cabi_skip\"")
  l.add("extern func cabiLoadU8(p: Int): Int = \"lyric_cabi_load_u8\"")
  l.add("extern func cabiLoadI32(p: Int): Int = \"lyric_cabi_load_i32\"")
  l.add("extern func cabiLoadI64(p: Int): Long = \"lyric_cabi_load_i64\"")
  l.add("extern func cabiLoadF32(p: Int): Float = \"lyric_cabi_load_f32\"")
  l.add("extern func cabiLoadF64(p: Int): Double = \"lyric_cabi_load_f64\"")
  l.add("extern func cabiStoreU8(p: Int, v: Int): Unit = \"lyric_cabi_store_u8\"")
  l.add("extern func cabiStoreI32(p: Int, v: Int): Unit = \"lyric_cabi_store_i32\"")
  l.add("extern func cabiStoreI64(p: Int, v: Long): Unit = \"lyric_cabi_store_i64\"")
  l.add("extern func cabiStoreF32(p: Int, v: Float): Unit = \"lyric_cabi_store_f32\"")
  l.add("extern func cabiStoreF64(p: Int, v: Double): Unit = \"lyric_cabi_store_f64\"")
  l.add("extern func cabiStringLift(p: Int, n: Int): String = \"lyric_cabi_string_lift\"")
  l.add("extern func cabiStringLower(s: String): Int = \"lyric_cabi_string_lower\"")
  l.add("extern func cabiStringByteLen(s: String): Int = \"lyric_cabi_string_byte_len\"")
  l.add("extern func cabiAlloc(size: Int, align: Int): Int = \"lyric_cabi_alloc\"")
  l.add("extern func cabiFree(p: Int, size: Int, align: Int): Unit = \"lyric_cabi_free\"")
  l.add("extern func cabiRetArea(size: Int, align: Int): Int = \"lyric_cabi_ret_area\"")
  l.add("extern func cabiSetRetPtr(p: Int): Unit = \"lyric_cabi_set_ret_ptr\"")
  l.add("extern func cabiSetRetI32(v: Int): Unit = \"lyric_cabi_set_ret_i32\"")
  l.add("extern func cabiSetRetI64(v: Long): Unit = \"lyric_cabi_set_ret_i64\"")
  l.add("extern func cabiSetRetF32(v: Float): Unit = \"lyric_cabi_set_ret_f32\"")
  l.add("extern func cabiSetRetF64(v: Double): Unit = \"lyric_cabi_set_ret_f64\"")
  Str.joinList("\n", l)
}

func retKindOf(ret: in WitTy): String {
  val fl = flatOf(ret)
  if fl.count == 0 {
    "none"
  } else if fl.count == 1 {
    fl[0]
  } else {
    "mem"
  }
}

func emitExport(g: in Gen, k: in Int, d: in FunctionDecl, params: in List[WitField], ret: in WitTy): String {
  val lines: List[String] = newList()
  val kn = idStr(k)
  var flatCount = 0
  for p in params {
    flatCount = flatCount + flatOf(p.ty).count
  }
  val spilled = flatCount > 16
  lines.add("pub " + (if d.isAsync { "async " } else { "" }) + "func __cabi_ex_" + kn + "(): Unit {")
  if spilled {
    lines.add("  val base = cabiNextI32()")
    var i = 0
    while i < params.count {
      lines.add("  val a" + idStr(i) + " = " + loadExpr(g, params[i].ty, "base + " + idStr(fieldOffset(params, i))))
      i = i + 1
    }
    var size = 0
    var align = 1
    for p in params {
      size = alignUp(size, alignOf(p.ty)) + sizeOf(p.ty)
      align = maxInt(align, alignOf(p.ty))
    }
    lines.add("  cabiFree(base, " + idStr(alignUp(size, align)) + ", " + idStr(align) + ")")
  } else {
    var i = 0
    while i < params.count {
      lines.add("  val a" + idStr(i) + " = " + liftExpr(g, params[i].ty))
      i = i + 1
    }
  }
  val args: List[String] = newList()
  var ai = 0
  while ai < params.count {
    args.add("a" + idStr(ai))
    ai = ai + 1
  }
  val call = (if d.isAsync { "await " } else { "" }) + d.name + "(" + Str.joinList(", ", args) + ")"
  val kind = retKindOf(ret)
  if kind == "none" {
    lines.add("  " + call)
  } else if kind == "mem" {
    lines.add("  val r = " + call)
    lines.add("  val area = cabiRetArea(" + idStr(sizeOf(ret)) + ", " + idStr(alignOf(ret)) + ")")
    lines.add("  " + storeStmt(g, ret, "area", "r"))
    lines.add("  cabiSetRetPtr(area)")
  } else {
    lines.add("  val r = " + call)
    lines.add("  " + lowerFlatStmt(g, ret, "r"))
  }
  lines.add("}")
  if kind == "mem" {
    lines.add("pub func __cabi_post_" + kn + "(): Unit {")
    lines.add("  val ptr = cabiNextI32()")
    lines.add("  " + freeStmt(g, ret, "ptr"))
    lines.add("}")
  }
  Str.joinList("\n", lines)
}

/// Named WIT types reachable from `t`, dependencies first, each once.
func collectDefs(t: in WitTy, defs: in List[WitTy]): Unit {
  match t {
    case WOption(inner) -> collectDefs(inner, defs)
    case WList(elem) -> collectDefs(elem, defs)
    case WTuple(elems) -> {
      for e in elems {
        collectDefs(e, defs)
      }
    }
    case WResult(ok, err) -> {
      collectDefs(ok, defs)
      collectDefs(err, defs)
    }
    case WRecord(_, fields) -> {
      for f in fields {
        collectDefs(f.ty, defs)
      }
      addDef(t, defs)
    }
    case WVariant(_, cases) -> {
      for c in cases {
        collectDefs(c.payload, defs)
      }
      addDef(t, defs)
    }
    case WEnum(_, _) -> addDef(t, defs)
    case _ -> ()
  }
}

func addDef(t: in WitTy, defs: in List[WitTy]): Unit {
  val key = tyKey(t)
  for d in defs {
    if tyKey(d) == key {
      return
    }
  }
  defs.add(t)
}

/// A name that becomes a WIT identifier: a letter first, then letters, digits and
/// the separators `witName` folds (`.`, `-`, `_`).
func isWitSafeName(s: in String): Bool {
  if s.length == 0 {
    return false
  }
  var i = 0
  while i < s.length {
    val c = Str.charAtOrReplacement(s, i)
    val ok = isUpperCh(c) or isLowerCh(c) or (i > 0 and (isDigitCh(c) or c == '.' or c == '-' or c == '_'))
    if not ok {
      return false
    }
    i = i + 1
  }
  true
}

func sanitizeIdent(s: in String): String {
  var acc = ""
  var i = 0
  while i < s.length {
    val c = Str.charAtOrReplacement(s, i)
    if isUpperCh(c) or isLowerCh(c) or isDigitCh(c) {
      acc = acc + c.toString()
    } else {
      acc = acc + "_"
    }
    i = i + 1
  }
  acc
}

/// The `@wasmImport` module string of `anns`: None when absent, Some("") when
/// the annotation is malformed.
func wasmImportModuleOf(anns: in List[Annotation]): Option[String] {
  match findAnnotation(anns, "wasmImport") {
    case None -> None
    case Some(a) -> match annotationStringArg(a) { case Some(m) -> Some(value = m); case None -> Some(value = "") }
  }
}

func withoutWasmImport(anns: in List[Annotation]): List[Annotation] {
  val r: List[Annotation] = newList()
  for a in anns {
    if not (a.name.segments.count == 1 and a.name.segments[0] == "wasmImport") {
      r.add(a)
    }
  }
  r
}

/// A scalar or `String` host-import type (`Bool` and `Byte` are not carried).
func importTy(te: in TypeExpr, tbl: in TypeTable): Result[WitTy, String] {
  match resolveValueTy(te, tbl, 0) {
    case Err(e) -> failTy(e)
    case Ok(t) -> match t {
      case WInt -> okTy(t)
      case WLong -> okTy(t)
      case WFloat -> okTy(t)
      case WDouble -> okTy(t)
      case WString -> okTy(t)
      case _ -> failTy("a host import parameter or result must be Int, Long, Float, Double or String")
    }
  }
}

/// The WIT interface name a `@wasmImport` module string becomes.  An
/// `npm:<package>` module (docs/35 section 9) is written `npm-<package>`:
/// `@` dropped, every other character that is not a letter or digit (`/`, `.`,
/// `_`, `~`, `-`) a single `-`, so `npm:@aws-sdk/client-s3` is the interface
/// `npm-aws-sdk-client-s3`.  Any other module string is used as written.
func hostModuleName(module: in String): String {
  if not Str.startsWith(module, "npm:") {
    return module
  }
  val pkg = Str.substring(module, 4)
  var acc = "npm"
  var i = 0
  while i < pkg.length {
    val c = Str.charAtOrReplacement(pkg, i)
    if isLowerCh(c) or isUpperCh(c) or isDigitCh(c) {
      acc = acc + "-" + c.toString()
      var j = i + 1
      while j < pkg.length and isAlnumCh(Str.charAtOrReplacement(pkg, j)) {
        acc = acc + Str.charAtOrReplacement(pkg, j).toString()
        j = j + 1
      }
      i = j
    } else {
      i = i + 1
    }
  }
  acc
}

/// The host import an annotated extern declares, or an error.
func hostImportOf(d: in ExternFuncDecl, rawModule: in String, tbl: in TypeTable): Result[HostImport, String] {
  val module = hostModuleName(rawModule)
  if Str.startsWith(rawModule, "npm:") and module == "npm" {
    return Err(error = "@wasmImport on " + d.name + ": '" + rawModule + "' names no NPM package")
  }
  if not isWitSafeName(module) {
    return Err(
      error = "@wasmImport on " + d.name + ": the module name '" + module +
        "' must start with a letter and use only letters, digits, '.', '-' and '_' (it becomes a WIT interface name)"
    )
  }
  if not isWitSafeName(d.symbol) {
    return Err(
      error = "@wasmImport extern func " + d.name + ": the import name '" + d.symbol +
        "' must start with a letter and use only letters, digits, '.', '-' and '_' (it becomes a WIT function name)"
    )
  }
  val params: List[WitField] = newList()
  var width = 0
  for p in d.params {
    match importTy(p.ty, tbl) {
      case Err(e) -> return Err(error = "@wasmImport extern func " + d.name + ", parameter " + p.name + ": " + e)
      case Ok(t) -> {
        params.add(WitField(name = p.name, ty = t))
        width = width + flatOf(t).count
      }
    }
  }
  val ret = match d.ret {
    case None -> WUnit
    case Some(te) -> match resolveTy(te, tbl, 0) {
      case Err(e) -> return Err(error = "@wasmImport extern func " + d.name + ", result: " + e)
      case Ok(t) -> match t {
        case WUnit -> WUnit
        case _ -> match importTy(te, tbl) {
          case Ok(rt) -> rt
          case Err(e) -> return Err(error = "@wasmImport extern func " + d.name + ", result: " + e)
        }
      }
    }
  }
  val retSlot = match ret { case WString -> 1; case _ -> 0 }
  if width + retSlot > 16 {
    return Err(error = "@wasmImport extern func " + d.name + " has more than 16 flat core parameters")
  }
  Ok(
    value = HostImport(
      module = module,
      source = rawModule,
      name = d.symbol,
      cSym = "lyric_host_" + module.length.toString() + "_" + sanitizeIdent(module) + "_" +
        d.symbol.length.toString() +
        "_" +
        sanitizeIdent(d.symbol),
      params = params,
      ret = ret
    )
  )
}

/// Add the generated shims to `file` and describe its exports.  An export the
/// component ABI cannot carry gets a `W0040` note and is left out.
pub func componentRewriteFile(file: in SourceFile): ComponentRewrite {
  val pkg = pkgNameOf(file)
  val tbl = tableOf(file)
  val g = newGen()
  val exports: List[CExport] = newList()
  val defs: List[WitTy] = newList()
  val notes: List[String] = newList()
  val bodies: List[String] = newList()
  val imports: List[HostImport] = newList()
  val baseItems: List[Item] = newList()
  for it in file.items {
    match it.kind {
      case IExternFunc(d) -> {
        match wasmImportModuleOf(it.annotations) {
          case None -> baseItems.add(it)
          case Some(m) -> match hostImportOf(d, m, tbl) {
            case Err(e) -> {
              val info0 = ComponentPkg(pkg = pkg, exports = exports, defs = defs, notes = notes, imports = imports)
              return ComponentRewrite(file = file, info = info0, error = e)
            }
            case Ok(h) -> {
              imports.add(h)
              baseItems.add(
                Item(
                  docComments = it.docComments,
                  annotations = withoutWasmImport(it.annotations),
                  visibility = it.visibility,
                  kind = IExternFunc(
                    decl = ExternFuncDecl(name = d.name, params = d.params, ret = d.ret, symbol = h.cSym, span = d.span)
                  ),
                  span = it.span
                )
              )
            }
          }
        }
      }
      case _ -> baseItems.add(it)
    }
    match it.kind {
      case IFunc(d) -> {
        if isPubDecl(d) and d.name != "main" {
          var why = exportBlocker(d, tbl)
          if why.length == 0 {
            for ex in exports {
              if witName(ex.jsName) == witName(d.name) {
                why = "its WIT name " + witName(d.name) + " is already taken by " + ex.jsName
              }
            }
          }
          if why.length > 0 {
            notes.add("warning[W0040]: pub func " + pkg + "." + d.name + " is not exported to the component: " + why)
          } else {
            val params: List[WitField] = newList()
            for p in d.params {
              match resolveValueTy(p.ty, tbl, 0) {
                case Ok(t) -> params.add(WitField(name = p.name, ty = t))
                case Err(_) -> ()
              }
            }
            val ret = match d.ret {
              case None -> WUnit
              case Some(te) -> match resolveTy(te, tbl, 0) { case Ok(t) -> t; case Err(_) -> WUnit }
            }
            val k = exports.count
            if d.isAsync {
              notes.add(
                "warning[W0041]: pub async func " + pkg + "." + d.name +
                  " is exported as a synchronous call: the component call blocks until the task completes (docs/35 Q-JS-006)"
              )
            }
            bodies.add(emitExport(g, k, d, params, ret))
            val flat: List[String] = newList()
            var total = 0
            for p in params {
              for kind in flatOf(p.ty) {
                flat.add(kind)
                total = total + 1
              }
            }
            val flatParams: List[String] = newList()
            if total > 16 {
              flatParams.add("i32")
            } else {
              for kind in flat {
                flatParams.add(kind)
              }
            }
            for p in params {
              collectDefs(p.ty, defs)
            }
            collectDefs(ret, defs)
            val rk = retKindOf(ret)
            exports.add(
              CExport(
                pkg = pkg,
                jsName = d.name,
                wasmName = pkg + ".__cabi_ex_" + idStr(k),
                postName = if rk == "mem" { pkg + ".__cabi_post_" + idStr(k) } else { "" },
                params = params,
                ret = ret,
                flat = flatParams,
                retKind = rk,
                isAsync = d.isAsync
              )
            )
          }
        }
      }
      case _ -> ()
    }
  }
  val info = ComponentPkg(pkg = pkg, exports = exports, defs = defs, notes = notes, imports = imports)
  if exports.count == 0 and imports.count == 0 {
    return ComponentRewrite(file = file, info = info, error = "")
  }
  if exports.count == 0 {
    val importOnly = SourceFile(
      moduleDoc = file.moduleDoc,
      fileAnnotations = file.fileAnnotations,
      packageDecl = file.packageDecl,
      imports = file.imports,
      items = baseItems,
      span = file.span
    )
    return ComponentRewrite(file = importOnly, info = info, error = "")
  }
  val text = "package " + pkg + "\nimport Std.Collections\n" + externPreamble() + "\n" + Str.joinList("\n", g.chunks) +
    "\n" +
    Str.joinList("\n", bodies) +
    "\n"
  val pr = parse(text)
  var errs = ""
  for dg in pr.diagnostics {
    if errs.length == 0 {
      errs = dg.message
    }
  }
  if errs.length > 0 {
    return ComponentRewrite(file = file, info = info, error = "the generated shims did not parse: " + errs)
  }
  val items: List[Item] = newList()
  for it in baseItems {
    items.add(it)
  }
  for it in pr.file.items {
    items.add(it)
  }
  val imports: List[ImportDecl] = newList()
  for im in file.imports {
    imports.add(im)
  }
  for im in pr.file.imports {
    var dup = false
    for have in file.imports {
      if Str.joinList(".", have.path.segments) == Str.joinList(".", im.path.segments) and have.asAlias == im.asAlias {
        dup = true
      }
    }
    if not dup {
      imports.add(im)
    }
  }
  val merged = SourceFile(
    moduleDoc = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = imports,
    items = items,
    span = file.span
  )
  ComponentRewrite(file = merged, info = info, error = "")
}

/// Why `d` cannot be a component export, or "".
func exportBlocker(d: in FunctionDecl, tbl: in TypeTable): String {
  if hasGenerics(d.generics) {
    return "it is generic"
  }
  val wn = witName(d.name)
  for r in tbl.records {
    if witName(r.name) == wn {
      return "its WIT name collides with the record " + r.name + " (functions and types share one WIT namespace)"
    }
  }
  for u in tbl.unions {
    if witName(u.name) == wn {
      return "its WIT name collides with the union " + u.name + " (functions and types share one WIT namespace)"
    }
  }
  for en in tbl.enums {
    if witName(en.name) == wn {
      return "its WIT name collides with the enum " + en.name + " (functions and types share one WIT namespace)"
    }
  }
  for p in d.params {
    match p.mode {
      case PMIn -> ()
      case _ -> return "parameter '" + p.name + "' is out/inout"
    }
    match resolveValueTy(p.ty, tbl, 0) {
      case Ok(_) -> ()
      case Err(e) -> return "parameter '" + p.name + "': " + e
    }
  }
  match d.ret {
    case None -> ()
    case Some(te) -> match resolveTy(te, tbl, 0) { case Ok(_) -> (); case Err(e) -> return "its result: " + e }
  }
  ""
}

// ─── WIT ─────────────────────────────────────────────────────────────────────
/// The host imports of `pkgs` with a repeated (module, name) kept once: two
/// externs binding the same host function share one WIT function and one C
/// wrapper.
/// Identity of a host function: the literal (module, name) pair, length-prefixed
/// so no two distinct pairs share a key.
func importKey(h: in HostImport): String {
  h.module.length.toString() + ":" + h.module + h.name
}

func uniqueImports(pkgs: in List[ComponentPkg]): List[HostImport] {
  val r: List[HostImport] = newList()
  for p in pkgs {
    for h in p.imports {
      var seen = false
      for q in r {
        if importKey(q) == importKey(h) {
          seen = true
        }
      }
      if not seen {
        r.add(h)
      }
    }
  }
  r
}

func importSignature(h: in HostImport): String {
  val ps: List[String] = newList()
  for f in h.params {
    ps.add(lyricTy(f.ty))
  }
  "(" + Str.joinList(", ", ps) + "): " + lyricTy(h.ret)
}

/// A message when two externs bind the same host function (module and name)
/// with different signatures, or "" when the imports are consistent.
pub func importConflict(pkgs: in List[ComponentPkg]): String {
  val seen: List[HostImport] = newList()
  for p in pkgs {
    for h in p.imports {
      for q in seen {
        if importKey(q) == importKey(h) and importSignature(q) != importSignature(h) {
          return "the host import " + h.module + "." + h.name + " is declared with two signatures: " + importSignature(q) +
            " and " +
            importSignature(h)
        }
      }
      seen.add(h)
    }
  }
  val uniq = uniqueImports(pkgs)
  var i = 0
  while i < uniq.count {
    var j = i + 1
    while j < uniq.count {
      val a = uniq[i]
      val b = uniq[j]
      if a.module != b.module and witName(a.module) == witName(b.module) {
        return "the host import modules '" + a.module + "' and '" + b.module + "' both become the WIT interface " +
          witName(a.module) +
          "; rename one"
      }
      if a.module == b.module and a.name != b.name and witName(a.name) == witName(b.name) {
        return "the host imports " + a.module + "." + a.name + " and " + b.module + "." + b.name +
          " both become the WIT function " +
          witName(a.name) +
          "; rename one"
      }
      j = j + 1
    }
    for p in exportingPkgs(pkgs) {
      if witName(p.pkg) == witName(uniq[i].module) {
        return "the host import module '" + uniq[i].module + "' has the same WIT name as the exported package " + p.pkg +
          "; rename one"
      }
    }
    i = i + 1
  }
  ""
}

/// The distinct `@wasmImport` modules of `pkgs`, in first-seen order.
func importModules(pkgs: in List[ComponentPkg]): List[String] {
  val r: List[String] = newList()
  for p in pkgs {
    for h in p.imports {
      var seen = false
      for q in r {
        if q == h.module {
          seen = true
        }
      }
      if not seen {
        r.add(h.module)
      }
    }
  }
  r
}

func witRef(t: in WitTy): String {
  match t {
    case WBool -> "bool"
    case WByte -> "u8"
    case WInt -> "s32"
    case WLong -> "s64"
    case WFloat -> "f32"
    case WDouble -> "f64"
    case WString -> "string"
    case WUnit -> "_"
    case WOption(inner) -> "option<" + witRef(inner) + ">"
    case WList(elem) -> "list<" + witRef(elem) + ">"
    case WTuple(elems) -> {
      val parts: List[String] = newList()
      for e in elems {
        parts.add(witRef(e))
      }
      "tuple<" + Str.joinList(", ", parts) + ">"
    }
    case WResult(ok, err) -> {
      if isUnit(ok) and isUnit(err) {
        "result"
      } else if isUnit(err) {
        "result<" + witRef(ok) + ">"
      } else {
        "result<" + witRef(ok) + ", " + witRef(err) + ">"
      }
    }
    case WRecord(name, _) -> witName(name)
    case WVariant(name, _) -> witName(name)
    case WEnum(name, _) -> witName(name)
  }
}

func witDef(t: in WitTy): String {
  match t {
    case WRecord(name, fields) -> {
      val fs: List[String] = newList()
      for f in fields {
        fs.add("    " + witName(f.name) + ": " + witRef(f.ty))
      }
      "  record " + witName(name) + " {\n" + Str.joinList(",\n", fs) + "\n  }"
    }
    case WVariant(name, cases) -> {
      val cs: List[String] = newList()
      for c in cases {
        if isUnit(c.payload) {
          cs.add("    " + witName(c.name))
        } else {
          cs.add("    " + witName(c.name) + "(" + witRef(c.payload) + ")")
        }
      }
      "  variant " + witName(name) + " {\n" + Str.joinList(",\n", cs) + "\n  }"
    }
    case WEnum(name, cases) -> {
      val cs: List[String] = newList()
      for c in cases {
        cs.add("    " + witName(c))
      }
      "  enum " + witName(name) + " {\n" + Str.joinList(",\n", cs) + "\n  }"
    }
    case _ -> ""
  }
}

func exportingPkgs(pkgs: in List[ComponentPkg]): List[ComponentPkg] {
  val r: List[ComponentPkg] = newList()
  for p in pkgs {
    if p.exports.count > 0 {
      r.add(p)
    }
  }
  r
}

func firstPkgName(pkgs: in List[ComponentPkg]): String {
  val ex = exportingPkgs(pkgs)
  if ex.count > 0 {
    ex[0].pkg
  } else {
    "program"
  }
}

/// `lyric:<package>@<version>`, named for the first exporting Lyric package.
pub func witPackageName(pkgs: in List[ComponentPkg], version: in String): String {
  "lyric:" + witName(firstPkgName(pkgs)) + "@" + version
}

/// The world name: the `[wasm] world` override, else `<package>-world`.
pub func witWorldName(pkgs: in List[ComponentPkg], world: in String): String {
  if world.length > 0 {
    return world
  }
  witName(firstPkgName(pkgs)) + "-world"
}

/// The WIT document for the exporting packages (docs/35 §7.2).
pub func renderWit(pkgs: in List[ComponentPkg], version: in String, world: in String): String {
  val ex = exportingPkgs(pkgs)
  val parts: List[String] = newList()
  parts.add("package " + witPackageName(pkgs, version) + ";\n")
  for m in importModules(pkgs) {
    val ilines: List[String] = newList()
    for h in uniqueImports(pkgs) {
      if h.module == m {
        val ps: List[String] = newList()
        for f in h.params {
          ps.add(witName(f.name) + ": " + witRef(f.ty))
        }
        val tail = if isUnit(h.ret) { "" } else { " -> " + witRef(h.ret) }
        ilines.add("  " + witName(h.name) + ": func(" + Str.joinList(", ", ps) + ")" + tail + ";")
      }
    }
    parts.add("interface " + witName(m) + " {\n" + Str.joinList("\n", ilines) + "\n}\n")
  }
  for p in ex {
    val lines: List[String] = newList()
    for d in p.defs {
      lines.add(witDef(d))
    }
    for e in p.exports {
      val ps: List[String] = newList()
      for f in e.params {
        ps.add(witName(f.name) + ": " + witRef(f.ty))
      }
      val tail = if isUnit(e.ret) { "" } else { " -> " + witRef(e.ret) }
      lines.add("  " + witName(e.jsName) + ": func(" + Str.joinList(", ", ps) + ")" + tail + ";")
    }
    parts.add("interface " + witName(p.pkg) + " {\n" + Str.joinList("\n", lines) + "\n}\n")
  }
  val exportLines: List[String] = newList()
  for m in importModules(pkgs) {
    exportLines.add("  import " + witName(m) + ";")
  }
  for p in ex {
    exportLines.add("  export " + witName(p.pkg) + ";")
  }
  parts.add("world " + witWorldName(pkgs, world) + " {\n" + Str.joinList("\n", exportLines) + "\n}\n")
  Str.joinList("\n", parts)
}

// ─── C wrappers ──────────────────────────────────────────────────────────────
func cType(kind: in String): String {
  match kind {
    case "i64" -> "int64_t"
    case "f32" -> "float"
    case "f64" -> "double"
    case _ -> "int32_t"
  }
}

/// The C statement pushing core parameter `a` of `kind` into the slot array.
func pushStmt(kind: in String, a: in String): String {
  match kind {
    case "i64" -> "cabi_push((uint64_t)" + a + ");"
    case "f32" -> "{ uint32_t b; memcpy(&b, &" + a + ", 4); cabi_push(b); }"
    case "f64" -> "{ uint64_t b; memcpy(&b, &" + a + ", 8); cabi_push(b); }"
    case _ -> "cabi_push((uint32_t)" + a + ");"
  }
}

/// The core export name: `lyric:<package>/<interface>@<version>#<func>`.
func coreExportName(pkgs: in List[ComponentPkg], e: in CExport, version: in String): String {
  "lyric:" + witName(firstPkgName(pkgs)) + "/" + witName(e.pkg) + "@" + version + "#" + witName(e.jsName)
}

func cabiRuntime(hasAsync: in Bool): String {
  val l: List[String] = newList()
  l.add("/* Generated by `lyric build --shape component` (docs/35 W4). Do not edit. */")
  l.add("#include <stdint.h>")
  l.add("#include <stdlib.h>")
  l.add("#include <string.h>")
  l.add("")
  l.add("extern void* lyric_wasm_string_new(const uint8_t*, int32_t);")
  l.add("extern int32_t lyric_wasm_string_len(void*);")
  l.add("extern const uint8_t* lyric_wasm_string_data(void*);")
  l.add("")
  if hasAsync {
    l.add("#include <time.h>")
    l.add("extern int64_t lyric_wasm_poll(void);")
    l.add("extern int32_t lyric_task_is_complete(void*);")
    l.add("extern void lyric_wasm_release(void*);")
    l.add("")
  }
  l.add("static uint64_t cabi_slots[64];")
  l.add("static int32_t cabi_n, cabi_cursor;")
  l.add("static uint64_t cabi_ret_bits;")
  l.add("static int32_t cabi_ret_ptr;")
  l.add("static void cabi_reset(void) { cabi_n = 0; cabi_cursor = 0; }")
  l.add("static void cabi_push(uint64_t v) { cabi_slots[cabi_n++] = v; }")
  l.add("#define CABI_ADDR(p) ((void*)(uintptr_t)(uint32_t)(p))")
  l.add("int32_t lyric_cabi_next_i32(void) { return (int32_t)(uint32_t)cabi_slots[cabi_cursor++]; }")
  l.add("int64_t lyric_cabi_next_i64(void) { return (int64_t)cabi_slots[cabi_cursor++]; }")
  l.add(
    "float lyric_cabi_next_f32(void) { uint32_t b = (uint32_t)cabi_slots[cabi_cursor++]; float f; memcpy(&f, &b, 4); return f; }"
  )
  l.add(
    "double lyric_cabi_next_f64(void) { uint64_t b = cabi_slots[cabi_cursor++]; double d; memcpy(&d, &b, 8); return d; }"
  )
  l.add("void lyric_cabi_skip(int32_t n) { cabi_cursor += n; }")
  l.add("int32_t lyric_cabi_load_u8(int32_t p) { return *(uint8_t*)CABI_ADDR(p); }")
  l.add("int32_t lyric_cabi_load_i32(int32_t p) { int32_t v; memcpy(&v, CABI_ADDR(p), 4); return v; }")
  l.add("int64_t lyric_cabi_load_i64(int32_t p) { int64_t v; memcpy(&v, CABI_ADDR(p), 8); return v; }")
  l.add("float lyric_cabi_load_f32(int32_t p) { float v; memcpy(&v, CABI_ADDR(p), 4); return v; }")
  l.add("double lyric_cabi_load_f64(int32_t p) { double v; memcpy(&v, CABI_ADDR(p), 8); return v; }")
  l.add("void lyric_cabi_store_u8(int32_t p, int32_t v) { *(uint8_t*)CABI_ADDR(p) = (uint8_t)v; }")
  l.add("void lyric_cabi_store_i32(int32_t p, int32_t v) { memcpy(CABI_ADDR(p), &v, 4); }")
  l.add("void lyric_cabi_store_i64(int32_t p, int64_t v) { memcpy(CABI_ADDR(p), &v, 8); }")
  l.add("void lyric_cabi_store_f32(int32_t p, float v) { memcpy(CABI_ADDR(p), &v, 4); }")
  l.add("void lyric_cabi_store_f64(int32_t p, double v) { memcpy(CABI_ADDR(p), &v, 8); }")
  l.add("void* lyric_cabi_string_lift(int32_t p, int32_t n) {")
  l.add("  void* s = lyric_wasm_string_new((const uint8_t*)CABI_ADDR(p), n);")
  l.add("  if (n > 0) free(CABI_ADDR(p));")
  l.add("  return s;")
  l.add("}")
  l.add("int32_t lyric_cabi_string_lower(void* s) {")
  l.add("  int32_t n = lyric_wasm_string_len(s);")
  l.add("  if (n == 0) return 1;")
  l.add("  uint8_t* b = (uint8_t*)malloc((size_t)n);")
  l.add("  memcpy(b, lyric_wasm_string_data(s), (size_t)n);")
  l.add("  return (int32_t)(uintptr_t)b;")
  l.add("}")
  l.add("int32_t lyric_cabi_string_byte_len(void* s) { return lyric_wasm_string_len(s); }")
  l.add(
    "int32_t lyric_cabi_alloc(int32_t size, int32_t align) { (void)align; return (int32_t)(uintptr_t)malloc((size_t)size); }"
  )
  l.add(
    "void lyric_cabi_free(int32_t p, int32_t size, int32_t align) { (void)align; if (size > 0 && p != 0) free(CABI_ADDR(p)); }"
  )
  l.add(
    "int32_t lyric_cabi_ret_area(int32_t size, int32_t align) { (void)align; return (int32_t)(uintptr_t)calloc(1, size > 0 ? (size_t)size : 1); }"
  )
  l.add("void lyric_cabi_set_ret_ptr(int32_t p) { cabi_ret_ptr = p; }")
  l.add("void lyric_cabi_set_ret_i32(int32_t v) { cabi_ret_bits = (uint32_t)v; }")
  l.add("void lyric_cabi_set_ret_i64(int64_t v) { cabi_ret_bits = (uint64_t)v; }")
  l.add("void lyric_cabi_set_ret_f32(float v) { uint32_t b; memcpy(&b, &v, 4); cabi_ret_bits = b; }")
  l.add("void lyric_cabi_set_ret_f64(double v) { uint64_t b; memcpy(&b, &v, 8); cabi_ret_bits = b; }")
  if hasAsync {
    l.add("/* Run the scheduler until `task` completes, sleeping out the timers a")
    l.add("   suspended task waits on.  A component export is a synchronous call, so an")
    l.add("   async export blocks its caller for the task's duration (docs/35 Q-JS-006). */")
    l.add("static void cabi_drive(void* task) {")
    l.add("  for (;;) {")
    l.add("    int64_t wait = lyric_wasm_poll();")
    l.add("    if (lyric_task_is_complete(task)) return;")
    l.add("    if (wait < 0) __builtin_trap(); /* nothing can ever complete it */")
    l.add("    if (wait > 0) {")
    l.add("      struct timespec ts;")
    l.add("      ts.tv_sec = (time_t)(wait / 1000);")
    l.add("      ts.tv_nsec = (long)((wait % 1000) * 1000000);")
    l.add("      nanosleep(&ts, 0);")
    l.add("    }")
    l.add("  }")
    l.add("}")
  }
  l.add("")
  l.add("__attribute__((export_name(\"cabi_realloc\")))")
  l.add("void* cabi_realloc(void* old, size_t old_size, size_t align, size_t new_size) {")
  l.add("  if (new_size == 0) return (void*)align;")
  l.add("  if (old && old_size > 0) return realloc(old, new_size);")
  l.add("  return malloc(new_size);")
  l.add("}")
  l.add("")
  Str.joinList("\n", l)
}

func cTypeOfTy(t: in WitTy): String {
  match t {
    case WInt -> "int32_t"
    case WLong -> "int64_t"
    case WFloat -> "float"
    case WDouble -> "double"
    case WString -> "void*"
    case _ -> "void"
  }
}

/// The C function a Lyric `@wasmImport` extern calls: it lowers the arguments to
/// the canonical flat form (a string is borrowed as pointer and length), calls the
/// real core import, and lifts the result (a string comes back through a return
/// area the host fills using `cabi_realloc`).
/// The WIT interface id a host import module is imported under:
/// `lyric:<first package>/<module>@<version>`.
func importInterfaceId(pkgs: in List[ComponentPkg], module: in String, version: in String): String {
  "lyric:" + witName(firstPkgName(pkgs)) + "/" + witName(module) + "@" + version
}

/// The `jco transpile --map` arguments that satisfy every host import of `pkgs`
/// with a JavaScript module: an `npm:<package>` import with the package itself,
/// any other with `../<module>.js`, a file the caller writes beside the
/// component (the bindings directory is a sibling of it).
pub func jcoMapArgs(pkgs: in List[ComponentPkg], version: in String): List[String] {
  val args: List[String] = newList()
  val seen: Map[String, Bool] = newMap()
  for h in uniqueImports(pkgs) {
    val id = importInterfaceId(pkgs, h.module, version)
    if not seen.containsKey(id) {
      seen.add(id, true)
      val target = if Str.startsWith(h.source, "npm:") { Str.substring(h.source, 4) } else { "../" + h.source + ".js" }
      args.add("--map")
      args.add(id + "=" + target)
    }
  }
  args
}

func renderImportWrapper(pkgs: in List[ComponentPkg], h: in HostImport, i: in Int, version: in String): String {
  val l: List[String] = newList()
  val id = importInterfaceId(pkgs, h.module, version)
  val rawName = "lyric_rawimport" + idStr(i)
  val rawParams: List[String] = newList()
  val ownParams: List[String] = newList()
  val callArgs: List[String] = newList()
  var pi = 0
  for f in h.params {
    val a = "a" + idStr(pi)
    ownParams.add(cTypeOfTy(f.ty) + " " + a)
    match f.ty {
      case WString -> {
        rawParams.add("int32_t")
        rawParams.add("int32_t")
        callArgs.add("(int32_t)(uintptr_t)lyric_wasm_string_data(" + a + ")")
        callArgs.add("lyric_wasm_string_len(" + a + ")")
      }
      case t -> {
        rawParams.add(cTypeOfTy(t))
        callArgs.add(a)
      }
    }
    pi = pi + 1
  }
  val isStr = match h.ret { case WString -> true; case _ -> false }
  if isStr {
    rawParams.add("int32_t")
  }
  val rawRet = if isStr { "void" } else { cTypeOfTy(h.ret) }
  l.add("__attribute__((import_module(\"" + id + "\"), import_name(\"" + witName(h.name) + "\")))")
  l.add(
    "extern " + rawRet + " " + rawName + "(" +
      (if rawParams.count == 0 { "void" } else { Str.joinList(", ", rawParams) }) +
      ");"
  )
  val retC = cTypeOfTy(h.ret)
  l.add(retC + " " + h.cSym + "(" + (if ownParams.count == 0 { "void" } else { Str.joinList(", ", ownParams) }) + ") {")
  if isStr {
    callArgs.add("(int32_t)(uintptr_t)ret")
    l.add("  int32_t ret[2] = {0, 0};")
    l.add("  " + rawName + "(" + Str.joinList(", ", callArgs) + ");")
    l.add("  return lyric_cabi_string_lift(ret[0], ret[1]);")
  } else if isUnit(h.ret) {
    l.add("  " + rawName + "(" + Str.joinList(", ", callArgs) + ");")
  } else {
    l.add("  return " + rawName + "(" + Str.joinList(", ", callArgs) + ");")
  }
  l.add("}")
  l.add("")
  Str.joinList("\n", l)
}

/// The C file for the exporting packages (see the module header).
/// Whether any exported function of `pkgs` is an `async func`.
pub func componentHasAsync(pkgs: in List[ComponentPkg]): Bool {
  for p in pkgs {
    for e in p.exports {
      if e.isAsync {
        return true
      }
    }
  }
  false
}

pub func renderCabi(pkgs: in List[ComponentPkg], version: in String): String {
  val buf: List[String] = newList()
  buf.add(cabiRuntime(componentHasAsync(pkgs)))
  var hi = 0
  for h in uniqueImports(pkgs) {
    buf.add(renderImportWrapper(pkgs, h, hi, version))
    hi = hi + 1
  }
  var n = 0
  for p in exportingPkgs(pkgs) {
    for e in p.exports {
      val sh = "lyric_shim" + idStr(n)
      buf.add("extern " + (if e.isAsync { "void*" } else { "void" }) + " " + sh + "(void) __asm__(\"" + e.wasmName + "\");")
      val exportName = coreExportName(pkgs, e, version)
      val ps: List[String] = newList()
      var i = 0
      while i < e.flat.count {
        ps.add(cType(e.flat[i]) + " a" + idStr(i))
        i = i + 1
      }
      val retC = match e.retKind { case "none" -> "void"; case "mem" -> "int32_t"; case k -> cType(k) }
      buf.add("__attribute__((export_name(\"" + exportName + "\")))")
      buf.add(retC + " lyric_wrap" + idStr(n) + "(" + (if ps.count == 0 { "void" } else { Str.joinList(", ", ps) }) + ") {")
      buf.add("  cabi_reset();")
      i = 0
      while i < e.flat.count {
        buf.add("  " + pushStmt(e.flat[i], "a" + idStr(i)))
        i = i + 1
      }
      if e.isAsync {
        buf.add("  { void* task = " + sh + "(); cabi_drive(task); lyric_wasm_release(task); }")
      } else {
        buf.add("  " + sh + "();")
      }
      match e.retKind {
        case "none" -> ()
        case "mem" -> buf.add("  return cabi_ret_ptr;")
        case "i64" -> buf.add("  return (int64_t)cabi_ret_bits;")
        case "f32" -> buf.add("  { uint32_t b = (uint32_t)cabi_ret_bits; float f; memcpy(&f, &b, 4); return f; }")
        case "f64" -> buf.add("  { double d; memcpy(&d, &cabi_ret_bits, 8); return d; }")
        case _ -> buf.add("  return (int32_t)(uint32_t)cabi_ret_bits;")
      }
      buf.add("}")
      if e.postName.length > 0 {
        buf.add("extern void lyric_postshim" + idStr(n) + "(void) __asm__(\"" + e.postName + "\");")
        buf.add("__attribute__((export_name(\"cabi_post_" + exportName + "\")))")
        buf.add("void lyric_post" + idStr(n) + "(int32_t p) {")
        buf.add("  cabi_reset();")
        buf.add("  cabi_push((uint32_t)p);")
        buf.add("  lyric_postshim" + idStr(n) + "();")
        buf.add("  free(CABI_ADDR(p));")
        buf.add("}")
      }
      buf.add("")
      n = n + 1
    }
  }
  Str.joinList("\n", buf) + "\n"
}
