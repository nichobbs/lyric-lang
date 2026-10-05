//! byref_receivers.l — methods whose receiver is `self: inout T` (#8179).
//!
//! A method's receiver is passed like any other parameter, so `self: inout
//! T` passes the caller's place by reference: an assignment to `self`, or to
//! one of its fields, lands on that place (docs/01 §5.2).  A backend method
//! takes its receiver as the host `this`, which cannot be rebound, so the
//! middle end lowers such a method to the D037 form it stands for, a function
//! whose first parameter is the receiver, and every call of it to a plain
//! call that passes the receiver as an ordinary `inout` argument:
//!
//!   * before type checking, each record-body method with an `inout`
//!     receiver becomes the dot-named function `func T.m(self: inout T, ...)`
//!     (`hoistByRefReceiverMethods`), its bare field and sibling-method uses
//!     becoming `self.<name>`, as for a value-generic record's methods (D173);
//!   * after type checking, each call the checker resolved to a dot-named
//!     function with an `out`/`inout` parameter, written as a method call
//!     (`p.m(x)`) or through the type (`T.m(p, x)`), becomes a plain call of
//!     the function (`rewriteByRefDotCalls`), so the receiver is the first
//!     argument and is evaluated first and passed as a place (D171);
//!   * after `?`-propagation, the `inout` receiver of each such function is
//!     renamed from the `self` keyword to an ordinary parameter name
//!     (`renameByRefReceivers`), so every backend lowers it as the `inout`
//!     parameter it is, never as a host `this`.
package Lyric.Pipeline

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.TypeChecker
import Lyric.ContractElaborator

/// The name an `inout` receiver parameter is lowered under.
pub func byRefReceiverName(): String = "__lyric_self"

