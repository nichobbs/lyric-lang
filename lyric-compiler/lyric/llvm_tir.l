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
import Lyric.Lexer as Lex
import Lyric.LlvmTypes
import Lyric.LlvmIr
import Lyric.Symbols
import Lyric.Tir
import Lyric.Tir.Mono as TirMono

/// Whether the TIR lowering is requested: `lyric build --target native
/// --via-tir` sets `LYRIC_NATIVE_VIA_TIR=1` for the build, and CI sets it
/// directly (docs/70 phase 4a, D520).
pub func viaTirRequested(): Bool {
  Environment.getVarOrDefault("LYRIC_NATIVE_VIA_TIR", "") == "1"
}

/// `LYRIC_NATIVE_TIR_SKIP=a,b`: the functions (bare names) that stay on the AST path, for
/// bisecting a miscompile of the TIR lowering without rebuilding the compiler.
pub func tirSkipped(name: in String): Bool {
  val raw = Environment.getVarOrDefault("LYRIC_NATIVE_TIR_SKIP", "")
  if raw.length == 0 {
    return false
  }
  for part in Str.split(raw, ",") {
    if part == name {
      return true
    }
  }
  false
}

/// `LYRIC_NATIVE_TIR_TRACE=1` lists the functions lowered from TIR after the census.
pub func tirTraceRequested(): Bool {
  Environment.getVarOrDefault("LYRIC_NATIVE_TIR_TRACE", "") == "1"
}

/// One package's TIR as the code generator receives it: the built package and the
/// DefPath key of every symbol in it (`SymbolId.id` to key), from which a top-level
/// function's package, name and arity are read.
pub record TirUnitInput {
  pkg: TPackage
  names: Map[Int, String]
  census: TirCensus
  /// Whether `+`, `-`, `*` and unary `-` on `Int`, `Long`, `UInt`, `ULong` and `Byte` panic on
  /// overflow (D163: a debug build of a user package); false wraps (release, the standard library).
  checkedArith: Bool = false
  /// Whether the package went through `Lyric.Tir.Contracts` (docs/70 section 7.2, D502): its functions' `requires:` and
  /// `ensures:` are asserts in the body, the clauses staying on the declaration for the verifier.  False for TIR
  /// the contract pass has not seen, whose functions with clauses stay on the AST path.
  contractsElaborated: Bool = false
  /// On the instances unit of a monomorphised bundle (docs/70 section 7.2, D500; `Lyric.Mono.Instances`
  /// is the last package of `MonoResult.pkgs`): the table `(generic, arguments) -> instance` and each
  /// instance union's case symbols in declaration order.  Every unit of the bundle is given the one
  /// instances unit after its own, as `tir[1]`.
  instances: List[TirMono.InstanceInfo] = newList()
  instCases: Map[Int, List[SymbolId]] = newMap()
}

