//! iface_expr.l - the codec and text form of the expressions a parameter's default is made of
//! (docs/70 §9.2).
//!
//! A default is a typed `TExpr` built from the declaring package's own checker tables, so a consumer
//! places it at a call without the callee's tables.  The kinds are the ones a default occurs as
//! (D581): literals, global names, calls by value of a declared function, a host member or an
//! intrinsic, constructions, conversions, list literals and tuples.  Node ids and spans are not
//! recorded: the consumer numbers the copy it places at each call afresh, and a decoded node has id 0
//! and no source span.  `defaultCarriable` says whether a producer can record an expression.
package Lyric.Iface

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Symbols
import Lyric.Tir

// ── What can be carried ──────────────────────────────────────────────────────
func exprsCarriable(xs: in List[TExpr]): Bool {
  for x in xs {
    if not defaultCarriable(x) {
      return false
    }
  }
  true
}

func argsCarriable(args: in List[TArg]): Bool {
  for a in args {
    match a {
      case TArgIn(v) -> if not defaultCarriable(v) { return false }
      case _ -> return false
    }
  }
  true
}

/// Whether `e` is made only of the kinds the codec records.
pub func defaultCarriable(e: in TExpr): Bool {
  match e.kind {
    case XLit(_) -> true
    case XGlobal(_, _) -> true
    case XCall(callee, args) -> {
      val calleeOk = match callee {
        case Direct(_, _) -> true
        case Extern(_) -> true
        case Intrinsic(_) -> true
        case _ -> false
      }
      calleeOk and argsCarriable(args)
    }
    case XConstruct(_, fields) -> exprsCarriable(fields)
    case XConvert(_, inner) -> defaultCarriable(inner)
    case XListLit(elems) -> exprsCarriable(elems)
    case XTuple(elems) -> exprsCarriable(elems)
    case _ -> false
  }
}

// ── Pieces ───────────────────────────────────────────────────────────────────
func putTyList(w: in IfaceWriter, it: in DefPathInterner, xs: in List[Ty]) {
  putU(w, xs.count)
  for x in xs {
    putTy(w, it, x)
  }
}

func readTyList(r: in IfaceReader, it: in DefPathInterner): List[Ty] {
  val n = readCount(r)
  val res: List[Ty] = newList()
  var k = 0
  while k < n and not r.failed {
    res.add(readTy(r, it))
    k = k + 1
  }
  res
}

func putHost(w: in IfaceWriter, it: in DefPathInterner, h: in HostTypeRef) {
  putStr(w, h.name)
  putTyList(w, it, h.args)
}

func readHost(r: in IfaceReader, it: in DefPathInterner): HostTypeRef {
  val name = readStr(r)
  HostTypeRef(name = name, args = readTyList(r, it))
}

func hostKindCode(k: in HostMemberKind): Int {
  match k {
    case HMMethod -> 0
    case HMConstructor -> 1
    case HMPropertyGet -> 2
    case HMPropertySet -> 3
    case HMFieldGet -> 4
    case HMFieldSet -> 5
    case HMIndexerGet -> 6
    case HMIndexerSet -> 7
  }
}

func hostKindOfCode(c: in Int): Option[HostMemberKind] {
  match c {
    case 0 -> Some(value = HMMethod)
    case 1 -> Some(value = HMConstructor)
    case 2 -> Some(value = HMPropertyGet)
    case 3 -> Some(value = HMPropertySet)
    case 4 -> Some(value = HMFieldGet)
    case 5 -> Some(value = HMFieldSet)
    case 6 -> Some(value = HMIndexerGet)
    case 7 -> Some(value = HMIndexerSet)
    case _ -> None
  }
}

func putMember(w: in IfaceWriter, it: in DefPathInterner, m: in HostMemberRef) {
  putHost(w, it, m.owner)
  putStr(w, m.name)
  putU(w, hostKindCode(m.kind))
  putBool(w, m.isStatic)
  putU(w, m.params.count)
  for p in m.params {
    putU(w, modeCode(p.mode))
    putTy(w, it, p.ty)
  }
  putTy(w, it, m.ret)
}

