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
//!   * Records: `{ i32 rc, i32 weak, i8* dtor, fields... }` heap structs with
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
/// An `extern func` marked `@wasmImport("module")` (docs/35 W3 slice 3): on a
/// `--shape module` build its symbol becomes a wasm import named `symbol` from
/// `module`, satisfied by the JS the host passes to `instantiate`.
pub record WasmImportDecl {
  symbol: String
  module: String
  /// Why the `@wasmImport` annotation is unusable, or "" when it is well formed.
  problem: String
}

pub record CodegenUnit {
  pkgName: String
  fns: List[FunctionDecl]
  externs: List[ExternFuncDecl]
  // Libraries the reachable externs name with `@library("name")` (D158),
  // linked as `-l<name>`; "c" is the C library the link already has.
  nativeLibs: List[String]
  /// The reachable externs marked `@wasmImport` (see `WasmImportDecl`).
  wasmImports: List[WasmImportDecl]
  // Type declarations register unfiltered (layouts are cheap and other
  // packages' signatures may reference them); generic declarations are
  // skipped at registration and panic only when actually used.
  records: List[RecordDecl]
  // Names of the `records` that were declared `opaque type`: they keep the
  // heap form (docs/67 §4.2) even when every field is by-value.
  opaqueNames: List[String]
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
  // Module-level `val` / `const` bindings (#5977 part 2). Native has no
  // static-global storage yet, so a reference to a module-level binding is
  // resolved by inlining its initializer at the use site — supported only for
  // a literal initializer (which is exactly what `@build_const` produces). A
  // non-literal initializer is collected too, so `loadLocal` can surface a
  // clean diagnostic instead of an "unknown name" one.
  moduleVals: List[ModuleValDef]
  // Whether this package's own source file has `import Std.String` in
  // scope (#6588 review follow-up, #6752) — see `Ctx.pkgImportsStdString`.
  importsStdString: Bool
  // The packages this unit's source file imports (dotted paths), for resolving
  // a bare function name that several packages declare to the one the caller
  // imports (`bareSig`).
  imports: List[String]
  // The type checker's `methodCallArities` for this package's file (empty
  // for a bundled package): see `Ctx.methodCallArities` (#7828).
  methodCallArities: Map[String, Int]
}

/// A module-level `val`/`const` binding. A literal initializer is inlined at
/// each use site (#5977); any other initializer becomes a static global that a
/// synthesised function (`mvInitFnName`, hoisted by the native bridge before
/// monomorphisation) fills in before `main` runs. `ty` is the declared type when present (a `const` always has one;
/// a `val` may not) — used as the expected type when lowering the initializer.
pub record ModuleValDef {
  name: String
  init: Expr
  ty: Option[TypeExpr]
  // The declaring package: a non-literal initializer's global is keyed by it.
  pkg: String
}

/// Call-registry entry: how a resolvable callee lowers.  `isExternSym`
/// selects between a Lyric function (`irName` = `Pkg.name`, possibly
/// arity-suffixed) and a C symbol from an `extern func`.
record NFuncSig {
  irName: String
  pkg: String
  paramNames: List[String]
  paramTys: List[TypeExpr]
  // Per-parameter mode (N9.6): `out`/`inout` parameters are passed as an
  // address to the caller's storage rather than by value — see
  // `paramArgNType` and `lowerByRefArg`.  Always `PMIn` for extern funcs
  // (no `_kernel_native/` declaration uses `out`/`inout`; enforced in
  // `buildSigs`).
  paramModes: List[ParamMode]
  // Each parameter's default expression, lowered at a call that leaves the
  // parameter out (#7985).  Always `None` for extern funcs and receivers.
  paramDefaults: List[Option[Expr]]
  retTy: Option[TypeExpr]
  isExternSym: Bool
  // Async callee (stage B2): the define returns a LyricTask* (as i8*) and
  // call sites unwrap (or hold the task under `spawn`) — see emitAsyncCall.
  isAsync: Bool
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
  // docs/67 §4.2: a record with no `var` field whose fields are all by-value
  // lowers to a plain LLVM struct VALUE (no ARC header, no allocation, no
  // destructor); every other record is the shared heap form behind a pointer.
  byValue: Bool
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
/// a Unit return.  `methodRetIsSelf` (#7585, D-progress-1016) marks a bare-`Self`
/// DECLARED return (erased in `methodRetTys` to `i8*` like every other
/// bare `Self`) so `lowerIfaceDispatch` knows to REBOX the erased result
/// into a fresh interface value — a call through the interface receiver
/// types the whole expression as the interface itself (T0113 receiver
/// substitution), not the erased raw pointer. `methodParamIsSelf` (#7618
/// review follow-up to #7616) is the per-parameter twin of
/// `methodRetIsSelf`: `methodParamIsSelf[m][p]` is true exactly when
/// parameter `p` of method `m` is a bare `Self` (erased in
/// `methodParamTys[m][p]` to `i8*`, same as the return case) — the ONLY
/// fact `lowerIfaceDispatch` may use to unbox an argument to the erased
/// slot (`unboxToSelfSlot`). This is checked EXPLICITLY, never inferred
/// from a parameter's erased type happening to be `i8*` (a real, unrelated
/// `NativePtr[Byte]` parameter erases to the exact same `NType` and must
/// NOT be treated as a `Self` slot).
record NIfaceInfo {
  key: String
  irName: String
  vtName: String
  methodNames: List[String]
  methodParamTys: List[List[NType]]
  methodRetTys: List[NType]
  methodRetIsSelf: List[Bool]
  methodParamIsSelf: List[List[Bool]]
  // Each method's parameter names and defaults, binding a call's named and
  // omitted arguments (#7985).
  methodParamNames: List[List[String]]
  methodParamDefaults: List[List[Option[Expr]]]
}

/// Registered (non-generic) union type: cases plus the payload area
/// size in 8-byte words (max over the cases' payload struct layouts).
record NUnionInfo {
  irName: String
  cases: List[NUnionCaseInfo]
  payloadWords: Int
  // docs/67 §4.2: a union whose every payload field is by-value is an inline
  // tagged struct VALUE `{ i32 disc, i32 pad, [W x i64] payload }` (no ARC
  // header, no allocation, no destructor); every other union is a heap object.
  inline: Bool
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
  /// `[lo, hi]` or `[lo, hi)` as written, for the range-violation message.
  boundsText: String
  /// `Byte`/`UInt`/`ULong`-backed: bounds compare unsigned.
  isUnsigned: Bool
  /// A `Double`/`Float` range: `loF ..= hiF` (or `..<` when `hiExclusive`),
  /// rounded to binary32 for `Float` (D155).
  isFloat: Bool = false
  loF: Double = 0.0
  hiF: Double = 0.0
  hiExclusive: Bool = false
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
  // Async instance (stage B2): the define returns a LyricTask* — call
  // sites go through emitAsyncCall like non-generic async callees.
  isAsync: Bool
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

/// A `Ctx.varEnumTypes` rebind recorded BEFORE `registerVarEnumType`
/// overwrites `name`'s mapping, so the enclosing scope's mapping can be
/// restored on scope exit (#6994, mirroring MSIL's `ScopeUndoMsil`
/// "enumty" kind / #6595 fix). `priorHint` is `None` when `name` had no
/// mapping before this scope's binding (restore = clear).
record NEnumTypeUndo {
  name: String
  priorHint: Option[String]
}

/// A `Ctx.varSlots`/`Ctx.varTypes` rebind recorded BEFORE `bindLocal`
/// overwrites `name`'s mapping, so an enclosing scope's binding can be
/// restored on scope exit — the general native shadowing gap `varEnumTypes`
/// (above) inherited: `bindLocal` always allocates a fresh slot for a
/// rebind (never reuses an enclosing scope's slot the way MSIL's
/// `allocSlotMsil` does), but never restored the enclosing name->slot/type
/// mapping either, so a nested block's same-named shadow permanently
/// leaked its slot past the block's own exit (mirrors MSIL's D-progress-602
/// / #5191 fix — native never got the equivalent). `priorSlot`/`priorType`
/// are `None` when `name` had no mapping before this scope's binding
/// (restore = clear).
record NBindingUndo {
  name: String
  priorSlot: Option[String]
  priorType: Option[NType]
}

/// Per-module mutable codegen state, threaded through all lowering.
/// Tickers use the singleton-list idiom (`.count` is the next index)
/// shared with `Jvm.Codegen.FuncCtx`.
record Ctx {
  mainPkg: String
  // Target pointer width in bytes (ptrBytesForTriple).
  ptrBytes: Int
  /// The target triple, which decides how a by-value record crosses the C
  /// boundary (#8009); empty when the caller named none.
  abiTriple: String = ""
  tmpTicker: List[Int]
  labelTicker: List[Int]
  strTicker: List[Int]
  // Current function state.
  varSlots: Map[String, String]
  varTypes: Map[String, NType]
  // A local/param's declared enum type's bare name, when its type
  // annotation names a known enum (#6969) — enums erase to bare `NI32`
  // at the IR level, indistinguishable from a real `Int`/`Char` by
  // `varTypes` alone, so a match scrutinee needs this SEPARATE hint to
  // scope a bare-case-name pattern test to its own enum instead of any
  // same-named case in the whole bundle. Absent (no entry) means "not
  // known to be a specific enum" — never a `Map.add` duplicate-key
  // panic on rebind, since every write site removes first.
  varEnumTypes: Map[String, String]
  // #6237: `Char` and `Int` both erase to `NI32` with no runtime tag
  // (native/plan/03-type-mapping.md), so `NVal.ty` alone can never
  // distinguish them. Local bindings with an explicit `Char` type
  // annotation (or a `Char`-literal initializer) are recorded here so
  // `.toString()` and `String + Char` concatenation — the two codegen
  // shapes that must actually tell Char and Int apart — can consult the
  // AST at the use site instead of the erased `NVal`. Best-effort: covers
  // literals and one level of variable binding, not full type inference
  // (an unannotated function parameter or a further-removed alias stays
  // untracked, exactly like every other unannotated binding in this
  // backend's varTypes/varSlots).
  varIsChar: Map[String, Bool]
  allocas: List[NInsn]
  loopBreak: List[String]
  loopCont: List[String]
  // Module accumulators.
  globals: List[NGlobalDef]
  sigs: Map[String, NFuncSig]
  // Per-package `import Std.String` gate (#6588 review follow-up, #6752):
  // whether the package's own source file has `import Std.String` in
  // scope, mirroring `Msil.Codegen.pkgImports` / `Jvm.Codegen.importsStdString`.
  // Consulted by `.indexOf`'s scalar-method arm so the import-sensitive
  // `Option[Int]` UFCS form (`Lyric.TypeChecker.stringIndexOfMember`) is
  // never shadowed by the raw `Int`-returning runtime intrinsic.
  pkgImportsStdString: Map[String, Bool]
  // Bare function keys (`name/arity`) that more than one package declares, with
  // every declaration in registration order, and the packages each package's
  // source file imports. `bareSig` resolves such a key to the declaration in an
  // imported package, as source scoping does, instead of whichever registered
  // first (`Std.Char.toLower` versus `Std.String.toLower`).
  sigAlts: Map[String, List[NFuncSig]]
  pkgImports: Map[String, List[String]]
  // The parameter count of the method each call leaving out a defaulted
  // argument resolved to, keyed `<pkg>|<methodCallSiteKey>` (each unit's
  // `methodCallArities` under its package): a method call looks its
  // overload up by this count rather than by the arguments written (#7828).
  methodCallArities: Map[String, Int]
  // Package the function being lowered belongs to (self-package call
  // resolution).
  curPkg: List[String]
  // The package a function specialised from another package's generic was
  // written in (its `__lyric_origin`), else empty: its method calls'
  // resolutions are keyed `<pkg>|<origin>|<methodCallSiteKey>`
  // (`Lyric.Pipeline.foreignMethodCallArities`).
  curOrigin: List[String]
  // Return type of the function being lowered (singleton list).
  curRet: List[NType]
  // Module-level `val`/`const` bindings by name (#5977 part 2), for use-site
  // inlining (native has no static-global storage yet).
  moduleVals: Map[String, ModuleValDef]
  // The static globals referenced so far, in discovery order: each entry is the
  // IR name of a hoisted initializer function (`mvInitFnName`), its global
  // being `mv.<name>`, with its type in the parallel `mvInitTys`. Shared by
  // every function context, like `globals`.
  mvInits: List[String]
  mvInitTys: List[NType]
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
  // Union equality functions already synthesised (or being synthesised),
  // by union IR name.
  unionEqFns: Map[String, Bool]
  // Generic functions (N3.1): declarations by call key, instantiation
  // cache, and reverse instantiation metadata for unification.
  genericFnDefs: Map[String, FunctionDecl]
  genericFnPkg: Map[String, String]
  fnInstCache: Map[String, NFnInst]
  instMeta: Map[String, NInstInfo]
  // One-shot expected type for the call `lowerExprExpecting` is about to
  // lower (0 or 1 element). `lowerCallEx` takes it on entry, before any
  // argument is lowered, so only that call's own generic instantiation can
  // use it to bind type parameters that appear only in its return type (#7413).
  pendingCallRetWant: List[NType]
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
  // `ifaceBareNameOwners` maps a bare interface name to the qualified name
  // that currently owns it in `ifaceInfos`, so `registerIfaceInfo` (#4900)
  // can detect two different in-scope interfaces sharing a bare name
  // (reachable via a multi-package `--target native` build, #6809) and fail
  // loudly instead of silently letting the second registration win.
  ifaceInfos: Map[String, NIfaceInfo]
  ifaceBareNameOwners: Map[String, String]
  ifaceVtables: Map[String, String]
  // Direct-receiver impl-method resolution (#7600, review follow-up
  // #7627). Maps the receiver's PACKAGE-QUALIFIED
  // `<pkg>.<Record>.<methodName>/<arity>` (matching `tyName` — the same
  // qualification every other `lowerUfcsCall` tier already uses) to the
  // `ctx.sigs` key of the collision-free impl-method symbol
  // (`implMethodName`) a call through the CONCRETE record receiver
  // resolves to. A bare (unqualified) record name would alias two
  // same-named records in different packages of a multi-package native
  // bundle to whichever package's impl happened to register first
  // (#7627). Populated by `registerImplDirectMethods` in the same
  // unit/impl/member order the type checker's own `tbl.impls` builds up
  // (`methodCandidatesFor`), so the first-declared `impl` wins a
  // same-named-method tie the same way the checker's first-match
  // selection does. A record's own-body method can never collide with an
  // impl method of the same name any more — the type checker rejects
  // that shape as T0139 (#7626) — so this map holds impl methods only,
  // and this has to run BEFORE the bare `curPkg + "." + name` lookup in
  // `lowerUfcsCall`: that lookup matches ANY same-arity function in the
  // current package regardless of its receiver type (it does not verify
  // the match is actually a method of THIS record), so an unrelated free
  // function sharing the impl method's bare name and arity would
  // otherwise shadow it.
  implDirectMethods: Map[String, String]
  // Protected-type record irNames (N3.4): marks which `recordDefs` entries
  // are protected types (a trailing `__mutex: i8*` field, construction
  // routes through `lowerProtectedConstructArgs`) rather than plain records.
  protectedRecNames: Map[String, Bool]
  // Package-qualified record names that keep the heap form even when every
  // field is by-value: opaque types and the target of any `impl I for R` (an
  // interface box holds a heap object, docs/67 §4.2; boxing a value record at
  // the upcast is #8010).
  heapOnlyRecs: Map[String, Bool]
  // By-value record boxes (`__box<R>`) already defined: a by-value record
  // stored in a List/Map/Task slot lives in a refcounted box.
  byValueBoxes: Map[String, Bool]
  // Per-function: the stack slot already holding a spilled inline-union value,
  // by the SSA name of the value (`pinInlineUnion`), so a match addresses its
  // scrutinee once rather than once per arm.
  inlineAddrs: Map[String, String]
  // ARC state (per function).  `scopeRefs` stacks the ref-typed locals
  // each lexical scope owns; `tempScopes` stacks the owned temporaries
  // of each evaluation region; the depth lists snapshot both stacks at
  // loop entry so break/continue release exactly the loop-inner scopes.
  scopeRefs: List[List[NOwnedLocal]]
  tempScopes: List[List[NOwnedTemp]]
  loopVarDepth: List[Int]
  loopTempDepth: List[Int]
  // Labelled loops currently being lowered (#7349): label -> the loop's index
  // in loopBreak/loopCont/loopVarDepth/loopTempDepth.
  loopLabelIndex: Map[String, Int]
  // `defer` (P2.D1): pending deferred `Block`s per lexical scope, mirroring `scopeRefs` — see D-N-020.
  deferStack: List[List[Block]]
  // `varEnumTypes` scope-undo log, one list per open lexical scope, mirroring
  // `scopeRefs`/`deferStack` (#6994, MSIL analog: `FuncCtx.scopeUndoMsil`'s
  // "enumty" entries / #6595). `registerVarEnumType` pushes an undo entry
  // onto the innermost open scope before it rebinds a name; `popVarScope`
  // replays that scope's entries (innermost binding first) to restore
  // whatever mapping the block's own bindings shadowed.
  enumTypeUndo: List[List[NEnumTypeUndo]]
  // `varSlots`/`varTypes` scope-undo log (general shadowing fix, mirroring
  // MSIL's D-progress-602/#5191, ported to native alongside #6994's
  // `enumTypeUndo` above since the two bugs are otherwise inseparable: a
  // same-named shadow rebinds both maps together, so restoring only the
  // enum hint while the slot/type mapping still leaks left the outer
  // binding reading the inner shadow's storage). Same push/pop shape as
  // `enumTypeUndo`.
  bindingUndo: List[List[NBindingUndo]]
  // Async coroutines (stage B2).  `taskElems` maps `__task<...>` struct
  // names to their element NType (mirrors `listElems`); `curAsyncTask` is
  // a per-function cell holding the SSA name of the current coroutine's
  // LyricTask* (empty = not lowering an async body); `usesAsync` is a
  // module-shared cell marking that coro wrappers/attrs must be emitted.
  taskElems: Map[String, NType]
  curAsyncTask: List[String]
  usesAsync: List[Int]
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
/// Every heap object starts with the ARC header `{ i32 rc, i32 weak, i8* dtor }`,
/// mirroring the C `LyricObjectHeader`.  The three fields are named in the LLVM
/// struct (rather than leaving `weak` in LP64 alignment padding) so the layout
/// is identical on every target pointer width, including wasm32 where there is
/// no padding.  A field declared after the header is at GEP index
/// `arcHeaderSlots + k`.
val arcRcSlot: Long = 0i64

val arcDtorSlot: Long = 2i64

val arcHeaderSlots: Int = 3

func addArcHeader(fields: in List[NType]) {
  fields.add(NI32)
  fields.add(NI32)
  fields.add(NPtr(pointee = NI8))
}

/// GEP index of the closure's function-pointer slot (the first field after
/// the header) and of its first capture.
val closureFnSlot: Long = 3i64

val closureCaptureBase: Int = 4

/// GEP indices of a union's discriminant and its payload word array.
val unionDiscSlot: Long = 3i64

val unionPayloadSlot: Long = 5i64

pub func lyricStringNType(): NType {
  val fields: List[NType] = newList()
  addArcHeader(fields)
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

/// Whether a surface `TypeExpr` names `Char` (#6237's Char/Int erasure
/// tracking — see `Ctx.varIsChar`'s header comment).
func isCharTypeExpr(te: in TypeExpr): Bool {
  match te.kind {
    case TRef(path) -> path.segments.count == 1 and path.segments[0] == "Char"
    case TParen(inner) -> isCharTypeExpr(inner)
    case TRefined(under, _) -> isCharTypeExpr(TypeExpr(kind = TRef(path = under), span = te.span))
    case _ -> false
  }
}

/// Best-effort static "is this expression a `Char`" check, consulted only
/// where `NVal.ty` alone cannot tell (`Char` and `Int` both erase to
/// `NI32` — see `Ctx.varIsChar`'s header comment): a `Char` literal, a
/// parenthesised char expression, or a variable this backend recorded as
/// char-typed at its binding site (`markVarChar`, called from `SLocal`
/// lowering and parameter binding). Anything else — an unannotated
/// parameter, a further call result, a record field — is conservatively
/// `false`, exactly like this backend's other best-effort local tracking
/// (`varTypes`/`varSlots` are equally incomplete for exotic shapes).
func exprIsCharTyped(ctx: in Ctx, e: in Expr): Bool {
  match e.kind {
    case ELiteral(lit) -> match lit { case LChar(_) -> true; case _ -> false }
    case EParen(inner) -> exprIsCharTyped(ctx, inner)
    case EPath(path) -> {
      if path.segments.count == 1 {
        match mapGet(ctx.varIsChar, path.segments[0]) {
          case Some(v) -> v
          case None -> false
        }
      } else {
        false
      }
    }
    // `s[i]` bracket indexing on a String receiver ALWAYS yields `Char`
    // (`indexElementType`'s `TyPrim(PtString) -> Char` rule has no other
    // outcome) — unlike a `List[T]`/`Map[K,V]` index, which could
    // genuinely be `Int`. Recognising this needs to tell "the receiver is
    // a String" apart from "the receiver is a List/Map", which — unlike
    // Char vs Int — this backend's ordinary `varTypes`/literal shape
    // already distinguishes (`exprIsStringTyped`).
    case EIndex(recv, _) -> exprIsStringTyped(ctx, recv)
    case _ -> false
  }
}

/// Whether `e` is a plain String-typed expression, per this backend's
/// existing (unambiguous) String tracking — used only to disambiguate
/// `s[i]`'s receiver from a `List`/`Map` index in `exprIsCharTyped` above.
func exprIsStringTyped(ctx: in Ctx, e: in Expr): Bool {
  match e.kind {
    case ELiteral(lit) -> match lit {
      case LString(_) -> true
      case LTripleString(_) -> true
      case LRawString(_) -> true
      case _ -> false
    }
    case EInterpolated(_) -> true
    case EParen(inner) -> exprIsStringTyped(ctx, inner)
    case EPath(path) -> {
      if path.segments.count == 1 {
        match mapGet(ctx.varTypes, path.segments[0]) {
          case Some(t) -> isStringNType(t)
          case None -> false
        }
      } else {
        false
      }
    }
    case _ -> false
  }
}

/// Records (or clears) `name`'s char-ness for `exprIsCharTyped`, mirroring
/// the remove-then-add pattern `bindLocal` uses for `varTypes`/`varSlots`
/// (a rebound name must not see its old entry).
func markVarChar(ctx: in Ctx, name: in String, isChar: in Bool): Unit {
  if ctx.varIsChar.containsKey(name) {
    ctx.varIsChar.remove(name)
  }
  ctx.varIsChar.add(name, isChar)
}

/// Char-ness of a `val`/`let`/`var` binding: an explicit `Char` type
/// annotation wins outright (it is authoritative regardless of the
/// initializer's shape); otherwise fall back to the initializer
/// expression's own char-ness (`exprIsCharTyped`).
func charnessOfBinding(ctx: in Ctx, tyOpt: in Option[TypeExpr], init: in Expr): Bool {
  match tyOpt {
    case Some(te) -> isCharTypeExpr(te)
    case None -> exprIsCharTyped(ctx, init)
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
      if n == "Double" {
        return NDouble
      }
      if n == "Float" {
        return NFloat
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
    // `Never` (a function that does not return, `Std.Environment.exitCode`): the
    // function lowers as a void function; its callers use the call as a
    // statement, and the body ends in a call that does not return.
    case TNever -> NVoid
    // A bare `Self` reaching this fallback is always an INTERFACE's own
    // declared method signature (#7585): a record/protected impl method's
    // own `Self` is substituted to the concrete type before it ever reaches
    // codegen (`substSelfInType`/`substSelfInFn`/`collectImplMethods`), so
    // the only remaining caller is `registerInterfaceTypes` resolving the
    // vtable slot's param/return types. Every implementer of `Self` on this
    // backend (record or protected type) is a heap-boxed, pointer-width
    // object (`03-type-mapping.md`), so erasing to a raw `i8*` — the SAME
    // erased representation the interface box's own `obj` slot already
    // uses — is ABI-compatible with any concrete impl's pointer type via
    // the unchecked function-pointer bitcast `ifaceVtableInitStr` already
    // performs for every vtable slot (see D-progress-1016).
    case TSelf -> NPtr(pointee = NI8)
    case TParen(inner) -> typeExprToNType(inner)
    // An inline range type (`Int range 0 ..= 3`) is its base type.
    case TRefined(under, _) -> typeExprToNType(TypeExpr(kind = TRef(path = under), span = te.span))
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
    case _ -> panic(
      "Lyric.LlvmCodegen: " + typeFormName(te) + " at " + te.span.startPos.line.toString() + ":" +
        te.span.startPos.column.toString() +
        " is not yet supported for --target native (Phase N1)"
    )
  }
}

// The user-facing name of a type form `typeExprToNType` cannot lower, for its diagnostic.
func typeFormName(te: in TypeExpr): String {
  match te.kind {
    case TArray(_, _) -> "an array type here"
    case TSlice(_) -> "a slice type here"
    case TRefined(_, _) -> "a range-refined type"
    case TTuple(_) -> "a tuple type here"
    case TNullable(_) -> "a nullable type (T?)"
    case TNever -> "the Never type"
    case TError -> "an erroneous type"
    case _ -> "this type form"
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
      val joined = qualifiedPathJoin(ctx, path)
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
      match te.kind {
        case TGenericApp(gh, _) -> {
          if lastSeg(gh) != "NativePtr" {
            panic(
              "Lyric.LlvmCodegen: generic type '" + lastSeg(gh) + "' (in " + ctx.curPkg[0] + " at line " +
                te.span.startPos.line.toString() +
                ") cannot be instantiated for --target native: a field or argument type of it has no native lowering"
            )
          }
        }
        case _ -> {
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
    case TArray(_, _) -> {
      val emptyNames: List[String] = newList()
      val emptyTys: List[NType] = newList()
      match typeToNEnvOpt(ctx, te, emptyNames, emptyTys) {
        case Some(t) -> return t
        case None -> panic(
          "error[N0020] " + te.span.startPos.line.toString() + ":" + te.span.startPos.column.toString() +
            ": this `array[N, T]` has no native layout: its length must be a compile-time constant (a value-generic length is not supported) and its element type must have a native lowering (docs/67 §4.3)"
        )
      }
    }
    case TParen(inner) -> typeToN(ctx, inner)
    case TRefined(under, _) -> typeToN(ctx, TypeExpr(kind = TRef(path = under), span = te.span))
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
      val joined = qualifiedPathJoin(ctx, path)
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
      if n == "Double" {
        return Some(value = NDouble)
      }
      if n == "Float" {
        return Some(value = NFloat)
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
    case TArray(_, _) -> {
      val emptyNames: List[String] = newList()
      val emptyTys: List[NType] = newList()
      typeToNEnvOpt(ctx, te, emptyNames, emptyTys)
    }
    case TUnit -> Some(value = NVoid)
    case TParen(inner) -> typeToNOpt(ctx, inner)
    case TRefined(under, _) -> typeToNOpt(ctx, TypeExpr(kind = TRef(path = under), span = te.span))
    case _ -> None
  }
}

/// `modulePathJoin(path.segments)`, except a single-segment (unqualified)
/// path is qualified with the CALLER's OWN `ctx.curPkg[0]` instead of
/// being left bare (#7627). An unqualified type reference such as `self:
/// Widget` or `Widget(n = 10)` always means the record named `Widget` IN
/// THE CURRENT PACKAGE — `modulePathJoin` alone returns just `"Widget"`
/// for a one-segment path, which is indistinguishable from the GLOBAL
/// bare `"Widget"` key every package's `Widget` record also registers
/// (`addRecKey`'s "first-wins shadowing across packages" fallback slot);
/// `lookupHeapType(ctx, joined, bare)` tries `joined` first, so passing
/// the truly qualified name here means the caller's OWN package's
/// `Widget` is always preferred, and the plain bare key is only ever
/// reached as a last resort (kept for forms this function does not
/// itself qualify, e.g. a name synthesised without any package context).
func qualifiedPathJoin(ctx: in Ctx, path: in ModulePath): String {
  if path.segments.count == 1 and ctx.curPkg.count > 0 {
    ctx.curPkg[0] + "." + path.segments[0]
  } else {
    modulePathJoin(path.segments)
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

/// The reserved `Ctx.varEnumTypes`/`scrutineeHasCase` sentinel meaning
/// "this scrutinee's declared type is `Int` or `Char` — concretely
/// known NOT to be any enum." Never collides with a real enum's bare
/// name: enum names are identifiers (lexer-restricted to XID_Start/
/// XID_Continue), which can't start with `#`.
val nonEnumScrutHint = "#nonenum"

/// `te`'s SCRUTINEE HINT for `Ctx.varEnumTypes`/`scrutineeHasCase`'s
/// NI32 disambiguation (#6740/#6969/#6976): the bare enum type name
/// when `te` is a `TRef` naming a known enum; `nonEnumScrutHint` when
/// `te` is concretely `Int` or `Char` (never any enum, by construction);
/// `""` (truly unknown — no declared type, or a type this function
/// doesn't classify) otherwise. Three-way, not two-way, because
/// `scrutineeHasCase` needs to tell "positively not an enum" (#6969:
/// never fall back to a bundle-wide guess) apart from "no information
/// at all" (#6976: fall back to the pre-#6969 bundle-wide check, same
/// as `Msil.Codegen`'s own accepted trade-off, rather than dropping
/// enum-case pattern support for hint-less scrutinees like a direct
/// call-result match).
func enumNameOfTypeExpr(ctx: in Ctx, te: in TypeExpr): String {
  match te.kind {
    case TRef(path) -> {
      val joined = modulePathJoin(path.segments)
      val bare = lastSeg(path)
      if ctx.enumDefs.containsKey(joined + ".__enum") or ctx.enumDefs.containsKey(bare + ".__enum") {
        bare
      } else if bare == "Int" or bare == "Char" {
        nonEnumScrutHint
      } else {
        ""
      }
    }
    case TParen(inner) -> enumNameOfTypeExpr(ctx, inner)
    case _ -> ""
  }
}

/// Record (or clear) `name`'s scrutinee hint in `ctx.varEnumTypes` (an
/// enum's bare name, `nonEnumScrutHint`, or no entry for "unknown") —
/// remove-then-add so a rebind of an already-tracked name never throws
/// `Map.add`'s duplicate-key error. Scope-undo-logged (#6994, mirroring
/// MSIL's `registerVarEnumTypeMsil`/#6595 fix): when an open lexical
/// scope exists (`enumTypeUndo` non-empty), the mapping this call is
/// about to overwrite is recorded on that scope's undo log first, so
/// `popVarScope` can restore it — an inner block's same-named
/// enum-typed shadow no longer permanently clobbers an outer scope's
/// mapping past the inner block's exit. A call before any scope is
/// pushed (function-parameter registration) has nothing to restore to
/// and is left unlogged, exactly like `varTypes`/`varSlots`' pre-existing,
/// separately-tracked "no scope-undo" gap (out of scope here).
func registerVarEnumType(ctx: in Ctx, name: in String, scrutHint: in String): Unit {
  if ctx.enumTypeUndo.count > 0 {
    val priorHint: Option[String] = mapGet(ctx.varEnumTypes, name)
    ctx.enumTypeUndo[ctx.enumTypeUndo.count - 1].add(NEnumTypeUndo(name = name, priorHint = priorHint))
  }
  if ctx.varEnumTypes.containsKey(name) {
    ctx.varEnumTypes.remove(name)
  }
  if scrutHint.length > 0 {
    ctx.varEnumTypes.add(name, scrutHint)
  }
}

/// `registerVarEnumType` from an `SLocal` binding's OPTIONAL type
/// annotation — a bare `val x = ...` (no annotation) clears any prior
/// enum-type mapping for `name`, since there's no declared type to
/// derive a hint from.
func registerVarEnumTypeFromOpt(ctx: in Ctx, name: in String, tyOpt: in Option[TypeExpr]): Unit {
  val enumHint = match tyOpt { case Some(te) -> enumNameOfTypeExpr(ctx, te); case None -> "" }
  registerVarEnumType(ctx, name, enumHint)
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

/// The type of a registered record's value.  A heap record is a pointer whose
/// struct body carries the ARC header (rc, weak, dtor) followed by the fields,
/// so GEP field indices are `arcHeaderSlots + declIndex`; a by-value record is
/// the header-less struct itself, read with `extractvalue`.
func recPtrType(ri: in NRecInfo): NType {
  if ri.byValue {
    return NStruct(name = ri.irName, fields = layoutFieldTys(ri.fieldTys))
  }
  val fields: List[NType] = newList()
  addArcHeader(fields)
  var i = 0
  while i < ri.fieldTys.count {
    fields.add(ri.fieldTys[i])
    i = i + 1
  }
  NPtr(pointee = NStruct(name = ri.irName, fields = fields))
}

/// The pointer type for a registered union: header, i32 discriminant,
/// i32 pad (so the payload is 8-aligned on LP64), then the payload words.
func unionPtrType(ui: in NUnionInfo): NType {
  if ui.inline {
    return NStruct(name = ui.irName, fields = unionInlineFields(ui.payloadWords))
  }
  NPtr(pointee = NStruct(name = ui.irName, fields = unionBodyFields(ui.payloadWords)))
}

/// The struct body of an inline union value: discriminant, pad, payload words.
func unionInlineFields(payloadWords: in Int): List[NType] {
  val fields: List[NType] = newList()
  fields.add(NI32)
  fields.add(NI32)
  fields.add(NArray(elem = NI64, size = payloadWords))
  fields
}

/// The struct definition's body: with the ARC header for a heap union.
func unionStructFields(ui: in NUnionInfo): List[NType] {
  if ui.inline {
    return unionInlineFields(ui.payloadWords)
  }
  unionBodyFields(ui.payloadWords)
}

/// GEP indices of the discriminant and payload words of a union object.
func unionDiscIdx(ui: in NUnionInfo): Long {
  if ui.inline {
    return 0i64
  }
  unionDiscSlot
}

func unionPayloadIdx(ui: in NUnionInfo): Long {
  if ui.inline {
    return 2i64
  }
  unionPayloadSlot
}

func unionBodyFields(payloadWords: in Int): List[NType] {
  val fields: List[NType] = newList()
  addArcHeader(fields)
  fields.add(NI32)
  fields.add(NI32)
  fields.add(NArray(elem = NI64, size = payloadWords))
  fields
}

/// Pointer width in bytes for a target triple.  Only used to size union payload
/// word arrays at type-definition time; allocation sizes come from LLVM
/// (`NSizeOf`).  wasm32 is the one 32-bit target the backend supports.
func ptrBytesForTriple(triple: in String): Int {
  if Str.startsWith(triple, "wasm32") {
    return 4
  }
  8
}

/// Natural-alignment sizes (x86-64 / AArch64 System V, wasm32) for the types
/// that can appear in heap-struct fields (aggregates are always behind
/// pointers).
func sizeOfN(ctx: in Ctx, t: in NType): Int {
  match t {
    case NI1 -> 1
    case NI8 -> 1
    case NI32 -> 4
    case NI64 -> 8
    case NDouble -> 8
    case NFloat -> 4
    case NPtr(_) -> ctx.ptrBytes
    case NArray(elem, size) -> sizeOfN(ctx, elem) * size
    // A Unit field (e.g. `Result[Unit, E]`'s Ok payload) occupies one
    // undef byte — see layoutFieldTys.
    case NVoid -> 1
    // A by-value record (docs/67 §4.2): C layout of its fields.  Looked up by
    // name because a struct value's own `fields` may come from a stub.
    case NStruct(name, _) -> structSize(ctx, byValueLayoutOf(ctx, name))
    case _ -> panic("Lyric.LlvmCodegen: this aggregate type cannot be sized for a native heap layout")
  }
}

/// The layout field types of the by-value record `name`.
func byValueLayoutOf(ctx: in Ctx, name: in String): List[NType] {
  match mapGet(ctx.unionDefs, name) {
    case Some(ui) -> {
      if ui.inline {
        return unionInlineFields(ui.payloadWords)
      }
    }
    case None -> {
    }
  }
  match mapGet(ctx.recordDefs, name) {
    case Some(ri) -> {
      if ri.byValue {
        return layoutFieldTys(ri.fieldTys)
      }
    }
    case None -> {
    }
  }
  panic("Lyric.LlvmCodegen: internal — '" + name + "' is not a registered by-value record")
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

func alignOfN(ctx: in Ctx, t: in NType): Int {
  match t {
    case NArray(elem, _) -> alignOfN(ctx, elem)
    case NStruct(name, _) -> {
      val fields = byValueLayoutOf(ctx, name)
      var maxA = 1
      var i = 0
      while i < fields.count {
        val a = alignOfN(ctx, fields[i])
        if a > maxA {
          maxA = a
        }
        i = i + 1
      }
      maxA
    }
    case _ -> sizeOfN(ctx, t)
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
func structSize(ctx: in Ctx, fields: in List[NType]): Int {
  var off = 0
  var maxA = 1
  var i = 0
  while i < fields.count {
    val a = alignOfN(ctx, fields[i])
    if a > maxA {
      maxA = a
    }
    off = roundUpTo(off, a)
    off = off + sizeOfN(ctx, fields[i])
    i = i + 1
  }
  roundUpTo(off, maxA)
}

/// A `NativeWeak[T]` value — a pointer to the synthesised empty `__weak<…>`
/// struct.  Weak values are ARC-tracked like strong refs (registered as
/// temps, released at scope end, released as record/union fields), but the
/// retain/release they emit is the weak-count variant (`lyric_weak_retain` /
/// `lyric_weak_release`), so the object header outlives the last strong ref
/// while any weak reference is held (issue #5504).
func isWeakNType(t: in NType): Bool {
  match t {
    case NPtr(pointee) -> {
      match pointee {
        case NStruct(name, _) -> Str.startsWith(name, "__weak<")
        case _ -> false
      }
    }
    case _ -> false
  }
}

/// ARC-managed values are pointers to named structs (LyricString, records,
/// unions, and `NativeWeak[T]`).  Raw c-strings (`i8*`) and `NativePtr[T]`
/// are not.  Weak values ARE refs (so the ownership machinery counts them);
/// `emitRetain` / `emitRelease` dispatch to the weak-count runtime helpers
/// for them.
func isRefNType(t: in NType): Bool {
  match t {
    case NPtr(pointee) -> {
      match pointee {
        case NStruct(name, fields) -> isArcHeaderFields(fields) or Str.startsWith(name, "__weak<")
        case _ -> false
      }
    }
    case _ -> false
  }
}

/// Whether a struct body starts with the ARC header `{ i32, i32, i8* }`: true
/// of every heap object, never of a by-value record, so a raw `NativePtr` to a
/// by-value record (`NPtr` of its struct) is not an ARC-managed reference
/// (docs/67 §4.2).  A `NativeWeak[T]` marker has no body and is recognised by
/// its name.
func isArcHeaderFields(fields: in List[NType]): Bool {
  if fields.count < 3 {
    return false
  }
  match fields[0] {
    case NI32 -> {
    }
    case _ -> return false
  }
  match fields[1] {
    case NI32 -> {
    }
    case _ -> return false
  }
  match fields[2] {
    case NPtr(pointee) -> match pointee { case NI8 -> true; case _ -> false }
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
  val fn = if isWeakNType(v.ty) { "lyric_weak_retain" } else { "lyric_retain" }
  insns.add(NCallVoid(fn = NGlobal(name = fn), args = arg1(NPtr(pointee = NI8), p)))
}

func emitRelease(ctx: in Ctx, insns: in List[NInsn], v: in NVal): Unit {
  val p = asI8Ptr(ctx, insns, v)
  val fn = if isWeakNType(v.ty) { "lyric_weak_release" } else { "lyric_release" }
  insns.add(NCallVoid(fn = NGlobal(name = fn), args = arg1(NPtr(pointee = NI8), p)))
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
  val freshEnumUndo: List[NEnumTypeUndo] = newList()
  ctx.enumTypeUndo.add(freshEnumUndo)
  val freshBindingUndo: List[NBindingUndo] = newList()
  ctx.bindingUndo.add(freshBindingUndo)
}

/// Restore the mappings this scope's `registerVarEnumType` calls
/// shadowed (innermost binding first), then drop the scope's undo log.
func restoreEnumTypeScopeAt(ctx: in Ctx, idx: in Int): Unit {
  val undo = ctx.enumTypeUndo[idx]
  var i = undo.count - 1
  while i >= 0 {
    val name = undo[i].name
    if ctx.varEnumTypes.containsKey(name) {
      ctx.varEnumTypes.remove(name)
    }
    match undo[i].priorHint {
      case Some(h) -> ctx.varEnumTypes.add(name, h)
      case None -> {
      }
    }
    i = i - 1
  }
}

/// Restore the `varSlots`/`varTypes` mappings this scope's `bindLocal`
/// calls shadowed (innermost binding first), then drop the scope's undo
/// log.
func restoreBindingScopeAt(ctx: in Ctx, idx: in Int): Unit {
  val undo = ctx.bindingUndo[idx]
  var i = undo.count - 1
  while i >= 0 {
    val name = undo[i].name
    if ctx.varSlots.containsKey(name) {
      ctx.varSlots.remove(name)
    }
    match undo[i].priorSlot {
      case Some(s) -> ctx.varSlots.add(name, s)
      case None -> {
      }
    }
    if ctx.varTypes.containsKey(name) {
      ctx.varTypes.remove(name)
    }
    match undo[i].priorType {
      case Some(t) -> ctx.varTypes.add(name, t)
      case None -> {
      }
    }
    i = i - 1
  }
}

/// Run scope `idx`'s pending `defer` blocks in reverse declaration order, before that scope's ARC releases (D-N-020).
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
  restoreEnumTypeScopeAt(ctx, ctx.enumTypeUndo.count - 1)
  ctx.enumTypeUndo.removeAt(ctx.enumTypeUndo.count - 1)
  restoreBindingScopeAt(ctx, ctx.bindingUndo.count - 1)
  ctx.bindingUndo.removeAt(ctx.bindingUndo.count - 1)
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
/// unregistered/retained by the caller of this helper); also runs each scope's pending `defer` blocks first (D-N-020).
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
/// scopes opened inside the innermost loop (not the loop-outer ones); also runs each scope's pending `defer` blocks first (D-N-020).
func enterLoopLabelNative(ctx: in Ctx, label: in Option[String]): Option[Int] {
  match label {
    case Some(l) -> {
      val prev = mapGet(ctx.loopLabelIndex, l)
      ctx.loopLabelIndex[l] = ctx.loopBreak.count
      prev
    }
    case None -> None
  }
}

// Restores the entry a nested loop's label shadowed: a loop in a `defer` or
// lambda body may reuse an enclosing loop's label (#7394).
func exitLoopLabelNative(ctx: in Ctx, label: in Option[String], prev: in Option[Int]): Unit {
  match label {
    case Some(l) -> match prev {
      case Some(p) -> {
        ctx.loopLabelIndex[l] = p
      }
      case None -> {
        ctx.loopLabelIndex.remove(l);
        ()
      }
    }
    case None -> ()
  }
}

// The type checker (T0130) guarantees a `break`/`continue` sits in a loop and
// that its label names an enclosing one.
func loopIndexForLabelNative(ctx: in Ctx, label: in Option[String]): Int {
  match label {
    case None -> {
      if ctx.loopBreak.count == 0 {
        panic("Lyric.LlvmCodegen: 'break'/'continue' outside a loop (compiler bug: T0130 should have rejected it)")
      }
      ctx.loopBreak.count - 1
    }
    case Some(l) -> match mapGet(ctx.loopLabelIndex, l) {
      case Some(i) -> i
      case None -> panic(
        "Lyric.LlvmCodegen: no enclosing loop labelled '" + l +
          "' (compiler bug: T0130 should have rejected it)"
      )
    }
  }
}

// Releases and runs the defers of every scope inside loop `li` (for a labelled
// jump, that includes each inner loop it exits).
func releaseForLoopExit(ctx: in Ctx, insns: in List[NInsn], li: in Int): Unit {
  val varFloor = ctx.loopVarDepth[li]
  val tempFloor = ctx.loopTempDepth[li]
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

func paramDefaultsOf(params: in List[Param]): List[Option[Expr]] {
  val ds: List[Option[Expr]] = newList()
  for p in params {
    ds.add(p.dflt)
  }
  ds
}

func noParamDefaults(n: in Int): List[Option[Expr]] {
  val ds: List[Option[Expr]] = newList()
  var i = 0
  while i < n {
    val none: Option[Expr] = None
    ds.add(none)
    i = i + 1
  }
  ds
}

/// The fewest arguments a call to `sig` may write: the parameters before the
/// trailing run of defaulted ones.
func requiredArgCount(sig: in NFuncSig): Int {
  var n = sig.paramDefaults.count
  while n > 0 {
    match sig.paramDefaults[n - 1] {
      case Some(_) -> {
        n = n - 1
      }
      case None -> return n
    }
  }
  n
}

func paramModesOf(params: in List[Param]): List[ParamMode] {
  val modes: List[ParamMode] = newList()
  var i = 0
  while i < params.count {
    modes.add(params[i].mode)
    i = i + 1
  }
  modes
}

/// `out`/`inout` are unsupported on `extern func` (C-ABI) declarations: the
/// native FFI boundary already has an explicit pointer idiom
/// (`NativePtr[T]`), and no `_kernel_native/` package declares one. Loud
/// diagnostic instead of silently treating the C symbol's parameter as
/// pass-by-value (which would be a real ABI mismatch against the address
/// a caller-side by-ref lowering would otherwise pass).
func checkExternNoByRefParams(ef: in ExternFuncDecl): Unit {
  var i = 0
  while i < ef.params.count {
    match ef.params[i].mode {
      case PMIn -> {
      }
      case _ -> panic(
        "Lyric.LlvmCodegen: extern func '" + ef.name + "' declares '" + ef.params[i].name +
          "' as out/inout, which is not supported for --target native extern declarations (use NativePtr[T] for C-ABI pointer parameters)"
      )
    }
    i = i + 1
  }
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
  val defaulted: List[NFuncSig] = newList()
  val defaultedKeys: List[String] = newList()
  val defaultedBare: List[String] = newList()
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
        paramModes = paramModesOf(fn.params),
        paramDefaults = paramDefaultsOf(fn.params),
        retTy = fn.ret,
        isExternSym = false,
        isAsync = fn.isAsync
      )
      addSig(sigs, u.pkgName + "." + fn.name + "/" + arity.toString(), sig)
      addSig(sigs, fn.name + "/" + arity.toString(), sig)
      defaulted.add(sig)
      defaultedKeys.add(u.pkgName + "." + fn.name)
      defaultedBare.add(fn.name)
      fi = fi + 1
    }
    var ei = 0
    while ei < u.externs.count {
      val ef = u.externs[ei]
      val arity = ef.params.count
      checkExternNoByRefParams(ef)
      val sig = NFuncSig(
        irName = externLlName(u.wasmImports, ef.symbol),
        pkg = u.pkgName,
        paramNames = paramNamesOf(ef.params),
        paramTys = paramTysOf(ef.params),
        paramModes = paramModesOf(ef.params),
        paramDefaults = noParamDefaults(ef.params.count),
        retTy = ef.ret,
        isExternSym = true,
        isAsync = false
      )
      addSig(sigs, u.pkgName + "." + ef.name + "/" + arity.toString(), sig)
      addSig(sigs, ef.name + "/" + arity.toString(), sig)
      ei = ei + 1
    }
    ui2 = ui2 + 1
  }
  // A call that leaves out trailing defaulted parameters writes fewer
  // arguments than the declaration has: register each function under every
  // shorter arity it accepts (#7985).  This runs after every exact arity is
  // registered, so an overload declared with exactly the written arity wins.
  var di = 0
  while di < defaulted.count {
    val sig = defaulted[di]
    var k = requiredArgCount(sig)
    while k < sig.paramTys.count {
      addSig(sigs, defaultedKeys[di] + "/" + k.toString(), sig)
      addSig(sigs, defaultedBare[di] + "/" + k.toString(), sig)
      k = k + 1
    }
    di = di + 1
  }
  sigs
}

/// The bare keys more than one package declares (see `Ctx.sigAlts`), each with
/// all its declarations in registration order.
func buildSigAlts(units: in List[CodegenUnit], sigs: in Map[String, NFuncSig]): Map[String, List[NFuncSig]] {
  val all: Map[String, List[NFuncSig]] = newMap()
  for u in units {
    val names: List[String] = newList()
    val arities: List[Int] = newList()
    for fn in u.fns {
      if not isGenericFn(fn) {
        names.add(fn.name)
        arities.add(fn.params.count)
      }
    }
    for ef in u.externs {
      names.add(ef.name)
      arities.add(ef.params.count)
    }
    var i = 0
    while i < names.count {
      val bare = names[i] + "/" + arities[i].toString()
      match mapGet(sigs, u.pkgName + "." + bare) {
        case Some(sg) -> {
          if not all.containsKey(bare) {
            val fresh: List[NFuncSig] = newList()
            all.add(bare, fresh)
          }
          match mapGet(all, bare) {
            case Some(lst) -> {
              var seen = false
              for prior in lst {
                if prior.pkg == sg.pkg {
                  seen = true
                }
              }
              if not seen {
                lst.add(sg)
              }
            }
            case None -> ()
          }
        }
        case None -> ()
      }
      i = i + 1
    }
  }
  val alts: Map[String, List[NFuncSig]] = newMap()
  for key in mapKeys(all) {
    match mapGet(all, key) {
      case Some(lst) -> {
        if lst.count > 1 {
          alts.add(key, lst)
        }
      }
      case None -> ()
    }
  }
  alts
}

func buildPkgImports(units: in List[CodegenUnit]): Map[String, List[String]] {
  val m: Map[String, List[String]] = newMap()
  for u in units {
    if not m.containsKey(u.pkgName) {
      m.add(u.pkgName, u.imports)
    }
  }
  m
}

/// A bare function key resolved against the calling package's imports: when
/// several packages declare it, the declaration in a package the caller
/// imports wins; otherwise the first registered, as before.
func bareSig(ctx: in Ctx, key: in String): Option[NFuncSig] {
  match mapGet(ctx.sigAlts, key) {
    case None -> mapGet(ctx.sigs, key)
    case Some(alts) -> {
      match mapGet(ctx.pkgImports, ctx.curPkg[0]) {
        case Some(imps) -> {
          for sg in alts {
            for p in imps {
              if p == sg.pkg {
                return Some(value = sg)
              }
            }
          }
        }
        case None -> ()
      }
      mapGet(ctx.sigs, key)
    }
  }
}

/// Recursively flattens an `EPath`, or a chain of `EMember`s over an
/// `EPath` base, into its full dotted segment list at any depth — e.g.
/// `Pkg.Sub.Type` (always parsed as nested `EMember`s over an `EPath`,
/// per `parsePostfixExpr`) flattens to `["Pkg", "Sub", "Type"]` whether
/// or not `Lyric.AliasRewriter` collapsed it into a flat `EPath` ahead of
/// codegen. `None` for any other expression shape (a call, index,
/// literal, etc. anywhere in the chain).
func flattenMemberPathSegs(e: in Expr): Option[List[String]] {
  match e.kind {
    case EPath(path) -> {
      if path.segments.count == 0 {
        None
      } else {
        Some(value = path.segments)
      }
    }
    case EMember(recv, memberName) -> {
      match flattenMemberPathSegs(recv) {
        case Some(segs) -> {
          val built: List[String] = newList()
          var i = 0
          while i < segs.count {
            built.add(segs[i])
            i = i + 1
          }
          built.add(memberName)
          Some(value = built)
        }
        case None -> None
      }
    }
    case _ -> None
  }
}

/// The registry key for a call target, or "" when the callee shape is
/// not a static function reference.  Exported so the bridge's
/// reachability walk resolves call sites identically to the codegen.
pub func callKeyOf(fnExpr: in Expr, argc: in Int): String {
  val inner = match fnExpr.kind { case ETypeApp(f, _) -> f; case _ -> fnExpr }
  match flattenMemberPathSegs(inner) {
    case Some(segs) -> modulePathJoin(segs) + "/" + argc.toString()
    case None -> ""
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
  val tyStr = "{ i32, i32, i8*, i64, i64, [" + (n + 1).toString() + " x i8] }"
  val initStr = "{ i32 2147483647, i32 0, i8* null, i64 " + n.toString() + ", i64 " + (n + 1).toString() + ", [" +
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
  addArcHeader(litFields)
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
  args.add(NArg(ty = NI32, value = NLitInt(v = line.toLong(), ty = NI32)))
  insns.add(NCallVoid(fn = NGlobal(name = "lyric_panic_msg"), args = args))
  insns.add(NUnreachable)
  insns.add(NLabel(name = freshLabel(ctx, "dead")))
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Locals.
// ─────────────────────────────────────────────────────────────────────────────
/// Record `name`'s current `varSlots`/`varTypes` mapping on the innermost
/// open scope's undo log (if any scope is open) BEFORE `bindLocal`
/// overwrites it, so `popVarScope` can restore whatever an inner block's
/// same-named binding shadowed (general native shadowing gap, mirroring
/// MSIL's D-progress-602/#5191 — see `NBindingUndo`'s header comment).
func recordBindingUndo(ctx: in Ctx, name: in String): Unit {
  if ctx.bindingUndo.count > 0 {
    val priorSlot: Option[String] = mapGet(ctx.varSlots, name)
    val priorType: Option[NType] = mapGet(ctx.varTypes, name)
    ctx.bindingUndo[ctx.bindingUndo.count - 1].add(
      NBindingUndo(name = name, priorSlot = priorSlot, priorType = priorType)
    )
  }
}

/// Create a hoisted alloca slot for `name` and store `v` into it.
func bindLocal(ctx: in Ctx, insns: in List[NInsn], name: in String, v: in NVal): Unit {
  recordBindingUndo(ctx, name)
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

/// A top-level (non-generic) function named as a value, e.g. `intEq` passed
/// to a `(Int, Int) -> Bool` parameter: lowered as the closure
/// `{ (a, b) -> intEq(a, b) }` over the function's own signature, which the
/// MSIL/JVM backends express as a delegate/method reference (#7413). None
/// when no function of that name is in scope; a name with overloads of
/// several arities is ambiguous without an expected type and is rejected.
func functionRefAsClosure(ctx: in Ctx, insns: in List[NInsn], name: in String): Option[NVal] {
  val selfPrefix = if ctx.curPkg.count > 0 { ctx.curPkg[0] + "." + name } else { name }
  // One signature per registered arity of the name: at each arity the
  // package's own function shadows a bare (imported) one, as `lowerCall`
  // resolves calls. Two arities, whichever package they come from, are an
  // overload a function value cannot choose between (#7527).
  val selfByArity: Map[String, NFuncSig] = newMap()
  val bareByArity: Map[String, NFuncSig] = newMap()
  for key in mapKeys(ctx.sigs) {
    val slash = Str.lastIndexOfRaw(key, "/")
    if slash > 0 {
      val stem = Str.substring(key, 0, slash)
      val arityKey = Str.substring(key, slash + 1, key.length - slash - 1)
      match mapGet(ctx.sigs, key) {
        case Some(sg) -> {
          if stem == selfPrefix {
            selfByArity[arityKey] = sg
          } else if stem == name {
            bareByArity[arityKey] = sg
          }
        }
        case None -> ()
      }
    }
  }
  var found: Option[NFuncSig] = None
  var matches = 0
  for ak in mapKeys(selfByArity) {
    found = mapGet(selfByArity, ak)
    matches = matches + 1
  }
  for ak in mapKeys(bareByArity) {
    if not selfByArity.containsKey(ak) {
      found = mapGet(bareByArity, ak)
      matches = matches + 1
    }
  }
  if matches > 1 {
    panic(
      "Lyric.LlvmCodegen: function '" + name + "' is overloaded by arity and cannot be passed as a value for " +
        "--target native; wrap it in a lambda that fixes the arity"
    )
  }
  val sig = match found { case Some(sg) -> sg; case None -> return None }
  if sig.isAsync {
    panic("Lyric.LlvmCodegen: async function '" + name + "' cannot be passed as a value for --target native")
  }
  val zp = Position(offset = 0, line = 0, column = 0)
  val sp = Span(startPos = zp, endPos = zp)
  val lps: List[LambdaParam] = newList()
  val callArgs: List[CallArg] = newList()
  val pTys: List[NType] = newList()
  var i = 0
  while i < sig.paramNames.count {
    match sig.paramModes[i] {
      case PMIn -> ()
      case _ -> panic(
        "Lyric.LlvmCodegen: function '" + name +
          "' has an out/inout parameter and cannot be passed as a value for " +
          "--target native"
      )
    }
    val pn = "__fnref_" + i.toString()
    val pty = sig.paramTys[i]
    lps.add(LambdaParam(name = pn, ty = Some(value = pty), span = sp))
    val argSegs: List[String] = newList()
    argSegs.add(pn)
    callArgs.add(CAPositional(expr = Expr(kind = EPath(path = ModulePath(segments = argSegs, span = sp)), span = sp)))
    pTys.add(typeToN(ctx, pty))
    i = i + 1
  }
  val fnSegs: List[String] = newList()
  fnSegs.add(name)
  val callExpr = Expr(
    kind = ECall(
      fn = Expr(kind = EPath(path = ModulePath(segments = fnSegs, span = sp)), span = sp),
      args = callArgs
    ),
    span = sp
  )
  val stmts: List[Statement] = newList()
  stmts.add(Statement(kind = SExpr(expr = callExpr), span = sp))
  val retTy = match sig.retTy { case Some(te) -> typeToN(ctx, te); case None -> NVoid }
  val want = closureNType(ctx, pTys, retTy)
  Some(value = lowerLambda(ctx, insns, lps, Block(statements = stmts, span = sp), want))
}

func loadLocal(ctx: in Ctx, insns: in List[NInsn], name: in String): NVal {
  val ty = match mapGet(ctx.varTypes, name) {
    case Some(t) -> t
    case None -> {
      // Not a local — a reference to a module-level `val`/`const` (#5977 part 2).
      // Native has no static-global storage yet, so inline the binding's
      // initializer at the use site; only a literal initializer is supported
      // (which is exactly what `@build_const` produces). Resolve self-package
      // qualified FIRST — so a package's own binding wins over a same-named one
      // in another bundled package (#6225) — then the bare name (an imported /
      // cross-package reference), the same order `lowerCall` uses for functions.
      val selfKey = if ctx.curPkg.count > 0 { ctx.curPkg[0] + "." + name } else { name }
      match mapGet(ctx.moduleVals, selfKey) {
        case Some(mv) -> return lowerModuleVal(ctx, insns, mv)
        case None -> {
          match mapGet(ctx.moduleVals, name) {
            case Some(mv) -> return lowerModuleVal(ctx, insns, mv)
            case None -> {
              match functionRefAsClosure(ctx, insns, name) {
                case Some(fv) -> return fv
                case None -> panic(
                  "Lyric.LlvmCodegen: unknown name '" + name +
                    "' (non-local references other than module-level val/const and top-level functions are not " +
                    "yet supported for --target native)"
                )
              }
            }
          }
        }
      }
    }
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

// True iff `e` is a compile-time literal — possibly parenthesized, or a negated
// numeric literal (`-1`, the common `val MIN: Int = -1` form) — the only
// module-level initializer form native can inline at a use site (#5977).
/// The hoisted function that computes a non-literal module-level `val`'s
/// initial value (`Lyric.LlvmBridge.hoistModuleValInits` adds it, before
/// monomorphisation, so generic initializers instantiate like any call).
pub func mvInitFnName(name: in String): String {
  "__lyric_mvinit_" + name
}

// Read a module-level `val` backed by a static global. The first reference
// registers the global (zero-initialised, with an "initialised" flag) and its
// initializer; every read first calls the global's `mvensure` function, which
// runs the initializer on first use. A global whose initializer reads another
// therefore initializes it first, in whatever order the packages and files
// declare them (an initializer that depends on itself reads zero). The stored
// value is owned by the global for the life of the process and loads borrow
// from it, like a local slot. `lyric_init_module_globals` ensures them all
// before `main`, so no thread sees one uninitialised.
func loadModuleGlobal(ctx: in Ctx, insns: in List[NInsn], sig: in NFuncSig): NVal {
  val ty = retTypeToN(ctx, sig.retTy)
  val gname = "mv." + sig.irName
  var known = false
  for n in ctx.mvInits {
    if n == sig.irName {
      known = true
    }
  }
  if not known {
    ctx.mvInits.add(sig.irName)
    ctx.mvInitTys.add(ty)
    ctx.globals.add(
      NGlobalDef(
        name = gname,
        linkage = "internal global",
        tyStr = nTypeToIrString(ty),
        initStr = "zeroinitializer",
        align = 8
      )
    )
    ctx.globals.add(
      NGlobalDef(
        name = "mvf." + sig.irName,
        linkage = "internal global",
        tyStr = "i1",
        initStr = "zeroinitializer",
        align = 1
      )
    )
  }
  val noEnsureArgs: List[NArg] = newList()
  insns.add(NCallVoid(fn = NGlobal(name = "mvensure." + sig.irName), args = noEnsureArgs))
  val dest = freshTmp(ctx)
  insns.add(NLoad(dest = dest, ty = ty, ptr = NGlobal(name = gname)))
  NVal(ty = ty, value = NLocal(name = dest))
}

// The functions behind the module globals: one `mvensure.<init>` per global,
// which runs the global's initializer the first time it is called (the flag is
// set before the initializer runs, so a cycle reads zero instead of recursing),
// and the start-up function that ensures every one before `main`.
func synthModuleGlobalFns(name: in String, inits: in List[String], tys: in List[NType]): List[NFunc] {
  val fns: List[NFunc] = newList()
  val noArgs: List[NArg] = newList()
  val noParams: List[NParam] = newList()
  val noAttrs: List[String] = newList()
  var i = 0
  while i < inits.count {
    val flag = NGlobal(name = "mvf." + inits[i])
    val slot = NGlobal(name = "mv." + inits[i])
    val body: List[NInsn] = newList()
    body.add(NLabel(name = "entry"))
    body.add(NLoad(dest = "done", ty = NI1, ptr = flag))
    body.add(NCondBr(cond = NLocal(name = "done"), thenLabel = "exit", elseLabel = "run"))
    body.add(NLabel(name = "run"))
    body.add(NStore(ty = NI1, value = NLitInt(v = 1i64, ty = NI1), ptr = flag))
    body.add(NCall(dest = "value", retTy = tys[i], fn = NGlobal(name = inits[i]), args = noArgs))
    body.add(NStore(ty = tys[i], value = NLocal(name = "value"), ptr = slot))
    body.add(NBr(label = "exit"))
    body.add(NLabel(name = "exit"))
    body.add(NRetVoid)
    fns.add(
      NFunc(
        name = "mvensure." + inits[i],
        params = noParams,
        retTy = NVoid,
        isPublic = false,
        isExtern = false,
        body = body,
        attributes = noAttrs
      )
    )
    i = i + 1
  }
  val start: List[NInsn] = newList()
  start.add(NLabel(name = "entry"))
  var j = 0
  while j < inits.count {
    start.add(NCallVoid(fn = NGlobal(name = "mvensure." + inits[j]), args = noArgs))
    j = j + 1
  }
  start.add(NRetVoid)
  fns.add(
    NFunc(
      name = name,
      params = noParams,
      retTy = NVoid,
      isPublic = false,
      isExtern = false,
      body = start,
      attributes = noAttrs
    )
  )
  fns
}

// True iff `e` is a compile-time literal — possibly parenthesized, or a negated
// numeric literal (`-1`, the common `val MIN: Int = -1` form) — the only
// module-level initializer form native inlines at a use site (#5977); any other
// initializer becomes a static global.
pub func isLiteralInit(e: in Expr): Bool {
  match e.kind {
    case ELiteral(_) -> true
    case EParen(inner) -> isLiteralInit(inner)
    case EPrefix(op, operand) -> {
      match op {
        case PreNeg -> isLiteralInit(operand)
        case _ -> false
      }
    }
    case _ -> false
  }
}

// Inline a module-level `val`/`const` at a reference site by lowering its
// initializer, using the declared type as the expected type when present so a
// widening literal (e.g. `val N: Long = 5`) constructs at the declared width.
func lowerModuleVal(ctx: in Ctx, insns: in List[NInsn], mv: in ModuleValDef): NVal {
  if not isLiteralInit(mv.init) {
    match mapGet(ctx.sigs, mv.pkg + "." + mvInitFnName(mv.name) + "/0") {
      case Some(sig) -> return loadModuleGlobal(ctx, insns, sig)
      case None -> ()
    }
    panic(
      "Lyric.LlvmCodegen: module-level '" + mv.name +
        "' has a non-literal initializer, which is not yet supported for --target native (only literal-initialized module val/const are inlined; #5977)"
    )
  }
  match mv.ty {
    case Some(t) -> lowerExprExpecting(ctx, insns, mv.init, typeToN(ctx, t))
    case None -> lowerExpr(ctx, insns, mv.init)
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

/// Both operands of a binary op at the type the checker gives it.
record WidenedOperands {
  a: NVal
  b: NVal
  ty: NType
}

func intNTypeRank(t: in NType): Int {
  match t {
    case NI8 -> 1
    case NI32 -> 2
    case NI64 -> 3
    case _ -> 0
  }
}

func litFitsNType(v: in Long, t: in NType): Bool {
  match t {
    case NI8 -> v >= 0i64 and v <= 255i64
    case NI32 -> v >= 0i64 - 2147483648i64 and v <= 2147483647i64
    case NI64 -> true
    case _ -> false
  }
}

// Extend an integer operand to `toTy`: `Byte` (i8) is unsigned and
// zero-extends; `Int` sign-extends.
func extendIntOperand(ctx: in Ctx, insns: in List[NInsn], v: in NVal, toTy: in NType): NVal {
  val dest = freshTmp(ctx)
  match v.ty {
    case NI8 -> insns.add(NZExt(dest = dest, fromTy = v.ty, value = v.value, toTy = toTy))
    case _ -> insns.add(NSExt(dest = dest, fromTy = v.ty, value = v.value, toTy = toTy))
  }
  NVal(ty = toTy, value = NLocal(name = dest))
}

/// Bring a binary op's operands to one type, as the type checker's
/// `widenArithmetic` does (#7350): identical types pass; an integer literal
/// takes the other side's width when its value fits there; otherwise the
/// narrower integer operand is extended to the wider one (`Byte < Int <
/// Long`).  `Float` and `Double` are both `double` here.  Anything else is
/// a codegen error (the type checker rejects it upstream).
func widenOperands(ctx: in Ctx, insns: in List[NInsn], a: in NVal, b: in NVal): WidenedOperands {
  if nTypeToIrString(a.ty) == nTypeToIrString(b.ty) {
    return WidenedOperands(a = a, b = b, ty = a.ty)
  }
  match a.value {
    case NLitInt(v, _) -> {
      if litFitsNType(v, b.ty) {
        return WidenedOperands(a = NVal(ty = b.ty, value = a.value), b = b, ty = b.ty)
      }
    }
    case _ -> {
    }
  }
  match b.value {
    case NLitInt(v, _) -> {
      if litFitsNType(v, a.ty) {
        return WidenedOperands(a = a, b = NVal(ty = a.ty, value = b.value), ty = a.ty)
      }
    }
    case _ -> {
    }
  }
  // `Float < Double` (D155): a mixed pair computes in binary64.
  if isFloatingNType(a.ty) and isFloatingNType(b.ty) {
    return WidenedOperands(a = extendFloatToDouble(ctx, insns, a), b = extendFloatToDouble(ctx, insns, b), ty = NDouble)
  }
  val ra = intNTypeRank(a.ty)
  val rb = intNTypeRank(b.ty)
  if ra > 0 and rb > 0 {
    if ra > rb {
      return WidenedOperands(a = a, b = extendIntOperand(ctx, insns, b, a.ty), ty = a.ty)
    }
    return WidenedOperands(a = extendIntOperand(ctx, insns, a, b.ty), b = b, ty = b.ty)
  }
  panic(
    "Lyric.LlvmCodegen: mixed operand types '" + nTypeToIrString(a.ty) + "' and '" + nTypeToIrString(b.ty) +
      "' reached codegen; the type checker admits no such pair"
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
    case NI1 -> callRuntime(
      ctx,
      insns,
      "lyric_string_from_bool",
      lyricStringNType(),
      arg1(NI32, widenBoolToI32(ctx, insns, v.value))
    )
    case NDouble -> callRuntime(ctx, insns, "lyric_string_from_float", lyricStringNType(), arg1(NDouble, v.value))
    case NFloat -> callRuntime(ctx, insns, "lyric_string_from_float32", lyricStringNType(), arg1(NFloat, v.value))
    case _ -> {
      if isStringNType(v.ty) {
        return v
      }
      panic("Lyric.LlvmCodegen: .toString() on this type is not yet supported for --target native (Phase N1)")
    }
  }
}

/// True for the scalar receivers `emitToString` converts. Any other
/// receiver (a record, opaque type, union, ...) falls through to UFCS
/// resolution, so a user-defined `T.toString(x: in T)` method is honoured
/// instead of the built-in conversion (#7257).
func isScalarNType(t: in NType): Bool {
  match t {
    case NI32 -> true
    case NI64 -> true
    case NI8 -> true
    case NI1 -> true
    case NDouble -> true
    case NFloat -> true
    case _ -> false
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
/// Short, stable variant name for an `ExprKind`, used only to make the
/// `lowerExpr` fallback panic below self-diagnosing — this is not a
/// user-facing pretty-printer, so it need not cover every field.
func describeExprKind(kind: in ExprKind): String {
  match kind {
    case ELiteral(_) -> "ELiteral"
    case EInterpolated(_) -> "EInterpolated"
    case EPath(_) -> "EPath"
    case EParen(_) -> "EParen"
    case ETuple(_) -> "ETuple"
    case EList(_) -> "EList"
    case EIf(_, _, _, _) -> "EIf"
    case EMatch(_, _) -> "EMatch"
    case EAwait(_) -> "EAwait"
    case EYield(_) -> "EYield"
    case ESpawn(_) -> "ESpawn"
    case ETry(_) -> "ETry"
    case EOld(_) -> "EOld"
    case EForall(_, _, _) -> "EForall"
    case EExists(_, _, _) -> "EExists"
    case ESelf -> "ESelf"
    case EResult -> "EResult"
    case ELambda(_, _) -> "ELambda"
    case ECall(_, _) -> "ECall"
    case ETypeApp(_, _) -> "ETypeApp"
    case EIndex(_, _) -> "EIndex"
    case EMember(_, _) -> "EMember"
    case EPropagate(_) -> "EPropagate"
    case EPrefix(_, _) -> "EPrefix"
    case EBinop(_, _, _) -> "EBinop"
    case ERange(_) -> "ERange"
    case EAssign(_, _, _) -> "EAssign"
    case EBlock(_) -> "EBlock"
    case EUnsafe(_) -> "EUnsafe"
    case EError -> "EError"
  }
}

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
      // Enum case ordinal (`Red`) is checked BEFORE a nullary union case
      // (`None`) for a bare single-segment name — matching
      // `Msil.Codegen`'s bare-name resolution order exactly
      // (`enumCaseOrdinals` before `unionCaseCtorByName`, ~codegen.l:8058
      // vs :8080). Enum case paths (`Color.Red`) are i32 discriminants.
      // This ordering only matters when a bundle has an enum case and a
      // union case sharing the exact same bare name — pick the same
      // winner MSIL/dotnet does for identical unqualified source, rather
      // than an arbitrary native-only choice.
      match mapGet(ctx.enumDefs, joined) {
        case Some(idx) -> {
          if not Str.endsWith(joined, ".__enum") {
            return NVal(ty = NI32, value = NLitInt(v = idx.toLong(), ty = NI32))
          }
        }
        case None -> {
        }
      }
      // Nullary union case (`None`, `Option.None`) constructs an instance.
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
    case ELambda(_, _) -> panic(
      "Lyric.LlvmCodegen: a lambda here has no expected function type; bind it to an annotated val, a typed parameter, or a declared return type (in " +
        ctx.curPkg[0] +
        " at line " +
        expr.span.startPos.line.toString() +
        ")"
    )
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
    case EList(elems) -> {
      // No expected type here (a bare `[...]` in statement/effect position or an
      // un-annotated inference site). Infer the element type from the first
      // element; an empty literal has no type to infer, so require an expected
      // type — annotate the binding or use `newList[T]()` (#5977).
      if elems.count == 0 {
        panic(
          "Lyric.LlvmCodegen: an empty list literal `[]` needs an expected type on --target native — annotate the binding (val xs: List[Int] = []) or use newList[Int]()"
        )
      }
      val firstV = lowerExpr(ctx, insns, elems[0])
      val elem = firstV.ty
      val lst = constructList(ctx, insns, elem)
      val recvP = collectionAsI8(ctx, insns, lst)
      pushToList(ctx, insns, recvP, firstV)
      var li = 1
      while li < elems.count {
        pushToList(ctx, insns, recvP, lowerExprExpecting(ctx, insns, elems[li], elem))
        li = li + 1
      }
      lst
    }
    case EIndex(receiver, indices) -> lowerCollectionIndex(ctx, insns, receiver, indices, expr.span.startPos.line)
    // `await` on a task-typed value (a `spawn` binding) parks until the
    // task completes; anything else passes through, because a direct
    // async call already awaited at its own call site (stage B2).
    case EAwait(inner) -> {
      val v = lowerExpr(ctx, insns, inner)
      match taskElemOfType(ctx, v.ty) {
        case Some(elem) -> unwrapTask(ctx, insns, v, elem)
        case None -> v
      }
    }
    // `spawn f(...)` runs the ramp (hot task, D-N-021) and keeps the
    // un-awaited task value; a sync callee degenerates to the plain call.
    case ESpawn(inner) -> {
      match inner.kind {
        case ECall(fn, callArgs) -> lowerCallEx(ctx, insns, fn, callArgs, inner.span.startPos.line, true)
        case _ -> lowerExpr(ctx, insns, inner)
      }
    }
    case _ -> panic(
      "Lyric.LlvmCodegen: this expression form (" + describeExprKind(expr.kind) +
        ") is not yet supported for --target native (Phase N1) at [" +
        expr.span.startPos.line.toString() +
        ":" +
        expr.span.startPos.column.toString() +
        "]"
    )
  }
}

func lowerLiteral(ctx: in Ctx, insns: in List[NInsn], lit: in Literal): NVal {
  match lit {
    case LInt(v, suffix, _) -> {
      val isLong = match suffix { case I64 -> true; case U64 -> true; case _ -> v < -2147483648i64 or v > 2147483647i64 }
      // A `u8` literal is a `Byte` wherever no expected type narrows it: an
      // `Int` here made `val b = 200u8` an Int binding, so `b + 100u8` was
      // 300 rather than wrapping to 44, and `Box(value = 255u8)` was
      // instantiated as `Box[Int]` (#7858).
      val isByte = match suffix { case U8 -> true; case _ -> false }
      if isByte {
        NVal(ty = NI8, value = NLitInt(v = v, ty = NI8))
      } else if isLong {
        NVal(ty = NI64, value = NLitInt(v = v, ty = NI64))
      } else {
        NVal(ty = NI32, value = NLitInt(v = v, ty = NI32))
      }
    }
    // A `Float` literal's value is binary32-exact (D155).
    case LFloat(v, sfx, _) -> match sfx {
      case F32 -> NVal(ty = NFloat, value = NLitFloat(v = v, ty = NFloat))
      case _ -> NVal(ty = NDouble, value = NLitFloat(v = v, ty = NDouble))
    }
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
        case NDouble | NFloat -> {
          val dest = freshTmp(ctx)
          insns.add(NFNeg(dest = dest, ty = v.ty, a = v.value))
          NVal(ty = v.ty, value = NLocal(name = dest))
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
    case PreRef -> panic(
      "Lyric.LlvmCodegen: function references (&f) are not yet supported for --target native (pass a lambda instead)"
    )
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

func binFloatOp(ctx: in Ctx, insns: in List[NInsn], op: in BinOp, ty: in NType, a: in NValue, b: in NValue): NVal {
  val dest = freshTmp(ctx)
  match op {
    case BAdd -> insns.add(NFAdd(dest = dest, ty = ty, a = a, b = b))
    case BSub -> insns.add(NFSub(dest = dest, ty = ty, a = a, b = b))
    case BMul -> insns.add(NFMul(dest = dest, ty = ty, a = a, b = b))
    case BDiv -> insns.add(NFDiv(dest = dest, ty = ty, a = a, b = b))
    case BMod -> insns.add(NFRem(dest = dest, ty = ty, a = a, b = b))
    case _ -> panic("Lyric.LlvmCodegen: unexpected float binop")
  }
  NVal(ty = ty, value = NLocal(name = dest))
}

/// True for the binary floating-point types, `Double` and `Float`.
func isFloatingNType(t: in NType): Bool {
  match t {
    case NDouble -> true
    case NFloat -> true
    case _ -> false
  }
}

/// `float` -> `double`: exact (D155).
func extendFloatToDouble(ctx: in Ctx, insns: in List[NInsn], v: in NVal): NVal {
  match v.ty {
    case NFloat -> {
      val dest = freshTmp(ctx)
      insns.add(NFPExt(dest = dest, value = v.value))
      NVal(ty = NDouble, value = NLocal(name = dest))
    }
    case _ -> v
  }
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
    // `String + Char` / `Char + String` concatenation (#6237): `Char`
    // erases to the same `NI32` as `Int` with no runtime tag, so
    // `lowerStringBinop`'s own operand-type check can't tell a bare Char
    // apart from a bare Int — it must see a real `LyricString*` on both
    // sides. Widen the non-string operand here, BEFORE that check, using
    // the syntactic char-ness of the ORIGINAL (unlowered) expression
    // (`exprIsCharTyped`) — the only place this backend can still tell.
    var a2 = a
    var b2 = b
    if op == BAdd {
      if not isStringNType(a.ty) and exprIsCharTyped(ctx, lhs) {
        a2 = callRuntime(ctx, insns, "lyric_string_from_char", lyricStringNType(), arg1(NI32, a.value))
      }
      if not isStringNType(b.ty) and exprIsCharTyped(ctx, rhs) {
        b2 = callRuntime(ctx, insns, "lyric_string_from_char", lyricStringNType(), arg1(NI32, b.value))
      }
      // `String + <scalar>` renders the scalar as its `toString` does, as on
      // MSIL and JVM (#7858); a `Byte` zero-extends, so 128..255 stay
      // unsigned. An `NI32` operand is left to `lowerStringBinop`'s
      // rejection: it may be a `Char` the best-effort tracking above did not
      // recognise, which would print its code point instead of the glyph.
      if isConcatStringifiableNType(a2.ty) {
        a2 = emitToString(ctx, insns, a2)
      }
      if isConcatStringifiableNType(b2.ty) {
        b2 = emitToString(ctx, insns, b2)
      }
    }
    return lowerStringBinop(ctx, insns, op, a2, b2)
  }
  // Unions compare structurally (docs/01 §2.5): same case, equal payloads.
  if op == BEq or op == BNeq {
    match unionInfoOfNType(ctx, a.ty) {
      case Some(ui) -> return lowerUnionEq(ctx, insns, ui, a, b, op == BNeq)
      case None -> ()
    }
  }
  // By-value records compare field by field.
  if (op == BEq or op == BNeq) and isByValueStructNType(a.ty) {
    val eq = emitStructEq(ctx, insns, a.ty, a.value, b.value)
    if op == BEq {
      return NVal(ty = NI1, value = NLocal(name = eq))
    }
    val ne = freshTmp(ctx)
    insns.add(NXor(dest = ne, ty = NI1, a = NLocal(name = eq), b = NLitInt(v = 1i64, ty = NI1)))
    return NVal(ty = NI1, value = NLocal(name = ne))
  }
  val w = widenOperands(ctx, insns, a, b)
  if isComparisonOp(op) {
    match w.ty {
      case NDouble | NFloat -> {
        val dest = freshTmp(ctx)
        insns.add(NFCmp(dest = dest, pred = fcmpPredFor(op), ty = w.ty, a = w.a.value, b = w.b.value))
        return NVal(ty = NI1, value = NLocal(name = dest))
      }
      case NI8 -> {
        val dest = freshTmp(ctx)
        insns.add(NICmp(dest = dest, pred = icmpPredForUnsigned(op), ty = NI8, a = w.a.value, b = w.b.value))
        return NVal(ty = NI1, value = NLocal(name = dest))
      }
      case ty -> {
        val dest = freshTmp(ctx)
        insns.add(NICmp(dest = dest, pred = icmpPredFor(op), ty = ty, a = w.a.value, b = w.b.value))
        return NVal(ty = NI1, value = NLocal(name = dest))
      }
    }
  }
  match op {
    case BXor -> {
      val dest = freshTmp(ctx)
      insns.add(NXor(dest = dest, ty = w.ty, a = w.a.value, b = w.b.value))
      return NVal(ty = w.ty, value = NLocal(name = dest))
    }
    case _ -> {
    }
  }
  match w.ty {
    case NDouble | NFloat -> binFloatOp(ctx, insns, op, w.ty, w.a.value, w.b.value)
    case ty -> binIntOp(ctx, insns, op, ty, w.a.value, w.b.value, line)
  }
}

/// The scalar operand types `String + x` stringifies on this backend: every
/// scalar except `NI32`, which `Int` and `Char` share (see `Ctx.varIsChar`).
func isConcatStringifiableNType(t: in NType): Bool {
  match t {
    case NI8 -> true
    case NI64 -> true
    case NI1 -> true
    case NDouble -> true
    case NFloat -> true
    case _ -> false
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
  // The right operand's temps (e.g. a `String` from `.substring(...)`
  // feeding a `==` test) must be released HERE, inside `evalL`, before
  // branching to `doneL` — `doneL` is also reached directly from the
  // short-circuit-skip edge (`lhs` decided the result without evaluating
  // `rhs` at all), so a temp registered while lowering `rhs` does not
  // dominate `doneL` and releasing it there is both a verifier-rejected
  // IR shape and, worse, a release of a garbage/uninitialized value on
  // the skip path (issue #6645: confirmed by `opt -passes=verify`
  // reporting "Instruction does not dominate all uses!" for exactly this
  // shape, and by a `-O2` clang inliner crash on the resulting module).
  pushTempScope(ctx)
  val b = lowerExpr(ctx, insns, rhs)
  popTempScope(ctx, insns)
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
          case Some(idx) -> return NVal(ty = NI32, value = NLitInt(v = idx.toLong(), ty = NI32))
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
  // A by-value record is read straight out of the aggregate.
  if ri.byValue {
    val ext = freshTmp(ctx)
    insns.add(NExtractValue(dest = ext, aggTy = v.ty, agg = v.value, index = idx))
    return NVal(ty = ri.fieldTys[idx], value = NLocal(name = ext))
  }
  val structTy = match v.ty { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  val fieldPtr = freshTmp(ctx)
  val fArgs: List[NArg] = newList()
  fArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  fArgs.add(NArg(ty = NI32, value = NLitInt(v = (arcHeaderSlots + idx).toLong(), ty = NI32)))
  insns.add(NGEP(dest = fieldPtr, ty = structTy, ptr = v.value, indices = fArgs))
  val dest = freshTmp(ctx)
  insns.add(NLoad(dest = dest, ty = ri.fieldTys[idx], ptr = NLocal(name = fieldPtr)))
  NVal(ty = ri.fieldTys[idx], value = NLocal(name = dest))
}

/// Shared lowering for String's boolean-returning one-arg predicates
/// (`.startsWith`/`.contains`/`.endsWith`): call the `sym` runtime function
/// (returns `int32_t` 0/1, matching `lyric_string_eq`'s convention) and
/// materialise a proper `i1` the same way `BEq`/`BNeq` do (`stringCmpTo`).
func lowerStringPredicateCall(
  ctx: in Ctx, insns: in List[NInsn], sym: in String, v: in NVal, args: in List[CallArg]
): NVal {
  val a0 = lowerPositionalArg(ctx, insns, args, 0)
  val r = callRuntime(ctx, insns, sym, NI32, arg2(lyricStringNType(), v.value, lyricStringNType(), a0.value))
  val dest = freshTmp(ctx)
  insns.add(NICmp(dest = dest, pred = INe, ty = NI32, a = r.value, b = NLitInt(v = 0i64, ty = NI32)))
  NVal(ty = NI1, value = NLocal(name = dest))
}

/// An `i1` that is true when the integer `x` (of width `ty`) is not a BMP
/// scalar value: `x >u 0xFFFF`, or `(x - 0xD800) <u 0x800` (a surrogate).
func toCharBadI(ctx: in Ctx, insns: in List[NInsn], x: in NValue, ty: in NType): NValue {
  val over = freshTmp(ctx)
  insns.add(NICmp(dest = over, pred = IUgt, ty = ty, a = x, b = NLitInt(v = 65535i64, ty = ty)))
  val off = freshTmp(ctx)
  insns.add(NSub(dest = off, ty = ty, a = x, b = NLitInt(v = 55296i64, ty = ty)))
  val surr = freshTmp(ctx)
  insns.add(NICmp(dest = surr, pred = IUlt, ty = ty, a = NLocal(name = off), b = NLitInt(v = 2048i64, ty = ty)))
  val bad = freshTmp(ctx)
  insns.add(NOr(dest = bad, ty = NI1, a = NLocal(name = over), b = NLocal(name = surr)))
  NLocal(name = bad)
}

/// Branch to a `lyric_panic_msg` trap carrying the shared `.toChar()` failure
/// text when `bad` holds.
func emitToCharRangeTrap(ctx: in Ctx, insns: in List[NInsn], bad: in NValue, line: in Int): Unit {
  val trapL = freshLabel(ctx, "tochar.trap")
  val okL = freshLabel(ctx, "tochar.ok")
  insns.add(NCondBr(cond = bad, thenLabel = trapL, elseLabel = okL))
  insns.add(NLabel(name = trapL))
  emitPanicRaw(ctx, insns, toCharRangeMessage(), line)
  insns.add(NBr(label = okL))
  insns.add(NLabel(name = okL))
}

/// `.toChar()` on an `i32`: trap unless it is a BMP scalar value, else the
/// value itself (native's `Char` is the scalar as an `i32`).
func lowerCheckedToCharI32(ctx: in Ctx, insns: in List[NInsn], x: in NValue, line: in Int): NVal {
  emitToCharRangeTrap(ctx, insns, toCharBadI(ctx, insns, x, NI32), line)
  NVal(ty = NI32, value = x)
}

/// Scalar method-call receivers: `.and/.or/.xor/.shl/.shr`, the
/// conversion family, `.toString()`, and String's `.substring`/`.trim`/
/// `.trimStart`/`.trimEnd`/`.replace`/`.toLower`/`.toUpper`/`.indexOf`/
/// `.lastIndexOf`/`.startsWith`/`.contains`/`.endsWith`.
/// Returns None when `name` is not a scalar method (the caller then
/// resolves it as a UFCS function call).
func lowerScalarMethodCall(
  ctx: in Ctx,
  insns: in List[NInsn],
  v: in NVal,
  name: in String,
  args: in List[CallArg],
  line: in Int,
  recvExpr: in Option[Expr],
): Option[NVal] {
  if isStringNType(v.ty) {
    if name == "toString" and args.count == 0 {
      return Some(value = v)
    }
    if name == "codeUnitAt" and args.count == 1 {
      // `s.codeUnitAt(i)` (D-progress-1006): this target's strings are UTF-8,
      // so the code unit at byte offset `i` is a byte, zero-extended to Int.
      // Out-of-range panics in `lyric_string_byte_at`, like `s[i]`.
      val cuIdx = lowerPositionalArg(ctx, insns, args, 0)
      val cuIdxW = freshTmp(ctx)
      insns.add(NSExt(dest = cuIdxW, fromTy = NI32, value = cuIdx.value, toTy = NI64))
      val cuByte = callRuntime(
        ctx,
        insns,
        "lyric_string_byte_at",
        NI8,
        arg2(lyricStringNType(), v.value, NI64, NLocal(name = cuIdxW))
      )
      val cuDest = freshTmp(ctx)
      insns.add(NZExt(dest = cuDest, fromTy = NI8, value = cuByte.value, toTy = NI32))
      return Some(value = NVal(ty = NI32, value = NLocal(name = cuDest)))
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
    if name == "trim" and args.count == 0 {
      return Some(
        value = callRuntime(ctx, insns, "lyric_string_trim", lyricStringNType(), arg1(lyricStringNType(), v.value))
      )
    }
    if name == "trimStart" and args.count == 0 {
      return Some(
        value = callRuntime(
          ctx,
          insns,
          "lyric_string_trim_start",
          lyricStringNType(),
          arg1(lyricStringNType(), v.value)
        )
      )
    }
    if name == "trimEnd" and args.count == 0 {
      return Some(
        value = callRuntime(
          ctx,
          insns,
          "lyric_string_trim_end",
          lyricStringNType(),
          arg1(lyricStringNType(), v.value)
        )
      )
    }
    if name == "replace" and args.count == 2 {
      val a0 = lowerPositionalArg(ctx, insns, args, 0)
      val a1 = lowerPositionalArg(ctx, insns, args, 1)
      val sTy = lyricStringNType()
      val callArgs: List[NArg] = newList()
      callArgs.add(NArg(ty = sTy, value = v.value))
      callArgs.add(NArg(ty = sTy, value = a0.value))
      callArgs.add(NArg(ty = sTy, value = a1.value))
      return Some(value = callRuntime(ctx, insns, "lyric_string_replace", sTy, callArgs))
    }
    if name == "toLower" and args.count == 0 {
      return Some(
        value = callRuntime(
          ctx,
          insns,
          "lyric_string_to_lower",
          lyricStringNType(),
          arg1(lyricStringNType(), v.value)
        )
      )
    }
    if name == "toUpper" and args.count == 0 {
      return Some(
        value = callRuntime(
          ctx,
          insns,
          "lyric_string_to_upper",
          lyricStringNType(),
          arg1(lyricStringNType(), v.value)
        )
      )
    }
    if (name == "indexOf" or name == "lastIndexOf") and args.count == 1 {
      // #6588 review follow-up (#6752): `.indexOf`/`.lastIndexOf` are
      // import-sensitive (`Lyric.TypeChecker.stringIndexOfMember`) — with
      // `import Std.String` in scope of the calling file, `s.indexOf(x)` /
      // `s.lastIndexOf(x)` type-check as `Option[Int]`, the UFCS spelling of
      // the real `Std.String.indexOf`/`.lastIndexOf` free functions; without
      // the import they type as the raw `-1`-sentinel `Int`. Intercepting
      // unconditionally here with the raw runtime intrinsic (as MSIL
      // originally did before #6348, and as JVM's
      // `fileImportsStdString`/`importsStdString` gate exists to prevent)
      // would hand a raw i32 to a caller whose `match`/`isinst` expects a
      // real `Option[Int]` union value — memory corruption, not a type
      // error. `ctx.curPkg[0] != "Std.String"` mirrors the JVM gate's own
      // defensive self-package exclusion (`Std.String`'s own `indexOf`/
      // `lastIndexOf` wrapper bodies call this raw form on purpose; routing
      // it back through itself would recurse forever) even though
      // `Std.String` does not import itself today.
      var importsStdStr = false
      if ctx.curPkg[0] != "Std.String" {
        match mapGet(ctx.pkgImportsStdString, ctx.curPkg[0]) {
          case Some(v) -> {
            importsStdStr = v
          }
          case None -> {
          }
        }
      }
      if importsStdStr {
        // Fall through to `lowerUfcsCall`, which resolves
        // `Std.String.indexOf`/`.lastIndexOf` as an ordinary UFCS function
        // call — the same path this call took before this scalar-method arm
        // existed.
        return None
      }
      val sym = if name == "indexOf" { "lyric_string_index_of" } else { "lyric_string_last_index_of" }
      val a0 = lowerPositionalArg(ctx, insns, args, 0)
      val n = callRuntime(ctx, insns, sym, NI64, arg2(lyricStringNType(), v.value, lyricStringNType(), a0.value))
      val dest = freshTmp(ctx)
      insns.add(NTrunc(dest = dest, fromTy = NI64, value = n.value, toTy = NI32))
      return Some(value = NVal(ty = NI32, value = NLocal(name = dest)))
    }
    if name == "startsWith" and args.count == 1 {
      return Some(value = lowerStringPredicateCall(ctx, insns, "lyric_string_starts_with", v, args))
    }
    if name == "contains" and args.count == 1 {
      return Some(value = lowerStringPredicateCall(ctx, insns, "lyric_string_contains", v, args))
    }
    if name == "endsWith" and args.count == 1 {
      return Some(value = lowerStringPredicateCall(ctx, insns, "lyric_string_ends_with", v, args))
    }
    // #7304: `Std.String.isNormalized`/`normalize`'s bodies call
    // `s.isNormalized()`/`s.normalize()` via UFCS, exactly like every other
    // wrapper in this file — safe on MSIL/JVM only because those backends
    // recognize the name as an intrinsic. Native has no such intrinsic, so
    // without this explicit panic the call falls through to
    // `lowerUfcsCall`, which resolves `<curPkg>.<name>/<arity>` and finds
    // the very function being compiled (`Std.String.isNormalized/1`) —
    // infinite self-recursion at runtime instead of the clean compile-time
    // "not yet supported" this file gives every other un-ported method.
    // Mirrors the `indexOf`/`lastIndexOf` self-package guard above
    // (#6752) for the same recursion hazard class.
    if (name == "isNormalized" or name == "normalize") and args.count == 0 {
      panic(
        "Lyric.LlvmCodegen: String member '." + name +
          "' is not yet supported for --target native (Unicode normalization tables not yet ported to lyric-rt)"
      )
    }
    return None
  }
  if name == "toString" and args.count == 0 and isScalarNType(v.ty) {
    // `Char.toString()` (#6237): `Char` and `Int` both erase to `NI32`
    // (`v.ty` alone can't tell them apart — see `Ctx.varIsChar`'s header
    // comment), so `emitToString`'s `NI32` case would otherwise call
    // `lyric_string_from_int` and print the codepoint's decimal digits
    // instead of the character. Consult the original receiver expression's
    // syntactic char-ness before falling back to `emitToString`.
    val isChar = match recvExpr { case Some(e) -> exprIsCharTyped(ctx, e); case None -> false }
    if isChar {
      return Some(value = callRuntime(ctx, insns, "lyric_string_from_char", lyricStringNType(), arg1(NI32, v.value)))
    }
    return Some(value = emitToString(ctx, insns, v))
  }
  // A `Float` receiver of any conversion but `toFloat` converts as the
  // `Double` it widens to exactly (D155).
  val isFloatRecv = match v.ty { case NFloat -> true; case _ -> false }
  if isFloatRecv and args.count == 0 and (name == "toLong" or name == "toInt" or name == "toChar" or name == "toByte" or name == "toDouble" or name == "toNat") {
    return lowerScalarMethodCall(ctx, insns, extendFloatToDouble(ctx, insns, v), name, args, line, recvExpr)
  }
  if name == "toFloat" and args.count == 0 {
    match v.ty {
      case NI32 -> {
        val dest = freshTmp(ctx)
        insns.add(NSIToFP(dest = dest, fromTy = NI32, value = v.value, toTy = NFloat))
        return Some(value = NVal(ty = NFloat, value = NLocal(name = dest)))
      }
      case NI64 -> {
        val dest = freshTmp(ctx)
        insns.add(NSIToFP(dest = dest, fromTy = NI64, value = v.value, toTy = NFloat))
        return Some(value = NVal(ty = NFloat, value = NLocal(name = dest)))
      }
      // `Byte` is unsigned: zero-extend before the signed conversion.
      case NI8 -> {
        val wide = freshTmp(ctx)
        insns.add(NZExt(dest = wide, fromTy = NI8, value = v.value, toTy = NI32))
        val dest = freshTmp(ctx)
        insns.add(NSIToFP(dest = dest, fromTy = NI32, value = NLocal(name = wide), toTy = NFloat))
        return Some(value = NVal(ty = NFloat, value = NLocal(name = dest)))
      }
      case NDouble -> {
        val dest = freshTmp(ctx)
        insns.add(NFPTrunc(dest = dest, value = v.value))
        return Some(value = NVal(ty = NFloat, value = NLocal(name = dest)))
      }
      case NFloat -> return Some(value = v)
      case _ -> {
      }
    }
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
  if name == "toDouble" and args.count == 0 {
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
      // `Byte` is unsigned: zero-extend before the signed conversion.
      case NI8 -> {
        val wide = freshTmp(ctx)
        insns.add(NZExt(dest = wide, fromTy = NI8, value = v.value, toTy = NI32))
        val dest = freshTmp(ctx)
        insns.add(NSIToFP(dest = dest, fromTy = NI32, value = NLocal(name = wide), toTy = NDouble))
        return Some(value = NVal(ty = NDouble, value = NLocal(name = dest)))
      }
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
      // Truncate toward zero, then keep the low 8 bits (modulo 256).
      case NDouble -> {
        val wide = freshTmp(ctx)
        insns.add(NFPToSI(dest = wide, fromTy = NDouble, value = v.value, toTy = NI64))
        val dest = freshTmp(ctx)
        insns.add(NTrunc(dest = dest, fromTy = NI64, value = NLocal(name = wide), toTy = NI8))
        return Some(value = NVal(ty = NI8, value = NLocal(name = dest)))
      }
      case _ -> {
      }
    }
  }
  if name == "toChar" and args.count == 0 {
    // Checked narrowing (D-progress-1006): a `Char` is a BMP scalar value,
    // never a surrogate (docs/01 §2.1).  `Char` itself also erases to NI32
    // here; its check always passes.
    match v.ty {
      case NI32 -> return Some(value = lowerCheckedToCharI32(ctx, insns, v.value, line))
      case NI64 -> {
        emitToCharRangeTrap(ctx, insns, toCharBadI(ctx, insns, v.value, NI64), line)
        val dest = freshTmp(ctx)
        insns.add(NTrunc(dest = dest, fromTy = NI64, value = v.value, toTy = NI32))
        return Some(value = NVal(ty = NI32, value = NLocal(name = dest)))
      }
      case NDouble -> {
        // `-1.0 < d < 65536.0` (ordered, so NaN fails) before truncating
        // toward zero, then the surrogate check on the integer.
        val gtLo = freshTmp(ctx)
        insns.add(NFCmp(dest = gtLo, pred = FOgt, ty = NDouble, a = v.value, b = NLitFloat(v = 0.0 - 1.0, ty = NDouble)))
        val ltHi = freshTmp(ctx)
        insns.add(NFCmp(dest = ltHi, pred = FOlt, ty = NDouble, a = v.value, b = NLitFloat(v = 65536.0, ty = NDouble)))
        val inRange = freshTmp(ctx)
        insns.add(NAnd(dest = inRange, ty = NI1, a = NLocal(name = gtLo), b = NLocal(name = ltHi)))
        val bad = freshTmp(ctx)
        insns.add(NXor(dest = bad, ty = NI1, a = NLocal(name = inRange), b = NLitInt(v = 1i64, ty = NI1)))
        emitToCharRangeTrap(ctx, insns, NLocal(name = bad), line)
        val iv = freshTmp(ctx)
        insns.add(NFPToSI(dest = iv, fromTy = NDouble, value = v.value, toTy = NI32))
        return Some(value = lowerCheckedToCharI32(ctx, insns, NLocal(name = iv), line))
      }
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
  // whose head is not a local variable, nor a bare module-level `val`/`const`
  // (`MAX_DEPTH.toString()` is a method call on the value, not a qualified
  // call to a function named `MAX_DEPTH.toString`).
  match e.kind {
    case EPath(path) -> {
      if path.segments.count == 0 {
        return false
      }
      val head = path.segments[0]
      if ctx.varTypes.containsKey(head) {
        return false
      }
      if path.segments.count == 1 {
        val selfKey = if ctx.curPkg.count > 0 { ctx.curPkg[0] + "." + head } else { head }
        if ctx.moduleVals.containsKey(selfKey) or ctx.moduleVals.containsKey(head) {
          return false
        }
      }
      true
    }
    case _ -> false
  }
}

/// Reorder call arguments to the callee's declared parameter order and
/// lower each.  Positional args bind left-to-right; named args bind by
/// declared name.
func lowerCallArgs(ctx: in Ctx, insns: in List[NInsn], sig: in NFuncSig, args: in List[CallArg]): List[NArg] {
  if args.count > sig.paramTys.count {
    panic(
      "Lyric.LlvmCodegen: call to '" + sig.irName + "' passes " + args.count.toString() +
        " argument(s) but the declaration has " +
        sig.paramTys.count.toString()
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
  if args.count + 1 > sig.paramTys.count {
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
      // A parameter the call leaves out takes its default, evaluated after
      // the written arguments in parameter order, as on dotnet and the JVM.
      val dflt = if pi2 < sig.paramDefaults.count { sig.paramDefaults[pi2] } else { None }
      match dflt {
        case Some(dex) -> {
          vals.add(lowerArgAgainst(ctx, insns, sig, dex, pi2))
          slots.add(pi2)
          found = vals.count - 1
        }
        case None -> panic(
          "Lyric.LlvmCodegen: no argument bound for parameter '" + sig.paramNames[pi2] + "' of '" + sig.irName +
            "', which has no default"
        )
      }
    }
    if sig.isExternSym and isFunctionTypeExpr(sig.paramTys[pi2]) {
      val fnDeclTy = externCallbackNType(ctx, sig.paramTys[pi2])
      val fv = externAdaptArg(ctx, insns, sig.paramTys[pi2], fnDeclTy, vals[found])
      ordered.add(NArg(ty = fnDeclTy, value = fv.value))
      pi2 = pi2 + 1
      continue
    }
    val declTy = paramArgNType(ctx, sig, pi2)
    val v = if sig.isExternSym {
      externAdaptArg(ctx, insns, sig.paramTys[pi2], declTy, vals[found])
    } else if isByRefParam(ctx, sig, pi2) {
      // The value IS already the address (lowerArgAgainst routed it
      // through lowerByRefArg below) — never run value-coercion (Int→Long
      // widening etc.) over a pointer.
      vals[found]
    } else {
      coerceTo(ctx, insns, vals[found], declTy)
    }
    ordered.add(NArg(ty = declTy, value = v.value))
    pi2 = pi2 + 1
  }
}

/// True when parameter `slot` of `sig` is declared `out`/`inout` AND its
/// underlying type is representable (a `Unit` out/inout parameter carries
/// no address — see `lowerFunctionEnv`).
func isByRefParam(ctx: in Ctx, sig: in NFuncSig, slot: Int): Bool {
  val isByRefMode = match sig.paramModes[slot] { case PMIn -> false; case _ -> true }
  if not isByRefMode {
    return false
  }
  match typeToN(ctx, sig.paramTys[slot]) {
    case NVoid -> false
    case _ -> true
  }
}

/// The LLVM argument type for parameter `slot`: a pointer-to-declared-type
/// for `out`/`inout` (the caller passes the address of its storage cell),
/// the declared type itself for `in` (see `lowerFunctionEnv`'s matching
/// callee-side lowering).
func paramArgNType(ctx: in Ctx, sig: in NFuncSig, slot: Int): NType {
  val base = typeToN(ctx, sig.paramTys[slot])
  if isByRefParam(ctx, sig, slot) {
    NPtr(pointee = base)
  } else {
    base
  }
}

/// Lower one argument against its declared parameter (N4.5-aware):
/// normally with the declared type as the expected type; an extern
/// callback (function-typed) parameter expects the Lyric closure for
/// the callback's reduced signature, and an extern `NativePtr[Byte]`
/// parameter lowers with NO expected type — lowerExprExpecting's
/// fallback coerces eagerly, which would reject the closure value the
/// ordering pass adapts into the userdata pointer (a genuine i8* value
/// coerces there as a no-op).  An `out`/`inout` parameter (N9.6) lowers
/// the argument expression's ADDRESS instead of its value.
func lowerArgAgainst(ctx: in Ctx, insns: in List[NInsn], sig: in NFuncSig, ex: in Expr, slot: Int): NVal {
  if isByRefParam(ctx, sig, slot) {
    return lowerByRefArg(ctx, insns, ex, typeToN(ctx, sig.paramTys[slot]))
  }
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

/// The address of an `out`/`inout` call argument (N9.6). The type checker
/// (`typechecker_exprs.l::argIsValidByRefTarget`) already rejects a
/// non-l-value argument at an `out`/`inout` parameter, but it is
/// deliberately conservative — it *accepts* any `EMember`/`EIndex` shape as
/// a "potential l-value" without deciding whether the native backend can
/// actually compute its address.  This function covers the two shapes
/// verified safe: a bare local (its `ctx.varSlots` entry already IS a
/// pointer to its storage, whether that local is a plain `alloca` or
/// itself an aliased `out`/`inout` parameter — see `lowerFunctionEnv`) and
/// a record field access (a GEP off the record's heap pointer, exactly
/// `lowerFieldAssign`'s addressing). Anything else (an index/element
/// expression, a qualified module path, …) is a loud, named diagnostic —
/// never a silent miscompile — pending its own verified addressing scheme.
func lowerByRefArg(ctx: in Ctx, insns: in List[NInsn], ex: in Expr, declTy: in NType): NVal {
  match ex.kind {
    case EParen(inner) -> lowerByRefArg(ctx, insns, inner, declTy)
    case EPath(path) -> {
      if path.segments.count == 1 {
        val name = path.segments[0]
        val slot = match mapGet(ctx.varSlots, name) {
          case Some(s) -> s
          case None -> panic(
            "Lyric.LlvmCodegen: out/inout argument '" + name +
              "' is not a local variable or parameter — module-level bindings are not yet supported as out/inout arguments for --target native"
          )
        }
        // #6813: the type checker's `argSatisfiesParam` applies
        // `widenArithmetic` uniformly across every parameter mode, so an
        // `Int` local type-checks against an `inout Long` parameter — but
        // a by-ref argument forwards the local's OWN alloca pointer
        // as-is (Rule 5: the callee never copies), tagged with the
        // CALLEE's declared type below. A width/kind mismatch between
        // the local's actual storage and `declTy` would alias an i32
        // alloca through an i64 pointer (or similarly mismatched struct
        // pointer types) — silently wrong at runtime if `clang` even
        // accepts the mismatched-pointee GEP/load/store in the emitted
        // `.ll`. Fail loudly here instead, matching #6812's "loud
        // diagnostic, never silent miscompile" policy for every other
        // out/inout scope cut.
        val actualTy = match mapGet(ctx.varTypes, name) {
          case Some(t) -> t
          case None -> panic("Lyric.LlvmCodegen: no type recorded for out/inout argument '" + name + "'")
        }
        if nTypeToIrString(actualTy) != nTypeToIrString(declTy) {
          panic(
            "Lyric.LlvmCodegen: out/inout argument '" + name + "' has type '" + nTypeToIrString(actualTy) +
              "' but the parameter declares 'inout/out " +
              nTypeToIrString(declTy) +
              "' — a by-ref argument's type must match the parameter's declared type exactly for --target native " +
              "(no numeric widening across an out/inout boundary, since the callee aliases the caller's " +
              "storage directly rather than copying a widened value)"
          )
        }
        return NVal(ty = NPtr(pointee = declTy), value = NLocal(name = slot))
      }
      panic(
        "Lyric.LlvmCodegen: out/inout argument '" + modulePathJoin(path.segments) +
          "' is a qualified path, which is not yet supported for --target native (only a local variable/parameter or a record field access is)"
      )
    }
    case EMember(recv, fieldName) -> {
      val obj = lowerExpr(ctx, insns, recv)
      val ri = match recInfoOfType(ctx, obj.ty) {
        case Some(r) -> r
        case None -> panic(
          "Lyric.LlvmCodegen: out/inout argument '." + fieldName +
            "' is not a record field, which is required for --target native"
        )
      }
      val idx = recFieldIndex(ri, fieldName)
      if idx < 0 {
        panic("Lyric.LlvmCodegen: record '" + ri.irName + "' has no field '" + fieldName + "'")
      }
      if ri.byValue {
        panic(
          "Lyric.LlvmCodegen: out/inout argument '." + fieldName + "' is a field of by-value record '" + ri.irName +
            "', which has no `var` field to write through"
        )
      }
      val fieldTy = ri.fieldTys[idx]
      // #6813: same widening hazard as the bare-local branch above — a
      // narrower/differently-kinded field type must not alias through
      // the callee's declared by-ref pointer type.
      if nTypeToIrString(fieldTy) != nTypeToIrString(declTy) {
        panic(
          "Lyric.LlvmCodegen: out/inout argument '." + fieldName + "' has type '" + nTypeToIrString(fieldTy) +
            "' but the parameter declares 'inout/out " +
            nTypeToIrString(declTy) +
            "' — a by-ref argument's type must match the parameter's declared type exactly for --target native " +
            "(no numeric widening across an out/inout boundary, since the callee aliases the caller's " +
            "storage directly rather than copying a widened value)"
        )
      }
      val structTy = match obj.ty { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
      val fieldPtr = freshTmp(ctx)
      val fArgs: List[NArg] = newList()
      fArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
      fArgs.add(NArg(ty = NI32, value = NLitInt(v = (arcHeaderSlots + idx).toLong(), ty = NI32)))
      insns.add(NGEP(dest = fieldPtr, ty = structTy, ptr = obj.value, indices = fArgs))
      NVal(ty = NPtr(pointee = fieldTy), value = NLocal(name = fieldPtr))
    }
    case _ -> panic(
      "Lyric.LlvmCodegen: this out/inout argument shape is not yet supported for --target native (only a local variable/parameter or a record field access is; index/element expressions and other l-value forms are not yet supported)"
    )
  }
}

/// Adapt a value to the declared type: integer literals retype freely;
/// Int widens to Long implicitly at a declared-Long boundary (matching
/// the managed backends' literal-friendly call sites); a wider non-literal
/// int narrows to a declared-narrower boundary (#7452 — see the `NTrunc`
/// branch below). Anything else must already match.
///
/// `atSpan`, when supplied by a caller that has a source `Expr` in hand
/// (`lowerExprExpecting`), locates the terminal type-mismatch panic at the
/// user's actual source position so `Lyric.Emitter.nativeBridgePanicDiagnostic`
/// (#7452) can report a real `error[N0007] line:col: …` instead of pointing
/// at file-start — mirroring `msilBridgePanicDiagnostic`'s `error[T0119]
/// line:col: …` convention (`emitter.l`'s `parsePanicSpan`).
func coerceTo(ctx: in Ctx, insns: in List[NInsn], v: in NVal, want: in NType, atSpan: in Option[Span] = None): NVal {
  val sameKind = nTypeToIrString(v.ty) == nTypeToIrString(want)
  if sameKind {
    return v
  }
  // Implicit upcast: a concrete record flowing into an interface-typed
  // position (arg / return / binding / field / match arm) is boxed into a
  // fat pointer here (N3.2) — the type checker inserts no coercion node.
  match ifaceBoxInfoOfType(ctx, want) {
    case Some(info) -> {
      // A by-value record is a struct value, not a pointer (#8010).
      val implementer: Option[String] = match v.ty {
        case NStruct(sname, _) -> if Str.startsWith(sname, "__") {
          None
        } else {
          Some(value = sname)
        }
        case _ -> recordIrNameOfType(v.ty)
      }
      match implementer {
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
        case NDouble -> return NVal(ty = NDouble, value = NLitFloat(v = longToDouble(litV), ty = NDouble))
        // An integer literal where a `Float` is lowered (a range-pattern
        // bound, which is not type-checked against the scrutinee): the
        // nearest binary32 value, rounded once from the exact integer.
        case NFloat -> return NVal(ty = NFloat, value = NLitFloat(v = float32LiteralValue(litV.toString(), longToDouble(litV)), ty = NFloat))
        case _ -> {
        }
      }
    }
    case _ -> {
    }
  }
  val fromStr = nTypeToIrString(v.ty)
  val wantStr = nTypeToIrString(want)
  // The implicit `Float < Double` widening at a binding, argument, field or
  // return (D155).
  if fromStr == "float" and wantStr == "double" {
    return extendFloatToDouble(ctx, insns, v)
  }
  if fromStr == "i32" and wantStr == "i64" {
    val dest = freshTmp(ctx)
    insns.add(NSExt(dest = dest, fromTy = NI32, value = v.value, toTy = NI64))
    return NVal(ty = NI64, value = NLocal(name = dest))
  }
  // #7452: narrow a wider non-literal integer to a declared-narrower slot,
  // the same `trunc` `.toByte()` emits explicitly (above). Reachable
  // whenever the type checker admits an `Int`-typed argument where a
  // narrower type is lowered: a type parameter inside a generic body
  // (`typeEquiv` treats a bare `TyVar` as satisfied by any argument type,
  // `typechecker_types.l`) instantiated so that an `Int` reaches a `Byte`
  // slot.  The stdlib collections' own element-taking members check their
  // arguments against the element type since #7969.  MSIL narrows implicitly
  // (the CLR evaluation stack has no sub-`int32` width) and JVM emits `i2b`;
  // LLVM IR has no such implicit narrowing — a mismatched SSA value width is
  // a verifier error — so native must emit the `trunc` explicitly here too.
  if (fromStr == "i64" and wantStr == "i32") or (fromStr == "i64" and wantStr == "i8") or (fromStr == "i32" and wantStr == "i8") {
    val dest = freshTmp(ctx)
    insns.add(NTrunc(dest = dest, fromTy = v.ty, value = v.value, toTy = want))
    return NVal(ty = want, value = NLocal(name = dest))
  }
  match taskElemOfType(ctx, v.ty) {
    case Some(_) -> {
      panic(
        "Lyric.LlvmCodegen: a spawned task is flowing into a '" + wantStr +
          "'-typed position without being awaited; `await` the spawn binding before using its value"
      )
    }
    case None -> {
    }
  }
  // #7452: a genuinely incompatible mismatch (not a numeric narrowing) is
  // still a hard codegen error, but is now reported as `N0007` instead of a
  // bare untyped panic. With a real `atSpan` (the common case — every call
  // through `lowerExprExpecting` has one), the message embeds
  // `error[N0007] line:col: …`, matching `msilBridgePanicDiagnostic`'s
  // `error[T0119] line:col: …` shape so `Lyric.Emitter.parsePanicSpan`
  // recovers the real source position; `Lyric.Emitter.emitNativeInProcess`/
  // `emitNativeProject` catch the panic (mirroring the MSIL/JVM in-process
  // bridges) and turn it into a structured `Diagnostic`, never an unhandled
  // exception. Without a span (a `coerceTo` call site that has none), the
  // message carries no code — the emitter's generic fallback still wraps it
  // under `N0007` with a synthetic point span, exactly like MSIL's `T0120`/
  // JVM's `J008` fallback for an uncoded panic.
  match atSpan {
    case Some(sp) -> panic(
      "error[N0007] " + sp.startPos.line.toString() + ":" + sp.startPos.column.toString() +
        ": Lyric.LlvmCodegen: cannot pass a '" +
        fromStr +
        "' where '" +
        wantStr +
        "' is expected (insert an explicit conversion)"
    )
    case None -> panic(
      "Lyric.LlvmCodegen: cannot pass a '" + fromStr + "' where '" + wantStr +
        "' is expected (insert an explicit conversion)"
    )
  }
}

/// Unbox a value flowing into an erased-`Self` interface-method PARAMETER
/// slot (#7585, #7618 review follow-up to #7616): a `Self`-typed parameter
/// dispatched through the SAME interface receiver types the caller's
/// argument as the interface itself (T0113 receiver substitution), but the
/// vtable's erased slot expects the raw `i8*` object pointer, matching
/// every other concrete impl's pointer-width receiver. Read-only
/// extraction (a borrow, mode `in` per Rule 5) — no retain needed; the box
/// itself stays alive for the call's duration since the caller still holds
/// it.
///
/// Callable ONLY from `lowerIfaceDispatch`, gated on `ii.methodParamIsSelf`
/// — never from `coerceTo`'s general "adapt to declared type" path, and
/// never inferred merely from `want` being `i8*` (a genuine, unrelated
/// `NativePtr[Byte]` parameter erases to the exact same `NType`; passing a
/// ref-typed value there is a real type error and must panic through
/// `coerceTo`'s ordinary type-mismatch path instead of silently unboxing).
func unboxToSelfSlot(ctx: in Ctx, insns: in List[NInsn], v: in NVal): NVal {
  match ifaceBoxInfoOfType(ctx, v.ty) {
    case Some(info) -> {
      val structTy = ifaceBoxStructType(info)
      val objSlot = freshTmp(ctx)
      val objArgs: List[NArg] = newList()
      objArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
      objArgs.add(NArg(ty = NI32, value = NLitInt(v = ifaceBoxObjSlot, ty = NI32)))
      insns.add(NGEP(dest = objSlot, ty = structTy, ptr = v.value, indices = objArgs))
      val objVal = freshTmp(ctx)
      insns.add(NLoad(dest = objVal, ty = NPtr(pointee = NI8), ptr = NLocal(name = objSlot)))
      NVal(ty = NPtr(pointee = NI8), value = NLocal(name = objVal))
    }
    case None -> {
      // The checker accepts a CONCRETE record/protected-type value at a
      // `Self`-substituted-to-the-interface parameter position too (the
      // ordinary "concrete implementor flows into an interface-typed
      // slot" upcast, `checkImplConformance`) — it just never got boxed
      // because THIS slot's declared type is the erased `i8*`, not the
      // interface box type `coerceTo`'s upcast branch matches on. A plain
      // bitcast is enough: the vtable-dispatched callee expects the SAME
      // raw pointer-width representation either way, and this is a borrow
      // (mode `in`, Rule 5) — no retain, no new box.
      if isRefNType(v.ty) {
        val dest = freshTmp(ctx)
        insns.add(NBitcast(dest = dest, fromTy = v.ty, value = v.value, toTy = NPtr(pointee = NI8)))
        NVal(ty = NPtr(pointee = NI8), value = NLocal(name = dest))
      } else if isBoxedValueNType(v.ty) {
        // A by-value record: boxed for the call, as the vtable thunk reads
        // its `Self` parameters out of a box (#8010).
        val held = boxByValue(ctx, insns, v)
        registerTemp(ctx, held)
        val dest = freshTmp(ctx)
        insns.add(NBitcast(dest = dest, fromTy = held.ty, value = held.value, toTy = NPtr(pointee = NI8)))
        NVal(ty = NPtr(pointee = NI8), value = NLocal(name = dest))
      } else {
        // Neither an interface box nor a ref type — the checker's own
        // T0113 substitution guarantees a `Self`-through-interface
        // argument is always one or the other, so reaching here is a
        // compiler-invariant violation, not a user error.
        panic(
          "Lyric.LlvmCodegen: internal — unboxToSelfSlot: expected an interface-boxed or ref-typed value at a Self slot, got '" +
            nTypeToIrString(v.ty) +
            "'"
        )
      }
    }
  }
}

func longToDouble(v: in Long): Double {
  v.toDouble()
}

// Whether a bare call to `funcName` (with `argc` arguments) names a
// registered, non-generic, NON-`Std`-owned function that must win over the
// compiler's own same-named intrinsic (#7508).  Mirrors `hasFuncOverrideMsil`
// (`msil/codegen.l`) and `hasFuncOverrideJvm` (`jvm/codegen/04_calls.l`):
// `ctx.sigs` (`buildSigs`) already registers every non-generic function
// under its bare `<name>/<arity>` key with the MAIN package's own
// declarations registered first (so they shadow a same-named stdlib
// function, matching source scoping) — the exact resolution order a
// bare call goes through once it falls out of the intrinsic table below.
// The stdlib functions these intrinsics implement (`newList`, `mapGet`, …)
// are all GENERIC and so never appear in `ctx.sigs` at all (`buildSigs`
// skips generic functions) — only a genuinely different, non-generic,
// non-`Std` declaration can ever match here, so a `Std`-owned or absent
// resolution always leaves the intrinsic path in place.
func hasFuncOverrideNative(ctx: in Ctx, funcName: in String, argc: in Int): Bool {
  match mapGet(ctx.sigs, funcName + "/" + argc.toString()) {
    case Some(sig) -> not (sig.pkg == "Std" or sig.pkg.startsWith("Std."))
    case None -> false
  }
}

/// Prelude `println(x)`: a codegen builtin taking any value, as on the MSIL
/// and JVM backends. A program need not import `Std.Console` to use it, so it
/// lowers straight to the runtime's line write (#7413). It is intercepted
/// before name resolution because `Std.Console.println` takes only a
/// `String`: resolving a `println(<Byte>)` against it, whenever `Std.Console`
/// is in the import closure, rejected the call (#7858). A scalar prints what
/// its `toString` returns.
func lowerPreludePrintln(ctx: in Ctx, insns: in List[NInsn], args: in List[CallArg], line: in Int): NVal {
  if args.count == 0 {
    val empty = emitStringLiteral(ctx, insns, "")
    return callRuntime(
      ctx,
      insns,
      "lyric_console_write_line",
      NVoid,
      arg2(NI32, NLitInt(v = 1i64, ty = NI32), empty.ty, empty.value)
    )
  }
  val pv = lowerPositionalArg(ctx, insns, args, 0)
  val text = if isStringNType(pv.ty) {
    pv
  } else {
    val noMethodArgs: List[CallArg] = newList()
    val pExpr: Option[Expr] = match args[0] {
      case CAPositional(ex) -> Some(value = ex)
      case CANamed(_, value, _) -> Some(value = value)
    }
    match lowerScalarMethodCall(ctx, insns, pv, "toString", noMethodArgs, line, pExpr) {
      case Some(sv) -> sv
      case None -> panic(
        "Lyric.LlvmCodegen: println(x) on a value of this type is not yet supported for --target native; " +
          "pass a String or a scalar"
      )
    }
  }
  callRuntime(
    ctx,
    insns,
    "lyric_console_write_line",
    NVoid,
    arg2(NI32, NLitInt(v = 1i64, ty = NI32), text.ty, text.value)
  )
}

func lowerCall(ctx: in Ctx, insns: in List[NInsn], fnExpr: in Expr, args: in List[CallArg], line: in Int): NVal {
  lowerCallEx(ctx, insns, fnExpr, args, line, false)
}

/// `wantTask` is true only for the immediate call under a `spawn`: an
/// async callee then yields its un-awaited task value instead of
/// awaiting in place.
func lowerCallEx(
  ctx: in Ctx,
  insns: in List[NInsn],
  fnExpr: in Expr,
  args: in List[CallArg],
  line: in Int,
  wantTask: in Bool,
): NVal {
  var retWant: Option[NType] = None
  if ctx.pendingCallRetWant.count > 0 {
    retWant = Some(value = ctx.pendingCallRetWant[0])
    ctx.pendingCallRetWant.clear()
  }
  // Builtins first.
  match fnExpr.kind {
    case EPath(path) -> {
      if path.segments.count == 1 {
        val n = path.segments[0]
        if n == arrayCopyIntrinsic() and args.count == 1 {
          return lowerPositionalArg(ctx, insns, args, 0)
        }
        if n == arrayUncheckedIntrinsic() and args.count == 1 {
          return lowerPositionalArg(ctx, insns, args, 0)
        }
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
        if n == "println" and args.count <= 1 and not hasFuncOverrideNative(ctx, n, args.count) {
          return lowerPreludePrintln(ctx, insns, args, line)
        }
        if (n == "nativeLoadByte" and args.count == 2) or (n == "nativeStoreByte" and args.count == 3) {
          return lowerNativeByteAccess(ctx, insns, n, args)
        }
        if n == "nativeNullPtr" and args.count == 0 {
          // The C NULL pointer as a NativePtr[Byte] (N4.5) — e.g. the
          // attr argument of pthread_create.  Placement is the mode
          // checker's N0100 charge, like nativeAddrOf.
          return NVal(ty = NPtr(pointee = NI8), value = NLitNull(ty = NPtr(pointee = NI8)))
        }
        if n == "mapGet" and args.count == 2 and not hasFuncOverrideNative(ctx, n, args.count) {
          // Reserved Std.Collections accessor (N5.8): its pure-Lyric
          // body routes through an out-mode kernel call the native
          // backend does not lower.
          val m = lowerCallArgExpecting0Plain(ctx, insns, args)
          return lowerMapGetBuiltin(ctx, insns, m, args)
        }
        if n == "dictGetKeys" and args.count == 1 and not hasFuncOverrideNative(ctx, n, args.count) {
          val m = lowerCallArgExpecting0Plain(ctx, insns, args)
          val kTy = match mapKeyOfType(ctx, m.ty) {
            case Some(t) -> t
            case None -> panic(
              "Lyric.LlvmCodegen: 'dictGetKeys' is reserved for Std.Collections maps on --target native"
            )
          }
          return lowerMapSnapshotBuiltin(ctx, insns, m, "lyric_map_keys", kTy)
        }
        if n == "dictGetValues" and args.count == 1 and not hasFuncOverrideNative(ctx, n, args.count) {
          val m = lowerCallArgExpecting0Plain(ctx, insns, args)
          val vTy = match mapValOfType(ctx, m.ty) {
            case Some(t) -> t
            case None -> panic(
              "Lyric.LlvmCodegen: 'dictGetValues' is reserved for Std.Collections maps on --target native"
            )
          }
          return lowerMapSnapshotBuiltin(ctx, insns, m, "lyric_map_values", vTy)
        }
        if (n == "newList" or n == "newListWithCapacity" or n == "newMap") and not hasFuncOverrideNative(ctx, n, args.count) {
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
        if n == "__lyric_protected_wait" or n == "__lyric_protected_notify" {
          panic("Lyric.LlvmCodegen: protected-type `when:` barriers are not yet supported for --target native (D-N-017)")
        }
        if n == "assert" and args.count >= 1 {
          val cond = lowerPositionalArg(ctx, insns, args, 0)
          val okL = freshLabel(ctx, "assert.ok")
          val failL = freshLabel(ctx, "assert.fail")
          insns.add(NCondBr(cond = cond.value, thenLabel = okL, elseLabel = failL))
          insns.add(NLabel(name = failL))
          if args.count > 1 {
            // The message is evaluated only on the failure path, as on
            // MSIL/JVM, so a dynamic message costs nothing when the
            // assertion holds.
            val msg = lowerPositionalArg(ctx, insns, args, 1)
            val cs = callRuntime(ctx, insns, "lyric_string_to_cstring", NPtr(pointee = NI8), arg1(lyricStringNType(), msg.value))
            val filePtr = emitRawCString(ctx, insns, ctx.mainPkg)
            val pArgs: List[NArg] = newList()
            pArgs.add(NArg(ty = NPtr(pointee = NI8), value = cs.value))
            pArgs.add(NArg(ty = NPtr(pointee = NI8), value = filePtr.value))
            pArgs.add(NArg(ty = NI32, value = NLitInt(v = line.toLong(), ty = NI32)))
            insns.add(NCallVoid(fn = NGlobal(name = "lyric_panic_msg"), args = pArgs))
            insns.add(NUnreachable)
            insns.add(NLabel(name = freshLabel(ctx, "dead")))
          } else {
            emitPanicRaw(ctx, insns, "assertion failed", line)
          }
          insns.add(NBr(label = okL))
          insns.add(NLabel(name = okL))
          return NVal(ty = NVoid, value = NUndef(ty = NVoid))
        }
      }
    }
    case EMember(receiver, memberName) -> {
      if not isPackagePathExpr(ctx, receiver) {
        // `isPackagePathExpr` only recognizes a flat `EPath` receiver, so a
        // multi-segment qualified callee (`Pkg.Sub.Thing(...)`) that
        // `Lyric.AliasRewriter` left uncollapsed — because a local/param in
        // scope happens to share the callee's head segment — reaches here
        // still nested, and looks exactly like a local-value receiver.  The
        // type checker's own call resolution tries the qualified package
        // path first regardless of that shadowing (`constructorSymbolOf` /
        // `unionCaseSymbolOf` / `directSig` in `typechecker_exprs.l`), only
        // falling back to the receiver's method space when no
        // package-qualified match exists — mirror that order here (#6841,
        // #6842) before committing to the local-receiver interpretation.
        match tryLowerQualifiedCallee(ctx, insns, fnExpr, args, line, wantTask, retWant) {
          case Some(v) -> return v
          case None -> {
          }
        }
        val recvVal = lowerExpr(ctx, insns, receiver)
        // `r.f(args)` where `f` is a function-typed field of the record `r`:
        // read the field (a borrow) and call the closure it holds.
        match recInfoOfType(ctx, recvVal.ty) {
          case Some(ri) -> {
            val fieldIdx = recFieldIndex(ri, memberName)
            if fieldIdx >= 0 {
              match closureSigOfType(ctx, ri.fieldTys[fieldIdx]) {
                case Some(cs) -> {
                  val fieldVal = lowerRecordFieldLoad(ctx, insns, ri, recvVal, memberName)
                  return lowerClosureCall(ctx, insns, fieldVal, cs, args)
                }
                case None -> {
                }
              }
            }
          }
          case None -> {
          }
        }
        val someRecvExpr: Option[Expr] = Some(value = receiver)
        match lowerScalarMethodCall(ctx, insns, recvVal, memberName, args, line, someRecvExpr) {
          case Some(v) -> return v
          case None -> {
          }
        }
        match lowerCollectionMethodCall(ctx, insns, recvVal, memberName, args) {
          case Some(v) -> return v
          case None -> return lowerUfcsCall(ctx, insns, recvVal, memberName, args, line, wantTask, methodCallSiteKey(fnExpr))
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
      if tname == arrayCopyIntrinsic() and args.count == 1 {
        return lowerArrayCopyCall(ctx, insns, targs, args)
      }
      if tname == arrayFillIntrinsic() and args.count == 1 {
        return lowerArrayFillCall(ctx, insns, targs, args)
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
      val explicitTes: List[TypeExpr] = newList()
      var allTypes = true
      for ta in targs {
        match ta {
          case TAType(inner) -> explicitTes.add(inner)
          case TAValue(_) -> {
            allTypes = false
          }
        }
      }
      if allTypes and tname.length > 0 {
        match tryLowerExplicitGenericCall(ctx, insns, tname, explicitTes, args, line, wantTask, retWant) {
          case Some(v) -> return v
          case None -> {
          }
        }
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
      if iname.length > 0 {
        val idxTes: List[TypeExpr] = newList()
        for ix in idxs {
          idxTes.add(exprAsTypeExpr(ix))
        }
        match tryLowerExplicitGenericCall(ctx, insns, iname, idxTes, args, line, wantTask, retWant) {
          case Some(v) -> return v
          case None -> {
          }
        }
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
          case None -> panic(
            "Lyric.LlvmCodegen: '" + cpath.segments[0] +
              "' is not callable (only function-typed values support indirect calls)"
          )
        }
      }
    }
    case _ -> {
    }
  }
  // `N.m(args)` where `N` is a module-level `val`/`const` (not a local, not a
  // package) reaches here as a flat two-segment path: it is a method call on
  // the value, so re-enter as a member call on the value receiver.
  match fnExpr.kind {
    case EPath(mpath) -> {
      if mpath.segments.count == 2 and not ctx.varTypes.containsKey(mpath.segments[0]) {
        val headSegs: List[String] = newList()
        headSegs.add(mpath.segments[0])
        val headExpr = Expr(kind = EPath(path = ModulePath(segments = headSegs, span = mpath.span)), span = fnExpr.span)
        if not isPackagePathExpr(ctx, headExpr) {
          val memberCallee = Expr(kind = EMember(receiver = headExpr, memberName = mpath.segments[1]), span = fnExpr.span)
          return lowerCallEx(ctx, insns, memberCallee, args, line, wantTask)
        }
      }
    }
    case _ -> {
    }
  }
  // A bare call inside a method to a method of the receiver's type is
  // `self.m(args)`, ahead of any free function of that name, as on dotnet
  // and the JVM (#1722, #7985).
  match fnExpr.kind {
    case EPath(bp) -> if bp.segments.count == 1 {
      match mapGet(ctx.varTypes, "self") {
        case Some(selfTy) -> if receiverHasMethod(ctx, receiverStructName(selfTy), bp.segments[0]) {
          val selfRecv = Expr(kind = ESelf, span = fnExpr.span)
          val siblingCallee = Expr(kind = EMember(receiver = selfRecv, memberName = bp.segments[0]), span = fnExpr.span)
          return lowerCallEx(ctx, insns, siblingCallee, args, line, wantTask)
        }
        case None -> ()
      }
    }
    case _ -> ()
  }
  // Static function call through the registry.
  val key = callKeyOf(fnExpr, args.count)
  if key.length == 0 {
    panic(
      "Lyric.LlvmCodegen: indirect calls are not yet supported for --target native (rest of Phase N2.6): the callee is a " +
        describeExprKind(fnExpr.kind) +
        " expression (in " +
        ctx.curPkg[0] +
        " at line " +
        line.toString() +
        ")"
    )
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
      sigOpt = bareSig(ctx, key)
    }
  }
  match sigOpt {
    case Some(sig) -> lowerResolvedSigCall(ctx, insns, sig, args, line, wantTask)
    case None -> {
      // Generic functions instantiate per call site (N3.1).
      val noPre: List[NVal] = newList()
      if ctx.genericFnDefs.containsKey(ctx.curPkg[0] + "." + key) {
        return lowerGenericFnCall(ctx, insns, ctx.curPkg[0] + "." + key, noPre, args, line, wantTask, retWant)
      }
      if ctx.genericFnDefs.containsKey(key) {
        return lowerGenericFnCall(ctx, insns, key, noPre, args, line, wantTask, retWant)
      }
      lowerConstructCall(ctx, insns, fnExpr, args, key, line, retWant)
    }
  }
}

/// Lowers a call to an already-resolved static function signature: arg
/// binding, the `Std.Time.sleepMillis` / `Std.Process.runCapture*` async
/// leaf intercepts, and the direct/task call emission.  Shared by the
/// registry lookup above and `tryLowerQualifiedCallee`'s AliasRewriter
/// shadow-defeat fallback (#6841/#6842), which resolves the same
/// `ctx.sigs` registry from a callee AST shape the plain lookup above
/// can't key (a still-nested `EMember` chain).
func lowerResolvedSigCall(
  ctx: in Ctx,
  insns: in List[NInsn],
  sig: in NFuncSig,
  args: in List[CallArg],
  line: in Int,
  wantTask: in Bool,
): NVal {
  val callArgs = lowerCallArgs(ctx, insns, sig, args)
  if ctx.curAsyncTask.count > 0 and sig.irName == "Std.Time.sleepMillis" and callArgs.count == 1 {
    return emitAsyncSleep(ctx, insns, callArgs)
  }
  // The async process leaf (D-N-023).  Only for awaited-in-place calls:
  // a direct `spawn runCapture(...)` keeps the blocking sync path (spawn
  // an async wrapper function to overlap captures).  Arity-coupled to
  // `Std.Process.runCapture/3`, `Std.Process.runCaptureWithInput/4`,
  // and the seam's /4 — if any signature changes, update this intercept
  // AND the llvm_bridge.l reachability walk together, or the redirect
  // silently disables (#5108).
  if ctx.curAsyncTask.count > 0 and not wantTask {
    val isRunCapture = sig.irName == "Std.Process.runCapture" and callArgs.count == 3
    val isRunCaptureWithInput = sig.irName == "Std.Process.runCaptureWithInput" and callArgs.count == 4
    if isRunCapture or isRunCaptureWithInput {
      match emitAsyncRunCapture(ctx, insns, sig, callArgs) {
        case Some(v) -> return v
        case None -> {
        }
      }
    }
  }
  if sig.isAsync {
    return emitAsyncCall(ctx, insns, sig.irName, callArgs, retTypeToN(ctx, sig.retTy), wantTask)
  }
  val retTy = retTypeToN(ctx, sig.retTy)
  if sig.isExternSym and cAbiArch(ctx.abiTriple).length > 0 and cAbiNeeded(callArgs, retTy) {
    return cAbiExternCall(ctx, insns, sig.irName, callArgs, retTy)
  }
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

/// AliasRewriter shadow-defeat fallback (#6841/#6842): a fully qualified
/// call callee (`Pkg.Sub.Thing(...)`, parsed as nested `EMember`s per
/// `parsePostfixExpr`) whose head segment happens to share a name with a
/// local/param in scope reaches codegen still nested — `AliasRewriter`
/// deliberately leaves it uncollapsed (`alias_rewriter.l` §6b) so a
/// genuine local-value method chain still resolves — but the type
/// checker's own call resolution tries the qualified package path first,
/// unconditionally, and only falls back to the receiver's method space
/// when no package-qualified match exists (`constructorSymbolOf` /
/// `unionCaseSymbolOf` / `directSig` in `typechecker_exprs.l`).  Mirror
/// that order here: try the full flattened path as a free function or a
/// record/union/generic/distinct construction; `None` when nothing
/// matches, so the caller falls back to the local-receiver interpretation.
func tryLowerQualifiedCallee(
  ctx: in Ctx,
  insns: in List[NInsn],
  fnExpr: in Expr,
  args: in List[CallArg],
  line: in Int,
  wantTask: in Bool,
  retWant: in Option[NType],
): Option[NVal] {
  val segs = match flattenMemberPathSegs(fnExpr) { case Some(s) -> s; case None -> return None }
  if segs.count < 2 {
    return None
  }
  val plainName = modulePathJoin(segs)
  val key = plainName + "/" + args.count.toString()
  val selfKey = ctx.curPkg[0] + "." + key
  var sigOpt = mapGet(ctx.sigs, selfKey)
  match sigOpt {
    case Some(_) -> {
    }
    case None -> {
      sigOpt = bareSig(ctx, key)
    }
  }
  match sigOpt {
    case Some(sig) -> return Some(value = lowerResolvedSigCall(ctx, insns, sig, args, line, wantTask))
    case None -> {
    }
  }
  val noPre: List[NVal] = newList()
  if ctx.genericFnDefs.containsKey(selfKey) {
    return Some(value = lowerGenericFnCall(ctx, insns, selfKey, noPre, args, line, wantTask, retWant))
  }
  if ctx.genericFnDefs.containsKey(key) {
    return Some(value = lowerGenericFnCall(ctx, insns, key, noPre, args, line, wantTask, retWant))
  }
  tryLowerConstruct(ctx, insns, plainName, args, line, retWant)
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
  retWant: in Option[NType],
): NVal {
  val inner = match fnExpr.kind { case ETypeApp(f, _) -> f; case _ -> fnExpr }
  val name = match flattenMemberPathSegs(inner) { case Some(segs) -> modulePathJoin(segs); case None -> "" }
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
      val argExpr: Option[Expr] = match args[0] {
        case CAPositional(ex) -> Some(value = ex)
        case CANamed(_, value, _) -> Some(value = value)
      }
      // `lowerScalarMethodCall` returns `None` for a non-scalar receiver so
      // a user-defined `T.toString` method wins on the `.toString()` path
      // (#7257). The prelude spelling has no such method to fall back to,
      // so a non-scalar argument is reported here rather than being
      // resolved against unrelated construct forms below (#4984).
      match lowerScalarMethodCall(ctx, insns, tv, "toString", noMethodArgs, line, argExpr) {
        case Some(result) -> return result
        case None -> panic(
          "Lyric.LlvmCodegen: toString(x) on this type is not yet supported for --target native (Phase N1)"
        )
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
      // A weak reference owns one weak count on the target: bump it now
      // (lyric_weak_retain, via the weak-dispatching emitRetain) and register
      // the weak value as an owned temp so the ownership machinery drops that
      // count (lyric_weak_release) at scope end — keeping the object header
      // alive for as long as any NativeWeak is held (#5504).
      val weakVal = NVal(ty = wty, value = NLocal(name = dest))
      emitRetain(ctx, insns, weakVal)
      registerTemp(ctx, weakVal)
      return weakVal
    }
    match tryLowerConstruct(ctx, insns, name, args, line, retWant) {
      case Some(v) -> return v
      case None -> {
      }
    }
  }
  panic(
    "Lyric.LlvmCodegen: cannot resolve call target '" + key +
      "' for --target native (the callee may be outside the bundled import closure)"
  )
}

/// Registry lookup shared by `lowerConstructCall` (the `ctx.sigs`-miss
/// fallback for a callee already reduced to a flat qualified name) and
/// `tryLowerQualifiedCallee` (the AliasRewriter shadow-defeat fallback,
/// #6841/#6842): resolves `name` — a fully dot-joined callee path —
/// against the record / union-case / generic-record / generic-union-case
/// / distinct-type construction registries.  `None` when `name` matches
/// none of them.
/// Looks up `m` under the caller's OWN package-qualified spelling of
/// `bareOrDotted` first, falling back to the bare (unqualified) key only
/// when the caller's own package never registered one. `addRecKey` /
/// `replaceRecKey` (and the analogous case-ref / distinct-type
/// registration sites) add BOTH a `<pkg>.<name>` key and a bare `<name>`
/// key for every record/case/distinct-type declaration, so that a
/// same-package unqualified reference resolves without the caller having
/// to know its own package. But the bare key is a single GLOBAL slot
/// shared by every package in the bundle — `addRecKey`'s "first-wins
/// shadowing across packages" rule means whichever package's declaration
/// happens to be collected FIRST wins the bare key for every OTHER
/// package's unqualified references too (#7627): two packages each
/// declaring `record Widget { ... }` collide on the bare `"Widget"` key,
/// so a construct call inside the package that registered SECOND
/// silently builds the FIRST package's `Widget`. Qualifying with the
/// caller's own `ctx.curPkg[0]` first closes that: every legitimate
/// same-package reference already has a `<pkg>.<name>` entry (added
/// alongside the bare one at the same declaration site), so this can
/// never regress an existing resolution — it only ever prefers the
/// caller's own declaration over a same-named stranger's.
func curPkgQualifiedGet[T](ctx: in Ctx, m: in Map[String, T], bareOrDotted: in String): Option[T] {
  if ctx.curPkg.count > 0 {
    match mapGet(m, ctx.curPkg[0] + "." + bareOrDotted) {
      case Some(v) -> return Some(value = v)
      case None -> {
      }
    }
  }
  mapGet(m, bareOrDotted)
}

/// The `genericFnDefs` key of method `nameAndArity` (`<name>/<arity>`, the
/// receiver counted) of the generic record that `recvTyName` instantiates.
func genericRecordMethodKey(ctx: in Ctx, recvTyName: in String, nameAndArity: in String): Option[String] {
  match mapGet(ctx.instMeta, recvTyName) {
    case Some(im) -> {
      val k = im.gkey + "." + nameAndArity
      if ctx.genericFnDefs.containsKey(k) {
        return Some(value = k)
      }
      val dot = lastDotIndex(im.gkey)
      if dot > 0 {
        val bk = Str.substring(im.gkey, dot + 1, im.gkey.length - dot - 1) + "." + nameAndArity
        if ctx.genericFnDefs.containsKey(bk) {
          return Some(value = bk)
        }
      }
      None
    }
    case None -> None
  }
}

/// Whether the type named `recvTyName` has a method `name` of any arity: a
/// record method or dot-named function registered as `<Type>.<name>/<n>`, an
/// impl method, or a generic record's method.
func receiverHasMethod(ctx: in Ctx, recvTyName: in String, name: in String): Bool {
  if recvTyName.length == 0 {
    return false
  }
  val dot = lastDotIndex(recvTyName)
  val bare = if dot > 0 { Str.substring(recvTyName, dot + 1, recvTyName.length - dot - 1) } else { recvTyName }
  // The receiver is parameter 0, so a method's registered arity is at least 1.
  var n = 1
  while n <= 32 {
    val suffix = "." + name + "/" + n.toString()
    if ctx.sigs.containsKey(recvTyName + suffix) or ctx.sigs.containsKey(bare + suffix) {
      return true
    }
    if ctx.implDirectMethods.containsKey(recvTyName + suffix) {
      return true
    }
    match genericRecordMethodKey(ctx, recvTyName, name + "/" + n.toString()) {
      case Some(_) -> return true
      case None -> ()
    }
    // A record-body method is a package function whose first parameter is
    // `self` of the record's type (D037).
    val key = name + "/" + n.toString()
    val own = if ctx.curPkg.count > 0 { mapGet(ctx.sigs, ctx.curPkg[0] + "." + key) } else { mapGet(ctx.sigs, key) }
    match own {
      case Some(sig) -> if isSelfMethodOf(sig, bare) { return true }
      case None -> ()
    }
    n = n + 1
  }
  false
}

func isSelfMethodOf(sig: in NFuncSig, typeName: in String): Bool {
  if sig.paramNames.count == 0 or sig.paramNames[0] != "self" {
    return false
  }
  match sig.paramTys[0].kind {
    case TRef(p) -> p.segments.count > 0 and p.segments[p.segments.count - 1] == typeName
    case TSelf -> true
    case _ -> false
  }
}

/// The IR struct name of a receiver type: the pointee of a heap object's
/// pointer, or a by-value record's struct itself; "" for any other type.
func receiverStructName(t: in NType): String {
  match t {
    case NPtr(pointee) -> match pointee { case NStruct(n, _) -> n; case _ -> "" }
    case NStruct(n, _) -> n
    case _ -> ""
  }
}

func tryLowerConstruct(
  ctx: in Ctx,
  insns: in List[NInsn],
  name: in String,
  args: in List[CallArg],
  line: in Int,
  retWant: in Option[NType],
): Option[NVal] {
  match curPkgQualifiedGet(ctx, ctx.recordDefs, name) {
    case Some(ri) -> {
      if ctx.protectedRecNames.containsKey(ri.irName) {
        return Some(value = lowerProtectedConstructArgs(ctx, insns, ri, args))
      }
      return Some(value = lowerRecordConstructArgs(ctx, insns, ri, args))
    }
    case None -> {
    }
  }
  match curPkgQualifiedGet(ctx, ctx.caseRefs, name) {
    case Some(cref) -> {
      val ui = match mapGet(ctx.unionDefs, cref.unionKey) {
        case Some(u) -> u
        case None -> panic("Lyric.LlvmCodegen: internal — case '" + name + "' references unregistered union")
      }
      return Some(value = lowerUnionConstruct(ctx, insns, ui, cref.caseIdx, args))
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
      return Some(value = lowerGenericCaseConstruct(ctx, insns, gkey, caseName, args))
    }
    case None -> {
    }
  }
  if ctx.genericRecordDefs.containsKey(name) {
    return Some(value = lowerGenericRecordConstruct(ctx, insns, genericQualifiedKey(ctx, name), args, retWant))
  }
  match curPkgQualifiedGet(ctx, ctx.distinctDefs, name) {
    case Some(di) -> return Some(value = lowerDistinctConstruct(ctx, insns, name, di, args, line))
    case None -> {
    }
  }
  // `X.from(v)` (language reference §2.3) and the older `X.From(v)`.
  if Str.endsWith(name, ".from") or Str.endsWith(name, ".From") {
    val baseName = Str.substring(name, 0, name.length - 5)
    match curPkgQualifiedGet(ctx, ctx.distinctDefs, baseName) {
      case Some(di) -> return Some(value = lowerDistinctConstruct(ctx, insns, baseName, di, args, line))
      case None -> {
      }
    }
  }
  if Str.endsWith(name, ".tryFrom") {
    val baseName = Str.substring(name, 0, name.length - 8)
    match curPkgQualifiedGet(ctx, ctx.distinctDefs, baseName) {
      case Some(di) -> return Some(value = lowerDistinctTryFrom(ctx, insns, baseName, di, args, line))
      case None -> {
      }
    }
  }
  None
}

/// UFCS method-call resolution: `recv.name(args)` calls the function
/// `name` with the receiver as its first argument.  Resolution tries,
/// in order: the current package; the receiver's static struct type name
/// (package-qualified, then bare) joined with `name` — the key an
/// extension-method-style declaration (`func Identity.rawHandle(...)`)
/// registers under; the receiver type's defining PACKAGE alone joined
/// with `name` (methods in type bodies desugar to bare package functions,
/// D037); then bare `name` alone.
func lowerUfcsCall(
  ctx: in Ctx,
  insns: in List[NInsn],
  recv: in NVal,
  name: in String,
  args: in List[CallArg],
  line: in Int,
  wantTask: in Bool,
  siteKey: in String,
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
          "' is not yet lowerable for --target native — only non-generic abstract interface methods dispatch through the vtable; default and generic interface methods are deferred (N3.2). (Self-returning and Self-parameter interface methods ARE supported, #7585.)"
      )
    }
    case None -> {
    }
  }
  // The callee the type checker resolved: its parameter count plus the
  // receiver (#7828), and whether it is a dot-named function rather than a
  // method of the receiver's type (#8098).
  val originKey = if ctx.curOrigin.count > 0 { ctx.curOrigin[0] + "|" } else { "" }
  val callTarget = methodCallTarget(ctx.methodCallArities, ctx.curPkg[0] + "|" + originKey + siteKey, args.count)
  val arity = (callTarget.arity + 1).toString()
  // `.<name>(...)` on a CONCRETE record receiver — try an `impl I
  // for R` method FIRST, via the index `registerImplDirectMethods` built
  // from every impl's PACKAGE-QUALIFIED `<pkg>.<record>.<method>/<arity>`
  // (#7627). This has to run BEFORE the bare `curPkg + "." + name`
  // lookup below: that lookup matches ANY same-arity function in the
  // current package regardless of its receiver type (it does not verify
  // the match is actually a method of THIS record), so an unrelated free
  // function sharing the impl method's bare name and arity would
  // otherwise shadow it (#7600). A record's own-body method can never
  // share a name with one of its impl methods any more — the type
  // checker rejects that shape as T0139 (#7626) — so trying the impl
  // index first can never steal a match that belongs to a genuinely
  // different function: an impl method's own key is collision-free by
  // construction (package + record + method).
  var sigOpt: Option[NFuncSig] = None
  val recvTyName = receiverStructName(recv.ty)
  // A call resolved to a dot-named function `func T.m(self, ...)` takes it
  // over any same-named method of the type (#8098).
  if callTarget.dotNamed and recvTyName.length > 0 {
    sigOpt = mapGet(ctx.sigs, recvTyName + "." + name + "/" + arity)
    val dnDot = lastDotIndex(recvTyName)
    match sigOpt {
      case Some(_) -> ()
      case None -> if dnDot > 0 {
        sigOpt = mapGet(
          ctx.sigs,
          Str.substring(recvTyName, dnDot + 1, recvTyName.length - dnDot - 1) + "." + name + "/" + arity
        )
      }
    }
  }
  val haveDotNamed = match sigOpt { case Some(_) -> true; case None -> false }
  if recvTyName.length > 0 and not haveDotNamed {
    match mapGet(ctx.implDirectMethods, recvTyName + "." + name + "/" + arity) {
      case Some(sigKey) -> {
        sigOpt = mapGet(ctx.sigs, sigKey)
      }
      case None -> {
      }
    }
  }
  // A method of a generic record, on one of its instances.
  match sigOpt {
    case Some(_) -> ()
    case None -> match genericRecordMethodKey(ctx, recvTyName, name + "/" + arity) {
      case Some(gk) -> {
        val instPre: List[NVal] = newList()
        instPre.add(recv)
        return lowerGenericFnCall(ctx, insns, gk, instPre, args, line, wantTask, None)
      }
      case None -> ()
    }
  }
  match sigOpt {
    case Some(_) -> {
    }
    case None -> {
      if recvTyName.length > 0 {
        val tyName = recvTyName
        // `tyName` is already package-qualified (e.g. "Std.Tls.Identity"
        // for a record/opaque type's ARC pointee, or a by-value record's
        // struct). A dot-named function (`func Identity.rawHandle(...)`)
        // and a D037 in-type-body method both register under the compound
        // "TypeName.methodName" name — try the exact qualified form first,
        // then the bare "TypeName.methodName" form (no package prefix;
        // matches the registry's own bare-name key).  This runs before the
        // package-level lookups below, so a method of the receiver's type
        // wins over a same-named free function.
        sigOpt = mapGet(ctx.sigs, tyName + "." + name + "/" + arity)
        val dotIdx = lastDotIndex(tyName)
        match sigOpt {
          case Some(_) -> {
          }
          case None -> {
            if dotIdx > 0 {
              val bareTyName = Str.substring(tyName, dotIdx + 1, tyName.length - dotIdx - 1)
              sigOpt = mapGet(ctx.sigs, bareTyName + "." + name + "/" + arity)
            }
          }
        }
      }
    }
  }
  match sigOpt {
    case Some(_) -> {
    }
    case None -> {
      sigOpt = mapGet(ctx.sigs, ctx.curPkg[0] + "." + name + "/" + arity)
    }
  }
  match sigOpt {
    case Some(_) -> {
    }
    case None -> {
      // A UFCS call to a package function of the receiver type's defining
      // package (not qualified by the type name).
      val defDot = lastDotIndex(recvTyName)
      if defDot > 0 {
        sigOpt = mapGet(ctx.sigs, Str.substring(recvTyName, 0, defDot) + "." + name + "/" + arity)
      }
    }
  }
  match sigOpt {
    case Some(_) -> {
    }
    case None -> {
      sigOpt = bareSig(ctx, name + "/" + arity)
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
        return lowerGenericFnCall(ctx, insns, ctx.curPkg[0] + "." + name + "/" + arity, pre, args, line, wantTask, None)
      }
      if ctx.genericFnDefs.containsKey(name + "/" + arity) {
        return lowerGenericFnCall(ctx, insns, name + "/" + arity, pre, args, line, wantTask, None)
      }
    }
  }
  val sig = match sigOpt {
    case Some(s) -> s
    case None -> panic(
      "Lyric.LlvmCodegen: method '." + name +
        "' on this receiver is not yet supported for --target native (no matching function '" +
        name +
        "/" +
        arity +
        "' in the bundled import closure)"
    )
  }
  val callArgs = lowerCallArgsWithReceiver(ctx, insns, sig, recv, args)
  if ctx.curAsyncTask.count > 0 and sig.irName == "Std.Time.sleepMillis" and callArgs.count == 1 {
    return emitAsyncSleep(ctx, insns, callArgs)
  }
  if sig.isAsync {
    return emitAsyncCall(ctx, insns, sig.irName, callArgs, retTypeToN(ctx, sig.retTy), wantTask)
  }
  val retTy = retTypeToN(ctx, sig.retTy)
  if sig.isExternSym and cAbiArch(ctx.abiTriple).length > 0 and cAbiNeeded(callArgs, retTy) {
    return cAbiExternCall(ctx, insns, sig.irName, callArgs, retTy)
  }
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

/// The index of the last `.` in `s`, or -1 if none. Exported so the
/// bridge's reachability walk (`llvm_bridge.l`'s `registerFileFns`) can
/// split an extension-method-style declared name ("Identity.rawHandle")
/// into its trailing segment, mirroring this file's own `lowerUfcsCall`
/// resolution.
pub func lastDotIndex(s: in String): Int {
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

// ─────────────────────────────────────────────────────────────────────────────
// §10.4. By-value records (docs/67 §4.2).
// ─────────────────────────────────────────────────────────────────────────────
// A record with no `var` field whose fields are all by-value (scalars, enums,
// distinct types over those, and other by-value records) lowers to a plain LLVM
// struct VALUE: no ARC header, no heap allocation, no retain/release, no
// destructor.  The decision is made once per record declaration, before any
// layout is computed, so every other record's field types and every type
// mapping agree.  Records with a `var` field keep the shared heap form (D157);
// so do opaque types and the target of an `impl I for R` (an interface box
// holds a heap object).
record NByValState {
  decls: Map[String, RecordDecl]
  declPkgs: Map[String, String]
  distincts: Map[String, DistinctTypeDecl]
  distinctPkgs: Map[String, String]
  enums: Map[String, Bool]
  // Names that resolve to a non-record heap type, prefixed by kind: "r:" for a
  // protected type or generic record, "u:" for a union, "i:" for an interface.
  heapNames: Map[String, Bool]
  heapOnly: Map[String, Bool]
  results: Map[String, NRecInfo]
  failed: Map[String, Bool]
  visiting: Map[String, Bool]
  typeDefs: List[NTypeDefn]
  // Non-generic unions: declarations by qualified and bare name, and the ones
  // that classify as inline (docs/67 §4.2) by IR name.
  unionDecls: Map[String, UnionDecl]
  unionPkgs: Map[String, String]
  uresults: Map[String, NUnionInfo]
  // Generic declarations by qualified and bare name (first wins, as the
  // generic registries), for classifying instantiated field types.
  genUnionDecls: Map[String, UnionDecl]
  genUnionPkgs: Map[String, String]
  genRecDecls: Map[String, RecordDecl]
  genRecPkgs: Map[String, String]
  // The generic instantiations classified by-value, in registration order:
  // their layouts and metadata, registered with the other by-value types
  // before any layout, exactly as codegen's lazy instantiation would.
  instRecs: List[NRecInfo]
  instUnions: List[NUnionInfo]
  instMetaNames: List[String]
  instMetaInfos: List[NInstInfo]
}

/// The path an `impl <Iface> for <Target>`'s target type names.
func implTargetPath(te: in TypeExpr): Option[ModulePath] {
  match te.kind {
    case TRef(path) -> Some(value = path)
    case TGenericApp(head, _) -> Some(value = head)
    case TParen(inner) -> implTargetPath(inner)
    case _ -> None
  }
}

/// Fill `heapOnly` (`Ctx.heapOnlyRecs`) with the package-qualified names of
/// the records that keep the heap form whatever their fields: opaque types.
/// An `impl I for R` target is classified like any record: a by-value one is
/// boxed when it is upcast to the interface (`buildIfaceBox`), and its vtable
/// slots are thunks that read it out of the box (#8010).
func fillHeapOnlyRecs(heapOnly: in Map[String, Bool], units: in List[CodegenUnit]): Unit {
  for u in units {
    for n in u.opaqueNames {
      putOnce(heapOnly, u.pkgName + "." + n)
    }
  }
}

func isHeapOnlyRec(ctx: in Ctx, pkg: in String, name: in String): Bool {
  ctx.heapOnlyRecs.containsKey(pkg + "." + name)
}

func recordHasVarField(rd: in RecordDecl): Bool {
  for f in recFieldsOf(rd) {
    if f.isMutable {
      return true
    }
  }
  false
}

/// A field type that keeps a record by-value once resolved: a scalar, a
/// Unit placeholder, or another by-value record's struct value.
func isByValueFieldNType(t: in NType): Bool {
  match t {
    case NArray(e, _) -> isByValueFieldNType(e)
    case NI1 -> true
    case NI8 -> true
    case NI32 -> true
    case NI64 -> true
    case NFloat -> true
    case NDouble -> true
    case NVoid -> true
    case NStruct(_, _) -> true
    case _ -> false
  }
}

func byValuePathKey(pkg: in String, path: in ModulePath): String {
  if path.segments.count == 1 {
    pkg + "." + path.segments[0]
  } else {
    modulePathJoin(path.segments)
  }
}

/// The NType of a by-value field written as `te`, as a zero- or one-element
/// list (empty: the field is not by-value, so the record keeps the heap form).
func classifyByValueField(st: in NByValState, pkg: in String, te: in TypeExpr): List[NType] {
  val noNames: List[String] = newList()
  val noTys: List[NType] = newList()
  classifyByValueFieldEnv(st, pkg, te, noNames, noTys)
}

/// `classifyByValueField` under a generic environment: `envNames[i]` stands for
/// the by-value type `envTys[i]` (the substituted arguments of an instantiation).
func classifyByValueFieldEnv(
  st: in NByValState,
  pkg: in String,
  te: in TypeExpr,
  envNames: in List[String],
  envTys: in List[NType],
): List[NType] {
  val res: List[NType] = newList()
  match te.kind {
    case TParen(inner) -> return classifyByValueFieldEnv(st, pkg, inner, envNames, envTys)
    case TRefined(under, _) -> return classifyByValueFieldEnv(st, pkg, TypeExpr(kind = TRef(path = under), span = te.span), envNames, envTys)
    case TUnit -> {
      res.add(NVoid)
      return res
    }
    case TGenericApp(head, args) -> return classifyGenericApp(st, pkg, head, args, envNames, envTys)
    // `array[N, T]` of a by-value element is itself by-value (D167).
    case TArray(size, elem) -> {
      match arrayLenOfSize(size) {
        case Some(n) -> {
          val ft = classifyByValueFieldEnv(st, pkg, elem, envNames, envTys)
          if ft.count == 1 and isByValueFieldNType(ft[0]) and not isVoidNType(ft[0]) {
            res.add(NArray(elem = ft[0], size = n))
          }
        }
        case None -> ()
      }
      return res
    }
    case TRef(path) -> {
      if path.segments.count == 1 {
        val ei = envIndexOf(envNames, path.segments[0])
        if ei >= 0 {
          res.add(envTys[ei])
          return res
        }
      }
      val joined = byValuePathKey(pkg, path)
      val bare = lastSeg(path)
      // The same precedence as `lookupHeapType`: records (protected types
      // included), unions, enums, distinct types, interfaces — each tried by
      // the qualified name, then the bare one — before the scalar names.
      var declKey = ""
      if st.decls.containsKey(joined) {
        declKey = joined
      } else if st.heapNames.containsKey("r:" + joined) {
        return res
      } else if st.decls.containsKey(bare) {
        declKey = bare
      } else if st.heapNames.containsKey("r:" + bare) {
        return res
      }
      if declKey.length > 0 {
        val rd = st.decls[declKey]
        val rpkg = st.declPkgs[declKey]
        if classifyByValueRecord(st, rpkg, rd) {
          val ri = st.results[rpkg + "." + rd.name]
          res.add(NStruct(name = ri.irName, fields = layoutFieldTys(ri.fieldTys)))
        }
        return res
      }
      var unionKey = ""
      if st.unionDecls.containsKey(joined) {
        unionKey = joined
      } else if st.unionDecls.containsKey(bare) {
        unionKey = bare
      }
      if unionKey.length > 0 {
        val ud = st.unionDecls[unionKey]
        val upkg = st.unionPkgs[unionKey]
        if classifyInlineUnion(st, upkg, ud) {
          val ui = st.uresults[upkg + "." + ud.name]
          res.add(NStruct(name = ui.irName, fields = unionInlineFields(ui.payloadWords)))
        }
        return res
      }
      if st.enums.containsKey(joined) or st.enums.containsKey(bare) {
        res.add(NI32)
        return res
      }
      var distKey = ""
      if st.distincts.containsKey(joined) {
        distKey = joined
      } else if st.distincts.containsKey(bare) {
        distKey = bare
      }
      if distKey.length > 0 {
        val dd = st.distincts[distKey]
        match dd.generics {
          case Some(_) -> return res
          case None -> return classifyByValueField(st, st.distinctPkgs[distKey], dd.underlying)
        }
      }
      if st.heapNames.containsKey("i:" + joined) or st.heapNames.containsKey("i:" + bare) {
        return res
      }
      if bare == "Int" or bare == "Char" {
        res.add(NI32)
      } else if bare == "Long" {
        res.add(NI64)
      } else if bare == "Double" {
        res.add(NDouble)
      } else if bare == "Float" {
        res.add(NFloat)
      } else if bare == "Bool" {
        res.add(NI1)
      } else if bare == "Byte" {
        res.add(NI8)
      }
      res
    }
    case _ -> res
  }
}

/// Classify one non-generic record declaration; a by-value record's full
/// `NRecInfo` lands in `st.results` and its struct definition in `st.typeDefs`
/// (nested by-value records first, so a definition never precedes the ones it
/// embeds).
func classifyByValueRecord(st: in NByValState, pkg: in String, rd: in RecordDecl): Bool {
  val irName = pkg + "." + rd.name
  if st.results.containsKey(irName) {
    return true
  }
  if st.failed.containsKey(irName) or st.visiting.containsKey(irName) {
    return false
  }
  match rd.generics {
    case Some(_) -> return false
    case None -> {
    }
  }
  if recordHasVarField(rd) or st.heapOnly.containsKey(irName) {
    st.failed.add(irName, true)
    return false
  }
  val fields = recFieldsOf(rd)
  if fields.count == 0 {
    st.failed.add(irName, true)
    return false
  }
  st.visiting.add(irName, true)
  val names: List[String] = newList()
  val tys: List[NType] = newList()
  val dflts: List[Option[Expr]] = newList()
  var ok = true
  var i = 0
  while i < fields.count and ok {
    val ft = classifyByValueField(st, pkg, fields[i].ty)
    if ft.count == 0 {
      ok = false
    } else {
      names.add(fields[i].name)
      tys.add(ft[0])
      dflts.add(fields[i].dflt)
    }
    i = i + 1
  }
  st.visiting.remove(irName)
  if not ok {
    st.failed.add(irName, true)
    return false
  }
  st.results.add(
    irName,
    NRecInfo(irName = irName, fieldNames = names, fieldTys = tys, fieldDefaults = dflts, byValue = true)
  )
  st.typeDefs.add(NTypeDefn(name = irName, fields = layoutFieldTys(tys)))
  true
}

/// A generic application written as a field type: resolved like
/// `typeToNEnvOpt` (generic unions, then generic records, by the written name
/// then the bare one) and, when every argument is by-value, instantiated and
/// classified by the per-instantiation rule, so a record or union holding
/// `Option[Vec3]` or `Option[Int]` embeds it inline.
func classifyGenericApp(
  st: in NByValState,
  pkg: in String,
  head: in ModulePath,
  args: in List[TypeArg],
  envNames: in List[String],
  envTys: in List[NType],
): List[NType] {
  val res: List[NType] = newList()
  val joined = modulePathJoin(head.segments)
  val bare = lastSeg(head)
  if bare == "NativePtr" or bare == "NativeWeak" {
    return res
  }
  val argTys: List[NType] = newList()
  for a in args {
    match a {
      case TAType(inner) -> {
        val ft = classifyByValueFieldEnv(st, pkg, inner, envNames, envTys)
        if ft.count == 0 {
          return res
        }
        argTys.add(ft[0])
      }
      case TAValue(_) -> return res
    }
  }
  var uKey = ""
  if st.genUnionDecls.containsKey(joined) {
    uKey = joined
  } else if st.genUnionDecls.containsKey(bare) {
    uKey = bare
  }
  if uKey.length > 0 {
    val ud = st.genUnionDecls[uKey]
    val upkg = st.genUnionPkgs[uKey]
    val gkey = upkg + "." + ud.name
    val instName = instIrName(gkey, argTys)
    if classifyGenericUnionInst(st, upkg, gkey, ud, instName, argTys) {
      val ui = st.uresults[instName]
      res.add(NStruct(name = instName, fields = unionInlineFields(ui.payloadWords)))
    }
    return res
  }
  var rKey = ""
  if st.genRecDecls.containsKey(joined) {
    rKey = joined
  } else if st.genRecDecls.containsKey(bare) {
    rKey = bare
  }
  if rKey.length > 0 {
    val rd = st.genRecDecls[rKey]
    val rpkg = st.genRecPkgs[rKey]
    val gkey = rpkg + "." + rd.name
    val instName = instIrName(gkey, argTys)
    if classifyGenericRecordInst(st, rpkg, gkey, rd, instName, argTys) {
      val ri = st.results[instName]
      res.add(NStruct(name = instName, fields = layoutFieldTys(ri.fieldTys)))
    }
  }
  res
}

func recordInstMeta(st: in NByValState, instName: in String, gkey: in String, argTys: in List[NType]): Unit {
  st.instMetaNames.add(instName)
  st.instMetaInfos.add(NInstInfo(gkey = gkey, argTys = argTys))
}

/// One instantiation of a generic union: inline when it is not an `impl`
/// target and every case field, with the arguments substituted, is by-value.
func classifyGenericUnionInst(
  st: in NByValState,
  pkg: in String,
  gkey: in String,
  ud: in UnionDecl,
  instName: in String,
  argTys: in List[NType],
): Bool {
  if st.uresults.containsKey(instName) {
    return true
  }
  if st.failed.containsKey(instName) or st.visiting.containsKey(instName) {
    return false
  }
  val envNames = genericParamNamesOf(ud.generics)
  if envNames.count != argTys.count or st.heapOnly.containsKey(pkg + "." + ud.name) {
    st.failed.add(instName, true)
    return false
  }
  st.visiting.add(instName, true)
  val cases: List[NUnionCaseInfo] = newList()
  var maxBytes = 0
  var ok = true
  var ci = 0
  while ci < ud.cases.count and ok {
    val cd = ud.cases[ci]
    val names: List[String] = newList()
    val tys: List[NType] = newList()
    var fi = 0
    while fi < cd.fields.count and ok {
      val ft = classifyByValueFieldEnv(st, pkg, unionFieldTy(cd.fields[fi]), envNames, argTys)
      if ft.count == 0 {
        ok = false
      } else {
        names.add(unionFieldName(cd.fields[fi], fi))
        tys.add(ft[0])
      }
      fi = fi + 1
    }
    if ok {
      val sz = stStructSize(st, layoutFieldTys(tys))
      if sz > maxBytes {
        maxBytes = sz
      }
      cases.add(NUnionCaseInfo(name = cd.name, fieldNames = names, fieldTys = tys))
    }
    ci = ci + 1
  }
  st.visiting.remove(instName)
  if not ok {
    st.failed.add(instName, true)
    return false
  }
  val words = (maxBytes + 7) / 8
  val ui = NUnionInfo(irName = instName, cases = cases, payloadWords = words, inline = true)
  st.uresults.add(instName, ui)
  st.instUnions.add(ui)
  recordInstMeta(st, instName, gkey, argTys)
  st.typeDefs.add(NTypeDefn(name = instName, fields = unionInlineFields(words)))
  for c in cases {
    if c.fieldTys.count > 0 {
      st.typeDefs.add(NTypeDefn(name = casePayloadStructName(ui, c.name), fields = layoutFieldTys(c.fieldTys)))
    }
  }
  true
}

/// One instantiation of a generic record: by-value when it has no `var` field,
/// at least one field, is not an `impl` target, and every field is by-value.
func classifyGenericRecordInst(
  st: in NByValState,
  pkg: in String,
  gkey: in String,
  rd: in RecordDecl,
  instName: in String,
  argTys: in List[NType],
): Bool {
  if st.results.containsKey(instName) {
    return true
  }
  if st.failed.containsKey(instName) or st.visiting.containsKey(instName) {
    return false
  }
  val envNames = genericParamNamesOf(rd.generics)
  val fields = recFieldsOf(rd)
  if envNames.count != argTys.count or fields.count == 0 or recordHasVarField(rd) or st.heapOnly.containsKey(pkg + "." + rd.name) {
    st.failed.add(instName, true)
    return false
  }
  st.visiting.add(instName, true)
  val names: List[String] = newList()
  val tys: List[NType] = newList()
  val dflts: List[Option[Expr]] = newList()
  var ok = true
  var i = 0
  while i < fields.count and ok {
    val ft = classifyByValueFieldEnv(st, pkg, fields[i].ty, envNames, argTys)
    if ft.count == 0 {
      ok = false
    } else {
      names.add(fields[i].name)
      tys.add(ft[0])
      dflts.add(fields[i].dflt)
    }
    i = i + 1
  }
  st.visiting.remove(instName)
  if not ok {
    st.failed.add(instName, true)
    return false
  }
  val ri = NRecInfo(irName = instName, fieldNames = names, fieldTys = tys, fieldDefaults = dflts, byValue = true)
  st.results.add(instName, ri)
  st.instRecs.add(ri)
  recordInstMeta(st, instName, gkey, argTys)
  st.typeDefs.add(NTypeDefn(name = instName, fields = layoutFieldTys(tys)))
  true
}

/// Size and alignment of a by-value field type during classification, before
/// the registries exist (the same C rules as `sizeOfN`/`alignOfN`).
func stSizeOf(st: in NByValState, t: in NType): Int {
  match t {
    case NI1 -> 1
    case NI8 -> 1
    case NI32 -> 4
    case NI64 -> 8
    case NDouble -> 8
    case NFloat -> 4
    case NVoid -> 1
    case NArray(elem, size) -> stSizeOf(st, elem) * size
    case NStruct(name, _) -> {
      if st.uresults.containsKey(name) {
        return 8 + 8 * st.uresults[name].payloadWords
      }
      stStructSize(st, layoutFieldTys(st.results[name].fieldTys))
    }
    case _ -> panic("Lyric.LlvmCodegen: internal — unsizable by-value field type")
  }
}

func stAlignOf(st: in NByValState, t: in NType): Int {
  match t {
    case NArray(elem, _) -> stAlignOf(st, elem)
    case NStruct(name, _) -> {
      if st.uresults.containsKey(name) {
        return 8
      }
      val fields = layoutFieldTys(st.results[name].fieldTys)
      var maxA = 1
      for f in fields {
        val a = stAlignOf(st, f)
        if a > maxA {
          maxA = a
        }
      }
      maxA
    }
    case _ -> stSizeOf(st, t)
  }
}

func stStructSize(st: in NByValState, fields: in List[NType]): Int {
  var off = 0
  var maxA = 1
  for f in fields {
    val a = stAlignOf(st, f)
    if a > maxA {
      maxA = a
    }
    off = roundUpTo(off, a)
    off = off + stSizeOf(st, f)
  }
  roundUpTo(off, maxA)
}

/// Classify one non-generic union declaration: inline when no `impl` targets
/// it and every case payload field is by-value (scalars, enums, distinct
/// types, by-value records, other inline unions).  A union that holds itself,
/// directly or through another union, is a cycle and stays heap.  The full
/// `NUnionInfo` lands in `st.uresults` and its struct definitions in
/// `st.typeDefs`, inner types first.
func classifyInlineUnion(st: in NByValState, pkg: in String, ud: in UnionDecl): Bool {
  val irName = pkg + "." + ud.name
  if st.uresults.containsKey(irName) {
    return true
  }
  if st.failed.containsKey(irName) or st.visiting.containsKey(irName) {
    return false
  }
  match ud.generics {
    case Some(_) -> return false
    case None -> {
    }
  }
  if st.heapOnly.containsKey(irName) {
    st.failed.add(irName, true)
    return false
  }
  st.visiting.add(irName, true)
  val cases: List[NUnionCaseInfo] = newList()
  var maxBytes = 0
  var ok = true
  var ci = 0
  while ci < ud.cases.count and ok {
    val cd = ud.cases[ci]
    val names: List[String] = newList()
    val tys: List[NType] = newList()
    var fi = 0
    while fi < cd.fields.count and ok {
      val ft = classifyByValueField(st, pkg, unionFieldTy(cd.fields[fi]))
      if ft.count == 0 {
        ok = false
      } else {
        names.add(unionFieldName(cd.fields[fi], fi))
        tys.add(ft[0])
      }
      fi = fi + 1
    }
    if ok {
      val sz = stStructSize(st, layoutFieldTys(tys))
      if sz > maxBytes {
        maxBytes = sz
      }
      cases.add(NUnionCaseInfo(name = cd.name, fieldNames = names, fieldTys = tys))
    }
    ci = ci + 1
  }
  st.visiting.remove(irName)
  if not ok {
    st.failed.add(irName, true)
    return false
  }
  val words = (maxBytes + 7) / 8
  val ui = NUnionInfo(irName = irName, cases = cases, payloadWords = words, inline = true)
  st.uresults.add(irName, ui)
  st.typeDefs.add(NTypeDefn(name = irName, fields = unionInlineFields(words)))
  for c in cases {
    if c.fieldTys.count > 0 {
      st.typeDefs.add(NTypeDefn(name = casePayloadStructName(ui, c.name), fields = layoutFieldTys(c.fieldTys)))
    }
  }
  true
}

/// Classify every non-generic record of the bundle; the by-value records'
/// `NRecInfo`s land in the result's `results` (by IR name) and their struct
/// definitions are appended to `typeDefs`.
func putOnce(m: in Map[String, Bool], key: in String): Unit {
  if not m.containsKey(key) {
    m.add(key, true)
  }
}

func classifyByValueRecords(
  heapOnly: in Map[String, Bool], units: in List[CodegenUnit], typeDefs: in List[NTypeDefn]
): NByValState {
  val st = NByValState(
    decls = newMap(),
    declPkgs = newMap(),
    distincts = newMap(),
    distinctPkgs = newMap(),
    enums = newMap(),
    heapNames = newMap(),
    heapOnly = heapOnly,
    results = newMap(),
    failed = newMap(),
    visiting = newMap(),
    typeDefs = typeDefs,
    unionDecls = newMap(),
    unionPkgs = newMap(),
    uresults = newMap(),
    genUnionDecls = newMap(),
    genUnionPkgs = newMap(),
    genRecDecls = newMap(),
    genRecPkgs = newMap(),
    instRecs = newList(),
    instUnions = newList(),
    instMetaNames = newList(),
    instMetaInfos = newList()
  )
  for u in units {
    for rd in u.records {
      match rd.generics {
        case Some(_) -> {
          // Resolved through the generic registry, never `recordDefs`.
          continue
        }
        case None -> {
        }
      }
      if not st.decls.containsKey(u.pkgName + "." + rd.name) {
        st.decls.add(u.pkgName + "." + rd.name, rd)
        st.declPkgs.add(u.pkgName + "." + rd.name, u.pkgName)
      }
      if not st.decls.containsKey(rd.name) {
        st.decls.add(rd.name, rd)
        st.declPkgs.add(rd.name, u.pkgName)
      }
    }
    for dd in u.distincts {
      if not st.distincts.containsKey(u.pkgName + "." + dd.name) {
        st.distincts.add(u.pkgName + "." + dd.name, dd)
        st.distinctPkgs.add(u.pkgName + "." + dd.name, u.pkgName)
      }
      if not st.distincts.containsKey(dd.name) {
        st.distincts.add(dd.name, dd)
        st.distinctPkgs.add(dd.name, u.pkgName)
      }
    }
    for gd in u.records {
      match gd.generics {
        case Some(_) -> {
          if not st.genRecDecls.containsKey(u.pkgName + "." + gd.name) {
            st.genRecDecls.add(u.pkgName + "." + gd.name, gd)
            st.genRecPkgs.add(u.pkgName + "." + gd.name, u.pkgName)
          }
          if not st.genRecDecls.containsKey(gd.name) {
            st.genRecDecls.add(gd.name, gd)
            st.genRecPkgs.add(gd.name, u.pkgName)
          }
        }
        case None -> {
        }
      }
    }
    for gu in u.unions {
      match gu.generics {
        case Some(_) -> {
          if not st.genUnionDecls.containsKey(u.pkgName + "." + gu.name) {
            st.genUnionDecls.add(u.pkgName + "." + gu.name, gu)
            st.genUnionPkgs.add(u.pkgName + "." + gu.name, u.pkgName)
          }
          if not st.genUnionDecls.containsKey(gu.name) {
            st.genUnionDecls.add(gu.name, gu)
            st.genUnionPkgs.add(gu.name, u.pkgName)
          }
        }
        case None -> {
        }
      }
    }
    for ed in u.enums {
      putOnce(st.enums, u.pkgName + "." + ed.name)
      putOnce(st.enums, ed.name)
    }
    for ud in u.unions {
      match ud.generics {
        case Some(_) -> {
        }
        case None -> {
          if not st.unionDecls.containsKey(u.pkgName + "." + ud.name) {
            st.unionDecls.add(u.pkgName + "." + ud.name, ud)
            st.unionPkgs.add(u.pkgName + "." + ud.name, u.pkgName)
          }
          if not st.unionDecls.containsKey(ud.name) {
            st.unionDecls.add(ud.name, ud)
            st.unionPkgs.add(ud.name, u.pkgName)
          }
        }
      }
    }
    for pd in u.protecteds {
      putOnce(st.heapNames, "r:" + u.pkgName + "." + pd.name)
      putOnce(st.heapNames, "r:" + pd.name)
    }
    for idl in u.interfaces {
      putOnce(st.heapNames, "i:" + u.pkgName + "." + idl.name)
      putOnce(st.heapNames, "i:" + idl.name)
    }
  }
  for u in units {
    for rd in u.records {
      val _ = classifyByValueRecord(st, u.pkgName, rd)
    }
    for ud in u.unions {
      val _ = classifyInlineUnion(st, u.pkgName, ud)
    }
  }
  st
}

/// Whether a generic record instantiated at `argTys` is by-value: no `var`
/// field, not opaque / interface-implementing, and every instantiated field a
/// by-value type.
func genericRecordByValue(ctx: in Ctx, gkey: in String, rd: in RecordDecl, tys: in List[NType]): Bool {
  val pkg = match mapGet(ctx.genericDeclPkg, gkey) { case Some(p) -> p; case None -> "" }
  if recordHasVarField(rd) or isHeapOnlyRec(ctx, pkg, rd.name) or tys.count == 0 {
    return false
  }
  for t in tys {
    if not isByValueFieldNType(t) {
      return false
    }
  }
  true
}

// ─────────────────────────────────────────────────────────────────────────────
// `array[N, T]` (D167, docs/67 §4.3).
//
// `Lyric.ContractElaborator.lowerArrays` has already lowered bounds checks (a
// panic before the access), `.length`, `for`, `==` and `.toSlice()`; what is
// left for the backend is the type, the literal, the element read and write, and
// the three intrinsics (`arrayFillIntrinsic`, `arrayCopyIntrinsic`,
// `arrayUncheckedIntrinsic`).
// ─────────────────────────────────────────────────────────────────────────────
/// The integer a (possibly parenthesised, possibly negated) literal expression is.
func literalIntOfExpr(e: in Expr): Option[Int] {
  match e.kind {
    case ELiteral(lit) -> match lit { case LInt(v, _, _) -> Some(value = v.toInt()); case _ -> None }
    case EParen(inner) -> literalIntOfExpr(inner)
    case EPrefix(op, operand) -> match op {
      case PreNeg -> match literalIntOfExpr(operand) {
        case Some(v) -> Some(value = 0 - v)
        case None -> None
      }
      case _ -> None
    }
    case _ -> None
  }
}

/// The compile-time length written in an `array[N, T]` type: an integer
/// literal.  The pipeline rewrites every length it resolved (a constant, an
/// expression that folds) to its literal before a backend runs, so codegen
/// never looks a name up.
func arrayLenOfSize(size: in TypeArg): Option[Int] {
  match size {
    case TAValue(ve) -> literalIntOfExpr(ve)
    case TAType(_) -> None
  }
}

/// `array[N, T]`: the inline LLVM array `[N x T]` when `T` is by-value, so an
/// array of by-value elements is itself by-value (and can sit in a by-value
/// record, with no allocation); otherwise the reference-counted `List`
/// representation, which shares its index, assignment and iteration paths.
func arrayNType(ctx: in Ctx, size: in TypeArg, el: in NType): Option[NType] {
  match arrayLenOfSize(size) {
    case Some(n) -> if isByValueFieldNType(el) and not isVoidNType(el) {
      Some(value = NArray(elem = el, size = n))
    } else {
      Some(value = listNType(ctx, el))
    }
    case None -> None
  }
}

/// An aggregate stored by value that a `List` / `Map` / `Task` slot holds boxed:
/// a by-value record or union's struct, or an inline array.
func isBoxedValueNType(t: in NType): Bool {
  match t {
    case NStruct(_, _) -> true
    case NArray(_, _) -> true
    case _ -> false
  }
}

/// The type of the storage `e` names when it is a place the backend can take
/// the address of: a local, a field of a heap record, or an element of an inline
/// array in one.  `None` for anything else (a call result, a by-value record's
/// field), which is read as a value.
func placeNType(ctx: in Ctx, e: in Expr): Option[NType] {
  match e.kind {
    case EParen(inner) -> placeNType(ctx, inner)
    case ESelf -> mapGet(ctx.varTypes, "self")
    case EPath(p) -> if p.segments.count == 1 and ctx.varSlots.containsKey(p.segments[0]) {
      mapGet(ctx.varTypes, p.segments[0])
    } else {
      None
    }
    case EMember(recv, fieldName) -> match placeOrListElemNType(ctx, recv) {
      case Some(rt) -> match rt {
        case NPtr(_) -> match recInfoOfType(ctx, rt) {
          case Some(ri) -> {
            val idx = recFieldIndex(ri, fieldName)
            if idx >= 0 and not ri.byValue {
              Some(value = ri.fieldTys[idx])
            } else {
              None
            }
          }
          case None -> None
        }
        case _ -> None
      }
      case None -> None
    }
    case EIndex(recv, idxs) -> if idxs.count == 1 {
      match placeNType(ctx, recv) {
        case Some(rt) -> match rt { case NArray(el, _) -> Some(value = el); case _ -> None }
        case None -> None
      }
    } else {
      None
    }
    case _ -> None
  }
}

/// `placeNType`, or, for the element of a heap array (a `List` in a place) that
/// is a reference to a record, that record's type: the record's own field is a
/// place whatever holds the reference (`cs[i].hits[j] = v`).
func placeOrListElemNType(ctx: in Ctx, e: in Expr): Option[NType] {
  match placeNType(ctx, e) {
    case Some(t) -> return Some(value = t)
    case None -> ()
  }
  match e.kind {
    case EParen(inner) -> placeOrListElemNType(ctx, inner)
    case EIndex(recv, idxs) -> if idxs.count == 1 {
      match placeNType(ctx, recv) {
        case Some(rt) -> match rt {
          case NArray(_, _) -> None
          case _ -> match listElemOfType(ctx, rt) {
            case Some(el) -> match el { case NPtr(_) -> Some(value = el); case _ -> None }
            case None -> None
          }
        }
        case None -> None
      }
    } else {
      None
    }
    case _ -> None
  }
}

/// The address of the place `e` (`placeNType` is `Some`): a pointer to its storage.
func placeAddr(ctx: in Ctx, insns: in List[NInsn], e: in Expr): NVal {
  match e.kind {
    case EParen(inner) -> placeAddr(ctx, insns, inner)
    case ESelf -> localAddr(ctx, "self")
    case EPath(p) -> localAddr(ctx, p.segments[0])
    case EMember(recv, fieldName) -> {
      val obj = lowerExpr(ctx, insns, recv)
      val ri = match recInfoOfType(ctx, obj.ty) {
        case Some(r) -> r
        case None -> panic("Lyric.LlvmCodegen: internal — a field place on a value that is not a record")
      }
      val idx = recFieldIndex(ri, fieldName)
      val structTy = match obj.ty {
        case NPtr(pointee) -> pointee
        case _ -> panic("Lyric.LlvmCodegen: internal — a field place on a record value")
      }
      val fieldPtr = freshTmp(ctx)
      val fArgs: List[NArg] = newList()
      fArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
      fArgs.add(NArg(ty = NI32, value = NLitInt(v = (arcHeaderSlots + idx).toLong(), ty = NI32)))
      insns.add(NGEP(dest = fieldPtr, ty = structTy, ptr = obj.value, indices = fArgs))
      NVal(ty = NPtr(pointee = ri.fieldTys[idx]), value = NLocal(name = fieldPtr))
    }
    case EIndex(recv, idxs) -> {
      val base = placeAddr(ctx, insns, recv)
      val arrTy = match base.ty {
        case NPtr(pointee) -> pointee
        case _ -> panic("Lyric.LlvmCodegen: internal — an element place off a non-pointer")
      }
      match arrTy {
        case NArray(el, n) -> {
          val idx = lowerArrayIndexValue(ctx, insns, idxs[0], n, e.span.startPos.line)
          arrayElemPtr(ctx, insns, base, arrTy, el, idx)
        }
        case _ -> panic("Lyric.LlvmCodegen: internal — an element place off a value that is not an array")
      }
    }
    case _ -> panic("Lyric.LlvmCodegen: internal — the address of a value that is not a place")
  }
}

func localAddr(ctx: in Ctx, name: in String): NVal {
  val ty = match mapGet(ctx.varTypes, name) {
    case Some(t) -> t
    case None -> panic("Lyric.LlvmCodegen: no variable '" + name + "'")
  }
  val slot = match mapGet(ctx.varSlots, name) {
    case Some(s) -> s
    case None -> panic("Lyric.LlvmCodegen: no storage slot for '" + name + "'")
  }
  NVal(ty = NPtr(pointee = ty), value = NLocal(name = slot))
}

/// The element pointer `&arr[idx]` of the inline array at `arrAddr`.
func arrayElemPtr(
  ctx: in Ctx,
  insns: in List[NInsn],
  arrAddr: in NVal,
  arrTy: in NType,
  elemTy: in NType,
  idx: in NValue,
): NVal {
  val dest = freshTmp(ctx)
  val gArgs: List[NArg] = newList()
  gArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  gArgs.add(NArg(ty = NI32, value = idx))
  insns.add(NGEP(dest = dest, ty = arrTy, ptr = arrAddr.value, indices = gArgs))
  NVal(ty = NPtr(pointee = elemTy), value = NLocal(name = dest))
}

/// A stack copy of an array value, so an element of an rvalue can be addressed.
func spillArray(ctx: in Ctx, insns: in List[NInsn], v: in NVal): NVal {
  val slot = "arr.addr." + freshTmp(ctx)
  ctx.allocas.add(NAlloca(dest = slot, ty = v.ty))
  insns.add(NStore(ty = v.ty, value = v.value, ptr = NLocal(name = slot)))
  NVal(ty = NPtr(pointee = v.ty), value = NLocal(name = slot))
}

/// The index of an array access with the `__lyric_unchecked` marker removed:
/// the lowering has already checked (or proven) it.
func uncheckedIndexInner(idx: in Expr): Option[Expr] {
  match idx.kind {
    case ECall(fn, args) -> match fn.kind {
      case EPath(p) -> if p.segments.count == 1 and p.segments[0] == arrayUncheckedIntrinsic() and args.count == 1 {
        Some(value = nativeCallArgExpr(args[0]))
      } else {
        None
      }
      case _ -> None
    }
    case EParen(inner) -> uncheckedIndexInner(inner)
    case _ -> None
  }
}

/// `panic("index <i> out of range for array[<n>]")` for the index value `iv`,
/// the message the shared lowering gives a checked access.
func lowerArrayOobPanic(ctx: in Ctx, insns: in List[NInsn], iv: in NValue, n: in Int, sp: in Span): Unit {
  val name = "__lyric_oob_" + freshTmp(ctx)
  // The message's temporaries live only on this path, which never returns:
  // their scope is dropped without a release on the in-range path.
  pushVarScope(ctx)
  pushTempScope(ctx)
  bindLocal(ctx, insns, name, NVal(ty = NI32, value = iv))
  val idxSegs: List[String] = newList()
  idxSegs.add(name)
  val idxRef = mkExpr(EPath(path = ModulePath(segments = idxSegs, span = sp)), sp)
  val toStr = mkExpr(ECall(fn = mkExpr(EMember(receiver = idxRef, memberName = "toString"), sp), args = newList()), sp)
  val head = mkExpr(EBinop(op = BAdd, lhs = mkExpr(ELiteral(lit = LString(text = "index ")), sp), rhs = toStr), sp)
  val msg = mkExpr(
    EBinop(
      op = BAdd,
      lhs = head,
      rhs = mkExpr(ELiteral(lit = LString(text = " out of range for array[" + n.toString() + "]")), sp)
    ),
    sp
  )
  val panicSegs: List[String] = newList()
  panicSegs.add("panic")
  val args: List[CallArg] = newList()
  args.add(CAPositional(expr = msg))
  val call = mkExpr(ECall(fn = mkExpr(EPath(path = ModulePath(segments = panicSegs, span = sp)), sp), args = args), sp)
  val _ = lowerExpr(ctx, insns, call)
  ctx.tempScopes.removeAt(ctx.tempScopes.count - 1)
  popVarScope(ctx, insns)
}

/// The `i32` index of an access to an `array[n, _]`.  An index the lowering has
/// not settled (code a pass synthesised after it) is checked here, with a fixed
/// message; a settled one is not.
func lowerArrayIndexValue(ctx: in Ctx, insns: in List[NInsn], idx: in Expr, n: in Int, line: in Int): NValue {
  match uncheckedIndexInner(idx) {
    case Some(inner) -> lowerExprExpecting(ctx, insns, inner, NI32).value
    case None -> {
      val v = lowerExprExpecting(ctx, insns, idx, NI32)
      val ok = freshTmp(ctx)
      insns.add(NICmp(dest = ok, pred = IUlt, ty = NI32, a = v.value, b = NLitInt(v = n.toLong(), ty = NI32)))
      val okL = freshLabel(ctx, "arr.in")
      val badL = freshLabel(ctx, "arr.oob")
      insns.add(NCondBr(cond = NLocal(name = ok), thenLabel = okL, elseLabel = badL))
      insns.add(NLabel(name = badL))
      lowerArrayOobPanic(ctx, insns, v.value, n, idx.span)
      insns.add(NBr(label = okL))
      insns.add(NLabel(name = okL))
      v.value
    }
  }
}

func readArrayElem(
  ctx: in Ctx,
  insns: in List[NInsn],
  arrAddr: in NVal,
  arrTy: in NType,
  elemTy: in NType,
  n: in Int,
  idxExpr: in Expr,
  line: in Int,
): NVal {
  val idx = lowerArrayIndexValue(ctx, insns, idxExpr, n, line)
  val ptr = arrayElemPtr(ctx, insns, arrAddr, arrTy, elemTy, idx)
  val dest = freshTmp(ctx)
  insns.add(NLoad(dest = dest, ty = elemTy, ptr = ptr.value))
  NVal(ty = elemTy, value = NLocal(name = dest))
}

/// `a[i]` where `a` is a place holding an inline array: the element is read
/// through its address, never by loading the whole array.
func lowerArrayIndexRead(
  ctx: in Ctx, insns: in List[NInsn], receiver: in Expr, idxExpr: in Expr, line: in Int
): Option[NVal] {
  match placeNType(ctx, receiver) {
    case Some(t) -> match t {
      case NArray(el, n) -> {
        val addr = placeAddr(ctx, insns, receiver)
        Some(value = readArrayElem(ctx, insns, addr, t, el, n, idxExpr, line))
      }
      case _ -> None
    }
    case None -> None
  }
}

/// `a[i] = v` / `a[i] op= v` where `a` is a place holding an inline array;
/// false when the receiver is not one.
func lowerArrayElemAssign(
  ctx: in Ctx,
  insns: in List[NInsn],
  receiver: in Expr,
  idxExpr: in Expr,
  op: in AssignOp,
  value: in Expr,
  line: in Int,
): Bool {
  val arrTy = match placeNType(ctx, receiver) { case Some(t) -> t; case None -> return false }
  match arrTy {
    case NArray(el, n) -> {
      val addr = placeAddr(ctx, insns, receiver)
      val idx = lowerArrayIndexValue(ctx, insns, idxExpr, n, line)
      val ptr = arrayElemPtr(ctx, insns, addr, arrTy, el, idx)
      val newVal = match op {
        case AssEq -> lowerExprExpecting(ctx, insns, value, el)
        case _ -> {
          // The right-hand side is evaluated before the element is read, as
          // for a list element (`combineIndexedAssignValue`).
          val rhs = lowerExpr(ctx, insns, value)
          val curDest = freshTmp(ctx)
          insns.add(NLoad(dest = curDest, ty = el, ptr = ptr.value))
          val cur = NVal(ty = el, value = NLocal(name = curDest))
          combineIndexedAssignValue(ctx, insns, op, el, cur, rhs, line)
        }
      }
      insns.add(NStore(ty = el, value = newVal.value, ptr = ptr.value))
      true
    }
    case _ -> false
  }
}

/// `[a, b, c]` against an inline array type: an `insertvalue` chain.
func lowerArrayLiteral(
  ctx: in Ctx,
  insns: in List[NInsn],
  elems: in List[Expr],
  arrTy: in NType,
  elemTy: in NType,
  n: in Int,
): NVal {
  if elems.count != n {
    panic(
      "Lyric.LlvmCodegen: an array literal of " + elems.count.toString() + " element(s) for " + nTypeToIrString(arrTy)
    )
  }
  var cur: NValue = NUndef(ty = arrTy)
  var i = 0
  while i < elems.count {
    val v = lowerExprExpecting(ctx, insns, elems[i], elemTy)
    val dest = freshTmp(ctx)
    insns.add(NInsertValue(dest = dest, aggTy = arrTy, agg = cur, elemTy = elemTy, elem = v.value, index = i))
    cur = NLocal(name = dest)
    i = i + 1
  }
  NVal(ty = arrTy, value = cur)
}

func arrayTypeExprOfArgs(targs: in List[TypeArg]): Option[TypeExpr] {
  if targs.count != 1 {
    return None
  }
  match targs[0] {
    case TAType(te) -> Some(value = te)
    case TAValue(_) -> None
  }
}

func arrayElemTypeExpr(te: in TypeExpr): Option[TypeExpr] {
  match te.kind {
    case TArray(_, el) -> Some(value = el)
    case TParen(inner) -> arrayElemTypeExpr(inner)
    case _ -> None
  }
}

/// `__lyric_array_copy[array[N, T]](a)`: an inline array is already a value, so
/// its copy is itself; the `List` representation is copied element by element,
/// an element that is an array copied in turn.
func lowerArrayCopyCall(ctx: in Ctx, insns: in List[NInsn], targs: in List[TypeArg], args: in List[CallArg]): NVal {
  val v = match arrayTypeExprOfArgs(targs) {
    case Some(te) -> lowerExprExpecting(ctx, insns, nativeCallArgExpr(args[0]), typeToN(ctx, te))
    case None -> lowerPositionalArg(ctx, insns, args, 0)
  }
  copyArrayValue(ctx, insns, v, arrayTypeExprOfArgs(targs))
}

func copyArrayValue(ctx: in Ctx, insns: in List[NInsn], v: in NVal, arrTe: in Option[TypeExpr]): NVal {
  match v.ty {
    case NArray(_, _) -> return v
    case _ -> ()
  }
  val elemTy = match listElemOfType(ctx, v.ty) { case Some(t) -> t; case None -> return v }
  val elemTe: Option[TypeExpr] = match arrTe { case Some(te) -> arrayElemTypeExpr(te); case None -> None }
  val nested = match elemTe {
    case Some(et) -> match et.kind { case TArray(_, _) -> true; case _ -> false }
    case None -> false
  }
  val dst = constructList(ctx, insns, elemTy)
  val srcP = collectionAsI8(ctx, insns, v)
  val dstP = collectionAsI8(ctx, insns, dst)
  val lenV = callRuntime(ctx, insns, "lyric_list_len", NI64, arg1(NPtr(pointee = NI8), srcP))
  val idxSlot = "acopy.idx." + freshTmp(ctx)
  ctx.allocas.add(NAlloca(dest = idxSlot, ty = NI64))
  insns.add(NStore(ty = NI64, value = NLitInt(v = 0i64, ty = NI64), ptr = NLocal(name = idxSlot)))
  val condL = freshLabel(ctx, "acopy.cond")
  val bodyL = freshLabel(ctx, "acopy.body")
  val exitL = freshLabel(ctx, "acopy.exit")
  insns.add(NBr(label = condL))
  insns.add(NLabel(name = condL))
  val cur = freshTmp(ctx)
  insns.add(NLoad(dest = cur, ty = NI64, ptr = NLocal(name = idxSlot)))
  val cmp = freshTmp(ctx)
  insns.add(NICmp(dest = cmp, pred = ISlt, ty = NI64, a = NLocal(name = cur), b = lenV.value))
  insns.add(NCondBr(cond = NLocal(name = cmp), thenLabel = bodyL, elseLabel = exitL))
  insns.add(NLabel(name = bodyL))
  pushTempScope(ctx)
  val gArgs: List[NArg] = newList()
  gArgs.add(NArg(ty = NPtr(pointee = NI8), value = srcP))
  gArgs.add(NArg(ty = NI64, value = NLocal(name = cur)))
  val slot = callRuntime(ctx, insns, "lyric_list_get", NI64, gArgs)
  val elemV = valOfSlot(ctx, insns, slot.value, elemTy)
  val copied = if nested { copyArrayValue(ctx, insns, elemV, elemTe) } else { elemV }
  pushToList(ctx, insns, dstP, copied)
  popTempScope(ctx, insns)
  val next = freshTmp(ctx)
  insns.add(NAdd(dest = next, ty = NI64, a = NLocal(name = cur), b = NLitInt(v = 1i64, ty = NI64)))
  insns.add(NStore(ty = NI64, value = NLocal(name = next), ptr = NLocal(name = idxSlot)))
  insns.add(NBr(label = condL))
  insns.add(NLabel(name = exitL))
  dst
}

/// `__lyric_array_fill[array[N, T]](z)`: an array of `N` elements, each a
/// fresh evaluation of `z`.  An inline array's elements are values, so `z` is
/// evaluated once and stored `N` times; the `List` representation evaluates it
/// once per element (a mutable record must not be shared).
func lowerArrayFillCall(ctx: in Ctx, insns: in List[NInsn], targs: in List[TypeArg], args: in List[CallArg]): NVal {
  val arrTe = match arrayTypeExprOfArgs(targs) {
    case Some(te) -> te
    case None -> panic("Lyric.LlvmCodegen: internal — an array fill without its array type")
  }
  val arrTy = typeToN(ctx, arrTe)
  val zExpr = nativeCallArgExpr(args[0])
  match arrTy {
    case NArray(el, n) -> {
      val z = lowerExprExpecting(ctx, insns, zExpr, el)
      val slot = "afill.addr." + freshTmp(ctx)
      ctx.allocas.add(NAlloca(dest = slot, ty = arrTy))
      insns.add(NStore(ty = arrTy, value = NZeroInit(ty = arrTy), ptr = NLocal(name = slot)))
      val addr = NVal(ty = NPtr(pointee = arrTy), value = NLocal(name = slot))
      val idxSlot = "afill.idx." + freshTmp(ctx)
      ctx.allocas.add(NAlloca(dest = idxSlot, ty = NI32))
      insns.add(NStore(ty = NI32, value = NLitInt(v = 0i64, ty = NI32), ptr = NLocal(name = idxSlot)))
      val condL = freshLabel(ctx, "afill.cond")
      val bodyL = freshLabel(ctx, "afill.body")
      val exitL = freshLabel(ctx, "afill.exit")
      insns.add(NBr(label = condL))
      insns.add(NLabel(name = condL))
      val cur = freshTmp(ctx)
      insns.add(NLoad(dest = cur, ty = NI32, ptr = NLocal(name = idxSlot)))
      val cmp = freshTmp(ctx)
      insns.add(NICmp(dest = cmp, pred = ISlt, ty = NI32, a = NLocal(name = cur), b = NLitInt(v = n.toLong(), ty = NI32)))
      insns.add(NCondBr(cond = NLocal(name = cmp), thenLabel = bodyL, elseLabel = exitL))
      insns.add(NLabel(name = bodyL))
      val ptr = arrayElemPtr(ctx, insns, addr, arrTy, el, NLocal(name = cur))
      insns.add(NStore(ty = el, value = z.value, ptr = ptr.value))
      val next = freshTmp(ctx)
      insns.add(NAdd(dest = next, ty = NI32, a = NLocal(name = cur), b = NLitInt(v = 1i64, ty = NI32)))
      insns.add(NStore(ty = NI32, value = NLocal(name = next), ptr = NLocal(name = idxSlot)))
      insns.add(NBr(label = condL))
      insns.add(NLabel(name = exitL))
      val dest = freshTmp(ctx)
      insns.add(NLoad(dest = dest, ty = arrTy, ptr = NLocal(name = slot)))
      NVal(ty = arrTy, value = NLocal(name = dest))
    }
    case _ -> {
      val elemTy = match listElemOfType(ctx, arrTy) {
        case Some(t) -> t
        case None -> panic("Lyric.LlvmCodegen: internal — an array fill of " + nTypeToIrString(arrTy))
      }
      val n = match arrTe.kind {
        case TArray(size, _) -> match arrayLenOfSize(size) {
          case Some(k) -> k
          case None -> panic(
            "error[N0020] " + arrTe.span.startPos.line.toString() + ":" +
              arrTe.span.startPos.column.toString() +
              ": this `array[N, T]` has no native layout: its length must be a compile-time constant (a value-generic length is not supported)"
          )
        }
        case _ -> 0
      }
      val dst = constructList(ctx, insns, elemTy)
      val dstP = collectionAsI8(ctx, insns, dst)
      val idxSlot = "afill.idx." + freshTmp(ctx)
      ctx.allocas.add(NAlloca(dest = idxSlot, ty = NI32))
      insns.add(NStore(ty = NI32, value = NLitInt(v = 0i64, ty = NI32), ptr = NLocal(name = idxSlot)))
      val condL = freshLabel(ctx, "afill.cond")
      val bodyL = freshLabel(ctx, "afill.body")
      val exitL = freshLabel(ctx, "afill.exit")
      insns.add(NBr(label = condL))
      insns.add(NLabel(name = condL))
      val cur = freshTmp(ctx)
      insns.add(NLoad(dest = cur, ty = NI32, ptr = NLocal(name = idxSlot)))
      val cmp = freshTmp(ctx)
      insns.add(NICmp(dest = cmp, pred = ISlt, ty = NI32, a = NLocal(name = cur), b = NLitInt(v = n.toLong(), ty = NI32)))
      insns.add(NCondBr(cond = NLocal(name = cmp), thenLabel = bodyL, elseLabel = exitL))
      insns.add(NLabel(name = bodyL))
      pushTempScope(ctx)
      val z = lowerExprExpecting(ctx, insns, zExpr, elemTy)
      pushToList(ctx, insns, dstP, z)
      popTempScope(ctx, insns)
      val next = freshTmp(ctx)
      insns.add(NAdd(dest = next, ty = NI32, a = NLocal(name = cur), b = NLitInt(v = 1i64, ty = NI32)))
      insns.add(NStore(ty = NI32, value = NLocal(name = next), ptr = NLocal(name = idxSlot)))
      insns.add(NBr(label = condL))
      insns.add(NLabel(name = exitL))
      dst
    }
  }
}

/// True when `t` is a by-value record's struct value (never a pointer): a bare
/// named struct appears as a value type for by-value records only.
func isByValueStructNType(t: in NType): Bool {
  match t {
    case NStruct(_, _) -> true
    case _ -> false
  }
}

func byValueRecName(t: in NType): String {
  match t {
    case NStruct(name, _) -> name
    case _ -> ""
  }
}

/// Register every non-generic record/union/enum/distinct declaration in
/// the bundle.  Two phases: names first (so pointer-typed fields can
/// reference any registered type, including cyclically), then field
/// layouts, IR type definitions, and synthesised destructors.
func registerHeapTypes(
  ctx: in Ctx, units: in List[CodegenUnit], typeDefs: in List[NTypeDefn], fns: in List[NFunc]
): Unit {
  fillHeapOnlyRecs(ctx.heapOnlyRecs, units)
  val byValState = classifyByValueRecords(ctx.heapOnlyRecs, units, typeDefs)
  val byVal = byValState.results
  val byValU = byValState.uresults
  // Generic instantiations classified by-value are registered up front, like
  // the non-generic ones, so a later lazy instantiation finds them.
  for ri in byValState.instRecs {
    ctx.recordDefs.add(ri.irName, ri)
  }
  for ui in byValState.instUnions {
    ctx.unionDefs.add(ui.irName, ui)
  }
  var mi = 0
  while mi < byValState.instMetaNames.count {
    ctx.instMeta.add(byValState.instMetaNames[mi], byValState.instMetaInfos[mi])
    mi = mi + 1
  }
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
          // A by-value record is registered with its full layout up front, so
          // other layouts (union payload sizes, other records' fields) can
          // size and name it before Phase B reaches its declaration.
          val stub = match mapGet(byVal, u.pkgName + "." + rd.name) {
            case Some(full) -> full
            case None -> NRecInfo(
              irName = u.pkgName + "." + rd.name,
              fieldNames = emptyNames,
              fieldTys = emptyTys,
              fieldDefaults = emptyDflts,
              byValue = false
            )
          }
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
          // An inline union is registered with its full layout up front, like a
          // by-value record.
          val stub = match mapGet(byValU, u.pkgName + "." + ud.name) {
            case Some(full) -> full
            case None -> NUnionInfo(
              irName = u.pkgName + "." + ud.name,
              cases = emptyCases,
              payloadWords = 0,
              inline = false
            )
          }
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
          // Generic protected types (#7830) lower on MSIL/JVM only;
          // per-instantiation native layouts are #7864 (D-N-017).
          // `nativeGenericProtectedDiagnostics` reports this as N0008
          // before codegen; this is the fallback for a direct caller.
          panic(
            "Lyric.LlvmCodegen: [N0008] " + genericProtectedMessage(pd.name) + " (at " + pd.span.startPos.line.toString() + ":" +
              pd.span.startPos.column.toString() +
              ")"
          )
        }
        case None -> {
          val emptyNames: List[String] = newList()
          val emptyTys: List[NType] = newList()
          val emptyDflts: List[Option[Expr]] = newList()
          val stub = NRecInfo(
            irName = u.pkgName + "." + pd.name,
            fieldNames = emptyNames,
            fieldTys = emptyTys,
            fieldDefaults = emptyDflts,
            byValue = false
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
        // Bare case name (#6589): a reference with no qualifying prefix
        // at all (`Http1_1` rather than `HttpVersion.Http1_1`), whether
        // in the same file or a different package — the common idiom
        // for a value assigned against an explicit type annotation
        // (`var v: HttpVersion = Http1_1`) or returned as a function's
        // trailing block value. Mirrors `Msil.Codegen.registerEnumDeclMsil`'s
        // `cn` key exactly, including its first-wins collision policy
        // across the whole bundle: whichever enum is scanned first claims
        // a case name two different enums both use, so an ambiguous bare
        // name must still be qualified at the use site. This lets the
        // existing bare-`EPath` lookup in `lowerExpr` (previously only
        // ever hit by an already-qualified multi-segment path) resolve a
        // truly bare case reference too.
        val bareKey = ed.cases[eci].name
        if not ctx.enumDefs.containsKey(bareKey) {
          ctx.enumDefs.add(bareKey, eci)
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
  var boundsText = ""
  var isFloatRange = false
  var loF = 0.0
  var hiF = 0.0
  var hiExclusive = false
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
        case RBHalfOpen(l, h, _) -> {
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
      var boundsOk = false
      if isFloatingNType(under) {
        // A floating-point range: ordered compares against the bounds (a NaN
        // is in no range), rounded to binary32 for a `Float` range (D155).
        // var-mutation shape (#4631).
        match loExprOpt {
          case Some(le) -> {
            match hiExprOpt {
              case Some(he) -> {
                val lb = foldLiteralBound(le)
                val hb = foldLiteralBound(he)
                if lb.ok and hb.ok {
                  val single = match under { case NFloat -> true; case _ -> false }
                  hasRange = true
                  boundsOk = true
                  isFloatRange = true
                  loF = if single { lb.f32 } else { lb.d }
                  hiF = if single { hb.f32 } else { hb.d }
                  hiExclusive = not hiInclusive
                  boundsText = "[" + floatBoundText(lb) + ", " + floatBoundText(hb) + (if hiInclusive { "]" } else { ")" })
                }
              }
              case None -> {
              }
            }
          }
          case None -> {
          }
        }
      } else {
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
        match loOpt {
          case Some(l) -> {
            match hiOpt {
              case Some(h) -> {
                hasRange = true
                boundsOk = true
                lo = l
                hi = if hiInclusive { h } else { h - 1i64 }
                boundsText = "[" + toString(l) + ", " + toString(h) + (if hiInclusive { "]" } else { ")" })
              }
              case None -> {
              }
            }
          }
          case None -> {
          }
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
  val underName = match dd.underlying.kind {
    case TRef(path) -> if path.segments.count > 0 { path.segments[path.segments.count - 1] } else { "" }
    case _ -> ""
  }
  val isUnsigned = underName == "Byte" or underName == "UInt" or underName == "ULong"
  val info = NDistinctInfo(
    underlying = under,
    hasRange = hasRange,
    lo = lo,
    hi = hi,
    boundsText = boundsText,
    isUnsigned = isUnsigned,
    isFloat = isFloatRange,
    loF = loF,
    hiF = hiF,
    hiExclusive = hiExclusive
  )
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
  val irName = pkg + "." + rd.name
  // A by-value record was fully registered (layout and struct definition)
  // before Phase A; there is no header, destructor, or heap layout to add.
  match mapGet(ctx.recordDefs, irName) {
    case Some(pre) -> {
      if pre.byValue and pre.irName == irName {
        return
      }
    }
    case None -> {
    }
  }
  val fields = recFieldsOf(rd)
  val names: List[String] = newList()
  val tys: List[NType] = newList()
  val dflts: List[Option[Expr]] = newList()
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
  val ri = NRecInfo(irName = irName, fieldNames = names, fieldTys = tys, fieldDefaults = dflts, byValue = false)
  replaceRecKey(ctx, pkg + "." + rd.name, ri)
  replaceRecKey(ctx, rd.name, ri)
  val defnFields: List[NType] = newList()
  addArcHeader(defnFields)
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
  // An inline union was fully registered (layout and struct definitions)
  // before Phase A; only its case names remain to register.
  match mapGet(ctx.unionDefs, irName) {
    case Some(pre) -> {
      if pre.inline and pre.irName == irName {
        registerUnionCaseRefs(ctx, pkg, ud.name, pre)
        return
      }
    }
    case None -> {
    }
  }
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
    val sz = structSize(ctx, tys)
    if sz > maxBytes {
      maxBytes = sz
    }
    cases.add(NUnionCaseInfo(name = cd.name, fieldNames = names, fieldTys = tys))
    ci = ci + 1
  }
  val words = (maxBytes + 7) / 8
  val ui = NUnionInfo(irName = irName, cases = cases, payloadWords = words, inline = false)
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
    ci2 = ci2 + 1
  }
  registerUnionCaseRefs(ctx, pkg, ud.name, ui)
  if unionHasRefFields(ui) {
    fns.add(synthUnionDtor(ctx, ui))
  }
}

/// Case-name entries resolve constructor calls and patterns.  The
/// unqualified name mirrors source scoping (first-wins).
func registerUnionCaseRefs(ctx: in Ctx, pkg: in String, unionName: in String, ui: in NUnionInfo): Unit {
  var ci2 = 0
  while ci2 < ui.cases.count {
    val cref = NCaseRef(unionKey = ui.irName, caseIdx = ci2)
    val bare = ui.cases[ci2].name
    if not ctx.caseRefs.containsKey(bare) {
      ctx.caseRefs.add(bare, cref)
    }
    if not ctx.caseRefs.containsKey(unionName + "." + bare) {
      ctx.caseRefs.add(unionName + "." + bare, cref)
    }
    if not ctx.caseRefs.containsKey(pkg + "." + unionName + "." + bare) {
      ctx.caseRefs.add(pkg + "." + unionName + "." + bare, cref)
    }
    // A case qualified by its package alone (`Tcp.TlsTrustInsecure` under
    // `import Std.TcpHost as Tcp`, which the alias rewrite makes
    // `Std.TcpHost.TlsTrustInsecure`), as the type checker resolves it.
    if not ctx.caseRefs.containsKey(pkg + "." + bare) {
      ctx.caseRefs.add(pkg + "." + bare, cref)
    }
    ci2 = ci2 + 1
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
  registerGenericRecordMethods(ctx, pkg, rd)
}

// A generic record's methods are generic functions over the record's type
// parameters (and their own), named `<Record>.<method>` with the receiver
// `self: <Record>[T, ...]`, and instantiated per call like any generic
// function.  A member call on an instance finds them through the instance's
// generic key (`lowerMethodCallOnInstance`).
func registerGenericRecordMethods(ctx: in Ctx, pkg: in String, rd: in RecordDecl): Unit {
  val recParams = match rd.generics { case Some(gp) -> gp.params; case None -> return }
  val selfArgs: List[TypeArg] = newList()
  for gp in recParams {
    match gp {
      case GPType(n, sp) -> {
        val segs: List[String] = newList()
        segs.add(n)
        selfArgs.add(TAType(ty = TypeExpr(kind = TRef(path = ModulePath(segments = segs, span = sp)), span = sp)))
      }
      // A value generic parameter cannot be a native type argument here.
      case GPValue(_, _, _) -> return
    }
  }
  for m in rd.members {
    match m {
      case RMFunc(fn) -> {
        val allParams: List[GenericParam] = newList()
        for gp in recParams {
          allParams.add(gp)
        }
        match fn.generics {
          case Some(fg) -> {
            for gp in fg.params {
              allParams.add(gp)
            }
          }
          case None -> ()
        }
        val headSegs: List[String] = newList()
        headSegs.add(rd.name)
        val selfTe = TypeExpr(
          kind = TGenericApp(head = ModulePath(segments = headSegs, span = fn.span), args = selfArgs),
          span = fn.span
        )
        val params: List[Param] = newList()
        for p in fn.params {
          params.add(p.copy(ty = substSelfWith(p.ty, selfTe)))
        }
        val ret = match fn.ret { case Some(r) -> Some(value = substSelfWith(r, selfTe)); case None -> None }
        val gspan = match rd.generics { case Some(gp) -> gp.span; case None -> fn.span }
        val gfn = fn.copy(
          name = rd.name + "." + fn.name,
          generics = Some(value = GenericParams(params = allParams, span = gspan, legacyPrefixForm = false)),
          params = params,
          ret = ret
        )
        val akey = "." + fn.name + "/" + params.count.toString()
        for k in [pkg + "." + rd.name + akey, rd.name + akey] {
          if not ctx.genericFnDefs.containsKey(k) {
            ctx.genericFnDefs.add(k, gfn)
            ctx.genericFnPkg.add(k, pkg)
          }
        }
      }
      case _ -> ()
    }
  }
}

func substSelfWith(te: in TypeExpr, replacement: in TypeExpr): TypeExpr {
  match te.kind {
    case TSelf -> replacement
    case TParen(inner) -> TypeExpr(kind = TParen(inner = substSelfWith(inner, replacement)), span = te.span)
    case _ -> te
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
    // A by-value record: its IR name (`V*` is the pointer to a heap `V`).
    case NStruct(name, _) -> name
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
  addArcHeader(fields)
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
      // The closure's own types: a by-value record parameter is a struct
      // value, as the Lyric function the closure wraps takes it (#8009).
      val reduced: List[NType] = newList()
      var i = 0
      while i < parameters.count - 1 {
        reduced.add(typeToN(ctx, parameters[i]))
        i = i + 1
      }
      closureNType(ctx, reduced, typeToN(ctx, retTy))
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
      // A signature carrying a by-value record takes the C-ABI form (#8009).
      match callbackCAbi(ctx, parameters, retTy) {
        case Some(cb) -> {
          val cKey = nTypeToIrString(externCallbackNType(ctx, t))
          match mapGet(ctx.trampolines, cKey) {
            case Some(existing) -> return existing
            case None -> ()
          }
          val cbName = "__lyric_cb_tramp." + ctx.trampolines.count.toString()
          ctx.moduleFns.add(cAbiTrampoline(ctx, cbName, externCallbackClosureWant(ctx, t), cb))
          ctx.trampolines.add(cKey, cbName)
          return cbName
        }
        case None -> ()
      }
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
      gArgs.add(NArg(ty = NI32, value = NLitInt(v = closureFnSlot, ty = NI32)))
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
          toTy = NFnPtr(params = lyricParams, ret = rawRet)
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
        case None -> panic(
          "Lyric.LlvmCodegen: an extern function-typed parameter takes a Lyric closure argument; got " +
            nTypeToIrString(v.ty)
        )
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

/// `NativeWeak[T]`: shares T's representation behind a marker struct name.
/// It does not keep the target's payload alive, but it IS weak-counted —
/// `isRefNType` returns true for the marker so the value is retained/released
/// through the ordinary ARC machinery, dispatched to `lyric_weak_retain` /
/// `lyric_weak_release` by `emitRetain` / `emitRelease` (#5504).
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
  addArcHeader(fields)
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
  addArcHeader(fields)
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

// The C LyricTask is opaque; only the ARC header prefix is declared.
// Each `__task<T>` instantiation names the same layout so the awaited
// result type survives to await/unwrap lowering (mirrors `__map<...>`);
// all access goes through the lyric_task_* / lyric_async_* runtime calls.
func taskNType(ctx: in Ctx, elem: in NType): NType {
  val nm = "__task<" + mangleNTypeArg(elem) + ">"
  val fields = mapHeaderFields()
  if not ctx.taskElems.containsKey(nm) {
    ctx.taskElems.add(nm, elem)
    ctx.moduleTypeDefs.add(NTypeDefn(name = nm, fields = fields))
  }
  NPtr(pointee = NStruct(name = nm, fields = fields))
}

func taskElemOfType(ctx: in Ctx, t: in NType): Option[NType] {
  match t {
    case NPtr(pointee) -> {
      match pointee {
        case NStruct(name, _) -> mapGet(ctx.taskElems, name)
        case _ -> None
      }
    }
    case _ -> None
  }
}

// ── Async coroutines (stage B2) ──────────────────────────────────────────────
// An `async func` lowers to an LLVM coroutine (`presplitcoroutine`): the
// define returns its LyricTask* (as i8*) and the body runs hot inside the
// ramp until the first genuine suspension — an await on an incomplete task
// or an async sleep — matching .NET's hot-task model (see lyric_async.c).
// `spawn f(...)` holds the un-awaited task; every other async call site
// awaits in place, mirroring the front end where `spawn`/`await` are
// type-transparent and only `spawn` defers consumption of the result.
/// The current coroutine's LyricTask* operand, or None when lowering a
/// synchronous context.
func currentTaskPtr(ctx: in Ctx): Option[NValue] {
  if ctx.curAsyncTask.count == 0 {
    None
  } else {
    Some(value = NLocal(name = ctx.curAsyncTask[0]))
  }
}

/// Emit `llvm.coro.suspend` plus its resume/cleanup/exit dispatch and
/// leave the stream positioned in the resume block.  The task must have
/// registered with the scheduler (await/sleep) immediately before, so the
/// suspended frame is reachable when its wake condition fires.
func emitSuspendPoint(ctx: in Ctx, insns: in List[NInsn]): Unit {
  val s = freshTmp(ctx)
  val sArgs: List[NArg] = newList()
  sArgs.add(NArg(ty = NToken, value = NLitTokenNone))
  sArgs.add(NArg(ty = NI1, value = NLitInt(v = 0i64, ty = NI1)))
  insns.add(NCall(dest = s, retTy = NI8, fn = NGlobal(name = "llvm.coro.suspend"), args = sArgs))
  val resumeL = freshLabel(ctx, "coro.resume")
  val cases: List[NSwitchCase] = newList()
  cases.add(NSwitchCase(matchVal = 0i64, label = resumeL))
  cases.add(NSwitchCase(matchVal = 1i64, label = "coro.cleanup"))
  insns.add(NSwitch(ty = NI8, scrutinee = NLocal(name = s), defaultLabel = "coro.exit", cases = cases))
  insns.add(NLabel(name = resumeL))
}

/// Await a task value: park until it completes — suspending when inside a
/// coroutine, driving the scheduler to completion (`lyric_task_block_on`)
/// in a synchronous context — then read the result slot as a borrow (the
/// task keeps the owning ref until it is released).
func unwrapTask(ctx: in Ctx, insns: in List[NInsn], task: in NVal, elem: in NType): NVal {
  val tp = asI8Ptr(ctx, insns, task)
  match currentTaskPtr(ctx) {
    case Some(me) -> {
      val c = callRuntime(ctx, insns, "lyric_task_is_complete", NI32, arg1(NPtr(pointee = NI8), tp))
      val cb = freshTmp(ctx)
      insns.add(NICmp(dest = cb, pred = INe, ty = NI32, a = c.value, b = NLitInt(v = 0i64, ty = NI32)))
      val doneL = freshLabel(ctx, "await.done")
      val parkL = freshLabel(ctx, "await.park")
      insns.add(NCondBr(cond = NLocal(name = cb), thenLabel = doneL, elseLabel = parkL))
      insns.add(NLabel(name = parkL))
      insns.add(
        NCallVoid(fn = NGlobal(name = "lyric_async_await"), args = arg2(NPtr(pointee = NI8), me, NPtr(pointee = NI8), tp))
      )
      emitSuspendPoint(ctx, insns)
      insns.add(NBr(label = doneL))
      insns.add(NLabel(name = doneL))
    }
    case None -> {
      insns.add(NCallVoid(fn = NGlobal(name = "lyric_task_block_on"), args = arg1(NPtr(pointee = NI8), tp)))
    }
  }
  match elem {
    case NVoid -> NVal(ty = NVoid, value = NUndef(ty = NVoid))
    case _ -> {
      val slot = callRuntime(ctx, insns, "lyric_task_result", NI64, arg1(NPtr(pointee = NI8), tp))
      valOfSlot(ctx, insns, slot.value, elem)
    }
  }
}

/// Emit a call to an async (coroutine) callee.  The define returns the
/// task as i8*; `wantTask` (a `spawn` context) yields the task value
/// itself, otherwise the call awaits (unwraps) in place.
func emitAsyncCall(
  ctx: in Ctx,
  insns: in List[NInsn],
  irName: in String,
  callArgs: in List[NArg],
  elem: in NType,
  wantTask: in Bool,
): NVal {
  val dest = freshTmp(ctx)
  insns.add(NCall(dest = dest, retTy = NPtr(pointee = NI8), fn = NGlobal(name = irName), args = callArgs))
  val tty = taskNType(ctx, elem)
  val cast = freshTmp(ctx)
  insns.add(NBitcast(dest = cast, fromTy = NPtr(pointee = NI8), value = NLocal(name = dest), toTy = tty))
  val taskV = NVal(ty = tty, value = NLocal(name = cast))
  registerTemp(ctx, taskV)
  if wantTask {
    return taskV
  }
  unwrapTask(ctx, insns, taskV, elem)
}

/// `Std.Time.sleepMillis` inside a coroutine is the async leaf: park this
/// task on the timer list and suspend, instead of blocking the scheduler
/// thread (synchronous contexts fall through to the blocking kernel twin,
/// which is semantically equivalent there).
func emitAsyncSleep(ctx: in Ctx, insns: in List[NInsn], callArgs: in List[NArg]): NVal {
  val me = NLocal(name = ctx.curAsyncTask[0])
  val ms = coerceTo(ctx, insns, NVal(ty = callArgs[0].ty, value = callArgs[0].value), NI64)
  insns.add(NCallVoid(fn = NGlobal(name = "lyric_async_sleep"), args = arg2(NPtr(pointee = NI8), me, NI64, ms.value)))
  emitSuspendPoint(ctx, insns)
  NVal(ty = NVoid, value = NUndef(ty = NVoid))
}

/// The index of a union case by name, or -1.
func unionCaseIndexOf(ui: in NUnionInfo, name: in String): Int {
  var i = 0
  while i < ui.cases.count {
    if ui.cases[i].name == name {
      return i
    }
    i = i + 1
  }
  0 - 1
}

/// An inline union value viewed as a pointer to a hoisted stack copy, so the
/// pointer-based discriminant and payload GEPs apply to it.
func inlineUnionAddr(ctx: in Ctx, insns: in List[NInsn], v: in NVal): NVal {
  match v.value {
    case NLocal(n) -> {
      if ctx.inlineAddrs.containsKey(n) {
        return NVal(ty = NPtr(pointee = v.ty), value = NLocal(name = ctx.inlineAddrs[n]))
      }
    }
    case _ -> {
    }
  }
  val slot = "iu.addr." + freshTmp(ctx)
  ctx.allocas.add(NAlloca(dest = slot, ty = v.ty))
  insns.add(NStore(ty = v.ty, value = v.value, ptr = NLocal(name = slot)))
  NVal(ty = NPtr(pointee = v.ty), value = NLocal(name = slot))
}

/// Spill an inline-union value once, where it is produced, and remember the
/// slot: every later `inlineUnionAddr` of the same value reuses it, and the
/// store dominates them all.
func pinInlineUnion(ctx: in Ctx, insns: in List[NInsn], v: in NVal): Unit {
  match v.value {
    case NLocal(n) -> {
      if not ctx.inlineAddrs.containsKey(n) and isByValueStructNType(v.ty) and not isNoneUnion(unionInfoOfType(ctx, v.ty)) {
        val addr = inlineUnionAddr(ctx, insns, v)
        match addr.value {
          case NLocal(slot) -> ctx.inlineAddrs.add(n, slot)
          case _ -> {
          }
        }
      }
    }
    case _ -> {
    }
  }
}

/// Read field `fi` of union `ui`'s case `caseIdx` payload as a borrow.
func emitUnionPayloadFieldRead(
  ctx: in Ctx,
  insns: in List[NInsn],
  ui: in NUnionInfo,
  scrutinee0: in NVal,
  caseIdx: in Int,
  fi: in Int,
): NVal {
  val scrutinee = if ui.inline { inlineUnionAddr(ctx, insns, scrutinee0) } else { scrutinee0 }
  val structTy = match scrutinee.ty {
    case NPtr(pointee) -> pointee
    case _ -> panic("Lyric.LlvmCodegen: union payload read on a non-pointer value")
  }
  val objName = match scrutinee.value {
    case NLocal(n) -> n
    case _ -> panic("Lyric.LlvmCodegen: union scrutinee must be a local value")
  }
  val casePtr = emitCasePayloadPtr(ctx, insns, ui, structTy, objName, caseIdx)
  val caseTy = casePayloadStructType(ui, ui.cases[caseIdx])
  val fieldPtr = freshTmp(ctx)
  val fArgs: List[NArg] = newList()
  fArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  fArgs.add(NArg(ty = NI32, value = NLitInt(v = fi.toLong(), ty = NI32)))
  insns.add(NGEP(dest = fieldPtr, ty = caseTy, ptr = NLocal(name = casePtr), indices = fArgs))
  val fieldVal = freshTmp(ctx)
  insns.add(NLoad(dest = fieldVal, ty = ui.cases[caseIdx].fieldTys[fi], ptr = NLocal(name = fieldPtr)))
  NVal(ty = ui.cases[caseIdx].fieldTys[fi], value = NLocal(name = fieldVal))
}

/// `Std.Process.runCapture` / `runCaptureWithInput` inside a coroutine is
/// the async process leaf
/// (D-N-023): redirect to the kernel's nonblocking async seam
/// (`Std.ProcessCaptureHost.hostRunCaptureListAsync`, which pumps the
/// capture op through the sleep leaf), then project its
/// `Result[ProcessCaptureResult, String]` into the
/// `Result[ProcessResult, String]` the intercepted call was typed as —
/// the Ok payload through the stdlib's own `Std.Process.projectResult`.
/// Returns None (caller falls through to the blocking sync call) when
/// the async seam is not in the bundle.
func mustLeafSig(
  // #4631 seed workaround: these unwraps live in dedicated helpers whose
  // return type equals the payload, because the frozen mint seed's
  // match-binding inference unifies a `Some(x)` binding with an ENCLOSING
  // function's Option return type — inside `emitAsyncRunCapture`
  // (returning Option[NVal]) it typed the bindings as NVal and rejected
  // their field reads.  Callers check presence first.
  o: in Option[NFuncSig],
): NFuncSig {
  match o {
    case Some(s) -> s
    case None -> panic("Lyric.LlvmCodegen: internal — leaf sig checked present")
  }
}

func mustLeafUnion(o: in Option[NUnionInfo]): NUnionInfo {
  match o {
    case Some(u) -> u
    case None -> panic("Lyric.LlvmCodegen: internal — leaf union checked present")
  }
}

func isNoneUnion(o: in Option[NUnionInfo]): Bool {
  match o {
    case Some(_) -> false
    case None -> true
  }
}

func emitAsyncRunCapture(ctx: in Ctx, insns: in List[NInsn], sig: in NFuncSig, callArgs: in List[NArg]): Option[NVal] {
  if not ctx.sigs.containsKey("Std.ProcessCaptureHost.hostRunCaptureListAsync/4") {
    return None
  }
  if not ctx.sigs.containsKey("Std.Process.projectResult/1") {
    return None
  }
  val asig = mustLeafSig(mapGet(ctx.sigs, "Std.ProcessCaptureHost.hostRunCaptureListAsync/4"))
  val projSig = mustLeafSig(mapGet(ctx.sigs, "Std.Process.projectResult/1"))
  val rawTy = retTypeToN(ctx, asig.retTy)
  val targetTy = retTypeToN(ctx, sig.retTy)
  if isNoneUnion(unionInfoOfType(ctx, rawTy)) or isNoneUnion(unionInfoOfType(ctx, targetTy)) {
    return None
  }
  val rawUi = mustLeafUnion(unionInfoOfType(ctx, rawTy))
  val targetUi = mustLeafUnion(unionInfoOfType(ctx, targetTy))
  val rawOk = unionCaseIndexOf(rawUi, "Ok")
  val rawErr = unionCaseIndexOf(rawUi, "Err")
  val tgtOk = unionCaseIndexOf(targetUi, "Ok")
  val tgtErr = unionCaseIndexOf(targetUi, "Err")
  if rawOk < 0 or rawErr < 0 or tgtOk < 0 or tgtErr < 0 {
    return None
  }
  // runCapture/3 (exe, args, timeout) -> (exe, args, stdinContent = "",
  // timeout); runCaptureWithInput/4 already matches the seam's arg order.
  val aArgs: List[NArg] = newList()
  if callArgs.count == 3 {
    val emptyStdin = emitStringLiteral(ctx, insns, "")
    aArgs.add(callArgs[0])
    aArgs.add(callArgs[1])
    aArgs.add(NArg(ty = emptyStdin.ty, value = emptyStdin.value))
    aArgs.add(callArgs[2])
  } else {
    aArgs.add(callArgs[0])
    aArgs.add(callArgs[1])
    aArgs.add(callArgs[2])
    aArgs.add(callArgs[3])
  }
  val raw = emitAsyncCall(ctx, insns, asig.irName, aArgs, rawTy, false)
  // Project: match on the raw Result, per the lowerIf value-slot protocol.
  val structTy = match raw.ty { case NPtr(pointee) -> pointee; case _ -> return None }
  val discPtr = freshTmp(ctx)
  val dArgs: List[NArg] = newList()
  dArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  dArgs.add(NArg(ty = NI32, value = NLitInt(v = unionDiscSlot, ty = NI32)))
  insns.add(NGEP(dest = discPtr, ty = structTy, ptr = raw.value, indices = dArgs))
  val disc = freshTmp(ctx)
  insns.add(NLoad(dest = disc, ty = NI32, ptr = NLocal(name = discPtr)))
  val isOk = freshTmp(ctx)
  insns.add(
    NICmp(dest = isOk, pred = IEq, ty = NI32, a = NLocal(name = disc), b = NLitInt(v = rawOk.toLong(), ty = NI32))
  )
  val okL = freshLabel(ctx, "prc.ok")
  val errL = freshLabel(ctx, "prc.err")
  val doneL = freshLabel(ctx, "prc.done")
  val slotName = "prc.slot." + freshTmp(ctx)
  ctx.allocas.add(NAlloca(dest = slotName, ty = targetTy))
  insns.add(NCondBr(cond = NLocal(name = isOk), thenLabel = okL, elseLabel = errL))
  insns.add(NLabel(name = okL))
  pushTempScope(ctx)
  val pcr = emitUnionPayloadFieldRead(ctx, insns, rawUi, raw, rawOk, 0)
  val prTy = retTypeToN(ctx, projSig.retTy)
  val prDest = freshTmp(ctx)
  val projArgs: List[NArg] = newList()
  projArgs.add(NArg(ty = pcr.ty, value = pcr.value))
  insns.add(NCall(dest = prDest, retTy = prTy, fn = NGlobal(name = projSig.irName), args = projArgs))
  val pr = NVal(ty = prTy, value = NLocal(name = prDest))
  registerTemp(ctx, pr)
  val okVals: List[NVal] = newList()
  okVals.add(pr)
  val okV = lowerUnionConstructVals(ctx, insns, targetUi, tgtOk, okVals)
  ensureOwned(ctx, insns, okV)
  popTempScope(ctx, insns)
  insns.add(NStore(ty = targetTy, value = okV.value, ptr = NLocal(name = slotName)))
  insns.add(NBr(label = doneL))
  insns.add(NLabel(name = errL))
  pushTempScope(ctx)
  val msg = emitUnionPayloadFieldRead(ctx, insns, rawUi, raw, rawErr, 0)
  val errVals: List[NVal] = newList()
  errVals.add(msg)
  val errV = lowerUnionConstructVals(ctx, insns, targetUi, tgtErr, errVals)
  ensureOwned(ctx, insns, errV)
  popTempScope(ctx, insns)
  insns.add(NStore(ty = targetTy, value = errV.value, ptr = NLocal(name = slotName)))
  insns.add(NBr(label = doneL))
  insns.add(NLabel(name = doneL))
  val dest = freshTmp(ctx)
  insns.add(NLoad(dest = dest, ty = targetTy, ptr = NLocal(name = slotName)))
  val outV = NVal(ty = targetTy, value = NLocal(name = dest))
  registerTemp(ctx, outV)
  Some(value = outV)
}

/// `lyric_task_complete(task, slot, is_ref)`: store the produced value in
/// the current coroutine's task (ownership of a ref-typed result transfers
/// into the task's result slot) and wake its waiters.
func emitTaskComplete(ctx: in Ctx, insns: in List[NInsn], v: in NVal): Unit {
  val me = NLocal(name = ctx.curAsyncTask[0])
  var slotV: NValue = NLitInt(v = 0i64, ty = NI64)
  var isRef: NValue = NLitInt(v = 0i64, ty = NI32)
  match v.ty {
    case NVoid -> {
    }
    case _ -> {
      if isBoxedValueNType(v.ty) {
        // The result slot takes over the box's only reference.
        val box = boxByValue(ctx, insns, v)
        val boxSlot = freshTmp(ctx)
        insns.add(NPtrToInt(dest = boxSlot, fromTy = box.ty, value = box.value, toTy = NI64))
        slotV = NLocal(name = boxSlot)
      } else {
        slotV = slotOfVal(ctx, insns, v)
      }
      isRef = refFlagOf(v.ty)
    }
  }
  val cArgs: List[NArg] = newList()
  cArgs.add(NArg(ty = NPtr(pointee = NI8), value = me))
  cArgs.add(NArg(ty = NI64, value = slotV))
  cArgs.add(NArg(ty = NI32, value = isRef))
  insns.add(NCallVoid(fn = NGlobal(name = "lyric_task_complete"), args = cArgs))
}

/// The refcounted box (`__box<R>`) a by-value record occupies in a
/// List/Map/Task slot: the ARC header followed by the struct.  The box holds
/// no references (a by-value record's fields are all by-value), so it has no
/// destructor and the runtime frees it when the last reference drops.
func byValueBoxType(ctx: in Ctx, t: in NType): NType {
  val nm = "__box<" + mangleNTypeArg(t) + ">"
  val fields: List[NType] = newList()
  addArcHeader(fields)
  fields.add(t)
  if not ctx.byValueBoxes.containsKey(nm) {
    ctx.byValueBoxes.add(nm, true)
    ctx.moduleTypeDefs.add(NTypeDefn(name = nm, fields = fields))
  }
  NPtr(pointee = NStruct(name = nm, fields = fields))
}

/// Allocate a box holding the by-value record `v`: an OWNED (rc = 1) pointer,
/// not registered with any temp scope.
func boxByValue(ctx: in Ctx, insns: in List[NInsn], v: in NVal): NVal {
  val boxTy = byValueBoxType(ctx, v.ty)
  val boxStructTy = match boxTy { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  val obj = emitHeapAlloc(ctx, insns, boxTy, "")
  val payloadPtr = freshTmp(ctx)
  val gArgs: List[NArg] = newList()
  gArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  gArgs.add(NArg(ty = NI32, value = NLitInt(v = arcHeaderSlots.toLong(), ty = NI32)))
  insns.add(NGEP(dest = payloadPtr, ty = boxStructTy, ptr = NLocal(name = obj), indices = gArgs))
  insns.add(NStore(ty = v.ty, value = v.value, ptr = NLocal(name = payloadPtr)))
  NVal(ty = boxTy, value = NLocal(name = obj))
}

// Widen a value to the container's 64-bit slot representation.
func slotOfVal(ctx: in Ctx, insns: in List[NInsn], v: in NVal): NValue {
  if isBoxedValueNType(v.ty) {
    // The container retains the box (its element flag is 1); the temp scope
    // drops this construction's own reference.
    val box = boxByValue(ctx, insns, v)
    registerTemp(ctx, box)
    val dest = freshTmp(ctx)
    insns.add(NPtrToInt(dest = dest, fromTy = box.ty, value = box.value, toTy = NI64))
    return NLocal(name = dest)
  }
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
    // A `Float` occupies the low 32 bits of the slot.
    case NFloat -> {
      val bits = freshTmp(ctx)
      insns.add(NBitcast(dest = bits, fromTy = NFloat, value = v.value, toTy = NI32))
      val dest = freshTmp(ctx)
      insns.add(NZExt(dest = dest, fromTy = NI32, value = NLocal(name = bits), toTy = NI64))
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
    case _ -> panic(
      "Lyric.LlvmCodegen: this element type cannot be stored in a List/Map slot for --target native: " +
        nTypeToIrString(v.ty)
    )
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
    // A by-value record or array is loaded out of its box (a copy: values have no identity).
    case NStruct(_, _) | NArray(_, _) -> {
      val boxTy = byValueBoxType(ctx, elemTy)
      val boxStructTy = match boxTy { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
      val box = freshTmp(ctx)
      insns.add(NIntToPtr(dest = box, fromTy = NI64, value = slot, toTy = boxTy))
      val payloadPtr = freshTmp(ctx)
      val gArgs: List[NArg] = newList()
      gArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
      gArgs.add(NArg(ty = NI32, value = NLitInt(v = arcHeaderSlots.toLong(), ty = NI32)))
      insns.add(NGEP(dest = payloadPtr, ty = boxStructTy, ptr = NLocal(name = box), indices = gArgs))
      val dest = freshTmp(ctx)
      insns.add(NLoad(dest = dest, ty = elemTy, ptr = NLocal(name = payloadPtr)))
      NVal(ty = elemTy, value = NLocal(name = dest))
    }
    case NI64 -> NVal(ty = NI64, value = slot)
    case NDouble -> {
      val dest = freshTmp(ctx)
      insns.add(NBitcast(dest = dest, fromTy = NI64, value = slot, toTy = NDouble))
      NVal(ty = NDouble, value = NLocal(name = dest))
    }
    case NFloat -> {
      val bits = freshTmp(ctx)
      insns.add(NTrunc(dest = bits, fromTy = NI64, value = slot, toTy = NI32))
      val dest = freshTmp(ctx)
      insns.add(NBitcast(dest = dest, fromTy = NI32, value = NLocal(name = bits), toTy = NFloat))
      NVal(ty = NFloat, value = NLocal(name = dest))
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
    case _ -> panic(
      "Lyric.LlvmCodegen: this element type cannot be read from a List/Map slot for --target native: " +
        nTypeToIrString(elemTy)
    )
  }
}

// The list/map receiver as the i8* the runtime functions take.
func collectionAsI8(ctx: in Ctx, insns: in List[NInsn], v: in NVal): NValue {
  val dest = freshTmp(ctx)
  insns.add(NBitcast(dest = dest, fromTy = v.ty, value = v.value, toTy = NPtr(pointee = NI8)))
  NLocal(name = dest)
}

/// Tri-state element/result ownership flag the List/Map/Task runtime
/// kernels dispatch on (#5545): 0 scalar, 1 strong ref
/// (`lyric_retain`/`lyric_release`), 2 weak ref
/// (`lyric_weak_retain`/`lyric_weak_release` — never keeps the target
/// strongly alive). Must be checked BEFORE `isRefNType`: a
/// `NativeWeak[T]` value IS a ref-typed pointer (`NPtr(NStruct(...))`)
/// by `isRefNType`'s own definition, so the weak check would never be
/// reached if ordered after it.
func refFlagOf(t: in NType): NValue {
  if isWeakNType(t) {
    return NLitInt(v = 2i64, ty = NI32)
  }
  // A by-value record is stored boxed, and the box is a strong reference.
  if isRefNType(t) or isBoxedValueNType(t) {
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

// Push one already-lowered value onto a LyricList (given the list cast to i8*),
// via the same `lyric_list_push` kernel `.add(x)` lowers to.
func pushToList(ctx: in Ctx, insns: in List[NInsn], recvP: in NValue, v: in NVal): Unit {
  val pArgs: List[NArg] = newList()
  pArgs.add(NArg(ty = NPtr(pointee = NI8), value = recvP))
  pArgs.add(NArg(ty = NI64, value = slotOfVal(ctx, insns, v)))
  val _ = callRuntime(ctx, insns, "lyric_list_push", NVoid, pArgs)
}

/// Lower a `[e1, e2, ...]` list literal (EList) of known element type by
/// constructing an empty LyricList and pushing each element — the same
/// `lyric_list_new` + `lyric_list_push` sequence `newList()` + `.add()` lowers
/// to (#5977). Each element is lowered with `elem` as its expected type so
/// nested collection literals and generic cases construct correctly.
func lowerListLiteral(ctx: in Ctx, insns: in List[NInsn], elems: in List[Expr], elem: in NType): NVal {
  val lst = constructList(ctx, insns, elem)
  val recvP = collectionAsI8(ctx, insns, lst)
  var i = 0
  while i < elems.count {
    pushToList(ctx, insns, recvP, lowerExprExpecting(ctx, insns, elems[i], elem))
    i = i + 1
  }
  lst
}

func constructMap(ctx: in Ctx, insns: in List[NInsn], k: in NType, v: in NType): NVal {
  var keyFlag = NLitInt(v = 0i64, ty = NI32)
  if isStringNType(k) {
    keyFlag = NLitInt(v = 1i64, ty = NI32)
  } else {
    if isRefNType(k) or isBoxedValueNType(k) {
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
  // A `[...]` list literal against an expected `List[T]` (record field, typed
  // binding, arg, return) — the element type comes from `want` (#5977), the
  // same way `newList()` takes its element types from the expected type.
  match e.kind {
    case EList(elems) -> {
      match want {
        case NArray(el, n) -> return Some(value = lowerArrayLiteral(ctx, insns, elems, want, el, n))
        case _ -> ()
      }
      match listElemOfType(ctx, want) {
        case Some(elem) -> return Some(value = lowerListLiteral(ctx, insns, elems, elem))
        case None -> return None
      }
    }
    case _ -> ()
  }
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
  // `default()` is the zero value of the expected type: 0, false, null for a
  // reference (the placeholder a later `out` argument or assignment replaces,
  // releasing nothing), a zeroed by-value aggregate.
  if nm == "default" and ctorArgs.count == 0 and not hasFuncOverrideNative(ctx, "default", 0) {
    match want {
      case NVoid -> ()
      case _ -> return Some(value = NVal(ty = want, value = zeroValueOf(want)))
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
      // `.slice(start, stop)` / `.concat(other)` / `.append(x)` (#6104):
      // `List[T]`/`slice[T]` never-mutating combinators — each returns a
      // FRESH list (element pointers retained by the new list, source
      // untouched), backing `Std.HttpEngine`'s buffer bookkeeping on
      // every target. Bounds/panic contract matches the MSIL twin
      // (`Msil.Codegen.lowerSliceSliceMsil`).
      if name == "slice" and args.count == 2 {
        val startV = lowerCallArgExpecting(ctx, insns, args, 0, NI64)
        val stopV = lowerCallArgExpecting(ctx, insns, args, 1, NI64)
        val raw = freshTmp(ctx)
        val cArgs: List[NArg] = newList()
        cArgs.add(NArg(ty = NPtr(pointee = NI8), value = recvP))
        cArgs.add(NArg(ty = NI64, value = startV.value))
        cArgs.add(NArg(ty = NI64, value = stopV.value))
        insns.add(NCall(dest = raw, retTy = NPtr(pointee = NI8), fn = NGlobal(name = "lyric_list_slice"), args = cArgs))
        val cast = freshTmp(ctx)
        insns.add(NBitcast(dest = cast, fromTy = NPtr(pointee = NI8), value = NLocal(name = raw), toTy = recv.ty))
        val outV = NVal(ty = recv.ty, value = NLocal(name = cast))
        registerTemp(ctx, outV)
        return Some(value = outV)
      }
      if name == "concat" and args.count == 1 {
        val otherV = lowerCallArgExpecting(ctx, insns, args, 0, recv.ty)
        val otherP = collectionAsI8(ctx, insns, otherV)
        val raw = freshTmp(ctx)
        val cArgs: List[NArg] = newList()
        cArgs.add(NArg(ty = NPtr(pointee = NI8), value = recvP))
        cArgs.add(NArg(ty = NPtr(pointee = NI8), value = otherP))
        insns.add(NCall(dest = raw, retTy = NPtr(pointee = NI8), fn = NGlobal(name = "lyric_list_concat"), args = cArgs))
        val cast = freshTmp(ctx)
        insns.add(NBitcast(dest = cast, fromTy = NPtr(pointee = NI8), value = NLocal(name = raw), toTy = recv.ty))
        val outV = NVal(ty = recv.ty, value = NLocal(name = cast))
        registerTemp(ctx, outV)
        return Some(value = outV)
      }
      if name == "append" and args.count == 1 {
        val v = lowerCallArgExpecting(ctx, insns, args, 0, elem)
        val raw = freshTmp(ctx)
        val cArgs: List[NArg] = newList()
        cArgs.add(NArg(ty = NPtr(pointee = NI8), value = recvP))
        cArgs.add(NArg(ty = NI64, value = slotOfVal(ctx, insns, v)))
        insns.add(NCall(dest = raw, retTy = NPtr(pointee = NI8), fn = NGlobal(name = "lyric_list_append"), args = cArgs))
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

/// `nativeLoadByte(p, offset)` / `nativeStoreByte(p, offset, value)`
/// (D161): the byte at `p + offset`, through an `i8` GEP.
func lowerNativeByteAccess(ctx: in Ctx, insns: in List[NInsn], name: in String, args: in List[CallArg]): NVal {
  val bytePtr = NPtr(pointee = NI8)
  val p = lowerExprExpecting(ctx, insns, nativeCallArgExpr(args[0]), bytePtr)
  val off = lowerExprExpecting(ctx, insns, nativeCallArgExpr(args[1]), NI64)
  val addr = freshTmp(ctx)
  val idx: List[NArg] = newList()
  idx.add(NArg(ty = NI64, value = off.value))
  insns.add(NGEP(dest = addr, ty = NI8, ptr = p.value, indices = idx))
  if name == "nativeLoadByte" {
    val dest = freshTmp(ctx)
    insns.add(NLoad(dest = dest, ty = NI8, ptr = NLocal(name = addr)))
    return NVal(ty = NI8, value = NLocal(name = dest))
  }
  val v = lowerExprExpecting(ctx, insns, nativeCallArgExpr(args[2]), NI8)
  insns.add(NStore(ty = NI8, value = v.value, ptr = NLocal(name = addr)))
  NVal(ty = NVoid, value = NUndef(ty = NVoid))
}

func nativeCallArgExpr(a: in CallArg): Expr {
  match a {
    case CAPositional(ex) -> ex
    case CANamed(_, value, _) -> value
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
    case None -> panic(
      "Lyric.LlvmCodegen: 'mapGet' is reserved for Std.Collections maps on --target native (got " +
        nTypeToIrString(m.ty) +
        ")"
    )
  }
  val vTy = match mapValOfType(ctx, m.ty) {
    case Some(t) -> t
    case None -> panic("Lyric.LlvmCodegen: internal — map type without a value type")
  }
  val optKey = match resolveGenericUnionKey(ctx, "Option", "Option") {
    case Some(kk) -> kk
    case None -> panic(
      "Lyric.LlvmCodegen: mapGet needs a generic union named 'Option' (with cases Some/None) in the import closure"
    )
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
  match lowerArrayIndexRead(ctx, insns, receiver, indices[0], line) {
    case Some(v) -> return v
    case None -> ()
  }
  val recv = lowerExpr(ctx, insns, receiver)
  match recv.ty {
    case NArray(el, n) -> {
      val addr = spillArray(ctx, insns, recv)
      return readArrayElem(ctx, insns, addr, recv.ty, el, n, indices[0], line)
    }
    case _ -> ()
  }
  if isStringNType(recv.ty) {
    // `s[i]` (#6237): `i` is a byte offset, matching this backend's
    // existing byte-indexed `.length`/`.substring` model (D-N-006); the
    // runtime intrinsic decodes the full Unicode scalar value starting at
    // that offset via UTF-8 iteration and returns it as `Char` (NI32) —
    // see `lyric_string_char_at`'s own header comment for why a raw byte
    // read would be wrong here.
    val idx = lowerExprExpecting(ctx, insns, indices[0], NI64)
    return callRuntime(ctx, insns, "lyric_string_char_at", NI32, arg2(lyricStringNType(), recv.value, NI64, idx.value))
  }
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
    "Lyric.LlvmCodegen: indexing on this receiver is not yet supported for --target native (lists, maps, slices, and Strings index) at line " +
      line.toString() +
      ": " +
      nTypeToIrString(recv.ty)
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
    case None -> panic(
      "Lyric.LlvmCodegen: 'for' on --target native iterates List[T] (slices land with the N5 stdlib port); got " +
        nTypeToIrString(it.ty)
    )
  }
  var bindName = ""
  var haveBind = false
  match pat.kind {
    case PBinding(nm, inner) -> {
      match inner {
        case Some(_) -> panic(
          "Lyric.LlvmCodegen: this for-pattern is not yet supported for --target native (use a plain name)"
        )
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
    // #7010: clear any stale varIsChar entry from an earlier binding of
    // this name (e.g. a prior `val bindName: Char = ...` in scope) — the
    // loop-element type isn't tracked as Char here (a real gap, #6237's
    // own follow-up), but an unconditional `false` at least prevents the
    // old entry from silently surviving the rebind and misrouting this
    // (non-Char) value through lyric_string_from_char.
    markVarChar(ctx, bindName, false)
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

/// `for i in lo ..< hi` / `lo ..= hi`: a counted loop over the bounds' common
/// integer type, both bounds evaluated once at entry (matching the MSIL and
/// JVM counting loops).  `Byte` bounds compare unsigned (#4628).
func lowerForOverRange(
  ctx: in Ctx,
  insns: in List[NInsn],
  pat: in Pattern,
  lo: in Expr,
  hi: in Expr,
  inclusive: in Bool,
  body: in Block,
): Unit {
  var bindName = ""
  var haveBind = false
  match pat.kind {
    case PBinding(nm, inner) -> {
      match inner {
        case Some(_) -> panic(
          "Lyric.LlvmCodegen: this for-pattern is not yet supported for --target native (use a plain name)"
        )
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
  val loV = lowerExpr(ctx, insns, lo)
  val hiV = lowerExpr(ctx, insns, hi)
  val w = widenOperands(ctx, insns, loV, hiV)
  if intNTypeRank(w.ty) == 0 {
    panic("Lyric.LlvmCodegen: a range `for` needs integer bounds; got " + nTypeToIrString(w.ty))
  }
  val ty = w.ty
  val idxSlot = "for.idx." + freshTmp(ctx)
  ctx.allocas.add(NAlloca(dest = idxSlot, ty = ty))
  insns.add(NStore(ty = ty, value = w.a.value, ptr = NLocal(name = idxSlot)))
  val hiSlot = "for.hi." + freshTmp(ctx)
  ctx.allocas.add(NAlloca(dest = hiSlot, ty = ty))
  insns.add(NStore(ty = ty, value = w.b.value, ptr = NLocal(name = hiSlot)))
  val pred = match ty { case NI8 -> if inclusive { IUle } else { IUlt }; case _ -> if inclusive { ISle } else { ISlt } }
  val condL = freshLabel(ctx, "for.cond")
  val bodyL = freshLabel(ctx, "for.body")
  val incL = freshLabel(ctx, "for.inc")
  val exitL = freshLabel(ctx, "for.exit")
  insns.add(NBr(label = condL))
  insns.add(NLabel(name = condL))
  val curIdx = freshTmp(ctx)
  insns.add(NLoad(dest = curIdx, ty = ty, ptr = NLocal(name = idxSlot)))
  val curHi = freshTmp(ctx)
  insns.add(NLoad(dest = curHi, ty = ty, ptr = NLocal(name = hiSlot)))
  val cmp = freshTmp(ctx)
  insns.add(NICmp(dest = cmp, pred = pred, ty = ty, a = NLocal(name = curIdx), b = NLocal(name = curHi)))
  insns.add(NCondBr(cond = NLocal(name = cmp), thenLabel = bodyL, elseLabel = exitL))
  insns.add(NLabel(name = bodyL))
  ctx.loopBreak.add(exitL)
  ctx.loopCont.add(incL)
  ctx.loopVarDepth.add(ctx.scopeRefs.count)
  ctx.loopTempDepth.add(ctx.tempScopes.count)
  pushVarScope(ctx)
  if haveBind {
    val bodyIdx = freshTmp(ctx)
    insns.add(NLoad(dest = bodyIdx, ty = ty, ptr = NLocal(name = idxSlot)))
    bindLocal(ctx, insns, bindName, NVal(ty = ty, value = NLocal(name = bodyIdx)))
    markVarChar(ctx, bindName, false)
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
  insns.add(NLoad(dest = incIdx, ty = ty, ptr = NLocal(name = idxSlot)))
  val nextIdx = freshTmp(ctx)
  insns.add(NAdd(dest = nextIdx, ty = ty, a = NLocal(name = incIdx), b = NLitInt(v = 1i64, ty = ty)))
  insns.add(NStore(ty = ty, value = NLocal(name = nextIdx), ptr = NLocal(name = idxSlot)))
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
  val ri = NRecInfo(irName = nm, fieldNames = names, fieldTys = elemTys, fieldDefaults = dflts, byValue = false)
  ctx.recordDefs.add(nm, ri)
  val defnFields: List[NType] = newList()
  addArcHeader(defnFields)
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
    case TArray(size, element) -> {
      match typeToNEnvOpt(ctx, element, envNames, envTys) {
        case Some(el) -> arrayNType(ctx, size, el)
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

/// Whether a generic union instantiated with these case field types is inline:
/// not an `impl` target, and every payload field by-value (a self-reference is
/// still a pointer to the registration stub, so a recursive union stays heap).
func genericUnionInline(ctx: in Ctx, gkey: in String, ud: in UnionDecl, cases: in List[NUnionCaseInfo]): Bool {
  val pkg = match mapGet(ctx.genericDeclPkg, gkey) { case Some(p) -> p; case None -> "" }
  if isHeapOnlyRec(ctx, pkg, ud.name) {
    return false
  }
  for c in cases {
    for t in c.fieldTys {
      if not isByValueFieldNType(t) {
        return false
      }
    }
  }
  true
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
  // A self-referential case field (`tail: PersistentList[T]`) instantiates
  // this same union again while its fields are being lowered. Register a
  // zero-payload stub first so that recursion finds it instead of
  // re-entering (a compiler stack overflow before, #7280), exactly as the
  // non-generic registration does; the stub is replaced below.
  val emptyCases: List[NUnionCaseInfo] = newList()
  ctx.unionDefs.add(instName, NUnionInfo(irName = instName, cases = emptyCases, payloadWords = 0, inline = false))
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
        case None -> {
          ctx.unionDefs.remove(instName)
          return None
        }
      }
      fi = fi + 1
    }
    val sz = structSize(ctx, tys)
    if sz > maxBytes {
      maxBytes = sz
    }
    cases.add(NUnionCaseInfo(name = cd.name, fieldNames = names, fieldTys = tys))
    ci = ci + 1
  }
  val words = (maxBytes + 7) / 8
  val inlineU = genericUnionInline(ctx, gkey, ud, cases)
  val ui = NUnionInfo(irName = instName, cases = cases, payloadWords = words, inline = inlineU)
  ctx.unionDefs.remove(instName)
  ctx.unionDefs.add(instName, ui)
  ctx.instMeta.add(instName, NInstInfo(gkey = gkey, argTys = argTys))
  ctx.moduleTypeDefs.add(NTypeDefn(name = instName, fields = unionStructFields(ui)))
  var ci2 = 0
  while ci2 < cases.count {
    if cases[ci2].fieldTys.count > 0 {
      ctx.moduleTypeDefs.add(
        NTypeDefn(name = casePayloadStructName(ui, cases[ci2].name), fields = layoutFieldTys(cases[ci2].fieldTys))
      )
    }
    ci2 = ci2 + 1
  }
  if unionHasRefFields(ui) and not ui.inline {
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
  // Stub first, for a field that refers back to this instantiation (see
  // `instantiateGenericUnionOpt`, #7280).
  val stubNames: List[String] = newList()
  val stubTys: List[NType] = newList()
  val stubDflts: List[Option[Expr]] = newList()
  ctx.recordDefs.add(
    instName,
    NRecInfo(irName = instName, fieldNames = stubNames, fieldTys = stubTys, fieldDefaults = stubDflts, byValue = false)
  )
  var i = 0
  while i < fields.count {
    names.add(fields[i].name)
    match typeToNEnvOpt(ctx, fields[i].ty, envNames, argTys) {
      case Some(t) -> tys.add(t)
      case None -> {
        ctx.recordDefs.remove(instName)
        return None
      }
    }
    dflts.add(fields[i].dflt)
    i = i + 1
  }
  val byValue = genericRecordByValue(ctx, gkey, rd, tys)
  val ri = NRecInfo(irName = instName, fieldNames = names, fieldTys = tys, fieldDefaults = dflts, byValue = byValue)
  ctx.recordDefs.remove(instName)
  ctx.recordDefs.add(instName, ri)
  ctx.instMeta.add(instName, NInstInfo(gkey = gkey, argTys = argTys))
  if byValue {
    ctx.moduleTypeDefs.add(NTypeDefn(name = instName, fields = layoutFieldTys(tys)))
    return Some(value = ri)
  }
  val defnFields: List[NType] = newList()
  addArcHeader(defnFields)
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
    case None -> panic(
      "Lyric.LlvmCodegen: cannot instantiate generic union '" + gkey +
        "' for --target native (a field type is not yet lowerable)"
    )
  }
  lowerUnionConstructVals(ctx, insns, ui, caseIdx, rawVals)
}

/// Lower a generic record constructor call (`Box(item = x, tag = 2)`):
/// infer the type args from directly-param-typed fields, instantiate,
/// construct.
func lowerGenericRecordConstruct(
  ctx: in Ctx,
  insns: in List[NInsn],
  gkey: in String,
  args: in List[CallArg],
  retWant: in Option[NType],
): NVal {
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
  // A lambda field is deferred: its function type may mention type
  // parameters that only the other fields or the expected type bind, so it is
  // lowered last, against the field's type under those bindings.
  val deferredLambda: List[Bool] = newList()
  val fieldExprs: List[Option[Expr]] = newList()
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
    var fe: Option[Expr] = None
    if found2 >= 0 {
      fe = Some(value = argFieldExpr[found2])
    } else {
      match fields[fi2].dflt {
        case Some(d) -> {
          fe = Some(value = d)
        }
        case None -> panic(
          "Lyric.LlvmCodegen: missing field '" + fields[fi2].name + "' constructing record '" + rd.name + "'"
        )
      }
    }
    fieldExprs.add(fe)
    val fexpr = match fe { case Some(x) -> x; case None -> panic("unreachable") }
    if isLambdaExpr(fexpr) {
      deferredLambda.add(true)
      rawVals.add(NVal(ty = NVoid, value = NUndef(ty = NVoid)))
    } else {
      deferredLambda.add(false)
      rawVals.add(lowerExpr(ctx, insns, fexpr))
    }
    fi2 = fi2 + 1
  }
  // Bind each type parameter from the field values (a bare `T` field, or
  // one nested in a generic instantiation such as `rest:
  // PersistentList[T]`), then from the expected type at the construction
  // site for any parameter no field determines (#7413).
  val envNames = genericParamNamesOf(rd.generics)
  val boundNames: List[String] = newList()
  val boundTys: List[NType] = newList()
  var ufi = 0
  while ufi < fields.count {
    if not deferredLambda[ufi] {
      unifyTyArg(ctx, fields[ufi].ty, rawVals[ufi].ty, envNames, boundNames, boundTys)
    }
    ufi = ufi + 1
  }
  if boundNames.count < envNames.count {
    match retWant {
      case Some(w) -> {
        val selfArgs: List[TypeArg] = newList()
        var sai = 0
        while sai < envNames.count {
          val tpSegs: List[String] = newList()
          tpSegs.add(envNames[sai])
          selfArgs.add(TAType(ty = TypeExpr(kind = TRef(path = ModulePath(segments = tpSegs, span = rd.span)), span = rd.span)))
          sai = sai + 1
        }
        val headSegs: List[String] = newList()
        headSegs.add(rd.name)
        val selfTy = TypeExpr(
          kind = TGenericApp(head = ModulePath(segments = headSegs, span = rd.span), args = selfArgs),
          span = rd.span
        )
        unifyTyArg(ctx, selfTy, w, envNames, boundNames, boundTys)
      }
      case None -> ()
    }
  }
  var dli = 0
  while dli < fields.count {
    if deferredLambda[dli] {
      val lamExpr = match fieldExprs[dli] { case Some(x) -> x; case None -> panic("unreachable") }
      match typeToNEnvOpt(ctx, fields[dli].ty, boundNames, boundTys) {
        case Some(want) -> {
          rawVals[dli] = lowerExprExpecting(ctx, insns, lamExpr, want)
        }
        case None -> {
          rawVals[dli] = lowerExpr(ctx, insns, lamExpr)
        }
      }
      unifyTyArg(ctx, fields[dli].ty, rawVals[dli].ty, envNames, boundNames, boundTys)
    }
    dli = dli + 1
  }
  val envTys: List[NType] = newList()
  var pi = 0
  while pi < envNames.count {
    val bi = envIndexOf(boundNames, envNames[pi])
    if bi < 0 {
      panic(
        "Lyric.LlvmCodegen: cannot infer type argument '" + envNames[pi] + "' for record '" + rd.name +
          "' from its constructor arguments; annotate the binding or pass the value through a typed position"
      )
    }
    envTys.add(boundTys[bi])
    pi = pi + 1
  }
  val ri = match instantiateGenericRecordOpt(ctx, genericQualifiedKey(ctx, gkey), envTys) {
    case Some(r) -> r
    case None -> panic(
      "Lyric.LlvmCodegen: cannot instantiate generic record '" + gkey +
        "' for --target native (a field type is not yet lowerable)"
    )
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
func unifyTypeArgWith(
  ctx: in Ctx,
  ta: in TypeArg,
  argTy: in NType,
  paramNames: in List[String],
  boundNames: in List[String],
  boundTys: in List[NType],
): Unit {
  match ta {
    case TAType(inner) -> unifyTyArg(ctx, inner, argTy, paramNames, boundNames, boundTys)
    case TAValue(_) -> ()
  }
}

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
                  // Built-in collections carry their element types in
                  // side tables rather than `instMeta` (#7413).
                  val headName = modulePathJoin(head.segments)
                  if headName == "List" and targs.count == 1 {
                    match listElemOfType(ctx, argTy) {
                      case Some(et) -> unifyTypeArgWith(ctx, targs[0], et, paramNames, boundNames, boundTys)
                      case None -> ()
                    }
                  } else if headName == "Map" and targs.count == 2 {
                    match mapKeyOfType(ctx, argTy) {
                      case Some(kt) -> unifyTypeArgWith(ctx, targs[0], kt, paramNames, boundNames, boundTys)
                      case None -> ()
                    }
                    match mapValOfType(ctx, argTy) {
                      case Some(vt) -> unifyTypeArgWith(ctx, targs[1], vt, paramNames, boundNames, boundTys)
                      case None -> ()
                    }
                  }
                }
              }
            }
            case _ -> {
            }
          }
        }
        // An instantiated generic BY-VALUE record is the struct itself.
        case NStruct(instName, _) -> {
          match mapGet(ctx.instMeta, instName) {
            case Some(meta) -> {
              if targs.count == meta.argTys.count {
                var i = 0
                while i < targs.count {
                  unifyTypeArgWith(ctx, targs[i], meta.argTys[i], paramNames, boundNames, boundTys)
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
    case TSlice(elemTe) -> {
      match listElemOfType(ctx, argTy) {
        case Some(et) -> unifyTyArg(ctx, elemTe, et, paramNames, boundNames, boundTys)
        case None -> ()
      }
    }
    case TArray(_, elemTe) -> {
      match argTy {
        case NArray(el, _) -> unifyTyArg(ctx, elemTe, el, paramNames, boundNames, boundTys)
        case _ -> match listElemOfType(ctx, argTy) {
          case Some(et) -> unifyTyArg(ctx, elemTe, et, paramNames, boundNames, boundTys)
          case None -> ()
        }
      }
    }
    case TParen(inner) -> unifyTyArg(ctx, inner, argTy, paramNames, boundNames, boundTys)
    // A function-typed parameter binds from the argument closure's own
    // signature (`f: () -> T` against a `() -> Int` closure binds `T = Int`).
    case TFunction(parameters, retTy) -> {
      match closureSigOfType(ctx, argTy) {
        case Some(cs) -> {
          if parameters.count == cs.paramTys.count {
            var pi = 0
            while pi < parameters.count {
              unifyTyArg(ctx, parameters[pi], cs.paramTys[pi], paramNames, boundNames, boundTys)
              pi = pi + 1
            }
          }
          unifyTyArg(ctx, retTy, cs.retTy, paramNames, boundNames, boundTys)
        }
        case None -> ()
      }
    }
    case _ -> {
    }
  }
}

/// A construction of a generic union's case (`AnswerDialog(yes = true)`): its
/// type arguments may be determined only by where the value is used, so a
/// generic call takes it after the arguments that do bind them.
func isGenericCaseCtorExpr(ctx: in Ctx, e: in Expr): Bool {
  match e.kind {
    case ECall(fn, _) -> match fn.kind {
      case EPath(path) -> path.segments.count == 1 and
        ctx.caseToGenericUnion.containsKey(path.segments[0]) and
        not ctx.varTypes.containsKey(path.segments[0])
      case _ -> false
    }
    case EParen(inner) -> isGenericCaseCtorExpr(ctx, inner)
    case _ -> false
  }
}

func copyStrings(xs: in List[String]): List[String] {
  val copy: List[String] = newList()
  for x in xs {
    copy.add(x)
  }
  copy
}

func copyNTypes(xs: in List[NType]): List[NType] {
  val copy: List[NType] = newList()
  for x in xs {
    copy.add(x)
  }
  copy
}

/// `name[T1, T2](args)` where `name` is a generic function: the type
/// arguments bind its type parameters in declaration order.
func tryLowerExplicitGenericCall(
  ctx: in Ctx,
  insns: in List[NInsn],
  name: in String,
  targTys: in List[TypeExpr],
  args: in List[CallArg],
  line: in Int,
  wantTask: in Bool,
  retWant: in Option[NType],
): Option[NVal] {
  val key = name + "/" + args.count.toString()
  val selfKey = ctx.curPkg[0] + "." + key
  var useKey = ""
  if ctx.genericFnDefs.containsKey(selfKey) {
    useKey = selfKey
  } else if ctx.genericFnDefs.containsKey(key) {
    useKey = key
  }
  if useKey.length == 0 {
    return None
  }
  val tys: List[NType] = newList()
  for te in targTys {
    tys.add(typeToN(ctx, te))
  }
  val noPre: List[NVal] = newList()
  Some(value = lowerGenericFnCallWith(ctx, insns, useKey, noPre, args, line, wantTask, retWant, tys))
}

/// Call a generic function: map arguments to parameters, infer the
/// type-argument tuple from the argument types, instantiate the
/// function (lowered once per tuple, cached), and emit the call.
/// `preVals` are already-lowered leading arguments (the UFCS receiver).
func isLambdaExpr(e: in Expr): Bool {
  match e.kind {
    case ELambda(_, _) -> true
    case EParen(inner) -> isLambdaExpr(inner)
    case _ -> false
  }
}

/// The closure type parameter `pi` of generic function `fd` takes, under the
/// type arguments bound by the already-lowered arguments before position
/// `pi` (lambda placeholders, typed `NVoid`, bind nothing). None when a type
/// parameter the parameter mentions is still unbound.
func lambdaParamWant(
  ctx: in Ctx,
  fd: in FunctionDecl,
  pi: in Int,
  rawVals: in List[NVal],
  paramNames: in List[String],
  seedNames: in List[String],
  seedTys: in List[NType],
): Option[NType] {
  if pi >= fd.params.count {
    return None
  }
  val boundNames: List[String] = copyStrings(seedNames)
  val boundTys: List[NType] = copyNTypes(seedTys)
  var j = 0
  while j < rawVals.count and j < pi {
    match rawVals[j].ty {
      case NVoid -> ()
      case _ -> unifyTyArg(ctx, fd.params[j].ty, rawVals[j].ty, paramNames, boundNames, boundTys)
    }
    j = j + 1
  }
  if teMentionsUnbound(fd.params[pi].ty, paramNames, boundNames) {
    return None
  }
  typeToNEnvOpt(ctx, fd.params[pi].ty, boundNames, boundTys)
}

/// As `lambdaParamWant`, but binding from every lowered argument (used for
/// a lambda deferred past the arguments after it).
func lambdaParamWantAt(
  ctx: in Ctx,
  fd: in FunctionDecl,
  pi: in Int,
  rawVals: in List[NVal],
  paramNames: in List[String],
  seedNames: in List[String],
  seedTys: in List[NType],
): Option[NType] {
  val boundNames: List[String] = copyStrings(seedNames)
  val boundTys: List[NType] = copyNTypes(seedTys)
  var j = 0
  while j < rawVals.count {
    match rawVals[j].ty {
      case NVoid -> ()
      case _ -> unifyTyArg(ctx, fd.params[j].ty, rawVals[j].ty, paramNames, boundNames, boundTys)
    }
    j = j + 1
  }
  if teMentionsUnbound(fd.params[pi].ty, paramNames, boundNames) {
    return None
  }
  typeToNEnvOpt(ctx, fd.params[pi].ty, boundNames, boundTys)
}

/// Whether `te` names a type parameter from `paramNames` absent from `bound`.
func teMentionsUnbound(te: in TypeExpr, paramNames: in List[String], bound: in List[String]): Bool {
  match te.kind {
    case TRef(path) -> {
      if path.segments.count == 1 {
        val nm = path.segments[0]
        return envIndexOf(paramNames, nm) >= 0 and envIndexOf(bound, nm) < 0
      }
      false
    }
    case TGenericApp(_, targs) -> {
      var i = 0
      while i < targs.count {
        match targs[i] {
          case TAType(inner) -> {
            if teMentionsUnbound(inner, paramNames, bound) {
              return true
            }
          }
          case TAValue(_) -> ()
        }
        i = i + 1
      }
      false
    }
    case TSlice(inner) -> teMentionsUnbound(inner, paramNames, bound)
    case TArray(_, inner) -> teMentionsUnbound(inner, paramNames, bound)
    case TParen(inner) -> teMentionsUnbound(inner, paramNames, bound)
    case TFunction(params, ret) -> {
      var i = 0
      while i < params.count {
        if teMentionsUnbound(params[i], paramNames, bound) {
          return true
        }
        i = i + 1
      }
      teMentionsUnbound(ret, paramNames, bound)
    }
    case _ -> false
  }
}

func lowerGenericFnCall(
  ctx: in Ctx,
  insns: in List[NInsn],
  gkey: in String,
  preVals: in List[NVal],
  args: in List[CallArg],
  line: in Int,
  wantTask: in Bool,
  retWant: in Option[NType],
): NVal {
  val noExplicit: List[NType] = newList()
  lowerGenericFnCallWith(ctx, insns, gkey, preVals, args, line, wantTask, retWant, noExplicit)
}

/// `lowerGenericFnCall` with the call's explicit type arguments
/// (`stay[String, NoEffect](m)`): they bind the function's type parameters in
/// declaration order before any argument or the expected type is consulted.
func lowerGenericFnCallWith(
  ctx: in Ctx,
  insns: in List[NInsn],
  gkey: in String,
  preVals: in List[NVal],
  args: in List[CallArg],
  line: in Int,
  wantTask: in Bool,
  retWant: in Option[NType],
  explicitTys: in List[NType],
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
  val deferredLambdas: List[Int] = newList()
  val deferredLambdaExprs: List[Expr] = newList()
  val fnTyParamNames = genericParamNamesOf(fd.generics)
  val seedNames: List[String] = newList()
  val seedTys: List[NType] = newList()
  if explicitTys.count > 0 {
    if explicitTys.count != fnTyParamNames.count {
      panic(
        "Lyric.LlvmCodegen: generic function '" + fd.name + "' takes " + fnTyParamNames.count.toString() +
          " type argument(s) but the call passes " +
          explicitTys.count.toString()
      )
    }
    var sdi = 0
    while sdi < explicitTys.count {
      seedNames.add(fnTyParamNames[sdi])
      seedTys.add(explicitTys[sdi])
      sdi = sdi + 1
    }
  }
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
        // A parameter the call leaves out takes its default (#7985).
        match fd.params[pi].dflt {
          case Some(dex) -> {
            argSlot.add(pi)
            argExpr.add(dex)
            found = argExpr.count - 1
          }
          case None -> panic(
            "Lyric.LlvmCodegen: no argument bound for parameter '" + fd.params[pi].name +
              "' of generic function '" +
              fd.name +
              "', which has no default"
          )
        }
      }
      val ax = argExpr[found]
      if isLambdaExpr(ax) or isGenericCaseCtorExpr(ctx, ax) {
        // A lambda needs its function type before it can be lowered. Take
        // it from the parameter type under the type arguments the earlier
        // arguments bind (`mapForEach(m, { k, v -> ... })`); only when a
        // later argument is needed is the lambda deferred past it (#7282).
        match lambdaParamWant(ctx, fd, pi, rawVals, fnTyParamNames, seedNames, seedTys) {
          case Some(w) -> rawVals.add(lowerExprExpecting(ctx, insns, ax, w))
          case None -> {
            deferredLambdas.add(pi)
            deferredLambdaExprs.add(ax)
            rawVals.add(NVal(ty = NVoid, value = NUndef(ty = NVoid)))
          }
        }
      } else {
        rawVals.add(lowerExpr(ctx, insns, ax))
      }
    }
    pi = pi + 1
  }
  // Deferred lambdas resolve in passes: one lowered lambda can bind a type
  // parameter another lambda's type needs.
  val pending: List[Int] = newList()
  var dli = 0
  while dli < deferredLambdas.count {
    pending.add(dli)
    dli = dli + 1
  }
  var progressed = true
  var retBound = false
  while pending.count > 0 and (progressed or not retBound) {
    if not progressed {
      // Nothing more binds from the arguments: let the expected type of the
      // call bind the parameters only its return type mentions, then retry.
      retBound = true
      match retWant {
        case Some(w) -> match fd.ret {
          case Some(rte) -> unifyTyArg(ctx, rte, w, fnTyParamNames, seedNames, seedTys)
          case None -> ()
        }
        case None -> ()
      }
    }
    progressed = false
    val still: List[Int] = newList()
    var pk = 0
    while pk < pending.count {
      val di = pending[pk]
      val dpi = deferredLambdas[di]
      match lambdaParamWantAt(ctx, fd, dpi, rawVals, fnTyParamNames, seedNames, seedTys) {
        case Some(w) -> {
          rawVals[dpi] = lowerExprExpecting(ctx, insns, deferredLambdaExprs[di], w)
          progressed = true
        }
        case None -> still.add(di)
      }
      pk = pk + 1
    }
    pending.clear()
    var sk = 0
    while sk < still.count {
      pending.add(still[sk])
      sk = sk + 1
    }
  }
  if pending.count > 0 {
    val dpi = deferredLambdas[pending[0]]
    panic(
      "Lyric.LlvmCodegen: cannot infer the type of the lambda or case construction passed as parameter '" +
        fd.params[dpi].name +
        "' of generic function '" +
        fd.name +
        "'; annotate the lambda's parameters or bind it to a typed val"
    )
  }
  // Infer type args.
  val paramNames = fnTyParamNames
  val boundNames: List[String] = copyStrings(seedNames)
  val boundTys: List[NType] = copyNTypes(seedTys)
  var pi2 = 0
  while pi2 < nParams {
    unifyTyArg(ctx, fd.params[pi2].ty, rawVals[pi2].ty, paramNames, boundNames, boundTys)
    pi2 = pi2 + 1
  }
  // A type parameter that appears only in the return type (`plistEmpty[T]():
  // PersistentList[T]`) binds from the expected type at the call site; the
  // arguments stay authoritative for every parameter they already bound.
  if boundNames.count < paramNames.count {
    match retWant {
      case Some(w) -> match fd.ret {
        case Some(rte) -> unifyTyArg(ctx, rte, w, paramNames, boundNames, boundTys)
        case None -> ()
      }
      case None -> ()
    }
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
        case None -> panic(
          "Lyric.LlvmCodegen: cannot lower parameter type of generic function '" + fd.name +
            "' for --target native"
        )
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
          case None -> panic(
            "Lyric.LlvmCodegen: cannot lower return type of generic function '" + fd.name +
              "' for --target native"
          )
        }
      }
      case None -> {
      }
    }
    ctx.fnInstCache.add(instIr, NFnInst(irName = instIr, paramTys = paramTys, retTy = instRet, isAsync = fd.isAsync))
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
  if inst.isAsync {
    return emitAsyncCall(ctx, insns, inst.irName, callArgs, inst.retTy, wantTask)
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
  addArcHeader(implFields)
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
  val obj = emitHeapAlloc(ctx, insns, implTy, dtorName)
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
      fromTy = NFnPtr(params = fnParamTys, ret = sig.retTy),
      value = NGlobal(name = bodyFnName),
      toTy = NPtr(pointee = NI8)
    )
  )
  val fnSlot = freshTmp(ctx)
  val fArgs: List[NArg] = newList()
  fArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  fArgs.add(NArg(ty = NI32, value = NLitInt(v = closureFnSlot, ty = NI32)))
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
    cArgs.add(NArg(ty = NI32, value = NLitInt(v = (closureCaptureBase + si).toLong(), ty = NI32)))
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
  // The lambda body lowers inside the generic instantiation that contains it,
  // so a type parameter it names (`val r: View[A] = ...`) resolves the same.
  var tei = 0
  while tei < modCtx.fnTyEnvNames.count {
    ctx.fnTyEnvNames.add(modCtx.fnTyEnvNames[tei])
    ctx.fnTyEnvTys.add(modCtx.fnTyEnvTys[tei])
    tei = tei + 1
  }
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
    gArgs.add(NArg(ty = NI32, value = NLitInt(v = (closureCaptureBase + ci).toLong(), ty = NI32)))
    bodyInsns.add(NGEP(dest = capPtr, ty = structTy, ptr = NLocal(name = "self.env"), indices = gArgs))
    val capVal = freshTmp(ctx)
    bodyInsns.add(NLoad(dest = capVal, ty = capTys[ci], ptr = NLocal(name = capPtr)))
    val slot = free[ci] + ".cap." + freshTmp(ctx)
    ctx.allocas.add(NAlloca(dest = slot, ty = capTys[ci]))
    bodyInsns.add(NStore(ty = capTys[ci], value = NLocal(name = capVal), ptr = NLocal(name = slot)))
    ctx.varSlots.add(free[ci], slot)
    ctx.varTypes.add(free[ci], capTys[ci])
    // #6237: propagate the enclosing function's char-ness for a captured
    // variable into the closure body's own ctx (varIsChar is per-function
    // state — freshFnCtx starts it empty, unlike varTypes/varSlots which
    // are seeded here from the capture itself).
    val capIsChar = match mapGet(modCtx.varIsChar, free[ci]) { case Some(v) -> v; case None -> false }
    ctx.varIsChar.add(free[ci], capIsChar)
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
    val pnIsChar = match lambdaParams[pi].ty { case Some(te) -> isCharTypeExpr(te); case None -> false }
    ctx.varIsChar.add(pn, pnIsChar)
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
      gArgs.add(NArg(ty = NI32, value = NLitInt(v = (closureCaptureBase + i).toLong(), ty = NI32)))
      body.add(NGEP(dest = fieldPtr, ty = structTy, ptr = NLocal(name = "obj"), indices = gArgs))
      val fieldVal = freshTmp(ctx)
      body.add(NLoad(dest = fieldVal, ty = capTys[i], ptr = NLocal(name = fieldPtr)))
      // Weak-dispatching release: a captured `NativeWeak[T]` field drops its
      // weak count, everything else its strong count (#5504).
      emitRelease(ctx, body, NVal(ty = capTys[i], value = NLocal(name = fieldVal)))
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
    case None -> panic(
      "Lyric.LlvmCodegen: NativeWeak.upgrade() needs a generic union named 'Option' (with cases Some/None) in the import closure"
    )
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
  gArgs.add(NArg(ty = NI32, value = NLitInt(v = closureFnSlot, ty = NI32)))
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
      toTy = NFnPtr(params = fnParamTys, ret = sig.retTy)
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
func coerceUnlessDiverged(
  ctx: in Ctx, insns: in List[NInsn], v: in NVal, want: in NType, atSpan: in Option[Span] = None
): NVal {
  if isVoidNType(v.ty) and not isVoidNType(want) {
    return v
  }
  coerceTo(ctx, insns, v, want, atSpan)
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
      return coerceUnlessDiverged(
        ctx,
        insns,
        lowerIf(ctx, insns, cond, thenBranch, elseBranch, w1),
        want,
        Some(value = e.span)
      )
    }
    case EMatch(scrutinee, arms) -> {
      val w2: Option[NType] = Some(value = want)
      return coerceUnlessDiverged(
        ctx,
        insns,
        lowerMatch(ctx, insns, scrutinee, arms, e.span.startPos.line, w2),
        want,
        Some(value = e.span)
      )
    }
    case EBlock(block) -> {
      val w3: Option[NType] = Some(value = want)
      return coerceUnlessDiverged(ctx, insns, lowerBlockValueW(ctx, insns, block, w3), want, Some(value = e.span))
    }
    case EParen(inner) -> return lowerExprExpecting(ctx, insns, inner, want)
    case ETuple(exprs) -> {
      match tupleConstructForExpected(ctx, insns, exprs, want) {
        case Some(v) -> return v
        case None -> {
        }
      }
    }
    case ECall(_, _) -> {
      ctx.pendingCallRetWant.clear()
      ctx.pendingCallRetWant.add(want)
      val callV = lowerExpr(ctx, insns, e)
      ctx.pendingCallRetWant.clear()
      return coerceUnlessDiverged(ctx, insns, callV, want, Some(value = e.span))
    }
    case _ -> {
    }
  }
  coerceUnlessDiverged(ctx, insns, lowerExpr(ctx, insns, e), want, Some(value = e.span))
}

/// A tuple literal against an expected tuple type of the same arity: each
/// component is lowered against its expected component type, so a `None`,
/// `Some(...)`, `[]` or lambda component gets its type from the tuple type
/// (#7824) and the tuple is built at exactly `want`'s layout.  Lowering the
/// components bare would leave a payload-free case with no type to take.
func tupleConstructForExpected(ctx: in Ctx, insns: in List[NInsn], exprs: in List[Expr], want: in NType): Option[NVal] {
  val ri = match recInfoOfType(ctx, want) { case Some(r) -> r; case None -> return None }
  if not Str.startsWith(ri.irName, "__tuple<") or ri.fieldTys.count != exprs.count {
    return None
  }
  val vals: List[NVal] = newList()
  var i = 0
  while i < exprs.count {
    match ri.fieldTys[i] {
      case NVoid -> vals.add(lowerExpr(ctx, insns, exprs[i]))
      case fieldTy -> vals.add(lowerExprExpecting(ctx, insns, exprs[i], fieldTy))
    }
    i = i + 1
  }
  Some(value = lowerRecordConstructVals(ctx, insns, ri, vals))
}

/// The (caseName, args) of `e` when it is a union-case construction
/// whose case belongs to the expected union instantiation; constructs
/// it against the concrete case field types.
func caseConstructForExpected(ctx: in Ctx, insns: in List[NInsn], e: in Expr, want: in NType): Option[NVal] {
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
      idxArgs.add(NArg(ty = NI32, value = NLitInt(v = (arcHeaderSlots + i).toLong(), ty = NI32)))
      body.add(NGEP(dest = fieldPtr, ty = structTy, ptr = NLocal(name = "obj"), indices = idxArgs))
      val fieldVal = freshTmp(ctx)
      body.add(NLoad(dest = fieldVal, ty = ri.fieldTys[i], ptr = NLocal(name = fieldPtr)))
      // Weak-dispatching release: a `NativeWeak[T]` field drops its weak
      // count, everything else its strong count (#5504).
      emitRelease(ctx, body, NVal(ty = ri.fieldTys[i], value = NLocal(name = fieldVal)))
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
  discArgs.add(NArg(ty = NI32, value = NLitInt(v = unionDiscSlot, ty = NI32)))
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
      switchCases.add(NSwitchCase(matchVal = ci.toLong(), label = label))
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
      pArgs.add(NArg(ty = NI32, value = NLitInt(v = unionPayloadSlot, ty = NI32)))
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
          fArgs.add(NArg(ty = NI32, value = NLitInt(v = fi.toLong(), ty = NI32)))
          body.add(NGEP(dest = fieldPtr, ty = caseTy, ptr = NLocal(name = casePtr), indices = fArgs))
          val fieldVal = freshTmp(ctx)
          body.add(NLoad(dest = fieldVal, ty = ui.cases[ci2].fieldTys[fi], ptr = NLocal(name = fieldPtr)))
          // Weak-dispatching release: a `NativeWeak[T]` case field drops its
          // weak count, everything else its strong count (#5504).
          emitRelease(ctx, body, NVal(ty = ui.cases[ci2].fieldTys[fi], value = NLocal(name = fieldVal)))
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

// ── Union equality ──────────────────────────────────────────────────────────
/// The registered union a heap pointer type points at, if any.
func unionInfoOfNType(ctx: in Ctx, t: in NType): Option[NUnionInfo] {
  val name = match t {
    case NPtr(pointee) -> match pointee { case NStruct(n, _) -> n; case _ -> return None }
    case NStruct(n, _) -> n
    case _ -> return None
  }
  for k in mapKeys(ctx.unionDefs) {
    match mapGet(ctx.unionDefs, k) {
      case Some(ui) -> {
        if ui.irName == name {
          // A pointer to an inline union is a raw `NativePtr`; a bare struct
          // is a union only when inline.
          val isPtr = match t { case NPtr(_) -> true; case _ -> false }
          if isPtr == ui.inline {
            return None
          }
          return Some(value = ui)
        }
      }
      case None -> ()
    }
  }
  None
}

func unionEqName(ui: in NUnionInfo): String {
  ui.irName + ".eq"
}

/// `a == b` (or `!=`) on two values of union `ui`, through its synthesised
/// equality function.
func lowerUnionEq(
  ctx: in Ctx, insns: in List[NInsn], ui: in NUnionInfo, a0: in NVal, b0: in NVal, negate: in Bool
): NVal {
  val fnName = ensureUnionEq(ctx, ui)
  // Inline unions compare through stack copies.
  val a = if ui.inline { inlineUnionAddr(ctx, insns, a0) } else { a0 }
  val b = if ui.inline { inlineUnionAddr(ctx, insns, b0) } else { b0 }
  val ra = freshTmp(ctx)
  insns.add(NBitcast(dest = ra, fromTy = a.ty, value = a.value, toTy = NPtr(pointee = NI8)))
  val rb = freshTmp(ctx)
  insns.add(NBitcast(dest = rb, fromTy = b.ty, value = b.value, toTy = NPtr(pointee = NI8)))
  val args: List[NArg] = newList()
  args.add(NArg(ty = NPtr(pointee = NI8), value = NLocal(name = ra)))
  args.add(NArg(ty = NPtr(pointee = NI8), value = NLocal(name = rb)))
  val eq = freshTmp(ctx)
  insns.add(NCall(dest = eq, retTy = NI1, fn = NGlobal(name = fnName), args = args))
  if not negate {
    return NVal(ty = NI1, value = NLocal(name = eq))
  }
  val ne = freshTmp(ctx)
  insns.add(NXor(dest = ne, ty = NI1, a = NLocal(name = eq), b = NLitInt(v = 1i64, ty = NI1)))
  NVal(ty = NI1, value = NLocal(name = ne))
}

/// The name of union `ui`'s equality function, synthesising it into the
/// module on first use.  The name is registered before the body is built,
/// so a union whose payload holds the same union refers to it recursively.
func ensureUnionEq(ctx: in Ctx, ui: in NUnionInfo): String {
  val fnName = unionEqName(ui)
  if not ctx.unionEqFns.containsKey(ui.irName) {
    ctx.unionEqFns.add(ui.irName, true)
    ctx.moduleFns.add(synthUnionEq(ctx, ui))
  }
  fnName
}

/// `i1 Union.eq(i8* a, i8* b)`: the same instance, or the same case with
/// each payload field equal by its own type's `==` (a `String` by its text,
/// a union structurally, a float by IEEE rules, any other reference by
/// identity).
func synthUnionEq(mctx: in Ctx, ui: in NUnionInfo): NFunc {
  // A function-level view of the module ctx: it owns the stack slots an inline
  // union field's comparison spills into, hoisted to the entry block below.
  val ctx = freshFnCtx(mctx, mctx.mainPkg, NI1)
  val body: List[NInsn] = newList()
  body.add(NLabel(name = "entry"))
  val structTy = if ui.inline {
    unionPtrType(ui)
  } else {
    match unionPtrType(ui) {
      case NPtr(pointee) -> pointee
      case _ -> panic("unreachable")
    }
  }
  val objTy = NPtr(pointee = structTy)
  val trueL = "eq.true"
  val falseL = "eq.false"
  val sameL = "eq.cmp"
  // No same-instance shortcut: equality is structural (IEEE) for heap and inline
  // unions alike, so `x == x` with a NaN payload is false for both.
  body.add(NBr(label = sameL))
  body.add(NLabel(name = sameL))
  body.add(NBitcast(dest = "oa", fromTy = NPtr(pointee = NI8), value = NLocal(name = "ra"), toTy = objTy))
  body.add(NBitcast(dest = "ob", fromTy = NPtr(pointee = NI8), value = NLocal(name = "rb"), toTy = objTy))
  val discA = loadUnionDisc(ctx, body, ui, structTy, "oa")
  val discB = loadUnionDisc(ctx, body, ui, structTy, "ob")
  val discEq = freshTmp(ctx)
  body.add(NICmp(dest = discEq, pred = IEq, ty = NI32, a = NLocal(name = discA), b = NLocal(name = discB)))
  val switchL = "eq.switch"
  body.add(NCondBr(cond = NLocal(name = discEq), thenLabel = switchL, elseLabel = falseL))
  body.add(NLabel(name = switchL))
  val switchCases: List[NSwitchCase] = newList()
  var ci = 0
  while ci < ui.cases.count {
    switchCases.add(NSwitchCase(matchVal = ci.toLong(), label = "eq.case." + ci.toString()))
    ci = ci + 1
  }
  body.add(NSwitch(ty = NI32, scrutinee = NLocal(name = discA), defaultLabel = trueL, cases = switchCases))
  var cj = 0
  while cj < ui.cases.count {
    body.add(NLabel(name = "eq.case." + cj.toString()))
    val caseTy = casePayloadStructType(ui, ui.cases[cj])
    val hasFields = ui.cases[cj].fieldTys.count > 0
    val pa = if hasFields { loadCasePayloadPtr(ctx, body, ui, structTy, caseTy, "oa") } else { "" }
    val pb = if hasFields { loadCasePayloadPtr(ctx, body, ui, structTy, caseTy, "ob") } else { "" }
    var fi = 0
    while fi < ui.cases[cj].fieldTys.count {
      val fty = ui.cases[cj].fieldTys[fi]
      if not isVoidNType(fty) {
        val va = loadCaseField(ctx, body, caseTy, pa, fi, fty)
        val vb = loadCaseField(ctx, body, caseTy, pb, fi, fty)
        val eq = emitValueEqN(ctx, body, fty, va, vb)
        val nextL = "eq.case." + cj.toString() + ".f" + fi.toString()
        body.add(NCondBr(cond = NLocal(name = eq), thenLabel = nextL, elseLabel = falseL))
        body.add(NLabel(name = nextL))
      }
      fi = fi + 1
    }
    body.add(NBr(label = trueL))
    cj = cj + 1
  }
  body.add(NLabel(name = trueL))
  body.add(NRet(ty = NI1, value = NLitInt(v = 1i64, ty = NI1)))
  body.add(NLabel(name = falseL))
  body.add(NRet(ty = NI1, value = NLitInt(v = 0i64, ty = NI1)))
  val params: List[NParam] = newList()
  params.add(NParam(name = "ra", ty = NPtr(pointee = NI8)))
  params.add(NParam(name = "rb", ty = NPtr(pointee = NI8)))
  val attrs: List[String] = newList()
  val finalBody: List[NInsn] = newList()
  finalBody.add(NLabel(name = "entry"))
  appendInsns(finalBody, ctx.allocas)
  var bi = 1
  while bi < body.count {
    finalBody.add(body[bi])
    bi = bi + 1
  }
  NFunc(
    name = unionEqName(ui),
    params = params,
    retTy = NI1,
    isPublic = false,
    isExtern = false,
    body = finalBody,
    attributes = attrs
  )
}

func loadUnionDisc(ctx: in Ctx, body: in List[NInsn], ui: in NUnionInfo, structTy: in NType, obj: in String): String {
  val discPtr = freshTmp(ctx)
  val args: List[NArg] = newList()
  args.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  args.add(NArg(ty = NI32, value = NLitInt(v = unionDiscIdx(ui), ty = NI32)))
  body.add(NGEP(dest = discPtr, ty = structTy, ptr = NLocal(name = obj), indices = args))
  val disc = freshTmp(ctx)
  body.add(NLoad(dest = disc, ty = NI32, ptr = NLocal(name = discPtr)))
  disc
}

func loadCasePayloadPtr(
  ctx: in Ctx,
  body: in List[NInsn],
  ui: in NUnionInfo,
  structTy: in NType,
  caseTy: in NType,
  obj: in String,
): String {
  val payloadPtr = freshTmp(ctx)
  val args: List[NArg] = newList()
  args.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  args.add(NArg(ty = NI32, value = NLitInt(v = unionPayloadIdx(ui), ty = NI32)))
  body.add(NGEP(dest = payloadPtr, ty = structTy, ptr = NLocal(name = obj), indices = args))
  val casePtr = freshTmp(ctx)
  body.add(
    NBitcast(
      dest = casePtr,
      fromTy = NPtr(pointee = NArray(elem = NI64, size = ui.payloadWords)),
      value = NLocal(name = payloadPtr),
      toTy = NPtr(pointee = caseTy)
    )
  )
  casePtr
}

func loadCaseField(
  ctx: in Ctx, body: in List[NInsn], caseTy: in NType, casePtr: in String, fi: in Int, fty: in NType
): String {
  val fieldPtr = freshTmp(ctx)
  val args: List[NArg] = newList()
  args.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  args.add(NArg(ty = NI32, value = NLitInt(v = fi.toLong(), ty = NI32)))
  body.add(NGEP(dest = fieldPtr, ty = caseTy, ptr = NLocal(name = casePtr), indices = args))
  val v = freshTmp(ctx)
  body.add(NLoad(dest = v, ty = fty, ptr = NLocal(name = fieldPtr)))
  v
}

/// An `i1` local holding `a == b` for two by-value record values: every field
/// equal by its own type's `==` (a struct field recursively).
func emitStructEq(ctx: in Ctx, body: in List[NInsn], t: in NType, a: in NValue, b: in NValue): String {
  val ri = match mapGet(ctx.recordDefs, byValueRecName(t)) {
    case Some(r) -> r
    case None -> panic(
      "Lyric.LlvmCodegen: internal — equality on unregistered struct '" + byValueRecName(t) + "'"
    )
  }
  var acc = ""
  var fi = 0
  while fi < ri.fieldTys.count {
    if not isVoidNType(ri.fieldTys[fi]) {
      val ea = freshTmp(ctx)
      body.add(NExtractValue(dest = ea, aggTy = t, agg = a, index = fi))
      val eb = freshTmp(ctx)
      body.add(NExtractValue(dest = eb, aggTy = t, agg = b, index = fi))
      val eq = emitValueEqN(ctx, body, ri.fieldTys[fi], ea, eb)
      if acc.length == 0 {
        acc = eq
      } else {
        val both = freshTmp(ctx)
        body.add(NAnd(dest = both, ty = NI1, a = NLocal(name = acc), b = NLocal(name = eq)))
        acc = both
      }
    }
    fi = fi + 1
  }
  if acc.length == 0 {
    val tru = freshTmp(ctx)
    body.add(NICmp(dest = tru, pred = IEq, ty = NI1, a = NLitInt(v = 1i64, ty = NI1), b = NLitInt(v = 1i64, ty = NI1)))
    acc = tru
  }
  acc
}

/// An `i1` local holding `a == b` for two inline arrays `[n x el]`: every
/// element pair equal by the element type's `==`.
func emitArrayEq(
  ctx: in Ctx, body: in List[NInsn], t: in NType, el: in NType, n: in Int, a: in String, b: in String
): String {
  var acc = ""
  var i = 0
  while i < n {
    val ea = freshTmp(ctx)
    body.add(NExtractValue(dest = ea, aggTy = t, agg = NLocal(name = a), index = i))
    val eb = freshTmp(ctx)
    body.add(NExtractValue(dest = eb, aggTy = t, agg = NLocal(name = b), index = i))
    val eq = emitValueEqN(ctx, body, el, ea, eb)
    if acc.length == 0 {
      acc = eq
    } else {
      val both = freshTmp(ctx)
      body.add(NAnd(dest = both, ty = NI1, a = NLocal(name = acc), b = NLocal(name = eq)))
      acc = both
    }
    i = i + 1
  }
  if acc.length == 0 {
    val tru = freshTmp(ctx)
    body.add(NICmp(dest = tru, pred = IEq, ty = NI1, a = NLitInt(v = 1i64, ty = NI1), b = NLitInt(v = 1i64, ty = NI1)))
    acc = tru
  }
  acc
}

/// An `i1` local holding `a == b` for two values of IR type `t`, by the
/// rules `synthUnionEq` documents.
func emitValueEqN(ctx: in Ctx, body: in List[NInsn], t: in NType, a: in String, b: in String): String {
  val dest = freshTmp(ctx)
  if isStringNType(t) {
    val r = freshTmp(ctx)
    val args: List[NArg] = newList()
    args.add(NArg(ty = t, value = NLocal(name = a)))
    args.add(NArg(ty = t, value = NLocal(name = b)))
    body.add(NCall(dest = r, retTy = NI32, fn = NGlobal(name = "lyric_string_eq"), args = args))
    body.add(NICmp(dest = dest, pred = INe, ty = NI32, a = NLocal(name = r), b = NLitInt(v = 0i64, ty = NI32)))
    return dest
  }
  match t {
    case NDouble | NFloat -> {
      body.add(NFCmp(dest = dest, pred = FOeq, ty = t, a = NLocal(name = a), b = NLocal(name = b)))
      return dest
    }
    case _ -> ()
  }
  match t {
    // An inline `array[N, T]` (D167) is equal when every element is, each by
    // its own type's rules (a nested array element by element).
    case NArray(el, n) -> return emitArrayEq(ctx, body, t, el, n, a, b)
    case _ -> ()
  }
  match unionInfoOfNType(ctx, t) {
    case Some(inner) -> {
      val fnName = ensureUnionEq(ctx, inner)
      // An inline union compares through stack copies of both values.
      val pa = if inner.inline {
        inlineUnionAddr(ctx, body, NVal(ty = t, value = NLocal(name = a)))
      } else {
        NVal(ty = t, value = NLocal(name = a))
      }
      val pb = if inner.inline {
        inlineUnionAddr(ctx, body, NVal(ty = t, value = NLocal(name = b)))
      } else {
        NVal(ty = t, value = NLocal(name = b))
      }
      val ra = freshTmp(ctx)
      body.add(NBitcast(dest = ra, fromTy = pa.ty, value = pa.value, toTy = NPtr(pointee = NI8)))
      val rb = freshTmp(ctx)
      body.add(NBitcast(dest = rb, fromTy = pb.ty, value = pb.value, toTy = NPtr(pointee = NI8)))
      val args: List[NArg] = newList()
      args.add(NArg(ty = NPtr(pointee = NI8), value = NLocal(name = ra)))
      args.add(NArg(ty = NPtr(pointee = NI8), value = NLocal(name = rb)))
      body.add(NCall(dest = dest, retTy = NI1, fn = NGlobal(name = fnName), args = args))
      return dest
    }
    case None -> ()
  }
  if isByValueStructNType(t) {
    return emitStructEq(ctx, body, t, NLocal(name = a), NLocal(name = b))
  }
  body.add(NICmp(dest = dest, pred = IEq, ty = t, a = NLocal(name = a), b = NLocal(name = b)))
  dest
}

// ── Construction ─────────────────────────────────────────────────────────────
/// Allocate a heap object and initialise its ARC header (rc = 1 per
/// Rule 1; dtor null when the type owns no refs).
func emitHeapAlloc(ctx: in Ctx, insns: in List[NInsn], objTy: in NType, dtorName: in String): String {
  val allocStructTy = match objTy { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  val size = freshTmp(ctx)
  insns.add(NSizeOf(dest = size, ty = allocStructTy))
  val raw = freshTmp(ctx)
  insns.add(
    NCall(
      dest = raw,
      retTy = NPtr(pointee = NI8),
      fn = NGlobal(name = "lyric_alloc"),
      args = arg1(NI64, NLocal(name = size))
    )
  )
  val obj = freshTmp(ctx)
  insns.add(NBitcast(dest = obj, fromTy = NPtr(pointee = NI8), value = NLocal(name = raw), toTy = objTy))
  val structTy = match objTy { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  val rcPtr = freshTmp(ctx)
  val rcArgs: List[NArg] = newList()
  rcArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  rcArgs.add(NArg(ty = NI32, value = NLitInt(v = arcRcSlot, ty = NI32)))
  insns.add(NGEP(dest = rcPtr, ty = structTy, ptr = NLocal(name = obj), indices = rcArgs))
  insns.add(NStore(ty = NI32, value = NLitInt(v = 1i64, ty = NI32), ptr = NLocal(name = rcPtr)))
  val dtorPtr = freshTmp(ctx)
  val dtorArgs: List[NArg] = newList()
  dtorArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  dtorArgs.add(NArg(ty = NI32, value = NLitInt(v = arcDtorSlot, ty = NI32)))
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
        fromTy = NFnPtr(params = fnParams, ret = NVoid),
        value = NGlobal(name = dtorName),
        toTy = NPtr(pointee = NI8)
      )
    )
    insns.add(NStore(ty = NPtr(pointee = NI8), value = NLocal(name = cast), ptr = NLocal(name = dtorPtr)))
  }
  // Seed the weak count to 1 (the implicit weak held while strong refs live).
  // Set through the runtime helper so the weak-count protocol (#5504) stays
  // defined in one place, lyric_weak.c.
  insns.add(NCallVoid(fn = NGlobal(name = "lyric_weak_init"), args = arg1(NPtr(pointee = NI8), NLocal(name = raw))))
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

/// Build a by-value record: an `insertvalue` chain from `undef`, with no
/// allocation and no ARC.  A Unit field's placeholder byte stays undef.
func buildByValueRecord(ctx: in Ctx, insns: in List[NInsn], ri: in NRecInfo, vals: in List[NVal]): NVal {
  val aggTy = recPtrType(ri)
  var cur: NValue = NUndef(ty = aggTy)
  var fi = 0
  while fi < vals.count {
    if isVoidNType(ri.fieldTys[fi]) {
      fi = fi + 1
      continue
    }
    val dest = freshTmp(ctx)
    insns.add(
      NInsertValue(dest = dest, aggTy = aggTy, agg = cur, elemTy = ri.fieldTys[fi], elem = vals[fi].value, index = fi)
    )
    cur = NLocal(name = dest)
    fi = fi + 1
  }
  NVal(ty = aggTy, value = cur)
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
  if ri.byValue {
    return buildByValueRecord(ctx, insns, ri, vals)
  }
  val objTy = recPtrType(ri)
  val structTy = match objTy { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  val dtorName = if recHasRefFields(ri) { recDtorName(ri) } else { "" }
  val obj = emitHeapAlloc(ctx, insns, objTy, dtorName)
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
    fArgs.add(NArg(ty = NI32, value = NLitInt(v = (arcHeaderSlots + fi).toLong(), ty = NI32)))
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
  // An inline union is built in a hoisted stack slot and loaded as a value:
  // no allocation, no ARC header.
  val structTy = if ui.inline {
    objTy
  } else {
    match objTy {
      case NPtr(pointee) -> pointee
      case _ -> panic("unreachable")
    }
  }
  val dtorName = if unionHasRefFields(ui) { unionDtorName(ui) } else { "" }
  var obj = ""
  if ui.inline {
    obj = "iu.slot." + freshTmp(ctx)
    ctx.allocas.add(NAlloca(dest = obj, ty = structTy))
  } else {
    obj = emitHeapAlloc(ctx, insns, objTy, dtorName)
  }
  val discPtr = freshTmp(ctx)
  val dArgs: List[NArg] = newList()
  dArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  dArgs.add(NArg(ty = NI32, value = NLitInt(v = unionDiscIdx(ui), ty = NI32)))
  insns.add(NGEP(dest = discPtr, ty = structTy, ptr = NLocal(name = obj), indices = dArgs))
  insns.add(NStore(ty = NI32, value = NLitInt(v = caseIdx.toLong(), ty = NI32), ptr = NLocal(name = discPtr)))
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
      fArgs.add(NArg(ty = NI32, value = NLitInt(v = fi.toLong(), ty = NI32)))
      insns.add(NGEP(dest = fieldPtr, ty = caseTy, ptr = NLocal(name = casePtr), indices = fArgs))
      insns.add(NStore(ty = ci.fieldTys[fi], value = vals[fi].value, ptr = NLocal(name = fieldPtr)))
      fi = fi + 1
    }
  }
  if ui.inline {
    val loaded = freshTmp(ctx)
    insns.add(NLoad(dest = loaded, ty = structTy, ptr = NLocal(name = obj)))
    return NVal(ty = structTy, value = NLocal(name = loaded))
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
  pArgs.add(NArg(ty = NI32, value = NLitInt(v = unionPayloadIdx(ui), ty = NI32)))
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
    val bad = distinctOutOfRange(ctx, insns, di, v)
    val trapL = freshLabel(ctx, "range.trap")
    val okL = freshLabel(ctx, "range.ok")
    insns.add(NCondBr(cond = bad, thenLabel = trapL, elseLabel = okL))
    insns.add(NLabel(name = trapL))
    emitPanicRaw(ctx, insns, distinctRangeMessage(name, "from", di), line)
    insns.add(NBr(label = okL))
    insns.add(NLabel(name = okL))
  }
  v
}

/// The same text the managed targets raise (language reference §2.3).
func distinctRangeMessage(name: in String, method: in String, di: in NDistinctInfo): String {
  val dot = lastDotIndex(name)
  val short = if dot >= 0 { Str.substring(name, dot + 1, name.length - dot - 1) } else { name }
  short + "." + method + ": value out of range " + di.boundsText
}

// A floating-point range bound as the managed targets name it in the
// violation message: the bound as written, an integer bound without a
// fractional part.
func floatBoundText(b: in LiteralBound): String {
  if b.isFloat {
    b.d.toString()
  } else {
    b.l.toString()
  }
}

/// An `i1` that is true when `v` lies outside `di`'s bounds.
func distinctOutOfRange(ctx: in Ctx, insns: in List[NInsn], di: in NDistinctInfo, v: in NVal): NValue {
  if di.isFloat {
    val geLo = freshTmp(ctx)
    insns.add(
      NFCmp(dest = geLo, pred = FOge, ty = di.underlying, a = v.value, b = NLitFloat(v = di.loF, ty = di.underlying))
    )
    val inHi = freshTmp(ctx)
    val hiPred = if di.hiExclusive { FOlt } else { FOle }
    insns.add(
      NFCmp(dest = inHi, pred = hiPred, ty = di.underlying, a = v.value, b = NLitFloat(v = di.hiF, ty = di.underlying))
    )
    val inRange = freshTmp(ctx)
    insns.add(NAnd(dest = inRange, ty = NI1, a = NLocal(name = geLo), b = NLocal(name = inHi)))
    val bad = freshTmp(ctx)
    insns.add(NXor(dest = bad, ty = NI1, a = NLocal(name = inRange), b = NLitInt(v = 1i64, ty = NI1)))
    return NLocal(name = bad)
  }
  val ltPred = if di.isUnsigned { IUlt } else { ISlt }
  val gtPred = if di.isUnsigned { IUgt } else { ISgt }
  val loCmp = freshTmp(ctx)
  insns.add(
    NICmp(dest = loCmp, pred = ltPred, ty = di.underlying, a = v.value, b = NLitInt(v = di.lo, ty = di.underlying))
  )
  val hiCmp = freshTmp(ctx)
  insns.add(
    NICmp(dest = hiCmp, pred = gtPred, ty = di.underlying, a = v.value, b = NLitInt(v = di.hi, ty = di.underlying))
  )
  val bad = freshTmp(ctx)
  insns.add(NOr(dest = bad, ty = NI1, a = NLocal(name = loCmp), b = NLocal(name = hiCmp)))
  NLocal(name = bad)
}

/// `T.tryFrom(x)`: `Ok(x)` when `x` is in range, otherwise
/// `Err("<T>.tryFrom: value out of range [lo, hi]")` as on the managed targets, as `Result[T, String]`.
/// Each arm is lowered against the expected `Result` type so the generic
/// cases instantiate with both type arguments known.
func lowerDistinctTryFrom(
  ctx: in Ctx,
  insns: in List[NInsn],
  name: in String,
  di: in NDistinctInfo,
  args: in List[CallArg],
  line: in Int,
): NVal {
  if args.count != 1 {
    panic("Lyric.LlvmCodegen: '" + name + ".tryFrom' takes exactly one argument")
  }
  val sp = callArgSpan(args[0])
  val v = coerceTo(ctx, insns, lowerPositionalArg(ctx, insns, args, 0), di.underlying)
  val tmp = "__tryfrom_" + freshTmp(ctx)
  bindLocal(ctx, insns, tmp, v)
  val tyArgs: List[TypeArg] = newList()
  tyArgs.add(TAType(ty = TypeExpr(kind = TRef(path = dottedPath(name, sp)), span = sp)))
  tyArgs.add(TAType(ty = TypeExpr(kind = TRef(path = dottedPath("String", sp)), span = sp)))
  val want = typeToN(ctx, TypeExpr(kind = TGenericApp(head = dottedPath("Result", sp), args = tyArgs), span = sp))
  val okCall = caseCallExpr("Ok", Expr(kind = EPath(path = dottedPath(tmp, sp)), span = sp), sp)
  if not di.hasRange {
    return lowerExprExpecting(ctx, insns, okCall, want)
  }
  val bad = distinctOutOfRange(ctx, insns, di, loadLocal(ctx, insns, tmp))
  val errL = freshLabel(ctx, "tryfrom.err")
  val okL = freshLabel(ctx, "tryfrom.ok")
  val joinL = freshLabel(ctx, "tryfrom.join")
  val slot = "tryfrom." + freshTmp(ctx)
  ctx.allocas.add(NAlloca(dest = slot, ty = want))
  insns.add(NCondBr(cond = bad, thenLabel = errL, elseLabel = okL))
  insns.add(NLabel(name = errL))
  val msg = Expr(kind = ELiteral(lit = LString(text = distinctRangeMessage(name, "tryFrom", di))), span = sp)
  val errV = lowerExprExpecting(ctx, insns, caseCallExpr("Err", msg, sp), want)
  // Ownership moves into the join slot; the joined value is the one temp.
  ensureOwned(ctx, insns, errV)
  insns.add(NStore(ty = want, value = errV.value, ptr = NLocal(name = slot)))
  insns.add(NBr(label = joinL))
  insns.add(NLabel(name = okL))
  val okV = lowerExprExpecting(ctx, insns, okCall, want)
  // Ownership moves into the join slot; the joined value is the one temp.
  ensureOwned(ctx, insns, okV)
  insns.add(NStore(ty = want, value = okV.value, ptr = NLocal(name = slot)))
  insns.add(NBr(label = joinL))
  insns.add(NLabel(name = joinL))
  val loaded = freshTmp(ctx)
  insns.add(NLoad(dest = loaded, ty = want, ptr = NLocal(name = slot)))
  val res = NVal(ty = want, value = NLocal(name = loaded))
  registerTemp(ctx, res)
  res
}

func callArgSpan(a: in CallArg): Span {
  match a {
    case CAPositional(ex) -> ex.span
    case CANamed(_, _, sp) -> sp
  }
}

func dottedPath(name: in String, sp: in Span): ModulePath {
  val parts = Str.split(name, ".")
  val segs: List[String] = newList()
  var i = 0
  while i < parts.length {
    segs.add(parts[i])
    i = i + 1
  }
  ModulePath(segments = segs, span = sp)
}

func caseCallExpr(caseName: in String, arg: in Expr, sp: in Span): Expr {
  val cargs: List[CallArg] = newList()
  cargs.add(CAPositional(expr = arg))
  Expr(kind = ECall(fn = Expr(kind = EPath(path = dottedPath(caseName, sp)), span = sp), args = cargs), span = sp)
}

// ── Pattern matching (N2.4) ──────────────────────────────────────────────────
/// Union info for a scrutinee type, when it is a registered union.
func unionInfoOfType(ctx: in Ctx, t: in NType): Option[NUnionInfo] {
  match t {
    case NPtr(pointee) -> {
      match pointee {
        case NStruct(name, _) -> match mapGet(ctx.unionDefs, name) {
          // A pointer to an inline union is a raw `NativePtr`, not a union.
          case Some(ui) -> if ui.inline { None } else { Some(value = ui) }
          case None -> None
        }
        case _ -> None
      }
    }
    // An inline union is the struct itself, never behind a pointer.
    case NStruct(name, _) -> match mapGet(ctx.unionDefs, name) {
      case Some(ui) -> if ui.inline { Some(value = ui) } else { None }
      case None -> None
    }
    case _ -> None
  }
}

/// `true` when `name` names one of `t`'s cases — a union case (`t` is a
/// heap struct pointer) OR an enum case (`t` erases to bare `NI32` at
/// the native IR level, so an enum-typed scrutinee is distinguished from
/// a real `Int`/`Char` only via `enumHint`, the scrutinee's SCRUTINEE
/// HINT from `inferScrutineeEnumHint` — never by `t` itself, #6740).
/// Three-way on `enumHint` (see `enumNameOfTypeExpr`'s doc comment):
///   - a real enum's bare name -> scope the check to THAT specific enum
///     (`enumHint + "." + name` in `ctx.enumDefs`), fixing the #6969
///     hazard where an ordinary `Int`/`Char` catch-all bind was wrongly
///     reinterpreted as an equality test merely because its name
///     collided with an UNRELATED enum's case name elsewhere in the
///     bundle. A miss here is conclusive (never falls through to the
///     bundle-wide check below) — the scrutinee's REAL type is known,
///     and `name` isn't one of its cases, so it's just a bind.
///   - `nonEnumScrutHint` -> `false`, unconditionally: the scrutinee is
///     concretely `Int`/`Char`, never any enum, so `name` is always a
///     plain bind no matter what it happens to spell.
///   - `""` (truly unknown, #6976) -> falls back to the pre-#6969
///     bundle-wide `ctx.enumDefs.containsKey(name)` check, mirroring
///     `Msil.Codegen.lowerPatternTestMsil`'s own accepted trade-off
///     (#5995: prefer the type-scoped key when known, fall back to the
///     ambiguous bare key otherwise) rather than dropping enum-case
///     pattern support entirely for a hint-less scrutinee shape (an
///     untyped local, a direct call-result match, a field access).
func scrutineeHasCase(ctx: in Ctx, t: in NType, name: in String, enumHint: in String): Bool {
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
    case None -> {
      match t {
        case NI32 -> {
          if enumHint == nonEnumScrutHint {
            false
          } else if enumHint.length > 0 {
            ctx.enumDefs.containsKey(enumHint + "." + name)
          } else {
            ctx.enumDefs.containsKey(name)
          }
        }
        case _ -> false
      }
    }
  }
}

/// The SCRUTINEE HINT (see `enumNameOfTypeExpr`'s doc comment) of a
/// match scrutinee expression, when it's a bare local/param reference
/// (`EPath` with one segment) registered in `ctx.varEnumTypes`, or `""`
/// (unknown) otherwise. Mirrors `Msil.Codegen.inferScrutineeEnumHintMsil`
/// (#5995) so a bare-case-name pattern (`case Http1_1 ->`) resolves
/// against the scrutinee's OWN enum instead of colliding with another
/// in-bundle enum's same-named case.
func inferScrutineeEnumHint(ctx: in Ctx, e: in Expr): String {
  match e.kind {
    case EParen(inner) -> inferScrutineeEnumHint(ctx, inner)
    case EPath(path) -> {
      if path.segments.count == 1 {
        match mapGet(ctx.varEnumTypes, path.segments[0]) {
          case Some(n) -> n
          case None -> ""
        }
      } else {
        ""
      }
    }
    case _ -> ""
  }
}

func recInfoOfType(ctx: in Ctx, t: in NType): Option[NRecInfo] {
  match t {
    case NPtr(pointee) -> {
      match pointee {
        case NStruct(name, _) -> match mapGet(ctx.recordDefs, name) {
          // A pointer to a by-value record is a raw `NativePtr`, not a record.
          case Some(ri) -> if ri.byValue { None } else { Some(value = ri) }
          case None -> None
        }
        case _ -> None
      }
    }
    // A by-value record is the struct itself, never behind a pointer.
    case NStruct(name, _) -> mapGet(ctx.recordDefs, name)
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
  scrutEnumHint: in String,
): Unit {
  val p = stripPattern(pat)
  match p.kind {
    case PWildcard -> insns.add(NBr(label = okLabel))
    case PBinding(name, inner) -> {
      match inner {
        case Some(_) -> panic(
          "Lyric.LlvmCodegen: nested binding patterns (name @ pattern) are not yet supported for --target native"
        )
        case None -> {
          // A bare identifier that names a case of the scrutinee's
          // union is a nullary constructor pattern, not a binding
          // (`case Nada ->`): the parser cannot distinguish them.
          if scrutineeHasCase(ctx, sv.ty, name, scrutEnumHint) {
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
    case PLiteral(lit0) -> {
      // A float literal pattern on a `Float` scrutinee is the `Float` nearest
      // the literal (D155), so `case 0.1` matches `0.1f32`.
      val lit = floatPatternLiteralFor(lit0, sv.ty)
      val lv = lowerLiteral(ctx, insns, lit)
      if isStringNType(sv.ty) {
        val eq = callRuntime(ctx, insns, "lyric_string_eq", NI32, arg2(sv.ty, sv.value, lv.ty, lv.value))
        val isEq = freshTmp(ctx)
        insns.add(NICmp(dest = isEq, pred = INe, ty = NI32, a = eq.value, b = NLitInt(v = 0i64, ty = NI32)))
        insns.add(NCondBr(cond = NLocal(name = isEq), thenLabel = okLabel, elseLabel = failLabel))
      } else {
        match sv.ty {
          case NDouble | NFloat -> {
            val lc = coerceTo(ctx, insns, lv, sv.ty)
            val cmp = freshTmp(ctx)
            insns.add(NFCmp(dest = cmp, pred = FOeq, ty = sv.ty, a = sv.value, b = lc.value))
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
    case PRange(lo, inclusive, hi, _) -> {
      val loV = lowerRangeBound(ctx, insns, lo, sv.ty)
      val hiV = lowerRangeBound(ctx, insns, hi, sv.ty)
      val geLo = freshTmp(ctx)
      val leHi = freshTmp(ctx)
      if isFloatingNType(sv.ty) {
        // Ordered compares: a NaN scrutinee lies in no range.
        insns.add(NFCmp(dest = geLo, pred = FOge, ty = sv.ty, a = sv.value, b = loV.value))
        insns.add(NFCmp(dest = leHi, pred = if inclusive { FOle } else { FOlt }, ty = sv.ty, a = sv.value, b = hiV.value))
      } else {
        // A `Byte` (`i8`) orders unsigned, as its comparisons do (#4628,
        // #7842).
        val isByte = match sv.ty { case NI8 -> true; case _ -> false }
        insns.add(NICmp(dest = geLo, pred = if isByte { IUge } else { ISge }, ty = sv.ty, a = sv.value, b = loV.value))
        val hiPred = if inclusive { if isByte { IUle } else { ISle } } else { if isByte { IUlt } else { ISlt } }
        insns.add(NICmp(dest = leHi, pred = hiPred, ty = sv.ty, a = sv.value, b = hiV.value))
      }
      val both = freshTmp(ctx)
      insns.add(NAnd(dest = both, ty = NI1, a = NLocal(name = geLo), b = NLocal(name = leHi)))
      insns.add(NCondBr(cond = NLocal(name = both), thenLabel = okLabel, elseLabel = failLabel))
    }
    case PConstructor(head, subpats) -> emitConstructorTest(
      ctx,
      insns,
      sv,
      head,
      subpats,
      okLabel,
      failLabel,
      bindNames,
      bindVals
    )
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
          case _ -> {
            // A refutable element (`case (Some(a), Some(b))`): test the
            // field in place, continuing to the next element on success.
            val nextL = freshLabel(ctx, "match.tuple")
            val fv = lowerRecordFieldLoad(ctx, insns, ri, sv, ri.fieldNames[pi])
            emitPatternTest(ctx, insns, fv, sub, nextL, failLabel, bindNames, bindVals, "")
            insns.add(NLabel(name = nextL))
          }
        }
        pi = pi + 1
      }
      insns.add(NBr(label = okLabel))
    }
    case _ -> panic(
      "Lyric.LlvmCodegen: this pattern form is not yet supported for --target native (Phase N2 lowers wildcard, binding, literal, range, and constructor patterns)"
    )
  }
}

func emitConstructorTest(
  ctx: in Ctx,
  insns: in List[NInsn],
  sv0: in NVal,
  head: in ModulePath,
  subpats: in List[Pattern],
  okLabel: in String,
  failLabel: in String,
  bindNames: in List[String],
  bindVals: in List[NVal],
): Unit {
  val joined = modulePathJoin(head.segments)
  // Enum case pattern: scrutinee is the i32 discriminant itself. Gated on
  // the scrutinee's actual runtime representation (`sv.ty == NI32`), not
  // just a name match in `ctx.enumDefs` (#6753): this function is also
  // reached with a BARE single-segment `head` from `emitPatternTest`'s
  // `PBinding` -> `scrutineeHasCase` redirect once the scrutinee is
  // already confirmed to be a union — a struct pointer, never NI32 — so
  // without this guard an unrelated enum elsewhere in the bundle sharing
  // the union case's bare name (now that bare enum-case names are
  // registered, #6589) would hijack the test into a type-mismatched
  // `NICmp` against a pointer value instead of falling through to the
  // union-case check below.
  match sv0.ty {
    case NI32 -> {
      match mapGet(ctx.enumDefs, joined) {
        case Some(idx) -> {
          val cmp = freshTmp(ctx)
          insns.add(NICmp(dest = cmp, pred = IEq, ty = NI32, a = sv0.value, b = NLitInt(v = idx.toLong(), ty = NI32)))
          insns.add(NCondBr(cond = NLocal(name = cmp), thenLabel = okLabel, elseLabel = failLabel))
          return
        }
        case None -> {
        }
      }
    }
    case _ -> {
    }
  }
  val ui = match unionInfoOfType(ctx, sv0.ty) {
    case Some(u) -> u
    case None -> panic(
      "Lyric.LlvmCodegen: constructor pattern '" + joined + "' matched against a non-union value"
    )
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
  val structTy = if ui.inline {
    unionPtrType(ui)
  } else {
    match unionPtrType(ui) {
      case NPtr(pointee) -> pointee
      case _ -> panic("unreachable")
    }
  }
  // An inline scrutinee is addressed through a stack copy.
  val sv = if ui.inline { inlineUnionAddr(ctx, insns, sv0) } else { sv0 }
  val discPtr = freshTmp(ctx)
  val dArgs: List[NArg] = newList()
  dArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  dArgs.add(NArg(ty = NI32, value = NLitInt(v = unionDiscIdx(ui), ty = NI32)))
  insns.add(NGEP(dest = discPtr, ty = structTy, ptr = sv.value, indices = dArgs))
  val disc = freshTmp(ctx)
  insns.add(NLoad(dest = disc, ty = NI32, ptr = NLocal(name = discPtr)))
  val cmp = freshTmp(ctx)
  insns.add(
    NICmp(dest = cmp, pred = IEq, ty = NI32, a = NLocal(name = disc), b = NLitInt(v = cref.caseIdx.toLong(), ty = NI32))
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
    fArgs.add(NArg(ty = NI32, value = NLitInt(v = fi.toLong(), ty = NI32)))
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
        // "" — a nested field's bare-case-name test never reaches
        // `scrutineeHasCase`'s enum branch (a `PBinding` sub-pattern is
        // always a plain bind, handled above); the hint is unused here.
        emitPatternTest(ctx, insns, fieldVals[pi], sub, nextL, failLabel, bindNames, bindVals, "")
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
  // An inline-union scrutinee is spilled once here, ahead of every arm test.
  pinInlineUnion(ctx, insns, sv0)
  // Pin the scrutinee into a named local so every arm block can address
  // it (also keeps it alive across arms via the enclosing temp scope).
  val sv = sv0
  // #6969: the scrutinee's declared enum type name (if recognisable), so
  // a bare-case-name arm (`case Http1_1 ->`) resolves against it instead
  // of colliding with another in-bundle enum's same-named case.
  val scrutEnumHint = inferScrutineeEnumHint(ctx, scrutinee)
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
        emitPatternTest(ctx, insns, sv, arm.pattern, guardL, nextL, bindNames, bindVals, scrutEnumHint)
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
        emitPatternTest(ctx, insns, sv, arm.pattern, armBodyL, nextL, bindNames, bindVals, scrutEnumHint)
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
            // #7010: clear any stale varIsChar entry from an earlier
            // binding of this name — the tuple field's surface type
            // isn't tracked as Char here (a real gap), but clearing to
            // `false` prevents a stale `true` entry from silently
            // misrouting this value through lyric_string_from_char.
            markVarChar(ctx, name, false)
          }
        }
      }
      case PWildcard -> {
      }
      case _ -> panic(
        "Lyric.LlvmCodegen: only bindings and wildcards are supported inside tuple patterns for --target native"
      )
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
    // #7010: clear any stale varIsChar entry from an earlier binding of
    // this name — a match-arm payload's surface type isn't tracked as
    // Char here (a real gap), but clearing to `false` prevents a stale
    // `true` entry from silently misrouting this value through
    // lyric_string_from_char.
    markVarChar(ctx, bindNames[i], false)
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
                case None -> {
                  bindLocal(ctx, insns, name, v)
                  registerVarEnumTypeFromOpt(ctx, name, tyOpt)
                  markVarChar(ctx, name, charnessOfBinding(ctx, tyOpt, init))
                }
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
          registerVarEnumTypeFromOpt(ctx, name, tyOpt)
          markVarChar(ctx, name, charnessOfBinding(ctx, tyOpt, init))
        }
        case LBVar(name, tyOpt, initOpt) -> {
          match initOpt {
            case Some(init) -> {
              val v = match tyOpt {
                case Some(te) -> lowerExprExpecting(ctx, insns, init, typeToN(ctx, te))
                case None -> lowerExpr(ctx, insns, init)
              }
              bindLocal(ctx, insns, name, v)
              registerVarEnumTypeFromOpt(ctx, name, tyOpt)
              markVarChar(ctx, name, charnessOfBinding(ctx, tyOpt, init))
            }
            case None -> {
              match tyOpt {
                case Some(te) -> {
                  val ty = typeToN(ctx, te)
                  val zero = zeroValueOf(ty)
                  bindLocal(ctx, insns, name, NVal(ty = ty, value = zero))
                  registerVarEnumTypeFromOpt(ctx, name, tyOpt)
                  markVarChar(ctx, name, isCharTypeExpr(te))
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
      // In a coroutine body, `return` completes the task (waking its
      // waiters) and branches to the shared final-suspend block instead
      // of emitting `ret` — the ramp's only `ret` is in coro.exit.
      val inCoro = ctx.curAsyncTask.count > 0
      match valOpt {
        case Some(v) -> {
          match ctx.curRet[0] {
            case NVoid -> {
              val _ = lowerExpr(ctx, insns, v)
              releaseAllForReturn(ctx, insns)
              if inCoro {
                emitTaskComplete(ctx, insns, NVal(ty = NVoid, value = NUndef(ty = NVoid)))
                insns.add(NBr(label = "coro.final"))
              } else {
                insns.add(NRetVoid)
              }
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
              if inCoro {
                emitTaskComplete(ctx, insns, cv)
                insns.add(NBr(label = "coro.final"))
              } else {
                insns.add(NRet(ty = rt, value = cv.value))
              }
            }
          }
        }
        case None -> {
          releaseAllForReturn(ctx, insns)
          if inCoro {
            emitTaskComplete(ctx, insns, NVal(ty = NVoid, value = NUndef(ty = NVoid)))
            insns.add(NBr(label = "coro.final"))
          } else {
            insns.add(NRetVoid)
          }
        }
      }
      insns.add(NLabel(name = freshLabel(ctx, "dead")))
    }
    case SBreak(label) -> {
      val li = loopIndexForLabelNative(ctx, label)
      releaseForLoopExit(ctx, insns, li)
      insns.add(NBr(label = ctx.loopBreak[li]))
      insns.add(NLabel(name = freshLabel(ctx, "dead")))
    }
    case SContinue(label) -> {
      val li = loopIndexForLabelNative(ctx, label)
      releaseForLoopExit(ctx, insns, li)
      insns.add(NBr(label = ctx.loopCont[li]))
      insns.add(NLabel(name = freshLabel(ctx, "dead")))
    }
    case SWhile(label, cond, body) -> {
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
      val savedLabel1 = enterLoopLabelNative(ctx, label)
      ctx.loopBreak.add(exitL)
      ctx.loopCont.add(condL)
      ctx.loopVarDepth.add(ctx.scopeRefs.count)
      ctx.loopTempDepth.add(ctx.tempScopes.count)
      lowerBlockStmts(ctx, insns, body)
      exitLoopLabelNative(ctx, label, savedLabel1)
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
      val savedLabel2 = enterLoopLabelNative(ctx, label)
      match iter.kind {
        case ERange(bound) -> match bound {
          case RBClosed(lo, hi) -> lowerForOverRange(ctx, insns, pat, lo, hi, true, body)
          case RBHalfOpen(lo, hi, _) -> lowerForOverRange(ctx, insns, pat, lo, hi, false, body)
          case RBLowerOpen(_) -> panic(
            "Lyric.LlvmCodegen: an open-start range cannot drive a `for` loop (no lower bound to count from)"
          )
          case RBUpperOpen(_) -> panic(
            "Lyric.LlvmCodegen: an open-end range cannot drive a `for` loop (no upper bound to stop at)"
          )
        }
        case _ -> lowerForOverList(ctx, insns, pat, iter, body)
      }
      exitLoopLabelNative(ctx, label, savedLabel2)
    }
    case SLoop(label, body) -> {
      val bodyL = freshLabel(ctx, "loop.body")
      val exitL = freshLabel(ctx, "loop.exit")
      insns.add(NBr(label = bodyL))
      insns.add(NLabel(name = bodyL))
      val savedLabel3 = enterLoopLabelNative(ctx, label)
      ctx.loopBreak.add(exitL)
      ctx.loopCont.add(bodyL)
      ctx.loopVarDepth.add(ctx.scopeRefs.count)
      ctx.loopTempDepth.add(ctx.tempScopes.count)
      lowerBlockStmts(ctx, insns, body)
      exitLoopLabelNative(ctx, label, savedLabel3)
      ctx.loopBreak.removeAt(ctx.loopBreak.count - 1)
      ctx.loopCont.removeAt(ctx.loopCont.count - 1)
      ctx.loopVarDepth.removeAt(ctx.loopVarDepth.count - 1)
      ctx.loopTempDepth.removeAt(ctx.loopTempDepth.count - 1)
      insns.add(NBr(label = bodyL))
      insns.add(NLabel(name = exitL))
    }
    case SThrow(_) -> panic("Lyric.LlvmCodegen: 'throw' is not supported for --target native (D-N-003: panics abort)")
    case STry(_, _, _) -> panic(
      "Lyric.LlvmCodegen: try/catch is not supported for --target native (D-N-003: no unwinding)"
    )
    case SDefer(body) -> {
      // Registers into the innermost scope; runs via `runDeferredScopeAt` at scope exit, not inline here (D-N-020; a panic still bypasses it per D-N-003).
      ctx.deferStack[ctx.deferStack.count - 1].add(body)
    }
    // `scope { }` lowers as a scoped block (D-N-021), matching MSIL's plain-block lowering; its §7.4 guarantees hold degenerately since every spawned call completes at the spawn site.
    case SScope(_, body) -> lowerBlockStmts(ctx, insns, body)
    case SInvariant(_) -> {
      // Loop invariants are proof obligations (lyric prove); they carry
      // no runtime lowering here.
    }
    case _ -> panic("Lyric.LlvmCodegen: this statement form is not yet supported for --target native (Phase N1)")
  }
}

// A float literal pattern against a `Float` scrutinee, rewritten to its
// binary32 form (D155).
func floatPatternLiteralFor(lit: in Literal, scrutTy: in NType): Literal {
  match scrutTy {
    case NFloat -> match lit {
      case LFloat(v, sfx, raw) -> match sfx {
        case F32 -> lit
        case _ -> LFloat(
          value = float32LiteralValue(raw, v),
          suffix = F32,
          raw = raw
        )
      }
      case _ -> lit
    }
    case _ -> lit
  }
}

// A range pattern bound against a `Float` scrutinee: a float literal bound,
// possibly negated or parenthesised, denotes the nearest `Float` (D155).
// One bound of a range pattern, in the scrutinee's type.  Range-pattern
// bounds are not type-checked against the scrutinee, so an integer bound on a
// floating scrutinee (`case 0 ..= 1` on a `Float`) is converted here, as the
// JVM and MSIL backends do.
func lowerRangeBound(ctx: in Ctx, insns: in List[NInsn], bound: in Expr, scrutTy: in NType): NVal {
  val bv = lowerExpr(ctx, insns, floatPatternBoundFor(bound, scrutTy))
  if isFloatingNType(scrutTy) and isIntNType(bv.ty) {
    match bv.value {
      case NLitInt(_, _) -> ()
      case _ -> {
        val wide = match bv.ty {
          case NI8 -> {
            val z = freshTmp(ctx)
            insns.add(NZExt(dest = z, fromTy = NI8, value = bv.value, toTy = NI32))
            NVal(ty = NI32, value = NLocal(name = z))
          }
          case _ -> bv
        }
        val dest = freshTmp(ctx)
        insns.add(NSIToFP(dest = dest, fromTy = wide.ty, value = wide.value, toTy = scrutTy))
        return NVal(ty = scrutTy, value = NLocal(name = dest))
      }
    }
  }
  coerceTo(ctx, insns, bv, scrutTy)
}

func floatPatternBoundFor(e: in Expr, scrutTy: in NType): Expr {
  match scrutTy {
    case NFloat -> match e.kind {
      case ELiteral(lit) -> Expr(
        kind = ELiteral(lit = floatPatternLiteralFor(lit, scrutTy)),
        span = e.span
      )
      case EParen(inner) -> Expr(
        kind = EParen(inner = floatPatternBoundFor(inner, scrutTy)),
        span = e.span
      )
      case EPrefix(op, inner) -> Expr(
        kind = EPrefix(
          op = op,
          operand = floatPatternBoundFor(inner, scrutTy)
        ),
        span = e.span
      )
      case _ -> e
    }
    case _ -> e
  }
}

func zeroValueOf(ty: in NType): NValue {
  match ty {
    case NDouble -> NLitFloat(v = 0.0, ty = NDouble)
    case NFloat -> NLitFloat(v = 0.0, ty = NFloat)
    case NPtr(pointee) -> NLitNull(ty = NPtr(pointee = pointee))
    case NStruct(_, _) -> NZeroInit(ty = ty)
    case NArray(_, _) -> NZeroInit(ty = ty)
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
    case _ -> panic(
      "Lyric.LlvmCodegen: assignment to this target form is not yet supported for --target native (fields are Phase N2)"
    )
  }
}

// Shared read-combine-write step for a compound index assignment
// (`xs[i] += e`, `m[k] -= e`, …): `cur` is the element already read back
// from the container, `rhs` is the already-lowered RHS value. Takes `rhs`
// pre-lowered (rather than the raw `Expr`) so callers can evaluate the RHS
// BEFORE reading the container's current value — matching the JVM
// backend's `EIndex` compound-assign evaluation order
// (`jvm/codegen/05_stmts.l`), so `xs[i] += e` where `e` itself mutates
// `xs` behaves identically on native and JVM. Mirrors the duplicated
// combine logic in `lowerAssign`/`lowerFieldAssign` above, kept as its own
// small helper here (rather than factored into those two already-shipped
// call sites) to keep this indexed-assignment addition isolated from
// their existing, separately-verified codegen.
func combineIndexedAssignValue(
  ctx: in Ctx,
  insns: in List[NInsn],
  op: in AssignOp,
  ty: in NType,
  cur: in NVal,
  rhs: in NVal,
  line: in Int,
): NVal {
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
      case NDouble | NFloat -> binFloatOp(ctx, insns, binOp, ty, cur.value, rhsC.value)
      case _ -> binIntOp(ctx, insns, binOp, ty, cur.value, rhsC.value, line)
    }
  }
}

/// `xs[i] = e` / `xs[i] op= e` on a `List[T]` (and, since `slice[T]` shares
/// `List[T]`'s runtime representation, D-N-015, also `slice[T]`) or
/// `Map[K, V]` receiver (issue #6811/#6808: `Std.HttpEngine.Hpack`'s
/// Huffman trie builder mutates `List[Int]` parallel arrays by index).
/// `lyric_list_set`/`lyric_map_set` already retain-new/release-old
/// internally (see `lyric_collections.c`), so — unlike the plain-variable
/// and field assignment paths above — no separate ARC dance is needed
/// here.
func lowerIndexAssign(
  ctx: in Ctx,
  insns: in List[NInsn],
  receiver: in Expr,
  indices: in List[Expr],
  op: in AssignOp,
  value: in Expr,
  line: in Int,
): Unit {
  if indices.count != 1 {
    panic("Lyric.LlvmCodegen: indexed assignment takes exactly one index for --target native")
  }
  if lowerArrayElemAssign(ctx, insns, receiver, indices[0], op, value, line) {
    return
  }
  val recv = lowerExpr(ctx, insns, receiver)
  match listElemOfType(ctx, recv.ty) {
    case Some(elem) -> {
      val idx = lowerExprExpecting(ctx, insns, indices[0], NI64)
      val recvP = collectionAsI8(ctx, insns, recv)
      val newVal = match op {
        case AssEq -> lowerExprExpecting(ctx, insns, value, elem)
        case _ -> {
          // RHS evaluated BEFORE the container read (matches the JVM
          // backend's order, see combineIndexedAssignValue's header).
          val rhs = lowerExpr(ctx, insns, value)
          val gArgs: List[NArg] = newList()
          gArgs.add(NArg(ty = NPtr(pointee = NI8), value = recvP))
          gArgs.add(NArg(ty = NI64, value = idx.value))
          val slot = callRuntime(ctx, insns, "lyric_list_get", NI64, gArgs)
          val cur = valOfSlot(ctx, insns, slot.value, elem)
          combineIndexedAssignValue(ctx, insns, op, elem, cur, rhs, line)
        }
      }
      val sArgs: List[NArg] = newList()
      sArgs.add(NArg(ty = NPtr(pointee = NI8), value = recvP))
      sArgs.add(NArg(ty = NI64, value = idx.value))
      sArgs.add(NArg(ty = NI64, value = slotOfVal(ctx, insns, newVal)))
      val _ = callRuntime(ctx, insns, "lyric_list_set", NVoid, sArgs)
      return
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
      val newVal = match op {
        case AssEq -> lowerExprExpecting(ctx, insns, value, vTy)
        case _ -> {
          // RHS evaluated BEFORE the container read (matches the JVM
          // backend's order, see combineIndexedAssignValue's header).
          val rhs = lowerExpr(ctx, insns, value)
          val outSlot = "mapidxasn.out." + freshTmp(ctx)
          ctx.allocas.add(NAlloca(dest = outSlot, ty = NI64))
          val gArgs: List[NArg] = newList()
          gArgs.add(NArg(ty = NPtr(pointee = NI8), value = recvP))
          gArgs.add(NArg(ty = NI64, value = slotOfVal(ctx, insns, kv)))
          gArgs.add(NArg(ty = NPtr(pointee = NI64), value = NLocal(name = outSlot)))
          val found = callRuntime(ctx, insns, "lyric_map_get", NI32, gArgs)
          val hit = freshTmp(ctx)
          insns.add(NICmp(dest = hit, pred = INe, ty = NI32, a = found.value, b = NLitInt(v = 0i64, ty = NI32)))
          val okL = freshLabel(ctx, "mapidxasn.ok")
          val missL = freshLabel(ctx, "mapidxasn.miss")
          insns.add(NCondBr(cond = NLocal(name = hit), thenLabel = okL, elseLabel = missL))
          insns.add(NLabel(name = missL))
          emitPanicRaw(ctx, insns, "map key not found (use mapGet for an Option result)", line)
          insns.add(NBr(label = okL))
          insns.add(NLabel(name = okL))
          val raw = freshTmp(ctx)
          insns.add(NLoad(dest = raw, ty = NI64, ptr = NLocal(name = outSlot)))
          val cur = valOfSlot(ctx, insns, NLocal(name = raw), vTy)
          combineIndexedAssignValue(ctx, insns, op, vTy, cur, rhs, line)
        }
      }
      val sArgs: List[NArg] = newList()
      sArgs.add(NArg(ty = NPtr(pointee = NI8), value = recvP))
      sArgs.add(NArg(ty = NI64, value = slotOfVal(ctx, insns, kv)))
      sArgs.add(NArg(ty = NI64, value = slotOfVal(ctx, insns, newVal)))
      val _ = callRuntime(ctx, insns, "lyric_map_set", NVoid, sArgs)
      return
    }
    case None -> {
    }
  }
  panic(
    "Lyric.LlvmCodegen: indexed assignment on this receiver is not yet supported for --target native (List[T], slice[T] — same runtime representation, D-N-015 — and Map[K, V] support element assignment; String bracket indexing is a separate tracked gap, issue #6237) at line " +
      line.toString() +
      ": " +
      nTypeToIrString(recv.ty)
  )
}

func lowerAssign(
  ctx: in Ctx, insns: in List[NInsn], target: in Expr, op: in AssignOp, value: in Expr, line: in Int
): Unit {
  match target.kind {
    case EMember(recv, fieldName) -> {
      lowerFieldAssign(ctx, insns, recv, fieldName, op, value, line)
      return
    }
    case EIndex(receiver, indices) -> {
      lowerIndexAssign(ctx, insns, receiver, indices, op, value, line)
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
          case NDouble | NFloat -> binFloatOp(ctx, insns, binOp, ty, cur.value, rhsC.value)
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
  if ri.byValue {
    panic(
      "Lyric.LlvmCodegen: internal — assignment to field '." + fieldName + "' of by-value record '" + ri.irName +
        "' (a record with no `var` field cannot be assigned through)"
    )
  }
  val fieldTy = ri.fieldTys[idx]
  val structTy = match obj.ty { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  val fieldPtr = freshTmp(ctx)
  val fArgs: List[NArg] = newList()
  fArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  fArgs.add(NArg(ty = NI32, value = NLitInt(v = (arcHeaderSlots + idx).toLong(), ty = NI32)))
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
          case NDouble | NFloat -> binFloatOp(ctx, insns, binOp, fieldTy, cur.value, rhsC.value)
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
  val enumTypes: Map[String, String] = newMap()
  val isChar: Map[String, Bool] = newMap()
  val curPkg: List[String] = newList()
  curPkg.add(pkg)
  val curOrigin: List[String] = newList()
  for o in mod.curOrigin {
    curOrigin.add(o)
  }
  val curRet: List[NType] = newList()
  curRet.add(retTy)
  Ctx(
    mainPkg = mod.mainPkg,
    tmpTicker = mod.tmpTicker,
    labelTicker = mod.labelTicker,
    ptrBytes = mod.ptrBytes,
    abiTriple = mod.abiTriple,
    strTicker = mod.strTicker,
    varSlots = slots,
    varTypes = types,
    varEnumTypes = enumTypes,
    varIsChar = isChar,
    allocas = newList(),
    loopBreak = newList(),
    loopCont = newList(),
    globals = mod.globals,
    sigs = mod.sigs,
    pkgImportsStdString = mod.pkgImportsStdString,
    sigAlts = mod.sigAlts,
    pkgImports = mod.pkgImports,
    methodCallArities = mod.methodCallArities,
    curPkg = curPkg,
    curOrigin = curOrigin,
    curRet = curRet,
    moduleVals = mod.moduleVals,
    mvInits = mod.mvInits,
    mvInitTys = mod.mvInitTys,
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
    unionEqFns = mod.unionEqFns,
    genericFnDefs = mod.genericFnDefs,
    genericFnPkg = mod.genericFnPkg,
    fnInstCache = mod.fnInstCache,
    instMeta = mod.instMeta,
    fnTyEnvNames = newList(),
    fnTyEnvTys = newList(),
    pendingCallRetWant = newList(),
    closureSigs = mod.closureSigs,
    trampolines = mod.trampolines,
    weakTargets = mod.weakTargets,
    listElems = mod.listElems,
    mapKeyTys = mod.mapKeyTys,
    mapValTys = mod.mapValTys,
    ifaceInfos = mod.ifaceInfos,
    ifaceBareNameOwners = mod.ifaceBareNameOwners,
    ifaceVtables = mod.ifaceVtables,
    implDirectMethods = mod.implDirectMethods,
    protectedRecNames = mod.protectedRecNames,
    heapOnlyRecs = mod.heapOnlyRecs,
    byValueBoxes = mod.byValueBoxes,
    inlineAddrs = newMap(),
    scopeRefs = newList(),
    tempScopes = newList(),
    loopVarDepth = newList(),
    loopTempDepth = newList(),
    loopLabelIndex = newMap(),
    deferStack = newList(),
    enumTypeUndo = newList(),
    bindingUndo = newList(),
    taskElems = mod.taskElems,
    curAsyncTask = newList(),
    usesAsync = mod.usesAsync
  )
}

func lowerFunction(modCtx: in Ctx, pkg: in String, fn: in FunctionDecl, irName: in String): NFunc {
  val noNames: List[String] = newList()
  val noTys: List[NType] = newList()
  lowerFunctionEnv(modCtx, pkg, fn, irName, noNames, noTys)
}

// Async generator detection (D-N-019): a native-local mirror of the type checker's yield walk, since backends don't import `Lyric.TypeChecker`.
func funcBodyContainsYieldNative(fn: in FunctionDecl): Bool {
  match fn.body {
    case None -> false
    case Some(body) -> match body {
      case FBExpr(e) -> exprContainsYieldNative(e)
      case FBBlock(b) -> blockContainsYieldNative(b)
    }
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
    // yield inside a spawn belongs to the spawned task, not this scope.
    case ESpawn(_) -> false
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
    case ERange(rb) -> match rb {
      case RBClosed(a, b) -> exprContainsYieldNative(a) or exprContainsYieldNative(b)
      case RBHalfOpen(a, b, _) -> exprContainsYieldNative(a) or exprContainsYieldNative(b)
      case RBLowerOpen(a) -> exprContainsYieldNative(a)
      case RBUpperOpen(a) -> exprContainsYieldNative(a)
    }
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
        case Some(b) -> match b {
          case EOBExpr(ee) -> exprContainsYieldNative(ee)
          case EOBBlock(eb) -> blockContainsYieldNative(eb)
        }
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
    case SLocal(binding) -> match binding {
      case LBVal(_, _, e) -> exprContainsYieldNative(e)
      case LBLet(_, _, e) -> exprContainsYieldNative(e)
      case LBVar(_, _, Some(e)) -> exprContainsYieldNative(e)
      case LBVar(_, _, None) -> false
    }
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
  ctx0.curOrigin.clear()
  val origin = originPkgOf(fn.annotations)
  if origin.length > 0 and origin != pkg {
    ctx0.curOrigin.add(origin)
  }
  var ei = 0
  while ei < envNames.count {
    ctx0.fnTyEnvNames.add(envNames[ei])
    ctx0.fnTyEnvTys.add(envTys[ei])
    ei = ei + 1
  }
  // For an async fn, `retTy` stays the ELEMENT type: `curRet` drives
  // return-value coercion, while the define itself returns the task as
  // i8* (rewritten at assembly below).
  val retTy = retTypeToN(ctx0, fn.ret)
  ctx0.curRet.removeAt(0)
  ctx0.curRet.add(retTy)
  val ctx = ctx0
  val isCoro = fn.isAsync
  val params: List[NParam] = newList()
  val body: List[NInsn] = newList()
  val p8 = NPtr(pointee = NI8)
  if isCoro {
    // Coroutine prologue (stage B2): coro.id / coro.alloc / coro.begin,
    // then the LyricTask this frame reports through.  Fixed SSA/label
    // names are safe — one coroutine prologue per function.
    if ctx.usesAsync.count == 0 {
      ctx.usesAsync.add(1)
    }
    val idArgs: List[NArg] = newList()
    idArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
    idArgs.add(NArg(ty = p8, value = NLitNull(ty = p8)))
    idArgs.add(NArg(ty = p8, value = NLitNull(ty = p8)))
    idArgs.add(NArg(ty = p8, value = NLitNull(ty = p8)))
    body.add(NCall(dest = "coro.id", retTy = NToken, fn = NGlobal(name = "llvm.coro.id"), args = idArgs))
    body.add(
      NCall(
        dest = "coro.need",
        retTy = NI1,
        fn = NGlobal(name = "llvm.coro.alloc"),
        args = arg1(NToken, NLocal(name = "coro.id"))
      )
    )
    body.add(NCondBr(cond = NLocal(name = "coro.need"), thenLabel = "coro.dynalloc", elseLabel = "coro.begin"))
    body.add(NLabel(name = "coro.dynalloc"))
    val noArgs: List[NArg] = newList()
    body.add(NCall(dest = "coro.size", retTy = NI64, fn = NGlobal(name = "llvm.coro.size.i64"), args = noArgs))
    body.add(
      NCall(
        dest = "coro.mem",
        retTy = p8,
        fn = NGlobal(name = "lyric_alloc"),
        args = arg1(NI64, NLocal(name = "coro.size"))
      )
    )
    body.add(NBr(label = "coro.begin"))
    body.add(NLabel(name = "coro.begin"))
    val phiIn: List[NPhiIncoming] = newList()
    phiIn.add(NPhiIncoming(value = NLitNull(ty = p8), label = "entry"))
    phiIn.add(NPhiIncoming(value = NLocal(name = "coro.mem"), label = "coro.dynalloc"))
    body.add(NPhi(dest = "coro.frame", ty = p8, incoming = phiIn))
    body.add(
      NCall(
        dest = "coro.hdl",
        retTy = p8,
        fn = NGlobal(name = "llvm.coro.begin"),
        args = arg2(NToken, NLocal(name = "coro.id"), p8, NLocal(name = "coro.frame"))
      )
    )
    body.add(
      NCall(
        dest = "coro.task",
        retTy = p8,
        fn = NGlobal(name = "lyric_task_new"),
        args = arg1(p8, NLocal(name = "coro.hdl"))
      )
    )
    ctx.curAsyncTask.add("coro.task")
  }
  // Parameters land in allocas so `var`-style reads/writes and address
  // uniformity hold; mem2reg cleans this up at -O1+.  `in` params are
  // ARC borrows (Rule 5): never retained on entry or released on exit.
  //
  // `out`/`inout` (N9.6, #6794): the LLVM signature takes a pointer to the
  // parameter's own type — the ADDRESS of the caller's storage cell —
  // instead of copying a value in.  No fresh alloca is needed: every read
  // (`loadLocal`) and write (`lowerAssign`) of a local name goes through
  // `ctx.varSlots[name]` as a bare pointer-to-`ty` SSA value already (the
  // same shape an `alloca` produces), so binding `varSlots[p.name]`
  // directly to the incoming pointer parameter makes every subsequent
  // read/write alias the CALLER's cell — true reference semantics, exactly
  // like the MSIL backend's `MByRef` and the JVM backend's boxed-cell
  // by-ref lowering.  This also means a chained `inout` forward (passing
  // an `inout` parameter on to another `inout` call, as `Std.HttpEngine`'s
  // H2 frame dispatch does pervasively) is a plain pointer forward with no
  // extra copy.
  //
  // ARC (04-arc-design.md Rules 3/4): a write to the by-ref cell runs
  // through the ordinary `lowerAssign`/`lowerFieldAssign` paths, which
  // already retain-new/release-old for a ref-typed slot — since the slot
  // IS the caller's storage, this is exactly the ARC bookkeeping a direct
  // `x = newVal` at the caller site would perform.  The callee must NOT
  // retain on entry or release on exit for `out`/`inout` any more than it
  // would for `in` (Rule 5): the pointed-to value is never in this
  // function's ownership, so it is not added to `ctx.scopeRefs`.
  //
  // `out` and `inout` lower IDENTICALLY here: the only language-level
  // difference (an `out` parameter is definite-assignment-checked, T0086
  // in `typechecker_stmts.l`; nothing requires WRITE-BEFORE-READ to be
  // enforced at the machine level) is a type-checker concern, not a
  // codegen one — a stray read of an unwritten `out` parameter reads
  // whatever the caller's cell already holds (never uninitialized memory:
  // every `var` local is zero/null-initialized when declared without an
  // initializer, and `lyric_release`/`lyric_retain` on a null pointer are
  // safe no-ops, so there is no memory-safety hazard either way).
  //
  // A `Unit`-typed `out`/`inout` parameter carries no representable value
  // (there is nothing to write a pointer at), so it lowers exactly like a
  // `Unit`-typed `in` parameter regardless of the declared mode.
  var pi = 0
  while pi < fn.params.count {
    val p = fn.params[pi]
    val isByRefMode = match p.mode { case PMIn -> false; case _ -> true }
    if isByRefMode and isCoro {
      panic(
        "Lyric.LlvmCodegen: async function '" + fn.name + "' declares out/inout parameter '" + p.name +
          "', which is not yet supported for --target native (a suspended coroutine cannot safely hold a pointer into caller-frame storage across a suspend point)"
      )
    }
    val pty = typeToN(ctx, p.ty)
    val ptyIsVoid = match pty { case NVoid -> true; case _ -> false }
    registerVarEnumType(ctx, p.name, enumNameOfTypeExpr(ctx, p.ty))
    ctx.varIsChar.add(p.name, isCharTypeExpr(p.ty))
    if isByRefMode and not ptyIsVoid {
      val ptrTy = NPtr(pointee = pty)
      params.add(NParam(name = "arg." + p.name, ty = ptrTy))
      // No alloca, no copy: the incoming pointer IS the storage slot.
      ctx.varSlots.add(p.name, "arg." + p.name)
      ctx.varTypes.add(p.name, pty)
    } else {
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
    }
    pi = pi + 1
  }
  pushVarScope(ctx)
  pushTempScope(ctx)
  if isCoro {
    // Ref-typed params are borrows (Rule 5) and unsafe across suspends:
    // the caller regains control at the first suspend and may release
    // its refs while this frame is parked.  Retain each on entry and
    // register it in the function scope so every exit path releases it.
    var rpi = 0
    while rpi < fn.params.count {
      val pname = fn.params[rpi].name
      match mapGet(ctx.varTypes, pname) {
        case Some(pty) -> {
          if isRefNType(pty) {
            emitRetain(ctx, body, NVal(ty = pty, value = NLocal(name = "arg." + pname)))
            match mapGet(ctx.varSlots, pname) {
              case Some(sl) -> ctx.scopeRefs[0].add(NOwnedLocal(slot = sl, ty = pty))
              case None -> {
              }
            }
          }
        }
        case None -> {
        }
      }
      rpi = rpi + 1
    }
  }
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
  // Coroutines complete their task and branch to the shared
  // final-suspend block instead of emitting `ret`.
  match retTy {
    case NVoid -> {
      releaseAllForReturn(ctx, body)
      if isCoro {
        emitTaskComplete(ctx, body, NVal(ty = NVoid, value = NUndef(ty = NVoid)))
        body.add(NBr(label = "coro.final"))
      } else {
        body.add(NRetVoid)
      }
    }
    case rt -> {
      match tail.ty {
        case NVoid -> {
          // The body ended with a terminator-producing construct (e.g.
          // every path returned explicitly); emit an unreachable
          // fall-off return of the zero value to keep the block closed.
          releaseAllForReturn(ctx, body)
          if isCoro {
            emitTaskComplete(ctx, body, NVal(ty = rt, value = zeroValueOf(rt)))
            body.add(NBr(label = "coro.final"))
          } else {
            body.add(NRet(ty = rt, value = zeroValueOf(rt)))
          }
        }
        case _ -> {
          val cv = coerceTo(ctx, body, tail, rt)
          if isRefNType(rt) {
            ensureOwned(ctx, body, cv)
          }
          releaseAllForReturn(ctx, body)
          if isCoro {
            emitTaskComplete(ctx, body, cv)
            body.add(NBr(label = "coro.final"))
          } else {
            body.add(NRet(ty = rt, value = cv.value))
          }
        }
      }
    }
  }
  if isCoro {
    // Shared coroutine epilogue.  coro.final: the final suspend parks a
    // COMPLETE frame until its owner's destroy (resuming a finally-
    // suspended coroutine is UB, hence the unreachable resume edge).
    // coro.cleanup: frees the frame on the destroy path.  coro.exit:
    // returns the task to the ramp's caller (CoroSplit frame-spills
    // `coro.task`, and rewrites this ret in the resume/destroy clones).
    body.add(NLabel(name = "coro.final"))
    val fsArgs: List[NArg] = newList()
    fsArgs.add(NArg(ty = NToken, value = NLitTokenNone))
    fsArgs.add(NArg(ty = NI1, value = NLitInt(v = 1i64, ty = NI1)))
    body.add(NCall(dest = "coro.fs", retTy = NI8, fn = NGlobal(name = "llvm.coro.suspend"), args = fsArgs))
    val fsCases: List[NSwitchCase] = newList()
    fsCases.add(NSwitchCase(matchVal = 0i64, label = "coro.unreach"))
    fsCases.add(NSwitchCase(matchVal = 1i64, label = "coro.cleanup"))
    body.add(NSwitch(ty = NI8, scrutinee = NLocal(name = "coro.fs"), defaultLabel = "coro.exit", cases = fsCases))
    body.add(NLabel(name = "coro.unreach"))
    body.add(NUnreachable)
    body.add(NLabel(name = "coro.cleanup"))
    body.add(
      NCall(
        dest = "coro.freemem",
        retTy = p8,
        fn = NGlobal(name = "llvm.coro.free"),
        args = arg2(NToken, NLocal(name = "coro.id"), p8, NLocal(name = "coro.hdl"))
      )
    )
    body.add(NCallVoid(fn = NGlobal(name = "lyric_free"), args = arg1(p8, NLocal(name = "coro.freemem"))))
    body.add(NBr(label = "coro.exit"))
    body.add(NLabel(name = "coro.exit"))
    body.add(
      NCall(
        dest = "coro.done",
        retTy = NI1,
        fn = NGlobal(name = "llvm.coro.end"),
        args = arg2(p8, NLocal(name = "coro.hdl"), NI1, NLitInt(v = 0i64, ty = NI1))
      )
    )
    body.add(NRet(ty = p8, value = NLocal(name = "coro.task")))
  }
  // Assemble: entry label, hoisted allocas, then the body.
  val insns: List[NInsn] = newList()
  insns.add(NLabel(name = "entry"))
  appendInsns(insns, ctx.allocas)
  appendInsns(insns, body)
  val attrs: List[String] = newList()
  if isCoro {
    attrs.add("presplitcoroutine")
  }
  val isPub = match fn.visibility { case Some(_) -> true; case None -> pkg == ctx.mainPkg }
  NFunc(
    name = irName,
    params = params,
    retTy = if isCoro { p8 } else { retTy },
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
  decls.add(mkDecl2("lyric_string_char_at", NI32, sTy, NI64))
  decls.add(mkDecl2("lyric_string_byte_at", NI8, sTy, NI64))
  decls.add(mkDecl2("lyric_string_eq", NI32, sTy, sTy))
  // Same signature as `Std.ConsoleHost.consoleWriteLineFd` (Lyric `Int` fd,
  // `int32_t fd` in C), which this declaration shadows when the kernel is also
  // bundled.  The width matters: wasm-ld rejects a call whose signature differs
  // from the definition's, where x86-64 silently tolerates it.
  decls.add(mkDecl2("lyric_console_write_line", NVoid, NI32, sTy))
  decls.add(mkDecl2("lyric_string_cmp", NI32, sTy, sTy))
  decls.add(mkDecl1("lyric_string_from_int", sTy, NI64))
  decls.add(mkDecl1("lyric_string_from_float", sTy, NDouble))
  decls.add(mkDecl1("lyric_string_from_float32", sTy, NFloat))
  decls.add(mkDecl1("lyric_string_from_bool", sTy, NI32))
  decls.add(mkDecl1("lyric_string_from_char", sTy, NI32))
  decls.add(mkDecl3("lyric_string_substring", sTy, sTy, NI64, NI64))
  decls.add(mkDecl1("lyric_string_trim", sTy, sTy))
  decls.add(mkDecl1("lyric_string_trim_start", sTy, sTy))
  decls.add(mkDecl1("lyric_string_trim_end", sTy, sTy))
  decls.add(mkDecl3("lyric_string_replace", sTy, sTy, sTy, sTy))
  decls.add(mkDecl1("lyric_string_to_lower", sTy, sTy))
  decls.add(mkDecl1("lyric_string_to_upper", sTy, sTy))
  decls.add(mkDecl2("lyric_string_index_of", NI64, sTy, sTy))
  decls.add(mkDecl2("lyric_string_last_index_of", NI64, sTy, sTy))
  decls.add(mkDecl2("lyric_string_starts_with", NI32, sTy, sTy))
  decls.add(mkDecl2("lyric_string_contains", NI32, sTy, sTy))
  decls.add(mkDecl2("lyric_string_ends_with", NI32, sTy, sTy))
  decls.add(mkDecl1("lyric_string_to_cstring", NPtr(pointee = NI8), sTy))
  decls.add(mkDecl1("lyric_cstring_free", NVoid, NPtr(pointee = NI8)))
  decls.add(mkDecl1("lyric_weak_upgrade", NPtr(pointee = NI8), NPtr(pointee = NI8)))
  decls.add(mkDecl1("lyric_weak_retain", NVoid, NPtr(pointee = NI8)))
  decls.add(mkDecl1("lyric_weak_release", NVoid, NPtr(pointee = NI8)))
  decls.add(mkDecl1("lyric_weak_init", NVoid, NPtr(pointee = NI8)))
  val p8 = NPtr(pointee = NI8)
  decls.add(mkDecl1("lyric_list_new", p8, NI32))
  decls.add(mkDecl2("lyric_list_push", NVoid, p8, NI64))
  decls.add(mkDecl2("lyric_list_get", NI64, p8, NI64))
  decls.add(mkDecl3("lyric_list_set", NVoid, p8, NI64, NI64))
  decls.add(mkDecl2("lyric_list_remove_at", NVoid, p8, NI64))
  decls.add(mkDecl1("lyric_list_len", NI64, p8))
  decls.add(mkDecl1("lyric_list_clear", NVoid, p8))
  decls.add(mkDecl1("lyric_list_copy", p8, p8))
  decls.add(mkDecl3("lyric_list_slice", p8, p8, NI64, NI64))
  decls.add(mkDecl2("lyric_list_concat", p8, p8, p8))
  decls.add(mkDecl2("lyric_list_append", p8, p8, NI64))
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

/// The `llvm.coro.*` intrinsics and lyric-rt scheduler entry points an
/// async-using module needs (stage B2); appended to the extern
/// declarations only when the bundle lowered at least one coroutine.
func asyncRuntimeDecls(): List[NFunc] {
  val decls: List[NFunc] = newList()
  val p8 = NPtr(pointee = NI8)
  val idTys: List[NType] = newList()
  idTys.add(NI32)
  idTys.add(p8)
  idTys.add(p8)
  idTys.add(p8)
  decls.add(mkDeclN("llvm.coro.id", NToken, idTys))
  decls.add(mkDecl1("llvm.coro.alloc", NI1, NToken))
  val noTys: List[NType] = newList()
  decls.add(mkDeclN("llvm.coro.size.i64", NI64, noTys))
  decls.add(mkDecl2("llvm.coro.begin", p8, NToken, p8))
  decls.add(mkDecl2("llvm.coro.suspend", NI8, NToken, NI1))
  decls.add(mkDecl2("llvm.coro.free", p8, NToken, p8))
  decls.add(mkDecl2("llvm.coro.end", NI1, p8, NI1))
  decls.add(mkDecl1("llvm.coro.resume", NVoid, p8))
  decls.add(mkDecl1("llvm.coro.destroy", NVoid, p8))
  decls.add(mkDecl1("lyric_task_new", p8, p8))
  decls.add(mkDecl3("lyric_task_complete", NVoid, p8, NI64, NI32))
  decls.add(mkDecl1("lyric_task_result", NI64, p8))
  decls.add(mkDecl1("lyric_task_is_complete", NI32, p8))
  decls.add(mkDecl2("lyric_async_await", NVoid, p8, p8))
  decls.add(mkDecl2("lyric_async_sleep", NVoid, p8, NI64))
  decls.add(mkDecl1("lyric_task_block_on", NVoid, p8))
  decls
}

/// A thin `define` wrapping one `llvm.coro.resume`/`llvm.coro.destroy`
/// intrinsic.  The scheduler (C) resumes frames through these symbols:
/// CoroSplit emits the frame's resume/destroy function pointers as
/// `internal fastcc`, so C code must not call through the frame
/// directly — the LLVM-compiled wrapper gets the calling convention
/// right by construction (see lyric_async.c).
func coroWrapperDefine(name: in String, intrinsic: in String): NFunc {
  val p8 = NPtr(pointee = NI8)
  val params: List[NParam] = newList()
  params.add(NParam(name = "hdl", ty = p8))
  val body: List[NInsn] = newList()
  body.add(NLabel(name = "entry"))
  body.add(NCallVoid(fn = NGlobal(name = intrinsic), args = arg1(p8, NLocal(name = "hdl"))))
  body.add(NRetVoid)
  val attrs: List[String] = newList()
  NFunc(name = name, params = params, retTy = NVoid, isPublic = true, isExtern = false, body = body, attributes = attrs)
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
      case TFunction(_, _) -> tys.add(externCallbackNType(ctx, ef.params[i].ty))
      case _ -> tys.add(typeToN(ctx, ef.params[i].ty))
    }
    i = i + 1
  }
  val retN = retTypeToN(ctx, ef.ret)
  // A by-value record crosses as the platform's C ABI passes the struct
  // (#8009), on a target `cAbiArch` knows.
  if cAbiArch(ctx.abiTriple).length > 0 and cAbiCovers(tys, retN) {
    return cAbiExternDecl(ctx, ef.symbol, tys, retN)
  }
  // Backstop for `nativeByValueExternDiagnostics`: never emit an LLVM
  // aggregate where the C ABI expects the platform's struct passing.
  var k = 0
  while k < tys.count {
    if isByValueStructNType(tys[k]) {
      panic(
        "N0010: " + byValueExternMessage(ef.name, byValueRecName(tys[k]), ctx.unionDefs.containsKey(byValueRecName(tys[k])))
      )
    }
    match tys[k] {
      case NArray(_, _) -> panic("N0010: " + byValueExternMessage(ef.name, "array", false))
      case _ -> ()
    }
    k = k + 1
  }
  match retN {
    case NArray(_, _) -> panic("N0010: " + byValueExternMessage(ef.name, "array", false))
    case _ -> ()
  }
  if isByValueStructNType(retN) {
    panic(
      "N0010: " + byValueExternMessage(ef.name, byValueRecName(retN), ctx.unionDefs.containsKey(byValueRecName(retN)))
    )
  }
  mkDeclN(ef.symbol, retN, tys)
}

/// The symbol the platform's startup code calls with `(argc, argv)`.  wasi-libc's
/// `_start` reaches the program through `__main_argc_argv` (clang renames a C
/// `main(int, char**)` to it); a plain `main` there is an undefined weak
/// symbol that traps on entry.
func entryNameForTriple(triple: in String): String {
  if Str.startsWith(triple, "wasm32") {
    return "__main_argc_argv"
  }
  "main"
}

/// Synthesise the C-ABI `main` wrapper around the user's `func main`.
/// An `async func main` returns its task: drive the scheduler until it
/// completes, read the exit code, and drop the caller's task ref.
func synthCMain(
  mainPkg: in String,
  userMainRet: in NType,
  userMainIr: in String,
  mainIsAsync: in Bool,
  entryName: in String,
  initGlobalsIr: in String,
): NFunc {
  val p8 = NPtr(pointee = NI8)
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
  if initGlobalsIr.length > 0 {
    body.add(NCallVoid(fn = NGlobal(name = initGlobalsIr), args = noArgs))
  }
  if mainIsAsync {
    body.add(NCall(dest = "task", retTy = p8, fn = NGlobal(name = userMainIr), args = noArgs))
    body.add(NCallVoid(fn = NGlobal(name = "lyric_task_block_on"), args = arg1(p8, NLocal(name = "task"))))
    match userMainRet {
      case NI32 -> {
        body.add(
          NCall(dest = "slot", retTy = NI64, fn = NGlobal(name = "lyric_task_result"), args = arg1(p8, NLocal(name = "task")))
        )
        body.add(NTrunc(dest = "code", fromTy = NI64, value = NLocal(name = "slot"), toTy = NI32))
        body.add(NCallVoid(fn = NGlobal(name = "lyric_release"), args = arg1(p8, NLocal(name = "task"))))
        body.add(NRet(ty = NI32, value = NLocal(name = "code")))
      }
      case NVoid -> {
        body.add(NCallVoid(fn = NGlobal(name = "lyric_release"), args = arg1(p8, NLocal(name = "task"))))
        body.add(NRet(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
      }
      case _ -> panic("Lyric.LlvmCodegen: `func main` must return Int or Unit for --target native")
    }
    val asyncAttrs: List[String] = newList()
    return NFunc(
      name = entryName,
      params = params,
      retTy = NI32,
      isPublic = true,
      isExtern = false,
      body = body,
      attributes = asyncAttrs
    )
  }
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
    name = entryName,
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
  // Module-level `val`/`const` bindings across the whole bundle (#5977 part 2),
  // keyed BOTH by qualified name (`Pkg.name`) and bare name (`name`) — the same
  // two-part scheme `buildSigs` uses for functions (and `loadLocal` looks up
  // self-package-qualified FIRST, so a package's own binding always wins over a
  // same-named one in another bundled package — #6225). Bare keys are a
  // first-wins fallback for an imported/cross-package bare reference; `units[0]`
  // (the user package) registers first so its bare names shadow bundled ones.
  // The `containsKey` guard is required, not just policy: `Map.add` throws on a
  // duplicate key rather than overwriting (see `addSig`, and
  // `Std.Collections.mapPutAll`'s remove-then-add workaround), so an unguarded
  // `.add` would crash native compilation on any bare-name collision (#6224).
  val moduleVals: Map[String, ModuleValDef] = newMap()
  var mvUi = 0
  while mvUi < units.count {
    val upkg = units[mvUi].pkgName
    val mvs = units[mvUi].moduleVals
    var mvI = 0
    while mvI < mvs.count {
      val qkey = upkg + "." + mvs[mvI].name
      if not moduleVals.containsKey(qkey) {
        moduleVals.add(qkey, mvs[mvI])
      }
      if not moduleVals.containsKey(mvs[mvI].name) {
        moduleVals.add(mvs[mvI].name, mvs[mvI])
      }
      mvI = mvI + 1
    }
    mvUi = mvUi + 1
  }
  // Per-package `import Std.String` gate (#6588 review follow-up, #6752) —
  // see `Ctx.pkgImportsStdString`.
  val pkgImportsStdString: Map[String, Bool] = newMap()
  var impUi = 0
  while impUi < units.count {
    if not pkgImportsStdString.containsKey(units[impUi].pkgName) {
      pkgImportsStdString.add(units[impUi].pkgName, units[impUi].importsStdString)
    }
    impUi = impUi + 1
  }
  val methodCallArities: Map[String, Int] = newMap()
  for cu in units {
    for ak in mapKeys(cu.methodCallArities) {
      match mapGet(cu.methodCallArities, ak) {
        case Some(n) -> if not methodCallArities.containsKey(cu.pkgName + "|" + ak) {
          methodCallArities.add(cu.pkgName + "|" + ak, n)
        }
        case None -> ()
      }
    }
  }
  val emptySlots: Map[String, String] = newMap()
  val emptyTypes: Map[String, NType] = newMap()
  val emptyEnumTypes: Map[String, String] = newMap()
  val emptyIsChar: Map[String, Bool] = newMap()
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
    ptrBytes = ptrBytesForTriple(triple),
    abiTriple = triple,
    strTicker = newList(),
    varSlots = emptySlots,
    varTypes = emptyTypes,
    varEnumTypes = emptyEnumTypes,
    varIsChar = emptyIsChar,
    allocas = newList(),
    loopBreak = newList(),
    loopCont = newList(),
    globals = newList(),
    sigs = sigs,
    pkgImportsStdString = pkgImportsStdString,
    sigAlts = buildSigAlts(units, sigs),
    pkgImports = buildPkgImports(units),
    methodCallArities = methodCallArities,
    curPkg = newList(),
    curOrigin = newList(),
    curRet = newList(),
    moduleVals = moduleVals,
    mvInits = newList(),
    mvInitTys = newList(),
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
    unionEqFns = newMap(),
    genericFnDefs = emptyGenFns,
    genericFnPkg = emptyGenFnPkg,
    fnInstCache = emptyFnInsts,
    instMeta = emptyInstMeta,
    fnTyEnvNames = newList(),
    fnTyEnvTys = newList(),
    pendingCallRetWant = newList(),
    closureSigs = emptyClosureSigs,
    trampolines = newMap(),
    weakTargets = emptyWeakTargets,
    listElems = newMap(),
    mapKeyTys = newMap(),
    mapValTys = newMap(),
    ifaceInfos = newMap(),
    ifaceBareNameOwners = newMap(),
    ifaceVtables = newMap(),
    implDirectMethods = newMap(),
    protectedRecNames = newMap(),
    heapOnlyRecs = newMap(),
    byValueBoxes = newMap(),
    inlineAddrs = newMap(),
    scopeRefs = newList(),
    tempScopes = newList(),
    loopVarDepth = newList(),
    loopTempDepth = newList(),
    loopLabelIndex = newMap(),
    deferStack = newList(),
    enumTypeUndo = newList(),
    bindingUndo = newList(),
    taskElems = newMap(),
    curAsyncTask = newList(),
    usesAsync = newList()
  )
  // Type definitions and synthesised functions accumulate on the ctx so
  // lazy generic instantiation (typeToN during lowering) can append.
  val fns = ctx.moduleFns
  val types = ctx.moduleTypeDefs
  val sFields: List[NType] = newList()
  addArcHeader(sFields)
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
  registerImplVtables(ctx, units, fns)
  registerImplDirectMethods(ctx, units)
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
  var mainIsAsync = false
  var ui = 0
  while ui < units.count {
    val u = units[ui]
    var ei = 0
    while ei < u.externs.count {
      val ef = u.externs[ei]
      val llName = externLlName(u.wasmImports, ef.symbol)
      if not declaredExterns.containsKey(llName) {
        declaredExterns.add(llName, true)
        val plain = externDeclOf(ctx, ef)
        val importModule = wasmImportModule(u.wasmImports, ef.symbol)
        if importModule.length > 0 {
          val attrs: List[String] = newList()
          attrs.add("\"wasm-import-module\"=\"" + importModule + "\"")
          attrs.add("\"wasm-import-name\"=\"" + ef.symbol + "\"")
          externDecls.add(
            NFunc(
              name = llName,
              params = plain.params,
              retTy = plain.retTy,
              isPublic = plain.isPublic,
              isExtern = plain.isExtern,
              body = plain.body,
              attributes = attrs
            )
          )
        } else {
          externDecls.add(plain)
        }
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
        mainIsAsync = fn.isAsync
      }
      fi = fi + 1
    }
    ui = ui + 1
  }
  if mainIr.length > 0 {
    var initGlobalsIr = ""
    if ctx.mvInits.count > 0 {
      initGlobalsIr = "lyric_init_module_globals"
      for gf in synthModuleGlobalFns(initGlobalsIr, ctx.mvInits, ctx.mvInitTys) {
        fns.add(gf)
      }
    }
    fns.add(synthCMain(mainPkg, mainRet, mainIr, mainIsAsync, entryNameForTriple(triple), initGlobalsIr))
  }
  // Coroutine plumbing lands only in async-using modules: the coro
  // intrinsics + scheduler declares, and the resume/destroy wrapper
  // defines the C scheduler calls back through (see coroWrapperDefine).
  if ctx.usesAsync.count > 0 {
    val aDecls = asyncRuntimeDecls()
    var adi = 0
    while adi < aDecls.count {
      if not declaredExterns.containsKey(aDecls[adi].name) {
        declaredExterns.add(aDecls[adi].name, true)
        externDecls.add(aDecls[adi])
      }
      adi = adi + 1
    }
    fns.add(coroWrapperDefine("lyric_coro_resume", "llvm.coro.resume"))
    fns.add(coroWrapperDefine("lyric_coro_destroy", "llvm.coro.destroy"))
  }
  val libs: List[String] = newList()
  for u in units {
    for lib in u.nativeLibs {
      if not listContains(libs, lib) {
        libs.add(lib)
      }
    }
  }
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

/// Mirrors `Msil.Codegen.hasAnnotationMsil` / `Jvm.Codegen.hasAnnotationJvm`
/// (each backend keeps its own private copy; there is no shared
/// AST-utility package for this today). Checks the annotation's leading
/// path segment, e.g. `@projectable` or `@projectable(json, sql)`.
func hasAnnotationNative(anns: in List[Annotation], headName: in String): Bool {
  var i = 0
  while i < anns.count {
    val segs = anns[i].name.segments
    if segs.count > 0 and segs[0] == headName {
      return true
    }
    i = i + 1
  }
  false
}

/// #6239 (review follow-up to #6234 part 1): `opaqueToRecordDecl` only
/// carries over an opaque type's fields — `RecordDecl` has no
/// `annotations` field, so EVERY annotation on the source
/// `OpaqueTypeDecl` (`decl.annotations`, the trailing-position list
/// `parseOpaqueTypeBody` populates) is dropped. Most annotations are
/// harmless to drop at the codegen layer (e.g. `@stable(since = ...)`
/// is front-end/doc/contract-meta-only on every target — it carries no
/// codegen semantics on `Msil.Codegen`/`Jvm.Codegen` either). But
/// `@projectable` is a real, both-targets-shipped feature (D015):
/// `Msil.Codegen`/`Jvm.Codegen` synthesise a `<Name>View` exposed-record
/// twin plus `toView()`/`tryInto()` conversion functions whenever
/// `hasAnnotationMsil`/`hasAnnotationJvm(decl.annotations,
/// "projectable")` is true. Silently dropping `@projectable` here would
/// let a `@projectable opaque type` compile "successfully" for
/// `--target native` with zero diagnostic while quietly losing that
/// projection surface — an undocumented cross-target parity gap, which
/// CLAUDE.md's production-readiness standard rules out. `@projectable`
/// native codegen is real, separate feature work (a `<Name>View` twin
/// has no native-IR analog yet); until that lands, fail loud rather
/// than silently: `N0101`, mirroring the existing `N0099` "construct
/// not yet lowered on this target" convention used elsewhere in this
/// file (native codegen has no diagnostics-collection mechanism, so
/// house style for a target-unsupported construct is a `panic` whose
/// message leads with the code, not a collected `Diagnostic` — that's
/// the mode checker's own mechanism, e.g. `N0100`).
func checkOpaqueNativeSupported(od: in OpaqueTypeDecl): Unit {
  if hasAnnotationNative(od.annotations, "projectable") {
    panic(
      "N0101: @projectable opaque type '" + od.name + "' is not supported for --target native (the <Name>View projection " +
        "type plus toView()/tryInto() codegen exists on --target dotnet and " +
        "--target jvm only; native has no synthesized-view codegen yet, " +
        "tracked in #6234). Drop @projectable, or use --target dotnet / " +
        "--target jvm for this type."
    )
  }
}

/// `opaque type` has no native codegen of its own (#6234 part 1):
/// opacity is a front-end visibility concern enforced by the type
/// checker's cross-package field-read restriction
/// (`Lyric.TypeChecker.checkOpaqueDeclTypes`), not a codegen concern —
/// the underlying heap layout, construction, field access, and ARC
/// destructor synthesis are structurally identical to a record's, the
/// same premise `Msil.Codegen`/`Jvm.Codegen` already act on (an opaque
/// type lowers to an ordinary class with private fields there). This
/// reshapes an `OpaqueTypeDecl` into the equivalent `RecordDecl` so
/// every existing record code path — `registerRecordLayout`,
/// `lowerRecordConstructArgs`, `lowerRecordFieldLoad`,
/// `recHasRefFields`/`synthRecordDtor`, generic record instantiation —
/// handles opaque types for free, with zero duplicated logic. A
/// custom-destructor hook for opaque types wrapping a raw resource
/// (e.g. a `NativePtr` OS handle) is a separate, unimplemented gap
/// (#6234 part 2, deliberately out of scope here): this conversion only
/// makes an opaque type's ARC-managed fields (Strings, other heap
/// objects) release correctly, exactly like a record's — a future
/// opaque type wrapping an inert resource still leaks it, same as a
/// record would today. Calls `checkOpaqueNativeSupported` first (#6239):
/// a `RecordDecl` has no `annotations` field, so this reshape would
/// otherwise silently drop `@projectable` along with every other
/// annotation — see that function's comment for why `@projectable`
/// specifically must fail loud instead.
pub func opaqueToRecordDecl(od: in OpaqueTypeDecl): RecordDecl {
  checkOpaqueNativeSupported(od)
  val members: List[RecordMember] = newList()
  var i = 0
  while i < od.members.count {
    match od.members[i] {
      case OMField(f) -> members.add(RMField(field = f))
      case OMInvariant(inv) -> members.add(RMInvariant(inv = inv))
    }
    i = i + 1
  }
  RecordDecl(name = od.name, generics = od.generics, whereClause = od.whereClause, members = members, span = od.span)
}

/// True when `file` has `import Std.String` (or `import Std.String as X`)
/// in scope — the per-package gate `.indexOf`'s and `.lastIndexOf`'s
/// shared scalar-method arm consults (#6588 review follow-up, #6752;
/// `.lastIndexOf` joined the same gate in #6755), mirroring
/// `Jvm.Codegen.fileImportsStdString` / `Msil.Codegen`'s `pkgImports`
/// check (both exist for the identical reason: routing `.indexOf`/
/// `.lastIndexOf` unconditionally through the raw host/runtime intrinsic
/// when the caller's file imports `Std.String` — and therefore expects
/// the real `Option[Int]`-returning `Std.String.indexOf`/`.lastIndexOf`
/// per `Lyric.TypeChecker.stringIndexOfMember` — reintroduces the #6348
/// class of memory corruption).
pub func fileImportsStdString(file: in SourceFile): Bool {
  var i = 0
  while i < file.imports.count {
    if modulePathJoin(file.imports[i].path.segments) == "Std.String" {
      return true
    }
    i = i + 1
  }
  false
}

/// The dotted package paths `file` imports.
pub func fileImportPackages(file: in SourceFile): List[String] {
  val pkgs: List[String] = newList()
  for imp in file.imports {
    pkgs.add(modulePathJoin(imp.path.segments))
  }
  pkgs
}

/// Collect one source file's lowerable items into a CodegenUnit.
pub func unitOfFile(pkgName: in String, file: in SourceFile): CodegenUnit {
  val fns: List[FunctionDecl] = newList()
  val externs: List[ExternFuncDecl] = newList()
  val nativeLibs: List[String] = newList()
  val wasmImports: List[WasmImportDecl] = newList()
  val records: List[RecordDecl] = newList()
  val opaqueNames: List[String] = newList()
  val unions: List[UnionDecl] = newList()
  val enums: List[EnumDecl] = newList()
  val distincts: List[DistinctTypeDecl] = newList()
  val interfaces: List[InterfaceDecl] = newList()
  val impls: List[ImplDecl] = newList()
  val protecteds: List[ProtectedTypeDecl] = newList()
  val moduleVals: List[ModuleValDef] = newList()
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(decl) -> fns.add(decl)
      case IExternFunc(decl) -> {
        externs.add(decl)
        addExternLibrary(nativeLibs, file.items[i].annotations)
        addWasmImport(wasmImports, decl.symbol, file.items[i].annotations)
      }
      // Module-level `val`/`const` (#5977 part 2): collect for use-site
      // inlining. A `val` with a non-binding (destructuring) pattern is not a
      // named module binding, so it is skipped here — consistent with the
      // bundle path (`unitOf` in llvm_bridge.l); a reference to it then surfaces
      // the `loadLocal` "unknown name" diagnostic at the use site rather than
      // failing an otherwise-unrelated compile at collection time.
      case IVal(decl) -> {
        match decl.pattern.kind {
          case PBinding(vn, _) -> moduleVals.add(ModuleValDef(name = vn, init = decl.init, ty = decl.ty, pkg = pkgName))
          case _ -> ()
        }
      }
      case IConst(decl) -> moduleVals.add(
        ModuleValDef(name = decl.name, init = decl.init, ty = Some(value = decl.ty), pkg = pkgName)
      )
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
      // A body-less forward declaration (`opaque type Foo` with no `{ ... }`)
      // has no fields and no runtime representation on any target (matches
      // the MSIL/JVM `decl.hasBody` guard) — nothing to lower.  Opaque
      // methods are ordinary UFCS functions (D037: `self: in Foo` receiver),
      // already collected above via `IFunc` regardless of the receiver
      // type's opacity, so no method collection is needed here.
      case IOpaque(decl) -> {
        if decl.hasBody {
          records.add(opaqueToRecordDecl(decl))
          opaqueNames.add(decl.name)
        }
      }
      case ITypeAlias(_) -> {
      }
      case IExternType(_) -> {
      }
      case _ -> panic(
        "Lyric.LlvmCodegen: this item form is not yet supported for --target native (Phase N2/N3 lowers functions, extern funcs, records, unions, enums, distinct types, interfaces, impls, and protected types)"
      )
    }
    i = i + 1
  }
  CodegenUnit(
    pkgName = pkgName,
    fns = fns,
    externs = externs,
    nativeLibs = nativeLibs,
    wasmImports = wasmImports,
    records = records,
    opaqueNames = opaqueNames,
    unions = unions,
    enums = enums,
    distincts = distincts,
    interfaces = interfaces,
    impls = impls,
    protecteds = protecteds,
    moduleVals = moduleVals,
    importsStdString = fileImportsStdString(file),
    imports = fileImportPackages(file),
    methodCallArities = newMap()
  )
}

/// Record the library an extern func's `@library("name")` names (D158),
/// once, leaving out "c", which every native link already includes.
pub func addExternLibrary(libs: in List[String], anns: in List[Annotation]): Unit {
  for a in anns {
    if a.name.segments.count == 1 and a.name.segments[0] == "library" and a.args.count == 1 {
      match a.args[0] {
        case ALiteral(value, _) -> match value {
          case AVString(lib, _) -> if lib != "c" and not listContains(libs, lib) {
            libs.add(lib)
          }
          case _ -> ()
        }
        case _ -> ()
      }
    }
  }
}

/// Why a `@wasmImport` module string cannot be used, or "" when it can.  The
/// string lands inside LLVM attribute quotes, so `"` and `\\` are rejected.
func wasmImportModuleProblem(module: in String): String {
  if module.length == 0 {
    return "the module name is empty"
  }
  if Str.contains(module, "\"") or Str.contains(module, "\\") {
    return "the module name must not contain a quote or backslash"
  }
  ""
}

/// Record `symbol` as a wasm import when `anns` carry `@wasmImport("module")`.
/// A malformed annotation is recorded with its `problem` so the glue reports it
/// (`N0014`) instead of silently treating the extern as an ordinary C one.
pub func addWasmImport(imports: in List[WasmImportDecl], symbol: in String, anns: in List[Annotation]): Unit {
  match findAnnotation(anns, "wasmImport") {
    case None -> ()
    case Some(a) -> {
      var module = ""
      var problem = "it needs exactly one string literal argument, the module name"
      match annotationStringArg(a) {
        case Some(m) -> {
          module = m
          problem = wasmImportModuleProblem(m)
        }
        case None -> ()
      }
      imports.add(
        WasmImportDecl(symbol = symbol, module = if problem.length == 0 { module } else { "" }, problem = problem)
      )
    }
  }
}

/// The LLVM symbol an extern is declared and called under.  A wasm import keeps
/// its JS-visible name in the `wasm-import-name` attribute, so its LLVM name is
/// namespaced: a host function called `log` must not collide with libm's.
pub func externLlName(imports: in List[WasmImportDecl], symbol: in String): String {
  val module = wasmImportModule(imports, symbol)
  if module.length > 0 {
    "wasmimport." + module + "." + symbol
  } else {
    symbol
  }
}

/// Why the `@wasmImport` on `symbol` is unusable, or "" when it is absent or fine.
pub func wasmImportProblem(imports: in List[WasmImportDecl], symbol: in String): String {
  for w in imports {
    if w.symbol == symbol and w.problem.length > 0 {
      return w.problem
    }
  }
  ""
}

/// The module `symbol` is imported from, or "" when it is an ordinary extern.
pub func wasmImportModule(imports: in List[WasmImportDecl], symbol: in String): String {
  for w in imports {
    if w.symbol == symbol {
      return w.module
    }
  }
  ""
}

/// Methods declared inside a record body desugar to package functions
/// with the explicit `self` receiver already in their parameter list
/// (D037), named `<Record>.<method>` as a dot-named function is; non-generic
/// ones lower like any other function.  The
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
              case None -> {
                // Registered as `<Record>.<method>`, so a same-named method of
                // another record in the package is a different function.
                val lifted = substSelfInFn(fn, decl.name)
                fns.add(lifted.copy(name = decl.name + "." + fn.name))
              }
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

/// True for a bare `Self` (optionally paren-wrapped) — the only nesting
/// depth `typeExprToNType`'s `TSelf` arm erases to `i8*` (#7585, D-progress-1016).
func isBareSelfTypeExpr(te: in TypeExpr): Bool {
  match te.kind {
    case TSelf -> true
    case TParen(inner) -> isBareSelfTypeExpr(inner)
    case _ -> false
  }
}

/// True when `Self` appears anywhere in `te` — bare, paren-wrapped, or
/// nested inside a generic argument, array/slice element, tuple field,
/// function parameter/return, or nullable wrapper.
func typeExprMentionsSelf(te: in TypeExpr): Bool {
  match te.kind {
    case TSelf -> true
    case TParen(inner) -> typeExprMentionsSelf(inner)
    case TGenericApp(_, args) -> {
      var i = 0
      while i < args.count {
        match args[i] {
          case TAType(t) -> if typeExprMentionsSelf(t) { return true }
          case TAValue(_) -> {
          }
        }
        i = i + 1
      }
      false
    }
    case TArray(_, element) -> typeExprMentionsSelf(element)
    case TSlice(element) -> typeExprMentionsSelf(element)
    case TTuple(types) -> {
      var i = 0
      while i < types.count {
        if typeExprMentionsSelf(types[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    case TNullable(inner) -> typeExprMentionsSelf(inner)
    case TFunction(parameters, retTy) -> {
      var i = 0
      while i < parameters.count {
        if typeExprMentionsSelf(parameters[i]) {
          return true
        }
        i = i + 1
      }
      typeExprMentionsSelf(retTy)
    }
    case _ -> false
  }
}

/// True when `Self` appears NESTED (inside a generic argument, array/slice
/// element, tuple field, or function type) rather than bare — the shape
/// native cannot erase uniformly (#7585): `List[Self]`/`Option[Self]`
/// would need a monomorphized "List/Option of a pointer-width erased Self"
/// instantiation per interface, which `Lyric.Mono`'s call-site-inferred
/// generics (D-N-010) has no mechanism to synthesise from an interface
/// declaration alone (there is no concrete call site to infer `T = Self`
/// from). Callers reject this shape with a named diagnostic instead of
/// falling into the vaguer generic-type-not-supported panic.
func typeExprHasNestedSelf(te: in TypeExpr): Bool {
  typeExprMentionsSelf(te) and not isBareSelfTypeExpr(te)
}

/// One nested-`Self` shape found in a signature: `where_` names the
/// offending parameter/return for the message, `span` locates it.
record NestedSelfShape {
  where_: String
  span: Span
}

/// Every nested-`Self` shape (`List[Self]`, ...) in `sig`'s params/return
/// (#7618 review): the ONE traversal `registerInterfaceNames`'s panic path
/// and `nativeSelfShapeDiagnostics`'s diagnostic path both walk, factored
/// out so the two can never drift — each caller just picks what to DO with
/// a found shape (panic immediately vs. collect an `N0006` `Diagnostic`).
func nestedSelfShapesInSig(sig: in FunctionSig): List[NestedSelfShape] {
  val acc: List[NestedSelfShape] = newList()
  var pi = 0
  while pi < sig.params.count {
    if typeExprHasNestedSelf(sig.params[pi].ty) {
      acc.add(NestedSelfShape(where_ = "parameter '" + sig.params[pi].name + "'", span = sig.params[pi].ty.span))
    }
    pi = pi + 1
  }
  match sig.ret {
    case Some(r) -> if typeExprHasNestedSelf(r) { acc.add(NestedSelfShape(where_ = "return type", span = r.span)) }
    case None -> {
    }
  }
  acc
}

/// Shared message text for `N0006` (nested `Self`), used by both the
/// structured `Diagnostic` `nativeSelfShapeDiagnostics` produces (the
/// primary path — `Lyric.LlvmBridge` reports it and aborts the build
/// BEFORE codegen ever runs, no exception, no stack trace) and the
/// defensive fallback panic below (only reachable for a caller that
/// invokes `codegenNativePackage`/`codegenNativeBundle` directly, without
/// going through `Lyric.LlvmBridge`'s pre-pass — e.g. a self-test).
func nestedSelfShapeMessage(ifaceName: in String, methodName: in String, where_: in String): String {
  "interface '" + ifaceName + "' method '" + methodName + "' " + where_ +
    " mentions 'Self' nested inside a generic type — --target native supports a bare 'Self' parameter/return (erased to a pointer, #7585) but not 'Self' nested inside a generic type argument (e.g. 'List[Self]'/'Option[Self]'); this shape is not yet supported for --target native"
}

/// `N0006`: `Self` nested inside a generic type argument in an interface
/// method signature, for `--target native` (#7585). See
/// `nativeSelfShapeDiagnostics` — the primary detection path, run as a
/// pre-pass in `Lyric.LlvmBridge` before codegen.
func nestedSelfShapeDiagnostic(
  ifaceName: in String, methodName: in String, where_: in String, span: in Span
): Diagnostic {
  errorDiagnostic("N0006", nestedSelfShapeMessage(ifaceName, methodName, where_), span)
}

/// Defensive-only fallback: panics with the SAME message `N0006` reports,
/// for a caller that lowers `units` directly (`codegenNativePackage`/
/// `codegenNativeBundle`) without first running `nativeSelfShapeDiagnostics`
/// through `Lyric.LlvmBridge`'s pre-pass. Never reached by `lyric build
/// --target native` (the bridge's pre-pass catches every case first and
/// aborts the build with a proper `error[N0006]` line, no exception).
func panicUnsupportedSelfShape(ifaceName: in String, methodName: in String, where_: in String, span: in Span): Unit {
  panic(
    "Lyric.LlvmCodegen: [N0006] " + nestedSelfShapeMessage(ifaceName, methodName, where_) + " (at " +
      span.startPos.line.toString() +
      ":" +
      span.startPos.column.toString() +
      ")"
  )
}

/// Pre-pass (#7585): every `Self`-nested-in-a-generic-type-argument shape
/// across every non-generic interface in `units`, as `N0006` diagnostics —
/// no panic, no exception. `Lyric.LlvmBridge`'s native entry points run
/// this BEFORE calling into codegen (`registerInterfaceNames`'s own check,
/// `panicUnsupportedSelfShape`, is an unreachable defensive fallback for
/// bridge callers once this runs first) so `lyric build --target native`
/// reports a normal `error[N0006] file:line:col: ...` line and exits
/// non-zero, matching every other native pre-codegen diagnostic gate
/// (mode-checker `N0100`, etc.) instead of an internal exception.
pub func nativeSelfShapeDiagnostics(units: in List[CodegenUnit]): List[Diagnostic] {
  val diags: List[Diagnostic] = newList()
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
          val sigs = nonGenericSyncSigs(idecl)
          var mi = 0
          while mi < sigs.count {
            val sig = sigs[mi]
            val shapes = nestedSelfShapesInSig(sig)
            var si = 0
            while si < shapes.count {
              diags.add(nestedSelfShapeDiagnostic(qualified, sig.name, shapes[si].where_, shapes[si].span))
              si = si + 1
            }
            mi = mi + 1
          }
        }
      }
      ii = ii + 1
    }
    ua = ua + 1
  }
  diags
}

/// The by-value record a type written as `te` names, or "" when it names
/// anything else.
func byValueRecordNameOf(st: in NByValState, pkg: in String, te: in TypeExpr): String {
  match te.kind {
    // A callback type: its parameters and return cross the C boundary too.
    case TFunction(parameters, retTy) -> {
      for pt in parameters {
        val n = byValueRecordNameOf(st, pkg, pt)
        if n.length > 0 {
          return n
        }
      }
      return byValueRecordNameOf(st, pkg, retTy)
    }
    case TParen(inner) -> return byValueRecordNameOf(st, pkg, inner)
    case _ -> {
    }
  }
  val ft = classifyByValueField(st, pkg, te)
  if ft.count == 1 {
    match ft[0] {
      case NArray(_, _) -> return "array"
      case _ -> ()
    }
    return byValueRecName(ft[0])
  }
  ""
}

// ─────────────────────────────────────────────────────────────────────────────
// C ABI for by-value records at the extern boundary (#8009).
//
// A by-value record is an LLVM struct value, and LLVM passes a first-class
// aggregate argument field by field, which is not how C passes a struct.  An
// `extern func` taking or returning one is declared and called the way clang
// lowers the matching C prototype:
//
//   x86-64 System V: a record of at most 16 bytes travels in one or two
//     eightbytes, each a `double` (only float/double fields, in an SSE
//     register) or an `i64` (in a general register); a larger one, or one
//     the remaining registers cannot hold, is `byval` memory; a large
//     result is returned through an `sret` pointer.
//   AArch64 (AAPCS64): a homogeneous aggregate of one to four floats or
//     doubles is an `[N x T]` in FP registers; any other record of at most
//     16 bytes is an `i64` or `[2 x i64]`; a larger one is passed as a pointer
//     to a copy the caller makes, and returned through `sret`.
//   wasm32 (basic C ABI): a record of a single scalar is that scalar; any
//     other is `byval`, and returned through `sret`.
//
// A coerced value goes through a 16-byte stack buffer, so an eightbyte that
// runs past the end of the record never reads beyond its storage; the callee
// never reads the bytes past the record (System V and AAPCS64 leave a
// register's upper bits unspecified).
// ─────────────────────────────────────────────────────────────────────────────
union CArgAbi {
  case CAPlain
  case CAParts(parts: List[NType])
  case CAArray(elem: NType, count: Int, attrs: String)
  case CAByval
  case CAPtr
}

union CRetAbi {
  case CRPlain
  case CRParts(parts: List[NType])
  case CRArray(elem: NType, count: Int)
  case CRSret
}

record CAbiPlan {
  args: List[CArgAbi]
  ret: CRetAbi
}

/// The C ABI family of `triple`: "x86_64", "aarch64", "wasm32", or "" for a
/// target whose struct passing the backend does not lower (N0010 there).
pub func cAbiArch(triple: in String): String {
  if Str.contains(triple, "windows") or Str.contains(triple, "mingw") {
    return ""
  }
  if Str.startsWith(triple, "x86_64") {
    return "x86_64"
  }
  if Str.startsWith(triple, "aarch64") or Str.startsWith(triple, "arm64") {
    return "aarch64"
  }
  if Str.startsWith(triple, "wasm32") {
    return "wasm32"
  }
  ""
}

// Whether every by-value aggregate in a signature is a record the C ABI
// lowering covers: an inline array or union, or a by-value record inside a
// callback type, keeps N0010.
func cAbiCovers(tys: in List[NType], ret: in NType): Bool {
  for t in tys {
    if not cAbiTypeCovered(t) {
      return false
    }
  }
  cAbiTypeCovered(ret)
}

func cAbiTypeCovered(t: in NType): Bool {
  match t {
    case NArray(_, _) -> false
    case NStruct(name, _) -> not Str.startsWith(name, "__")
    case NFnPtr(ps, r) -> {
      for p in ps {
        if isBoxedValueNType(p) {
          return false
        }
      }
      not isBoxedValueNType(r)
    }
    case _ -> true
  }
}

func cAbiNeeded(args: in List[NArg], ret: in NType): Bool {
  for a in args {
    if isByValueStructNType(a.ty) {
      return true
    }
  }
  isByValueStructNType(ret)
}

// One scalar of a by-value record, at its byte offset.
record CScalar {
  offset: Int
  ty: NType
}

// The scalars of `t` at their offsets from `base`, nested records and inline
// arrays flattened.
func cFlatten(ctx: in Ctx, t: in NType, base: in Int, acc: in List[CScalar]): Unit {
  match t {
    case NStruct(name, _) -> {
      val fields = layoutFieldTys(byValueLayoutOf(ctx, name))
      var off = 0
      for f in fields {
        off = roundUpTo(off, alignOfN(ctx, f))
        cFlatten(ctx, f, base + off, acc)
        off = off + sizeOfN(ctx, f)
      }
    }
    case NArray(elem, n) -> {
      val sz = sizeOfN(ctx, elem)
      var i = 0
      while i < n {
        cFlatten(ctx, elem, base + i * sz, acc)
        i = i + 1
      }
    }
    case _ -> acc.add(CScalar(offset = base, ty = t))
  }
}

func isCFloatNType(t: in NType): Bool {
  match t {
    case NFloat -> true
    case NDouble -> true
    case _ -> false
  }
}

// AArch64 homogeneous floating-point aggregate: one to four scalars, all
// `float` or all `double`.
func cHfaElem(scalars: in List[CScalar]): Option[NType] {
  if scalars.count == 0 or scalars.count > 4 {
    return None
  }
  val first = scalars[0].ty
  if not isCFloatNType(first) {
    return None
  }
  for sc in scalars {
    if nTypeToIrString(sc.ty) != nTypeToIrString(first) {
      return None
    }
  }
  Some(value = first)
}

// x86-64: the eightbytes of a record of at most 16 bytes, `double` for an
// SSE one (only floating-point scalars) and `i64` for an INTEGER one.
func cSysvParts(ctx: in Ctx, t: in NType): List[NType] {
  val scalars: List[CScalar] = newList()
  cFlatten(ctx, t, 0, scalars)
  val size = sizeOfN(ctx, t)
  val parts: List[NType] = newList()
  var eb = 0
  while eb * 8 < size {
    var allFloat = true
    var any = false
    for sc in scalars {
      if sc.offset >= eb * 8 and sc.offset < eb * 8 + 8 {
        any = true
        if not isCFloatNType(sc.ty) {
          allFloat = false
        }
      }
    }
    parts.add(if any and allFloat { NDouble } else { NI64 })
    eb = eb + 1
  }
  parts
}

func cRetAbiOf(ctx: in Ctx, arch: in String, ret: in NType): CRetAbi {
  if not isByValueStructNType(ret) {
    return CRPlain
  }
  val size = sizeOfN(ctx, ret)
  val scalars: List[CScalar] = newList()
  cFlatten(ctx, ret, 0, scalars)
  if arch == "x86_64" {
    if size > 16 {
      return CRSret
    }
    return CRParts(parts = cSysvParts(ctx, ret))
  }
  if arch == "aarch64" {
    // A homogeneous aggregate is returned as the record itself, which LLVM
    // returns in consecutive FP registers, as clang does.
    match cHfaElem(scalars) {
      case Some(_) -> return CRPlain
      case None -> ()
    }
    if size > 16 {
      return CRSret
    }
    if size > 8 {
      return CRArray(elem = NI64, count = 2)
    }
    return CRParts(parts = listOfNType(NI64))
  }
  if scalars.count == 1 {
    return CRParts(parts = listOfNType(scalars[0].ty))
  }
  CRSret
}

/// How each parameter and the result of a C call cross the boundary.
func cAbiPlanOf(ctx: in Ctx, params: in List[NType], ret: in NType): CAbiPlan {
  val arch = cAbiArch(ctx.abiTriple)
  val args: List[CArgAbi] = newList()
  val retAbi = cRetAbiOf(ctx, arch, ret)
  // System V register budget: six general and eight SSE argument registers;
  // an `sret` pointer takes the first general one.  Only x86-64 needs it: on
  // AArch64 an aggregate the registers cannot hold still takes the same
  // coerced form and LLVM places it on the stack, as clang's own lowering
  // does, and wasm32 has no argument registers.
  var intLeft = 6
  var sseLeft = 8
  match retAbi {
    case CRSret -> {
      intLeft = intLeft - 1
    }
    case _ -> ()
  }
  for p in params {
    if not isByValueStructNType(p) {
      if isCFloatNType(p) {
        sseLeft = sseLeft - 1
      } else {
        intLeft = intLeft - 1
      }
      args.add(CAPlain)
      continue
    }
    val size = sizeOfN(ctx, p)
    val scalars: List[CScalar] = newList()
    cFlatten(ctx, p, 0, scalars)
    if arch == "x86_64" {
      if size > 16 {
        args.add(CAByval)
      } else {
        val parts = cSysvParts(ctx, p)
        var needInt = 0
        var needSse = 0
        for pt in parts {
          if isCFloatNType(pt) {
            needSse = needSse + 1
          } else {
            needInt = needInt + 1
          }
        }
        if needInt <= intLeft and needSse <= sseLeft {
          intLeft = intLeft - needInt
          sseLeft = sseLeft - needSse
          args.add(CAParts(parts = parts))
        } else {
          args.add(CAByval)
        }
      }
    } else if arch == "aarch64" {
      match cHfaElem(scalars) {
        case Some(el) -> args.add(CAArray(elem = el, count = scalars.count, attrs = "alignstack(8)"))
        case None -> if size > 16 {
          args.add(CAPtr)
        } else if size > 8 {
          args.add(CAArray(elem = NI64, count = 2, attrs = ""))
        } else {
          args.add(CAParts(parts = listOfNType(NI64)))
        }
      }
    } else if scalars.count == 1 {
      args.add(CAParts(parts = listOfNType(scalars[0].ty)))
    } else {
      args.add(CAByval)
    }
  }
  CAbiPlan(args = args, ret = retAbi)
}

func listOfNType(t: in NType): List[NType] {
  val xs: List[NType] = newList()
  xs.add(t)
  xs
}

func cAggregateAttr(ctx: in Ctx, kind: in String, t: in NType): String {
  kind + "(" + nTypeToIrString(t) + ") align " + toString(alignOfN(ctx, t))
}

// The LLVM return type a plan's result crosses as.
func cRetNType(ret: in CRetAbi, declared: in NType): NType {
  match ret {
    case CRPlain -> declared
    case CRParts(parts) -> if parts.count == 1 { parts[0] } else { NLitStruct(fields = parts) }
    case CRArray(el, n) -> NArray(elem = el, size = n)
    case CRSret -> NVoid
  }
}

/// The `declare` of an extern whose signature carries a by-value record.
func cAbiExternDecl(ctx: in Ctx, name: in String, tys: in List[NType], ret: in NType): NFunc {
  val plan = cAbiPlanOf(ctx, tys, ret)
  NFunc(
    name = name,
    params = cAbiParams(ctx, plan, tys, ret),
    retTy = cRetNType(plan.ret, ret),
    isPublic = false,
    isExtern = true,
    body = newList(),
    attributes = newList()
  )
}

// The C-facing parameters of a signature under `plan`: an `sret` pointer
// first, then each parameter as one or more LLVM arguments, `p<i>` (a
// coerced record's parts `p<i>_<k>`).
func cAbiParams(ctx: in Ctx, plan: in CAbiPlan, tys: in List[NType], ret: in NType): List[NParam] {
  val params: List[NParam] = newList()
  match plan.ret {
    case CRSret -> params.add(NParam(name = "sret", ty = NPtr(pointee = ret), attrs = cAggregateAttr(ctx, "sret", ret)))
    case _ -> ()
  }
  var i = 0
  while i < tys.count {
    val nm = "p" + toString(i)
    match plan.args[i] {
      case CAPlain -> params.add(NParam(name = nm, ty = tys[i]))
      case CAParts(parts) -> {
        var k = 0
        while k < parts.count {
          params.add(NParam(name = nm + "_" + toString(k), ty = parts[k]))
          k = k + 1
        }
      }
      case CAArray(el, n, at) -> params.add(NParam(name = nm, ty = NArray(elem = el, size = n), attrs = at))
      case CAByval -> params.add(
        NParam(name = nm, ty = NPtr(pointee = tys[i]), attrs = cAggregateAttr(ctx, "byval", tys[i]))
      )
      case CAPtr -> params.add(NParam(name = nm, ty = NPtr(pointee = tys[i])))
    }
    i = i + 1
  }
  params
}

/// The C-facing function-pointer type of an extern callback parameter: a
/// signature carrying a by-value record crosses as C passes it (#8009).
func externCallbackNType(ctx: in Ctx, te: in TypeExpr): NType {
  match te.kind {
    case TParen(inner) -> externCallbackNType(ctx, inner)
    case TFunction(parameters, retTy) -> match callbackCAbi(ctx, parameters, retTy) {
      case Some(cb) -> {
        val ptys: List[NType] = newList()
        for prm in cAbiParams(ctx, cb.plan, cb.params, cb.ret) {
          ptys.add(prm.ty)
        }
        NFnPtr(params = ptys, ret = cRetNType(cb.plan.ret, cb.ret))
      }
      case None -> typeExprToNType(te)
    }
    case _ -> typeExprToNType(te)
  }
}

record CCallbackAbi {
  params: List[NType]
  ret: NType
  plan: CAbiPlan
}

// A callback signature's own types and C ABI plan, when one of them is a
// by-value record on a target the lowering covers.
func callbackCAbi(ctx: in Ctx, parameters: in List[TypeExpr], retTy: in TypeExpr): Option[CCallbackAbi] {
  if cAbiArch(ctx.abiTriple).length == 0 {
    return None
  }
  val ps: List[NType] = newList()
  var any = false
  for pt in parameters {
    val t = typeToN(ctx, pt)
    if isByValueStructNType(t) {
      any = true
    }
    ps.add(t)
  }
  val r = typeToN(ctx, retTy)
  if isByValueStructNType(r) {
    any = true
  }
  if not any {
    return None
  }
  Some(value = CCallbackAbi(params = ps, ret = r, plan = cAbiPlanOf(ctx, ps, r)))
}

/// The trampoline for a callback whose signature carries a by-value record:
/// it takes the C-ABI form, rebuilds each record, calls the closure, and
/// returns the result as C expects it.
func cAbiTrampoline(ctx: in Ctx, name: in String, closTy: in NType, cb: in CCallbackAbi): NFunc {
  val closStruct = match closTy { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  val n = cb.params.count
  val allocas: List[NInsn] = newList()
  val body: List[NInsn] = newList()
  val udName = "p" + toString(n - 1)
  body.add(NBitcast(dest = "hdr", fromTy = NPtr(pointee = NI8), value = NLocal(name = udName), toTy = closTy))
  val gArgs: List[NArg] = newList()
  gArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  gArgs.add(NArg(ty = NI32, value = NLitInt(v = closureFnSlot, ty = NI32)))
  body.add(NGEP(dest = "slot", ty = closStruct, ptr = NLocal(name = "hdr"), indices = gArgs))
  body.add(NLoad(dest = "fnraw", ty = NPtr(pointee = NI8), ptr = NLocal(name = "slot")))
  val lyricParams: List[NType] = newList()
  lyricParams.add(NPtr(pointee = NI8))
  val callArgs: List[NArg] = newList()
  callArgs.add(NArg(ty = NPtr(pointee = NI8), value = NLocal(name = udName)))
  val scratchTy = NArray(elem = NI64, size = 2)
  var i = 0
  while i < n - 1 {
    val t = cb.params[i]
    val nm = "p" + toString(i)
    lyricParams.add(t)
    val v: NValue = match cb.plan.args[i] {
      case CAPlain -> NLocal(name = nm)
      case CAParts(parts) -> {
        val buf = cScratchSlot(ctx, allocas)
        var k = 0
        while k < parts.count {
          cStoreAt(ctx, body, buf, scratchTy, k * 8, parts[k], NLocal(name = nm + "_" + toString(k)))
          k = k + 1
        }
        cLoadAt(ctx, body, buf, scratchTy, 0, t)
      }
      case CAArray(el, cnt, _) -> {
        val arrTy = NArray(elem = el, size = cnt)
        if isCFloatNType(el) {
          val slot = freshTmp(ctx)
          allocas.add(NAlloca(dest = slot, ty = t))
          cStoreAt(ctx, body, slot, t, 0, arrTy, NLocal(name = nm))
          val rv = freshTmp(ctx)
          body.add(NLoad(dest = rv, ty = t, ptr = NLocal(name = slot)))
          NLocal(name = rv)
        } else {
          val buf = cScratchSlot(ctx, allocas)
          cStoreAt(ctx, body, buf, scratchTy, 0, arrTy, NLocal(name = nm))
          cLoadAt(ctx, body, buf, scratchTy, 0, t)
        }
      }
      case CAByval -> {
        val rv = freshTmp(ctx)
        body.add(NLoad(dest = rv, ty = t, ptr = NLocal(name = nm)))
        NLocal(name = rv)
      }
      case CAPtr -> {
        val rv = freshTmp(ctx)
        body.add(NLoad(dest = rv, ty = t, ptr = NLocal(name = nm)))
        NLocal(name = rv)
      }
    }
    callArgs.add(NArg(ty = t, value = v))
    i = i + 1
  }
  body.add(
    NBitcast(
      dest = "fn",
      fromTy = NPtr(pointee = NI8),
      value = NLocal(name = "fnraw"),
      toTy = NFnPtr(params = lyricParams, ret = cb.ret)
    )
  )
  val cRet = cRetNType(cb.plan.ret, cb.ret)
  match cb.ret {
    case NVoid -> {
      body.add(NCallVoid(fn = NLocal(name = "fn"), args = callArgs))
      body.add(NRetVoid)
    }
    case rt -> {
      body.add(NCall(dest = "r", retTy = rt, fn = NLocal(name = "fn"), args = callArgs))
      match cb.plan.ret {
        case CRPlain -> body.add(NRet(ty = rt, value = NLocal(name = "r")))
        case CRSret -> {
          body.add(NStore(ty = rt, value = NLocal(name = "r"), ptr = NLocal(name = "sret")))
          body.add(NRetVoid)
        }
        case _ -> {
          val buf = cScratchSlot(ctx, allocas)
          cStoreAt(ctx, body, buf, scratchTy, 0, rt, NLocal(name = "r"))
          body.add(NRet(ty = cRet, value = cLoadAt(ctx, body, buf, scratchTy, 0, cRet)))
        }
      }
    }
  }
  val full: List[NInsn] = newList()
  for a in allocas {
    full.add(a)
  }
  for b in body {
    full.add(b)
  }
  NFunc(
    name = name,
    params = cAbiParams(ctx, cb.plan, cb.params, cb.ret),
    retTy = cRet,
    isPublic = false,
    isExtern = false,
    body = full,
    attributes = newList()
  )
}

// Store `v` of type `vTy` `byteOffset` bytes into the slot `slot` of type
// `slotTy`.
func cStoreAt(
  ctx: in Ctx,
  insns: in List[NInsn],
  slot: in String,
  slotTy: in NType,
  byteOffset: in Int,
  vTy: in NType,
  v: in NValue,
): Unit {
  val raw = freshTmp(ctx)
  insns.add(
    NBitcast(dest = raw, fromTy = NPtr(pointee = slotTy), value = NLocal(name = slot), toTy = NPtr(pointee = NI8))
  )
  val at = freshTmp(ctx)
  val idx: List[NArg] = newList()
  idx.add(NArg(ty = NI64, value = NLitInt(v = byteOffset.toLong(), ty = NI64)))
  insns.add(NGEP(dest = at, ty = NI8, ptr = NLocal(name = raw), indices = idx))
  val typed = freshTmp(ctx)
  insns.add(NBitcast(dest = typed, fromTy = NPtr(pointee = NI8), value = NLocal(name = at), toTy = NPtr(pointee = vTy)))
  insns.add(NStore(ty = vTy, value = v, ptr = NLocal(name = typed)))
}

// A 16-byte, 8-aligned stack buffer that a record of at most 16 bytes is
// stored into and read back out of as its coerced parts.
func cScratchSlot(ctx: in Ctx, allocas: in List[NInsn]): String {
  val slot = freshTmp(ctx)
  allocas.add(NAlloca(dest = slot, ty = NArray(elem = NI64, size = 2)))
  slot
}

// A stack slot of the record's own type holding `v`.
func cSpill(ctx: in Ctx, allocas: in List[NInsn], insns: in List[NInsn], ty: in NType, v: in NValue): String {
  val slot = freshTmp(ctx)
  allocas.add(NAlloca(dest = slot, ty = ty))
  insns.add(NStore(ty = ty, value = v, ptr = NLocal(name = slot)))
  slot
}

// The value of type `asTy` stored `byteOffset` bytes into the slot `slot`
// of type `slotTy`.
func cLoadAt(
  ctx: in Ctx, insns: in List[NInsn], slot: in String, slotTy: in NType, byteOffset: in Int, asTy: in NType
): NValue {
  val raw = freshTmp(ctx)
  insns.add(
    NBitcast(dest = raw, fromTy = NPtr(pointee = slotTy), value = NLocal(name = slot), toTy = NPtr(pointee = NI8))
  )
  val at = freshTmp(ctx)
  val idx: List[NArg] = newList()
  idx.add(NArg(ty = NI64, value = NLitInt(v = byteOffset.toLong(), ty = NI64)))
  insns.add(NGEP(dest = at, ty = NI8, ptr = NLocal(name = raw), indices = idx))
  val typed = freshTmp(ctx)
  insns.add(
    NBitcast(dest = typed, fromTy = NPtr(pointee = NI8), value = NLocal(name = at), toTy = NPtr(pointee = asTy))
  )
  val v = freshTmp(ctx)
  insns.add(NLoad(dest = v, ty = asTy, ptr = NLocal(name = typed)))
  NLocal(name = v)
}

// Store `v` of type `vTy` at the start of the slot `slot` of type `slotTy`.
func cStoreInto(
  ctx: in Ctx, insns: in List[NInsn], slot: in String, slotTy: in NType, vTy: in NType, v: in NValue
): Unit {
  val typed = freshTmp(ctx)
  insns.add(
    NBitcast(dest = typed, fromTy = NPtr(pointee = slotTy), value = NLocal(name = slot), toTy = NPtr(pointee = vTy))
  )
  insns.add(NStore(ty = vTy, value = v, ptr = NLocal(name = typed)))
}

/// A call to an extern whose signature carries a by-value record, lowered
/// as `cAbiExternDecl` declares it.
func cAbiExternCall(ctx: in Ctx, insns: in List[NInsn], callee: in String, args: in List[NArg], ret: in NType): NVal {
  val tys: List[NType] = newList()
  for a in args {
    tys.add(a.ty)
  }
  val plan = cAbiPlanOf(ctx, tys, ret)
  val lowered: List[NArg] = newList()
  var sretSlot = ""
  match plan.ret {
    case CRSret -> {
      sretSlot = freshTmp(ctx)
      ctx.allocas.add(NAlloca(dest = sretSlot, ty = ret))
      lowered.add(NArg(ty = NPtr(pointee = ret), value = NLocal(name = sretSlot), attrs = cAggregateAttr(ctx, "sret", ret)))
    }
    case _ -> ()
  }
  val scratchTy = NArray(elem = NI64, size = 2)
  var i = 0
  while i < args.count {
    val a = args[i]
    match plan.args[i] {
      case CAPlain -> lowered.add(a)
      case CAParts(parts) -> {
        val buf = cScratchSlot(ctx, ctx.allocas)
        cStoreInto(ctx, insns, buf, scratchTy, a.ty, a.value)
        var k = 0
        while k < parts.count {
          lowered.add(NArg(ty = parts[k], value = cLoadAt(ctx, insns, buf, scratchTy, k * 8, parts[k])))
          k = k + 1
        }
      }
      case CAArray(el, n, at) -> {
        val arrTy = NArray(elem = el, size = n)
        if isCFloatNType(el) {
          // A homogeneous aggregate has exactly the array's layout, and may
          // be larger than the scratch buffer.
          val slot = cSpill(ctx, ctx.allocas, insns, a.ty, a.value)
          lowered.add(NArg(ty = arrTy, value = cLoadAt(ctx, insns, slot, a.ty, 0, arrTy), attrs = at))
        } else {
          val buf = cScratchSlot(ctx, ctx.allocas)
          cStoreInto(ctx, insns, buf, scratchTy, a.ty, a.value)
          lowered.add(NArg(ty = arrTy, value = cLoadAt(ctx, insns, buf, scratchTy, 0, arrTy), attrs = at))
        }
      }
      case CAByval -> {
        val slot = cSpill(ctx, ctx.allocas, insns, a.ty, a.value)
        lowered.add(NArg(ty = NPtr(pointee = a.ty), value = NLocal(name = slot), attrs = cAggregateAttr(ctx, "byval", a.ty)))
      }
      case CAPtr -> {
        val slot = cSpill(ctx, ctx.allocas, insns, a.ty, a.value)
        lowered.add(NArg(ty = NPtr(pointee = a.ty), value = NLocal(name = slot)))
      }
    }
    i = i + 1
  }
  val callRet = cRetNType(plan.ret, ret)
  match plan.ret {
    case CRSret -> {
      insns.add(NCallVoid(fn = NGlobal(name = callee), args = lowered))
      val v = freshTmp(ctx)
      insns.add(NLoad(dest = v, ty = ret, ptr = NLocal(name = sretSlot)))
      NVal(ty = ret, value = NLocal(name = v))
    }
    case CRPlain -> match ret {
      case NVoid -> {
        insns.add(NCallVoid(fn = NGlobal(name = callee), args = lowered))
        NVal(ty = NVoid, value = NUndef(ty = NVoid))
      }
      case _ -> {
        val dest = freshTmp(ctx)
        insns.add(NCall(dest = dest, retTy = ret, fn = NGlobal(name = callee), args = lowered))
        val outV = NVal(ty = ret, value = NLocal(name = dest))
        registerTemp(ctx, outV)
        outV
      }
    }
    case _ -> {
      // The coerced result goes through the scratch buffer and is read back
      // as the record.
      val r = freshTmp(ctx)
      insns.add(NCall(dest = r, retTy = callRet, fn = NGlobal(name = callee), args = lowered))
      val buf = cScratchSlot(ctx, ctx.allocas)
      cStoreInto(ctx, insns, buf, scratchTy, callRet, NLocal(name = r))
      NVal(ty = ret, value = cLoadAt(ctx, insns, buf, scratchTy, 0, ret))
    }
  }
}

/// Message for `N0010`: a by-value aggregate in an `extern func` signature
/// that the C ABI lowering does not cover.
func byValueExternMessage(fnName: in String, recName: in String, isUnion: in Bool): String {
  if recName == "array" {
    return "extern func '" + fnName +
      "' passes an inline `array[N, T]` across the C boundary, and C passes no array by value (docs/67 §4.3); " +
      "pass a NativePtr to its first element"
  }
  if isUnion {
    return "extern func '" + fnName + "' passes by-value union '" + recName +
      "' across the C boundary, and a union has no C struct equivalent (docs/67 §4.2); pass a NativePtr, or " +
      "give a case a reference payload so the union keeps its heap form"
  }
  "extern func '" + fnName + "' passes by-value record '" + recName +
    "' across the C boundary, and this target's C struct ABI is not lowered (x86-64, AArch64 and wasm32 are; docs/67 §4.2); " +
    "pass a NativePtr, or declare the record with a `var` field so it keeps its heap form"
}

// The by-value aggregate `te` names that cannot cross the C boundary: a
// record, at a parameter, the result or in a callback type, crosses when
// `lowered`; an inline array or union never does.
func uncoveredByValueName(st: in NByValState, pkg: in String, te: in TypeExpr, lowered: in Bool): String {
  val n = byValueRecordNameOf(st, pkg, te)
  if n.length == 0 or not lowered or n == "array" or st.uresults.containsKey(n) {
    return n
  }
  ""
}

/// Pre-pass: every `extern func` parameter or return of a by-value aggregate
/// (docs/67 §4.2) the C ABI lowering does not cover, as an `N0010` diagnostic
/// at the declaration.  On a target `cAbiArch` knows, a by-value record
/// crosses as C passes the struct, in a callback type too (#8009); an inline
/// array or union, and any by-value record on another target (or with no
/// target named), is rejected instead of emitting a mismatched call.
pub func nativeByValueExternDiagnostics(units: in List[CodegenUnit], triple: in String = ""): List[Diagnostic] {
  val lowered = cAbiArch(triple).length > 0
  val diags: List[Diagnostic] = newList()
  val heapOnly: Map[String, Bool] = newMap()
  fillHeapOnlyRecs(heapOnly, units)
  val sink: List[NTypeDefn] = newList()
  val st = classifyByValueRecords(heapOnly, units, sink)
  for u in units {
    for ef in u.externs {
      var bad = ""
      for p in ef.params {
        if bad.length == 0 {
          bad = uncoveredByValueName(st, u.pkgName, p.ty, lowered)
        }
      }
      match ef.ret {
        case Some(rt) -> {
          if bad.length == 0 {
            bad = uncoveredByValueName(st, u.pkgName, rt, lowered)
          }
        }
        case None -> {
        }
      }
      if bad.length > 0 {
        diags.add(errorDiagnostic("N0010", byValueExternMessage(ef.name, bad, st.uresults.containsKey(bad)), ef.span))
      }
    }
  }
  diags
}

/// Message for `N0008`: a generic protected type on `--target native`.
func genericProtectedMessage(name: in String): String {
  "generic protected type '" + name +
    "' is not yet supported for --target native (#7864); declare it without type parameters or build for --target dotnet / jvm"
}

/// Pre-pass (#7886): every generic `protected type` in `units` as an `N0008`
/// diagnostic at its declaration.  `Lyric.LlvmBridge` runs it before codegen,
/// beside `nativeSelfShapeDiagnostics`, so the build stops with a normal
/// `error[N0008] file:line:col: ...` line.
pub func nativeGenericProtectedDiagnostics(units: in List[CodegenUnit]): List[Diagnostic] {
  val diags: List[Diagnostic] = newList()
  for u in units {
    for pd in u.protecteds {
      match pd.generics {
        case Some(_) -> diags.add(errorDiagnostic("N0008", genericProtectedMessage(u.pkgName + "." + pd.name), pd.span))
        case None -> ()
      }
    }
  }
  diags
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
// record (`{ i32 rc, i32 weak, i8* dtor, ...user fields }`), plus one trailing
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
/// `FieldDecl` (annotations/visibility are unused by codegen; docComments
/// carry through for consistency but are likewise not read here);
/// `PFImmutable` already wraps one.
func protFieldsOf(decl: in ProtectedTypeDecl): List[FieldDecl] {
  val fields: List[FieldDecl] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case PMField(pf) -> {
        match pf {
          case PFVar(name, ty, initOpt, docs, anns, span) -> {
            fields.add(
              FieldDecl(
                docComments = docs,
                annotations = anns,
                visibility = None,
                isMutable = true,
                name = name,
                ty = ty,
                dflt = initOpt,
                span = span
              )
            )
          }
          case PFLet(name, ty, initOpt, docs, anns, span) -> {
            fields.add(
              FieldDecl(
                docComments = docs,
                annotations = anns,
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
          case PFVar(name, _, _, _, _, _) -> names.add(name, true)
          case PFLet(name, _, _, _, _, _) -> names.add(name, true)
          case PFImmutable(fd) -> names.add(fd.name, true)
        }
      }
      case PMEntry(ed) -> names.add("()" + ed.name, true)
      case PMFunc(fn) -> names.add("()" + fn.name, true)
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
      // A bare call to a sibling entry/func becomes `self.m(..)`; the
      // member's mutex is recursive, so re-entering it from inside the
      // monitor is the same as MSIL's `Monitor.Enter` re-entry.
      val callee = match fn.kind {
        case EPath(cp) -> {
          if cp.segments.count == 1 and fieldNames.containsKey("()" + cp.segments[0]) and not fieldNames.containsKey(cp.segments[0]) {
            Expr(kind = EMember(receiver = Expr(kind = ESelf, span = fn.span), memberName = cp.segments[0]), span = fn.span)
          } else {
            desugarProtectedExpr(fieldNames, fn)
          }
        }
        case _ -> desugarProtectedExpr(fieldNames, fn)
      }
      return Expr(kind = ECall(fn = callee, args = args2), span = e.span)
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
        // #7585: an entry's own `Self`-typed params/return (e.g. `other: in
        // Self`, `fresh(): Self`) are NOT substituted upstream the way a
        // record impl method's are (`collectImplMethods`); substitute here
        // so the inner function's declared signature — resolved via
        // `typeToN` like any other function — is the concrete protected
        // type, not a bare `TSelf` (which only the INTERFACE's own erased
        // vtable slot signature should ever see).
        fns.add(
          substSelfInFn(
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
            ),
            decl.name
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
              // #7585: same `Self` substitution as the `PMEntry` arm above.
              fns.add(
                substSelfInFn(
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
                  ),
                  decl.name
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
  val ri = NRecInfo(irName = irName, fieldNames = names, fieldTys = tys, fieldDefaults = dflts, byValue = false)
  replaceRecKey(ctx, pkg + "." + pd.name, ri)
  replaceRecKey(ctx, pd.name, ri)
  if not ctx.protectedRecNames.containsKey(ri.irName) {
    ctx.protectedRecNames.add(ri.irName, true)
  }
  val defnFields: List[NType] = newList()
  addArcHeader(defnFields)
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
      idxArgs.add(NArg(ty = NI32, value = NLitInt(v = (arcHeaderSlots + i).toLong(), ty = NI32)))
      body.add(NGEP(dest = fieldPtr, ty = structTy, ptr = NLocal(name = "obj"), indices = idxArgs))
      val fieldVal = freshTmp(ctx)
      body.add(NLoad(dest = fieldVal, ty = ri.fieldTys[i], ptr = NLocal(name = fieldPtr)))
      // Weak-dispatching release: a `NativeWeak[T]` field drops its weak
      // count, everything else its strong count (#5504).
      emitRelease(ctx, body, NVal(ty = ri.fieldTys[i], value = NLocal(name = fieldVal)))
    }
    i = i + 1
  }
  val mutexFieldPtr = freshTmp(ctx)
  val mIdxArgs: List[NArg] = newList()
  mIdxArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  mIdxArgs.add(NArg(ty = NI32, value = NLitInt(v = (arcHeaderSlots + mutexIdx).toLong(), ty = NI32)))
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
  val obj = emitHeapAlloc(ctx, insns, objTy, recDtorName(ri))
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
    fArgs.add(NArg(ty = NI32, value = NLitInt(v = (arcHeaderSlots + fi).toLong(), ty = NI32)))
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
  // #7585: substitute `Self` in the member's OWN params/return to the
  // concrete protected type BEFORE building this wrapper's registered
  // signature — mirrors `collectImplMethods`/`implMethodToFn` for record
  // impls. Every call site re-resolves a registered `NFuncSig.retTy`/
  // param types via `typeToN`/`retTypeToN` fresh at each call
  // (`lowerCallEx`, `lowerUfcsCall`), so storing the substituted TypeExprs
  // here is what makes every later call site resolve the concrete type,
  // not a bare `TSelf` (which only the INTERFACE's own erased vtable slot
  // signature should ever see — that erasure is `typeExprToNType`'s
  // `TSelf` arm, D-progress-1016).
  val sParams: List[Param] = newList()
  var spi = 0
  while spi < params.count {
    val p = params[spi]
    sParams.add(
      Param(
        mode = p.mode,
        modeExplicit = p.modeExplicit,
        name = p.name,
        ty = substSelfInType(p.ty, pd.name),
        dflt = p.dflt,
        annotations = p.annotations,
        span = p.span
      )
    )
    spi = spi + 1
  }
  val sRet = match ret { case Some(r) -> Some(value = substSelfInType(r, pd.name)); case None -> None }
  // Protected-type entry/method params are forwarded verbatim by the
  // hand-built lock/unlock wrapper below (no per-param slot machinery,
  // unlike `lowerFunctionEnv`); threading a by-ref pointer through that
  // shape is unverified, so reject loudly rather than risk a silent
  // ABI mismatch between the wrapper and the inner function (N9.6 scope
  // cut — no shipped `protected type` method uses `out`/`inout` today).
  var mci = 0
  while mci < sParams.count {
    match sParams[mci].mode {
      case PMIn -> {
      }
      case _ -> panic(
        "Lyric.LlvmCodegen: protected type '" + pd.name + "' method '" + methodName + "' declares '" +
          sParams[mci].name +
          "' as out/inout, which is not yet supported for --target native on protected-type methods"
      )
    }
    mci = mci + 1
  }
  val arity = 1 + sParams.count
  val wrapperIrName = pkg + "." + pd.name + "." + methodName
  val innerIrName = pkg + "." + pd.name + "." + methodName + ".__inner"
  val sigParamTys: List[TypeExpr] = newList()
  sigParamTys.add(selfTypeRef(pd.name, pd.span))
  val sigParamNames: List[String] = newList()
  sigParamNames.add("self")
  val sigParamModes: List[ParamMode] = newList()
  sigParamModes.add(PMIn)
  val sigParamDefaults: List[Option[Expr]] = newList()
  val noSelfDefault: Option[Expr] = None
  sigParamDefaults.add(noSelfDefault)
  var i = 0
  while i < sParams.count {
    sigParamTys.add(sParams[i].ty)
    sigParamNames.add(sParams[i].name)
    sigParamModes.add(PMIn)
    sigParamDefaults.add(sParams[i].dflt)
    i = i + 1
  }
  val sig = NFuncSig(
    irName = wrapperIrName,
    pkg = pkg,
    paramNames = sigParamNames,
    paramTys = sigParamTys,
    paramModes = sigParamModes,
    paramDefaults = sigParamDefaults,
    retTy = sRet,
    isExternSym = false,
    isAsync = false
  )
  addSig(ctx.sigs, pkg + "." + methodName + "/" + arity.toString(), sig)
  addSig(ctx.sigs, methodName + "/" + arity.toString(), sig)
  var shorter = requiredArgCount(sig)
  while shorter < arity {
    addSig(ctx.sigs, pkg + "." + methodName + "/" + shorter.toString(), sig)
    addSig(ctx.sigs, methodName + "/" + shorter.toString(), sig)
    shorter = shorter + 1
  }
  val retTyN = retTypeToN(ctx, sRet)
  val paramTysN: List[NType] = newList()
  val paramNamesN: List[String] = newList()
  var j = 0
  while j < sParams.count {
    paramTysN.add(typeToN(ctx, sParams[j].ty))
    paramNamesN.add(sParams[j].name)
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
  idxArgs.add(NArg(ty = NI32, value = NLitInt(v = (arcHeaderSlots + mutexIdx).toLong(), ty = NI32)))
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
// aggregate ABI): `__iface.<m>` = `{ i32 rc, i32 weak, i8* dtor, i8* obj, vtable* }`.
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

/// An interface or impl method may write its receiver as an explicit first
/// parameter (`func area(self: in Self, ...)`); the receiver is supplied
/// separately here, so that parameter is dropped.
func withoutExplicitSelf(params: in List[Param]): List[Param] {
  if params.count > 0 and params[0].name == "self" {
    val rest: List[Param] = newList()
    var i = 1
    while i < params.count {
      rest.add(params[i])
      i = i + 1
    }
    return rest
  }
  params
}

/// Rewrite an `impl I for R` method into a self-receiving package function:
/// prepend `self: in R` (impl methods parse without an injected receiver —
/// the body's `self` keyword lowers to `loadLocal("self")`), substitute any
/// `Self` in the remaining signature, and give it the collision-free name.
func implMethodToFn(recordName: in String, ifaceName: in String, fn: in FunctionDecl): FunctionDecl {
  val ownParams = withoutExplicitSelf(fn.params)
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
  while i < ownParams.count {
    val p = ownParams[i]
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

/// GEP field indices into the interface box struct
/// `{ i32 rc, i32 weak, i8* dtor, i8* obj, vtable* }` (fields 0-2 are the shared
/// ARC header, so only the obj/vtable slots need names here).
val ifaceBoxObjSlot: Long = 3i64

val ifaceBoxVtblSlot: Long = 4i64

/// The heap-boxed fat-pointer type for an interface value:
/// `{ i32 rc, i32 weak, i8* dtor, i8* obj, vtable* }`.
func ifaceBoxStructType(ii: in NIfaceInfo): NType {
  val fields: List[NType] = newList()
  addArcHeader(fields)
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
///
/// Invariant: every internal (non-record) IR struct name minted by this
/// file begins with `__` (union payload structs, `__iface.*`/`__ifacevt.*`,
/// `__closure<...>`/`__closureimpl.*`, `__weak<...>`, ...) or is one of the
/// listed sentinels (`LyricString`). Any new internal struct type must keep
/// this prefix, or be added as a sentinel here, or `recordIrNameOfType`
/// will misidentify it as a record.
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
  // #4900: `typeToN`'s `TRef` case joins a single-segment type path to
  // itself (`modulePathJoin` of one segment is that segment), so the bare
  // name below is not a mere fallback — it is the ONLY key consulted for
  // the overwhelmingly common unqualified interface reference (`x: in
  // Shape`, not `x: in Pkg.Shape`).  Silently letting a second same-bare-
  // name interface from a different package overwrite it (now reachable
  // via a multi-package `--target native` build, `compileProjectToNativeWithFlags`
  // fully lowers every own package, #6809) would route calls through the
  // wrong vtable with no diagnostic.  Fail loudly at registration instead.
  match mapGet(ctx.ifaceBareNameOwners, name) {
    case Some(owner) -> {
      if owner != qualified {
        panic(
          "Lyric.LlvmCodegen: ambiguous interface name '" + name + "' for --target native — both '" + owner + "' and '" +
            qualified +
            "' are interfaces in scope for this build, and an unqualified reference to '" +
            name +
            "' cannot tell them apart (#4900); rename one of them"
        )
      }
    }
    case None -> {
      ctx.ifaceBareNameOwners.add(name, qualified)
    }
  }
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
  idxArgs.add(NArg(ty = NI32, value = NLitInt(v = ifaceBoxObjSlot, ty = NI32)))
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

/// The ordered subset of `idecl.members` that the native backend's vtable
/// layout covers: non-generic `IMSig` signatures and default methods
/// (`IMFunc`), with any explicit `self` parameter dropped, skipping async methods
/// (async interface dispatch is unimplemented on this backend) and any
/// method with its own generics (MVAR is unbuildable, docs/43 Q-GEN-002).
/// `registerInterfaceNames` (phase A, method-name list) and
/// `registerInterfaceTypes` (phase B, param/return types + vtable field
/// count) both derive from this SAME filtered, in-order list — the vtable
/// slot at index `i` in phase A's `methodNames` must be the same method as
/// index `i` in phase B's `methodParamTys`/`methodRetTys`, so any drift
/// between the two filters would silently misalign a slot.
func nonGenericSyncSigs(idecl: in InterfaceDecl): List[FunctionSig] {
  val sigs: List[FunctionSig] = newList()
  var mi = 0
  while mi < idecl.members.count {
    match idecl.members[mi] {
      case IMSig(sig) -> {
        match sig.generics {
          case Some(_) -> {
          }
          case None -> {
            if not sig.isAsync {
              sigs.add(sig.copy(params = withoutExplicitSelf(sig.params)))
            }
          }
        }
      }
      // A default method takes a slot too: `Lyric.ImplDefaults` copies its
      // body into every impl that does not override it, so each impl's
      // vtable has a method to point the slot at.
      case IMFunc(fn) -> {
        match fn.generics {
          case Some(_) -> {
          }
          case None -> {
            if not fn.isAsync {
              sigs.add(
                FunctionSig(
                  docComments = fn.docComments,
                  isAsync = false,
                  name = fn.name,
                  generics = None,
                  params = withoutExplicitSelf(fn.params),
                  ret = fn.ret,
                  whereClause = None,
                  contracts = fn.contracts,
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
    mi = mi + 1
  }
  sigs
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
          val sigs = nonGenericSyncSigs(idecl)
          val mnames: List[String] = newList()
          val mretSelf: List[Bool] = newList()
          val mparamSelf: List[List[Bool]] = newList()
          var mi = 0
          while mi < sigs.count {
            val sig = sigs[mi]
            mnames.add(sig.name)
            // #7585: reject a NESTED `Self` (`List[Self]`, `Option[Self]`,
            // ...) with a named diagnostic here, in phase A, before phase B
            // ever calls `typeToN` on it — the vaguer "generic type not
            // supported" panic from deep inside `typeExprToNType` would
            // otherwise fire first and not name the interface/method.
            // `nestedSelfShapesInSig` is the SAME traversal
            // `nativeSelfShapeDiagnostics` uses (#7618 review: factored into
            // one shared helper so the two can never drift) — this caller
            // panics on each shape (the unreachable-once-the-bridge's-own
            // pre-pass-runs-first defensive fallback), the other collects a
            // structured `N0006` diagnostic per shape instead.
            val shapes = nestedSelfShapesInSig(sig)
            var si = 0
            while si < shapes.count {
              panicUnsupportedSelfShape(qualified, sig.name, shapes[si].where_, shapes[si].span)
              si = si + 1
            }
            // #7618: record whether each parameter is a bare `Self` —
            // `lowerIfaceDispatch` consults this explicitly, never the
            // erased `i8*` shape, to decide whether to unbox an argument
            // (a real `NativePtr[Byte]` parameter erases identically).
            val paramSelf: List[Bool] = newList()
            var pi = 0
            while pi < sig.params.count {
              paramSelf.add(isBareSelfTypeExpr(sig.params[pi].ty))
              pi = pi + 1
            }
            mparamSelf.add(paramSelf)
            var retIsSelf = false
            match sig.ret {
              case Some(r) -> {
                retIsSelf = isBareSelfTypeExpr(r)
              }
              case None -> {
              }
            }
            mretSelf.add(retIsSelf)
            mi = mi + 1
          }
          val mparamNames: List[List[String]] = newList()
          val mparamDefaults: List[List[Option[Expr]]] = newList()
          for sg in sigs {
            mparamNames.add(paramNamesOf(sg.params))
            mparamDefaults.add(paramDefaultsOf(sg.params))
          }
          val info = NIfaceInfo(
            key = qualified,
            irName = "__iface." + mangled,
            vtName = "__ifacevt." + mangled,
            methodNames = mnames,
            methodParamTys = newList(),
            methodRetTys = newList(),
            methodRetIsSelf = mretSelf,
            methodParamIsSelf = mparamSelf,
            methodParamNames = mparamNames,
            methodParamDefaults = mparamDefaults
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
          val sigs = nonGenericSyncSigs(idecl)
          var mi = 0
          while mi < sigs.count {
            val sig = sigs[mi]
            val ps: List[NType] = newList()
            var pi = 0
            while pi < sig.params.count {
              ps.add(typeToN(ctx, sig.params[pi].ty))
              pi = pi + 1
            }
            pTys.add(ps)
            rTys.add(retTypeToN(ctx, sig.ret))
            mi = mi + 1
          }
          val info = NIfaceInfo(
            key = pre.key,
            irName = pre.irName,
            vtName = pre.vtName,
            methodNames = pre.methodNames,
            methodParamTys = pTys,
            methodRetTys = rTys,
            methodRetIsSelf = pre.methodRetIsSelf,
            methodParamIsSelf = pre.methodParamIsSelf,
            methodParamNames = pre.methodParamNames,
            methodParamDefaults = pre.methodParamDefaults
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
          addArcHeader(boxFields)
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
    // #7457: an impl for a protected type has its methods moved into the
    // type as entries by the contract elaborator, so the slot points at the
    // entry's lock wrapper (`<Type>.<method>`), not an impl-method symbol.
    val implIr = if ctx.protectedRecNames.containsKey(pkg + "." + recordName) {
      pkg + "." + recordName + "." + ii.methodNames[i]
    } else {
      pkg + "." + implMethodName(recordName, ifaceName, ii.methodNames[i])
    }
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

/// The vtable of a by-value implementer `R` (#8010): an interface value holds
/// it in a `__box<R>`, so each slot is a thunk taking the box as its erased
/// `self`.  The thunk reads the record out of the box, does the same for each
/// `Self` parameter, calls the impl method with the values, and boxes a
/// `Self` result, which the caller owns.
func byValueVtableInitStr(
  ctx: in Ctx,
  pkg: in String,
  recordName: in String,
  ri: in NRecInfo,
  ifaceName: in String,
  ii: in NIfaceInfo,
  fns: in List[NFunc],
): String {
  val recTy = recPtrType(ri)
  val boxTy = byValueBoxType(ctx, recTy)
  val boxStructTy = match boxTy { case NPtr(pointee) -> pointee; case _ -> panic("unreachable") }
  val i8p = NPtr(pointee = NI8)
  var acc = "{ "
  var i = 0
  while i < ii.methodNames.count {
    if i > 0 {
      acc = acc + ", "
    }
    val implIr = pkg + "." + implMethodName(recordName, ifaceName, ii.methodNames[i])
    val thunkName = implIr + ".vthunk"
    val body: List[NInsn] = newList()
    body.add(NLabel(name = "entry"))
    val params: List[NParam] = newList()
    params.add(NParam(name = "self", ty = i8p))
    val implArgs: List[NArg] = newList()
    implArgs.add(
      NArg(ty = recTy, value = loadFromByValueBox(ctx, body, NLocal(name = "self"), boxTy, boxStructTy, recTy))
    )
    val implParamTys: List[NType] = newList()
    implParamTys.add(recTy)
    val thunkParamTys: List[NType] = newList()
    thunkParamTys.add(i8p)
    var pi = 0
    while pi < ii.methodParamTys[i].count {
      val pty = ii.methodParamTys[i][pi]
      val pname = "a" + toString(pi)
      params.add(NParam(name = pname, ty = pty))
      thunkParamTys.add(pty)
      if ii.methodParamIsSelf[i][pi] {
        implArgs.add(NArg(ty = recTy, value = loadFromByValueBox(ctx, body, NLocal(name = pname), boxTy, boxStructTy, recTy)))
        implParamTys.add(recTy)
      } else {
        implArgs.add(NArg(ty = pty, value = NLocal(name = pname)))
        implParamTys.add(pty)
      }
      pi = pi + 1
    }
    val retTy = ii.methodRetTys[i]
    val retIsSelf = ii.methodRetIsSelf[i]
    val implRetTy = if retIsSelf { recTy } else { retTy }
    match implRetTy {
      case NVoid -> {
        body.add(NCallVoid(fn = NGlobal(name = implIr), args = implArgs))
        body.add(NRetVoid)
      }
      case _ -> {
        val r = freshTmp(ctx)
        body.add(NCall(dest = r, retTy = implRetTy, fn = NGlobal(name = implIr), args = implArgs))
        if retIsSelf {
          val held = boxByValue(ctx, body, NVal(ty = recTy, value = NLocal(name = r)))
          val raw = freshTmp(ctx)
          body.add(NBitcast(dest = raw, fromTy = held.ty, value = held.value, toTy = i8p))
          body.add(NRet(ty = retTy, value = NLocal(name = raw)))
        } else {
          body.add(NRet(ty = retTy, value = NLocal(name = r)))
        }
      }
    }
    fns.add(
      NFunc(
        name = thunkName,
        params = params,
        retTy = retTy,
        isPublic = false,
        isExtern = false,
        body = body,
        attributes = newList()
      )
    )
    val fnTyStr = nTypeToIrString(NFnPtr(params = thunkParamTys, ret = retTy))
    acc = acc + "i8* bitcast (" + fnTyStr + " @" + quoteIrIdent(thunkName) + " to i8*)"
    i = i + 1
  }
  acc + " }"
}

// The record a `__box<R>` at `raw` holds, read into a value.
func loadFromByValueBox(
  ctx: in Ctx,
  body: in List[NInsn],
  raw: in NValue,
  boxTy: in NType,
  boxStructTy: in NType,
  recTy: in NType,
): NValue {
  val b = freshTmp(ctx)
  body.add(NBitcast(dest = b, fromTy = NPtr(pointee = NI8), value = raw, toTy = boxTy))
  val payload = freshTmp(ctx)
  val gArgs: List[NArg] = newList()
  gArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  gArgs.add(NArg(ty = NI32, value = NLitInt(v = arcHeaderSlots.toLong(), ty = NI32)))
  body.add(NGEP(dest = payload, ty = boxStructTy, ptr = NLocal(name = b), indices = gArgs))
  val v = freshTmp(ctx)
  body.add(NLoad(dest = v, ty = recTy, ptr = NLocal(name = payload)))
  NLocal(name = v)
}

/// Emit a vtable constant global for every `impl I for R` and record the
/// `<recordIr>|<ifaceKey>` -> global-name mapping consulted at upcast sites.
func registerImplVtables(ctx: in Ctx, units: in List[CodegenUnit], fns: in List[NFunc]): Unit {
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
                  // The impl's own package's record of that name before
                  // the first one declared anywhere.
                  val target = match mapGet(ctx.recordDefs, u.pkgName + "." + recordName) {
                    case Some(own) -> Some(value = own)
                    case None -> mapGet(ctx.recordDefs, recordName)
                  }
                  match target {
                    case None -> {
                    }
                    case Some(ri) -> {
                      val selfPtrTy = recPtrType(ri)
                      val gname = ifaceVtableGlobalName(ri.irName, info)
                      if not ctx.ifaceVtables.containsKey(ri.irName + "|" + info.key) {
                        val initStr = if ri.byValue {
                          byValueVtableInitStr(ctx, u.pkgName, recordName, ri, ifaceName, info, fns)
                        } else {
                          ifaceVtableInitStr(ctx, u.pkgName, recordName, selfPtrTy, ifaceName, info)
                        }
                        ctx.globals.add(
                          NGlobalDef(
                            name = gname,
                            linkage = "internal constant",
                            tyStr = nTypeToIrString(ifaceVtStructType(info)),
                            initStr = initStr,
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

/// Index every non-generic `impl I for R` method under
/// `<pkg>.<R>.<method>/<arity>` (PACKAGE-QUALIFIED, #7627 — a bare record
/// name would alias two same-named records in different packages in a
/// multi-package native bundle) -> its collision-free `ctx.sigs` key
/// (`implMethodName`, #7600), so a call on the CONCRETE record receiver can
/// find it (`lowerUfcsCall` has no other lookup that reaches the
/// `<Record>.<Iface>.<method>` name `collectImplMethods` gives it). Walked in
/// the same units/impls/members order the type checker's `symTableAddImpl` +
/// `methodCandidatesFor` build and consult `tbl.impls`, and `addSig`-style
/// first-wins on a duplicate key. In practice a duplicate key never
/// reaches this pass any more: the type checker now rejects both a
/// record's own-body method sharing a name with one of its impl methods
/// and two impls of the same target sharing a method name (T0139), the
/// same way it already rejects the protected-type analog (T0136) —
/// #7626/#7627's review follow-ups. The first-wins tie-break below is
/// therefore a defensive fallback only, kept in case a caller ever feeds
/// this function units that bypassed the checker. Protected-type impls
/// never reach here regardless: the contract elaborator moves them into
/// the type's own entries before codegen sees the `IImpl` item (#7457) —
/// `protectedRecNames` is still consulted defensively in case a future
/// caller feeds this function units before that elaboration runs.
func registerImplDirectMethods(ctx: in Ctx, units: in List[CodegenUnit]): Unit {
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
              if not ctx.protectedRecNames.containsKey(u.pkgName + "." + recordName) {
                val ifaceName = implIfaceName(decl.iface)
                var mi = 0
                while mi < decl.members.count {
                  match decl.members[mi] {
                    case IMplFunc(fn) -> {
                      match fn.generics {
                        case Some(_) -> {
                        }
                        case None -> {
                          if not fn.isAsync {
                            val arity = (withoutExplicitSelf(fn.params).count + 1).toString()
                            val key = u.pkgName + "." + recordName + "." + fn.name + "/" + arity
                            val sigKey = u.pkgName + "." + implMethodName(recordName, ifaceName, fn.name) + "/" + arity
                            if not ctx.implDirectMethods.containsKey(key) {
                              ctx.implDirectMethods.add(key, sigKey)
                            }
                          }
                        }
                      }
                    }
                    case IMplAssoc(_) -> {
                    }
                  }
                  mi = mi + 1
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
  val box = emitHeapAlloc(ctx, insns, boxTy, ifaceBoxDtorName(ii))
  // obj slot (ifaceBoxObjSlot): retain then store the erased object pointer.
  // A by-value record is copied into a fresh `__box<R>` the interface value
  // owns (#8010); its vtable's thunks read it back out.
  val objI8 = freshTmp(ctx)
  if isBoxedValueNType(v.ty) {
    val held = boxByValue(ctx, insns, v)
    insns.add(NBitcast(dest = objI8, fromTy = held.ty, value = held.value, toTy = NPtr(pointee = NI8)))
  } else {
    insns.add(NBitcast(dest = objI8, fromTy = v.ty, value = v.value, toTy = NPtr(pointee = NI8)))
    insns.add(NCallVoid(fn = NGlobal(name = "lyric_retain"), args = arg1(NPtr(pointee = NI8), NLocal(name = objI8))))
  }
  val objSlot = freshTmp(ctx)
  val objArgs: List[NArg] = newList()
  objArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  objArgs.add(NArg(ty = NI32, value = NLitInt(v = ifaceBoxObjSlot, ty = NI32)))
  insns.add(NGEP(dest = objSlot, ty = structTy, ptr = NLocal(name = box), indices = objArgs))
  insns.add(NStore(ty = NPtr(pointee = NI8), value = NLocal(name = objI8), ptr = NLocal(name = objSlot)))
  // vtable slot (index 3): point at the impl's constant vtable.
  val vtSlot = freshTmp(ctx)
  val vtArgs: List[NArg] = newList()
  vtArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  vtArgs.add(NArg(ty = NI32, value = NLitInt(v = ifaceBoxVtblSlot, ty = NI32)))
  insns.add(NGEP(dest = vtSlot, ty = structTy, ptr = NLocal(name = box), indices = vtArgs))
  insns.add(
    NStore(ty = NPtr(pointee = ifaceVtStructType(ii)), value = NGlobal(name = vtGlobal), ptr = NLocal(name = vtSlot))
  )
  val boxVal = NVal(ty = boxTy, value = NLocal(name = box))
  registerTemp(ctx, boxVal)
  boxVal
}

/// Rebox a `Self`-returning interface method's erased `i8*` result into a
/// FRESH interface value (#7585): a call through an interface receiver
/// types the whole call expression as the interface itself (T0113
/// receiver substitution — `substituteMethodSig` in the shared type
/// checker), not the erased raw pointer, so `lowerIfaceDispatch` must
/// hand back a real `__iface.*` box, not the bare `i8*`.
///
/// Reuses the SAME vtable pointer `vtbl` already loaded from the
/// receiver's own box — sound because the type checker only accepts a
/// `Self`-declared return as exactly the callee impl's own target type
/// (`checkImplConformance`), which is by construction the SAME concrete
/// runtime type as the receiver, so its vtable for THIS interface is
/// identical to the receiver's.
///
/// No extra retain: the called method already transferred a fresh rc=1
/// ownership of `objI8` to this call site (Rule 6), and that ownership
/// moves directly into the new box's `obj` slot — the box's own
/// destructor (`synthIfaceBoxDtor`) is the one release that balances it.
func reboxErasedSelfResult(ctx: in Ctx, insns: in List[NInsn], ii: in NIfaceInfo, objI8: in NVal, vtbl: in NVal): NVal {
  val boxTy = ifaceBoxPtrType(ii)
  val structTy = ifaceBoxStructType(ii)
  val box = emitHeapAlloc(ctx, insns, boxTy, ifaceBoxDtorName(ii))
  val objSlot = freshTmp(ctx)
  val objArgs: List[NArg] = newList()
  objArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  objArgs.add(NArg(ty = NI32, value = NLitInt(v = ifaceBoxObjSlot, ty = NI32)))
  insns.add(NGEP(dest = objSlot, ty = structTy, ptr = NLocal(name = box), indices = objArgs))
  insns.add(NStore(ty = NPtr(pointee = NI8), value = objI8.value, ptr = NLocal(name = objSlot)))
  val vtSlot = freshTmp(ctx)
  val vtArgs: List[NArg] = newList()
  vtArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  vtArgs.add(NArg(ty = NI32, value = NLitInt(v = ifaceBoxVtblSlot, ty = NI32)))
  insns.add(NGEP(dest = vtSlot, ty = structTy, ptr = NLocal(name = box), indices = vtArgs))
  insns.add(NStore(ty = NPtr(pointee = ifaceVtStructType(ii)), value = vtbl.value, ptr = NLocal(name = vtSlot)))
  val boxVal = NVal(ty = boxTy, value = NLocal(name = box))
  registerTemp(ctx, boxVal)
  boxVal
}

/// One interface call argument, lowered against its parameter: a bare `Self`
/// parameter unboxes explicitly (#7618), every other one coerces.
func lowerIfaceArgAt(ctx: in Ctx, insns: in List[NInsn], ex: in Expr, pt: in NType, isSelf: in Bool): NVal {
  if isSelf {
    return unboxToSelfSlot(ctx, insns, lowerExpr(ctx, insns, ex))
  }
  coerceTo(ctx, insns, lowerExprExpecting(ctx, insns, ex, pt), pt)
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
  objArgs.add(NArg(ty = NI32, value = NLitInt(v = ifaceBoxObjSlot, ty = NI32)))
  insns.add(NGEP(dest = objSlot, ty = structTy, ptr = recv.value, indices = objArgs))
  val objVal = freshTmp(ctx)
  insns.add(NLoad(dest = objVal, ty = NPtr(pointee = NI8), ptr = NLocal(name = objSlot)))
  // Load vtable pointer (index 3).
  val vtSlotPtr = freshTmp(ctx)
  val vtArgs: List[NArg] = newList()
  vtArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  vtArgs.add(NArg(ty = NI32, value = NLitInt(v = ifaceBoxVtblSlot, ty = NI32)))
  insns.add(NGEP(dest = vtSlotPtr, ty = structTy, ptr = recv.value, indices = vtArgs))
  val vtPtrTy = NPtr(pointee = ifaceVtStructType(ii))
  val vtbl = freshTmp(ctx)
  insns.add(NLoad(dest = vtbl, ty = vtPtrTy, ptr = NLocal(name = vtSlotPtr)))
  // Index the method slot and load the raw function pointer.
  val fnSlotPtr = freshTmp(ctx)
  val mArgs: List[NArg] = newList()
  mArgs.add(NArg(ty = NI32, value = NLitInt(v = 0i64, ty = NI32)))
  mArgs.add(NArg(ty = NI32, value = NLitInt(v = slot.toLong(), ty = NI32)))
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
      toTy = NFnPtr(params = fnParamTys, ret = retTy)
    )
  )
  // Build call args: obj first, then the coerced declared arguments. A
  // parameter that is itself a bare `Self` (#7618) unboxes explicitly via
  // `unboxToSelfSlot` — its own type-mismatch panic distinguishes it from
  // a genuine `NativePtr[Byte]` parameter, which erases to the SAME `i8*`
  // but must coerce (and, on a mismatch, fail) through the ordinary path.
  val paramIsSelf = ii.methodParamIsSelf[slot]
  val paramNames = ii.methodParamNames[slot]
  val paramDefaults = ii.methodParamDefaults[slot]
  // Written arguments are evaluated in source order, positional ones
  // binding left to right and named ones by name; a parameter the call
  // leaves out then takes the interface member's default (#7985).
  val argExprs: List[Expr] = newList()
  val argSlots: List[Int] = newList()
  var nextPositional = 0
  for a in args {
    match a {
      case CAPositional(ex) -> {
        argExprs.add(ex)
        argSlots.add(nextPositional)
        nextPositional = nextPositional + 1
      }
      case CANamed(argName, value, _) -> {
        var found = -1
        var ni = 0
        while ni < paramNames.count {
          if paramNames[ni] == argName {
            found = ni
          }
          ni = ni + 1
        }
        if found < 0 {
          panic(
            "Lyric.LlvmCodegen: named argument '" + argName + "' does not match a parameter of interface method '." +
              ii.methodNames[slot] +
              "'"
          )
        }
        argExprs.add(value)
        argSlots.add(found)
      }
    }
  }
  val slotVals: List[NVal] = newList()
  val slotFilled: List[Bool] = newList()
  for pt in paramTys {
    slotVals.add(NVal(ty = pt, value = NUndef(ty = pt)))
    slotFilled.add(false)
  }
  var ai = 0
  while ai < argExprs.count {
    val ps = argSlots[ai]
    slotVals[ps] = lowerIfaceArgAt(ctx, insns, argExprs[ai], paramTys[ps], paramIsSelf[ps])
    slotFilled[ps] = true
    ai = ai + 1
  }
  var di = 0
  while di < paramTys.count {
    if not slotFilled[di] {
      match paramDefaults[di] {
        case Some(dex) -> {
          slotVals[di] = lowerIfaceArgAt(ctx, insns, dex, paramTys[di], paramIsSelf[di])
        }
        case None -> panic(
          "Lyric.LlvmCodegen: no argument bound for parameter '" + paramNames[di] + "' of interface method '." +
            ii.methodNames[slot] +
            "', which has no default"
        )
      }
    }
    di = di + 1
  }
  val callArgs: List[NArg] = newList()
  callArgs.add(NArg(ty = NPtr(pointee = NI8), value = NLocal(name = objVal)))
  var ci = 0
  while ci < paramTys.count {
    callArgs.add(NArg(ty = paramTys[ci], value = slotVals[ci].value))
    ci = ci + 1
  }
  match retTy {
    case NVoid -> {
      insns.add(NCallVoid(fn = NLocal(name = fnTyped), args = callArgs))
      NVal(ty = NVoid, value = NUndef(ty = NVoid))
    }
    case _ -> {
      val dest = freshTmp(ctx)
      insns.add(NCall(dest = dest, retTy = retTy, fn = NLocal(name = fnTyped), args = callArgs))
      // #7585: a `Self`-declared return dispatched through the interface
      // types the call expression as the interface (T0113), not the
      // erased raw pointer — rebox before handing the value back.
      if ii.methodRetIsSelf[slot] {
        val rawObj = NVal(ty = NPtr(pointee = NI8), value = NLocal(name = dest))
        val vtblVal = NVal(ty = vtPtrTy, value = NLocal(name = vtbl))
        return reboxErasedSelfResult(ctx, insns, ii, rawObj, vtblVal)
      }
      val outV = NVal(ty = retTy, value = NLocal(name = dest))
      registerTemp(ctx, outV)
      outV
    }
  }
}

pub func dottedPkgName(file: in SourceFile): String {
  modulePathJoin(file.packageDecl.path.segments)
}
