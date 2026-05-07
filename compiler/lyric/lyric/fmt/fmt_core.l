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
  else { '?' }
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
    case LInt(v, s)         -> longToStr(v) + intSufStr(s)
    case LFloat(v, s)       -> floatLitStr(v) + floatSufStr(s)
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
  val modeStr = match p.mode {
    case PMIn    -> "in "
    case PMOut   -> "acc "
    case PMInout -> "inout "
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

pub func contractStr(cc: in ContractClause): String {
  match cc {
    case CCRequires(ex, _)  -> "requires: " + exprInline(0, ex)
    case CCEnsures(ex, _)   -> "ensures: " + exprInline(0, ex)
    case CCWhen(ex, _)      -> "when: " + exprInline(0, ex)
    case CCDecreases(ex, _) -> "decreases: " + exprInline(0, ex)
    case CCRaises(tys, _)   -> "raises: " + typesStr(tys)
  }
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
// §8. Inline expression printer.  Mirrors `exprInline` in Fmt.fs.
// `minPrec` is the minimum precedence the caller is willing to accept
// without wrapping in parens.
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
    case EBlock(b)          -> "{ " + blockInline(b) + " }"
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
  kw + " (" + joinStrings(parts, ", ") + ")" + whereStr + " { " + exprInline(0, body) + " }"
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
    case EOBBlock(b) -> "{ " + blockInline(b) + " }"
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
    case STry(body, catches)   -> tryInlineStr(body, catches)
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

func tryInlineStr(body: in Block, catches: in List[CatchClause]): String {
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
  "try { " + blockInline(body) + " } " + joinStrings(parts, " ")
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
  joinStrings(itemDoc(item), "; ")
}

// ─────────────────────────────────────────────────────────────────────────────
// §10. Multi-line block printer.  Mirrors `blockLines` and `stmtLines`.
// ─────────────────────────────────────────────────────────────────────────────

pub func blockLines(b: in Block): List[String] {
  val acc: List[String] = newList()
  var i = 0
  while i < b.statements.count {
    val sl = stmtLines(b.statements[i])
    var j = 0
    while j < sl.count {
      acc.add(sl[j])
      j = j + 1
    }
    i = i + 1
  }
  acc
}

pub func stmtLines(s: in Statement): List[String] {
  match s.kind {
    case SLocal(_)         -> singleLineDoc(stmtInline(s))
    case SAssign(_, _, _)  -> singleLineDoc(stmtInline(s))
    case SReturn(_)        -> singleLineDoc(stmtInline(s))
    case SBreak(_)         -> singleLineDoc(stmtInline(s))
    case SContinue(_)      -> singleLineDoc(stmtInline(s))
    case SThrow(_)         -> singleLineDoc(stmtInline(s))
    case SInvariant(_)     -> singleLineDoc(stmtInline(s))
    case SRule(_, _)       -> singleLineDoc(stmtInline(s))
    case SExpr(e)          -> stmtExprLines(s, e)
    case SFor(lbl, p, it, b) -> forLines(lbl, p, it, b)
    case SWhile(lbl, c, b)   -> whileLines(lbl, c, b)
    case SLoop(lbl, b)       -> loopLines(lbl, b)
    case STry(body, catches) -> tryLines(body, catches)
    case SDefer(b)         -> deferLines(b)
    case SScope(bindStr, b)   -> scopeLines(bindStr, b)
    case SItem(item)       -> itemDoc(item)
  }
}

func stmtExprLines(s: in Statement, e: in Expr): List[String] {
  match e.kind {
    case EMatch(scrut, arms)             -> matchLines(scrut, arms)
    case EIf(cond, thn, els, thenForm)   -> {
      if thenForm { singleLineDoc(stmtInline(s)) }
      else { ifBlockLines(cond, thn, els) }
    }
    case _                               -> singleLineDoc(stmtInline(s))
  }
}

func matchLines(scrut: in Expr, arms: in List[MatchArm]): List[String] {
  val head = singleLineDoc("match " + exprInline(0, scrut) + " {")
  val armLines: List[String] = newList()
  var i = 0
  while i < arms.count {
    val a = arms[i]
    val guard = match a.guard {
      case Some(g) -> " if " + exprInline(0, g)
      case None    -> ""
    }
    match a.body {
      case EOBExpr(body) -> {
        armLines.add("case " + patStr(a.pattern) + guard + " -> " + exprInline(0, body))
      }
      case EOBBlock(blk) -> {
        armLines.add("case " + patStr(a.pattern) + guard + " -> {")
        val inner = indentDoc(2, blockLines(blk))
        var j = 0
        while j < inner.count { armLines.add(inner[j]); j = j + 1 }
        armLines.add("}")
      }
    }
    i = i + 1
  }
  concatDoc3(head, indentDoc(2, armLines), singleLineDoc("}"))
}

func ifBlockLines(cond: in Expr, thn: in ExprOrBlock, els: in Option[ExprOrBlock]): List[String] {
  val condStr = exprInline(0, cond)
  val thenDoc = match thn {
    case EOBBlock(b) -> blockLines(b)
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
      val eb = indentDoc(2, blockLines(b))
      i = 0
      while i < eb.count { acc.add(eb[i]); i = i + 1 }
      acc.add("}")
    }
    case Some(EOBExpr(e2)) -> {
      // If the else expression is itself a brace-form `if`, splice it in
      // as an `} else if` chain to mirror Fmt.fs.
      match e2.kind {
        case EIf(c2, t2, eb2, false) -> {
          val inner = ifBlockLines(c2, t2, eb2)
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

func forLines(lbl: in Option[String], p: in Pattern, it: in Expr, b: in Block): List[String] {
  val ls = match lbl {
    case Some(l) -> l + ": "
    case None    -> ""
  }
  val head = singleLineDoc(ls + "for " + patStr(p) + " in " + exprInline(0, it) + " {")
  concatDoc3(head, indentDoc(2, blockLines(b)), singleLineDoc("}"))
}

func whileLines(lbl: in Option[String], c: in Expr, b: in Block): List[String] {
  val ls = match lbl {
    case Some(l) -> l + ": "
    case None    -> ""
  }
  val head = singleLineDoc(ls + "while " + exprInline(0, c) + " {")
  concatDoc3(head, indentDoc(2, blockLines(b)), singleLineDoc("}"))
}

func loopLines(lbl: in Option[String], b: in Block): List[String] {
  val ls = match lbl {
    case Some(l) -> l + ": "
    case None    -> ""
  }
  val head = singleLineDoc(ls + "do {")
  concatDoc3(head, indentDoc(2, blockLines(b)), singleLineDoc("}"))
}

func tryLines(body: in Block, catches: in List[CatchClause]): List[String] {
  val acc: List[String] = newList()
  acc.add("try {")
  val bd = indentDoc(2, blockLines(body))
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
    val cb = indentDoc(2, blockLines(c.body))
    var j = 0
    while j < cb.count { acc.add(cb[j]); j = j + 1 }
    i = i + 1
  }
  acc.add("}")
  acc
}

func deferLines(b: in Block): List[String] {
  val head = singleLineDoc("defer {")
  concatDoc3(head, indentDoc(2, blockLines(b)), singleLineDoc("}"))
}

func scopeLines(bindStr: in Option[String], b: in Block): List[String] {
  val bs = match bindStr {
    case Some(n) -> " " + n
    case None    -> ""
  }
  val head = singleLineDoc("scope" + bs + " {")
  concatDoc3(head, indentDoc(2, blockLines(b)), singleLineDoc("}"))
}
