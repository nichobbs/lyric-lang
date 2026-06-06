//! fmt/fmt_items.l — item printers for the self-hosted Lyric formatter.
//! Mirrors the `itemDoc`, `funcDoc`, `recordDoc`, `unionDoc`, `enumDoc`,
//! and `protectedMemberDoc` rec-group helpers from Fmt.fs.
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
  params: in List[Param],
): List[String] {
  if paramsFitInline(paramsCol, params, suffix.length) and not hasTriviaBetweenParams(ctx, params) {
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
    if line == "" {
      acc.add("")
    } else {
      acc.add("  " + line)
    }
    i = i + 1
  }
  acc.add(suffix)
  acc
}

@pure
func hasTriviaBetweenParams(ctx: in FmtCtx, ps: in List[Param]): Bool {
  if ps.count == 0 {
    return false
  }
  // Use the cursor's current position as the lower bound rather than
  // `ps[0].span.startPos.offset`: a parameter's `span` starts at the
  // parameter's first token (the name), so comments living BEFORE the
  // first param (e.g. between `(` and `// x is the input`) are not
  // covered by `[firstStart, lastEnd)`.  If any unpopped trivia falls
  // before the last param's end, force multi-line.
  val last = ps[ps.count - 1].span.endPos.offset
  if ctx.cursor >= ctx.items.count {
    return false
  }
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
  if doc.count == 0 {
    return singleLineDoc(suffix)
  }
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
    case CCRequires(_, sp) -> sp.startPos.offset
    case CCEnsures(_, sp) -> sp.startPos.offset
    case CCWhen(_, sp) -> sp.startPos.offset
    case CCDecreases(_, sp) -> sp.startPos.offset
    case CCRaises(_, sp) -> sp.startPos.offset
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
    if line == "" {
      acc.add("")
    } else {
      acc.add("  " + line)
    }
    k = k + 1
  }
}

/// Append every line of `items` to `acc` in order, verbatim.
func appendDoc(acc: inout List[String], items: in List[String]): Unit {
  var k = 0
  while k < items.count {
    acc.add(items[k])
    k = k + 1
  }
}

pub func fieldDeclStr(fd: in FieldDecl): String {
  val vis = match fd.visibility { case Some(_) -> "pub "; case None -> "" }
  val defStr = match fd.dflt { case Some(e) -> " = " + exprInline(0, e); case None -> "" }
  val mutStr = if fd.isMutable { "var " } else { "" }
  vis + mutStr + fd.name + ": " + typeStr(fd.ty) + defStr
}

// ─────────────────────────────────────────────────────────────────────────────
// Function signature (sig-only form, no body).
// ─────────────────────────────────────────────────────────────────────────────
pub func funcSigStr(sg: in FunctionSig): String {
  val asyncStr = if sg.isAsync { "async " } else { "" }
  val gens = genParamsStr(sg.generics)
  val params = paramsStr(sg.params)
  val retStr = match sg.ret { case Some(t) -> ": " + typeStr(t); case None -> "" }
  asyncStr + "func " + sg.name + gens + "(" + params + ")" + retStr
}

