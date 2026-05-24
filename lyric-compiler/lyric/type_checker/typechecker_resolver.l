// typechecker_resolver.l — resolves parser TypeExpr to checker Type.
// Mirrors compiler/src/Lyric.TypeChecker/Resolver.fs.
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Public entry point.
// ─────────────────────────────────────────────────────────────────────────────

pub func resolveType(
  tbl:  in SymbolTable,
  ctx:  in GenericContext,
  diag: in List[Diagnostic],
  te:   in TypeExpr
): Type {
  match te.kind {
    case TUnit        -> TyPrim(pt = PtUnit)
    case TSelf        -> TySelf
    case TNever       -> TyPrim(pt = PtNever)
    case TError       -> TyError
    case TParen(inner) -> resolveType(tbl, ctx, diag, inner)

    case TTuple(elems) -> {
      val ts: List[Type] = newList()
      var i = 0
      while i < elems.count {
        ts.add(resolveType(tbl, ctx, diag, elems[i]))
        i = i + 1
      }
      TyTuple(elems = ts)
    }

    case TNullable(inner) ->
      TyNullable(inner = resolveType(tbl, ctx, diag, inner))

    case TFunction(ps, rte) -> {
      val pts: List[Type] = newList()
      var i = 0
      while i < ps.count {
        pts.add(resolveType(tbl, ctx, diag, ps[i]))
        i = i + 1
      }
      val rt = resolveType(tbl, ctx, diag, rte)
      TyFunction(params = pts, ret = rt, isAsync = false)
    }

    case TArray(_, elem) ->
      TyArray(size = None, element = resolveType(tbl, ctx, diag, elem))

    case TSlice(elem) ->
      TySlice(element = resolveType(tbl, ctx, diag, elem))

    case TRef(path) -> {
      val args: List[Type] = newList()
      resolveTypePath(tbl, ctx, diag, path, te.span, args)
    }

    case TGenericApp(head, argsList) -> {
      val resolvedArgs: List[Type] = newList()
      var i = 0
      while i < argsList.count {
        match argsList[i] {
          case TAType(t)  -> resolvedArgs.add(resolveType(tbl, ctx, diag, t))
          case TAValue(_) -> resolvedArgs.add(TyError)
        }
        i = i + 1
      }
      resolveTypePath(tbl, ctx, diag, head, te.span, resolvedArgs)
    }

    case TRefined(under, _) -> {
      val args: List[Type] = newList()
      resolveTypePath(tbl, ctx, diag, under, te.span, args)
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Path resolution helper.
// ─────────────────────────────────────────────────────────────────────────────

func resolveTypePath(
  tbl:  in SymbolTable,
  ctx:  in GenericContext,
  diag: in List[Diagnostic],
  path: in ModulePath,
  span: in Span,
  args: in List[Type]
): Type {
  if path.segments.count == 0 {
    diag.add(errorDiagnostic("T0010", "empty module path in type position", span))
    return TyError
  }
  if path.segments.count == 1 {
    val name = path.segments[0]
    match primFromString(name) {
      case Some(prim) -> {
        if args.count > 0 {
          diag.add(errorDiagnostic("T0012",
            "primitive type '" + name + "' does not take type arguments", span))
        }
        return TyPrim(pt = prim)
      }
      case None -> {}
    }
    if gctxIsTypeParam(ctx, name) and args.count == 0 {
      return TyVar(name = name)
    }
    match symTableTryFindOne(tbl, name) {
      case Some(sym) ->
        match symbolTypeIdOpt(sym) {
          case Some(tid) -> return TyUser(id = tid, name = sym.name, args = args)
          case None -> {
            diag.add(errorDiagnostic("T0013", "'" + name + "' is not a type", span))
            return TyError
          }
        }
      case None -> {
        diag.add(errorDiagnostic("T0010", "unknown type name '" + name + "'", span))
        return TyError
      }
    }
  }
  // Multi-segment: resolve against the symbol table using the last segment.
  // Types from checkWithImports are registered by simple name, so
  // `Std.Collections.List` resolves to the same entry as `List` when `List`
  // was imported.  Fall through to primitive check, then T0014.
  val last = path.segments[path.segments.count - 1]
  match symTableTryFindOne(tbl, last) {
    case Some(sym) ->
      match symbolTypeIdOpt(sym) {
        case Some(tid) -> return TyUser(id = tid, name = sym.name, args = args)
        case None -> {}
      }
    case None -> {}
  }
  match primFromString(last) {
    case Some(prim) -> {
      if args.count > 0 {
        diag.add(errorDiagnostic("T0012",
          "primitive type '" + last + "' does not take type arguments", span))
      }
      TyPrim(pt = prim)
    }
    case None -> {
      val joined = joinSegments(path.segments)
      diag.add(errorDiagnostic("T0014",
        "unknown qualified type '" + joined + "' ('" + last + "' not found in scope)", span))
      TyError
    }
  }
}

func joinSegments(segs: in List[String]): String {
  if segs.count == 0 { return "" }
  var s = segs[0]
  var i = 1
  while i < segs.count {
    s = s + "." + segs[i]
    i = i + 1
  }
  s
}
