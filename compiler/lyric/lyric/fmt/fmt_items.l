// fmt/fmt_items.l — item printers for the self-hosted Lyric formatter.
// Mirrors the `itemDoc`, `funcDoc`, `recordDoc`, `unionDoc`, `enumDoc`,
// and `protectedMemberDoc` rec-group helpers from Fmt.fs.
package Lyric.Fmt

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// Field decl (used by record / opaque / extern / protected immutable).
// ─────────────────────────────────────────────────────────────────────────────

/// Build a function-signature `Doc` from a `prefix` (e.g.
/// `"pub func foo("`), a `suffix` (e.g. `"): Int"`), the column where
/// the first param starts (`paramsCol`, = `prefix.length` at item-
/// indent 0), and the parameter list.  Inline if the inline rendering
/// fits the 120-char budget given `suffix.length`; otherwise multi-
/// line with one param per line and the closing paren + suffix on
/// its own line.
pub func funcSigDocFromParts(
    prefix: in String,
    suffix: in String,
    paramsCol: in Int,
    ctx: inout FmtCtx,
    params: in List[Param]): List[String] {
  if paramsFitInline(paramsCol, params, suffix.length)
     and not hasTriviaBetweenParams(ctx, params) {
    val inline = paramsStr(params)
    return singleLineDoc(prefix + inline + suffix)
  }
  val pd = paramsAtCol(paramsCol, ctx, params)
  // Multi-line: prefix on first line, params indented by 2, suffix
  // on its own line at the prefix's indent (== col 0 of the sigDoc).
  val acc: List[String] = newList()
  acc.add(prefix)
  var i = 0
  while i < pd.count {
    val line = pd[i]
    if line == "" { acc.add("") } else { acc.add("  " + line) }
    i = i + 1
  }
  acc.add(suffix)
  acc
}

@pure
func hasTriviaBetweenParams(ctx: in FmtCtx, ps: in List[Param]): Bool {
  if ps.count == 0 { return false }
  // Use the cursor's current position as the lower bound rather than
  // `ps[0].span.startPos.offset`: a parameter's `span` starts at the
  // parameter's first token (the name), so comments living BEFORE the
  // first param (e.g. between `(` and `// x is the input`) are not
  // covered by `[firstStart, lastEnd)`.  If any unpopped trivia falls
  // before the last param's end, force multi-line.
  val last = ps[ps.count - 1].span.endPos.offset
  if ctx.cursor >= ctx.items.count { return false }
  // Compare against `harvestedItemOffset` of the next unpopped item.
  // `hasTriviaInRange(ctx, lo, hi)` does the right thing when `lo` is
  // already at-or-below the cursor's first item — since the function
  // walks the cursor forward and stops at `hi`.  Pass `lo = 0`: any
  // unpopped item with offset `< last` triggers multi-line.
  hasTriviaInRange(ctx, 0, last)
}

/// Append `suffix` to the last line of `doc`.  Used to attach
/// `" = expr"` / `" {"` / etc. to a multi-line signature whose last
/// line is the closing paren + return-type segment.
@pure
pub func appendToLastLine(doc: in List[String], suffix: in String): List[String] {
  if doc.count == 0 { return singleLineDoc(suffix) }
  val acc: List[String] = newList()
  var i = 0
  while i < doc.count - 1 {
    acc.add(doc[i])
    i = i + 1
  }
  acc.add(doc[doc.count - 1] + suffix)
  acc
}

@pure
func contractClauseStartOffset(cc: in ContractClause): Int {
  match cc {
    case CCRequires(_, sp)  -> sp.startPos.offset
    case CCEnsures(_, sp)   -> sp.startPos.offset
    case CCWhen(_, sp)      -> sp.startPos.offset
    case CCDecreases(_, sp) -> sp.startPos.offset
    case CCRaises(_, sp)    -> sp.startPos.offset
  }
}

/// Append `popTriviaBefore` output to `acc`, prefixing each non-blank
/// line with the contract-clause indent (`  `).  Blank-line markers
/// stay literally `""` so `joinLines`' `trimEnd` doesn't try to
/// strip indented whitespace.
func appendIndentedTrivia(acc: inout List[String], items: in List[String]): Unit {
  var k = 0
  while k < items.count {
    val line = items[k]
    if line == "" { acc.add("") } else { acc.add("  " + line) }
    k = k + 1
  }
}

