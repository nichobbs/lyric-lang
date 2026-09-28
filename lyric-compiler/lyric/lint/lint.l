//! lint/lint.l — self-hosted `lyric lint` style and quality checker.
//! Mirrors compiler/src/Lyric.Cli/Lint.fs (Phase 5 §M5.3 shim elimination).
//! Six AST-only rules: L001-L005, L007 (#7549; L006 retired, docs/01 §14.6).
package Lyric.Lint

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser

// ─── Diagnostic types ─────────────────────────────────────────────────────────
pub union LintSev {
  case LintError
  case LintWarning
}

pub record LintDiag {
  code: String
  severity: LintSev
  message: String
  span: Span
  // ─── Character helpers (ASCII only — naming rules are ASCII) ──────────────────
}

func isAsciiUpper(c: in Char): Bool {
  c >= 'A' and c <= 'Z'
}

func isAsciiLower(c: in Char): Bool {
  c >= 'a' and c <= 'z'
}

func isAsciiDigit(c: in Char): Bool {
  c >= '0' and c <= '9'
}

func startsUpper(s: in String): Bool {
  s.length > 0 and isAsciiUpper(Str.charAtOrReplacement(s, 0))
}

func startsLower(s: in String): Bool {
  s.length > 0 and isAsciiLower(Str.charAtOrReplacement(s, 0))
}

func isUpperSnake(s: in String): Bool {
  if s.length == 0 {
    return false
  }
  var i = 0
  var ok = true
  while i < s.length and ok {
    val c = Str.charAtOrReplacement(s, i)
    if not (isAsciiUpper(c) or isAsciiDigit(c) or c == '_') {
      ok = false
    }
    i = i + 1
  }
  ok
}

// ─── Rule helpers ─────────────────────────────────────────────────────────────
func lintError(code: in String, msg: in String, sp: in Span): LintDiag {
  LintDiag(code = code, severity = LintError, message = msg, span = sp)
}

func lintWarning(code: in String, msg: in String, sp: in Span): LintDiag {
  LintDiag(code = code, severity = LintWarning, message = msg, span = sp)
}

// L001 — type name must start with an uppercase letter.
func checkTypeName(name: in String, sp: in Span): List[LintDiag] {
  if startsUpper(name) {
    return newList()
  }
  val acc: List[LintDiag] = newList()
  acc.add(lintError("L001", "type name '" + name + "' should be PascalCase (start with an uppercase letter)", sp))
  acc
}

// L002 — function name must start with a lowercase letter.
func checkFuncName(name: in String, sp: in Span): List[LintDiag] {
  if startsLower(name) {
    return newList()
  }
  val acc: List[LintDiag] = newList()
  acc.add(lintError("L002", "function name '" + name + "' should be camelCase (start with a lowercase letter)", sp))
  acc
}

// L003 — pub item should have a doc comment.
func checkPubDoc(
  vis: in Option[Visibility], docs: in List[DocComment], name: in String, kind: in String, sp: in Span
): List[LintDiag] {
  match vis {
    case None -> newList()
    case Some(_) -> {
      if docs.count > 0 {
        return newList()
      }
      val acc: List[LintDiag] = newList()
      acc.add(lintWarning("L003", "pub " + kind + " '" + name + "' has no doc comment (///)", sp))
      acc
    }
  }
}

