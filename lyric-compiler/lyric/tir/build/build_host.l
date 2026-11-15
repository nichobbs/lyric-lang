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

/// The name the host's array, pointer and by-reference types share in a member signature.
pub func hostArrayName(): String {
  "an array, pointer or by-reference type"
}

func isHostObject(name: in String): Bool {
  name == "System.Object" or name == "java.lang.Object"
}

/// The host's own classes for strings, boxed numbers and characters: a value of the language, never a
/// functional interface or a delegate, so a function value fits none of them.
func isHostValueClass(name: in String): Bool {
  name == "System.String" or name == "java.lang.String" or name == "java.lang.CharSequence" or
    name == "java.lang.Number" or
    name == "java.lang.Boolean" or
    name == "java.lang.Character" or
    name == "java.lang.Byte" or
    name == "java.lang.Short" or
    name == "java.lang.Integer" or
    name == "java.lang.Long" or
    name == "java.lang.Float" or
    name == "java.lang.Double" or
    name == "System.Boolean" or
    name == "System.Char" or
    name == "System.Byte" or
    name == "System.Int16" or
    name == "System.Int32" or
    name == "System.Int64" or
    name == "System.Single" or
    name == "System.Double"
}

/// The host integer types with no Lyric type: an `Int` or `Long` argument narrows to one, range checked.
func isNarrowHostInt(name: in String): Bool {
  name == "System.SByte" or name == "System.Int16" or name == "System.UInt16" or name == "System.UInt32" or
    name == "System.UInt64"
}

/// An element type whose array is the host's own array: bytes and host (extern) values.
func isHostArrayElement(el: in Ty): Bool {
  match el {
    case TPrim(TPByte) -> true
    case TExtern(_) -> true
    case _ -> false
  }
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
        // A value with no runtime representation (`Unit`, `Never`) is not boxed.
        val boxable = match from { case TNever -> false; case TPrim(TPUnit) -> false; case _ -> true }
        return if boxable { Some(value = CvBoxToHost(host = h)) } else { None }
      }
      // A slice or `array[N, T]` of bytes or of host values passed for a host array: the elements keep the host's
      // representation (the signature keeps no element type, so any other element is not claimed).
      if h.name == hostArrayName() {
        return match from {
          case TSlice(el) -> if isHostArrayElement(el) { Some(value = CvBoxToHost(host = h)) } else { None }
          case TArray(_, el) -> if isHostArrayElement(el) { Some(value = CvBoxToHost(host = h)) } else { None }
          case _ -> None
        }
      }
      match from {
        // A function value passed for a host functional interface or delegate (`Thread.new({ -> ... })`):
        // the host adapts it; the operand keeps its function type.
        case TFunc(_, _, _) -> if isHostValueClass(h.name) { None } else { Some(value = CvBoxToHost(host = h)) }
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