pub func fieldDeclStr(fd: in FieldDecl): String {
  val vis = match fd.visibility {
    case Some(_) -> "pub "
    case None    -> ""
  }
  val defStr = match fd.dflt {
    case Some(e) -> " = " + exprInline(0, e)
    case None    -> ""
  }
  vis + fd.name + ": " + typeStr(fd.ty) + defStr
}

// ─────────────────────────────────────────────────────────────────────────────
// Function signature (sig-only form, no body).
// ─────────────────────────────────────────────────────────────────────────────

pub func funcSigStr(sg: in FunctionSig): String {
  val asyncStr = if sg.isAsync { "async " } else { "" }
  val gens     = genParamsStr(sg.generics)
  val params   = paramsStr(sg.params)
  val retStr = match sg.ret {
    case Some(t) -> ": " + typeStr(t)
    case None    -> ""
  }
  asyncStr + "func " + sg.name + gens + "(" + params + ")" + retStr
}

// ─────────────────────────────────────────────────────────────────────────────
// Function decl.  Mirrors `funcDoc`.
// ─────────────────────────────────────────────────────────────────────────────

pub func funcDoc(visStr: in String, fn: in FunctionDecl, ctx: inout FmtCtx): List[String] {
  val annoLines = annotationLines(fn.annotations)
  val fnDocLs   = docLines(fn.docComments)
  val asyncStr  = if fn.isAsync { "async " } else { "" }
  val gens      = genParamsStr(fn.generics)
  val retStr = match fn.ret {
    case Some(t) -> ": " + typeStr(t)
    case None    -> ""
  }
  // Width-driven multi-line signature: keep inline when budget +
  // trivia-peek allow, otherwise break on the parameter list with
  // Black-style "magic trailing comma".  Item col is 0 (top-level)
  // or 2 (member of a record/protected type body); we use 0 here as
  // the conservative default — funcs nested 1 level deep run a few
  // chars under budget rather than over.
  val sigPrefix = visStr + asyncStr + "func " + fn.name + gens + "("
  val sigSuffix = ")" + retStr
  val paramsCol = sigPrefix.length
  val sig = funcSigDocFromParts(sigPrefix, sigSuffix, paramsCol, ctx, fn.params)

  // Order on the wire: signature → where? → contracts → body.
  // The self-hosted parser accepts `where` only BEFORE the contract
  // clauses (see `parseFunctionDeclBody`), so emitting them in the
  // reverse order would round-trip the formatter's own output into a
  // P0040 parse error.  Pop trivia and emit lines in source order so
  // the `FmtCtx` cursor advances monotonically too.
  val whereLines: List[String] = newList()
  match fn.whereClause {
    case Some(wc) -> {
      val pre = popTriviaBefore(ctx, wc.span.startPos.offset)
      appendIndentedTrivia(whereLines, pre)
      whereLines.add("  " + whereClauseStr(Some(value = wc)))
    }
    case None -> {}
  }
  val contractLines: List[String] = newList()
  var i = 0
  while i < fn.contracts.count {
    val c = fn.contracts[i]
    val pre = popTriviaBefore(ctx, contractClauseStartOffset(c))
    appendIndentedTrivia(contractLines, pre)
    val cd = indentDoc(2, contractDoc(2, ctx, c))
    var k = 0
    while k < cd.count { contractLines.add(cd[k]); k = k + 1 }
    i = i + 1
  }
  val extras = concatDoc(whereLines, contractLines)
  val body: List[String] = match fn.body {
    case None -> {
      val acc: List[String] = newList()
      var j = 0
      while j < sig.count { acc.add(sig[j]); j = j + 1 }
      j = 0
      while j < extras.count { acc.add(extras[j]); j = j + 1 }
      acc
    }
    case Some(FBExpr(e)) -> {
      if extras.count == 0 {
        appendToLastLine(sig, " = " + exprInline(0, e))
      } else {
        val acc: List[String] = newList()
        var j = 0
        while j < sig.count { acc.add(sig[j]); j = j + 1 }
        j = 0
        while j < extras.count { acc.add(extras[j]); j = j + 1 }
        acc.add("  = " + exprInline(0, e))
        acc
      }
    }
    case Some(FBBlock(b)) -> {
      if extras.count == 0 {
        val head = appendToLastLine(sig, " {")
        concatDoc3(head, indentDoc(2, blockLines(b, ctx)), singleLineDoc("}"))
      } else {
        val acc: List[String] = newList()
        var j = 0
        while j < sig.count { acc.add(sig[j]); j = j + 1 }
        j = 0
        while j < extras.count { acc.add(extras[j]); j = j + 1 }
        acc.add("{")
        val bd = indentDoc(2, blockLines(b, ctx))
        j = 0
        while j < bd.count { acc.add(bd[j]); j = j + 1 }
        acc.add("}")
        acc
      }
    }
  }
  concatDoc3(fnDocLs, annoLines, body)
}