func readMember(r: in IfaceReader, it: in DefPathInterner): HostMemberRef {
  val owner = readHost(r, it)
  val name = readStr(r)
  val kc = readU(r)
  val isStatic = readBool(r)
  val n = readCount(r)
  val ps: List[TParamTy] = newList()
  var k = 0
  while k < n and not r.failed {
    val mc = readU(r)
    val ty = readTy(r, it)
    match modeOfCode(mc) {
      case Some(m) -> ps.add(TParamTy(mode = m, ty = ty))
      case None -> readFail(r, "unknown parameter mode " + toString(mc))
    }
    k = k + 1
  }
  val ret = readTy(r, it)
  val kind = match hostKindOfCode(kc) {
    case Some(x) -> x
    case None -> {
      readFail(r, "unknown host member kind " + toString(kc))
      HMMethod
    }
  }
  HostMemberRef(owner = owner, name = name, kind = kind, isStatic = isStatic, params = ps, ret = ret)
}

func intrinsicCode(op: in IntrinsicOp): Int {
  match op {
    case IoAdd -> 0
    case IoSub -> 1
    case IoMul -> 2
    case IoDiv -> 3
    case IoMod -> 4
    case IoNeg -> 5
    case IoNot -> 6
    case IoBitAnd -> 7
    case IoBitOr -> 8
    case IoBitXor -> 9
    case IoEq -> 10
    case IoNeq -> 11
    case IoLt -> 12
    case IoLte -> 13
    case IoGt -> 14
    case IoGte -> 15
    case IoBuiltin(_) -> 16
    case IoTryFrom -> 17
  }
}

func intrinsicOfCode(c: in Int): Option[IntrinsicOp] {
  match c {
    case 0 -> Some(value = IoAdd)
    case 1 -> Some(value = IoSub)
    case 2 -> Some(value = IoMul)
    case 3 -> Some(value = IoDiv)
    case 4 -> Some(value = IoMod)
    case 5 -> Some(value = IoNeg)
    case 6 -> Some(value = IoNot)
    case 7 -> Some(value = IoBitAnd)
    case 8 -> Some(value = IoBitOr)
    case 9 -> Some(value = IoBitXor)
    case 10 -> Some(value = IoEq)
    case 11 -> Some(value = IoNeq)
    case 12 -> Some(value = IoLt)
    case 13 -> Some(value = IoLte)
    case 14 -> Some(value = IoGt)
    case 15 -> Some(value = IoGte)
    case 17 -> Some(value = IoTryFrom)
    case _ -> None
  }
}

func putConv(w: in IfaceWriter, it: in DefPathInterner, k: in ConvKind) {
  match k {
    case CvWiden(to) -> {
      putU(w, 0)
      putU(w, primCode(to))
    }
    case CvWrapDistinct(s) -> {
      putU(w, 1)
      putSym(w, it, s)
    }
    case CvUnwrapDistinct(s) -> {
      putU(w, 2)
      putSym(w, it, s)
    }
    case CvRangeCheck -> putU(w, 3)
    case CvUnrefine -> putU(w, 4)
    case CvUpcast(s) -> {
      putU(w, 5)
      putSym(w, it, s)
    }
    case CvBoxToHost(h) -> {
      putU(w, 6)
      putHost(w, it, h)
    }
    case CvFromHost -> putU(w, 7)
    case CvToSlice -> putU(w, 8)
    case CvToList -> putU(w, 9)
    case CvLiftNullable -> putU(w, 10)
    case CvFromNever -> putU(w, 11)
  }
}

