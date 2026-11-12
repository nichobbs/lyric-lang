//! llvm_tir.l - Lyric.LlvmTir: the native backend's lowering of TIR (docs/70 §8,
//! phase 4a, D520).
//!
//! `lowerTirFunction` turns one monomorphic `TFnDecl` into an `NFunc`.  It reads
//! types from `TExpr.ty`, callees from `Callee` and conversions from `ConvKind`
//! and nothing else: no inference, no name lookup, no checker side table.  The
//! one thing it is handed that TIR does not carry is `TirLowerEnv.fnNames`, the
//! linkage table of docs/70 §9.5 for this slice: the IR symbol of each
//! `SymbolId` the bundle defines.
//!
//! A function this slice cannot lower is not an error: the result is
//! `Err(TirFallback)` naming the first construct that stopped it, and the
//! caller keeps the AST path's lowering of that function and counts the
//! fallback (§12.2).  Nothing is skipped silently.
//!
//! Linkage and attributes of the produced `NFunc` are the AST path's to supply
//! (the caller copies them from the function it replaces).
package Lyric.LlvmTir

import Std.Core
import Std.Collections
import Std.Encoding as Encoding
import Std.Environment as Environment
import Std.String as Str
import Lyric.LlvmTypes
import Lyric.LlvmIr
import Lyric.Symbols
import Lyric.Tir

/// Whether the TIR lowering is requested: `lyric build --target native
/// --via-tir` sets `LYRIC_NATIVE_VIA_TIR=1` for the build, and CI sets it
/// directly (docs/70 phase 4a, D520).
pub func viaTirRequested(): Bool {
  Environment.getVarOrDefault("LYRIC_NATIVE_VIA_TIR", "") == "1"
}

/// One package's TIR as the code generator receives it: the built package and the
/// DefPath key of every symbol in it (`SymbolId.id` to key), from which a top-level
/// function's package, name and arity are read.
pub record TirUnitInput {
  pkg: TPackage
  names: Map[Int, String]
  census: TirCensus
}

/// The package, name and parameter count of a top-level function.
pub record TirFnName {
  pkg: String
  name: String
  arity: Int
}

/// The parameter count of the text between a function key's parentheses: the
/// commas at bracket depth zero, plus one, or zero for no parameters.
func paramCount(params: in String): Int {
  if params.length == 0 {
    return 0
  }
  var depth = 0
  var n = 1
  var i = 0
  while i < params.length {
    match Str.charAt(params, i) {
      case Some(ch) -> {
        if ch == '[' or ch == '(' {
          depth = depth + 1
        } else if ch == ']' or ch == ')' {
          depth = depth - 1
        } else if ch == ',' and depth == 0 {
          n = n + 1
        }
      }
      case None -> ()
    }
    i = i + 1
  }
  n
}

/// Read a top-level function's DefPath key, `Pkg::name(P1,P2)` (docs/70 §4.2); None
/// for the key of a type, a member or anything else.
pub func tirTopLevelFn(key: in String): Option[TirFnName] {
  match Str.indexOf(key, "::") {
    case None -> None
    case Some(sep) -> {
      val rest = Str.substring(key, sep + 2)
      match Str.indexOf(rest, "(") {
        case None -> None
        case Some(open) -> {
          val head = Str.substring(rest, 0, open)
          if Str.contains(head, "::") or not Str.endsWith(rest, ")") {
            return None
          }
          val params = Str.substring(rest, open + 1, rest.length - open - 2)
          Some(value = TirFnName(pkg = Str.substring(key, 0, sep), name = head, arity = paramCount(params)))
        }
      }
    }
  }
}

/// What came of lowering a unit's functions from TIR: how many were lowered, and
/// the reason each of the others stayed on the AST path.
pub record TirCensus {
  lowered: List[String]
  fallbacks: List[String]
}

pub func newTirCensus(): TirCensus {
  TirCensus(lowered = newList(), fallbacks = newList())
}

/// The census as report lines: the totals, then each fallback reason with how many
/// functions it kept on the AST path, most frequent first.
pub func tirCensusLines(c: in TirCensus): List[String] {
  val lines: List[String] = newList()
  lines.add(
    "native via-TIR: " + toString(c.lowered.count) + " of " + toString(c.lowered.count + c.fallbacks.count) +
      " functions lowered from TIR"
  )
  val counts: Map[String, Int] = newMap()
  for f in c.fallbacks {
    val reason = match Str.indexOf(f, ": ") { case Some(i) -> Str.substring(f, i + 2); case None -> f }
    val had = match mapGet(counts, reason) { case Some(n) -> n; case None -> 0 }
    if counts.containsKey(reason) {
      counts.remove(reason)
    }
    counts.add(reason, had + 1)
  }
  val taken: Map[String, Bool] = newMap()
  var round = 0
  val reasonCount = mapKeys(counts).count
  while round < reasonCount {
    var best = ""
    var bestN = 0
    for k in mapKeys(counts) {
      if not taken.containsKey(k) {
        val n = match mapGet(counts, k) { case Some(v) -> v; case None -> 0 }
        if n > bestN {
          best = k
          bestN = n
        }
      }
    }
    taken.add(best, true)
    lines.add("  fallback: " + best + " x " + toString(bestN))
    round = round + 1
  }
  lines
}

/// What the lowering needs beyond the declaration.
pub record TirLowerEnv {
  /// IR symbol of each declared function, keyed by `SymbolId.id`.
  fnNames: Map[Int, String]
  /// The package label a panic reports as its file, as the AST path does.
  panicFile: String
  /// The by-value records, keyed by `SymbolId.id`.  The code generator owns record layout
  /// (docs/70 phase 4a): it hands over the type and the field types it chose, and this
  /// lowering never decides between the heap and the by-value form.
  recs: Map[Int, TirRecLayout] = newMap()
}

/// A by-value record's layout as the code generator chose it: its LLVM struct type and
/// the type of each field in declaration order (`NVoid` for a Unit field, whose
/// placeholder byte the struct holds but nothing reads).
pub record TirRecLayout {
  ty: NType
  fieldTys: List[NType]
}

/// Why a function stayed on the AST path.
pub record TirFallback {
  sym: SymbolId
  reason: String
}

pub record TirLowered {
  fn: NFunc
  globals: List[NGlobalDef]
  /// Runtime declarations the body calls (`lyric_panic_msg`); the caller adds
  /// those the package lacks.
  externs: List[NFunc]
}

record Slot {
  ptr: String
  ty: NType
}

record LoopLabels {
  label: Option[String]
  breakL: String
  contL: String
  /// How many reference scopes and temporary scopes were open when the loop began: a
  /// `break` or `continue` releases what was opened since.
  scopeDepth: Int
  tempDepth: Int
}

/// A value and, for a reference, who owns it: `owned` is a count this code holds and must
/// release or hand on (a call result, a retained value); a borrowed reference (a read of a
/// local, a static literal) is held by someone else.
record Val {
  ty: NType
  value: NValue
  owned: Bool = false
}

record LCtx {
  env: TirLowerEnv
  insns: List[NInsn]
  allocas: List[NInsn]
  globals: List[NGlobalDef]
  ticker: List[Int]
  cur: List[String]
  slots: Map[Int, Slot]
  loops: List[LoopLabels]
  problems: List[String]
  retTy: NType
  globalPrefix: String
  /// The reference locals live in each open lexical scope, released when it closes.
  refScopes: List[List[Slot]]
  /// The owned references passed on as borrowed operands in each open statement, released
  /// when it ends.
  temps: List[List[Val]]
}

func tmp(c: in LCtx): String {
  c.ticker.add(0)
  "t" + toString(c.ticker.count)
}

func newLabel(c: in LCtx, stem: in String): String {
  c.ticker.add(0)
  stem + "." + toString(c.ticker.count)
}

/// Open the block `name`; later phis name it as their incoming edge.
func startBlock(c: in LCtx, name: in String): Unit {
  c.insns.add(NLabel(name = name))
  c.cur.clear()
  c.cur.add(name)
}

func curBlock(c: in LCtx): String {
  c.cur[0]
}

func unitVal(): Val {
  Val(ty = NVoid, value = NUndef(ty = NVoid))
}

/// Record why the function cannot be lowered and hand back a placeholder so
/// lowering can continue to the end; the function is discarded afterwards.
func unsupported(c: in LCtx, why: in String): Val {
  c.problems.add(why)
  Val(ty = NI32, value = NUndef(ty = NI32))
}

func isStringN(t: in NType): Bool {
  match t {
    case NPtr(pointee) -> match pointee { case NStruct(name, _) -> name == "LyricString"; case _ -> false }
    case _ -> false
  }
}

/// The types whose values are reference counted.
func isRefN(t: in NType): Bool {
  isStringN(t)
}

func i8ptr(): NType {
  NPtr(pointee = NI8)
}