// ─────────────────────────────────────────────────────────────────────────────
// Record-shaped declarations (record / exposed record).
// ─────────────────────────────────────────────────────────────────────────────

func whereClauseLines(wc: in Option[WhereClause]): List[String] {
  val s = whereClauseStr(wc)
  if s == "" { emptyDoc() } else { singleLineDoc("  " + s) }
}

pub func recordMemberLines(m: in RecordMember, ctx: inout FmtCtx): List[String] {
  match m {
    case RMField(field)   -> singleLineDoc(fieldDeclStr(field))
    case RMInvariant(inv) -> singleLineDoc("invariant: " + exprInline(0, inv.expr))
    case RMFunc(fn)       -> funcDoc("", fn, ctx)
  }
}

@pure
func recordMemberStartOffset(m: in RecordMember): Int {
  match m {
    case RMField(field)   -> field.span.startPos.offset
    case RMInvariant(inv) -> inv.span.startPos.offset
    case RMFunc(fn)       -> fn.span.startPos.offset
  }
}

pub func recordDoc(visStr: in String, kw: in String, name: in String,
                   gens: in Option[GenericParams], wc: in Option[WhereClause],
                   members: in List[RecordMember], bodyEnd: in Int,
                   ctx: inout FmtCtx): List[String] {
  val genStr = genParamsStr(gens)
  val whereL = whereClauseLines(wc)
  val mLines: List[String] = newList()
  var i = 0
  while i < members.count {
    val m = members[i]
    val pre = popTriviaBefore(ctx, recordMemberStartOffset(m))
    var k = 0
    while k < pre.count { mLines.add(pre[k]); k = k + 1 }
    val ml = recordMemberLines(m, ctx)
    var j = 0
    while j < ml.count { mLines.add(ml[j]); j = j + 1 }
    i = i + 1
  }
  // Trailing comments before the closing brace.
  val tail = popCommentsBefore(ctx, bodyEnd)
  var k = 0
  while k < tail.count { mLines.add(tail[k]); k = k + 1 }

  val acc: List[String] = newList()
  acc.add(visStr + kw + " " + name + genStr + " {")
  i = 0
  while i < whereL.count { acc.add(whereL[i]); i = i + 1 }
  val ind = indentDoc(2, mLines)
  i = 0
  while i < ind.count { acc.add(ind[i]); i = i + 1 }
  acc.add("}")
  acc
}

// ─────────────────────────────────────────────────────────────────────────────
// Union decl.
// ─────────────────────────────────────────────────────────────────────────────

pub func unionDoc(visStr: in String, ud: in UnionDecl, ctx: inout FmtCtx): List[String] {
  val gens   = genParamsStr(ud.generics)
  val whereL = whereClauseLines(ud.whereClause)
  val cases: List[String] = newList()
  var i = 0
  while i < ud.cases.count {
    val c = ud.cases[i]
    val pre = popTriviaBefore(ctx, c.span.startPos.offset)
    var k = 0
    while k < pre.count { cases.add(pre[k]); k = k + 1 }
    val cd = docLines(c.docComments)
    val ca = annotationLines(c.annotations)
    var j = 0
    while j < cd.count { cases.add(cd[j]); j = j + 1 }
    j = 0
    while j < ca.count { cases.add(ca[j]); j = j + 1 }
    val fields: List[String] = newList()
    var ki = 0
    while ki < c.fields.count {
      match c.fields[ki] {
        case UFNamed(n, ty, _) -> fields.add(n + ": " + typeStr(ty))
        case UFPos(ty, _)      -> fields.add(typeStr(ty))
      }
      ki = ki + 1
    }
    if c.fields.count == 0 {
      cases.add("case " + c.name)
    } else {
      cases.add("case " + c.name + "(" + joinStrings(fields, ", ") + ")")
    }
    i = i + 1
  }
  // Trailing comments before the closing brace.
  val tail = popCommentsBefore(ctx, ud.span.endPos.offset)
  var ki = 0
  while ki < tail.count { cases.add(tail[ki]); ki = ki + 1 }

  val acc: List[String] = newList()
  acc.add(visStr + "union " + ud.name + gens + " {")
  i = 0
  while i < whereL.count { acc.add(whereL[i]); i = i + 1 }
  val ind = indentDoc(2, cases)
  i = 0
  while i < ind.count { acc.add(ind[i]); i = i + 1 }
  acc.add("}")
  acc
}