func readConv(r: in IfaceReader, it: in DefPathInterner): ConvKind {
  val tag = readU(r)
  match tag {
    case 0 -> {
      val pc = readU(r)
      match primOfCode(pc) {
        case Some(p) -> CvWiden(to = p)
        case None -> {
          readFail(r, "unknown primitive " + toString(pc))
          CvRangeCheck
        }
      }
    }
    case 1 -> CvWrapDistinct(sym = readSym(r, it))
    case 2 -> CvUnwrapDistinct(sym = readSym(r, it))
    case 3 -> CvRangeCheck
    case 4 -> CvUnrefine
    case 5 -> CvUpcast(iface = readSym(r, it))
    case 6 -> CvBoxToHost(host = readHost(r, it))
    case 7 -> CvFromHost
    case 8 -> CvToSlice
    case 9 -> CvToList
    case 10 -> CvLiftNullable
    case 11 -> CvFromNever
    case _ -> {
      readFail(r, "unknown conversion tag " + toString(tag))
      CvRangeCheck
    }
  }
}

// ── Expressions ──────────────────────────────────────────────────────────────
func putExprs(w: in IfaceWriter, it: in DefPathInterner, xs: in List[TExpr]) {
  putU(w, xs.count)
  for x in xs {
    putExpr(w, it, x)
  }
}

/// Writes `e`, which `defaultCarriable` accepts; any other kind fails the write.
pub func putExpr(w: in IfaceWriter, it: in DefPathInterner, e: in TExpr) {
  putTy(w, it, e.ty)
  match e.kind {
    case XLit(l) -> {
      putU(w, 0)
      putLit(w, l)
    }
    case XGlobal(s, targs) -> {
      putU(w, 1)
      putSym(w, it, s)
      putTyList(w, it, targs)
    }
    case XCall(callee, args) -> {
      putU(w, 2)
      match callee {
        case Direct(s, targs) -> {
          putU(w, 0)
          putSym(w, it, s)
          putTyList(w, it, targs)
        }
        case Extern(m) -> {
          putU(w, 1)
          putMember(w, it, m)
        }
        case Intrinsic(op) -> {
          putU(w, 2)
          putU(w, intrinsicCode(op))
          match op {
            case IoBuiltin(name) -> putStr(w, name)
            case _ -> ()
          }
        }
        case _ -> {
          writeFail(w, "a default calls through a callee the interface cannot record")
          putU(w, 0)
          putU(w, 0)
          putU(w, 0)
        }
      }
      putU(w, args.count)
      for a in args {
        match a {
          case TArgIn(v) -> putExpr(w, it, v)
          case _ -> writeFail(w, "a default passes an out or inout argument")
        }
      }
    }
    case XConstruct(s, fields) -> {
      putU(w, 3)
      putSym(w, it, s)
      putExprs(w, it, fields)
    }
    case XConvert(k, inner) -> {
      putU(w, 4)
      putConv(w, it, k)
      putExpr(w, it, inner)
    }
    case XListLit(elems) -> {
      putU(w, 5)
      putExprs(w, it, elems)
    }
    case XTuple(elems) -> {
      putU(w, 6)
      putExprs(w, it, elems)
    }
    case _ -> {
      writeFail(w, "a default is an expression of a kind the interface cannot record")
      putU(w, 0)
      putLit(w, TLUnit)
    }
  }
}

func readExprs(r: in IfaceReader, it: in DefPathInterner): List[TExpr] {
  val n = readCount(r)
  val res: List[TExpr] = newList()
  var k = 0
  while k < n and not r.failed {
    res.add(readExpr(r, it))
    k = k + 1
  }
  res
}

func unitExpr(): TExpr {
  TExpr(id = NodeId(id = 0), ty = TNever, span = noSourceSpan(), kind = XLit(lit = TLUnit))
}

/// Reads an expression.  A malformed file yields a unit literal and sets the reader's failure.
pub func readExpr(r: in IfaceReader, it: in DefPathInterner): TExpr {
  if not readEnter(r) {
    return unitExpr()
  }
  val e = readExprBody(r, it)
  readLeave(r)
  e
}

func mkNode(ty: in Ty, kind: in TExprKind): TExpr {
  TExpr(id = NodeId(id = 0), ty = ty, span = noSourceSpan(), kind = kind)
}

