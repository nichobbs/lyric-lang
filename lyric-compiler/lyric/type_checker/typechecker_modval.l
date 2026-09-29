//! typechecker_modval.l — module-level destructuring `val` (#7763).
//!
//! The grammar's `ValDecl` takes a pattern (`val (lo, hi) = bounds()`), but
//! the checker and every backend only understand a module-level `val` that
//! binds one name.  `desugarModuleValPatterns` rewrites each module-level
//! `val` whose pattern is an irrefutable destructuring — `_`, a tuple of
//! those, a name, a `name @ <irrefutable>` binding, in any parentheses —
//! into single-name `val`s, in source order, before anything indexes or
//! checks the items:
//!
//!   * a tuple pattern over a tuple literal of the same arity binds element
//!     by element (`val (a, b) = (1, 2)` is `val a = 1` then `val b = 2`), so
//!     each binding keeps a literal initializer where the source had one;
//!   * anything else evaluates the initializer once into a
//!     `__lyric_modval_<n>` and binds each name to a `match` projecting it
//!     out of that value.
//!
//! A tuple type annotation is split across the bindings so each gets its
//! element type; any other binding is annotated with its checked type after
//! type checking (`recordModuleValTypes` / `annotateModuleVals`).  Every
//! binding keeps the declaration's visibility, doc comments and annotations.
//! A temporary has the declaration's visibility too: an importing package
//! types a projected `pub` name from its initializer, which reads the
//! temporary, before the declaring package's checked types exist.
//!
//! A refutable pattern (constructor, record, literal, range, type test,
//! alternatives, const pattern) has no failure path at module level and is
//! rejected with T0144, naming the form.
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

pub record ModuleValDesugarResult {
  file: SourceFile
  diagnostics: List[Diagnostic]
}

/// Rewrites every destructuring module-level `val` of `file` into
/// single-name `val`s; see the file header.  Idempotent.
pub func desugarModuleValPatterns(file: in SourceFile): ModuleValDesugarResult {
  val diag: List[Diagnostic] = newList()
  val items = desugarModuleValItems(file.items, diag)
  ModuleValDesugarResult(
    file = SourceFile(
      moduleDoc = file.moduleDoc,
      fileAnnotations = file.fileAnnotations,
      packageDecl = file.packageDecl,
      imports = file.imports,
      items = items,
      span = file.span
    ),
    diagnostics = diag
  )
}

/// The item-list form of `desugarModuleValPatterns`, for items gathered from
/// another package.  T0144 diagnostics go to `diag`; a refutable `val` is
/// kept as written.
pub func desugarModuleValItems(items: in List[Item], diag: in List[Diagnostic]): List[Item] {
  if not hasDestructuringVal(items) {
    return items
  }
  val dest: List[Item] = newList()
  val ctr = ModValCounter(next = 0)
  for it in items {
    match it.kind {
      case IVal(decl) -> match decl.pattern.kind {
        case PBinding(_, None) -> dest.add(it)
        case _ -> {
          val refutable = refutablePatternForm(decl.pattern)
          if refutable.length > 0 {
            diag.add(
              errorDiagnostic(
                "T0144",
                "a module-level `val` must bind an irrefutable pattern (a name, `_`, `name @ <pattern>`, or a tuple " +
                  "of those), but this one is " +
                  refutable +
                  ", which can fail to match and has no failure path at " +
                  "module level" +
                  refutableHint(decl.pattern),
                decl.pattern.span
              )
            )
            dest.add(it)
          } else {
            bindModuleVal(it, decl.pattern, decl.init, decl.ty, ctr, dest)
          }
        }
      }
      case _ -> dest.add(it)
    }
  }
  dest
}

func hasDestructuringVal(items: in List[Item]): Bool {
  for it in items {
    match it.kind {
      case IVal(decl) -> match decl.pattern.kind { case PBinding(_, None) -> (); case _ -> return true }
      case _ -> ()
    }
  }
  false
}

record ModValCounter {
  var next: Int
}

val modValBinder = "__lyric_modval_bind"

// The refutable form `p` contains, described for T0144, or "" when `p` is
// irrefutable.
func refutablePatternForm(p: in Pattern): String {
  match p.kind {
    case PWildcard -> ""
    case PBinding(_, inner) -> match inner { case Some(ip) -> refutablePatternForm(ip); case None -> "" }
    case PParen(ip) -> refutablePatternForm(ip)
    case PTuple(ps) -> {
      for q in ps {
        val f = refutablePatternForm(q)
        if f.length > 0 {
          return f
        }
      }
      ""
    }
    case PConstructor(_, _) -> "a constructor pattern"
    case PRecord(_, _, _) -> "a record pattern"
    case PLiteral(_) -> "a literal pattern"
    case PRange(_, _, _, _) -> "a range pattern"
    case PTypeTest(_, _) -> "a type-test pattern"
    case POr(_) -> "an alternative (`|`) pattern"
    case PConstRef(_) -> "a const pattern"
    case PError -> "a malformed pattern"
  }
}

