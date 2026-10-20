//! typechecker_foreign.l — `foreign record` (D188, docs/67 §4.7): a struct with C
//! layout that lives in a kernel file and is the shape of a C API's descriptors.
//!
//! A foreign record is a plain layout type.  Its fields are `Plain` types,
//! `NativePtr[T]`, `array[N, T]` of those, or other foreign records; it has no
//! generics, invariants, methods, defaults or `var` fields.  It is a value with
//! no identity (D157): a `val`/`in` binding is immutable and a `var` local or
//! `inout` parameter is written field by field in place, so its address can be
//! handed to C.
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

/// Whether `t` is a declared `foreign record`.
pub func isForeignRecordType(tbl: in SymbolTable, t: in Type): Bool {
  match unrefine(t) {
    case TyUser(tid, _, _) -> match symTableTypeSymbolOf(tbl, tid) {
      case Some(sym) -> match sym.kind {
        case DKRecord(_, rd) -> rd.isForeign
        case _ -> false
      }
      case None -> false
    }
    case _ -> false
  }
}

func isNativePtrType(tbl: in SymbolTable, t: in Type): Bool {
  match unrefine(t) {
    case TyUser(tid, _, _) -> match mapGet(tbl.nativeIntrinsicTypes, "NativePtr") {
      case Some(pid) -> typeIdEq(pid, tid)
      case None -> false
    }
    case _ -> false
  }
}

/// `None` when `t` may be the type of a foreign record's field; otherwise why not.
pub func foreignFieldViolation(tbl: in SymbolTable, t: in Type, depth: in Int): Option[String] {
  if depth > 16 {
    return Some(value = "the type nests too deeply to check")
  }
  if isNativePtrType(tbl, t) or isNativeUserdataType(tbl, t) {
    return None
  }
  match unrefine(t) {
    // A C callback: a function type with a `NativeUserdata` parameter, whose
    // parameters and result are themselves C-passable.  It is stored as a function pointer.
    case TyFunction(ps, ret, _) -> {
      if externCallbackUserdataIndex(tbl, ps) < 0 {
        return Some(value = "a function-typed field is a C callback and needs a NativeUserdata parameter")
      }
      for p in ps {
        match foreignFieldViolation(tbl, p, depth + 1) {
          case Some(why) -> return Some(value = "its callback parameter is not allowed: " + why)
          case None -> ()
        }
      }
      match unrefine(ret) {
        case TyPrim(PtUnit) -> None
        case _ -> match foreignFieldViolation(tbl, ret, depth + 1) {
          case Some(why) -> Some(value = "its callback result is not allowed: " + why)
          case None -> None
        }
      }
    }
    case TyArray(sz, el, _) -> {
      if isNativePtrType(tbl, el) {
        return Some(value = "an array of NativePtr has no layout here; hold the pointers in separate fields")
      }
      match sz {
        case None -> return Some(value = "an array field needs a constant length")
        case Some(_) -> ()
      }
      match foreignFieldViolation(tbl, el, depth + 1) {
        case None -> None
        case Some(why) -> Some(value = "its array element is not allowed: " + why)
      }
    }
    case _ -> if isForeignRecordType(tbl, t) { None } else { plainViolation(tbl, t) }
  }
}