func readExprBody(r: in IfaceReader, it: in DefPathInterner): TExpr {
  val ty = readTy(r, it)
  val tag = readU(r)
  if r.failed {
    return unitExpr()
  }
  match tag {
    case 0 -> mkNode(ty, XLit(lit = readLit(r)))
    case 1 -> {
      val s = readSym(r, it)
      mkNode(ty, XGlobal(sym = s, typeArgs = readTyList(r, it)))
    }
    case 2 -> {
      val ct = readU(r)
      var callee: Callee = Intrinsic(op = IoAdd)
      if ct == 0 {
        val s = readSym(r, it)
        callee = Direct(sym = s, typeArgs = readTyList(r, it))
      } else if ct == 1 {
        callee = Extern(member = readMember(r, it))
      } else if ct == 2 {
        val oc = readU(r)
        if oc == 16 {
          callee = Intrinsic(op = IoBuiltin(name = readStr(r)))
        } else {
          match intrinsicOfCode(oc) {
            case Some(op) -> {
              callee = Intrinsic(op = op)
            }
            case None -> readFail(r, "unknown intrinsic " + toString(oc))
          }
        }
      } else {
        readFail(r, "unknown callee tag " + toString(ct))
      }
      val n = readCount(r)
      val args: List[TArg] = newList()
      var k = 0
      while k < n and not r.failed {
        args.add(TArgIn(value = readExpr(r, it)))
        k = k + 1
      }
      mkNode(ty, XCall(callee = callee, args = args))
    }
    case 3 -> {
      val s = readSym(r, it)
      mkNode(ty, XConstruct(sym = s, fields = readExprs(r, it)))
    }
    case 4 -> {
      val k = readConv(r, it)
      mkNode(ty, XConvert(kind = k, inner = readExpr(r, it)))
    }
    case 5 -> mkNode(ty, XListLit(elems = readExprs(r, it)))
    case 6 -> mkNode(ty, XTuple(elems = readExprs(r, it)))
    case _ -> {
      readFail(r, "unknown expression tag " + toString(tag))
      unitExpr()
    }
  }
}

/// The default of parameter `name` of the function declared at the DefPath key `fnKey` in `i`: what a
/// consumer of a built or restored interface places at a call that leaves the argument out.  `None` when
/// the function has no such parameter, the parameter declares no default, or the producer could not record
/// it (the declaration's `hasDefault` still says the argument may be omitted).
pub func paramDefaultOf(i: in Iface, fnKey: in String, name: in String): Option[TExpr] {
  for d in i.decls {
    if defPathKey(d.path) == fnKey {
      match d.detail {
        case IfDFunc(_, ps, _, _, _, _) -> {
          for p in ps {
            if p.name == name {
              return p.dflt
            }
          }
        }
        case _ -> ()
      }
    }
  }
  None
}

// ── Declarations a default names (D482) ──────────────────────────────────────
func entryKindCode(k: in TSymKind): Int {
  match k {
    case TSkFunc -> 0
    case TSkType -> 1
    case TSkCase -> 2
    case TSkVal -> 3
    case TSkConst -> 4
    case TSkInterfaceMethod -> 5
    case TSkEntry -> 6
  }
}

func entryKindOf(c: in Int): TSymKind {
  match c {
    case 1 -> TSkType
    case 2 -> TSkCase
    case 3 -> TSkVal
    case 4 -> TSkConst
    case 5 -> TSkInterfaceMethod
    case 6 -> TSkEntry
    case _ -> TSkFunc
  }
}

func entryModeCode(m: in TMode): Int {
  match m {
    case TMIn -> 0
    case TMOut -> 1
    case TMInout -> 2
  }
}