func callRtVoid(c: in LCtx, fn: in String, args: in List[NArg]): Unit {
  c.insns.add(NCallVoid(fn = NGlobal(name = fn), args = args))
}

func callRt(c: in LCtx, fn: in String, retTy: in NType, args: in List[NArg]): NValue {
  val d = tmp(c)
  c.insns.add(NCall(dest = d, retTy = retTy, fn = NGlobal(name = fn), args = args))
  NLocal(name = d)
}

func arg1(ty: in NType, v: in NValue): List[NArg] {
  val xs: List[NArg] = newList()
  xs.add(NArg(ty = ty, value = v))
  xs
}

func arg2(t1: in NType, v1: in NValue, t2: in NType, v2: in NValue): List[NArg] {
  val xs: List[NArg] = newList()
  xs.add(NArg(ty = t1, value = v1))
  xs.add(NArg(ty = t2, value = v2))
  xs
}

func asI8(c: in LCtx, ty: in NType, v: in NValue): NValue {
  val d = tmp(c)
  c.insns.add(NBitcast(dest = d, fromTy = ty, value = v, toTy = i8ptr()))
  NLocal(name = d)
}

func retainRef(c: in LCtx, ty: in NType, v: in NValue): Unit {
  callRtVoid(c, "lyric_retain", arg1(i8ptr(), asI8(c, ty, v)))
}

func releaseRef(c: in LCtx, ty: in NType, v: in NValue): Unit {
  callRtVoid(c, "lyric_release", arg1(i8ptr(), asI8(c, ty, v)))
}

/// A reference this code owns: a borrowed one is retained, an owned one is taken as it is.
/// A value that is not a reference is returned unchanged.
func own(c: in LCtx, v: in Val): Val {
  if not isRefN(v.ty) or v.owned {
    return v
  }
  retainRef(c, v.ty, v.value)
  Val(ty = v.ty, value = v.value, owned = true)
}

/// Release a reference nothing took.
func discard(c: in LCtx, v: in Val): Unit {
  if v.owned and isRefN(v.ty) {
    releaseRef(c, v.ty, v.value)
  }
}

func pushTemps(c: in LCtx): Unit {
  c.temps.add(newList())
}

/// Close the innermost statement: release the owned operands it passed on.
func popTemps(c: in LCtx): Unit {
  val top = c.temps[c.temps.count - 1]
  var i = top.count - 1
  while i >= 0 {
    releaseRef(c, top[i].ty, top[i].value)
    i = i - 1
  }
  c.temps.removeAt(c.temps.count - 1)
}

/// Use `v` as a borrowed operand: an owned reference is released when the statement ends.
func borrow(c: in LCtx, v: in Val): Val {
  if v.owned and isRefN(v.ty) {
    c.temps[c.temps.count - 1].add(v)
    return Val(ty = v.ty, value = v.value)
  }
  v
}

func pushRefScope(c: in LCtx): Unit {
  c.refScopes.add(newList())
}

func releaseSlot(c: in LCtx, slot: in Slot): Unit {
  val d = tmp(c)
  c.insns.add(NLoad(dest = d, ty = slot.ty, ptr = NLocal(name = slot.ptr)))
  releaseRef(c, slot.ty, NLocal(name = d))
}

func popRefScope(c: in LCtx): Unit {
  val top = c.refScopes[c.refScopes.count - 1]
  var i = top.count - 1
  while i >= 0 {
    releaseSlot(c, top[i])
    i = i - 1
  }
  c.refScopes.removeAt(c.refScopes.count - 1)
}

/// Release, without closing them, every temporary and local opened since the given depths:
/// what a `return`, `break` or `continue` leaves behind.
func releaseDownTo(c: in LCtx, scopeDepth: in Int, tempDepth: in Int): Unit {
  var t = c.temps.count - 1
  while t >= tempDepth {
    val ts = c.temps[t]
    var k = ts.count - 1
    while k >= 0 {
      releaseRef(c, ts[k].ty, ts[k].value)
      k = k - 1
    }
    t = t - 1
  }
  var s = c.refScopes.count - 1
  while s >= scopeDepth {
    val ss = c.refScopes[s]
    var k = ss.count - 1
    while k >= 0 {
      releaseSlot(c, ss[k])
      k = k - 1
    }
    s = s - 1
  }
}

/// Note that the local `slot` is released when the innermost scope closes.
func trackRef(c: in LCtx, slot: in Slot): Unit {
  if isRefN(slot.ty) {
    c.refScopes[c.refScopes.count - 1].add(slot)
  }
}

/// `x` lowered as a branch of an `if` or a `match` arm: its temporaries close with it, and a
/// reference result is owned so it outlives them.
func branchValue(c: in LCtx, x: in TExpr, wantRef: in Bool): Val {
  pushTemps(c)
  val v = lowerExpr(c, x)
  val r = if wantRef { own(c, v) } else { discard(c, v); v }
  popTemps(c)
  r
}

func primN(k: in TPrimKind): NType {
  match k {
    case TPBool -> NI1
    case TPByte -> NI8
    case TPInt -> NI32
    case TPLong -> NI64
    case TPUInt -> NI32
    case TPULong -> NI64
    case TPNat -> NI64
    case TPFloat -> NFloat
    case TPDouble -> NDouble
    case TPChar -> NI32
    case TPString -> lyricStringNType()
    case TPUnit -> NVoid
  }
}

/// The LLVM type of a scalar `Ty`; None for anything this slice does not lower.
func tyToN(recs: in Map[Int, TirRecLayout], t: in Ty): Option[NType] {
  match t {
    case TPrim(k) -> Some(value = primN(k))
    case TRefined(u, _, _, _) -> tyToN(recs, u)
    case TNever -> Some(value = NVoid)
    case TNamed(sym, args) -> if args.count == 0 {
      match mapGet(recs, sym.id) {
        case Some(r) -> Some(value = r.ty)
        case None -> None
      }
    } else {
      None
    }
    case _ -> None
  }
}

func isFloatTy(t: in Ty): Bool {
  match t {
    case TPrim(k) -> match k { case TPFloat -> true; case TPDouble -> true; case _ -> false }
    case TRefined(u, _, _, _) -> isFloatTy(u)
    case _ -> false
  }
}

func isUnsignedTy(t: in Ty): Bool {
  match t {
    case TPrim(k) -> match k { case TPByte -> true; case TPUInt -> true; case TPULong -> true; case _ -> false }
    case TRefined(u, _, _, _) -> isUnsignedTy(u)
    case _ -> false
  }
}

func bitsOf(t: in NType): Int {
  match t {
    case NI1 -> 1
    case NI8 -> 8
    case NI32 -> 32
    case NI64 -> 64
    case _ -> 0
  }
}

func isNever(t: in Ty): Bool {
  match t {
    case TNever -> true
    case _ -> false
  }
}

func zeroOf(t: in NType): NValue {
  match t {
    case NDouble -> NLitFloat(v = 0.0, ty = NDouble)
    case NFloat -> NLitFloat(v = 0.0, ty = NFloat)
    case NPtr(_) -> NLitNull(ty = t)
    case _ -> NLitInt(v = 0i64, ty = t)
  }
}

func cString(c: in LCtx, text: in String): String {
  val bytes = Encoding.encodeUtf8(text)
  c.ticker.add(0)
  val gname = c.globalPrefix + toString(c.ticker.count)
  c.globals.add(
    NGlobalDef(
      name = gname,
      linkage = "private unnamed_addr constant",
      tyStr = "[" + toString(bytes.length + 1) + " x i8]",
      initStr = "c\"" + escapeIrBytes(bytes) + "\\00\"",
      align = 1
    )
  )
  val ptr = tmp(c)
  c.insns.add(
    NBitcast(
      dest = ptr,
      fromTy = NPtr(pointee = NArray(elem = NI8, size = bytes.length + 1)),
      value = NGlobal(name = gname),
      toTy = NPtr(pointee = NI8)
    )
  )
  ptr
}

func emitPanic(c: in LCtx, msg: in String, line: in Int): Unit {
  val msgPtr = cString(c, msg)
  val filePtr = cString(c, c.env.panicFile)
  val args: List[NArg] = newList()
  args.add(NArg(ty = NPtr(pointee = NI8), value = NLocal(name = msgPtr)))
  args.add(NArg(ty = NPtr(pointee = NI8), value = NLocal(name = filePtr)))
  args.add(NArg(ty = NI32, value = NLitInt(v = line.toLong(), ty = NI32)))
  c.insns.add(NCallVoid(fn = NGlobal(name = "lyric_panic_msg"), args = args))
  c.insns.add(NUnreachable)
  startBlock(c, newLabel(c, "dead"))
}