func refutableHint(p: in Pattern): String {
  match p.kind {
    case PTypeTest(inner, _) -> match inner.kind {
      case PBinding(_, None) -> "; declare the type with `val <name>: <Type> = ...` instead"
      case _ -> ""
    }
    case PParen(ip) -> refutableHint(ip)
    case _ -> "; destructure it with a `match` inside a function instead"
  }
}

func stripPatternParens(p: in Pattern): Pattern {
  match p.kind {
    case PParen(ip) -> stripPatternParens(ip)
    case _ -> p
  }
}

func stripExprParens(e: in Expr): Expr {
  match e.kind {
    case EParen(inner) -> stripExprParens(inner)
    case _ -> e
  }
}

// The element types of a tuple annotation of arity `n`, or None when `ty` is
// not written as one.
func tupleElemTypes(ty: in TypeExpr, n: in Int): Option[List[TypeExpr]] {
  match ty.kind {
    case TParen(inner) -> tupleElemTypes(inner, n)
    case TTuple(ts) -> if ts.count == n { Some(value = ts) } else { None }
    case _ -> None
  }
}

// Emits the single-name `val`s for `pat = init` (annotated `ty`) in place of
// the destructuring item `orig`.
func bindModuleVal(
  orig: in Item,
  pat: in Pattern,
  init: in Expr,
  ty: in Option[TypeExpr],
  ctr: in ModValCounter,
  dest: in List[Item],
): Unit {
  val p = stripPatternParens(pat)
  match p.kind {
    case PBinding(name, None) -> dest.add(namedVal(orig, name, ty, init, p.span))
    case PWildcard -> {
      // Nothing to evaluate for a bare literal; anything else still runs
      // (and an annotation is still checked) like any module `val`.
      val annotated = match ty { case Some(_) -> true; case None -> false }
      if not isLiteralExpr(init) or annotated {
        val _ = tempVal(orig, init, ty, ctr, dest)
      }
    }
    case PTuple(ps) -> {
      val es: Option[List[Expr]] = match stripExprParens(init).kind {
        case ETuple(xs) -> if xs.count == ps.count { Some(value = xs) } else { None }
        case _ -> None
      }
      val tys: Option[Option[List[TypeExpr]]] = match ty {
        case None -> Some(value = None)
        case Some(t) -> match tupleElemTypes(t, ps.count) {
          case Some(ts) -> Some(value = Some(value = ts))
          case None -> None
        }
      }
      match es {
        case Some(xs) -> match tys {
          case Some(elemTys) -> {
            var i = 0
            while i < ps.count {
              val ety: Option[TypeExpr] = match elemTys { case Some(ts) -> Some(value = ts[i]); case None -> None }
              bindModuleVal(orig, ps[i], xs[i], ety, ctr, dest)
              i = i + 1
            }
          }
          case None -> projectFromTemp(orig, p, init, ty, ctr, dest)
        }
        case None -> projectFromTemp(orig, p, init, ty, ctr, dest)
      }
    }
    case _ -> projectFromTemp(orig, p, init, ty, ctr, dest)
  }
}

// `val __lyric_modval_<n> = init`, then one `val` per name `p` binds,
// projected out of it with a `match`.
func projectFromTemp(
  orig: in Item,
  p: in Pattern,
  init: in Expr,
  ty: in Option[TypeExpr],
  ctr: in ModValCounter,
  dest: in List[Item],
): Unit {
  val temp = tempVal(orig, init, ty, ctr, dest)
  val names: List[String] = newList()
  collectBinderNames(p, names)
  for name in names {
    val sp = orig.span
    val scrutinee = pathExpr(temp, sp)
    val arm = MatchArm(
      pattern = projectionPattern(p, name),
      guard = None,
      body = EOBExpr(expr = pathExpr(modValBinder, sp)),
      span = sp
    )
    val arms: List[MatchArm] = newList()
    arms.add(arm)
    val proj = Expr(kind = EMatch(scrutinee = scrutinee, arms = arms), span = sp)
    dest.add(namedVal(orig, name, binderType(p, ty, name), proj, sp))
  }
}

func tempVal(orig: in Item, init: in Expr, ty: in Option[TypeExpr], ctr: in ModValCounter, dest: in List[Item]): String {
  val name = "__lyric_modval_" + toString(ctr.next)
  ctr.next = ctr.next + 1
  val noDocs: List[DocComment] = newList()
  val noAnns: List[Annotation] = newList()
  dest.add(
    Item(
      docComments = noDocs,
      annotations = noAnns,
      visibility = orig.visibility,
      kind = IVal(decl = ValDecl(pattern = bindingPattern(name, orig.span), ty = ty, init = init, span = orig.span)),
      span = orig.span
    )
  )
  name
}