// L004 — doc comment contains TODO or FIXME.
func checkDocTodos(docs: in List[DocComment]): List[LintDiag] {
  val acc: List[LintDiag] = newList()
  var i = 0
  while i < docs.count {
    val d = docs[i]
    val docText = d.text
    var found = false
    var j = 0
    while j + 3 < docText.length and not found {
      if (Str.charAtOrReplacement(docText, j) == 'T' or Str.charAtOrReplacement(docText, j) == 't') and (Str.charAtOrReplacement(docText, j + 1) == 'O' or Str.charAtOrReplacement(docText, j + 1) == 'o') and (Str.charAtOrReplacement(docText, j + 2) == 'D' or Str.charAtOrReplacement(docText, j + 2) == 'd') and (Str.charAtOrReplacement(docText, j + 3) == 'O' or Str.charAtOrReplacement(docText, j + 3) == 'o') {
        found = true
      }
      j = j + 1
    }
    var j2 = 0
    while j2 + 4 < docText.length and not found {
      if (Str.charAtOrReplacement(docText, j2) == 'F' or Str.charAtOrReplacement(docText, j2) == 'f') and (Str.charAtOrReplacement(docText, j2 + 1) == 'I' or Str.charAtOrReplacement(docText, j2 + 1) == 'i') and (Str.charAtOrReplacement(docText, j2 + 2) == 'X' or Str.charAtOrReplacement(docText, j2 + 2) == 'x') and (Str.charAtOrReplacement(docText, j2 + 3) == 'M' or Str.charAtOrReplacement(docText, j2 + 3) == 'm') and (Str.charAtOrReplacement(docText, j2 + 4) == 'E' or Str.charAtOrReplacement(docText, j2 + 4) == 'e') {
        found = true
      }
      j2 = j2 + 1
    }
    if found {
      acc.add(lintWarning("L004", "doc comment contains TODO/FIXME: '" + docText + "'", d.span))
    }
    i = i + 1
  }
  acc
}

// L005 — pub func with a block body should declare at least one contract.
// Suppressed when the module is annotated @runtime_checked.
func checkPubContract(vis: in Option[Visibility], fn: in FunctionDecl, isRuntimeChecked: in Bool): List[LintDiag] {
  if isRuntimeChecked {
    return newList()
  }
  match vis {
    case None -> newList()
    case Some(_) -> {
      match fn.body {
        case Some(body) -> {
          match body {
            case FBBlock(_) -> {
              if fn.contracts.count == 0 {
                val acc: List[LintDiag] = newList()
                acc.add(
                  lintWarning(
                    "L005",
                    "pub func '" + fn.name +
                      "' has no requires/ensures contracts — consider adding contracts or marking the module @runtime_checked",
                    fn.span
                  )
                )
                acc
              } else {
                newList()
              }
            }
            case _ -> newList()
          }
        }
        case None -> newList()
      }
    }
  }
}

// ─── List concat helper ───────────────────────────────────────────────────────
func appendDiags(target: in List[LintDiag], src: in List[LintDiag]) {
  var i = 0
  while i < src.count {
    target.add(src[i])
    i = i + 1
  }
}

// ─── L007 — package-private type in a pub signature (#7549) ──────────────────
//
// docs/01 §3.1 enforces visibility at use sites (T0097): a `pub`/`internal`
// item whose signature names a package-private (unmarked) type from the same
// package compiles fine at the declaration but every use of that item from
// another package fails.  This rule flags the declaration instead.
//
// Scope: lint is AST-only, single-file (docs/01 §13.8), so this rule only
// sees type declarations in the SAME file as the item it is checking — a
// package-private type declared in a sibling file of a split multi-file
// package (docs/19) is not visible to this pass and will not be flagged
// (package-wide registry for manifest lints: #7607).
// Cross-package private types are out of scope entirely: those already fail
// T0097 at every use site regardless of this rule.
//
// A type name is "private" here iff it is declared with no `pub`/`internal`
// modifier (Visibility == None) — the exact same tier T0097 rejects (docs/01
// §3.1: `pub` and `internal` are both visible cross-package within a
// project; only the unmarked tier is package-private). A `pub`/`internal`
// type alias whose right-hand side names a private type is private too (the
// alias is transparent, so naming the alias does not make the underlying
// type constructible from outside). Extern types (`extern type` / `extern
// package` members) are never registered as local type declarations, so a
// reference to one is never flagged — they are FFI host bindings, exempt
// from these visibility tiers per docs/01 §3.1.
record LintTypeDecl {
  name: String
  isPrivate: Bool
  // Set only for a type-alias declaration: its right-hand-side type, so a
  // reference to the alias can be chased through to its underlying type.
  aliasRhs: Option[TypeExpr]
}