// ─────────────────────────────────────────────────────────────────────────────
// Function decl.  Mirrors `funcDoc`.
// ─────────────────────────────────────────────────────────────────────────────
pub func funcDoc(visStr: in String, fn: in FunctionDecl, ctx: inout FmtCtx): List[String] {
  val annoLines = annotationLines(fn.annotations)
  val fnDocLs = docLines(fn.docComments)
  val asyncStr = if fn.isAsync { "async " } else { "" }
  val gens = genParamsStr(fn.generics)
  val retStr = match fn.ret { case Some(t) -> ": " + typeStr(t); case None -> "" }
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
    case None -> {
    }
  }
  val contractLines: List[String] = newList()
  var i = 0
  while i < fn.contracts.count {
    val c = fn.contracts[i]
    val pre = popTriviaBefore(ctx, contractClauseStartOffset(c))
    appendIndentedTrivia(contractLines, pre)
    val cd = indentDoc(2, contractDoc(2, ctx, c))
    var k = 0
    while k < cd.count {
      contractLines.add(cd[k])
      k = k + 1
    }
    i = i + 1
  }
  val extras = concatDoc(whereLines, contractLines)
  val body: List[String] = match fn.body {
    case None -> {
      val acc: List[String] = newList()
      var j = 0
      while j < sig.count {
        acc.add(sig[j])
        j = j + 1
      }
      j = 0
      while j < extras.count {
        acc.add(extras[j])
        j = j + 1
      }
      acc
    }
    case Some(FBExpr(e)) -> {
      if extras.count == 0 {
        appendToLastLine(sig, " = " + exprInline(0, e))
      } else {
        val acc: List[String] = newList()
        var j = 0
        while j < sig.count {
          acc.add(sig[j])
          j = j + 1
        }
        j = 0
        while j < extras.count {
          acc.add(extras[j])
          j = j + 1
        }
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
        while j < sig.count {
          acc.add(sig[j])
          j = j + 1
        }
        j = 0
        while j < extras.count {
          acc.add(extras[j])
          j = j + 1
        }
        acc.add("{")
        val bd = indentDoc(2, blockLines(b, ctx))
        j = 0
        while j < bd.count {
          acc.add(bd[j])
          j = j + 1
        }
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
  if s == "" {
    emptyDoc()
  } else {
    singleLineDoc("  " + s)
  }
}

pub func recordMemberLines(m: in RecordMember, ctx: inout FmtCtx): List[String] {
  match m {
    case RMField(field) -> fieldMemberLines(field)
    case RMInvariant(inv) -> singleLineDoc("invariant: " + exprInline(0, inv.expr))
    case RMFunc(fn) -> funcDoc("", fn, ctx)
  }
}

/// Render a record/opaque field with its leading `///` doc comments and
/// `@annotation` lines.  The parser binds these into `FieldDecl`
/// (`docComments` / `annotations`); unlike union and enum cases — whose
/// `unionDoc` / `enumDoc` printers already emit them — the field printer
/// historically dropped them, silently losing per-field documentation
/// on every `lyric fmt` pass.
func fieldMemberLines(field: in FieldDecl): List[String] {
  val acc: List[String] = newList()
  val docs = docLines(field.docComments)
  var i = 0
  while i < docs.count {
    acc.add(docs[i])
    i = i + 1
  }
  val annos = annotationLines(field.annotations)
  i = 0
  while i < annos.count {
    acc.add(annos[i])
    i = i + 1
  }
  acc.add(fieldDeclStr(field))
  acc
}

@pure
func recordMemberStartOffset(m: in RecordMember): Int {
  match m {
    case RMField(field) -> field.span.startPos.offset
    case RMInvariant(inv) -> inv.span.startPos.offset
    case RMFunc(fn) -> fn.span.startPos.offset
  }
}

pub func recordDoc(
  visStr: in String,
  kw: in String,
  name: in String,
  gens: in Option[GenericParams],
  wc: in Option[WhereClause],
  members: in List[RecordMember],
  bodyEnd: in Int,
  ctx: inout FmtCtx,
): List[String] {
  val genStr = genParamsStr(gens)
  val whereL = whereClauseLines(wc)
  val mLines: List[String] = newList()
  var i = 0
  while i < members.count {
    val m = members[i]
    appendTriviaInto(mLines, ctx, recordMemberStartOffset(m), false)
    val ml = recordMemberLines(m, ctx)
    var j = 0
    while j < ml.count {
      mLines.add(ml[j])
      j = j + 1
    }
    i = i + 1
  }
  // Trailing comments before the closing brace; a trailing comment on the
  // last member is re-attached to its line rather than split onto its own.
  appendTriviaInto(mLines, ctx, bodyEnd, true)

  val acc: List[String] = newList()
  acc.add(visStr + kw + " " + name + genStr + " {")
  i = 0
  while i < whereL.count {
    acc.add(whereL[i])
    i = i + 1
  }
  val ind = indentDoc(2, mLines)
  i = 0
  while i < ind.count {
    acc.add(ind[i])
    i = i + 1
  }
  acc.add("}")
  acc
}

// ─────────────────────────────────────────────────────────────────────────────
// Union decl.
// ─────────────────────────────────────────────────────────────────────────────
@pure
func unionFieldStr(f: in UnionField): String {
  match f {
    case UFNamed(n, ty, _) -> n + ": " + typeStr(ty)
    case UFPos(ty, _) -> typeStr(ty)
  }
}

@pure
func unionFieldStart(f: in UnionField): Int {
  match f {
    case UFNamed(_, _, sp) -> sp.startPos.offset
    case UFPos(_, sp) -> sp.startPos.offset
  }
}

/// Multi-line rendering of a union case's field list, used when the field
/// region carries interior trivia (a trailing `// note` on individual
/// named fields, e.g. the `MEHClause` case in `lyric-compiler/msil/lowering.l`).
/// Mirrors the magic-trailing-comma layout used for params / call args:
/// opener on the `case` line, one field per line indented by 2 with a
/// trailing comma, closer on its own line.  A trailing comment after the
/// `(` re-attaches to the opener line; a trailing comment on a field
/// re-attaches to that field's line; a trailing comment after the closing
/// `)` (which sits after the case's own span) is left for the enclosing
/// `unionDoc` case / closing-brace boundary to re-attach.
func unionCaseMultiLines(c: in UnionCase, ctx: inout FmtCtx): List[String] {
  val acc: List[String] = newList()
  acc.add("case " + c.name + "(")
  var fi = 0
  while fi < c.fields.count {
    // Trivia before this field: the opener-line trailing comment (first
    // field) or the previous field's trailing comment.
    appendTriviaInto(acc, ctx, unionFieldStart(c.fields[fi]), false)
    acc.add("  " + unionFieldStr(c.fields[fi]) + ",")
    fi = fi + 1
  }
  // Any comment between the last field and the case's own `)` (rare; the
  // usual trailing comment sits after `)` and is popped by the caller).
  appendTriviaInto(acc, ctx, c.span.endPos.offset, false)
  acc.add(")")
  acc
}

pub func unionDoc(visStr: in String, ud: in UnionDecl, ctx: inout FmtCtx): List[String] {
  val gens = genParamsStr(ud.generics)
  val whereL = whereClauseLines(ud.whereClause)
  val cases: List[String] = newList()
  var i = 0
  while i < ud.cases.count {
    val c = ud.cases[i]
    appendTriviaInto(cases, ctx, c.span.startPos.offset, false)
    val cd = docLines(c.docComments)
    val ca = annotationLines(c.annotations)
    var j = 0
    while j < cd.count {
      cases.add(cd[j])
      j = j + 1
    }
    j = 0
    while j < ca.count {
      cases.add(ca[j])
      j = j + 1
    }
    if c.fields.count == 0 {
      cases.add("case " + c.name)
    } else if hasTriviaInRange(ctx, c.span.startPos.offset, c.span.endPos.offset) {
      // The field list carries interior comments / blank lines (e.g. a
      // trailing `// note` per named field).  Render multi-line so each
      // comment survives on its own field's line rather than being merged
      // or dropped by the flat single-line form.
      val ml = unionCaseMultiLines(c, ctx)
      var ki = 0
      while ki < ml.count {
        cases.add(ml[ki])
        ki = ki + 1
      }
    } else {
      val fields: List[String] = newList()
      var ki = 0
      while ki < c.fields.count {
        fields.add(unionFieldStr(c.fields[ki]))
        ki = ki + 1
      }
      cases.add("case " + c.name + "(" + joinStrings(fields, ", ") + ")")
    }
    i = i + 1
  }
  // Trailing comments before the closing brace; a trailing comment on the
  // last case is re-attached to its line rather than split onto its own.
  appendTriviaInto(cases, ctx, ud.span.endPos.offset, true)

  val acc: List[String] = newList()
  acc.add(visStr + "union " + ud.name + gens + " {")
  i = 0
  while i < whereL.count {
    acc.add(whereL[i])
    i = i + 1
  }
  val ind = indentDoc(2, cases)
  i = 0
  while i < ind.count {
    acc.add(ind[i])
    i = i + 1
  }
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
    appendTriviaInto(cases, ctx, c.span.startPos.offset, false)
    val cd = docLines(c.docComments)
    val ca = annotationLines(c.annotations)
    var j = 0
    while j < cd.count {
      cases.add(cd[j])
      j = j + 1
    }
    j = 0
    while j < ca.count {
      cases.add(ca[j])
      j = j + 1
    }
    cases.add("case " + c.name)
    i = i + 1
  }
  // Trailing comments before the closing brace; a trailing comment on the
  // last case is re-attached to its line rather than split onto its own.
  appendTriviaInto(cases, ctx, ed.span.endPos.offset, true)

  val acc: List[String] = newList()
  acc.add(visStr + "enum " + ed.name + " {")
  val ind = indentDoc(2, cases)
  i = 0
  while i < ind.count {
    acc.add(ind[i])
    i = i + 1
  }
  acc.add("}")
  acc
}

// ─────────────────────────────────────────────────────────────────────────────
// Protected member.
// ─────────────────────────────────────────────────────────────────────────────
func protectedFieldStr(pf: in ProtectedField): List[String] {
  match pf {
    case PFVar(n, ty, init, _) -> {
      val initStr = match init { case Some(e) -> " = " + exprInline(0, e); case None -> "" }
      singleLineDoc("var " + n + ": " + typeStr(ty) + initStr)
    }
    case PFLet(n, ty, init, _) -> {
      val initStr = match init { case Some(e) -> " = " + exprInline(0, e); case None -> "" }
      singleLineDoc("let " + n + ": " + typeStr(ty) + initStr)
    }
    case PFImmutable(field) -> fieldMemberLines(field)
  }
}

func entryDoc(ed: in EntryDecl, ctx: inout FmtCtx): List[String] {
  val vStr = match ed.visibility { case Some(_) -> "pub "; case None -> "" }
  val params = paramsStr(ed.params)
  val retStr = match ed.ret { case Some(t) -> ": " + typeStr(t); case None -> "" }
  val sig = vStr + "entry " + ed.name + "(" + params + ")" + retStr
  val conLines: List[String] = newList()
  var i = 0
  while i < ed.contracts.count {
    val c = ed.contracts[i]
    val pre = popTriviaBefore(ctx, contractClauseStartOffset(c))
    appendIndentedTrivia(conLines, pre)
    val cd = indentDoc(2, contractDoc(2, ctx, c))
    var k = 0
    while k < cd.count {
      conLines.add(cd[k])
      k = k + 1
    }
    i = i + 1
  }
  val bodyLines: List[String] = match ed.body {
    case FBBlock(b) -> blockLines(b, ctx)
    case FBExpr(e) -> singleLineDoc(exprInline(0, e))
  }
  if conLines.count == 0 {
    val head = singleLineDoc(sig + " {")
    concatDoc3(head, indentDoc(2, bodyLines), singleLineDoc("}"))
  } else {
    val acc: List[String] = newList()
    acc.add(sig)
    i = 0
    while i < conLines.count {
      acc.add(conLines[i])
      i = i + 1
    }
    acc.add("{")
    val bd = indentDoc(2, bodyLines)
    i = 0
    while i < bd.count {
      acc.add(bd[i])
      i = i + 1
    }
    acc.add("}")
    acc
  }
}

pub func protectedMemberDoc(pm: in ProtectedMember, ctx: inout FmtCtx): List[String] {
  match pm {
    case PMField(pf) -> protectedFieldStr(pf)
    case PMInvariant(ic) -> singleLineDoc("invariant: " + exprInline(0, ic.expr))
    case PMEntry(ed) -> entryDoc(ed, ctx)
    case PMFunc(fn) -> funcDoc("", fn, ctx)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Top-level item dispatch.  Mirrors `itemDoc` in Fmt.fs.
// ─────────────────────────────────────────────────────────────────────────────
pub func itemDoc(item: in Item, ctx: inout FmtCtx): List[String] {
  val visStr = match item.visibility { case Some(_) -> "pub "; case None -> "" }
  val annoLines = annotationLines(item.annotations)
  val header = concatDoc(docLines(item.docComments), annoLines)
  match item.kind {
    case IFunc(fn) -> itemFunc(visStr, fn, ctx)
    case IRecord(rd) -> concatDoc(header, recordDoc(visStr, "record", rd.name, rd.generics, rd.whereClause, rd.members, rd.span.endPos.offset, ctx))
    case IExposedRec(rd) -> concatDoc(header, recordDoc(visStr, "exposed record", rd.name, rd.generics, rd.whereClause, rd.members, rd.span.endPos.offset, ctx))
    case IUnion(ud) -> concatDoc(header, unionDoc(visStr, ud, ctx))
    case IEnum(ed) -> concatDoc(header, enumDoc(visStr, ed, ctx))
    case IOpaque(od) -> opaqueDoc(visStr, item, od, ctx)
    case IDistinctType(dt) -> concatDoc(header, distinctDoc(visStr, dt))
    case ITypeAlias(ta) -> concatDoc(header, typeAliasDoc(visStr, ta))
    case IProtected(pd) -> concatDoc(header, protectedTypeDoc(visStr, pd, ctx))
    case IInterface(id) -> concatDoc(header, interfaceDoc(visStr, id, ctx))
    case IImpl(id) -> concatDoc(header, implDoc(id, ctx))
    case IWire(wd) -> concatDoc(header, wireDoc(wd, ctx))
    case IScopeKind(sd) -> concatDoc(header, singleLineDoc("scope_kind " + sd.name))
    case IConst(cd) -> concatDoc(header, constDoc(visStr, cd))
    case IVal(vd) -> concatDoc(header, valDoc(visStr, vd))
    case IExtern(ep) -> externDoc(item, ep, ctx)
    case IExternType(et) -> concatDoc(header, externTypeDoc(visStr, et))
    case ITest(td) -> concatDoc(header, testDoc(td, ctx))
    case IProperty(pd) -> concatDoc(header, propertyDoc(pd, ctx))
    case IFixture(fd) -> concatDoc(header, fixtureDoc(fd))
    case IConfig(cd) -> concatDoc(header, configDoc(visStr, cd))
    case IAspect(ad) -> concatDoc(header, aspectDoc(visStr, ad, ctx))
    case IError -> singleLineDoc("// <parse-error>")
  }
}

func itemFunc(visStr: in String, fn: in FunctionDecl, ctx: inout FmtCtx): List[String] {
  // funcDoc already prepends doc comments + annotations from `fn`
  // itself; we don't re-emit `item.DocComments` because Item's doc
  // comments are the same list (see parser).
  funcDoc(visStr, fn, ctx)
}

@pure
func opaqueMemberStartOffset(m: in OpaqueMember): Int {
  match m {
    case OMField(fd) -> fd.span.startPos.offset
    case OMInvariant(ic) -> ic.span.startPos.offset
  }
}

func opaqueDoc(visStr: in String, item: in Item, od: in OpaqueTypeDecl, ctx: inout FmtCtx): List[String] {
  // `itemDoc` dispatches to `opaqueDoc` WITHOUT prepending the shared
  // `header` (unlike record/union/etc.), so the item's leading
  // annotations (`@stable`, …) must be emitted here or they are dropped.
  // `od.annotations` is the distinct set of trailing annotations
  // (`parseTrailingAnnotations`), so the two never overlap.
  val leadAnnos = annotationLines(item.annotations)
  val odAnnos = annotationLines(od.annotations)
  val gens = genParamsStr(od.generics)
  val whereL = whereClauseLines(od.whereClause)
  val docL = docLines(item.docComments)
  if not od.hasBody {
    concatDoc(concatDoc3(docL, leadAnnos, odAnnos), singleLineDoc(visStr + "opaque type " + od.name + gens))
  } else {
    val mLines: List[String] = newList()
    var i = 0
    while i < od.members.count {
      appendTriviaInto(mLines, ctx, opaqueMemberStartOffset(od.members[i]), false)
      match od.members[i] {
        case OMField(fd) -> {
          val fl = fieldMemberLines(fd)
          var z = 0
          while z < fl.count {
            mLines.add(fl[z])
            z = z + 1
          }
        }
        case OMInvariant(ic) -> mLines.add("invariant: " + exprInline(0, ic.expr))
      }
      i = i + 1
    }
    // A comment in an otherwise empty or trailing body (e.g.
    // `opaque type T { // note }`) lives before the closing brace.
    appendTriviaInto(mLines, ctx, item.span.endPos.offset, true)
    val acc: List[String] = newList()
    var j = 0
    while j < docL.count {
      acc.add(docL[j])
      j = j + 1
    }
    j = 0
    while j < leadAnnos.count {
      acc.add(leadAnnos[j])
      j = j + 1
    }
    j = 0
    while j < odAnnos.count {
      acc.add(odAnnos[j])
      j = j + 1
    }
    acc.add(visStr + "opaque type " + od.name + gens + " {")
    j = 0
    while j < whereL.count {
      acc.add(whereL[j])
      j = j + 1
    }
    val ind = indentDoc(2, mLines)
    j = 0
    while j < ind.count {
      acc.add(ind[j])
      j = j + 1
    }
    acc.add("}")
    acc
  }
}

func distinctDoc(visStr: in String, dt: in DistinctTypeDecl): List[String] {
  val gens = genParamsStr(dt.generics)
  val rangeStr = match dt.rangeClause { case Some(rb) -> " range " + rangeBoundStr(rb); case None -> "" }
  val derivesStr = if dt.derives.count == 0 { "" } else { " derives " + joinStrings(dt.derives, ", ") }
  singleLineDoc(visStr + "type " + dt.name + gens + " = " + typeStr(dt.underlying) + rangeStr + derivesStr)
}

func typeAliasDoc(visStr: in String, ta: in TypeAliasDecl): List[String] {
  singleLineDoc(visStr + "alias " + ta.name + genParamsStr(ta.generics) + " = " + typeStr(ta.rhs))
}

@pure
func protectedFieldStartOffset(pf: in ProtectedField): Int {
  match pf {
    case PFVar(_, _, _, sp) -> sp.startPos.offset
    case PFLet(_, _, _, sp) -> sp.startPos.offset
    case PFImmutable(fd) -> fd.span.startPos.offset
  }
}

@pure
func protectedMemberStartOffset(pm: in ProtectedMember): Int {
  match pm {
    case PMField(pf) -> protectedFieldStartOffset(pf)
    case PMInvariant(ic) -> ic.span.startPos.offset
    case PMEntry(ed) -> ed.span.startPos.offset
    case PMFunc(fn) -> fn.span.startPos.offset
  }
}

func protectedTypeDoc(visStr: in String, pd: in ProtectedTypeDecl, ctx: inout FmtCtx): List[String] {
  val gens = genParamsStr(pd.generics)
  val whereL = whereClauseLines(pd.whereClause)
  val mLines: List[String] = newList()
  var i = 0
  while i < pd.members.count {
    // Consume trivia between the previous member and this one.  Without
    // this, blank-line markers left in the `ctx` cursor would be dumped
    // into the next member's body by `blockLines`' leading
    // `appendTriviaInto` (a member with a body — an `entry` or `func`),
    // and two source blank-runs landing adjacent there collapse to one on
    // the next pass.  Comments are re-emitted as leading member lines;
    // blank markers are dropped (canonical protected bodies carry no
    // inter-member blank).
    val pre = popCommentsBefore(ctx, protectedMemberStartOffset(pd.members[i]))
    var p = 0
    while p < pre.count {
      mLines.add(pre[p])
      p = p + 1
    }
    val ml = protectedMemberDoc(pd.members[i], ctx)
    var j = 0
    while j < ml.count {
      mLines.add(ml[j])
      j = j + 1
    }
    i = i + 1
  }
  val acc: List[String] = newList()
  acc.add(visStr + "protected type " + pd.name + gens + " {")
  i = 0
  while i < whereL.count {
    acc.add(whereL[i])
    i = i + 1
  }
  val ind = indentDoc(2, mLines)
  i = 0
  while i < ind.count {
    acc.add(ind[i])
    i = i + 1
  }
  acc.add("}")
  acc
}

@pure
func interfaceMemberStartOffset(m: in InterfaceMember): Int {
  match m {
    case IMSig(sg) -> sg.span.startPos.offset
    case IMFunc(fn) -> fn.span.startPos.offset
    case IMAssoc(a) -> a.span.startPos.offset
  }
}

func interfaceDoc(visStr: in String, id: in InterfaceDecl, ctx: inout FmtCtx): List[String] {
  val gens = genParamsStr(id.generics)
  val whereL = whereClauseLines(id.whereClause)
  val mLines: List[String] = newList()
  var i = 0
  while i < id.members.count {
    appendTriviaInto(mLines, ctx, interfaceMemberStartOffset(id.members[i]), false)
    match id.members[i] {
      case IMSig(sg) -> {
        // A body-less signature: doc comments + the signature + its
        // contract clauses (`requires:` / `ensures:` / …), mirroring how
        // an extern-package member is rendered.
        appendDoc(mLines, docLines(sg.docComments))
        mLines.add(funcSigStr(sg))
        var ci = 0
        while ci < sg.contracts.count {
          val c = sg.contracts[ci]
          val cpre = popTriviaBefore(ctx, contractClauseStartOffset(c))
          appendIndentedTrivia(mLines, cpre)
          appendDoc(mLines, indentDoc(2, contractDoc(2, ctx, c)))
          ci = ci + 1
        }
      }
      case IMFunc(fn) -> {
        val fd = funcDoc("", fn, ctx)
        var j = 0
        while j < fd.count {
          mLines.add(fd[j])
          j = j + 1
        }
      }
      case IMAssoc(a) -> {
        match a.dflt {
          case Some(t) -> mLines.add("type " + a.name + " = " + typeStr(t))
          case None -> mLines.add("type " + a.name)
        }
      }
    }
    i = i + 1
  }
  appendTriviaInto(mLines, ctx, id.span.endPos.offset, true)
  val acc: List[String] = newList()
  acc.add(visStr + "interface " + id.name + gens + " {")
  i = 0
  while i < whereL.count {
    acc.add(whereL[i])
    i = i + 1
  }
  val ind = indentDoc(2, mLines)
  i = 0
  while i < ind.count {
    acc.add(ind[i])
    i = i + 1
  }
  acc.add("}")
  acc
}

@pure
func implMemberStartOffset(m: in ImplMember): Int {
  match m {
    case IMplFunc(fn) -> fn.span.startPos.offset
    case IMplAssoc(a) -> a.span.startPos.offset
  }
}

func implDoc(id: in ImplDecl, ctx: inout FmtCtx): List[String] {
  val gens = genParamsStr(id.generics)
  val target = typeStr(id.target)
  val ifStr = constraintRefStr(id.iface)
  val whereL = whereClauseLines(id.whereClause)
  val mLines: List[String] = newList()
  var i = 0
  while i < id.members.count {
    // Pop inter-member trivia (blank lines + comments) before each member
    // so it is not left for the function-signature printer to mistake for
    // a comment inside the parameter list (which would force a spurious
    // multi-line break with a blank line after `(`), and so member
    // comments are preserved rather than dropped.
    appendTriviaInto(mLines, ctx, implMemberStartOffset(id.members[i]), false)
    match id.members[i] {
      case IMplFunc(fn) -> {
        val fd = funcDoc("", fn, ctx)
        var j = 0
        while j < fd.count {
          mLines.add(fd[j])
          j = j + 1
        }
      }
      case IMplAssoc(a) -> {
        match a.dflt {
          case Some(t) -> mLines.add("type " + a.name + " = " + typeStr(t))
          case None -> mLines.add("type " + a.name)
        }
      }
    }
    i = i + 1
  }
  appendTriviaInto(mLines, ctx, id.span.endPos.offset, true)
  val acc: List[String] = newList()
  acc.add("impl" + gens + " " + ifStr + " for " + target + " {")
  i = 0
  while i < whereL.count {
    acc.add(whereL[i])
    i = i + 1
  }
  val ind = indentDoc(2, mLines)
  i = 0
  while i < ind.count {
    acc.add(ind[i])
    i = i + 1
  }
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
      case WMBind(iface, prov, _) -> mLines.add("bind " + typeStr(iface) + " = " + exprInline(0, prov))
      case WMExpose(n, _) -> mLines.add("expose " + n)
      case WMLocal(n, ty, init, _) -> {
        val tyStr = match ty { case Some(t) -> ": " + typeStr(t); case None -> "" }
        mLines.add("val " + n + tyStr + " = " + exprInline(0, init))
      }
    }
    i = i + 1
  }
  val acc: List[String] = newList()
  acc.add("wire " + wd.name + "(" + params + ") {")
  val ind = indentDoc(2, mLines)
  i = 0
  while i < ind.count {
    acc.add(ind[i])
    i = i + 1
  }
  acc.add("}")
  acc
}

func constDoc(visStr: in String, cd: in ConstDecl): List[String] {
  singleLineDoc(visStr + "const " + cd.name + ": " + typeStr(cd.ty) + " = " + exprInline(0, cd.init))
}

func valDoc(visStr: in String, vd: in ValDecl): List[String] {
  val tyStr = match vd.ty { case Some(t) -> ": " + typeStr(t); case None -> "" }
  singleLineDoc(visStr + "val " + patStr(vd.pattern) + tyStr + " = " + exprInline(0, vd.init))
}

/// True when an opaque decl's annotation list carries the synthetic
/// "exposed" tag the parser injects for an `exposed type` extern member.
@pure
func annotationsHaveExposedTag(anns: in List[Annotation]): Bool {
  var i = 0
  while i < anns.count {
    val segs = anns[i].name.segments
    if segs.count == 1 and segs[0] == "exposed" {
      return true
    }
    i = i + 1
  }
  false
}

/// Visibility prefix for an extern member (`pub ` / `internal ` / none).
@pure
func externVisStr(vis: in Option[Visibility]): String {
  match vis {
    case Some(VisPub(_)) -> "pub "
    case Some(VisInternal(_)) -> "internal "
    case None -> ""
  }
}

/// One extern-package member: leading non-doc trivia, its captured doc
/// comments and annotations, then the declaration itself rendered at full
/// fidelity (visibility + signature + contracts for a func, the full body
/// for a record).  Mirrors the order the source wrote them so the
/// `FmtCtx` cursor advances monotonically.
func externMemberLines(emd: in ExternMemberDecl, ctx: inout FmtCtx): List[String] {
  val acc: List[String] = newList()
  val pre = popTriviaBefore(ctx, emd.span.startPos.offset)
  appendDoc(acc, pre)
  appendDoc(acc, docLines(emd.docComments))
  appendDoc(acc, annotationLines(emd.annotations))
  val visStr = externVisStr(emd.visibility)
  match emd.kind {
    case EMSig(sg) -> {
      acc.add(visStr + funcSigStr(sg))
      var ci = 0
      while ci < sg.contracts.count {
        val c = sg.contracts[ci]
        val cpre = popTriviaBefore(ctx, contractClauseStartOffset(c))
        appendIndentedTrivia(acc, cpre)
        appendDoc(acc, indentDoc(2, contractDoc(2, ctx, c)))
        ci = ci + 1
      }
    }
    case EMExposedRec(r) -> appendDoc(acc, recordDoc(visStr, "exposed record", r.name, r.generics, r.whereClause, r.members, r.span.endPos.offset, ctx))
    case EMRecord(r) -> appendDoc(acc, recordDoc(visStr, "record", r.name, r.generics, r.whereClause, r.members, r.span.endPos.offset, ctx))
    case EMUnion(u) -> appendDoc(acc, unionDoc(visStr, u, ctx))
    case EMEnum(e) -> appendDoc(acc, enumDoc(visStr, e, ctx))
    case EMOpaque(o) -> {
      // The parser models a `exposed type X` extern member as an opaque
      // decl carrying a synthetic "exposed" annotation tag; reverse it.
      val kw = if annotationsHaveExposedTag(o.annotations) { "exposed type " } else { "opaque type " }
      acc.add(visStr + kw + o.name + genParamsStr(o.generics))
    }
    case EMTypeAlias(ta) -> appendDoc(acc, typeAliasDoc(visStr, ta))
    case EMDistinctType(d) -> appendDoc(acc, distinctDoc(visStr, d))
  }
  acc
}

func externDoc(item: in Item, ep: in ExternPackageDecl, ctx: inout FmtCtx): List[String] {
  val acc: List[String] = newList()
  appendDoc(acc, docLines(item.docComments))
  appendDoc(acc, annotationLines(ep.annotations))
  acc.add("extern package " + pathStr(ep.path) + " {")
  val mLines: List[String] = newList()
  var i = 0
  while i < ep.members.count {
    appendDoc(mLines, externMemberLines(ep.members[i], ctx))
    i = i + 1
  }
  // Pop any trailing comments before the closing brace into `mLines`
  // first (so a trailing comment on the last member stays on its line),
  // then indent the whole body.
  appendTriviaInto(mLines, ctx, ep.span.endPos.offset, true)
  appendDoc(acc, indentDoc(2, mLines))
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
  while i < ind.count {
    acc.add(ind[i])
    i = i + 1
  }
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
  val whereStr = match pd.guardExpr { case Some(w) -> " where " + exprInline(0, w); case None -> "" }
  val acc: List[String] = newList()
  acc.add("property \"" + escapeStr(pd.title) + "\" forall (" + joinStrings(parts, ", ") + ")" + whereStr + " {")
  val ind = indentDoc(2, blockLines(pd.body, ctx))
  i = 0
  while i < ind.count {
    acc.add(ind[i])
    i = i + 1
  }
  acc.add("}")
  acc
}

func fixtureDoc(fd: in FixtureDecl): List[String] {
  val tyStr = match fd.ty { case Some(t) -> ": " + typeStr(t); case None -> "" }
  singleLineDoc("fixture " + fd.name + tyStr + " = " + exprInline(0, fd.init))
}

// ─────────────────────────────────────────────────────────────────────────────
// D046 config block render.
// ─────────────────────────────────────────────────────────────────────────────
func configFieldLine(f: in ConfigField): String {
  // Annotations on a config field render on their own preceding lines
  // (emitted by `configDoc`); the field itself is one line with
  // `name: T = default?`.
  val dflt = match f.default { case Some(e) -> " = " + exprInline(0, e); case None -> "" }
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
    while k < annLines.count {
      acc.add("  " + annLines[k])
      k = k + 1
    }
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
    case AMNameLike(g, _) -> "name like \"" + g + "\""
    case AMNameIn(names, _) -> "name in { " + joinStrings(names, ", ") + " }"
    case AMAnnotated(n, _) -> "annotated: @" + n
    case AMVisibility(v, _) -> "visibility: " + v
    case AMSignatureReturns(t, _) -> "signature: returns \"" + t + "\""
  }
}

