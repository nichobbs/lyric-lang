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
  /// The unions, keyed by the union's `SymbolId.id`, and each union case's place in one, keyed
  /// by the case's symbol.
  unions: Map[Int, TirUnionLayout] = newMap()
  cases: Map[Int, TirCaseRef] = newMap()
  /// The enums (keyed by the enum's `SymbolId.id`) and each enum case's ordinal (keyed by the
  /// case's symbol).  An enum value is its `i32` ordinal.
  /// A set: the value is always `true`.
  enums: Map[Int, Bool] = newMap()
  enumCases: Map[Int, Int] = newMap()
  /// The tuple layouts the code generator has registered, keyed by `renderTy` of the tuple type.
  /// A tuple is a synthesised heap record, so the code generator cannot list them up front: a
  /// lowering that meets one that is missing records it in `needTuples`, fails, and is run
  /// again with the layout added.
  tuples: Map[String, TirRecLayout] = newMap()
  needTuples: List[TirTupleNeed] = newList()
  /// The closure types the code generator has registered, keyed by `renderTy` of the function
  /// type, and the ones a lowering found missing (see `tuples`).
  funcs: Map[String, NType] = newMap()
  needFuncs: List[TirFuncNeed] = newList()
}

/// A function type the lowering needs a closure type for: its key in `TirLowerEnv.funcs` and
/// the parameter and result types the code generator registers it from.
pub record TirFuncNeed {
  key: String
  paramTys: List[NType]
  retTy: NType
}

/// A closure environment the lowering built: the struct a closure object is allocated as (the
/// ARC header, the function pointer, then the captures), the capture types and the destructor
/// that releases the reference captures (empty when there are none).  The code generator emits
/// the type and the destructor.
pub record TirClosureDef {
  implName: String
  implFields: List[NType]
  capTys: List[NType]
  dtor: String
}

/// A tuple type the lowering needs a layout for: its key in `TirLowerEnv.tuples` and the
/// element types the code generator registers the record from.
pub record TirTupleNeed {
  key: String
  elemTys: List[NType]
}

/// A union case's payload: the struct its fields are stored through and each field's type
/// (`NVoid` for a Unit field).
pub record TirCaseLayout {
  payloadTy: NType
  fieldTys: List[NType]
}

/// A union as the code generator laid it out: an inline tagged struct value (`inline`), or the
/// pointer to a heap object whose header precedes the discriminant.  `discIdx` and `payloadIdx`
/// are the GEP indices of the discriminant and the payload area in `structTy`.
pub record TirUnionLayout {
  ty: NType
  structTy: NType
  inline: Bool
  payloadWords: Int
  discIdx: Int
  payloadIdx: Int
  dtor: String
  cases: List[TirCaseLayout]
}

/// Which union a case belongs to, and its discriminant.
pub record TirCaseRef {
  unionId: Int
  index: Int
}

/// A by-value record's layout as the code generator chose it: its LLVM struct type and
/// the type of each field in declaration order (`NVoid` for a Unit field, whose
/// placeholder byte the struct holds but nothing reads).
pub record TirRecLayout {
  /// The LLVM struct for a by-value record; the pointer to the struct (header, then the
  /// fields) for a heap record.
  ty: NType
  fieldTys: List[NType]
  byValue: Bool = true
  /// A heap record's destructor symbol, or "" when it has no reference field.
  dtor: String = ""
}

/// Why a function stayed on the AST path.
pub record TirFallback {
  sym: SymbolId
  reason: String
  /// Tuple layouts the failed lowering found missing; registering them and lowering again can succeed.
  needTuples: List[TirTupleNeed] = newList()
  /// The same for closure types.
  needFuncs: List[TirFuncNeed] = newList()
}