func divGuard(c: in LCtx, ty: in Ty, nty: in NType, a: in NValue, b: in NValue, line: in Int): Unit {
  val zero = tmp(c)
  c.insns.add(NICmp(dest = zero, pred = IEq, ty = nty, a = b, b = NLitInt(v = 0i64, ty = nty)))
  var bad = zero
  if not isUnsignedTy(ty) {
    val minLit = if bitsOf(nty) == 64 { -9223372036854775807i64 - 1i64 } else { -2147483648i64 }
    val isMin = tmp(c)
    c.insns.add(NICmp(dest = isMin, pred = IEq, ty = nty, a = a, b = NLitInt(v = minLit, ty = nty)))
    val isNeg1 = tmp(c)
    c.insns.add(NICmp(dest = isNeg1, pred = IEq, ty = nty, a = b, b = NLitInt(v = -1i64, ty = nty)))
    val ovf = tmp(c)
    c.insns.add(NAnd(dest = ovf, ty = NI1, a = NLocal(name = isMin), b = NLocal(name = isNeg1)))
    val both = tmp(c)
    c.insns.add(NOr(dest = both, ty = NI1, a = NLocal(name = zero), b = NLocal(name = ovf)))
    bad = both
  }
  val trapL = newLabel(c, "div.trap")
  val okL = newLabel(c, "div.ok")
  c.insns.add(NCondBr(cond = NLocal(name = bad), thenLabel = trapL, elseLabel = okL))
  startBlock(c, trapL)
  emitPanic(c, if isUnsignedTy(ty) { "integer division by zero" } else { "integer division by zero or overflow" }, line)
  c.insns.add(NBr(label = okL))
  startBlock(c, okL)
}

func icmpPred(op: in IntrinsicOp, unsigned: in Bool): Option[ICmpPred] {
  match op {
    case IoEq -> Some(value = IEq)
    case IoNeq -> Some(value = INe)
    case IoLt -> Some(value = if unsigned { IUlt } else { ISlt })
    case IoLte -> Some(value = if unsigned { IUle } else { ISle })
    case IoGt -> Some(value = if unsigned { IUgt } else { ISgt })
    case IoGte -> Some(value = if unsigned { IUge } else { ISge })
    case _ -> None
  }
}

func fcmpPred(op: in IntrinsicOp): Option[FCmpPred] {
  match op {
    case IoEq -> Some(value = FOeq)
    case IoNeq -> Some(value = FUne)
    case IoLt -> Some(value = FOlt)
    case IoLte -> Some(value = FOle)
    case IoGt -> Some(value = FOgt)
    case IoGte -> Some(value = FOge)
    case _ -> None
  }
}

func opName(op: in IntrinsicOp): String {
  match op {
    case IoBuiltin(n) -> "builtin " + n
    case _ -> "operator"
  }
}

/// A binary intrinsic on two scalars of type `ty`; the result is the node's
/// type (`resTy`), which differs from `ty` only for comparisons.
func lowerBinary(
  c: in LCtx, op: in IntrinsicOp, ty: in Ty, nty: in NType, a: in NValue, b: in NValue, line: in Int
): Val {
  val flt = isFloatTy(ty)
  val uns = isUnsignedTy(ty)
  match icmpPred(op, uns) {
    case Some(p) -> {
      val d = tmp(c)
      if flt {
        match fcmpPred(op) {
          case Some(fp) -> c.insns.add(NFCmp(dest = d, pred = fp, ty = nty, a = a, b = b))
          case None -> ()
        }
      } else {
        c.insns.add(NICmp(dest = d, pred = p, ty = nty, a = a, b = b))
      }
      return Val(ty = NI1, value = NLocal(name = d))
    }
    case None -> ()
  }
  val d = tmp(c)
  match op {
    case IoAdd -> c.insns.add(
      if flt { NFAdd(dest = d, ty = nty, a = a, b = b) } else { NAdd(dest = d, ty = nty, a = a, b = b) }
    )
    case IoSub -> c.insns.add(
      if flt { NFSub(dest = d, ty = nty, a = a, b = b) } else { NSub(dest = d, ty = nty, a = a, b = b) }
    )
    case IoMul -> c.insns.add(
      if flt { NFMul(dest = d, ty = nty, a = a, b = b) } else { NMul(dest = d, ty = nty, a = a, b = b) }
    )
    case IoDiv -> {
      if flt {
        c.insns.add(NFDiv(dest = d, ty = nty, a = a, b = b))
      } else {
        divGuard(c, ty, nty, a, b, line)
        c.insns.add(if uns { NUDiv(dest = d, ty = nty, a = a, b = b) } else { NSDiv(dest = d, ty = nty, a = a, b = b) })
      }
    }
    case IoMod -> {
      if flt {
        c.insns.add(NFRem(dest = d, ty = nty, a = a, b = b))
      } else {
        divGuard(c, ty, nty, a, b, line)
        c.insns.add(if uns { NURem(dest = d, ty = nty, a = a, b = b) } else { NSRem(dest = d, ty = nty, a = a, b = b) })
      }
    }
    case IoBitAnd -> c.insns.add(NAnd(dest = d, ty = nty, a = a, b = b))
    case IoBitOr -> c.insns.add(NOr(dest = d, ty = nty, a = a, b = b))
    case IoBitXor -> c.insns.add(NXor(dest = d, ty = nty, a = a, b = b))
    case _ -> return unsupported(c, "intrinsic " + opName(op))
  }
  Val(ty = nty, value = NLocal(name = d))
}

func lowerUnary(c: in LCtx, op: in IntrinsicOp, ty: in Ty, nty: in NType, a: in NValue): Val {
  val d = tmp(c)
  match op {
    case IoNeg -> {
      if isFloatTy(ty) {
        c.insns.add(NFNeg(dest = d, ty = nty, a = a))
      } else {
        c.insns.add(NSub(dest = d, ty = nty, a = zeroOf(nty), b = a))
      }
    }
    case IoNot -> c.insns.add(NXor(dest = d, ty = nty, a = a, b = NLitInt(v = 1i64, ty = nty)))
    case _ -> return unsupported(c, "unary intrinsic " + opName(op))
  }
  Val(ty = nty, value = NLocal(name = d))
}

func assignOp(k: in AssignKind): Option[IntrinsicOp] {
  match k {
    case AkSet -> None
    case AkAdd -> Some(value = IoAdd)
    case AkSub -> Some(value = IoSub)
    case AkMul -> Some(value = IoMul)
    case AkDiv -> Some(value = IoDiv)
    case AkMod -> Some(value = IoMod)
  }
}

func declareSlot(c: in LCtx, d: in LocalDecl): Option[Slot] {
  match tyToN(c.env.recs, d.ty) {
    case None -> {
      c.problems.add("a local of type " + renderTy(d.ty))
      None
    }
    case Some(nt) -> match nt {
      case NVoid -> {
        c.problems.add("a local of type " + renderTy(d.ty))
        None
      }
      case _ -> {
        val name = "s" + toString(d.id.id) + "." + d.name
        c.allocas.add(NAlloca(dest = name, ty = nt))
        val slot = Slot(ptr = name, ty = nt)
        if c.slots.containsKey(d.id.id) {
          c.slots.remove(d.id.id)
        }
        c.slots.add(d.id.id, slot)
        Some(value = slot)
      }
    }
  }
}

func lowerExpr(c: in LCtx, e: in TExpr): Val {
  match e.kind {
    case XLit(lit) -> lowerLit(c, e, lit)
    case XLocal(id) -> match mapGet(c.slots, id.id) {
      case None -> unsupported(c, "a local with no slot")
      case Some(slot) -> {
        val d = tmp(c)
        c.insns.add(NLoad(dest = d, ty = slot.ty, ptr = NLocal(name = slot.ptr)))
        Val(ty = slot.ty, value = NLocal(name = d))
      }
    }
    case XCall(callee, args) -> lowerCall(c, e, callee, args)
    case XConvert(kind, inner) -> lowerConvert(c, e, kind, inner)
    case XIf(cond, t, el) -> lowerIf(c, e, cond, t, el)
    case XBlock(stmts, tail) -> {
      pushRefScope(c)
      for s in stmts {
        lowerStmt(c, s)
      }
      pushTemps(c)
      val v = match tail { case Some(x) -> own(c, lowerExpr(c, x)); case None -> unitVal() }
      popTemps(c)
      popRefScope(c)
      v
    }
    case XShort(op, l, r) -> lowerShort(c, op, l, r)
    case XAssign(place, op, value) -> lowerAssign(c, place, op, value)
    case XMatch(scrut, arms, exhaustive) -> lowerMatch(c, e, scrut, arms, exhaustive)
    case XConstruct(sym, fields) -> lowerConstruct(c, sym, fields)
    case XField(recv, field) -> lowerField(c, recv, field)
    case XCopy(base, updates) -> lowerCopy(c, e, base, updates)
    case _ -> unsupported(c, "expression " + exprKindName(e.kind))
  }
}

func isStructN(t: in NType): Bool {
  match t {
    case NStruct(_, _) -> true
    case _ -> false
  }
}