func buildTypeRegistry(file: in SourceFile): List[LintTypeDecl] {
  val regs: List[LintTypeDecl] = newList()
  var i = 0
  while i < file.items.count {
    val item = file.items[i]
    val isPriv = match item.visibility { case None -> true; case Some(_) -> false }
    match item.kind {
      case IRecord(rd) -> regs.add(LintTypeDecl(name = rd.name, isPrivate = isPriv, aliasRhs = None))
      case IExposedRec(rd) -> regs.add(LintTypeDecl(name = rd.name, isPrivate = isPriv, aliasRhs = None))
      case IUnion(ud) -> regs.add(LintTypeDecl(name = ud.name, isPrivate = isPriv, aliasRhs = None))
      case IEnum(ed) -> regs.add(LintTypeDecl(name = ed.name, isPrivate = isPriv, aliasRhs = None))
      case IOpaque(od) -> regs.add(LintTypeDecl(name = od.name, isPrivate = isPriv, aliasRhs = None))
      case IProtected(pd) -> regs.add(LintTypeDecl(name = pd.name, isPrivate = isPriv, aliasRhs = None))
      case IDistinctType(dt) -> regs.add(LintTypeDecl(name = dt.name, isPrivate = isPriv, aliasRhs = None))
      case IInterface(id) -> regs.add(LintTypeDecl(name = id.name, isPrivate = isPriv, aliasRhs = None))
      case ITypeAlias(ta) -> regs.add(LintTypeDecl(name = ta.name, isPrivate = isPriv, aliasRhs = Some(value = ta.rhs)))
      case _ -> ()
    }
    i = i + 1
  }
  regs
}

func findTypeDecl(regs: in List[LintTypeDecl], name: in String): Option[LintTypeDecl] {
  var i = 0
  while i < regs.count {
    if regs[i].name == name {
      return Some(value = regs[i])
    }
    i = i + 1
  }
  None
}

// Chases a same-file type name through alias indirection (`alias X =
// PrivateType`) to decide whether it ultimately names a private type.  A
// name not declared in this file (imported, or declared in a sibling file of
// the same package) is never treated as private — this pass has no
// visibility into it (see the scope note above).
func isPrivateTypeName(regs: in List[LintTypeDecl], name: in String, depth: in Int): Bool {
  if depth > 8 {
    return false
  }
  match findTypeDecl(regs, name) {
    case None -> false
    case Some(decl) -> {
      if decl.isPrivate {
        true
      } else {
        match decl.aliasRhs {
          case None -> false
          case Some(rhs) -> {
            match rhs.kind {
              case TRef(path) -> {
                if path.segments.count == 1 {
                  isPrivateTypeName(regs, path.segments[0], depth + 1)
                } else {
                  false
                }
              }
              case _ -> false
            }
          }
        }
      }
    }
  }
}

func genericParamNames(gp: in Option[GenericParams]): List[String] {
  val names: List[String] = newList()
  match gp {
    case None -> ()
    case Some(g) -> {
      var i = 0
      while i < g.params.count {
        match g.params[i] {
          case GPType(n, _) -> names.add(n)
          case GPValue(n, _, _) -> names.add(n)
        }
        i = i + 1
      }
    }
  }
  names
}

func containsName(names: in List[String], n: in String): Bool {
  var i = 0
  var found = false
  while i < names.count and not found {
    if names[i] == n {
      found = true
    }
    i = i + 1
  }
  found
}

func mergeNames(a: in List[String], b: in List[String]): List[String] {
  val merged: List[String] = newList()
  var i = 0
  while i < a.count {
    merged.add(a[i])
    i = i + 1
  }
  var j = 0
  while j < b.count {
    merged.add(b[j])
    j = j + 1
  }
  merged
}