/// A distinct type as the lowering reads it: its representation, the primitive it wraps (so the operators
/// on it read their signedness and overflow rule from the primitive) and its range when it has one.
pub record TirDistinct {
  ty: NType
  /// The wrapped `Byte`/`UInt`/`ULong`: the range bounds compare unsigned.
  unsigned: Bool
  hasRange: Bool
  lo: Long
  hi: Long
  /// A `Double`/`Float` range: `loF ..= hiF`, or `..<` when `hiExclusive`.
  isFloat: Bool = false
  loF: Double = 0.0
  hiF: Double = 0.0
  hiExclusive: Bool = false
  /// `[lo, hi]` or `[lo, hi)` as written, for the range-violation message.
  boundsText: String
  /// The type's own name, for the same message.
  name: String
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

/// An `impl` method's DefPath key, `Pkg::Target::$impl(Iface)::name(P1,P2)` (docs/70 §4.2): the
/// package, the target type, the interface and the method's name; None for any other key.
pub record TirImplMember {
  pkg: String
  owner: String
  iface: String
  name: String
}

pub func tirImplMember(key: in String): Option[TirImplMember] {
  match Str.indexOf(key, "::") {
    case None -> None
    case Some(sep) -> {
      val rest = Str.substring(key, sep + 2)
      match Str.indexOf(rest, "::$impl(") {
        case None -> None
        case Some(m) -> {
          val owner = Str.substring(rest, 0, m)
          val tail = Str.substring(rest, m + 8)
          match Str.indexOf(tail, ")::") {
            case None -> None
            case Some(close) -> {
              val iface = Str.substring(tail, 0, close)
              val fnPart = Str.substring(tail, close + 3)
              match Str.indexOf(fnPart, "(") {
                case None -> None
                case Some(open) -> Some(
                  value = TirImplMember(
                    pkg = Str.substring(key, 0, sep),
                    owner = owner,
                    iface = iface,
                    name = Str.substring(fnPart, 0, open)
                  )
                )
              }
            }
          }
        }
      }
    }
  }
}

/// A method declared in a type's body, `Pkg::Type::name(P1)` (docs/70 §4.2): the package, the type
/// and the method's name (`iface` is empty); None for any other key, an `impl` method's included.
pub func tirTypeMember(key: in String): Option[TirImplMember] {
  match Str.indexOf(key, "::") {
    case None -> None
    case Some(sep) -> {
      val rest = Str.substring(key, sep + 2)
      match Str.indexOf(rest, "(") {
        case None -> None
        case Some(open) -> {
          val head = Str.substring(rest, 0, open)
          if Str.contains(head, "$impl") or not Str.endsWith(rest, ")") {
            return None
          }
          match Str.indexOf(head, "::") {
            case None -> None
            case Some(m) -> {
              val name = Str.substring(head, m + 2)
              if Str.contains(name, "::") {
                return None
              }
              Some(
                value = TirImplMember(pkg = Str.substring(key, 0, sep), owner = Str.substring(head, 0, m), iface = "", name = name)
              )
            }
          }
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
/// `label` names a group of units in the first line (" (bundled stdlib)"); the own packages have none.
pub func tirCensusLines(c: in TirCensus, label: in String = ""): List[String] {
  val lines: List[String] = newList()
  lines.add(
    "native via-TIR" + label + ": " + toString(c.lowered.count) + " of " + toString(c.lowered.count + c.fallbacks.count) +
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
  /// The distinct types, keyed by symbol: each is its underlying type's representation, so wrapping and
  /// unwrapping one changes the type only (a range-checked one also checks the range when it is wrapped).
  distincts: Map[Int, NType] = newMap()
  /// What the lowering needs of each distinct type beyond its representation, keyed as `distincts` is.
  distinctInfos: Map[Int, TirDistinct] = newMap()
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
  /// The list types (`List[T]` and `slice[T]` share one runtime representation) the code
  /// generator has registered, keyed by `renderTy` of the element type, and the ones a lowering
  /// found missing (see `tuples`).
  lists: Map[String, NType] = newMap()
  /// The map types, keyed by `renderTy` of the key and value types joined by `|`.
  maps: Map[String, NType] = newMap()
  needMaps: List[TirMapNeed] = newList()
  /// The task types (`Task[T]`), keyed by `renderTy` of the result type, and the ones a lowering
  /// found missing.
  tasks: Map[String, NType] = newMap()
  needTasks: List[TirListNeed] = newList()
  /// The code generator's list scan functions (`indexOf`, `lastIndexOf` and `remove` of an
  /// element equal to a value), keyed `<kind>|<renderTy of the element>`, and the ones a lowering
  /// found missing.
  scans: Map[String, String] = newMap()
  needScans: List[TirScanNeed] = newList()
  /// The symbols of the functions a call named that have no IR name (`fnNames`): the code generator
  /// instantiates a generic function of another package on demand, so the name of one of its
  /// instances exists only once it has been asked for.
  needFns: List[Int] = newList()
  /// The module-level values `globals` lacks, resolved by the code generator like `needFns`.
  needGlobals: List[Int] = newList()
  /// The module-level `val`/`const`s, keyed by symbol.
  globals: Map[Int, TirGlobalRef] = newMap()
  /// The DefPath key of each symbol, for naming a type in a fallback reason.
  symNames: Map[Int, String] = newMap()
  /// The async functions' IR names, keyed by symbol.  They are kept out of `fnNames`: a call to
  /// one gets a task back that the call site unwraps.
  asyncFns: Map[Int, String] = newMap()
  /// The protected types, keyed by symbol: a counted pointer to an object whose last field is
  /// the mutex.  They have a type and readable, writable fields (an entry's body runs under the
  /// lock the AST path's wrapper takes) but no construction, copy or pattern, which need the
  /// mutex set up, so they are kept out of `recs`.
  protRecs: Map[Int, TirRecLayout] = newMap()
  /// The non-generic interfaces, keyed by the interface's symbol; each interface method's place
  /// in one, keyed by the method's symbol; and the vtable constant of a record that implements
  /// an interface, keyed `<record symbol>|<interface symbol>`.
  ifaces: Map[Int, TirIfaceLayout] = newMap()
  ifaceMethods: Map[Int, TirIfaceMethodRef] = newMap()
  ifaceVts: Map[String, String] = newMap()
  /// The stdlib functions the code generator implements itself (`newList`,
  /// `newListWithCapacity`), keyed by the callee's symbol, valued by name.
  intrinsics: Map[Int, String] = newMap()
  needLists: List[TirListNeed] = newList()
  /// See `TirUnitInput.checkedArith`.  The contract elaborator's overflow pass rewrites the AST
  /// the TIR is built from, so the lowering emits the same checks itself.
  checkedArith: Bool = false
  /// See `TirUnitInput.contractsElaborated`.
  contractsElaborated: Bool = false
}

/// A module-level `val` or `const` as the code generator holds it: a constant its initialiser is (`initIr` empty,
/// `lit` the value), or a global computed on first use (`initIr` the IR name of its hoisted initialiser,
/// whose `mvensure.<initIr>` runs it and whose `mv.<initIr>` holds it).
pub record TirGlobalRef {
  ty: NType
  initIr: String
  lit: NValue
  /// A string literal's text, for a value that needs instructions to build (`hasText`): lowered at each read.
  hasText: Bool = false
  text: String = ""
}

/// A function type the lowering needs a closure type for: its key in `TirLowerEnv.funcs` and
/// the parameter and result types the code generator registers it from.
pub record TirFuncNeed {
  key: String
  paramTys: List[NType]
  retTy: NType
}

/// A list element type the lowering needs a list type for: its key in `TirLowerEnv.lists` and
/// the element type the code generator registers the list from.
pub record TirListNeed {
  key: String
  elemTy: NType
}

/// A map type the lowering needs: its key in `TirLowerEnv.maps` and the key and value types the
/// code generator registers it from.
pub record TirMapNeed {
  key: String
  keyTy: NType
  valTy: NType
}

/// One method of an interface as the code generator laid it out: its vtable slot, the types of
/// the erased call (receiver aside) and whether it is a plain method (no `Self`, no by-reference
/// parameter, not async), the only kind this lowering dispatches.
pub record TirIfaceMethod {
  name: String
  paramTys: List[NType]
  retTy: NType
  plain: Bool
}

/// An interface as the code generator laid it out: the heap box pointer (`{ header, obj,
/// vtable* }`), its struct, the vtable struct, the box destructor and the methods in slot order.
pub record TirIfaceLayout {
  boxTy: NType
  structTy: NType
  vtTy: NType
  dtor: String
  methods: List[TirIfaceMethod]
}

pub record TirIfaceMethodRef {
  ifaceId: Int
  slot: Int
}

/// A list scan the lowering needs: its key in `TirLowerEnv.scans`, the kind (`indexOf`,
/// `lastIndexOf` or `remove`) and the element type the code generator synthesises it for.
pub record TirScanNeed {
  key: String
  kind: String
  elemTy: NType
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
  /// A by-value record whose zero value (the checker's `zeroExprFor`) is the all-zero bit
  /// pattern: no field has a declared default.  Set by the code generator, which holds the
  /// declaration; false for a heap record or tuple.
  zeroBits: Bool = false
}

/// Why a function stayed on the AST path.
pub record TirFallback {
  sym: SymbolId
  reason: String
  /// Tuple layouts the failed lowering found missing; registering them and lowering again can succeed.
  needTuples: List[TirTupleNeed] = newList()
  /// The same for closure types.
  needFuncs: List[TirFuncNeed] = newList()
  /// The same for list types.
  needLists: List[TirListNeed] = newList()
  needMaps: List[TirMapNeed] = newList()
  needTasks: List[TirListNeed] = newList()
  needScans: List[TirScanNeed] = newList()
  needFns: List[Int] = newList()
  needGlobals: List[Int] = newList()
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
  /// Lowering the body of an async function: a return completes the task and joins `coro.final`.
  coro: Bool = false
}

/// A parameter an async function retains for its whole run (the caller may release its
/// argument while the coroutine is suspended).
record CoroParam {
  name: String
  slot: Slot
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

func listContainsInt(xs: in List[Int], x: in Int): Bool {
  for y in xs {
    if y == x {
      return true
    }
  }
  false
}

/// `renderTy` with each declared type shown by its DefPath key instead of its symbol number.
func renderTyIn(env: in TirLowerEnv, t: in Ty): String {
  match t {
    case TNamed(sym, args) -> {
      val name = match mapGet(env.symNames, sym.id) { case Some(k) -> k; case None -> "#" + toString(sym.id) }
      if args.count == 0 {
        name
      } else {
        var acc = name + "["
        var i = 0
        while i < args.count {
          if i > 0 {
            acc = acc + ", "
          }
          acc = acc + renderTyIn(env, args[i])
          i = i + 1
        }
        acc + "]"
      }
    }
    case TSlice(e) -> "slice[" + renderTyIn(env, e) + "]"
    case TNullable(i) -> renderTyIn(env, i) + "?"
    case _ -> renderTy(t)
  }
}

/// Record why the function cannot be lowered and hand back a placeholder so
/// lowering can continue to the end; the function is discarded afterwards.
func unsupported(c: in LCtx, why: in String): Val {
  c.problems.add(why)
  Val(ty = NI32, value = NUndef(ty = NI32))
}

/// Whether the type of an expression lowers to `nt`.
/// The type an operator on `t` follows: the primitive a distinct type wraps, else `t`.
func opTy(c: in LCtx, t: in Ty): Ty {
  match t {
    case TNamed(sym, args) -> if args.count == 0 {
      match mapGet(c.env.distinctInfos, sym.id) {
        case Some(d) -> match d.ty {
          case NI8 -> TPrim(kind = TPByte)
          case NI32 -> TPrim(kind = if d.unsigned { TPUInt } else { TPInt })
          case NI64 -> TPrim(kind = if d.unsigned { TPULong } else { TPLong })
          case NFloat -> TPrim(kind = TPFloat)
          case NDouble -> TPrim(kind = TPDouble)
          case _ -> t
        }
        case None -> t
      }
    } else {
      t
    }
    case _ -> t
  }
}

func sameResultType(c: in LCtx, ty: in Ty, nt: in NType): Bool {
  match tyToN(c.env, ty) {
    case Some(rt) -> nTypeToIrString(rt) == nTypeToIrString(nt)
    case None -> false
  }
}

func isIntegerN(t: in NType): Bool {
  match t {
    case NI8 -> true
    case NI32 -> true
    case NI64 -> true
    case _ -> false
  }
}

/// An integer, boolean or floating-point value (what `scalarToString` formats).
func isScalarN(t: in NType): Bool {
  match t {
    case NI1 -> true
    case NI8 -> true
    case NI32 -> true
    case NI64 -> true
    case NFloat -> true
    case NDouble -> true
    case _ -> false
  }
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

/// The spelling of `t` in the name the AST monomorphiser (`Lyric.Mono.specFuncName`) gives a
/// specialised function: a scalar or declared type by its bare name, a generic instance as its
/// head, `_` and its arguments.  The AST path names a specialisation after how the source spelled
/// the argument, so this is a guess that the caller checks against the names that exist; None for a
/// shape it does not cover.
pub func tirAstTypeKey(names: in Map[Int, String], byInst: in Map[Int, TirMono.InstanceInfo], t: in Ty): Option[String] {
  match t {
    case TPrim(k) -> Some(value = primKindName(k))
    case TRefined(u, _, _, _) -> tirAstTypeKey(names, byInst, u)
    case TNamed(sym, args) -> if args.count > 0 {
      None
    } else {
      match mapGet(names, sym.id) {
        case None -> None
        case Some(key) -> {
          val head = match Str.indexOf(key, "[") { case Some(b) -> Str.substring(key, 0, b); case None -> key }
          val bare = match Str.lastIndexOf(head, "::") { case Some(i) -> Str.substring(head, i + 2); case None -> head }
          match mapGet(byInst, sym.id) {
            case None -> Some(value = bare)
            case Some(ii) -> {
              var acc = bare
              for a in ii.args {
                match tirAstTypeKey(names, byInst, a) {
                  case Some(k) -> {
                    acc = acc + "_" + k
                  }
                  case None -> return None
                }
              }
              Some(value = acc)
            }
          }
        }
      }
    }
    case _ -> None
  }
}

/// The type argument `t` of a generic instance as the code generator instantiates the generic with
/// it: a scalar, or a type already laid out (`known`, the type of each record, union and enum by
/// symbol).  None for a shape the instance registration does not cover; the instance is then left
/// unregistered and its users stay on the AST path.
pub func tirInstArgN(known: in Map[Int, NType], t: in Ty): Option[NType] {
  match t {
    case TPrim(k) -> Some(value = primN(k))
    case TRefined(u, _, _, _) -> tirInstArgN(known, u)
    case TNamed(sym, args) -> if args.count == 0 { mapGet(known, sym.id) } else { None }
    case _ -> None
  }
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
    case TNamed(sym, args) -> if sym.id == -1 and args.count == 1 {
      taskType(env, args[0])
    } else if args.count == 0 {
      match mapGet(env.recs, sym.id) {
        case Some(r) -> Some(value = r.ty)
        case None -> match mapGet(env.unions, sym.id) {
          case Some(u) -> Some(value = u.ty)
          case None -> if env.enums.containsKey(sym.id) {
            Some(value = NI32)
          } else if env.distincts.containsKey(sym.id) {
            mapGet(env.distincts, sym.id)
          } else {
            match mapGet(env.ifaces, sym.id) {
              case Some(il) -> Some(value = il.boxTy)
              case None -> match mapGet(env.protRecs, sym.id) { case Some(pl) -> Some(value = pl.ty); case None -> None }
            }
          }
        }
      }
    } else {
      None
    }
    case TTuple(_) -> match tupleLayout(env, t) { case Some(lay) -> Some(value = lay.ty); case None -> None }
    case TArray(len, el) -> arrayType(env, len, el)
    case TFunc(_, _, _) -> funcType(env, t)
    case TSlice(_) -> listType(env, t)
    case TExtern(h) -> if h.name == "lyric.native.NativePtr`1" {
      nativePtrType(env, h)
    } else if h.name == "System.Collections.Generic.Dictionary`2" {
      mapType(env, h)
    } else {
      listType(env, t)
    }
    case _ -> None
  }
}

/// An element type an inline array holds: by-value scalars, records and unions, and arrays of
/// those.  Mirrors `isByValueFieldNType` in llvm_codegen.l, which decides the same question when
/// it lays out a record.
func inlineElemN(t: in NType): Bool {
  match t {
    case NArray(e, _) -> inlineElemN(e)
    case NI1 -> true
    case NI8 -> true
    case NI32 -> true
    case NI64 -> true
    case NFloat -> true
    case NDouble -> true
    case NStruct(_, _) -> true
    case _ -> false
  }
}

/// `array[N, T]` with a known length: the inline LLVM array `[N x T]` when the element is held
/// by value, otherwise the reference-counted list the AST path uses, whose copy at a store is the
/// builder's `XArrayCopy` node.
func arrayType(env: in TirLowerEnv, len: in ArrayLen, el: in Ty): Option[NType] {
  val n = match len { case ALKnown(k) -> k; case _ -> return None }
  match tyToN(env, el) {
    case Some(en) -> if inlineElemN(en) { Some(value = NArray(elem = en, size = n)) } else { listTypeOfElem(env, el) }
    case None -> None
  }
}

/// `NativePtr[T]`: a raw pointer to `T`, not counted.  The pointee is a scalar or another raw
/// pointer; a pointer to a record or union keeps its AST-path form.
func nativePtrType(env: in TirLowerEnv, h: in HostTypeRef): Option[NType] {
  if h.args.count != 1 {
    return None
  }
  match tyToN(env, h.args[0]) {
    case Some(inner) -> match inner {
      case NVoid -> None
      case NPtr(_) -> if isRefN(inner) { None } else { Some(value = NPtr(pointee = inner)) }
      case _ -> if isScalarN(inner) { Some(value = NPtr(pointee = inner)) } else { None }
    }
    case None -> None
  }
}

/// A `Map[K, V]`: a `String` or scalar key and a scalar or reference value.  A map type the code
/// generator has not registered is recorded in `env.needMaps` (once) and reads as unsupported for
/// this attempt.
func mapType(env: in TirLowerEnv, h: in HostTypeRef): Option[NType] {
  if h.args.count != 2 {
    return None
  }
  val kn = match tyToN(env, h.args[0]) { case Some(x) -> x; case None -> return None }
  val vn = match tyToN(env, h.args[1]) { case Some(x) -> x; case None -> return None }
  if not (isStringN(kn) or isScalarN(kn)) or not listElemOk(vn) {
    return None
  }
  val key = renderTy(h.args[0]) + "|" + renderTy(h.args[1])
  match mapGet(env.maps, key) {
    case Some(nt) -> Some(value = nt)
    case None -> {
      var seen = false
      for n in env.needMaps {
        if n.key == key {
          seen = true
        }
      }
      if not seen {
        env.needMaps.add(TirMapNeed(key = key, keyTy = kn, valTy = vn))
      }
      None
    }
  }
}

func isMapTy(t: in Ty): Bool {
  match t {
    case TExtern(h) -> h.name == "System.Collections.Generic.Dictionary`2" and h.args.count == 2
    case _ -> false
  }
}

func mapKeyVal(c: in LCtx, t: in Ty): Option[List[NType]] {
  match t {
    case TExtern(h) -> if h.args.count == 2 {
      match tyToN(c.env, h.args[0]) {
        case Some(k) -> match tyToN(c.env, h.args[1]) {
          case Some(v) -> {
            val xs: List[NType] = newList()
            xs.add(k)
            xs.add(v)
            Some(value = xs)
          }
          case None -> None
        }
        case None -> None
      }
    } else {
      None
    }
    case _ -> None
  }
}

/// An empty map of type `t`; the caller owns it.  A `String` key sets the key flag, a scalar
/// does not.
func newMapOf(c: in LCtx, t: in Ty): Val {
  val mt = match tyToN(c.env, t) { case Some(x) -> x; case None -> return unsupported(c, "a map of " + renderTy(t)) }
  val kv = match mapKeyVal(c, t) { case Some(x) -> x; case None -> return unsupported(c, "a map of " + renderTy(t)) }
  val keyFlag = if isStringN(kv[0]) { 1i64 } else { 0i64 }
  val valFlag = elemFlag(kv[1]).toLong()
  val raw = callRt(
    c,
    "lyric_map_new",
    i8ptr(),
    arg2(NI32, NLitInt(v = keyFlag, ty = NI32), NI32, NLitInt(v = valFlag, ty = NI32))
  )
  val d = tmp(c)
  c.insns.add(NBitcast(dest = d, fromTy = i8ptr(), value = raw, toTy = mt))
  Val(ty = mt, value = NLocal(name = d), owned = true)
}

/// The `Map` members that are one kernel call; the receiver is `ins[0]`.
func lowerMapBuiltin(c: in LCtx, name: in String, ins: in List[TExpr]): Option[Val] {
  if ins.count == 0 or not isMapTy(ins[0].ty) or not tyLowers(c.env, ins[0].ty) {
    return None
  }
  val isAdd = name == "Map.add" and ins.count == 3
  val isHas = name == "Map.containsKey" and ins.count == 2
  val isRemove = name == "Map.remove" and ins.count == 2
  val isCount = name == "Map.count" and ins.count == 1
  if not (isAdd or isHas or isRemove or isCount) {
    return None
  }
  val m = borrow(c, lowerExpr(c, ins[0]))
  val mp = listAsI8(c, m)
  if isCount {
    val n = callRt(c, "lyric_map_len", NI64, arg1(i8ptr(), mp))
    val d = tmp(c)
    c.insns.add(NTrunc(dest = d, fromTy = NI64, value = n, toTy = NI32))
    return Some(value = Val(ty = NI32, value = NLocal(name = d)))
  }
  val k = borrow(c, lowerExpr(c, ins[1]))
  if isAdd {
    val v = borrow(c, lowerExpr(c, ins[2]))
    val args: List[NArg] = newList()
    args.add(NArg(ty = i8ptr(), value = mp))
    args.add(NArg(ty = NI64, value = slotOf(c, k)))
    args.add(NArg(ty = NI64, value = slotOf(c, v)))
    callRtVoid(c, "lyric_map_set", args)
    return Some(value = unitVal())
  }
  val r = callRt(
    c,
    if isHas { "lyric_map_contains" } else { "lyric_map_remove" },
    NI32,
    arg2(i8ptr(), mp, NI64, slotOf(c, k))
  )
  val b = tmp(c)
  c.insns.add(NICmp(dest = b, pred = INe, ty = NI32, a = r, b = NLitInt(v = 0i64, ty = NI32)))
  Some(value = Val(ty = NI1, value = NLocal(name = b)))
}

/// `m[k]`: panics when the key is absent.
func lowerMapIndex(c: in LCtx, recv: in TExpr, idx: in TExpr, line: in Int): Val {
  val kv = match mapKeyVal(c, recv.ty) {
    case Some(x) -> x
    case None -> return unsupported(c, "indexing " + renderTy(recv.ty))
  }
  val m = borrow(c, lowerExpr(c, recv))
  val k = borrow(c, lowerExpr(c, idx))
  mapGetOrPanic(c, m, k, kv[1], line)
}

/// The value under key `k` of the map `m`, borrowed from it; panics when the key is absent.
func mapGetOrPanic(c: in LCtx, m: in Val, k: in Val, valTy: in NType, line: in Int): Val {
  val outSlot = "mapidx.out." + toString(c.ticker.count + 1)
  c.ticker.add(0)
  c.allocas.add(NAlloca(dest = outSlot, ty = NI64))
  val args: List[NArg] = newList()
  args.add(NArg(ty = i8ptr(), value = listAsI8(c, m)))
  args.add(NArg(ty = NI64, value = slotOf(c, k)))
  args.add(NArg(ty = NPtr(pointee = NI64), value = NLocal(name = outSlot)))
  val found = callRt(c, "lyric_map_get", NI32, args)
  val miss = tmp(c)
  c.insns.add(NICmp(dest = miss, pred = IEq, ty = NI32, a = found, b = NLitInt(v = 0i64, ty = NI32)))
  trapIf(c, NLocal(name = miss), "map key not found (use mapGet for an Option result)", line)
  val raw = tmp(c)
  c.insns.add(NLoad(dest = raw, ty = NI64, ptr = NLocal(name = outSlot)))
  fromSlot(c, NLocal(name = raw), valTy)
}

/// The value `cur op rhs` for a compound assignment to an element of type `placeTy`: a scalar
/// through the operator, a `String` by concatenation (a fresh owned string).
func compoundElem(
  c: in LCtx, op: in AssignKind, placeTy: in Ty, nt: in NType, cur: in Val, rhs: in Val, line: in Int
): Option[Val] {
  if isStringN(nt) {
    match op {
      case AkAdd -> return Some(value = lowerStringBinary(c, IoAdd, cur, borrow(c, rhs)))
      case _ -> {
        c.problems.add("a compound assignment on a String element")
        return None
      }
    }
  }
  if not isScalarN(nt) {
    c.problems.add("a compound assignment on an element of type " + renderTy(placeTy))
    return None
  }
  match assignOp(op) {
    case Some(iop) -> Some(value = rangeCheckedResult(c, placeTy, lowerBinary(c, iop, opTy(c, placeTy), nt, cur.value, rhs.value, line), line))
    case None -> None
  }
}

/// `m[k] = v` and `m[k] op= v`: the kernel retains the new value and releases the old one.  A
/// compound assignment reads the current value first (the key must be present), after the
/// right-hand side is evaluated.
func lowerMapSet(c: in LCtx, recv: in TExpr, idx: in TExpr, op: in AssignKind, value: in TExpr): Val {
  if not tyLowers(c.env, recv.ty) {
    return unsupported(c, "assignment to an element of " + renderTy(recv.ty))
  }
  val m = borrow(c, lowerExpr(c, recv))
  val k = borrow(c, lowerExpr(c, idx))
  val line = idx.span.startPos.line
  val v = match op {
    case AkSet -> borrow(c, lowerExpr(c, value))
    case _ -> {
      val kv = match mapKeyVal(c, recv.ty) {
        case Some(x) -> x
        case None -> return unsupported(c, "indexing " + renderTy(recv.ty))
      }
      val rhs = lowerExpr(c, value)
      val cur = mapGetOrPanic(c, m, k, kv[1], line)
      match compoundElem(c, op, value.ty, kv[1], cur, rhs, line) {
        case Some(nv) -> borrow(c, nv)
        case None -> return unitVal()
      }
    }
  }
  val args: List[NArg] = newList()
  args.add(NArg(ty = i8ptr(), value = listAsI8(c, m)))
  args.add(NArg(ty = NI64, value = slotOf(c, k)))
  args.add(NArg(ty = NI64, value = slotOf(c, v)))
  callRtVoid(c, "lyric_map_set", args)
  unitVal()
}

/// `Task[T]`: a counted pointer to the runtime's task, registered by the code generator per
/// result type (see `listType`).
func taskType(env: in TirLowerEnv, elem: in Ty): Option[NType] {
  val en = match tyToN(env, elem) { case Some(x) -> x; case None -> return None }
  if isStructN(en) {
    return None
  }
  val key = renderTy(elem)
  match mapGet(env.tasks, key) {
    case Some(nt) -> Some(value = nt)
    case None -> {
      var seen = false
      for n in env.needTasks {
        if n.key == key {
          seen = true
        }
      }
      if not seen {
        env.needTasks.add(TirListNeed(key = key, elemTy = en))
      }
      None
    }
  }
}

/// The element type of a `slice[T]` or a stdlib `List[T]` (the host type the checker gives
/// `List` on this target); None for anything else.
func listElemTy(t: in Ty): Option[Ty] {
  match t {
    case TSlice(e) -> Some(value = e)
    case TExtern(h) -> if h.args.count == 1 and h.name == "System.Collections.Generic.List`1" {
      Some(value = h.args[0])
    } else {
      None
    }
    case _ -> None
  }
}

func isListTy(t: in Ty): Bool {
  match listElemTy(t) {
    case Some(_) -> true
    case None -> false
  }
}

func tyLowers(env: in TirLowerEnv, t: in Ty): Bool {
  match tyToN(env, t) {
    case Some(_) -> true
    case None -> false
  }
}

/// Elements the list kernels store in a 64-bit slot: scalars and reference-counted values
/// (the container retains the latter).  By-value aggregates are boxed by the AST path and
/// stay there.
/// Whether a list or map holds `nt` as an element or value, as `listType` and `mapType` decide it.
pub func tirListElemOk(nt: in NType): Bool {
  listElemOk(nt)
}

/// Whether `nt` is a map key the lowering supports.
pub func tirMapKeyOk(nt: in NType): Bool {
  isStringN(nt) or isScalarN(nt)
}

func listElemOk(nt: in NType): Bool {
  match nt {
    case NVoid -> false
    case _ -> isScalarN(nt) or isRefN(nt) or isAggN(nt)
  }
}

/// A by-value record, union or array: held in a list or map slot as a counted box (a
/// 64-bit slot holds a pointer to the header followed by the value), copied in and out.
func isAggN(t: in NType): Bool {
  match t {
    case NStruct(_, _) -> true
    case NArray(_, _) -> true
    case _ -> false
  }
}

/// The element flag the list and map kernels dispatch on: 1 for a counted element (a reference,
/// or the box of a by-value aggregate), 0 for a scalar.
func elemFlag(t: in NType): Int {
  if isRefN(t) or isAggN(t) {
    1
  } else {
    0
  }
}

func boxFields(t: in NType): List[NType] {
  val f: List[NType] = newList()
  addArcHeader(f)
  f.add(t)
  f
}

/// The box a by-value aggregate `t` occupies in a slot: the layout of `__box<T>` in the code
/// generator (the header, then the value), as a literal struct so the lowering needs no
/// registered type.
func boxPtrTy(t: in NType): NType {
  NPtr(pointee = NLitStruct(fields = boxFields(t)))
}

/// A new box (count 1) holding `v`.
func boxAgg(c: in LCtx, v: in Val): NValue {
  val st = NLitStruct(fields = boxFields(v.ty))
  val obj = allocObject(c, boxPtrTy(v.ty), st, "")
  val ix: List[NArg] = newList()
  ix.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  ix.add(NArg(ty = NI32, value = NLitInt(v = 3i64, ty = NI32)))
  val p = tmp(c)
  c.insns.add(NGEP(dest = p, ty = st, ptr = obj, indices = ix))
  c.insns.add(NStore(ty = v.ty, value = v.value, ptr = NLocal(name = p)))
  obj
}

/// The list type of `t` (see `listElemTy`).  A list type the code generator has not registered
/// is recorded in `env.needLists` (once) and reads as unsupported for this attempt.
func listType(env: in TirLowerEnv, t: in Ty): Option[NType] {
  val el = match listElemTy(t) { case Some(x) -> x; case None -> return None }
  listTypeOfElem(env, el)
}

/// The list type whose element type is `el`; see `listType`.
func listTypeOfElem(env: in TirLowerEnv, el: in Ty): Option[NType] {
  val en = match tyToN(env, el) { case Some(x) -> x; case None -> return None }
  if not listElemOk(en) {
    return None
  }
  val key = renderTy(el)
  match mapGet(env.lists, key) {
    case Some(nt) -> Some(value = nt)
    case None -> {
      var seen = false
      for n in env.needLists {
        if n.key == key {
          seen = true
        }
      }
      if not seen {
        env.needLists.add(TirListNeed(key = key, elemTy = en))
      }
      None
    }
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

/// The name D163's panic message uses for a type whose arithmetic is overflow-checked.
func overflowTypeName(ty: in Ty): Option[String] {
  match ty {
    case TPrim(k) -> match k {
      case TPInt -> Some(value = "Int")
      case TPLong -> Some(value = "Long")
      case TPUInt -> Some(value = "UInt")
      case TPULong -> Some(value = "ULong")
      case TPByte -> Some(value = "Byte")
      case _ -> None
    }
    case _ -> None
  }
}

/// The result of an operator whose result type is a range-checked distinct type: derived arithmetic goes
/// through `T.from`, so a result outside the range panics with its message (#7226).  Comparisons yield `Bool`
/// and pass through.
func rangeCheckedResult(c: in LCtx, resultTy: in Ty, v: in Val, line: in Int): Val {
  match resultTy {
    case TNamed(sym, args) -> if args.count == 0 {
      match mapGet(c.env.distinctInfos, sym.id) {
        case Some(d) -> if d.hasRange {
          trapIf(c, distinctOutOfRange(c, d, v), distinctRangeMessage(d), line)
        }
        case None -> ()
      }
    }
    case _ -> ()
  }
  v
}

/// The text the managed targets raise when a value is wrapped into a range-checked distinct type (language
/// reference section 2.3).
func distinctRangeMessage(d: in TirDistinct): String {
  d.name + ".from: value out of range " + d.boundsText
}

/// An `i1` that is true when `v` lies outside the range of `d`.
func distinctOutOfRange(c: in LCtx, d: in TirDistinct, v: in Val): NValue {
  if d.isFloat {
    val geLo = tmp(c)
    c.insns.add(NFCmp(dest = geLo, pred = FOge, ty = d.ty, a = v.value, b = NLitFloat(v = d.loF, ty = d.ty)))
    val inHi = tmp(c)
    c.insns.add(
      NFCmp(dest = inHi, pred = if d.hiExclusive { FOlt } else { FOle }, ty = d.ty, a = v.value, b = NLitFloat(v = d.hiF, ty = d.ty))
    )
    val inRange = tmp(c)
    c.insns.add(NAnd(dest = inRange, ty = NI1, a = NLocal(name = geLo), b = NLocal(name = inHi)))
    val bad = tmp(c)
    c.insns.add(NXor(dest = bad, ty = NI1, a = NLocal(name = inRange), b = NLitInt(v = 1i64, ty = NI1)))
    return NLocal(name = bad)
  }
  val below = icmpV(c, if d.unsigned { IUlt } else { ISlt }, d.ty, v.value, intLit(d.ty, d.lo))
  val above = icmpV(c, if d.unsigned { IUgt } else { ISgt }, d.ty, v.value, intLit(d.ty, d.hi))
  val bad = tmp(c)
  c.insns.add(NOr(dest = bad, ty = NI1, a = below, b = above))
  NLocal(name = bad)
}

/// Branch to a panic named `msg` when `cond` holds, and continue otherwise.
func trapIf(c: in LCtx, cond: in NValue, msg: in String, line: in Int): Unit {
  val trapL = newLabel(c, "ovf.trap")
  val okL = newLabel(c, "ovf.ok")
  c.insns.add(NCondBr(cond = cond, thenLabel = trapL, elseLabel = okL))
  startBlock(c, trapL)
  emitPanic(c, msg, line)
  c.insns.add(NBr(label = okL))
  startBlock(c, okL)
}

func icmpV(c: in LCtx, pred: in ICmpPred, ty: in NType, a: in NValue, b: in NValue): NValue {
  val d = tmp(c)
  c.insns.add(NICmp(dest = d, pred = pred, ty = ty, a = a, b = b))
  NLocal(name = d)
}

func intLit(ty: in NType, v: in Long): NValue {
  NLitInt(v = v, ty = ty)
}

/// D163: after `r = a op b` on a checked type, panic with `arithmetic overflow: <Type> <operation>`
/// when the exact result does not fit.  The same tests the elaborator's rewrite spells in Lyric.
func overflowCheck(
  c: in LCtx,
  ty: in Ty,
  nty: in NType,
  op: in IntrinsicOp,
  a: in NValue,
  b: in NValue,
  r: in NValue,
  line: in Int,
): Unit {
  if not c.env.checkedArith {
    return
  }
  val tn = match overflowTypeName(ty) { case Some(n) -> n; case None -> return }
  val uns = isUnsignedTy(ty)
  val word = match op { case IoAdd -> "addition"; case IoSub -> "subtraction"; case _ -> "multiplication" }
  val msg = "arithmetic overflow: " + tn + " " + word
  match op {
    case IoAdd -> {
      if uns {
        trapIf(c, icmpV(c, IUlt, nty, r, a), msg, line)
      } else {
        val x1 = tmp(c)
        c.insns.add(NXor(dest = x1, ty = nty, a = a, b = r))
        val x2 = tmp(c)
        c.insns.add(NXor(dest = x2, ty = nty, a = b, b = r))
        val both = tmp(c)
        c.insns.add(NAnd(dest = both, ty = nty, a = NLocal(name = x1), b = NLocal(name = x2)))
        trapIf(c, icmpV(c, ISlt, nty, NLocal(name = both), intLit(nty, 0i64)), msg, line)
      }
    }
    case IoSub -> {
      if uns {
        trapIf(c, icmpV(c, IUlt, nty, a, b), msg, line)
      } else {
        val x1 = tmp(c)
        c.insns.add(NXor(dest = x1, ty = nty, a = a, b = b))
        val x2 = tmp(c)
        c.insns.add(NXor(dest = x2, ty = nty, a = a, b = r))
        val both = tmp(c)
        c.insns.add(NAnd(dest = both, ty = nty, a = NLocal(name = x1), b = NLocal(name = x2)))
        trapIf(c, icmpV(c, ISlt, nty, NLocal(name = both), intLit(nty, 0i64)), msg, line)
      }
    }
    case _ -> mulCheck(c, tn, nty, a, b, r, msg, line)
  }
}

func mulCheck(
  c: in LCtx,
  tn: in String,
  nty: in NType,
  a: in NValue,
  b: in NValue,
  r: in NValue,
  msg: in String,
  line: in Int,
): Unit {
  if tn == "Int" or tn == "UInt" or tn == "Byte" {
    // The product in the next wider type cannot overflow: test it against this type's range.
    val wide = if tn == "Byte" { NI32 } else { NI64 }
    val wa = tmp(c)
    val wb = tmp(c)
    if tn == "Int" {
      c.insns.add(NSExt(dest = wa, fromTy = nty, value = a, toTy = wide))
      c.insns.add(NSExt(dest = wb, fromTy = nty, value = b, toTy = wide))
    } else {
      c.insns.add(NZExt(dest = wa, fromTy = nty, value = a, toTy = wide))
      c.insns.add(NZExt(dest = wb, fromTy = nty, value = b, toTy = wide))
    }
    val w = tmp(c)
    c.insns.add(NMul(dest = w, ty = wide, a = NLocal(name = wa), b = NLocal(name = wb)))
    if tn == "Int" {
      val lo = icmpV(c, ISlt, wide, NLocal(name = w), intLit(wide, -2147483648i64))
      val hi = icmpV(c, ISgt, wide, NLocal(name = w), intLit(wide, 2147483647i64))
      val bad = tmp(c)
      c.insns.add(NOr(dest = bad, ty = NI1, a = lo, b = hi))
      trapIf(c, NLocal(name = bad), msg, line)
    } else {
      val limit = if tn == "UInt" { 4294967295i64 } else { 255i64 }
      trapIf(c, icmpV(c, IUgt, wide, NLocal(name = w), intLit(wide, limit)), msg, line)
    }
    return
  }
  if tn == "Long" {
    val minLong = -9223372036854775807i64 - 1i64
    val aNeg1 = icmpV(c, IEq, nty, a, intLit(nty, -1i64))
    val bMin = icmpV(c, IEq, nty, b, intLit(nty, minLong))
    val minByNeg1 = tmp(c)
    c.insns.add(NAnd(dest = minByNeg1, ty = NI1, a = aNeg1, b = bMin))
    trapIf(c, NLocal(name = minByNeg1), msg, line)
  }
  // Long and ULong: `a != 0` (and `a != -1`, whose quotient could itself overflow) and `r / a != b`.
  val skip1 = icmpV(c, IEq, nty, a, intLit(nty, 0i64))
  var skip = skip1
  if tn == "Long" {
    val skip2 = icmpV(c, IEq, nty, a, intLit(nty, -1i64))
    val both = tmp(c)
    c.insns.add(NOr(dest = both, ty = NI1, a = skip1, b = skip2))
    skip = NLocal(name = both)
  }
  val chkL = newLabel(c, "ovf.chk")
  val doneL = newLabel(c, "ovf.done")
  c.insns.add(NCondBr(cond = skip, thenLabel = doneL, elseLabel = chkL))
  startBlock(c, chkL)
  val q = tmp(c)
  c.insns.add(
    if tn == "Long" { NSDiv(dest = q, ty = nty, a = r, b = a) } else { NUDiv(dest = q, ty = nty, a = r, b = a) }
  )
  trapIf(c, icmpV(c, INe, nty, NLocal(name = q), b), msg, line)
  c.insns.add(NBr(label = doneL))
  startBlock(c, doneL)
}

/// D163: `-x` on a checked type panics for the minimum value.
func negOverflowCheck(c: in LCtx, ty: in Ty, nty: in NType, a: in NValue, line: in Int): Unit {
  if not c.env.checkedArith {
    return
  }
  val tn = match overflowTypeName(ty) { case Some(n) -> n; case None -> return }
  if tn == "Int" {
    trapIf(c, icmpV(c, IEq, nty, a, intLit(nty, -2147483648i64)), "arithmetic overflow: Int negation", line)
  } else if tn == "Long" {
    trapIf(
      c,
      icmpV(c, IEq, nty, a, intLit(nty, -9223372036854775807i64 - 1i64)),
      "arithmetic overflow: Long negation",
      line
    )
  }
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
    case IoWire(w, m) -> "wire " + w + "." + m
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
    case IoAdd -> {
      c.insns.add(if flt { NFAdd(dest = d, ty = nty, a = a, b = b) } else { NAdd(dest = d, ty = nty, a = a, b = b) })
      overflowCheck(c, ty, nty, op, a, b, NLocal(name = d), line)
    }
    case IoSub -> {
      c.insns.add(if flt { NFSub(dest = d, ty = nty, a = a, b = b) } else { NSub(dest = d, ty = nty, a = a, b = b) })
      overflowCheck(c, ty, nty, op, a, b, NLocal(name = d), line)
    }
    case IoMul -> {
      c.insns.add(if flt { NFMul(dest = d, ty = nty, a = a, b = b) } else { NMul(dest = d, ty = nty, a = a, b = b) })
      overflowCheck(c, ty, nty, op, a, b, NLocal(name = d), line)
    }
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

func lowerUnary(c: in LCtx, op: in IntrinsicOp, ty: in Ty, nty: in NType, a: in NValue, line: in Int): Val {
  val d = tmp(c)
  match op {
    case IoNeg -> {
      negOverflowCheck(c, ty, nty, a, line)
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
      c.problems.add("a local of type " + renderTyIn(c.env, d.ty))
      None
    }
    case Some(nt) -> match nt {
      case NVoid -> {
        // A Unit local owns no storage: its slot is a marker (empty pointer, `NVoid`) so a read yields
        // Unit and an assignment only evaluates its right-hand side.
        if c.slots.containsKey(d.id.id) {
          c.slots.remove(d.id.id)
        }
        c.slots.add(d.id.id, Slot(ptr = "", ty = NVoid))
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
      case Some(slot) -> match slot.ty {
        case NVoid -> unitVal()
        case _ -> {
          val d = tmp(c)
          c.insns.add(NLoad(dest = d, ty = slot.ty, ptr = NLocal(name = slot.ptr)))
          Val(ty = slot.ty, value = NLocal(name = d))
        }
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
    case XIndex(recv, idx, how) -> lowerIndex(c, recv, idx, how, e.span.startPos.line)
    case XConstruct(sym, fields) -> lowerConstruct(c, sym, fields)
    case XField(recv, field) -> lowerField(c, recv, field)
    case XCopy(base, updates) -> lowerCopy(c, e, base, updates)
    case XTuple(elems) -> lowerTuple(c, e, elems)
    case XListLit(elems) -> lowerListLit(c, e, elems)
    case XArrayCopy(inner) -> lowerArrayCopy(c, inner)
    case XZeroValue(ty) -> lowerZeroValue(c, ty)
    case XAwait(inner) -> lowerAwait(c, inner)
    case XSpawn(inner) -> lowerSpawn(c, inner)
    case XLambda(params, captures, body) -> lowerLambda(c, e, params, captures, body)
    case XGlobal(sym, targs) -> lowerGlobal(c, e, sym, targs)
    case _ -> unsupported(c, "expression " + exprKindName(e.kind))
  }
}

/// A read of a module-level `val` or `const`: the constant inlined, or the global behind its hoisted
/// initialiser, which `mvensure.<init>` runs on first use and the load then borrows from (the global owns
/// the value for the life of the process, as on the AST path).
func lowerGlobal(c: in LCtx, e: in TExpr, sym: in SymbolId, targs: in List[Ty]): Val {
  if targs.count > 0 {
    return unsupported(c, "a generic module-level value")
  }
  match mapGet(c.env.globals, sym.id) {
    case None -> {
      if not listContainsInt(c.env.needGlobals, sym.id) {
        c.env.needGlobals.add(sym.id)
      }
      unsupported(c, "the module-level value " + renderGlobalName(c.env, sym))
    }
    case Some(g) -> {
      if not sameResultType(c, e.ty, g.ty) {
        return unsupported(c, "a module-level value whose type differs from its declaration's")
      }
      if g.hasText {
        stringLiteral(c, g.text)
      } else if g.initIr.length == 0 {
        Val(ty = g.ty, value = g.lit)
      } else {
        val noArgs: List[NArg] = newList()
        c.insns.add(NCallVoid(fn = NGlobal(name = "mvensure." + g.initIr), args = noArgs))
        val d = tmp(c)
        c.insns.add(NLoad(dest = d, ty = g.ty, ptr = NGlobal(name = "mv." + g.initIr)))
        Val(ty = g.ty, value = NLocal(name = d))
      }
    }
  }
}

func renderGlobalName(env: in TirLowerEnv, sym: in SymbolId): String {
  match mapGet(env.symNames, sym.id) {
    case Some(k) -> k
    case None -> "#" + toString(sym.id)
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
/// The layout of the object a field is read from or written to: a record, or a protected type
/// (whose user fields come first, so a declared field index is the layout index).
func fieldOwnerLayout(c: in LCtx, sym: in SymbolId): Option[TirRecLayout] {
  match mapGet(c.env.protRecs, sym.id) {
    case Some(p) -> Some(value = p)
    case None -> recLayout(c, sym)
  }
}

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
  match mapGet(c.env.protRecs, sym.id) {
    case Some(lay) -> return constructProtected(c, lay, fields)
    case None -> ()
  }
  match recLayout(c, sym) {
    case None -> unitVal()
    case Some(lay) -> constructWith(c, lay, fields)
  }
}

/// A protected object: the heap record of its user fields, then the runtime-sized mutex buffer
/// (`lyric_mutex_size`, `lyric_alloc`, `lyric_mutex_init`) the code generator's layout holds in
/// its last field.  The destructor the layout names tears the mutex down.
func constructProtected(c: in LCtx, lay: in TirRecLayout, fields: in List[TExpr]): Val {
  if fields.count + 1 != lay.fieldTys.count {
    return unsupported(
      c,
      "a protected construction with " + toString(fields.count) + " fields for a layout of " +
        toString(lay.fieldTys.count)
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
  val obj = allocHeap(c, lay)
  var j = 0
  while j < vals.count {
    storeHeapField(c, lay, obj, j, vals[j])
    j = j + 1
  }
  val size = tmp(c)
  c.insns.add(NCall(dest = size, retTy = NI32, fn = NGlobal(name = "lyric_mutex_size"), args = noArgs()))
  val wide = tmp(c)
  c.insns.add(NSExt(dest = wide, fromTy = NI32, value = NLocal(name = size), toTy = NI64))
  val buf = callRt(c, "lyric_alloc", i8ptr(), arg1(NI64, NLocal(name = wide)))
  callRtVoid(c, "lyric_mutex_init", arg1(i8ptr(), buf))
  c.insns.add(NStore(ty = i8ptr(), value = buf, ptr = fieldPtr(c, lay, obj, fields.count)))
  Val(ty = lay.ty, value = obj, owned = true)
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
  match fieldOwnerLayout(c, field.owner) {
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
/// Lists, maps and inline arrays index through their own lowering; other indexing stays on the AST path.
func lowerIndex(c: in LCtx, recv: in TExpr, idx: in TExpr, how: in IndexKind, line: in Int): Val {
  match how {
    case IkString -> {
      val r = borrow(c, lowerExpr(c, recv))
      val i = borrow(c, lowerExpr(c, idx))
      val wide = tmp(c)
      c.insns.add(NSExt(dest = wide, fromTy = i.ty, value = i.value, toTy = NI64))
      val ch = callRt(c, "lyric_string_char_at", NI32, arg2(lyricStringNType(), r.value, NI64, NLocal(name = wide)))
      Val(ty = NI32, value = ch)
    }
    case IkList -> lowerListIndex(c, recv, idx)
    case IkSlice -> lowerListIndex(c, recv, idx)
    case IkMap -> lowerMapIndex(c, recv, idx, line)
    case IkArray -> lowerArrayIndex(c, recv, idx, line)
    case _ -> unsupported(c, "indexing a value that is not a string, a list, a map or an array")
  }
}

func lowerListIndex(c: in LCtx, recv: in TExpr, idx: in TExpr): Val {
  val el = match listElemN(c, recv.ty) {
    case Some(x) -> x
    case None -> return unsupported(c, "indexing " + renderTy(recv.ty))
  }
  val l = borrow(c, lowerExpr(c, recv))
  val i = wideIndex(c, idx)
  val slot = callRt(c, "lyric_list_get", NI64, arg2(i8ptr(), listAsI8(c, l), NI64, i))
  fromSlot(c, slot, el)
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
    case XValueParam(_, _) -> "XValueParam"
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

/// The value of a floating-point literal in its type: a `Float` literal is the binary32 value
/// nearest the written one (D155), which LLVM requires of a `float` constant.
func floatLitValue(nt: in NType, v: in Double): Double {
  match nt {
    case NFloat -> Lex.float32LiteralValue(toString(v), v)
    case _ -> v
  }
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
        Val(ty = nt, value = NLitFloat(v = floatLitValue(nt, v.toDouble()), ty = nt))
      } else {
        Val(ty = nt, value = NLitInt(v = wrapLit(v, nt), ty = nt))
      }
    }
    case TLFloat(v) -> match tyToN(c.env, e.ty) {
      case None -> unsupported(c, "a float literal of type " + renderTy(e.ty))
      case Some(nt) -> Val(ty = nt, value = NLitFloat(v = floatLitValue(nt, v), ty = nt))
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
        case IoBuiltin(name) -> return lowerBuiltin(c, name, ins, line, e.ty)
        case IoWire(w, m) -> return unsupported(c, "a call through the wire " + w + "." + m)
        case _ -> ()
      }
      if ins.count == 2 {
        val a0 = borrow(c, lowerExpr(c, ins[0]))
        val b0 = borrow(c, lowerExpr(c, ins[1]))
        // `String + x` and `x + String` concatenate the text of the scalar `x` (the surface
        // converts it as `toString` would).
        val textOf = match op { case IoAdd -> true; case _ -> false }
        val a = if textOf and isStringN(b0.ty) and not isStringN(a0.ty) and isScalarN(a0.ty) {
          borrow(c, scalarToString(c, ins[0].ty, a0))
        } else {
          a0
        }
        val b = if textOf and isStringN(a0.ty) and not isStringN(b0.ty) and isScalarN(b0.ty) {
          borrow(c, scalarToString(c, ins[1].ty, b0))
        } else {
          b0
        }
        if isStringN(a.ty) {
          if not isStringN(b.ty) {
            return unsupported(c, "a string operator with a " + renderTy(ins[1].ty) + " operand")
          }
          return lowerStringBinary(c, op, a, b)
        }
        match tyToN(c.env, ins[0].ty) {
          case Some(nt) -> if isStructN(nt) or isRefN(nt) {
            unsupported(c, "an operator on " + renderTy(ins[0].ty))
          } else if nTypeToIrString(a.ty) != nTypeToIrString(b.ty) {
            unsupported(
              c,
              "an operator on operands of different types (" + renderTy(ins[0].ty) + ", " + renderTy(ins[1].ty) + ")"
            )
          } else {
            rangeCheckedResult(c, e.ty, lowerBinary(c, op, opTy(c, ins[0].ty), nt, a.value, b.value, line), line)
          }
          case None -> unsupported(c, "an operator on " + renderTy(ins[0].ty))
        }
      } else if ins.count == 1 {
        // `-<integer literal>` is one literal of the result type: `-2147483648` negates a value
        // that does not fit `Int`, and its operand and result types differ.
        match op {
          case IoNeg -> match ins[0].kind {
            case XLit(TLInt(v)) -> match tyToN(c.env, e.ty) {
              case Some(rt) -> if not isFloatTy(e.ty) and isIntegerN(rt) {
                return Val(ty = rt, value = NLitInt(v = wrapLit(0i64 - v, rt), ty = rt))
              }
              case None -> ()
            }
            case _ -> ()
          }
          case _ -> ()
        }
        val a = borrow(c, lowerExpr(c, ins[0]))
        match tyToN(c.env, ins[0].ty) {
          case Some(nt) -> if isStructN(nt) or isRefN(nt) {
            unsupported(c, "an operator on " + renderTy(ins[0].ty))
          } else if not sameResultType(c, e.ty, nt) {
            unsupported(c, "a unary operator whose result type differs from its operand's")
          } else {
            rangeCheckedResult(c, e.ty, lowerUnary(c, op, opTy(c, ins[0].ty), nt, a.value, line), line)
          }
          case None -> unsupported(c, "an operator on " + renderTy(ins[0].ty))
        }
      } else {
        unsupported(c, "intrinsic " + opName(op))
      }
    }
    case Direct(sym, targs) -> {
      match mapGet(c.env.intrinsics, sym.id) {
        case Some(name) -> return lowerCollectionIntrinsic(c, e, name, args)
        case None -> ()
      }
      match mapGet(c.env.asyncFns, sym.id) {
        case Some(irName) -> {
          if targs.count > 0 {
            return unsupported(c, "a generic call")
          }
          return lowerAsyncCall(c, e, irName, args, false)
        }
        case None -> ()
      }
      if targs.count > 0 {
        return unsupported(c, "a generic call")
      }
      match mapGet(c.env.fnNames, sym.id) {
        case None -> {
          if not listContainsInt(c.env.needFns, sym.id) {
            c.env.needFns.add(sym.id)
          }
          unsupported(c, "a call with no IR name (symbol #" + toString(sym.id) + ")")
        }
        case Some(irName) -> {
          if c.coro {
            match lowerCoroLeaf(c, irName, args) {
              case Some(v) -> return v
              case None -> ()
            }
          }
          if c.coro and isCoroLeaf(irName) {
            return unsupported(c, "a coroutine calling " + irName)
          }
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
                if anyByRef and isRefN(av.ty) {
                  retainRef(c, av.ty, av.value)
                  held.add(av)
                }
                nargs.add(NArg(ty = av.ty, value = av.value))
              }
              case TArgOut(place) -> nargs.add(byRefArg(c, place))
              case TArgInout(place) -> nargs.add(byRefArg(c, place))
            }
          }
          val result = match tyToN(c.env, e.ty) {
            case None -> unsupported(c, "a call returning " + renderTyIn(c.env, e.ty))
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
    case Interface(_, ifaceArgs, method, targs) -> if ifaceArgs.count > 0 or targs.count > 0 {
      unsupported(c, "a generic interface method")
    } else {
      lowerIfaceCall(c, e, method, args)
    }
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
    case None -> return unsupported(c, "a call returning " + renderTyIn(c.env, e.ty))
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
func assembleFn(
  c: in LCtx,
  name: in String,
  params: in List[NParam],
  stores: in List[NInsn],
  body: in TExpr,
  coroParams: in List[CoroParam],
): NFunc {
  if c.coro {
    emitCoroPrologue(c)
  }
  pushRefScope(c)
  pushTemps(c)
  if c.coro {
    for cp in coroParams {
      retainRef(c, cp.slot.ty, NLocal(name = cp.name))
      trackRef(c, cp.slot)
    }
    emitCoroDeferStart(c)
  }
  val result0 = lowerExpr(c, body)
  val result = match c.retTy { case NVoid -> { discard(c, result0); result0 }; case _ -> own(c, result0) }
  popTemps(c)
  popRefScope(c)
  if c.coro {
    emitTaskComplete(c, result)
    emitCoroEpilogue(c)
  } else {
    match c.retTy {
      case NVoid -> c.insns.add(NRetVoid)
      case _ -> c.insns.add(NRet(ty = c.retTy, value = result.value))
    }
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
    retTy = if c.coro { i8ptr() } else { c.retTy },
    isPublic = false,
    isExtern = false,
    body = all,
    attributes = coroAttrs(c.coro)
  )
}

func coroAttrs(coro: in Bool): List[String] {
  val xs: List[String] = newList()
  if coro {
    xs.add("presplitcoroutine")
  }
  xs
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
        match sl.ty {
          case NVoid -> return unsupported(c, "a capture of a Unit local")
          case _ -> ()
        }
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
  c.extraFns.add(assembleFn(ch, bodyName, bparams, stores, body, newList()))
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
      case Some(slot) -> match slot.ty {
        case NVoid -> NArg(ty = NVoid, value = NUndef(ty = NVoid))
        case _ -> NArg(
          ty = NPtr(pointee = slot.ty),
          value = NLocal(name = slot.ptr)
        )
      }
      case None -> {
        c.problems.add("a by-reference argument with no slot")
        none
      }
    }
    case PlField(recv, field) -> match heapFieldPlace(c, recv, field) {
      case Some(fp) -> NArg(ty = NPtr(pointee = fp.ty), value = fp.value)
      case None -> none
    }
    case PlIndex(recv, idx, how) -> match how {
      case IkArray -> match arrayElemPlace(c, recv, idx, idx.span.startPos.line) {
        case Some(p) -> NArg(ty = NPtr(pointee = p.ty), value = p.value)
        case None -> none
      }
      case _ -> {
        c.problems.add("a by-reference argument that is not a local, a record field or an array element")
        none
      }
    }
    case _ -> {
      c.problems.add("a by-reference argument that is not a local, a record field or an array element")
      none
    }
  }
}

/// The address of field `field` of the heap record `recv` evaluates to, typed with the field's
/// type.  The receiver is borrowed, so an owned temporary stays alive until the statement ends.
func heapFieldPlace(c: in LCtx, recv: in TExpr, field: in FieldRef): Option[Val] {
  match fieldOwnerLayout(c, field.owner) {
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
func lowerBuiltin(c: in LCtx, name: in String, ins: in List[TExpr], line: in Int, rty: in Ty): Val {
  if name == "panic" and ins.count == 1 {
    return lowerPanicCall(c, ins[0], line)
  }
  // `assert(cond)` and `assert(cond, message)`: the contract pass's checks.  The message is evaluated on the
  // failure path only, as on the AST path, so a dynamic message costs nothing when the assertion holds.
  if name == "assert" and (ins.count == 1 or ins.count == 2) {
    val cond = borrow(c, lowerExpr(c, ins[0]))
    val okL = newLabel(c, "assert.ok")
    val failL = newLabel(c, "assert.fail")
    c.insns.add(NCondBr(cond = cond.value, thenLabel = okL, elseLabel = failL))
    startBlock(c, failL)
    if ins.count == 2 {
      discard(c, lowerPanicCall(c, ins[1], line))
    } else {
      emitPanic(c, "assertion failed", line)
    }
    c.insns.add(NBr(label = okL))
    startBlock(c, okL)
    return unitVal()
  }
  // The C NULL pointer as a `NativePtr[Byte]` (docs/native-plan N4.5).  Where it may be written is the mode
  // checker's N0100 charge.
  if name == "nativeNullPtr" and ins.count == 0 {
    return Val(ty = NPtr(pointee = NI8), value = NLitNull(ty = NPtr(pointee = NI8)))
  }
  // The address of a local's stack slot (N4.2): the slot is the pointer.  The local must hold a scalar or a
  // pointer so the result is the `NativePtr[T]` the checker typed it as.
  if name == "nativeAddrOf" and ins.count == 1 {
    match ins[0].kind {
      case XLocal(id) -> match mapGet(c.slots, id.id) {
        case Some(slot) -> {
          match slot.ty {
            case NVoid -> return unsupported(c, "the address of a Unit local")
            case _ -> ()
          }
          val pt = NPtr(pointee = slot.ty)
          return match tyToN(c.env, rty) {
            case Some(want) -> if nTypeToIrString(want) == nTypeToIrString(pt) {
              Val(ty = pt, value = NLocal(name = slot.ptr))
            } else {
              unsupported(
                c,
                "the address of a local that holds a " + renderTyIn(c.env, ins[0].ty) + " (the pointer type would be " +
                  nTypeToIrString(want) +
                  ")"
              )
            }
            case None -> unsupported(c, "the address of a local of type " + renderTyIn(c.env, ins[0].ty))
          }
        }
        case None -> return unsupported(c, "the address of a local with no stack slot")
      }
      case _ -> return unsupported(c, "the address of something other than a local")
    }
  }
  match lowerCollectionBuiltin(c, name, ins) {
    case Some(v) -> return v
    case None -> ()
  }
  match lowerListScan(c, name, ins, rty) {
    case Some(v) -> return v
    case None -> ()
  }
  match lowerMapBuiltin(c, name, ins) {
    case Some(v) -> return v
    case None -> ()
  }
  match lowerStringMethod(c, name, ins) {
    case Some(v) -> return v
    case None -> ()
  }
  match lowerNumericConversion(c, name, ins, line) {
    case Some(v) -> return v
    case None -> ()
  }
  if ins.count != 1 {
    return unsupported(c, "builtin " + name + " with " + toString(ins.count) + " arguments")
  }
  val arg = ins[0]
  if name == "array.length" {
    val n = match arg.ty {
      case TArray(len, _) -> match len { case ALKnown(k) -> Some(value = k); case _ -> None }
      case _ -> None
    }
    match n {
      case Some(k) -> {
        discard(c, lowerExpr(c, arg))
        return Val(ty = NI32, value = NLitInt(v = k.toLong(), ty = NI32))
      }
      case None -> return unsupported(c, "the length of " + renderTy(arg.ty))
    }
  }
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

/// The leaves the AST path lowers specially inside a coroutine: they park the task instead of
/// blocking the scheduler.  `sleepMillis` and the fd waits lower here (`lowerCoroLeaf`); the
/// process capture and the socket twins return a `Result`, so a coroutine that calls one stays on
/// the AST path until generic unions lower.  Keep in step with `lowerResolvedSigCall`,
/// `tryEmitIoLeaf` and `nativeAsyncTwin` in llvm_codegen.l.
func isCoroLeaf(irName: in String): Bool {
  irName == "Std.Time.sleepMillis" or irName == "Std.IoWait.waitFd" or irName == "Std.IoWait.waitFd2" or
    irName == "Std.Process.runCapture" or
    irName == "Std.Process.runCaptureWithInput" or
    irName == "Std.TcpHost.hostAccept" or
    irName == "Std.TcpHost.hostRead" or
    irName == "Std.TcpHost.hostWrite"
}

/// An integer argument as the runtime's 64-bit (or, for an event mask, 32-bit) operand.
func leafOperand(c: in LCtx, v: in Val, want: in NType): Option[NValue] {
  if nTypeToIrString(v.ty) == nTypeToIrString(want) {
    return Some(value = v.value)
  }
  match v.ty {
    case NI32 -> match want {
      case NI64 -> {
        val d = tmp(c)
        c.insns.add(NSExt(dest = d, fromTy = NI32, value = v.value, toTy = NI64))
        Some(value = NLocal(name = d))
      }
      case _ -> None
    }
    case _ -> None
  }
}

/// `Std.Time.sleepMillis`, `Std.IoWait.waitFd` and `waitFd2` inside a coroutine: register the
/// task with the reactor, suspend, and (for the waits) read the outcome after the resume, as the
/// AST path's `emitAsyncSleep` and `emitAsyncWaitFd` do.  None for any other callee.
func lowerCoroLeaf(c: in LCtx, irName: in String, args: in List[TArg]): Option[Val] {
  val isSleep = irName == "Std.Time.sleepMillis" and args.count == 1
  val isWait = irName == "Std.IoWait.waitFd" and args.count == 3
  val isWait2 = irName == "Std.IoWait.waitFd2" and args.count == 5
  if not (isSleep or isWait or isWait2) {
    return None
  }
  val rargs: List[NArg] = newList()
  rargs.add(NArg(ty = i8ptr(), value = NLocal(name = "coro.task")))
  var i = 0
  for a in args {
    val ex = match a { case TArgIn(v) -> v; case _ -> return None }
    val v = borrow(c, lowerExpr(c, ex))
    val isMask = i == 1 or (isWait2 and i == 3)
    val want = if isMask { NI32 } else { NI64 }
    match leafOperand(c, v, want) {
      case Some(op) -> rargs.add(NArg(ty = want, value = op))
      case None -> {
        c.problems.add("an argument of " + irName + " of type " + nTypeToIrString(v.ty))
        return Some(value = unitVal())
      }
    }
    i = i + 1
  }
  val fn = if isSleep { "lyric_async_sleep" } else if isWait { "lyric_async_wait_fd" } else { "lyric_async_wait_fd2" }
  callRtVoid(c, fn, rargs)
  emitSuspendPoint(c)
  if isSleep {
    return Some(value = unitVal())
  }
  val r = callRt(c, "lyric_async_wait_fd_result", NI32, arg1(i8ptr(), NLocal(name = "coro.task")))
  Some(value = Val(ty = NI32, value = r))
}

func noArgs(): List[NArg] {
  val xs: List[NArg] = newList()
  xs
}

func singleTy(t: in Ty): List[Ty] {
  val xs: List[Ty] = newList()
  xs.add(t)
  xs
}

/// `llvm.coro.suspend` and its resume, cleanup and exit dispatch; the stream continues in the
/// resume block.
func emitSuspendPoint(c: in LCtx): Unit {
  val sv = tmp(c)
  val sArgs: List[NArg] = newList()
  sArgs.add(NArg(ty = NToken, value = NLitTokenNone))
  sArgs.add(NArg(ty = NI1, value = NLitInt(v = 0i64, ty = NI1)))
  c.insns.add(NCall(dest = sv, retTy = NI8, fn = NGlobal(name = "llvm.coro.suspend"), args = sArgs))
  val resumeL = newLabel(c, "coro.resume")
  val cases: List[NSwitchCase] = newList()
  cases.add(NSwitchCase(matchVal = 0i64, label = resumeL))
  cases.add(NSwitchCase(matchVal = 1i64, label = "coro.cleanup"))
  c.insns.add(NSwitch(ty = NI8, scrutinee = NLocal(name = sv), defaultLabel = "coro.exit", cases = cases))
  startBlock(c, resumeL)
}

/// The coroutine prologue: id, frame allocation, handle, and the task this frame reports through.
/// The labels and values are fixed names: one coroutine is assembled per function, and an async
/// lambda (which would nest a second one) stays on the AST path.
func emitCoroPrologue(c: in LCtx): Unit {
  val p8 = i8ptr()
  val idArgs: List[NArg] = newList()
  idArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  idArgs.add(NArg(ty = p8, value = NLitNull(ty = p8)))
  idArgs.add(NArg(ty = p8, value = NLitNull(ty = p8)))
  idArgs.add(NArg(ty = p8, value = NLitNull(ty = p8)))
  c.insns.add(NCall(dest = "coro.id", retTy = NToken, fn = NGlobal(name = "llvm.coro.id"), args = idArgs))
  c.insns.add(
    NCall(
      dest = "coro.need",
      retTy = NI1,
      fn = NGlobal(name = "llvm.coro.alloc"),
      args = arg1(NToken, NLocal(name = "coro.id"))
    )
  )
  c.insns.add(NCondBr(cond = NLocal(name = "coro.need"), thenLabel = "coro.dynalloc", elseLabel = "coro.begin"))
  startBlock(c, "coro.dynalloc")
  c.insns.add(NCall(dest = "coro.size", retTy = NI64, fn = NGlobal(name = "llvm.coro.size.i64"), args = noArgs()))
  c.insns.add(
    NCall(
      dest = "coro.mem",
      retTy = p8,
      fn = NGlobal(name = "lyric_alloc"),
      args = arg1(NI64, NLocal(name = "coro.size"))
    )
  )
  c.insns.add(NBr(label = "coro.begin"))
  startBlock(c, "coro.begin")
  val phiIn: List[NPhiIncoming] = newList()
  phiIn.add(NPhiIncoming(value = NLitNull(ty = p8), label = "entry"))
  phiIn.add(NPhiIncoming(value = NLocal(name = "coro.mem"), label = "coro.dynalloc"))
  c.insns.add(NPhi(dest = "coro.frame", ty = p8, incoming = phiIn))
  c.insns.add(
    NCall(
      dest = "coro.hdl",
      retTy = p8,
      fn = NGlobal(name = "llvm.coro.begin"),
      args = arg2(NToken, NLocal(name = "coro.id"), p8, NLocal(name = "coro.frame"))
    )
  )
  c.insns.add(
    NCall(
      dest = "coro.task",
      retTy = p8,
      fn = NGlobal(name = "lyric_task_new"),
      args = arg1(p8, NLocal(name = "coro.hdl"))
    )
  )
}

/// After the parameters are retained: let a multi-threaded scheduler start the callee on a
/// worker (the ramp suspends once when it asks to).
func emitCoroDeferStart(c: in LCtx): Unit {
  val p8 = i8ptr()
  c.insns.add(
    NCall(
      dest = "coro.defer",
      retTy = NI32,
      fn = NGlobal(name = "lyric_task_defer_start"),
      args = arg1(p8, NLocal(name = "coro.task"))
    )
  )
  c.insns.add(
    NICmp(
      dest = "coro.defer.b",
      pred = INe,
      ty = NI32,
      a = NLocal(name = "coro.defer"),
      b = NLitInt(v = 0i64, ty = NI32)
    )
  )
  c.insns.add(
    NCondBr(cond = NLocal(name = "coro.defer.b"), thenLabel = "coro.defer.susp", elseLabel = "coro.defer.cont")
  )
  startBlock(c, "coro.defer.susp")
  val dsArgs: List[NArg] = newList()
  dsArgs.add(NArg(ty = NToken, value = NLitTokenNone))
  dsArgs.add(NArg(ty = NI1, value = NLitInt(v = 0i64, ty = NI1)))
  c.insns.add(NCall(dest = "coro.ds", retTy = NI8, fn = NGlobal(name = "llvm.coro.suspend"), args = dsArgs))
  val dsCases: List[NSwitchCase] = newList()
  dsCases.add(NSwitchCase(matchVal = 0i64, label = "coro.defer.cont"))
  dsCases.add(NSwitchCase(matchVal = 1i64, label = "coro.cleanup"))
  c.insns.add(NSwitch(ty = NI8, scrutinee = NLocal(name = "coro.ds"), defaultLabel = "coro.exit", cases = dsCases))
  startBlock(c, "coro.defer.cont")
}

/// The final suspend, cleanup (free the frame) and exit blocks; the function returns the task.
func emitCoroEpilogue(c: in LCtx): Unit {
  val p8 = i8ptr()
  startBlock(c, "coro.final")
  val fsArgs: List[NArg] = newList()
  fsArgs.add(NArg(ty = NToken, value = NLitTokenNone))
  fsArgs.add(NArg(ty = NI1, value = NLitInt(v = 1i64, ty = NI1)))
  c.insns.add(NCall(dest = "coro.fs", retTy = NI8, fn = NGlobal(name = "llvm.coro.suspend"), args = fsArgs))
  val fsCases: List[NSwitchCase] = newList()
  fsCases.add(NSwitchCase(matchVal = 0i64, label = "coro.unreach"))
  fsCases.add(NSwitchCase(matchVal = 1i64, label = "coro.cleanup"))
  c.insns.add(NSwitch(ty = NI8, scrutinee = NLocal(name = "coro.fs"), defaultLabel = "coro.exit", cases = fsCases))
  startBlock(c, "coro.unreach")
  c.insns.add(NUnreachable)
  startBlock(c, "coro.cleanup")
  c.insns.add(
    NCall(
      dest = "coro.freemem",
      retTy = p8,
      fn = NGlobal(name = "llvm.coro.free"),
      args = arg2(NToken, NLocal(name = "coro.id"), p8, NLocal(name = "coro.hdl"))
    )
  )
  c.insns.add(NCallVoid(fn = NGlobal(name = "lyric_free"), args = arg1(p8, NLocal(name = "coro.freemem"))))
  c.insns.add(NBr(label = "coro.exit"))
  startBlock(c, "coro.exit")
  c.insns.add(
    NCall(
      dest = "",
      retTy = NI1,
      fn = NGlobal(name = "llvm.coro.end"),
      args = arg2(p8, NLocal(name = "coro.hdl"), NI1, NLitInt(v = 0i64, ty = NI1))
    )
  )
  c.insns.add(NRet(ty = p8, value = NLocal(name = "coro.task")))
}

/// `lyric_task_complete(task, slot, is_ref)`: hand the result (an owned reference's count moves
/// into the task) to the task and wake its waiters; then join the final suspend.
func emitTaskComplete(c: in LCtx, v: in Val): Unit {
  var slotV: NValue = NLitInt(v = 0i64, ty = NI64)
  var isRef = 0i64
  match v.ty {
    case NVoid -> ()
    case _ -> if isScalarN(v.ty) or isRefN(v.ty) {
      slotV = slotOf(c, v)
      isRef = if isRefN(v.ty) { 1i64 } else { 0i64 }
    } else {
      c.problems.add("an async result of this type")
    }
  }
  val args: List[NArg] = newList()
  args.add(NArg(ty = i8ptr(), value = NLocal(name = "coro.task")))
  args.add(NArg(ty = NI64, value = slotV))
  args.add(NArg(ty = NI32, value = NLitInt(v = isRef, ty = NI32)))
  callRtVoid(c, "lyric_task_complete", args)
  c.insns.add(NBr(label = "coro.final"))
}

/// Wait for `task` (a `Task[T]` value with result type `elem`) and read its result as a borrow:
/// park and suspend inside a coroutine, drive the scheduler to completion outside one.
func unwrapTask(c: in LCtx, task: in Val, elem: in NType): Val {
  val tp = listAsI8(c, task)
  if c.coro {
    val done = callRt(c, "lyric_task_is_complete", NI32, arg1(i8ptr(), tp))
    val cb = tmp(c)
    c.insns.add(NICmp(dest = cb, pred = INe, ty = NI32, a = done, b = NLitInt(v = 0i64, ty = NI32)))
    val doneL = newLabel(c, "await.done")
    val parkL = newLabel(c, "await.park")
    c.insns.add(NCondBr(cond = NLocal(name = cb), thenLabel = doneL, elseLabel = parkL))
    startBlock(c, parkL)
    callRtVoid(c, "lyric_async_await", arg2(i8ptr(), NLocal(name = "coro.task"), i8ptr(), tp))
    emitSuspendPoint(c)
    c.insns.add(NBr(label = doneL))
    startBlock(c, doneL)
  } else {
    callRtVoid(c, "lyric_task_block_on", arg1(i8ptr(), tp))
  }
  match elem {
    case NVoid -> unitVal()
    case _ -> {
      val slot = callRt(c, "lyric_task_result", NI64, arg1(i8ptr(), tp))
      fromSlot(c, slot, elem)
    }
  }
}

/// A call to an async function: the callee returns its task; a `spawn` keeps the task (owned
/// by the statement's temporaries), any other call awaits it in place.
func lowerAsyncCall(c: in LCtx, e: in TExpr, irName: in String, args: in List[TArg], wantTask: in Bool): Val {
  val rt = match tyToN(c.env, e.ty) {
    case Some(t) -> t
    case None -> return unsupported(c, "an async call returning " + renderTy(e.ty))
  }
  val tt = match tyToN(c.env, TNamed(sym = SymbolId(id = -1), args = singleTy(e.ty))) {
    case Some(t) -> t
    case None -> return unsupported(c, "a task of " + renderTy(e.ty))
  }
  if c.coro and isCoroLeaf(irName) {
    return unsupported(c, "a coroutine calling " + irName)
  }
  val nargs: List[NArg] = newList()
  for a in args {
    match a {
      case TArgIn(v) -> {
        val av = borrow(c, lowerExpr(c, v))
        nargs.add(NArg(ty = av.ty, value = av.value))
      }
      case _ -> {
        c.problems.add("an out argument of an async call")
      }
    }
  }
  if wantTask {
    callRtVoid(c, "lyric_spawn_hint", noArgs())
  }
  val d = tmp(c)
  c.insns.add(NCall(dest = d, retTy = i8ptr(), fn = NGlobal(name = irName), args = nargs))
  callRtVoid(c, "lyric_ramp_done", noArgs())
  val cast = tmp(c)
  c.insns.add(NBitcast(dest = cast, fromTy = i8ptr(), value = NLocal(name = d), toTy = tt))
  val task = borrow(c, Val(ty = tt, value = NLocal(name = cast), owned = true))
  if wantTask {
    return task
  }
  unwrapTask(c, task, rt)
}

/// `spawn f(x)` of an async function keeps the un-awaited task; a synchronous callee has no
/// task to keep and stays on the AST path.
func lowerSpawn(c: in LCtx, inner: in TExpr): Val {
  match inner.kind {
    case XCall(callee, args) -> match callee {
      case Direct(sym, targs) -> match mapGet(c.env.asyncFns, sym.id) {
        case Some(irName) -> if targs.count == 0 {
          lowerAsyncCall(c, inner, irName, args, true)
        } else {
          unsupported(c, "a spawn of a generic call")
        }
        case None -> unsupported(
          c,
          "a spawn of a synchronous call"
        )
      }
      case _ -> unsupported(c, "a spawn of this call")
    }
    case _ -> unsupported(c, "a spawn of this expression")
  }
}

/// `await t`: park until the task completes and read its result; a value that is not a task
/// (a direct async call already awaited at its own call site) passes through.
func lowerAwait(c: in LCtx, inner: in TExpr): Val {
  val v = lowerExpr(c, inner)
  match inner.ty {
    case TNamed(sym, targs) -> if sym.id == -1 and targs.count == 1 {
      val elem = match tyToN(c.env, targs[0]) {
        case Some(x) -> x
        case None -> return unsupported(c, "an await of " + renderTy(inner.ty))
      }
      unwrapTask(c, borrow(c, v), elem)
    } else {
      v
    }
    case _ -> v
  }
}

/// A value in the 64-bit slot the list kernels store (the AST path's `slotOfVal`): integers
/// widen, floats keep their bits, references are pointers.
func slotOf(c: in LCtx, v: in Val): NValue {
  val d = tmp(c)
  match v.ty {
    case NI64 -> return v.value
    case NDouble -> c.insns.add(NBitcast(dest = d, fromTy = NDouble, value = v.value, toTy = NI64))
    case NFloat -> {
      val bits = tmp(c)
      c.insns.add(NBitcast(dest = bits, fromTy = NFloat, value = v.value, toTy = NI32))
      c.insns.add(NZExt(dest = d, fromTy = NI32, value = NLocal(name = bits), toTy = NI64))
    }
    case NI32 -> c.insns.add(NSExt(dest = d, fromTy = NI32, value = v.value, toTy = NI64))
    case NI8 -> c.insns.add(NZExt(dest = d, fromTy = NI8, value = v.value, toTy = NI64))
    case NI1 -> c.insns.add(NZExt(dest = d, fromTy = NI1, value = v.value, toTy = NI64))
    case NStruct(_, _) -> return slotOfAgg(c, v)
    case NArray(_, _) -> return slotOfAgg(c, v)
    case _ -> c.insns.add(NPtrToInt(dest = d, fromTy = v.ty, value = v.value, toTy = NI64))
  }
  NLocal(name = d)
}

/// The slot of a by-value aggregate: a new box.  The container retains it, so this code's own
/// count is released when the statement ends.
func slotOfAgg(c: in LCtx, v: in Val): NValue {
  val box = boxAgg(c, v)
  val bt = boxPtrTy(v.ty)
  c.temps[c.temps.count - 1].add(Val(ty = bt, value = box, owned = true))
  val d = tmp(c)
  c.insns.add(NPtrToInt(dest = d, fromTy = bt, value = box, toTy = NI64))
  NLocal(name = d)
}

/// A by-value aggregate read out of its box: a copy, so nothing borrows from the container.
func fromBoxSlot(c: in LCtx, slot: in NValue, nt: in NType): Val {
  val bt = boxPtrTy(nt)
  val box = tmp(c)
  c.insns.add(NIntToPtr(dest = box, fromTy = NI64, value = slot, toTy = bt))
  val ix: List[NArg] = newList()
  ix.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  ix.add(NArg(ty = NI32, value = NLitInt(v = 3i64, ty = NI32)))
  val p = tmp(c)
  c.insns.add(NGEP(dest = p, ty = NLitStruct(fields = boxFields(nt)), ptr = NLocal(name = box), indices = ix))
  val d = tmp(c)
  c.insns.add(NLoad(dest = d, ty = nt, ptr = NLocal(name = p)))
  Val(ty = nt, value = NLocal(name = d))
}

/// The element a slot holds; a reference is borrowed from the list (the kernel's get does not
/// retain).
func fromSlot(c: in LCtx, slot: in NValue, nt: in NType): Val {
  val d = tmp(c)
  match nt {
    case NI64 -> return Val(ty = nt, value = slot)
    case NDouble -> c.insns.add(NBitcast(dest = d, fromTy = NI64, value = slot, toTy = NDouble))
    case NFloat -> {
      val bits = tmp(c)
      c.insns.add(NTrunc(dest = bits, fromTy = NI64, value = slot, toTy = NI32))
      c.insns.add(NBitcast(dest = d, fromTy = NI32, value = NLocal(name = bits), toTy = NFloat))
    }
    case NI32 -> c.insns.add(NTrunc(dest = d, fromTy = NI64, value = slot, toTy = NI32))
    case NI8 -> c.insns.add(NTrunc(dest = d, fromTy = NI64, value = slot, toTy = NI8))
    case NI1 -> c.insns.add(NTrunc(dest = d, fromTy = NI64, value = slot, toTy = NI1))
    case NStruct(_, _) -> return fromBoxSlot(c, slot, nt)
    case NArray(_, _) -> return fromBoxSlot(c, slot, nt)
    case _ -> c.insns.add(NIntToPtr(dest = d, fromTy = NI64, value = slot, toTy = nt))
  }
  Val(ty = nt, value = NLocal(name = d))
}

/// A list value as the `i8*` the kernels take.
func listAsI8(c: in LCtx, v: in Val): NValue {
  val d = tmp(c)
  c.insns.add(NBitcast(dest = d, fromTy = v.ty, value = v.value, toTy = i8ptr()))
  NLocal(name = d)
}

/// The element type of the list or slice `t`, lowered.
func listElemN(c: in LCtx, t: in Ty): Option[NType] {
  match listElemTy(t) {
    case Some(el) -> tyToN(c.env, el)
    case None -> match t { case TArray(_, el) -> tyToN(c.env, el); case _ -> None }
  }
}

/// An empty list of type `t`; the caller owns it.
func newListOf(c: in LCtx, t: in Ty): Val {
  val lt = match tyToN(c.env, t) { case Some(x) -> x; case None -> return unsupported(c, "a list of " + renderTy(t)) }
  val el = match listElemN(c, t) { case Some(x) -> x; case None -> return unsupported(c, "a list of " + renderTy(t)) }
  val flag = elemFlag(el).toLong()
  val raw = callRt(c, "lyric_list_new", i8ptr(), arg1(NI32, NLitInt(v = flag, ty = NI32)))
  val d = tmp(c)
  c.insns.add(NBitcast(dest = d, fromTy = i8ptr(), value = raw, toTy = lt))
  Val(ty = lt, value = NLocal(name = d), owned = true)
}

/// Push `x` (borrowed; the kernel retains a reference element) onto the list `l`.
func pushOnto(c: in LCtx, l: in Val, x: in TExpr): Unit {
  val v = borrow(c, lowerExpr(c, x))
  val args: List[NArg] = newList()
  args.add(NArg(ty = i8ptr(), value = listAsI8(c, l)))
  args.add(NArg(ty = NI64, value = slotOf(c, v)))
  callRtVoid(c, "lyric_list_push", args)
}

/// `[a, b, c]` as a list or slice.
func lowerListLit(c: in LCtx, e: in TExpr, elems: in List[TExpr]): Val {
  match e.ty {
    case TArray(_, _) -> match tyToN(c.env, e.ty) {
      case Some(nt) -> match nt {
        case NArray(_, _) -> return lowerArrayLit(c, nt, elems)
        case _ -> ()
      }
      case None -> return unsupported(c, "a literal of " + renderTy(e.ty))
    }
    case _ -> ()
  }
  val l = newListOf(c, e.ty)
  // A failed lowering of the list type is reported in `c.problems` and yields a placeholder that
  // is not a reference: there is nothing to push onto.
  if not isRefN(l.ty) {
    return l
  }
  for x in elems {
    pushOnto(c, l, x)
  }
  l
}

/// `mapKeys(m)` and `mapValues(m)`: a fresh list of the map's keys or values, in the runtime's
/// slot order, whose elements the list retains as the map does.
func lowerMapSnapshot(c: in LCtx, e: in TExpr, name: in String, arg: in TArg): Val {
  val mExpr = match arg { case TArgIn(v) -> v; case _ -> return unsupported(c, "an out argument of " + name) }
  if not isMapTy(mExpr.ty) or not tyLowers(c.env, mExpr.ty) {
    return unsupported(c, name + " of " + renderTy(mExpr.ty))
  }
  val lt = match tyToN(c.env, e.ty) {
    case Some(x) -> x
    case None -> return unsupported(c, "a list of " + renderTy(e.ty))
  }
  val m = borrow(c, lowerExpr(c, mExpr))
  val raw = callRt(
    c,
    if name == "mapKeys" { "lyric_map_keys" } else { "lyric_map_values" },
    i8ptr(),
    arg1(i8ptr(), listAsI8(c, m))
  )
  val d = tmp(c)
  c.insns.add(NBitcast(dest = d, fromTy = i8ptr(), value = raw, toTy = lt))
  Val(ty = lt, value = NLocal(name = d), owned = true)
}

/// `newList()` and `newListWithCapacity(n)`.
func lowerCollectionIntrinsic(c: in LCtx, e: in TExpr, name: in String, args: in List[TArg]): Val {
  if name == "newMap" and isMapTy(e.ty) {
    return newMapOf(c, e.ty)
  }
  if (name == "mapKeys" or name == "mapValues") and isListTy(e.ty) and args.count == 1 {
    return lowerMapSnapshot(c, e, name, args[0])
  }
  if not isListTy(e.ty) {
    return unsupported(c, name + " producing " + renderTy(e.ty))
  }
  for a in args {
    match a {
      case TArgIn(v) -> discard(c, lowerExpr(c, v))
      case _ -> {
        c.problems.add("an out argument of " + name)
      }
    }
  }
  newListOf(c, e.ty)
}

/// The scan function the code generator synthesised for `kind` over `elem`; one it has not
/// registered is recorded in `env.needScans` (once) and reads as unsupported for this attempt.
func scanFnOf(c: in LCtx, kind: in String, elem: in Ty, elemN: in NType): Option[String] {
  val key = kind + "|" + renderTy(elem)
  match mapGet(c.env.scans, key) {
    case Some(f) -> Some(value = f)
    case None -> {
      var seen = false
      for n in c.env.needScans {
        if n.key == key {
          seen = true
        }
      }
      if not seen {
        c.env.needScans.add(TirScanNeed(key = key, kind = kind, elemTy = elemN))
      }
      None
    }
  }
}

/// `contains`, `indexOf`, `lastIndexOf` and `remove` of a value on a list or slice of scalars or
/// strings: the code generator's scan function compares each element with the value under the
/// element type's `==` (the text of a `String`).  Other element types keep the AST path.
func lowerListScan(c: in LCtx, name: in String, ins: in List[TExpr], rty: in Ty): Option[Val] {
  if ins.count != 2 or not isListTy(ins[0].ty) {
    return None
  }
  val kind = if name == "List.contains" or name == "List.indexOf" {
    "indexOf"
  } else if name == "List.lastIndexOf" {
    "lastIndexOf"
  } else if name == "List.remove" {
    "remove"
  } else {
    return None
  }
  val el = match listElemTy(ins[0].ty) { case Some(x) -> x; case None -> return None }
  val elN = match tyToN(c.env, el) { case Some(x) -> x; case None -> return None }
  if not (isScalarN(elN) or isStringN(elN)) or not tyLowers(c.env, ins[0].ty) {
    return None
  }
  val wantInt = name == "List.indexOf" or name == "List.lastIndexOf"
  if wantInt {
    match rty {
      case TPrim(TPInt) -> ()
      case _ -> return Some(value = unsupported(c, "a list " + name + " result of " + renderTy(rty)))
    }
  }
  val fn = match scanFnOf(c, kind, el, elN) {
    case Some(f) -> f
    case None -> return Some(value = unsupported(c, "a list scan that is not registered yet"))
  }
  val l = borrow(c, lowerExpr(c, ins[0]))
  val needle = borrow(c, lowerExpr(c, ins[1]))
  val args: List[NArg] = newList()
  args.add(NArg(ty = i8ptr(), value = listAsI8(c, l)))
  args.add(NArg(ty = NI64, value = slotOf(c, needle)))
  val d = tmp(c)
  if kind == "remove" {
    c.insns.add(NCall(dest = d, retTy = NI1, fn = NGlobal(name = fn), args = args))
    return Some(value = Val(ty = NI1, value = NLocal(name = d)))
  }
  c.insns.add(NCall(dest = d, retTy = NI64, fn = NGlobal(name = fn), args = args))
  if name == "List.contains" {
    val hit = tmp(c)
    c.insns.add(NICmp(dest = hit, pred = ISge, ty = NI64, a = NLocal(name = d), b = NLitInt(v = 0i64, ty = NI64)))
    return Some(value = Val(ty = NI1, value = NLocal(name = hit)))
  }
  val n = tmp(c)
  c.insns.add(NTrunc(dest = n, fromTy = NI64, value = NLocal(name = d), toTy = NI32))
  Some(value = Val(ty = NI32, value = NLocal(name = n)))
}

/// The list and slice members that are one kernel call; the receiver is `ins[0]`.
func lowerCollectionBuiltin(c: in LCtx, name: in String, ins: in List[TExpr]): Option[Val] {
  if ins.count == 0 or not isListTy(ins[0].ty) {
    return None
  }
  val recvTy = ins[0].ty
  val isLen = (name == "slice.length" or name == "List.count") and ins.count == 1
  val isAdd = name == "List.add" and ins.count == 2
  val isInsert = name == "List.add" and ins.count == 3
  val isRemoveAt = name == "List.removeAt" and ins.count == 2
  val isClear = name == "List.clear" and ins.count == 1
  val isCopy = (name == "List.toArray" or name == "slice.toList") and ins.count == 1
  val isSlice = name == "slice.slice" and ins.count == 3
  val isConcat = name == "slice.concat" and ins.count == 2
  val isAppend = name == "slice.append" and ins.count == 2
  if not (isLen or isAdd or isInsert or isRemoveAt or isClear or isCopy or isSlice or isConcat or isAppend) {
    return None
  }
  if not tyLowers(c.env, recvTy) {
    return None
  }
  val l = borrow(c, lowerExpr(c, ins[0]))
  if isLen {
    val n = callRt(c, "lyric_list_len", NI64, arg1(i8ptr(), listAsI8(c, l)))
    val d = tmp(c)
    c.insns.add(NTrunc(dest = d, fromTy = NI64, value = n, toTy = NI32))
    return Some(value = Val(ty = NI32, value = NLocal(name = d)))
  }
  if isAdd {
    pushOnto(c, l, ins[1])
    return Some(value = unitVal())
  }
  if isInsert {
    val idx = wideIndex(c, ins[1])
    val v = borrow(c, lowerExpr(c, ins[2]))
    val args: List[NArg] = newList()
    args.add(NArg(ty = i8ptr(), value = listAsI8(c, l)))
    args.add(NArg(ty = NI64, value = idx))
    args.add(NArg(ty = NI64, value = slotOf(c, v)))
    callRtVoid(c, "lyric_list_insert", args)
    return Some(value = unitVal())
  }
  if isRemoveAt {
    val idx = wideIndex(c, ins[1])
    callRtVoid(c, "lyric_list_remove_at", arg2(i8ptr(), listAsI8(c, l), NI64, idx))
    return Some(value = unitVal())
  }
  if isClear {
    callRtVoid(c, "lyric_list_clear", arg1(i8ptr(), listAsI8(c, l)))
    return Some(value = unitVal())
  }
  // The combinators return a fresh list (a reference element is retained by it) of the same
  // representation, so the result keeps the receiver's type.
  var raw: NValue = NLocal(name = "")
  if isCopy {
    raw = callRt(c, "lyric_list_copy", i8ptr(), arg1(i8ptr(), listAsI8(c, l)))
  } else if isSlice {
    val from = wideIndex(c, ins[1])
    val to = wideIndex(c, ins[2])
    val args: List[NArg] = newList()
    args.add(NArg(ty = i8ptr(), value = listAsI8(c, l)))
    args.add(NArg(ty = NI64, value = from))
    args.add(NArg(ty = NI64, value = to))
    raw = callRt(c, "lyric_list_slice", i8ptr(), args)
  } else if isConcat {
    val other = borrow(c, lowerExpr(c, ins[1]))
    raw = callRt(c, "lyric_list_concat", i8ptr(), arg2(i8ptr(), listAsI8(c, l), i8ptr(), listAsI8(c, other)))
  } else {
    val v = borrow(c, lowerExpr(c, ins[1]))
    raw = callRt(c, "lyric_list_append", i8ptr(), arg2(i8ptr(), listAsI8(c, l), NI64, slotOf(c, v)))
  }
  val d = tmp(c)
  c.insns.add(NBitcast(dest = d, fromTy = i8ptr(), value = raw, toTy = l.ty))
  Some(value = Val(ty = l.ty, value = NLocal(name = d), owned = true))
}

/// `panic(message)`: the message as a C string, the package label and the line, then no way on.
func lowerPanicCall(c: in LCtx, msg: in TExpr, line: in Int): Val {
  val m = borrow(c, lowerExpr(c, msg))
  if not isStringN(m.ty) {
    return unsupported(c, "a panic message that is no string")
  }
  panicWithString(c, m, line)
  unitVal()
}

/// Panic with the message in `m` (a `String`), then start a block nothing reaches.
func panicWithString(c: in LCtx, m: in Val, line: in Int): Unit {
  val cs = callRt(c, "lyric_string_to_cstring", NPtr(pointee = NI8), arg1(lyricStringNType(), m.value))
  val filePtr = cString(c, c.env.panicFile)
  val args: List[NArg] = newList()
  args.add(NArg(ty = NPtr(pointee = NI8), value = cs))
  args.add(NArg(ty = NPtr(pointee = NI8), value = NLocal(name = filePtr)))
  args.add(NArg(ty = NI32, value = NLitInt(v = line.toLong(), ty = NI32)))
  c.insns.add(NCallVoid(fn = NGlobal(name = "lyric_panic_msg"), args = args))
  c.insns.add(NUnreachable)
  startBlock(c, newLabel(c, "dead"))
}

/// `panic("index <i> out of range for array[<n>]")`.  The message's temporaries live on this
/// path only, which never returns, so their statement scope is dropped without a release.
func arrayOobPanic(c: in LCtx, iv: in NValue, n: in Int, line: in Int): Unit {
  pushTemps(c)
  val head = stringLiteral(c, "index ")
  val idx = borrow(c, scalarToString(c, TPrim(kind = TPInt), Val(ty = NI32, value = iv)))
  val joined = borrow(c, lowerStringBinary(c, IoAdd, head, idx))
  val tail = stringLiteral(c, " out of range for array[" + toString(n) + "]")
  val msg = borrow(c, lowerStringBinary(c, IoAdd, joined, tail))
  panicWithString(c, msg, line)
  c.temps.removeAt(c.temps.count - 1)
}

/// The `i32` index of an access to an `array[n, _]`, panicking when it is outside `0 ..< n`.
func arrayIndexValue(c: in LCtx, idx: in TExpr, n: in Int, line: in Int): Option[NValue] {
  val v = borrow(c, lowerExpr(c, idx))
  match v.ty {
    case NI32 -> ()
    case _ -> {
      c.problems.add("an array index of type " + renderTy(idx.ty))
      return None
    }
  }
  val ok = tmp(c)
  c.insns.add(NICmp(dest = ok, pred = IUlt, ty = NI32, a = v.value, b = NLitInt(v = n.toLong(), ty = NI32)))
  val okL = newLabel(c, "arr.in")
  val badL = newLabel(c, "arr.oob")
  c.insns.add(NCondBr(cond = NLocal(name = ok), thenLabel = okL, elseLabel = badL))
  startBlock(c, badL)
  arrayOobPanic(c, v.value, n, line)
  c.insns.add(NBr(label = okL))
  startBlock(c, okL)
  Some(value = v.value)
}

/// `&arr[idx]` for the inline array at `base`.
func arrayElemPtr(c: in LCtx, arrTy: in NType, base: in NValue, idx: in NValue): NValue {
  val d = tmp(c)
  val ix: List[NArg] = newList()
  ix.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  ix.add(NArg(ty = NI32, value = idx))
  c.insns.add(NGEP(dest = d, ty = arrTy, ptr = base, indices = ix))
  NLocal(name = d)
}

/// The address of the array storage `e` denotes, when it is a place: a local's slot, a field of
/// a heap record, a field of a by-value record in a place, or an element of an inline array in a
/// place.  None for anything else (a call result), which is read as a value.
func arrayPlaceAddr(c: in LCtx, e: in TExpr): Option[NValue] {
  match e.kind {
    case XLocal(id) -> match mapGet(c.slots, id.id) {
      case Some(slot) -> match slot.ty {
        case NVoid -> None
        case _ -> Some(value = NLocal(name = slot.ptr))
      }
      case None -> None
    }
    case XField(recv, field) -> match fieldOwnerLayout(c, field.owner) {
      case None -> None
      case Some(lay) -> {
        if field.index < 0 or field.index >= lay.fieldTys.count {
          return None
        }
        if lay.byValue {
          match arrayPlaceAddr(c, recv) {
            case None -> None
            case Some(base) -> {
              val d = tmp(c)
              val ix: List[NArg] = newList()
              ix.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
              ix.add(NArg(ty = NI32, value = NLitInt(v = field.index.toLong(), ty = NI32)))
              c.insns.add(NGEP(dest = d, ty = lay.ty, ptr = base, indices = ix))
              Some(value = NLocal(name = d))
            }
          }
        } else {
          match heapFieldPlace(c, recv, field) {
            case Some(fp) -> Some(value = fp.value)
            case None -> None
          }
        }
      }
    }
    case XIndex(recv, idx, how) -> match how {
      case IkArray -> match arrayElemPlace(c, recv, idx, e.span.startPos.line) {
        case Some(p) -> Some(value = p.value)
        case None -> None
      }
      case _ -> None
    }
    case _ -> None
  }
}

/// The address of element `idx` of the array `recv` denotes, typed with the element's type: the
/// array is addressed in place when it is one, and is otherwise a stack copy of its value.
func arrayElemPlace(c: in LCtx, recv: in TExpr, idx: in TExpr, line: in Int): Option[Val] {
  val arrTy = match tyToN(c.env, recv.ty) {
    case Some(t) -> t
    case None -> {
      c.problems.add("indexing " + renderTy(recv.ty))
      return None
    }
  }
  val el = match arrTy {
    case NArray(e, _) -> e
    case _ -> {
      c.problems.add("an array index on " + renderTy(recv.ty))
      return None
    }
  }
  val n = match arrTy { case NArray(_, k) -> k; case _ -> 0 }
  val base = match arrayPlaceAddr(c, recv) {
    case Some(a) -> a
    case None -> {
      val v = lowerExpr(c, recv)
      val name = "arr.tmp" + toString(c.ticker.count + 1)
      c.ticker.add(0)
      c.allocas.add(NAlloca(dest = name, ty = arrTy))
      c.insns.add(NStore(ty = arrTy, value = v.value, ptr = NLocal(name = name)))
      NLocal(name = name)
    }
  }
  match arrayIndexValue(c, idx, n, line) {
    case None -> None
    case Some(i) -> Some(value = Val(ty = el, value = arrayElemPtr(c, arrTy, base, i)))
  }
}

/// `a[i]` on an inline array: the element is read through its address, never by loading the
/// whole array.
func lowerArrayIndex(c: in LCtx, recv: in TExpr, idx: in TExpr, line: in Int): Val {
  if isHeapArray(c, recv.ty) {
    return lowerHeapArrayIndex(c, recv, idx, line)
  }
  match arrayElemPlace(c, recv, idx, line) {
    case None -> unitVal()
    case Some(p) -> {
      val d = tmp(c)
      c.insns.add(NLoad(dest = d, ty = p.ty, ptr = p.value))
      Val(ty = p.ty, value = NLocal(name = d))
    }
  }
}

/// An array held as a reference-counted list (its elements are not held by value).
func isHeapArray(c: in LCtx, t: in Ty): Bool {
  match t {
    case TArray(_, _) -> match tyToN(c.env, t) {
      case Some(nt) -> match nt { case NArray(_, _) -> false; case _ -> true }
      case None -> false
    }
    case _ -> false
  }
}

func heapArrayLen(t: in Ty): Option[Int] {
  match t {
    case TArray(len, _) -> match len { case ALKnown(k) -> Some(value = k); case _ -> None }
    case _ -> None
  }
}

/// `a[i]` on an array held as a list: the index is checked against the array's length first (the
/// panic message of an inline array), then the element is read from the list.
func lowerHeapArrayIndex(c: in LCtx, recv: in TExpr, idx: in TExpr, line: in Int): Val {
  val n = match heapArrayLen(recv.ty) {
    case Some(k) -> k
    case None -> return unsupported(c, "indexing " + renderTy(recv.ty))
  }
  val el = match listElemN(c, recv.ty) {
    case Some(x) -> x
    case None -> return unsupported(c, "indexing " + renderTy(recv.ty))
  }
  val l = borrow(c, lowerExpr(c, recv))
  val iv = match arrayIndexValue(c, idx, n, line) { case Some(x) -> x; case None -> return unitVal() }
  val wide = tmp(c)
  c.insns.add(NSExt(dest = wide, fromTy = NI32, value = iv, toTy = NI64))
  val slot = callRt(c, "lyric_list_get", NI64, arg2(i8ptr(), listAsI8(c, l), NI64, NLocal(name = wide)))
  fromSlot(c, slot, el)
}

/// `a[i] = v` and `a[i] op= v` on an array held as a list; the kernel retains the new element and
/// releases the old one.
func lowerHeapArraySet(c: in LCtx, recv: in TExpr, idx: in TExpr, op: in AssignKind, value: in TExpr, line: in Int): Val {
  val n = match heapArrayLen(recv.ty) {
    case Some(k) -> k
    case None -> return unsupported(c, "assignment to an element of " + renderTy(recv.ty))
  }
  val el = match listElemN(c, recv.ty) {
    case Some(x) -> x
    case None -> return unsupported(c, "assignment to an element of " + renderTy(recv.ty))
  }
  val l = borrow(c, lowerExpr(c, recv))
  val iv = match arrayIndexValue(c, idx, n, line) { case Some(x) -> x; case None -> return unitVal() }
  val wide = tmp(c)
  c.insns.add(NSExt(dest = wide, fromTy = NI32, value = iv, toTy = NI64))
  val v = match op {
    case AkSet -> borrow(c, lowerExpr(c, value))
    case _ -> {
      val rhs = lowerExpr(c, value)
      val slot = callRt(c, "lyric_list_get", NI64, arg2(i8ptr(), listAsI8(c, l), NI64, NLocal(name = wide)))
      val cur = fromSlot(c, slot, el)
      match compoundElem(c, op, value.ty, el, cur, rhs, line) {
        case Some(nv) -> borrow(c, nv)
        case None -> return unitVal()
      }
    }
  }
  val args: List[NArg] = newList()
  args.add(NArg(ty = i8ptr(), value = listAsI8(c, l)))
  args.add(NArg(ty = NI64, value = NLocal(name = wide)))
  args.add(NArg(ty = NI64, value = slotOf(c, v)))
  callRtVoid(c, "lyric_list_set", args)
  unitVal()
}

/// `XArrayCopy`: an inline array is already a value; an array held as a list is copied (the
/// kernel's copy retains each element).  An array whose elements are arrays would need a deep
/// copy and stays on the AST path.
func lowerArrayCopy(c: in LCtx, inner: in TExpr): Val {
  val v = lowerExpr(c, inner)
  match v.ty {
    case NArray(_, _) -> return v
    case _ -> ()
  }
  match inner.ty {
    case TArray(_, el) -> match el {
      case TArray(_, _) -> return unsupported(c, "a copy of an array of arrays")
      case _ -> ()
    }
    case _ -> return unsupported(c, "a copy of " + renderTy(inner.ty))
  }
  if not isRefN(v.ty) {
    return unsupported(c, "a copy of " + renderTy(inner.ty))
  }
  val l = borrow(c, v)
  val raw = callRt(c, "lyric_list_copy", i8ptr(), arg1(i8ptr(), listAsI8(c, l)))
  val d = tmp(c)
  c.insns.add(NBitcast(dest = d, fromTy = i8ptr(), value = raw, toTy = l.ty))
  Val(ty = l.ty, value = NLocal(name = d), owned = true)
}

/// `XZeroValue`: `var a: array[N, T]` without an initializer, which the checker allows only for an
/// element with a zero value.  An inline array of scalar leaves is `zeroinitializer`.  A record
/// element's zero is the all-zero bit pattern when the record has no field defaults (`zeroBits`) and
/// every field is itself zero-bits; a record with a default stays on the AST path, which builds the
/// checker's zero expression.  An array held as a list has no zero value (a `String` or a reference element has none, T0156), so
/// those stay on the AST path.
func lowerZeroValue(c: in LCtx, ty: in Ty): Val {
  val nt = match tyToN(c.env, ty) {
    case Some(x) -> x
    case None -> return unsupported(c, "the zero value of " + renderTy(ty))
  }
  match nt {
    case NArray(_, _) -> {
      if not arrayZeroOk(c.env, nt) {
        return unsupported(c, "the zero value of " + renderTy(ty))
      }
      Val(ty = nt, value = NZeroInit(ty = nt))
    }
    case _ -> unsupported(c, "the zero value of " + renderTy(ty))
  }
}

/// `a[i] = v` and `a[i] op= v` on an inline array.  The right-hand side is evaluated after the
/// index and before the element is read.
func lowerArraySet(c: in LCtx, recv: in TExpr, idx: in TExpr, op: in AssignKind, value: in TExpr, line: in Int): Val {
  if isHeapArray(c, recv.ty) {
    return lowerHeapArraySet(c, recv, idx, op, value, line)
  }
  match arrayElemPlace(c, recv, idx, line) {
    case None -> unitVal()
    case Some(p) -> match p.value {
      case NLocal(name) -> assignSlot(c, Slot(ptr = name, ty = p.ty), elemTyOf(recv.ty), op, value)
      case _ -> unsupported(c, "an assignment to an array element")
    }
  }
}

func elemTyOf(t: in Ty): Ty {
  match t {
    case TArray(_, e) -> e
    case _ -> t
  }
}

/// `[a, b, c]` against an inline array type: an `insertvalue` chain.
func lowerArrayLit(c: in LCtx, arrTy: in NType, elems: in List[TExpr]): Val {
  val el = match arrTy { case NArray(e, _) -> e; case _ -> return unsupported(c, "an array literal") }
  val n = match arrTy { case NArray(_, k) -> k; case _ -> 0 }
  if elems.count != n {
    return unsupported(c, "an array literal of " + toString(elems.count) + " elements for length " + toString(n))
  }
  var agg: NValue = NUndef(ty = arrTy)
  var i = 0
  while i < n {
    val v = lowerExpr(c, elems[i])
    if nTypeToIrString(v.ty) != nTypeToIrString(el) {
      return unsupported(c, "an array literal element of type " + renderTy(elems[i].ty))
    }
    val d = tmp(c)
    c.insns.add(NInsertValue(dest = d, aggTy = arrTy, agg = agg, elemTy = el, elem = v.value, index = i))
    agg = NLocal(name = d)
    i = i + 1
  }
  Val(ty = arrTy, value = agg)
}

/// The zero value of `var a: array[N, T]` without an initializer: every element zero, which is
/// the checker's zero value only for scalar elements.
func arrayZeroOk(env: in TirLowerEnv, t: in NType): Bool {
  match t {
    case NArray(e, _) -> isScalarN(e) or arrayZeroOk(env, e) or structZeroOk(env, e)
    case _ -> false
  }
}

/// A by-value record whose zero value is all-zero bits: no field default, and every field a
/// scalar, an array of zero-bits elements or another such record.
func structZeroOk(env: in TirLowerEnv, t: in NType): Bool {
  match t {
    case NStruct(_, _) -> {
      val want = nTypeToIrString(t)
      for l in mapValues(env.recs) {
        if l.byValue and l.zeroBits and nTypeToIrString(l.ty) == want {
          for ft in l.fieldTys {
            if not (isScalarN(ft) or arrayZeroOk(env, ft) or structZeroOk(env, ft)) {
              return false
            }
          }
          return true
        }
      }
      false
    }
    case _ -> false
  }
}

/// `for x in a` on an inline array: the loop runs over a stack copy, so the body cannot change
/// what it iterates.
func lowerForArray(c: in LCtx, label: in Option[String], pat: in TPat, iter: in TExpr, body: in TExpr): Unit {
  val arrTy = match tyToN(c.env, iter.ty) {
    case Some(t) -> t
    case None -> {
      c.problems.add("a for over " + renderTy(iter.ty))
      return
    }
  }
  val el = match arrTy {
    case NArray(e, _) -> e
    case _ -> {
      c.problems.add("a for over " + renderTy(iter.ty))
      return
    }
  }
  val n = match arrTy { case NArray(_, k) -> k; case _ -> 0 }
  val v = lowerExpr(c, iter)
  val copyName = "for" + toString(c.ticker.count + 1) + ".arr"
  c.ticker.add(0)
  c.allocas.add(NAlloca(dest = copyName, ty = arrTy))
  c.insns.add(NStore(ty = arrTy, value = v.value, ptr = NLocal(name = copyName)))
  val slotName = "for" + toString(c.ticker.count + 1) + ".i"
  c.ticker.add(0)
  c.allocas.add(NAlloca(dest = slotName, ty = NI32))
  c.insns.add(NStore(ty = NI32, value = NLitInt(v = 0i64, ty = NI32), ptr = NLocal(name = slotName)))
  val condL = newLabel(c, "for.cond")
  val bodyL = newLabel(c, "for.body")
  val stepL = newLabel(c, "for.step")
  val endL = newLabel(c, "for.end")
  c.insns.add(NBr(label = condL))
  startBlock(c, condL)
  val cur = tmp(c)
  c.insns.add(NLoad(dest = cur, ty = NI32, ptr = NLocal(name = slotName)))
  val ok = tmp(c)
  c.insns.add(NICmp(dest = ok, pred = ISlt, ty = NI32, a = NLocal(name = cur), b = NLitInt(v = n.toLong(), ty = NI32)))
  c.insns.add(NCondBr(cond = NLocal(name = ok), thenLabel = bodyL, elseLabel = endL))
  startBlock(c, bodyL)
  val depth = c.refScopes.count
  val tdepth = c.temps.count
  pushRefScope(c)
  val ptr = arrayElemPtr(c, arrTy, NLocal(name = copyName), NLocal(name = cur))
  val ev = tmp(c)
  c.insns.add(NLoad(dest = ev, ty = el, ptr = ptr))
  patBind(c, pat, Val(ty = el, value = NLocal(name = ev)))
  c.loops.add(LoopLabels(label = label, breakL = endL, contL = stepL, scopeDepth = depth, tempDepth = tdepth))
  discard(c, lowerExpr(c, body))
  c.loops.removeAt(c.loops.count - 1)
  popRefScope(c)
  c.insns.add(NBr(label = stepL))
  startBlock(c, stepL)
  val at = tmp(c)
  c.insns.add(NLoad(dest = at, ty = NI32, ptr = NLocal(name = slotName)))
  val next = tmp(c)
  c.insns.add(NAdd(dest = next, ty = NI32, a = NLocal(name = at), b = NLitInt(v = 1i64, ty = NI32)))
  c.insns.add(NStore(ty = NI32, value = NLocal(name = next), ptr = NLocal(name = slotName)))
  c.insns.add(NBr(label = condL))
  startBlock(c, endL)
}

/// A `String` argument widened to the runtime's 64-bit index.
func wideIndex(c: in LCtx, e: in TExpr): NValue {
  val v = borrow(c, lowerExpr(c, e))
  val d = tmp(c)
  c.insns.add(NSExt(dest = d, fromTy = v.ty, value = v.value, toTy = NI64))
  NLocal(name = d)
}

/// The `String` methods that are one runtime call: the receiver is `ins[0]`.  A result `String`
/// is owned by the caller; a predicate is an `i1`.  `indexOf` is left to the caller's imports
/// (it is an `Option[Int]` or the raw index depending on them).
func lowerStringMethod(c: in LCtx, name: in String, ins: in List[TExpr]): Option[Val] {
  if not Str.startsWith(name, "String.") or ins.count == 0 {
    return None
  }
  val method = Str.substring(name, 7)
  val sTy = lyricStringNType()
  val n = ins.count
  if (method == "trim" or method == "trimStart" or method == "trimEnd" or method == "toLower" or method == "toUpper") and n == 1 {
    val fn = match method {
      case "trim" -> "lyric_string_trim"
      case "trimStart" -> "lyric_string_trim_start"
      case "trimEnd" -> "lyric_string_trim_end"
      case "toLower" -> "lyric_string_to_lower"
      case _ -> "lyric_string_to_upper"
    }
    val r = borrow(c, lowerExpr(c, ins[0]))
    return Some(value = Val(ty = sTy, value = callRt(c, fn, sTy, arg1(sTy, r.value)), owned = true))
  }
  if method == "substring" and n == 3 {
    val r = borrow(c, lowerExpr(c, ins[0]))
    val start = wideIndex(c, ins[1])
    val len = wideIndex(c, ins[2])
    val args: List[NArg] = newList()
    args.add(NArg(ty = sTy, value = r.value))
    args.add(NArg(ty = NI64, value = start))
    args.add(NArg(ty = NI64, value = len))
    return Some(value = Val(ty = sTy, value = callRt(c, "lyric_string_substring", sTy, args), owned = true))
  }
  if method == "substring" and n == 2 {
    val r = borrow(c, lowerExpr(c, ins[0]))
    val start = wideIndex(c, ins[1])
    val total = callRt(c, "lyric_string_len", NI64, arg1(sTy, r.value))
    val rest = tmp(c)
    c.insns.add(NSub(dest = rest, ty = NI64, a = total, b = start))
    val args: List[NArg] = newList()
    args.add(NArg(ty = sTy, value = r.value))
    args.add(NArg(ty = NI64, value = start))
    args.add(NArg(ty = NI64, value = NLocal(name = rest)))
    return Some(value = Val(ty = sTy, value = callRt(c, "lyric_string_substring", sTy, args), owned = true))
  }
  if method == "replace" and n == 3 {
    val r = borrow(c, lowerExpr(c, ins[0]))
    val a = borrow(c, lowerExpr(c, ins[1]))
    val b = borrow(c, lowerExpr(c, ins[2]))
    val args: List[NArg] = newList()
    args.add(NArg(ty = sTy, value = r.value))
    args.add(NArg(ty = sTy, value = a.value))
    args.add(NArg(ty = sTy, value = b.value))
    return Some(value = Val(ty = sTy, value = callRt(c, "lyric_string_replace", sTy, args), owned = true))
  }
  if method == "codeUnitAt" and n == 2 {
    val r = borrow(c, lowerExpr(c, ins[0]))
    val idx = wideIndex(c, ins[1])
    val byte = callRt(c, "lyric_string_byte_at", NI8, arg2(sTy, r.value, NI64, idx))
    val d = tmp(c)
    c.insns.add(NZExt(dest = d, fromTy = NI8, value = byte, toTy = NI32))
    return Some(value = Val(ty = NI32, value = NLocal(name = d)))
  }
  if (method == "startsWith" or method == "endsWith" or method == "contains") and n == 2 {
    val fn = match method {
      case "startsWith" -> "lyric_string_starts_with"
      case "endsWith" -> "lyric_string_ends_with"
      case _ -> "lyric_string_contains"
    }
    val r = borrow(c, lowerExpr(c, ins[0]))
    val a = borrow(c, lowerExpr(c, ins[1]))
    val raw = callRt(c, fn, NI32, arg2(sTy, r.value, sTy, a.value))
    return Some(value = Val(ty = NI1, value = icmpV(c, INe, NI32, raw, intLit(NI32, 0i64))))
  }
  None
}

/// The numeric conversions between `Int`, `Long`, `Byte` and `Double` whose semantics do not depend
/// on more than the source type (`UInt`, `ULong`, `Nat`, `Char` and `Float` sources stay on the AST
/// path): widening is sign- or zero-extending by the source's signedness, narrowing truncates,
/// `Double` to an integer is `fptosi`.
func lowerNumericConversion(c: in LCtx, name: in String, ins: in List[TExpr], line: in Int): Option[Val] {
  val dot = match Str.indexOf(name, ".") { case Some(i) -> i; case None -> return None }
  val from = Str.substring(name, 0, dot)
  val method = Str.substring(name, dot + 1)
  if not (from == "Int" or from == "Long" or from == "Byte" or from == "UInt" or from == "ULong" or from == "Double" or from == "Float" or from == "Char" or from == "Nat") {
    return None
  }
  if ins.count == 2 and (method == "and" or method == "or" or method == "xor" or method == "shl" or method == "shr") {
    return Some(value = lowerBitwise(c, from, method, ins))
  }
  if ins.count != 1 {
    return None
  }
  // The contract elaborator rewrites these three into a checked or corrected block on the AST (D278,
  // always on); TIR does not carry that rewrite until phase 3c, so the function stays on the AST path.
  if from == "ULong" and (method == "toLong" or method == "toDouble" or method == "toFloat") {
    return None
  }
  val unsigned = from == "UInt" or from == "ULong" or from == "Byte"
  val v0 = borrow(c, lowerExpr(c, ins[0]))
  val isFloat = match v0.ty { case NFloat -> true; case _ -> false }
  if isFloat and method == "toFloat" {
    return Some(value = v0)
  }
  // A `Float` converts as the `Double` it widens to exactly.
  val v = if isFloat {
    val w = tmp(c)
    c.insns.add(NFPExt(dest = w, value = v0.value))
    Val(ty = NDouble, value = NLocal(name = w))
  } else {
    v0
  }
  val isInt = bitsOf(v.ty) > 0
  val isDouble = match v.ty { case NDouble -> true; case _ -> false }
  if not (isInt or isDouble) {
    return None
  }
  if method == "toFloat" or method == "toDouble" {
    val target = if method == "toFloat" { NFloat } else { NDouble }
    if isDouble {
      if method == "toDouble" {
        return Some(value = v)
      }
      val d = tmp(c)
      c.insns.add(NFPTrunc(dest = d, value = v.value))
      return Some(value = Val(ty = NFloat, value = NLocal(name = d)))
    }
    if from == "UInt" or from == "ULong" {
      return None
    }
    val src = if bitsOf(v.ty) == 8 { zextTo(c, v, NI32) } else { v }
    val d = tmp(c)
    c.insns.add(NSIToFP(dest = d, fromTy = src.ty, value = src.value, toTy = target))
    return Some(value = Val(ty = target, value = NLocal(name = d)))
  }
  if method == "toLong" or method == "toInt" or method == "toByte" or method == "toULong" or method == "toUInt" {
    val target = if method == "toLong" or method == "toULong" { NI64 } else if method == "toByte" { NI8 } else { NI32 }
    if isDouble {
      if method == "toULong" or method == "toUInt" {
        return None
      }
      // Truncate toward zero; a `Byte` keeps the low 8 bits of the `Long`.
      val wideTy = if method == "toByte" { NI64 } else { target }
      val d = tmp(c)
      c.insns.add(NFPToSI(dest = d, fromTy = NDouble, value = v.value, toTy = wideTy))
      val w = Val(ty = wideTy, value = NLocal(name = d))
      return Some(value = if method == "toByte" { truncTo(c, w, NI8) } else { w })
    }
    if bitsOf(target) == bitsOf(v.ty) {
      return Some(value = Val(ty = target, value = v.value))
    }
    if bitsOf(target) > bitsOf(v.ty) {
      // A widening from an unsigned source or to an unsigned target zero-extends.
      return Some(
        value = if unsigned or method == "toULong" or method == "toUInt" {
          zextTo(c, v, target)
        } else {
          sextTo(c, v, target)
        }
      )
    }
    return Some(value = truncTo(c, v, target))
  }
  if method == "toNat" {
    // Checked: `Nat` is the non-negative `Long` it lowers to.  A `Byte` and a
    // `Char` cannot be negative.
    if isDouble {
      // Truncation toward zero follows, so the bound is an exclusive -1.0; the
      // ordered compare is false for NaN.
      val gt = tmp(c)
      c.insns.add(NFCmp(dest = gt, pred = FOgt, ty = NDouble, a = v.value, b = NLitFloat(v = 0.0 - 1.0, ty = NDouble)))
      val bad = tmp(c)
      c.insns.add(NXor(dest = bad, ty = NI1, a = NLocal(name = gt), b = NLitInt(v = 1i64, ty = NI1)))
      trapIf(c, NLocal(name = bad), Lex.toNatRangeMessage(), line)
      val d = tmp(c)
      c.insns.add(NFPToSI(dest = d, fromTy = NDouble, value = v.value, toTy = NI64))
      return Some(value = Val(ty = NI64, value = NLocal(name = d)))
    }
    if from == "Byte" {
      return Some(value = zextTo(c, v, NI64))
    }
    val wide = if bitsOf(v.ty) == 64 { v } else { sextTo(c, v, NI64) }
    if from != "Char" {
      trapIf(c, icmpV(c, ISlt, NI64, wide.value, intLit(NI64, 0i64)), Lex.toNatRangeMessage(), line)
    }
    return Some(value = Val(ty = NI64, value = wide.value))
  }
  if method == "toChar" {
    // Checked narrowing: a `Char` is a BMP scalar value, never a surrogate.
    val vi = if isDouble {
      val gt = icmpFV(c, FOgt, v.value, 0.0 - 1.0)
      val lt = icmpFV(c, FOlt, v.value, 65536.0)
      val inRange = tmp(c)
      c.insns.add(NAnd(dest = inRange, ty = NI1, a = gt, b = lt))
      val outOfRange = tmp(c)
      c.insns.add(NXor(dest = outOfRange, ty = NI1, a = NLocal(name = inRange), b = NLitInt(v = 1i64, ty = NI1)))
      trapIf(c, NLocal(name = outOfRange), Lex.toCharRangeMessage(), line)
      val d = tmp(c)
      c.insns.add(NFPToSI(dest = d, fromTy = NDouble, value = v.value, toTy = NI32))
      Val(ty = NI32, value = NLocal(name = d))
    } else if bitsOf(v.ty) == 8 {
      return Some(value = zextTo(c, v, NI32))
    } else {
      v
    }
    trapIf(c, charBad(c, vi), Lex.toCharRangeMessage(), line)
    return Some(value = if bitsOf(vi.ty) == 64 { truncTo(c, vi, NI32) } else { vi })
  }
  None
}

func icmpFV(c: in LCtx, pred: in FCmpPred, a: in NValue, k: in Double): NValue {
  val d = tmp(c)
  c.insns.add(NFCmp(dest = d, pred = pred, ty = NDouble, a = a, b = NLitFloat(v = k, ty = NDouble)))
  NLocal(name = d)
}

/// True when `x` is above `U+FFFF` or in the surrogate range `U+D800..U+DFFF`.
func charBad(c: in LCtx, x: in Val): NValue {
  val ty = x.ty
  val over = icmpV(c, IUgt, ty, x.value, intLit(ty, 65535i64))
  val off = tmp(c)
  c.insns.add(NSub(dest = off, ty = ty, a = x.value, b = intLit(ty, 55296i64)))
  val surr = icmpV(c, IUlt, ty, NLocal(name = off), intLit(ty, 2048i64))
  val bad = tmp(c)
  c.insns.add(NOr(dest = bad, ty = NI1, a = over, b = surr))
  NLocal(name = bad)
}

func zextTo(c: in LCtx, v: in Val, to: in NType): Val {
  val d = tmp(c)
  c.insns.add(NZExt(dest = d, fromTy = v.ty, value = v.value, toTy = to))
  Val(ty = to, value = NLocal(name = d))
}

func sextTo(c: in LCtx, v: in Val, to: in NType): Val {
  val d = tmp(c)
  c.insns.add(NSExt(dest = d, fromTy = v.ty, value = v.value, toTy = to))
  Val(ty = to, value = NLocal(name = d))
}

func truncTo(c: in LCtx, v: in Val, to: in NType): Val {
  val d = tmp(c)
  c.insns.add(NTrunc(dest = d, fromTy = v.ty, value = v.value, toTy = to))
  Val(ty = to, value = NLocal(name = d))
}

/// `a.and(b)`, `.or`, `.xor`, `.shl` and `.shr` on an integer.  A shift amount is an `Int`
/// converted to the operand's width; `.shr` is logical for `Byte`, `UInt` and `ULong` and
/// arithmetic for the signed widths.
func lowerBitwise(c: in LCtx, from: in String, method: in String, ins: in List[TExpr]): Val {
  val a = borrow(c, lowerExpr(c, ins[0]))
  val b0 = borrow(c, lowerExpr(c, ins[1]))
  val ty = a.ty
  if bitsOf(ty) == 0 {
    return unsupported(c, "bitwise " + method + " on " + from)
  }
  val isShift = method == "shl" or method == "shr"
  val bv = if isShift and bitsOf(b0.ty) != bitsOf(ty) {
    if bitsOf(ty) > bitsOf(b0.ty) {
      sextTo(c, b0, ty).value
    } else {
      truncTo(c, b0, ty).value
    }
  } else {
    b0.value
  }
  val d = tmp(c)
  if method == "and" {
    c.insns.add(NAnd(dest = d, ty = ty, a = a.value, b = bv))
  } else if method == "or" {
    c.insns.add(NOr(dest = d, ty = ty, a = a.value, b = bv))
  } else if method == "xor" {
    c.insns.add(NXor(dest = d, ty = ty, a = a.value, b = bv))
  } else if method == "shl" {
    c.insns.add(NShl(dest = d, ty = ty, a = a.value, b = bv))
  } else if from == "Byte" or from == "UInt" or from == "ULong" {
    c.insns.add(NLShr(dest = d, ty = ty, a = a.value, b = bv))
  } else {
    c.insns.add(NAShr(dest = d, ty = ty, a = a.value, b = bv))
  }
  Val(ty = ty, value = NLocal(name = d))
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

/// A heap record used as an interface it implements: a box holding the (retained) object and
/// the record's vtable for the interface.  The box is owned by the caller.
func lowerUpcast(c: in LCtx, e: in TExpr, iface: in SymbolId, inner: in TExpr): Val {
  val il = match mapGet(c.env.ifaces, iface.id) {
    case Some(x) -> x
    case None -> return unsupported(c, "an upcast to " + renderTy(e.ty))
  }
  val recId = match inner.ty {
    case TNamed(sym, targs) -> if targs.count == 0 {
      sym.id
    } else {
      return unsupported(c, "an upcast of " + renderTy(inner.ty))
    }
    case _ -> return unsupported(c, "an upcast of " + renderTy(inner.ty))
  }
  val vt = match mapGet(c.env.ifaceVts, toString(recId) + "|" + toString(iface.id)) {
    case Some(g) -> g
    case None -> return unsupported(c, "an upcast of " + renderTy(inner.ty) + " to " + renderTy(e.ty))
  }
  val v = borrow(c, lowerExpr(c, inner))
  if not isRefN(v.ty) {
    return unsupported(c, "an upcast of a by-value record")
  }
  val box = allocObject(c, il.boxTy, il.structTy, il.dtor)
  val objI8 = tmp(c)
  c.insns.add(NBitcast(dest = objI8, fromTy = v.ty, value = v.value, toTy = i8ptr()))
  callRtVoid(c, "lyric_retain", arg1(i8ptr(), NLocal(name = objI8)))
  val objSlot = tmp(c)
  val oi: List[NArg] = newList()
  oi.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  oi.add(NArg(ty = NI32, value = NLitInt(v = 3i64, ty = NI32)))
  c.insns.add(NGEP(dest = objSlot, ty = il.structTy, ptr = box, indices = oi))
  c.insns.add(NStore(ty = i8ptr(), value = NLocal(name = objI8), ptr = NLocal(name = objSlot)))
  val vtSlot = tmp(c)
  val vi: List[NArg] = newList()
  vi.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  vi.add(NArg(ty = NI32, value = NLitInt(v = 4i64, ty = NI32)))
  c.insns.add(NGEP(dest = vtSlot, ty = il.structTy, ptr = box, indices = vi))
  c.insns.add(NStore(ty = NPtr(pointee = il.vtTy), value = NGlobal(name = vt), ptr = NLocal(name = vtSlot)))
  Val(ty = il.boxTy, value = box, owned = true)
}

/// A call of a plain interface method: the erased object and the vtable come out of the box, the
/// vtable slot holds the method, which takes the object as `i8*` and then the arguments.
func lowerIfaceCall(c: in LCtx, e: in TExpr, method: in SymbolId, args: in List[TArg]): Val {
  val mr = match mapGet(c.env.ifaceMethods, method.id) {
    case Some(x) -> x
    case None -> return unsupported(c, "an interface method with no slot")
  }
  val il = match mapGet(c.env.ifaces, mr.ifaceId) {
    case Some(x) -> x
    case None -> return unsupported(c, "an interface with no layout")
  }
  val m = il.methods[mr.slot]
  if not m.plain {
    return unsupported(c, "the interface method " + m.name)
  }
  if args.count != m.paramTys.count + 1 {
    return unsupported(c, "the interface method " + m.name + " with " + toString(args.count) + " arguments")
  }
  val vals: List[Val] = newList()
  for a in args {
    match a {
      case TArgIn(v) -> vals.add(borrow(c, lowerExpr(c, v)))
      case _ -> {
        c.problems.add("an out argument of an interface method")
        return unitVal()
      }
    }
  }
  val recv = vals[0]
  if nTypeToIrString(recv.ty) != nTypeToIrString(il.boxTy) {
    return unsupported(c, "an interface call on a value that is not the interface box")
  }
  var i = 0
  while i < m.paramTys.count {
    if nTypeToIrString(vals[i + 1].ty) != nTypeToIrString(m.paramTys[i]) {
      return unsupported(c, "an interface argument of another type than the vtable slot's")
    }
    i = i + 1
  }
  val objSlot = tmp(c)
  val oi: List[NArg] = newList()
  oi.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  oi.add(NArg(ty = NI32, value = NLitInt(v = 3i64, ty = NI32)))
  c.insns.add(NGEP(dest = objSlot, ty = il.structTy, ptr = recv.value, indices = oi))
  val obj = tmp(c)
  c.insns.add(NLoad(dest = obj, ty = i8ptr(), ptr = NLocal(name = objSlot)))
  val vtSlot = tmp(c)
  val vi: List[NArg] = newList()
  vi.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  vi.add(NArg(ty = NI32, value = NLitInt(v = 4i64, ty = NI32)))
  c.insns.add(NGEP(dest = vtSlot, ty = il.structTy, ptr = recv.value, indices = vi))
  val vtPtrTy = NPtr(pointee = il.vtTy)
  val vtbl = tmp(c)
  c.insns.add(NLoad(dest = vtbl, ty = vtPtrTy, ptr = NLocal(name = vtSlot)))
  val fnSlot = tmp(c)
  val mi: List[NArg] = newList()
  mi.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  mi.add(NArg(ty = NI32, value = NLitInt(v = mr.slot.toLong(), ty = NI32)))
  c.insns.add(NGEP(dest = fnSlot, ty = il.vtTy, ptr = NLocal(name = vtbl), indices = mi))
  val fnRaw = tmp(c)
  c.insns.add(NLoad(dest = fnRaw, ty = i8ptr(), ptr = NLocal(name = fnSlot)))
  val fnParamTys: List[NType] = newList()
  fnParamTys.add(i8ptr())
  for pt in m.paramTys {
    fnParamTys.add(pt)
  }
  val fnTyped = tmp(c)
  c.insns.add(
    NBitcast(
      dest = fnTyped,
      fromTy = i8ptr(),
      value = NLocal(name = fnRaw),
      toTy = NFnPtr(params = fnParamTys, ret = m.retTy)
    )
  )
  val callArgs: List[NArg] = newList()
  callArgs.add(NArg(ty = i8ptr(), value = NLocal(name = obj)))
  var k = 1
  while k < vals.count {
    callArgs.add(NArg(ty = vals[k].ty, value = vals[k].value))
    k = k + 1
  }
  match m.retTy {
    case NVoid -> {
      c.insns.add(NCallVoid(fn = NLocal(name = fnTyped), args = callArgs))
      unitVal()
    }
    case rt -> {
      val d = tmp(c)
      c.insns.add(NCall(dest = d, retTy = rt, fn = NLocal(name = fnTyped), args = callArgs))
      Val(ty = rt, value = NLocal(name = d), owned = isRefN(rt))
    }
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
    case CvUpcast(iface) -> lowerUpcast(c, e, iface, inner)
    case CvWrapDistinct(sym) -> if c.env.distincts.containsKey(sym.id) {
      val v = lowerExpr(c, inner)
      match mapGet(c.env.distinctInfos, sym.id) {
        case Some(d) -> if d.hasRange {
          trapIf(c, distinctOutOfRange(c, d, v), distinctRangeMessage(d), e.span.startPos.line)
        }
        case None -> ()
      }
      v
    } else {
      unsupported(c, "a conversion to the distinct type " + renderTyIn(c.env, e.ty))
    }
    case CvUnwrapDistinct(sym) -> if c.env.distincts.containsKey(sym.id) {
      lowerExpr(c, inner)
    } else {
      unsupported(c, "a conversion from the distinct type " + renderTyIn(c.env, inner.ty))
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
      val line = value.span.startPos.line
      val res = rangeCheckedResult(c, placeTy, lowerBinary(c, iop, opTy(c, placeTy), slot.ty, NLocal(name = cur), rhs.value, line), line)
      c.insns.add(NStore(ty = slot.ty, value = res.value, ptr = NLocal(name = slot.ptr)))
    }
  }
  unitVal()
}

/// `xs[i] = v` and `xs[i] op= v` on a `List`; the kernel retains the new element and releases
/// the old one.  A compound assignment evaluates the right-hand side, then reads the element.
func lowerListSet(c: in LCtx, recv: in TExpr, idx: in TExpr, op: in AssignKind, value: in TExpr): Val {
  if not tyLowers(c.env, recv.ty) {
    return unsupported(c, "assignment to an element of " + renderTy(recv.ty))
  }
  val l = borrow(c, lowerExpr(c, recv))
  val i = wideIndex(c, idx)
  val v = match op {
    case AkSet -> borrow(c, lowerExpr(c, value))
    case _ -> {
      val el = match listElemN(c, recv.ty) {
        case Some(x) -> x
        case None -> return unsupported(c, "indexing " + renderTy(recv.ty))
      }
      val rhs = lowerExpr(c, value)
      val slot = callRt(c, "lyric_list_get", NI64, arg2(i8ptr(), listAsI8(c, l), NI64, i))
      val cur = fromSlot(c, slot, el)
      match compoundElem(c, op, value.ty, el, cur, rhs, idx.span.startPos.line) {
        case Some(nv) -> borrow(c, nv)
        case None -> return unitVal()
      }
    }
  }
  val args: List[NArg] = newList()
  args.add(NArg(ty = i8ptr(), value = listAsI8(c, l)))
  args.add(NArg(ty = NI64, value = i))
  args.add(NArg(ty = NI64, value = slotOf(c, v)))
  callRtVoid(c, "lyric_list_set", args)
  unitVal()
}

func lowerAssign(c: in LCtx, place: in TPlace, op: in AssignKind, value: in TExpr): Val {
  match place.kind {
    case PlLocal(id) -> match mapGet(c.slots, id.id) {
      case None -> unsupported(c, "an assignment to a local with no slot")
      case Some(slot) -> match slot.ty {
        case NVoid -> {
          discard(c, lowerExpr(c, value))
          unitVal()
        }
        case _ -> assignSlot(c, slot, place.ty, op, value)
      }
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
    case PlIndex(recv, idx, how) -> match how {
      case IkList -> lowerListSet(c, recv, idx, op, value)
      case IkMap -> lowerMapSet(c, recv, idx, op, value)
      case IkArray -> lowerArraySet(c, recv, idx, op, value, idx.span.startPos.line)
      case _ -> unsupported(c, "an assignment to an element or global")
    }
    case _ -> unsupported(c, "an assignment to an element or global")
  }
}

/// A range pattern with integer bounds on an integer scrutinee.
func intRangeTest(c: in LCtx, lo: in TLit, hi: in TLit, inclusive: in Bool, scrut: in Val, sty: in Ty): Val {
  match litValue(lo) {
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
}

/// A range-pattern bound as a floating-point number.
func floatBound(l: in TLit): Option[Double] {
  match l {
    case TLFloat(f) -> Some(value = f)
    case TLInt(v) -> Some(value = v.toDouble())
    case _ -> None
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
    case TpRecord(_, fields) -> {
      for f in fields {
        if patBinds(f.pat) {
          return true
        }
      }
      false
    }
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

/// Field `field` of the record `obj` (laid out as `lay`): `extractvalue` out of a by-value
/// record, a load through the field pointer of a heap one (borrowed from the object).
func readRecField(c: in LCtx, lay: in TirRecLayout, obj: in NValue, field: in FieldRef): Option[Val] {
  if field.index < 0 or field.index >= lay.fieldTys.count {
    c.problems.add("field " + field.name + " outside its record's layout")
    return None
  }
  match lay.fieldTys[field.index] {
    case NVoid -> {
      c.problems.add("a pattern on the Unit field " + field.name)
      None
    }
    case ft -> {
      val d = tmp(c)
      if lay.byValue {
        c.insns.add(NExtractValue(dest = d, aggTy = lay.ty, agg = obj, index = field.index))
      } else {
        c.insns.add(NLoad(dest = d, ty = ft, ptr = fieldPtr(c, lay, obj, field.index)))
      }
      Some(value = Val(ty = ft, value = NLocal(name = d)))
    }
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
        c.insns.add(
          NFCmp(
            dest = d,
            pred = FOeq,
            ty = scrut.ty,
            a = scrut.value,
            b = NLitFloat(v = floatLitValue(scrut.ty, f), ty = scrut.ty)
          )
        )
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
    case TpRange(lo, hi, inclusive) -> if isFloatTy(sty) {
      match floatBound(lo) {
        case None -> unsupported(c, "a range pattern with a bound that is no number")
        case Some(lf) -> match floatBound(hi) {
          case None -> unsupported(c, "a range pattern with a bound that is no number")
          case Some(hf) -> {
            val geLo = tmp(c)
            c.insns.add(
              NFCmp(
                dest = geLo,
                pred = FOge,
                ty = scrut.ty,
                a = scrut.value,
                b = NLitFloat(v = floatLitValue(scrut.ty, lf), ty = scrut.ty)
              )
            )
            val cmpHi = tmp(c)
            c.insns.add(
              NFCmp(
                dest = cmpHi,
                pred = if inclusive { FOle } else { FOlt },
                ty = scrut.ty,
                a = scrut.value,
                b = NLitFloat(v = floatLitValue(scrut.ty, hf), ty = scrut.ty)
              )
            )
            andV(c, Val(ty = NI1, value = NLocal(name = geLo)), Val(ty = NI1, value = NLocal(name = cmpHi)))
          }
        }
      }
    } else {
      intRangeTest(c, lo, hi, inclusive, scrut, sty)
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
    case TpRecord(sym, fields) -> match mapGet(c.env.recs, sym.id) {
      case None -> unsupported(
        c,
        "a record pattern on a type that is not a registered record"
      )
      case Some(lay) -> {
        var acc = trueV()
        for fp in fields {
          if subPatTests(fp.pat) {
            match readRecField(c, lay, scrut.value, fp.field) {
              case Some(fv) -> {
                acc = andV(c, acc, patTestAny(c, fp.pat, fv, fp.pat.ty))
              }
              case None -> ()
            }
          }
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
    case TpRecord(sym, fields) -> match mapGet(c.env.recs, sym.id) {
      case None -> c.problems.add(
        "a record pattern on a type that is not a registered record"
      )
      case Some(lay) -> {
        for fp in fields {
          if patBinds(fp.pat) {
            match readRecField(c, lay, scrut.value, fp.field) {
              case Some(fv) -> patBind(c, fp.pat, fv)
              case None -> ()
            }
          }
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
    case TpRecord(sym, fields) -> match mapGet(c.env.recs, sym.id) {
      case None -> c.problems.add(
        "a record pattern on a type that is not a registered record"
      )
      case Some(lay) -> {
        for fp in fields {
          if patBinds(fp.pat) {
            match readRecField(c, lay, v.value, fp.field) {
              case Some(fv) -> patBindOwned(c, fp.pat, fv)
              case None -> ()
            }
          }
        }
      }
    }
    case _ -> c.problems.add("a destructuring let pattern of this kind")
  }
}

/// A pattern every value of its type matches: a wildcard, a binding, and a tuple or record of
/// such patterns.
func patIrrefutable(pat: in TPat): Bool {
  match pat.kind {
    case TpWild -> true
    case TpBind(_, inner) -> match inner { case None -> true; case Some(p) -> patIrrefutable(p) }
    case TpTuple(elems) -> {
      for p in elems {
        if not patIrrefutable(p) {
          return false
        }
      }
      true
    }
    case TpRecord(_, fields) -> {
      for fp in fields {
        if not patIrrefutable(fp.pat) {
          return false
        }
      }
      true
    }
    case _ -> false
  }
}

func lowerMatch(c: in LCtx, e: in TExpr, scrutE: in TExpr, arms: in List[TArm], exhaustive: in Bool): Val {
  if arms.count == 0 {
    return unsupported(c, "a match with no arms")
  }
  // The checker's verdict does not cover every pattern (a record pattern, say), but a last arm
  // nothing can fail is a proof of its own.
  val lastArm = arms[arms.count - 1]
  val lastCatchesAll = match lastArm.guard { case Some(_) -> false; case None -> patIrrefutable(lastArm.pat) }
  if not exhaustive and not lastCatchesAll {
    return unsupported(c, "a match the builder did not prove exhaustive")
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
  val isRecord = match scrutE.ty { case TNamed(rs, _) -> c.env.recs.containsKey(rs.id); case _ -> false }
  val scrut = if isStringN(scrut0.ty) or isTuple or isRecord { borrow(c, scrut0) } else { scrut0 }
  val isUnion = match us { case Some(_) -> true; case None -> false }
  if isRefN(scrut.ty) and not isUnion and not isStringN(scrut.ty) and not isTuple and not isRecord {
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
    case _ -> match iter.ty {
      case TArray(_, _) -> if isHeapArray(c, iter.ty) {
        lowerForHeapArray(c, label, pat, iter, body)
      } else {
        lowerForArray(c, label, pat, iter, body)
      }
      case _ -> lowerForList(c, label, pat, iter, body)
    }
  }
}

/// `for x in list`: the list is held for the loop, the length is read each iteration and an
/// element is retained for the body (a body that removes it cannot free what it still reads).
func lowerForList(c: in LCtx, label: in Option[String], pat: in TPat, iter: in TExpr, body: in TExpr): Unit {
  val el = match listElemN(c, iter.ty) {
    case Some(x) -> x
    case None -> {
      c.problems.add("a for over " + renderTy(iter.ty))
      return
    }
  }
  val l = borrow(c, lowerExpr(c, iter))
  lowerForListOver(c, label, pat, l, el, body)
}

/// `for x in a` on an array held as a list: the loop runs over a copy of the list, so the body
/// cannot change what it iterates (an element that is itself an array is not copied).
func lowerForHeapArray(c: in LCtx, label: in Option[String], pat: in TPat, iter: in TExpr, body: in TExpr): Unit {
  val el = match listElemN(c, iter.ty) {
    case Some(x) -> x
    case None -> {
      c.problems.add("a for over " + renderTy(iter.ty))
      return
    }
  }
  val src = borrow(c, lowerExpr(c, iter))
  val raw = callRt(c, "lyric_list_copy", i8ptr(), arg1(i8ptr(), listAsI8(c, src)))
  val d = tmp(c)
  c.insns.add(NBitcast(dest = d, fromTy = i8ptr(), value = raw, toTy = src.ty))
  val copy = borrow(c, Val(ty = src.ty, value = NLocal(name = d), owned = true))
  lowerForListOver(c, label, pat, copy, el, body)
}

func lowerForListOver(c: in LCtx, label: in Option[String], pat: in TPat, l: in Val, el: in NType, body: in TExpr): Unit {
  val lp = listAsI8(c, l)
  val slotName = "for" + toString(c.ticker.count + 1) + ".i"
  c.ticker.add(0)
  c.allocas.add(NAlloca(dest = slotName, ty = NI64))
  c.insns.add(NStore(ty = NI64, value = NLitInt(v = 0i64, ty = NI64), ptr = NLocal(name = slotName)))
  val condL = newLabel(c, "for.cond")
  val bodyL = newLabel(c, "for.body")
  val stepL = newLabel(c, "for.step")
  val endL = newLabel(c, "for.end")
  c.insns.add(NBr(label = condL))
  startBlock(c, condL)
  val cur = tmp(c)
  c.insns.add(NLoad(dest = cur, ty = NI64, ptr = NLocal(name = slotName)))
  val n = callRt(c, "lyric_list_len", NI64, arg1(i8ptr(), lp))
  val ok = tmp(c)
  c.insns.add(NICmp(dest = ok, pred = ISlt, ty = NI64, a = NLocal(name = cur), b = n))
  c.insns.add(NCondBr(cond = NLocal(name = ok), thenLabel = bodyL, elseLabel = endL))
  startBlock(c, bodyL)
  val depth = c.refScopes.count
  val tdepth = c.temps.count
  pushRefScope(c)
  val slot = callRt(c, "lyric_list_get", NI64, arg2(i8ptr(), lp, NI64, NLocal(name = cur)))
  patBindOwned(c, pat, fromSlot(c, slot, el))
  c.loops.add(LoopLabels(label = label, breakL = endL, contL = stepL, scopeDepth = depth, tempDepth = tdepth))
  discard(c, lowerExpr(c, body))
  c.loops.removeAt(c.loops.count - 1)
  popRefScope(c)
  c.insns.add(NBr(label = stepL))
  startBlock(c, stepL)
  val at = tmp(c)
  c.insns.add(NLoad(dest = at, ty = NI64, ptr = NLocal(name = slotName)))
  val next = tmp(c)
  c.insns.add(NAdd(dest = next, ty = NI64, a = NLocal(name = at), b = NLitInt(v = 1i64, ty = NI64)))
  c.insns.add(NStore(ty = NI64, value = NLocal(name = next), ptr = NLocal(name = slotName)))
  c.insns.add(NBr(label = condL))
  startBlock(c, endL)
}

func lowerStmt(c: in LCtx, s: in TStmt): Unit {
  pushTemps(c)
  lowerStmtInner(c, s)
  popTemps(c)
}

func lowerStmtInner(c: in LCtx, s: in TStmt): Unit {
  match s.kind {
    case TsExpr(x) -> discard(c, lowerExpr(c, x))
    case TsScope(_, body) -> discard(c, lowerExpr(c, body))
    case TsVar(decl, init) -> match declareSlot(c, decl) {
      case None -> match init { case Some(x) -> discard(c, lowerExpr(c, x)); case None -> () }
      case Some(slot) -> {
        val v = match init {
          case Some(x) -> own(c, lowerExpr(c, x))
          case None -> match slot.ty {
            case NArray(_, _) -> {
              if not arrayZeroOk(c.env, slot.ty) {
                c.problems.add("the zero value of " + renderTy(decl.ty))
              }
              Val(ty = slot.ty, value = NZeroInit(ty = slot.ty))
            }
            case _ -> {
              match decl.ty {
                case TArray(_, _) -> c.problems.add("the zero value of " + renderTy(decl.ty))
                case _ -> ()
              }
              Val(ty = slot.ty, value = zeroOf(slot.ty))
            }
          }
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
          case None -> discard(c, lowerExpr(c, init))
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
      case TpRecord(_, _) -> {
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
              if c.coro {
                emitTaskComplete(c, unitVal())
              } else {
                c.insns.add(NRetVoid)
              }
            }
            case rt -> {
              val ov = own(c, v)
              releaseDownTo(c, 0, 0)
              if c.coro {
                emitTaskComplete(c, ov)
              } else {
                c.insns.add(NRet(ty = rt, value = ov.value))
              }
            }
          }
        }
        case None -> {
          releaseDownTo(c, 0, 0)
          if c.coro {
            emitTaskComplete(c, unitVal())
          } else {
            c.insns.add(NRetVoid)
          }
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
        needFuncs = env.needFuncs,
        needLists = env.needLists,
        needMaps = env.needMaps,
        needTasks = env.needTasks,
        needScans = env.needScans,
        needFns = env.needFns,
        needGlobals = env.needGlobals
      )
    )
  }
}

func lowerTirFunctionInner(env: in TirLowerEnv, fn: in TFnDecl): Result[TirLowered, TirFallback] {
  if fn.typeParams.count > 0 {
    return fallback(fn.sym, "a generic function")
  }
  if fn.isGenerator {
    return fallback(fn.sym, "a generator")
  }
  if (fn.preconds.count > 0 or fn.postconds.count > 0) and not env.contractsElaborated {
    return fallback(fn.sym, "contracts that the contract pass has not elaborated")
  }
  val irName = match mapGet(if fn.isAsync { env.asyncFns } else { env.fnNames }, fn.sym.id) {
    case Some(n) -> n
    case None -> return fallback(fn.sym, "no IR name for symbol #" + toString(fn.sym.id))
  }
  val body = match fn.body { case Some(b) -> b; case None -> return fallback(fn.sym, "no body") }
  val retTy = match tyToN(env, fn.ret) {
    case Some(t) -> t
    case None -> return fallback(fn.sym, "return type " + renderTyIn(env, fn.ret))
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
    closures = newList(),
    coro = fn.isAsync
  )
  c.cur.add("entry")
  val coroParams: List[CoroParam] = newList()
  val params: List[NParam] = newList()
  val stores: List[NInsn] = newList()
  for p in fn.params {
    val byRef = match p.mode { case TMIn -> false; case _ -> true }
    val pt = match tyToN(env, p.local.ty) {
      case Some(t) -> t
      case None -> return fallback(fn.sym, "parameter type " + renderTyIn(env, p.local.ty))
    }
    val pname = "a" + toString(p.local.id.id)
    if byRef and fn.isAsync {
      return fallback(fn.sym, "an async function with an out or inout parameter")
    }
    val ptUnit = match pt { case NVoid -> true; case _ -> false }
    if ptUnit {
      // A Unit parameter keeps its position (the callers pass a placeholder) and owns no storage.
      params.add(NParam(name = pname, ty = NVoid))
      c.slots.add(p.local.id.id, Slot(ptr = "", ty = NVoid))
    } else if byRef {
      // An out or inout parameter is the address of the caller's cell: the local's slot is that
      // pointer, so every read and write reaches the caller's storage, and the callee owns
      // nothing (it is never tracked for release).
      params.add(NParam(name = pname, ty = NPtr(pointee = pt)))
      c.slots.add(p.local.id.id, Slot(ptr = pname, ty = pt))
    } else {
      params.add(NParam(name = pname, ty = pt))
      match declareSlot(c, p.local) {
        case Some(slot) -> {
          stores.add(NStore(ty = pt, value = NLocal(name = pname), ptr = NLocal(name = slot.ptr)))
          if isRefN(pt) {
            coroParams.add(CoroParam(name = pname, slot = slot))
          }
        }
        case None -> ()
      }
    }
  }
  val lowered = assembleFn(c, irName, params, stores, body, coroParams)
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