func namedVal(orig: in Item, name: in String, ty: in Option[TypeExpr], init: in Expr, sp: in Span): Item {
  Item(
    docComments = orig.docComments,
    annotations = orig.annotations,
    visibility = orig.visibility,
    kind = IVal(decl = ValDecl(pattern = bindingPattern(name, sp), ty = ty, init = init, span = orig.span)),
    span = orig.span
  )
}

func bindingPattern(name: in String, sp: in Span): Pattern {
  Pattern(kind = PBinding(name = name, inner = None), span = sp)
}

func pathExpr(name: in String, sp: in Span): Expr {
  val segs: List[String] = newList()
  segs.add(name)
  Expr(kind = EPath(path = ModulePath(segments = segs, span = sp)), span = sp)
}

func isLiteralExpr(e: in Expr): Bool {
  match stripExprParens(e).kind {
    case ELiteral(_) -> true
    case _ -> false
  }
}

// The names an irrefutable pattern binds, in source order.
func collectBinderNames(p: in Pattern, acc: in List[String]): Unit {
  match p.kind {
    case PBinding(name, inner) -> {
      acc.add(name)
      match inner {
        case Some(ip) -> collectBinderNames(ip, acc)
        case None -> ()
      }
    }
    case PParen(ip) -> collectBinderNames(ip, acc)
    case PTuple(ps) -> {
      for q in ps {
        collectBinderNames(q, acc)
      }
    }
    case _ -> ()
  }
}

// `p` with `target` bound to the reserved projection binder and every other
// name replaced by `_`.  The binder name is never a union case, so the arm
// can only bind, never test.
func projectionPattern(p: in Pattern, target: in String): Pattern {
  val kind: PatternKind = match p.kind {
    case PBinding(name, inner) -> {
      val newInner: Option[Pattern] = match inner {
        case Some(ip) -> Some(value = projectionPattern(ip, target))
        case None -> None
      }
      if name == target {
        PBinding(name = modValBinder, inner = newInner)
      } else {
        match newInner {
          case Some(ip) -> ip.kind
          case None -> PWildcard
        }
      }
    }
    case PParen(ip) -> PParen(inner = projectionPattern(ip, target))
    case PTuple(ps) -> {
      val qs: List[Pattern] = newList()
      for q in ps {
        qs.add(projectionPattern(q, target))
      }
      PTuple(patterns = qs)
    }
    case other -> other
  }
  Pattern(kind = kind, span = p.span)
}