// Recursively collects every same-file private type name a `TypeExpr`
// mentions — including inside array/slice/tuple/nullable/function-type
// shapes and generic arguments — skipping names that are in-scope generic
// parameters rather than concrete type references.
func collectPrivateTypes(ty: in TypeExpr, regs: in List[LintTypeDecl], generics: in List[String], acc: in List[String]) {
  match ty.kind {
    case TRef(path) -> {
      if path.segments.count == 1 {
        val nm = path.segments[0]
        if not containsName(generics, nm) and isPrivateTypeName(regs, nm, 0) {
          acc.add(nm)
        }
      }
    }
    case TGenericApp(head, args) -> {
      if head.segments.count == 1 {
        val nm = head.segments[0]
        if not containsName(generics, nm) and isPrivateTypeName(regs, nm, 0) {
          acc.add(nm)
        }
      }
      var i = 0
      while i < args.count {
        match args[i] {
          case TAType(t) -> collectPrivateTypes(t, regs, generics, acc)
          case TAValue(_) -> ()
        }
        i = i + 1
      }
    }
    case TArray(_, element) -> collectPrivateTypes(element, regs, generics, acc)
    case TSlice(element) -> collectPrivateTypes(element, regs, generics, acc)
    case TRefined(underlying, _) -> {
      if underlying.segments.count == 1 {
        val nm = underlying.segments[0]
        if not containsName(generics, nm) and isPrivateTypeName(regs, nm, 0) {
          acc.add(nm)
        }
      }
    }
    case TTuple(types) -> {
      var i = 0
      while i < types.count {
        collectPrivateTypes(types[i], regs, generics, acc)
        i = i + 1
      }
    }
    case TNullable(inner) -> collectPrivateTypes(inner, regs, generics, acc)
    case TFunction(parameters, retTy) -> {
      var i = 0
      while i < parameters.count {
        collectPrivateTypes(parameters[i], regs, generics, acc)
        i = i + 1
      }
      collectPrivateTypes(retTy, regs, generics, acc)
    }
    case TParen(inner) -> collectPrivateTypes(inner, regs, generics, acc)
    case _ -> ()
  }
}

func privacyMessage(itemLabel: in String, posDesc: in String, name: in String): String {
  itemLabel + " " + posDesc + " references package-private type '" + name + "' from the same package — mark '" + name +
    "' pub or internal, or remove this item's pub/internal modifier"
}

func checkTypePrivacy(
  regs: in List[LintTypeDecl],
  generics: in List[String],
  ty: in TypeExpr,
  itemLabel: in String,
  posDesc: in String,
  sp: in Span,
): List[LintDiag] {
  val names: List[String] = newList()
  collectPrivateTypes(ty, regs, generics, names)
  val acc: List[LintDiag] = newList()
  // One warning per distinct private type in a position: `Map[K, K]`
  // names `K` once as far as the author is concerned.
  val seen: List[String] = newList()
  var i = 0
  while i < names.count {
    if not containsName(seen, names[i]) {
      seen.add(names[i])
      acc.add(lintWarning("L007", privacyMessage(itemLabel, posDesc, names[i]), sp))
    }
    i = i + 1
  }
  acc
}

func checkBareNamePrivacy(
  regs: in List[LintTypeDecl],
  generics: in List[String],
  name: in String,
  itemLabel: in String,
  posDesc: in String,
  sp: in Span,
): List[LintDiag] {
  val acc: List[LintDiag] = newList()
  if not containsName(generics, name) and isPrivateTypeName(regs, name, 0) {
    acc.add(lintWarning("L007", privacyMessage(itemLabel, posDesc, name), sp))
  }
  acc
}

// The receiver of a dotted type-associated function (`pub func Widget.create(...)`)
// is the first `.`-separated segment of `fn.name`; `None` for an ordinary
// (non-dotted) function name.
func funcReceiverName(name: in String): Option[String] {
  match Str.indexOf(name, ".") {
    case Some(idx) -> Some(value = Str.substring(name, 0, idx))
    case None -> None
  }
}

