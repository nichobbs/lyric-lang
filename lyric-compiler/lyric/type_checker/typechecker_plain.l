//! typechecker_plain.l — the `Plain` structural marker (D155, docs/67 §4.5).
//!
//! A type is `Plain` when its bit pattern is its whole meaning: the numeric
//! and `Bool`/`Char` scalars, enums, a distinct type over a `Plain` type with
//! no range constraint, a record with no `var` field and no `invariant:`
//! whose fields are all `Plain`, and an `array[N, T]` of a `Plain` element.
//! The marker is computed here from the type's structure, never declared:
//! it is valid in `where` clauses only (never `derives`), and
//! `plainViolation` says which part of a type defeats it so a T0108 can
//! explain itself.
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

pub func isPlainMarker(name: in String): Bool = name == "Plain"

/// `None` when `t` is `Plain`; otherwise why it is not.
pub func plainViolation(tbl: in SymbolTable, t: in Type): Option[String] = plainViolationAt(tbl, t, 0)

pub func isPlainType(tbl: in SymbolTable, t: in Type): Bool {
  match plainViolation(tbl, t) {
    case None -> true
    case Some(_) -> false
  }
}

func plainPrimViolation(pt: in PrimType): Option[String] {
  match pt {
    case PtBool -> None
    case PtByte -> None
    case PtInt -> None
    case PtLong -> None
    case PtUInt -> None
    case PtULong -> None
    case PtFloat -> None
    case PtDouble -> None
    case PtChar -> None
    case PtNat -> Some(value = "'Nat' is a compile-time length, not a runtime value")
    case PtString -> Some(value = "'String' is a reference, so its bytes are not its meaning")
    case PtUnit -> Some(value = "'Unit' has no bit pattern")
    case PtNever -> Some(value = "'Never' has no values")
  }
}

func plainViolationAt(tbl: in SymbolTable, t: in Type, depth: in Int): Option[String] {
  if depth > 16 {
    return Some(value = "the type nests too deeply to check")
  }
  match t {
    case TyPrim(pt) -> plainPrimViolation(pt)
    case TyRefined(_, _, _, _, _) -> Some(
      value = "a range subtype is not 'Plain': foreign code writes buffer memory without running range checks, so convert at the boundary with tryFrom"
    )
    case TyArray(_, el, _) -> match plainViolationAt(tbl, el, depth + 1) {
      case None -> None
      case Some(why) -> Some(value = "its array element is not 'Plain': " + why)
    }
    case TyTuple(_) -> Some(value = "a tuple has no declared layout")
    case TyNullable(_) -> Some(value = "a nullable type carries a presence flag, not just a bit pattern")
    case TyFunction(_, _, _) -> Some(value = "a function is a reference")
    case TySlice(_) -> Some(value = "a slice is a reference to storage")
    case TyUser(tid, name, args) -> plainUserViolation(tbl, t, tid, name, args, depth)
    case TyVar(_) -> Some(value = "an unresolved type parameter cannot be proved 'Plain'")
    case _ -> Some(value = "this type is not a scalar, enum, record or array")
  }
}

func plainUserViolation(
  tbl: in SymbolTable,
  t: in Type,
  tid: in SymbolId,
  name: in String,
  args: in List[Type],
  depth: in Int,
): Option[String] {
  match symTableTypeSymbolOf(tbl, tid) {
    case None -> Some(value = "'" + name + "' is not a declared type")
    case Some(sym) -> match sym.kind {
      case DKEnum(_, _) -> None
      case DKRecord(_, rd) -> plainRecordViolation(tbl, tid, rd, name, args, depth)
      case DKDistinctType(_, dt) -> {
        match dt.rangeClause {
          case Some(_) -> return Some(
            value = "'" + name +
              "' is a range subtype, which is not 'Plain': foreign code writes buffer memory without running range checks, so convert at the boundary with tryFrom"
          )
          case None -> ()
        }
        val scratch: List[Diagnostic] = newList()
        match distinctMemberType(tbl, scratch, t, "value", dt.span) {
          case None -> Some(value = "'" + name + "' has no resolvable underlying type")
          case Some(under) -> match plainViolationAt(tbl, under, depth + 1) {
            case None -> None
            case Some(why) -> Some(value = "the underlying type of '" + name + "' is not 'Plain': " + why)
          }
        }
      }
      case DKOpaque(_, _) -> Some(
        value = "'" + name +
          "' is an opaque type, and viewing it as bytes would expose its representation"
      )
      case DKExposedRec(_, _) -> Some(
        value = "'" + name +
          "' is an exposed record, which is not laid out as a value"
      )
      case DKUnion(_, _) -> Some(value = "'" + name + "' is a union, which has no fixed bit layout")
      case DKProtected(_, _) -> Some(value = "'" + name + "' is a protected type, which owns a lock")
      case DKInterface(_, _) -> Some(value = "'" + name + "' is an interface, which is a reference")
      case _ -> Some(value = "'" + name + "' is not a scalar, enum, record or array")
    }
  }
}

func plainRecordViolation(
  tbl: in SymbolTable,
  tid: in SymbolId,
  rd: in RecordDecl,
  name: in String,
  args: in List[Type],
  depth: in Int,
): Option[String] {
  if rd.isForeign {
    // A foreign record's fields are checked as a layout (`checkForeignRecordDecl`):
    // pointers are allowed, and it is a plain value, so it is `Plain` itself.
    for f in fieldsOfRecordInstantiated(tbl, tid, args) {
      match foreignFieldViolation(tbl, f.ty, depth + 1) {
        case None -> ()
        case Some(why) -> return Some(value = "field '" + f.name + "' of '" + name + "' is not allowed in a foreign record: " + why)
      }
    }
    return None
  }
  for m in rd.members {
    match m {
      case RMInvariant(_) -> return Some(
        value = "'" + name +
          "' declares an invariant, and foreign code writes buffer memory without running it, so convert at the boundary with tryFrom"
      )
      case RMField(fd) -> if fd.isMutable {
        return Some(
          value = "'" + name + "' has a 'var' field (field '" + fd.name +
            "'), so it has identity rather than being a value"
        )
      }
      case _ -> ()
    }
  }
  for f in fieldsOfRecordInstantiated(tbl, tid, args) {
    match plainViolationAt(tbl, f.ty, depth + 1) {
      case None -> ()
      case Some(why) -> return Some(value = "field '" + f.name + "' of '" + name + "' is not 'Plain': " + why)
    }
  }
  None
}