/// The by-value layout of the record `sym`; a record the code generator did not register
/// by value (a heap record, a union case, a generic) stays on the AST path.
func recLayout(c: in LCtx, sym: in SymbolId): Option[TirRecLayout] {
  match mapGet(c.env.recs, sym.id) {
    case Some(r) -> Some(value = r)
    case None -> {
      c.problems.add("a record or union case (symbol #" + toString(sym.id) + ") that is not a by-value record")
      None
    }
  }
}

/// `insertvalue` of `v` at declaration index `i`: a Unit field has only its placeholder
/// byte, so nothing is stored.
func insertField(c: in LCtx, lay: in TirRecLayout, agg: in NValue, i: in Int, v: in Val): NValue {
  match lay.fieldTys[i] {
    case NVoid -> agg
    case ft -> {
      val d = tmp(c)
      c.insns.add(NInsertValue(dest = d, aggTy = lay.ty, agg = agg, elemTy = ft, elem = v.value, index = i))
      NLocal(name = d)
    }
  }
}

/// A by-value record: an `insertvalue` chain from `undef`, no allocation and no ARC.
/// The fields are evaluated in declaration order.
func lowerConstruct(c: in LCtx, sym: in SymbolId, fields: in List[TExpr]): Val {
  match recLayout(c, sym) {
    case None -> unitVal()
    case Some(lay) -> {
      if fields.count != lay.fieldTys.count {
        return unsupported(
          c,
          "a construction with " + toString(fields.count) + " of " + toString(lay.fieldTys.count) + " fields"
        )
      }
      var cur: NValue = NUndef(ty = lay.ty)
      var i = 0
      while i < fields.count {
        val v = borrow(c, lowerExpr(c, fields[i]))
        cur = insertField(c, lay, cur, i, v)
        i = i + 1
      }
      Val(ty = lay.ty, value = cur)
    }
  }
}

/// A field read: `extractvalue` out of the aggregate.  A Unit field reads as Unit.
func lowerField(c: in LCtx, recv: in TExpr, field: in FieldRef): Val {
  match recLayout(c, field.owner) {
    case None -> unitVal()
    case Some(lay) -> {
      val r = borrow(c, lowerExpr(c, recv))
      if field.index < 0 or field.index >= lay.fieldTys.count {
        return unsupported(c, "field " + field.name + " outside its record's layout")
      }
      match lay.fieldTys[field.index] {
        case NVoid -> unitVal()
        case ft -> {
          val d = tmp(c)
          c.insns.add(NExtractValue(dest = d, aggTy = lay.ty, agg = r.value, index = field.index))
          Val(ty = ft, value = NLocal(name = d))
        }
      }
    }
  }
}

/// `r.copy(f = v, ...)`: the base is evaluated once, then each update is inserted in
/// source order.
func lowerCopy(c: in LCtx, e: in TExpr, base: in TExpr, updates: in List[TFieldUpdate]): Val {
  val owner = match e.ty { case TNamed(sym, _) -> sym; case _ -> return unsupported(c, "a copy of " + renderTy(e.ty)) }
  match recLayout(c, owner) {
    case None -> unitVal()
    case Some(lay) -> {
      var cur = borrow(c, lowerExpr(c, base)).value
      for u in updates {
        val v = borrow(c, lowerExpr(c, u.value))
        if u.field.index < 0 or u.field.index >= lay.fieldTys.count {
          return unsupported(c, "field " + u.field.name + " outside its record's layout")
        }
        cur = insertField(c, lay, cur, u.field.index, v)
      }
      Val(ty = lay.ty, value = cur)
    }
  }
}

func exprKindName(k: in TExprKind): String {
  match k {
    case XLit(_) -> "XLit"
    case XLocal(_) -> "XLocal"
    case XGlobal(_, _) -> "XGlobal"
    case XCall(_, _) -> "XCall"
    case XConstruct(_, _) -> "XConstruct"
    case XField(_, _) -> "XField"
    case XIndex(_, _, _) -> "XIndex"
    case XConvert(_, _) -> "XConvert"
    case XTuple(_) -> "XTuple"
    case XListLit(_) -> "XListLit"
    case XInterp(_) -> "XInterp"
    case XRange(_, _, _) -> "XRange"
    case XShort(_, _, _) -> "XShort"
    case XIf(_, _, _) -> "XIf"
    case XMatch(_, _, _) -> "XMatch"
    case XBlock(_, _) -> "XBlock"
    case XUnsafe(_) -> "XUnsafe"
    case XLambda(_, _, _) -> "XLambda"
    case XAwait(_) -> "XAwait"
    case XSpawn(_) -> "XSpawn"
    case XYield(_) -> "XYield"
    case XPropagate(_) -> "XPropagate"
    case XOld(_) -> "XOld"
    case XResult -> "XResult"
    case XForall(_, _, _) -> "XForall"
    case XExists(_, _, _) -> "XExists"
    case XAssign(_, _, _) -> "XAssign"
    case XCopy(_, _) -> "XCopy"
    case _ -> "an expression kind added after this lowering was written"
  }
}

/// An unsigned literal above the signed maximum of its width (a `UInt` of
/// 4294967295) as the two's-complement value LLVM stores.
func wrapLit(v: in Long, nt: in NType): Long {
  match nt {
    case NI32 -> if v > 2147483647i64 { v - 4294967296i64 } else { v }
    case NI8 -> if v > 127i64 { v - 256i64 } else { v }
    case _ -> v
  }
}

/// A static `LyricString` (its count is the immortal sentinel, so retaining or releasing it is
/// a no-op); a borrowed value.
func stringLiteral(c: in LCtx, text: in String): Val {
  val bytes = Encoding.encodeUtf8(text)
  val n = bytes.length
  c.ticker.add(0)
  val gname = c.globalPrefix + "s" + toString(c.ticker.count)
  val data = "[" + toString(n + 1) + " x i8]"
  c.globals.add(
    NGlobalDef(
      name = gname,
      linkage = "private unnamed_addr constant",
      tyStr = "{ i32, i32, i8*, i64, i64, " + data + " }",
      initStr = "{ i32 2147483647, i32 0, i8* null, i64 " + toString(n) + ", i64 " + toString(n + 1) + ", " + data +
        " c\"" +
        escapeIrBytes(bytes) +
        "\\00\" }",
      align = 8
    )
  )
  val litFields: List[NType] = newList()
  addArcHeader(litFields)
  litFields.add(NI64)
  litFields.add(NI64)
  litFields.add(NArray(elem = NI8, size = n + 1))
  val d = tmp(c)
  c.insns.add(
    NBitcast(
      dest = d,
      fromTy = NPtr(pointee = NLitStruct(fields = litFields)),
      value = NGlobal(name = gname),
      toTy = lyricStringNType()
    )
  )
  Val(ty = lyricStringNType(), value = NLocal(name = d))
}

func lowerLit(c: in LCtx, e: in TExpr, lit: in TLit): Val {
  match lit {
    case TLUnit -> unitVal()
    case TLBool(b) -> Val(ty = NI1, value = NLitInt(v = if b { 1i64 } else { 0i64 }, ty = NI1))
    case TLChar(cp) -> Val(ty = NI32, value = NLitInt(v = cp.toLong(), ty = NI32))
    case TLString(text) -> stringLiteral(c, text)
    case TLInt(v) -> match tyToN(c.env.recs, e.ty) {
      case None -> unsupported(c, "an integer literal of type " + renderTy(e.ty))
      case Some(nt) -> if isFloatTy(e.ty) {
        Val(ty = nt, value = NLitFloat(v = v.toDouble(), ty = nt))
      } else {
        Val(ty = nt, value = NLitInt(v = wrapLit(v, nt), ty = nt))
      }
    }
    case TLFloat(v) -> match tyToN(c.env.recs, e.ty) {
      case None -> unsupported(c, "a float literal of type " + renderTy(e.ty))
      case Some(nt) -> Val(ty = nt, value = NLitFloat(v = v, ty = nt))
    }
  }
}

