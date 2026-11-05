//! typechecker_send.l — the `Send` structural marker and the `spawn` rules
//! T0225 and T0226 (D404).
//!
//! A type is `Send` when tasks running at the same time can share one value
//! of it without a race: the primitives, enums, distinct and range types over
//! a `Send` type, tuples, nullables, arrays, slices and buffers of `Send`
//! elements, records, exposed records and opaque types with no `var` field
//! whose fields are all `Send`, unions whose case fields are all `Send`,
//! protected types, `Task[T]` of a `Send` `T`, and a type parameter bounded
//! `where T: Send`.  Like `Plain` (D155) the marker is computed, never
//! declared, and `sendViolation` says which part of a type defeats it.
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.Symbols

pub func isSendMarker(name: in String): Bool = name == "Send"

/// The entry `@sendable` adds to a declaration's derive list; no derive
/// marker can be spelled with an `@`.
pub func sendableMark(): String = "@sendable"

// Whether any declaration of `tid` asserts `@sendable`.  One host type can be
// declared in several packages and still be one type (`externTypeDefPath`).
func declaredSendable(tbl: in SymbolTable, tid: in SymbolId): Bool {
  for sym in tbl.symbols {
    val id = match sym.kind {
      case DKExternType(i, _) -> Some(value = i)
      case DKRecord(i, _) -> Some(value = i)
      case DKExposedRec(i, _) -> Some(value = i)
      case DKOpaque(i, _) -> Some(value = i)
      case _ -> None
    }
    match id {
      case Some(i) -> if symbolIdEq(i, tid) and sym.derives.contains(sendableMark()) { return true }
      case None -> ()
    }
  }
  false
}

/// `None` when `t` is `Send`; otherwise why it is not.  `bounds` are the
/// enclosing declaration's `where` bounds, which make a type parameter
/// bounded by `Send` acceptable.
pub func sendViolation(tbl: in SymbolTable, bounds: in List[ResolvedBound], t: in Type): Option[String] {
  sendViolationAt(tbl, bounds, newList(), t, 0)
}

pub func isSendType(tbl: in SymbolTable, bounds: in List[ResolvedBound], t: in Type): Bool {
  match sendViolation(tbl, bounds, t) {
    case None -> true
    case Some(_) -> false
  }
}

func boundHasSend(bounds: in List[ResolvedBound], name: in String): Bool {
  for b in bounds {
    if b.name == name {
      for c in b.constraints {
        if isSendMarker(c) {
          return true
        }
      }
    }
  }
  false
}

func sendViolationAt(
  tbl: in SymbolTable,
  bounds: in List[ResolvedBound],
  seen: in List[String],
  t: in Type,
  depth: in Int,
): Option[String] {
  if depth > 24 {
    return Some(value = "the type nests too deeply to check")
  }
  match t {
    case TyPrim(_) -> None
    case TyRefined(under, _, _, _, _) -> sendViolationAt(tbl, bounds, seen, under, depth + 1)
    case TyTuple(elems) -> {
      for el in elems {
        match sendViolationAt(tbl, bounds, seen, el, depth + 1) {
          case None -> ()
          case Some(why) -> return Some(value = "a tuple element is not sendable: " + why)
        }
      }
      None
    }
    case TyNullable(inner) -> sendViolationAt(tbl, bounds, seen, inner, depth + 1)
    case TyArray(_, el, _) -> match sendViolationAt(tbl, bounds, seen, el, depth + 1) {
      case None -> None
      case Some(why) -> Some(value = "its array element is not sendable: " + why)
    }
    case TySlice(el) -> match sendViolationAt(tbl, bounds, seen, el, depth + 1) {
      case None -> None
      case Some(why) -> Some(value = "its slice element is not sendable: " + why)
    }
    case TyFunction(_, _, _) -> Some(
      value = "a function value may capture mutable state, which the task and its spawner would then share"
    )
    case TyParam(name, _) -> if boundHasSend(bounds, name) {
      None
    } else {
      Some(value = "type parameter '" + name + "' is not known to be sendable; bound it with 'where " + name + ": Send'")
    }
    case TyUser(tid, name, args) -> sendUserViolation(tbl, bounds, seen, t, tid, name, args, depth)
    // Already reported where the type was formed.
    case TyError(_) -> None
    case TyInfer(_) -> None
    case TyLen(_) -> None
    case TySelf -> Some(value = "'Self' is not known to be sendable")
    case TyException -> Some(value = "an exception value is not known to be sendable")
  }
}

