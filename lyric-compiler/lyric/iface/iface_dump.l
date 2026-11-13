//! iface_dump.l - the text form of a package interface, printed by
//! `lyric interface dump` (docs/70 §9.6).
//!
//! The dump is total over the model: two interfaces with the same dump are the
//! same interface, which is what the producer's round-trip check (I0005)
//! compares.  It lists the canonical form, so it does not depend on the order
//! a producer collected declarations in.
package Lyric.Iface

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Math as Math
import Lyric.Symbols
import Lyric.Tir

func joinList(xs: in List[String], sep: in String): String {
  var buf = ""
  var i = 0
  while i < xs.count {
    if i > 0 {
      buf = buf + sep
    }
    buf = buf + xs[i]
    i = i + 1
  }
  buf
}

func symText(it: in DefPathInterner, s: in SymbolId): String {
  if isBuiltinSymbol(s) {
    "builtin#" + toString(0 - s.id)
  } else {
    match defPathKeyOf(it, s) {
      case Some(k) -> k
      case None -> "?" + toString(s.id)
    }
  }
}

func tysText(it: in DefPathInterner, xs: in List[Ty]): String {
  val parts: List[String] = newList()
  for x in xs {
    parts.add(tyText(it, x))
  }
  joinList(parts, ", ")
}

func optLongText(v: in Option[Long]): String {
  match v {
    case None -> "_"
    case Some(n) -> toString(n)
  }
}

/// `t` as text, naming declarations by their DefPath key.
pub func tyText(it: in DefPathInterner, t: in Ty): String {
  match t {
    case TPrim(k) -> primKindName(k)
    case TTuple(xs) -> "(" + tysText(it, xs) + ")"
    case TNullable(inner) -> tyText(it, inner) + "?"
    case TFunc(ps, ret, isAsync) -> {
      val parts: List[String] = newList()
      for p in ps {
        parts.add(modeName(p.mode) + " " + tyText(it, p.ty))
      };
      (if isAsync then "async " else "") + "(" + joinList(parts, ", ") + ") -> " + tyText(it, ret)
    }
    case TArray(len, elem) -> {
      val l = match len {
        case ALKnown(n) -> toString(n)
        case ALParam(owner, index) -> symText(it, owner) + "#" + toString(index)
        case ALUnsized -> "_"
      }
      "array[" + l + ", " + tyText(it, elem) + "]"
    }
    case TSlice(elem) -> "slice[" + tyText(it, elem) + "]"
    case TNamed(sym, args) -> if args.count == 0 {
      symText(it, sym)
    } else {
      symText(it, sym) + "[" + tysText(it, args) + "]"
    }
    case TParam(owner, index) -> "param " + symText(it, owner) + "#" + toString(index)
    case TRefined(u, lo, hi, inc) -> tyText(it, u) + " range " + optLongText(lo) + (if inc then " ..= " else " ..< ") +
      optLongText(hi)
    case TLen(n) -> "len " + toString(n)
    case TNever -> "Never"
    case TException -> "Exception"
    case TExtern(h) -> "extern " + h.name + (if h.args.count == 0 then "" else "[" + tysText(it, h.args) + "]")
  }
}

func litText(l: in TLit): String {
  match l {
    case TLInt(v) -> toString(v)
    case TLFloat(v) -> "bits:" + toString(Math.doubleToBits(v))
    case TLChar(cp) -> "char:" + toString(cp)
    case TLString(s) -> "\"" + s + "\""
    case TLBool(b) -> if b then "true" else "false"
    case TLUnit -> "()"
  }
}

func exprsText(it: in DefPathInterner, xs: in List[TExpr]): String {
  val parts: List[String] = newList()
  for x in xs {
    parts.add(exprText(it, x))
  }
  joinList(parts, ", ")
}

func argsText(it: in DefPathInterner, args: in List[TArg]): String {
  val parts: List[String] = newList()
  for a in args {
    match a {
      case TArgIn(v) -> parts.add(exprText(it, v))
      case TArgOut(_) -> parts.add("<out>")
      case TArgInout(_) -> parts.add("<inout>")
    }
  }
  joinList(parts, ", ")
}

func convText(it: in DefPathInterner, k: in ConvKind): String {
  match k {
    case CvWiden(to) -> "widen " + primKindName(to)
    case CvWrapDistinct(s) -> "wrap " + symText(it, s)
    case CvUnwrapDistinct(s) -> "unwrap " + symText(it, s)
    case CvRangeCheck -> "rangecheck"
    case CvUnrefine -> "unrefine"
    case CvUpcast(s) -> "upcast " + symText(it, s)
    case CvBoxToHost(h) -> "box " + tyText(it, TExtern(host = h))
    case CvFromHost -> "fromhost"
    case CvToSlice -> "toslice"
    case CvToList -> "tolist"
    case CvLiftNullable -> "lift"
    case CvFromNever -> "fromnever"
  }
}

func intrinsicText(op: in IntrinsicOp): String {
  match op {
    case IoBuiltin(name) -> "builtin " + name
    case IoTryFrom -> "tryFrom"
    case _ -> "op" + toString(intrinsicCode(op))
  }
}