func putEntry(w: in IfaceWriter, it: in DefPathInterner, e: in TSymEntry) {
  putSym(w, it, e.sym)
  putU(w, entryKindCode(e.kind))
  putU(w, e.typeParamCount)
  match e.sig {
    case Some(s) -> {
      putBool(w, true)
      putU(w, s.typeParamCount)
      putU(w, s.params.count)
      for p in s.params {
        putU(w, entryModeCode(p.mode))
        putTy(w, it, p.ty)
      }
      putTy(w, it, s.ret)
      putBool(w, s.isAsync)
    }
    case None -> putBool(w, false)
  }
  putU(w, e.fields.count)
  for f in e.fields {
    putStr(w, f.name)
    putTy(w, it, f.ty)
    putBool(w, f.mutable)
  }
  match e.ty {
    case Some(t) -> {
      putBool(w, true)
      putTy(w, it, t)
    }
    case None -> putBool(w, false)
  }
  putBool(w, e.mutable)
}

func readEntry(r: in IfaceReader, it: in DefPathInterner): TSymEntry {
  val sym = readSym(r, it)
  val kind = entryKindOf(readU(r))
  val tpc = readU(r)
  var sig: Option[TSig] = None
  if readBool(r) {
    val stpc = readU(r)
    val n = readCount(r)
    val ps: List[TParamTy] = newList()
    var i = 0
    while i < n and not r.failed {
      val mc = readU(r)
      val m = if mc == 1 { TMOut } else if mc == 2 { TMInout } else { TMIn }
      ps.add(TParamTy(mode = m, ty = readTy(r, it)))
      i = i + 1
    }
    val ret = readTy(r, it)
    sig = Some(value = TSig(typeParamCount = stpc, params = ps, ret = ret, isAsync = readBool(r)))
  }
  val nf = readCount(r)
  val fs: List[TFieldSig] = newList()
  var j = 0
  while j < nf and not r.failed {
    val nm = readStr(r)
    val fty = readTy(r, it)
    fs.add(TFieldSig(name = nm, ty = fty, mutable = readBool(r)))
    j = j + 1
  }
  var ty: Option[Ty] = None
  if readBool(r) {
    ty = Some(value = readTy(r, it))
  }
  TSymEntry(sym = sym, kind = kind, typeParamCount = tpc, sig = sig, fields = fs, ty = ty, mutable = readBool(r))
}

/// The declarations a default names, written after the default.
pub func putEntries(w: in IfaceWriter, it: in DefPathInterner, es: in List[TSymEntry]) {
  putU(w, es.count)
  for e in es {
    putEntry(w, it, e)
  }
}

pub func readEntries(r: in IfaceReader, it: in DefPathInterner): List[TSymEntry] {
  val n = readCount(r)
  val es: List[TSymEntry] = newList()
  var i = 0
  while i < n and not r.failed {
    es.add(readEntry(r, it))
    i = i + 1
  }
  es
}

/// The default of field `name` of the record declared at the DefPath key `recKey` in `i`, with the
/// declarations it names.
pub func fieldDefaultOf(i: in Iface, recKey: in String, name: in String): Option[IfDefault] {
  for d in i.decls {
    if defPathKey(d.path) == recKey {
      match d.detail {
        case IfDRecord(_, fs) -> {
          for f in fs {
            if f.name == name {
              match f.dflt {
                case Some(x) -> return Some(value = IfDefault(expr = x, entries = f.dfltEntries))
                case None -> return None
              }
            }
          }
        }
        case _ -> ()
      }
    }
  }
  None
}

/// `paramDefaultOf` with the declarations the default names.
pub func paramDefaultWithEntries(i: in Iface, fnKey: in String, name: in String): Option[IfDefault] {
  for d in i.decls {
    if defPathKey(d.path) == fnKey {
      match d.detail {
        case IfDFunc(_, ps, _, _, _, _) -> {
          for p in ps {
            if p.name == name {
              match p.dflt {
                case Some(x) -> return Some(value = IfDefault(expr = x, entries = p.dfltEntries))
                case None -> return None
              }
            }
          }
        }
        case _ -> ()
      }
    }
  }
  None
}