func sendArgsViolation(
  tbl: in SymbolTable,
  bounds: in List[ResolvedBound],
  seen: in List[String],
  what: in String,
  args: in List[Type],
  depth: in Int,
): Option[String] {
  for a in args {
    match sendViolationAt(tbl, bounds, seen, a, depth + 1) {
      case None -> ()
      case Some(why) -> return Some(value = "its " + what + " is not sendable: " + why)
    }
  }
  None
}

func sendUserViolation(
  tbl: in SymbolTable,
  bounds: in List[ResolvedBound],
  seen: in List[String],
  t: in Type,
  tid: in SymbolId,
  name: in String,
  args: in List[Type],
  depth: in Int,
): Option[String] {
  if symbolIdEq(tid, builtinTaskTypeId()) {
    return sendArgsViolation(tbl, bounds, seen, "task result", args, depth)
  }
  if symbolIdEq(tid, builtinBufferTypeId()) {
    return sendArgsViolation(tbl, bounds, seen, "buffer element", args, depth)
  }
  // A type that refers to itself (`union Tree { case Node(l: Tree, r: Tree) }`)
  // is sendable when everything else in it is: the inner occurrence, at the
  // same type arguments, adds nothing new to check.
  val key = toString(tid.id) + ":" + renderType(t)
  if seen.contains(key) {
    return None
  }
  if declaredSendable(tbl, tid) {
    return None
  }
  seen.add(key)
  val verdict = sendDeclaredViolation(tbl, bounds, seen, t, tid, name, args, depth)
  seen.removeAt(seen.count - 1)
  verdict
}

func sendDeclaredViolation(
  tbl: in SymbolTable,
  bounds: in List[ResolvedBound],
  seen: in List[String],
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
      case DKProtected(_, _) -> None
      case DKRecord(_, rd) -> sendRecordViolation(tbl, bounds, seen, tid, rd, name, args, depth)
      case DKExposedRec(_, rd) -> sendRecordViolation(tbl, bounds, seen, tid, rd, name, args, depth)
      case DKOpaque(_, od) -> sendOpaqueViolation(tbl, bounds, seen, od, name, args, depth)
      case DKUnion(_, ud) -> sendUnionViolation(tbl, bounds, seen, sym, ud, name, args, depth)
      case DKDistinctType(_, dt) -> {
        val scratch: List[Diagnostic] = newList()
        match distinctMemberType(tbl, scratch, t, "value", dt.span) {
          case None -> Some(value = "'" + name + "' has no resolvable underlying type")
          case Some(under) -> match sendViolationAt(tbl, bounds, seen, under, depth + 1) {
            case None -> None
            case Some(why) -> Some(
              value = "the underlying type of '" + name + "' is not sendable: " + why
            )
          }
        }
      }
      case DKInterface(_, _) -> Some(
        value = "'" + name +
          "' is an interface, and the value behind it may hold mutable state"
      )
      case DKExternType(_, _) -> Some(
        value = "'" + name +
          "' is a host object with unsynchronised mutable state"
      )
      case _ -> Some(value = "'" + name + "' is not known to be sendable")
    }
  }
}

func sendRecordViolation(
  tbl: in SymbolTable,
  bounds: in List[ResolvedBound],
  seen: in List[String],
  tid: in SymbolId,
  rd: in RecordDecl,
  name: in String,
  args: in List[Type],
  depth: in Int,
): Option[String] {
  for m in rd.members {
    match m {
      case RMField(fd) -> if fd.isMutable {
        return Some(
          value = "'" + name + "' has a 'var' field (field '" + fd.name +
            "'), so it has identity and the task would share it with its spawner"
        )
      }
      case _ -> ()
    }
  }
  val gnames = recordGenericNamesOf(tbl, tid)
  for f in fieldsOfRecord(tbl, tid) {
    match sendViolationAt(tbl, bounds, seen, substituteTyParams(f.ty, gnames, args), depth + 1) {
      case None -> ()
      case Some(why) -> return Some(value = "field '" + f.name + "' of '" + name + "' is not sendable: " + why)
    }
  }
  None
}