// ─────────────────────────────────────────────────────────────────────────────
// Enum decl.
// ─────────────────────────────────────────────────────────────────────────────

pub func enumDoc(visStr: in String, ed: in EnumDecl, ctx: inout FmtCtx): List[String] {
  val cases: List[String] = newList()
  var i = 0
  while i < ed.cases.count {
    val c = ed.cases[i]
    val pre = popTriviaBefore(ctx, c.span.startPos.offset)
    var k = 0
    while k < pre.count { cases.add(pre[k]); k = k + 1 }
    val cd = docLines(c.docComments)
    val ca = annotationLines(c.annotations)
    var j = 0
    while j < cd.count { cases.add(cd[j]); j = j + 1 }
    j = 0
    while j < ca.count { cases.add(ca[j]); j = j + 1 }
    cases.add("case " + c.name)
    i = i + 1
  }
  // Trailing comments before the closing brace.
  val tail = popCommentsBefore(ctx, ed.span.endPos.offset)
  var ki = 0
  while ki < tail.count { cases.add(tail[ki]); ki = ki + 1 }

  val acc: List[String] = newList()
  acc.add(visStr + "enum " + ed.name + " {")
  val ind = indentDoc(2, cases)
  i = 0
  while i < ind.count { acc.add(ind[i]); i = i + 1 }
  acc.add("}")
  acc
}

// ─────────────────────────────────────────────────────────────────────────────
// Protected member.
// ─────────────────────────────────────────────────────────────────────────────

func protectedFieldStr(pf: in ProtectedField): List[String] {
  match pf {
    case PFVar(n, ty, init, _) -> {
      val initStr = match init {
        case Some(e) -> " = " + exprInline(0, e)
        case None    -> ""
      }
      singleLineDoc("var " + n + ": " + typeStr(ty) + initStr)
    }
    case PFLet(n, ty, init, _) -> {
      val initStr = match init {
        case Some(e) -> " = " + exprInline(0, e)
        case None    -> ""
      }
      singleLineDoc("let " + n + ": " + typeStr(ty) + initStr)
    }
    case PFImmutable(field) -> singleLineDoc(fieldDeclStr(field))
  }
}

func entryDoc(ed: in EntryDecl, ctx: inout FmtCtx): List[String] {
  val vStr = match ed.visibility {
    case Some(_) -> "pub "
    case None    -> ""
  }
  val params = paramsStr(ed.params)
  val retStr = match ed.ret {
    case Some(t) -> ": " + typeStr(t)
    case None    -> ""
  }
  val sig = vStr + "entry " + ed.name + "(" + params + ")" + retStr
  val conLines: List[String] = newList()
  var i = 0
  while i < ed.contracts.count {
    val c = ed.contracts[i]
    val pre = popTriviaBefore(ctx, contractClauseStartOffset(c))
    appendIndentedTrivia(conLines, pre)
    val cd = indentDoc(2, contractDoc(2, ctx, c))
    var k = 0
    while k < cd.count { conLines.add(cd[k]); k = k + 1 }
    i = i + 1
  }
  val bodyLines: List[String] = match ed.body {
    case FBBlock(b) -> blockLines(b, ctx)
    case FBExpr(e)  -> singleLineDoc(exprInline(0, e))
  }
  if conLines.count == 0 {
    val head = singleLineDoc(sig + " {")
    concatDoc3(head, indentDoc(2, bodyLines), singleLineDoc("}"))
  } else {
    val acc: List[String] = newList()
    acc.add(sig)
    i = 0
    while i < conLines.count { acc.add(conLines[i]); i = i + 1 }
    acc.add("{")
    val bd = indentDoc(2, bodyLines)
    i = 0
    while i < bd.count { acc.add(bd[i]); i = i + 1 }
    acc.add("}")
    acc
  }
}

