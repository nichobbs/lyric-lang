//! llvm/codegen.l — Lyric.LlvmCodegen: AST → LLVM IR lowering (Phase N1).
//!
//! Walks parsed + middle-ended `SourceFile`s and produces an `NPackage`
//! for `Lyric.LlvmLowering.lowerPackage`.  Phase N1 scope (scalar codegen,
//! native/plan/08-work-items.md):
//!
//!   * Int/Long/Float/Bool/Char/Byte scalars, String references.
//!   * Arithmetic, comparison, short-circuit `and`/`or`, `not`,
//!     bitwise `.and/.or/.xor/.shl/.shr`, checked integer division.
//!   * `val`/`var` locals (alloca-based; LLVM's mem2reg promotes),
//!     assignment (plain + compound), if/else (statement and
//!     expression), `while`, `break`/`continue`, blocks, `return`.
//!   * Function definitions and cross-package static calls (positional
//!     and named arguments; overloads disambiguated by arity).
//!   * String literals (static `LyricString` globals), concatenation,
//!     equality/ordering, `.length`, `.substring`, interpolation, and
//!     `.toString()` on every scalar.
//!   * `extern func` C-ABI declarations and calls (D-N-007).
//!   * `panic(msg)` / `assert(cond)` via `lyric_panic_msg`.
//!   * `func main(): Int | Unit` entry-point synthesis (C `main`).
//!
//! Style constraint: value-position if/else whose other branch panics is
//! written in return style throughout this file — the self-hosted MSIL
//! emitter miscompiles that shape (ilverify ReturnMissing/StackUnderflow,
//! #4625); `typeExprToNType`, `lowerExpr`'s EPath arm, and
//! `assignTargetName` hit it before the rewrite.
//!
//! Phase N2 (records, unions, enums, distinct types, pattern matching,
//! ARC insertion) lowers here too:
//!
//!   * Records: `{ i32 rc, i8* dtor, fields... }` heap structs with
//!     synthesised destructors (Rule 7) and inline construction
//!     (Rules 1/2).  Methods in record bodies lower as package
//!     functions with the explicit `self` receiver (D037), resolved
//!     via UFCS.
//!   * Unions: `{ header, i32 disc, i32 pad, [W x i64] payload }` with
//!     per-case payload structs; `match` lowers to discriminant tests
//!     with payload-field bindings, literal/range/string tests,
//!     guards, and a non-exhaustive panic backstop.
//!   * ARC: value-provenance bookkeeping — constructors and
//!     ref-returning calls yield OWNED temps (Rule 6) released at
//!     region end unless transferred to a binding (Rule 4), a heap
//!     store (Rules 2/3), or a return; borrows retain on binding;
//!     scope stacks release locals on block exit, `return`, `break`,
//!     and `continue`.  `in` params are borrows (Rule 5).
//!
//! Later slices lower here too: closures with by-value ARC captures
//! and synthesised capture-releasing destructors (N2.6),
//! `NativeWeak[T]` with `upgrade(): Option[T]` (N2.5), generic
//! records/unions/functions via lazy per-type-argument-tuple
//! instantiation (N3.1), tuples as synthesised `__tuple<...>` records
//! (N3.3), the `nativeAddrOf` builtin (N4.2), `List[T]` / `Map[K, V]`
//! on the lyric-rt kernels with `for` over lists (N5.8), Unit-typed
//! union/record payload fields (`Result[Unit, E]`), and diverging
//! (`panic`) branches in value-position `if`/`match` (N5.9).
//!
//! Not yet lowered (each panics with a construct-naming message, per
//! the MSIL/JVM backend convention for backend gaps): interfaces and
//! protected types (rest of N3), function references (`&f`),
//! module-level `val`, list literals, async (Phase 2).  `slice[T]`
//! shares the RC'd list representation (D-N-015).
package Lyric.LlvmCodegen

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Encoding as Encoding
import Lyric.Lexer
import Lyric.Parser
import Lyric.LlvmTypes
import Lyric.LlvmIr

// ─────────────────────────────────────────────────────────────────────────────
// §1. Codegen inputs and cross-package call registry.
// ─────────────────────────────────────────────────────────────────────────────
/// One package's contribution to the native module.  `fns` are the
/// function bodies to lower (the bridge pre-filters to the reachable
/// set for bundled stdlib packages); `externs` are the reachable
/// `extern func` declarations.
pub record CodegenUnit {
  pkgName: String
  fns: List[FunctionDecl]
  externs: List[ExternFuncDecl]
  // Type declarations register unfiltered (layouts are cheap and other
  // packages' signatures may reference them); generic declarations are
  // skipped at registration and panic only when actually used.
  records: List[RecordDecl]
  unions: List[UnionDecl]
  enums: List[EnumDecl]
  distincts: List[DistinctTypeDecl]
  // Interface declarations and `impl I for T` blocks (N3.2).  Interfaces
  // synthesise a per-interface vtable struct + heap-boxed fat-pointer type;
  // impls synthesise a vtable constant and contribute their methods as
  // self-receiving functions (collected into `fns` by `collectImplMethods`).
  interfaces: List[InterfaceDecl]
  impls: List[ImplDecl]
  // Protected types (N3.4): a record-shaped heap object with a trailing
  // runtime-sized mutex buffer (D-N-017).  Entries/funcs contribute a
  // desugared inner body (collected into `fns` by `collectProtectedMethods`)
  // plus a codegen-synthesised lock/unlock wrapper (`registerProtectedMethods`).
  protecteds: List[ProtectedTypeDecl]
}

/// Call-registry entry: how a resolvable callee lowers.  `isExternSym`
/// selects between a Lyric function (`irName` = `Pkg.name`, possibly
/// arity-suffixed) and a C symbol from an `extern func`.
record NFuncSig {
  irName: String
  pkg: String
  paramNames: List[String]
  paramTys: List[TypeExpr]
  retTy: Option[TypeExpr]
  isExternSym: Bool
}

/// The result of lowering one expression: its LLVM type and operand.
record NVal {
  ty: NType
  value: NValue
}

/// Registered (non-generic) record type: IR struct name plus the field
/// layout in declaration order.
record NRecInfo {
  irName: String
  fieldNames: List[String]
  fieldTys: List[NType]
  fieldDefaults: List[Option[Expr]]
}

record NUnionCaseInfo {
  name: String
  fieldNames: List[String]
  fieldTys: List[NType]
}

/// Registered (non-generic) interface (N3.2).  `irName` is the heap-boxed
/// fat-pointer struct name (`__iface.<mangled>`), `vtName` the vtable
/// struct name (`__ifacevt.<mangled>`).  Methods are in IMSig declaration
/// order — the vtable slot index.  `methodParamTys` excludes the implicit
/// `self` receiver (arg 0 at the call site); `methodRetTys` is `NVoid` for
/// a Unit return.
record NIfaceInfo {
  key: String
  irName: String
  vtName: String
  methodNames: List[String]
  methodParamTys: List[List[NType]]
  methodRetTys: List[NType]
}

/// Registered (non-generic) union type: cases plus the payload area
/// size in 8-byte words (max over the cases' payload struct layouts).
record NUnionInfo {
  irName: String
  cases: List[NUnionCaseInfo]
  payloadWords: Int
}

/// Resolves a case name to its union and discriminant index.
record NCaseRef {
  unionKey: String
  caseIdx: Int
}

/// Registered distinct type: the underlying representation plus the
/// optional literal range bounds (range subtypes check on construction).
record NDistinctInfo {
  underlying: NType
  hasRange: Bool
  lo: Long
  hi: Long
}

/// Reverse metadata for a type instantiation: which generic declaration
/// and argument tuple produced it (drives call-site unification).
record NInstInfo {
  gkey: String
  argTys: List[NType]
}

/// One generic-function instantiation: concrete signature + IR symbol.
record NFnInst {
  irName: String
  paramTys: List[NType]
  retTy: NType
}

/// The call signature behind a closure type (keyed by the closure
/// struct name).
record NClosureSig {
  paramTys: List[NType]
  retTy: NType
}

/// A ref-typed local owned by a lexical scope (released on scope exit).
record NOwnedLocal {
  slot: String
  ty: NType
}

/// An owned ref-typed temporary (rc transferred by a constructor or a
/// call); released at the end of its evaluation region unless
/// transferred to a binding, a heap store, or a return.
record NOwnedTemp {
  value: NValue
  ty: NType
}

/// Per-module mutable codegen state, threaded through all lowering.
/// Tickers use the singleton-list idiom (`.count` is the next index)
/// shared with `Jvm.Codegen.FuncCtx`.
record Ctx {
  mainPkg: String
  tmpTicker: List[Int]
  labelTicker: List[Int]
  strTicker: List[Int]
  // Current function state.
  varSlots: Map[String, String]
  varTypes: Map[String, NType]
  allocas: List[NInsn]
  loopBreak: List[String]
  loopCont: List[String]
  // Module accumulators.
  globals: List[NGlobalDef]
  sigs: Map[String, NFuncSig]
  // Package the function being lowered belongs to (self-package call
  // resolution).
  curPkg: List[String]
  // Return type of the function being lowered (singleton list).
  curRet: List[NType]
  // Heap-type registries (module-wide, shared across functions).
  recordDefs: Map[String, NRecInfo]
  unionDefs: Map[String, NUnionInfo]
  caseRefs: Map[String, NCaseRef]
  enumDefs: Map[String, Int]
  distinctDefs: Map[String, NDistinctInfo]
  // Generic type declarations (N3.1): instantiated on demand per
  // concrete type-argument tuple.  `caseToGenericUnion` maps a case
  // name to its generic union's registry key for constructor-call
  // inference; `genericDeclPkg` records the declaring package.
  genericRecordDefs: Map[String, RecordDecl]
  genericUnionDefs: Map[String, UnionDecl]
  genericDeclPkg: Map[String, String]
  caseToGenericUnion: Map[String, String]
  // Module accumulators for lazy instantiation: type definitions and
  // synthesised functions (destructors) appended during lowering.
  moduleTypeDefs: List[NTypeDefn]
  moduleFns: List[NFunc]
  // Generic functions (N3.1): declarations by call key, instantiation
  // cache, and reverse instantiation metadata for unification.
  genericFnDefs: Map[String, FunctionDecl]
  genericFnPkg: Map[String, String]
  fnInstCache: Map[String, NFnInst]
  instMeta: Map[String, NInstInfo]
  // Per-function type-parameter environment (set when lowering a
  // generic function instantiation; consulted by typeToN).
  fnTyEnvNames: List[String]
  fnTyEnvTys: List[NType]
  // Closure signatures by closure-struct name (N2.6).
  closureSigs: Map[String, NClosureSig]
  // Callback trampolines by raw C-callback signature (N4.5): the ccc
  // wrapper synthesised when a Lyric closure is passed to an extern
  // func parameter of function type.
  trampolines: Map[String, String]
  // NativeWeak target types by weak-struct name (N2.5).
  weakTargets: Map[String, NType]
  // Collection instantiations (N5.8): element type by list-struct name;
  // key / value types by map-struct name.  All share the fixed
  // LyricList / LyricMap C layouts — the per-instantiation struct name
  // only preserves the Lyric-level element typing for method lowering.
  listElems: Map[String, NType]
  mapKeyTys: Map[String, NType]
  mapValTys: Map[String, NType]
  // Interface registries (N3.2), module-wide.  `ifaceInfos` maps both the
  // qualified (`Pkg.Name`) and bare (`Name`) interface name to its
  // NIfaceInfo; `ifaceVtables` maps `<recordIrName>|<ifaceKey>` to the
  // emitted vtable-constant global name, resolved at upcast sites.
  ifaceInfos: Map[String, NIfaceInfo]
  ifaceVtables: Map[String, String]
  // Protected-type record irNames (N3.4): marks which `recordDefs` entries
  // are protected types (a trailing `__mutex: i8*` field, construction
  // routes through `lowerProtectedConstructArgs`) rather than plain records.
  protectedRecNames: Map[String, Bool]
  // ARC state (per function).  `scopeRefs` stacks the ref-typed locals
  // each lexical scope owns; `tempScopes` stacks the owned temporaries
  // of each evaluation region; the depth lists snapshot both stacks at
  // loop entry so break/continue release exactly the loop-inner scopes.
  scopeRefs: List[List[NOwnedLocal]]
  tempScopes: List[List[NOwnedTemp]]
  loopVarDepth: List[Int]
  loopTempDepth: List[Int]
  // `defer` (P2.D1): one list per lexical scope (mirrors `scopeRefs`'s
  // stack discipline exactly, same push/pop sites), holding the deferred
  // `Block`s registered directly in that scope in declaration order.
  // Native has no try/finally to lean on (unlike msil/jvm's `try { rest }
  // finally { D }` recursive lowering), so a scope's deferred blocks are
  // instead run explicitly at every exit from that scope: normal
  // fall-off (`popVarScope`), `return` (`releaseAllForReturn`, every
  // scope), and `break`/`continue` (`releaseForLoopExit`, scopes down to
  // the loop floor) — in each case, in reverse declaration order and
  // innermost-scope-first, before that scope's ARC releases run (so a
  // deferred block can still read the scope's own locals).
  deferStack: List[List[Block]]
}

func freshTmp(ctx: in Ctx): String {
  val n = ctx.tmpTicker.count
  ctx.tmpTicker.add(0)
  "t" + n.toString()
}

func freshLabel(ctx: in Ctx, stem: in String): String {
  val n = ctx.labelTicker.count
  ctx.labelTicker.add(0)
  stem + "." + n.toString()
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Type mapping (03-type-mapping.md).
// ─────────────────────────────────────────────────────────────────────────────
pub func lyricStringNType(): NType {
  val fields: List[NType] = newList()
  fields.add(NI32)
  fields.add(NPtr(pointee = NI8))
  fields.add(NI64)
  fields.add(NI64)
  NPtr(pointee = NStruct(name = "LyricString", fields = fields))
}

func isStringNType(t: in NType): Bool {
  match t {
    case NPtr(pointee) -> match pointee { case NStruct(name, _) -> name == "LyricString"; case _ -> false }
    case _ -> false
  }
}

func lastSeg(path: in ModulePath): String {
  if path.segments.count == 0 {
    ""
  } else {
    path.segments[path.segments.count - 1]
  }
}

/// Map a surface type to its LLVM lowering.  Panics (naming the type)
/// for constructs outside the N1 scalar scope.
pub func typeExprToNType(te: in TypeExpr): NType {
  match te.kind {
    case TRef(path) -> {
      val n = lastSeg(path)
      if n == "Int" {
        return NI32
      }
      if n == "Long" {
        return NI64
      }
      if n == "Float" or n == "Double" {
        return NDouble
      }
      if n == "Bool" {
        return NI1
      }
      if n == "Unit" {
        return NVoid
      }
      if n == "Byte" {
        return NI8
      }
      if n == "Char" {
        return NI32
      }
      if n == "String" {
        return lyricStringNType()
      }
      panic(
        "Lyric.LlvmCodegen: type '" + n +
          "' is not yet supported for --target native (Phase N1 lowers scalars and String only)"
      )
    }
    case TGenericApp(head, args) -> {
      val n = lastSeg(head)
      if n == "NativePtr" and args.count == 1 {
        match args[0] {
          case TAType(inner) -> return NPtr(pointee = typeExprToNType(inner))
          case TAValue(_) -> panic("Lyric.LlvmCodegen: NativePtr takes a type argument")
        }
      }
      panic("Lyric.LlvmCodegen: generic type '" + n + "' is not yet supported for --target native (Phase N1)")
    }
    case TUnit -> NVoid
    case TParen(inner) -> typeExprToNType(inner)
    case TFunction(parameters, retTy) -> {
      // A raw C function-pointer type (N4.5): only meaningful in extern
      // func parameter positions, where a Lyric closure argument is
      // wrapped in a synthesised ccc trampoline.
      val ps: List[NType] = newList()
      var i = 0
      while i < parameters.count {
        ps.add(typeExprToNType(parameters[i]))
        i = i + 1
      }
      NFnPtr(params = ps, ret = typeExprToNType(retTy))
    }
    case _ -> panic("Lyric.LlvmCodegen: this type form is not yet supported for --target native (Phase N1)")
  }
}

func retTypeToNType(ret: in Option[TypeExpr]): NType {
  match ret {
    case Some(te) -> typeExprToNType(te)
    case None -> NVoid
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2.5. Heap types: registries, layout, and ARC bookkeeping (Phase N2).
// ─────────────────────────────────────────────────────────────────────────────
/// Registry-aware type resolution: scalars first, then records, unions,
/// enums (i32), and distinct types (their underlying representation).
func typeToN(ctx: in Ctx, te: in TypeExpr): NType {
  match te.kind {
    case TRef(path) -> {
      if path.segments.count == 1 {
        val envIdx = envIndexOf(ctx.fnTyEnvNames, path.segments[0])
        if envIdx >= 0 {
          return ctx.fnTyEnvTys[envIdx]
        }
      }
      val joined = modulePathJoin(path.segments)
      val n = lastSeg(path)
      match lookupHeapType(ctx, joined, n) {
        case Some(t) -> return t
        case None -> {
        }
      }
      typeExprToNType(te)
    }
    case TGenericApp(_, _) -> {
      // Generic applications (Option[Int], user generics) instantiate
      // lazily (N3.1); NativePtr passes through typeExprToNType.
      val emptyNames: List[String] = newList()
      val emptyTys: List[NType] = newList()
      match typeToNEnvOpt(ctx, te, emptyNames, emptyTys) {
        case Some(t) -> return t
        case None -> {
        }
      }
      typeExprToNType(te)
    }
    case TFunction(_, _) -> {
      val emptyNames: List[String] = newList()
      val emptyTys: List[NType] = newList()
      match typeToNEnvOpt(ctx, te, emptyNames, emptyTys) {
        case Some(t) -> return t
        case None -> {
        }
      }
      typeExprToNType(te)
    }
    case TTuple(_) -> {
      val emptyNames: List[String] = newList()
      val emptyTys: List[NType] = newList()
      match typeToNEnvOpt(ctx, te, emptyNames, emptyTys) {
        case Some(t) -> return t
        case None -> {
        }
      }
      typeExprToNType(te)
    }
    case TSlice(_) -> {
      val emptyNames: List[String] = newList()
      val emptyTys: List[NType] = newList()
      match typeToNEnvOpt(ctx, te, emptyNames, emptyTys) {
        case Some(t) -> return t
        case None -> {
        }
      }
      typeExprToNType(te)
    }
    case TParen(inner) -> typeToN(ctx, inner)
    case _ -> typeExprToNType(te)
  }
}

/// Non-panicking variant of `typeToN`, used when registering bundled
/// (stdlib) type declarations: a bundled record whose field types the
/// native backend cannot lower yet must not break unrelated programs —
/// it stays unregistered, so a *use* panics with the resolution
/// message while non-users compile fine.
func typeToNOpt(ctx: in Ctx, te: in TypeExpr): Option[NType] {
  match te.kind {
    case TRef(path) -> {
      if path.segments.count == 1 {
        val envIdx = envIndexOf(ctx.fnTyEnvNames, path.segments[0])
        if envIdx >= 0 {
          return Some(value = ctx.fnTyEnvTys[envIdx])
        }
      }
      val joined = modulePathJoin(path.segments)
      val n = lastSeg(path)
      match lookupHeapType(ctx, joined, n) {
        case Some(t) -> return Some(value = t)
        case None -> {
        }
      }
      if n == "Int" or n == "Char" {
        return Some(value = NI32)
      }
      if n == "Long" {
        return Some(value = NI64)
      }
      if n == "Float" or n == "Double" {
        return Some(value = NDouble)
      }
      if n == "Bool" {
        return Some(value = NI1)
      }
      if n == "Unit" {
        return Some(value = NVoid)
      }
      if n == "Byte" {
        return Some(value = NI8)
      }
      if n == "String" {
        return Some(value = lyricStringNType())
      }
      None
    }
    case TGenericApp(_, _) -> {
      val emptyNames: List[String] = newList()
      val emptyTys: List[NType] = newList()
      typeToNEnvOpt(ctx, te, emptyNames, emptyTys)
    }
    case TFunction(_, _) -> {
      val emptyNames: List[String] = newList()
      val emptyTys: List[NType] = newList()
      typeToNEnvOpt(ctx, te, emptyNames, emptyTys)
    }
    case TTuple(_) -> {
      val emptyNames: List[String] = newList()
      val emptyTys: List[NType] = newList()
      typeToNEnvOpt(ctx, te, emptyNames, emptyTys)
    }
    case TSlice(_) -> {
      val emptyNames: List[String] = newList()
      val emptyTys: List[NType] = newList()
      typeToNEnvOpt(ctx, te, emptyNames, emptyTys)
    }
    case TUnit -> Some(value = NVoid)
    case TParen(inner) -> typeToNOpt(ctx, inner)
    case _ -> None
  }
}

func lookupHeapType(ctx: in Ctx, joined: in String, bare: in String): Option[NType] {
  match mapGet(ctx.recordDefs, joined) {
    case Some(ri) -> return Some(value = recPtrType(ri))
    case None -> {
    }
  }
  match mapGet(ctx.recordDefs, bare) {
    case Some(ri) -> return Some(value = recPtrType(ri))
    case None -> {
    }
  }
  match mapGet(ctx.unionDefs, joined) {
    case Some(ui) -> return Some(value = unionPtrType(ui))
    case None -> {
    }
  }
  match mapGet(ctx.unionDefs, bare) {
    case Some(ui) -> return Some(value = unionPtrType(ui))
    case None -> {
    }
  }
  if ctx.enumDefs.containsKey(joined + ".__enum") or ctx.enumDefs.containsKey(bare + ".__enum") {
    return Some(value = NI32)
  }
  // Field access goes through a helper: the stage-0 seed mis-infers
  // the `Some(di)` binding against this function's Option[NType]
  // return type and rejects `di.underlying` (#4631 family).
  match mapGet(ctx.distinctDefs, joined) {
    case Some(di) -> return Some(value = distinctUnderlying(di))
    case None -> {
    }
  }
  match mapGet(ctx.distinctDefs, bare) {
    case Some(di) -> return Some(value = distinctUnderlying(di))
    case None -> {
    }
  }
  match mapGet(ctx.ifaceInfos, joined) {
    case Some(info) -> return Some(value = ifaceBoxPtrType(info))
    case None -> {
    }
  }
  match mapGet(ctx.ifaceInfos, bare) {
    case Some(info) -> return Some(value = ifaceBoxPtrType(info))
    case None -> {
    }
  }
  None
}

func distinctUnderlying(di: in NDistinctInfo): NType {
  di.underlying
}

func retTypeToN(ctx: in Ctx, ret: in Option[TypeExpr]): NType {
  match ret {
    case Some(te) -> typeToN(ctx, te)
    case None -> NVoid
  }
}

/// The pointer type for a registered record.  The struct body carries
/// the ARC header (rc, dtor) followed by the fields, so GEP field
/// indices are `2 + declIndex`.
func recPtrType(ri: in NRecInfo): NType {
  val fields: List[NType] = newList()
  fields.add(NI32)
  fields.add(NPtr(pointee = NI8))
  var i = 0
  while i < ri.fieldTys.count {
    fields.add(ri.fieldTys[i])
    i = i + 1
  }
  NPtr(pointee = NStruct(name = ri.irName, fields = fields))
}

/// The pointer type for a registered union: header, i32 discriminant,
/// i32 pad (so the payload is 8-aligned), then the payload words.
func unionPtrType(ui: in NUnionInfo): NType {
  NPtr(pointee = NStruct(name = ui.irName, fields = unionBodyFields(ui.payloadWords)))
}

func unionBodyFields(payloadWords: in Int): List[NType] {
  val fields: List[NType] = newList()
  fields.add(NI32)
  fields.add(NPtr(pointee = NI8))
  fields.add(NI32)
  fields.add(NI32)
  fields.add(NArray(elem = NI64, size = payloadWords))
  fields
}

/// x86-64 / AArch64 System V sizes for the types that can appear in
/// heap-struct fields (aggregates are always behind pointers).
func sizeOfN(t: in NType): Int {
  match t {
    case NI1 -> 1
    case NI8 -> 1
    case NI32 -> 4
    case NI64 -> 8
    case NDouble -> 8
    case NPtr(_) -> 8
    case NArray(elem, size) -> sizeOfN(elem) * size
    // A Unit field (e.g. `Result[Unit, E]`'s Ok payload) occupies one
    // undef byte — see layoutFieldTys.
    case NVoid -> 1
    case _ -> panic("Lyric.LlvmCodegen: by-value aggregate fields are not supported in native heap layouts")
  }
}

/// Struct-definition field types for a record/union-case layout:
/// Unit-typed fields keep their slot (GEP indices must line up with the
/// NRecInfo/NUnionCaseInfo field positions) but `void` is not a valid
/// LLVM field type, so each lowers to one undef `i8`.  Construction and
/// reads skip Unit fields entirely — a Unit value carries no data.
func layoutFieldTys(tys: in List[NType]): List[NType] {
  val mapped: List[NType] = newList()
  var i = 0
  while i < tys.count {
    match tys[i] {
      case NVoid -> mapped.add(NI8)
      case t -> mapped.add(t)
    }
    i = i + 1
  }
  mapped
}

func isVoidNType(t: in NType): Bool {
  match t {
    case NVoid -> true
    case _ -> false
  }
}

func alignOfN(t: in NType): Int {
  match t {
    case NArray(elem, _) -> alignOfN(elem)
    case _ -> sizeOfN(t)
  }
}

func roundUpTo(off: in Int, a: in Int): Int {
  if a <= 1 {
    return off
  }
  // Binds first: a trailing line starting with '(' would parse as a
  // call continuing the if statement.
  val rounded = ((off + a - 1) / a) * a
  rounded
}

/// Struct layout size (C rules): field offsets aligned per field, total
/// rounded up to the max field alignment.
func structSize(fields: in List[NType]): Int {
  var off = 0
  var maxA = 1
  var i = 0
  while i < fields.count {
    val a = alignOfN(fields[i])
    if a > maxA {
      maxA = a
    }
    off = roundUpTo(off, a)
    off = off + sizeOfN(fields[i])
    i = i + 1
  }
  roundUpTo(off, maxA)
}

/// Allocation size of a record: ARC header + fields.
func recAllocSize(ri: in NRecInfo): Int {
  val fields: List[NType] = newList()
  fields.add(NI32)
  fields.add(NPtr(pointee = NI8))
  var i = 0
  while i < ri.fieldTys.count {
    fields.add(ri.fieldTys[i])
    i = i + 1
  }
  structSize(fields)
}

func unionAllocSize(ui: in NUnionInfo): Int {
  structSize(unionBodyFields(ui.payloadWords))
}

/// ARC-managed values are pointers to named structs (LyricString,
/// records, unions).  Raw c-strings (`i8*`) and `NativePtr[T]` are not.
func isRefNType(t: in NType): Bool {
  match t {
    case NPtr(pointee) -> {
      match pointee {
        case NStruct(name, _) -> not Str.startsWith(name, "__weak<")
        case _ -> false
      }
    }
    case _ -> false
  }
}

func asI8Ptr(ctx: in Ctx, insns: in List[NInsn], v: in NVal): NValue {
  match v.ty {
    case NPtr(pointee) -> {
      match pointee {
        case NI8 -> return v.value
        case _ -> {
        }
      }
    }
    case _ -> {
    }
  }
  val dest = freshTmp(ctx)
  insns.add(NBitcast(dest = dest, fromTy = v.ty, value = v.value, toTy = NPtr(pointee = NI8)))
  NLocal(name = dest)
}

func emitRetain(ctx: in Ctx, insns: in List[NInsn], v: in NVal): Unit {
  val p = asI8Ptr(ctx, insns, v)
  insns.add(NCallVoid(fn = NGlobal(name = "lyric_retain"), args = arg1(NPtr(pointee = NI8), p)))
}

func emitRelease(ctx: in Ctx, insns: in List[NInsn], v: in NVal): Unit {
  val p = asI8Ptr(ctx, insns, v)
  insns.add(NCallVoid(fn = NGlobal(name = "lyric_release"), args = arg1(NPtr(pointee = NI8), p)))
}

// ── Ownership bookkeeping ────────────────────────────────────────────────────
func pushTempScope(ctx: in Ctx): Unit {
  val fresh: List[NOwnedTemp] = newList()
  ctx.tempScopes.add(fresh)
}

/// Release every still-owned temp of the top scope and pop it.
func popTempScope(ctx: in Ctx, insns: in List[NInsn]): Unit {
  val top = ctx.tempScopes[ctx.tempScopes.count - 1]
  var i = top.count - 1
  while i >= 0 {
    emitRelease(ctx, insns, NVal(ty = top[i].ty, value = top[i].value))
    i = i - 1
  }
  ctx.tempScopes.removeAt(ctx.tempScopes.count - 1)
}

/// Register an owned ref-typed value in the current temp scope.  No-op
/// for scalars and when no temp scope is active (module-level paths).
func registerTemp(ctx: in Ctx, v: in NVal): Unit {
  if not isRefNType(v.ty) {
    return
  }
  if ctx.tempScopes.count == 0 {
    return
  }
  ctx.tempScopes[ctx.tempScopes.count - 1].add(NOwnedTemp(value = v.value, ty = v.ty))
}

func nValueEq(a: in NValue, b: in NValue): Bool {
  match a {
    case NLocal(an) -> match b { case NLocal(bn) -> an == bn; case _ -> false }
    case NGlobal(an) -> match b { case NGlobal(bn) -> an == bn; case _ -> false }
    case _ -> false
  }
}

/// Remove `v` from any temp scope (ownership is being transferred to a
/// binding, a heap store, or the caller).  Returns true when found —
/// i.e. `v` was an owned temp; false means `v` is a borrow.
func unregisterTemp(ctx: in Ctx, v: in NVal): Bool {
  var si = ctx.tempScopes.count - 1
  while si >= 0 {
    val scp = ctx.tempScopes[si]
    var i = scp.count - 1
    while i >= 0 {
      if nValueEq(scp[i].value, v.value) {
        scp.removeAt(i)
        return true
      }
      i = i - 1
    }
    si = si - 1
  }
  false
}

/// Make `v` owned by the current consumer: owned temps transfer
/// (unregister); borrows get a retain.  Scalars pass through.
func ensureOwned(ctx: in Ctx, insns: in List[NInsn], v: in NVal): Unit {
  if not isRefNType(v.ty) {
    return
  }
  if unregisterTemp(ctx, v) {
    return
  }
  emitRetain(ctx, insns, v)
}

func pushVarScope(ctx: in Ctx): Unit {
  val fresh: List[NOwnedLocal] = newList()
  ctx.scopeRefs.add(fresh)
  val freshDefers: List[Block] = newList()
  ctx.deferStack.add(freshDefers)
}

/// Run the `defer` blocks registered directly in the var scope at `idx`
/// (P2.D1), in reverse declaration order, before that scope's ARC
/// locals are released — a deferred block may read locals from its own
/// enclosing scope.  Native has no try/finally, so this is called
/// explicitly at every scope-exit site (`popVarScope`,
/// `releaseAllForReturn`, `releaseForLoopExit`) instead of leaning on a
/// runtime unwind mechanism.
func runDeferredScopeAt(ctx: in Ctx, insns: in List[NInsn], idx: in Int): Unit {
  val defers = ctx.deferStack[idx]
  var i = defers.count - 1
  while i >= 0 {
    lowerBlockStmts(ctx, insns, defers[i])
    i = i - 1
  }
}

/// Release the ref-typed locals of the top var scope (reverse bind
/// order) and pop it.
func popVarScope(ctx: in Ctx, insns: in List[NInsn]): Unit {
  runDeferredScopeAt(ctx, insns, ctx.deferStack.count - 1)
  releaseVarScopeAt(ctx, insns, ctx.scopeRefs.count - 1)
  ctx.scopeRefs.removeAt(ctx.scopeRefs.count - 1)
  ctx.deferStack.removeAt(ctx.deferStack.count - 1)
}

func releaseVarScopeAt(ctx: in Ctx, insns: in List[NInsn], idx: in Int): Unit {
  val scp = ctx.scopeRefs[idx]
  var i = scp.count - 1
  while i >= 0 {
    val dest = freshTmp(ctx)
    insns.add(NLoad(dest = dest, ty = scp[i].ty, ptr = NLocal(name = scp[i].slot)))
    emitRelease(ctx, insns, NVal(ty = scp[i].ty, value = NLocal(name = dest)))
    i = i - 1
  }
}

/// Emit the releases a `return` needs: every var scope in the stack and
/// every remaining owned temp (the return value itself must already be
/// unregistered/retained by the caller of this helper).  Runs each
/// scope's pending `defer` blocks (P2.D1) before releasing that scope's
/// ARC locals, innermost scope first.
func releaseAllForReturn(ctx: in Ctx, insns: in List[NInsn]): Unit {
  var ti = ctx.tempScopes.count - 1
  while ti >= 0 {
    val scp = ctx.tempScopes[ti]
    var i = scp.count - 1
    while i >= 0 {
      emitRelease(ctx, insns, NVal(ty = scp[i].ty, value = scp[i].value))
      i = i - 1
    }
    ti = ti - 1
  }
  var si = ctx.scopeRefs.count - 1
  while si >= 0 {
    runDeferredScopeAt(ctx, insns, si)
    releaseVarScopeAt(ctx, insns, si)
    si = si - 1
  }
}

/// Emit the releases `break`/`continue` need: var scopes and temp
/// scopes opened inside the innermost loop (not the loop-outer ones).
/// Runs each scope's pending `defer` blocks (P2.D1) before releasing
/// that scope's ARC locals, innermost scope first.
func releaseForLoopExit(ctx: in Ctx, insns: in List[NInsn]): Unit {
  val varFloor = ctx.loopVarDepth[ctx.loopVarDepth.count - 1]
  val tempFloor = ctx.loopTempDepth[ctx.loopTempDepth.count - 1]
  var ti = ctx.tempScopes.count - 1
  while ti >= tempFloor {
    val scp = ctx.tempScopes[ti]
    var i = scp.count - 1
    while i >= 0 {
      emitRelease(ctx, insns, NVal(ty = scp[i].ty, value = scp[i].value))
      i = i - 1
    }
    ti = ti - 1
  }
  var si = ctx.scopeRefs.count - 1
  while si >= varFloor {
    runDeferredScopeAt(ctx, insns, si)
    releaseVarScopeAt(ctx, insns, si)
    si = si - 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Registry construction.
// ─────────────────────────────────────────────────────────────────────────────
func paramNamesOf(params: in List[Param]): List[String] {
  val names: List[String] = newList()
  var i = 0
  while i < params.count {
    names.add(params[i].name)
    i = i + 1
  }
  names
}

func paramTysOf(params: in List[Param]): List[TypeExpr] {
  val tys: List[TypeExpr] = newList()
  var i = 0
  while i < params.count {
    tys.add(params[i].ty)
    i = i + 1
  }
  tys
}

func addSig(sigs: in Map[String, NFuncSig], key: in String, sig: in NFuncSig): Unit {
  if not sigs.containsKey(key) {
    sigs.add(key, sig)
  }
}

/// The IR symbol for a Lyric function.  A name that is overloaded by
/// arity within its package gets a stable `.<arity>` suffix so each
/// overload owns a distinct symbol.
func irNameFor(pkg: in String, name: in String, arity: in Int, overloaded: in Bool): String {
  if overloaded {
    pkg + "." + name + "." + arity.toString()
  } else {
    pkg + "." + name
  }
}

/// Build the cross-package call registry over every unit's functions
/// and extern funcs.  Keys: `<name>/<arity>` (bare) and
/// `<Pkg>.<name>/<arity>` (qualified); first registration wins, and the
/// main package registers first so its names shadow stdlib bare names,
/// matching source scoping.
func buildSigs(units: in List[CodegenUnit]): Map[String, NFuncSig] {
  val sigs: Map[String, NFuncSig] = newMap()
  // Pass 1: count same-package name+arity groups to detect overloads.
  val nameCount: Map[String, Int] = newMap()
  var ui = 0
  while ui < units.count {
    val u = units[ui]
    var fi = 0
    while fi < u.fns.count {
      match u.fns[fi].generics {
        case Some(_) -> {
        }
        case None -> {
          val key = u.pkgName + "." + u.fns[fi].name
          val prior = match mapGet(nameCount, key) { case Some(c) -> c; case None -> 0 }
          if nameCount.containsKey(key) {
            nameCount.remove(key)
          }
          nameCount.add(key, prior + 1)
        }
      }
      fi = fi + 1
    }
    ui = ui + 1
  }
  var ui2 = 0
  while ui2 < units.count {
    val u = units[ui2]
    var fi = 0
    while fi < u.fns.count {
      val fn = u.fns[fi]
      if isGenericFn(fn) {
        fi = fi + 1
        continue
      }
      val groupKey = u.pkgName + "." + fn.name
      val overloaded = match mapGet(nameCount, groupKey) { case Some(c) -> c > 1; case None -> false }
      val arity = fn.params.count
      val sig = NFuncSig(
        irName = irNameFor(u.pkgName, fn.name, arity, overloaded),
        pkg = u.pkgName,
        paramNames = paramNamesOf(fn.params),
        paramTys = paramTysOf(fn.params),
        retTy = fn.ret,
        isExternSym = false
      )
      addSig(sigs, u.pkgName + "." + fn.name + "/" + arity.toString(), sig)
      addSig(sigs, fn.name + "/" + arity.toString(), sig)
      fi = fi + 1
    }
    var ei = 0
    while ei < u.externs.count {
      val ef = u.externs[ei]
      val arity = ef.params.count
      val sig = NFuncSig(
        irName = ef.symbol,
        pkg = u.pkgName,
        paramNames = paramNamesOf(ef.params),
        paramTys = paramTysOf(ef.params),
        retTy = ef.ret,
        isExternSym = true
      )
      addSig(sigs, u.pkgName + "." + ef.name + "/" + arity.toString(), sig)
      addSig(sigs, ef.name + "/" + arity.toString(), sig)
      ei = ei + 1
    }
    ui2 = ui2 + 1
  }
  sigs
}

/// The registry key for a call target, or "" when the callee shape is
/// not a static function reference.  Exported so the bridge's
/// reachability walk resolves call sites identically to the codegen.
pub func callKeyOf(fnExpr: in Expr, argc: in Int): String {
  val inner = match fnExpr.kind { case ETypeApp(f, _) -> f; case _ -> fnExpr }
  match inner.kind {
    case EPath(path) -> {
      if path.segments.count == 0 {
        ""
      } else {
        modulePathJoin(path.segments) + "/" + argc.toString()
      }
    }
    case EMember(recv, memberName) -> {
      match recv.kind {
        case EPath(rpath) -> modulePathJoin(rpath.segments) + "." + memberName + "/" + argc.toString()
        case _ -> ""
      }
    }
    case _ -> ""
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. String literal globals and runtime helpers.
// ─────────────────────────────────────────────────────────────────────────────
/// Emit (once) the static `LyricString` global for `text` and return an
/// NVal of String type referencing it via bitcast.
func emitStringLiteral(ctx: in Ctx, insns: in List[NInsn], text: in String): NVal {
  val bytes = Encoding.encodeUtf8(text)
  val n = bytes.length
  val idx = ctx.strTicker.count
  ctx.strTicker.add(0)
  val gname = ".strobj." + idx.toString()
  // Data carries a trailing NUL (len excludes it) so debuggers and
  // lyric_string_to_cstring fast paths see C-friendly bytes.
  val tyStr = "{ i32, i8*, i64, i64, [" + (n + 1).toString() + " x i8] }"
  val initStr = "{ i32 2147483647, i8* null, i64 " + n.toString() + ", i64 " + (n + 1).toString() + ", [" +
    (n + 1).toString() +
    " x i8] c\"" +
    escapeIrBytes(bytes) +
    "\\00\" }"
  ctx.globals.add(
    NGlobalDef(name = gname, linkage = "private unnamed_addr constant", tyStr = tyStr, initStr = initStr, align = 8)
  )
  val dest = freshTmp(ctx)
  // The global's own type is the anonymous literal struct (header +
  // inline data array); bitcast to %LyricString* for uniform call sites.
  val litFields: List[NType] = newList()
  litFields.add(NI32)
  litFields.add(NPtr(pointee = NI8))
  litFields.add(NI64)
  litFields.add(NI64)
  litFields.add(NArray(elem = NI8, size = n + 1))
  insns.add(
    NBitcast(
      dest = dest,
      fromTy = NPtr(pointee = NLitStruct(fields = litFields)),
      value = NGlobal(name = gname),
      toTy = lyricStringNType()
    )
  )
  NVal(ty = lyricStringNType(), value = NLocal(name = dest))
}

/// Emit a raw NUL-terminated `[N x i8]` c-string global (no LyricString
/// header) and return an i8* to its first byte.  Used for panic
/// file/message operands.
func emitRawCString(ctx: in Ctx, insns: in List[NInsn], text: in String): NVal {
  val bytes = Encoding.encodeUtf8(text)
  val n = bytes.length
  val idx = ctx.strTicker.count
  ctx.strTicker.add(0)
  val gname = ".cstr." + idx.toString()
  val tyStr = "[" + (n + 1).toString() + " x i8]"
  val initStr = "c\"" + escapeIrBytes(bytes) + "\\00\""
  ctx.globals.add(
    NGlobalDef(name = gname, linkage = "private unnamed_addr constant", tyStr = tyStr, initStr = initStr, align = 1)
  )
  val dest = freshTmp(ctx)
  insns.add(
    NBitcast(
      dest = dest,
      fromTy = NPtr(pointee = NArray(elem = NI8, size = n + 1)),
      value = NGlobal(name = gname),
      toTy = NPtr(pointee = NI8)
    )
  )
  NVal(ty = NPtr(pointee = NI8), value = NLocal(name = dest))
}

/// Emit `lyric_panic_msg(msg, file, line)` + `unreachable`, then open a
/// fresh dead block so the current block stays well-formed.
func emitPanicRaw(ctx: in Ctx, insns: in List[NInsn], msg: in String, line: in Int): Unit {
  val msgPtr = emitRawCString(ctx, insns, msg)
  val filePtr = emitRawCString(ctx, insns, ctx.mainPkg)
  val args: List[NArg] = newList()
  args.add(NArg(ty = NPtr(pointee = NI8), value = msgPtr.value))
  args.add(NArg(ty = NPtr(pointee = NI8), value = filePtr.value))
  args.add(NArg(ty = NI32, value = NLitInt(v = intToLong(line), ty = NI32)))
  insns.add(NCallVoid(fn = NGlobal(name = "lyric_panic_msg"), args = args))
  insns.add(NUnreachable)
  insns.add(NLabel(name = freshLabel(ctx, "dead")))
}

func intToLong(v: in Int): Long {
  v.toLong()
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Locals.
// ─────────────────────────────────────────────────────────────────────────────
/// Create a hoisted alloca slot for `name` and store `v` into it.
func bindLocal(ctx: in Ctx, insns: in List[NInsn], name: in String, v: in NVal): Unit {
  match v.ty {
    case NVoid -> {
      // A Unit binding owns no storage; record the type so reads of the
      // name yield Unit.
      if ctx.varTypes.containsKey(name) {
        ctx.varTypes.remove(name)
      }
      ctx.varTypes.add(name, NVoid)
    }
    case _ -> {
      // ARC Rule 4: the binding takes ownership — owned temps transfer,
      // borrows are retained; the owning scope releases on exit.
      if isRefNType(v.ty) {
        ensureOwned(ctx, insns, v)
      }
      val slot = name + ".slot." + freshTmp(ctx)
      ctx.allocas.add(NAlloca(dest = slot, ty = v.ty))
      insns.add(NStore(ty = v.ty, value = v.value, ptr = NLocal(name = slot)))
      if ctx.varSlots.containsKey(name) {
        ctx.varSlots.remove(name)
      }
      ctx.varSlots.add(name, slot)
      if ctx.varTypes.containsKey(name) {
        ctx.varTypes.remove(name)
      }
      ctx.varTypes.add(name, v.ty)
      if isRefNType(v.ty) and ctx.scopeRefs.count > 0 {
        ctx.scopeRefs[ctx.scopeRefs.count - 1].add(NOwnedLocal(slot = slot, ty = v.ty))
      }
    }
  }
}

func loadLocal(ctx: in Ctx, insns: in List[NInsn], name: in String): NVal {
  val ty = match mapGet(ctx.varTypes, name) {
    case Some(t) -> t
    case None -> panic("Lyric.LlvmCodegen: unknown name '" + name + "' (module-level constants and non-local references are not yet supported for --target native)")
  }
  match ty {
    case NVoid -> NVal(ty = NVoid, value = NUndef(ty = NVoid))
    case _ -> {
      val slot = match mapGet(ctx.varSlots, name) {
        case Some(s) -> s
        case None -> panic("Lyric.LlvmCodegen: no storage slot for '" + name + "'")
      }
      val dest = freshTmp(ctx)
      insns.add(NLoad(dest = dest, ty = ty, ptr = NLocal(name = slot)))
      NVal(ty = ty, value = NLocal(name = dest))
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Numeric helpers.
// ─────────────────────────────────────────────────────────────────────────────
func isIntNType(t: in NType): Bool {
  match t {
    case NI32 -> true
    case NI64 -> true
    case NI8 -> true
    case NI1 -> true
    case _ -> false
  }
}

/// Unify the operand types of a binary op: identical types pass; a
/// literal adapts to the other side's width.  Anything else is a
/// codegen error (the type checker rejects it upstream).
func unifyOperands(a: in NVal, b: in NVal): NType {
  val sameKind = nTypeToIrString(a.ty) == nTypeToIrString(b.ty)
  if sameKind {
    return a.ty
  }
  match a.value {
    case NLitInt(_, _) -> {
      if isIntNType(b.ty) {
        return b.ty
      }
    }
    case _ -> {
    }
  }
  match b.value {
    case NLitInt(_, _) -> {
      if isIntNType(a.ty) {
        return a.ty
      }
    }
    case _ -> {
    }
  }
  panic(
    "Lyric.LlvmCodegen: mixed operand types '" + nTypeToIrString(a.ty) + "' and '" + nTypeToIrString(b.ty) +
      "' (insert an explicit conversion such as .toLong()/.toFloat())"
  )
}

/// Emit the checked-division guard: panics at runtime on division by
/// zero and on the two's-complement MIN/-1 overflow, matching the
/// managed targets' exception semantics (LLVM sdiv would be UB).
func emitDivGuard(ctx: in Ctx, insns: in List[NInsn], ty: in NType, a: in NValue, b: in NValue, line: in Int): Unit {
  val minLit = match ty {
    case NI64 -> NLitInt(v = -9223372036854775807i64 - 1i64, ty = NI64)
    case _ -> NLitInt(v = -2147483648i64, ty = NI32)
  }
  val zeroCmp = freshTmp(ctx)
  insns.add(NICmp(dest = zeroCmp, pred = IEq, ty = ty, a = b, b = NLitInt(v = 0i64, ty = ty)))
  val minCmp = freshTmp(ctx)
  insns.add(NICmp(dest = minCmp, pred = IEq, ty = ty, a = a, b = minLit))
  val negOneCmp = freshTmp(ctx)
  insns.add(NICmp(dest = negOneCmp, pred = IEq, ty = ty, a = b, b = NLitInt(v = -1i64, ty = ty)))
  val ovf = freshTmp(ctx)
  insns.add(NAnd(dest = ovf, ty = NI1, a = NLocal(name = minCmp), b = NLocal(name = negOneCmp)))
  val bad = freshTmp(ctx)
  insns.add(NOr(dest = bad, ty = NI1, a = NLocal(name = zeroCmp), b = NLocal(name = ovf)))
  val trapL = freshLabel(ctx, "div.trap")
  val okL = freshLabel(ctx, "div.ok")
  insns.add(NCondBr(cond = NLocal(name = bad), thenLabel = trapL, elseLabel = okL))
  insns.add(NLabel(name = trapL))
  emitPanicRaw(ctx, insns, "integer division by zero or overflow", line)
  insns.add(NBr(label = okL))
  insns.add(NLabel(name = okL))
}

/// Division guard for unsigned widths (Byte): only division by zero can
/// trap — there is no MIN / -1 overflow case (#4628).
func emitDivZeroGuard(ctx: in Ctx, insns: in List[NInsn], ty: in NType, b: in NValue, line: in Int): Unit {
  val zeroCmp = freshTmp(ctx)
  insns.add(NICmp(dest = zeroCmp, pred = IEq, ty = ty, a = b, b = NLitInt(v = 0i64, ty = ty)))
  val trapL = freshLabel(ctx, "div.trap")
  val okL = freshLabel(ctx, "div.ok")
  insns.add(NCondBr(cond = NLocal(name = zeroCmp), thenLabel = trapL, elseLabel = okL))
  insns.add(NLabel(name = trapL))
  emitPanicRaw(ctx, insns, "integer division by zero", line)
  insns.add(NBr(label = okL))
  insns.add(NLabel(name = okL))
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. Runtime call helper.
// ─────────────────────────────────────────────────────────────────────────────
func callRuntime(ctx: in Ctx, insns: in List[NInsn], sym: in String, retTy: in NType, args: in List[NArg]): NVal {
  match retTy {
    case NVoid -> {
      insns.add(NCallVoid(fn = NGlobal(name = sym), args = args))
      NVal(ty = NVoid, value = NUndef(ty = NVoid))
    }
    case _ -> {
      val dest = freshTmp(ctx)
      insns.add(NCall(dest = dest, retTy = retTy, fn = NGlobal(name = sym), args = args))
      val outV = NVal(ty = retTy, value = NLocal(name = dest))
      // ARC Rule 6: a ref-returning call transfers ownership here.
      registerTemp(ctx, outV)
      outV
    }
  }
}

func arg1(ty: in NType, v: in NValue): List[NArg] {
  val args: List[NArg] = newList()
  args.add(NArg(ty = ty, value = v))
  args
}

func arg2(ty1: in NType, v1: in NValue, ty2: in NType, v2: in NValue): List[NArg] {
  val args: List[NArg] = newList()
  args.add(NArg(ty = ty1, value = v1))
  args.add(NArg(ty = ty2, value = v2))
  args
}

/// `.toString()` lowering for every scalar (and identity on String).
func emitToString(ctx: in Ctx, insns: in List[NInsn], v: in NVal): NVal {
  match v.ty {
    case NI32 -> {
      val wide = freshTmp(ctx)
      insns.add(NSExt(dest = wide, fromTy = NI32, value = v.value, toTy = NI64))
      callRuntime(ctx, insns, "lyric_string_from_int", lyricStringNType(), arg1(NI64, NLocal(name = wide)))
    }
    case NI64 -> callRuntime(ctx, insns, "lyric_string_from_int", lyricStringNType(), arg1(NI64, v.value))
    case NI8 -> {
      val wide = freshTmp(ctx)
      insns.add(NZExt(dest = wide, fromTy = NI8, value = v.value, toTy = NI64))
      callRuntime(ctx, insns, "lyric_string_from_int", lyricStringNType(), arg1(NI64, NLocal(name = wide)))
    }
    case NI1 -> callRuntime(ctx, insns, "lyric_string_from_bool", lyricStringNType(), arg1(NI32, widenBoolToI32(ctx, insns, v.value)))
    case NDouble -> callRuntime(ctx, insns, "lyric_string_from_float", lyricStringNType(), arg1(NDouble, v.value))
    case _ -> {
      if isStringNType(v.ty) {
        return v
      }
      panic("Lyric.LlvmCodegen: .toString() on this type is not yet supported for --target native (Phase N1)")
    }
  }
}

func widenBoolToI32(ctx: in Ctx, insns: in List[NInsn], v: in NValue): NValue {
  val dest = freshTmp(ctx)
  insns.add(NZExt(dest = dest, fromTy = NI1, value = v, toTy = NI32))
  NLocal(name = dest)
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. Expression lowering.
// ─────────────────────────────────────────────────────────────────────────────
func lowerExpr(ctx: in Ctx, insns: in List[NInsn], expr: in Expr): NVal {
  match expr.kind {
    case ELiteral(lit) -> lowerLiteral(ctx, insns, lit)
    case EInterpolated(segments) -> lowerInterpolated(ctx, insns, segments)
    case EPath(path) -> {
      val joined = modulePathJoin(path.segments)
      if path.segments.count == 1 {
        if ctx.varTypes.containsKey(path.segments[0]) {
          return loadLocal(ctx, insns, path.segments[0])
        }
      }
      // Nullary union case (`None`, `Option.None`) constructs an
      // instance; enum case paths (`Color.Red`) are i32 discriminants.
      match mapGet(ctx.caseRefs, joined) {
        case Some(cref) -> {
          val ui = match mapGet(ctx.unionDefs, cref.unionKey) {
            case Some(u) -> u
            case None -> panic("Lyric.LlvmCodegen: internal — case '" + joined + "' references unregistered union")
          }
          if ui.cases[cref.caseIdx].fieldNames.count > 0 {
            panic("Lyric.LlvmCodegen: union case '" + joined + "' requires arguments")
          }
          val noArgs: List[CallArg] = newList()
          return lowerUnionConstruct(ctx, insns, ui, cref.caseIdx, noArgs)
        }
        case None -> {
        }
      }
      match mapGet(ctx.enumDefs, joined) {
        case Some(idx) -> {
          if not Str.endsWith(joined, ".__enum") {
            return NVal(ty = NI32, value = NLitInt(v = intToLong(idx), ty = NI32))
          }
        }
        case None -> {
        }
      }
      if ctx.caseToGenericUnion.containsKey(joined) and not ctx.varTypes.containsKey(joined) {
        panic(
          "Lyric.LlvmCodegen: cannot infer the type arguments of generic union case '" + joined +
            "' here; annotate the binding, return type, or parameter it flows into"
        )
      }
      if path.segments.count == 1 {
        return loadLocal(ctx, insns, path.segments[0])
      }
      panic(
        "Lyric.LlvmCodegen: qualified value reference '" + joined +
          "' is not yet supported for --target native (module-level constants are Phase N2+)"
      )
    }
    case EParen(inner) -> lowerExpr(ctx, insns, inner)
    case EIf(cond, thenBranch, elseBranch, _) -> {
      val noWant: Option[NType] = None
      lowerIf(ctx, insns, cond, thenBranch, elseBranch, noWant)
    }
    case ECall(fn, args) -> lowerCall(ctx, insns, fn, args, expr.span.startPos.line)
    case EMember(receiver, memberName) -> lowerMember(ctx, insns, receiver, memberName)
    case EPrefix(op, operand) -> lowerPrefix(ctx, insns, op, operand)
    case EBinop(op, lhs, rhs) -> lowerBinop(ctx, insns, op, lhs, rhs, expr.span.startPos.line)
    case EBlock(block) -> lowerBlockValue(ctx, insns, block)
    case EAssign(target, op, value) -> {
      lowerAssign(ctx, insns, target, op, value, expr.span.startPos.line)
      NVal(ty = NVoid, value = NUndef(ty = NVoid))
    }
    case EMatch(scrutinee, arms) -> {
      val noWant: Option[NType] = None
      lowerMatch(ctx, insns, scrutinee, arms, expr.span.startPos.line, noWant)
    }
    // `self` in a record-method body is the desugared receiver param.
    case ESelf -> loadLocal(ctx, insns, "self")
    case ELambda(_, _) -> panic("Lyric.LlvmCodegen: a lambda here has no expected function type; bind it to an annotated val, a typed parameter, or a declared return type")
    case ETuple(exprs) -> {
      val elems: List[NVal] = newList()
      var ti = 0
      while ti < exprs.count {
        elems.add(lowerExpr(ctx, insns, exprs[ti]))
        ti = ti + 1
      }
      val elemTys: List[NType] = newList()
      var tj = 0
      while tj < elems.count {
        elemTys.add(elems[tj].ty)
        tj = tj + 1
      }
      lowerRecordConstructVals(ctx, insns, tupleRecInfo(ctx, elemTys), elems)
    }
    case EList(_) -> panic("Lyric.LlvmCodegen: list literals are not yet supported for --target native (collections are Phase N2/N5)")
    case EIndex(receiver, indices) -> lowerCollectionIndex(ctx, insns, receiver, indices, expr.span.startPos.line)
    // `await expr` is a pure passthrough on --target native (D-N-019): with
    // `spawn`/`scope` out of scope, no Lyric program in the supported
    // surface can hold an async call's result unawaited, so an async
    // function's declared return type is never wrapped — `await` has
    // nothing to unwrap.
    case EAwait(inner) -> lowerExpr(ctx, insns, inner)
    case _ -> panic("Lyric.LlvmCodegen: this expression form is not yet supported for --target native (Phase N1)")
  }
}

func lowerLiteral(ctx: in Ctx, insns: in List[NInsn], lit: in Literal): NVal {
  match lit {
    case LInt(v, suffix, _) -> {
      val isLong = match suffix { case I64 -> true; case U64 -> true; case _ -> v < -2147483648i64 or v > 2147483647i64 }
      if isLong {
        NVal(ty = NI64, value = NLitInt(v = v, ty = NI64))
      } else {
        NVal(ty = NI32, value = NLitInt(v = v, ty = NI32))
      }
    }
    case LFloat(v, _, _) -> NVal(ty = NDouble, value = NLitFloat(v = v))
    case LChar(codepoint) -> NVal(ty = NI32, value = NLitInt(v = codepoint.toLong(), ty = NI32))
    case LString(text) -> emitStringLiteral(ctx, insns, text)
    case LTripleString(text) -> emitStringLiteral(ctx, insns, text)
    case LRawString(text) -> emitStringLiteral(ctx, insns, text)
    case LBool(value) -> {
      if value {
        NVal(ty = NI1, value = NLitInt(v = 1i64, ty = NI1))
      } else {
        NVal(ty = NI1, value = NLitInt(v = 0i64, ty = NI1))
      }
    }
    case LUnit -> NVal(ty = NVoid, value = NUndef(ty = NVoid))
  }
}

func lowerInterpolated(ctx: in Ctx, insns: in List[NInsn], segments: in List[InterpolatedSegment]): NVal {
  if segments.count == 0 {
    return emitStringLiteral(ctx, insns, "")
  }
  var acc = match segments[0] {
    case ISText(text, _) -> emitStringLiteral(ctx, insns, text)
    case ISExpr(ex) -> emitToString(ctx, insns, lowerExpr(ctx, insns, ex))
  }
  var i = 1
  while i < segments.count {
    val piece = match segments[i] {
      case ISText(text, _) -> emitStringLiteral(ctx, insns, text)
      case ISExpr(ex) -> emitToString(ctx, insns, lowerExpr(ctx, insns, ex))
    }
    acc = callRuntime(
      ctx,
      insns,
      "lyric_string_concat",
      lyricStringNType(),
      arg2(lyricStringNType(), acc.value, lyricStringNType(), piece.value)
    )
    i = i + 1
  }
  acc
}

func lowerPrefix(ctx: in Ctx, insns: in List[NInsn], op: in PrefixOp, operand: in Expr): NVal {
  val v = lowerExpr(ctx, insns, operand)
  match op {
    case PreNeg -> {
      match v.ty {
        case NDouble -> {
          val dest = freshTmp(ctx)
          insns.add(NFNeg(dest = dest, a = v.value))
          NVal(ty = NDouble, value = NLocal(name = dest))
        }
        case _ -> {
          val dest = freshTmp(ctx)
          insns.add(NSub(dest = dest, ty = v.ty, a = NLitInt(v = 0i64, ty = v.ty), b = v.value))
          NVal(ty = v.ty, value = NLocal(name = dest))
        }
      }
    }
    case PreNot -> {
      val dest = freshTmp(ctx)
      insns.add(NXor(dest = dest, ty = NI1, a = v.value, b = NLitInt(v = 1i64, ty = NI1)))
      NVal(ty = NI1, value = NLocal(name = dest))
    }
    case PreRef -> panic("Lyric.LlvmCodegen: function references (&f) are not yet supported for --target native (pass a lambda instead)")
  }
}

func binIntOp(
  ctx: in Ctx, insns: in List[NInsn], op: in BinOp, ty: in NType, a: in NValue, b: in NValue, line: in Int
): NVal {
  val dest = freshTmp(ctx)
  match op {
    case BAdd -> insns.add(NAdd(dest = dest, ty = ty, a = a, b = b))
    case BSub -> insns.add(NSub(dest = dest, ty = ty, a = a, b = b))
    case BMul -> insns.add(NMul(dest = dest, ty = ty, a = a, b = b))
    case BDiv -> {
      // Byte is unsigned: udiv, and only the zero check applies (#4628).
      match ty {
        case NI8 -> {
          emitDivZeroGuard(ctx, insns, ty, b, line)
          insns.add(NUDiv(dest = dest, ty = ty, a = a, b = b))
        }
        case _ -> {
          emitDivGuard(ctx, insns, ty, a, b, line)
          insns.add(NSDiv(dest = dest, ty = ty, a = a, b = b))
        }
      }
    }
    case BMod -> {
      match ty {
        case NI8 -> {
          emitDivZeroGuard(ctx, insns, ty, b, line)
          insns.add(NURem(dest = dest, ty = ty, a = a, b = b))
        }
        case _ -> {
          emitDivGuard(ctx, insns, ty, a, b, line)
          insns.add(NSRem(dest = dest, ty = ty, a = a, b = b))
        }
      }
    }
    case _ -> panic("Lyric.LlvmCodegen: unexpected integer binop")
  }
  NVal(ty = ty, value = NLocal(name = dest))
}

func binFloatOp(ctx: in Ctx, insns: in List[NInsn], op: in BinOp, a: in NValue, b: in NValue): NVal {
  val dest = freshTmp(ctx)
  match op {
    case BAdd -> insns.add(NFAdd(dest = dest, a = a, b = b))
    case BSub -> insns.add(NFSub(dest = dest, a = a, b = b))
    case BMul -> insns.add(NFMul(dest = dest, a = a, b = b))
    case BDiv -> insns.add(NFDiv(dest = dest, a = a, b = b))
    case BMod -> insns.add(NFRem(dest = dest, a = a, b = b))
    case _ -> panic("Lyric.LlvmCodegen: unexpected float binop")
  }
  NVal(ty = NDouble, value = NLocal(name = dest))
}

func icmpPredFor(op: in BinOp): ICmpPred {
  match op {
    case BEq -> IEq
    case BNeq -> INe
    case BLt -> ISlt
    case BLte -> ISle
    case BGt -> ISgt
    case BGte -> ISge
    case _ -> panic("Lyric.LlvmCodegen: unexpected comparison op")
  }
}

/// Byte comparisons use the unsigned predicates (#4628).
func icmpPredForUnsigned(op: in BinOp): ICmpPred {
  match op {
    case BEq -> IEq
    case BNeq -> INe
    case BLt -> IUlt
    case BLte -> IUle
    case BGt -> IUgt
    case BGte -> IUge
    case _ -> panic("Lyric.LlvmCodegen: unexpected comparison op")
  }
}

func fcmpPredFor(op: in BinOp): FCmpPred {
  match op {
    case BEq -> FOeq
    case BNeq -> FUne
    case BLt -> FOlt
    case BLte -> FOle
    case BGt -> FOgt
    case BGte -> FOge
    case _ -> panic("Lyric.LlvmCodegen: unexpected float comparison op")
  }
}

func isComparisonOp(op: in BinOp): Bool {
  match op {
    case BEq -> true
    case BNeq -> true
    case BLt -> true
    case BLte -> true
    case BGt -> true
    case BGte -> true
    case _ -> false
  }
}

func lowerBinop(ctx: in Ctx, insns: in List[NInsn], op: in BinOp, lhs: in Expr, rhs: in Expr, line: in Int): NVal {
  // Short-circuit boolean forms first (rhs must not evaluate eagerly).
  match op {
    case BAnd -> return lowerShortCircuit(ctx, insns, lhs, rhs, true)
    case BOr -> return lowerShortCircuit(ctx, insns, lhs, rhs, false)
    case _ -> {
    }
  }
  val a = lowerExpr(ctx, insns, lhs)
  val b = lowerExpr(ctx, insns, rhs)
  if isStringNType(a.ty) or isStringNType(b.ty) {
    return lowerStringBinop(ctx, insns, op, a, b)
  }
  if isComparisonOp(op) {
    match unifyOperands(a, b) {
      case NDouble -> {
        val dest = freshTmp(ctx)
        insns.add(NFCmp(dest = dest, pred = fcmpPredFor(op), a = a.value, b = b.value))
        return NVal(ty = NI1, value = NLocal(name = dest))
      }
      case NI8 -> {
        val dest = freshTmp(ctx)
        insns.add(NICmp(dest = dest, pred = icmpPredForUnsigned(op), ty = NI8, a = a.value, b = b.value))
        return NVal(ty = NI1, value = NLocal(name = dest))
      }
      case ty -> {
        val dest = freshTmp(ctx)
        insns.add(NICmp(dest = dest, pred = icmpPredFor(op), ty = ty, a = a.value, b = b.value))
        return NVal(ty = NI1, value = NLocal(name = dest))
      }
    }
  }
  match op {
    case BXor -> {
      val ty = unifyOperands(a, b)
      val dest = freshTmp(ctx)
      insns.add(NXor(dest = dest, ty = ty, a = a.value, b = b.value))
      return NVal(ty = ty, value = NLocal(name = dest))
    }
    case _ -> {
    }
  }
  match unifyOperands(a, b) {
    case NDouble -> binFloatOp(ctx, insns, op, a.value, b.value)
    case ty -> binIntOp(ctx, insns, op, ty, a.value, b.value, line)
  }
}

func lowerStringBinop(ctx: in Ctx, insns: in List[NInsn], op: in BinOp, a: in NVal, b: in NVal): NVal {
  if not (isStringNType(a.ty) and isStringNType(b.ty)) {
    panic("Lyric.LlvmCodegen: mixed String/non-String operands (call .toString() explicitly)")
  }
  val sTy = lyricStringNType()
  match op {
    case BAdd -> callRuntime(ctx, insns, "lyric_string_concat", sTy, arg2(sTy, a.value, sTy, b.value))
    case BEq -> {
      val eq = callRuntime(ctx, insns, "lyric_string_eq", NI32, arg2(sTy, a.value, sTy, b.value))
      val dest = freshTmp(ctx)
      insns.add(NICmp(dest = dest, pred = INe, ty = NI32, a = eq.value, b = NLitInt(v = 0i64, ty = NI32)))
      NVal(ty = NI1, value = NLocal(name = dest))
    }
    case BNeq -> {
      val eq = callRuntime(ctx, insns, "lyric_string_eq", NI32, arg2(sTy, a.value, sTy, b.value))
      val dest = freshTmp(ctx)
      insns.add(NICmp(dest = dest, pred = IEq, ty = NI32, a = eq.value, b = NLitInt(v = 0i64, ty = NI32)))
      NVal(ty = NI1, value = NLocal(name = dest))
    }
    case BLt -> stringCmpTo(ctx, insns, a, b, ISlt)
    case BLte -> stringCmpTo(ctx, insns, a, b, ISle)
    case BGt -> stringCmpTo(ctx, insns, a, b, ISgt)
    case BGte -> stringCmpTo(ctx, insns, a, b, ISge)
    case _ -> panic("Lyric.LlvmCodegen: this String operator is not yet supported for --target native")
  }
}

func stringCmpTo(ctx: in Ctx, insns: in List[NInsn], a: in NVal, b: in NVal, pred: in ICmpPred): NVal {
  val sTy = lyricStringNType()
  val c = callRuntime(ctx, insns, "lyric_string_cmp", NI32, arg2(sTy, a.value, sTy, b.value))
  val dest = freshTmp(ctx)
  insns.add(NICmp(dest = dest, pred = pred, ty = NI32, a = c.value, b = NLitInt(v = 0i64, ty = NI32)))
  NVal(ty = NI1, value = NLocal(name = dest))
}

/// Short-circuit `and`/`or` through a temp slot: the right operand only
/// evaluates when the left one does not decide the result.
func lowerShortCircuit(ctx: in Ctx, insns: in List[NInsn], lhs: in Expr, rhs: in Expr, isAnd: in Bool): NVal {
  val slot = "sc.slot." + freshTmp(ctx)
  ctx.allocas.add(NAlloca(dest = slot, ty = NI1))
  val a = lowerExpr(ctx, insns, lhs)
  insns.add(NStore(ty = NI1, value = a.value, ptr = NLocal(name = slot)))
  val evalL = freshLabel(ctx, "sc.rhs")
  val doneL = freshLabel(ctx, "sc.done")
  if isAnd {
    insns.add(NCondBr(cond = a.value, thenLabel = evalL, elseLabel = doneL))
  } else {
    insns.add(NCondBr(cond = a.value, thenLabel = doneL, elseLabel = evalL))
  }
  insns.add(NLabel(name = evalL))
  val b = lowerExpr(ctx, insns, rhs)
  insns.add(NStore(ty = NI1, value = b.value, ptr = NLocal(name = slot)))
  insns.add(NBr(label = doneL))
  insns.add(NLabel(name = doneL))
  val dest = freshTmp(ctx)
  insns.add(NLoad(dest = dest, ty = NI1, ptr = NLocal(name = slot)))
  NVal(ty = NI1, value = NLocal(name = dest))
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. Member access and scalar methods.
// ─────────────────────────────────────────────────────────────────────────────
func lowerMember(ctx: in Ctx, insns: in List[NInsn], receiver: in Expr, memberName: in String): NVal {
  // `Color.Red` / `MaybeStr.Nothing` parse as member access on a type
  // path, not a multi-segment EPath: resolve enum cases and nullary
  // union cases before treating the receiver as a value.
  if isPackagePathExpr(ctx, receiver) {
    match receiver.kind {
      case EPath(rpath) -> {
        val joined = modulePathJoin(rpath.segments) + "." + memberName
        match mapGet(ctx.enumDefs, joined) {
          case Some(idx) -> return NVal(ty = NI32, value = NLitInt(v = intToLong(idx), ty = NI32))
          case None -> {
          }
        }
        match mapGet(ctx.caseRefs, joined) {
          case Some(cref) -> {
            val ui = match mapGet(ctx.unionDefs, cref.unionKey) {
              case Some(u) -> u
              case None -> panic("Lyric.LlvmCodegen: internal — case '" + joined + "' references unregistered union")
            }
            if ui.cases[cref.caseIdx].fieldNames.count > 0 {
              panic("Lyric.LlvmCodegen: union case '" + joined + "' requires arguments")
            }
            val noArgs: List[CallArg] = newList()
            return lowerUnionConstruct(ctx, insns, ui, cref.caseIdx, noArgs)
          }
          case None -> {
          }
        }
      }
      case _ -> {
      }
    }
  }
  val v = lowerExpr(ctx, insns, receiver)
  if isStringNType(v.ty) {
    if memberName == "length" {
      val n = callRuntime(ctx, insns, "lyric_string_len", NI64, arg1(lyricStringNType(), v.value))
      val dest = freshTmp(ctx)
      insns.add(NTrunc(dest = dest, fromTy = NI64, value = n.value, toTy = NI32))
      return NVal(ty = NI32, value = NLocal(name = dest))
    }
    panic("Lyric.LlvmCodegen: String member '." + memberName + "' is not yet supported for --target native (Phase N1)")
  }
  // Collections (N5.8): `.count` on List/Map receivers; `.length` is
  // the slice spelling of the same read (slices share the list repr,
  // D-N-015 — the type checker owns which spelling each type admits).
  if memberName == "count" or memberName == "length" {
    match listElemOfType(ctx, v.ty) {
      case Some(_) -> return listCountVal(ctx, insns, collectionAsI8(ctx, insns, v))
      case None -> {
      }
    }
    match mapKeyOfType(ctx, v.ty) {
      case Some(_) -> {
        val n = callRuntime(ctx, insns, "lyric_map_len", NI64, arg1(NPtr(pointee = NI8), collectionAsI8(ctx, insns, v)))
        val dest = freshTmp(ctx)
        insns.add(NTrunc(dest = dest, fromTy = NI64, value = n.value, toTy = NI32))
        return NVal(ty = NI32, value = NLocal(name = dest))
      }
      case None -> {
      }
    }
  }
  // Record field access: GEP + load (a borrow — the record keeps
  // ownership of the field value).
  match recInfoOfType(ctx, v.ty) {
    case Some(ri) -> return lowerRecordFieldLoad(ctx, insns, ri, v, memberName)
    case None -> {
    }
  }
  // Distinct types share their underlying representation, so `.value`
  // is the identity.  Record fields shadow this (checked above).
  if memberName == "value" {
    return v
  }
  panic(
    "Lyric.LlvmCodegen: member access '." + memberName +
      "' is not yet supported for --target native (this receiver has no such field)"
  )
}

func recFieldIndex(ri: in NRecInfo, fieldName: in String): Int {
  var i = 0
  while i < ri.fieldNames.count {
    if ri.fieldNames[i] == fieldName {
      return i
    }
    i = i + 1
  }
  0 - 1
}

func lowerRecordFieldLoad(ctx: in Ctx, insns: in List[NInsn], ri: in NRecInfo, v: in NVal, fieldName: in String): NVal {
  val idx = recFieldIndex(ri, fieldName)
  if idx < 0 {
    panic("Lyric.LlvmCodegen: record '" + ri.irName + "' has no field '" + fieldName + "'")
  }
  // A Unit field has no stored data (layoutFieldTys).
  if isVoidNType(ri.fieldTys[idx]) {
    return NVal(ty = NVoid, value = NUndef(ty = NVoid))
  }
  val structTy = match v.ty { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  val fieldPtr = freshTmp(ctx)
  val fArgs: List[NArg] = newList()
  fArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  fArgs.add(NArg(ty = NI32, value = NLitInt(v = intToLong(2 + idx), ty = NI32)))
  insns.add(NGEP(dest = fieldPtr, ty = structTy, ptr = v.value, indices = fArgs))
  val dest = freshTmp(ctx)
  insns.add(NLoad(dest = dest, ty = ri.fieldTys[idx], ptr = NLocal(name = fieldPtr)))
  NVal(ty = ri.fieldTys[idx], value = NLocal(name = dest))
}

/// Scalar method-call receivers: `.and/.or/.xor/.shl/.shr`, the
/// conversion family, `.toString()`, and String's `.substring`.
/// Returns None when `name` is not a scalar method (the caller then
/// resolves it as a UFCS function call).
func lowerScalarMethodCall(
  ctx: in Ctx,
  insns: in List[NInsn],
  v: in NVal,
  name: in String,
  args: in List[CallArg],
  line: in Int,
): Option[NVal] {
  if isStringNType(v.ty) {
    if name == "toString" and args.count == 0 {
      return Some(value = v)
    }
    if name == "substring" and args.count == 2 {
      val a0 = lowerPositionalArg(ctx, insns, args, 0)
      val a1 = lowerPositionalArg(ctx, insns, args, 1)
      val startW = freshTmp(ctx)
      insns.add(NSExt(dest = startW, fromTy = NI32, value = a0.value, toTy = NI64))
      val lenW = freshTmp(ctx)
      insns.add(NSExt(dest = lenW, fromTy = NI32, value = a1.value, toTy = NI64))
      val callArgs: List[NArg] = newList()
      callArgs.add(NArg(ty = lyricStringNType(), value = v.value))
      callArgs.add(NArg(ty = NI64, value = NLocal(name = startW)))
      callArgs.add(NArg(ty = NI64, value = NLocal(name = lenW)))
      return Some(value = callRuntime(ctx, insns, "lyric_string_substring", lyricStringNType(), callArgs))
    }
    return None
  }
  if name == "toString" and args.count == 0 {
    return Some(value = emitToString(ctx, insns, v))
  }
  if name == "toLong" and args.count == 0 {
    match v.ty {
      case NI32 -> {
        val dest = freshTmp(ctx)
        insns.add(NSExt(dest = dest, fromTy = NI32, value = v.value, toTy = NI64))
        return Some(value = NVal(ty = NI64, value = NLocal(name = dest)))
      }
      case NI64 -> return Some(value = v)
      case NI8 -> {
        val dest = freshTmp(ctx)
        insns.add(NZExt(dest = dest, fromTy = NI8, value = v.value, toTy = NI64))
        return Some(value = NVal(ty = NI64, value = NLocal(name = dest)))
      }
      case NDouble -> {
        val dest = freshTmp(ctx)
        insns.add(NFPToSI(dest = dest, fromTy = NDouble, value = v.value, toTy = NI64))
        return Some(value = NVal(ty = NI64, value = NLocal(name = dest)))
      }
      case _ -> {
      }
    }
  }
  if name == "toInt" and args.count == 0 {
    match v.ty {
      case NI64 -> {
        val dest = freshTmp(ctx)
        insns.add(NTrunc(dest = dest, fromTy = NI64, value = v.value, toTy = NI32))
        return Some(value = NVal(ty = NI32, value = NLocal(name = dest)))
      }
      case NI32 -> return Some(value = v)
      case NI8 -> {
        val dest = freshTmp(ctx)
        insns.add(NZExt(dest = dest, fromTy = NI8, value = v.value, toTy = NI32))
        return Some(value = NVal(ty = NI32, value = NLocal(name = dest)))
      }
      case NDouble -> {
        val dest = freshTmp(ctx)
        insns.add(NFPToSI(dest = dest, fromTy = NDouble, value = v.value, toTy = NI32))
        return Some(value = NVal(ty = NI32, value = NLocal(name = dest)))
      }
      case _ -> {
      }
    }
  }
  if (name == "toFloat" or name == "toDouble") and args.count == 0 {
    match v.ty {
      case NI32 -> {
        val dest = freshTmp(ctx)
        insns.add(NSIToFP(dest = dest, fromTy = NI32, value = v.value, toTy = NDouble))
        return Some(value = NVal(ty = NDouble, value = NLocal(name = dest)))
      }
      case NI64 -> {
        val dest = freshTmp(ctx)
        insns.add(NSIToFP(dest = dest, fromTy = NI64, value = v.value, toTy = NDouble))
        return Some(value = NVal(ty = NDouble, value = NLocal(name = dest)))
      }
      case NDouble -> return Some(value = v)
      case _ -> {
      }
    }
  }
  if name == "toByte" and args.count == 0 {
    match v.ty {
      case NI32 -> {
        val dest = freshTmp(ctx)
        insns.add(NTrunc(dest = dest, fromTy = NI32, value = v.value, toTy = NI8))
        return Some(value = NVal(ty = NI8, value = NLocal(name = dest)))
      }
      case NI64 -> {
        val dest = freshTmp(ctx)
        insns.add(NTrunc(dest = dest, fromTy = NI64, value = v.value, toTy = NI8))
        return Some(value = NVal(ty = NI8, value = NLocal(name = dest)))
      }
      case NI8 -> return Some(value = v)
      case _ -> {
      }
    }
  }
  if name == "toChar" and args.count == 0 {
    match v.ty {
      case NI32 -> return Some(value = v)
      case NI8 -> {
        val dest = freshTmp(ctx)
        insns.add(NZExt(dest = dest, fromTy = NI8, value = v.value, toTy = NI32))
        return Some(value = NVal(ty = NI32, value = NLocal(name = dest)))
      }
      case _ -> {
      }
    }
  }
  if args.count == 1 and (name == "and" or name == "or" or name == "xor" or name == "shl" or name == "shr") {
    val b = lowerPositionalArg(ctx, insns, args, 0)
    val ty = v.ty
    val bv = if name == "shl" or name == "shr" {
      // Shift amounts are Int in the surface language; widen/narrow to
      // the operand width (LLVM requires matching shift types).
      coerceShiftAmount(ctx, insns, ty, b)
    } else {
      b.value
    }
    val dest = freshTmp(ctx)
    if name == "and" {
      insns.add(NAnd(dest = dest, ty = ty, a = v.value, b = bv))
    } else if name == "or" {
      insns.add(NOr(dest = dest, ty = ty, a = v.value, b = bv))
    } else if name == "xor" {
      insns.add(NXor(dest = dest, ty = ty, a = v.value, b = bv))
    } else if name == "shl" {
      insns.add(NShl(dest = dest, ty = ty, a = v.value, b = bv))
    } else {
      // Byte is unsigned (its widenings zero-extend), so its right shift
      // is logical; the signed widths shift arithmetically (#4628).
      match ty {
        case NI8 -> insns.add(NLShr(dest = dest, ty = ty, a = v.value, b = bv))
        case _ -> insns.add(NAShr(dest = dest, ty = ty, a = v.value, b = bv))
      }
    }
    return Some(value = NVal(ty = ty, value = NLocal(name = dest)))
  }
  None
}

func coerceShiftAmount(ctx: in Ctx, insns: in List[NInsn], ty: in NType, amt: in NVal): NValue {
  val sameKind = nTypeToIrString(ty) == nTypeToIrString(amt.ty)
  if sameKind {
    return amt.value
  }
  match amt.value {
    case NLitInt(v, _) -> return NLitInt(v = v, ty = ty)
    case _ -> {
    }
  }
  match ty {
    case NI64 -> {
      val dest = freshTmp(ctx)
      insns.add(NSExt(dest = dest, fromTy = NI32, value = amt.value, toTy = NI64))
      NLocal(name = dest)
    }
    case _ -> {
      val dest = freshTmp(ctx)
      insns.add(NTrunc(dest = dest, fromTy = NI64, value = amt.value, toTy = ty))
      NLocal(name = dest)
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §10. Calls.
// ─────────────────────────────────────────────────────────────────────────────
func lowerPositionalArg(ctx: in Ctx, insns: in List[NInsn], args: in List[CallArg], idx: in Int): NVal {
  match args[idx] {
    case CAPositional(ex) -> lowerExpr(ctx, insns, ex)
    case CANamed(_, value, _) -> lowerExpr(ctx, insns, value)
  }
}

func isPackagePathExpr(ctx: in Ctx, e: in Expr): Bool {
  // A member receiver is a package path (not a value) when it is a path
  // whose head is not a local variable.
  match e.kind {
    case EPath(path) -> {
      if path.segments.count == 0 {
        return false
      }
      not ctx.varTypes.containsKey(path.segments[0])
    }
    case _ -> false
  }
}

/// Reorder call arguments to the callee's declared parameter order and
/// lower each.  Positional args bind left-to-right; named args bind by
/// declared name.
func lowerCallArgs(ctx: in Ctx, insns: in List[NInsn], sig: in NFuncSig, args: in List[CallArg]): List[NArg] {
  if args.count != sig.paramTys.count {
    panic(
      "Lyric.LlvmCodegen: call to '" + sig.irName + "' passes " + args.count.toString() +
        " argument(s) but the declaration has " +
        sig.paramTys.count.toString() +
        " (default arguments are not yet supported for --target native)"
    )
  }
  val ordered: List[NArg] = newList()
  bindCallArgs(ctx, insns, sig, args, 0, ordered)
  ordered
}

/// UFCS call-argument lowering: the pre-lowered receiver binds
/// parameter 0; `args` bind the remaining parameters.
func lowerCallArgsWithReceiver(
  ctx: in Ctx,
  insns: in List[NInsn],
  sig: in NFuncSig,
  recv: in NVal,
  args: in List[CallArg],
): List[NArg] {
  if args.count + 1 != sig.paramTys.count {
    panic(
      "Lyric.LlvmCodegen: method call to '" + sig.irName + "' passes " + (args.count + 1).toString() +
        " argument(s) (incl. receiver) but the declaration has " +
        sig.paramTys.count.toString()
    )
  }
  val ordered: List[NArg] = newList()
  val recvTy = typeToN(ctx, sig.paramTys[0])
  val rv = coerceTo(ctx, insns, recv, recvTy)
  ordered.add(NArg(ty = recvTy, value = rv.value))
  bindCallArgs(ctx, insns, sig, args, 1, ordered)
  ordered
}

/// Shared slot-binding body for both call-argument lowerers: evaluates
/// `args` in source order (Lyric's evaluation order) against `sig`'s
/// parameters starting at `firstSlot` (0 for free calls; 1 for UFCS
/// calls, whose pre-lowered receiver already occupies slot 0 in
/// `ordered`), then appends the slot-ordered, coerced NArgs.
func bindCallArgs(
  ctx: in Ctx,
  insns: in List[NInsn],
  sig: in NFuncSig,
  args: in List[CallArg],
  firstSlot: Int,
  ordered: in List[NArg],
): Unit {
  val vals: List[NVal] = newList()
  val slots: List[Int] = newList()
  var i = 0
  var nextPositional = firstSlot
  while i < args.count {
    match args[i] {
      case CAPositional(ex) -> {
        vals.add(lowerArgAgainst(ctx, insns, sig, ex, nextPositional))
        slots.add(nextPositional)
        nextPositional = nextPositional + 1
      }
      case CANamed(argName, value, _) -> {
        var slot = -1
        var pi = firstSlot
        while pi < sig.paramNames.count {
          if sig.paramNames[pi] == argName {
            slot = pi
          }
          pi = pi + 1
        }
        if slot < 0 {
          panic("Lyric.LlvmCodegen: named argument '" + argName + "' does not match a parameter of '" + sig.irName + "'")
        }
        vals.add(lowerArgAgainst(ctx, insns, sig, value, slot))
        slots.add(slot)
      }
    }
    i = i + 1
  }
  var pi2 = firstSlot
  while pi2 < sig.paramTys.count {
    var found = -1
    var vi = 0
    while vi < slots.count {
      if slots[vi] == pi2 {
        found = vi
      }
      vi = vi + 1
    }
    if found < 0 {
      panic("Lyric.LlvmCodegen: no argument bound for parameter " + pi2.toString() + " of '" + sig.irName + "'")
    }
    if sig.isExternSym and isFunctionTypeExpr(sig.paramTys[pi2]) {
      val fnDeclTy = typeExprToNType(sig.paramTys[pi2])
      val fv = externAdaptArg(ctx, insns, sig.paramTys[pi2], fnDeclTy, vals[found])
      ordered.add(NArg(ty = fnDeclTy, value = fv.value))
      pi2 = pi2 + 1
      continue
    }
    val declTy = typeToN(ctx, sig.paramTys[pi2])
    val v = if sig.isExternSym {
      externAdaptArg(ctx, insns, sig.paramTys[pi2], declTy, vals[found])
    } else {
      coerceTo(ctx, insns, vals[found], declTy)
    }
    ordered.add(NArg(ty = declTy, value = v.value))
    pi2 = pi2 + 1
  }
}

/// Lower one argument against its declared parameter (N4.5-aware):
/// normally with the declared type as the expected type; an extern
/// callback (function-typed) parameter expects the Lyric closure for
/// the callback's reduced signature, and an extern `NativePtr[Byte]`
/// parameter lowers with NO expected type — lowerExprExpecting's
/// fallback coerces eagerly, which would reject the closure value the
/// ordering pass adapts into the userdata pointer (a genuine i8* value
/// coerces there as a no-op).
func lowerArgAgainst(ctx: in Ctx, insns: in List[NInsn], sig: in NFuncSig, ex: in Expr, slot: Int): NVal {
  if sig.isExternSym {
    if isFunctionTypeExpr(sig.paramTys[slot]) {
      return lowerExprExpecting(ctx, insns, ex, externCallbackClosureWant(ctx, sig.paramTys[slot]))
    }
    if isBytePtrNType(typeToN(ctx, sig.paramTys[slot])) {
      return lowerExpr(ctx, insns, ex)
    }
  }
  lowerExprExpecting(ctx, insns, ex, typeToN(ctx, sig.paramTys[slot]))
}

/// Adapt a value to the declared type: integer literals retype freely;
/// Int widens to Long implicitly at a declared-Long boundary (matching
/// the managed backends' literal-friendly call sites).  Anything else
/// must already match.
func coerceTo(ctx: in Ctx, insns: in List[NInsn], v: in NVal, want: in NType): NVal {
  val sameKind = nTypeToIrString(v.ty) == nTypeToIrString(want)
  if sameKind {
    return v
  }
  // Implicit upcast: a concrete record flowing into an interface-typed
  // position (arg / return / binding / field / match arm) is boxed into a
  // fat pointer here (N3.2) — the type checker inserts no coercion node.
  match ifaceBoxInfoOfType(ctx, want) {
    case Some(info) -> {
      match recordIrNameOfType(v.ty) {
        case Some(rir) -> {
          match mapGet(ctx.ifaceVtables, rir + "|" + info.key) {
            case Some(vtGlobal) -> return buildIfaceBox(ctx, insns, v, info, vtGlobal)
            case None -> {
              // The type checker admitted this record→interface upcast, so
              // registerImplVtables should have emitted a vtable — a missing
              // one is a compiler-invariant violation, not a user error, so
              // fail fast rather than silently mistype the value (#4909).
              panic(
                "Lyric.LlvmCodegen: no vtable registered for record '" + rir + "' implementing interface '" + info.key +
                  "' (registerImplVtables invariant violation)"
              )
            }
          }
        }
        case None -> {
        }
      }
    }
    case None -> {
    }
  }
  match v.value {
    case NLitInt(litV, _) -> {
      if isIntNType(want) {
        return NVal(ty = want, value = NLitInt(v = litV, ty = want))
      }
      match want {
        case NDouble -> return NVal(ty = NDouble, value = NLitFloat(v = longToDouble(litV)))
        case _ -> {
        }
      }
    }
    case _ -> {
    }
  }
  val fromStr = nTypeToIrString(v.ty)
  val wantStr = nTypeToIrString(want)
  if fromStr == "i32" and wantStr == "i64" {
    val dest = freshTmp(ctx)
    insns.add(NSExt(dest = dest, fromTy = NI32, value = v.value, toTy = NI64))
    return NVal(ty = NI64, value = NLocal(name = dest))
  }
  panic(
    "Lyric.LlvmCodegen: cannot pass a '" + fromStr + "' where '" + wantStr +
      "' is expected (insert an explicit conversion)"
  )
}

func longToDouble(v: in Long): Double {
  v.toDouble()
}

func lowerCall(ctx: in Ctx, insns: in List[NInsn], fnExpr: in Expr, args: in List[CallArg], line: in Int): NVal {
  // Builtins first.
  match fnExpr.kind {
    case EPath(path) -> {
      if path.segments.count == 1 {
        val n = path.segments[0]
        if n == "panic" and args.count == 1 {
          val msg = lowerPositionalArg(ctx, insns, args, 0)
          val cs = callRuntime(ctx, insns, "lyric_string_to_cstring", NPtr(pointee = NI8), arg1(lyricStringNType(), msg.value))
          val filePtr = emitRawCString(ctx, insns, ctx.mainPkg)
          val pArgs: List[NArg] = newList()
          pArgs.add(NArg(ty = NPtr(pointee = NI8), value = cs.value))
          pArgs.add(NArg(ty = NPtr(pointee = NI8), value = filePtr.value))
          pArgs.add(NArg(ty = NI32, value = NLitInt(v = line.toLong(), ty = NI32)))
          insns.add(NCallVoid(fn = NGlobal(name = "lyric_panic_msg"), args = pArgs))
          insns.add(NUnreachable)
          insns.add(NLabel(name = freshLabel(ctx, "dead")))
          return NVal(ty = NVoid, value = NUndef(ty = NVoid))
        }
        if n == "nativeNullPtr" and args.count == 0 {
          // The C NULL pointer as a NativePtr[Byte] (N4.5) — e.g. the
          // attr argument of pthread_create.  Placement is the mode
          // checker's N0100 charge, like nativeAddrOf.
          return NVal(ty = NPtr(pointee = NI8), value = NLitNull(ty = NPtr(pointee = NI8)))
        }
        if n == "mapGet" and args.count == 2 {
          // Reserved Std.Collections accessor (N5.8): its pure-Lyric
          // body routes through an out-mode kernel call the native
          // backend does not lower.
          val m = lowerCallArgExpecting0Plain(ctx, insns, args)
          return lowerMapGetBuiltin(ctx, insns, m, args)
        }
        if n == "dictGetKeys" and args.count == 1 {
          val m = lowerCallArgExpecting0Plain(ctx, insns, args)
          val kTy = match mapKeyOfType(ctx, m.ty) {
            case Some(t) -> t
            case None -> panic("Lyric.LlvmCodegen: 'dictGetKeys' is reserved for Std.Collections maps on --target native")
          }
          return lowerMapSnapshotBuiltin(ctx, insns, m, "lyric_map_keys", kTy)
        }
        if n == "dictGetValues" and args.count == 1 {
          val m = lowerCallArgExpecting0Plain(ctx, insns, args)
          val vTy = match mapValOfType(ctx, m.ty) {
            case Some(t) -> t
            case None -> panic("Lyric.LlvmCodegen: 'dictGetValues' is reserved for Std.Collections maps on --target native")
          }
          return lowerMapSnapshotBuiltin(ctx, insns, m, "lyric_map_values", vTy)
        }
        if n == "newList" or n == "newListWithCapacity" or n == "newMap" {
          panic(
            "Lyric.LlvmCodegen: '" + n +
              "' needs its element types on --target native: annotate the binding (val xs: List[Int] = newList()) or pass explicit type arguments (newList[Int]())"
          )
        }
        if n == "nativeAddrOf" and args.count == 1 {
          // The address of a local's stack slot (N4.2).  The alloca IS
          // the pointer; mutability and placement rules (var-only,
          // kernel/@unsafe_ffi contexts, no escaping) are the mode
          // checker's N0100 charge.
          match args[0] {
            case CAPositional(ex) -> {
              match ex.kind {
                case EPath(apath) -> {
                  if apath.segments.count == 1 {
                    val an = apath.segments[0]
                    val aty = match mapGet(ctx.varTypes, an) {
                      case Some(t) -> t
                      case None -> panic("Lyric.LlvmCodegen: nativeAddrOf target '" + an + "' is not a local variable")
                    }
                    val aslot = match mapGet(ctx.varSlots, an) {
                      case Some(sl) -> sl
                      case None -> panic("Lyric.LlvmCodegen: nativeAddrOf target '" + an + "' has no stack slot")
                    }
                    return NVal(ty = NPtr(pointee = aty), value = NLocal(name = aslot))
                  }
                  panic("Lyric.LlvmCodegen: nativeAddrOf takes a local variable")
                }
                case _ -> panic("Lyric.LlvmCodegen: nativeAddrOf takes a local variable")
              }
            }
            case CANamed(_, _, _) -> panic("Lyric.LlvmCodegen: nativeAddrOf takes a positional local variable")
          }
        }
        if n == "assert" and args.count >= 1 {
          val cond = lowerPositionalArg(ctx, insns, args, 0)
          val okL = freshLabel(ctx, "assert.ok")
          val failL = freshLabel(ctx, "assert.fail")
          insns.add(NCondBr(cond = cond.value, thenLabel = okL, elseLabel = failL))
          insns.add(NLabel(name = failL))
          emitPanicRaw(ctx, insns, "assertion failed", line)
          insns.add(NBr(label = okL))
          insns.add(NLabel(name = okL))
          return NVal(ty = NVoid, value = NUndef(ty = NVoid))
        }
      }
    }
    case EMember(receiver, memberName) -> {
      if not isPackagePathExpr(ctx, receiver) {
        val recvVal = lowerExpr(ctx, insns, receiver)
        match lowerScalarMethodCall(ctx, insns, recvVal, memberName, args, line) {
          case Some(v) -> return v
          case None -> {
          }
        }
        match lowerCollectionMethodCall(ctx, insns, recvVal, memberName, args) {
          case Some(v) -> return v
          case None -> return lowerUfcsCall(ctx, insns, recvVal, memberName, args, line)
        }
      }
    }
    case ETypeApp(tfn, targs) -> {
      // Explicit collection constructors: newList[Int]() / newMap[K, V]().
      var tname = ""
      match tfn.kind {
        case EPath(tp) -> {
          if tp.segments.count == 1 {
            tname = tp.segments[0]
          }
        }
        case _ -> {
        }
      }
      if (tname == "newList" or tname == "newListWithCapacity") and targs.count == 1 {
        match targs[0] {
          case TAType(inner) -> {
            evalCtorArgsForEffect(ctx, insns, args)
            return constructList(ctx, insns, typeToN(ctx, inner))
          }
          case TAValue(_) -> panic("Lyric.LlvmCodegen: newList takes a type argument")
        }
      }
      if tname == "newMap" and targs.count == 2 {
        var kTy = NVoid
        var vTy = NVoid
        match targs[0] {
          case TAType(inner) -> {
            kTy = typeToN(ctx, inner)
          }
          case TAValue(_) -> panic("Lyric.LlvmCodegen: newMap takes type arguments")
        }
        match targs[1] {
          case TAType(inner) -> {
            vTy = typeToN(ctx, inner)
          }
          case TAValue(_) -> panic("Lyric.LlvmCodegen: newMap takes type arguments")
        }
        return constructMap(ctx, insns, kTy, vTy)
      }
    }
    case EIndex(ir, idxs) -> {
      // `newList[Long]()` parses as a call on an index expression, not
      // an ETypeApp — recover the type arguments from the index
      // expressions.
      var iname = ""
      match ir.kind {
        case EPath(ip) -> {
          if ip.segments.count == 1 {
            iname = ip.segments[0]
          }
        }
        case _ -> {
        }
      }
      if (iname == "newList" or iname == "newListWithCapacity") and idxs.count == 1 {
        evalCtorArgsForEffect(ctx, insns, args)
        return constructList(ctx, insns, typeToN(ctx, exprAsTypeExpr(idxs[0])))
      }
      if iname == "newMap" and idxs.count == 2 {
        val kTy = typeToN(ctx, exprAsTypeExpr(idxs[0]))
        val vTy = typeToN(ctx, exprAsTypeExpr(idxs[1]))
        return constructMap(ctx, insns, kTy, vTy)
      }
    }
    case _ -> {
    }
  }
  // Indirect call through a closure-typed local (N2.6).
  match fnExpr.kind {
    case EPath(cpath) -> {
      if cpath.segments.count == 1 and ctx.varTypes.containsKey(cpath.segments[0]) {
        val clos = loadLocal(ctx, insns, cpath.segments[0])
        match closureSigOfType(ctx, clos.ty) {
          case Some(cs) -> return lowerClosureCall(ctx, insns, clos, cs, args)
          case None -> panic("Lyric.LlvmCodegen: '" + cpath.segments[0] + "' is not callable (only function-typed values support indirect calls)")
        }
      }
    }
    case _ -> {
    }
  }
  // Static function call through the registry.
  val key = callKeyOf(fnExpr, args.count)
  if key.length == 0 {
    panic("Lyric.LlvmCodegen: indirect calls are not yet supported for --target native (rest of Phase N2.6)")
  }
  // Resolution order: self-package qualified, then the key as written,
  // then heap-type constructors (records, union cases, distinct types).
  val selfKey = ctx.curPkg[0] + "." + key
  // var-mutation shape (#4631).
  var sigOpt: Option[NFuncSig] = None
  match mapGet(ctx.sigs, selfKey) {
    case Some(s) -> {
      sigOpt = Some(value = s)
    }
    case None -> {
      sigOpt = mapGet(ctx.sigs, key)
    }
  }
  match sigOpt {
    case Some(sig) -> {
      val callArgs = lowerCallArgs(ctx, insns, sig, args)
      val retTy = retTypeToN(ctx, sig.retTy)
      match retTy {
        case NVoid -> {
          insns.add(NCallVoid(fn = NGlobal(name = sig.irName), args = callArgs))
          NVal(ty = NVoid, value = NUndef(ty = NVoid))
        }
        case _ -> {
          val dest = freshTmp(ctx)
          insns.add(NCall(dest = dest, retTy = retTy, fn = NGlobal(name = sig.irName), args = callArgs))
          val outV = NVal(ty = retTy, value = NLocal(name = dest))
          registerTemp(ctx, outV)
          outV
        }
      }
    }
    case None -> {
      // Generic functions instantiate per call site (N3.1).
      val noPre: List[NVal] = newList()
      if ctx.genericFnDefs.containsKey(ctx.curPkg[0] + "." + key) {
        return lowerGenericFnCall(ctx, insns, ctx.curPkg[0] + "." + key, noPre, args, line)
      }
      if ctx.genericFnDefs.containsKey(key) {
        return lowerGenericFnCall(ctx, insns, key, noPre, args, line)
      }
      lowerConstructCall(ctx, insns, fnExpr, args, key, line)
    }
  }
}

/// Constructor-call fallback for `lowerCall`: record construction,
/// union-case construction, and distinct-type conversion.
func lowerConstructCall(
  ctx: in Ctx,
  insns: in List[NInsn],
  fnExpr: in Expr,
  args: in List[CallArg],
  key: in String,
  line: in Int,
): NVal {
  val inner = match fnExpr.kind { case ETypeApp(f, _) -> f; case _ -> fnExpr }
  val name = match inner.kind {
    case EPath(path) -> modulePathJoin(path.segments)
    case EMember(recv, memberName) -> {
      match recv.kind {
        case EPath(rpath) -> modulePathJoin(rpath.segments) + "." + memberName
        case _ -> ""
      }
    }
    case _ -> ""
  }
  if name.length > 0 {
    // Bare `toString(x)` (the prelude free-function spelling the type
    // checker admits alongside the `.toString()` method form, D-N-003's
    // "toString"/"println"/... prelude list) reaches `lowerConstructCall`
    // as an unresolved call — `lowerCall` only tries `ctx.sigs` first, so a
    // genuine user function named `toString` would already have resolved
    // there.  Delegate to the same scalar-method lowering `.toString()`
    // uses so stdlib helpers built on the bare form (e.g.
    // `Std.Testing.assertEqualInt`) compile for native too.
    if name == "toString" and args.count == 1 {
      val tv = lowerPositionalArg(ctx, insns, args, 0)
      val noMethodArgs: List[CallArg] = newList()
      // `lowerScalarMethodCall`'s `None` arm is unreachable here: the type
      // checker only admits the prelude `toString(x)` call for a type that
      // supports string conversion, and every such type (String passthrough,
      // every scalar) is already handled by `lowerScalarMethodCall`'s
      // `.toString()` path.  If a future scalar-like type widens that set
      // without a matching `lowerScalarMethodCall` arm, the fallthrough below
      // would resolve `tv`'s already-lowered instructions against unrelated
      // construct forms (record/union/distinct) instead of surfacing a clear
      // "no toString for this type" diagnostic — worth revisiting if that
      // widening ever happens (#4984).
      match lowerScalarMethodCall(ctx, insns, tv, "toString", noMethodArgs, line) {
        case Some(result) -> return result
        case None -> {
        }
      }
    }
    if name == "NativeWeak" and args.count == 1 {
      val target = lowerPositionalArg(ctx, insns, args, 0)
      if not isRefNType(target.ty) {
        panic("Lyric.LlvmCodegen: NativeWeak requires an ARC-managed value")
      }
      val wty = weakNType(ctx, target.ty)
      val dest = freshTmp(ctx)
      insns.add(NBitcast(dest = dest, fromTy = target.ty, value = target.value, toTy = wty))
      // Non-owning: no retain, never registered as an owned temp.
      return NVal(ty = wty, value = NLocal(name = dest))
    }
    match mapGet(ctx.recordDefs, name) {
      case Some(ri) -> {
        if ctx.protectedRecNames.containsKey(ri.irName) {
          return lowerProtectedConstructArgs(ctx, insns, ri, args)
        }
        return lowerRecordConstructArgs(ctx, insns, ri, args)
      }
      case None -> {
      }
    }
    match mapGet(ctx.caseRefs, name) {
      case Some(cref) -> {
        val ui = match mapGet(ctx.unionDefs, cref.unionKey) {
          case Some(u) -> u
          case None -> panic("Lyric.LlvmCodegen: internal — case '" + name + "' references unregistered union")
        }
        return lowerUnionConstruct(ctx, insns, ui, cref.caseIdx, args)
      }
      case None -> {
      }
    }
    // Generic union case (`Some(5)`): infer type args, instantiate,
    // construct (N3.1).
    match mapGet(ctx.caseToGenericUnion, name) {
      case Some(gkey) -> {
        val dotIdx = lastDotIndex(name)
        val caseName = if dotIdx >= 0 { Str.substring(name, dotIdx + 1, name.length - dotIdx - 1) } else { name }
        return lowerGenericCaseConstruct(ctx, insns, gkey, caseName, args)
      }
      case None -> {
      }
    }
    if ctx.genericRecordDefs.containsKey(name) {
      return lowerGenericRecordConstruct(ctx, insns, genericQualifiedKey(ctx, name), args)
    }
    match mapGet(ctx.distinctDefs, name) {
      case Some(di) -> return lowerDistinctConstruct(ctx, insns, name, di, args, line)
      case None -> {
      }
    }
    // `X.From(v)` distinct-conversion spelling.
    if Str.endsWith(name, ".From") {
      val baseName = Str.substring(name, 0, name.length - 5)
      match mapGet(ctx.distinctDefs, baseName) {
        case Some(di) -> return lowerDistinctConstruct(ctx, insns, baseName, di, args, line)
        case None -> {
        }
      }
    }
  }
  panic(
    "Lyric.LlvmCodegen: cannot resolve call target '" + key +
      "' for --target native (the callee may be outside the bundled import closure)"
  )
}

/// UFCS method-call resolution: `recv.name(args)` calls the function
/// `name` with the receiver as its first argument.  Resolution tries
/// the current package, the receiver type's defining package (methods
/// in type bodies desugar to package functions, D037), then bare names.
func lowerUfcsCall(
  ctx: in Ctx,
  insns: in List[NInsn],
  recv: in NVal,
  name: in String,
  args: in List[CallArg],
  line: in Int,
): NVal {
  if name == "upgrade" and args.count == 0 {
    match weakTargetOfType(ctx, recv.ty) {
      case Some(target) -> return lowerWeakUpgrade(ctx, insns, recv, target)
      case None -> {
      }
    }
  }
  // Interface-typed receiver: dispatch through the vtable (N3.2).  A name
  // absent from the vtable slots reaches here only for a deferred method
  // form — the type checker already rejects methods not on the interface —
  // so name it specifically rather than falling through to the generic
  // "no matching function" panic (#4905).
  match ifaceBoxInfoOfType(ctx, recv.ty) {
    case Some(info) -> {
      val slot = ifaceMethodSlot(info, name)
      if slot >= 0 {
        return lowerIfaceDispatch(ctx, insns, recv, info, slot, args)
      }
      panic(
        "Lyric.LlvmCodegen: interface method '." + name + "' on '" + info.key +
          "' is not yet lowerable for --target native — only non-generic abstract interface methods dispatch through the vtable; default, generic, async, and Self-returning interface methods are deferred (N3.2)."
      )
    }
    case None -> {
    }
  }
  val arity = (args.count + 1).toString()
  var sigOpt = mapGet(ctx.sigs, ctx.curPkg[0] + "." + name + "/" + arity)
  match sigOpt {
    case Some(_) -> {
    }
    case None -> {
      match recv.ty {
        case NPtr(pointee) -> {
          match pointee {
            case NStruct(tyName, _) -> {
              val dotIdx = lastDotIndex(tyName)
              if dotIdx > 0 {
                sigOpt = mapGet(ctx.sigs, Str.substring(tyName, 0, dotIdx) + "." + name + "/" + arity)
              }
            }
            case _ -> {
            }
          }
        }
        case _ -> {
        }
      }
    }
  }
  match sigOpt {
    case Some(_) -> {
    }
    case None -> {
      sigOpt = mapGet(ctx.sigs, name + "/" + arity)
    }
  }
  match sigOpt {
    case Some(_) -> {
    }
    case None -> {
      // Generic UFCS: `m.unwrapOr(0)` resolves the generic function
      // with the receiver as its first argument.
      val pre: List[NVal] = newList()
      pre.add(recv)
      if ctx.genericFnDefs.containsKey(ctx.curPkg[0] + "." + name + "/" + arity) {
        return lowerGenericFnCall(ctx, insns, ctx.curPkg[0] + "." + name + "/" + arity, pre, args, line)
      }
      if ctx.genericFnDefs.containsKey(name + "/" + arity) {
        return lowerGenericFnCall(ctx, insns, name + "/" + arity, pre, args, line)
      }
    }
  }
  val sig = match sigOpt {
    case Some(s) -> s
    case None -> panic("Lyric.LlvmCodegen: method '." + name + "' on this receiver is not yet supported for --target native (no matching function '" + name + "/" + arity + "' in the bundled import closure)")
  }
  val callArgs = lowerCallArgsWithReceiver(ctx, insns, sig, recv, args)
  val retTy = retTypeToN(ctx, sig.retTy)
  match retTy {
    case NVoid -> {
      insns.add(NCallVoid(fn = NGlobal(name = sig.irName), args = callArgs))
      NVal(ty = NVoid, value = NUndef(ty = NVoid))
    }
    case _ -> {
      val dest = freshTmp(ctx)
      insns.add(NCall(dest = dest, retTy = retTy, fn = NGlobal(name = sig.irName), args = callArgs))
      val outV = NVal(ty = retTy, value = NLocal(name = dest))
      registerTemp(ctx, outV)
      outV
    }
  }
}

func lastDotIndex(s: in String): Int {
  var i = s.length - 1
  while i >= 0 {
    if Str.substring(s, i, 1) == "." {
      return i
    }
    i = i - 1
  }
  0 - 1
}

// ─────────────────────────────────────────────────────────────────────────────
// §10.5. Heap-type registration, destructors, and construction (Phase N2).
// ─────────────────────────────────────────────────────────────────────────────
func addRecKey(ctx: in Ctx, key: in String, ri: in NRecInfo): Unit {
  if not ctx.recordDefs.containsKey(key) {
    ctx.recordDefs.add(key, ri)
  }
}

func replaceRecKey(ctx: in Ctx, key: in String, ri: in NRecInfo): Unit {
  if ctx.recordDefs.containsKey(key) {
    match mapGet(ctx.recordDefs, key) {
      case Some(prior) -> {
        // Only replace the stub for the same declaration (first-wins
        // shadowing across packages must hold for bare names).
        if prior.irName != ri.irName {
          return
        }
      }
      case None -> {
      }
    }
    ctx.recordDefs.remove(key)
  }
  ctx.recordDefs.add(key, ri)
}

func addUnionKey(ctx: in Ctx, key: in String, ui: in NUnionInfo): Unit {
  if not ctx.unionDefs.containsKey(key) {
    ctx.unionDefs.add(key, ui)
  }
}

func replaceUnionKey(ctx: in Ctx, key: in String, ui: in NUnionInfo): Unit {
  if ctx.unionDefs.containsKey(key) {
    match mapGet(ctx.unionDefs, key) {
      case Some(prior) -> {
        if prior.irName != ui.irName {
          return
        }
      }
      case None -> {
      }
    }
    ctx.unionDefs.remove(key)
  }
  ctx.unionDefs.add(key, ui)
}

func recFieldsOf(decl: in RecordDecl): List[FieldDecl] {
  val fields: List[FieldDecl] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMField(f) -> fields.add(f)
      case RMInvariant(_) -> {
      }
      case RMFunc(_) -> {
        // Methods in type bodies desugar to package functions (D037);
        // native lowering of record methods lands with the stdlib port.
      }
    }
    i = i + 1
  }
  fields
}

func unionFieldName(f: in UnionField, idx: in Int): String {
  match f {
    case UFNamed(name, _, _) -> name
    case UFPos(_, _) -> "_" + idx.toString()
  }
}

func unionFieldTy(f: in UnionField): TypeExpr {
  match f {
    case UFNamed(_, ty, _) -> ty
    case UFPos(ty, _) -> ty
  }
}

/// Literal Long value of a range bound expression, or None when the
/// bound is not an integer literal.
func rangeBoundLit(e: in Expr): Option[Long] {
  match e.kind {
    case ELiteral(lit) -> {
      match lit {
        case LInt(v, _, _) -> Some(value = v)
        case _ -> None
      }
    }
    case EPrefix(op, operand) -> {
      match op {
        case PreNeg -> {
          match rangeBoundLit(operand) {
            case Some(v) -> Some(value = 0i64 - v)
            case None -> None
          }
        }
        case _ -> None
      }
    }
    case EParen(inner) -> rangeBoundLit(inner)
    case _ -> None
  }
}

/// Register every non-generic record/union/enum/distinct declaration in
/// the bundle.  Two phases: names first (so pointer-typed fields can
/// reference any registered type, including cyclically), then field
/// layouts, IR type definitions, and synthesised destructors.
func registerHeapTypes(
  ctx: in Ctx, units: in List[CodegenUnit], typeDefs: in List[NTypeDefn], fns: in List[NFunc]
): Unit {
  // Phase A: allocate names.
  var ui = 0
  while ui < units.count {
    val u = units[ui]
    var ri = 0
    while ri < u.records.count {
      val rd = u.records[ri]
      match rd.generics {
        case Some(_) -> registerGenericRecord(ctx, u.pkgName, rd)
        case None -> {
          val emptyNames: List[String] = newList()
          val emptyTys: List[NType] = newList()
          val emptyDflts: List[Option[Expr]] = newList()
          val stub = NRecInfo(
            irName = u.pkgName + "." + rd.name,
            fieldNames = emptyNames,
            fieldTys = emptyTys,
            fieldDefaults = emptyDflts
          )
          addRecKey(ctx, u.pkgName + "." + rd.name, stub)
          addRecKey(ctx, rd.name, stub)
        }
      }
      ri = ri + 1
    }
    var ci = 0
    while ci < u.unions.count {
      val ud = u.unions[ci]
      match ud.generics {
        case Some(_) -> registerGenericUnion(ctx, u.pkgName, ud)
        case None -> {
          val emptyCases: List[NUnionCaseInfo] = newList()
          val stub = NUnionInfo(irName = u.pkgName + "." + ud.name, cases = emptyCases, payloadWords = 0)
          addUnionKey(ctx, u.pkgName + "." + ud.name, stub)
          addUnionKey(ctx, ud.name, stub)
        }
      }
      ci = ci + 1
    }
    // Protected types (N3.4) are record-shaped, so they share the record
    // stub registry — allocates the name before field layouts (Phase B)
    // resolve, same as records above.
    var pdi = 0
    while pdi < u.protecteds.count {
      val pd = u.protecteds[pdi]
      match pd.generics {
        case Some(_) -> {
          // Generic protected types are deferred (N3.4 first slice); a
          // use panics with the normal type-resolution message.
        }
        case None -> {
          val emptyNames: List[String] = newList()
          val emptyTys: List[NType] = newList()
          val emptyDflts: List[Option[Expr]] = newList()
          val stub = NRecInfo(
            irName = u.pkgName + "." + pd.name,
            fieldNames = emptyNames,
            fieldTys = emptyTys,
            fieldDefaults = emptyDflts
          )
          addRecKey(ctx, u.pkgName + "." + pd.name, stub)
          addRecKey(ctx, pd.name, stub)
        }
      }
      pdi = pdi + 1
    }
    var gfi = 0
    while gfi < u.fns.count {
      val gfn = u.fns[gfi]
      match gfn.generics {
        case Some(_) -> {
          val akey = "/" + gfn.params.count.toString()
          if not ctx.genericFnDefs.containsKey(u.pkgName + "." + gfn.name + akey) {
            ctx.genericFnDefs.add(u.pkgName + "." + gfn.name + akey, gfn)
            ctx.genericFnPkg.add(u.pkgName + "." + gfn.name + akey, u.pkgName)
          }
          if not ctx.genericFnDefs.containsKey(gfn.name + akey) {
            ctx.genericFnDefs.add(gfn.name + akey, gfn)
            if not ctx.genericFnPkg.containsKey(gfn.name + akey) {
              ctx.genericFnPkg.add(gfn.name + akey, u.pkgName)
            }
          }
        }
        case None -> {
        }
      }
      gfi = gfi + 1
    }
    var ei = 0
    while ei < u.enums.count {
      val ed = u.enums[ei]
      if not ctx.enumDefs.containsKey(ed.name + ".__enum") {
        ctx.enumDefs.add(ed.name + ".__enum", 0)
      }
      if not ctx.enumDefs.containsKey(u.pkgName + "." + ed.name + ".__enum") {
        ctx.enumDefs.add(u.pkgName + "." + ed.name + ".__enum", 0)
      }
      var eci = 0
      while eci < ed.cases.count {
        val caseKey = ed.name + "." + ed.cases[eci].name
        if not ctx.enumDefs.containsKey(caseKey) {
          ctx.enumDefs.add(caseKey, eci)
        }
        val qKey = u.pkgName + "." + caseKey
        if not ctx.enumDefs.containsKey(qKey) {
          ctx.enumDefs.add(qKey, eci)
        }
        eci = eci + 1
      }
      ei = ei + 1
    }
    ui = ui + 1
  }
  // Phase B: field layouts, case tables, type definitions, destructors.
  // The user package (units[0]) registers strictly (unresolvable field
  // types panic with the precise message); bundled stdlib declarations
  // register tolerantly (skipped so a use, not the bundle, fails).
  var ui2 = 0
  while ui2 < units.count {
    val u = units[ui2]
    val strict = ui2 == 0
    var di = 0
    while di < u.distincts.count {
      val dd = u.distincts[di]
      match dd.generics {
        case Some(_) -> {
        }
        case None -> registerDistinct(ctx, u.pkgName, dd, strict)
      }
      di = di + 1
    }
    var ri = 0
    while ri < u.records.count {
      val rd = u.records[ri]
      match rd.generics {
        case Some(_) -> {
        }
        case None -> registerRecordLayout(ctx, u.pkgName, rd, typeDefs, fns, strict)
      }
      ri = ri + 1
    }
    var ci = 0
    while ci < u.unions.count {
      val ud = u.unions[ci]
      match ud.generics {
        case Some(_) -> {
        }
        case None -> registerUnionLayout(ctx, u.pkgName, ud, typeDefs, fns, strict)
      }
      ci = ci + 1
    }
    var pdi2 = 0
    while pdi2 < u.protecteds.count {
      val pd = u.protecteds[pdi2]
      match pd.generics {
        case Some(_) -> {
        }
        case None -> registerProtectedLayout(ctx, u.pkgName, pd, typeDefs, fns, strict)
      }
      pdi2 = pdi2 + 1
    }
    ui2 = ui2 + 1
  }
}

func registerDistinct(ctx: in Ctx, pkg: in String, dd: in DistinctTypeDecl, strict: in Bool): Unit {
  var under = NVoid
  var underOk = false
  match typeToNOpt(ctx, dd.underlying) {
    case Some(t) -> {
      under = t
      underOk = true
    }
    case None -> {
    }
  }
  if not underOk {
    if strict {
      // Re-run through the panicking path for the precise message.
      val _ = typeToN(ctx, dd.underlying)
    }
    return
  }
  var hasRange = false
  var lo = 0i64
  var hi = 0i64
  match dd.rangeClause {
    case Some(rb) -> {
      var loExprOpt: Option[Expr] = None
      var hiExprOpt: Option[Expr] = None
      var hiInclusive = true
      var openEnded = false
      match rb {
        case RBClosed(l, h) -> {
          loExprOpt = Some(value = l)
          hiExprOpt = Some(value = h)
        }
        case RBHalfOpen(l, h) -> {
          loExprOpt = Some(value = l)
          hiExprOpt = Some(value = h)
          hiInclusive = false
        }
        case RBLowerOpen(_) -> {
          openEnded = true
        }
        case RBUpperOpen(_) -> {
          openEnded = true
        }
      }
      if openEnded {
        if strict {
          panic("Lyric.LlvmCodegen: range subtype '" + dd.name + "' needs closed literal bounds for --target native")
        }
        return
      }
      // var-mutation shape (#4631: value-position match over Option
      // mis-lowers in the stage-0 seed).
      var loOpt: Option[Long] = None
      match loExprOpt {
        case Some(e) -> {
          loOpt = rangeBoundLit(e)
        }
        case None -> {
        }
      }
      var hiOpt: Option[Long] = None
      match hiExprOpt {
        case Some(e) -> {
          hiOpt = rangeBoundLit(e)
        }
        case None -> {
        }
      }
      var boundsOk = false
      match loOpt {
        case Some(l) -> {
          match hiOpt {
            case Some(h) -> {
              hasRange = true
              boundsOk = true
              lo = l
              hi = if hiInclusive { h } else { h - 1i64 }
            }
            case None -> {
            }
          }
        }
        case None -> {
        }
      }
      if not boundsOk {
        if strict {
          panic("Lyric.LlvmCodegen: range subtype '" + dd.name + "' needs literal bounds for --target native")
        }
        return
      }
    }
    case None -> {
    }
  }
  val info = NDistinctInfo(underlying = under, hasRange = hasRange, lo = lo, hi = hi)
  if not ctx.distinctDefs.containsKey(pkg + "." + dd.name) {
    ctx.distinctDefs.add(pkg + "." + dd.name, info)
  }
  if not ctx.distinctDefs.containsKey(dd.name) {
    ctx.distinctDefs.add(dd.name, info)
  }
}

func recDtorName(ri: in NRecInfo): String {
  ri.irName + ".dtor"
}

func recHasRefFields(ri: in NRecInfo): Bool {
  var i = 0
  while i < ri.fieldTys.count {
    if isRefNType(ri.fieldTys[i]) {
      return true
    }
    i = i + 1
  }
  false
}

/// Drop a stub registration (tolerant mode) so uses of the type fail
/// with the type-resolution message rather than a bad layout.
func unregisterRecStub(ctx: in Ctx, key: in String, irName: in String): Unit {
  match mapGet(ctx.recordDefs, key) {
    case Some(prior) -> {
      if prior.irName == irName {
        ctx.recordDefs.remove(key)
      }
    }
    case None -> {
    }
  }
}

func unregisterUnionStub(ctx: in Ctx, key: in String, irName: in String): Unit {
  match mapGet(ctx.unionDefs, key) {
    case Some(prior) -> {
      if prior.irName == irName {
        ctx.unionDefs.remove(key)
      }
    }
    case None -> {
    }
  }
}

func registerRecordLayout(
  ctx: in Ctx,
  pkg: in String,
  rd: in RecordDecl,
  typeDefs: in List[NTypeDefn],
  fns: in List[NFunc],
  strict: in Bool,
): Unit {
  val fields = recFieldsOf(rd)
  val names: List[String] = newList()
  val tys: List[NType] = newList()
  val dflts: List[Option[Expr]] = newList()
  val irName = pkg + "." + rd.name
  var i = 0
  while i < fields.count {
    names.add(fields[i].name)
    match typeToNOpt(ctx, fields[i].ty) {
      case Some(t) -> tys.add(t)
      case None -> {
        if strict {
          // Panicking path for the precise field-type message.
          tys.add(typeToN(ctx, fields[i].ty))
        } else {
          unregisterRecStub(ctx, irName, irName)
          unregisterRecStub(ctx, rd.name, irName)
          return
        }
      }
    }
    dflts.add(fields[i].dflt)
    i = i + 1
  }
  val ri = NRecInfo(irName = irName, fieldNames = names, fieldTys = tys, fieldDefaults = dflts)
  replaceRecKey(ctx, pkg + "." + rd.name, ri)
  replaceRecKey(ctx, rd.name, ri)
  val defnFields: List[NType] = newList()
  defnFields.add(NI32)
  defnFields.add(NPtr(pointee = NI8))
  val layoutTys = layoutFieldTys(tys)
  var fi = 0
  while fi < layoutTys.count {
    defnFields.add(layoutTys[fi])
    fi = fi + 1
  }
  typeDefs.add(NTypeDefn(name = ri.irName, fields = defnFields))
  if recHasRefFields(ri) {
    fns.add(synthRecordDtor(ctx, ri))
  }
}

func unionDtorName(ui: in NUnionInfo): String {
  ui.irName + ".dtor"
}

func unionHasRefFields(ui: in NUnionInfo): Bool {
  var ci = 0
  while ci < ui.cases.count {
    var fi = 0
    while fi < ui.cases[ci].fieldTys.count {
      if isRefNType(ui.cases[ci].fieldTys[fi]) {
        return true
      }
      fi = fi + 1
    }
    ci = ci + 1
  }
  false
}

func casePayloadStructName(ui: in NUnionInfo, caseName: in String): String {
  ui.irName + "." + caseName
}

func casePayloadStructType(ui: in NUnionInfo, ci: in NUnionCaseInfo): NType {
  NStruct(name = casePayloadStructName(ui, ci.name), fields = ci.fieldTys)
}

func registerUnionLayout(
  ctx: in Ctx,
  pkg: in String,
  ud: in UnionDecl,
  typeDefs: in List[NTypeDefn],
  fns: in List[NFunc],
  strict: in Bool,
): Unit {
  val cases: List[NUnionCaseInfo] = newList()
  val irName = pkg + "." + ud.name
  var maxBytes = 0
  var ci = 0
  while ci < ud.cases.count {
    val cd = ud.cases[ci]
    val names: List[String] = newList()
    val tys: List[NType] = newList()
    var fi = 0
    while fi < cd.fields.count {
      names.add(unionFieldName(cd.fields[fi], fi))
      match typeToNOpt(ctx, unionFieldTy(cd.fields[fi])) {
        case Some(t) -> tys.add(t)
        case None -> {
          if strict {
            tys.add(typeToN(ctx, unionFieldTy(cd.fields[fi])))
          } else {
            unregisterUnionStub(ctx, irName, irName)
            unregisterUnionStub(ctx, ud.name, irName)
            return
          }
        }
      }
      fi = fi + 1
    }
    val sz = structSize(tys)
    if sz > maxBytes {
      maxBytes = sz
    }
    cases.add(NUnionCaseInfo(name = cd.name, fieldNames = names, fieldTys = tys))
    ci = ci + 1
  }
  val words = (maxBytes + 7) / 8
  val ui = NUnionInfo(irName = irName, cases = cases, payloadWords = words)
  replaceUnionKey(ctx, pkg + "." + ud.name, ui)
  replaceUnionKey(ctx, ud.name, ui)
  typeDefs.add(NTypeDefn(name = ui.irName, fields = unionBodyFields(words)))
  var ci2 = 0
  while ci2 < cases.count {
    if cases[ci2].fieldTys.count > 0 {
      typeDefs.add(
        NTypeDefn(name = casePayloadStructName(ui, cases[ci2].name), fields = layoutFieldTys(cases[ci2].fieldTys))
      )
    }
    // Case-name entries resolve constructor calls and patterns.  The
    // unqualified name mirrors source scoping (first-wins).
    val cref = NCaseRef(unionKey = ui.irName, caseIdx = ci2)
    val bare = cases[ci2].name
    if not ctx.caseRefs.containsKey(bare) {
      ctx.caseRefs.add(bare, cref)
    }
    if not ctx.caseRefs.containsKey(ud.name + "." + bare) {
      ctx.caseRefs.add(ud.name + "." + bare, cref)
    }
    if not ctx.caseRefs.containsKey(pkg + "." + ud.name + "." + bare) {
      ctx.caseRefs.add(pkg + "." + ud.name + "." + bare, cref)
    }
    ci2 = ci2 + 1
  }
  if unionHasRefFields(ui) {
    fns.add(synthUnionDtor(ctx, ui))
  }
}

// ── Generic type instantiation (N3.1) ────────────────────────────────────────
func registerGenericRecord(ctx: in Ctx, pkg: in String, rd: in RecordDecl): Unit {
  val qualified = pkg + "." + rd.name
  if not ctx.genericRecordDefs.containsKey(qualified) {
    ctx.genericRecordDefs.add(qualified, rd)
    ctx.genericDeclPkg.add(qualified, pkg)
  }
  if not ctx.genericRecordDefs.containsKey(rd.name) {
    ctx.genericRecordDefs.add(rd.name, rd)
    if not ctx.genericDeclPkg.containsKey(rd.name) {
      ctx.genericDeclPkg.add(rd.name, pkg)
    }
  }
}

func registerGenericUnion(ctx: in Ctx, pkg: in String, ud: in UnionDecl): Unit {
  val qualified = pkg + "." + ud.name
  if not ctx.genericUnionDefs.containsKey(qualified) {
    ctx.genericUnionDefs.add(qualified, ud)
    ctx.genericDeclPkg.add(qualified, pkg)
  }
  if not ctx.genericUnionDefs.containsKey(ud.name) {
    ctx.genericUnionDefs.add(ud.name, ud)
    if not ctx.genericDeclPkg.containsKey(ud.name) {
      ctx.genericDeclPkg.add(ud.name, pkg)
    }
  }
  var ci = 0
  while ci < ud.cases.count {
    val caseName = ud.cases[ci].name
    if not ctx.caseToGenericUnion.containsKey(caseName) {
      ctx.caseToGenericUnion.add(caseName, qualified)
    }
    if not ctx.caseToGenericUnion.containsKey(ud.name + "." + caseName) {
      ctx.caseToGenericUnion.add(ud.name + "." + caseName, qualified)
    }
    if not ctx.caseToGenericUnion.containsKey(qualified + "." + caseName) {
      ctx.caseToGenericUnion.add(qualified + "." + caseName, qualified)
    }
    ci = ci + 1
  }
}

func genericParamNamesOf(gp: in Option[GenericParams]): List[String] {
  val names: List[String] = newList()
  match gp {
    case Some(g) -> {
      var i = 0
      while i < g.params.count {
        match g.params[i] {
          case GPType(name, _) -> names.add(name)
          case GPValue(_, _, _) -> {
          }
        }
        i = i + 1
      }
    }
    case None -> {
    }
  }
  names
}

/// The IR name of one instantiation: `Pkg.Name<i64,LyricString*>`.
/// Type args mangle without `%`/quotes — nested instantiations would
/// otherwise nest IR quoting and produce unparsable type names.
func instIrName(baseIr: in String, argTys: in List[NType]): String {
  var acc = baseIr + "<"
  var i = 0
  while i < argTys.count {
    if i > 0 {
      acc = acc + ","
    }
    acc = acc + mangleNTypeArg(argTys[i])
    i = i + 1
  }
  acc + ">"
}

func mangleNTypeArg(t: in NType): String {
  match t {
    case NPtr(pointee) -> {
      match pointee {
        case NStruct(name, _) -> name + "*"
        case _ -> mangleNTypeArg(pointee) + "*"
      }
    }
    case NArray(elem, size) -> "arr" + size.toString() + "." + mangleNTypeArg(elem)
    case _ -> nTypeToIrString(t)
  }
}

/// The uniform closure type for a call signature: a heap object
/// `{ rc, dtor, fnptr }` (captures live behind it in the per-lambda
/// impl struct).  Registered by struct name so call sites recover the
/// signature.
func closureNType(ctx: in Ctx, paramTys: in List[NType], retTy: in NType): NType {
  var nm = "__closure<" + mangleNTypeArg(retTy) + "("
  var i = 0
  while i < paramTys.count {
    if i > 0 {
      nm = nm + ","
    }
    nm = nm + mangleNTypeArg(paramTys[i])
    i = i + 1
  }
  nm = nm + ")>"
  if not ctx.closureSigs.containsKey(nm) {
    ctx.closureSigs.add(nm, NClosureSig(paramTys = paramTys, retTy = retTy))
    ctx.moduleTypeDefs.add(NTypeDefn(name = nm, fields = closureHeaderFields()))
  }
  NPtr(pointee = NStruct(name = nm, fields = closureHeaderFields()))
}

func closureHeaderFields(): List[NType] {
  val fields: List[NType] = newList()
  fields.add(NI32)
  fields.add(NPtr(pointee = NI8))
  fields.add(NPtr(pointee = NI8))
  fields
}

func closureSigOfType(ctx: in Ctx, t: in NType): Option[NClosureSig] {
  match t {
    case NPtr(pointee) -> {
      match pointee {
        case NStruct(name, _) -> mapGet(ctx.closureSigs, name)
        case _ -> None
      }
    }
    case _ -> None
  }
}

// ─── Callback trampolines (N4.5) ─────────────────────────────────────────────
// An extern func parameter of function type takes a Lyric closure.  The
// callback's C signature must carry the closure pointer as its LAST
// parameter, declared `NativePtr[Byte]` — the userdata slot every
// callback-driven C API provides.  The Lyric closure's own signature is
// the callback's minus that slot: for `start: func(NativePtr[Byte]):
// NativePtr[Byte]` (pthread_create's start routine) the argument is a
// `func(): NativePtr[Byte]` closure, and the SAME closure value is
// passed for the API's userdata argument (a closure in a
// `NativePtr[Byte]` extern-argument position lowers to a bitcast of the
// closure pointer).  The synthesised trampoline rebuilds the Lyric
// calling convention from the raw side:
//
//   define <R> @__lyric_cb_tramp.N(<P1..Pk-1>, i8* %ud) {
//     %fn = load the fnptr slot of (%ud as closure header)
//     call <R> %fn(i8* %ud, <P1..Pk-1>)
//   }
//
// The call-duration borrow needs no retain; a C API that holds the
// callback beyond the call requires the _kernel_native/ wrapper to
// retain/release around the registration (native/plan/05-ffi-design.md).
// Structural NativePtr[Byte] (i8*) test — string-comparing the IR
// spelling would silently stop matching under an opaque-pointer
// (`ptr`) rendering (#4733).
func isBytePtrNType(t: in NType): Bool {
  match t {
    case NPtr(pointee) -> {
      match pointee {
        case NI8 -> true
        case _ -> false
      }
    }
    case _ -> false
  }
}

func isFunctionTypeExpr(t: in TypeExpr): Bool {
  match t.kind {
    case TFunction(_, _) -> true
    case TParen(inner) -> isFunctionTypeExpr(inner)
    case _ -> false
  }
}

/// The Lyric-side expected type for a closure passed to an extern
/// callback parameter: the callback signature minus its trailing
/// userdata slot, as a closure struct pointer.
func externCallbackClosureWant(ctx: in Ctx, t: in TypeExpr): NType {
  match t.kind {
    case TParen(inner) -> externCallbackClosureWant(ctx, inner)
    case TFunction(parameters, retTy) -> {
      if parameters.count < 1 {
        panic(
          "Lyric.LlvmCodegen: an extern callback parameter must declare a trailing NativePtr[Byte] userdata slot (got a zero-parameter function type)"
        )
      }
      val lastTy = typeExprToNType(parameters[parameters.count - 1])
      if not isBytePtrNType(lastTy) {
        panic(
          "Lyric.LlvmCodegen: an extern callback parameter's last parameter must be NativePtr[Byte] (the userdata slot); got " +
            nTypeToIrString(lastTy)
        )
      }
      val reduced: List[NType] = newList()
      var i = 0
      while i < parameters.count - 1 {
        reduced.add(typeExprToNType(parameters[i]))
        i = i + 1
      }
      closureNType(ctx, reduced, typeExprToNType(retTy))
    }
    case _ -> panic("Lyric.LlvmCodegen: internal — externCallbackClosureWant on a non-function type")
  }
}

/// Synthesise (or reuse) the ccc trampoline for one callback signature;
/// returns the trampoline's symbol name.
func trampolineFor(ctx: in Ctx, t: in TypeExpr): String {
  match t.kind {
    case TParen(inner) -> return trampolineFor(ctx, inner)
    case _ -> {
    }
  }
  match t.kind {
    case TFunction(parameters, retTy) -> {
      val rawParams: List[NType] = newList()
      var i = 0
      while i < parameters.count {
        rawParams.add(typeExprToNType(parameters[i]))
        i = i + 1
      }
      val rawRet = typeExprToNType(retTy)
      val key = nTypeToIrString(NFnPtr(params = rawParams, ret = rawRet))
      match mapGet(ctx.trampolines, key) {
        case Some(existing) -> return existing
        case None -> {
        }
      }
      // The closure type this trampoline unwraps (registers the struct
      // and its signature as a side effect).
      val closTy = externCallbackClosureWant(ctx, t)
      val closStruct = match closTy { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
      val name = "__lyric_cb_tramp." + ctx.trampolines.count.toString()
      val params: List[NParam] = newList()
      var pi = 0
      while pi < rawParams.count - 1 {
        params.add(NParam(name = "p" + pi.toString(), ty = rawParams[pi]))
        pi = pi + 1
      }
      params.add(NParam(name = "ud", ty = NPtr(pointee = NI8)))
      val body: List[NInsn] = newList()
      body.add(NBitcast(dest = "hdr", fromTy = NPtr(pointee = NI8), value = NLocal(name = "ud"), toTy = closTy))
      val gArgs: List[NArg] = newList()
      gArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
      gArgs.add(NArg(ty = NI32, value = NLitInt(v = 2i64, ty = NI32)))
      body.add(NGEP(dest = "slot", ty = closStruct, ptr = NLocal(name = "hdr"), indices = gArgs))
      body.add(NLoad(dest = "fnraw", ty = NPtr(pointee = NI8), ptr = NLocal(name = "slot")))
      val lyricParams: List[NType] = newList()
      lyricParams.add(NPtr(pointee = NI8))
      var li = 0
      while li < rawParams.count - 1 {
        lyricParams.add(rawParams[li])
        li = li + 1
      }
      body.add(
        NBitcast(
          dest = "fn",
          fromTy = NPtr(pointee = NI8),
          value = NLocal(name = "fnraw"),
          toTy = NPtr(pointee = NFnPtr(params = lyricParams, ret = rawRet))
        )
      )
      val callArgs: List[NArg] = newList()
      callArgs.add(NArg(ty = NPtr(pointee = NI8), value = NLocal(name = "ud")))
      var ci = 0
      while ci < rawParams.count - 1 {
        callArgs.add(NArg(ty = rawParams[ci], value = NLocal(name = "p" + ci.toString())))
        ci = ci + 1
      }
      match rawRet {
        case NVoid -> {
          body.add(NCallVoid(fn = NLocal(name = "fn"), args = callArgs))
          body.add(NRetVoid)
        }
        case rt -> {
          body.add(NCall(dest = "r", retTy = rt, fn = NLocal(name = "fn"), args = callArgs))
          body.add(NRet(ty = rt, value = NLocal(name = "r")))
        }
      }
      ctx.moduleFns.add(
        NFunc(
          name = name,
          params = params,
          retTy = rawRet,
          isPublic = false,
          isExtern = false,
          body = body,
          attributes = newList()
        )
      )
      ctx.trampolines.add(key, name)
      name
    }
    case _ -> panic("Lyric.LlvmCodegen: internal — trampolineFor on a non-function type")
  }
}

/// Extern-call argument adaptation (N4.5): a closure value meeting a
/// function-pointer parameter becomes its trampoline symbol; a closure
/// value meeting a NativePtr[Byte] parameter becomes the closure
/// pointer itself (the userdata).  A List/Map value meeting a
/// NativePtr[Byte] parameter passes as its raw kernel pointer (the
/// lyric-rt process/collection helpers take container handles that
/// way).  Everything else coerces normally.
func externAdaptArg(ctx: in Ctx, insns: in List[NInsn], declTyExpr: in TypeExpr, declTy: in NType, v: in NVal): NVal {
  match declTy {
    case NFnPtr(_, _) -> {
      match closureSigOfType(ctx, v.ty) {
        case Some(_) -> return NVal(ty = declTy, value = NGlobal(name = trampolineFor(ctx, declTyExpr)))
        case None -> panic("Lyric.LlvmCodegen: an extern function-typed parameter takes a Lyric closure argument; got " + nTypeToIrString(v.ty))
      }
    }
    case _ -> {
    }
  }
  if isBytePtrNType(declTy) {
    match closureSigOfType(ctx, v.ty) {
      case Some(_) -> {
        val cast = freshTmp(ctx)
        insns.add(NBitcast(dest = cast, fromTy = v.ty, value = v.value, toTy = NPtr(pointee = NI8)))
        return NVal(ty = NPtr(pointee = NI8), value = NLocal(name = cast))
      }
      case None -> {
      }
    }
    match listElemOfType(ctx, v.ty) {
      case Some(_) -> {
        val cast = freshTmp(ctx)
        insns.add(NBitcast(dest = cast, fromTy = v.ty, value = v.value, toTy = NPtr(pointee = NI8)))
        return NVal(ty = NPtr(pointee = NI8), value = NLocal(name = cast))
      }
      case None -> {
      }
    }
    match mapKeyOfType(ctx, v.ty) {
      case Some(_) -> {
        val cast = freshTmp(ctx)
        insns.add(NBitcast(dest = cast, fromTy = v.ty, value = v.value, toTy = NPtr(pointee = NI8)))
        return NVal(ty = NPtr(pointee = NI8), value = NLocal(name = cast))
      }
      case None -> {
      }
    }
  }
  coerceTo(ctx, insns, v, declTy)
}

/// `NativeWeak[T]`: a non-owning pointer sharing T's representation
/// behind a marker struct name (excluded from ARC by `isRefNType`).
func listHeaderFields(): List[NType] {
  // ─── Collections (N5.8) ──────────────────────────────────────────────────────
  // `List[T]` / `Map[K, V]` lower to the lyric-rt C kernels
  // (`lyric_list_*` / `lyric_map_*`): a single fixed layout storing every
  // element in a 64-bit slot, with ref-typed entries retained by the
  // container itself (`elems_are_refs` / `vals_are_refs`, declared at
  // construction).  Each instantiation gets its own struct NAME so the
  // Lyric-level element types survive to method lowering, but the fields
  // mirror the one C layout and all access goes through runtime calls —
  // the emitted struct definitions are never GEPed.
  val fields: List[NType] = newList()
  fields.add(NI32)
  fields.add(NPtr(pointee = NI8))
  fields.add(NPtr(pointee = NI64))
  fields.add(NI64)
  fields.add(NI64)
  fields.add(NI32)
  fields
}

func listNType(ctx: in Ctx, elem: in NType): NType {
  val nm = "__list<" + mangleNTypeArg(elem) + ">"
  val fields = listHeaderFields()
  if not ctx.listElems.containsKey(nm) {
    ctx.listElems.add(nm, elem)
    ctx.moduleTypeDefs.add(NTypeDefn(name = nm, fields = fields))
  }
  NPtr(pointee = NStruct(name = nm, fields = fields))
}

// The C LyricMap is opaque; only the ARC header prefix is declared.
func mapHeaderFields(): List[NType] {
  val fields: List[NType] = newList()
  fields.add(NI32)
  fields.add(NPtr(pointee = NI8))
  fields
}

func mapNType(ctx: in Ctx, k: in NType, v: in NType): NType {
  val nm = "__map<" + mangleNTypeArg(k) + "," + mangleNTypeArg(v) + ">"
  val fields = mapHeaderFields()
  if not ctx.mapKeyTys.containsKey(nm) {
    ctx.mapKeyTys.add(nm, k)
    ctx.mapValTys.add(nm, v)
    ctx.moduleTypeDefs.add(NTypeDefn(name = nm, fields = fields))
  }
  NPtr(pointee = NStruct(name = nm, fields = fields))
}

func listElemOfType(ctx: in Ctx, t: in NType): Option[NType] {
  match t {
    case NPtr(pointee) -> {
      match pointee {
        case NStruct(name, _) -> mapGet(ctx.listElems, name)
        case _ -> None
      }
    }
    case _ -> None
  }
}

func mapKeyOfType(ctx: in Ctx, t: in NType): Option[NType] {
  match t {
    case NPtr(pointee) -> {
      match pointee {
        case NStruct(name, _) -> mapGet(ctx.mapKeyTys, name)
        case _ -> None
      }
    }
    case _ -> None
  }
}

func mapValOfType(ctx: in Ctx, t: in NType): Option[NType] {
  match t {
    case NPtr(pointee) -> {
      match pointee {
        case NStruct(name, _) -> mapGet(ctx.mapValTys, name)
        case _ -> None
      }
    }
    case _ -> None
  }
}

// Widen a value to the container's 64-bit slot representation.
func slotOfVal(ctx: in Ctx, insns: in List[NInsn], v: in NVal): NValue {
  if isRefNType(v.ty) {
    val dest = freshTmp(ctx)
    insns.add(NPtrToInt(dest = dest, fromTy = v.ty, value = v.value, toTy = NI64))
    return NLocal(name = dest)
  }
  match v.ty {
    case NI64 -> v.value
    case NDouble -> {
      val dest = freshTmp(ctx)
      insns.add(NBitcast(dest = dest, fromTy = NDouble, value = v.value, toTy = NI64))
      NLocal(name = dest)
    }
    case NI32 -> {
      val dest = freshTmp(ctx)
      insns.add(NSExt(dest = dest, fromTy = NI32, value = v.value, toTy = NI64))
      NLocal(name = dest)
    }
    case NI8 -> {
      val dest = freshTmp(ctx)
      insns.add(NZExt(dest = dest, fromTy = NI8, value = v.value, toTy = NI64))
      NLocal(name = dest)
    }
    case NI1 -> {
      val dest = freshTmp(ctx)
      insns.add(NZExt(dest = dest, fromTy = NI1, value = v.value, toTy = NI64))
      NLocal(name = dest)
    }
    case _ -> panic("Lyric.LlvmCodegen: this element type cannot be stored in a List/Map slot for --target native: " + nTypeToIrString(v.ty))
  }
}

// Narrow a 64-bit slot back to the element type.  Ref-typed results are
// BORROWS (the kernel get does not retain); binding retains, matching
// record-field reads.
func valOfSlot(ctx: in Ctx, insns: in List[NInsn], slot: in NValue, elemTy: in NType): NVal {
  if isRefNType(elemTy) {
    val dest = freshTmp(ctx)
    insns.add(NIntToPtr(dest = dest, fromTy = NI64, value = slot, toTy = elemTy))
    return NVal(ty = elemTy, value = NLocal(name = dest))
  }
  match elemTy {
    case NI64 -> NVal(ty = NI64, value = slot)
    case NDouble -> {
      val dest = freshTmp(ctx)
      insns.add(NBitcast(dest = dest, fromTy = NI64, value = slot, toTy = NDouble))
      NVal(ty = NDouble, value = NLocal(name = dest))
    }
    case NI32 -> {
      val dest = freshTmp(ctx)
      insns.add(NTrunc(dest = dest, fromTy = NI64, value = slot, toTy = NI32))
      NVal(ty = NI32, value = NLocal(name = dest))
    }
    case NI8 -> {
      val dest = freshTmp(ctx)
      insns.add(NTrunc(dest = dest, fromTy = NI64, value = slot, toTy = NI8))
      NVal(ty = NI8, value = NLocal(name = dest))
    }
    case NI1 -> {
      val dest = freshTmp(ctx)
      insns.add(NTrunc(dest = dest, fromTy = NI64, value = slot, toTy = NI1))
      NVal(ty = NI1, value = NLocal(name = dest))
    }
    case _ -> panic("Lyric.LlvmCodegen: this element type cannot be read from a List/Map slot for --target native: " + nTypeToIrString(elemTy))
  }
}

// The list/map receiver as the i8* the runtime functions take.
func collectionAsI8(ctx: in Ctx, insns: in List[NInsn], v: in NVal): NValue {
  val dest = freshTmp(ctx)
  insns.add(NBitcast(dest = dest, fromTy = v.ty, value = v.value, toTy = NPtr(pointee = NI8)))
  NLocal(name = dest)
}

func refFlagOf(t: in NType): NValue {
  if isRefNType(t) {
    return NLitInt(v = 1i64, ty = NI32)
  }
  NLitInt(v = 0i64, ty = NI32)
}

func constructList(ctx: in Ctx, insns: in List[NInsn], elem: in NType): NVal {
  val raw = callRuntime(ctx, insns, "lyric_list_new", NPtr(pointee = NI8), arg1(NI32, refFlagOf(elem)))
  val ty = listNType(ctx, elem)
  val dest = freshTmp(ctx)
  insns.add(NBitcast(dest = dest, fromTy = NPtr(pointee = NI8), value = raw.value, toTy = ty))
  val outV = NVal(ty = ty, value = NLocal(name = dest))
  registerTemp(ctx, outV)
  outV
}

func constructMap(ctx: in Ctx, insns: in List[NInsn], k: in NType, v: in NType): NVal {
  var keyFlag = NLitInt(v = 0i64, ty = NI32)
  if isStringNType(k) {
    keyFlag = NLitInt(v = 1i64, ty = NI32)
  } else {
    if isRefNType(k) {
      panic("Lyric.LlvmCodegen: Map keys on --target native must be String or a scalar type; got " + nTypeToIrString(k))
    }
  }
  val mArgs: List[NArg] = newList()
  mArgs.add(NArg(ty = NI32, value = keyFlag))
  mArgs.add(NArg(ty = NI32, value = refFlagOf(v)))
  val raw = callRuntime(ctx, insns, "lyric_map_new", NPtr(pointee = NI8), mArgs)
  val ty = mapNType(ctx, k, v)
  val dest = freshTmp(ctx)
  insns.add(NBitcast(dest = dest, fromTy = NPtr(pointee = NI8), value = raw.value, toTy = ty))
  val outV = NVal(ty = ty, value = NLocal(name = dest))
  registerTemp(ctx, outV)
  outV
}

/// The capacity hint of `newListWithCapacity(n)` has no kernel
/// equivalent (lyric_list_new grows on demand); the argument
/// expression still evaluates for effect.
func evalCtorArgsForEffect(ctx: in Ctx, insns: in List[NInsn], ctorArgs: in List[CallArg]): Unit {
  var ai = 0
  while ai < ctorArgs.count {
    match ctorArgs[ai] {
      case CAPositional(ex) -> {
        val _ = lowerExpr(ctx, insns, ex)
      }
      case CANamed(_, value, _) -> {
        val _ = lowerExpr(ctx, insns, value)
      }
    }
    ai = ai + 1
  }
}

/// Bare `newList()` / `newListWithCapacity(n)` / `newMap()` construct
/// against the expected collection type — the type arguments live in
/// the binding annotation, mirroring the managed kernels' generic
/// constructors.  (Explicit `newList[Int]()` type applications resolve
/// in lowerCall without an expected type.)
func collectionConstructForExpected(ctx: in Ctx, insns: in List[NInsn], e: in Expr, want: in NType): Option[NVal] {
  var nm = ""
  var ctorArgs: List[CallArg] = newList()
  match e.kind {
    case ECall(fn, callArgs) -> {
      match fn.kind {
        case EPath(p) -> {
          if p.segments.count == 1 {
            nm = p.segments[0]
          }
        }
        case _ -> {
        }
      }
      ctorArgs = callArgs
    }
    case _ -> {
    }
  }
  if nm == "newList" or nm == "newListWithCapacity" {
    match listElemOfType(ctx, want) {
      case Some(elem) -> {
        evalCtorArgsForEffect(ctx, insns, ctorArgs)
        return Some(value = constructList(ctx, insns, elem))
      }
      case None -> {
      }
    }
  }
  if nm == "newMap" and ctorArgs.count == 0 {
    match mapKeyOfType(ctx, want) {
      case Some(k) -> {
        match mapValOfType(ctx, want) {
          case Some(v) -> return Some(value = constructMap(ctx, insns, k, v))
          case None -> {
          }
        }
      }
      case None -> {
      }
    }
  }
  None
}

/// Instance methods on List[T] / Map[K, V] receivers, lowered to the
/// lyric-rt kernels (the collections surface has no Lyric-declared
/// method bodies — on managed targets these dispatch to the BCL).
func lowerCollectionMethodCall(
  ctx: in Ctx,
  insns: in List[NInsn],
  recv: in NVal,
  name: in String,
  args: in List[CallArg],
): Option[NVal] {
  match listElemOfType(ctx, recv.ty) {
    case Some(elem) -> {
      val recvP = collectionAsI8(ctx, insns, recv)
      if name == "add" and args.count == 1 {
        val v = lowerCallArgExpecting(ctx, insns, args, 0, elem)
        val pArgs: List[NArg] = newList()
        pArgs.add(NArg(ty = NPtr(pointee = NI8), value = recvP))
        pArgs.add(NArg(ty = NI64, value = slotOfVal(ctx, insns, v)))
        return Some(value = callRuntime(ctx, insns, "lyric_list_push", NVoid, pArgs))
      }
      if name == "set" and args.count == 2 {
        val idx = lowerCallArgExpecting(ctx, insns, args, 0, NI64)
        val v = lowerCallArgExpecting(ctx, insns, args, 1, elem)
        val pArgs: List[NArg] = newList()
        pArgs.add(NArg(ty = NPtr(pointee = NI8), value = recvP))
        pArgs.add(NArg(ty = NI64, value = idx.value))
        pArgs.add(NArg(ty = NI64, value = slotOfVal(ctx, insns, v)))
        return Some(value = callRuntime(ctx, insns, "lyric_list_set", NVoid, pArgs))
      }
      if name == "removeAt" and args.count == 1 {
        val idx = lowerCallArgExpecting(ctx, insns, args, 0, NI64)
        val pArgs: List[NArg] = newList()
        pArgs.add(NArg(ty = NPtr(pointee = NI8), value = recvP))
        pArgs.add(NArg(ty = NI64, value = idx.value))
        return Some(value = callRuntime(ctx, insns, "lyric_list_remove_at", NVoid, pArgs))
      }
      if name == "clear" and args.count == 0 {
        return Some(value = callRuntime(ctx, insns, "lyric_list_clear", NVoid, arg1(NPtr(pointee = NI8), recvP)))
      }
      if (name == "count" or name == "length") and args.count == 0 {
        return Some(value = listCountVal(ctx, insns, recvP))
      }
      // `List.toArray()` and `slice.toList()` are both a fresh shallow
      // copy on the native target: list and slice share the LyricList
      // repr (D-N-015), so the snapshot IS the conversion.  Ref
      // elements are retained by the copy; the result registers as an
      // owned temp like any other constructor.
      if (name == "toArray" or name == "toList") and args.count == 0 {
        val raw = freshTmp(ctx)
        val cArgs: List[NArg] = newList()
        cArgs.add(NArg(ty = NPtr(pointee = NI8), value = recvP))
        insns.add(NCall(dest = raw, retTy = NPtr(pointee = NI8), fn = NGlobal(name = "lyric_list_copy"), args = cArgs))
        val cast = freshTmp(ctx)
        insns.add(NBitcast(dest = cast, fromTy = NPtr(pointee = NI8), value = NLocal(name = raw), toTy = recv.ty))
        val outV = NVal(ty = recv.ty, value = NLocal(name = cast))
        registerTemp(ctx, outV)
        return Some(value = outV)
      }
      return None
    }
    case None -> {
    }
  }
  match mapKeyOfType(ctx, recv.ty) {
    case Some(k) -> {
      val vTy = match mapValOfType(ctx, recv.ty) {
        case Some(t) -> t
        case None -> panic("Lyric.LlvmCodegen: internal — map type without a value type")
      }
      val recvP = collectionAsI8(ctx, insns, recv)
      if name == "add" and args.count == 2 {
        val kv = lowerCallArgExpecting(ctx, insns, args, 0, k)
        val vv = lowerCallArgExpecting(ctx, insns, args, 1, vTy)
        val pArgs: List[NArg] = newList()
        pArgs.add(NArg(ty = NPtr(pointee = NI8), value = recvP))
        pArgs.add(NArg(ty = NI64, value = slotOfVal(ctx, insns, kv)))
        pArgs.add(NArg(ty = NI64, value = slotOfVal(ctx, insns, vv)))
        return Some(value = callRuntime(ctx, insns, "lyric_map_set", NVoid, pArgs))
      }
      if name == "containsKey" and args.count == 1 {
        val kv = lowerCallArgExpecting(ctx, insns, args, 0, k)
        val pArgs: List[NArg] = newList()
        pArgs.add(NArg(ty = NPtr(pointee = NI8), value = recvP))
        pArgs.add(NArg(ty = NI64, value = slotOfVal(ctx, insns, kv)))
        val r = callRuntime(ctx, insns, "lyric_map_contains", NI32, pArgs)
        return Some(value = i32ToBool(ctx, insns, r))
      }
      if name == "remove" and args.count == 1 {
        val kv = lowerCallArgExpecting(ctx, insns, args, 0, k)
        val pArgs: List[NArg] = newList()
        pArgs.add(NArg(ty = NPtr(pointee = NI8), value = recvP))
        pArgs.add(NArg(ty = NI64, value = slotOfVal(ctx, insns, kv)))
        val r = callRuntime(ctx, insns, "lyric_map_remove", NI32, pArgs)
        return Some(value = i32ToBool(ctx, insns, r))
      }
      if name == "count" and args.count == 0 {
        val n = callRuntime(ctx, insns, "lyric_map_len", NI64, arg1(NPtr(pointee = NI8), recvP))
        val dest = freshTmp(ctx)
        insns.add(NTrunc(dest = dest, fromTy = NI64, value = n.value, toTy = NI32))
        return Some(value = NVal(ty = NI32, value = NLocal(name = dest)))
      }
      return None
    }
    case None -> {
    }
  }
  None
}

func lowerCallArgExpecting(ctx: in Ctx, insns: in List[NInsn], args: in List[CallArg], i: in Int, want: in NType): NVal {
  match args[i] {
    case CAPositional(ex) -> lowerExprExpecting(ctx, insns, ex, want)
    case CANamed(_, value, _) -> lowerExprExpecting(ctx, insns, value, want)
  }
}

// Recover a type expression from an index-position expression: the
// parser reads `newList[Long]` as indexing, so the "index" is really a
// type name (possibly a nested generic application, which parses as
// nested indexing).
func exprAsTypeExpr(e: in Expr): TypeExpr {
  match e.kind {
    case EPath(p) -> TypeExpr(kind = TRef(path = p), span = e.span)
    case EIndex(ir, idxs) -> {
      match ir.kind {
        case EPath(hp) -> {
          val targs: List[TypeArg] = newList()
          var i = 0
          while i < idxs.count {
            targs.add(TAType(ty = exprAsTypeExpr(idxs[i])))
            i = i + 1
          }
          TypeExpr(kind = TGenericApp(head = hp, args = targs), span = e.span)
        }
        case _ -> panic("Lyric.LlvmCodegen: this type argument form is not supported for --target native")
      }
    }
    case EParen(inner) -> exprAsTypeExpr(inner)
    case _ -> panic("Lyric.LlvmCodegen: this type argument form is not supported for --target native")
  }
}

func lowerCallArgExpecting0Plain(ctx: in Ctx, insns: in List[NInsn], args: in List[CallArg]): NVal {
  match args[0] {
    case CAPositional(ex) -> lowerExpr(ctx, insns, ex)
    case CANamed(_, value, _) -> lowerExpr(ctx, insns, value)
  }
}

func listCountVal(ctx: in Ctx, insns: in List[NInsn], recvP: in NValue): NVal {
  val n = callRuntime(ctx, insns, "lyric_list_len", NI64, arg1(NPtr(pointee = NI8), recvP))
  val dest = freshTmp(ctx)
  insns.add(NTrunc(dest = dest, fromTy = NI64, value = n.value, toTy = NI32))
  NVal(ty = NI32, value = NLocal(name = dest))
}

func i32ToBool(ctx: in Ctx, insns: in List[NInsn], v: in NVal): NVal {
  val dest = freshTmp(ctx)
  insns.add(NICmp(dest = dest, pred = INe, ty = NI32, a = v.value, b = NLitInt(v = 0i64, ty = NI32)))
  NVal(ty = NI1, value = NLocal(name = dest))
}

/// `mapGet(m, key): Option[V]` — the canonical map accessor from
/// `Std.Collections`, lowered directly against the kernel out-param
/// call (its pure-Lyric body uses an `out`-mode parameter the native
/// backend does not lower).  The read value is a borrow; Some's field
/// store retains it (the same protocol as lowerWeakUpgrade, minus the
/// transferred +1).
func lowerMapGetBuiltin(ctx: in Ctx, insns: in List[NInsn], m: in NVal, args: in List[CallArg]): NVal {
  val kTy = match mapKeyOfType(ctx, m.ty) {
    case Some(t) -> t
    case None -> panic("Lyric.LlvmCodegen: 'mapGet' is reserved for Std.Collections maps on --target native (got " + nTypeToIrString(m.ty) + ")")
  }
  val vTy = match mapValOfType(ctx, m.ty) {
    case Some(t) -> t
    case None -> panic("Lyric.LlvmCodegen: internal — map type without a value type")
  }
  val optKey = match resolveGenericUnionKey(ctx, "Option", "Option") {
    case Some(kk) -> kk
    case None -> panic("Lyric.LlvmCodegen: mapGet needs a generic union named 'Option' (with cases Some/None) in the import closure")
  }
  val argTys: List[NType] = newList()
  argTys.add(vTy)
  val ui = match instantiateGenericUnionOpt(ctx, optKey, argTys) {
    case Some(u) -> u
    case None -> panic("Lyric.LlvmCodegen: cannot instantiate Option for mapGet")
  }
  var someIdx = 0 - 1
  var noneIdx = 0 - 1
  var ci = 0
  while ci < ui.cases.count {
    if ui.cases[ci].name == "Some" {
      someIdx = ci
    }
    if ui.cases[ci].name == "None" {
      noneIdx = ci
    }
    ci = ci + 1
  }
  if someIdx < 0 or noneIdx < 0 {
    panic("Lyric.LlvmCodegen: the 'Option' union in scope lacks Some/None cases")
  }
  val kv = lowerCallArgExpecting(ctx, insns, args, 1, kTy)
  val recvP = collectionAsI8(ctx, insns, m)
  val outSlot = "mapget.out." + freshTmp(ctx)
  ctx.allocas.add(NAlloca(dest = outSlot, ty = NI64))
  val gArgs: List[NArg] = newList()
  gArgs.add(NArg(ty = NPtr(pointee = NI8), value = recvP))
  gArgs.add(NArg(ty = NI64, value = slotOfVal(ctx, insns, kv)))
  gArgs.add(NArg(ty = NPtr(pointee = NI64), value = NLocal(name = outSlot)))
  val found = callRuntime(ctx, insns, "lyric_map_get", NI32, gArgs)
  val hit = freshTmp(ctx)
  insns.add(NICmp(dest = hit, pred = INe, ty = NI32, a = found.value, b = NLitInt(v = 0i64, ty = NI32)))
  val someL = freshLabel(ctx, "mapget.some")
  val noneL = freshLabel(ctx, "mapget.none")
  val mergeL = freshLabel(ctx, "mapget.merge")
  val slot = "mapget.slot." + freshTmp(ctx)
  val optTy = unionPtrType(ui)
  ctx.allocas.add(NAlloca(dest = slot, ty = optTy))
  insns.add(NCondBr(cond = NLocal(name = hit), thenLabel = someL, elseLabel = noneL))
  insns.add(NLabel(name = someL))
  val rawSlot = freshTmp(ctx)
  insns.add(NLoad(dest = rawSlot, ty = NI64, ptr = NLocal(name = outSlot)))
  pushTempScope(ctx)
  val elemV = valOfSlot(ctx, insns, NLocal(name = rawSlot), vTy)
  val someVals: List[NVal] = newList()
  someVals.add(elemV)
  val someV = lowerUnionConstructVals(ctx, insns, ui, someIdx, someVals)
  ensureOwned(ctx, insns, someV)
  popTempScope(ctx, insns)
  insns.add(NStore(ty = optTy, value = someV.value, ptr = NLocal(name = slot)))
  insns.add(NBr(label = mergeL))
  insns.add(NLabel(name = noneL))
  pushTempScope(ctx)
  val noneVals: List[NVal] = newList()
  val noneV = lowerUnionConstructVals(ctx, insns, ui, noneIdx, noneVals)
  ensureOwned(ctx, insns, noneV)
  popTempScope(ctx, insns)
  insns.add(NStore(ty = optTy, value = noneV.value, ptr = NLocal(name = slot)))
  insns.add(NBr(label = mergeL))
  insns.add(NLabel(name = mergeL))
  val dest = freshTmp(ctx)
  insns.add(NLoad(dest = dest, ty = optTy, ptr = NLocal(name = slot)))
  val outV = NVal(ty = optTy, value = NLocal(name = dest))
  registerTemp(ctx, outV)
  outV
}

/// `xs[i]` / `m[k]` (N5.8).  A list read is a borrow (like a record
/// field); a map read panics on a missing key (`mapGet` is the
/// Option-returning accessor).
func lowerCollectionIndex(
  ctx: in Ctx, insns: in List[NInsn], receiver: in Expr, indices: in List[Expr], line: in Int
): NVal {
  if indices.count != 1 {
    panic("Lyric.LlvmCodegen: indexing takes exactly one index for --target native")
  }
  val recv = lowerExpr(ctx, insns, receiver)
  match listElemOfType(ctx, recv.ty) {
    case Some(elem) -> {
      val idx = lowerExprExpecting(ctx, insns, indices[0], NI64)
      val recvP = collectionAsI8(ctx, insns, recv)
      val gArgs: List[NArg] = newList()
      gArgs.add(NArg(ty = NPtr(pointee = NI8), value = recvP))
      gArgs.add(NArg(ty = NI64, value = idx.value))
      val slot = callRuntime(ctx, insns, "lyric_list_get", NI64, gArgs)
      return valOfSlot(ctx, insns, slot.value, elem)
    }
    case None -> {
    }
  }
  match mapKeyOfType(ctx, recv.ty) {
    case Some(kTy) -> {
      val vTy = match mapValOfType(ctx, recv.ty) {
        case Some(t) -> t
        case None -> panic("Lyric.LlvmCodegen: internal — map type without a value type")
      }
      val kv = lowerExprExpecting(ctx, insns, indices[0], kTy)
      val recvP = collectionAsI8(ctx, insns, recv)
      val outSlot = "mapidx.out." + freshTmp(ctx)
      ctx.allocas.add(NAlloca(dest = outSlot, ty = NI64))
      val gArgs: List[NArg] = newList()
      gArgs.add(NArg(ty = NPtr(pointee = NI8), value = recvP))
      gArgs.add(NArg(ty = NI64, value = slotOfVal(ctx, insns, kv)))
      gArgs.add(NArg(ty = NPtr(pointee = NI64), value = NLocal(name = outSlot)))
      val found = callRuntime(ctx, insns, "lyric_map_get", NI32, gArgs)
      val hit = freshTmp(ctx)
      insns.add(NICmp(dest = hit, pred = INe, ty = NI32, a = found.value, b = NLitInt(v = 0i64, ty = NI32)))
      val okL = freshLabel(ctx, "mapidx.ok")
      val missL = freshLabel(ctx, "mapidx.miss")
      insns.add(NCondBr(cond = NLocal(name = hit), thenLabel = okL, elseLabel = missL))
      insns.add(NLabel(name = missL))
      emitPanicRaw(ctx, insns, "map key not found (use mapGet for an Option result)", line)
      insns.add(NBr(label = okL))
      insns.add(NLabel(name = okL))
      val raw = freshTmp(ctx)
      insns.add(NLoad(dest = raw, ty = NI64, ptr = NLocal(name = outSlot)))
      return valOfSlot(ctx, insns, NLocal(name = raw), vTy)
    }
    case None -> {
    }
  }
  panic(
    "Lyric.LlvmCodegen: indexing on this receiver is not yet supported for --target native (lists and maps index; slices land with N5)"
  )
}

/// `for x in xs` over List[T] (N5.8): an index loop over the kernel
/// length/get calls.  The loop variable rebinds per iteration in its
/// own var scope (the element read is a borrow; bindLocal retains it
/// and the iteration scope releases it), so `break` / `continue`
/// unwind correctly through the loop-depth snapshots.
///
/// KNOWN DIVERGENCE (#4790): the length is read once before the loop,
/// so mutating the list inside the body silently iterates the stale
/// bound (a removed tail element panics the OOB check in
/// lyric_list_get; an appended one is skipped), where the managed
/// targets throw InvalidOperationException on any mutation during
/// iteration.  The parity design (a modification counter in LyricList
/// + a per-iteration check) is tracked in #4790.
func lowerForOverList(ctx: in Ctx, insns: in List[NInsn], pat: in Pattern, iter: in Expr, body: in Block): Unit {
  val it = lowerExpr(ctx, insns, iter)
  val elem = match listElemOfType(ctx, it.ty) {
    case Some(t) -> t
    case None -> panic("Lyric.LlvmCodegen: 'for' on --target native iterates List[T] (slices land with the N5 stdlib port); got " + nTypeToIrString(it.ty))
  }
  var bindName = ""
  var haveBind = false
  match pat.kind {
    case PBinding(nm, inner) -> {
      match inner {
        case Some(_) -> panic("Lyric.LlvmCodegen: this for-pattern is not yet supported for --target native (use a plain name)")
        case None -> {
          bindName = nm
          haveBind = true
        }
      }
    }
    case PWildcard -> {
    }
    case _ -> panic("Lyric.LlvmCodegen: this for-pattern is not yet supported for --target native (use a plain name)")
  }
  // Keep the iterated list alive across the loop even when it is an
  // owned temp (e.g. `for k in dictGetKeys(m)`): the hidden binding
  // takes ownership and the enclosing scope releases it.
  val itName = "__for.it." + freshTmp(ctx)
  bindLocal(ctx, insns, itName, it)
  val itVal = loadLocal(ctx, insns, itName)
  val recvP = collectionAsI8(ctx, insns, itVal)
  // Length is snapshot once here, at loop entry — unlike the managed
  // targets (.NET/JVM), where a `List` enumerator throws on concurrent
  // modification, native has no iterator-invalidation check. Adding or
  // removing elements from the iterated list during the loop body does
  // not change this bound: added elements past the snapshot length are
  // never visited, and removal can shift indices so an element is
  // skipped or the same index revisited (#4790). Don't mutate the
  // iterated list from within the loop body.
  val lenV = callRuntime(ctx, insns, "lyric_list_len", NI64, arg1(NPtr(pointee = NI8), recvP))
  val idxSlot = "for.idx." + freshTmp(ctx)
  ctx.allocas.add(NAlloca(dest = idxSlot, ty = NI64))
  insns.add(NStore(ty = NI64, value = NLitInt(v = 0i64, ty = NI64), ptr = NLocal(name = idxSlot)))
  val condL = freshLabel(ctx, "for.cond")
  val bodyL = freshLabel(ctx, "for.body")
  val incL = freshLabel(ctx, "for.inc")
  val exitL = freshLabel(ctx, "for.exit")
  insns.add(NBr(label = condL))
  insns.add(NLabel(name = condL))
  val curIdx = freshTmp(ctx)
  insns.add(NLoad(dest = curIdx, ty = NI64, ptr = NLocal(name = idxSlot)))
  val cmp = freshTmp(ctx)
  insns.add(NICmp(dest = cmp, pred = ISlt, ty = NI64, a = NLocal(name = curIdx), b = lenV.value))
  insns.add(NCondBr(cond = NLocal(name = cmp), thenLabel = bodyL, elseLabel = exitL))
  insns.add(NLabel(name = bodyL))
  ctx.loopBreak.add(exitL)
  ctx.loopCont.add(incL)
  ctx.loopVarDepth.add(ctx.scopeRefs.count)
  ctx.loopTempDepth.add(ctx.tempScopes.count)
  pushVarScope(ctx)
  val bodyIdx = freshTmp(ctx)
  insns.add(NLoad(dest = bodyIdx, ty = NI64, ptr = NLocal(name = idxSlot)))
  val gArgs: List[NArg] = newList()
  gArgs.add(NArg(ty = NPtr(pointee = NI8), value = recvP))
  gArgs.add(NArg(ty = NI64, value = NLocal(name = bodyIdx)))
  val slot = callRuntime(ctx, insns, "lyric_list_get", NI64, gArgs)
  if haveBind {
    val elemV = valOfSlot(ctx, insns, slot.value, elem)
    bindLocal(ctx, insns, bindName, elemV)
  }
  lowerBlockStmts(ctx, insns, body)
  popVarScope(ctx, insns)
  ctx.loopBreak.removeAt(ctx.loopBreak.count - 1)
  ctx.loopCont.removeAt(ctx.loopCont.count - 1)
  ctx.loopVarDepth.removeAt(ctx.loopVarDepth.count - 1)
  ctx.loopTempDepth.removeAt(ctx.loopTempDepth.count - 1)
  insns.add(NBr(label = incL))
  insns.add(NLabel(name = incL))
  val incIdx = freshTmp(ctx)
  insns.add(NLoad(dest = incIdx, ty = NI64, ptr = NLocal(name = idxSlot)))
  val nextIdx = freshTmp(ctx)
  insns.add(NAdd(dest = nextIdx, ty = NI64, a = NLocal(name = incIdx), b = NLitInt(v = 1i64, ty = NI64)))
  insns.add(NStore(ty = NI64, value = NLocal(name = nextIdx), ptr = NLocal(name = idxSlot)))
  insns.add(NBr(label = condL))
  insns.add(NLabel(name = exitL))
}

/// `dictGetKeys(m)` / `dictGetValues(m)` — fresh rc=1 snapshot lists
/// (the kernel retains ref-typed entries into the list).
func lowerMapSnapshotBuiltin(ctx: in Ctx, insns: in List[NInsn], m: in NVal, sym: in String, elem: in NType): NVal {
  val recvP = collectionAsI8(ctx, insns, m)
  val raw = callRuntime(ctx, insns, sym, NPtr(pointee = NI8), arg1(NPtr(pointee = NI8), recvP))
  val ty = listNType(ctx, elem)
  val dest = freshTmp(ctx)
  insns.add(NBitcast(dest = dest, fromTy = NPtr(pointee = NI8), value = raw.value, toTy = ty))
  val outV = NVal(ty = ty, value = NLocal(name = dest))
  registerTemp(ctx, outV)
  outV
}

func weakNType(ctx: in Ctx, target: in NType): NType {
  val nm = "__weak<" + mangleNTypeArg(target) + ">"
  if not ctx.weakTargets.containsKey(nm) {
    ctx.weakTargets.add(nm, target)
    val noFields: List[NType] = newList()
    ctx.moduleTypeDefs.add(NTypeDefn(name = nm, fields = noFields))
  }
  val noFields2: List[NType] = newList()
  NPtr(pointee = NStruct(name = nm, fields = noFields2))
}

func weakTargetOfType(ctx: in Ctx, t: in NType): Option[NType] {
  match t {
    case NPtr(pointee) -> {
      match pointee {
        case NStruct(name, _) -> mapGet(ctx.weakTargets, name)
        case _ -> None
      }
    }
    case _ -> None
  }
}

/// Tuples are synthesised records `__tuple<elems>` with fields
/// `_0.._n` (N3.3): construction, field access, destructors, and ARC
/// reuse the record machinery wholesale.
func tupleRecInfo(ctx: in Ctx, elemTys: in List[NType]): NRecInfo {
  var nm = "__tuple<"
  var i = 0
  while i < elemTys.count {
    if i > 0 {
      nm = nm + ","
    }
    nm = nm + mangleNTypeArg(elemTys[i])
    i = i + 1
  }
  nm = nm + ">"
  match mapGet(ctx.recordDefs, nm) {
    case Some(existing) -> return existing
    case None -> {
    }
  }
  val names: List[String] = newList()
  val dflts: List[Option[Expr]] = newList()
  var fi = 0
  while fi < elemTys.count {
    names.add("_" + fi.toString())
    val noD: Option[Expr] = None
    dflts.add(noD)
    fi = fi + 1
  }
  val ri = NRecInfo(irName = nm, fieldNames = names, fieldTys = elemTys, fieldDefaults = dflts)
  ctx.recordDefs.add(nm, ri)
  val defnFields: List[NType] = newList()
  defnFields.add(NI32)
  defnFields.add(NPtr(pointee = NI8))
  val layoutTys = layoutFieldTys(elemTys)
  var di = 0
  while di < layoutTys.count {
    defnFields.add(layoutTys[di])
    di = di + 1
  }
  ctx.moduleTypeDefs.add(NTypeDefn(name = nm, fields = defnFields))
  if recHasRefFields(ri) {
    ctx.moduleFns.add(synthRecordDtor(ctx, ri))
  }
  ri
}

func envIndexOf(envNames: in List[String], name: in String): Int {
  var i = 0
  while i < envNames.count {
    if envNames[i] == name {
      return i
    }
    i = i + 1
  }
  0 - 1
}

/// `typeToNOpt` with a type-parameter environment: `T` resolves through
/// the env; generic applications instantiate recursively.
func typeToNEnvOpt(ctx: in Ctx, te: in TypeExpr, envNames: in List[String], envTys: in List[NType]): Option[NType] {
  match te.kind {
    case TRef(path) -> {
      if path.segments.count == 1 {
        val idx = envIndexOf(envNames, path.segments[0])
        if idx >= 0 {
          return Some(value = envTys[idx])
        }
      }
      typeToNOpt(ctx, te)
    }
    case TGenericApp(head, args) -> {
      val joined = modulePathJoin(head.segments)
      val bare = lastSeg(head)
      if bare == "NativePtr" and args.count == 1 {
        match args[0] {
          case TAType(inner) -> {
            match typeToNEnvOpt(ctx, inner, envNames, envTys) {
              case Some(t) -> return Some(value = NPtr(pointee = t))
              case None -> return None
            }
          }
          case TAValue(_) -> return None
        }
      }
      if bare == "NativeWeak" and args.count == 1 {
        match args[0] {
          case TAType(inner) -> {
            match typeToNEnvOpt(ctx, inner, envNames, envTys) {
              case Some(t) -> return Some(value = weakNType(ctx, t))
              case None -> return None
            }
          }
          case TAValue(_) -> return None
        }
      }
      val argTys: List[NType] = newList()
      var ai = 0
      while ai < args.count {
        match args[ai] {
          case TAType(inner) -> {
            match typeToNEnvOpt(ctx, inner, envNames, envTys) {
              case Some(t) -> argTys.add(t)
              case None -> return None
            }
          }
          case TAValue(_) -> return None
        }
        ai = ai + 1
      }
      match resolveGenericUnionKey(ctx, joined, bare) {
        case Some(gkey) -> {
          match instantiateGenericUnionOpt(ctx, gkey, argTys) {
            case Some(ui) -> return Some(value = unionPtrType(ui))
            case None -> return None
          }
        }
        case None -> {
        }
      }
      match resolveGenericRecordKey(ctx, joined, bare) {
        case Some(gkey) -> {
          match instantiateGenericRecordOpt(ctx, gkey, argTys) {
            case Some(ri) -> return Some(value = recPtrType(ri))
            case None -> return None
          }
        }
        case None -> {
        }
      }
      // The reserved stdlib collections (N5.8) — user-declared generic
      // records/unions of the same name win above.
      if bare == "List" and argTys.count == 1 {
        return Some(value = listNType(ctx, argTys[0]))
      }
      if bare == "Map" and argTys.count == 2 {
        return Some(value = mapNType(ctx, argTys[0], argTys[1]))
      }
      // NativePtr[T] with a registry-resolved pointee (kernel out-params
      // like NativePtr[slice[Byte]]; the plain-scalar cases also resolve
      // here identically to typeExprToNType's arm).
      if bare == "NativePtr" and argTys.count == 1 {
        return Some(value = NPtr(pointee = argTys[0]))
      }
      None
    }
    case TFunction(parameters, retTy) -> {
      val ptys: List[NType] = newList()
      var pi = 0
      while pi < parameters.count {
        match typeToNEnvOpt(ctx, parameters[pi], envNames, envTys) {
          case Some(t) -> ptys.add(t)
          case None -> return None
        }
        pi = pi + 1
      }
      match typeToNEnvOpt(ctx, retTy, envNames, envTys) {
        case Some(rt) -> Some(value = closureNType(ctx, ptys, rt))
        case None -> None
      }
    }
    case TTuple(types) -> {
      val etys: List[NType] = newList()
      var tti = 0
      while tti < types.count {
        match typeToNEnvOpt(ctx, types[tti], envNames, envTys) {
          case Some(t) -> etys.add(t)
          case None -> return None
        }
        tti = tti + 1
      }
      Some(value = recPtrType(tupleRecInfo(ctx, etys)))
    }
    case TSlice(element) -> {
      // `slice[T]` shares the RC'd LyricList kernel representation,
      // immutable by construction (D-N-015 — the plan's borrowed
      // {ptr,len} fat pointer cannot safely back a returned slice
      // without lifetime checking; the RC'd repr is memory-safe under
      // the existing ARC rules with no new runtime code).  The type
      // checker owns the mutability distinction; here `for`, indexing,
      // and `.length` reuse the list paths wholesale.
      match typeToNEnvOpt(ctx, element, envNames, envTys) {
        case Some(el) -> Some(value = listNType(ctx, el))
        case None -> None
      }
    }
    case TParen(inner) -> typeToNEnvOpt(ctx, inner, envNames, envTys)
    case _ -> typeToNOpt(ctx, te)
  }
}

func resolveGenericUnionKey(ctx: in Ctx, joined: in String, bare: in String): Option[String] {
  if ctx.genericUnionDefs.containsKey(joined) {
    return Some(value = genericQualifiedKey(ctx, joined))
  }
  if ctx.genericUnionDefs.containsKey(bare) {
    return Some(value = genericQualifiedKey(ctx, bare))
  }
  None
}

func resolveGenericRecordKey(ctx: in Ctx, joined: in String, bare: in String): Option[String] {
  if ctx.genericRecordDefs.containsKey(joined) {
    return Some(value = genericQualifiedKey(ctx, joined))
  }
  if ctx.genericRecordDefs.containsKey(bare) {
    return Some(value = genericQualifiedKey(ctx, bare))
  }
  None
}

/// Normalise a generic registry key to its declaring-package qualified
/// form so every instantiation of the same declaration shares a cache
/// entry regardless of how the source spelled the reference.
func genericQualifiedKey(ctx: in Ctx, key: in String): String {
  val pkg = match mapGet(ctx.genericDeclPkg, key) { case Some(p) -> p; case None -> return key }
  if Str.startsWith(key, pkg + ".") {
    return key
  }
  pkg + "." + key
}

/// Registry accessors that never bind a pattern under an Option-typed
/// return context (the stage-0 seed mis-types such bindings, #4631
/// family — see lookupHeapType's note).
func mustGetGenericUnion(ctx: in Ctx, key: in String): UnionDecl {
  match mapGet(ctx.genericUnionDefs, key) {
    case Some(d) -> d
    case None -> panic("Lyric.LlvmCodegen: internal — generic union '" + key + "' not registered")
  }
}

func mustGetGenericRecord(ctx: in Ctx, key: in String): RecordDecl {
  match mapGet(ctx.genericRecordDefs, key) {
    case Some(d) -> d
    case None -> panic("Lyric.LlvmCodegen: internal — generic record '" + key + "' not registered")
  }
}

func instantiateGenericUnionOpt(ctx: in Ctx, gkey: in String, argTys: in List[NType]): Option[NUnionInfo] {
  if not ctx.genericUnionDefs.containsKey(gkey) {
    return None
  }
  val ud = mustGetGenericUnion(ctx, gkey)
  val instName = instIrName(gkey, argTys)
  match mapGet(ctx.unionDefs, instName) {
    case Some(existing) -> return Some(value = existing)
    case None -> {
    }
  }
  val envNames = genericParamNamesOf(ud.generics)
  if envNames.count != argTys.count {
    return None
  }
  val cases: List[NUnionCaseInfo] = newList()
  var maxBytes = 0
  var ci = 0
  while ci < ud.cases.count {
    val cd = ud.cases[ci]
    val names: List[String] = newList()
    val tys: List[NType] = newList()
    var fi = 0
    while fi < cd.fields.count {
      names.add(unionFieldName(cd.fields[fi], fi))
      match typeToNEnvOpt(ctx, unionFieldTy(cd.fields[fi]), envNames, argTys) {
        case Some(t) -> tys.add(t)
        case None -> return None
      }
      fi = fi + 1
    }
    val sz = structSize(tys)
    if sz > maxBytes {
      maxBytes = sz
    }
    cases.add(NUnionCaseInfo(name = cd.name, fieldNames = names, fieldTys = tys))
    ci = ci + 1
  }
  val words = (maxBytes + 7) / 8
  val ui = NUnionInfo(irName = instName, cases = cases, payloadWords = words)
  ctx.unionDefs.add(instName, ui)
  ctx.instMeta.add(instName, NInstInfo(gkey = gkey, argTys = argTys))
  ctx.moduleTypeDefs.add(NTypeDefn(name = instName, fields = unionBodyFields(words)))
  var ci2 = 0
  while ci2 < cases.count {
    if cases[ci2].fieldTys.count > 0 {
      ctx.moduleTypeDefs.add(
        NTypeDefn(name = casePayloadStructName(ui, cases[ci2].name), fields = layoutFieldTys(cases[ci2].fieldTys))
      )
    }
    ci2 = ci2 + 1
  }
  if unionHasRefFields(ui) {
    ctx.moduleFns.add(synthUnionDtor(ctx, ui))
  }
  Some(value = ui)
}

func instantiateGenericRecordOpt(ctx: in Ctx, gkey: in String, argTys: in List[NType]): Option[NRecInfo] {
  if not ctx.genericRecordDefs.containsKey(gkey) {
    return None
  }
  val rd = mustGetGenericRecord(ctx, gkey)
  val instName = instIrName(gkey, argTys)
  match mapGet(ctx.recordDefs, instName) {
    case Some(existing) -> return Some(value = existing)
    case None -> {
    }
  }
  val envNames = genericParamNamesOf(rd.generics)
  if envNames.count != argTys.count {
    return None
  }
  val fields = recFieldsOf(rd)
  val names: List[String] = newList()
  val tys: List[NType] = newList()
  val dflts: List[Option[Expr]] = newList()
  var i = 0
  while i < fields.count {
    names.add(fields[i].name)
    match typeToNEnvOpt(ctx, fields[i].ty, envNames, argTys) {
      case Some(t) -> tys.add(t)
      case None -> return None
    }
    dflts.add(fields[i].dflt)
    i = i + 1
  }
  val ri = NRecInfo(irName = instName, fieldNames = names, fieldTys = tys, fieldDefaults = dflts)
  ctx.recordDefs.add(instName, ri)
  ctx.instMeta.add(instName, NInstInfo(gkey = gkey, argTys = argTys))
  val defnFields: List[NType] = newList()
  defnFields.add(NI32)
  defnFields.add(NPtr(pointee = NI8))
  val layoutTys = layoutFieldTys(tys)
  var fi = 0
  while fi < layoutTys.count {
    defnFields.add(layoutTys[fi])
    fi = fi + 1
  }
  ctx.moduleTypeDefs.add(NTypeDefn(name = instName, fields = defnFields))
  if recHasRefFields(ri) {
    ctx.moduleFns.add(synthRecordDtor(ctx, ri))
  }
  Some(value = ri)
}

/// Lower a generic union-case constructor call (`Some(5)`): infer the
/// type arguments from the case's argument types, instantiate, and
/// construct.  Params not mentioned by this case's directly-typed
/// fields cannot be inferred here — the expected-type path
/// (`lowerExprExpecting`) covers annotated bindings, returns, and
/// arguments; anything else needs an annotation.
func lowerGenericCaseConstruct(
  ctx: in Ctx,
  insns: in List[NInsn],
  gkey: in String,
  caseName: in String,
  args: in List[CallArg],
): NVal {
  val ud = mustGetGenericUnion(ctx, gkey)
  var caseIdx = 0 - 1
  var ci = 0
  while ci < ud.cases.count {
    if ud.cases[ci].name == caseName {
      caseIdx = ci
    }
    ci = ci + 1
  }
  if caseIdx < 0 {
    panic("Lyric.LlvmCodegen: internal — union '" + gkey + "' has no case '" + caseName + "'")
  }
  val cd = ud.cases[caseIdx]
  // Map args to case fields (named by name, positional in order),
  // recorded as parallel (fieldIdx, expr) lists.
  val argFieldIdx: List[Int] = newList()
  val argFieldExpr: List[Expr] = newList()
  var positionalIdx = 0
  var ai = 0
  while ai < args.count {
    match args[ai] {
      case CANamed(name, value, _) -> {
        var target = 0 - 1
        var fj = 0
        while fj < cd.fields.count {
          if unionFieldName(cd.fields[fj], fj) == name {
            target = fj
          }
          fj = fj + 1
        }
        if target < 0 {
          panic("Lyric.LlvmCodegen: union case '" + caseName + "' has no field '" + name + "'")
        }
        argFieldIdx.add(target)
        argFieldExpr.add(value)
      }
      case CAPositional(ex) -> {
        if positionalIdx >= cd.fields.count {
          panic("Lyric.LlvmCodegen: too many arguments constructing union case '" + caseName + "'")
        }
        argFieldIdx.add(positionalIdx)
        argFieldExpr.add(ex)
        positionalIdx = positionalIdx + 1
      }
    }
    ai = ai + 1
  }
  // Lower per field (declaration order) and infer the type env from
  // fields whose declared type is a bare parameter reference.
  val rawVals: List[NVal] = newList()
  var fi2 = 0
  while fi2 < cd.fields.count {
    var found2 = 0 - 1
    var aj = 0
    while aj < argFieldIdx.count {
      if argFieldIdx[aj] == fi2 {
        found2 = aj
      }
      aj = aj + 1
    }
    if found2 < 0 {
      panic(
        "Lyric.LlvmCodegen: missing field '" + unionFieldName(cd.fields[fi2], fi2) + "' constructing union case '" +
          caseName +
          "'"
      )
    }
    rawVals.add(lowerExpr(ctx, insns, argFieldExpr[found2]))
    fi2 = fi2 + 1
  }
  val envNames = genericParamNamesOf(ud.generics)
  val envTys: List[NType] = newList()
  var pi = 0
  while pi < envNames.count {
    var found = false
    var fj = 0
    while fj < cd.fields.count {
      if not found {
        match unionFieldTy(cd.fields[fj]).kind {
          case TRef(path) -> {
            if path.segments.count == 1 and path.segments[0] == envNames[pi] {
              envTys.add(rawVals[fj].ty)
              found = true
            }
          }
          case _ -> {
          }
        }
      }
      fj = fj + 1
    }
    if not found {
      panic(
        "Lyric.LlvmCodegen: cannot infer type argument '" + envNames[pi] + "' for union case '" + caseName +
          "' from its arguments; annotate the binding or pass the value through a typed position"
      )
    }
    pi = pi + 1
  }
  val ui = match instantiateGenericUnionOpt(ctx, genericQualifiedKey(ctx, gkey), envTys) {
    case Some(u) -> u
    case None -> panic("Lyric.LlvmCodegen: cannot instantiate generic union '" + gkey + "' for --target native (a field type is not yet lowerable)")
  }
  lowerUnionConstructVals(ctx, insns, ui, caseIdx, rawVals)
}

/// Lower a generic record constructor call (`Box(item = x, tag = 2)`):
/// infer the type args from directly-param-typed fields, instantiate,
/// construct.
func lowerGenericRecordConstruct(ctx: in Ctx, insns: in List[NInsn], gkey: in String, args: in List[CallArg]): NVal {
  val rd = mustGetGenericRecord(ctx, gkey)
  val fields = recFieldsOf(rd)
  val argFieldIdx: List[Int] = newList()
  val argFieldExpr: List[Expr] = newList()
  var positionalIdx = 0
  var ai = 0
  while ai < args.count {
    match args[ai] {
      case CANamed(name, value, _) -> {
        var target = 0 - 1
        var fj = 0
        while fj < fields.count {
          if fields[fj].name == name {
            target = fj
          }
          fj = fj + 1
        }
        if target < 0 {
          panic("Lyric.LlvmCodegen: record '" + rd.name + "' has no field '" + name + "'")
        }
        argFieldIdx.add(target)
        argFieldExpr.add(value)
      }
      case CAPositional(ex) -> {
        if positionalIdx >= fields.count {
          panic("Lyric.LlvmCodegen: too many arguments constructing record '" + rd.name + "'")
        }
        argFieldIdx.add(positionalIdx)
        argFieldExpr.add(ex)
        positionalIdx = positionalIdx + 1
      }
    }
    ai = ai + 1
  }
  val rawVals: List[NVal] = newList()
  var fi2 = 0
  while fi2 < fields.count {
    var found2 = 0 - 1
    var aj = 0
    while aj < argFieldIdx.count {
      if argFieldIdx[aj] == fi2 {
        found2 = aj
      }
      aj = aj + 1
    }
    if found2 >= 0 {
      rawVals.add(lowerExpr(ctx, insns, argFieldExpr[found2]))
    } else {
      match fields[fi2].dflt {
        case Some(d) -> rawVals.add(lowerExpr(ctx, insns, d))
        case None -> panic("Lyric.LlvmCodegen: missing field '" + fields[fi2].name + "' constructing record '" + rd.name + "'")
      }
    }
    fi2 = fi2 + 1
  }
  val envNames = genericParamNamesOf(rd.generics)
  val envTys: List[NType] = newList()
  var pi = 0
  while pi < envNames.count {
    var found = false
    var fj = 0
    while fj < fields.count {
      if not found {
        match fields[fj].ty.kind {
          case TRef(path) -> {
            if path.segments.count == 1 and path.segments[0] == envNames[pi] {
              envTys.add(rawVals[fj].ty)
              found = true
            }
          }
          case _ -> {
          }
        }
      }
      fj = fj + 1
    }
    if not found {
      panic(
        "Lyric.LlvmCodegen: cannot infer type argument '" + envNames[pi] + "' for record '" + rd.name +
          "' from its constructor arguments; annotate the binding or pass the value through a typed position"
      )
    }
    pi = pi + 1
  }
  val ri = match instantiateGenericRecordOpt(ctx, genericQualifiedKey(ctx, gkey), envTys) {
    case Some(r) -> r
    case None -> panic("Lyric.LlvmCodegen: cannot instantiate generic record '" + gkey + "' for --target native (a field type is not yet lowerable)")
  }
  lowerRecordConstructVals(ctx, insns, ri, rawVals)
}

func isGenericFn(fn: in FunctionDecl): Bool {
  match fn.generics {
    case Some(_) -> true
    case None -> false
  }
}

func mustGetGenericFn(ctx: in Ctx, key: in String): FunctionDecl {
  match mapGet(ctx.genericFnDefs, key) {
    case Some(d) -> d
    case None -> panic("Lyric.LlvmCodegen: internal — generic function '" + key + "' not registered")
  }
}

/// Structural unification of a declared (possibly parameterised) type
/// against a concrete argument NType, extending bound(Names|Tys).
func unifyTyArg(
  ctx: in Ctx,
  declTe: in TypeExpr,
  argTy: in NType,
  paramNames: in List[String],
  boundNames: in List[String],
  boundTys: in List[NType],
): Unit {
  match declTe.kind {
    case TRef(path) -> {
      if path.segments.count == 1 {
        val nm = path.segments[0]
        if envIndexOf(paramNames, nm) >= 0 and envIndexOf(boundNames, nm) < 0 {
          boundNames.add(nm)
          boundTys.add(argTy)
        }
      }
    }
    case TGenericApp(head, targs) -> {
      match argTy {
        case NPtr(pointee) -> {
          match pointee {
            case NStruct(instName, _) -> {
              match mapGet(ctx.instMeta, instName) {
                case Some(meta) -> {
                  if targs.count == meta.argTys.count {
                    var i = 0
                    while i < targs.count {
                      match targs[i] {
                        case TAType(inner) -> unifyTyArg(ctx, inner, meta.argTys[i], paramNames, boundNames, boundTys)
                        case TAValue(_) -> {
                        }
                      }
                      i = i + 1
                    }
                  }
                }
                case None -> {
                }
              }
            }
            case _ -> {
            }
          }
        }
        case _ -> {
        }
      }
    }
    case TParen(inner) -> unifyTyArg(ctx, inner, argTy, paramNames, boundNames, boundTys)
    case _ -> {
    }
  }
}

/// Call a generic function: map arguments to parameters, infer the
/// type-argument tuple from the argument types, instantiate the
/// function (lowered once per tuple, cached), and emit the call.
/// `preVals` are already-lowered leading arguments (the UFCS receiver).
func lowerGenericFnCall(
  ctx: in Ctx,
  insns: in List[NInsn],
  gkey: in String,
  preVals: in List[NVal],
  args: in List[CallArg],
  line: in Int,
): NVal {
  val fd = mustGetGenericFn(ctx, gkey)
  val pkg = match mapGet(ctx.genericFnPkg, gkey) { case Some(pk) -> pk; case None -> ctx.curPkg[0] }
  val nParams = fd.params.count
  // Map args to parameter slots.
  val argSlot: List[Int] = newList()
  val argExpr: List[Expr] = newList()
  var nextPositional = preVals.count
  var ai = 0
  while ai < args.count {
    match args[ai] {
      case CANamed(name, value, _) -> {
        var slot = 0 - 1
        var pj = preVals.count
        while pj < nParams {
          if fd.params[pj].name == name {
            slot = pj
          }
          pj = pj + 1
        }
        if slot < 0 {
          panic(
            "Lyric.LlvmCodegen: named argument '" + name + "' does not match a parameter of generic function '" + fd.name + "'"
          )
        }
        argSlot.add(slot)
        argExpr.add(value)
      }
      case CAPositional(ex) -> {
        if nextPositional >= nParams {
          panic("Lyric.LlvmCodegen: too many arguments calling generic function '" + fd.name + "'")
        }
        argSlot.add(nextPositional)
        argExpr.add(ex)
        nextPositional = nextPositional + 1
      }
    }
    ai = ai + 1
  }
  // Lower per parameter order.
  val rawVals: List[NVal] = newList()
  var pi = 0
  while pi < nParams {
    if pi < preVals.count {
      rawVals.add(preVals[pi])
    } else {
      var found = 0 - 1
      var aj = 0
      while aj < argSlot.count {
        if argSlot[aj] == pi {
          found = aj
        }
        aj = aj + 1
      }
      if found < 0 {
        panic(
          "Lyric.LlvmCodegen: no argument bound for parameter '" + fd.params[pi].name + "' of generic function '" + fd.name +
            "'"
        )
      }
      rawVals.add(lowerExpr(ctx, insns, argExpr[found]))
    }
    pi = pi + 1
  }
  // Infer type args.
  val paramNames = genericParamNamesOf(fd.generics)
  val boundNames: List[String] = newList()
  val boundTys: List[NType] = newList()
  var pi2 = 0
  while pi2 < nParams {
    unifyTyArg(ctx, fd.params[pi2].ty, rawVals[pi2].ty, paramNames, boundNames, boundTys)
    pi2 = pi2 + 1
  }
  val envTys: List[NType] = newList()
  var ti = 0
  while ti < paramNames.count {
    val bi = envIndexOf(boundNames, paramNames[ti])
    if bi < 0 {
      panic(
        "Lyric.LlvmCodegen: cannot infer type argument '" + paramNames[ti] + "' for generic function '" + fd.name +
          "' from its arguments"
      )
    }
    envTys.add(boundTys[bi])
    ti = ti + 1
  }
  // Instantiate (cache-first: recursive generic calls hit the cache).
  val instIr = instIrName(pkg + "." + fd.name + "." + nParams.toString(), envTys)
  var haveInst = ctx.fnInstCache.containsKey(instIr)
  if not haveInst {
    val paramTys: List[NType] = newList()
    var pt = 0
    while pt < nParams {
      match typeToNEnvOpt(ctx, fd.params[pt].ty, paramNames, envTys) {
        case Some(t) -> paramTys.add(t)
        case None -> panic("Lyric.LlvmCodegen: cannot lower parameter type of generic function '" + fd.name + "' for --target native")
      }
      pt = pt + 1
    }
    var instRet = NVoid
    match fd.ret {
      case Some(rte) -> {
        match typeToNEnvOpt(ctx, rte, paramNames, envTys) {
          case Some(t) -> {
            instRet = t
          }
          case None -> panic("Lyric.LlvmCodegen: cannot lower return type of generic function '" + fd.name + "' for --target native")
        }
      }
      case None -> {
      }
    }
    ctx.fnInstCache.add(instIr, NFnInst(irName = instIr, paramTys = paramTys, retTy = instRet))
    ctx.moduleFns.add(lowerFunctionEnv(ctx, pkg, fd, instIr, paramNames, envTys))
  }
  val inst = match mapGet(ctx.fnInstCache, instIr) {
    case Some(fi) -> fi
    case None -> panic("Lyric.LlvmCodegen: internal — missing fn instantiation '" + instIr + "'")
  }
  val callArgs: List[NArg] = newList()
  var ci = 0
  while ci < rawVals.count {
    val cv = coerceTo(ctx, insns, rawVals[ci], inst.paramTys[ci])
    callArgs.add(NArg(ty = inst.paramTys[ci], value = cv.value))
    ci = ci + 1
  }
  match inst.retTy {
    case NVoid -> {
      insns.add(NCallVoid(fn = NGlobal(name = inst.irName), args = callArgs))
      NVal(ty = NVoid, value = NUndef(ty = NVoid))
    }
    case rt -> {
      val dest = freshTmp(ctx)
      insns.add(NCall(dest = dest, retTy = rt, fn = NGlobal(name = inst.irName), args = callArgs))
      val outV = NVal(ty = rt, value = NLocal(name = dest))
      registerTemp(ctx, outV)
      outV
    }
  }
}

// ── Closures (N2.6) ──────────────────────────────────────────────────────────
func namesContains(xs: in List[String], name: in String): Bool {
  var i = 0
  while i < xs.count {
    if xs[i] == name {
      return true
    }
    i = i + 1
  }
  false
}

func truncateNames(xs: in List[String], n: in Int): Unit {
  while xs.count > n {
    xs.removeAt(xs.count - 1)
  }
}

/// Free-variable analysis over a lambda body: `free` accumulates outer
/// locals referenced (captures); `assigned` accumulates assignment
/// targets (mutating a capture is rejected — captures are by-value).
func fvExpr(ctx: in Ctx, e: in Expr, bound: in List[String], free: in List[String], assigned: in List[String]): Unit {
  match e.kind {
    case EPath(path) -> {
      if path.segments.count == 1 {
        val n = path.segments[0]
        if ctx.varTypes.containsKey(n) and not namesContains(bound, n) and not namesContains(free, n) {
          free.add(n)
        }
      }
    }
    case EInterpolated(segments) -> {
      var i = 0
      while i < segments.count {
        match segments[i] {
          case ISExpr(ex) -> fvExpr(ctx, ex, bound, free, assigned)
          case ISText(_, _) -> {
          }
        }
        i = i + 1
      }
    }
    case EParen(inner) -> fvExpr(ctx, inner, bound, free, assigned)
    case ETuple(exprs) -> fvExprList(ctx, exprs, bound, free, assigned)
    case EList(exprs) -> fvExprList(ctx, exprs, bound, free, assigned)
    case EIf(cond, thenBranch, elseBranch, _) -> {
      fvExpr(ctx, cond, bound, free, assigned)
      fvEob(ctx, thenBranch, bound, free, assigned)
      match elseBranch {
        case Some(eb) -> fvEob(ctx, eb, bound, free, assigned)
        case None -> {
        }
      }
    }
    case EMatch(scrutinee, arms) -> {
      fvExpr(ctx, scrutinee, bound, free, assigned)
      var i = 0
      while i < arms.count {
        val mark = bound.count
        fvPattern(arms[i].pattern, bound)
        match arms[i].guard {
          case Some(g) -> fvExpr(ctx, g, bound, free, assigned)
          case None -> {
          }
        }
        fvEob(ctx, arms[i].body, bound, free, assigned)
        truncateNames(bound, mark)
        i = i + 1
      }
    }
    case ELambda(lambdaParams, body) -> {
      val mark = bound.count
      var i = 0
      while i < lambdaParams.count {
        bound.add(lambdaParams[i].name)
        i = i + 1
      }
      fvBlock(ctx, body, bound, free, assigned)
      truncateNames(bound, mark)
    }
    case ECall(fn, args) -> {
      // A static callee path is not a value reference; member callees
      // walk their receiver.
      match fn.kind {
        case EPath(_) -> {
        }
        case EMember(recv, _) -> {
          if not isPackagePathExpr(ctx, recv) {
            fvExpr(ctx, recv, bound, free, assigned)
          }
        }
        case _ -> fvExpr(ctx, fn, bound, free, assigned)
      }
      match fn.kind {
        case EPath(path) -> {
          // A single-segment callee naming a local is an indirect call.
          if path.segments.count == 1 and ctx.varTypes.containsKey(path.segments[0]) {
            fvExpr(ctx, fn, bound, free, assigned)
          }
        }
        case _ -> {
        }
      }
      var i = 0
      while i < args.count {
        match args[i] {
          case CANamed(_, value, _) -> fvExpr(ctx, value, bound, free, assigned)
          case CAPositional(ex) -> fvExpr(ctx, ex, bound, free, assigned)
        }
        i = i + 1
      }
    }
    case ETypeApp(fn, _) -> fvExpr(ctx, fn, bound, free, assigned)
    case EIndex(receiver, indices) -> {
      fvExpr(ctx, receiver, bound, free, assigned)
      fvExprList(ctx, indices, bound, free, assigned)
    }
    case EMember(recv, _) -> {
      if not isPackagePathExpr(ctx, recv) {
        fvExpr(ctx, recv, bound, free, assigned)
      }
    }
    case EPropagate(inner) -> fvExpr(ctx, inner, bound, free, assigned)
    case EPrefix(_, operand) -> fvExpr(ctx, operand, bound, free, assigned)
    case EBinop(_, lhs, rhs) -> {
      fvExpr(ctx, lhs, bound, free, assigned)
      fvExpr(ctx, rhs, bound, free, assigned)
    }
    case EAssign(target, _, value) -> {
      match target.kind {
        case EPath(tp) -> {
          if tp.segments.count == 1 and not namesContains(assigned, tp.segments[0]) {
            assigned.add(tp.segments[0])
          }
        }
        case _ -> fvExpr(ctx, target, bound, free, assigned)
      }
      fvExpr(ctx, value, bound, free, assigned)
    }
    case EBlock(block) -> fvBlock(ctx, block, bound, free, assigned)
    case _ -> {
    }
  }
}

func fvExprList(
  ctx: in Ctx,
  exprs: in List[Expr],
  bound: in List[String],
  free: in List[String],
  assigned: in List[String],
): Unit {
  var i = 0
  while i < exprs.count {
    fvExpr(ctx, exprs[i], bound, free, assigned)
    i = i + 1
  }
}

func fvEob(
  ctx: in Ctx, eob: in ExprOrBlock, bound: in List[String], free: in List[String], assigned: in List[String]
): Unit {
  match eob {
    case EOBExpr(ex) -> fvExpr(ctx, ex, bound, free, assigned)
    case EOBBlock(b) -> fvBlock(ctx, b, bound, free, assigned)
  }
}

func fvPattern(pat: in Pattern, bound: in List[String]): Unit {
  match pat.kind {
    case PBinding(name, inner) -> {
      bound.add(name)
      match inner {
        case Some(ip) -> fvPattern(ip, bound)
        case None -> {
        }
      }
    }
    case PConstructor(_, subs) -> {
      var i = 0
      while i < subs.count {
        fvPattern(subs[i], bound)
        i = i + 1
      }
    }
    case PParen(inner) -> fvPattern(inner, bound)
    case _ -> {
    }
  }
}

func fvBlock(
  ctx: in Ctx, block: in Block, bound: in List[String], free: in List[String], assigned: in List[String]
): Unit {
  val mark = bound.count
  var i = 0
  while i < block.statements.count {
    fvStmt(ctx, block.statements[i], bound, free, assigned)
    i = i + 1
  }
  truncateNames(bound, mark)
}

func fvStmt(
  ctx: in Ctx, stmt: in Statement, bound: in List[String], free: in List[String], assigned: in List[String]
): Unit {
  match stmt.kind {
    case SLocal(binding) -> {
      match binding {
        case LBVal(pat, _, init) -> {
          fvExpr(ctx, init, bound, free, assigned)
          fvPattern(pat, bound)
        }
        case LBLet(name, _, init) -> {
          fvExpr(ctx, init, bound, free, assigned)
          bound.add(name)
        }
        case LBVar(name, _, initOpt) -> {
          match initOpt {
            case Some(init) -> fvExpr(ctx, init, bound, free, assigned)
            case None -> {
            }
          }
          bound.add(name)
        }
      }
    }
    case SAssign(target, _, value) -> {
      match target.kind {
        case EPath(tp) -> {
          if tp.segments.count == 1 and not namesContains(bound, tp.segments[0]) and not namesContains(assigned, tp.segments[0]) {
            assigned.add(tp.segments[0])
          }
        }
        case _ -> fvExpr(ctx, target, bound, free, assigned)
      }
      fvExpr(ctx, value, bound, free, assigned)
    }
    case SReturn(valOpt) -> {
      match valOpt {
        case Some(v) -> fvExpr(ctx, v, bound, free, assigned)
        case None -> {
        }
      }
    }
    case SWhile(_, cond, body) -> {
      fvExpr(ctx, cond, bound, free, assigned)
      fvBlock(ctx, body, bound, free, assigned)
    }
    case SExpr(ex) -> fvExpr(ctx, ex, bound, free, assigned)
    case _ -> {
    }
  }
}

/// Lower a lambda literal against a known closure signature: synthesise
/// the impl struct (header + captures), the body function, and the
/// capture-releasing destructor; construct the closure heap object.
func lowerLambda(
  ctx: in Ctx, insns: in List[NInsn], lambdaParams: in List[LambdaParam], body: in Block, sigTy: in NType
): NVal {
  val sig = match closureSigOfType(ctx, sigTy) {
    case Some(cs) -> cs
    case None -> panic("Lyric.LlvmCodegen: internal — lambda lowered without a closure signature")
  }
  if lambdaParams.count != sig.paramTys.count {
    panic(
      "Lyric.LlvmCodegen: lambda takes " + lambdaParams.count.toString() +
        " parameter(s) but the expected function type has " +
        sig.paramTys.count.toString()
    )
  }
  // Captures: free variables of the body (minus params).
  val bound: List[String] = newList()
  var bi = 0
  while bi < lambdaParams.count {
    bound.add(lambdaParams[bi].name)
    bi = bi + 1
  }
  val free: List[String] = newList()
  val assigned: List[String] = newList()
  fvBlock(ctx, body, bound, free, assigned)
  var ci = 0
  while ci < assigned.count {
    if namesContains(free, assigned[ci]) {
      panic(
        "Lyric.LlvmCodegen: lambda mutates captured variable '" + assigned[ci] +
          "'; native closures capture by value (rebind inside the lambda instead)"
      )
    }
    ci = ci + 1
  }
  val capTys: List[NType] = newList()
  var fi = 0
  while fi < free.count {
    match mapGet(ctx.varTypes, free[fi]) {
      case Some(t) -> capTys.add(t)
      case None -> panic("Lyric.LlvmCodegen: internal — capture '" + free[fi] + "' has no type")
    }
    fi = fi + 1
  }
  val lamId = ctx.moduleFns.count.toString() + "." + ctx.moduleTypeDefs.count.toString()
  val implName = "__closureimpl." + lamId
  val implFields: List[NType] = newList()
  implFields.add(NI32)
  implFields.add(NPtr(pointee = NI8))
  implFields.add(NPtr(pointee = NI8))
  var ti = 0
  while ti < capTys.count {
    implFields.add(capTys[ti])
    ti = ti + 1
  }
  ctx.moduleTypeDefs.add(NTypeDefn(name = implName, fields = implFields))
  val implTy = NPtr(pointee = NStruct(name = implName, fields = implFields))
  // Body function.
  val bodyFnName = "__lyric.lambda." + lamId
  ctx.moduleFns.add(synthLambdaBody(ctx, bodyFnName, implName, implFields, lambdaParams, body, sig, free, capTys))
  // Capture-releasing destructor (only when a capture is ARC-managed).
  var anyRefCap = false
  var ri = 0
  while ri < capTys.count {
    if isRefNType(capTys[ri]) {
      anyRefCap = true
    }
    ri = ri + 1
  }
  var dtorName = ""
  if anyRefCap {
    dtorName = implName + ".dtor"
    ctx.moduleFns.add(synthClosureDtor(ctx, dtorName, implName, implFields, capTys))
  }
  // Construct.
  val obj = emitHeapAlloc(ctx, insns, implTy, structSize(implFields), dtorName)
  val structTy = NStruct(name = implName, fields = implFields)
  val fnParamTys: List[NType] = newList()
  fnParamTys.add(NPtr(pointee = NI8))
  var pi = 0
  while pi < sig.paramTys.count {
    fnParamTys.add(sig.paramTys[pi])
    pi = pi + 1
  }
  val fnPtrCast = freshTmp(ctx)
  insns.add(
    NBitcast(
      dest = fnPtrCast,
      fromTy = NPtr(pointee = NFnPtr(params = fnParamTys, ret = sig.retTy)),
      value = NGlobal(name = bodyFnName),
      toTy = NPtr(pointee = NI8)
    )
  )
  val fnSlot = freshTmp(ctx)
  val fArgs: List[NArg] = newList()
  fArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  fArgs.add(NArg(ty = NI32, value = NLitInt(v = 2i64, ty = NI32)))
  insns.add(NGEP(dest = fnSlot, ty = structTy, ptr = NLocal(name = obj), indices = fArgs))
  insns.add(NStore(ty = NPtr(pointee = NI8), value = NLocal(name = fnPtrCast), ptr = NLocal(name = fnSlot)))
  var si = 0
  while si < free.count {
    val capVal = loadLocal(ctx, insns, free[si])
    if isRefNType(capTys[si]) {
      emitRetain(ctx, insns, capVal)
    }
    val capSlot = freshTmp(ctx)
    val cArgs: List[NArg] = newList()
    cArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
    cArgs.add(NArg(ty = NI32, value = NLitInt(v = intToLong(3 + si), ty = NI32)))
    insns.add(NGEP(dest = capSlot, ty = structTy, ptr = NLocal(name = obj), indices = cArgs))
    insns.add(NStore(ty = capTys[si], value = capVal.value, ptr = NLocal(name = capSlot)))
    si = si + 1
  }
  val castOut = freshTmp(ctx)
  insns.add(NBitcast(dest = castOut, fromTy = implTy, value = NLocal(name = obj), toTy = sigTy))
  val outV = NVal(ty = sigTy, value = NLocal(name = castOut))
  registerTemp(ctx, outV)
  outV
}

func synthLambdaBody(
  modCtx: in Ctx,
  fnName: in String,
  implName: in String,
  implFields: in List[NType],
  lambdaParams: in List[LambdaParam],
  body: in Block,
  sig: in NClosureSig,
  free: in List[String],
  capTys: in List[NType],
): NFunc {
  val ctx = freshFnCtx(modCtx, modCtx.curPkg[0], sig.retTy)
  val params: List[NParam] = newList()
  params.add(NParam(name = "env", ty = NPtr(pointee = NI8)))
  val bodyInsns: List[NInsn] = newList()
  val structTy = NStruct(name = implName, fields = implFields)
  bodyInsns.add(
    NBitcast(
      dest = "self.env",
      fromTy = NPtr(pointee = NI8),
      value = NLocal(name = "env"),
      toTy = NPtr(pointee = structTy)
    )
  )
  // Captures load as borrows (the closure owns them; the call keeps the
  // closure alive for the duration).
  var ci = 0
  while ci < free.count {
    val capPtr = freshTmp(ctx)
    val gArgs: List[NArg] = newList()
    gArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
    gArgs.add(NArg(ty = NI32, value = NLitInt(v = intToLong(3 + ci), ty = NI32)))
    bodyInsns.add(NGEP(dest = capPtr, ty = structTy, ptr = NLocal(name = "self.env"), indices = gArgs))
    val capVal = freshTmp(ctx)
    bodyInsns.add(NLoad(dest = capVal, ty = capTys[ci], ptr = NLocal(name = capPtr)))
    val slot = free[ci] + ".cap." + freshTmp(ctx)
    ctx.allocas.add(NAlloca(dest = slot, ty = capTys[ci]))
    bodyInsns.add(NStore(ty = capTys[ci], value = NLocal(name = capVal), ptr = NLocal(name = slot)))
    ctx.varSlots.add(free[ci], slot)
    ctx.varTypes.add(free[ci], capTys[ci])
    ci = ci + 1
  }
  var pi = 0
  while pi < lambdaParams.count {
    val pn = lambdaParams[pi].name
    val pty = sig.paramTys[pi]
    params.add(NParam(name = "arg." + pn, ty = pty))
    val slot = pn + ".slot." + freshTmp(ctx)
    ctx.allocas.add(NAlloca(dest = slot, ty = pty))
    bodyInsns.add(NStore(ty = pty, value = NLocal(name = "arg." + pn), ptr = NLocal(name = slot)))
    ctx.varSlots.add(pn, slot)
    ctx.varTypes.add(pn, pty)
    pi = pi + 1
  }
  pushVarScope(ctx)
  pushTempScope(ctx)
  val tailWant: Option[NType] = match sig.retTy { case NVoid -> None; case rt -> Some(value = rt) }
  val tail = lowerBlockValueW(ctx, bodyInsns, body, tailWant)
  match sig.retTy {
    case NVoid -> {
      releaseAllForReturn(ctx, bodyInsns)
      bodyInsns.add(NRetVoid)
    }
    case rt -> {
      match tail.ty {
        case NVoid -> {
          releaseAllForReturn(ctx, bodyInsns)
          bodyInsns.add(NRet(ty = rt, value = zeroValueOf(rt)))
        }
        case _ -> {
          val cv = coerceTo(ctx, bodyInsns, tail, rt)
          if isRefNType(rt) {
            ensureOwned(ctx, bodyInsns, cv)
          }
          releaseAllForReturn(ctx, bodyInsns)
          bodyInsns.add(NRet(ty = rt, value = cv.value))
        }
      }
    }
  }
  val insnsOut: List[NInsn] = newList()
  insnsOut.add(NLabel(name = "entry"))
  appendInsns(insnsOut, ctx.allocas)
  appendInsns(insnsOut, bodyInsns)
  val attrs: List[String] = newList()
  NFunc(
    name = fnName,
    params = params,
    retTy = sig.retTy,
    isPublic = false,
    isExtern = false,
    body = insnsOut,
    attributes = attrs
  )
}

func synthClosureDtor(
  ctx: in Ctx,
  dtorName: in String,
  implName: in String,
  implFields: in List[NType],
  capTys: in List[NType],
): NFunc {
  val body: List[NInsn] = newList()
  body.add(NLabel(name = "entry"))
  val structTy = NStruct(name = implName, fields = implFields)
  body.add(
    NBitcast(dest = "obj", fromTy = NPtr(pointee = NI8), value = NLocal(name = "raw"), toTy = NPtr(pointee = structTy))
  )
  var i = 0
  while i < capTys.count {
    if isRefNType(capTys[i]) {
      val fieldPtr = freshTmp(ctx)
      val gArgs: List[NArg] = newList()
      gArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
      gArgs.add(NArg(ty = NI32, value = NLitInt(v = intToLong(3 + i), ty = NI32)))
      body.add(NGEP(dest = fieldPtr, ty = structTy, ptr = NLocal(name = "obj"), indices = gArgs))
      val fieldVal = freshTmp(ctx)
      body.add(NLoad(dest = fieldVal, ty = capTys[i], ptr = NLocal(name = fieldPtr)))
      val cast = freshTmp(ctx)
      body.add(NBitcast(dest = cast, fromTy = capTys[i], value = NLocal(name = fieldVal), toTy = NPtr(pointee = NI8)))
      body.add(NCallVoid(fn = NGlobal(name = "lyric_release"), args = arg1(NPtr(pointee = NI8), NLocal(name = cast))))
    }
    i = i + 1
  }
  body.add(NRetVoid)
  val params: List[NParam] = newList()
  params.add(NParam(name = "raw", ty = NPtr(pointee = NI8)))
  val attrs: List[String] = newList()
  NFunc(
    name = dtorName,
    params = params,
    retTy = NVoid,
    isPublic = false,
    isExtern = false,
    body = body,
    attributes = attrs
  )
}

/// `NativeWeak[T].upgrade()`: `lyric_weak_upgrade` CAS-increments the
/// target's rc when it is still alive (the +1 transfers here as an
/// owned temp); the result wraps into `Option[T]`'s `Some`/`None`.
func lowerWeakUpgrade(ctx: in Ctx, insns: in List[NInsn], recv: in NVal, target: in NType): NVal {
  val optKey = match resolveGenericUnionKey(ctx, "Option", "Option") {
    case Some(k) -> k
    case None -> panic("Lyric.LlvmCodegen: NativeWeak.upgrade() needs a generic union named 'Option' (with cases Some/None) in the import closure")
  }
  val argTys: List[NType] = newList()
  argTys.add(target)
  val ui = match instantiateGenericUnionOpt(ctx, optKey, argTys) {
    case Some(u) -> u
    case None -> panic("Lyric.LlvmCodegen: cannot instantiate Option for NativeWeak.upgrade()")
  }
  var someIdx = 0 - 1
  var noneIdx = 0 - 1
  var ci = 0
  while ci < ui.cases.count {
    if ui.cases[ci].name == "Some" {
      someIdx = ci
    }
    if ui.cases[ci].name == "None" {
      noneIdx = ci
    }
    ci = ci + 1
  }
  if someIdx < 0 or noneIdx < 0 {
    panic("Lyric.LlvmCodegen: the 'Option' union in scope lacks Some/None cases")
  }
  val raw = freshTmp(ctx)
  insns.add(NBitcast(dest = raw, fromTy = recv.ty, value = recv.value, toTy = NPtr(pointee = NI8)))
  val up = freshTmp(ctx)
  insns.add(
    NCall(
      dest = up,
      retTy = NPtr(pointee = NI8),
      fn = NGlobal(name = "lyric_weak_upgrade"),
      args = arg1(NPtr(pointee = NI8), NLocal(name = raw))
    )
  )
  val isNull = freshTmp(ctx)
  insns.add(
    NICmp(
      dest = isNull,
      pred = IEq,
      ty = NPtr(pointee = NI8),
      a = NLocal(name = up),
      b = NLitNull(ty = NPtr(pointee = NI8))
    )
  )
  val someL = freshLabel(ctx, "weak.some")
  val noneL = freshLabel(ctx, "weak.none")
  val mergeL = freshLabel(ctx, "weak.merge")
  val slot = "weak.slot." + freshTmp(ctx)
  val optTy = unionPtrType(ui)
  ctx.allocas.add(NAlloca(dest = slot, ty = optTy))
  insns.add(NCondBr(cond = NLocal(name = isNull), thenLabel = noneL, elseLabel = someL))
  insns.add(NLabel(name = someL))
  val typed = freshTmp(ctx)
  insns.add(NBitcast(dest = typed, fromTy = NPtr(pointee = NI8), value = NLocal(name = up), toTy = target))
  // The CAS +1 transfers to this owned temp; Some's field store retains
  // its own reference, and the temp releases at region end.
  pushTempScope(ctx)
  val upVal = NVal(ty = target, value = NLocal(name = typed))
  registerTemp(ctx, upVal)
  val someVals: List[NVal] = newList()
  someVals.add(upVal)
  val someV = lowerUnionConstructVals(ctx, insns, ui, someIdx, someVals)
  ensureOwned(ctx, insns, someV)
  popTempScope(ctx, insns)
  insns.add(NStore(ty = optTy, value = someV.value, ptr = NLocal(name = slot)))
  insns.add(NBr(label = mergeL))
  insns.add(NLabel(name = noneL))
  pushTempScope(ctx)
  val noneVals: List[NVal] = newList()
  val noneV = lowerUnionConstructVals(ctx, insns, ui, noneIdx, noneVals)
  ensureOwned(ctx, insns, noneV)
  popTempScope(ctx, insns)
  insns.add(NStore(ty = optTy, value = noneV.value, ptr = NLocal(name = slot)))
  insns.add(NBr(label = mergeL))
  insns.add(NLabel(name = mergeL))
  val dest = freshTmp(ctx)
  insns.add(NLoad(dest = dest, ty = optTy, ptr = NLocal(name = slot)))
  val outV = NVal(ty = optTy, value = NLocal(name = dest))
  registerTemp(ctx, outV)
  outV
}

/// Indirect call through a closure value.
func lowerClosureCall(
  ctx: in Ctx, insns: in List[NInsn], clos: in NVal, sig: in NClosureSig, args: in List[CallArg]
): NVal {
  if args.count != sig.paramTys.count {
    panic(
      "Lyric.LlvmCodegen: closure call passes " + args.count.toString() + " argument(s) but the function type has " +
        sig.paramTys.count.toString()
    )
  }
  val structTy = match clos.ty { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  val fnSlot = freshTmp(ctx)
  val gArgs: List[NArg] = newList()
  gArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  gArgs.add(NArg(ty = NI32, value = NLitInt(v = 2i64, ty = NI32)))
  insns.add(NGEP(dest = fnSlot, ty = structTy, ptr = clos.value, indices = gArgs))
  val fnRaw = freshTmp(ctx)
  insns.add(NLoad(dest = fnRaw, ty = NPtr(pointee = NI8), ptr = NLocal(name = fnSlot)))
  val fnParamTys: List[NType] = newList()
  fnParamTys.add(NPtr(pointee = NI8))
  var i = 0
  while i < sig.paramTys.count {
    fnParamTys.add(sig.paramTys[i])
    i = i + 1
  }
  val fnTyped = freshTmp(ctx)
  insns.add(
    NBitcast(
      dest = fnTyped,
      fromTy = NPtr(pointee = NI8),
      value = NLocal(name = fnRaw),
      toTy = NPtr(pointee = NFnPtr(params = fnParamTys, ret = sig.retTy))
    )
  )
  val envCast = freshTmp(ctx)
  insns.add(NBitcast(dest = envCast, fromTy = clos.ty, value = clos.value, toTy = NPtr(pointee = NI8)))
  val callArgs: List[NArg] = newList()
  callArgs.add(NArg(ty = NPtr(pointee = NI8), value = NLocal(name = envCast)))
  var ai = 0
  while ai < args.count {
    val av = match args[ai] {
      case CAPositional(ex) -> lowerExprExpecting(ctx, insns, ex, sig.paramTys[ai])
      case CANamed(_, value, _) -> lowerExprExpecting(ctx, insns, value, sig.paramTys[ai])
    }
    callArgs.add(NArg(ty = sig.paramTys[ai], value = av.value))
    ai = ai + 1
  }
  match sig.retTy {
    case NVoid -> {
      insns.add(NCallVoid(fn = NLocal(name = fnTyped), args = callArgs))
      NVal(ty = NVoid, value = NUndef(ty = NVoid))
    }
    case rt -> {
      val dest = freshTmp(ctx)
      insns.add(NCall(dest = dest, retTy = rt, fn = NLocal(name = fnTyped), args = callArgs))
      val outV = NVal(ty = rt, value = NLocal(name = dest))
      registerTemp(ctx, outV)
      outV
    }
  }
}

/// Lower `e` under a known expected type: generic-union case
/// constructions resolve against the expected instantiation directly
/// (the only way to type nullary cases like `None`, and cases that
/// mention only some type params, like `Result`'s `Ok`/`Err`), then
/// everything else lowers normally and coerces.
/// Coerce `v` to `want` unless the producing expression diverged
/// (panic / return lower to an NVoid value in value position): `Never`
/// coerces to anything in a well-typed program, so the NVoid value
/// passes through untouched and the caller's slot scheme (lowerIf /
/// lowerMatch) skips its store.
func coerceUnlessDiverged(ctx: in Ctx, insns: in List[NInsn], v: in NVal, want: in NType): NVal {
  if isVoidNType(v.ty) and not isVoidNType(want) {
    return v
  }
  coerceTo(ctx, insns, v, want)
}

func lowerExprExpecting(ctx: in Ctx, insns: in List[NInsn], e: in Expr, want: in NType): NVal {
  match caseConstructForExpected(ctx, insns, e, want) {
    case Some(v) -> return v
    case None -> {
    }
  }
  match collectionConstructForExpected(ctx, insns, e, want) {
    case Some(v) -> return v
    case None -> {
    }
  }
  // Structural recursion: the expected type flows into value-position
  // control flow so branches/arms can construct generic cases.
  match e.kind {
    case ELambda(lambdaParams, body) -> {
      match closureSigOfType(ctx, want) {
        case Some(_) -> return lowerLambda(ctx, insns, lambdaParams, body, want)
        case None -> {
        }
      }
    }
    case EIf(cond, thenBranch, elseBranch, _) -> {
      val w1: Option[NType] = Some(value = want)
      return coerceUnlessDiverged(ctx, insns, lowerIf(ctx, insns, cond, thenBranch, elseBranch, w1), want)
    }
    case EMatch(scrutinee, arms) -> {
      val w2: Option[NType] = Some(value = want)
      return coerceUnlessDiverged(ctx, insns, lowerMatch(ctx, insns, scrutinee, arms, e.span.startPos.line, w2), want)
    }
    case EBlock(block) -> {
      val w3: Option[NType] = Some(value = want)
      return coerceUnlessDiverged(ctx, insns, lowerBlockValueW(ctx, insns, block, w3), want)
    }
    case EParen(inner) -> return lowerExprExpecting(ctx, insns, inner, want)
    case _ -> {
    }
  }
  coerceUnlessDiverged(ctx, insns, lowerExpr(ctx, insns, e), want)
}

/// The (caseName, args) of `e` when it is a union-case construction
/// whose case belongs to the expected union instantiation; constructs
/// it against the concrete case field types.
func caseConstructForExpected(ctx: in Ctx, insns: in List[NInsn], e: in Expr, want: in NType): Option[NVal] {
  if not isRefNType(want) {
    return None
  }
  val ui = match unionInfoOfType(ctx, want) { case Some(u) -> u; case None -> return None }
  var refName = ""
  val noArgs: List[CallArg] = newList()
  var callArgs = noArgs
  match e.kind {
    case EPath(path) -> {
      refName = modulePathJoin(path.segments)
    }
    case EMember(recv, memberName) -> {
      if isPackagePathExpr(ctx, recv) {
        match recv.kind {
          case EPath(rpath) -> {
            refName = modulePathJoin(rpath.segments) + "." + memberName
          }
          case _ -> {
          }
        }
      }
    }
    case ECall(fn, args) -> {
      match fn.kind {
        case EPath(path) -> {
          refName = modulePathJoin(path.segments)
        }
        case EMember(recv, memberName) -> {
          if isPackagePathExpr(ctx, recv) {
            match recv.kind {
              case EPath(rpath) -> {
                refName = modulePathJoin(rpath.segments) + "." + memberName
              }
              case _ -> {
              }
            }
          }
        }
        case _ -> {
        }
      }
      callArgs = args
    }
    case _ -> {
    }
  }
  if refName.length == 0 {
    return None
  }
  // A local shadows a case name.
  if ctx.varTypes.containsKey(refName) {
    return None
  }
  if not ctx.caseToGenericUnion.containsKey(refName) {
    return None
  }
  val dotIdx = lastDotIndex(refName)
  val caseName = if dotIdx >= 0 { Str.substring(refName, dotIdx + 1, refName.length - dotIdx - 1) } else { refName }
  var caseIdx = 0 - 1
  var ci = 0
  while ci < ui.cases.count {
    if ui.cases[ci].name == caseName {
      caseIdx = ci
    }
    ci = ci + 1
  }
  if caseIdx < 0 {
    return None
  }
  Some(value = lowerUnionConstruct(ctx, insns, ui, caseIdx, callArgs))
}

/// `define internal void @<T>.dtor(i8*)`: release each ref-typed field
/// (ARC Rule 7).  `lyric_release` frees the object afterwards.
func synthRecordDtor(ctx: in Ctx, ri: in NRecInfo): NFunc {
  val body: List[NInsn] = newList()
  body.add(NLabel(name = "entry"))
  val objTy = recPtrType(ri)
  val structTy = match objTy { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  body.add(NBitcast(dest = "obj", fromTy = NPtr(pointee = NI8), value = NLocal(name = "raw"), toTy = objTy))
  var i = 0
  while i < ri.fieldTys.count {
    if isRefNType(ri.fieldTys[i]) {
      val fieldPtr = freshTmp(ctx)
      val idxArgs: List[NArg] = newList()
      idxArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
      idxArgs.add(NArg(ty = NI32, value = NLitInt(v = intToLong(2 + i), ty = NI32)))
      body.add(NGEP(dest = fieldPtr, ty = structTy, ptr = NLocal(name = "obj"), indices = idxArgs))
      val fieldVal = freshTmp(ctx)
      body.add(NLoad(dest = fieldVal, ty = ri.fieldTys[i], ptr = NLocal(name = fieldPtr)))
      val cast = freshTmp(ctx)
      body.add(NBitcast(dest = cast, fromTy = ri.fieldTys[i], value = NLocal(name = fieldVal), toTy = NPtr(pointee = NI8)))
      body.add(NCallVoid(fn = NGlobal(name = "lyric_release"), args = arg1(NPtr(pointee = NI8), NLocal(name = cast))))
    }
    i = i + 1
  }
  body.add(NRetVoid)
  val params: List[NParam] = newList()
  params.add(NParam(name = "raw", ty = NPtr(pointee = NI8)))
  val attrs: List[String] = newList()
  NFunc(
    name = recDtorName(ri),
    params = params,
    retTy = NVoid,
    isPublic = false,
    isExtern = false,
    body = body,
    attributes = attrs
  )
}

/// Union destructor: switch on the discriminant; each ref-carrying case
/// releases its ref fields through the case payload view.
func synthUnionDtor(ctx: in Ctx, ui: in NUnionInfo): NFunc {
  val body: List[NInsn] = newList()
  body.add(NLabel(name = "entry"))
  val objTy = unionPtrType(ui)
  val structTy = match objTy { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  body.add(NBitcast(dest = "obj", fromTy = NPtr(pointee = NI8), value = NLocal(name = "raw"), toTy = objTy))
  val discPtr = freshTmp(ctx)
  val discArgs: List[NArg] = newList()
  discArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  discArgs.add(NArg(ty = NI32, value = NLitInt(v = 2i64, ty = NI32)))
  body.add(NGEP(dest = discPtr, ty = structTy, ptr = NLocal(name = "obj"), indices = discArgs))
  val disc = freshTmp(ctx)
  body.add(NLoad(dest = disc, ty = NI32, ptr = NLocal(name = discPtr)))
  val endL = "dtor.end"
  val switchCases: List[NSwitchCase] = newList()
  val caseLabels: List[String] = newList()
  var ci = 0
  while ci < ui.cases.count {
    var hasRef = false
    var fi = 0
    while fi < ui.cases[ci].fieldTys.count {
      if isRefNType(ui.cases[ci].fieldTys[fi]) {
        hasRef = true
      }
      fi = fi + 1
    }
    if hasRef {
      val label = "dtor.case." + ci.toString()
      caseLabels.add(label)
      switchCases.add(NSwitchCase(matchVal = intToLong(ci), label = label))
    } else {
      caseLabels.add("")
    }
    ci = ci + 1
  }
  body.add(NSwitch(ty = NI32, scrutinee = NLocal(name = disc), defaultLabel = endL, cases = switchCases))
  var ci2 = 0
  while ci2 < ui.cases.count {
    if caseLabels[ci2].length > 0 {
      body.add(NLabel(name = caseLabels[ci2]))
      val payloadPtr = freshTmp(ctx)
      val pArgs: List[NArg] = newList()
      pArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
      pArgs.add(NArg(ty = NI32, value = NLitInt(v = 4i64, ty = NI32)))
      body.add(NGEP(dest = payloadPtr, ty = structTy, ptr = NLocal(name = "obj"), indices = pArgs))
      val caseTy = casePayloadStructType(ui, ui.cases[ci2])
      val casePtr = freshTmp(ctx)
      body.add(
        NBitcast(
          dest = casePtr,
          fromTy = NPtr(pointee = NArray(elem = NI64, size = ui.payloadWords)),
          value = NLocal(name = payloadPtr),
          toTy = NPtr(pointee = caseTy)
        )
      )
      var fi = 0
      while fi < ui.cases[ci2].fieldTys.count {
        if isRefNType(ui.cases[ci2].fieldTys[fi]) {
          val fieldPtr = freshTmp(ctx)
          val fArgs: List[NArg] = newList()
          fArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
          fArgs.add(NArg(ty = NI32, value = NLitInt(v = intToLong(fi), ty = NI32)))
          body.add(NGEP(dest = fieldPtr, ty = caseTy, ptr = NLocal(name = casePtr), indices = fArgs))
          val fieldVal = freshTmp(ctx)
          body.add(NLoad(dest = fieldVal, ty = ui.cases[ci2].fieldTys[fi], ptr = NLocal(name = fieldPtr)))
          val cast = freshTmp(ctx)
          body.add(
            NBitcast(
              dest = cast,
              fromTy = ui.cases[ci2].fieldTys[fi],
              value = NLocal(name = fieldVal),
              toTy = NPtr(pointee = NI8)
            )
          )
          body.add(NCallVoid(fn = NGlobal(name = "lyric_release"), args = arg1(NPtr(pointee = NI8), NLocal(name = cast))))
        }
        fi = fi + 1
      }
      body.add(NBr(label = endL))
    }
    ci2 = ci2 + 1
  }
  body.add(NLabel(name = endL))
  body.add(NRetVoid)
  val params: List[NParam] = newList()
  params.add(NParam(name = "raw", ty = NPtr(pointee = NI8)))
  val attrs: List[String] = newList()
  NFunc(
    name = unionDtorName(ui),
    params = params,
    retTy = NVoid,
    isPublic = false,
    isExtern = false,
    body = body,
    attributes = attrs
  )
}

// ── Construction ─────────────────────────────────────────────────────────────
/// Allocate a heap object and initialise its ARC header (rc = 1 per
/// Rule 1; dtor null when the type owns no refs).
func emitHeapAlloc(ctx: in Ctx, insns: in List[NInsn], objTy: in NType, size: in Int, dtorName: in String): String {
  val raw = freshTmp(ctx)
  insns.add(
    NCall(
      dest = raw,
      retTy = NPtr(pointee = NI8),
      fn = NGlobal(name = "lyric_alloc"),
      args = arg1(NI64, NLitInt(v = intToLong(size), ty = NI64))
    )
  )
  val obj = freshTmp(ctx)
  insns.add(NBitcast(dest = obj, fromTy = NPtr(pointee = NI8), value = NLocal(name = raw), toTy = objTy))
  val structTy = match objTy { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  val rcPtr = freshTmp(ctx)
  val rcArgs: List[NArg] = newList()
  rcArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  rcArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  insns.add(NGEP(dest = rcPtr, ty = structTy, ptr = NLocal(name = obj), indices = rcArgs))
  insns.add(NStore(ty = NI32, value = NLitInt(v = 1i64, ty = NI32), ptr = NLocal(name = rcPtr)))
  val dtorPtr = freshTmp(ctx)
  val dtorArgs: List[NArg] = newList()
  dtorArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  dtorArgs.add(NArg(ty = NI32, value = NLitInt(v = 1i64, ty = NI32)))
  insns.add(NGEP(dest = dtorPtr, ty = structTy, ptr = NLocal(name = obj), indices = dtorArgs))
  if dtorName.length == 0 {
    insns.add(NStore(ty = NPtr(pointee = NI8), value = NLitNull(ty = NPtr(pointee = NI8)), ptr = NLocal(name = dtorPtr)))
  } else {
    val fnParams: List[NType] = newList()
    fnParams.add(NPtr(pointee = NI8))
    val cast = freshTmp(ctx)
    insns.add(
      NBitcast(
        dest = cast,
        fromTy = NPtr(pointee = NFnPtr(params = fnParams, ret = NVoid)),
        value = NGlobal(name = dtorName),
        toTy = NPtr(pointee = NI8)
      )
    )
    insns.add(NStore(ty = NPtr(pointee = NI8), value = NLocal(name = cast), ptr = NLocal(name = dtorPtr)))
  }
  obj
}

/// Resolve construction args (named/positional/defaults) to the field
/// declaration order and lower each.
func resolveFieldArgs(
  ctx: in Ctx,
  insns: in List[NInsn],
  what: in String,
  fieldNames: in List[String],
  fieldTys: in List[NType],
  fieldDefaults: in List[Option[Expr]],
  args: in List[CallArg],
): List[NVal] {
  val provided: Map[String, Expr] = newMap()
  var positionalIdx = 0
  var ai = 0
  while ai < args.count {
    match args[ai] {
      case CANamed(name, value, _) -> {
        if not provided.containsKey(name) {
          provided.add(name, value)
        }
      }
      case CAPositional(ex) -> {
        if positionalIdx >= fieldNames.count {
          panic("Lyric.LlvmCodegen: too many arguments constructing " + what)
        }
        if not provided.containsKey(fieldNames[positionalIdx]) {
          provided.add(fieldNames[positionalIdx], ex)
        }
        positionalIdx = positionalIdx + 1
      }
    }
    ai = ai + 1
  }
  val outV: List[NVal] = newList()
  var fi = 0
  while fi < fieldNames.count {
    // var-mutation shape (stage-0 value-position-match lowering gap,
    // #4631: the rewrapped Option falls through as None).
    var ex: Option[Expr] = None
    match mapGet(provided, fieldNames[fi]) {
      case Some(e) -> {
        ex = Some(value = e)
      }
      case None -> {
        ex = fieldDefaults[fi]
      }
    }
    match ex {
      case Some(e) -> outV.add(lowerExprExpecting(ctx, insns, e, fieldTys[fi]))
      case None -> panic("Lyric.LlvmCodegen: missing field '" + fieldNames[fi] + "' constructing " + what)
    }
    fi = fi + 1
  }
  outV
}

func lowerRecordConstructArgs(ctx: in Ctx, insns: in List[NInsn], ri: in NRecInfo, args: in List[CallArg]): NVal {
  val noDflts: List[Option[Expr]] = ri.fieldDefaults
  val vals = resolveFieldArgs(ctx, insns, "record '" + ri.irName + "'", ri.fieldNames, ri.fieldTys, noDflts, args)
  lowerRecordConstructVals(ctx, insns, ri, vals)
}

/// Construct a record from pre-lowered field values (coerced here).
func lowerRecordConstructVals(ctx: in Ctx, insns: in List[NInsn], ri: in NRecInfo, rawVals: in List[NVal]): NVal {
  val vals: List[NVal] = newList()
  var vi = 0
  while vi < rawVals.count {
    match ri.fieldTys[vi] {
      case NVoid -> vals.add(rawVals[vi])
      case want -> vals.add(coerceTo(ctx, insns, rawVals[vi], want))
    }
    vi = vi + 1
  }
  val objTy = recPtrType(ri)
  val structTy = match objTy { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  val dtorName = if recHasRefFields(ri) { recDtorName(ri) } else { "" }
  val obj = emitHeapAlloc(ctx, insns, objTy, recAllocSize(ri), dtorName)
  var fi = 0
  while fi < vals.count {
    // A Unit field's placeholder byte stays undef (layoutFieldTys).
    if isVoidNType(ri.fieldTys[fi]) {
      fi = fi + 1
      continue
    }
    // Rule 2: the object owns its ref fields — retain before storing.
    if isRefNType(ri.fieldTys[fi]) {
      emitRetain(ctx, insns, vals[fi])
    }
    val fieldPtr = freshTmp(ctx)
    val fArgs: List[NArg] = newList()
    fArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
    fArgs.add(NArg(ty = NI32, value = NLitInt(v = intToLong(2 + fi), ty = NI32)))
    insns.add(NGEP(dest = fieldPtr, ty = structTy, ptr = NLocal(name = obj), indices = fArgs))
    insns.add(NStore(ty = ri.fieldTys[fi], value = vals[fi].value, ptr = NLocal(name = fieldPtr)))
    fi = fi + 1
  }
  val outV = NVal(ty = objTy, value = NLocal(name = obj))
  registerTemp(ctx, outV)
  outV
}

func lowerUnionConstruct(
  ctx: in Ctx, insns: in List[NInsn], ui: in NUnionInfo, caseIdx: in Int, args: in List[CallArg]
): NVal {
  val ci = ui.cases[caseIdx]
  val noDflts: List[Option[Expr]] = newList()
  var di = 0
  while di < ci.fieldNames.count {
    val noD: Option[Expr] = None
    noDflts.add(noD)
    di = di + 1
  }
  val vals = resolveFieldArgs(
    ctx,
    insns,
    "union case '" + ui.irName + "." + ci.name + "'",
    ci.fieldNames,
    ci.fieldTys,
    noDflts,
    args
  )
  lowerUnionConstructVals(ctx, insns, ui, caseIdx, vals)
}

/// Construct a union case from pre-lowered field values (coerced to the
/// case's concrete field types here).
func lowerUnionConstructVals(
  ctx: in Ctx,
  insns: in List[NInsn],
  ui: in NUnionInfo,
  caseIdx: in Int,
  rawVals: in List[NVal],
): NVal {
  val ci = ui.cases[caseIdx]
  val vals: List[NVal] = newList()
  var vi = 0
  while vi < rawVals.count {
    match ci.fieldTys[vi] {
      case NVoid -> vals.add(rawVals[vi])
      case want -> vals.add(coerceTo(ctx, insns, rawVals[vi], want))
    }
    vi = vi + 1
  }
  val objTy = unionPtrType(ui)
  val structTy = match objTy { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  val dtorName = if unionHasRefFields(ui) { unionDtorName(ui) } else { "" }
  val obj = emitHeapAlloc(ctx, insns, objTy, unionAllocSize(ui), dtorName)
  val discPtr = freshTmp(ctx)
  val dArgs: List[NArg] = newList()
  dArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  dArgs.add(NArg(ty = NI32, value = NLitInt(v = 2i64, ty = NI32)))
  insns.add(NGEP(dest = discPtr, ty = structTy, ptr = NLocal(name = obj), indices = dArgs))
  insns.add(NStore(ty = NI32, value = NLitInt(v = intToLong(caseIdx), ty = NI32), ptr = NLocal(name = discPtr)))
  if vals.count > 0 {
    val casePtr = emitCasePayloadPtr(ctx, insns, ui, structTy, obj, caseIdx)
    val caseTy = casePayloadStructType(ui, ci)
    var fi = 0
    while fi < vals.count {
      // A Unit field's placeholder byte stays undef (layoutFieldTys).
      if isVoidNType(ci.fieldTys[fi]) {
        fi = fi + 1
        continue
      }
      if isRefNType(ci.fieldTys[fi]) {
        emitRetain(ctx, insns, vals[fi])
      }
      val fieldPtr = freshTmp(ctx)
      val fArgs: List[NArg] = newList()
      fArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
      fArgs.add(NArg(ty = NI32, value = NLitInt(v = intToLong(fi), ty = NI32)))
      insns.add(NGEP(dest = fieldPtr, ty = caseTy, ptr = NLocal(name = casePtr), indices = fArgs))
      insns.add(NStore(ty = ci.fieldTys[fi], value = vals[fi].value, ptr = NLocal(name = fieldPtr)))
      fi = fi + 1
    }
  }
  val outV = NVal(ty = objTy, value = NLocal(name = obj))
  registerTemp(ctx, outV)
  outV
}

/// GEP to the union payload area and bitcast it to the case's payload
/// struct pointer.
func emitCasePayloadPtr(
  ctx: in Ctx,
  insns: in List[NInsn],
  ui: in NUnionInfo,
  structTy: in NType,
  obj: in String,
  caseIdx: in Int,
): String {
  val payloadPtr = freshTmp(ctx)
  val pArgs: List[NArg] = newList()
  pArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  pArgs.add(NArg(ty = NI32, value = NLitInt(v = 4i64, ty = NI32)))
  insns.add(NGEP(dest = payloadPtr, ty = structTy, ptr = NLocal(name = obj), indices = pArgs))
  val caseTy = casePayloadStructType(ui, ui.cases[caseIdx])
  val casePtr = freshTmp(ctx)
  insns.add(
    NBitcast(
      dest = casePtr,
      fromTy = NPtr(pointee = NArray(elem = NI64, size = ui.payloadWords)),
      value = NLocal(name = payloadPtr),
      toTy = NPtr(pointee = caseTy)
    )
  )
  casePtr
}

func lowerDistinctConstruct(
  ctx: in Ctx,
  insns: in List[NInsn],
  name: in String,
  di: in NDistinctInfo,
  args: in List[CallArg],
  line: in Int,
): NVal {
  if args.count != 1 {
    panic("Lyric.LlvmCodegen: distinct type '" + name + "' takes exactly one construction argument")
  }
  val v = coerceTo(ctx, insns, lowerPositionalArg(ctx, insns, args, 0), di.underlying)
  if di.hasRange {
    val loCmp = freshTmp(ctx)
    insns.add(
      NICmp(dest = loCmp, pred = ISlt, ty = di.underlying, a = v.value, b = NLitInt(v = di.lo, ty = di.underlying))
    )
    val hiCmp = freshTmp(ctx)
    insns.add(
      NICmp(dest = hiCmp, pred = ISgt, ty = di.underlying, a = v.value, b = NLitInt(v = di.hi, ty = di.underlying))
    )
    val bad = freshTmp(ctx)
    insns.add(NOr(dest = bad, ty = NI1, a = NLocal(name = loCmp), b = NLocal(name = hiCmp)))
    val trapL = freshLabel(ctx, "range.trap")
    val okL = freshLabel(ctx, "range.ok")
    insns.add(NCondBr(cond = NLocal(name = bad), thenLabel = trapL, elseLabel = okL))
    insns.add(NLabel(name = trapL))
    emitPanicRaw(ctx, insns, "value out of range for type " + name, line)
    insns.add(NBr(label = okL))
    insns.add(NLabel(name = okL))
  }
  v
}

// ── Pattern matching (N2.4) ──────────────────────────────────────────────────
/// Union info for a scrutinee type, when it is a registered union.
func unionInfoOfType(ctx: in Ctx, t: in NType): Option[NUnionInfo] {
  match t {
    case NPtr(pointee) -> {
      match pointee {
        case NStruct(name, _) -> mapGet(ctx.unionDefs, name)
        case _ -> None
      }
    }
    case _ -> None
  }
}

func scrutineeHasCase(ctx: in Ctx, t: in NType, name: in String): Bool {
  match unionInfoOfType(ctx, t) {
    case Some(ui) -> {
      var i = 0
      while i < ui.cases.count {
        if ui.cases[i].name == name {
          return true
        }
        i = i + 1
      }
      false
    }
    case None -> false
  }
}

func recInfoOfType(ctx: in Ctx, t: in NType): Option[NRecInfo] {
  match t {
    case NPtr(pointee) -> {
      match pointee {
        case NStruct(name, _) -> mapGet(ctx.recordDefs, name)
        case _ -> None
      }
    }
    case _ -> None
  }
}

func stripPattern(p: in Pattern): Pattern {
  match p.kind {
    case PParen(inner) -> stripPattern(inner)
    case _ -> p
  }
}

/// Emit the test for `arm`'s pattern against `sv`, branching to
/// `okLabel` on match and `failLabel` otherwise, and record the
/// case-field/whole-value bindings to apply in the arm body.  Bindings
/// are (name, NVal) pairs appended to `bindNames`/`bindVals`.
func emitPatternTest(
  ctx: in Ctx,
  insns: in List[NInsn],
  sv: in NVal,
  pat: in Pattern,
  okLabel: in String,
  failLabel: in String,
  bindNames: in List[String],
  bindVals: in List[NVal],
): Unit {
  val p = stripPattern(pat)
  match p.kind {
    case PWildcard -> insns.add(NBr(label = okLabel))
    case PBinding(name, inner) -> {
      match inner {
        case Some(_) -> panic("Lyric.LlvmCodegen: nested binding patterns (name @ pattern) are not yet supported for --target native")
        case None -> {
          // A bare identifier that names a case of the scrutinee's
          // union is a nullary constructor pattern, not a binding
          // (`case Nada ->`): the parser cannot distinguish them.
          if scrutineeHasCase(ctx, sv.ty, name) {
            val segs: List[String] = newList()
            segs.add(name)
            val noSubs: List[Pattern] = newList()
            emitConstructorTest(
              ctx,
              insns,
              sv,
              ModulePath(segments = segs, span = p.span),
              noSubs,
              okLabel,
              failLabel,
              bindNames,
              bindVals
            )
            return
          }
          bindNames.add(name)
          bindVals.add(sv)
          insns.add(NBr(label = okLabel))
        }
      }
    }
    case PLiteral(lit) -> {
      val lv = lowerLiteral(ctx, insns, lit)
      if isStringNType(sv.ty) {
        val eq = callRuntime(ctx, insns, "lyric_string_eq", NI32, arg2(sv.ty, sv.value, lv.ty, lv.value))
        val isEq = freshTmp(ctx)
        insns.add(NICmp(dest = isEq, pred = INe, ty = NI32, a = eq.value, b = NLitInt(v = 0i64, ty = NI32)))
        insns.add(NCondBr(cond = NLocal(name = isEq), thenLabel = okLabel, elseLabel = failLabel))
      } else {
        match sv.ty {
          case NDouble -> {
            val cmp = freshTmp(ctx)
            insns.add(NFCmp(dest = cmp, pred = FOeq, a = sv.value, b = lv.value))
            insns.add(NCondBr(cond = NLocal(name = cmp), thenLabel = okLabel, elseLabel = failLabel))
          }
          case sty -> {
            val lc = coerceTo(ctx, insns, lv, sty)
            val cmp = freshTmp(ctx)
            insns.add(NICmp(dest = cmp, pred = IEq, ty = sty, a = sv.value, b = lc.value))
            insns.add(NCondBr(cond = NLocal(name = cmp), thenLabel = okLabel, elseLabel = failLabel))
          }
        }
      }
    }
    case PRange(lo, inclusive, hi) -> {
      val loV = coerceTo(ctx, insns, lowerExpr(ctx, insns, lo), sv.ty)
      val hiV = coerceTo(ctx, insns, lowerExpr(ctx, insns, hi), sv.ty)
      val geLo = freshTmp(ctx)
      insns.add(NICmp(dest = geLo, pred = ISge, ty = sv.ty, a = sv.value, b = loV.value))
      val leHi = freshTmp(ctx)
      val hiPred = if inclusive { ISle } else { ISlt }
      insns.add(NICmp(dest = leHi, pred = hiPred, ty = sv.ty, a = sv.value, b = hiV.value))
      val both = freshTmp(ctx)
      insns.add(NAnd(dest = both, ty = NI1, a = NLocal(name = geLo), b = NLocal(name = leHi)))
      insns.add(NCondBr(cond = NLocal(name = both), thenLabel = okLabel, elseLabel = failLabel))
    }
    case PConstructor(head, subpats) -> emitConstructorTest(ctx, insns, sv, head, subpats, okLabel, failLabel, bindNames, bindVals)
    case PTuple(patterns) -> {
      val ri = match recInfoOfType(ctx, sv.ty) {
        case Some(r) -> r
        case None -> panic("Lyric.LlvmCodegen: tuple pattern matched against a non-tuple value")
      }
      if patterns.count != ri.fieldNames.count {
        panic("Lyric.LlvmCodegen: tuple pattern arity mismatch")
      }
      var pi = 0
      while pi < patterns.count {
        val sub = stripPattern(patterns[pi])
        match sub.kind {
          case PBinding(bname, binner) -> {
            match binner {
              case Some(_) -> panic("Lyric.LlvmCodegen: nested binding patterns are not yet supported for --target native")
              case None -> {
                bindNames.add(bname)
                bindVals.add(lowerRecordFieldLoad(ctx, insns, ri, sv, ri.fieldNames[pi]))
              }
            }
          }
          case PWildcard -> {
          }
          case _ -> panic("Lyric.LlvmCodegen: only bindings and wildcards are supported inside tuple patterns for --target native")
        }
        pi = pi + 1
      }
      insns.add(NBr(label = okLabel))
    }
    case _ -> panic("Lyric.LlvmCodegen: this pattern form is not yet supported for --target native (Phase N2 lowers wildcard, binding, literal, range, and constructor patterns)")
  }
}

func emitConstructorTest(
  ctx: in Ctx,
  insns: in List[NInsn],
  sv: in NVal,
  head: in ModulePath,
  subpats: in List[Pattern],
  okLabel: in String,
  failLabel: in String,
  bindNames: in List[String],
  bindVals: in List[NVal],
): Unit {
  val joined = modulePathJoin(head.segments)
  // Enum case pattern: scrutinee is the i32 discriminant itself.
  match mapGet(ctx.enumDefs, joined) {
    case Some(idx) -> {
      val cmp = freshTmp(ctx)
      insns.add(NICmp(dest = cmp, pred = IEq, ty = NI32, a = sv.value, b = NLitInt(v = intToLong(idx), ty = NI32)))
      insns.add(NCondBr(cond = NLocal(name = cmp), thenLabel = okLabel, elseLabel = failLabel))
      return
    }
    case None -> {
    }
  }
  val ui = match unionInfoOfType(ctx, sv.ty) {
    case Some(u) -> u
    case None -> panic("Lyric.LlvmCodegen: constructor pattern '" + joined + "' matched against a non-union value")
  }
  // Resolve the case by name within the scrutinee's union: this covers
  // generic instantiations (whose cases have no caseRefs entries) and
  // validates non-generic patterns against the actual scrutinee.
  val caseName = lastSeg(head)
  var caseIdxFound = 0 - 1
  var cix = 0
  while cix < ui.cases.count {
    if ui.cases[cix].name == caseName {
      caseIdxFound = cix
    }
    cix = cix + 1
  }
  if caseIdxFound < 0 {
    panic("Lyric.LlvmCodegen: constructor pattern '" + joined + "' does not belong to union '" + ui.irName + "'")
  }
  val cref = NCaseRef(unionKey = ui.irName, caseIdx = caseIdxFound)
  val structTy = match unionPtrType(ui) { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  val discPtr = freshTmp(ctx)
  val dArgs: List[NArg] = newList()
  dArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  dArgs.add(NArg(ty = NI32, value = NLitInt(v = 2i64, ty = NI32)))
  insns.add(NGEP(dest = discPtr, ty = structTy, ptr = sv.value, indices = dArgs))
  val disc = freshTmp(ctx)
  insns.add(NLoad(dest = disc, ty = NI32, ptr = NLocal(name = discPtr)))
  val cmp = freshTmp(ctx)
  insns.add(
    NICmp(
      dest = cmp,
      pred = IEq,
      ty = NI32,
      a = NLocal(name = disc),
      b = NLitInt(v = intToLong(cref.caseIdx), ty = NI32)
    )
  )
  val ci = ui.cases[cref.caseIdx]
  if subpats.count == 0 {
    insns.add(NCondBr(cond = NLocal(name = cmp), thenLabel = okLabel, elseLabel = failLabel))
    return
  }
  if subpats.count != ci.fieldNames.count {
    panic(
      "Lyric.LlvmCodegen: constructor pattern '" + joined + "' has " + subpats.count.toString() +
        " sub-patterns but the case declares " +
        ci.fieldNames.count.toString() +
        " fields"
    )
  }
  // Field loads live in a dedicated block so they only run when the
  // discriminant matched.
  val fieldsL = freshLabel(ctx, "match.fields")
  insns.add(NCondBr(cond = NLocal(name = cmp), thenLabel = fieldsL, elseLabel = failLabel))
  insns.add(NLabel(name = fieldsL))
  val objName = match sv.value {
    case NLocal(n) -> n
    case _ -> panic("Lyric.LlvmCodegen: union scrutinee must be a local value")
  }
  val casePtr = emitCasePayloadPtr(ctx, insns, ui, structTy, objName, cref.caseIdx)
  val caseTy = casePayloadStructType(ui, ci)
  var fi = 0
  // Sub-patterns test in order; scalar/binding sub-patterns chain
  // within this block against the loaded field values.
  val fieldVals: List[NVal] = newList()
  while fi < ci.fieldNames.count {
    // A Unit field has no stored data (layoutFieldTys) — its value is
    // the Unit value itself.
    if isVoidNType(ci.fieldTys[fi]) {
      fieldVals.add(NVal(ty = NVoid, value = NUndef(ty = NVoid)))
      fi = fi + 1
      continue
    }
    val fieldPtr = freshTmp(ctx)
    val fArgs: List[NArg] = newList()
    fArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
    fArgs.add(NArg(ty = NI32, value = NLitInt(v = intToLong(fi), ty = NI32)))
    insns.add(NGEP(dest = fieldPtr, ty = caseTy, ptr = NLocal(name = casePtr), indices = fArgs))
    val fieldVal = freshTmp(ctx)
    insns.add(NLoad(dest = fieldVal, ty = ci.fieldTys[fi], ptr = NLocal(name = fieldPtr)))
    fieldVals.add(NVal(ty = ci.fieldTys[fi], value = NLocal(name = fieldVal)))
    fi = fi + 1
  }
  var pi = 0
  while pi < subpats.count {
    val sub = stripPattern(subpats[pi])
    val isLast = pi == subpats.count - 1
    val nextL = if isLast { okLabel } else { freshLabel(ctx, "match.sub") }
    match sub.kind {
      case PWildcard -> {
        if isLast {
          insns.add(NBr(label = okLabel))
        }
      }
      case PBinding(name, inner) -> {
        match inner {
          case Some(_) -> panic("Lyric.LlvmCodegen: nested binding patterns are not yet supported for --target native")
          case None -> {
            bindNames.add(name)
            bindVals.add(fieldVals[pi])
            if isLast {
              insns.add(NBr(label = okLabel))
            }
          }
        }
      }
      case _ -> {
        emitPatternTest(ctx, insns, fieldVals[pi], sub, nextL, failLabel, bindNames, bindVals)
        if not isLast {
          insns.add(NLabel(name = nextL))
        }
      }
    }
    pi = pi + 1
  }
}

/// Lower a `match` expression (value or statement position).  Arms test
/// sequentially; a fall-through past every arm panics (the type checker
/// enforces exhaustiveness, so this is a compiled backstop, not a
/// user-facing path).
func lowerMatch(
  ctx: in Ctx,
  insns: in List[NInsn],
  scrutinee: in Expr,
  arms: in List[MatchArm],
  line: in Int,
  want: in Option[NType],
): NVal {
  if arms.count == 0 {
    panic("Lyric.LlvmCodegen: match with no arms")
  }
  val sv0 = lowerExpr(ctx, insns, scrutinee)
  // Pin the scrutinee into a named local so every arm block can address
  // it (also keeps it alive across arms via the enclosing temp scope).
  val sv = sv0
  val mergeL = freshLabel(ctx, "match.merge")
  var slotName = ""
  var slotTy = NVoid
  var ai = 0
  while ai < arms.count {
    val arm = arms[ai]
    val armBodyL = freshLabel(ctx, "match.body")
    val isLastArm = ai == arms.count - 1
    val nextL = if isLastArm { freshLabel(ctx, "match.nomatch") } else { freshLabel(ctx, "match.next") }
    val bindNames: List[String] = newList()
    val bindVals: List[NVal] = newList()
    // Guarded arms re-test into the guard block first.
    match arm.guard {
      case Some(g) -> {
        val guardL = freshLabel(ctx, "match.guard")
        emitPatternTest(ctx, insns, sv, arm.pattern, guardL, nextL, bindNames, bindVals)
        insns.add(NLabel(name = guardL))
        pushVarScope(ctx)
        applyPatternBinds(ctx, insns, bindNames, bindVals)
        pushTempScope(ctx)
        val gv = lowerExpr(ctx, insns, g)
        popTempScope(ctx, insns)
        // Guard bindings stay live for the body; release scope only on
        // the fail path.
        val failReleaseL = freshLabel(ctx, "match.guardfail")
        insns.add(NCondBr(cond = gv.value, thenLabel = armBodyL, elseLabel = failReleaseL))
        insns.add(NLabel(name = failReleaseL))
        releaseVarScopeAt(ctx, insns, ctx.scopeRefs.count - 1)
        insns.add(NBr(label = nextL))
        insns.add(NLabel(name = armBodyL))
        val armV = lowerArmBody(ctx, insns, arm, want)
        // Arm value protocol mirrors lowerIf's slot scheme.
        match armV.ty {
          case NVoid -> {
          }
          case vty -> {
            if slotName.length == 0 {
              slotName = "match.slot." + freshTmp(ctx)
              slotTy = vty
              ctx.allocas.add(NAlloca(dest = slotName, ty = vty))
            }
            val cv = coerceTo(ctx, insns, armV, slotTy)
            insns.add(NStore(ty = slotTy, value = cv.value, ptr = NLocal(name = slotName)))
          }
        }
        popVarScope(ctx, insns)
        insns.add(NBr(label = mergeL))
      }
      case None -> {
        emitPatternTest(ctx, insns, sv, arm.pattern, armBodyL, nextL, bindNames, bindVals)
        insns.add(NLabel(name = armBodyL))
        pushVarScope(ctx)
        applyPatternBinds(ctx, insns, bindNames, bindVals)
        val armV = lowerArmBody(ctx, insns, arm, want)
        match armV.ty {
          case NVoid -> {
          }
          case vty -> {
            if slotName.length == 0 {
              slotName = "match.slot." + freshTmp(ctx)
              slotTy = vty
              ctx.allocas.add(NAlloca(dest = slotName, ty = vty))
            }
            val cv = coerceTo(ctx, insns, armV, slotTy)
            insns.add(NStore(ty = slotTy, value = cv.value, ptr = NLocal(name = slotName)))
          }
        }
        popVarScope(ctx, insns)
        insns.add(NBr(label = mergeL))
      }
    }
    insns.add(NLabel(name = nextL))
    if isLastArm {
      emitPanicRaw(ctx, insns, "non-exhaustive match", line)
      insns.add(NBr(label = mergeL))
    }
    ai = ai + 1
  }
  insns.add(NLabel(name = mergeL))
  if slotName.length == 0 {
    return NVal(ty = NVoid, value = NUndef(ty = NVoid))
  }
  val dest = freshTmp(ctx)
  insns.add(NLoad(dest = dest, ty = slotTy, ptr = NLocal(name = slotName)))
  val outV = NVal(ty = slotTy, value = NLocal(name = dest))
  registerTemp(ctx, outV)
  outV
}

/// Destructure a tuple value into `val (a, b, _)`-style bindings.
func bindTuplePattern(ctx: in Ctx, insns: in List[NInsn], v: in NVal, patterns: in List[Pattern]): Unit {
  val ri = match recInfoOfType(ctx, v.ty) {
    case Some(r) -> r
    case None -> panic("Lyric.LlvmCodegen: tuple destructuring on a non-tuple value")
  }
  if patterns.count != ri.fieldNames.count {
    panic(
      "Lyric.LlvmCodegen: tuple pattern arity " + patterns.count.toString() + " does not match the value's arity " +
        ri.fieldNames.count.toString()
    )
  }
  var i = 0
  while i < patterns.count {
    val sub = stripPattern(patterns[i])
    match sub.kind {
      case PBinding(name, inner) -> {
        match inner {
          case Some(_) -> panic("Lyric.LlvmCodegen: nested binding patterns are not yet supported for --target native")
          case None -> {
            val fv = lowerRecordFieldLoad(ctx, insns, ri, v, ri.fieldNames[i])
            bindLocal(ctx, insns, name, fv)
          }
        }
      }
      case PWildcard -> {
      }
      case _ -> panic("Lyric.LlvmCodegen: only bindings and wildcards are supported inside tuple patterns for --target native")
    }
    i = i + 1
  }
}

/// Bind pattern names as arm-scoped locals.  Bindings borrow from the
/// scrutinee (alive for the whole match), so `bindLocal`'s
/// retain-borrow rule keeps ownership sound if the arm rebinds or the
/// body escapes the value.
func applyPatternBinds(ctx: in Ctx, insns: in List[NInsn], bindNames: in List[String], bindVals: in List[NVal]): Unit {
  var i = 0
  while i < bindNames.count {
    bindLocal(ctx, insns, bindNames[i], bindVals[i])
    i = i + 1
  }
}

/// Lower an arm body producing an OWNED value (ref results retained or
/// transferred before the arm's scopes unwind).
func lowerArmBody(ctx: in Ctx, insns: in List[NInsn], arm: in MatchArm, want: in Option[NType]): NVal {
  pushTempScope(ctx)
  val v = lowerExprOrBlockW(ctx, insns, arm.body, want)
  if isRefNType(v.ty) {
    ensureOwned(ctx, insns, v)
  }
  popTempScope(ctx, insns)
  v
}

// ─────────────────────────────────────────────────────────────────────────────
// §11. Control flow.
// ─────────────────────────────────────────────────────────────────────────────
func lowerExprOrBlock(ctx: in Ctx, insns: in List[NInsn], eob: in ExprOrBlock): NVal {
  val noWant: Option[NType] = None
  lowerExprOrBlockW(ctx, insns, eob, noWant)
}

/// Branch lowering with an optional expected type (threaded so generic
/// union cases in if/match arms resolve against the consumer's type).
func lowerExprOrBlockW(ctx: in Ctx, insns: in List[NInsn], eob: in ExprOrBlock, want: in Option[NType]): NVal {
  match eob {
    case EOBExpr(ex) -> {
      match want {
        case Some(w) -> lowerExprExpecting(ctx, insns, ex, w)
        case None -> lowerExpr(ctx, insns, ex)
      }
    }
    case EOBBlock(b) -> lowerBlockValueW(ctx, insns, b, want)
  }
}

func lowerIf(
  ctx: in Ctx,
  insns: in List[NInsn],
  cond: in Expr,
  thenBranch: in ExprOrBlock,
  elseBranch: in Option[ExprOrBlock],
  want: in Option[NType],
): NVal {
  val c = lowerExpr(ctx, insns, cond)
  val thenL = freshLabel(ctx, "if.then")
  val elseL = freshLabel(ctx, "if.else")
  val mergeL = freshLabel(ctx, "if.merge")
  // Value-producing if: both branches store into a shared temp slot;
  // the slot is typed after lowering the then-branch.  Ref-typed
  // results follow the value-region ARC protocol: each branch stores
  // an OWNED value (its temps released within the branch), and the
  // merged load re-registers as a single owned temp.
  match elseBranch {
    case Some(eb) -> {
      // Slot protocol mirrors lowerMatch: a branch producing NVoid in a
      // value context has diverged (panic / return — Never coerces to
      // anything in a well-typed program) and simply doesn't store; the
      // slot is typed by the first value-producing branch.
      insns.add(NCondBr(cond = c.value, thenLabel = thenL, elseLabel = elseL))
      insns.add(NLabel(name = thenL))
      var slotName = ""
      var slotTy = NVoid
      val thenInsns: List[NInsn] = newList()
      pushTempScope(ctx)
      val tv = lowerExprOrBlockW(ctx, thenInsns, thenBranch, want)
      match tv.ty {
        case NVoid -> {
          popTempScope(ctx, thenInsns)
          appendInsns(insns, thenInsns)
        }
        case vty -> {
          if isRefNType(vty) {
            ensureOwned(ctx, thenInsns, tv)
          }
          popTempScope(ctx, thenInsns)
          appendInsns(insns, thenInsns)
          slotName = "if.slot." + freshTmp(ctx)
          slotTy = vty
          ctx.allocas.add(NAlloca(dest = slotName, ty = vty))
          insns.add(NStore(ty = vty, value = tv.value, ptr = NLocal(name = slotName)))
        }
      }
      insns.add(NBr(label = mergeL))
      insns.add(NLabel(name = elseL))
      pushTempScope(ctx)
      val ev = lowerExprOrBlockW(ctx, insns, eb, want)
      match ev.ty {
        case NVoid -> popTempScope(ctx, insns)
        case ety -> {
          if slotName.length == 0 {
            slotName = "if.slot." + freshTmp(ctx)
            slotTy = ety
            ctx.allocas.add(NAlloca(dest = slotName, ty = ety))
          }
          val evc = coerceTo(ctx, insns, ev, slotTy)
          if isRefNType(slotTy) {
            ensureOwned(ctx, insns, evc)
          }
          popTempScope(ctx, insns)
          insns.add(NStore(ty = slotTy, value = evc.value, ptr = NLocal(name = slotName)))
        }
      }
      insns.add(NBr(label = mergeL))
      insns.add(NLabel(name = mergeL))
      if slotName.length == 0 {
        return NVal(ty = NVoid, value = NUndef(ty = NVoid))
      }
      val dest = freshTmp(ctx)
      insns.add(NLoad(dest = dest, ty = slotTy, ptr = NLocal(name = slotName)))
      val outV = NVal(ty = slotTy, value = NLocal(name = dest))
      registerTemp(ctx, outV)
      outV
    }
    case None -> {
      insns.add(NCondBr(cond = c.value, thenLabel = thenL, elseLabel = mergeL))
      insns.add(NLabel(name = thenL))
      pushTempScope(ctx)
      val tv = lowerExprOrBlock(ctx, insns, thenBranch)
      val _ = tv
      popTempScope(ctx, insns)
      insns.add(NBr(label = mergeL))
      insns.add(NLabel(name = mergeL))
      NVal(ty = NVoid, value = NUndef(ty = NVoid))
    }
  }
}

func appendInsns(dest: in List[NInsn], src: in List[NInsn]): Unit {
  var i = 0
  while i < src.count {
    dest.add(src[i])
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §12. Statements and blocks.
// ─────────────────────────────────────────────────────────────────────────────
func lowerStmt(ctx: in Ctx, insns: in List[NInsn], stmt: in Statement): Unit {
  match stmt.kind {
    case SLocal(binding) -> {
      match binding {
        case LBVal(pat, tyOpt, init) -> {
          val v = match tyOpt {
            case Some(te) -> lowerExprExpecting(ctx, insns, init, typeToN(ctx, te))
            case None -> lowerExpr(ctx, insns, init)
          }
          match pat.kind {
            case PBinding(name, inner) -> {
              match inner {
                case Some(_) -> panic("Lyric.LlvmCodegen: nested binding patterns are not yet supported for --target native")
                case None -> bindLocal(ctx, insns, name, v)
              }
            }
            case PWildcard -> {
            }
            case PTuple(patterns) -> bindTuplePattern(ctx, insns, v, patterns)
            case _ -> panic("Lyric.LlvmCodegen: this destructuring val pattern is not yet supported for --target native")
          }
        }
        case LBLet(name, tyOpt, init) -> {
          val v = match tyOpt {
            case Some(te) -> lowerExprExpecting(ctx, insns, init, typeToN(ctx, te))
            case None -> lowerExpr(ctx, insns, init)
          }
          bindLocal(ctx, insns, name, v)
        }
        case LBVar(name, tyOpt, initOpt) -> {
          match initOpt {
            case Some(init) -> {
              val v = match tyOpt {
                case Some(te) -> lowerExprExpecting(ctx, insns, init, typeToN(ctx, te))
                case None -> lowerExpr(ctx, insns, init)
              }
              bindLocal(ctx, insns, name, v)
            }
            case None -> {
              match tyOpt {
                case Some(te) -> {
                  val ty = typeToN(ctx, te)
                  val zero = zeroValueOf(ty)
                  bindLocal(ctx, insns, name, NVal(ty = ty, value = zero))
                }
                case None -> panic("Lyric.LlvmCodegen: 'var' without initializer needs a type annotation")
              }
            }
          }
        }
      }
    }
    case SAssign(target, op, value) -> lowerAssign(ctx, insns, target, op, value, stmt.span.startPos.line)
    case SReturn(valOpt) -> {
      match valOpt {
        case Some(v) -> {
          match ctx.curRet[0] {
            case NVoid -> {
              val _ = lowerExpr(ctx, insns, v)
              releaseAllForReturn(ctx, insns)
              insns.add(NRetVoid)
            }
            case rt -> {
              val cv = lowerExprExpecting(ctx, insns, v, rt)
              // Rule 6: return transfers ownership — owned temps move
              // out unregistered; borrows retain before the scope
              // releases below.
              if isRefNType(rt) {
                ensureOwned(ctx, insns, cv)
              }
              releaseAllForReturn(ctx, insns)
              insns.add(NRet(ty = rt, value = cv.value))
            }
          }
        }
        case None -> {
          releaseAllForReturn(ctx, insns)
          insns.add(NRetVoid)
        }
      }
      insns.add(NLabel(name = freshLabel(ctx, "dead")))
    }
    case SBreak(label) -> {
      match label {
        case Some(_) -> panic("Lyric.LlvmCodegen: labeled break is not yet supported for --target native")
        case None -> {
        }
      }
      if ctx.loopBreak.count == 0 {
        panic("Lyric.LlvmCodegen: 'break' outside a loop")
      }
      releaseForLoopExit(ctx, insns)
      insns.add(NBr(label = ctx.loopBreak[ctx.loopBreak.count - 1]))
      insns.add(NLabel(name = freshLabel(ctx, "dead")))
    }
    case SContinue(label) -> {
      match label {
        case Some(_) -> panic("Lyric.LlvmCodegen: labeled continue is not yet supported for --target native")
        case None -> {
        }
      }
      if ctx.loopCont.count == 0 {
        panic("Lyric.LlvmCodegen: 'continue' outside a loop")
      }
      releaseForLoopExit(ctx, insns)
      insns.add(NBr(label = ctx.loopCont[ctx.loopCont.count - 1]))
      insns.add(NLabel(name = freshLabel(ctx, "dead")))
    }
    case SWhile(label, cond, body) -> {
      match label {
        case Some(_) -> panic("Lyric.LlvmCodegen: labeled while is not yet supported for --target native")
        case None -> {
        }
      }
      val condL = freshLabel(ctx, "while.cond")
      val bodyL = freshLabel(ctx, "while.body")
      val exitL = freshLabel(ctx, "while.exit")
      insns.add(NBr(label = condL))
      insns.add(NLabel(name = condL))
      // Cond temps release before the branch (the cond value is scalar).
      pushTempScope(ctx)
      val c = lowerExpr(ctx, insns, cond)
      popTempScope(ctx, insns)
      insns.add(NCondBr(cond = c.value, thenLabel = bodyL, elseLabel = exitL))
      insns.add(NLabel(name = bodyL))
      ctx.loopBreak.add(exitL)
      ctx.loopCont.add(condL)
      ctx.loopVarDepth.add(ctx.scopeRefs.count)
      ctx.loopTempDepth.add(ctx.tempScopes.count)
      lowerBlockStmts(ctx, insns, body)
      ctx.loopBreak.removeAt(ctx.loopBreak.count - 1)
      ctx.loopCont.removeAt(ctx.loopCont.count - 1)
      ctx.loopVarDepth.removeAt(ctx.loopVarDepth.count - 1)
      ctx.loopTempDepth.removeAt(ctx.loopTempDepth.count - 1)
      insns.add(NBr(label = condL))
      insns.add(NLabel(name = exitL))
    }
    case SExpr(ex) -> {
      val _ = lowerExpr(ctx, insns, ex)
    }
    case SFor(label, pat, iter, body) -> {
      match label {
        case Some(_) -> panic("Lyric.LlvmCodegen: labeled for is not yet supported for --target native")
        case None -> {
        }
      }
      lowerForOverList(ctx, insns, pat, iter, body)
    }
    case SLoop(_, _) -> panic("Lyric.LlvmCodegen: 'loop' is not yet supported for --target native (use 'while true')")
    case SThrow(_) -> panic("Lyric.LlvmCodegen: 'throw' is not supported for --target native (D-N-003: panics abort)")
    case STry(_, _, _) -> panic("Lyric.LlvmCodegen: try/catch is not supported for --target native (D-N-003: no unwinding)")
    case SDefer(body) -> {
      // P2.D1: register `body` in the innermost lexical scope's defer
      // list; it runs at that scope's exit (fall-off, return, break, or
      // continue) via `runDeferredScopeAt`, not inline here. Note:
      // D-N-003 still applies — a `panic` aborts the process immediately
      // with no unwinding, so a `defer` registered before a `panic`
      // further down the SAME function does not run (there is no scope
      // exit to trigger it; only dotnet/jvm's real exception unwinding
      // runs a `defer` during a panic).
      ctx.deferStack[ctx.deferStack.count - 1].add(body)
    }
    case SInvariant(_) -> {
      // Loop invariants are proof obligations (lyric prove); they carry
      // no runtime lowering here.
    }
    case _ -> panic("Lyric.LlvmCodegen: this statement form is not yet supported for --target native (Phase N1)")
  }
}

func zeroValueOf(ty: in NType): NValue {
  match ty {
    case NDouble -> NLitFloat(v = 0.0)
    case NPtr(pointee) -> NLitNull(ty = NPtr(pointee = pointee))
    case _ -> NLitInt(v = 0i64, ty = ty)
  }
}

// The assignable local behind an assignment target (split out of
// `lowerAssign` in return style: the self-hosted MSIL emitter
// miscompiles a value-position if/else whose other branch panics,
// #4625).
func assignTargetName(target: in Expr): String {
  match target.kind {
    case EPath(path) -> {
      if path.segments.count == 1 {
        return path.segments[0]
      }
      panic("Lyric.LlvmCodegen: assignment to a qualified path is not yet supported for --target native")
    }
    case _ -> panic("Lyric.LlvmCodegen: assignment to this target form is not yet supported for --target native (fields are Phase N2)")
  }
}

func lowerAssign(
  ctx: in Ctx, insns: in List[NInsn], target: in Expr, op: in AssignOp, value: in Expr, line: in Int
): Unit {
  match target.kind {
    case EMember(recv, fieldName) -> {
      lowerFieldAssign(ctx, insns, recv, fieldName, op, value, line)
      return
    }
    case _ -> {
    }
  }
  val name = assignTargetName(target)
  val ty = match mapGet(ctx.varTypes, name) {
    case Some(t) -> t
    case None -> panic("Lyric.LlvmCodegen: assignment to unknown variable '" + name + "'")
  }
  val slot = match mapGet(ctx.varSlots, name) {
    case Some(s) -> s
    case None -> panic("Lyric.LlvmCodegen: no storage slot for '" + name + "'")
  }
  val newVal = match op {
    case AssEq -> lowerExprExpecting(ctx, insns, value, ty)
    case _ -> {
      val rhs = lowerExpr(ctx, insns, value)
      val curDest = freshTmp(ctx)
      insns.add(NLoad(dest = curDest, ty = ty, ptr = NLocal(name = slot)))
      val cur = NVal(ty = ty, value = NLocal(name = curDest))
      val binOp = match op {
        case AssPlus -> BAdd
        case AssMinus -> BSub
        case AssStar -> BMul
        case AssSlash -> BDiv
        case AssPercent -> BMod
        case AssEq -> BAdd
      }
      if isStringNType(ty) {
        lowerStringBinop(ctx, insns, binOp, cur, coerceTo(ctx, insns, rhs, ty))
      } else {
        val rhsC = coerceTo(ctx, insns, rhs, ty)
        match ty {
          case NDouble -> binFloatOp(ctx, insns, binOp, cur.value, rhsC.value)
          case _ -> binIntOp(ctx, insns, binOp, ty, cur.value, rhsC.value, line)
        }
      }
    }
  }
  if isRefNType(ty) {
    // ARC Rule 3: retain-new-before-release-old (self-assignment safe).
    ensureOwned(ctx, insns, newVal)
    val oldDest = freshTmp(ctx)
    insns.add(NLoad(dest = oldDest, ty = ty, ptr = NLocal(name = slot)))
    insns.add(NStore(ty = ty, value = newVal.value, ptr = NLocal(name = slot)))
    emitRelease(ctx, insns, NVal(ty = ty, value = NLocal(name = oldDest)))
    return
  }
  insns.add(NStore(ty = ty, value = newVal.value, ptr = NLocal(name = slot)))
}

/// `obj.field = v` / `obj.field op= v` (ARC Rule 3 for ref fields).
func lowerFieldAssign(
  ctx: in Ctx,
  insns: in List[NInsn],
  recv: in Expr,
  fieldName: in String,
  op: in AssignOp,
  value: in Expr,
  line: in Int,
): Unit {
  val obj = lowerExpr(ctx, insns, recv)
  val ri = match recInfoOfType(ctx, obj.ty) {
    case Some(r) -> r
    case None -> panic("Lyric.LlvmCodegen: assignment target '." + fieldName + "' is not a record field")
  }
  val idx = recFieldIndex(ri, fieldName)
  if idx < 0 {
    panic("Lyric.LlvmCodegen: record '" + ri.irName + "' has no field '" + fieldName + "'")
  }
  val fieldTy = ri.fieldTys[idx]
  val structTy = match obj.ty { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  val fieldPtr = freshTmp(ctx)
  val fArgs: List[NArg] = newList()
  fArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  fArgs.add(NArg(ty = NI32, value = NLitInt(v = intToLong(2 + idx), ty = NI32)))
  insns.add(NGEP(dest = fieldPtr, ty = structTy, ptr = obj.value, indices = fArgs))
  val newVal = match op {
    case AssEq -> lowerExprExpecting(ctx, insns, value, fieldTy)
    case _ -> {
      val rhs = lowerExpr(ctx, insns, value)
      val curDest = freshTmp(ctx)
      insns.add(NLoad(dest = curDest, ty = fieldTy, ptr = NLocal(name = fieldPtr)))
      val cur = NVal(ty = fieldTy, value = NLocal(name = curDest))
      val binOp = match op {
        case AssPlus -> BAdd
        case AssMinus -> BSub
        case AssStar -> BMul
        case AssSlash -> BDiv
        case AssPercent -> BMod
        case AssEq -> BAdd
      }
      if isStringNType(fieldTy) {
        lowerStringBinop(ctx, insns, binOp, cur, coerceTo(ctx, insns, rhs, fieldTy))
      } else {
        val rhsC = coerceTo(ctx, insns, rhs, fieldTy)
        match fieldTy {
          case NDouble -> binFloatOp(ctx, insns, binOp, cur.value, rhsC.value)
          case _ -> binIntOp(ctx, insns, binOp, fieldTy, cur.value, rhsC.value, line)
        }
      }
    }
  }
  if isRefNType(fieldTy) {
    // The field slot owns its value: retain the incoming value (or
    // transfer an owned temp), then release what the slot held.
    ensureOwned(ctx, insns, newVal)
    val oldDest = freshTmp(ctx)
    insns.add(NLoad(dest = oldDest, ty = fieldTy, ptr = NLocal(name = fieldPtr)))
    insns.add(NStore(ty = fieldTy, value = newVal.value, ptr = NLocal(name = fieldPtr)))
    emitRelease(ctx, insns, NVal(ty = fieldTy, value = NLocal(name = oldDest)))
    return
  }
  insns.add(NStore(ty = fieldTy, value = newVal.value, ptr = NLocal(name = fieldPtr)))
}

/// One statement, with its own temp-release region.
func lowerStmtScoped(ctx: in Ctx, insns: in List[NInsn], stmt: in Statement): Unit {
  pushTempScope(ctx)
  lowerStmt(ctx, insns, stmt)
  popTempScope(ctx, insns)
}

func lowerBlockStmts(ctx: in Ctx, insns: in List[NInsn], block: in Block): Unit {
  pushVarScope(ctx)
  var i = 0
  while i < block.statements.count {
    lowerStmtScoped(ctx, insns, block.statements[i])
    i = i + 1
  }
  popVarScope(ctx, insns)
}

/// Lower a block in value position: every statement runs, and a trailing
/// expression statement supplies the block's value.  A ref-typed value
/// leaves the block OWNED (retained if it borrowed from a block-local),
/// registered as a temp in the enclosing region.
func lowerBlockValue(ctx: in Ctx, insns: in List[NInsn], block: in Block): NVal {
  val noWant: Option[NType] = None
  lowerBlockValueW(ctx, insns, block, noWant)
}

func lowerBlockValueW(ctx: in Ctx, insns: in List[NInsn], block: in Block, want: in Option[NType]): NVal {
  if block.statements.count == 0 {
    return NVal(ty = NVoid, value = NUndef(ty = NVoid))
  }
  pushVarScope(ctx)
  var i = 0
  while i < block.statements.count - 1 {
    lowerStmtScoped(ctx, insns, block.statements[i])
    i = i + 1
  }
  val last = block.statements[block.statements.count - 1]
  // var-mutation shape: the stage-0 seed cannot compile this arm's
  // statement sequence in a value-position match (the #4631 family of
  // stage-0 lowering gaps).
  var outV = NVal(ty = NVoid, value = NUndef(ty = NVoid))
  match last.kind {
    case SExpr(ex) -> {
      pushTempScope(ctx)
      val v = match want { case Some(w) -> lowerExprExpecting(ctx, insns, ex, w); case None -> lowerExpr(ctx, insns, ex) }
      if isRefNType(v.ty) {
        ensureOwned(ctx, insns, v)
      }
      popTempScope(ctx, insns)
      outV = v
    }
    case _ -> {
      lowerStmtScoped(ctx, insns, last)
    }
  }
  popVarScope(ctx, insns)
  registerTemp(ctx, outV)
  outV
}

// ─────────────────────────────────────────────────────────────────────────────
// §13. Function lowering and the package entry point.
// ─────────────────────────────────────────────────────────────────────────────
/// A fresh per-function view over the module-wide ctx: tickers,
/// globals, and the signature registry are shared (same underlying
/// lists/maps); variable scope, alloca hoisting, and loop stacks start
/// empty.
func freshFnCtx(mod: in Ctx, pkg: in String, retTy: in NType): Ctx {
  val slots: Map[String, String] = newMap()
  val types: Map[String, NType] = newMap()
  val curPkg: List[String] = newList()
  curPkg.add(pkg)
  val curRet: List[NType] = newList()
  curRet.add(retTy)
  Ctx(
    mainPkg = mod.mainPkg,
    tmpTicker = mod.tmpTicker,
    labelTicker = mod.labelTicker,
    strTicker = mod.strTicker,
    varSlots = slots,
    varTypes = types,
    allocas = newList(),
    loopBreak = newList(),
    loopCont = newList(),
    globals = mod.globals,
    sigs = mod.sigs,
    curPkg = curPkg,
    curRet = curRet,
    recordDefs = mod.recordDefs,
    unionDefs = mod.unionDefs,
    caseRefs = mod.caseRefs,
    enumDefs = mod.enumDefs,
    distinctDefs = mod.distinctDefs,
    genericRecordDefs = mod.genericRecordDefs,
    genericUnionDefs = mod.genericUnionDefs,
    genericDeclPkg = mod.genericDeclPkg,
    caseToGenericUnion = mod.caseToGenericUnion,
    moduleTypeDefs = mod.moduleTypeDefs,
    moduleFns = mod.moduleFns,
    genericFnDefs = mod.genericFnDefs,
    genericFnPkg = mod.genericFnPkg,
    fnInstCache = mod.fnInstCache,
    instMeta = mod.instMeta,
    fnTyEnvNames = newList(),
    fnTyEnvTys = newList(),
    closureSigs = mod.closureSigs,
    trampolines = mod.trampolines,
    weakTargets = mod.weakTargets,
    listElems = mod.listElems,
    mapKeyTys = mod.mapKeyTys,
    mapValTys = mod.mapValTys,
    ifaceInfos = mod.ifaceInfos,
    ifaceVtables = mod.ifaceVtables,
    protectedRecNames = mod.protectedRecNames,
    scopeRefs = newList(),
    tempScopes = newList(),
    loopVarDepth = newList(),
    loopTempDepth = newList(),
    deferStack = newList()
  )
}

func lowerFunction(modCtx: in Ctx, pkg: in String, fn: in FunctionDecl, irName: in String): NFunc {
  val noNames: List[String] = newList()
  val noTys: List[NType] = newList()
  lowerFunctionEnv(modCtx, pkg, fn, irName, noNames, noTys)
}

// ─────────────────────────────────────────────────────────────────────────────
// Async generator detection (D-N-019).  A native-local mirror of the type
// checker's `funcBodyContainsYield`/`exprContainsYield`/`blockContainsYield`
// (`typechecker_checker.l`) — the backend packages don't import
// `Lyric.TypeChecker` (msil/jvm each keep their own copy too), so this walks
// the same shared parser AST independently to flag the one async shape this
// slice does not lower: a `yield` anywhere inside an `async func` body.
// ─────────────────────────────────────────────────────────────────────────────
func funcBodyContainsYieldNative(fn: in FunctionDecl): Bool {
  match fn.body {
    case None -> false
    case Some(body) -> match body { case FBExpr(e) -> exprContainsYieldNative(e); case FBBlock(b) -> blockContainsYieldNative(b) }
  }
}

func exprContainsYieldNative(e: in Expr): Bool {
  match e.kind {
    case EYield(_) -> true
    case ELambda(_, _) -> false
    // yield inside a lambda is not a generator yield
    case ELiteral(_) -> false
    case EPath(_) -> false
    case ESelf -> false
    case EResult -> false
    case EError -> false
    case EParen(inner) -> exprContainsYieldNative(inner)
    case EAwait(inner) -> exprContainsYieldNative(inner)
    case ESpawn(inner) -> exprContainsYieldNative(inner)
    case EOld(inner) -> exprContainsYieldNative(inner)
    case EPropagate(inner) -> exprContainsYieldNative(inner)
    case ETry(inner) -> exprContainsYieldNative(inner)
    case EPrefix(_, inner) -> exprContainsYieldNative(inner)
    case ETuple(elems) -> listAnyExprContainsYieldNative(elems)
    case EList(elems) -> listAnyExprContainsYieldNative(elems)
    case EInterpolated(segs) -> {
      var found = false
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISExpr(se) -> {
            if exprContainsYieldNative(se) {
              found = true
            }
          }
          case ISText(_) -> {
          }
        }
        i = i + 1
      }
      found
    }
    case EBinop(_, l, r) -> exprContainsYieldNative(l) or exprContainsYieldNative(r)
    case EAssign(t, _, v) -> exprContainsYieldNative(t) or exprContainsYieldNative(v)
    case EMember(recv, _) -> exprContainsYieldNative(recv)
    case ETypeApp(f, _) -> exprContainsYieldNative(f)
    case EIndex(recv, idxs) -> exprContainsYieldNative(recv) or listAnyExprContainsYieldNative(idxs)
    case ECall(f, args) -> {
      if exprContainsYieldNative(f) {
        return true
      }
      var i = 0
      while i < args.count {
        val found = match args[i] {
          case CAPositional(v) -> exprContainsYieldNative(v)
          case CANamed(_, v, _) -> exprContainsYieldNative(v)
        }
        if found {
          return true
        }
        i = i + 1
      }
      false
    }
    case ERange(rb) -> match rb { case RBClosed(a, b) -> exprContainsYieldNative(a) or exprContainsYieldNative(b); case RBHalfOpen(a, b) -> exprContainsYieldNative(a) or exprContainsYieldNative(b); case RBLowerOpen(a) -> exprContainsYieldNative(a); case RBUpperOpen(a) -> exprContainsYieldNative(a) }
    case EIf(c, t, eOpt, _) -> {
      if exprContainsYieldNative(c) {
        return true
      }
      val inT = match t {
        case EOBExpr(te) -> exprContainsYieldNative(te)
        case EOBBlock(tb) -> blockContainsYieldNative(tb)
      }
      if inT {
        return true
      }
      match eOpt {
        case None -> false
        case Some(b) -> match b { case EOBExpr(ee) -> exprContainsYieldNative(ee); case EOBBlock(eb) -> blockContainsYieldNative(eb) }
      }
    }
    case EMatch(subj, arms) -> {
      if exprContainsYieldNative(subj) {
        return true
      }
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        val inGuard = match arm.guard { case None -> false; case Some(g) -> exprContainsYieldNative(g) }
        if inGuard {
          return true
        }
        val inBody = match arm.body {
          case EOBExpr(ae) -> exprContainsYieldNative(ae)
          case EOBBlock(ab) -> blockContainsYieldNative(ab)
        }
        if inBody {
          return true
        }
        i = i + 1
      }
      false
    }
    case EBlock(blk) -> blockContainsYieldNative(blk)
    case EUnsafe(blk) -> blockContainsYieldNative(blk)
    case EForall(_, w, body) -> {
      val inW = match w { case None -> false; case Some(we) -> exprContainsYieldNative(we) }
      inW or exprContainsYieldNative(body)
    }
    case EExists(_, w, body) -> {
      val inW = match w { case None -> false; case Some(we) -> exprContainsYieldNative(we) }
      inW or exprContainsYieldNative(body)
    }
  }
}

func listAnyExprContainsYieldNative(es: in List[Expr]): Bool {
  var i = 0
  while i < es.count {
    if exprContainsYieldNative(es[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func blockContainsYieldNative(blk: in Block): Bool {
  var i = 0
  while i < blk.statements.count {
    if stmtContainsYieldNative(blk.statements[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func stmtContainsYieldNative(stmt: in Statement): Bool {
  match stmt.kind {
    case SExpr(e) -> exprContainsYieldNative(e)
    case SThrow(e) -> exprContainsYieldNative(e)
    case SReturn(Some(e)) -> exprContainsYieldNative(e)
    case SReturn(None) -> false
    case SBreak(_) -> false
    case SContinue(_) -> false
    case SInvariant(_) -> false
    case SItem(_) -> false
    case SAssign(t, _, v) -> exprContainsYieldNative(t) or exprContainsYieldNative(v)
    case SLocal(binding) -> match binding { case LBVal(_, _, e) -> exprContainsYieldNative(e); case LBLet(_, _, e) -> exprContainsYieldNative(e); case LBVar(_, _, Some(e)) -> exprContainsYieldNative(e); case LBVar(_, _, None) -> false }
    case STry(body, catches, finally_) -> {
      if blockContainsYieldNative(body) {
        return true
      }
      var i = 0
      while i < catches.count {
        if blockContainsYieldNative(catches[i].body) {
          return true
        }
        i = i + 1
      }
      match finally_ {
        case None -> false
        case Some(fb) -> blockContainsYieldNative(fb)
      }
    }
    case SDefer(b) -> blockContainsYieldNative(b)
    case SScope(_, b) -> blockContainsYieldNative(b)
    case SLoop(_, b) -> blockContainsYieldNative(b)
    case SFor(_, _, iter, body) -> exprContainsYieldNative(iter) or blockContainsYieldNative(body)
    case SWhile(_, cond, body) -> exprContainsYieldNative(cond) or blockContainsYieldNative(body)
    case SRule(l, r) -> exprContainsYieldNative(l) or exprContainsYieldNative(r)
  }
}

/// Lower one function body; a non-empty type env lowers a generic
/// declaration as one concrete instantiation (N3.1).
func lowerFunctionEnv(
  modCtx: in Ctx,
  pkg: in String,
  fn: in FunctionDecl,
  irName: in String,
  envNames: in List[String],
  envTys: in List[NType],
): NFunc {
  if fn.isAsync and funcBodyContainsYieldNative(fn) {
    panic(
      "N0099: async generators ('yield' inside an 'async func') are not yet supported for --target native. Use --target dotnet or --target jvm for async generators."
    )
  }
  if isGenericFn(fn) and envNames.count == 0 {
    panic("Lyric.LlvmCodegen: un-monomorphized generic function '" + fn.name + "' reached the native backend")
  }
  val ctx0 = freshFnCtx(modCtx, pkg, NVoid)
  var ei = 0
  while ei < envNames.count {
    ctx0.fnTyEnvNames.add(envNames[ei])
    ctx0.fnTyEnvTys.add(envTys[ei])
    ei = ei + 1
  }
  val retTy = retTypeToN(ctx0, fn.ret)
  ctx0.curRet.removeAt(0)
  ctx0.curRet.add(retTy)
  val ctx = ctx0
  val params: List[NParam] = newList()
  val body: List[NInsn] = newList()
  // Parameters land in allocas so `var`-style reads/writes and address
  // uniformity hold; mem2reg cleans this up at -O1+.  `in` params are
  // ARC borrows (Rule 5): never retained on entry or released on exit.
  var pi = 0
  while pi < fn.params.count {
    val p = fn.params[pi]
    match p.mode {
      case PMIn -> {
      }
      case _ -> panic("Lyric.LlvmCodegen: out/inout parameters are not yet supported for --target native")
    }
    val pty = typeToN(ctx, p.ty)
    params.add(NParam(name = "arg." + p.name, ty = pty))
    match pty {
      case NVoid -> {
        ctx.varTypes.add(p.name, NVoid)
      }
      case _ -> {
        val slot = p.name + ".slot." + freshTmp(ctx)
        ctx.allocas.add(NAlloca(dest = slot, ty = pty))
        body.add(NStore(ty = pty, value = NLocal(name = "arg." + p.name), ptr = NLocal(name = slot)))
        ctx.varSlots.add(p.name, slot)
        ctx.varTypes.add(p.name, pty)
      }
    }
    pi = pi + 1
  }
  pushVarScope(ctx)
  pushTempScope(ctx)
  val tailWant: Option[NType] = match retTy { case NVoid -> None; case rt -> Some(value = rt) }
  val tail = match fn.body {
    case Some(fb) -> {
      match fb {
        case FBExpr(ex) -> {
          match tailWant {
            case Some(w) -> lowerExprExpecting(ctx, body, ex, w)
            case None -> lowerExpr(ctx, body, ex)
          }
        }
        case FBBlock(b) -> lowerBlockValueW(ctx, body, b, tailWant)
      }
    }
    case None -> panic("Lyric.LlvmCodegen: function '" + fn.name + "' has no body")
  }
  // Fall-off return: yield the trailing value (or void).  Ref-typed
  // tails transfer out (Rule 6) before the function scopes unwind.
  match retTy {
    case NVoid -> {
      releaseAllForReturn(ctx, body)
      body.add(NRetVoid)
    }
    case rt -> {
      match tail.ty {
        case NVoid -> {
          // The body ended with a terminator-producing construct (e.g.
          // every path returned explicitly); emit an unreachable
          // fall-off return of the zero value to keep the block closed.
          releaseAllForReturn(ctx, body)
          body.add(NRet(ty = rt, value = zeroValueOf(rt)))
        }
        case _ -> {
          val cv = coerceTo(ctx, body, tail, rt)
          if isRefNType(rt) {
            ensureOwned(ctx, body, cv)
          }
          releaseAllForReturn(ctx, body)
          body.add(NRet(ty = rt, value = cv.value))
        }
      }
    }
  }
  // Assemble: entry label, hoisted allocas, then the body.
  val insns: List[NInsn] = newList()
  insns.add(NLabel(name = "entry"))
  appendInsns(insns, ctx.allocas)
  appendInsns(insns, body)
  val attrs: List[String] = newList()
  val isPub = match fn.visibility { case Some(_) -> true; case None -> pkg == ctx.mainPkg }
  NFunc(
    name = irName,
    params = params,
    retTy = retTy,
    isPublic = isPub,
    isExtern = false,
    body = insns,
    attributes = attrs
  )
}

/// The fixed lyric-rt declarations every module carries.
func runtimeDecls(): List[NFunc] {
  val decls: List[NFunc] = newList()
  val sTy = lyricStringNType()
  decls.add(mkDecl1("lyric_retain", NVoid, NPtr(pointee = NI8)))
  decls.add(mkDecl1("lyric_release", NVoid, NPtr(pointee = NI8)))
  decls.add(mkDecl1("lyric_alloc", NPtr(pointee = NI8), NI64))
  decls.add(mkDecl3("lyric_panic_msg", NVoid, NPtr(pointee = NI8), NPtr(pointee = NI8), NI32))
  decls.add(mkDecl2("lyric_string_concat", sTy, sTy, sTy))
  decls.add(mkDecl1("lyric_string_len", NI64, sTy))
  decls.add(mkDecl2("lyric_string_eq", NI32, sTy, sTy))
  decls.add(mkDecl2("lyric_string_cmp", NI32, sTy, sTy))
  decls.add(mkDecl1("lyric_string_from_int", sTy, NI64))
  decls.add(mkDecl1("lyric_string_from_float", sTy, NDouble))
  decls.add(mkDecl1("lyric_string_from_bool", sTy, NI32))
  decls.add(mkDecl1("lyric_string_from_char", sTy, NI32))
  decls.add(mkDecl3("lyric_string_substring", sTy, sTy, NI64, NI64))
  decls.add(mkDecl1("lyric_string_to_cstring", NPtr(pointee = NI8), sTy))
  decls.add(mkDecl1("lyric_cstring_free", NVoid, NPtr(pointee = NI8)))
  decls.add(mkDecl1("lyric_weak_upgrade", NPtr(pointee = NI8), NPtr(pointee = NI8)))
  val p8 = NPtr(pointee = NI8)
  decls.add(mkDecl1("lyric_list_new", p8, NI32))
  decls.add(mkDecl2("lyric_list_push", NVoid, p8, NI64))
  decls.add(mkDecl2("lyric_list_get", NI64, p8, NI64))
  decls.add(mkDecl3("lyric_list_set", NVoid, p8, NI64, NI64))
  decls.add(mkDecl2("lyric_list_remove_at", NVoid, p8, NI64))
  decls.add(mkDecl1("lyric_list_len", NI64, p8))
  decls.add(mkDecl1("lyric_list_clear", NVoid, p8))
  decls.add(mkDecl1("lyric_list_copy", p8, p8))
  decls.add(mkDecl2("lyric_args_set", NVoid, NI32, NPtr(pointee = p8)))
  decls.add(mkDecl2("lyric_map_new", p8, NI32, NI32))
  decls.add(mkDecl3("lyric_map_set", NVoid, p8, NI64, NI64))
  decls.add(mkDecl3("lyric_map_get", NI32, p8, NI64, NPtr(pointee = NI64)))
  decls.add(mkDecl2("lyric_map_contains", NI32, p8, NI64))
  decls.add(mkDecl2("lyric_map_remove", NI32, p8, NI64))
  decls.add(mkDecl1("lyric_map_len", NI64, p8))
  decls.add(mkDecl1("lyric_map_keys", p8, p8))
  decls.add(mkDecl1("lyric_map_values", p8, p8))
  // Protected-type mutex kernel (N3.4) + raw free for the runtime-sized
  // mutex buffer (D-N-017).  `lyric_mutex_size()` is nullary.
  val noArgs: List[NType] = newList()
  decls.add(mkDeclN("lyric_mutex_size", NI32, noArgs))
  decls.add(mkDecl1("lyric_mutex_init", NVoid, p8))
  decls.add(mkDecl1("lyric_mutex_lock", NVoid, p8))
  decls.add(mkDecl1("lyric_mutex_unlock", NVoid, p8))
  decls.add(mkDecl1("lyric_mutex_destroy", NVoid, p8))
  decls.add(mkDecl1("lyric_free", NVoid, p8))
  decls
}

func mkParamList(tys: in List[NType]): List[NParam] {
  val ps: List[NParam] = newList()
  var i = 0
  while i < tys.count {
    ps.add(NParam(name = "a" + i.toString(), ty = tys[i]))
    i = i + 1
  }
  ps
}

func mkDeclN(name: in String, ret: in NType, tys: in List[NType]): NFunc {
  val noBody: List[NInsn] = newList()
  val noAttrs: List[String] = newList()
  NFunc(
    name = name,
    params = mkParamList(tys),
    retTy = ret,
    isPublic = true,
    isExtern = true,
    body = noBody,
    attributes = noAttrs
  )
}

func mkDecl1(name: in String, ret: in NType, t0: in NType): NFunc {
  val tys: List[NType] = newList()
  tys.add(t0)
  mkDeclN(name, ret, tys)
}

func mkDecl2(name: in String, ret: in NType, t0: in NType, t1: in NType): NFunc {
  val tys: List[NType] = newList()
  tys.add(t0)
  tys.add(t1)
  mkDeclN(name, ret, tys)
}

func mkDecl3(name: in String, ret: in NType, t0: in NType, t1: in NType, t2: in NType): NFunc {
  val tys: List[NType] = newList()
  tys.add(t0)
  tys.add(t1)
  tys.add(t2)
  mkDeclN(name, ret, tys)
}

func externDeclOf(ctx: in Ctx, ef: in ExternFuncDecl): NFunc {
  val tys: List[NType] = newList()
  var i = 0
  while i < ef.params.count {
    // Function-typed params stay raw C function pointers (N4.5 — the
    // ctx-aware mapping would produce a closure struct); everything
    // else resolves through the registry so collection-typed extern
    // params/returns (slice/List/Map kernels, D-N-015) get the same
    // struct pointer type their call sites use.
    match ef.params[i].ty.kind {
      case TFunction(_, _) -> tys.add(typeExprToNType(ef.params[i].ty))
      case _ -> tys.add(typeToN(ctx, ef.params[i].ty))
    }
    i = i + 1
  }
  mkDeclN(ef.symbol, retTypeToN(ctx, ef.ret), tys)
}

/// Synthesise the C-ABI `main` wrapper around the user's `func main`.
func synthCMain(mainPkg: in String, userMainRet: in NType, userMainIr: in String): NFunc {
  val params: List[NParam] = newList()
  params.add(NParam(name = "argc", ty = NI32))
  params.add(NParam(name = "argv", ty = NPtr(pointee = NPtr(pointee = NI8))))
  val body: List[NInsn] = newList()
  body.add(NLabel(name = "entry"))
  // Capture argc/argv before Lyric main runs so Std.Environment.args()
  // can materialise them on demand (lyric_args_get).
  val argArgs: List[NArg] = newList()
  argArgs.add(NArg(ty = NI32, value = NLocal(name = "argc")))
  argArgs.add(NArg(ty = NPtr(pointee = NPtr(pointee = NI8)), value = NLocal(name = "argv")))
  body.add(NCallVoid(fn = NGlobal(name = "lyric_args_set"), args = argArgs))
  val noArgs: List[NArg] = newList()
  match userMainRet {
    case NI32 -> {
      body.add(NCall(dest = "code", retTy = NI32, fn = NGlobal(name = userMainIr), args = noArgs))
      body.add(NRet(ty = NI32, value = NLocal(name = "code")))
    }
    case NVoid -> {
      body.add(NCallVoid(fn = NGlobal(name = userMainIr), args = noArgs))
      body.add(NRet(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
    }
    case _ -> panic("Lyric.LlvmCodegen: `func main` must return Int or Unit for --target native")
  }
  val attrs: List[String] = newList()
  NFunc(
    name = "main",
    params = params,
    retTy = NI32,
    isPublic = true,
    isExtern = false,
    body = body,
    attributes = attrs
  )
}

/// Lower a bundle of packages into one native module.  `units[0]` must
/// be the user's main package (its functions are all lowered and its
/// `func main` becomes the process entry point); the remaining units
/// carry the reachable slices of bundled stdlib packages.
pub func codegenNativeBundle(units: in List[CodegenUnit], triple: in String): NPackage {
  if units.count == 0 {
    panic("Lyric.LlvmCodegen: empty compilation bundle")
  }
  val mainPkg = units[0].pkgName
  val sigs = buildSigs(units)
  val emptySlots: Map[String, String] = newMap()
  val emptyTypes: Map[String, NType] = newMap()
  val emptyRecs: Map[String, NRecInfo] = newMap()
  val emptyUnions: Map[String, NUnionInfo] = newMap()
  val emptyCases: Map[String, NCaseRef] = newMap()
  val emptyEnums: Map[String, Int] = newMap()
  val emptyDistincts: Map[String, NDistinctInfo] = newMap()
  val emptyGenRecs: Map[String, RecordDecl] = newMap()
  val emptyGenUnions: Map[String, UnionDecl] = newMap()
  val emptyGenPkg: Map[String, String] = newMap()
  val emptyCaseGen: Map[String, String] = newMap()
  val emptyGenFns: Map[String, FunctionDecl] = newMap()
  val emptyGenFnPkg: Map[String, String] = newMap()
  val emptyFnInsts: Map[String, NFnInst] = newMap()
  val emptyInstMeta: Map[String, NInstInfo] = newMap()
  val emptyClosureSigs: Map[String, NClosureSig] = newMap()
  val emptyWeakTargets: Map[String, NType] = newMap()
  val ctx = Ctx(
    mainPkg = mainPkg,
    tmpTicker = newList(),
    labelTicker = newList(),
    strTicker = newList(),
    varSlots = emptySlots,
    varTypes = emptyTypes,
    allocas = newList(),
    loopBreak = newList(),
    loopCont = newList(),
    globals = newList(),
    sigs = sigs,
    curPkg = newList(),
    curRet = newList(),
    recordDefs = emptyRecs,
    unionDefs = emptyUnions,
    caseRefs = emptyCases,
    enumDefs = emptyEnums,
    distinctDefs = emptyDistincts,
    genericRecordDefs = emptyGenRecs,
    genericUnionDefs = emptyGenUnions,
    genericDeclPkg = emptyGenPkg,
    caseToGenericUnion = emptyCaseGen,
    moduleTypeDefs = newList(),
    moduleFns = newList(),
    genericFnDefs = emptyGenFns,
    genericFnPkg = emptyGenFnPkg,
    fnInstCache = emptyFnInsts,
    instMeta = emptyInstMeta,
    fnTyEnvNames = newList(),
    fnTyEnvTys = newList(),
    closureSigs = emptyClosureSigs,
    trampolines = newMap(),
    weakTargets = emptyWeakTargets,
    listElems = newMap(),
    mapKeyTys = newMap(),
    mapValTys = newMap(),
    ifaceInfos = newMap(),
    ifaceVtables = newMap(),
    protectedRecNames = newMap(),
    scopeRefs = newList(),
    tempScopes = newList(),
    loopVarDepth = newList(),
    loopTempDepth = newList(),
    deferStack = newList()
  )
  // Type definitions and synthesised functions accumulate on the ctx so
  // lazy generic instantiation (typeToN during lowering) can append.
  val fns = ctx.moduleFns
  val types = ctx.moduleTypeDefs
  val sFields: List[NType] = newList()
  sFields.add(NI32)
  sFields.add(NPtr(pointee = NI8))
  sFields.add(NI64)
  sFields.add(NI64)
  types.add(NTypeDefn(name = "LyricString", fields = sFields))
  // Interface box-type names first, so a record with an interface-typed
  // field resolves the interface during layout (#4917); then records; then
  // interface method sigs + type defs (may reference records); then impl
  // vtables (reference registered records).
  registerInterfaceNames(ctx, units)
  registerHeapTypes(ctx, units, types, fns)
  registerInterfaceTypes(ctx, units, types, fns)
  registerImplVtables(ctx, units)
  registerProtectedMethods(ctx, units, fns)
  val externDecls: List[NFunc] = newList()
  val declaredExterns: Map[String, Bool] = newMap()
  var di = 0
  val rtDecls = runtimeDecls()
  while di < rtDecls.count {
    externDecls.add(rtDecls[di])
    declaredExterns.add(rtDecls[di].name, true)
    di = di + 1
  }
  var mainRet = NVoid
  var mainIr = ""
  var ui = 0
  while ui < units.count {
    val u = units[ui]
    var ei = 0
    while ei < u.externs.count {
      val ef = u.externs[ei]
      if not declaredExterns.containsKey(ef.symbol) {
        declaredExterns.add(ef.symbol, true)
        externDecls.add(externDeclOf(ctx, ef))
      }
      ei = ei + 1
    }
    var fi = 0
    while fi < u.fns.count {
      val fn = u.fns[fi]
      // Generic functions lower on demand, per call-site instantiation
      // (N3.1).
      if isGenericFn(fn) {
        fi = fi + 1
        continue
      }
      val key = u.pkgName + "." + fn.name + "/" + fn.params.count.toString()
      val irName = match mapGet(sigs, key) { case Some(s) -> s.irName; case None -> u.pkgName + "." + fn.name }
      fns.add(lowerFunction(ctx, u.pkgName, fn, irName))
      if ui == 0 and fn.name == "main" and fn.params.count == 0 {
        mainRet = retTypeToNType(fn.ret)
        mainIr = irName
      }
      fi = fi + 1
    }
    ui = ui + 1
  }
  if mainIr.length > 0 {
    fns.add(synthCMain(mainPkg, mainRet, mainIr))
  }
  val libs: List[String] = newList()
  NPackage(
    name = mainPkg,
    triple = triple,
    types = types,
    globals = ctx.globals,
    functions = fns,
    externDecls = externDecls,
    nativeLibs = libs
  )
}

/// Single-file convenience entry (self-tests, ad-hoc compiles): every
/// function in `file` is lowered; there are no bundled dependencies.
pub func codegenNativePackage(file: in SourceFile, triple: in String): NPackage {
  val units: List[CodegenUnit] = newList()
  units.add(unitOfFile(dottedPkgName(file), file))
  codegenNativeBundle(units, triple)
}

/// Collect one source file's lowerable items into a CodegenUnit.
pub func unitOfFile(pkgName: in String, file: in SourceFile): CodegenUnit {
  val fns: List[FunctionDecl] = newList()
  val externs: List[ExternFuncDecl] = newList()
  val records: List[RecordDecl] = newList()
  val unions: List[UnionDecl] = newList()
  val enums: List[EnumDecl] = newList()
  val distincts: List[DistinctTypeDecl] = newList()
  val interfaces: List[InterfaceDecl] = newList()
  val impls: List[ImplDecl] = newList()
  val protecteds: List[ProtectedTypeDecl] = newList()
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(decl) -> fns.add(decl)
      case IExternFunc(decl) -> externs.add(decl)
      case IRecord(decl) -> {
        records.add(decl)
        collectRecordMethods(pkgName, decl, fns)
      }
      case IUnion(decl) -> unions.add(decl)
      case IEnum(decl) -> enums.add(decl)
      case IDistinctType(decl) -> distincts.add(decl)
      case IInterface(decl) -> interfaces.add(decl)
      case IImpl(decl) -> {
        impls.add(decl)
        collectImplMethods(pkgName, decl, fns)
      }
      case IProtected(decl) -> {
        protecteds.add(decl)
        collectProtectedMethods(pkgName, decl, fns)
      }
      case ITypeAlias(_) -> {
      }
      case IExternType(_) -> {
      }
      case _ -> panic("Lyric.LlvmCodegen: this item form is not yet supported for --target native (Phase N2/N3 lowers functions, extern funcs, records, unions, enums, distinct types, interfaces, impls, and protected types)")
    }
    i = i + 1
  }
  CodegenUnit(
    pkgName = pkgName,
    fns = fns,
    externs = externs,
    records = records,
    unions = unions,
    enums = enums,
    distincts = distincts,
    interfaces = interfaces,
    impls = impls,
    protecteds = protecteds
  )
}

/// Methods declared inside a record body desugar to package functions
/// with the explicit `self` receiver already in their parameter list
/// (D037); non-generic ones lower like any other function.  The
/// parser's synthesised receiver is typed `Self` — substitute the
/// concrete record reference so the native type mapping resolves it.
pub func collectRecordMethods(pkgName: in String, decl: in RecordDecl, fns: in List[FunctionDecl]): Unit {
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMFunc(fn) -> {
        match decl.generics {
          case Some(_) -> {
          }
          case None -> {
            match fn.generics {
              case Some(_) -> {
              }
              case None -> fns.add(substSelfInFn(fn, decl.name))
            }
          }
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
}

func selfTypeRef(recordName: in String, span: in Span): TypeExpr {
  val segs: List[String] = newList()
  segs.add(recordName)
  TypeExpr(kind = TRef(path = ModulePath(segments = segs, span = span)), span = span)
}

func substSelfInType(te: in TypeExpr, recordName: in String): TypeExpr {
  match te.kind {
    case TSelf -> selfTypeRef(recordName, te.span)
    case TParen(inner) -> TypeExpr(kind = TParen(inner = substSelfInType(inner, recordName)), span = te.span)
    case _ -> te
  }
}

func substSelfInFn(fn: in FunctionDecl, recordName: in String): FunctionDecl {
  val newParams: List[Param] = newList()
  var i = 0
  while i < fn.params.count {
    val p = fn.params[i]
    newParams.add(
      Param(
        mode = p.mode,
        modeExplicit = p.modeExplicit,
        name = p.name,
        ty = substSelfInType(p.ty, recordName),
        dflt = p.dflt,
        annotations = p.annotations,
        span = p.span
      )
    )
    i = i + 1
  }
  // var-mutation shape (#4631).
  var newRet: Option[TypeExpr] = None
  match fn.ret {
    case Some(r) -> {
      newRet = Some(value = substSelfInType(r, recordName))
    }
    case None -> {
    }
  }
  FunctionDecl(
    docComments = fn.docComments,
    annotations = fn.annotations,
    visibility = fn.visibility,
    isAsync = fn.isAsync,
    name = fn.name,
    generics = fn.generics,
    params = newParams,
    ret = newRet,
    whereClause = fn.whereClause,
    contracts = fn.contracts,
    body = fn.body,
    span = fn.span
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// §N3.4  Protected types.
//
// A protected type lowers to the same record-shaped heap object as a plain
// record (`{ i32 rc, i8* dtor, ...user fields }`), plus one trailing
// `__mutex: i8*` field: a pointer to a separately lyric_alloc'd buffer sized
// at runtime via `lyric_mutex_size()` (LLVM structs are fixed-size, and the
// self-hosted compiler runs on .NET so it cannot call the target runtime's
// lyric_mutex_size() at codegen time — see the decision log, D-N-017).
// `ctx.protectedRecNames` marks which `recordDefs` entries need this
// treatment; `typeToN` / field access / construction otherwise reuse the
// exact record machinery unchanged (`self: in ProtectedType` resolves
// through `ctx.recordDefs` exactly like a record receiver).
//
// The language reference (§7.5) makes both `entry` and `func` members
// mutually exclusive (an Ada-style monitor); native has no built-in
// monitor primitive (unlike MSIL's `Monitor.Enter(this)`/try/finally or a
// JVM `ReentrantLock` field), so each member lowers to TWO functions:
//   - an "inner" function: the desugared body (bare field references
//     rewritten to `self.field`, mirroring the MSIL emitter's
//     `desugarProtectedFuncBody`), lowered through the normal
//     FunctionDecl -> NFunc pipeline like any record/impl method.
//   - a hand-built "wrapper" NFunc: GEP+load the mutex pointer, call
//     lyric_mutex_lock, call the inner function, call lyric_mutex_unlock,
//     return.  Native's statement lowering emits scattered NRet/NRetVoid
//     with no unified epilogue (no try/finally), so a single lock/unlock
//     pair around one call site — rather than one per return point —
//     needs the call boundary the wrapper/inner split provides.
// UFCS call sites (`x.increment()`) resolve to the wrapper: its NFuncSig is
// registered directly into `ctx.sigs` (bypassing `buildSigs`, since the
// wrapper is never parsed Lyric source) under the plain method name,
// exactly where a record method of that name would be.
// ─────────────────────────────────────────────────────────────────────────────
/// Protected-type fields (`PMField` members) as a uniform `FieldDecl` list,
/// mirroring `recFieldsOf` for records.  `PFVar`/`PFLet` synthesise a
/// `FieldDecl` (docs/annotations/visibility are unused by codegen);
/// `PFImmutable` already wraps one.
func protFieldsOf(decl: in ProtectedTypeDecl): List[FieldDecl] {
  val fields: List[FieldDecl] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case PMField(pf) -> {
        match pf {
          case PFVar(name, ty, initOpt, span) -> {
            fields.add(
              FieldDecl(
                docComments = newList(),
                annotations = newList(),
                visibility = None,
                isMutable = true,
                name = name,
                ty = ty,
                dflt = initOpt,
                span = span
              )
            )
          }
          case PFLet(name, ty, initOpt, span) -> {
            fields.add(
              FieldDecl(
                docComments = newList(),
                annotations = newList(),
                visibility = None,
                isMutable = false,
                name = name,
                ty = ty,
                dflt = initOpt,
                span = span
              )
            )
          }
          case PFImmutable(fd) -> fields.add(fd)
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  fields
}

/// The set of field names declared on a protected type, used to rewrite
/// bare references (`n = n + 1`) to `self.n` in entry/func bodies.
func makeProtectedFieldNames(decl: in ProtectedTypeDecl): Map[String, Bool] {
  val names: Map[String, Bool] = newMap()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case PMField(pf) -> {
        match pf {
          case PFVar(name, _, _, _) -> names.add(name, true)
          case PFLet(name, _, _, _) -> names.add(name, true)
          case PFImmutable(fd) -> names.add(fd.name, true)
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  names
}

// ── Protected-body desugaring: bare field refs -> self.field ────────────────
// Mirrors the MSIL emitter's `desugarProtectedExpr`/`desugarProtectedStmt`
// (lyric-compiler/msil/codegen.l) — same shared AST, same rewrite.
// Recurses into every expression/statement form native can encounter in a
// body, including forms native itself does not yet lower (e.g. try/loop):
// harmless to visit, since those panic during lowering regardless.
func desugarProtectedExpr(fieldNames: in Map[String, Bool], e: in Expr): Expr {
  match e.kind {
    case EPath(path) -> {
      if path.segments.count == 1 {
        val name = path.segments[0]
        if fieldNames.containsKey(name) {
          val selfExpr = Expr(kind = ESelf, span = e.span)
          return Expr(kind = EMember(receiver = selfExpr, memberName = name), span = e.span)
        }
      }
      return e
    }
    case EMember(receiver, memberName) -> {
      return Expr(
        kind = EMember(receiver = desugarProtectedExpr(fieldNames, receiver), memberName = memberName),
        span = e.span
      )
    }
    case EBinop(op, lhs, rhs) -> {
      return Expr(
        kind = EBinop(
          op = op,
          lhs = desugarProtectedExpr(fieldNames, lhs),
          rhs = desugarProtectedExpr(fieldNames, rhs)
        ),
        span = e.span
      )
    }
    case EPrefix(op, operand) -> {
      return Expr(kind = EPrefix(op = op, operand = desugarProtectedExpr(fieldNames, operand)), span = e.span)
    }
    case EParen(inner) -> {
      return Expr(kind = EParen(inner = desugarProtectedExpr(fieldNames, inner)), span = e.span)
    }
    case ECall(fn, args) -> {
      val args2: List[CallArg] = newList()
      var i = 0
      while i < args.count {
        match args[i] {
          case CAPositional(expr) -> args2.add(CAPositional(expr = desugarProtectedExpr(fieldNames, expr)))
          case CANamed(name, value, span) -> {
            args2.add(CANamed(name = name, value = desugarProtectedExpr(fieldNames, value), span = span))
          }
        }
        i = i + 1
      }
      return Expr(kind = ECall(fn = desugarProtectedExpr(fieldNames, fn), args = args2), span = e.span)
    }
    case EIndex(receiver, indices) -> {
      val idxs: List[Expr] = newList()
      var i = 0
      while i < indices.count {
        idxs.add(desugarProtectedExpr(fieldNames, indices[i]))
        i = i + 1
      }
      return Expr(kind = EIndex(receiver = desugarProtectedExpr(fieldNames, receiver), indices = idxs), span = e.span)
    }
    case EIf(cond, thenBranch, elseBranch, thenForm) -> {
      val then2 = match thenBranch {
        case EOBExpr(expr) -> EOBExpr(expr = desugarProtectedExpr(fieldNames, expr))
        case EOBBlock(block) -> EOBBlock(block = desugarProtectedBlock(fieldNames, block))
      }
      val else2 = match elseBranch {
        case Some(eob) -> {
          match eob {
            case EOBExpr(expr) -> Some(value = EOBExpr(expr = desugarProtectedExpr(fieldNames, expr)))
            case EOBBlock(block) -> Some(value = EOBBlock(block = desugarProtectedBlock(fieldNames, block)))
          }
        }
        case None -> None
      }
      return Expr(
        kind = EIf(
          cond = desugarProtectedExpr(fieldNames, cond),
          thenBranch = then2,
          elseBranch = else2,
          thenForm = thenForm
        ),
        span = e.span
      )
    }
    case EMatch(scrutinee, arms) -> {
      val arms2: List[MatchArm] = newList()
      var i = 0
      while i < arms.count {
        val arm = arms[i]
        val g = match arm.guard { case Some(x) -> Some(value = desugarProtectedExpr(fieldNames, x)); case None -> None }
        val body2 = match arm.body {
          case EOBExpr(expr) -> EOBExpr(expr = desugarProtectedExpr(fieldNames, expr))
          case EOBBlock(block) -> EOBBlock(block = desugarProtectedBlock(fieldNames, block))
        }
        arms2.add(MatchArm(pattern = arm.pattern, guard = g, body = body2, span = arm.span))
        i = i + 1
      }
      return Expr(kind = EMatch(scrutinee = desugarProtectedExpr(fieldNames, scrutinee), arms = arms2), span = e.span)
    }
    case EBlock(block) -> return Expr(kind = EBlock(block = desugarProtectedBlock(fieldNames, block)), span = e.span)
    case EPropagate(inner) -> {
      return Expr(kind = EPropagate(inner = desugarProtectedExpr(fieldNames, inner)), span = e.span)
    }
    case EAssign(target, op, value) -> {
      return Expr(
        kind = EAssign(
          target = desugarProtectedExpr(fieldNames, target),
          op = op,
          value = desugarProtectedExpr(fieldNames, value)
        ),
        span = e.span
      )
    }
    case ETuple(exprs) -> {
      val xs: List[Expr] = newList()
      var i = 0
      while i < exprs.count {
        xs.add(desugarProtectedExpr(fieldNames, exprs[i]))
        i = i + 1
      }
      return Expr(kind = ETuple(exprs = xs), span = e.span)
    }
    case EList(exprs) -> {
      val xs: List[Expr] = newList()
      var i = 0
      while i < exprs.count {
        xs.add(desugarProtectedExpr(fieldNames, exprs[i]))
        i = i + 1
      }
      return Expr(kind = EList(exprs = xs), span = e.span)
    }
    case ELambda(lambdaParams, body) -> {
      return Expr(
        kind = ELambda(lambdaParams = lambdaParams, body = desugarProtectedBlock(fieldNames, body)),
        span = e.span
      )
    }
    case EAwait(inner) -> {
      return Expr(kind = EAwait(inner = desugarProtectedExpr(fieldNames, inner)), span = e.span)
    }
    case ESpawn(inner) -> {
      return Expr(kind = ESpawn(inner = desugarProtectedExpr(fieldNames, inner)), span = e.span)
    }
    case _ -> return e
  }
  return e
}

func desugarProtectedBlock(fieldNames: in Map[String, Bool], block: in Block): Block {
  val ss: List[Statement] = newList()
  var i = 0
  while i < block.statements.count {
    ss.add(desugarProtectedStmt(fieldNames, block.statements[i]))
    i = i + 1
  }
  Block(statements = ss, span = block.span)
}

func desugarProtectedStmt(fieldNames: in Map[String, Bool], s: in Statement): Statement {
  match s.kind {
    case SExpr(expr) -> return Statement(kind = SExpr(expr = desugarProtectedExpr(fieldNames, expr)), span = s.span)
    case SAssign(target, op, value) -> {
      return Statement(
        kind = SAssign(
          target = desugarProtectedExpr(fieldNames, target),
          op = op,
          value = desugarProtectedExpr(fieldNames, value)
        ),
        span = s.span
      )
    }
    case SReturn(value) -> {
      val v = match value { case Some(e) -> Some(value = desugarProtectedExpr(fieldNames, e)); case None -> None }
      return Statement(kind = SReturn(value = v), span = s.span)
    }
    case SLocal(binding) -> {
      match binding {
        case LBVal(pat, ty, init) -> {
          return Statement(
            kind = SLocal(binding = LBVal(pat = pat, ty = ty, init = desugarProtectedExpr(fieldNames, init))),
            span = s.span
          )
        }
        case LBVar(name, ty, init) -> {
          val v = match init { case Some(e) -> Some(value = desugarProtectedExpr(fieldNames, e)); case None -> None }
          return Statement(kind = SLocal(binding = LBVar(name = name, ty = ty, init = v)), span = s.span)
        }
        case LBLet(name, ty, init) -> {
          return Statement(
            kind = SLocal(binding = LBLet(name = name, ty = ty, init = desugarProtectedExpr(fieldNames, init))),
            span = s.span
          )
        }
      }
    }
    case SWhile(label, cond, body) -> {
      return Statement(
        kind = SWhile(
          label = label,
          cond = desugarProtectedExpr(fieldNames, cond),
          body = desugarProtectedBlock(fieldNames, body)
        ),
        span = s.span
      )
    }
    case SFor(label, pat, iter, body) -> {
      return Statement(
        kind = SFor(
          label = label,
          pat = pat,
          iter = desugarProtectedExpr(fieldNames, iter),
          body = desugarProtectedBlock(fieldNames, body)
        ),
        span = s.span
      )
    }
    case _ -> return s
  }
  return s
}

func desugarProtectedFuncBody(fieldNames: in Map[String, Bool], body: in FunctionBody): FunctionBody {
  match body {
    case FBExpr(expr) -> return FBExpr(expr = desugarProtectedExpr(fieldNames, expr))
    case FBBlock(block) -> return FBBlock(block = desugarProtectedBlock(fieldNames, block))
  }
  return body
}

/// The implicit `self: in <ProtectedType>` receiver injected as the first
/// parameter of every entry/func's inner function (entries/funcs parse
/// without an explicit receiver, unlike record/impl methods — D037).
func protectedSelfParam(pd: in ProtectedTypeDecl, span: in Span): Param {
  Param(
    mode = PMIn,
    modeExplicit = false,
    name = "self",
    ty = selfTypeRef(pd.name, span),
    dflt = None,
    annotations = newList(),
    span = span
  )
}

/// Collect a protected type's entries/funcs as self-receiving "inner"
/// functions (mirrors `collectRecordMethods`/`collectImplMethods`): each
/// gets the implicit self param prepended, its body desugared (bare field
/// refs -> self.field), and a collision-free `<Type>.<method>.__inner`
/// name.  The lock/unlock wrapper that UFCS call sites actually resolve to
/// is built directly as an NFunc by `registerProtectedMethods`, once the
/// type's NRecInfo (and so its mutex field index) is registered.
pub func collectProtectedMethods(pkgName: in String, decl: in ProtectedTypeDecl, fns: in List[FunctionDecl]): Unit {
  match decl.generics {
    case Some(_) -> {
      return
    }
    case None -> {
    }
  }
  val fieldNames = makeProtectedFieldNames(decl)
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case PMEntry(ed) -> {
        val params: List[Param] = newList()
        params.add(protectedSelfParam(decl, ed.span))
        var pi = 0
        while pi < ed.params.count {
          params.add(ed.params[pi])
          pi = pi + 1
        }
        fns.add(
          FunctionDecl(
            docComments = ed.docComments,
            annotations = ed.annotations,
            visibility = None,
            isAsync = false,
            name = decl.name + "." + ed.name + ".__inner",
            generics = None,
            params = params,
            ret = ed.ret,
            whereClause = None,
            contracts = newList(),
            body = Some(value = desugarProtectedFuncBody(fieldNames, ed.body)),
            span = ed.span
          )
        )
      }
      case PMFunc(fn) -> {
        match fn.generics {
          case Some(_) -> {
          }
          case None -> {
            if not fn.isAsync {
              val params: List[Param] = newList()
              params.add(protectedSelfParam(decl, fn.span))
              var pi = 0
              while pi < fn.params.count {
                params.add(fn.params[pi])
                pi = pi + 1
              }
              val newBody = match fn.body {
                case Some(b) -> Some(value = desugarProtectedFuncBody(fieldNames, b))
                case None -> None
              }
              fns.add(
                FunctionDecl(
                  docComments = fn.docComments,
                  annotations = fn.annotations,
                  visibility = fn.visibility,
                  isAsync = fn.isAsync,
                  name = decl.name + "." + fn.name + ".__inner",
                  generics = fn.generics,
                  params = params,
                  ret = fn.ret,
                  whereClause = fn.whereClause,
                  contracts = fn.contracts,
                  body = newBody,
                  span = fn.span
                )
              )
            }
          }
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
}

// ── Protected-type layout, destructor, construction ─────────────────────────
/// Register a non-generic protected type's layout: user fields (from
/// `PMField` members) plus a trailing `__mutex: i8*` field, then always
/// synthesise a destructor (a protected type must tear down its mutex
/// buffer regardless of whether its user fields hold any ARC refs) —
/// unlike `registerRecordLayout`, which only synthesises one when needed.
func registerProtectedLayout(
  ctx: in Ctx,
  pkg: in String,
  pd: in ProtectedTypeDecl,
  typeDefs: in List[NTypeDefn],
  fns: in List[NFunc],
  strict: in Bool,
): Unit {
  val fields = protFieldsOf(pd)
  val names: List[String] = newList()
  val tys: List[NType] = newList()
  val dflts: List[Option[Expr]] = newList()
  val irName = pkg + "." + pd.name
  var i = 0
  while i < fields.count {
    names.add(fields[i].name)
    match typeToNOpt(ctx, fields[i].ty) {
      case Some(t) -> tys.add(t)
      case None -> {
        if strict {
          tys.add(typeToN(ctx, fields[i].ty))
        } else {
          unregisterRecStub(ctx, irName, irName)
          unregisterRecStub(ctx, pd.name, irName)
          return
        }
      }
    }
    dflts.add(fields[i].dflt)
    i = i + 1
  }
  names.add("__mutex")
  tys.add(NPtr(pointee = NI8))
  val noDflt: Option[Expr] = None
  dflts.add(noDflt)
  val ri = NRecInfo(irName = irName, fieldNames = names, fieldTys = tys, fieldDefaults = dflts)
  replaceRecKey(ctx, pkg + "." + pd.name, ri)
  replaceRecKey(ctx, pd.name, ri)
  if not ctx.protectedRecNames.containsKey(ri.irName) {
    ctx.protectedRecNames.add(ri.irName, true)
  }
  val defnFields: List[NType] = newList()
  defnFields.add(NI32)
  defnFields.add(NPtr(pointee = NI8))
  val layoutTys = layoutFieldTys(tys)
  var fi = 0
  while fi < layoutTys.count {
    defnFields.add(layoutTys[fi])
    fi = fi + 1
  }
  typeDefs.add(NTypeDefn(name = ri.irName, fields = defnFields))
  fns.add(synthProtectedDtor(ctx, ri))
}

/// `define internal void @<T>.dtor(i8*)`: release each ref-typed user
/// field (ARC Rule 7, as `synthRecordDtor`), then destroy and free the
/// mutex buffer (D-N-017 — `lyric_free`, not `lyric_release`: the buffer
/// is a raw lyric_alloc, not an ARC object with a header).
func synthProtectedDtor(ctx: in Ctx, ri: in NRecInfo): NFunc {
  val body: List[NInsn] = newList()
  body.add(NLabel(name = "entry"))
  val objTy = recPtrType(ri)
  val structTy = match objTy { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  body.add(NBitcast(dest = "obj", fromTy = NPtr(pointee = NI8), value = NLocal(name = "raw"), toTy = objTy))
  // User fields only — the trailing __mutex field (index count - 1) is
  // torn down explicitly below via lyric_mutex_destroy + lyric_free, never
  // lyric_release, regardless of what isRefNType(NPtr(NI8)) happens to say.
  val mutexIdx = ri.fieldTys.count - 1
  var i = 0
  while i < mutexIdx {
    if isRefNType(ri.fieldTys[i]) {
      val fieldPtr = freshTmp(ctx)
      val idxArgs: List[NArg] = newList()
      idxArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
      idxArgs.add(NArg(ty = NI32, value = NLitInt(v = intToLong(2 + i), ty = NI32)))
      body.add(NGEP(dest = fieldPtr, ty = structTy, ptr = NLocal(name = "obj"), indices = idxArgs))
      val fieldVal = freshTmp(ctx)
      body.add(NLoad(dest = fieldVal, ty = ri.fieldTys[i], ptr = NLocal(name = fieldPtr)))
      val cast = freshTmp(ctx)
      body.add(NBitcast(dest = cast, fromTy = ri.fieldTys[i], value = NLocal(name = fieldVal), toTy = NPtr(pointee = NI8)))
      body.add(NCallVoid(fn = NGlobal(name = "lyric_release"), args = arg1(NPtr(pointee = NI8), NLocal(name = cast))))
    }
    i = i + 1
  }
  val mutexFieldPtr = freshTmp(ctx)
  val mIdxArgs: List[NArg] = newList()
  mIdxArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  mIdxArgs.add(NArg(ty = NI32, value = NLitInt(v = intToLong(2 + mutexIdx), ty = NI32)))
  body.add(NGEP(dest = mutexFieldPtr, ty = structTy, ptr = NLocal(name = "obj"), indices = mIdxArgs))
  val mutexVal = freshTmp(ctx)
  body.add(NLoad(dest = mutexVal, ty = NPtr(pointee = NI8), ptr = NLocal(name = mutexFieldPtr)))
  body.add(
    NCallVoid(fn = NGlobal(name = "lyric_mutex_destroy"), args = arg1(NPtr(pointee = NI8), NLocal(name = mutexVal)))
  )
  body.add(NCallVoid(fn = NGlobal(name = "lyric_free"), args = arg1(NPtr(pointee = NI8), NLocal(name = mutexVal))))
  body.add(NRetVoid)
  val params: List[NParam] = newList()
  params.add(NParam(name = "raw", ty = NPtr(pointee = NI8)))
  val attrs: List[String] = newList()
  NFunc(
    name = recDtorName(ri),
    params = params,
    retTy = NVoid,
    isPublic = false,
    isExtern = false,
    body = body,
    attributes = attrs
  )
}

/// Construct a protected type from call-site args: resolves the user
/// fields normally, then allocates and initialises the runtime-sized mutex
/// buffer (`lyric_mutex_size` -> `lyric_alloc` -> `lyric_mutex_init`) for
/// the trailing `__mutex` field the caller never supplies.
func lowerProtectedConstructArgs(ctx: in Ctx, insns: in List[NInsn], ri: in NRecInfo, args: in List[CallArg]): NVal {
  val userCount = ri.fieldNames.count - 1
  val userNames: List[String] = newList()
  val userTys: List[NType] = newList()
  val userDflts: List[Option[Expr]] = newList()
  var i = 0
  while i < userCount {
    userNames.add(ri.fieldNames[i])
    userTys.add(ri.fieldTys[i])
    userDflts.add(ri.fieldDefaults[i])
    i = i + 1
  }
  val userVals = resolveFieldArgs(ctx, insns, "protected type '" + ri.irName + "'", userNames, userTys, userDflts, args)
  val sizeI32 = freshTmp(ctx)
  val noArgs: List[NArg] = newList()
  insns.add(NCall(dest = sizeI32, retTy = NI32, fn = NGlobal(name = "lyric_mutex_size"), args = noArgs))
  val sizeI64 = freshTmp(ctx)
  insns.add(NSExt(dest = sizeI64, fromTy = NI32, value = NLocal(name = sizeI32), toTy = NI64))
  val mutexBuf = freshTmp(ctx)
  insns.add(
    NCall(
      dest = mutexBuf,
      retTy = NPtr(pointee = NI8),
      fn = NGlobal(name = "lyric_alloc"),
      args = arg1(NI64, NLocal(name = sizeI64))
    )
  )
  insns.add(
    NCallVoid(fn = NGlobal(name = "lyric_mutex_init"), args = arg1(NPtr(pointee = NI8), NLocal(name = mutexBuf)))
  )
  val allVals: List[NVal] = newList()
  var vi = 0
  while vi < userVals.count {
    allVals.add(userVals[vi])
    vi = vi + 1
  }
  allVals.add(NVal(ty = NPtr(pointee = NI8), value = NLocal(name = mutexBuf)))
  lowerProtectedConstructVals(ctx, insns, ri, allVals)
}

/// Build the heap object from pre-lowered field values (including the
/// trailing mutex-buffer pointer) — identical to `lowerRecordConstructVals`
/// except the dtor is always attached (a protected type always owns a
/// mutex buffer to tear down, unlike a plain record's ARC-only dtor).
func lowerProtectedConstructVals(ctx: in Ctx, insns: in List[NInsn], ri: in NRecInfo, rawVals: in List[NVal]): NVal {
  val vals: List[NVal] = newList()
  var vi = 0
  while vi < rawVals.count {
    match ri.fieldTys[vi] {
      case NVoid -> vals.add(rawVals[vi])
      case want -> vals.add(coerceTo(ctx, insns, rawVals[vi], want))
    }
    vi = vi + 1
  }
  val objTy = recPtrType(ri)
  val structTy = match objTy { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  val obj = emitHeapAlloc(ctx, insns, objTy, recAllocSize(ri), recDtorName(ri))
  var fi = 0
  while fi < vals.count {
    if isVoidNType(ri.fieldTys[fi]) {
      fi = fi + 1
      continue
    }
    if isRefNType(ri.fieldTys[fi]) {
      emitRetain(ctx, insns, vals[fi])
    }
    val fieldPtr = freshTmp(ctx)
    val fArgs: List[NArg] = newList()
    fArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
    fArgs.add(NArg(ty = NI32, value = NLitInt(v = intToLong(2 + fi), ty = NI32)))
    insns.add(NGEP(dest = fieldPtr, ty = structTy, ptr = NLocal(name = obj), indices = fArgs))
    insns.add(NStore(ty = ri.fieldTys[fi], value = vals[fi].value, ptr = NLocal(name = fieldPtr)))
    fi = fi + 1
  }
  val outV = NVal(ty = objTy, value = NLocal(name = obj))
  registerTemp(ctx, outV)
  outV
}

// ── Protected-method wrapper: lock, call inner, unlock ──────────────────────
/// For every non-generic protected type's entries/funcs, register the
/// lock/unlock wrapper's `NFuncSig` directly into `ctx.sigs` (so UFCS call
/// sites resolve to it, exactly where a record method of that name would
/// be) and hand-build its `NFunc` body.  Must run after `registerHeapTypes`
/// (the type's `NRecInfo` — and so its mutex field index — has to already
/// be registered).
func registerProtectedMethods(ctx: in Ctx, units: in List[CodegenUnit], fns: in List[NFunc]): Unit {
  var ui = 0
  while ui < units.count {
    val u = units[ui]
    var pi = 0
    while pi < u.protecteds.count {
      val pd = u.protecteds[pi]
      match pd.generics {
        case Some(_) -> {
        }
        case None -> registerProtectedMethodsFor(ctx, u.pkgName, pd, fns)
      }
      pi = pi + 1
    }
    ui = ui + 1
  }
}

func registerProtectedMethodsFor(ctx: in Ctx, pkg: in String, pd: in ProtectedTypeDecl, fns: in List[NFunc]): Unit {
  val riOpt = mapGet(ctx.recordDefs, pkg + "." + pd.name)
  val ri = match riOpt { case Some(r) -> r; case None -> { return } }
  val selfTy = recPtrType(ri)
  var mi = 0
  while mi < pd.members.count {
    match pd.members[mi] {
      case PMEntry(ed) -> registerProtectedMember(ctx, pkg, pd, ri, selfTy, ed.name, ed.params, ed.ret, fns)
      case PMFunc(fn) -> {
        match fn.generics {
          case Some(_) -> {
          }
          case None -> {
            if not fn.isAsync {
              registerProtectedMember(ctx, pkg, pd, ri, selfTy, fn.name, fn.params, fn.ret, fns)
            }
          }
        }
      }
      case _ -> {
      }
    }
    mi = mi + 1
  }
}

func registerProtectedMember(
  ctx: in Ctx,
  pkg: in String,
  pd: in ProtectedTypeDecl,
  ri: in NRecInfo,
  selfTy: in NType,
  methodName: in String,
  params: in List[Param],
  ret: in Option[TypeExpr],
  fns: in List[NFunc],
): Unit {
  val arity = 1 + params.count
  val wrapperIrName = pkg + "." + pd.name + "." + methodName
  val innerIrName = pkg + "." + pd.name + "." + methodName + ".__inner"
  val sigParamTys: List[TypeExpr] = newList()
  sigParamTys.add(selfTypeRef(pd.name, pd.span))
  val sigParamNames: List[String] = newList()
  sigParamNames.add("self")
  var i = 0
  while i < params.count {
    sigParamTys.add(params[i].ty)
    sigParamNames.add(params[i].name)
    i = i + 1
  }
  val sig = NFuncSig(
    irName = wrapperIrName,
    pkg = pkg,
    paramNames = sigParamNames,
    paramTys = sigParamTys,
    retTy = ret,
    isExternSym = false
  )
  addSig(ctx.sigs, pkg + "." + methodName + "/" + arity.toString(), sig)
  addSig(ctx.sigs, methodName + "/" + arity.toString(), sig)
  val retTyN = retTypeToN(ctx, ret)
  val paramTysN: List[NType] = newList()
  val paramNamesN: List[String] = newList()
  var j = 0
  while j < params.count {
    paramTysN.add(typeToN(ctx, params[j].ty))
    paramNamesN.add(params[j].name)
    j = j + 1
  }
  fns.add(synthProtectedWrapper(ctx, ri, selfTy, wrapperIrName, innerIrName, paramNamesN, paramTysN, retTyN))
}

/// Hand-built wrapper body: GEP+load the mutex field, lock, call the
/// inner function (forwarding self and every param unchanged — a plain
/// forward, not a borrow/ownership transfer, so no extra retain is
/// needed), unlock, return.
func synthProtectedWrapper(
  ctx: in Ctx,
  ri: in NRecInfo,
  selfTy: in NType,
  wrapperIrName: in String,
  innerIrName: in String,
  paramNames: in List[String],
  paramTys: in List[NType],
  retTy: in NType,
): NFunc {
  val body: List[NInsn] = newList()
  body.add(NLabel(name = "entry"))
  val structTy = match selfTy { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  val mutexIdx = ri.fieldTys.count - 1
  val mutexFieldPtr = freshTmp(ctx)
  val idxArgs: List[NArg] = newList()
  idxArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  idxArgs.add(NArg(ty = NI32, value = NLitInt(v = intToLong(2 + mutexIdx), ty = NI32)))
  body.add(NGEP(dest = mutexFieldPtr, ty = structTy, ptr = NLocal(name = "self"), indices = idxArgs))
  val mutexVal = freshTmp(ctx)
  body.add(NLoad(dest = mutexVal, ty = NPtr(pointee = NI8), ptr = NLocal(name = mutexFieldPtr)))
  body.add(
    NCallVoid(fn = NGlobal(name = "lyric_mutex_lock"), args = arg1(NPtr(pointee = NI8), NLocal(name = mutexVal)))
  )
  val callArgs: List[NArg] = newList()
  callArgs.add(NArg(ty = selfTy, value = NLocal(name = "self")))
  var i = 0
  while i < paramNames.count {
    callArgs.add(NArg(ty = paramTys[i], value = NLocal(name = paramNames[i])))
    i = i + 1
  }
  match retTy {
    case NVoid -> {
      body.add(NCallVoid(fn = NGlobal(name = innerIrName), args = callArgs))
      body.add(
        NCallVoid(fn = NGlobal(name = "lyric_mutex_unlock"), args = arg1(NPtr(pointee = NI8), NLocal(name = mutexVal)))
      )
      body.add(NRetVoid)
    }
    case rt -> {
      val resTmp = freshTmp(ctx)
      body.add(NCall(dest = resTmp, retTy = rt, fn = NGlobal(name = innerIrName), args = callArgs))
      body.add(
        NCallVoid(fn = NGlobal(name = "lyric_mutex_unlock"), args = arg1(NPtr(pointee = NI8), NLocal(name = mutexVal)))
      )
      body.add(NRet(ty = rt, value = NLocal(name = resTmp)))
    }
  }
  val params: List[NParam] = newList()
  params.add(NParam(name = "self", ty = selfTy))
  var pi = 0
  while pi < paramNames.count {
    params.add(NParam(name = paramNames[pi], ty = paramTys[pi]))
    pi = pi + 1
  }
  val attrs: List[String] = newList()
  NFunc(
    name = wrapperIrName,
    params = params,
    retTy = retTy,
    isPublic = false,
    isExtern = false,
    body = body,
    attributes = attrs
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// §N3.2  Interface vtable dispatch.
//
// An interface value lowers to a heap-boxed fat pointer (uniform with the
// record/closure representation, since the IR layer has no by-value
// aggregate ABI): `__iface.<m>` = `{ i32 rc, i8* dtor, i8* obj, vtable* }`.
// The `obj` slot holds the (type-erased) implementing object; a per-interface
// dtor releases it, so standard ARC on the box gives Rule-8 semantics for
// free.  Each interface has a vtable struct of one `i8*` slot per method; each
// `impl I for R` emits a constant vtable of `bitcast`ed concrete-method
// pointers.  Dispatch loads the slot, bitcasts to the method's function type,
// and calls with `obj` as arg 0.  This diverges from the by-value fat pointer
// in 03-type-mapping.md / 04-arc-design.md Rule 8 — see the decision log.
// ─────────────────────────────────────────────────────────────────────────────
func mangleIfaceName(key: in String): String {
  Str.replace(key, ".", "_")
}

/// The record name an `impl` targets, when it is a plain (non-generic)
/// record reference; generic targets are deferred (N3.2 first slice).
func implTargetRecordName(target: in TypeExpr): Option[String] {
  match target.kind {
    case TRef(path) -> Some(value = lastSeg(path))
    case TParen(inner) -> implTargetRecordName(inner)
    case _ -> None
  }
}

func implIfaceName(iface: in ConstraintRef): String {
  lastSeg(iface.head)
}

/// The synthetic, collision-free name of an impl method: qualified by both
/// the target record and the interface so `impl A for R` and `impl B for R`
/// (or a record method of the same name) never share an IR symbol.
func implMethodName(recordName: in String, ifaceName: in String, methodName: in String): String {
  recordName + "." + ifaceName + "." + methodName
}

/// Rewrite an `impl I for R` method into a self-receiving package function:
/// prepend `self: in R` (impl methods parse without an injected receiver —
/// the body's `self` keyword lowers to `loadLocal("self")`), substitute any
/// `Self` in the remaining signature, and give it the collision-free name.
func implMethodToFn(recordName: in String, ifaceName: in String, fn: in FunctionDecl): FunctionDecl {
  val newParams: List[Param] = newList()
  newParams.add(
    Param(
      mode = PMIn,
      modeExplicit = false,
      name = "self",
      ty = selfTypeRef(recordName, fn.span),
      dflt = None,
      annotations = newList(),
      span = fn.span
    )
  )
  var i = 0
  while i < fn.params.count {
    val p = fn.params[i]
    newParams.add(
      Param(
        mode = p.mode,
        modeExplicit = p.modeExplicit,
        name = p.name,
        ty = substSelfInType(p.ty, recordName),
        dflt = p.dflt,
        annotations = p.annotations,
        span = p.span
      )
    )
    i = i + 1
  }
  var newRet: Option[TypeExpr] = None
  match fn.ret {
    case Some(r) -> {
      newRet = Some(value = substSelfInType(r, recordName))
    }
    case None -> {
    }
  }
  FunctionDecl(
    docComments = fn.docComments,
    annotations = fn.annotations,
    visibility = fn.visibility,
    isAsync = fn.isAsync,
    name = implMethodName(recordName, ifaceName, fn.name),
    generics = fn.generics,
    params = newParams,
    ret = newRet,
    whereClause = fn.whereClause,
    contracts = fn.contracts,
    body = fn.body,
    span = fn.span
  )
}

/// Collect an `impl` block's methods as self-receiving functions (mirrors
/// `collectRecordMethods`).  Generic impls / generic or async methods and
/// impls for non-record targets are skipped here and rejected at use.
pub func collectImplMethods(pkgName: in String, decl: in ImplDecl, fns: in List[FunctionDecl]): Unit {
  match decl.generics {
    case Some(_) -> {
      return
    }
    case None -> {
    }
  }
  val recordName = match implTargetRecordName(decl.target) { case Some(n) -> n; case None -> { return } }
  val ifaceName = implIfaceName(decl.iface)
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case IMplFunc(fn) -> {
        match fn.generics {
          case Some(_) -> {
          }
          case None -> {
            if not fn.isAsync {
              fns.add(implMethodToFn(recordName, ifaceName, fn))
            }
          }
        }
      }
      case IMplAssoc(_) -> {
      }
    }
    i = i + 1
  }
}

/// The vtable struct type for an interface: `{ i8*, i8*, ... }`, one erased
/// function-pointer slot per method.
func ifaceVtStructType(ii: in NIfaceInfo): NType {
  val fields: List[NType] = newList()
  var i = 0
  while i < ii.methodNames.count {
    fields.add(NPtr(pointee = NI8))
    i = i + 1
  }
  NStruct(name = ii.vtName, fields = fields)
}

/// The heap-boxed fat-pointer type for an interface value:
/// `{ i32 rc, i8* dtor, i8* obj, vtable* }`.
func ifaceBoxStructType(ii: in NIfaceInfo): NType {
  val fields: List[NType] = newList()
  fields.add(NI32)
  fields.add(NPtr(pointee = NI8))
  fields.add(NPtr(pointee = NI8))
  fields.add(NPtr(pointee = ifaceVtStructType(ii)))
  NStruct(name = ii.irName, fields = fields)
}

func ifaceBoxPtrType(ii: in NIfaceInfo): NType {
  NPtr(pointee = ifaceBoxStructType(ii))
}

/// If `t` is an interface box pointer, recover its NIfaceInfo.
func ifaceBoxInfoOfType(ctx: in Ctx, t: in NType): Option[NIfaceInfo] {
  match t {
    case NPtr(pointee) -> {
      match pointee {
        case NStruct(name, _) -> {
          if Str.startsWith(name, "__iface.") {
            mapGet(ctx.ifaceInfos, name)
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

/// The record IR name (`Pkg.Record`) if `t` is a record pointer.
func recordIrNameOfType(t: in NType): Option[String] {
  match t {
    case NPtr(pointee) -> {
      match pointee {
        case NStruct(name, _) -> {
          if Str.startsWith(name, "__") or name == "LyricString" {
            None
          } else {
            Some(value = name)
          }
        }
        case _ -> None
      }
    }
    case _ -> None
  }
}

func ifaceVtableGlobalName(recordIr: in String, ii: in NIfaceInfo): String {
  "ifacevt_" + mangleIfaceName(recordIr) + "_" + mangleIfaceName(ii.key)
}

func ifaceBoxDtorName(ii: in NIfaceInfo): String {
  ii.irName + ".dtor"
}

func registerIfaceInfo(ctx: in Ctx, pkg: in String, name: in String, info: in NIfaceInfo): Unit {
  val qualified = pkg + "." + name
  if ctx.ifaceInfos.containsKey(qualified) {
    ctx.ifaceInfos.remove(qualified)
  }
  ctx.ifaceInfos.add(qualified, info)
  // Bare and box-struct-name keys are refreshed on every call so phase B's
  // full method signatures replace phase A's names-only placeholder.
  if ctx.ifaceInfos.containsKey(name) {
    ctx.ifaceInfos.remove(name)
  }
  ctx.ifaceInfos.add(name, info)
  if ctx.ifaceInfos.containsKey(info.irName) {
    ctx.ifaceInfos.remove(info.irName)
  }
  ctx.ifaceInfos.add(info.irName, info)
}

func ifaceMethodSlot(ii: in NIfaceInfo, name: in String): Int {
  var i = 0
  while i < ii.methodNames.count {
    if ii.methodNames[i] == name {
      return i
    }
    i = i + 1
  }
  -1
}

/// Synthesise the box destructor: release the erased `obj` (slot 2).  The
/// runtime frees the box itself once its refcount reaches zero.
func synthIfaceBoxDtor(ctx: in Ctx, ii: in NIfaceInfo): NFunc {
  val body: List[NInsn] = newList()
  body.add(NLabel(name = "entry"))
  val boxTy = ifaceBoxPtrType(ii)
  val structTy = ifaceBoxStructType(ii)
  body.add(NBitcast(dest = "obj", fromTy = NPtr(pointee = NI8), value = NLocal(name = "raw"), toTy = boxTy))
  val objSlot = freshTmp(ctx)
  val idxArgs: List[NArg] = newList()
  idxArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  idxArgs.add(NArg(ty = NI32, value = NLitInt(v = 2i64, ty = NI32)))
  body.add(NGEP(dest = objSlot, ty = structTy, ptr = NLocal(name = "obj"), indices = idxArgs))
  val objVal = freshTmp(ctx)
  body.add(NLoad(dest = objVal, ty = NPtr(pointee = NI8), ptr = NLocal(name = objSlot)))
  body.add(NCallVoid(fn = NGlobal(name = "lyric_release"), args = arg1(NPtr(pointee = NI8), NLocal(name = objVal))))
  body.add(NRetVoid)
  val params: List[NParam] = newList()
  params.add(NParam(name = "raw", ty = NPtr(pointee = NI8)))
  NFunc(
    name = ifaceBoxDtorName(ii),
    params = params,
    retTy = NVoid,
    isPublic = false,
    isExtern = false,
    body = body,
    attributes = newList()
  )
}

/// Register interface box + vtable NAMES and method-name lists (phase A).
/// Runs BEFORE records are registered so a record with an interface-typed
/// field resolves the interface to its box type during layout (#4917), and
/// before phase B so an interface-typed method parameter resolves there.
func registerInterfaceNames(ctx: in Ctx, units: in List[CodegenUnit]): Unit {
  var ua = 0
  while ua < units.count {
    val u = units[ua]
    var ii = 0
    while ii < u.interfaces.count {
      val idecl = u.interfaces[ii]
      match idecl.generics {
        case Some(_) -> {
        }
        case None -> {
          val qualified = u.pkgName + "." + idecl.name
          val mangled = mangleIfaceName(qualified)
          val mnames: List[String] = newList()
          var mi = 0
          while mi < idecl.members.count {
            match idecl.members[mi] {
              case IMSig(sig) -> {
                match sig.generics {
                  case Some(_) -> {
                  }
                  case None -> {
                    if not sig.isAsync {
                      mnames.add(sig.name)
                    }
                  }
                }
              }
              case _ -> {
              }
            }
            mi = mi + 1
          }
          val info = NIfaceInfo(
            key = qualified,
            irName = "__iface." + mangled,
            vtName = "__ifacevt." + mangled,
            methodNames = mnames,
            methodParamTys = newList(),
            methodRetTys = newList()
          )
          registerIfaceInfo(ctx, u.pkgName, idecl.name, info)
        }
      }
      ii = ii + 1
    }
    ua = ua + 1
  }
}

/// Fill interface method signatures and emit the vtable/box type definitions
/// and box destructors (phase B).  Runs AFTER records are registered so a
/// method parameter/return type that references a record resolves.
func registerInterfaceTypes(
  ctx: in Ctx, units: in List[CodegenUnit], types: in List[NTypeDefn], fns: in List[NFunc]
): Unit {
  var ub = 0
  while ub < units.count {
    val u = units[ub]
    var ii = 0
    while ii < u.interfaces.count {
      val idecl = u.interfaces[ii]
      match idecl.generics {
        case Some(_) -> {
        }
        case None -> {
          val qualified = u.pkgName + "." + idecl.name
          val pre = match mapGet(ctx.ifaceInfos, qualified) {
            case Some(x) -> x
            case None -> panic("Lyric.LlvmCodegen: interface '" + qualified + "' lost between registration phases")
          }
          val pTys: List[List[NType]] = newList()
          val rTys: List[NType] = newList()
          var mi = 0
          while mi < idecl.members.count {
            match idecl.members[mi] {
              case IMSig(sig) -> {
                match sig.generics {
                  case Some(_) -> {
                  }
                  case None -> {
                    if not sig.isAsync {
                      val ps: List[NType] = newList()
                      var pi = 0
                      while pi < sig.params.count {
                        ps.add(typeToN(ctx, sig.params[pi].ty))
                        pi = pi + 1
                      }
                      pTys.add(ps)
                      rTys.add(retTypeToN(ctx, sig.ret))
                    }
                  }
                }
              }
              case _ -> {
              }
            }
            mi = mi + 1
          }
          val info = NIfaceInfo(
            key = pre.key,
            irName = pre.irName,
            vtName = pre.vtName,
            methodNames = pre.methodNames,
            methodParamTys = pTys,
            methodRetTys = rTys
          )
          registerIfaceInfo(ctx, u.pkgName, idecl.name, info)
          val vtFields: List[NType] = newList()
          var vf = 0
          while vf < info.methodNames.count {
            vtFields.add(NPtr(pointee = NI8))
            vf = vf + 1
          }
          types.add(NTypeDefn(name = info.vtName, fields = vtFields))
          val boxFields: List[NType] = newList()
          boxFields.add(NI32)
          boxFields.add(NPtr(pointee = NI8))
          boxFields.add(NPtr(pointee = NI8))
          boxFields.add(NPtr(pointee = ifaceVtStructType(info)))
          types.add(NTypeDefn(name = info.irName, fields = boxFields))
          fns.add(synthIfaceBoxDtor(ctx, info))
        }
      }
      ii = ii + 1
    }
    ub = ub + 1
  }
}

/// Build the `{ i8* bitcast(...), ... }` constant initialiser for one
/// `impl I for R` vtable.  Each slot bitcasts the concrete impl method
/// (whose real first parameter is `R*`) to a raw `i8*`.
func ifaceVtableInitStr(
  ctx: in Ctx,
  pkg: in String,
  recordName: in String,
  selfPtrTy: in NType,
  ifaceName: in String,
  ii: in NIfaceInfo,
): String {
  var acc = "{ "
  var i = 0
  while i < ii.methodNames.count {
    if i > 0 {
      acc = acc + ", "
    }
    val implIr = pkg + "." + implMethodName(recordName, ifaceName, ii.methodNames[i])
    val fnParams: List[NType] = newList()
    fnParams.add(selfPtrTy)
    var pi = 0
    while pi < ii.methodParamTys[i].count {
      fnParams.add(ii.methodParamTys[i][pi])
      pi = pi + 1
    }
    val fnTyStr = nTypeToIrString(NFnPtr(params = fnParams, ret = ii.methodRetTys[i]))
    acc = acc + "i8* bitcast (" + fnTyStr + " @" + quoteIrIdent(implIr) + " to i8*)"
    i = i + 1
  }
  acc + " }"
}

/// Emit a vtable constant global for every `impl I for R` and record the
/// `<recordIr>|<ifaceKey>` -> global-name mapping consulted at upcast sites.
func registerImplVtables(ctx: in Ctx, units: in List[CodegenUnit]): Unit {
  var ua = 0
  while ua < units.count {
    val u = units[ua]
    var ii = 0
    while ii < u.impls.count {
      val decl = u.impls[ii]
      match decl.generics {
        case Some(_) -> {
        }
        case None -> {
          match implTargetRecordName(decl.target) {
            case None -> {
            }
            case Some(recordName) -> {
              val ifaceName = implIfaceName(decl.iface)
              match mapGet(ctx.ifaceInfos, ifaceName) {
                case None -> {
                }
                case Some(info) -> {
                  match mapGet(ctx.recordDefs, recordName) {
                    case None -> {
                    }
                    case Some(ri) -> {
                      val selfPtrTy = recPtrType(ri)
                      val gname = ifaceVtableGlobalName(ri.irName, info)
                      if not ctx.ifaceVtables.containsKey(ri.irName + "|" + info.key) {
                        ctx.globals.add(
                          NGlobalDef(
                            name = gname,
                            linkage = "internal constant",
                            tyStr = nTypeToIrString(ifaceVtStructType(info)),
                            initStr = ifaceVtableInitStr(ctx, u.pkgName, recordName, selfPtrTy, ifaceName, info),
                            align = 8
                          )
                        )
                        ctx.ifaceVtables.add(ri.irName + "|" + info.key, gname)
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
      ii = ii + 1
    }
    ua = ua + 1
  }
}

/// Upcast a concrete record value `v` to interface `ii`: box it, retain the
/// object into the box's `obj` slot, and point its vtable at the concrete
/// `impl` vtable constant.  The box is an ordinary owned temporary (ARC
/// releases it, and its destructor releases `obj`).
func buildIfaceBox(ctx: in Ctx, insns: in List[NInsn], v: in NVal, ii: in NIfaceInfo, vtGlobal: in String): NVal {
  val boxTy = ifaceBoxPtrType(ii)
  val structTy = ifaceBoxStructType(ii)
  val size = structSize(match structTy { case NStruct(_, f) -> f; case _ -> newList() })
  val box = emitHeapAlloc(ctx, insns, boxTy, size, ifaceBoxDtorName(ii))
  // obj slot (index 2): retain then store the erased object pointer.
  val objI8 = freshTmp(ctx)
  insns.add(NBitcast(dest = objI8, fromTy = v.ty, value = v.value, toTy = NPtr(pointee = NI8)))
  insns.add(NCallVoid(fn = NGlobal(name = "lyric_retain"), args = arg1(NPtr(pointee = NI8), NLocal(name = objI8))))
  val objSlot = freshTmp(ctx)
  val objArgs: List[NArg] = newList()
  objArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  objArgs.add(NArg(ty = NI32, value = NLitInt(v = 2i64, ty = NI32)))
  insns.add(NGEP(dest = objSlot, ty = structTy, ptr = NLocal(name = box), indices = objArgs))
  insns.add(NStore(ty = NPtr(pointee = NI8), value = NLocal(name = objI8), ptr = NLocal(name = objSlot)))
  // vtable slot (index 3): point at the impl's constant vtable.
  val vtSlot = freshTmp(ctx)
  val vtArgs: List[NArg] = newList()
  vtArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  vtArgs.add(NArg(ty = NI32, value = NLitInt(v = 3i64, ty = NI32)))
  insns.add(NGEP(dest = vtSlot, ty = structTy, ptr = NLocal(name = box), indices = vtArgs))
  insns.add(
    NStore(ty = NPtr(pointee = ifaceVtStructType(ii)), value = NGlobal(name = vtGlobal), ptr = NLocal(name = vtSlot))
  )
  val boxVal = NVal(ty = boxTy, value = NLocal(name = box))
  registerTemp(ctx, boxVal)
  boxVal
}

/// Dispatch an interface method call: load `obj` and the vtable pointer,
/// index the method slot, bitcast the raw pointer to the method's function
/// type, and call with `obj` (as `i8*`) as the receiver.
func lowerIfaceDispatch(
  ctx: in Ctx,
  insns: in List[NInsn],
  recv: in NVal,
  ii: in NIfaceInfo,
  slot: in Int,
  args: in List[CallArg],
): NVal {
  val structTy = ifaceBoxStructType(ii)
  // Load obj (index 2).
  val objSlot = freshTmp(ctx)
  val objArgs: List[NArg] = newList()
  objArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  objArgs.add(NArg(ty = NI32, value = NLitInt(v = 2i64, ty = NI32)))
  insns.add(NGEP(dest = objSlot, ty = structTy, ptr = recv.value, indices = objArgs))
  val objVal = freshTmp(ctx)
  insns.add(NLoad(dest = objVal, ty = NPtr(pointee = NI8), ptr = NLocal(name = objSlot)))
  // Load vtable pointer (index 3).
  val vtSlotPtr = freshTmp(ctx)
  val vtArgs: List[NArg] = newList()
  vtArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  vtArgs.add(NArg(ty = NI32, value = NLitInt(v = 3i64, ty = NI32)))
  insns.add(NGEP(dest = vtSlotPtr, ty = structTy, ptr = recv.value, indices = vtArgs))
  val vtPtrTy = NPtr(pointee = ifaceVtStructType(ii))
  val vtbl = freshTmp(ctx)
  insns.add(NLoad(dest = vtbl, ty = vtPtrTy, ptr = NLocal(name = vtSlotPtr)))
  // Index the method slot and load the raw function pointer.
  val fnSlotPtr = freshTmp(ctx)
  val mArgs: List[NArg] = newList()
  mArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  mArgs.add(NArg(ty = NI32, value = NLitInt(v = intToLong(slot), ty = NI32)))
  insns.add(NGEP(dest = fnSlotPtr, ty = ifaceVtStructType(ii), ptr = NLocal(name = vtbl), indices = mArgs))
  val fnRaw = freshTmp(ctx)
  insns.add(NLoad(dest = fnRaw, ty = NPtr(pointee = NI8), ptr = NLocal(name = fnSlotPtr)))
  // Bitcast to the method's function type (self as i8*).
  val paramTys = ii.methodParamTys[slot]
  val retTy = ii.methodRetTys[slot]
  val fnParamTys: List[NType] = newList()
  fnParamTys.add(NPtr(pointee = NI8))
  var pi = 0
  while pi < paramTys.count {
    fnParamTys.add(paramTys[pi])
    pi = pi + 1
  }
  val fnTyped = freshTmp(ctx)
  insns.add(
    NBitcast(
      dest = fnTyped,
      fromTy = NPtr(pointee = NI8),
      value = NLocal(name = fnRaw),
      toTy = NPtr(pointee = NFnPtr(params = fnParamTys, ret = retTy))
    )
  )
  // Build call args: obj first, then the coerced declared arguments.
  val callArgs: List[NArg] = newList()
  callArgs.add(NArg(ty = NPtr(pointee = NI8), value = NLocal(name = objVal)))
  var ai = 0
  while ai < args.count {
    val av = lowerCallArgExpecting(ctx, insns, args, ai, paramTys[ai])
    callArgs.add(NArg(ty = paramTys[ai], value = av.value))
    ai = ai + 1
  }
  match retTy {
    case NVoid -> {
      insns.add(NCallVoid(fn = NLocal(name = fnTyped), args = callArgs))
      NVal(ty = NVoid, value = NUndef(ty = NVoid))
    }
    case _ -> {
      val dest = freshTmp(ctx)
      insns.add(NCall(dest = dest, retTy = retTy, fn = NLocal(name = fnTyped), args = callArgs))
      val outV = NVal(ty = retTy, value = NLocal(name = dest))
      registerTemp(ctx, outV)
      outV
    }
  }
}

pub func dottedPkgName(file: in SourceFile): String {
  modulePathJoin(file.packageDecl.path.segments)
}