func memberText(it: in DefPathInterner, m: in HostMemberRef): String {
  val ps: List[String] = newList()
  for p in m.params {
    ps.add(modeName(p.mode) + " " + tyText(it, p.ty))
  }
  tyText(it, TExtern(host = m.owner)) + "." + m.name + "#" + toString(hostKindCode(m.kind)) +
    (if m.isStatic then " static" else "") +
    "(" +
    joinList(ps, ", ") +
    "): " +
    tyText(it, m.ret)
}

/// A default expression as text: every field the codec records, with its type.
pub func exprText(it: in DefPathInterner, e: in TExpr): String {
  val body = match e.kind {
    case XLit(l) -> litText(l)
    case XGlobal(s, targs) -> "global " + symText(it, s) + "[" + tysText(it, targs) + "]"
    case XCall(callee, args) -> {
      val c = match callee {
        case Direct(s, targs) -> "call " + symText(it, s) + "[" + tysText(it, targs) + "]"
        case Extern(m) -> "extern " + memberText(it, m)
        case Intrinsic(op) -> "intrinsic " + intrinsicText(op)
        case _ -> "callee?"
      }
      c + "(" + argsText(it, args) + ")"
    }
    case XConstruct(s, fields) -> "new " + symText(it, s) + "(" + exprsText(it, fields) + ")"
    case XConvert(k, inner) -> "convert " + convText(it, k) + " (" + exprText(it, inner) + ")"
    case XListLit(elems) -> "list [" + exprsText(it, elems) + "]"
    case XTuple(elems) -> "tuple (" + exprsText(it, elems) + ")"
    case _ -> "expr?"
  }
  "{" + body + " : " + tyText(it, e.ty) + "}"
}

func defaultText(it: in DefPathInterner, hasDefault: in Bool, dflt: in Option[TExpr]): String {
  if not hasDefault {
    return ""
  }
  match dflt {
    case Some(d) -> " = " + exprText(it, d)
    case None -> " = <default>"
  }
}

func typeParamsText(it: in DefPathInterner, ps: in List[TTypeParam]): String {
  if ps.count == 0 {
    return ""
  }
  val parts: List[String] = newList()
  for p in ps {
    var t = p.name
    match p.valueTy {
      case Some(vt) -> {
        t = t + ": value " + tyText(it, vt)
      }
      case None -> {
        if p.bounds.count > 0 {
          val bs: List[String] = newList()
          for b in p.bounds {
            bs.add(tyText(it, b))
          }
          t = t + ": " + joinList(bs, " + ")
        }
      }
    }
    parts.add(t)
  }
  "[" + joinList(parts, ", ") + "]"
}

func fieldsText(it: in DefPathInterner, fs: in List[IfField]): String {
  val parts: List[String] = newList()
  for f in fs {
    parts.add(
      (if f.mutable then "var " else "") + f.name + ": " + tyText(it, f.ty) +
        (if f.hasDefault then " = <default>" else "")
    )
  }
  "(" + joinList(parts, ", ") + ")"
}

func detailText(it: in DefPathInterner, d: in IfDetail): String {
  match d {
    case IfDNone -> ""
    case IfDFunc(tps, ps, ret, isAsync, isAxiom, isPure) -> {
      val parts: List[String] = newList()
      for p in ps {
        parts.add(p.name + ": " + modeName(p.mode) + " " + tyText(it, p.ty) + defaultText(it, p.hasDefault, p.dflt))
      }
      var flags = ""
      if isAsync {
        flags = flags + " async"
      }
      if isAxiom {
        flags = flags + " @axiom"
      }
      if isPure {
        flags = flags + " @pure"
      }
      typeParamsText(it, tps) + "(" + joinList(parts, ", ") + "): " + tyText(it, ret) + flags
    }
    case IfDRecord(tps, fs) -> typeParamsText(it, tps) + fieldsText(it, fs)
    case IfDType(tps) -> typeParamsText(it, tps)
    case IfDAlias(tps, underlying) -> typeParamsText(it, tps) + " = " + tyText(it, underlying)
    case IfDCase(fs) -> fieldsText(it, fs)
    case IfDValue(ty, mutable, value) -> {
      val v = match value { case None -> ""; case Some(l) -> " = " + litText(l) };
      (if mutable then " var" else "") + ": " + tyText(it, ty) + v
    }
    case IfDExtern(tps, host) -> typeParamsText(it, tps) + " = " + host
  }
}

/// The text of `i`, one line per fact, in canonical order.  `it` names the
/// declarations the types refer to.
pub func dumpIface(i: in Iface, it: in DefPathInterner): String {
  val c = canonicalIface(i)
  val lines: List[String] = newList()
  lines.add("interface " + c.header.pkg + " (format " + toString(c.header.formatVersion) + ")")
  lines.add("verification: " + ifVerifName(c.header.verification))
  lines.add("targets: " + joinList(c.header.targets, ", "))
  lines.add("annotations: " + joinList(c.header.consumerAnnotations, ", "))
  lines.add("reexports: " + joinList(c.reexports, ", "))
  lines.add("built against (" + toString(c.header.builtAgainst.count) + "):")
  for b in c.header.builtAgainst {
    lines.add("  " + b.pkg + " " + b.version + " " + b.hash)
  }
  lines.add("declarations (" + toString(c.decls.count) + "):")
  for d in c.decls {
    lines.add("  " + ifVisName(d.vis) + " " + ifKindName(d.kind) + " " + defPathKey(d.path) + detailText(it, d.detail))
  }
  joinList(lines, "\n") + "\n"
}