// Checks a function's full signature (receiver, parameters, return type)
// for package-private same-file types.  `receiverName`, when present, is
// checked as its own position; once reported, the receiver's type is not
// reported again for the same function (a self parameter, or a factory's
// `Widget.new(): Widget` return).
func checkFunctionSignaturePrivacy(
  regs: in List[LintTypeDecl],
  outerGenerics: in List[String],
  fn: in FunctionDecl,
  receiverName: in Option[String],
  itemLabel: in String,
): List[LintDiag] {
  val acc: List[LintDiag] = newList()
  val base = mergeNames(outerGenerics, genericParamNames(fn.generics))
  var generics = base
  match receiverName {
    case Some(r) -> {
      val rd = checkBareNamePrivacy(regs, base, r, itemLabel, "receiver '" + r + "'", fn.span)
      appendDiags(acc, rd)
      generics = withReportedReceiver(base, rd, r)
    }
    case None -> ()
  }
  var pi = 0
  while pi < fn.params.count {
    val p = fn.params[pi]
    appendDiags(acc, checkTypePrivacy(regs, generics, p.ty, itemLabel, "parameter '" + p.name + "'", p.span))
    pi = pi + 1
  }
  match fn.ret {
    case Some(rt) -> appendDiags(acc, checkTypePrivacy(regs, generics, rt, itemLabel, "return type", rt.span))
    case None -> ()
  }
  acc
}

// The exclusion set for a signature's remaining positions: once the
// receiver itself has been reported, its name joins the set so the same
// private type is not reported again for the same item.
func withReportedReceiver(generics: in List[String], receiverDiags: in List[LintDiag], r: in String): List[String] {
  if receiverDiags.count == 0 {
    return generics
  }
  val one: List[String] = newList()
  one.add(r)
  mergeNames(generics, one)
}

// A `pub func` member declared inside a `protected type` body (a record
// body cannot carry its own `pub`/`internal` modifier on a method — the
// grammar has no dispatch for it, so record-body methods take whatever
// visibility they always parse to, `None`, and never reach this check)
// always has an implicit receiver — the enclosing protected type — even
// though `fn.name` carries no dotted prefix there, so the receiver check
// always runs with the enclosing type's name rather than deriving it from
// `fn.name`.
func checkInBodyMethodPrivacy(
  regs: in List[LintTypeDecl],
  outerGenerics: in List[String],
  fn: in FunctionDecl,
  enclosingName: in String,
  itemLabel: in String,
): List[LintDiag] {
  checkFunctionSignaturePrivacy(regs, outerGenerics, fn, Some(value = enclosingName), itemLabel)
}

func checkFunctionSigPrivacy(
  regs: in List[LintTypeDecl],
  outerGenerics: in List[String],
  sig: in FunctionSig,
  itemLabel: in String,
): List[LintDiag] {
  val acc: List[LintDiag] = newList()
  val generics = mergeNames(outerGenerics, genericParamNames(sig.generics))
  var pi = 0
  while pi < sig.params.count {
    val p = sig.params[pi]
    appendDiags(acc, checkTypePrivacy(regs, generics, p.ty, itemLabel, "parameter '" + p.name + "'", p.span))
    pi = pi + 1
  }
  match sig.ret {
    case Some(rt) -> appendDiags(acc, checkTypePrivacy(regs, generics, rt, itemLabel, "return type", rt.span))
    case None -> ()
  }
  acc
}

func checkEntrySignaturePrivacy(
  regs: in List[LintTypeDecl],
  outerGenerics: in List[String],
  ed: in EntryDecl,
  receiverName: in String,
  itemLabel: in String,
): List[LintDiag] {
  val acc: List[LintDiag] = newList()
  val rd = checkBareNamePrivacy(
    regs,
    outerGenerics,
    receiverName,
    itemLabel,
    "receiver '" + receiverName + "'",
    ed.span
  )
  appendDiags(acc, rd)
  val generics = withReportedReceiver(outerGenerics, rd, receiverName)
  var pi = 0
  while pi < ed.params.count {
    val p = ed.params[pi]
    appendDiags(acc, checkTypePrivacy(regs, generics, p.ty, itemLabel, "parameter '" + p.name + "'", p.span))
    pi = pi + 1
  }
  match ed.ret {
    case Some(rt) -> appendDiags(acc, checkTypePrivacy(regs, generics, rt, itemLabel, "return type", rt.span))
    case None -> ()
  }
  acc
}