pub record TirLowered {
  fn: NFunc
  globals: List[NGlobalDef]
  /// Runtime declarations the body calls (`lyric_panic_msg`); the caller adds
  /// those the package lacks.
  externs: List[NFunc]
  /// The functions the body's lambdas lower to, and the closure environments they capture into.
  extraFns: List[NFunc] = newList()
  closures: List[TirClosureDef] = newList()
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
  /// The enclosing function's IR name, the lambda bodies lowered so far (shared with the
  /// lambdas nested in them) and the closure environments they need.
  fnName: String
  extraFns: List[NFunc]
  closures: List[TirClosureDef]
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

/// The types whose values are reference counted: strings and heap records (a pointer to a
/// struct that starts with the ARC header).
func isRefN(t: in NType): Bool {
  match t {
    case NPtr(pointee) -> match pointee { case NStruct(_, fields) -> startsWithArcHeader(fields); case _ -> false }
    case _ -> false
  }
}

func startsWithArcHeader(fields: in List[NType]): Bool {
  if fields.count < 3 {
    return false
  }
  match fields[0] {
    case NI32 -> ()
    case _ -> return false
  }
  match fields[1] {
    case NI32 -> ()
    case _ -> return false
  }
  match fields[2] {
    case NPtr(p) -> match p { case NI8 -> true; case _ -> false }
    case _ -> false
  }
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
func tyToN(env: in TirLowerEnv, t: in Ty): Option[NType] {
  match t {
    case TPrim(k) -> Some(value = primN(k))
    case TRefined(u, _, _, _) -> tyToN(env, u)
    case TNever -> Some(value = NVoid)
    case TNamed(sym, args) -> if args.count == 0 {
      match mapGet(env.recs, sym.id) {
        case Some(r) -> Some(value = r.ty)
        case None -> match mapGet(env.unions, sym.id) {
          case Some(u) -> Some(value = u.ty)
          case None -> if env.enums.containsKey(sym.id) { Some(value = NI32) } else { None }
        }
      }
    } else {
      None
    }
    case TTuple(_) -> match tupleLayout(env, t) { case Some(lay) -> Some(value = lay.ty); case None -> None }
    case TFunc(_, _, _) -> funcType(env, t)
    case _ -> None
  }
}

/// The closure type of a function type: every parameter is an `in` parameter of a concrete
/// type and the function is not async.  A closure type the code generator has not registered
/// is recorded in `env.needFuncs` (once) and reads as unsupported for this attempt.
func funcType(env: in TirLowerEnv, t: in Ty): Option[NType] {
  val ps = match t { case TFunc(ps, _, asy) -> if asy { return None } else { ps }; case _ -> return None }
  val ret = match t { case TFunc(_, r, _) -> r; case _ -> return None }
  val ptys: List[NType] = newList()
  for p in ps {
    match p.mode {
      case TMIn -> ()
      case _ -> return None
    }
    match tyToN(env, p.ty) {
      case Some(nt) -> match nt { case NVoid -> return None; case _ -> ptys.add(nt) }
      case None -> return None
    }
  }
  val rt = match tyToN(env, ret) { case Some(r) -> r; case None -> return None }
  val key = renderTy(t)
  match mapGet(env.funcs, key) {
    case Some(nt) -> Some(value = nt)
    case None -> {
      var seen = false
      for n in env.needFuncs {
        if n.key == key {
          seen = true
        }
      }
      if not seen {
        env.needFuncs.add(TirFuncNeed(key = key, paramTys = ptys, retTy = rt))
      }
      None
    }
  }
}

/// The layout of a tuple type.  A tuple whose layout the code generator has not registered yet
/// is recorded in `env.needTuples` (once) and reads as unsupported for this attempt.
func tupleLayout(env: in TirLowerEnv, t: in Ty): Option[TirRecLayout] {
  val elems = match t { case TTuple(xs) -> xs; case _ -> return None }
  val tys: List[NType] = newList()
  for x in elems {
    match tyToN(env, x) {
      case Some(nt) -> tys.add(nt)
      case None -> return None
    }
  }
  val key = renderTy(t)
  match mapGet(env.tuples, key) {
    case Some(lay) -> Some(value = lay)
    case None -> {
      var seen = false
      for n in env.needTuples {
        if n.key == key {
          seen = true
        }
      }
      if not seen {
        env.needTuples.add(TirTupleNeed(key = key, elemTys = tys))
      }
      None
    }
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
  match tyToN(c.env, d.ty) {
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
    case XInterp(parts) -> lowerInterp(c, parts)
    case XIndex(recv, idx, how) -> lowerIndex(c, recv, idx, how)
    case XConstruct(sym, fields) -> lowerConstruct(c, sym, fields)
    case XField(recv, field) -> lowerField(c, recv, field)
    case XCopy(base, updates) -> lowerCopy(c, e, base, updates)
    case XTuple(elems) -> lowerTuple(c, e, elems)
    case XLambda(params, captures, body) -> lowerLambda(c, e, params, captures, body)
    case _ -> unsupported(c, "expression " + exprKindName(e.kind))
  }
}

func isStructN(t: in NType): Bool {
  match t {
    case NStruct(_, _) -> true
    case _ -> false
  }
}

/// The layout of the record `sym`; a symbol the code generator did not register (a union case,
/// a generic, a protected type) stays on the AST path.
func recLayout(c: in LCtx, sym: in SymbolId): Option[TirRecLayout] {
  match mapGet(c.env.recs, sym.id) {
    case Some(r) -> Some(value = r)
    case None -> {
      c.problems.add("a record or union case (symbol #" + toString(sym.id) + ") that is not a registered record")
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

/// Whether `v` has the type the layout gave field `i`; a mismatch means the layout and the
/// TIR disagree, and storing it would be invalid IR.
func fieldTypeOk(c: in LCtx, lay: in TirRecLayout, i: in Int, v: in Val): Bool {
  match lay.fieldTys[i] {
    case NVoid -> true
    case ft -> if nTypeToIrString(ft) == nTypeToIrString(v.ty) {
      true
    } else {
      c.problems.add(
        "field " + toString(i) + " has type " + nTypeToIrString(v.ty) + " where the layout has " + nTypeToIrString(ft)
      )
      false
    }
  }
}

/// The struct a heap record's pointer points to.
func heapStruct(lay: in TirRecLayout): NType {
  match lay.ty {
    case NPtr(p) -> p
    case t -> t
  }
}

/// A pointer to field `i` of a heap record: the fields follow the three header slots.
func fieldPtr(c: in LCtx, lay: in TirRecLayout, obj: in NValue, i: in Int): NValue {
  val d = tmp(c)
  val idx: List[NArg] = newList()
  idx.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  idx.add(NArg(ty = NI32, value = NLitInt(v = (3 + i).toLong(), ty = NI32)))
  c.insns.add(NGEP(dest = d, ty = heapStruct(lay), ptr = obj, indices = idx))
  NLocal(name = d)
}

/// Allocate a heap record: count 1, the destructor (when it has reference fields) and the
/// weak count the runtime seeds.
func allocHeap(c: in LCtx, lay: in TirRecLayout): NValue {
  allocObject(c, lay.ty, heapStruct(lay), lay.dtor)
}

/// A heap object of struct `st` (pointer type `ty`): count 1, `dtor` in the header when it has
/// one, and the weak count the runtime seeds.
func allocObject(c: in LCtx, ty: in NType, st: in NType, dtor: in String): NValue {
  val size = tmp(c)
  c.insns.add(NSizeOf(dest = size, ty = st))
  val raw = callRt(c, "lyric_alloc", i8ptr(), arg1(NI64, NLocal(name = size)))
  val o = tmp(c)
  c.insns.add(NBitcast(dest = o, fromTy = i8ptr(), value = raw, toTy = ty))
  val obj = NLocal(name = o)
  val rcIdx: List[NArg] = newList()
  rcIdx.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  rcIdx.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  val rc = tmp(c)
  c.insns.add(NGEP(dest = rc, ty = st, ptr = obj, indices = rcIdx))
  c.insns.add(NStore(ty = NI32, value = NLitInt(v = 1i64, ty = NI32), ptr = NLocal(name = rc)))
  val dtIdx: List[NArg] = newList()
  dtIdx.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  dtIdx.add(NArg(ty = NI32, value = NLitInt(v = 2i64, ty = NI32)))
  val dt = tmp(c)
  c.insns.add(NGEP(dest = dt, ty = st, ptr = obj, indices = dtIdx))
  if dtor.length == 0 {
    c.insns.add(NStore(ty = i8ptr(), value = NLitNull(ty = i8ptr()), ptr = NLocal(name = dt)))
  } else {
    val params: List[NType] = newList()
    params.add(i8ptr())
    val cast = tmp(c)
    c.insns.add(
      NBitcast(dest = cast, fromTy = NFnPtr(params = params, ret = NVoid), value = NGlobal(name = dtor), toTy = i8ptr())
    )
    c.insns.add(NStore(ty = i8ptr(), value = NLocal(name = cast), ptr = NLocal(name = dt)))
  }
  callRtVoid(c, "lyric_weak_init", arg1(i8ptr(), raw))
  obj
}

/// Store `v` into field `i` of a heap record: the object owns its reference fields, so a
/// reference is retained first (ARC rule 2).  `v` is a borrowed operand, so an owned temporary
/// it came from is released when the statement ends.
func storeHeapField(c: in LCtx, lay: in TirRecLayout, obj: in NValue, i: in Int, v: in Val): Unit {
  match lay.fieldTys[i] {
    case NVoid -> ()
    case ft -> {
      if isRefN(ft) {
        retainRef(c, ft, v.value)
      }
      c.insns.add(NStore(ty = ft, value = v.value, ptr = fieldPtr(c, lay, obj, i)))
    }
  }
}

/// A record: a by-value record is an `insertvalue` chain from `undef` with no allocation and
/// no ARC; a heap record is allocated after its fields are evaluated, so an early exit inside
/// a field expression leaks nothing, and returned owned.  The fields are evaluated in
/// declaration order.
func lowerConstruct(c: in LCtx, sym: in SymbolId, fields: in List[TExpr]): Val {
  match mapGet(c.env.enumCases, sym.id) {
    case Some(ordinal) -> return Val(ty = NI32, value = NLitInt(v = ordinal.toLong(), ty = NI32))
    case None -> ()
  }
  match mapGet(c.env.cases, sym.id) {
    case Some(cr) -> return lowerCase(c, cr, fields)
    case None -> ()
  }
  match recLayout(c, sym) {
    case None -> unitVal()
    case Some(lay) -> constructWith(c, lay, fields)
  }
}

func constructWith(c: in LCtx, lay: in TirRecLayout, fields: in List[TExpr]): Val {
  if fields.count != lay.fieldTys.count {
    return unsupported(
      c,
      "a construction with " + toString(fields.count) + " of " + toString(lay.fieldTys.count) + " fields"
    )
  }
  val vals: List[Val] = newList()
  var i = 0
  while i < fields.count {
    val v = borrow(c, lowerExpr(c, fields[i]))
    if not fieldTypeOk(c, lay, i, v) {
      return unitVal()
    }
    vals.add(v)
    i = i + 1
  }
  if lay.byValue {
    var cur: NValue = NUndef(ty = lay.ty)
    var j = 0
    while j < vals.count {
      cur = insertField(c, lay, cur, j, vals[j])
      j = j + 1
    }
    return Val(ty = lay.ty, value = cur)
  }
  val obj = allocHeap(c, lay)
  var j = 0
  while j < vals.count {
    storeHeapField(c, lay, obj, j, vals[j])
    j = j + 1
  }
  Val(ty = lay.ty, value = obj, owned = true)
}

/// A tuple value: a heap record of its elements, built like any heap record.
func lowerTuple(c: in LCtx, e: in TExpr, elems: in List[TExpr]): Val {
  match tupleLayout(c.env, e.ty) {
    case None -> unsupported(c, "a tuple of " + renderTy(e.ty))
    case Some(lay) -> constructWith(c, lay, elems)
  }
}

/// Element `i` of a tuple, borrowed from the tuple object.
func loadTupleElem(c: in LCtx, lay: in TirRecLayout, tuple: in NValue, i: in Int): Val {
  val ft = lay.fieldTys[i]
  val d = tmp(c)
  c.insns.add(NLoad(dest = d, ty = ft, ptr = fieldPtr(c, lay, tuple, i)))
  Val(ty = ft, value = NLocal(name = d))
}

/// A field read: `extractvalue` out of a by-value record, a load through the field pointer
/// of a heap one (the result is borrowed from the object).  A Unit field reads as Unit.
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
          if lay.byValue {
            c.insns.add(NExtractValue(dest = d, aggTy = lay.ty, agg = r.value, index = field.index))
          } else {
            c.insns.add(NLoad(dest = d, ty = ft, ptr = fieldPtr(c, lay, r.value, field.index)))
          }
          Val(ty = ft, value = NLocal(name = d))
        }
      }
    }
  }
}

/// A string interpolation: every part is already a `String`, so it is a left fold of
/// concatenations.  Each intermediate is a fresh owned string that the next concatenation
/// consumes as a borrowed operand, so it is released as soon as that concatenation has run; the
/// final string is owned by the caller.
func lowerInterp(c: in LCtx, parts: in List[TExpr]): Val {
  if parts.count == 0 {
    return stringLiteral(c, "")
  }
  var acc = borrow(c, lowerExpr(c, parts[0]))
  if not isStringN(acc.ty) {
    return unsupported(c, "an interpolation part that is not a string")
  }
  var i = 1
  while i < parts.count {
    val next = borrow(c, lowerExpr(c, parts[i]))
    if not isStringN(next.ty) {
      return unsupported(c, "an interpolation part that is not a string")
    }
    val joined = lowerStringBinary(c, IoAdd, acc, next)
    if acc.owned {
      releaseRef(c, acc.ty, acc.value)
    }
    acc = joined
    i = i + 1
  }
  acc
}

/// `s[i]` on a string: the runtime decodes the scalar value starting at byte offset `i`.
/// Other indexing (lists, maps, arrays, slices) stays on the AST path.
func lowerIndex(c: in LCtx, recv: in TExpr, idx: in TExpr, how: in IndexKind): Val {
  match how {
    case IkString -> {
      val r = borrow(c, lowerExpr(c, recv))
      val i = borrow(c, lowerExpr(c, idx))
      val wide = tmp(c)
      c.insns.add(NSExt(dest = wide, fromTy = i.ty, value = i.value, toTy = NI64))
      val ch = callRt(c, "lyric_string_char_at", NI32, arg2(lyricStringNType(), r.value, NI64, NLocal(name = wide)))
      Val(ty = NI32, value = ch)
    }
    case _ -> unsupported(c, "indexing a value that is not a string")
  }
}

/// A pointer into a union object: field `idx` of `structTy` (the discriminant or the payload
/// area).
func unionSlotPtr(c: in LCtx, ul: in TirUnionLayout, base: in NValue, idx: in Int): NValue {
  val d = tmp(c)
  val ix: List[NArg] = newList()
  ix.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  ix.add(NArg(ty = NI32, value = NLitInt(v = idx.toLong(), ty = NI32)))
  c.insns.add(NGEP(dest = d, ty = ul.structTy, ptr = base, indices = ix))
  NLocal(name = d)
}

/// The payload area viewed as the case's payload struct.
func casePayloadPtr(c: in LCtx, ul: in TirUnionLayout, cl: in TirCaseLayout, base: in NValue): NValue {
  val area = unionSlotPtr(c, ul, base, ul.payloadIdx)
  val d = tmp(c)
  c.insns.add(
    NBitcast(
      dest = d,
      fromTy = NPtr(pointee = NArray(elem = NI64, size = ul.payloadWords)),
      value = area,
      toTy = NPtr(pointee = cl.payloadTy)
    )
  )
  NLocal(name = d)
}

/// A pointer to payload field `i` of a case.
func caseFieldPtr(c: in LCtx, cl: in TirCaseLayout, casePtr: in NValue, i: in Int): NValue {
  val d = tmp(c)
  val ix: List[NArg] = newList()
  ix.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  ix.add(NArg(ty = NI32, value = NLitInt(v = i.toLong(), ty = NI32)))
  c.insns.add(NGEP(dest = d, ty = cl.payloadTy, ptr = casePtr, indices = ix))
  NLocal(name = d)
}

/// A union case value.  An inline union is built in a hoisted stack slot and loaded as a value;
/// a heap union is allocated after its fields are evaluated and returned owned, the object
/// owning its reference fields.
func lowerCase(c: in LCtx, cr: in TirCaseRef, fields: in List[TExpr]): Val {
  val ul = match mapGet(c.env.unions, cr.unionId) {
    case Some(u) -> u
    case None -> return unsupported(c, "a union case of an unregistered union")
  }
  val cl = ul.cases[cr.index]
  if fields.count != cl.fieldTys.count {
    return unsupported(
      c,
      "a union case with " + toString(fields.count) + " of " + toString(cl.fieldTys.count) + " fields"
    )
  }
  val vals: List[Val] = newList()
  var i = 0
  while i < fields.count {
    val v = borrow(c, lowerExpr(c, fields[i]))
    match cl.fieldTys[i] {
      case NVoid -> ()
      case ft -> if nTypeToIrString(ft) != nTypeToIrString(v.ty) {
        c.problems.add("a union case field of type " + nTypeToIrString(v.ty) + " where the layout has " + nTypeToIrString(ft))
        return unitVal()
      }
    }
    vals.add(v)
    i = i + 1
  }
  var base: NValue = NUndef(ty = ul.ty)
  if ul.inline {
    c.ticker.add(0)
    val slot = "iu.slot." + toString(c.ticker.count)
    c.allocas.add(NAlloca(dest = slot, ty = ul.structTy))
    base = NLocal(name = slot)
  } else {
    base = allocObject(c, ul.ty, ul.structTy, ul.dtor)
  }
  c.insns.add(
    NStore(ty = NI32, value = NLitInt(v = cr.index.toLong(), ty = NI32), ptr = unionSlotPtr(c, ul, base, ul.discIdx))
  )
  if vals.count > 0 {
    val casePtr = casePayloadPtr(c, ul, cl, base)
    var j = 0
    while j < vals.count {
      match cl.fieldTys[j] {
        case NVoid -> ()
        case ft -> {
          if isRefN(ft) {
            retainRef(c, ft, vals[j].value)
          }
          c.insns.add(NStore(ty = ft, value = vals[j].value, ptr = caseFieldPtr(c, cl, casePtr, j)))
        }
      }
      j = j + 1
    }
  }
  if ul.inline {
    val d = tmp(c)
    c.insns.add(NLoad(dest = d, ty = ul.structTy, ptr = base))
    return Val(ty = ul.ty, value = NLocal(name = d))
  }
  Val(ty = ul.ty, value = base, owned = true)
}

/// A union scrutinee being matched: its layout, a pointer to its object (the heap pointer
/// itself, or a stack copy of an inline value) and its value.
record UnionScrut {
  lay: TirUnionLayout
  base: NValue
  value: Val
}

/// The union a type names, if the code generator registered it.
func unionOfTy(c: in LCtx, t: in Ty): Option[TirUnionLayout] {
  match t {
    case TNamed(sym, args) -> if args.count == 0 { mapGet(c.env.unions, sym.id) } else { None }
    case _ -> None
  }
}

/// Open a union scrutinee: a borrowed pointer to its object.  An inline value is spilled to a
/// stack slot so every case reads its payload through the same pointer.
func openUnion(c: in LCtx, ul: in TirUnionLayout, scrut: in Val): UnionScrut {
  val v = borrow(c, scrut)
  if not ul.inline {
    return UnionScrut(lay = ul, base = v.value, value = v)
  }
  c.ticker.add(0)
  val slot = "iu.scrut." + toString(c.ticker.count)
  c.allocas.add(NAlloca(dest = slot, ty = ul.structTy))
  c.insns.add(NStore(ty = ul.structTy, value = v.value, ptr = NLocal(name = slot)))
  UnionScrut(lay = ul, base = NLocal(name = slot), value = v)
}

/// The value of payload field `i` of case `cr`, read through the scrutinee's pointer.  Reading a
/// field of a case the discriminant has not selected is memory-safe (the payload area covers
/// every case) and its value is only used under the discriminant test.
func loadCaseField(c: in LCtx, u: in UnionScrut, cr: in TirCaseRef, i: in Int): Val {
  val cl = u.lay.cases[cr.index]
  val casePtr = casePayloadPtr(c, u.lay, cl, u.base)
  val ft = cl.fieldTys[i]
  val d = tmp(c)
  c.insns.add(NLoad(dest = d, ty = ft, ptr = caseFieldPtr(c, cl, casePtr, i)))
  Val(ty = ft, value = NLocal(name = d))
}

/// Whether a sub-pattern of a case field needs a test (anything but a wildcard or a plain binding).
func subPatTests(pat: in TPat): Bool {
  match pat.kind {
    case TpWild -> false
    case TpBind(_, inner) -> match inner { case None -> false; case Some(p) -> subPatTests(p) }
    case _ -> true
  }
}

/// The `i1` that says whether `pat` matches the union: the discriminant of a case pattern,
/// and then its scalar sub-patterns on the payload fields.
func patTestU(c: in LCtx, u: in UnionScrut, pat: in TPat): Val {
  match pat.kind {
    case TpWild -> trueV()
    case TpBind(_, inner) -> match inner { case None -> trueV(); case Some(p) -> patTestU(c, u, p) }
    case TpCtor(sym, args) -> match mapGet(c.env.cases, sym.id) {
      case None -> unsupported(c, "a pattern on a case outside the registered unions")
      case Some(cr) -> {
        val dp = unionSlotPtr(c, u.lay, u.base, u.lay.discIdx)
        val disc = tmp(c)
        c.insns.add(NLoad(dest = disc, ty = NI32, ptr = dp))
        val eq = tmp(c)
        c.insns.add(
          NICmp(dest = eq, pred = IEq, ty = NI32, a = NLocal(name = disc), b = NLitInt(v = cr.index.toLong(), ty = NI32))
        )
        var acc = Val(ty = NI1, value = NLocal(name = eq))
        var i = 0
        while i < args.count {
          if subPatTests(args[i]) {
            match u.lay.cases[cr.index].fieldTys[i] {
              case NVoid -> c.problems.add("a pattern on a Unit field")
              case _ -> {
                val fv = loadCaseField(c, u, cr, i)
                acc = andV(c, acc, patTest(c, args[i], fv, args[i].ty))
              }
            }
          }
          i = i + 1
        }
        acc
      }
    }
    case TpOr(alts) -> {
      var acc = patTestU(c, u, alts[0])
      var i = 1
      while i < alts.count {
        acc = orV(c, acc, patTestU(c, u, alts[i]))
        i = i + 1
      }
      acc
    }
    case _ -> unsupported(c, "a pattern of this kind on a union")
  }
}

/// A pattern binding is a borrow of the scrutinee, which outlives the arm, so it is never
/// retained or released; a reference binding that could be reassigned is not supported.
func bindBorrowed(c: in LCtx, decl: in LocalDecl, v: in Val): Unit {
  if decl.mutable and isRefN(v.ty) {
    c.problems.add("a mutable reference binding in a pattern")
    return
  }
  match declareSlot(c, decl) {
    case Some(slot) -> c.insns.add(NStore(ty = slot.ty, value = v.value, ptr = NLocal(name = slot.ptr)))
    case None -> ()
  }
}

/// Store the matched parts into the locals `pat` binds.
func patBindU(c: in LCtx, u: in UnionScrut, pat: in TPat): Unit {
  match pat.kind {
    case TpBind(decl, inner) -> {
      bindBorrowed(c, decl, u.value)
      match inner {
        case Some(p) -> patBindU(c, u, p)
        case None -> ()
      }
    }
    case TpCtor(sym, args) -> match mapGet(c.env.cases, sym.id) {
      case None -> ()
      case Some(cr) -> {
        var i = 0
        while i < args.count {
          match args[i].kind {
            case TpBind(decl, inner) -> match u.lay.cases[cr.index].fieldTys[i] {
              case NVoid -> c.problems.add("a binding of a Unit field")
              case _ -> {
                bindBorrowed(c, decl, loadCaseField(c, u, cr, i))
                match inner {
                  case Some(_) -> c.problems.add("a sub-pattern under a binding in a case pattern")
                  case None -> ()
                }
              }
            }
            case _ -> ()
          }
          i = i + 1
        }
      }
    }
    case _ -> ()
  }
}

/// `r.copy(f = v, ...)`: the base is evaluated once, then the updates in source order.  A
/// by-value record inserts them into the base; a heap record is a new object whose other
/// fields are the base's, each reference retained.
func lowerCopy(c: in LCtx, e: in TExpr, base: in TExpr, updates: in List[TFieldUpdate]): Val {
  val owner = match e.ty { case TNamed(sym, _) -> sym; case _ -> return unsupported(c, "a copy of " + renderTy(e.ty)) }
  match recLayout(c, owner) {
    case None -> unitVal()
    case Some(lay) -> {
      val b = borrow(c, lowerExpr(c, base))
      val upd: Map[Int, Val] = newMap()
      for u in updates {
        val v = borrow(c, lowerExpr(c, u.value))
        if u.field.index < 0 or u.field.index >= lay.fieldTys.count {
          return unsupported(c, "field " + u.field.name + " outside its record's layout")
        }
        if not fieldTypeOk(c, lay, u.field.index, v) {
          return unitVal()
        }
        if upd.containsKey(u.field.index) {
          upd.remove(u.field.index)
        }
        upd.add(u.field.index, v)
      }
      if lay.byValue {
        var cur = b.value
        for u in updates {
          match mapGet(upd, u.field.index) {
            case Some(v) -> {
              cur = insertField(c, lay, cur, u.field.index, v)
            }
            case None -> ()
          }
        }
        return Val(ty = lay.ty, value = cur)
      }
      val vals: List[Val] = newList()
      var i = 0
      while i < lay.fieldTys.count {
        match mapGet(upd, i) {
          case Some(v) -> vals.add(v)
          case None -> match lay.fieldTys[i] {
            case NVoid -> vals.add(unitVal())
            case ft -> {
              val d = tmp(c)
              c.insns.add(NLoad(dest = d, ty = ft, ptr = fieldPtr(c, lay, b.value, i)))
              vals.add(Val(ty = ft, value = NLocal(name = d)))
            }
          }
        }
        i = i + 1
      }
      val obj = allocHeap(c, lay)
      var j = 0
      while j < vals.count {
        storeHeapField(c, lay, obj, j, vals[j])
        j = j + 1
      }
      Val(ty = lay.ty, value = obj, owned = true)
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
    case TLInt(v) -> match tyToN(c.env, e.ty) {
      case None -> unsupported(c, "an integer literal of type " + renderTy(e.ty))
      case Some(nt) -> if isFloatTy(e.ty) {
        Val(ty = nt, value = NLitFloat(v = v.toDouble(), ty = nt))
      } else {
        Val(ty = nt, value = NLitInt(v = wrapLit(v, nt), ty = nt))
      }
    }
    case TLFloat(v) -> match tyToN(c.env, e.ty) {
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
        match tyToN(c.env, ins[0].ty) {
          case Some(nt) -> if isStructN(nt) or isRefN(nt) {
            unsupported(c, "an operator on " + renderTy(ins[0].ty))
          } else {
            lowerBinary(c, op, ins[0].ty, nt, a.value, b.value, line)
          }
          case None -> unsupported(c, "an operator on " + renderTy(ins[0].ty))
        }
      } else if ins.count == 1 {
        val a = borrow(c, lowerExpr(c, ins[0]))
        match tyToN(c.env, ins[0].ty) {
          case Some(nt) -> if isStructN(nt) or isRefN(nt) {
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
          var anyByRef = false
          for a in args {
            match a {
              case TArgIn(_) -> ()
              case _ -> {
                anyByRef = true
              }
            }
          }
          // A reference passed `in` beside a by-reference argument may be the very cell the callee
          // writes: it is held for the call so the write cannot free what the callee still reads.
          val held: List[Val] = newList()
          for a in args {
            match a {
              case TArgIn(v) -> {
                val av = borrow(c, lowerExpr(c, v))
                match av.ty {
                  case NVoid -> c.problems.add("a Unit argument")
                  case _ -> {
                    if anyByRef and isRefN(av.ty) {
                      retainRef(c, av.ty, av.value)
                      held.add(av)
                    }
                    nargs.add(NArg(ty = av.ty, value = av.value))
                  }
                }
              }
              case TArgOut(place) -> nargs.add(byRefArg(c, place))
              case TArgInout(place) -> nargs.add(byRefArg(c, place))
            }
          }
          val result = match tyToN(c.env, e.ty) {
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
          for h in held {
            releaseRef(c, h.ty, h.value)
          }
          result
        }
      }
    }
    case Indirect(fnValue) -> lowerIndirect(c, e, fnValue, args)
    case _ -> unsupported(c, "a call through " + calleeKind(callee))
  }
}

/// A call through a function value: the code pointer sits in the closure object's fourth
/// slot and takes the closure itself (as `i8*`) before the arguments, which are borrowed.  A
/// reference result is owned by the caller.
func lowerIndirect(c: in LCtx, e: in TExpr, fnValue: in TExpr, args: in List[TArg]): Val {
  val sigTys: List[NType] = newList()
  var okSig = true
  match fnValue.ty {
    case TFunc(ps, _, _) -> {
      for p in ps {
        match tyToN(c.env, p.ty) {
          case Some(nt) -> sigTys.add(nt)
          case None -> {
            okSig = false
          }
        }
      }
    }
    case _ -> {
      okSig = false
    }
  }
  val rt = match tyToN(c.env, e.ty) {
    case Some(r) -> r
    case None -> return unsupported(c, "a call returning " + renderTy(e.ty))
  }
  if not okSig {
    return unsupported(c, "a call through " + renderTy(fnValue.ty))
  }
  val clos = borrow(c, lowerExpr(c, fnValue))
  val structTy = match clos.ty {
    case NPtr(p) -> p
    case _ -> return unsupported(c, "a call through a value that is no closure")
  }
  val callArgs: List[NArg] = newList()
  val envCast = tmp(c)
  c.insns.add(NBitcast(dest = envCast, fromTy = clos.ty, value = clos.value, toTy = i8ptr()))
  callArgs.add(NArg(ty = i8ptr(), value = NLocal(name = envCast)))
  var i = 0
  for a in args {
    match a {
      case TArgIn(v) -> {
        val av = borrow(c, lowerExpr(c, v))
        if i >= sigTys.count or nTypeToIrString(av.ty) != nTypeToIrString(sigTys[i]) {
          return unsupported(c, "an argument that does not match the function type")
        }
        callArgs.add(NArg(ty = av.ty, value = av.value))
      }
      case _ -> {
        c.problems.add("an out or inout argument of a function value")
      }
    }
    i = i + 1
  }
  val slot = tmp(c)
  val gi: List[NArg] = newList()
  gi.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  gi.add(NArg(ty = NI32, value = NLitInt(v = 3i64, ty = NI32)))
  c.insns.add(NGEP(dest = slot, ty = structTy, ptr = clos.value, indices = gi))
  val raw = tmp(c)
  c.insns.add(NLoad(dest = raw, ty = i8ptr(), ptr = NLocal(name = slot)))
  val fparams: List[NType] = newList()
  fparams.add(i8ptr())
  for t in sigTys {
    fparams.add(t)
  }
  val typed = tmp(c)
  c.insns.add(
    NBitcast(dest = typed, fromTy = i8ptr(), value = NLocal(name = raw), toTy = NFnPtr(params = fparams, ret = rt))
  )
  match rt {
    case NVoid -> {
      c.insns.add(NCallVoid(fn = NLocal(name = typed), args = callArgs))
      unitVal()
    }
    case _ -> {
      val d = tmp(c)
      c.insns.add(NCall(dest = d, retTy = rt, fn = NLocal(name = typed), args = callArgs))
      Val(ty = rt, value = NLocal(name = d), owned = isRefN(rt))
    }
  }
}

/// Lower `body` as the body of the function being built in `c` and assemble the function: the
/// entry block, the allocas, the parameter stores, then the instructions.  The result is owned
/// and returned after every scope is released.
func assembleFn(c: in LCtx, name: in String, params: in List[NParam], stores: in List[NInsn], body: in TExpr): NFunc {
  pushRefScope(c)
  pushTemps(c)
  val result0 = lowerExpr(c, body)
  val result = match c.retTy { case NVoid -> { discard(c, result0); result0 }; case _ -> own(c, result0) }
  popTemps(c)
  popRefScope(c)
  match c.retTy {
    case NVoid -> c.insns.add(NRetVoid)
    case _ -> c.insns.add(NRet(ty = c.retTy, value = result.value))
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
  NFunc(
    name = name,
    params = params,
    retTy = c.retTy,
    isPublic = false,
    isExtern = false,
    body = all,
    attributes = newList()
  )
}

/// A lambda: a closure object holding the function pointer and the captured values (by
/// value; a reference is retained, and released by the object's destructor).  The body is a
/// function of its own, lowered like any other with the captures read from the environment.
func lowerLambda(c: in LCtx, e: in TExpr, params: in List[LocalDecl], captures: in List[Capture], body: in TExpr): Val {
  val closTy = match tyToN(c.env, e.ty) {
    case Some(t) -> t
    case None -> return unsupported(c, "a lambda of type " + renderTy(e.ty))
  }
  val retTy = match e.ty {
    case TFunc(_, r, _) -> match tyToN(c.env, r) {
      case Some(t) -> t
      case None -> return unsupported(c, "a lambda of type " + renderTy(e.ty))
    }
    case _ -> return unsupported(c, "a lambda of type " + renderTy(e.ty))
  }
  val capTys: List[NType] = newList()
  val capSlots: List[Slot] = newList()
  for cap in captures {
    match cap.mode {
      case CmByValue -> ()
      case CmByRef -> return unsupported(c, "a lambda that mutates a captured variable")
    }
    match mapGet(c.slots, cap.local.id) {
      case Some(sl) -> {
        capTys.add(sl.ty)
        capSlots.add(sl)
      }
      case None -> return unsupported(c, "a capture with no slot")
    }
  }
  c.ticker.add(0)
  val n = c.ticker.count
  val implName = "__closureimpl.tir." + c.fnName + "." + toString(n)
  val bodyName = "__lyric.lambda.tir." + c.fnName + "." + toString(n)
  val implFields: List[NType] = newList()
  addArcHeader(implFields)
  implFields.add(i8ptr())
  for t in capTys {
    implFields.add(t)
  }
  val structTy = NStruct(name = implName, fields = implFields)
  val implTy = NPtr(pointee = structTy)
  var anyRef = false
  for t in capTys {
    if isRefN(t) {
      anyRef = true
    }
  }
  val dtor = if anyRef { implName + ".dtor" } else { "" }
  c.closures.add(TirClosureDef(implName = implName, implFields = implFields, capTys = capTys, dtor = dtor))
  val ch = LCtx(
    env = c.env,
    insns = newList(),
    allocas = newList(),
    globals = c.globals,
    ticker = newList(),
    cur = newList(),
    slots = newMap(),
    loops = newList(),
    problems = c.problems,
    retTy = retTy,
    globalPrefix = ".tcstr." + bodyName + ".",
    refScopes = newList(),
    temps = newList(),
    fnName = bodyName,
    extraFns = c.extraFns,
    closures = c.closures
  )
  ch.cur.add("entry")
  val bparams: List[NParam] = newList()
  bparams.add(NParam(name = "env", ty = i8ptr()))
  val stores: List[NInsn] = newList()
  val ecast = "self.env"
  stores.add(NBitcast(dest = ecast, fromTy = i8ptr(), value = NLocal(name = "env"), toTy = implTy))
  var ci = 0
  while ci < captures.count {
    val gp = "cap" + toString(ci)
    val gi: List[NArg] = newList()
    gi.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
    gi.add(NArg(ty = NI32, value = NLitInt(v = (4 + ci).toLong(), ty = NI32)))
    stores.add(NGEP(dest = gp, ty = structTy, ptr = NLocal(name = ecast), indices = gi))
    val lv = "capv" + toString(ci)
    stores.add(NLoad(dest = lv, ty = capTys[ci], ptr = NLocal(name = gp)))
    val sname = "s" + toString(captures[ci].local.id) + ".cap"
    ch.allocas.add(NAlloca(dest = sname, ty = capTys[ci]))
    stores.add(NStore(ty = capTys[ci], value = NLocal(name = lv), ptr = NLocal(name = sname)))
    ch.slots.add(captures[ci].local.id, Slot(ptr = sname, ty = capTys[ci]))
    ci = ci + 1
  }
  val ptys: List[NType] = newList()
  for p in params {
    val pt = match tyToN(c.env, p.ty) {
      case Some(t) -> t
      case None -> return unsupported(c, "a lambda parameter of type " + renderTy(p.ty))
    }
    match pt {
      case NVoid -> return unsupported(c, "a Unit lambda parameter")
      case _ -> ()
    }
    ptys.add(pt)
    val pname = "a" + toString(p.id.id)
    bparams.add(NParam(name = pname, ty = pt))
    match declareSlot(ch, p) {
      case Some(sl) -> stores.add(NStore(ty = pt, value = NLocal(name = pname), ptr = NLocal(name = sl.ptr)))
      case None -> ()
    }
  }
  c.extraFns.add(assembleFn(ch, bodyName, bparams, stores, body))
  val obj = allocObject(c, implTy, structTy, dtor)
  val fps: List[NType] = newList()
  fps.add(i8ptr())
  for t in ptys {
    fps.add(t)
  }
  val fcast = tmp(c)
  c.insns.add(
    NBitcast(dest = fcast, fromTy = NFnPtr(params = fps, ret = retTy), value = NGlobal(name = bodyName), toTy = i8ptr())
  )
  val fslot = tmp(c)
  val fi: List[NArg] = newList()
  fi.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  fi.add(NArg(ty = NI32, value = NLitInt(v = 3i64, ty = NI32)))
  c.insns.add(NGEP(dest = fslot, ty = structTy, ptr = obj, indices = fi))
  c.insns.add(NStore(ty = i8ptr(), value = NLocal(name = fcast), ptr = NLocal(name = fslot)))
  var si = 0
  while si < captures.count {
    val cv = tmp(c)
    c.insns.add(NLoad(dest = cv, ty = capTys[si], ptr = NLocal(name = capSlots[si].ptr)))
    if isRefN(capTys[si]) {
      retainRef(c, capTys[si], NLocal(name = cv))
    }
    val cs = tmp(c)
    val ci2: List[NArg] = newList()
    ci2.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
    ci2.add(NArg(ty = NI32, value = NLitInt(v = (4 + si).toLong(), ty = NI32)))
    c.insns.add(NGEP(dest = cs, ty = structTy, ptr = obj, indices = ci2))
    c.insns.add(NStore(ty = capTys[si], value = NLocal(name = cv), ptr = NLocal(name = cs)))
    si = si + 1
  }
  val closOut = tmp(c)
  c.insns.add(NBitcast(dest = closOut, fromTy = implTy, value = obj, toTy = closTy))
  Val(ty = closTy, value = NLocal(name = closOut), owned = true)
}

/// The address of an `out` or `inout` argument's place, as the pointer argument the callee's
/// parameter takes: a local's slot, or a field of a heap record (a field of a by-value record
/// lives in its owner's aggregate and has no address).
func byRefArg(c: in LCtx, place: in TPlace): NArg {
  val none = NArg(ty = NI8, value = NLitInt(v = 0i64, ty = NI8))
  match place.kind {
    case PlLocal(id) -> match mapGet(c.slots, id.id) {
      case Some(slot) -> NArg(ty = NPtr(pointee = slot.ty), value = NLocal(name = slot.ptr))
      case None -> {
        c.problems.add("a by-reference argument with no slot")
        none
      }
    }
    case PlField(recv, field) -> match heapFieldPlace(c, recv, field) {
      case Some(fp) -> NArg(ty = NPtr(pointee = fp.ty), value = fp.value)
      case None -> none
    }
    case _ -> {
      c.problems.add("a by-reference argument that is not a local or a record field")
      none
    }
  }
}

/// The address of field `field` of the heap record `recv` evaluates to, typed with the field's
/// type.  The receiver is borrowed, so an owned temporary stays alive until the statement ends.
func heapFieldPlace(c: in LCtx, recv: in TExpr, field: in FieldRef): Option[Val] {
  match recLayout(c, field.owner) {
    case None -> None
    case Some(lay) -> {
      if lay.byValue {
        c.problems.add("a field of a by-value record as a place")
        return None
      }
      if field.index < 0 or field.index >= lay.fieldTys.count {
        c.problems.add("field " + field.name + " outside its record's layout")
        return None
      }
      match lay.fieldTys[field.index] {
        case NVoid -> {
          c.problems.add("a Unit field as a place")
          None
        }
        case ft -> {
          val r = borrow(c, lowerExpr(c, recv))
          Some(value = Val(ty = ft, value = fieldPtr(c, lay, r.value, field.index)))
        }
      }
    }
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
      match tyToN(c.env, e.ty) {
        case Some(nt) -> Val(ty = nt, value = NUndef(ty = nt))
        case None -> unsupported(c, "a conversion from Never to " + renderTy(e.ty))
      }
    }
    case CvWiden(_) -> {
      val v = lowerExpr(c, inner)
      match tyToN(c.env, e.ty) {
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
  val wantRef = match tyToN(c.env, e.ty) { case Some(nt) -> isRefN(nt); case None -> false }
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
  match tyToN(c.env, e.ty) {
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
    case AkAdd -> if isStringN(slot.ty) {
      val r = borrow(c, rhs)
      lowerStringBinary(c, IoAdd, Val(ty = slot.ty, value = NLocal(name = prev)), r)
    } else {
      unsupported(c, "a compound assignment on a reference")
    }
    case _ -> unsupported(c, "a compound assignment on a reference")
  }
  c.insns.add(NStore(ty = slot.ty, value = nv.value, ptr = NLocal(name = slot.ptr)))
  releaseRef(c, slot.ty, NLocal(name = prev))
  unitVal()
}

/// `x = e` and `x op= e` on a cell: a local's slot, a by-reference parameter's pointer or a
/// heap record's field.  A reference is replaced (the new value owned, the old one released).
func assignSlot(c: in LCtx, slot: in Slot, placeTy: in Ty, op: in AssignKind, value: in TExpr): Val {
  if isRefN(slot.ty) {
    return assignRef(c, slot, op, value)
  }
  val rhs = lowerExpr(c, value)
  match assignOp(op) {
    case None -> c.insns.add(NStore(ty = slot.ty, value = rhs.value, ptr = NLocal(name = slot.ptr)))
    case Some(iop) -> {
      val cur = tmp(c)
      c.insns.add(NLoad(dest = cur, ty = slot.ty, ptr = NLocal(name = slot.ptr)))
      val res = lowerBinary(c, iop, placeTy, slot.ty, NLocal(name = cur), rhs.value, value.span.startPos.line)
      c.insns.add(NStore(ty = slot.ty, value = res.value, ptr = NLocal(name = slot.ptr)))
    }
  }
  unitVal()
}

func lowerAssign(c: in LCtx, place: in TPlace, op: in AssignKind, value: in TExpr): Val {
  match place.kind {
    case PlLocal(id) -> match mapGet(c.slots, id.id) {
      case None -> unsupported(c, "an assignment to a local with no slot")
      case Some(slot) -> assignSlot(c, slot, place.ty, op, value)
    }
    case PlField(recv, field) -> match heapFieldPlace(c, recv, field) {
      case None -> unitVal()
      case Some(fp) -> match fp.value {
        case NLocal(name) -> assignSlot(
          c,
          Slot(ptr = name, ty = fp.ty),
          place.ty,
          op,
          value
        )
        case _ -> unsupported(c, "an assignment to a field")
      }
    }
    case _ -> unsupported(c, "an assignment to an element or global")
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
    case TpTuple(elems) -> {
      for a in elems {
        if patBinds(a) {
          return true
        }
      }
      false
    }
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
    case TpLit(l) -> match l {
      case TLString(text) -> if isStringN(scrut.ty) {
        stringEq(c, scrut, stringLiteral(c, text), false)
      } else {
        unsupported(c, "a string pattern on " + renderTy(sty))
      }
      case TLFloat(f) -> if isFloatTy(sty) {
        val d = tmp(c)
        c.insns.add(NFCmp(dest = d, pred = FOeq, ty = scrut.ty, a = scrut.value, b = NLitFloat(v = f, ty = scrut.ty)))
        Val(ty = NI1, value = NLocal(name = d))
      } else {
        unsupported(c, "a float pattern on " + renderTy(sty))
      }
      case _ -> match litValue(l) {
        case Some(v) -> {
          val d = tmp(c)
          c.insns.add(
            NICmp(dest = d, pred = IEq, ty = scrut.ty, a = scrut.value, b = NLitInt(v = wrapLit(v, scrut.ty), ty = scrut.ty))
          )
          Val(ty = NI1, value = NLocal(name = d))
        }
        case None -> unsupported(c, "a literal pattern of this kind")
      }
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
    case TpCtor(sym, _) -> match mapGet(c.env.enumCases, sym.id) {
      case Some(ordinal) -> {
        val d = tmp(c)
        c.insns.add(NICmp(dest = d, pred = IEq, ty = NI32, a = scrut.value, b = NLitInt(v = ordinal.toLong(), ty = NI32)))
        Val(ty = NI1, value = NLocal(name = d))
      }
      case None -> unsupported(c, "a case pattern on a value that is not an enum")
    }
    case TpTuple(elems) -> match tupleLayout(c.env, sty) {
      case None -> unsupported(c, "a tuple pattern on " + renderTy(sty))
      case Some(lay) -> {
        val tys = match sty { case TTuple(xs) -> xs; case _ -> newList() }
        var acc = trueV()
        var i = 0
        while i < elems.count {
          if subPatTests(elems[i]) {
            match lay.fieldTys[i] {
              case NVoid -> c.problems.add("a pattern on a Unit element")
              case _ -> {
                acc = andV(c, acc, patTestAny(c, elems[i], loadTupleElem(c, lay, scrut.value, i), tys[i]))
              }
            }
          }
          i = i + 1
        }
        acc
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

/// `patTest`, opening the value first when it is a union.
func patTestAny(c: in LCtx, pat: in TPat, v: in Val, ty: in Ty): Val {
  match unionOfTy(c, ty) {
    case Some(ul) -> patTestU(c, openUnion(c, ul, v), pat)
    case None -> patTest(c, pat, v, ty)
  }
}

/// Store the scrutinee into the locals `pat` binds.
func patBind(c: in LCtx, pat: in TPat, scrut: in Val): Unit {
  match pat.kind {
    case TpBind(decl, inner) -> {
      bindBorrowed(c, decl, scrut)
      match inner {
        case Some(p) -> patBind(c, p, scrut)
        case None -> ()
      }
    }
    case TpTuple(elems) -> match tupleLayout(c.env, pat.ty) {
      case None -> c.problems.add("a tuple pattern on " + renderTy(pat.ty))
      case Some(lay) -> {
        var i = 0
        while i < elems.count {
          if patBinds(elems[i]) {
            match lay.fieldTys[i] {
              case NVoid -> c.problems.add("a binding of a Unit element")
              case _ -> patBind(c, elems[i], loadTupleElem(c, lay, scrut.value, i))
            }
          }
          i = i + 1
        }
      }
    }
    case _ -> ()
  }
}

/// A destructuring `let`: each bound name becomes an ordinary local that owns its value (a
/// reference element is retained), so the tuple itself can be released at the end of the
/// statement.
func patBindOwned(c: in LCtx, pat: in TPat, v: in Val): Unit {
  match pat.kind {
    case TpWild -> ()
    case TpBind(decl, inner) -> match inner {
      case Some(_) -> c.problems.add("a binding with a sub-pattern")
      case None -> match declareSlot(c, decl) {
        case None -> ()
        case Some(slot) -> {
          val ov = own(c, v)
          c.insns.add(NStore(ty = slot.ty, value = ov.value, ptr = NLocal(name = slot.ptr)))
          trackRef(c, slot)
        }
      }
    }
    case TpTuple(elems) -> match tupleLayout(c.env, pat.ty) {
      case None -> c.problems.add("a tuple pattern on " + renderTy(pat.ty))
      case Some(lay) -> {
        var i = 0
        while i < elems.count {
          if patBinds(elems[i]) {
            match lay.fieldTys[i] {
              case NVoid -> c.problems.add("a binding of a Unit element")
              case _ -> patBindOwned(c, elems[i], loadTupleElem(c, lay, v.value, i))
            }
          }
          i = i + 1
        }
      }
    }
    case _ -> c.problems.add("a destructuring let pattern of this kind")
  }
}

func lowerMatch(c: in LCtx, e: in TExpr, scrutE: in TExpr, arms: in List[TArm], exhaustive: in Bool): Val {
  if not exhaustive {
    return unsupported(c, "a match the builder did not prove exhaustive")
  }
  if arms.count == 0 {
    return unsupported(c, "a match with no arms")
  }
  val scrut0 = lowerExpr(c, scrutE)
  match scrut0.ty {
    case NVoid -> return unsupported(c, "a match on a non-scalar")
    case _ -> ()
  }
  val us: Option[UnionScrut] = match unionOfTy(c, scrutE.ty) {
    case Some(ul) -> Some(value = openUnion(c, ul, scrut0))
    case None -> None
  }
  val isTuple = match scrutE.ty { case TTuple(_) -> true; case _ -> false }
  val scrut = if isStringN(scrut0.ty) or isTuple { borrow(c, scrut0) } else { scrut0 }
  val isUnion = match us { case Some(_) -> true; case None -> false }
  if isRefN(scrut.ty) and not isUnion and not isStringN(scrut.ty) and not isTuple {
    return unsupported(c, "a match on a reference value")
  }
  val wantRef = match tyToN(c.env, e.ty) { case Some(nt) -> isRefN(nt); case None -> false }
  match tyToN(c.env, scrutE.ty) {
    case None -> return unsupported(c, "a match on " + renderTy(scrutE.ty))
    case Some(_) -> ()
  }
  val resN = tyToN(c.env, e.ty)
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
    val test = match us { case Some(u) -> patTestU(c, u, arm.pat); case None -> patTest(c, arm.pat, scrut, scrutE.ty) }
    val bindL = newLabel(c, "arm.bind")
    val nextL = newLabel(c, "arm.next")
    c.insns.add(NCondBr(cond = test.value, thenLabel = bindL, elseLabel = nextL))
    startBlock(c, bindL)
    match us {
      case Some(u) -> patBindU(c, u, arm.pat)
      case None -> patBind(c, arm.pat, scrut)
    }
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
      match tyToN(c.env, lo.ty) {
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
      case TpTuple(_) -> {
        val v = lowerExpr(c, init)
        patBindOwned(c, pat, v)
        discard(c, v)
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
  match lowerTirFunctionInner(env, fn) {
    case Ok(l) -> Ok(value = l)
    case Err(f) -> Err(
      error = TirFallback(
        sym = f.sym,
        reason = f.reason,
        needTuples = env.needTuples,
        needFuncs = env.needFuncs
      )
    )
  }
}

func lowerTirFunctionInner(env: in TirLowerEnv, fn: in TFnDecl): Result[TirLowered, TirFallback] {
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
  val retTy = match tyToN(env, fn.ret) {
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
    temps = newList(),
    fnName = irName,
    extraFns = newList(),
    closures = newList()
  )
  c.cur.add("entry")
  val params: List[NParam] = newList()
  val stores: List[NInsn] = newList()
  for p in fn.params {
    val byRef = match p.mode { case TMIn -> false; case _ -> true }
    val pt = match tyToN(env, p.local.ty) {
      case Some(t) -> t
      case None -> return fallback(fn.sym, "parameter type " + renderTy(p.local.ty))
    }
    match pt {
      case NVoid -> return fallback(fn.sym, "a Unit parameter")
      case _ -> ()
    }
    val pname = "a" + toString(p.local.id.id)
    if byRef {
      // An out or inout parameter is the address of the caller's cell: the local's slot is that
      // pointer, so every read and write reaches the caller's storage, and the callee owns
      // nothing (it is never tracked for release).
      params.add(NParam(name = pname, ty = NPtr(pointee = pt)))
      c.slots.add(p.local.id.id, Slot(ptr = pname, ty = pt))
    } else {
      params.add(NParam(name = pname, ty = pt))
      match declareSlot(c, p.local) {
        case Some(slot) -> stores.add(NStore(ty = pt, value = NLocal(name = pname), ptr = NLocal(name = slot.ptr)))
        case None -> ()
      }
    }
  }
  val lowered = assembleFn(c, irName, params, stores, body)
  if c.problems.count > 0 {
    return fallback(fn.sym, c.problems[0])
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
      fn = lowered,
      globals = c.globals,
      externs = externs,
      extraFns = c.extraFns,
      closures = c.closures
    )
  )
}