func sendOpaqueViolation(
  tbl: in SymbolTable,
  bounds: in List[ResolvedBound],
  seen: in List[String],
  od: in OpaqueTypeDecl,
  name: in String,
  args: in List[Type],
  depth: in Int,
): Option[String] {
  if not od.hasBody {
    return Some(value = "'" + name + "' is an opaque type whose representation is not visible here")
  }
  val gnames = extractGenericNames(od.generics)
  val ctx = newGenericContext()
  gctxPushOwned(ctx, gnames, od.name)
  val scratch: List[Diagnostic] = newList()
  for m in od.members {
    match m {
      case OMField(fd) -> {
        if fd.isMutable {
          return Some(
            value = "'" + name + "' has a 'var' field (field '" + fd.name +
              "'), so it has identity and the task would share it with its spawner"
          )
        }
        val fty = substituteTyParams(resolveType(tbl, ctx, scratch, fd.ty), gnames, args)
        match sendViolationAt(tbl, bounds, seen, fty, depth + 1) {
          case None -> ()
          case Some(why) -> return Some(value = "field '" + fd.name + "' of '" + name + "' is not sendable: " + why)
        }
      }
      case OMInvariant(_) -> ()
    }
  }
  None
}

func sendUnionViolation(
  tbl: in SymbolTable,
  bounds: in List[ResolvedBound],
  seen: in List[String],
  sym: in Symbol,
  ud: in UnionDecl,
  name: in String,
  args: in List[Type],
  depth: in Int,
): Option[String] {
  val gnames = unionDeclGenericNames(ud)
  val scratch: List[Diagnostic] = newList()
  for uc in ud.cases {
    val ftypes = unionCaseFieldTypes(tbl, scratch, uc, ud.name, gnames, sym.originPackage)
    for ft in ftypes {
      match sendViolationAt(tbl, bounds, seen, substituteTyParams(ft, gnames, args), depth + 1) {
        case None -> ()
        case Some(why) -> return Some(value = "case '" + uc.name + "' of '" + name + "' is not sendable: " + why)
      }
    }
  }
  None
}

// ─────────────────────────────────────────────────────────────────────────────
// What the checker records while it checks bodies (D404).
// ─────────────────────────────────────────────────────────────────────────────
/// The key a function is known by in the `send*` tables: its package and the
/// span of its declaration.
pub func sendFnKey(sig: in ResolvedSignature): String = sig.originPackage + "@" + recordCopySiteKey(sig.span)

pub func sendEnterFn(tbl: in SymbolTable, sig: in ResolvedSignature, name: in String): Unit {
  val key = sendFnKey(sig)
  tbl.sendFnStack.add(key)
  if not tbl.sendFnNames.containsKey(key) {
    tbl.sendFnNames.add(key, name)
  }
}

pub func sendLeaveFn(tbl: in SymbolTable): Unit {
  if tbl.sendFnStack.count > 0 {
    tbl.sendFnStack.removeAt(tbl.sendFnStack.count - 1)
  }
}

func sendCurrentFn(tbl: in SymbolTable): String {
  if tbl.sendFnStack.count == 0 {
    ""
  } else {
    tbl.sendFnStack[tbl.sendFnStack.count - 1]
  }
}

func sendParamIndex(sig: in ResolvedSignature, name: in String): Int {
  var i = 0
  while i < sig.params.count {
    if sig.params[i].name == name {
      return i
    }
    i = i + 1
  }
  0 - 1
}