func checkRecordFieldsPrivacy(regs: in List[LintTypeDecl], rd: in RecordDecl, itemLabel: in String): List[LintDiag] {
  val acc: List[LintDiag] = newList()
  val generics = genericParamNames(rd.generics)
  var mi = 0
  while mi < rd.members.count {
    match rd.members[mi] {
      case RMField(f) -> {
        match f.visibility {
          case Some(_) -> {
            appendDiags(acc, checkTypePrivacy(regs, generics, f.ty, itemLabel, "field '" + f.name + "'", f.span))
          }
          case None -> ()
        }
      }
      case _ -> ()
    }
    mi = mi + 1
  }
  acc
}

func checkUnionCasesPrivacy(regs: in List[LintTypeDecl], ud: in UnionDecl, itemLabel: in String): List[LintDiag] {
  val acc: List[LintDiag] = newList()
  val generics = genericParamNames(ud.generics)
  var ci = 0
  while ci < ud.cases.count {
    val c = ud.cases[ci]
    var fi = 0
    while fi < c.fields.count {
      match c.fields[fi] {
        case UFNamed(fname, fty, fsp) -> {
          appendDiags(acc, checkTypePrivacy(regs, generics, fty, itemLabel, "case '" + c.name + "' field '" + fname + "'", fsp))
        }
        case UFPos(fty, fsp) -> {
          appendDiags(acc, checkTypePrivacy(regs, generics, fty, itemLabel, "case '" + c.name + "' payload", fsp))
        }
      }
      fi = fi + 1
    }
    ci = ci + 1
  }
  acc
}

func patternBindingName(p: in Pattern): Option[String] {
  match p.kind {
    case PBinding(n, _) -> Some(value = n)
    case PParen(inner) -> patternBindingName(inner)
    case _ -> None
  }
}

