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