/// True when `fn` takes its receiver by reference: a first parameter named
/// `self` declared `inout`.  An `out` receiver is rejected by the checker
/// (T0165) and is not lowered.
pub func hasByRefReceiver(fn: in FunctionDecl): Bool {
  if fn.params.count == 0 or fn.params[0].name != "self" {
    return false
  }
  match fn.params[0].mode {
    case PMInout -> true
    case _ -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Before type checking: record-body methods with an `inout` receiver become
// dot-named functions.
// ─────────────────────────────────────────────────────────────────────────────
pub func hoistByRefReceiverMethods(file: in SourceFile): SourceFile {
  var changed = false
  val items: List[Item] = newList()
  for it in file.items {
    match it.kind {
      case IRecord(d) -> {
        val hoist = byRefMethodsToHoist(d)
        if hoist.count > 0 {
          changed = true
          items.add(it.copy(kind = IRecord(decl = recordWithoutHoisted(d, hoist))))
          addHoistedByRefMethods(file, d, hoist, it.visibility, items)
        } else {
          items.add(it)
        }
      }
      case IExposedRec(d) -> {
        val hoist = byRefMethodsToHoist(d)
        if hoist.count > 0 {
          changed = true
          items.add(it.copy(kind = IExposedRec(decl = recordWithoutHoisted(d, hoist))))
          addHoistedByRefMethods(file, d, hoist, it.visibility, items)
        } else {
          items.add(it)
        }
      }
      case _ -> items.add(it)
    }
  }
  if changed {
    file.copy(items = items)
  } else {
    file
  }
}

// The `name/arity` keys of the record's methods with an `inout` receiver.  A
// method that shares its name and parameter count with another method stays
// in the record, where the checker reports the pair (T0162).
func byRefMethodsToHoist(d: in RecordDecl): Map[String, Bool] {
  val counts: Map[String, Int] = newMap()
  for m in d.members {
    match m {
      case RMFunc(fn) -> {
        val key = methodKey(fn)
        val n = match mapGet(counts, key) { case Some(c) -> c; case None -> 0 }
        if counts.containsKey(key) {
          counts.remove(key)
        }
        counts.add(key, n + 1)
      }
      case _ -> ()
    }
  }
  val hoist: Map[String, Bool] = newMap()
  for m in d.members {
    match m {
      case RMFunc(fn) -> {
        val key = methodKey(fn)
        val unique = match mapGet(counts, key) { case Some(c) -> c == 1; case None -> false }
        if unique and hasByRefReceiver(fn) and not hoist.containsKey(key) {
          hoist.add(key, true)
        }
      }
      case _ -> ()
    }
  }
  hoist
}

func methodKey(fn: in FunctionDecl): String = fn.name + "/" + toString(fn.params.count)

// The record without its hoisted methods.  A remaining method's bare call of
// a hoisted one (`reset()`) is a call on `self`, written out as `self.reset()`
// so it reaches the function the method became.
func recordWithoutHoisted(d: in RecordDecl, hoist: in Map[String, Bool]): RecordDecl {
  val hoistedNames: Map[String, Bool] = newMap()
  for m in d.members {
    match m {
      case RMFunc(fn) -> if hoist.containsKey(methodKey(fn)) and not hoistedNames.containsKey(fn.name) {
        hoistedNames.add(fn.name, false)
      }
      case _ -> ()
    }
  }
  // A name that is also a remaining method stays a call of that method.
  for m in d.members {
    match m {
      case RMFunc(fn) -> if not hoist.containsKey(methodKey(fn)) and hoistedNames.containsKey(fn.name) {
        hoistedNames.remove(fn.name)
      }
      case _ -> ()
    }
  }
  val selfTy = recordInstanceType(d, d.span)
  val members: List[RecordMember] = newList()
  for m in d.members {
    match m {
      case RMFunc(fn) -> if not hoist.containsKey(methodKey(fn)) {
        if hoistedNames.count == 0 {
          members.add(m)
        } else {
          members.add(RMFunc(fn = withSiblingCallsOnSelf(fn, hoistedNames, selfTy)))
        }
      }
      case _ -> members.add(m)
    }
  }
  d.copy(members = members)
}

func withSiblingCallsOnSelf(fn: in FunctionDecl, names: in Map[String, Bool], selfTy: in TypeExpr): FunctionDecl {
  val bound: List[String] = newList()
  for p in fn.params {
    bound.add(p.name)
  }
  val contracts: List[ContractClause] = newList()
  for c in fn.contracts {
    contracts.add(sfContract(c, names, bound, selfTy))
  }
  fn.copy(
    contracts = contracts,
    body = match fn.body { case Some(b) -> Some(value = sfFunctionBody(b, names, bound, selfTy)); case None -> None }
  )
}

// Each hoisted method as a dot-named function after the record.  A method
// with no visibility of its own is reachable wherever its record is, so its
// function takes the record's.  A record without type parameters gives a
// function without them.
func addHoistedByRefMethods(
  file: in SourceFile,
  d: in RecordDecl,
  hoist: in Map[String, Bool],
  recordVis: in Option[Visibility],
  acc: in List[Item],
): Unit {
  val members = recordMemberNames(d)
  for m in d.members {
    match m {
      case RMFunc(fn0) -> if hoist.containsKey(methodKey(fn0)) {
        val fn = match fn0.visibility { case Some(_) -> fn0; case None -> fn0.copy(visibility = recordVis) }
        val hoisted0 = withRecordMethodMarker(hoistMethod(d, members, fn))
        val hoisted = match hoisted0.generics {
          case Some(gp) -> if gp.params.count == 0 {
            hoisted0.copy(generics = None)
          } else {
            withOwnRecordQualified(file, d.name, hoisted0)
          }
          case None -> hoisted0
        }
        acc.add(
          Item(
            docComments = hoisted.docComments,
            annotations = hoisted.annotations,
            visibility = hoisted.visibility,
            kind = IFunc(decl = hoisted),
            span = hoisted.span
          )
        )
      }
      case _ -> ()
    }
  }
}

// A generic function is specialised into each package that calls it
// (`Lyric.Mono`), where its body is lowered in the caller's scope, so a
// hoisted generic method names its own record through the declaring package
// (`Pkg.Box[T]`, `Pkg.Box(v = v)`): a caller's own `Box` must not capture it
// (#8179).  Its signature, local and lambda-parameter annotations, and
// constructor calls are qualified.
/// The annotation a record method hoisted to a dot-named function carries,
/// so a pass that treats record methods differently from functions (the
/// aspect weaver, which leaves record methods unwoven) still sees a method.
pub func recordMethodMarker(): String = "__lyric_record_method"

func withRecordMethodMarker(fd: in FunctionDecl): FunctionDecl {
  val anns: List[Annotation] = newList()
  for a in fd.annotations {
    anns.add(a)
  }
  val segs: List[String] = newList()
  segs.add(recordMethodMarker())
  val noArgs: List[AnnotationArg] = newList()
  anns.add(Annotation(name = ModulePath(segments = segs, span = fd.span), args = noArgs, span = fd.span))
  fd.copy(annotations = anns)
}

func withOwnRecordQualified(file: in SourceFile, name: in String, fd: in FunctionDecl): FunctionDecl {
  val pkgSegs = file.packageDecl.path.segments
  if pkgSegs.count == 0 {
    return fd
  }
  val params: List[Param] = newList()
  for p in fd.params {
    params.add(p.copy(ty = qualifiedOwnType(p.ty, name, pkgSegs)))
  }
  val ret = match fd.ret { case Some(r) -> Some(value = qualifiedOwnType(r, name, pkgSegs)); case None -> None }
  val noDocs: List[DocComment] = newList()
  val noAnns: List[Annotation] = newList()
  val item = Item(
    docComments = noDocs,
    annotations = noAnns,
    visibility = fd.visibility,
    kind = IFunc(decl = fd),
    span = fd.span
  )
  val mapped = mapFileAndContracts(
    oneItemFile(file, item),
    { e: Expr ->
      match e.kind {
        case ECall(callee, args) -> match callee.kind {
          case EPath(cp) -> if cp.segments.count == 1 and cp.segments[0] == name {
            e.copy(
              kind = ECall(fn = callee.copy(kind = EPath(path = cp.copy(segments = qualifiedSegs(pkgSegs, name)))), args = args)
            )
          } else {
            e
          }
          case _ -> e
        }
        case ELambda(lps, body) -> {
          val outPs: List[LambdaParam] = newList()
          for lp in lps {
            outPs.add(
              lp.copy(ty = match lp.ty { case Some(t) -> Some(value = qualifiedOwnType(t, name, pkgSegs)); case None -> None })
            )
          }
          e.copy(kind = ELambda(lambdaParams = outPs, body = body))
        }
        case _ -> e
      }
    },
    { st: Statement -> qualifiedOwnLocal(st, name, pkgSegs) }
  )
  val body = match mapped.items[0].kind { case IFunc(md) -> md.body; case _ -> fd.body }
  fd.copy(params = params, ret = ret, body = body)
}

func qualifiedSegs(pkgSegs: in List[String], name: in String): List[String] {
  val segs: List[String] = newList()
  for s in pkgSegs {
    segs.add(s)
  }
  segs.add(name)
  segs
}

// A local's annotation, qualified like the signature.
func qualifiedOwnLocal(st: in Statement, name: in String, pkgSegs: in List[String]): Statement {
  match st.kind {
    case SLocal(b) -> match b {
      case LBVal(pat, ty, init) -> st.copy(
        kind = SLocal(
          binding = LBVal(
            pat = pat,
            ty = qualifiedOwnTypeOpt(ty, name, pkgSegs),
            init = init
          )
        )
      )
      case LBVar(n, ty, init) -> st.copy(
        kind = SLocal(
          binding = LBVar(
            name = n,
            ty = qualifiedOwnTypeOpt(ty, name, pkgSegs),
            init = init
          )
        )
      )
      case LBLet(n, ty, init) -> st.copy(
        kind = SLocal(
          binding = LBLet(
            name = n,
            ty = qualifiedOwnTypeOpt(ty, name, pkgSegs),
            init = init
          )
        )
      )
    }
    case _ -> st
  }
}

func qualifiedOwnTypeOpt(t: in Option[TypeExpr], name: in String, pkgSegs: in List[String]): Option[TypeExpr] {
  match t {
    case Some(te) -> Some(value = qualifiedOwnType(te, name, pkgSegs))
    case None -> None
  }
}

func qualifiedOwnType(t: in TypeExpr, name: in String, pkgSegs: in List[String]): TypeExpr {
  match t.kind {
    case TRef(p) -> if p.segments.count == 1 and p.segments[0] == name {
      t.copy(kind = TRef(path = p.copy(segments = qualifiedSegs(pkgSegs, name))))
    } else {
      t
    }
    case TGenericApp(head, args) -> {
      val acc: List[TypeArg] = newList()
      for a in args {
        acc.add(match a { case TAType(at) -> TAType(ty = qualifiedOwnType(at, name, pkgSegs)); case TAValue(_) -> a })
      }
      val qhead = if head.segments.count == 1 and head.segments[0] == name {
        head.copy(segments = qualifiedSegs(pkgSegs, name))
      } else {
        head
      }
      t.copy(kind = TGenericApp(head = qhead, args = acc))
    }
    case TArray(size, el) -> t.copy(kind = TArray(size = size, element = qualifiedOwnType(el, name, pkgSegs)))
    case TSlice(el) -> t.copy(kind = TSlice(element = qualifiedOwnType(el, name, pkgSegs)))
    case TTuple(ts) -> {
      val acc: List[TypeExpr] = newList()
      for x in ts {
        acc.add(qualifiedOwnType(x, name, pkgSegs))
      }
      t.copy(kind = TTuple(types = acc))
    }
    case TNullable(inner) -> t.copy(kind = TNullable(inner = qualifiedOwnType(inner, name, pkgSegs)))
    case TParen(inner) -> t.copy(kind = TParen(inner = qualifiedOwnType(inner, name, pkgSegs)))
    case TFunction(ps, r) -> {
      val acc: List[TypeExpr] = newList()
      for x in ps {
        acc.add(qualifiedOwnType(x, name, pkgSegs))
      }
      t.copy(kind = TFunction(parameters = acc, retTy = qualifiedOwnType(r, name, pkgSegs)))
    }
    case _ -> t
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// After type checking: calls of a dot-named function with an `out`/`inout`
// parameter become plain calls of the function.
// ─────────────────────────────────────────────────────────────────────────────
/// `p.m(x)` → `T.m(p, x)` and `T.m(p, x)` → `T.m(p, x)` as one path segment,
/// the name the function is declared under, for each call the checker
/// recorded (`SymbolTable.byRefDotCallSites`).  A non-generic function of
/// another package is named through that package (`Pkg.T.m`); a generic one
/// is specialised into this package by `Lyric.Mono`, under its own name.  The
/// callee keeps its span, under which the checker recorded the call.
pub func rewriteByRefDotCalls(file: in SourceFile, sites: in Map[String, ByRefDotCall]): SourceFile {
  if sites.count == 0 {
    return file
  }
  mapFileAndContracts(
    file,
    { e: Expr ->
      match e.kind {
        case ECall(fn, args) -> match mapGet(sites, recordCopySiteKey(fn.span)) {
          case Some(site) -> {
            val segs: List[String] = newList()
            if site.originPkg.length > 0 {
              for seg in dottedSegments(site.originPkg) {
                segs.add(seg)
              }
            }
            segs.add(site.name)
            val target = Expr(kind = EPath(path = ModulePath(segments = segs, span = fn.span)), span = fn.span)
            if site.receiverFirst {
              match fn.kind {
                case EMember(recv, _) -> {
                  val fullArgs: List[CallArg] = newList()
                  fullArgs.add(CAPositional(expr = recv))
                  for a in args {
                    fullArgs.add(a)
                  }
                  Expr(kind = ECall(fn = target, args = fullArgs), span = e.span)
                }
                case _ -> e
              }
            } else {
              Expr(kind = ECall(fn = target, args = args), span = e.span)
            }
          }
          case None -> e
        }
        case _ -> e
      }
    },
    { s: Statement -> s }
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// After `?`-propagation: an `inout` receiver becomes an ordinary parameter.
// ─────────────────────────────────────────────────────────────────────────────
/// Each function with an `inout` receiver, its `self` parameter renamed to
/// `byRefReceiverName()` and each `self` in its body and contract clauses
/// read through that name.  A nested function item is a function of its own
/// and is not entered.
pub func renameByRefReceivers(file: in SourceFile): SourceFile {
  var changed = false
  val items: List[Item] = newList()
  for it in file.items {
    match it.kind {
      case IFunc(fd) -> if hasByRefReceiver(fd) {
        changed = true
        items.add(it.copy(kind = IFunc(decl = renamedReceiver(file, it, fd))))
      } else {
        items.add(it)
      }
      case _ -> items.add(it)
    }
  }
  if changed {
    file.copy(items = items)
  } else {
    file
  }
}

func renamedReceiver(file: in SourceFile, it: in Item, fd: in FunctionDecl): FunctionDecl {
  val params: List[Param] = newList()
  var i = 0
  while i < fd.params.count {
    if i == 0 {
      params.add(fd.params[i].copy(name = byRefReceiverName()))
    } else {
      params.add(fd.params[i])
    }
    i = i + 1
  }
  val mapped = mapFileAndContracts(
    oneItemFile(file, it),
    { e: Expr ->
      match e.kind {
        case ESelf -> {
          val segs: List[String] = newList()
          segs.add(byRefReceiverName())
          Expr(kind = EPath(path = ModulePath(segments = segs, span = e.span)), span = e.span)
        }
        case _ -> e
      }
    },
    { s: Statement -> s }
  )
  match mapped.items[0].kind {
    case IFunc(md) -> md.copy(params = params)
    case _ -> fd.copy(params = params)
  }
}