// ─── Item walker ──────────────────────────────────────────────────────────────
func checkItem(item: in Item, isRuntimeChecked: in Bool, regs: in List[LintTypeDecl]): List[LintDiag] {
  val acc: List[LintDiag] = newList()
  val vis = item.visibility
  val docs = item.docComments
  val noGenerics: List[String] = newList()
  match item.kind {
    case IFunc(fn) -> {
      appendDiags(acc, checkFuncName(fn.name, fn.span))
      appendDiags(acc, checkPubDoc(vis, docs, fn.name, "func", item.span))
      appendDiags(acc, checkDocTodos(docs))
      appendDiags(acc, checkPubContract(vis, fn, isRuntimeChecked))
      match vis {
        case Some(_) -> {
          appendDiags(
            acc,
            checkFunctionSignaturePrivacy(regs, noGenerics, fn, funcReceiverName(fn.name), "pub func '" + fn.name + "'")
          )
        }
        case None -> ()
      }
    }
    case IRecord(rd) -> {
      appendDiags(acc, checkTypeName(rd.name, rd.span))
      appendDiags(acc, checkPubDoc(vis, docs, rd.name, "record", item.span))
      appendDiags(acc, checkDocTodos(docs))
      match vis {
        case Some(_) -> appendDiags(acc, checkRecordFieldsPrivacy(regs, rd, "pub record '" + rd.name + "'"))
        case None -> ()
      }
    }
    case IExposedRec(rd) -> {
      appendDiags(acc, checkTypeName(rd.name, rd.span))
      appendDiags(acc, checkPubDoc(vis, docs, rd.name, "exposed record", item.span))
      appendDiags(acc, checkDocTodos(docs))
      match vis {
        case Some(_) -> appendDiags(acc, checkRecordFieldsPrivacy(regs, rd, "pub exposed record '" + rd.name + "'"))
        case None -> ()
      }
    }
    case IUnion(ud) -> {
      appendDiags(acc, checkTypeName(ud.name, ud.span))
      appendDiags(acc, checkPubDoc(vis, docs, ud.name, "union", item.span))
      appendDiags(acc, checkDocTodos(docs))
      match vis {
        case Some(_) -> appendDiags(acc, checkUnionCasesPrivacy(regs, ud, "pub union '" + ud.name + "'"))
        case None -> ()
      }
    }
    case IEnum(ed) -> {
      appendDiags(acc, checkTypeName(ed.name, ed.span))
      appendDiags(acc, checkPubDoc(vis, docs, ed.name, "enum", item.span))
      appendDiags(acc, checkDocTodos(docs))
    }
    case IOpaque(od) -> {
      appendDiags(acc, checkTypeName(od.name, od.span))
      appendDiags(acc, checkPubDoc(vis, docs, od.name, "opaque type", item.span))
      appendDiags(acc, checkDocTodos(docs))
    }
    case IProtected(pd) -> {
      // Members carry no generics of their own; the type's parameters
      // shadow same-named private types in their signatures (#7621).
      val protGenerics = genericParamNames(pd.generics)
      appendDiags(acc, checkTypeName(pd.name, pd.span))
      appendDiags(acc, checkPubDoc(vis, docs, pd.name, "protected type", item.span))
      appendDiags(acc, checkDocTodos(docs))
      var mi = 0
      while mi < pd.members.count {
        match pd.members[mi] {
          case PMEntry(ed) -> {
            appendDiags(acc, checkFuncName(ed.name, ed.span))
            appendDiags(acc, checkPubDoc(ed.visibility, ed.docComments, ed.name, "entry", ed.span))
            appendDiags(acc, checkDocTodos(ed.docComments))
            match ed.visibility {
              case Some(_) -> {
                appendDiags(
                  acc,
                  checkEntrySignaturePrivacy(
                    regs,
                    protGenerics,
                    ed,
                    pd.name,
                    "pub protected type '" + pd.name + "' entry '" + ed.name + "'"
                  )
                )
              }
              case None -> ()
            }
          }
          case PMFunc(fn) -> {
            appendDiags(acc, checkFuncName(fn.name, fn.span))
            appendDiags(acc, checkDocTodos(fn.docComments))
            match fn.visibility {
              case Some(_) -> {
                appendDiags(
                  acc,
                  checkInBodyMethodPrivacy(regs, protGenerics, fn, pd.name, "pub func '" + pd.name + "." + fn.name + "'")
                )
              }
              case None -> ()
            }
          }
          case _ -> ()
        }
        mi = mi + 1
      }
    }
    case IInterface(id) -> {
      appendDiags(acc, checkTypeName(id.name, id.span))
      appendDiags(acc, checkPubDoc(vis, docs, id.name, "interface", item.span))
      appendDiags(acc, checkDocTodos(docs))
      val ifaceGenerics = genericParamNames(id.generics)
      var mi = 0
      while mi < id.members.count {
        match id.members[mi] {
          case IMSig(sg) -> {
            appendDiags(acc, checkFuncName(sg.name, sg.span))
            match vis {
              case Some(_) -> {
                appendDiags(
                  acc,
                  checkFunctionSigPrivacy(regs, ifaceGenerics, sg, "pub interface '" + id.name + "' method '" + sg.name + "'")
                )
              }
              case None -> ()
            }
          }
          case IMFunc(fn) -> {
            appendDiags(acc, checkFuncName(fn.name, fn.span))
            appendDiags(acc, checkDocTodos(fn.docComments))
            match vis {
              case Some(_) -> {
                appendDiags(
                  acc,
                  checkFunctionSignaturePrivacy(
                    regs,
                    ifaceGenerics,
                    fn,
                    None,
                    "pub interface '" + id.name + "' method '" + fn.name + "'"
                  )
                )
              }
              case None -> ()
            }
          }
          case IMAssoc(_) -> ()
        }
        mi = mi + 1
      }
    }
    case IImpl(id) -> {
      appendDiags(acc, checkDocTodos(docs))
      var mi = 0
      while mi < id.members.count {
        match id.members[mi] {
          case IMplFunc(fn) -> {
            appendDiags(acc, checkFuncName(fn.name, fn.span))
            appendDiags(acc, checkDocTodos(fn.docComments))
          }
          case IMplAssoc(_) -> ()
        }
        mi = mi + 1
      }
    }
    case IDistinctType(dt) -> {
      appendDiags(acc, checkTypeName(dt.name, dt.span))
      appendDiags(acc, checkPubDoc(vis, docs, dt.name, "distinct type", item.span))
      appendDiags(acc, checkDocTodos(docs))
    }
    case ITypeAlias(ta) -> {
      appendDiags(acc, checkTypeName(ta.name, ta.span))
      appendDiags(acc, checkPubDoc(vis, docs, ta.name, "type alias", item.span))
      appendDiags(acc, checkDocTodos(docs))
    }
    case IConst(cd) -> {
      val nameOk = startsUpper(cd.name) or isUpperSnake(cd.name)
      if not nameOk {
        acc.add(lintWarning("L001", "const '" + cd.name + "' should be PascalCase or UPPER_SNAKE_CASE", cd.span))
      }
      appendDiags(acc, checkPubDoc(vis, docs, cd.name, "const", item.span))
      appendDiags(acc, checkDocTodos(docs))
      match vis {
        case Some(_) -> {
          appendDiags(acc, checkTypePrivacy(regs, noGenerics, cd.ty, "pub const '" + cd.name + "'", "type", cd.span))
        }
        case None -> ()
      }
    }
    case IVal(vd) -> {
      appendDiags(acc, checkDocTodos(docs))
      match vis {
        case Some(_) -> {
          val valName = match patternBindingName(vd.pattern) { case Some(n) -> n; case None -> "val" }
          match vd.ty {
            case Some(ty) -> {
              appendDiags(acc, checkTypePrivacy(regs, noGenerics, ty, "pub val '" + valName + "'", "type", ty.span))
            }
            case None -> ()
          }
        }
        case None -> ()
      }
    }
    case _ -> {
      appendDiags(acc, checkDocTodos(docs))
    }
  }
  acc
}