// The annotation for binder `name` of `p`, when `ty` spells its position's
// type out (a tuple annotation, split element-wise).
func binderType(p: in Pattern, ty: in Option[TypeExpr], name: in String): Option[TypeExpr] {
  match ty {
    case None -> None
    case Some(t) -> match p.kind {
      case PBinding(n, inner) -> {
        if n == name {
          return ty
        }
        match inner {
          case Some(ip) -> binderType(ip, ty, name)
          case None -> None
        }
      }
      case PParen(ip) -> binderType(ip, ty, name)
      case PTuple(ps) -> match tupleElemTypes(t, ps.count) {
        case Some(ts) -> {
          var i = 0
          while i < ps.count {
            val found = binderType(ps[i], Some(value = ts[i]), name)
            match found {
              case Some(_) -> return found
              case None -> ()
            }
            i = i + 1
          }
          None
        }
        case None -> None
      }
      case _ -> None
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Checked types for the synthesized values.
// ─────────────────────────────────────────────────────────────────────────────
val modValTempPrefix = "__lyric_modval_"

/// Records, in `tbl.moduleValTypes`, the checked type of every unannotated
/// `val` the desugaring above synthesized (a temporary, or a name projected
/// out of one), so `annotateModuleVals` can write it onto the declaration:
/// a backend reads a tuple element back erased and needs the element type
/// to narrow it (the #7728 rule, applied at module level).  A tuple pattern
/// whose shape the initializer's type cannot have is T0144, reported once
/// per declaration.
pub func recordModuleValTypes(
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  items: in List[Item],
): Unit {
  val reported: Map[String, Bool] = newMap()
  for it in items {
    match it.kind {
      case IVal(decl) -> match decl.pattern.kind {
        case PBinding(name, None) -> match decl.ty {
          case None -> {
            if name.startsWith(modValTempPrefix) {
              recordModuleValType(tbl, name, inferModuleValInit(tbl, sigs, decl.init), decl.span)
            } else {
              match projectedTemp(decl.init) {
                case Some(proj) -> {
                  val tempTy = inferModuleValInit(tbl, sigs, pathExpr(proj.temp, decl.span))
                  val problem = tupleShapeProblem(proj.pattern, tempTy)
                  if problem.length > 0 {
                    if not reported.containsKey(proj.temp) {
                      reported[proj.temp] = true
                      diag.add(
                        errorDiagnostic(
                          "T0144",
                          "a module-level `val` must bind an irrefutable pattern, but " + problem +
                            ", so the pattern can never match its initializer",
                          decl.span
                        )
                      )
                    }
                  } else {
                    recordModuleValType(tbl, name, inferModuleValInit(tbl, sigs, decl.init), decl.span)
                  }
                }
                case None -> ()
              }
            }
          }
          case Some(_) -> ()
        }
        case _ -> ()
      }
      case _ -> ()
    }
  }
}

/// `file` with each value `recordModuleValTypes` typed annotated with it.
pub func annotateModuleVals(file: in SourceFile, types: in Map[String, TypeExpr]): SourceFile {
  if types.count == 0 {
    return file
  }
  val items: List[Item] = newList()
  for it in file.items {
    val annotated: Option[Item] = match it.kind {
      case IVal(decl) -> match decl.ty {
        case None -> match decl.pattern.kind {
          case PBinding(name, None) -> match mapGet(types, name) {
            case Some(te) -> Some(
              value = Item(
                docComments = it.docComments,
                annotations = it.annotations,
                visibility = it.visibility,
                kind = IVal(
                  decl = ValDecl(
                    pattern = decl.pattern,
                    ty = Some(
                      value = te
                    ),
                    init = decl.init,
                    span = decl.span
                  )
                ),
                span = it.span
              )
            )
            case None -> None
          }
          case _ -> None
        }
        case Some(_) -> None
      }
      case _ -> None
    }
    match annotated {
      case Some(a) -> items.add(a)
      case None -> items.add(it)
    }
  }
  SourceFile(
    moduleDoc = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = file.imports,
    items = items,
    span = file.span
  )
}

record ProjectedTemp {
  temp: String
  pattern: Pattern
}

// The temporary and pattern of a `match __lyric_modval_<n> { case P ->
// __lyric_modval_bind }` projection.
func projectedTemp(init: in Expr): Option[ProjectedTemp] {
  match init.kind {
    case EMatch(scrutinee, arms) -> match scrutinee.kind {
      case EPath(path) -> {
        if arms.count == 1 and path.segments.count == 1 and path.segments[0].startsWith(modValTempPrefix) {
          Some(value = ProjectedTemp(temp = path.segments[0], pattern = arms[0].pattern))
        } else {
          None
        }
      }
      case _ -> None
    }
    case _ -> None
  }
}

// An initializer is inferred like a module value read (an empty local scope)
// into a scratch list: whatever it reports, a use of the value reports too.
func inferModuleValInit(tbl: in SymbolTable, sigs: in Map[String, ResolvedSignature], init: in Expr): Type {
  val scratch: List[Diagnostic] = newList()
  val noRte: Option[TypeExpr] = None
  val noSelfFields: Map[String, Type] = newMap()
  val emptyScope = newScopeForFunction(TyError, newList(), noRte, noSelfFields, false, TyError)
  inferExpr(emptyScope, tbl, sigs, scratch, init)
}

func recordModuleValType(tbl: in SymbolTable, name: in String, ty: in Type, sp: in Span): Unit {
  val usable = match unrefine(ty) {
    case TyError -> false
    case TyPrim(pt) -> match pt { case PtUnit -> false; case PtNever -> false; case _ -> true }
    case _ -> true
  }
  if not usable {
    return
  }
  match typeExprForRef(tbl, ty, sp) {
    case Some(te) -> {
      tbl.moduleValTypes[name] = te
    }
    case None -> ()
  }
}

// Why tuple pattern `p` cannot match a value of type `ty`, or "".  A type the
// checker could not resolve is not a mismatch (it was reported elsewhere).
func tupleShapeProblem(p: in Pattern, ty: in Type): String {
  match p.kind {
    case PParen(ip) -> tupleShapeProblem(ip, ty)
    case PBinding(_, inner) -> match inner { case Some(ip) -> tupleShapeProblem(ip, ty); case None -> "" }
    case PTuple(ps) -> match unrefine(ty) {
      case TyError -> ""
      case TyVar(_) -> ""
      case TyTuple(elems) -> {
        if elems.count != ps.count {
          return "a " + toString(ps.count) + "-element tuple pattern is bound to a value of type " + renderType(ty)
        }
        var i = 0
        while i < ps.count {
          val inner = tupleShapeProblem(ps[i], elems[i])
          if inner.length > 0 {
            return inner
          }
          i = i + 1
        }
        ""
      }
      case _ -> "a " + toString(ps.count) + "-element tuple pattern is bound to a value of type " +
        renderType(ty)
    }
    case _ -> ""
  }
}