func lowerCall(c: in LCtx, e: in TExpr, callee: in Callee, args: in List[TArg]): Val {
  val line = e.span.startPos.line
  match callee {
    case Intrinsic(op) -> {
      val ins: List[TExpr] = newList()
      for a in args {
        match a {
          case TArgIn(v) -> ins.add(v)
          case _ -> {
            c.problems.add("an out argument of an operator")
          }
        }
      }
      match op {
        case IoBuiltin(name) -> return lowerBuiltin(c, name, ins)
        case _ -> ()
      }
      if ins.count == 2 {
        val a = borrow(c, lowerExpr(c, ins[0]))
        val b = borrow(c, lowerExpr(c, ins[1]))
        if isStringN(a.ty) {
          return lowerStringBinary(c, op, a, b)
        }
        match tyToN(c.env.recs, ins[0].ty) {
          case Some(nt) -> if isStructN(nt) {
            unsupported(c, "an operator on " + renderTy(ins[0].ty))
          } else {
            lowerBinary(c, op, ins[0].ty, nt, a.value, b.value, line)
          }
          case None -> unsupported(c, "an operator on " + renderTy(ins[0].ty))
        }
      } else if ins.count == 1 {
        val a = borrow(c, lowerExpr(c, ins[0]))
        match tyToN(c.env.recs, ins[0].ty) {
          case Some(nt) -> if isStructN(nt) {
            unsupported(c, "an operator on " + renderTy(ins[0].ty))
          } else {
            lowerUnary(c, op, ins[0].ty, nt, a.value)
          }
          case None -> unsupported(c, "an operator on " + renderTy(ins[0].ty))
        }
      } else {
        unsupported(c, "intrinsic " + opName(op))
      }
    }
    case Direct(sym, targs) -> {
      if targs.count > 0 {
        return unsupported(c, "a generic call")
      }
      match mapGet(c.env.fnNames, sym.id) {
        case None -> unsupported(c, "a call with no IR name (symbol #" + toString(sym.id) + ")")
        case Some(irName) -> {
          val nargs: List[NArg] = newList()
          for a in args {
            match a {
              case TArgIn(v) -> {
                val av = borrow(c, lowerExpr(c, v))
                match av.ty {
                  case NVoid -> c.problems.add("a Unit argument")
                  case _ -> nargs.add(NArg(ty = av.ty, value = av.value))
                }
              }
              case _ -> {
                c.problems.add("an out or inout argument")
              }
            }
          }
          match tyToN(c.env.recs, e.ty) {
            case None -> unsupported(c, "a call returning " + renderTy(e.ty))
            case Some(rt) -> match rt {
              case NVoid -> {
                c.insns.add(NCallVoid(fn = NGlobal(name = irName), args = nargs))
                unitVal()
              }
              case _ -> {
                val d = tmp(c)
                c.insns.add(NCall(dest = d, retTy = rt, fn = NGlobal(name = irName), args = nargs))
                Val(ty = rt, value = NLocal(name = d), owned = isRefN(rt))
              }
            }
          }
        }
      }
    }
    case _ -> unsupported(c, "a call through " + calleeKind(callee))
  }
}

/// `toString` of a scalar: the runtime's formatter, a fresh owned string.
func scalarToString(c: in LCtx, ty: in Ty, v: in Val): Val {
  val sTy = lyricStringNType()
  val uns = isUnsignedTy(ty)
  val isChar = match ty { case TPrim(k) -> match k { case TPChar -> true; case _ -> false }; case _ -> false }
  val r = match v.ty {
    case NI32 -> {
      if isChar {
        callRt(c, "lyric_string_from_char", sTy, arg1(NI32, v.value))
      } else {
        val wide = tmp(c)
        if uns {
          c.insns.add(NZExt(dest = wide, fromTy = NI32, value = v.value, toTy = NI64))
        } else {
          c.insns.add(NSExt(dest = wide, fromTy = NI32, value = v.value, toTy = NI64))
        }
        callRt(c, "lyric_string_from_int", sTy, arg1(NI64, NLocal(name = wide)))
      }
    }
    case NI64 -> callRt(
      c,
      if uns { "lyric_string_from_uint" } else { "lyric_string_from_int" },
      sTy,
      arg1(NI64, v.value)
    )
    case NI8 -> {
      val wide = tmp(c)
      c.insns.add(NZExt(dest = wide, fromTy = NI8, value = v.value, toTy = NI64))
      callRt(c, "lyric_string_from_int", sTy, arg1(NI64, NLocal(name = wide)))
    }
    case NI1 -> {
      val wide = tmp(c)
      c.insns.add(NZExt(dest = wide, fromTy = NI1, value = v.value, toTy = NI32))
      callRt(c, "lyric_string_from_bool", sTy, arg1(NI32, NLocal(name = wide)))
    }
    case NDouble -> callRt(c, "lyric_string_from_float", sTy, arg1(NDouble, v.value))
    case NFloat -> callRt(c, "lyric_string_from_float32", sTy, arg1(NFloat, v.value))
    case _ -> {
      c.problems.add("toString of " + renderTy(ty))
      NUndef(ty = sTy)
    }
  }
  Val(ty = sTy, value = r, owned = true)
}

/// The compiler's named built-ins (`IoBuiltin`): `println`, `print`, `toString` (also spelled `<Type>.toString` for the
/// method form) and `String.length`.
/// Any other name is outside this slice.
func lowerBuiltin(c: in LCtx, name: in String, ins: in List[TExpr]): Val {
  if ins.count != 1 {
    return unsupported(c, "builtin " + name + " with " + toString(ins.count) + " arguments")
  }
  val arg = ins[0]
  if name == "println" or name == "print" {
    val a = borrow(c, lowerExpr(c, arg))
    val text = if isStringN(a.ty) { a } else { borrow(c, scalarToString(c, arg.ty, a)) }
    val sTy = lyricStringNType()
    callRtVoid(
      c,
      if name == "println" { "lyric_console_write_line" } else { "lyric_console_write" },
      arg2(NI32, NLitInt(v = 1i64, ty = NI32), sTy, text.value)
    )
    return unitVal()
  }
  if name == "toString" or Str.endsWith(name, ".toString") {
    val a = lowerExpr(c, arg)
    if isStringN(a.ty) {
      return a
    }
    return scalarToString(c, arg.ty, a)
  }
  if name == "String.length" {
    val a = borrow(c, lowerExpr(c, arg))
    val n = callRt(c, "lyric_string_len", NI64, arg1(lyricStringNType(), a.value))
    val d = tmp(c)
    c.insns.add(NTrunc(dest = d, fromTy = NI64, value = n, toTy = NI32))
    return Val(ty = NI32, value = NLocal(name = d))
  }
  unsupported(c, "builtin " + name)
}

/// `+`, `==`, `!=` and the orderings on two borrowed strings.
func lowerStringBinary(c: in LCtx, op: in IntrinsicOp, a: in Val, b: in Val): Val {
  val sTy = lyricStringNType()
  match op {
    case IoAdd -> Val(
      ty = sTy,
      value = callRt(c, "lyric_string_concat", sTy, arg2(sTy, a.value, sTy, b.value)),
      owned = true
    )
    case IoEq -> stringEq(c, a, b, false)
    case IoNeq -> stringEq(c, a, b, true)
    case IoLt -> stringCmp(c, ISlt, a, b)
    case IoLte -> stringCmp(c, ISle, a, b)
    case IoGt -> stringCmp(c, ISgt, a, b)
    case IoGte -> stringCmp(c, ISge, a, b)
    case _ -> unsupported(c, "a string operator")
  }
}

func stringEq(c: in LCtx, a: in Val, b: in Val, negate: in Bool): Val {
  val sTy = lyricStringNType()
  val r = callRt(c, "lyric_string_eq", NI32, arg2(sTy, a.value, sTy, b.value))
  val d = tmp(c)
  c.insns.add(
    NICmp(dest = d, pred = if negate { IEq } else { INe }, ty = NI32, a = r, b = NLitInt(v = 0i64, ty = NI32))
  )
  Val(ty = NI1, value = NLocal(name = d))
}

func stringCmp(c: in LCtx, pred: in ICmpPred, a: in Val, b: in Val): Val {
  val sTy = lyricStringNType()
  val r = callRt(c, "lyric_string_cmp", NI32, arg2(sTy, a.value, sTy, b.value))
  val d = tmp(c)
  c.insns.add(NICmp(dest = d, pred = pred, ty = NI32, a = r, b = NLitInt(v = 0i64, ty = NI32)))
  Val(ty = NI1, value = NLocal(name = d))
}

func calleeKind(k: in Callee): String {
  match k {
    case Direct(_, _) -> "a direct callee"
    case Interface(_, _, _, _) -> "an interface method"
    case Indirect(_) -> "a function value"
    case Extern(_) -> "an extern member"
    case Intrinsic(_) -> "an intrinsic"
  }
}

func lowerConvert(c: in LCtx, e: in TExpr, kind: in ConvKind, inner: in TExpr): Val {
  match kind {
    case CvUnrefine -> lowerExpr(c, inner)
    case CvFromNever -> {
      val _ = lowerExpr(c, inner)
      match tyToN(c.env.recs, e.ty) {
        case Some(nt) -> Val(ty = nt, value = NUndef(ty = nt))
        case None -> unsupported(c, "a conversion from Never to " + renderTy(e.ty))
      }
    }
    case CvWiden(_) -> {
      val v = lowerExpr(c, inner)
      match tyToN(c.env.recs, e.ty) {
        case None -> unsupported(c, "a widening to " + renderTy(e.ty))
        case Some(to) -> lowerWiden(c, inner.ty, v, to)
      }
    }
    case _ -> unsupported(c, "a conversion")
  }
}