/// Records a resolved call: the edge from the function being checked to its
/// callee, and the callee and argument types for a `spawn` of this call.
/// `recvTy` is the receiver's type for a method call whose receiver is not
/// among `argTypes`; `recvImplicit` says the signature has no parameter for
/// it (a method declared in a type's body).
pub func sendNoteCall(
  tbl: in SymbolTable,
  span: in Span,
  sig: in ResolvedSignature,
  calleeName: in String,
  args: in List[CallArg],
  argTypes: in List[Type],
  recvTy: in Option[Type],
  recvImplicit: in Bool,
): Unit {
  val calleeKey = sendFnKey(sig)
  val from = sendCurrentFn(tbl)
  if from != "" {
    if not tbl.sendCallEdges.containsKey(from) {
      tbl.sendCallEdges.add(from, newList())
    }
    val edges = tbl.sendCallEdges[from]
    if not edges.contains(calleeKey) {
      edges.add(calleeKey)
    }
  }
  if not tbl.sendFnNames.containsKey(calleeKey) {
    tbl.sendFnNames.add(calleeKey, calleeName)
  }
  val collected: List[SendCallArg] = newList()
  // The receiver, when the signature takes it as its first parameter: either
  // prefixed to `argTypes` or given separately.
  var argBase = 0
  var paramBase = 0
  if argTypes.count == args.count + 1 and sig.params.count > 0 {
    collected.add(SendCallArg(label = "the receiver", ty = argTypes[0], mode = sig.params[0].mode))
    argBase = 1
    paramBase = 1
  } else if recvImplicit {
    match recvTy {
      case Some(rt) -> collected.add(SendCallArg(label = "the receiver", ty = rt, mode = PMIn))
      case None -> ()
    }
  } else if sig.params.count == args.count + 1 {
    match recvTy {
      case Some(rt) -> {
        collected.add(SendCallArg(label = "the receiver", ty = rt, mode = sig.params[0].mode))
        paramBase = 1
      }
      case None -> ()
    }
  }
  var i = 0
  while i < args.count and i + argBase < argTypes.count {
    val pidx = match args[i] { case CANamed(n, _, _) -> sendParamIndex(sig, n); case CAPositional(_) -> i + paramBase }
    val label = if pidx >= 0 and pidx < sig.params.count {
      "argument '" + sig.params[pidx].name + "'"
    } else {
      "argument " + toString(i + 1)
    }
    val mode = if pidx >= 0 and pidx < sig.params.count { sig.params[pidx].mode } else { PMIn }
    collected.add(SendCallArg(label = label, ty = argTypes[i + argBase], mode = mode))
    i = i + 1
  }
  val key = recordCopySiteKey(span)
  if tbl.sendCallInfo.containsKey(key) {
    tbl.sendCallInfo.remove(key)
  }
  tbl.sendCallInfo.add(key, SendCallInfo(calleeKey = calleeKey, calleeName = calleeName, args = collected))
}

/// Records that the function being checked reads module-level value `name`
/// of type `ty`, when `ty` is not `Send`.
pub func sendNoteModuleRead(tbl: in SymbolTable, name: in String, ty: in Type): Unit {
  val from = sendCurrentFn(tbl)
  if from == "" {
    return
  }
  val noBounds: List[ResolvedBound] = newList()
  match sendViolation(tbl, noBounds, ty) {
    case None -> ()
    case Some(why) -> {
      if not tbl.sendModuleReads.containsKey(from) {
        tbl.sendModuleReads.add(from, newList())
      }
      val reads = tbl.sendModuleReads[from]
      for r in reads {
        if r.name == name {
          return
        }
      }
      reads.add(SendModuleRead(name = name, ty = renderType(ty), why = why))
    }
  }
}

func modeWord(m: in ParamMode): String {
  match m {
    case PMIn -> "in"
    case PMOut -> "out"
    case PMInout -> "inout"
  }
}

func unparenExpr(e: in Expr): Expr {
  match e.kind {
    case EParen(inner) -> unparenExpr(inner)
    case _ -> e
  }
}