// ─── Sort helper (insertion sort by line/col) ─────────────────────────────────
func sortDiags(diags: in List[LintDiag]): List[LintDiag] {
  val n = diags.count
  var i = 1
  while i < n {
    val key = diags[i]
    var j = i - 1
    while j >= 0 {
      val dj = diags[j]
      val kLine = key.span.startPos.line
      val djLine = dj.span.startPos.line
      val kCol = key.span.startPos.column
      val djCol = dj.span.startPos.column
      if djLine > kLine or (djLine == kLine and djCol > kCol) {
        diags[j + 1] = dj
        j = j - 1
      } else {
        break
      }
    }
    diags[j + 1] = key
    i = i + 1
  }
  diags
}

// ─── Public entry ─────────────────────────────────────────────────────────────
pub func lint(source: in String): List[LintDiag] {
  val pr = parse(source)
  val file = pr.file
  var isRuntimeChecked = false
  var ai = 0
  while ai < file.fileAnnotations.count {
    val ann = file.fileAnnotations[ai]
    if ann.name.segments.count == 1 and ann.name.segments[0] == "runtime_checked" {
      isRuntimeChecked = true
    }
    ai = ai + 1
  }
  val regs = buildTypeRegistry(file)
  val acc: List[LintDiag] = newList()
  var i = 0
  while i < file.items.count {
    appendDiags(acc, checkItem(file.items[i], isRuntimeChecked, regs))
    i = i + 1
  }
  sortDiags(acc)
}