func lowerWiden(c: in LCtx, fromTy: in Ty, v: in Val, to: in NType): Val {
  val d = tmp(c)
  val fb = bitsOf(v.ty)
  val tb = bitsOf(to)
  if isFloatTy(fromTy) {
    match v.ty {
      case NFloat -> match to {
        case NDouble -> {
          c.insns.add(NFPExt(dest = d, value = v.value))
          return Val(ty = to, value = NLocal(name = d))
        }
        case _ -> ()
      }
      case _ -> ()
    }
    return unsupported(c, "a float conversion")
  }
  if fb == 0 {
    return unsupported(c, "a widening of a non-integer")
  }
  match to {
    case NDouble -> toFloat(c, fromTy, v, to, d)
    case NFloat -> toFloat(c, fromTy, v, to, d)
    case _ -> {
      if tb == fb {
        Val(ty = to, value = v.value)
      } else if tb > fb {
        if isUnsignedTy(fromTy) or fb == 1 {
          c.insns.add(NZExt(dest = d, fromTy = v.ty, value = v.value, toTy = to))
        } else {
          c.insns.add(NSExt(dest = d, fromTy = v.ty, value = v.value, toTy = to))
        }
        Val(ty = to, value = NLocal(name = d))
      } else {
        unsupported(c, "a narrowing conversion")
      }
    }
  }
}

func toFloat(c: in LCtx, fromTy: in Ty, v: in Val, to: in NType, d: in String): Val {
  if isUnsignedTy(fromTy) {
    return unsupported(c, "an unsigned to float conversion")
  }
  c.insns.add(NSIToFP(dest = d, fromTy = v.ty, value = v.value, toTy = to))
  Val(ty = to, value = NLocal(name = d))
}

func lowerIf(c: in LCtx, e: in TExpr, cond: in TExpr, t: in TExpr, el: in Option[TExpr]): Val {
  pushTemps(c)
  val cv = lowerExpr(c, cond)
  popTemps(c)
  val wantRef = match tyToN(c.env.recs, e.ty) { case Some(nt) -> isRefN(nt); case None -> false }
  val thenL = newLabel(c, "if.then")
  val elseL = newLabel(c, "if.else")
  val endL = newLabel(c, "if.end")
  c.insns.add(NCondBr(cond = cv.value, thenLabel = thenL, elseLabel = elseL))
  startBlock(c, thenL)
  val tv = branchValue(c, t, wantRef)
  val thenEnd = curBlock(c)
  c.insns.add(NBr(label = endL))
  startBlock(c, elseL)
  val ev = match el { case Some(x) -> branchValue(c, x, wantRef); case None -> unitVal() }
  val elseEnd = curBlock(c)
  c.insns.add(NBr(label = endL))
  startBlock(c, endL)
  match tyToN(c.env.recs, e.ty) {
    case None -> unsupported(c, "an if of type " + renderTy(e.ty))
    case Some(nt) -> match nt {
      case NVoid -> unitVal()
      case _ -> {
        val d = tmp(c)
        val inc: List[NPhiIncoming] = newList()
        inc.add(NPhiIncoming(value = tv.value, label = thenEnd))
        inc.add(NPhiIncoming(value = ev.value, label = elseEnd))
        c.insns.add(NPhi(dest = d, ty = nt, incoming = inc))
        Val(ty = nt, value = NLocal(name = d), owned = isRefN(nt))
      }
    }
  }
}

func lowerShort(c: in LCtx, op: in ShortOp, l: in TExpr, r: in TExpr): Val {
  val isAnd = match op {
    case ShAnd -> true
    case ShOr -> false
    case _ -> return unsupported(c, "a short-circuit operator")
  }
  val lv = lowerExpr(c, l)
  val lhsEnd = curBlock(c)
  val rhsL = newLabel(c, "sc.rhs")
  val endL = newLabel(c, "sc.end")
  if isAnd {
    c.insns.add(NCondBr(cond = lv.value, thenLabel = rhsL, elseLabel = endL))
  } else {
    c.insns.add(NCondBr(cond = lv.value, thenLabel = endL, elseLabel = rhsL))
  }
  startBlock(c, rhsL)
  pushTemps(c)
  val rv = lowerExpr(c, r)
  popTemps(c)
  val rhsEnd = curBlock(c)
  c.insns.add(NBr(label = endL))
  startBlock(c, endL)
  val d = tmp(c)
  val inc: List[NPhiIncoming] = newList()
  inc.add(NPhiIncoming(value = NLitInt(v = if isAnd { 0i64 } else { 1i64 }, ty = NI1), label = lhsEnd))
  inc.add(NPhiIncoming(value = rv.value, label = rhsEnd))
  c.insns.add(NPhi(dest = d, ty = NI1, incoming = inc))
  Val(ty = NI1, value = NLocal(name = d))
}

/// `x = e` and `x += e` on a reference local: the new value is owned, the previous one released.
/// Only a tracked local reaches here: the checker rejects an assignment to an `in` parameter,
/// whose slot holds a borrow this code must not release.
func assignRef(c: in LCtx, slot: in Slot, op: in AssignKind, value: in TExpr): Val {
  val prev = tmp(c)
  c.insns.add(NLoad(dest = prev, ty = slot.ty, ptr = NLocal(name = slot.ptr)))
  val rhs = lowerExpr(c, value)
  val nv = match op {
    case AkSet -> own(c, rhs)
    case AkAdd -> {
      val r = borrow(c, rhs)
      lowerStringBinary(c, IoAdd, Val(ty = slot.ty, value = NLocal(name = prev)), r)
    }
    case _ -> unsupported(c, "a compound assignment on a reference")
  }
  c.insns.add(NStore(ty = slot.ty, value = nv.value, ptr = NLocal(name = slot.ptr)))
  releaseRef(c, slot.ty, NLocal(name = prev))
  unitVal()
}

func lowerAssign(c: in LCtx, place: in TPlace, op: in AssignKind, value: in TExpr): Val {
  match place.kind {
    case PlLocal(id) -> match mapGet(c.slots, id.id) {
      case None -> unsupported(c, "an assignment to a local with no slot")
      case Some(slot) -> {
        if isRefN(slot.ty) {
          return assignRef(c, slot, op, value)
        }
        val rhs = lowerExpr(c, value)
        match assignOp(op) {
          case None -> c.insns.add(NStore(ty = slot.ty, value = rhs.value, ptr = NLocal(name = slot.ptr)))
          case Some(iop) -> {
            val cur = tmp(c)
            c.insns.add(NLoad(dest = cur, ty = slot.ty, ptr = NLocal(name = slot.ptr)))
            val res = lowerBinary(c, iop, place.ty, slot.ty, NLocal(name = cur), rhs.value, value.span.startPos.line)
            c.insns.add(NStore(ty = slot.ty, value = res.value, ptr = NLocal(name = slot.ptr)))
          }
        }
        unitVal()
      }
    }
    case _ -> unsupported(c, "an assignment to a field, element or global")
  }
}

func litValue(l: in TLit): Option[Long] {
  match l {
    case TLInt(v) -> Some(value = v)
    case TLChar(cp) -> Some(value = cp.toLong())
    case TLBool(b) -> Some(value = if b { 1i64 } else { 0i64 })
    case _ -> None
  }
}

func trueV(): Val {
  Val(ty = NI1, value = NLitInt(v = 1i64, ty = NI1))
}

func andV(c: in LCtx, a: in Val, b: in Val): Val {
  val d = tmp(c)
  c.insns.add(NAnd(dest = d, ty = NI1, a = a.value, b = b.value))
  Val(ty = NI1, value = NLocal(name = d))
}

func orV(c: in LCtx, a: in Val, b: in Val): Val {
  val d = tmp(c)
  c.insns.add(NOr(dest = d, ty = NI1, a = a.value, b = b.value))
  Val(ty = NI1, value = NLocal(name = d))
}

/// Whether `pat` binds a local anywhere inside it.
func patBinds(pat: in TPat): Bool {
  match pat.kind {
    case TpBind(_, _) -> true
    case TpOr(alts) -> {
      for a in alts {
        if patBinds(a) {
          return true
        }
      }
      false
    }
    case _ -> false
  }
}