/// T0225: every argument of a spawned call, the receiver included, must be
/// `Send` and passed `in`; a spawned call of a function value is rejected
/// because its captures cannot be checked.  Records the spawn for T0226.
pub func checkSpawnSendable(sc: in Scope, tbl: in SymbolTable, diag: in List[Diagnostic], inner: in Expr): Unit {
  val call = unparenExpr(inner)
  match mapGet(tbl.sendCallInfo, recordCopySiteKey(call.span)) {
    case Some(info) -> {
      for a in info.args {
        match a.mode {
          case PMIn -> match sendViolation(tbl, sc.bounds, a.ty) {
            case None -> ()
            case Some(why) -> diag.add(
              errorDiagnostic(
                "T0225",
                "the spawned call to '" + info.calleeName + "' cannot take " + a.label +
                  " of type " +
                  renderType(a.ty) +
                  ": " +
                  why +
                  "; the task runs at the same time as its spawner, so share the value through a protected type, pass an immutable copy (a slice), or build it inside the task",
                call.span
              )
            )
          }
          case _ -> diag.add(
            errorDiagnostic(
              "T0225",
              "the spawned call to '" + info.calleeName + "' passes " + a.label + " as '" + modeWord(a.mode) +
                "': the task would write the spawner's variable while the spawner runs; return the value from the task and assign it after 'await' instead",
              call.span
            )
          )
        }
      }
      tbl.sendSpawns.add(SendSpawnSite(calleeKey = info.calleeKey, calleeName = info.calleeName, span = call.span))
    }
    case None -> match call.kind {
      case ECall(fn, _) -> match unparenExpr(fn).kind {
        case EPath(p) -> if p.segments.count == 1 {
          match scopeTryFind(sc, p.segments[0]) {
            case Some(b) -> match b.ty {
              case TyFunction(_, _, _) -> diag.add(
                errorDiagnostic(
                  "T0225",
                  "'" + p.segments[0] +
                    "' is a function value, and a spawned call of one cannot be checked: the task would share whatever it captured with its spawner; spawn a named function and pass it the values it needs",
                  call.span
                )
              )
              case _ -> ()
            }
            case None -> ()
          }
        }
        case _ -> ()
      }
      case _ -> ()
    }
  }
}

/// T0226: the module-level values of a non-`Send` type that a spawned callee
/// reads, directly or through the functions of this package it calls.
pub func reportSpawnModuleState(tbl: in SymbolTable, diag: in List[Diagnostic]): Unit {
  for site in tbl.sendSpawns {
    // Breadth-first over the call edges, remembering how each function was
    // reached so the message can show the chain.
    val order: List[String] = newList()
    val via: Map[String, String] = newMap()
    order.add(site.calleeKey)
    via.add(site.calleeKey, "")
    var qi = 0
    var reported = false
    while qi < order.count and not reported {
      val fk = order[qi]
      match mapGet(tbl.sendModuleReads, fk) {
        case Some(reads) -> if reads.count > 0 {
          val r = reads[0]
          diag.add(
            errorDiagnostic(
              "T0226",
              "the spawned call to '" + site.calleeName + "' reads module-level value '" + r.name + "' of type " + r.ty +
                sendChainText(tbl, via, fk) +
                ": " +
                r.why +
                "; the task runs at the same time as other code that uses it, so keep the state in a protected type",
              site.span
            )
          )
          reported = true
        }
        case None -> ()
      }
      match mapGet(tbl.sendCallEdges, fk) {
        case Some(next) -> {
          for nk in next {
            if not via.containsKey(nk) {
              via.add(nk, fk)
              order.add(nk)
            }
          }
        }
        case None -> ()
      }
      qi = qi + 1
    }
  }
}

func sendFnDisplayName(tbl: in SymbolTable, key: in String): String {
  match mapGet(tbl.sendFnNames, key) {
    case Some(n) -> n
    case None -> key
  }
}

// " (through f -> g -> h)" naming how `key` was reached, or "" when it is the
// spawned function itself.
func sendChainText(tbl: in SymbolTable, via: in Map[String, String], key: in String): String {
  val reversed: List[String] = newList()
  var k = key
  var guard = 0
  while k != "" and guard < 64 {
    reversed.add(sendFnDisplayName(tbl, k))
    k = match mapGet(via, k) { case Some(p) -> p; case None -> "" }
    guard = guard + 1
  }
  val names: List[String] = newList()
  var ri = reversed.count - 1
  while ri >= 0 {
    names.add(reversed[ri])
    ri = ri - 1
  }
  if names.count <= 1 {
    ""
  } else {
    var text = " (through "
    var i = 0
    while i < names.count {
      if i > 0 {
        text = text + " -> "
      }
      text = text + names[i]
      i = i + 1
    }
    text + ")"
  }
}
