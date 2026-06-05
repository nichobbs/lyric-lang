// fmt/fmt_core.l — helpers + line model + type/pattern/literal/expr/stmt
// printers for the self-hosted Lyric formatter (Phase 5 §M5.3).
//
// Mirrors the F# bootstrap formatter at compiler/src/Lyric.Cli/Fmt.fs.
// The split across fmt_core.l / fmt_items.l / fmt.l is for file-size
// hygiene only; everything is a single `Lyric.Fmt` package and all
// helpers participate in cross-file mutual recursion.
//
// Field-name conventions mirror parser_ast.l (e.g. `ret` not `Return`,
// `iface` not `Interface`).
package Lyric.Fmt

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Char as Ch
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Document / line model.  A `Doc` is a list of source lines (no
// trailing newline per line; blank lines are the empty string).
// ─────────────────────────────────────────────────────────────────────────────

/// Indent every non-blank line by `n` spaces.
pub func indentDoc(n: in Int, doc: in List[String]): List[String] {
  val prefix = Str.repeat(" ", n)
  val acc: List[String] = newList()
  var i = 0
  while i < doc.count {
    val line = doc[i]
    if line == "" {
      acc.add("")
    } else {
      acc.add(prefix + line)
    }
    i = i + 1
  }
  acc
}

/// Concatenate two `Doc`s.
pub func concatDoc(a: in List[String], b: in List[String]): List[String] {
  val acc: List[String] = newList()
  var i = 0
  while i < a.count {
    acc.add(a[i])
    i = i + 1
  }
  i = 0
  while i < b.count {
    acc.add(b[i])
    i = i + 1
  }
  acc
}

/// Three-way concatenation; common enough to be worth the helper.
pub func concatDoc3(a: in List[String], b: in List[String], c: in List[String]): List[String] {
  concatDoc(concatDoc(a, b), c)
}

pub func singleLineDoc(s: in String): List[String] {
  val xs: List[String] = newList()
  xs.add(s)
  xs
}

pub func emptyDoc(): List[String] {
  val xs: List[String] = newList()
  xs
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Operator tables — precedence + spelling.  Mirrors Fmt.fs.
// ─────────────────────────────────────────────────────────────────────────────

@pure
pub func binPrec(op: in BinOp): Int {
  match op {
    case BImplies  -> 1
    case BOr       -> 2
    case BXor      -> 2
    case BAnd      -> 3
    case BEq       -> 4
    case BNeq      -> 4
    case BLt       -> 4
    case BLte      -> 4
    case BGt       -> 4
    case BGte      -> 4
    case BCoalesce -> 5
    case BAdd      -> 6
    case BSub      -> 6
    case BMul      -> 7
    case BDiv      -> 7
    case BMod      -> 7
  }
}

@pure
pub func binStr(op: in BinOp): String {
  match op {
    case BImplies  -> "implies"
    case BOr       -> "or"
    case BXor      -> "xor"
    case BAnd      -> "and"
    case BEq       -> "=="
    case BNeq      -> "!="
    case BLt       -> "<"
    case BLte      -> "<="
    case BGt       -> ">"
    case BGte      -> ">="
    case BCoalesce -> "??"
    case BAdd      -> "+"
    case BSub      -> "-"
    case BMul      -> "*"
    case BDiv      -> "/"
    case BMod      -> "%"
  }
}

@pure
pub func assignStr(op: in AssignOp): String {
  match op {
    case AssEq      -> "="
    case AssPlus    -> "+="
    case AssMinus   -> "-="
    case AssStar    -> "*="
    case AssSlash   -> "/="
    case AssPercent -> "%="
  }
}

@pure
pub func intSufStr(s: in IntSuffix): String {
  match s {
    case I8           -> "i8"
    case I16          -> "i16"
    case I32          -> "i32"
    case I64          -> "i64"
    case U8           -> "u8"
    case U16          -> "u16"
    case U32          -> "u32"
    case U64          -> "u64"
    case NoIntSuffix  -> ""
  }
}

@pure
pub func floatSufStr(s: in FloatSuffix): String {
  match s {
    case F32           -> "f32"
    case F64           -> "f64"
    case NoFloatSuffix -> ""
  }
}

@pure
pub func prefixStr(op: in PrefixOp): String {
  match op {
    case PreNeg -> "-"
    case PreNot -> "not "
    case PreRef -> "&"
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Char + string escape helpers.  Mirrors `escapeStr` in Fmt.fs.
// ─────────────────────────────────────────────────────────────────────────────

@pure
func charToStr(c: in Char): String {
  "" + c
}

@pure
func hexDigit(n: in Int): Char {
  if n < 10 {
    val base: Int = 48  // '0'
    val v = base + n
    intToChar(v)
  } else {
    val base: Int = 87  // 'a' - 10
    val v = base + n
    intToChar(v)
  }
}

@pure
func intToChar(n: in Int): Char {
  // Lyric does not yet expose `Int -> Char` conversion in the surface
  // language; the BCL extern path is used by the lexer's analogue.  A
  // small lookup table covers every code-point we ever emit (<= 0xFF).
  if n == 0 { '\u{0000}' }
  else if n == 1 { '\u{0001}' }
  else if n == 2 { '\u{0002}' }
  else if n == 3 { '\u{0003}' }
  else if n == 4 { '\u{0004}' }
  else if n == 5 { '\u{0005}' }
  else if n == 6 { '\u{0006}' }
  else if n == 7 { '\u{0007}' }
  else if n == 8 { '\u{0008}' }
  else if n == 9 { '\u{0009}' }
  else if n == 10 { '\u{000A}' }
  else if n == 11 { '\u{000B}' }
  else if n == 12 { '\u{000C}' }
  else if n == 13 { '\u{000D}' }
  else if n == 14 { '\u{000E}' }
  else if n == 15 { '\u{000F}' }
  else if n == 16 { '\u{0010}' }
  else if n == 17 { '\u{0011}' }
  else if n == 18 { '\u{0012}' }
  else if n == 19 { '\u{0013}' }
  else if n == 20 { '\u{0014}' }
  else if n == 21 { '\u{0015}' }
  else if n == 22 { '\u{0016}' }
  else if n == 23 { '\u{0017}' }
  else if n == 24 { '\u{0018}' }
  else if n == 25 { '\u{0019}' }
  else if n == 26 { '\u{001A}' }
  else if n == 27 { '\u{001B}' }
  else if n == 28 { '\u{001C}' }
  else if n == 29 { '\u{001D}' }
  else if n == 30 { '\u{001E}' }
  else if n == 31 { '\u{001F}' }
  else if n == 48 { '0' }
  else if n == 49 { '1' }
  else if n == 50 { '2' }
  else if n == 51 { '3' }
  else if n == 52 { '4' }
  else if n == 53 { '5' }
  else if n == 54 { '6' }
  else if n == 55 { '7' }
  else if n == 56 { '8' }
  else if n == 57 { '9' }
  else if n == 97 { 'a' }
  else if n == 98 { 'b' }
  else if n == 99 { 'c' }
  else if n == 100 { 'd' }
  else if n == 101 { 'e' }
  else if n == 102 { 'f' }
  // Every other code point (ordinary printable ASCII — letters, space,
  // punctuation) goes through the BCL-backed `Std.Char.fromInt`.  The
  // table above predates that helper; without this fallback any char
  // literal outside 0-31 / digits / a-f rendered as `'?'`, corrupting
  // `'z'`, `' '`, `'/'`, every uppercase letter, etc. on every format.
  else { Ch.fromInt(n) }
}

/// Format a code-point as `\uXXXX` (zero-padded 4-digit hex).
@pure
func uHex4(cp: in Int): String {
  // 0..0xFFFF only (BMP); higher code-points never reach `escapeStr`.
  val h0 = (cp / 4096) % 16
  val h1 = (cp / 256) % 16
  val h2 = (cp / 16) % 16
  val h3 = cp % 16
  "\\u" + charToStr(hexDigit(h0)) + charToStr(hexDigit(h1)) +
       charToStr(hexDigit(h2)) + charToStr(hexDigit(h3))
}

/// Escape a string for emission inside a `"…"` literal.  Mirrors the
/// `escapeStr` in Fmt.fs: `"`, `\`, control characters, and the four
/// common whitespace escapes are translated.
@pure
pub func escapeStr(s: in String): String {
  var acc = ""
  var i = 0
  while i < s.length {
    val c = s[i]
    if c == '"' {
      acc = acc + "\\\""
    } else if c == '\\' {
      acc = acc + "\\\\"
    } else if c == '\n' {
      acc = acc + "\\n"
    } else if c == '\r' {
      acc = acc + "\\r"
    } else if c == '\t' {
      acc = acc + "\\t"
    } else if charIsControl(c) {
      acc = acc + uHex4(charCodepoint(c))
    } else {
      acc = acc + charToStr(c)
    }
    i = i + 1
  }
  acc
}

@pure
func charIsControl(c: in Char): Bool {
  charCodepoint(c) < 32
}

@pure
func charCodepoint(c: in Char): Int {
  // ASCII fast path covers the only call site (escapeStr) which only
  // ever asks for control characters in 0..31.
  if c == '\u{0000}' { 0 }
  else if c == '\u{0001}' { 1 }
  else if c == '\u{0002}' { 2 }
  else if c == '\u{0003}' { 3 }
  else if c == '\u{0004}' { 4 }
  else if c == '\u{0005}' { 5 }
  else if c == '\u{0006}' { 6 }
  else if c == '\u{0007}' { 7 }
  else if c == '\u{0008}' { 8 }
  else if c == '\u{0009}' { 9 }
  else if c == '\u{000A}' { 10 }
  else if c == '\u{000B}' { 11 }
  else if c == '\u{000C}' { 12 }
  else if c == '\u{000D}' { 13 }
  else if c == '\u{000E}' { 14 }
  else if c == '\u{000F}' { 15 }
  else if c == '\u{0010}' { 16 }
  else if c == '\u{0011}' { 17 }
  else if c == '\u{0012}' { 18 }
  else if c == '\u{0013}' { 19 }
  else if c == '\u{0014}' { 20 }
  else if c == '\u{0015}' { 21 }
  else if c == '\u{0016}' { 22 }
  else if c == '\u{0017}' { 23 }
  else if c == '\u{0018}' { 24 }
  else if c == '\u{0019}' { 25 }
  else if c == '\u{001A}' { 26 }
  else if c == '\u{001B}' { 27 }
  else if c == '\u{001C}' { 28 }
  else if c == '\u{001D}' { 29 }
  else if c == '\u{001E}' { 30 }
  else if c == '\u{001F}' { 31 }
  else { 32 }  // sentinel "non-control"
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. ModulePath, doc-comments, annotations, generics, where-clauses,
// constraint refs, params, contracts.  Each returns either a `String`
// (single-line construct) or a `Doc` (`docLines` for multi-line lists).
// ─────────────────────────────────────────────────────────────────────────────

@pure
pub func pathStr(mp: in ModulePath): String {
  if mp.segments.count == 0 { return "" }
  var s = mp.segments[0]
  var i = 1
  while i < mp.segments.count {
    s = s + "." + mp.segments[i]
    i = i + 1
  }
  s
}

pub func docLines(docs: in List[DocComment]): List[String] {
  val acc: List[String] = newList()
  var i = 0
  while i < docs.count {
    val d = docs[i]
    val prefix = if d.isModule { "//!" } else { "///" }
    if d.text == "" { acc.add(prefix) }
    else { acc.add(prefix + " " + d.text) }
    i = i + 1
  }
  acc
}

pub func litStr(l: in Literal): String {
  match l {
    // Prefer the verbatim source spelling so `0xFF` / `100_000` / `2.99`
    // round-trip instead of canonicalising to `255` / `100000` /
    // `2.9899999999999998`.  Synthetic literals carry an empty `raw`.
    case LInt(v, s, raw)    -> if raw != "" { raw } else { longToStr(v) + intSufStr(s) }
    case LFloat(v, s, raw)  -> if raw != "" { raw } else { floatLitStr(v) + floatSufStr(s) }
    case LChar(cp)          -> charLitStr(cp)
    case LString(t)         -> "\"" + escapeStr(t) + "\""
    case LTripleString(t)   -> "\"\"\"" + t + "\"\"\""
    case LRawString(t)      -> "r\"" + t + "\""
    case LBool(true)        -> "true"
    case LBool(false)       -> "false"
    case LUnit              -> "()"
  }
}

@pure
func longToStr(v: in Long): String {
  // Std.Core does not expose Long->String directly; route through the
  // BCL extern via string concat which lifts to System.String.Concat.
  "" + v
}

@pure
func floatLitStr(v: in Double): String {
  // `%g` semantics: F# uses sprintf "%g"; Lyric does not have `%g`
  // built in, so route through System.Double.ToString().  For the
  // common case (integer-valued doubles), append ".0" to keep the
  // parser distinguishing them from integers — mirroring Fmt.fs.
  val s = doubleToStr(v)
  if Str.contains(s, ".") or Str.contains(s, "e") or Str.contains(s, "E") {
    s
  } else {
    s + ".0"
  }
}

@pure
func doubleToStr(v: in Double): String {
  // The bootstrap codegen lifts string + Double through
  // System.String.Concat, which uses the invariant "G" format.
  "" + v
}

@pure
func charLitStr(cp: in Int): String {
  // Mirror Fmt.fs's char literal emission.
  if cp == 92 {
    "'\\\\'"
  } else if cp == 39 {
    "'\\''"
  } else if cp == 10 {
    "'\\n'"
  } else if cp == 13 {
    "'\\r'"
  } else if cp == 9 {
    "'\\t'"
  } else if cp < 32 {
    "'" + uHex4(cp) + "'"
  } else if cp < 128 {
    "'" + charToStr(intToChar(cp)) + "'"
  } else {
    // Non-ASCII: emit as `\u{XXXX}`.  Falls back to a generic four-hex
    // escape for BMP code-points; non-BMP would need surrogates which
    // Fmt.fs also does not handle.
    "'\\u{" + uHex4(cp) + "}'"
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Type printers.  Mirrors `typeStr` and friends from Fmt.fs.
// ─────────────────────────────────────────────────────────────────────────────

pub func typeStr(te: in TypeExpr): String {
  match te.kind {
    case TRef(path)               -> pathStr(path)
    case TGenericApp(head, args)  -> pathStr(head) + "[" + typeArgsStr(args) + "]"
    case TArray(sz, elem)         -> "array[" + typeArgStr(sz) + ", " + typeStr(elem) + "]"
    case TSlice(elem)             -> "slice[" + typeStr(elem) + "]"
    case TRefined(under, rb)      -> pathStr(under) + " range " + rangeBoundStr(rb)
    case TTuple(types)            -> "(" + typesStr(types) + ")"
    case TNullable(inner)         -> typeStr(inner) + "?"
    case TFunction(params, retTy) -> "(" + typesStr(params) + ") -> " + typeStr(retTy)
    case TUnit                    -> "()"
    case TSelf                    -> "Self"
    case TNever                   -> "Never"
    case TParen(inner)            -> "(" + typeStr(inner) + ")"
    case TError                   -> "<type-error>"
  }
}

pub func typesStr(ts: in List[TypeExpr]): String {
  if ts.count == 0 { return "" }
  var s = typeStr(ts[0])
  var i = 1
  while i < ts.count {
    s = s + ", " + typeStr(ts[i])
    i = i + 1
  }
  s
}

pub func typeArgStr(ta: in TypeArg): String {
  match ta {
    case TAType(ty)   -> typeStr(ty)
    case TAValue(e)   -> exprInline(0, e)
  }
}

pub func typeArgsStr(args: in List[TypeArg]): String {
  if args.count == 0 { return "" }
  var s = typeArgStr(args[0])
  var i = 1
  while i < args.count {
    s = s + ", " + typeArgStr(args[i])
    i = i + 1
  }
  s
}

pub func rangeBoundStr(rb: in RangeBound): String {
  match rb {
    case RBClosed(lo, hi)   -> exprInline(0, lo) + " ..= " + exprInline(0, hi)
    case RBHalfOpen(lo, hi) -> exprInline(0, lo) + " ..< " + exprInline(0, hi)
    case RBLowerOpen(hi)    -> "..= " + exprInline(0, hi)
    case RBUpperOpen(lo)    -> exprInline(0, lo) + " .."
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Pattern printers.
// ─────────────────────────────────────────────────────────────────────────────

pub func patStr(p: in Pattern): String {
  match p.kind {
    case PWildcard                -> "_"
    case PLiteral(l)              -> litStr(l)
    case PRange(lo, incl, hi)     -> patRangeStr(lo, incl, hi)
    case PBinding(n, innerP)      -> {
      // The `match innerP { Some / None }` shape silently falls through
      // under the bootstrap codegen for `Option[Pattern]` here (the
      // value is destructured out of `PBinding` and re-matched in one
      // arm).  `isSome` + `unwrapOr` route around it; both are cheap
      // and the recursion terminates on the inner pattern's kind.
      if isSome(innerP) {
        n + " @ " + patStr(unwrapOr(innerP, p))
      } else {
        n
      }
    }
    case PConstructor(head, args) -> patCtorStr(head, args)
    case PRecord(head, fs, rest)  -> patRecordStr(head, fs, rest)
    case PTuple(patterns)         -> patTupleStr(patterns)
    case PParen(innerP)           -> patParenStr(innerP)
    case PTypeTest(innerP, ty)    -> patTypeTestStr(innerP, ty)
    case POr(patterns)            -> patOrStr(patterns)
    case PError                   -> "<pat-error>"
  }
}

func patTupleStr(ps: in List[Pattern]): String {
  "(" + patsStr(ps) + ")"
}

func patParenStr(p: in Pattern): String {
  "(" + patStr(p) + ")"
}

func patTypeTestStr(p: in Pattern, ty: in TypeExpr): String {
  patStr(p) + ": " + typeStr(ty)
}

func patOrStr(ps: in List[Pattern]): String {
  patsStrSep(ps, " | ")
}

func patRangeStr(lo: in Expr, incl: in Bool, hi: in Expr): String {
  val op = if incl { "..=" } else { ".." }
  exprInline(0, lo) + " " + op + " " + exprInline(0, hi)
}

func patBindingStr(n: in String, innerOpt: in Option[Pattern]): String {
  match innerOpt {
    case Some(ip) -> n + " @ " + patStr(ip)
    case None     -> n
  }
}

func patCtorStr(head: in ModulePath, args: in List[Pattern]): String {
  if args.count == 0 { pathStr(head) }
  else { pathStr(head) + "(" + patsStr(args) + ")" }
}

func patRecordStr(head: in ModulePath, fs: in List[RecordPatternField], rest: in Bool): String {
  val parts: List[String] = newList()
  var i = 0
  while i < fs.count {
    match fs[i] {
      case RPFNamed(n, p, _) -> parts.add(n + ": " + patStr(p))
      case RPFShort(n, _)    -> parts.add(n)
    }
    i = i + 1
  }
  if rest { parts.add("..") }
  pathStr(head) + " { " + joinStrings(parts, ", ") + " }"
}

pub func patsStr(ps: in List[Pattern]): String {
  patsStrSep(ps, ", ")
}

pub func patsStrSep(ps: in List[Pattern], sep: in String): String {
  if ps.count == 0 { return "" }
  var s = patStr(ps[0])
  var i = 1
  while i < ps.count {
    s = s + sep + patStr(ps[i])
    i = i + 1
  }
  s
}

pub func joinStrings(xs: in List[String], sep: in String): String {
  if xs.count == 0 { return "" }
  var s = xs[0]
  var i = 1
  while i < xs.count {
    s = s + sep + xs[i]
    i = i + 1
  }
  s
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. Generics, where-clauses, params, contracts, annotations.
// ─────────────────────────────────────────────────────────────────────────────

pub func genParamStr(gp: in GenericParam): String {
  match gp {
    case GPType(n, _)              -> n
    case GPValue(n, constraint, _) -> n + ": " + typeStr(constraint)
  }
}

pub func genParamsStr(gps: in Option[GenericParams]): String {
  match gps {
    case None    -> ""
    case Some(g) -> {
      val parts: List[String] = newList()
      var i = 0
      while i < g.params.count {
        parts.add(genParamStr(g.params[i]))
        i = i + 1
      }
      "[" + joinStrings(parts, ", ") + "]"
    }
  }
}

pub func constraintRefStr(cr: in ConstraintRef): String {
  if cr.args.count == 0 {
    pathStr(cr.head)
  } else {
    pathStr(cr.head) + "[" + typeArgsStr(cr.args) + "]"
  }
}

pub func whereBoundStr(wb: in WhereBound): String {
  val parts: List[String] = newList()
  var i = 0
  while i < wb.constraints.count {
    parts.add(constraintRefStr(wb.constraints[i]))
    i = i + 1
  }
  wb.name + ": " + joinStrings(parts, " + ")
}

pub func whereClauseStr(wc: in Option[WhereClause]): String {
  match wc {
    case None    -> ""
    case Some(w) -> {
      val parts: List[String] = newList()
      var i = 0
      while i < w.bounds.count {
        parts.add(whereBoundStr(w.bounds[i]))
        i = i + 1
      }
      "where " + joinStrings(parts, ", ")
    }
  }
}

pub func paramStr(p: in Param): String {
  // A bare param (`x: T`, no mode keyword) is sugar for `in`; the parser
  // records that via `modeExplicit = false` so we don't synthesise an
  // `in` the author never wrote.  `out`/`inout` are always explicit.
  val modeStr = if not p.modeExplicit { "" } else {
    match p.mode {
      case PMIn    -> "in "
      // The Lyric keyword is `out`; the original `out` → `acc` rename
      // (D-progress-131 reserved-keyword cleanup) accidentally rewrote
      // this display string.  Drive the output off the source spelling
      // instead.
      case PMOut   -> "out "
      case PMInout -> "inout "
    }
  }
  val defStr = match p.dflt {
    case None    -> ""
    case Some(d) -> " = " + exprInline(0, d)
  }
  p.name + ": " + modeStr + typeStr(p.ty) + defStr
}

pub func paramsStr(ps: in List[Param]): String {
  if ps.count == 0 { return "" }
  var s = paramStr(ps[0])
  var i = 1
  while i < ps.count {
    s = s + ", " + paramStr(ps[i])
    i = i + 1
  }
  s
}

/// Width-driven multi-line parameter-list rendering.  Returns a `Doc`
/// that's either a single line "p1, p2, …, pN" (no trailing comma) or
/// a multi-line list with one parameter per line and a trailing comma
/// after every entry (Black-style "magic trailing comma" — keeps git
/// diffs tight when adding a new parameter).  Caller is responsible
/// for the surrounding `(` / `)` punctuation.
///
/// The `col` argument is the source column where the FIRST parameter
/// starts (i.e. just after the `(`).  When the inline rendering plus
/// any caller-supplied suffix length (e.g. `") -> Foo"`) overruns the
/// 120-char budget at that column, the multi-line form fires.  The
/// caller telegraphs `suffixLen` via the budget-check helper
/// `paramsFitInline`; here we just assume a 0-length suffix and let
/// the caller make the final decision when it knows what comes after
/// the closing paren.
pub func paramsAtCol(col: in Int, ctx: inout FmtCtx, ps: in List[Param]): List[String] {
  if ps.count == 0 { return singleLineDoc("") }
  val inline = paramsStr(ps)
  // Budget peek + cursor-relative trivia peek.  `lo = 0` so we catch
  // unpopped trivia anywhere up to the last param's end — including
  // comments between `(` and the FIRST param, which are in the first
  // param's leading trivia (offset < `ps[0].span.startPos.offset`).
  // Caller's `paramsFitInline` does the precise budget check.
  val lastEnd = ps[ps.count - 1].span.endPos.offset
  val triviaInside = hasTriviaInRange(ctx, 0, lastEnd)
  if not triviaInside and col + inline.length <= maxWidth() {
    return singleLineDoc(inline)
  }
  // Multi-line: each param on its own line, trailing comma.
  val acc: List[String] = newList()
  var i = 0
  while i < ps.count {
    val p = ps[i]
    appendTriviaInto(acc, ctx, p.span.startPos.offset, false)
    acc.add(paramStr(p) + ",")
    i = i + 1
  }
  acc
}

/// Companion budget check for callers who know the suffix length
/// (typically `") <retStr>"` for a function decl signature).  Returns
/// `true` when the params CAN be rendered inline given the suffix
/// budget; `false` forces the multi-line path.
@pure
pub func paramsFitInline(col: in Int, ps: in List[Param], suffixLen: in Int): Bool {
  if ps.count == 0 { return true }
  val inline = paramsStr(ps)
  col + inline.length + suffixLen <= maxWidth()
}

pub func contractStr(cc: in ContractClause): String {
  match cc {
    case CCRequires(ex, _)  -> "requires: " + exprInline(0, ex)
    case CCEnsures(ex, _)   -> "ensures: " + exprInline(0, ex)
    case CCWhen(ex, _)      -> "when: " + exprInline(0, ex)
    case CCDecreases(ex, _) -> "decreases: " + exprInline(0, ex)
    case CCRaises(tys, _)   -> "raises: " + typesStr(tys)
  }
}

/// Width-driven multi-line variant of `contractStr`.  `col` is the
/// output column where the contract line will START — i.e. the
/// caller's outer indent (e.g. the function decl indents contracts by
/// 2, so `col = 2`).  The returned `Doc` carries no leading indent;
/// the caller wraps it with `indentDoc` as usual.
pub func contractDoc(col: in Int, ctx: inout FmtCtx, cc: in ContractClause): List[String] {
  match cc {
    case CCRequires(ex, _)  -> contractWithBody("requires: ",  col, ctx, ex)
    case CCEnsures(ex, _)   -> contractWithBody("ensures: ",   col, ctx, ex)
    case CCWhen(ex, _)      -> contractWithBody("when: ",      col, ctx, ex)
    case CCDecreases(ex, _) -> contractWithBody("decreases: ", col, ctx, ex)
    case CCRaises(tys, _)   -> singleLineDoc("raises: " + typesStr(tys))
  }
}

func contractWithBody(prefix: in String, col: in Int, ctx: inout FmtCtx, ex: in Expr): List[String] {
  prependPrefix(prefix, exprAtCol(col + prefix.length, ctx, ex))
}

pub func annotationValueStr(av: in AnnotationValue): String {
  match av {
    case AVInt(v, _)    -> longToStr(v)
    case AVString(s, _) -> "\"" + escapeStr(s) + "\""
    case AVBool(b, _)   -> if b { "true" } else { "false" }
    case AVIdent(i, _)  -> i
  }
}

pub func annotationArgStr(aa: in AnnotationArg): String {
  match aa {
    case AAName(n, v, _) -> n + " = " + annotationValueStr(v)
    case ABare(n, _)     -> n
    case ALiteral(v, _)  -> annotationValueStr(v)
  }
}

pub func annotationStr(a: in Annotation): String {
  if a.args.count == 0 {
    "@" + pathStr(a.name)
  } else {
    val parts: List[String] = newList()
    var i = 0
    while i < a.args.count {
      parts.add(annotationArgStr(a.args[i]))
      i = i + 1
    }
    "@" + pathStr(a.name) + "(" + joinStrings(parts, ", ") + ")"
  }
}

pub func annotationLines(anns: in List[Annotation]): List[String] {
  val acc: List[String] = newList()
  var i = 0
  while i < anns.count {
    acc.add(annotationStr(anns[i]))
    i = i + 1
  }
  acc
}

// ─────────────────────────────────────────────────────────────────────────────
// §7a. Width-driven pretty-printer infrastructure (Phase 5 §M5.3 stage 9,
// D-progress-145).
//
// The canonical line-width budget for `lyric fmt` is `MAX_WIDTH` characters.
// `exprAtCol(col, ctx, e)` returns a `Doc` (`List[String]`) for an expression
// rendered starting at source column `col`.  The decision tree is:
//
//   1. Compute the inline rendering via `exprInline`.
//   2. If `col + len(inline) <= MAX_WIDTH`, return the single-line `Doc`.
//   3. Otherwise dispatch on `ExprKind` to a per-construct multi-line layout
//      that recurses through `exprAtCol` for sub-expressions.
//
// Per-construct multi-line layouts use Black-style "magic trailing comma"
// placement: opener on the first line, items one-per-line indented by 2,
// closer on its own line at the original indent.  Operators in binary
// chains end the lhs line and the rhs starts a new indented line — keeps
// the operator visually attached to its left operand.
//
// The returned `Doc`'s first line carries no leading indent; subsequent
// lines carry indent relative to the expression's own first column (`col`).
// Outer callers (`indentDoc`, `blockLines`) add their own outer indent.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub func maxWidth(): Int { 120 }

/// Length of a `Doc`'s first line.  Used by callers that want to know how
/// far the cursor will have moved after printing.
@pure
pub func firstLineLen(doc: in List[String]): Int {
  if doc.count == 0 { 0 } else { doc[0].length }
}

/// Length of a `Doc`'s last line.  Same use case as `firstLineLen` but at
/// the end of a multi-line construct.
@pure
pub func lastLineLen(doc: in List[String]): Int {
  if doc.count == 0 { 0 } else { doc[doc.count - 1].length }
}

/// True when the inline rendering of `e` fits within the remaining
/// width budget at column `col`.  Comments inside the expression's
/// source span force `false` so the multi-line layout can weave them in.
pub func exprFitsInline(col: in Int, ctx: in FmtCtx, e: in Expr, inline: in String): Bool {
  if col + inline.length > maxWidth() { return false }
  if hasTriviaInRange(ctx, e.span.startPos.offset, e.span.endPos.offset) { return false }
  true
}

/// True when any harvested-trivia item (comment OR blank-line marker)
/// has an offset in `[lo, hi)`.  Doesn't consume — pure peek.
@pure
pub func hasTriviaInRange(ctx: in FmtCtx, lo: in Int, hi: in Int): Bool {
  var i = ctx.cursor
  while i < ctx.items.count {
    val o = harvestedItemOffset(ctx.items[i])
    if o >= hi { return false }
    if o >= lo { return true }
    i = i + 1
  }
  false
}

@pure
func harvestedItemOffset(h: in HarvestedItem): Int {
  match h {
    case HiComment(_, o) -> o
    case HiBlank(o)      -> o
  }
}

/// True when `s` is a statement the parser wraps in a single-statement
/// `EBlock` to use it in expression position (see parser_exprs.l: the
/// `return` / `throw` / `try` / `break` / `continue` keyword-as-expression
/// forms).  Rendering such a wrapper as `{ <stmt> }` would inject braces
/// the author never wrote and collapse a multi-statement `try` body onto
/// one line; instead we unwrap and render the bare statement.
@pure
func isKeywordExprStmt(s: in Statement): Bool {
  match s.kind {
    case STry(_, _, _) -> true
    case SThrow(_)     -> true
    case SBreak(_)     -> true
    case SContinue(_)  -> true
    case SReturn(_)    -> true
    case _             -> false
  }
}

/// True when `b` is a parser-synthesised wrapper around a single
/// keyword-as-expression statement *and the source wrote no braces*.  The
/// parser gives such a wrapper the bare statement's span (parser_exprs.l),
/// whereas an author-written `{ return e }` block's span starts at the `{`
/// before the statement.  Comparing the two start offsets distinguishes
/// `return e` (unwrap) from `{ return e }` (keep the braces) even though
/// both share the `Block`-of-one-statement shape.
@pure
func isBareKeywordExprBlock(b: in Block): Bool {
  b.statements.count == 1
    and isKeywordExprStmt(b.statements[0])
    and b.span.startPos.offset == b.statements[0].span.startPos.offset
}

/// Multi-line rendering of an `EBlock` expression.  A bare keyword-as-
/// expression wrapper is unwrapped to the statement (round-tripping
/// `return try { … } catch { … }`); any other block renders as a normal
/// brace-delimited multi-line block.
func blockExprDoc(col: in Int, ctx: inout FmtCtx, b: in Block): List[String] {
  if isBareKeywordExprBlock(b) {
    return stmtLines(b.statements[0], ctx)
  }
  concatDoc3(singleLineDoc("{"), indentDoc(2, blockLines(b, ctx)), singleLineDoc("}"))
}

/// Inline rendering of an `EBlock`: unwrap a bare keyword-as-expression
/// wrapper to its bare form, mirroring `blockExprDoc`.
func blockExprInline(b: in Block): String {
  if isBareKeywordExprBlock(b) {
    return stmtInline(b.statements[0])
  }
  "{ " + blockInline(b) + " }"
}

/// Width-driven multi-line entry point.  Always returns a non-empty
/// `Doc`; the first line never has leading whitespace (the caller
/// owns the outer indent).
pub func exprAtCol(col: in Int, ctx: inout FmtCtx, e: in Expr): List[String] {
  // A block with several statements has no faithful one-line form
  // (`blockInline` would fuse them with `; ` separators the source never
  // had), and a `try` is always a multi-line construct.  Route those to
  // the multi-line block printer before the width-driven inline attempt;
  // single-statement non-`try` blocks may still inline below.
  match e.kind {
    case EBlock(b) -> {
      val single = b.statements.count == 1
      val isTry = single and (match b.statements[0].kind {
        case STry(_, _, _) -> true
        case _             -> false
      })
      if (not single) or isTry { return blockExprDoc(col, ctx, b) }
    }
    case _ -> {}
  }
  val inline = exprInline(0, e)
  if exprFitsInline(col, ctx, e, inline) {
    return singleLineDoc(inline)
  }
  // Doesn't fit (or has trivia inside).  Switch on `ExprKind` and pick
  // a multi-line layout per construct.  Constructs without a multi-line
  // shape (literals, paths, prefix ops over fitting operands) fall back
  // to the inline rendering even if it exceeds the budget.
  match e.kind {
    case ECall(fn, args)            -> exprCallMulti(col, ctx, fn, args)
    case EBinop(op, lhs, rhs)       -> exprBinopMulti(col, ctx, op, lhs, rhs)
    case EList(elems)               -> exprListMulti(col, ctx, elems, "[", "]")
    case ETuple(elems)              -> exprListMulti(col, ctx, elems, "(", ")")
    case EParen(inner)              -> exprParenMulti(col, ctx, inner)
    case ELambda(ps, body)          -> exprLambdaMulti(col, ctx, ps, body)
    case EForall(bs, w, body)       -> exprQuantMulti(col, ctx, "forall", bs, w, body)
    case EExists(bs, w, body)       -> exprQuantMulti(col, ctx, "exists", bs, w, body)
    // When an if-expression (brace form) or match-expression is too wide to
    // fit inline, convert to the brace layout the statement-level formatters
    // already produce.  The `then` form (`if cond then e`) has no brace
    // layout, so it falls through to inline (which may overflow).
    case EIf(cond, thn, els, thenForm) -> {
      if thenForm { singleLineDoc(inline) }
      else { ifBlockLines(cond, thn, els, ctx) }
    }
    case EMatch(scrut, arms)        -> matchLines(scrut, arms, ctx)
    case EBlock(b)                  -> blockExprDoc(col, ctx, b)
    case _                          -> singleLineDoc(inline)
  }
}

/// `ECall` multi-line layout:
///
///     fn(
///       arg1,
///       arg2,
///       ...,
///     )
///
/// `fn` is rendered inline (calls render their head as a path / member
/// access / nested call; nested-call argument lists handle their own
/// breaking).  Each argument recursively uses `exprAtCol(col + 2, …)`
/// — the +2 reflects the per-argument indent.
func exprCallMulti(col: in Int, ctx: inout FmtCtx, fn: in Expr, args: in List[CallArg]): List[String] {
  val fnStr = exprInline(0, fn)
  val acc: List[String] = newList()
  if args.count == 0 {
    // Empty call still inline.
    return singleLineDoc(fnStr + "()")
  }
  acc.add(fnStr + "(")
  val argCol = col + 2
  var i = 0
  while i < args.count {
    val isLast = i + 1 >= args.count
    val tail = if isLast { "" } else { "," }
    // Comments and intentional blank lines that precede this arg in
    // the source.  Pop at the arg's start offset so they land between
    // the previous arg and this one — same trivia-anchoring shape
    // used at every other structural boundary in the formatter.
    val pre = popTriviaBefore(ctx, callArgStartOffset(args[i]))
    var k = 0
    while k < pre.count { acc.add("  " + pre[k]); k = k + 1 }
    val argDoc = callArgAtCol(argCol, ctx, args[i])
    var j = 0
    while j < argDoc.count {
      val isLastLine = j + 1 >= argDoc.count
      val line = argDoc[j]
      if isLastLine and not isLast { acc.add("  " + line + tail) }
      else if isLastLine and isLast { acc.add("  " + line) }
      else { acc.add("  " + line) }
      j = j + 1
    }
    i = i + 1
  }
  acc.add(")")
  acc
}

@pure
func callArgStartOffset(ca: in CallArg): Int {
  match ca {
    case CANamed(_, v, sp) -> sp.startPos.offset
    case CAPositional(e)   -> e.span.startPos.offset
  }
}

func callArgAtCol(col: in Int, ctx: inout FmtCtx, ca: in CallArg): List[String] {
  match ca {
    case CANamed(n, v, _) -> {
      val prefix = n + " = "
      val inner = exprAtCol(col + prefix.length, ctx, v)
      val acc: List[String] = newList()
      if inner.count == 0 {
        acc.add(prefix)
      } else {
        acc.add(prefix + inner[0])
        var j = 1
        while j < inner.count { acc.add(inner[j]); j = j + 1 }
      }
      acc
    }
    case CAPositional(e) -> exprAtCol(col, ctx, e)
  }
}

/// `EBinop` multi-line layout — operator at end of LHS line, RHS on
/// its own indented line:
///
///     lhs op
///       rhs
///
/// Chained applications (left-associative) flatten naturally because
/// the lhs of an outer `BinopMulti` is itself a binary op rendered
/// recursively.
func exprBinopMulti(col: in Int, ctx: inout FmtCtx, op: in BinOp, lhs: in Expr, rhs: in Expr): List[String] {
  val prec = binPrec(op)
  // Render LHS at the same precedence so paren rules match `exprInline`.
  val lhsDoc = exprAtCol(col, ctx, lhs)
  // Trivia between LHS and RHS — comments and intentional blank lines
  // anchored at the RHS's source-start.  Popping here weaves them
  // BETWEEN the two operand renderings; without this they'd escape
  // to the next outer structural boundary (the enclosing statement).
  val betweenOperands = popTriviaBefore(ctx, rhs.span.startPos.offset)
  val rhsPrec = match op {
    case BImplies  -> prec
    case BCoalesce -> prec
    case _         -> prec + 1
  }
  val rhsDoc = exprAtCol(col + 2, ctx, rhs)
  val opStr = " " + binStr(op)
  val acc: List[String] = newList()
  // LHS lines: copy verbatim except append op to the last line.
  var i = 0
  while i < lhsDoc.count {
    val isLast = i + 1 >= lhsDoc.count
    if isLast { acc.add(lhsDoc[i] + opStr) }
    else      { acc.add(lhsDoc[i]) }
    i = i + 1
  }
  // Inter-operand trivia: indented to RHS's column (col + 2).
  i = 0
  while i < betweenOperands.count {
    val line = betweenOperands[i]
    if line == "" { acc.add("") } else { acc.add("  " + line) }
    i = i + 1
  }
  // RHS lines: indent every line by 2 (relative to col).
  i = 0
  while i < rhsDoc.count {
    acc.add("  " + rhsDoc[i])
    i = i + 1
  }
  // Precedence-driven outer paren is left to the caller — the inline
  // path's `exprInline` handles it; for the multi-line path, an outer
  // construct that needs paren-wrapping calls `exprParenMulti` itself.
  acc
}

/// `EList` / `ETuple` multi-line layout — same shape as a call:
///
///     [
///       elem1,
///       elem2,
///     ]
func exprListMulti(col: in Int, ctx: inout FmtCtx, elems: in List[Expr], opener: in String, closer: in String): List[String] {
  val acc: List[String] = newList()
  if elems.count == 0 {
    return singleLineDoc(opener + closer)
  }
  acc.add(opener)
  val elemCol = col + 2
  var i = 0
  while i < elems.count {
    val isLast = i + 1 >= elems.count
    val tail = if isLast { "" } else { "," }
    // Comments / intentional blank lines that sit before this element
    // in the source.  Same per-arg pattern used in `exprCallMulti` —
    // anchors the trivia between the previous element and this one
    // instead of letting it escape to the next outer boundary.
    val pre = popTriviaBefore(ctx, elems[i].span.startPos.offset)
    var p = 0
    while p < pre.count {
      val line = pre[p]
      if line == "" { acc.add("") } else { acc.add("  " + line) }
      p = p + 1
    }
    val elemDoc = exprAtCol(elemCol, ctx, elems[i])
    var j = 0
    while j < elemDoc.count {
      val isLastLine = j + 1 >= elemDoc.count
      val line = elemDoc[j]
      if isLastLine { acc.add("  " + line + tail) }
      else          { acc.add("  " + line) }
      j = j + 1
    }
    i = i + 1
  }
  acc.add(closer)
  acc
}

/// `EParen` multi-line: just unwrap one layer and let the inner
/// expression decide.  Black-style elision of redundant parens around
/// already-multi-line content.
func exprParenMulti(col: in Int, ctx: inout FmtCtx, inner: in Expr): List[String] {
  val innerDoc = exprAtCol(col + 1, ctx, inner)
  if innerDoc.count <= 1 {
    return singleLineDoc("(" + (if innerDoc.count == 0 { "" } else { innerDoc[0] }) + ")")
  }
  val acc: List[String] = newList()
  acc.add("(")
  var i = 0
  while i < innerDoc.count {
    acc.add("  " + innerDoc[i])
    i = i + 1
  }
  acc.add(")")
  acc
}

/// `ELambda` multi-line layout:
///
///     { param1, param2 ->
///       stmt1
///       stmt2
///     }
///
/// The lambda body is a `Block`, so `blockLines` (already trivia-aware)
/// handles per-statement comments and blank-line preservation inside.
/// Empty-param lambdas drop the `->` arrow on the opening line:
///
///     {
///       stmt
///     }
func exprLambdaMulti(col: in Int, ctx: inout FmtCtx, ps: in List[LambdaParam], body: in Block): List[String] {
  val opener = if ps.count == 0 { "{" } else { "{ " + lambdaParamsStr(ps) + " ->" }
  val acc: List[String] = newList()
  acc.add(opener)
  val bd = indentDoc(2, blockLines(body, ctx))
  var i = 0
  while i < bd.count { acc.add(bd[i]); i = i + 1 }
  acc.add("}")
  acc
}

@pure
func lambdaParamsStr(ps: in List[LambdaParam]): String {
  val parts: List[String] = newList()
  var i = 0
  while i < ps.count {
    val lp = ps[i]
    match lp.ty {
      case Some(t) -> parts.add(lp.name + ": " + typeStr(t))
      case None    -> parts.add(lp.name)
    }
    i = i + 1
  }
  joinStrings(parts, ", ")
}

/// Shared multi-line layout for `EForall` / `EExists`:
///
///     forall (a: Int, b: Int) where guard {
///       body
///     }
///
/// When the binders + where-guard line itself overruns budget the
/// multi-line break still puts the body on a separate line — that's
/// the highest-leverage break, since contracts with quantifiers
/// usually have long bodies.  Threading multi-line layouts through
/// the binder tuple and the where-guard expression as well is a
/// follow-up; for now they render inline.
func exprQuantMulti(col: in Int, ctx: inout FmtCtx, kw: in String, bs: in List[PropertyBinder], w: in Option[Expr], body: in Expr): List[String] {
  val parts: List[String] = newList()
  var i = 0
  while i < bs.count {
    parts.add(bs[i].name + ": " + typeStr(bs[i].ty))
    i = i + 1
  }
  val whereStr = match w {
    case Some(we) -> " where " + exprInline(0, we)
    case None     -> ""
  }
  val opener = kw + " (" + joinStrings(parts, ", ") + ")" + whereStr + " {"
  val acc: List[String] = newList()
  acc.add(opener)
  // When the body was parsed as `{ … }` the parser wraps it in EBlock.
  // Render the block contents directly to avoid double braces.
  val bd = match body.kind {
    case EBlock(b) -> indentDoc(2, blockLines(b, ctx))
    case _         -> indentDoc(2, exprAtCol(col + 2, ctx, body))
  }
  var j = 0
  while j < bd.count { acc.add(bd[j]); j = j + 1 }
  acc.add("}")
  acc
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. Inline expression printer.  `minPrec` is the minimum precedence the
// caller is willing to accept without wrapping in parens.
// ─────────────────────────────────────────────────────────────────────────────

pub func exprInline(minPrec: in Int, e: in Expr): String {
  match e.kind {
    case ELiteral(l)        -> litStr(l)
    case EInterpolated(segs)-> interpolatedStr(segs)
    case EPath(mp)          -> pathStr(mp)
    case EParen(inner)      -> "(" + exprInline(0, inner) + ")"
    case ETuple(exprs)      -> "(" + exprsStr(exprs) + ")"
    case EList(exprs)       -> "[" + exprsStr(exprs) + "]"
    case EIf(cond, thn, els, thenForm)
                            -> ifInlineStr(cond, thn, els, thenForm)
    case EMatch(scrut, arms)-> matchInlineStr(scrut, arms)
    case EAwait(inner)      -> "await " + exprInline(0, inner)
    case EYield(inner)      -> "yield " + exprInline(0, inner)
    case ESpawn(inner)      -> "spawn " + exprInline(0, inner)
    case ETry(inner)        -> "try " + exprInline(0, inner)
    case EOld(inner)        -> "old(" + exprInline(0, inner) + ")"
    case EForall(bs, w, body) -> quantifierStr("forall", bs, w, body)
    case EExists(bs, w, body) -> quantifierStr("exists", bs, w, body)
    case ESelf              -> "self"
    case EResult            -> "result"
    case ELambda(ps, body)  -> lambdaInlineStr(ps, body)
    case ECall(fn, args)    -> exprInline(0, fn) + "(" + callArgsStr(args) + ")"
    case ETypeApp(fn, args) -> exprInline(0, fn) + "[" + typeArgsStr(args) + "]"
    case EIndex(recv, idx)  -> exprInline(0, recv) + "[" + exprsStr(idx) + "]"
    case EMember(recv, name)-> exprInline(0, recv) + "." + name
    case EPropagate(inner)  -> exprInline(0, inner) + "?"
    case EPrefix(op, inner) -> prefixStr(op) + exprInline(0, inner)
    case EBinop(op, lhs, rhs) -> binopInlineStr(minPrec, op, lhs, rhs)
    case ERange(rb)         -> rangeBoundStr(rb)
    case EAssign(t, op, v)  -> exprInline(0, t) + " " + assignStr(op) + " " + exprInline(0, v)
    case EBlock(b)          -> blockExprInline(b)
    case EUnsafe(b)         -> "unsafe { " + blockInline(b) + " }"
    case EError             -> "<error>"
  }
}

func interpolatedStr(segs: in List[InterpolatedSegment]): String {
  var acc = ""
  var i = 0
  while i < segs.count {
    match segs[i] {
      case ISText(text, _) -> { acc = acc + escapeStr(text) }
      case ISExpr(e)       -> { acc = acc + "${" + exprInline(0, e) + "}" }
    }
    i = i + 1
  }
  "\"" + acc + "\""
}

func ifInlineStr(cond: in Expr, thn: in ExprOrBlock, els: in Option[ExprOrBlock], thenForm: in Bool): String {
  val condStr = exprInline(0, cond)
  val thenStr = eobInline(thn)
  val elseStr = match els {
    case Some(eb) -> " else " + eobInline(eb)
    case None     -> ""
  }
  if thenForm {
    "if " + condStr + " then " + thenStr + elseStr
  } else {
    "if " + condStr + " " + thenStr + elseStr
  }
}

func matchInlineStr(scrut: in Expr, arms: in List[MatchArm]): String {
  val parts: List[String] = newList()
  var i = 0
  while i < arms.count {
    val a = arms[i]
    val guard = match a.guard {
      case Some(g) -> " if " + exprInline(0, g)
      case None    -> ""
    }
    parts.add("case " + patStr(a.pattern) + guard + " -> " + eobInline(a.body))
    i = i + 1
  }
  "match " + exprInline(0, scrut) + " { " + joinStrings(parts, "; ") + " }"
}

func quantifierStr(kw: in String, bs: in List[PropertyBinder], w: in Option[Expr], body: in Expr): String {
  val parts: List[String] = newList()
  var i = 0
  while i < bs.count {
    parts.add(bs[i].name + ": " + typeStr(bs[i].ty))
    i = i + 1
  }
  val whereStr = match w {
    case Some(we) -> " where " + exprInline(0, we)
    case None     -> ""
  }
  // When the body was parsed as `{ … }` the parser wraps it in EBlock.
  // Render the block contents directly to avoid double braces.
  val bodyStr = match body.kind {
    case EBlock(b) -> blockInline(b)
    case _         -> exprInline(0, body)
  }
  kw + " (" + joinStrings(parts, ", ") + ")" + whereStr + " { " + bodyStr + " }"
}

func lambdaInlineStr(ps: in List[LambdaParam], body: in Block): String {
  if ps.count == 0 {
    "{ " + blockInline(body) + " }"
  } else {
    val parts: List[String] = newList()
    var i = 0
    while i < ps.count {
      val lp = ps[i]
      match lp.ty {
        case Some(t) -> parts.add(lp.name + ": " + typeStr(t))
        case None    -> parts.add(lp.name)
      }
      i = i + 1
    }
    "{ " + joinStrings(parts, ", ") + " -> " + blockInline(body) + " }"
  }
}

func binopInlineStr(minPrec: in Int, op: in BinOp, lhs: in Expr, rhs: in Expr): String {
  val prec = binPrec(op)
  val lhsStr = exprInline(prec, lhs)
  val rhsPrec = match op {
    case BImplies  -> prec
    case BCoalesce -> prec
    case _         -> prec + 1
  }
  val rhsStr = exprInline(rhsPrec, rhs)
  val s = lhsStr + " " + binStr(op) + " " + rhsStr
  if prec < minPrec { "(" + s + ")" } else { s }
}

func eobInline(eob: in ExprOrBlock): String {
  match eob {
    case EOBExpr(e)  -> exprInline(0, e)
    case EOBBlock(b) -> blockExprInline(b)
  }
}

func blockInline(b: in Block): String {
  val parts: List[String] = newList()
  var i = 0
  while i < b.statements.count {
    parts.add(stmtInline(b.statements[i]))
    i = i + 1
  }
  joinStrings(parts, "; ")
}

pub func exprsStr(es: in List[Expr]): String {
  if es.count == 0 { return "" }
  var s = exprInline(0, es[0])
  var i = 1
  while i < es.count {
    s = s + ", " + exprInline(0, es[i])
    i = i + 1
  }
  s
}

func callArgStr(ca: in CallArg): String {
  match ca {
    case CANamed(n, v, _) -> n + " = " + exprInline(0, v)
    case CAPositional(e)  -> exprInline(0, e)
  }
}

func callArgsStr(args: in List[CallArg]): String {
  if args.count == 0 { return "" }
  var s = callArgStr(args[0])
  var i = 1
  while i < args.count {
    s = s + ", " + callArgStr(args[i])
    i = i + 1
  }
  s
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. Inline statement printer.  Mirrors `stmtInline` in Fmt.fs.
// ─────────────────────────────────────────────────────────────────────────────

pub func stmtInline(s: in Statement): String {
  match s.kind {
    case SLocal(lb)            -> localBindingStr(lb)
    case SAssign(t, op, v)     -> exprInline(0, t) + " " + assignStr(op) + " " + exprInline(0, v)
    case SReturn(value)        -> returnStr(value)
    case SBreak(label)         -> labelKwStr("break", label)
    case SContinue(label)      -> labelKwStr("continue", label)
    case SThrow(e)             -> "throw " + exprInline(0, e)
    case STry(body, catches, finally_)   -> tryInlineStr(body, catches, finally_)
    case SDefer(b)             -> "defer { " + blockInline(b) + " }"
    case SScope(bindStr, body)    -> scopeInlineStr(bindStr, body)
    case SFor(lbl, p, it, b)   -> forInlineStr(lbl, p, it, b)
    case SWhile(lbl, c, b)     -> whileInlineStr(lbl, c, b)
    case SLoop(lbl, b)         -> loopInlineStr(lbl, b)
    case SInvariant(e)         -> "invariant: " + exprInline(0, e)
    case SExpr(e)              -> exprInline(0, e)
    case SRule(lhs, rhs)       -> exprInline(0, lhs) + " -> " + exprInline(0, rhs)
    case SItem(item)           -> itemInlineFallback(item)
  }
}

/// Width-driven multi-line variants for the statement constructs whose
/// payload is a single expression.  Each prepends the keyword/prefix to
/// the first line of the expression's `Doc` and emits subsequent lines
/// verbatim (the expression's `Doc` already carries its own indent
/// relative to the prefix's right edge).
pub func localBindingDoc(col: in Int, ctx: inout FmtCtx, lb: in LocalBinding): List[String] {
  match lb {
    case LBVal(p, ty, init) -> {
      val tyStr = match ty {
        case Some(t) -> ": " + typeStr(t)
        case None    -> ""
      }
      val prefix = "val " + patStr(p) + tyStr + " = "
      prependPrefix(prefix, exprAtCol(col + prefix.length, ctx, init))
    }
    case LBVar(name, ty, init) -> {
      val tyStr = match ty {
        case Some(t) -> ": " + typeStr(t)
        case None    -> ""
      }
      match init {
        case Some(e) -> {
          val prefix = "var " + name + tyStr + " = "
          prependPrefix(prefix, exprAtCol(col + prefix.length, ctx, e))
        }
        case None -> singleLineDoc("var " + name + tyStr)
      }
    }
    case LBLet(name, ty, init) -> {
      val tyStr = match ty {
        case Some(t) -> ": " + typeStr(t)
        case None    -> ""
      }
      val prefix = "let " + name + tyStr + " = "
      prependPrefix(prefix, exprAtCol(col + prefix.length, ctx, init))
    }
  }
}

pub func returnDoc(col: in Int, ctx: inout FmtCtx, value: in Option[Expr]): List[String] {
  match value {
    case Some(e) -> {
      val prefix = "return "
      prependPrefix(prefix, exprAtCol(col + prefix.length, ctx, e))
    }
    case None -> singleLineDoc("return")
  }
}

pub func assignDoc(col: in Int, ctx: inout FmtCtx, target: in Expr, op: in AssignOp, value: in Expr): List[String] {
  val tgtInline = exprInline(0, target)
  val prefix = tgtInline + " " + assignStr(op) + " "
  prependPrefix(prefix, exprAtCol(col + prefix.length, ctx, value))
}

pub func throwDoc(col: in Int, ctx: inout FmtCtx, e: in Expr): List[String] {
  val prefix = "throw "
  prependPrefix(prefix, exprAtCol(col + prefix.length, ctx, e))
}

pub func bareExprDoc(col: in Int, ctx: inout FmtCtx, e: in Expr): List[String] {
  exprAtCol(col, ctx, e)
}

/// Concatenate `prefix` with the first line of `body`, leaving body's
/// subsequent lines untouched.  Used to attach a keyword (`val ` /
/// `return ` / `throw `) to a multi-line expression rendering.
@pure
func prependPrefix(prefix: in String, body: in List[String]): List[String] {
  val acc: List[String] = newList()
  if body.count == 0 {
    acc.add(prefix)
    return acc
  }
  acc.add(prefix + body[0])
  var i = 1
  while i < body.count {
    acc.add(body[i])
    i = i + 1
  }
  acc
}

func localBindingStr(lb: in LocalBinding): String {
  match lb {
    case LBVal(p, ty, init) -> {
      val tyStr = match ty {
        case Some(t) -> ": " + typeStr(t)
        case None    -> ""
      }
      "val " + patStr(p) + tyStr + " = " + exprInline(0, init)
    }
    case LBVar(name, ty, init) -> {
      val tyStr = match ty {
        case Some(t) -> ": " + typeStr(t)
        case None    -> ""
      }
      val initStr = match init {
        case Some(e) -> " = " + exprInline(0, e)
        case None    -> ""
      }
      "var " + name + tyStr + initStr
    }
    case LBLet(name, ty, init) -> {
      val tyStr = match ty {
        case Some(t) -> ": " + typeStr(t)
        case None    -> ""
      }
      "let " + name + tyStr + " = " + exprInline(0, init)
    }
  }
}

func returnStr(value: in Option[Expr]): String {
  match value {
    case Some(e) -> "return " + exprInline(0, e)
    case None    -> "return"
  }
}

func labelKwStr(kw: in String, label: in Option[String]): String {
  match label {
    case Some(l) -> kw + " " + l
    case None    -> kw
  }
}

func tryInlineStr(body: in Block, catches: in List[CatchClause], finally_: in Option[Block]): String {
  val parts: List[String] = newList()
  var i = 0
  while i < catches.count {
    val c = catches[i]
    val bindStr = match c.bindName {
      case Some(b) -> " as " + b
      case None    -> ""
    }
    parts.add("catch " + c.typeName + bindStr + " { " + blockInline(c.body) + " }")
    i = i + 1
  }
  val finStr = match finally_ {
    case None     -> ""
    case Some(fb) -> "finally { " + blockInline(fb) + " }"
  }
  val tail = if parts.count > 0 {
    " " + joinStrings(parts, " ") + (if finStr.length > 0 { " " + finStr } else { "" })
  } else if finStr.length > 0 {
    " " + finStr
  } else {
    ""
  }
  "try { " + blockInline(body) + " }" + tail
}

func scopeInlineStr(bindStr: in Option[String], body: in Block): String {
  val bs = match bindStr {
    case Some(n) -> " " + n
    case None    -> ""
  }
  "scope" + bs + " { " + blockInline(body) + " }"
}

func forInlineStr(lbl: in Option[String], p: in Pattern, it: in Expr, b: in Block): String {
  val ls = match lbl {
    case Some(l) -> l + ": "
    case None    -> ""
  }
  ls + "for " + patStr(p) + " in " + exprInline(0, it) + " { " + blockInline(b) + " }"
}

func whileInlineStr(lbl: in Option[String], c: in Expr, b: in Block): String {
  val ls = match lbl {
    case Some(l) -> l + ": "
    case None    -> ""
  }
  ls + "while " + exprInline(0, c) + " { " + blockInline(b) + " }"
}

func loopInlineStr(lbl: in Option[String], b: in Block): String {
  val ls = match lbl {
    case Some(l) -> l + ": "
    case None    -> ""
  }
  ls + "do { " + blockInline(b) + " }"
}

func itemInlineFallback(item: in Item): String {
  // Items that appear inline (e.g. inside a stmt list) are uncommon
  // but Fmt.fs joins their multi-line form with "; ".  Mirror that.
  // The inline form has no opportunity to weave in inter-construct
  // comments, so we hand `itemDoc` a fresh, empty `FmtCtx`.
  val empty: List[HarvestedItem] = newList()
  var ctx = newFmtCtx(empty)
  joinStrings(itemDoc(item, ctx), "; ")
}

// ─────────────────────────────────────────────────────────────────────────────
// §10. Multi-line block printer.  Mirrors `blockLines` and `stmtLines` from
// the F# `Fmt.fs`, but threads `ctx: inout FmtCtx` so item-internal comments
// (between statements, inside `if`/`for`/`while`/`match` bodies, etc.) get
// woven in at every structural boundary.  The cursor advances monotonically
// in source order; statements parse in source order, blocks contain
// statements in source order, so the iteration in `blockLines` lines up
// with the comment list naturally.
// ─────────────────────────────────────────────────────────────────────────────

pub func blockLines(b: in Block, ctx: inout FmtCtx): List[String] {
  val acc: List[String] = newList()
  var i = 0
  while i < b.statements.count {
    val s = b.statements[i]
    appendTriviaInto(acc, ctx, s.span.startPos.offset, false)
    val sl = stmtLines(s, ctx)
    var j = 0
    while j < sl.count {
      acc.add(sl[j])
      j = j + 1
    }
    i = i + 1
  }
  // Comments before the block's closing brace.  `dropBlanks = true`: a
  // blank line immediately before `}` should not become a trailing empty
  // line in the formatted body — the closing brace already provides a
  // visual terminator.  A trailing comment on the last statement is
  // re-attached to its line rather than emitted before `}`.
  appendTriviaInto(acc, ctx, b.span.endPos.offset, true)
  acc
}

pub func stmtLines(s: in Statement, ctx: inout FmtCtx): List[String] {
  // Width-budget reference column.  Most blocks are nested 1 level
  // deep (function body, lambda body), placing statements at output
  // col 2.  Deeper nestings (statement inside an `if` inside a `for`)
  // run a touch over budget by a few chars per nesting level — close
  // enough for the budget to catch real overruns without threading
  // `col` through every signature in the multi-line printer family.
  val col = 2
  match s.kind {
    case SLocal(lb)           -> localBindingDoc(col, ctx, lb)
    case SAssign(t, op, v)    -> assignDoc(col, ctx, t, op, v)
    case SReturn(value)       -> returnDoc(col, ctx, value)
    case SBreak(_)            -> singleLineDoc(stmtInline(s))
    case SContinue(_)         -> singleLineDoc(stmtInline(s))
    case SThrow(e)            -> throwDoc(col, ctx, e)
    case SInvariant(e)        -> invariantDoc(col, ctx, e)
    case SRule(_, _)          -> singleLineDoc(stmtInline(s))
    case SExpr(e)             -> stmtExprLines(s, e, ctx)
    case SFor(lbl, p, it, b)  -> forLines(lbl, p, it, b, ctx)
    case SWhile(lbl, c, b)    -> whileLines(lbl, c, b, ctx)
    case SLoop(lbl, b)        -> loopLines(lbl, b, ctx)
    case STry(body, catches, finally_)  -> tryLines(body, catches, finally_, ctx)
    case SDefer(b)            -> deferLines(b, ctx)
    case SScope(bindStr, b)   -> scopeLines(bindStr, b, ctx)
    case SItem(item)          -> itemDoc(item, ctx)
  }
}

pub func invariantDoc(col: in Int, ctx: inout FmtCtx, e: in Expr): List[String] {
  val prefix = "invariant: "
  prependPrefix(prefix, exprAtCol(col + prefix.length, ctx, e))
}

func stmtExprLines(s: in Statement, e: in Expr, ctx: inout FmtCtx): List[String] {
  match e.kind {
    case EMatch(scrut, arms)             -> matchLines(scrut, arms, ctx)
    case EIf(cond, thn, els, thenForm)   -> {
      if thenForm { singleLineDoc(stmtInline(s)) }
      else { ifBlockLines(cond, thn, els, ctx) }
    }
    case _                               -> bareExprDoc(2, ctx, e)
  }
}

func matchLines(scrut: in Expr, arms: in List[MatchArm], ctx: inout FmtCtx): List[String] {
  val head = singleLineDoc("match " + exprInline(0, scrut) + " {")
  val armLines: List[String] = newList()
  var i = 0
  while i < arms.count {
    val a = arms[i]
    appendTriviaInto(armLines, ctx, a.span.startPos.offset, false)
    val guard = match a.guard {
      case Some(g) -> " if " + exprInline(0, g)
      case None    -> ""
    }
    match a.body {
      case EOBExpr(body) -> {
        armLines.add("case " + patStr(a.pattern) + guard + " -> " + exprInline(0, body))
      }
      case EOBBlock(blk) -> {
        if isBareKeywordExprBlock(blk) {
          // Bare statement-as-arm-body: the parser wraps `-> return e` /
          // `-> throw …` in a single-statement block.  Render the bare
          // statement without injecting braces the source never had.
          val sl = stmtLines(blk.statements[0], ctx)
          val arrow = "case " + patStr(a.pattern) + guard + " -> "
          armLines.add(arrow + sl[0])
          var j = 1
          while j < sl.count { armLines.add(sl[j]); j = j + 1 }
        } else {
          armLines.add("case " + patStr(a.pattern) + guard + " -> {")
          val inner = indentDoc(2, blockLines(blk, ctx))
          var j = 0
          while j < inner.count { armLines.add(inner[j]); j = j + 1 }
          armLines.add("}")
        }
      }
    }
    i = i + 1
  }
  concatDoc3(head, indentDoc(2, armLines), singleLineDoc("}"))
}

func ifBlockLines(cond: in Expr, thn: in ExprOrBlock, els: in Option[ExprOrBlock], ctx: inout FmtCtx): List[String] {
  val condStr = exprInline(0, cond)
  val thenDoc = match thn {
    case EOBBlock(b) -> blockLines(b, ctx)
    case EOBExpr(e)  -> singleLineDoc(exprInline(0, e))
  }
  val acc: List[String] = newList()
  acc.add("if " + condStr + " {")
  val ind = indentDoc(2, thenDoc)
  var i = 0
  while i < ind.count { acc.add(ind[i]); i = i + 1 }
  // Else
  match els {
    case None -> { acc.add("}") }
    case Some(EOBBlock(b)) -> {
      acc.add("} else {")
      val eb = indentDoc(2, blockLines(b, ctx))
      i = 0
      while i < eb.count { acc.add(eb[i]); i = i + 1 }
      acc.add("}")
    }
    case Some(EOBExpr(e2)) -> {
      // If the else expression is itself a brace-form `if`, splice it in
      // as an `} else if` chain to mirror Fmt.fs.
      match e2.kind {
        case EIf(c2, t2, eb2, false) -> {
          val inner = ifBlockLines(c2, t2, eb2, ctx)
          if inner.count == 0 {
            acc.add("}")
          } else {
            acc.add("} else " + inner[0])
            i = 1
            while i < inner.count { acc.add(inner[i]); i = i + 1 }
          }
        }
        case _ -> {
          acc.add("} else {")
          val eb = indentDoc(2, singleLineDoc(exprInline(0, e2)))
          i = 0
          while i < eb.count { acc.add(eb[i]); i = i + 1 }
          acc.add("}")
        }
      }
    }
  }
  acc
}

func forLines(lbl: in Option[String], p: in Pattern, it: in Expr, b: in Block, ctx: inout FmtCtx): List[String] {
  val ls = match lbl {
    case Some(l) -> l + ": "
    case None    -> ""
  }
  val head = singleLineDoc(ls + "for " + patStr(p) + " in " + exprInline(0, it) + " {")
  concatDoc3(head, indentDoc(2, blockLines(b, ctx)), singleLineDoc("}"))
}

func whileLines(lbl: in Option[String], c: in Expr, b: in Block, ctx: inout FmtCtx): List[String] {
  val ls = match lbl {
    case Some(l) -> l + ": "
    case None    -> ""
  }
  val head = singleLineDoc(ls + "while " + exprInline(0, c) + " {")
  concatDoc3(head, indentDoc(2, blockLines(b, ctx)), singleLineDoc("}"))
}

func loopLines(lbl: in Option[String], b: in Block, ctx: inout FmtCtx): List[String] {
  val ls = match lbl {
    case Some(l) -> l + ": "
    case None    -> ""
  }
  val head = singleLineDoc(ls + "do {")
  concatDoc3(head, indentDoc(2, blockLines(b, ctx)), singleLineDoc("}"))
}

func tryLines(body: in Block, catches: in List[CatchClause], finally_: in Option[Block], ctx: inout FmtCtx): List[String] {
  val acc: List[String] = newList()
  acc.add("try {")
  val bd = indentDoc(2, blockLines(body, ctx))
  var i = 0
  while i < bd.count { acc.add(bd[i]); i = i + 1 }
  i = 0
  while i < catches.count {
    val c = catches[i]
    val bindStr = match c.bindName {
      case Some(b) -> " as " + b
      case None    -> ""
    }
    acc.add("} catch " + c.typeName + bindStr + " {")
    val cb = indentDoc(2, blockLines(c.body, ctx))
    var j = 0
    while j < cb.count { acc.add(cb[j]); j = j + 1 }
    i = i + 1
  }
  match finally_ {
    case None -> {}
    case Some(fb) -> {
      acc.add("} finally {")
      val fb2 = indentDoc(2, blockLines(fb, ctx))
      var k = 0
      while k < fb2.count { acc.add(fb2[k]); k = k + 1 }
    }
  }
  acc.add("}")
  acc
}

func deferLines(b: in Block, ctx: inout FmtCtx): List[String] {
  val head = singleLineDoc("defer {")
  concatDoc3(head, indentDoc(2, blockLines(b, ctx)), singleLineDoc("}"))
}

func scopeLines(bindStr: in Option[String], b: in Block, ctx: inout FmtCtx): List[String] {
  val bs = match bindStr {
    case Some(n) -> " " + n
    case None    -> ""
  }
  val head = singleLineDoc("scope" + bs + " {")
  concatDoc3(head, indentDoc(2, blockLines(b, ctx)), singleLineDoc("}"))
}
