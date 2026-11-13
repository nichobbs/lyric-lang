//! build_host.l - the conversions a host call's arguments take at the boundary (docs/70 §6.2, D600).
//! The host resolves an overload by the CLR's own numeric widening (`Math.Sqrt(4)` takes the `double`
//! overload of an `Int`), which is wider than the language's: any integer type widens to `Float` and
//! `Double`.  The conversion is a `CvWiden` node, so every backend lowers it as it does a language widening.
package Lyric.Tir.Build

import Std.Core
import Std.Collections
import Lyric.Tir

func isIntegerPrim(k: in TPrimKind): Bool {
  match k {
    case TPByte -> true
    case TPInt -> true
    case TPUInt -> true
    case TPLong -> true
    case TPULong -> true
    case _ -> false
  }
}

/// The widening from `from` to `to` at a host call: the language's, or an integer type to a
/// floating point one.
func hostWidenKind(from: in Ty, to: in Ty): Option[ConvKind] {
  match widenKind(from, to) {
    case Some(k) -> return Some(value = k)
    case None -> ()
  }
  match from {
    case TPrim(f) -> match to {
      case TPrim(t) -> {
        val intToFloat = isIntegerPrim(f) and (match t { case TPFloat -> true; case TPDouble -> true; case _ -> false })
        if intToFloat {
          Some(value = CvWiden(to = t))
        } else {
          None
        }
      }
      case _ -> None
    }
    case _ -> None
  }
}

func isHostObject(name: in String): Bool {
  name == "System.Object" or name == "java.lang.Object"
}

/// The host integer types with no Lyric type: an `Int` or `Long` argument narrows to one, range checked.
func isNarrowHostInt(name: in String): Bool {
  name == "System.SByte" or name == "System.Int16" or name == "System.UInt16" or name == "System.UInt32" or
    name == "System.UInt64"
}

/// The conversions a Lyric value takes into a host parameter the language does not widen to: boxing to
/// `object` (any value), narrowing an `Int` or `Long` to a smaller host integer (range checked, as the MSIL
/// resolver scores it), and a `Float` as the host's `Single`.  The operand keeps its Lyric type and the node has
/// the host type.
pub func hostBoxKind(from: in Ty, to: in Ty): Option[ConvKind] {
  match to {
    case TExtern(h) -> {
      if tyEq(from, to) {
        return None
      }
      if isHostObject(h.name) {
        return Some(value = CvBoxToHost(host = h))
      }
      match from {
        case TPrim(f) -> {
          val narrows = isNarrowHostInt(h.name) and (match f { case TPInt -> true; case TPLong -> true; case _ -> false })
          val single = h.name == "System.Single" and (match f { case TPFloat -> true; case _ -> false })
          if narrows or single {
            Some(value = CvBoxToHost(host = h))
          } else {
            None
          }
        }
        case _ -> None
      }
    }
    case _ -> None
  }
}