/// The declaration-level rules of a `foreign record`.
pub func checkForeignRecordDecl(tbl: in SymbolTable, diag: in List[Diagnostic], decl: in RecordDecl): Unit {
  match decl.generics {
    case Some(_) -> diag.add(
      errorDiagnostic(
        "T0178",
        "foreign record '" + decl.name + "' cannot be generic: a C layout is one concrete type",
        decl.span
      )
    )
    case None -> ()
  }
  match decl.whereClause {
    case Some(_) -> diag.add(
      errorDiagnostic(
        "T0178",
        "foreign record '" + decl.name + "' cannot have a where clause",
        decl.span
      )
    )
    case None -> ()
  }
  val ctx = newGenericContext()
  for m in decl.members {
    match m {
      case RMInvariant(_) -> diag.add(
        errorDiagnostic(
          "T0178",
          "foreign record '" + decl.name +
            "' cannot declare an invariant: C code writes its memory without running it",
          decl.span
        )
      )
      case RMFunc(fn) -> diag.add(
        errorDiagnostic(
          "T0178",
          "foreign record '" + decl.name + "' cannot declare a method ('" + fn.name +
            "'): it is a layout, not a behaviour",
          fn.span
        )
      )
      case RMField(fd) -> {
        if fd.isMutable {
          diag.add(
            errorDiagnostic(
              "T0178",
              "field '" + fd.name + "' of foreign record '" + decl.name +
                "' is written `var`: a foreign record is written in place through a `var` binding, so its fields carry no `var`",
              fd.span
            )
          )
        }
        match fd.dflt {
          case Some(_) -> diag.add(
            errorDiagnostic(
              "T0178",
              "field '" + fd.name + "' of foreign record '" + decl.name +
                "' has a default: construct it with every field",
              fd.span
            )
          )
          case None -> ()
        }
        val scratch: List[Diagnostic] = newList()
        val ft = resolveType(tbl, ctx, scratch, fd.ty)
        match foreignFieldViolation(tbl, ft, 0) {
          case None -> ()
          case Some(why) -> diag.add(
            errorDiagnostic(
              "T0179",
              "field '" + fd.name + "' of foreign record '" + decl.name + "' cannot be " + renderType(ft) +
                ": a foreign record holds `Plain` values, `NativePtr[T]`, arrays of those and other foreign records (" +
                why +
                ")",
              fd.span
            )
          )
        }
      }
    }
  }
}

// Whether the place `e` can be written field by field: a `var` local, an
// `inout`/`out` parameter, or a field or element of one.  False for anything else,
// including a place the checker cannot resolve (left to the other rules).
func foreignPlaceWritable(sc: in Scope, tbl: in SymbolTable, sigs: in Map[String, ResolvedSignature], e: in Expr): Bool {
  match e.kind {
    case EParen(inner) -> foreignPlaceWritable(sc, tbl, sigs, inner)
    case EPath(p) -> {
      if p.segments.count != 1 {
        return false
      }
      match scopeTryFind(sc, p.segments[0]) {
        case Some(b) -> b.isMutable
        case None -> false
      }
    }
    case ESelf -> true
    case EMember(recv, _) -> foreignPlaceWritable(sc, tbl, sigs, recv)
    case EIndex(recv, _) -> foreignPlaceWritable(sc, tbl, sigs, recv)
    case _ -> false
  }
}

/// T0180: `d.f = v` (or `d.f.g = v`, `d.arr[i] = v`) on a foreign record writes the
/// record in place, so the root must be a writable place.
pub func checkForeignFieldWrite(
  sc: in Scope,
  tbl: in SymbolTable,
  sigs: in Map[String, ResolvedSignature],
  diag: in List[Diagnostic],
  target: in Expr,
): Unit {
  match target.kind {
    case EParen(inner) -> checkForeignFieldWrite(sc, tbl, sigs, diag, inner)
    case EMember(recv, name) -> {
      val scratch: List[Diagnostic] = newList()
      val rt = inferExpr(sc, tbl, sigs, scratch, recv)
      if isForeignRecordType(tbl, rt) and not foreignPlaceWritable(sc, tbl, sigs, recv) {
        diag.add(
          errorDiagnostic(
            "T0180",
            "cannot write field '" + name + "' of " + renderType(rt) +
              " here: a foreign record is written in place, through a `var` local or an `inout` parameter",
            target.span
          )
        )
      }
    }
    case EIndex(recv, _) -> checkForeignFieldWrite(sc, tbl, sigs, diag, recv)
    case _ -> ()
  }
}