/// The `i1` that says whether `scrut` matches `pat`; only scalar patterns.
func patTest(c: in LCtx, pat: in TPat, scrut: in Val, sty: in Ty): Val {
  match pat.kind {
    case TpWild -> trueV()
    case TpBind(_, inner) -> match inner { case None -> trueV(); case Some(p) -> patTest(c, p, scrut, sty) }
    case TpLit(l) -> match litValue(l) {
      case Some(v) -> {
        val d = tmp(c)
        c.insns.add(
          NICmp(dest = d, pred = IEq, ty = scrut.ty, a = scrut.value, b = NLitInt(v = wrapLit(v, scrut.ty), ty = scrut.ty))
        )
        Val(ty = NI1, value = NLocal(name = d))
      }
      case None -> unsupported(c, "a non-integer literal pattern")
    }
    case TpRange(lo, hi, inclusive) -> match litValue(lo) {
      case None -> unsupported(c, "a non-integer range pattern")
      case Some(lv) -> match litValue(hi) {
        case None -> unsupported(c, "a non-integer range pattern")
        case Some(hv) -> {
          val uns = isUnsignedTy(sty)
          val geLo = tmp(c)
          c.insns.add(
            NICmp(
              dest = geLo,
              pred = if uns { IUge } else { ISge },
              ty = scrut.ty,
              a = scrut.value,
              b = NLitInt(v = wrapLit(lv, scrut.ty), ty = scrut.ty)
            )
          )
          val cmpHi = tmp(c)
          val hiPred = if inclusive { if uns { IUle } else { ISle } } else { if uns { IUlt } else { ISlt } }
          c.insns.add(
            NICmp(
              dest = cmpHi,
              pred = hiPred,
              ty = scrut.ty,
              a = scrut.value,
              b = NLitInt(v = wrapLit(hv, scrut.ty), ty = scrut.ty)
            )
          )
          andV(c, Val(ty = NI1, value = NLocal(name = geLo)), Val(ty = NI1, value = NLocal(name = cmpHi)))
        }
      }
    }
    case TpOr(alts) -> {
      var acc = patTest(c, alts[0], scrut, sty)
      var i = 1
      while i < alts.count {
        acc = orV(c, acc, patTest(c, alts[i], scrut, sty))
        i = i + 1
      }
      acc
    }
    case _ -> unsupported(c, "a pattern of this kind")
  }
}

/// Store the scrutinee into the locals `pat` binds.
func patBind(c: in LCtx, pat: in TPat, scrut: in Val): Unit {
  match pat.kind {
    case TpBind(decl, inner) -> {
      match declareSlot(c, decl) {
        case Some(slot) -> c.insns.add(NStore(ty = slot.ty, value = scrut.value, ptr = NLocal(name = slot.ptr)))
        case None -> ()
      }
      match inner {
        case Some(p) -> patBind(c, p, scrut)
        case None -> ()
      }
    }
    case _ -> ()
  }
}

func lowerMatch(c: in LCtx, e: in TExpr, scrutE: in TExpr, arms: in List[TArm], exhaustive: in Bool): Val {
  if not exhaustive {
    return unsupported(c, "a match the builder did not prove exhaustive")
  }
  if arms.count == 0 {
    return unsupported(c, "a match with no arms")
  }
  val scrut = lowerExpr(c, scrutE)
  match scrut.ty {
    case NVoid -> return unsupported(c, "a match on a non-scalar")
    case _ -> ()
  }
  if isRefN(scrut.ty) {
    return unsupported(c, "a match on a reference value")
  }
  val wantRef = match tyToN(c.env.recs, e.ty) { case Some(nt) -> isRefN(nt); case None -> false }
  match tyToN(c.env.recs, scrutE.ty) {
    case None -> return unsupported(c, "a match on " + renderTy(scrutE.ty))
    case Some(_) -> ()
  }
  val resN = tyToN(c.env.recs, e.ty)
  val endL = newLabel(c, "match.end")
  val incoming: List[NPhiIncoming] = newList()
  var i = 0
  while i < arms.count {
    val arm = arms[i]
    if patBinds(arm.pat) {
      match arm.pat.kind {
        case TpOr(_) -> c.problems.add("an or-pattern that binds")
        case _ -> ()
      }
    }
    val test = patTest(c, arm.pat, scrut, scrutE.ty)
    val bindL = newLabel(c, "arm.bind")
    val nextL = newLabel(c, "arm.next")
    c.insns.add(NCondBr(cond = test.value, thenLabel = bindL, elseLabel = nextL))
    startBlock(c, bindL)
    patBind(c, arm.pat, scrut)
    val bodyL = newLabel(c, "arm.body")
    match arm.guard {
      case Some(g) -> {
        pushTemps(c)
        val gv = lowerExpr(c, g)
        popTemps(c)
        c.insns.add(NCondBr(cond = gv.value, thenLabel = bodyL, elseLabel = nextL))
      }
      case None -> c.insns.add(NBr(label = bodyL))
    }
    startBlock(c, bodyL)
    val bv = branchValue(c, arm.body, wantRef)
    incoming.add(NPhiIncoming(value = bv.value, label = curBlock(c)))
    c.insns.add(NBr(label = endL))
    startBlock(c, nextL)
    i = i + 1
  }
  emitPanic(c, "non-exhaustive match", e.span.startPos.line)
  match resN {
    case Some(nt) -> incoming.add(NPhiIncoming(value = NUndef(ty = nt), label = curBlock(c)))
    case None -> ()
  }
  c.insns.add(NBr(label = endL))
  startBlock(c, endL)
  match resN {
    case None -> unsupported(c, "a match of type " + renderTy(e.ty))
    case Some(nt) -> match nt {
      case NVoid -> unitVal()
      case _ -> {
        val d = tmp(c)
        c.insns.add(NPhi(dest = d, ty = nt, incoming = incoming))
        Val(ty = nt, value = NLocal(name = d), owned = isRefN(nt))
      }
    }
  }
}

func lowerFor(c: in LCtx, label: in Option[String], pat: in TPat, iter: in TExpr, body: in TExpr): Unit {
  match iter.kind {
    case XRange(lo, hi, inclusive) -> {
      val lov = lowerExpr(c, lo)
      val hiv = lowerExpr(c, hi)
      match tyToN(c.env.recs, lo.ty) {
        case None -> {
          c.problems.add("a for over " + renderTy(lo.ty))
          return
        }
        case Some(nt) -> {
          if bitsOf(nt) == 0 {
            c.problems.add("a for over " + renderTy(lo.ty))
            return
          }
          val uns = isUnsignedTy(lo.ty)
          val slotName = "for" + toString(c.ticker.count + 1) + ".i"
          c.ticker.add(0)
          c.allocas.add(NAlloca(dest = slotName, ty = nt))
          c.insns.add(NStore(ty = nt, value = lov.value, ptr = NLocal(name = slotName)))
          val condL = newLabel(c, "for.cond")
          val bodyL = newLabel(c, "for.body")
          val stepL = newLabel(c, "for.step")
          val endL = newLabel(c, "for.end")
          c.insns.add(NBr(label = condL))
          startBlock(c, condL)
          val cur = tmp(c)
          c.insns.add(NLoad(dest = cur, ty = nt, ptr = NLocal(name = slotName)))
          val pred = if inclusive { if uns { IUle } else { ISle } } else { if uns { IUlt } else { ISlt } }
          val ok = tmp(c)
          c.insns.add(NICmp(dest = ok, pred = pred, ty = nt, a = NLocal(name = cur), b = hiv.value))
          c.insns.add(NCondBr(cond = NLocal(name = ok), thenLabel = bodyL, elseLabel = endL))
          startBlock(c, bodyL)
          patBind(c, pat, Val(ty = nt, value = NLocal(name = cur)))
          c.loops.add(
            LoopLabels(label = label, breakL = endL, contL = stepL, scopeDepth = c.refScopes.count, tempDepth = c.temps.count)
          )
          discard(c, lowerExpr(c, body))
          c.loops.removeAt(c.loops.count - 1)
          c.insns.add(NBr(label = stepL))
          startBlock(c, stepL)
          val at = tmp(c)
          c.insns.add(NLoad(dest = at, ty = nt, ptr = NLocal(name = slotName)))
          if inclusive {
            val last = tmp(c)
            c.insns.add(NICmp(dest = last, pred = IEq, ty = nt, a = NLocal(name = at), b = hiv.value))
            val incL = newLabel(c, "for.inc")
            c.insns.add(NCondBr(cond = NLocal(name = last), thenLabel = endL, elseLabel = incL))
            startBlock(c, incL)
          }
          val next = tmp(c)
          c.insns.add(NAdd(dest = next, ty = nt, a = NLocal(name = at), b = NLitInt(v = 1i64, ty = nt)))
          c.insns.add(NStore(ty = nt, value = NLocal(name = next), ptr = NLocal(name = slotName)))
          c.insns.add(NBr(label = condL))
          startBlock(c, endL)
        }
      }
    }
    case _ -> {
      c.problems.add("a for over " + renderTy(iter.ty))
    }
  }
}

func lowerStmt(c: in LCtx, s: in TStmt): Unit {
  pushTemps(c)
  lowerStmtInner(c, s)
  popTemps(c)
}