func aspectDoc(visStr: in String, ad: in AspectDecl, ctx: inout FmtCtx): List[String] {
  val acc: List[String] = newList()
  // Instantiation form (D051): `aspect Name from Pkg.Template { … }`.  The
  // `from` clause is matched on the `ad.from` field directly (a single match,
  // not a nested re-match of a sub-field), so it lowers correctly under the
  // stage-0 emitter — unlike the `around` advice, which is routed through
  // `aspectAroundLines` for that reason.
  val fromStr = match ad.from { case Some(mp) -> " from " + pathStr(mp); case None -> "" }
  acc.add(visStr + "aspect " + ad.name + fromStr + " {")
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
    val ex = if ad.exceptNames.count > 0 { " except name in { " + joinStrings(ad.exceptNames, ", ") + " }" } else { "" }
    acc.add("  matches: " + body + ex)
  }
  // §8 anonymous `config { }` block — canonical order (docs/26 §"Compile-time
  // enable / runtime configure") places it after `matches:` and before the
  // `around` advice.  Each member sits at column 4 (2 for the aspect body,
  // 2 for the block body).
  if ad.config.count > 0 {
    acc.add("  config {")
    var fi = 0
    while fi < ad.config.count {
      val f = ad.config[fi]
      val annLines = annotationLines(f.annotations)
      var ak = 0
      while ak < annLines.count {
        acc.add("    " + annLines[ak])
        ak = ak + 1
      }
      acc.add("  " + configFieldLine(f))
      fi = fi + 1
    }
    acc.add("  }")
  }
  // §5 contract augmentation: emit requires:/ensures: before the around block.
  var ci = 0
  while ci < ad.contracts.count {
    val cd = indentDoc(2, contractDoc(2, ctx, ad.contracts[ci]))
    var k = 0
    while k < cd.count {
      acc.add(cd[k])
      k = k + 1
    }
    ci = ci + 1
  }
  val al = aspectAroundLines(ad.around, ctx)
  var ai = 0
  while ai < al.count {
    acc.add(al[ai])
    ai = ai + 1
  }
  acc.add("}")
  acc
}