pub func protectedMemberDoc(pm: in ProtectedMember, ctx: inout FmtCtx): List[String] {
  match pm {
    case PMField(pf)     -> protectedFieldStr(pf)
    case PMInvariant(ic) -> singleLineDoc("invariant: " + exprInline(0, ic.expr))
    case PMEntry(ed)     -> entryDoc(ed, ctx)
    case PMFunc(fn)      -> funcDoc("", fn, ctx)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Top-level item dispatch.  Mirrors `itemDoc` in Fmt.fs.
// ─────────────────────────────────────────────────────────────────────────────

pub func itemDoc(item: in Item, ctx: inout FmtCtx): List[String] {
  val visStr = match item.visibility {
    case Some(_) -> "pub "
    case None    -> ""
  }
  val annoLines = annotationLines(item.annotations)
  val header = concatDoc(docLines(item.docComments), annoLines)
  match item.kind {
    case IFunc(fn)        -> itemFunc(visStr, fn, ctx)
    case IRecord(rd)      -> concatDoc(header, recordDoc(visStr, "record", rd.name, rd.generics, rd.whereClause, rd.members, rd.span.endPos.offset, ctx))
    case IExposedRec(rd)  -> concatDoc(header, recordDoc(visStr, "exposed record", rd.name, rd.generics, rd.whereClause, rd.members, rd.span.endPos.offset, ctx))
    case IUnion(ud)       -> concatDoc(header, unionDoc(visStr, ud, ctx))
    case IEnum(ed)        -> concatDoc(header, enumDoc(visStr, ed, ctx))
    case IOpaque(od)      -> opaqueDoc(visStr, item, od, ctx)
    case IDistinctType(dt)-> concatDoc(header, distinctDoc(visStr, dt))
    case ITypeAlias(ta)   -> concatDoc(header, typeAliasDoc(visStr, ta))
    case IProtected(pd)   -> concatDoc(header, protectedTypeDoc(visStr, pd, ctx))
    case IInterface(id)   -> concatDoc(header, interfaceDoc(visStr, id, ctx))
    case IImpl(id)        -> concatDoc(header, implDoc(id, ctx))
    case IWire(wd)        -> concatDoc(header, wireDoc(wd, ctx))
    case IScopeKind(sd)   -> concatDoc(header, singleLineDoc("scope_kind " + sd.name))
    case IConst(cd)       -> concatDoc(header, constDoc(visStr, cd))
    case IVal(vd)         -> concatDoc(header, valDoc(visStr, vd))
    case IExtern(ep)      -> externDoc(item, ep)
    case IExternType(et)  -> concatDoc(header, externTypeDoc(visStr, et))
    case ITest(td)        -> concatDoc(header, testDoc(td, ctx))
    case IProperty(pd)    -> concatDoc(header, propertyDoc(pd, ctx))
    case IFixture(fd)     -> concatDoc(header, fixtureDoc(fd))
    case IConfig(cd)      -> concatDoc(header, configDoc(visStr, cd))
    case IAspect(ad)      -> concatDoc(header, aspectDoc(visStr, ad, ctx))
    case IError           -> singleLineDoc("// <parse-error>")
  }
}

func itemFunc(visStr: in String, fn: in FunctionDecl, ctx: inout FmtCtx): List[String] {
  // funcDoc already prepends doc comments + annotations from `fn`
  // itself; we don't re-emit `item.DocComments` because Item's doc
  // comments are the same list (see parser).
  funcDoc(visStr, fn, ctx)
}

func opaqueDoc(visStr: in String, item: in Item, od: in OpaqueTypeDecl, ctx: inout FmtCtx): List[String] {
  val odAnnos = annotationLines(od.annotations)
  val gens = genParamsStr(od.generics)
  val whereL = whereClauseLines(od.whereClause)
  val docL = docLines(item.docComments)
  if not od.hasBody {
    concatDoc3(docL, odAnnos, singleLineDoc(visStr + "opaque type " + od.name + gens))
  } else {
    val mLines: List[String] = newList()
    var i = 0
    while i < od.members.count {
      match od.members[i] {
        case OMField(fd)    -> mLines.add(fieldDeclStr(fd))
        case OMInvariant(ic)-> mLines.add("invariant: " + exprInline(0, ic.expr))
      }
      i = i + 1
    }
    val acc: List[String] = newList()
    var j = 0
    while j < docL.count { acc.add(docL[j]); j = j + 1 }
    j = 0
    while j < odAnnos.count { acc.add(odAnnos[j]); j = j + 1 }
    acc.add(visStr + "opaque type " + od.name + gens + " {")
    j = 0
    while j < whereL.count { acc.add(whereL[j]); j = j + 1 }
    val ind = indentDoc(2, mLines)
    j = 0
    while j < ind.count { acc.add(ind[j]); j = j + 1 }
    acc.add("}")
    acc
  }
}

func distinctDoc(visStr: in String, dt: in DistinctTypeDecl): List[String] {
  val gens = genParamsStr(dt.generics)
  val rangeStr = match dt.rangeClause {
    case Some(rb) -> " range " + rangeBoundStr(rb)
    case None     -> ""
  }
  val derivesStr =
    if dt.derives.count == 0 { "" }
    else { " derives " + joinStrings(dt.derives, ", ") }
  singleLineDoc(visStr + "type " + dt.name + gens + " = " + typeStr(dt.underlying) + rangeStr + derivesStr)
}

func typeAliasDoc(visStr: in String, ta: in TypeAliasDecl): List[String] {
  singleLineDoc(visStr + "alias " + ta.name + genParamsStr(ta.generics) + " = " + typeStr(ta.rhs))
}

func protectedTypeDoc(visStr: in String, pd: in ProtectedTypeDecl, ctx: inout FmtCtx): List[String] {
  val gens = genParamsStr(pd.generics)
  val whereL = whereClauseLines(pd.whereClause)
  val mLines: List[String] = newList()
  var i = 0
  while i < pd.members.count {
    val ml = protectedMemberDoc(pd.members[i], ctx)
    var j = 0
    while j < ml.count { mLines.add(ml[j]); j = j + 1 }
    i = i + 1
  }
  val acc: List[String] = newList()
  acc.add(visStr + "protected type " + pd.name + gens + " {")
  i = 0
  while i < whereL.count { acc.add(whereL[i]); i = i + 1 }
  val ind = indentDoc(2, mLines)
  i = 0
  while i < ind.count { acc.add(ind[i]); i = i + 1 }
  acc.add("}")
  acc
}

func interfaceDoc(visStr: in String, id: in InterfaceDecl, ctx: inout FmtCtx): List[String] {
  val gens = genParamsStr(id.generics)
  val whereL = whereClauseLines(id.whereClause)
  val mLines: List[String] = newList()
  var i = 0
  while i < id.members.count {
    match id.members[i] {
      case IMSig(sg)   -> mLines.add(funcSigStr(sg))
      case IMFunc(fn)  -> {
        val fd = funcDoc("", fn, ctx)
        var j = 0
        while j < fd.count { mLines.add(fd[j]); j = j + 1 }
      }
      case IMAssoc(a)  -> {
        match a.dflt {
          case Some(t) -> mLines.add("type " + a.name + " = " + typeStr(t))
          case None    -> mLines.add("type " + a.name)
        }
      }
    }
    i = i + 1
  }
  val acc: List[String] = newList()
  acc.add(visStr + "interface " + id.name + gens + " {")
  i = 0
  while i < whereL.count { acc.add(whereL[i]); i = i + 1 }
  val ind = indentDoc(2, mLines)
  i = 0
  while i < ind.count { acc.add(ind[i]); i = i + 1 }
  acc.add("}")
  acc
}

func implDoc(id: in ImplDecl, ctx: inout FmtCtx): List[String] {
  val gens = genParamsStr(id.generics)
  val target = typeStr(id.target)
  val ifStr = constraintRefStr(id.iface)
  val whereL = whereClauseLines(id.whereClause)
  val mLines: List[String] = newList()
  var i = 0
  while i < id.members.count {
    match id.members[i] {
      case IMplFunc(fn) -> {
        val fd = funcDoc("", fn, ctx)
        var j = 0
        while j < fd.count { mLines.add(fd[j]); j = j + 1 }
      }
      case IMplAssoc(a) -> {
        match a.dflt {
          case Some(t) -> mLines.add("type " + a.name + " = " + typeStr(t))
          case None    -> mLines.add("type " + a.name)
        }
      }
    }
    i = i + 1
  }
  val acc: List[String] = newList()
  acc.add("impl" + gens + " " + ifStr + " for " + target + " {")
  i = 0
  while i < whereL.count { acc.add(whereL[i]); i = i + 1 }
  val ind = indentDoc(2, mLines)
  i = 0
  while i < ind.count { acc.add(ind[i]); i = i + 1 }
  acc.add("}")
  acc
}

func wireDoc(wd: in WireDecl, ctx: inout FmtCtx): List[String] {
  val params = paramsStr(wd.params)
  val mLines: List[String] = newList()
  var i = 0
  while i < wd.members.count {
    match wd.members[i] {
      case WMProvided(n, ty, _) -> mLines.add("provided " + n + ": " + typeStr(ty))
      case WMSingleton(n, ty, init, _) -> mLines.add("singleton " + n + ": " + typeStr(ty) + " = " + exprInline(0, init))
      case WMScoped(sk, n, ty, init, _) -> mLines.add("scoped " + sk + " " + n + ": " + typeStr(ty) + " = " + exprInline(0, init))
      case WMBind(iface, prov, _) -> mLines.add("bindStr " + typeStr(iface) + " = " + exprInline(0, prov))
      case WMExpose(n, _) -> mLines.add("expose " + n)
      case WMLocal(n, ty, init, _) -> {
        val tyStr = match ty {
          case Some(t) -> ": " + typeStr(t)
          case None    -> ""
        }
        mLines.add("val " + n + tyStr + " = " + exprInline(0, init))
      }
    }
    i = i + 1
  }
  val acc: List[String] = newList()
  acc.add("wire " + wd.name + "(" + params + ") {")
  val ind = indentDoc(2, mLines)
  i = 0
  while i < ind.count { acc.add(ind[i]); i = i + 1 }
  acc.add("}")
  acc
}

func constDoc(visStr: in String, cd: in ConstDecl): List[String] {
  singleLineDoc(visStr + "const " + cd.name + ": " + typeStr(cd.ty) + " = " + exprInline(0, cd.init))
}

func valDoc(visStr: in String, vd: in ValDecl): List[String] {
  val tyStr = match vd.ty {
    case Some(t) -> ": " + typeStr(t)
    case None    -> ""
  }
  singleLineDoc(visStr + "val " + patStr(vd.pattern) + tyStr + " = " + exprInline(0, vd.init))
}

func externDoc(item: in Item, ep: in ExternPackageDecl): List[String] {
  val docL = docLines(item.docComments)
  val epAnnos = annotationLines(ep.annotations)
  val mLines: List[String] = newList()
  var i = 0
  while i < ep.members.count {
    match ep.members[i] {
      case EMRecord(r)        -> mLines.add("record " + r.name)
      case EMExposedRec(r)    -> mLines.add("exposed record " + r.name)
      case EMUnion(u)         -> mLines.add("union " + u.name)
      case EMEnum(e)          -> mLines.add("enum " + e.name)
      case EMOpaque(o)        -> mLines.add("opaque type " + o.name)
      case EMSig(sg)          -> mLines.add(funcSigStr(sg))
      case EMTypeAlias(ta)    -> mLines.add("type " + ta.name)
      case EMDistinctType(d)  -> mLines.add("distinct type " + d.name)
    }
    i = i + 1
  }
  val acc: List[String] = newList()
  var j = 0
  while j < docL.count { acc.add(docL[j]); j = j + 1 }
  j = 0
  while j < epAnnos.count { acc.add(epAnnos[j]); j = j + 1 }
  acc.add("extern " + pathStr(ep.path) + " {")
  val ind = indentDoc(2, mLines)
  j = 0
  while j < ind.count { acc.add(ind[j]); j = j + 1 }
  acc.add("}")
  acc
}

func externTypeDoc(visStr: in String, et: in ExternTypeDecl): List[String] {
  singleLineDoc(visStr + "extern type " + et.name + genParamsStr(et.generics) + " = \"" + et.clrName + "\"")
}

func testDoc(td: in TestDecl, ctx: inout FmtCtx): List[String] {
  val acc: List[String] = newList()
  acc.add("test \"" + escapeStr(td.title) + "\" {")
  val ind = indentDoc(2, blockLines(td.body, ctx))
  var i = 0
  while i < ind.count { acc.add(ind[i]); i = i + 1 }
  acc.add("}")
  acc
}

func propertyDoc(pd: in PropertyDecl, ctx: inout FmtCtx): List[String] {
  val parts: List[String] = newList()
  var i = 0
  while i < pd.forAll.count {
    val b = pd.forAll[i]
    parts.add(b.name + ": " + typeStr(b.ty))
    i = i + 1
  }
  val whereStr = match pd.guardExpr {
    case Some(w) -> " where " + exprInline(0, w)
    case None    -> ""
  }
  val acc: List[String] = newList()
  acc.add("property \"" + escapeStr(pd.title) + "\" forall (" + joinStrings(parts, ", ") + ")" + whereStr + " {")
  val ind = indentDoc(2, blockLines(pd.body, ctx))
  i = 0
  while i < ind.count { acc.add(ind[i]); i = i + 1 }
  acc.add("}")
  acc
}

func fixtureDoc(fd: in FixtureDecl): List[String] {
  val tyStr = match fd.ty {
    case Some(t) -> ": " + typeStr(t)
    case None    -> ""
  }
  singleLineDoc("fixture " + fd.name + tyStr + " = " + exprInline(0, fd.init))
}

// ─────────────────────────────────────────────────────────────────────────────
// D046 config block render.
// ─────────────────────────────────────────────────────────────────────────────

func configFieldLine(f: in ConfigField): String {
  val annPrefix: List[String] = annotationLines(f.annotations)
  // Annotations on a config field render on their own preceding lines;
  // the field itself is one line with `name: T = default?`.
  val dflt = match f.default {
    case Some(e) -> " = " + exprInline(0, e)
    case None    -> ""
  }
  "  " + f.name + ": " + typeStr(f.ty) + dflt
}

func configDoc(visStr: in String, cd: in ConfigDecl): List[String] {
  val acc: List[String] = newList()
  acc.add(visStr + "config " + cd.name + " {")
  var i = 0
  while i < cd.fields.count {
    val f = cd.fields[i]
    val annLines = annotationLines(f.annotations)
    var k = 0
    while k < annLines.count { acc.add("  " + annLines[k]); k = k + 1 }
    acc.add(configFieldLine(f))
    i = i + 1
  }
  acc.add("}")
  acc
}

// ─────────────────────────────────────────────────────────────────────────────
// D047 aspect block render.
// ─────────────────────────────────────────────────────────────────────────────

func aspectMatcherPred(m: in AspectMatcher): String {
  match m {
    case AMNameLike(g, _)         -> "name like \"" + g + "\""
    case AMAnnotated(n, _)        -> "annotated: @" + n
    case AMVisibility(v, _)       -> "visibility: " + v
    case AMSignatureReturns(t, _) -> "signature: returns \"" + t + "\""
  }
}

func aspectDoc(visStr: in String, ad: in AspectDecl, ctx: inout FmtCtx): List[String] {
  val acc: List[String] = newList()
  acc.add(visStr + "aspect " + ad.name + " {")
  // §6 ordering: emit wraps:/inside: before matches:
  if ad.wraps.count > 0 {
    val wrapStr: String = joinStrings(ad.wraps, ", ")
    acc.add("  wraps: " + wrapStr)
  }
  if ad.inside.count > 0 {
    val insideStr: String = joinStrings(ad.inside, ", ")
    acc.add("  inside: " + insideStr)
  }
  if ad.matches.count > 0 {
    val preds: List[String] = newList()
    var i = 0
    while i < ad.matches.count {
      preds.add(aspectMatcherPred(ad.matches[i]))
      i = i + 1
    }
    val body = joinStrings(preds, " and ")
    val ex =
      if ad.exceptNames.count > 0 {
        " except name in { " + joinStrings(ad.exceptNames, ", ") + " }"
      } else {
        ""
      }
    acc.add("  matches: " + body + ex)
  }
  // §5 contract augmentation: emit requires:/ensures: before the around block.
  var ci = 0
  while ci < ad.contracts.count {
    val cd = indentDoc(2, contractDoc(2, ctx, ad.contracts[ci]))
    var k = 0
    while k < cd.count { acc.add(cd[k]); k = k + 1 }
    ci = ci + 1
  }
  match ad.around {
    case Some(ar) -> {
      val retStr = match ar.retName {
        case Some(r) -> " -> " + r
        case None    -> ""
      }
      acc.add("  around(" + ar.argsName + ")" + retStr + " {")
      val body = blockLines(ar.body, ctx)
      var k = 0
      while k < body.count { acc.add("    " + body[k]); k = k + 1 }
      acc.add("  }")
    }
    case None -> {}
  }
  acc.add("}")
  acc
}

// ─────────────────────────────────────────────────────────────────────────────
// Imports.
// ─────────────────────────────────────────────────────────────────────────────

pub func importDoc(imp: in ImportDecl): List[String] {
  val selStr = match imp.selector {
    case None -> ""
    case Some(ISSingle(item)) -> {
      val a = match item.asAlias {
        case Some(a) -> " as " + a
        case None    -> ""
      }
      "." + item.name + a
    }
    case Some(ISGroup(items)) -> {
      val parts: List[String] = newList()
      var i = 0
      while i < items.count {
        val it = items[i]
        match it.asAlias {
          case Some(a) -> parts.add(it.name + " as " + a)
          case None    -> parts.add(it.name)
        }
        i = i + 1
      }
      ".{" + joinStrings(parts, ", ") + "}"
    }
  }
  val aliasStr = match imp.asAlias {
    case Some(a) -> " as " + a
    case None    -> ""
  }
  val kw = if imp.isPubUse { "pub use" } else { "import" }
  singleLineDoc(kw + " " + pathStr(imp.path) + selStr + aliasStr)
}