func lowerStmtInner(c: in LCtx, s: in TStmt): Unit {
  match s.kind {
    case TsExpr(x) -> discard(c, lowerExpr(c, x))
    case TsVar(decl, init) -> match declareSlot(c, decl) {
      case None -> ()
      case Some(slot) -> {
        val v = match init {
          case Some(x) -> own(c, lowerExpr(c, x))
          case None -> Val(ty = slot.ty, value = zeroOf(slot.ty))
        }
        c.insns.add(NStore(ty = slot.ty, value = v.value, ptr = NLocal(name = slot.ptr)))
        trackRef(c, slot)
      }
    }
    case TsLet(pat, init) -> match pat.kind {
      case TpWild -> discard(c, lowerExpr(c, init))
      case TpBind(decl, inner) -> match inner {
        case Some(_) -> {
          c.problems.add("a binding with a sub-pattern")
        }
        case None -> match declareSlot(c, decl) {
          case None -> ()
          case Some(slot) -> {
            val v = own(c, lowerExpr(c, init))
            c.insns.add(NStore(ty = slot.ty, value = v.value, ptr = NLocal(name = slot.ptr)))
            trackRef(c, slot)
          }
        }
      }
      case _ -> {
        c.problems.add("a destructuring let")
      }
    }
    case TsReturn(value) -> {
      match value {
        case Some(x) -> {
          val v = lowerExpr(c, x)
          match c.retTy {
            case NVoid -> {
              discard(c, v)
              releaseDownTo(c, 0, 0)
              c.insns.add(NRetVoid)
            }
            case rt -> {
              val ov = own(c, v)
              releaseDownTo(c, 0, 0)
              c.insns.add(NRet(ty = rt, value = ov.value))
            }
          }
        }
        case None -> {
          releaseDownTo(c, 0, 0)
          c.insns.add(NRetVoid)
        }
      }
      startBlock(c, newLabel(c, "dead"))
    }
    case TsWhile(label, cond, body) -> {
      val condL = newLabel(c, "while.cond")
      val bodyL = newLabel(c, "while.body")
      val endL = newLabel(c, "while.end")
      c.insns.add(NBr(label = condL))
      startBlock(c, condL)
      pushTemps(c)
      val cv = lowerExpr(c, cond)
      popTemps(c)
      c.insns.add(NCondBr(cond = cv.value, thenLabel = bodyL, elseLabel = endL))
      startBlock(c, bodyL)
      c.loops.add(
        LoopLabels(label = label, breakL = endL, contL = condL, scopeDepth = c.refScopes.count, tempDepth = c.temps.count)
      )
      discard(c, lowerExpr(c, body))
      c.loops.removeAt(c.loops.count - 1)
      c.insns.add(NBr(label = condL))
      startBlock(c, endL)
    }
    case TsLoop(label, body) -> {
      val bodyL = newLabel(c, "loop.body")
      val endL = newLabel(c, "loop.end")
      c.insns.add(NBr(label = bodyL))
      startBlock(c, bodyL)
      c.loops.add(
        LoopLabels(label = label, breakL = endL, contL = bodyL, scopeDepth = c.refScopes.count, tempDepth = c.temps.count)
      )
      discard(c, lowerExpr(c, body))
      c.loops.removeAt(c.loops.count - 1)
      c.insns.add(NBr(label = bodyL))
      startBlock(c, endL)
    }
    case TsFor(label, pat, iter, body) -> lowerFor(c, label, pat, iter, body)
    case TsBreak(label) -> jumpLoop(c, label, true)
    case TsContinue(label) -> jumpLoop(c, label, false)
    case _ -> {
      c.problems.add("statement " + stmtKindName(s.kind))
    }
  }
}

func stmtKindName(k: in TStmtKind): String {
  match k {
    case TsLet(_, _) -> "TsLet"
    case TsVar(_, _) -> "TsVar"
    case TsExpr(_) -> "TsExpr"
    case TsReturn(_) -> "TsReturn"
    case TsBreak(_) -> "TsBreak"
    case TsContinue(_) -> "TsContinue"
    case TsThrow(_) -> "TsThrow"
    case TsTry(_, _, _) -> "TsTry"
    case TsDefer(_) -> "TsDefer"
    case TsScope(_, _) -> "TsScope"
    case TsFor(_, _, _, _) -> "TsFor"
    case TsWhile(_, _, _) -> "TsWhile"
    case TsLoop(_, _) -> "TsLoop"
    case TsInvariant(_) -> "TsInvariant"
    case _ -> "a statement kind added after this lowering was written"
  }
}

func jumpLoop(c: in LCtx, label: in Option[String], isBreak: in Bool): Unit {
  var i = c.loops.count - 1
  while i >= 0 {
    val lp = c.loops[i]
    val hit = match label {
      case None -> true
      case Some(want) -> match lp.label { case Some(have) -> have == want; case None -> false }
    }
    if hit {
      releaseDownTo(c, lp.scopeDepth, lp.tempDepth)
      c.insns.add(NBr(label = if isBreak { lp.breakL } else { lp.contL }))
      startBlock(c, newLabel(c, "dead"))
      return
    }
    i = i - 1
  }
  c.problems.add("a break or continue outside a loop")
}

func fallback(sym: in SymbolId, why: in String): Result[TirLowered, TirFallback] {
  Err(error = TirFallback(sym = sym, reason = why))
}

/// Lower `fn`, a monomorphic function with a body.  `Err` names the first
/// construct this slice does not cover; the caller keeps the AST path's
/// lowering of `fn` and counts the fallback.
pub func lowerTirFunction(env: in TirLowerEnv, fn: in TFnDecl): Result[TirLowered, TirFallback] {
  if fn.typeParams.count > 0 {
    return fallback(fn.sym, "a generic function")
  }
  if fn.isAsync {
    return fallback(fn.sym, "an async function")
  }
  if fn.preconds.count > 0 or fn.postconds.count > 0 {
    return fallback(fn.sym, "contracts (docs/70 phase 3c elaborates them)")
  }
  val irName = match mapGet(env.fnNames, fn.sym.id) {
    case Some(n) -> n
    case None -> return fallback(fn.sym, "no IR name for symbol #" + toString(fn.sym.id))
  }
  val body = match fn.body { case Some(b) -> b; case None -> return fallback(fn.sym, "no body") }
  val retTy = match tyToN(env.recs, fn.ret) {
    case Some(t) -> t
    case None -> return fallback(fn.sym, "return type " + renderTy(fn.ret))
  }
  val c = LCtx(
    env = env,
    insns = newList(),
    allocas = newList(),
    globals = newList(),
    ticker = newList(),
    cur = newList(),
    slots = newMap(),
    loops = newList(),
    problems = newList(),
    retTy = retTy,
    globalPrefix = ".tcstr." + irName + ".",
    refScopes = newList(),
    temps = newList()
  )
  c.cur.add("entry")
  val params: List[NParam] = newList()
  val stores: List[NInsn] = newList()
  for p in fn.params {
    match p.mode {
      case TMIn -> ()
      case _ -> return fallback(fn.sym, "an out or inout parameter")
    }
    val pt = match tyToN(env.recs, p.local.ty) {
      case Some(t) -> t
      case None -> return fallback(fn.sym, "parameter type " + renderTy(p.local.ty))
    }
    match pt {
      case NVoid -> return fallback(fn.sym, "a Unit parameter")
      case _ -> ()
    }
    val pname = "a" + toString(p.local.id.id)
    params.add(NParam(name = pname, ty = pt))
    match declareSlot(c, p.local) {
      case Some(slot) -> stores.add(NStore(ty = pt, value = NLocal(name = pname), ptr = NLocal(name = slot.ptr)))
      case None -> ()
    }
  }
  pushRefScope(c)
  pushTemps(c)
  val result0 = lowerExpr(c, body)
  val result = match retTy { case NVoid -> { discard(c, result0); result0 }; case _ -> own(c, result0) }
  popTemps(c)
  popRefScope(c)
  match retTy {
    case NVoid -> c.insns.add(NRetVoid)
    case _ -> c.insns.add(NRet(ty = retTy, value = result.value))
  }
  if c.problems.count > 0 {
    return fallback(fn.sym, c.problems[0])
  }
  val all: List[NInsn] = newList()
  all.add(NLabel(name = "entry"))
  for a in c.allocas {
    all.add(a)
  }
  for s in stores {
    all.add(s)
  }
  for i in c.insns {
    all.add(i)
  }
  val externs: List[NFunc] = newList()
  if c.globals.count > 0 {
    val pargs: List[NParam] = newList()
    pargs.add(NParam(name = "m", ty = NPtr(pointee = NI8)))
    pargs.add(NParam(name = "f", ty = NPtr(pointee = NI8)))
    pargs.add(NParam(name = "l", ty = NI32))
    externs.add(
      NFunc(
        name = "lyric_panic_msg",
        params = pargs,
        retTy = NVoid,
        isPublic = true,
        isExtern = true,
        body = newList(),
        attributes = newList()
      )
    )
  }
  Ok(
    value = TirLowered(
      fn = NFunc(
        name = irName,
        params = params,
        retTy = retTy,
        isPublic = false,
        isExtern = false,
        body = all,
        attributes = newList()
      ),
      globals = c.globals,
      externs = externs
    )
  )
}