// The `around(args) -> ret { … }` advice block.  The `Option[AspectAround]`
// is matched here as a *function parameter* rather than via
// `match ad.around { … }` in the caller: the stage-0 bootstrap emitter
// type-erases `ad` to `Object`, and a nested `match` whose binding came
// from matching a *field* of that erased value (`ar` from `ad.around`)
// then re-matching one of *its* fields (`ar.retName`) silently yields the
// fallback arm — which dropped the `-> ret` return binder.  Matching the
// parameter directly (mirroring how `itemDoc` hands a decl to `funcDoc`)
// lowers `match ar.retName` correctly.
func aspectAroundLines(aroundOpt: in Option[AspectAround], ctx: inout FmtCtx): List[String] {
  val acc: List[String] = newList()
  match aroundOpt {
    case None -> {
    }
    case Some(ar) -> {
      // Consume any trivia between the preceding aspect member (config /
      // matches / a contract clause) and the `around` keyword.  `aspectDoc`
      // emits members without popping the trivia between them, so without
      // this the leftover blank-line markers would be dumped into the
      // around body by `blockLines`' leading `appendTriviaInto` — and two
      // separate source blank-runs landing adjacent there collapse to one
      // on the next pass (an idempotency break).  Comments are re-emitted
      // as leading lines; blank-line markers are dropped (canonical aspect
      // bodies carry no inter-member blank).
      val pre = popCommentsBefore(ctx, ar.span.startPos.offset)
      var pk = 0
      while pk < pre.count {
        acc.add("  " + pre[pk])
        pk = pk + 1
      }
      val retStr = match ar.retName { case Some(r) -> " -> " + r; case None -> "" }
      acc.add("  around(" + ar.argsName + ")" + retStr + " {")
      val body = blockLines(ar.body, ctx)
      var k = 0
      while k < body.count {
        acc.add("    " + body[k])
        k = k + 1
      }
      acc.add("  }")
    }
  }
  acc
}

// ─────────────────────────────────────────────────────────────────────────────
// Imports.
// ─────────────────────────────────────────────────────────────────────────────
pub func importDoc(imp: in ImportDecl): List[String] {
  val selStr = match imp.selector {
    case None -> ""
    case Some(ISSingle(item)) -> {
      val a = match item.asAlias { case Some(a) -> " as " + a; case None -> "" }
      "." + item.name + a
    }
    case Some(ISGroup(items)) -> {
      val parts: List[String] = newList()
      var i = 0
      while i < items.count {
        val it = items[i]
        match it.asAlias {
          case Some(a) -> parts.add(it.name + " as " + a)
          case None -> parts.add(it.name)
        }
        i = i + 1
      }
      ".{" + joinStrings(parts, ", ") + "}"
    }
  }
  val aliasStr = match imp.asAlias { case Some(a) -> " as " + a; case None -> "" }
  val kw = if imp.isPubUse { "pub use" } else { "import" }
  singleLineDoc(kw + " " + pathStr(imp.path) + selStr + aliasStr)
}
