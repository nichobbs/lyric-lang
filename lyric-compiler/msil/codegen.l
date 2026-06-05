// msil/codegen.l — Msil.Codegen
//
// Bootstrap-grade AST-to-MSIL-IR lowering for the Lyric self-hosted compiler.
// Walks a parsed `SourceFile` (from Lyric.Parser) and produces an `MPackage`
// (from Msil.Lowering) suitable for further lowering to PE bytes by
// `Msil.Lowering.lowerMPackageWithCtx`.
//
// Supported in this bootstrap pass:
//   • Simple functions — arithmetic, locals, if/else, while
//   • Hello-world programs (main with println)
//   • Record types with fields
//   • Union types (lowered to sealed-union IR)
//   • Basic builtin calls: println, print, panic, toString, assert, newList,
//     newMap, mapGet, default, format1..format3, intToLong, longToInt, charToInt
//   • Interpolated strings via String.Concat chains
//   • Match expressions with literal and binding patterns
//   • Constructor calls and field access
//
// Unsupported forms panic at codegen time so failures are visible rather than
// silently wrong.
//
// MSIL vs JVM differences captured here:
//   • MLdloc/MStloc for locals (slot 0-based within locals list).
//   • MLdarg for parameters (slot 0-based within params list).
//   • MRet for all return types.
//   • MLdStr(token) where token = 0x70000000 | US heap offset.
//   • MCeq/MClt/MCgt + XOR for comparison results.
//   • MNewobj(ctorToken) for construction; MBox(typeToken) for boxing.

package Msil.Codegen

import Std.Core
import Std.Collections
import Std.String
import Lyric.Parser
import Lyric.RestoredPackages
import Lyric.Weaver as Weaver
import Msil.Lowering
import Msil.Ffi
import Msil.Kernel
import Msil.MetadataReader as Mdr

// ─────────────────────────────────────────────────────────────────────────────
// §1. CodegenCtx — package-level context with pre-registered external tokens.
// ─────────────────────────────────────────────────────────────────────────────

// CodegenCtx holds a LoweringCtx pre-seeded with all external TypeRef and
// MemberRef rows needed by the code generator.  Tokens are stable integer
// constants computed once in `newCodegenCtx` so that every instruction
// site can embed them directly without re-scanning the table.
pub record CodegenCtx {
  lctx:               LoweringCtx
  // TypeRef row indices (1-based)
  trConsole:          Int   // System.Console
  trString:           Int   // System.String
  trInt32:            Int   // System.Int32
  trInt64:            Int   // System.Int64
  trDouble:           Int   // System.Double
  trBoolean:          Int   // System.Boolean
  trChar:             Int   // System.Char
  trException:        Int   // System.Exception
  trCultureInfo:      Int   // System.Globalization.CultureInfo
  // MemberRef tokens (0x0A000000 | 1-based row)
  tokWriteLineStr:    Int   // Console.WriteLine(string)
  tokWriteLineInt:    Int   // Console.WriteLine(int32)
  tokWriteLineLong:   Int   // Console.WriteLine(int64)
  tokWriteLineDbl:    Int   // Console.WriteLine(double)
  tokWriteLineBool:   Int   // Console.WriteLine(bool)
  tokWriteStr:        Int   // Console.Write(string)
  tokConcat2:         Int   // String.Concat(string,string)
  tokConcat3:         Int   // String.Concat(string,string,string)
  tokExceptionCtor:   Int   // Exception..ctor(string) — one-arg ctor (callers emit ldstr+newobj+throw and rely on this arity)
  tokStringFormat1:   Int   // String.Format(string,object)
  tokStringFormat2:   Int   // String.Format(string,object,object)
  tokStringFormat3:   Int   // String.Format(string,object,object,object)
  tokObjToString:     Int   // Object.ToString() instance HASTHIS
  tokCultureInfoInvariantGet: Int  // CultureInfo.get_InvariantCulture(): CultureInfo  static
  tokDoubleToStringInv:       Int  // Double.ToString(IFormatProvider): string  instance HASTHIS
  tokExcGetMessage:   Int   // Exception.get_Message(): string  instance HASTHIS
  tokObjGetType:      Int   // Object.GetType(): Type  instance HASTHIS
  tokTypeGetName:     Int   // Type.get_Name: string  instance HASTHIS
  // List<object> via TypeSpec (for newList() and list operations)
  tokListObjCtor:      Int   // List<object>::.ctor()  newobj
  tokListObjAdd:       Int   // List<object>::Add(object): void  callvirt
  tokListObjGetItem:   Int   // List<object>::get_Item(int32): object  callvirt
  tokListObjSetItem:   Int   // List<object>::set_Item(int32, object): void  callvirt
  tokListObjGetCount:  Int   // List<object>::get_Count(): int32  callvirt
  tokListObjContains:  Int   // List<object>::Contains(object): bool  callvirt
  tokListObjRemoveAt:  Int   // List<object>::RemoveAt(int32): void  callvirt
  tokListObjTypeSpec:  Int   // TypeSpec token for List<object>  castclass
  // String intrinsic members (instance HASTHIS)
  tokStringGetChars:    Int   // String.get_Chars(int32): char
  tokStringGetLength:   Int   // String.get_Length(): int32
  tokStringSubstring:   Int   // String.Substring(int32,int32): string
  tokStringReplace:     Int   // String.Replace(string,string): string
  tokStringIsNormalized: Int  // String.IsNormalized(): bool
  tokStringNormalize:   Int   // String.Normalize(): string
  tokStringTrim:        Int   // String.Trim(): string
  tokStringIndexOf:     Int   // String.IndexOf(string): int32  (-1 if absent)
  tokStringLastIndexOf: Int   // String.LastIndexOf(string): int32  (-1 if absent)
  tokStringStartsWith:  Int   // String.StartsWith(string): bool
  tokStringEndsWith:    Int   // String.EndsWith(string): bool
  tokStringContains:    Int   // String.Contains(string): bool
  tokStringToLower:     Int   // String.ToLowerInvariant(): string
  tokStringToUpper:     Int   // String.ToUpperInvariant(): string
  // Object.Equals(object,object): bool  static (for value-equal string comparisons)
  tokObjectStaticEquals: Int
  // Async support (Phase A, Band 3).
  // Task and Task`1 TypeRef rows — used to build TypeSpec+MemberRef tokens lazily
  // in `emitExternTargetBody` for `@externTarget async func` unwrapping.
  trTask:      Int   // System.Threading.Tasks.Task (non-generic)
  trTask1:     Int   // System.Threading.Tasks.Task`1 (open generic)
  tokTaskWait: Int   // Task::Wait(): void  instance HASTHIS (void async externs)
  // ISO-8601 toString(DateTime).  Mirrors the F# bootstrap emitter's
  // DateTime.ToString("o") path (Codegen.fs) so stage-0 and stage-1 render
  // DateTime identically (#2184).  "o" is culture-invariant by spec.
  tokDateTimeToStringFmt: Int  // DateTime.ToString(string): string  instance HASTHIS
  // Reverse lookup: simple field name → FieldDef token.  Populated by
  // addPackageTokens for IRecord and IExposedRec fields so EMember can emit
  // ldfld on an MObject receiver when the static type is unknown.
  fieldTokensByName:    Map[String, Int]
  // Dictionary<object,object> via TypeSpec (for newMap() and map operations)
  tokDictObjCtor:     Int   // Dictionary<object,object>::.ctor()  newobj
  tokDictObjAdd:      Int   // Dictionary<object,object>::Add(object,object): void  callvirt
  tokDictObjGetItem:  Int   // Dictionary<object,object>::get_Item(object): object  callvirt
  tokDictObjSetItem:  Int   // Dictionary<object,object>::set_Item(object,object): void  callvirt
  tokDictObjTypeSpec: Int   // TypeSpec token for Dictionary<object,object>  castclass
  tokDictObjGetCount: Int   // Dictionary<object,object>::get_Count(): int32  callvirt
  tokDictObjContainsKey: Int  // Dictionary<object,object>::ContainsKey(object): bool  callvirt
  tokDictObjRemove:      Int  // Dictionary<object,object>::Remove(object): bool  callvirt
  tokDictObjTryGetValue: Int  // Dictionary<object,object>::TryGetValue(object, object): bool
  // Intra-package pre-computed tokens
  recordCtorTokens:   Map[String, Int]   // className → MethodDef token
  fieldTokens:        Map[String, Int]   // "ClassName/fieldName" → FieldDef token
  // Field metadata for cross-assembly generic union cases.  Both maps use the
  // same "ClassName/fieldName" and "ClassName/fieldN" key space as fieldTokens.
  // fieldSigBytes  → raw FieldSig blob (06 13 00 for VAR(0), etc.) used to
  //                  build TypeSpec-parented MemberRefs at ldfld sites.
  // fieldDeclaredNames → positional key "ClassName/fieldN" → declared field name
  //                  (e.g. "Std.Core.Option_Some/field0" → "value") so that
  //                  lowerPatternBindMsil can name the TypeSpec MemberRef
  //                  correctly when the user writes a binding alias
  //                  (`case Some(x)` instead of `case Some(value)`).
  fieldSigBytes:      Map[String, List[Byte]]
  fieldDeclaredNames: Map[String, String]
  fieldVarIndices:    Map[String, Int]
  // MSIL type for in-package record/union-case fields.  Key = "FQClassName/fieldName".
  // Populated by addPackageTokens so EMember returns the actual ldfld type (MBool,
  // MInt, etc.) rather than always MObject — prevents StackUnexpected / IPE when
  // value-type fields are compared with ceq vs. Object.Equals (#1442).
  fieldMsilTypes:     Map[String, MsilType]
  funcTokens:         Map[String, Int]   // funcName → MethodDef token
  funcRetTypes:       Map[String, MsilType]   // funcName → MsilType of declared return
  // funcName → declared parameter MsilTypes (same arity-qualified + bare keys
  // as funcTokens).  Used to thread a call argument's expected type into
  // `contextHintTyArgs` so a bare `f(None)` constructs `Option_None<concrete>`
  // rather than erasing to `<object>` (keeps the canonical nullary-case
  // representation consistent across construction positions).
  funcParamTypes:     Map[String, List[MsilType]]
  // Declared parameter MODES per function (same keys as funcParamTypes:
  // arity-qualified + bare-FQN alias).  Lets a call site pass `out`/`inout`
  // arguments by managed pointer (address-load) instead of by value.  See #1761.
  funcParamModes:     Map[String, List[ParamMode]]
  // Inner parameter MsilTypes of a function-typed parameter (`(A,B) -> R` ⇒
  // [MsilType(A), MsilType(B)]), keyed `"<fqn>#<paramIdx>"` (both the
  // arity-qualified and bare-FQN aliases).  Only function-typed parameters have
  // an entry.  Lets a call site propagate the expected parameter types of a
  // lambda passed directly as an argument into that lambda's body so its boxed
  // params unbox correctly (#1939).  Flat (not nested) to sidestep the stage-0
  // emitter's List[List[_]] indexing inference.
  funcParamFnInner:   Map[String, List[MsilType]]
  // Propagated parameter MsilTypes for a lifted lambda, keyed by lambda name
  // ("__lambda_<idx>").  Recorded at the call site (from funcParamFnInner) before
  // the lambda arg is lowered; consumed by lowerFuncMsil's `__lambda_*` path to
  // seed boxedParamTypes for un-annotated params.  #1939.
  lambdaParamTypes:   Map[String, List[MsilType]]
  // Capturing closures (#1479).  Keyed by lambda name ("__lambda_<idx>"): the
  // enclosing-scope variable names a lambda captures, and their MsilTypes
  // (parallel lists).  Recorded at the capture site; consumed by lowerFuncMsil's
  // `__lambda_*` path, which prepends an `object[] __caps` parameter and resolves
  // each captured name to `__caps[i]` (unboxed).  Captured values are bound into
  // the array at the capture site and the array is the delegate's (closed) target.
  lambdaCaptureNames: Map[String, List[String]]
  lambdaCaptureTypes: Map[String, List[MsilType]]
  // Subset of lambdaCaptureNames[name] that are by-reference cells (a hoisted
  // enclosing `var`): the `object[] __caps` slot holds the `List[object]` cell
  // itself, so the lifted body reads/writes it via `get_Item(0)`/`set_Item(0)`
  // (#1479 v2).  Captures absent from this list are by-value boxed copies.
  lambdaCaptureCells: Map[String, List[String]]
  // Compile-time const values: registered by IConst pre-scan so that EPath
  // references to const names inline ldc.i4 instead of ldsfld.
  constValues:        Map[String, Int]        // constName → inlined Int value
  // FFI caches (#370 + Phase R6).  Populated lazily by
  // emitExternTargetBody as `@externTarget` declarations are walked.
  ffiAsmRefs:         Map[String, Int]   // assembly simple name → AssemblyRef row index
  ffiTypeRefs:        Map[String, Int]   // "asm/ns.name" key → TypeRef row index
  // Auto-FFI metadata resolution (epic #1622, Phase 3c + 4).  Lazily-built
  // once per package over the reference pack; `metadataReady` is a one-shot
  // flag holder (empty = not yet built) since record scalar fields can't be
  // reassigned.  `metadataVtypeSet` maps public value-type FQNs (structs /
  // enums) to true — used by externValueTypeMsil to detect value types from
  // metadata instead of the retired clrIsValueType hardcoded list (#1802).
  metadataTypeIndex:  Map[String, String]
  metadataPathIndex:  Map[String, String]
  metadataVtypeSet:   Map[String, Bool]
  metadataReady:      List[Bool]
  // Lambda / yield / extern-type support (Band 2, R6).
  tokActionCtor:      Int                // System.Action::.ctor(object, native int)
  tokActionInvoke:    Int                // System.Action::Invoke(): void
  actionTypeRefs:     Map[String, Int]   // toString(nparams) → TypeRef row for System.Action`N
  externTypeNames:    Map[String, String]  // Lyric name → CLR FQN (from IExternType items)
  lambdaTicker:       List[Int]          // length = next __lambda_<i> index
  // Instance method MethodDef tokens, keyed by "FQClassName/methodName".  Populated
  // by `addPackageTokens` for record methods, interface methods (abstract slots),
  // and impl methods folded into the implementing record.  `lowerMethodCallMsil`
  // looks these up to emit `callvirt` for user-defined dispatch (#878).
  methodTokens:       Map[String, Int]
  // Declared return MsilType per instance/interface method, keyed by the same
  // "FQClassName/methodName" form as `methodTokens`.  `lowerMethodCallMsil`
  // looks this up so a user-defined dispatch reports its real return type
  // (e.g. a `Result[Unit, E]` union) to its caller instead of a bare `object`.
  // Without it the scrutinee of a `match store.set(...)` was tracked as
  // `MObject`, so union pattern tests/binds mis-extracted the payload and the
  // wrong arm fired (#1602).  Mirrors `funcRetTypes` for direct static calls.
  methodRetTypes:     Map[String, MsilType]
  // Declared MSIL parameter type per instance/interface/impl method parameter,
  // keyed `<FQClassName>/<methodName>#<paramIndex>` (0-based, excluding the
  // implicit `this`).  `lowerMethodCallMsil` consults it so a value-type
  // argument is passed as-is to a value-type parameter instead of being boxed —
  // the method signature declares the concrete value type, so boxing produced
  // `object` where `bool`/`int32` was expected (invalid IL, #1784).  A missing
  // entry falls back to the conservative box-if-value-type behaviour.
  methodParamTypes:   Map[String, MsilType]
  // Per-method param-mode list keyed by `<className>/<methodName>`.  Used by
  // the interface/impl dispatch in `lowerMethodCallMsil` to emit a byref
  // (managed pointer) load for `out`/`inout` arguments instead of the
  // by-value load — without it interface calls with byref params bound to
  // signatures missing the `&` qualifier (#1955).
  methodParamModes:   Map[String, List[ParamMode]]
  // Pending interface implementations discovered by the IImpl pre-pass.  Each
  // entry maps an implementing record's FQ name to its impl block(s); used to
  // (a) inject impl methods into the target MRecord, and (b) emit MPImpl items
  // after all TypeDefs are lowered so InterfaceImpl / MethodImpl rows can be
  // resolved by name (#878).
  implEntries:        List[ImplEntryMsil]
  // Persistent row counters for multi-package compilation (#1183).
  // `.count` tracks the highest MethodDef / FieldDef row already allocated by
  // prior `addPackageTokens` calls, so the next call starts at `.count + 1`
  // (matching the row-budget pre-scan order in `lowerMPackageWithCtx`).
  // For single-package compile (`Msil.Bridge.compileToMsil`), these are
  // freshly empty and the counter starts at 1 — behaviour unchanged.
  //
  // These are deliberately `List[Int]` rather than `Int`: Lyric records hold
  // their fields by value, so a non-`var Int` field could not be mutated in
  // place from `addPackageTokens`.  The list-padding shape mirrors
  // `lambdaTicker` (`L`-shaped counter, only the `.count` matters) and is
  // documented as the standard counter idiom in the self-hosted codegen
  // pending a proper `var` field landing (#1186).
  nextMethodDefRow:   List[Int]
  nextFieldDefRow:    List[Int]
  // Bundle-wide entry point.  When `addPackageTokens` walks a package and
  // encounters a top-level `func main()`, it records the MethodDef token
  // here.  At most one element — the first package whose `main()` is seen
  // wins, matching the F# `emitProject` host-entry policy.  Stays empty
  // when no package defines `main` (library-shaped bundle).  See #1183
  // Phase 2.
  mainEntryToken:     List[Int]
  // Per-package import edges (#1183 Phase 2).  `pkgImports[pkgName]` is the
  // dotted-name list of every package that `pkgName` imports.  Populated by
  // `addPackageTokens` so that call-site resolution in
  // `lowerBuiltinOrStaticCallMsil` can fall back to each imported package's
  // FQN-keyed funcs when a bare call doesn't match the current package.
  pkgImports:         Map[String, List[String]]
  // Cross-package union case lookup (#1183 codegen port).  Maps a union
  // case's simple name (e.g. "Some") to its FQN ctor key
  // (e.g. "Std.Core.Option$Some") so the construction site can resolve
  // calls like `Some(value = 42)` from a package that imports the union
  // rather than declares it.  `recordCtorTokens` is keyed by the FQN,
  // so a successful lookup here yields the key for the existing token
  // table.  When two unions in different packages share a simple case
  // name the first-processed wins (Dictionary.Add throws on duplicates;
  // `addPackageTokens` guards with `containsKey`).  The match-arm side
  // does not need a parallel table — `lowerPatternTestMsil` resolves
  // the case's TypeDef row directly via `findTypeDefRowByName`.
  unionCaseCtorByName: Map[String, String]
  // Cross-package type name lookup (#1183 codegen port).  Maps a type's
  // simple name (e.g. "Maybe", "Point") to its FQN
  // (e.g. "XPkgUnion.Lib.Maybe").  `typeExprToMsil` consults this when
  // resolving a single-segment `TRef` like `Maybe[Int]` after an
  // `import XPkgUnion.Lib`, so the resulting `MClass` carries the
  // correct cross-package FQN instead of `<current-pkg>.<seg>`.  First-
  // processed wins on collisions, mirroring `unionCaseCtorByName`.
  typeFqnByName:       Map[String, String]
  // Generic stdlib union case type-param count. Key = FQN ctor key of the
  // case class (e.g. "Std.Core.Option_Some"). Value = number of type params
  // on the parent union (e.g. 1 for Option[T], 2 for Result[T,E]). Used at
  // construction sites to build TypeSpec-based newobj tokens, which ECMA-335
  // §III.4.21 requires for generic types ("if typeTok is a generic class, the
  // token shall be a TypeSpec token").
  caseTypeParamCount:  Map[String, Int]
  // Synthesised views of restored DLLs the bundle imports but doesn't ship; seeds cross-assembly tokens (#1272).
  restoredArtifacts:   List[SynthesisedArtifact]
  // Nullary union case singletons.  Key = FQN ctor key (e.g. "Pkg.Union$Case");
  // value = FieldDef token (0x04000000 | row) for the static `Instance` field
  // emitted by lowerMNullaryUnionCase.  Construction sites that find a key here
  // emit `ldsfld Instance` instead of `newobj .ctor()` so that reference-equality
  // comparisons (BEq / Object.Equals) succeed when the same nullary case is used
  // in multiple places.
  singletonFieldTokens: Map[String, Int]
  // Module-level `val` static fields.  Pre-computed in `addPackageTokens`
  // (after all type FieldDef rows, in IVal source order) so that `EPath`
  // references inside function bodies can emit `ldsfld` rather than falling
  // through to the null-as-unknown fallback.  Parallels `singletonFieldTokens`
  // for nullary union cases.
  staticValTokens:     Map[String, Int]       // valName → 0x04000000 | fieldDefRow
  staticValMsilTypes:  Map[String, MsilType]  // valName → declared MsilType
  // Async SM synthesis (Phase B, Epic #2070).
  // TypeRef rows for System.Runtime.CompilerServices types.
  trAtmb:           Int   // AsyncTaskMethodBuilder (void variant, row)
  trAtmb1:          Int   // AsyncTaskMethodBuilder`1 (open generic, row)
  trIAsm:           Int   // IAsyncStateMachine (interface, row)
  // MemberRef tokens for ATMB (void) instance methods.
  tokAtmbCreate:    Int   // registered for MemberRef table ordering; not emitted (ATMB.Create() removed in .NET 7+, replaced by newobj zero-init)
  tokAtmbSetResult: Int   // ATMB::SetResult(): void  call (instance, on managed ptr)
  tokAtmbGetTask:   Int   // registered for MemberRef table ordering; not emitted directly (get_Task() is called via TypeSpec-parented MemberRef in the kickoff, not through this field)
  tokAtmbStartMr:   Int   // ATMB.Start<!!0>(ref !!0): void  open-generic MemberRef
  // Phase B.1 async suspension tokens.
  trTaskAwaiter1:        Int   // System.Runtime.CompilerServices.TaskAwaiter`1 (open generic struct)
  trTaskAwaiter:         Int   // System.Runtime.CompilerServices.TaskAwaiter   (non-generic struct)
  tokAtmbAwaitUnsafeMr:  Int   // ATMB.AwaitUnsafeOnCompleted<!!0,!!1> open MemberRef row (void ATMB TypeRef parent)
  tokAtmb1AwaitUnsafeMr: Int   // ATMB`1.AwaitUnsafeOnCompleted<!!0,!!1> open MemberRef row (ATMB`1 TypeRef parent)
  // Monotonically-increasing counter for unique SM class names.
  // Pattern: "<funcName>__SM_<ticker>".  Matches AsyncStateMachine.fs convention.
  smTicker: List[Int]
}

// One impl block (`impl Iface for Target { … }`) captured by the pre-pass.
// `methods` are produced by `lowerImplMethodMsil`, which reserves slot 0 for
// the implicit `this` so `self` and user parameters resolve correctly when
// the methods are emitted as virtual instance members of the target type.
pub record ImplEntryMsil {
  targetTypeName: String        // FQN, e.g. "Pkg.EnglishGreeter"
  ifaceTypeName:  String        // FQN, e.g. "Pkg.Greeter"
  methods:        List[MFunc]
}

// Build and return a fresh CodegenCtx for the named package.
// Registers all external AssemblyRef/TypeRef/MemberRef rows in a stable order
// so that every instruction token is a predictable constant.
// `major` / `minor` populate the Assembly row's version; both default to
// zero for bootstrap-grade callers that don't thread a manifest version.
// See `Msil.Bridge` entry points for the version threading wiring (#1364).
pub func newCodegenCtx(packageName: in String,
                       restoredArtifacts: in List[SynthesisedArtifact],
                       major: in Int, minor: in Int): CodegenCtx {
  val lctx = newLoweringCtx(packageName, major, minor)
  // After newLoweringCtx:
  //   arRuntime  = 1  (System.Runtime AssemblyRef)
  //   trObject   = 1  (System.Object TypeRef)

  // AssemblyRef[2]: System.Console
  val arConsole = ctxAddAssemblyRef(lctx, "System.Console", 10, 0)

  // TypeRef rows 2..8
  val trConsole  = ctxAddTypeRef(lctx, "System", "Console",   arConsole)
  val trString   = ctxAddTypeRef(lctx, "System", "String",    lctx.arRuntime)
  val trInt32    = ctxAddTypeRef(lctx, "System", "Int32",     lctx.arRuntime)
  val trInt64    = ctxAddTypeRef(lctx, "System", "Int64",     lctx.arRuntime)
  val trDouble   = ctxAddTypeRef(lctx, "System", "Double",    lctx.arRuntime)
  val trBoolean  = ctxAddTypeRef(lctx, "System", "Boolean",   lctx.arRuntime)
  val trChar     = ctxAddTypeRef(lctx, "System", "Char",      lctx.arRuntime)
  val trException      = ctxAddTypeRef(lctx, "System", "Exception",      lctx.arRuntime)
  val trIFormatProvider = ctxAddTypeRef(lctx, "System", "IFormatProvider", lctx.arRuntime)
  val trCultureInfo     = ctxAddTypeRef(lctx, "System.Globalization", "CultureInfo", lctx.arRuntime)

  // Build MemberRef signatures.
  // 1. Console.WriteLine(string): void  → MemberRef[1] → token 0x0A000001
  val wlStrPs: List[MsilType] = newList()
  wlStrPs.add(MString)
  val tokWLStr = 0x0A000000 + ctxAddMemberRef(
    lctx, trConsole, "WriteLine",
    "wl_str", buildStaticMethodSig(wlStrPs, MVoid))

  // 2. Console.WriteLine(int32): void  → 0x0A000002
  val wlIntPs: List[MsilType] = newList()
  wlIntPs.add(MInt)
  val tokWLInt = 0x0A000000 + ctxAddMemberRef(
    lctx, trConsole, "WriteLine",
    "wl_int", buildStaticMethodSig(wlIntPs, MVoid))

  // 3. Console.WriteLine(int64): void  → 0x0A000003
  val wlLongPs: List[MsilType] = newList()
  wlLongPs.add(MLong)
  val tokWLLong = 0x0A000000 + ctxAddMemberRef(
    lctx, trConsole, "WriteLine",
    "wl_long", buildStaticMethodSig(wlLongPs, MVoid))

  // 4. Console.WriteLine(double): void  → 0x0A000004
  val wlDblPs: List[MsilType] = newList()
  wlDblPs.add(MDouble)
  val tokWLDbl = 0x0A000000 + ctxAddMemberRef(
    lctx, trConsole, "WriteLine",
    "wl_dbl", buildStaticMethodSig(wlDblPs, MVoid))

  // 5. Console.WriteLine(bool): void  → 0x0A000005
  val wlBoolPs: List[MsilType] = newList()
  wlBoolPs.add(MBool)
  val tokWLBool = 0x0A000000 + ctxAddMemberRef(
    lctx, trConsole, "WriteLine",
    "wl_bool", buildStaticMethodSig(wlBoolPs, MVoid))

  // 6. Console.Write(string): void  → 0x0A000006
  val wStrPs: List[MsilType] = newList()
  wStrPs.add(MString)
  val tokWStr = 0x0A000000 + ctxAddMemberRef(
    lctx, trConsole, "Write",
    "w_str", buildStaticMethodSig(wStrPs, MVoid))

  // 7. String.Concat(string,string): string  → 0x0A000007
  val concat2Ps: List[MsilType] = newList()
  concat2Ps.add(MString)
  concat2Ps.add(MString)
  val tokConcat2 = 0x0A000000 + ctxAddMemberRef(
    lctx, trString, "Concat",
    "concat2", buildStaticMethodSig(concat2Ps, MString))

  // 8. String.Concat(string,string,string): string  → 0x0A000008
  val concat3Ps: List[MsilType] = newList()
  concat3Ps.add(MString)
  concat3Ps.add(MString)
  concat3Ps.add(MString)
  val tokConcat3 = 0x0A000000 + ctxAddMemberRef(
    lctx, trString, "Concat",
    "concat3", buildStaticMethodSig(concat3Ps, MString))

  // 9. Exception..ctor(string): void  instance HASTHIS  → 0x0A000009
  val excCtorPs: List[MsilType] = newList()
  excCtorPs.add(MString)
  val tokExcCtor = 0x0A000000 + ctxAddMemberRef(
    lctx, trException, ".ctor",
    "exc_ctor", buildInstanceMethodSig(excCtorPs, MVoid))

  // 10. String.Format(string,object): string  → 0x0A00000A
  val fmt1Ps: List[MsilType] = newList()
  fmt1Ps.add(MString)
  fmt1Ps.add(MObject)
  val tokFmt1 = 0x0A000000 + ctxAddMemberRef(
    lctx, trString, "Format",
    "fmt1", buildStaticMethodSig(fmt1Ps, MString))

  // 11. String.Format(string,object,object): string  → 0x0A00000B
  val fmt2Ps: List[MsilType] = newList()
  fmt2Ps.add(MString)
  fmt2Ps.add(MObject)
  fmt2Ps.add(MObject)
  val tokFmt2 = 0x0A000000 + ctxAddMemberRef(
    lctx, trString, "Format",
    "fmt2", buildStaticMethodSig(fmt2Ps, MString))

  // 12. String.Format(string,object,object,object): string  → 0x0A00000C
  val fmt3Ps: List[MsilType] = newList()
  fmt3Ps.add(MString)
  fmt3Ps.add(MObject)
  fmt3Ps.add(MObject)
  fmt3Ps.add(MObject)
  val tokFmt3 = 0x0A000000 + ctxAddMemberRef(
    lctx, trString, "Format",
    "fmt3", buildStaticMethodSig(fmt3Ps, MString))

  // 13. Object.ToString(): string  instance HASTHIS  → 0x0A00000D
  val toStrPs: List[MsilType] = newList()
  val tokObjToStr = 0x0A000000 + ctxAddMemberRef(
    lctx, lctx.trObject, "ToString",
    "obj_tostring", buildInstanceMethodSig(toStrPs, MString))

  // CultureInfo.get_InvariantCulture(): CultureInfo  static
  val tokCultInvGet = 0x0A000000 + ctxAddMemberRef(
    lctx, trCultureInfo, "get_InvariantCulture",
    "cult_inv_get", buildStaticMethodSig(newList(),
      MClassRef(typeRefCode = tdrTypeRef(trCultureInfo), clrFqn = "System.Globalization.CultureInfo")))

  // Double.ToString(IFormatProvider): string  instance HASTHIS
  val dblTsInvPs: List[MsilType] = newList()
  dblTsInvPs.add(MClassRef(typeRefCode = tdrTypeRef(trIFormatProvider), clrFqn = "System.IFormatProvider"))
  val tokDblToStrInv = 0x0A000000 + ctxAddMemberRef(
    lctx, trDouble, "ToString",
    "dbl_tostring_inv", buildInstanceMethodSig(dblTsInvPs, MString))

  // System.Type TypeRef (needed for GetType / get_Name)
  val trType = ctxAddTypeRef(lctx, "System", "Type", lctx.arRuntime)

  // Exception.get_Message(): string  instance HASTHIS
  val excGetMsgPs: List[MsilType] = newList()
  val tokExcGetMessage = 0x0A000000 + ctxAddMemberRef(
    lctx, trException, "get_Message",
    "exc_get_message", buildInstanceMethodSig(excGetMsgPs, MString))

  // Object.GetType(): Type  instance HASTHIS
  val objGetTypePs: List[MsilType] = newList()
  val tokObjGetType = 0x0A000000 + ctxAddMemberRef(
    lctx, lctx.trObject, "GetType",
    "obj_gettype", buildInstanceMethodSig(objGetTypePs, MObject))

  // Type.get_Name: string  instance HASTHIS  (Type is reference type; return MString)
  val typeGetNamePs: List[MsilType] = newList()
  val tokTypeGetName = 0x0A000000 + ctxAddMemberRef(
    lctx, trType, "get_Name",
    "type_get_name", buildInstanceMethodSig(typeGetNamePs, MString))

  // ── List<object> via TypeSpec ──────────────────────────────────────────────
  // AssemblyRef for System.Collections (houses List`1 contract in .NET 10)
  val arCollections = ctxAddAssemblyRef(lctx, "System.Collections", 10, 0)

  // TypeRef for System.Collections.Generic.List`1 (open generic definition)
  val trList1 = ctxAddTypeRef(lctx, "System.Collections.Generic", "List`1", arCollections)

  // TypeSpec: GENERICINST List`1<object>
  val listArgTypes: List[MsilType] = newList()
  listArgTypes.add(MObject)
  val listObjBlob = buildGenericInstBlob(tdrTypeRef(trList1), listArgTypes)
  val tsListObj = ctxAddTypeSpec(lctx, "ts_list_obj", listObjBlob)

  // 14. List<object>::.ctor(): void  instance HASTHIS
  val listCtorPs: List[MsilType] = newList()
  val tokListObjCtor = 0x0A000000 + ctxAddMemberRefForTypeSpec(
    lctx, tsListObj, ".ctor", "list_obj_ctor", buildInstanceMethodSig(listCtorPs, MVoid))

  // 15. List<object>::Add(!0): void  — MemberRef on TypeSpec must use ELEMENT_TYPE_VAR
  val listAddPs: List[MsilType] = newList()
  listAddPs.add(MTypeVar(0))
  val tokListObjAdd = 0x0A000000 + ctxAddMemberRefForTypeSpec(
    lctx, tsListObj, "Add", "list_obj_add", buildInstanceMethodSig(listAddPs, MVoid))

  // 16. List<object>::get_Item(int32): !0  — return type is the generic type param
  val listGetPs: List[MsilType] = newList()
  listGetPs.add(MInt)
  val tokListObjGetItem = 0x0A000000 + ctxAddMemberRefForTypeSpec(
    lctx, tsListObj, "get_Item", "list_obj_getitem", buildInstanceMethodSig(listGetPs, MTypeVar(0)))

  // 16b. List<object>::set_Item(int32, !0): void  — indexed assignment a[i] = v.
  // The value parameter is the generic element type (ELEMENT_TYPE_VAR 0); the
  // index is int32, matching get_Item.
  val listSetPs: List[MsilType] = newList()
  listSetPs.add(MInt)
  listSetPs.add(MTypeVar(0))
  val tokListObjSetItem = 0x0A000000 + ctxAddMemberRefForTypeSpec(
    lctx, tsListObj, "set_Item", "list_obj_setitem", buildInstanceMethodSig(listSetPs, MVoid))

  // 17. List<object>::get_Count(): int32  instance HASTHIS
  val listCntPs: List[MsilType] = newList()
  val tokListObjGetCount = 0x0A000000 + ctxAddMemberRefForTypeSpec(
    lctx, tsListObj, "get_Count", "list_obj_count", buildInstanceMethodSig(listCntPs, MInt))

  // 17b. List<object>::Contains(!0): bool  — element param is type var !0
  val listContainsPs: List[MsilType] = newList()
  listContainsPs.add(MTypeVar(index = 0))
  val tokListObjContains = 0x0A000000 + ctxAddMemberRefForTypeSpec(
    lctx, tsListObj, "Contains", "list_obj_contains", buildInstanceMethodSig(listContainsPs, MBool))

  // 17c. List<object>::RemoveAt(int32): void  instance HASTHIS
  val listRemoveAtPs: List[MsilType] = newList()
  listRemoveAtPs.add(MInt)
  val tokListObjRemoveAt = 0x0A000000 + ctxAddMemberRefForTypeSpec(
    lctx, tsListObj, "RemoveAt", "list_obj_removeat", buildInstanceMethodSig(listRemoveAtPs, MVoid))

  // ── Dictionary<object,object> via TypeSpec ────────────────────────────────
  val trDict2 = ctxAddTypeRef(lctx, "System.Collections.Generic", "Dictionary`2", arCollections)

  // TypeSpec: GENERICINST Dictionary`2<object,object>
  val dictArgTypes: List[MsilType] = newList()
  dictArgTypes.add(MObject)
  dictArgTypes.add(MObject)
  val dictObjBlob = buildGenericInstBlob(tdrTypeRef(trDict2), dictArgTypes)
  val tsDictObj = ctxAddTypeSpec(lctx, "ts_dict_obj", dictObjBlob)

  // 18. Dictionary<object,object>::.ctor(): void  instance HASTHIS
  val dictCtorPs: List[MsilType] = newList()
  val tokDictObjCtor = 0x0A000000 + ctxAddMemberRefForTypeSpec(
    lctx, tsDictObj, ".ctor", "dict_obj_ctor", buildInstanceMethodSig(dictCtorPs, MVoid))

  // 19. Dictionary<object,object>::Add(!0, !1): void  — MemberRef on TypeSpec uses type vars
  val dictAddPs: List[MsilType] = newList()
  dictAddPs.add(MTypeVar(0))
  dictAddPs.add(MTypeVar(1))
  val tokDictObjAdd = 0x0A000000 + ctxAddMemberRefForTypeSpec(
    lctx, tsDictObj, "Add", "dict_obj_add", buildInstanceMethodSig(dictAddPs, MVoid))

  // 20. Dictionary<object,object>::get_Item(!0): !1  — key param !0, value return !1
  val dictGetPs: List[MsilType] = newList()
  dictGetPs.add(MTypeVar(0))
  val tokDictObjGetItem = 0x0A000000 + ctxAddMemberRefForTypeSpec(
    lctx, tsDictObj, "get_Item", "dict_obj_getitem", buildInstanceMethodSig(dictGetPs, MTypeVar(1)))

  // 20b. Dictionary<object,object>::set_Item(!0, !1): void  — indexed
  // assignment `m[k] = v` on a Map.  Distinct from List<object>::set_Item
  // (which takes an int32 index): a Map store with a non-int key must go
  // through the dictionary indexer, or the codegen pushes a key of the wrong
  // stack type and the JIT rejects the body (#1602).
  val dictSetPs: List[MsilType] = newList()
  dictSetPs.add(MTypeVar(0))
  dictSetPs.add(MTypeVar(1))
  val tokDictObjSetItem = 0x0A000000 + ctxAddMemberRefForTypeSpec(
    lctx, tsDictObj, "set_Item", "dict_obj_setitem", buildInstanceMethodSig(dictSetPs, MVoid))

  // 21. Dictionary<object,object>::get_Count(): int32  instance HASTHIS
  val dictCntPs: List[MsilType] = newList()
  val tokDictObjGetCount = 0x0A000000 + ctxAddMemberRefForTypeSpec(
    lctx, tsDictObj, "get_Count", "dict_obj_count", buildInstanceMethodSig(dictCntPs, MInt))

  // 22. Dictionary<object,object>::ContainsKey(!0): bool  — key param is type var !0
  val dictCkPs: List[MsilType] = newList()
  dictCkPs.add(MTypeVar(0))
  val tokDictObjContainsKey = 0x0A000000 + ctxAddMemberRefForTypeSpec(
    lctx, tsDictObj, "ContainsKey", "dict_obj_ck", buildInstanceMethodSig(dictCkPs, MBool))

  // 22b. Dictionary<object,object>::Remove(!0): bool  HASTHIS — key is type var !0.
  val dictRmPs: List[MsilType] = newList()
  dictRmPs.add(MTypeVar(0))
  val tokDictObjRemove = 0x0A000000 + ctxAddMemberRefForTypeSpec(
    lctx, tsDictObj, "Remove", "dict_obj_remove", buildInstanceMethodSig(dictRmPs, MBool))

  // 23. Dictionary<object,object>::TryGetValue(object, out object): bool  HASTHIS
  // Signature: HASTHIS, 2 params, bool return, object key, byref-object value
  // For bootstrap we use get_Item instead; register as a stub pointing to get_Item sig.
  val tokDictObjTryGetValue = tokDictObjGetItem  // bootstrap: alias to get_Item

  // 24. System.Action TypeRef  (System.Runtime assembly)
  val trAction = ctxAddTypeRef(lctx, "System", "Action", lctx.arRuntime)

  // 25. System.Action::.ctor(object, native int): void  HASTHIS
  // Per ECMA-335: delegate .ctor takes an object (target) and a native int (method ptr).
  val actionCtorPs: List[MsilType] = newList()
  actionCtorPs.add(MObject)
  actionCtorPs.add(MNativeInt)
  val tokActionCtor = 0x0A000000 + ctxAddMemberRef(
    lctx, trAction, ".ctor", "action_ctor", buildInstanceMethodSig(actionCtorPs, MVoid))

  // 26. System.Action::Invoke(): void  HASTHIS
  val actionInvokePs: List[MsilType] = newList()
  val tokActionInvoke = 0x0A000000 + ctxAddMemberRef(
    lctx, trAction, "Invoke", "action_invoke", buildInstanceMethodSig(actionInvokePs, MVoid))

  // 27. String.get_Chars(int32): char  instance HASTHIS
  val strGetCharsPs: List[MsilType] = newList()
  strGetCharsPs.add(MInt)
  val tokStringGetChars = 0x0A000000 + ctxAddMemberRef(
    lctx, trString, "get_Chars",
    "str_get_chars", buildInstanceMethodSig(strGetCharsPs, MChar))

  // 28. String.get_Length(): int32  instance HASTHIS
  val strGetLengthPs: List[MsilType] = newList()
  val tokStringGetLength = 0x0A000000 + ctxAddMemberRef(
    lctx, trString, "get_Length",
    "str_get_length", buildInstanceMethodSig(strGetLengthPs, MInt))

  // 29. String.Substring(int32, int32): string  instance HASTHIS
  val strSubPs: List[MsilType] = newList()
  strSubPs.add(MInt)
  strSubPs.add(MInt)
  val tokStringSubstring = 0x0A000000 + ctxAddMemberRef(
    lctx, trString, "Substring",
    "str_substring", buildInstanceMethodSig(strSubPs, MString))

  // 29b. String.Replace(string, string): string  instance HASTHIS
  val strReplacePs: List[MsilType] = newList()
  strReplacePs.add(MString)
  strReplacePs.add(MString)
  val tokStringReplace = 0x0A000000 + ctxAddMemberRef(
    lctx, trString, "Replace",
    "str_replace", buildInstanceMethodSig(strReplacePs, MString))

  // 29c. String.IsNormalized(): bool  instance HASTHIS
  val strIsNormPs: List[MsilType] = newList()
  val tokStringIsNormalized = 0x0A000000 + ctxAddMemberRef(
    lctx, trString, "IsNormalized",
    "str_is_normalized", buildInstanceMethodSig(strIsNormPs, MBool))

  // 29d. String.Normalize(): string  instance HASTHIS
  val strNormPs: List[MsilType] = newList()
  val tokStringNormalize = 0x0A000000 + ctxAddMemberRef(
    lctx, trString, "Normalize",
    "str_normalize", buildInstanceMethodSig(strNormPs, MString))

  // 29e. Remaining String instance methods used via method syntax.
  val strTrimPs: List[MsilType] = newList()
  val tokStringTrim = 0x0A000000 + ctxAddMemberRef(
    lctx, trString, "Trim",
    "str_trim", buildInstanceMethodSig(strTrimPs, MString))

  val strIndexOfPs: List[MsilType] = newList()
  strIndexOfPs.add(MString)
  val tokStringIndexOf = 0x0A000000 + ctxAddMemberRef(
    lctx, trString, "IndexOf",
    "str_indexof", buildInstanceMethodSig(strIndexOfPs, MInt))

  val strLastIndexOfPs: List[MsilType] = newList()
  strLastIndexOfPs.add(MString)
  val tokStringLastIndexOf = 0x0A000000 + ctxAddMemberRef(
    lctx, trString, "LastIndexOf",
    "str_lastindexof", buildInstanceMethodSig(strLastIndexOfPs, MInt))

  val strStartsWithPs: List[MsilType] = newList()
  strStartsWithPs.add(MString)
  val tokStringStartsWith = 0x0A000000 + ctxAddMemberRef(
    lctx, trString, "StartsWith",
    "str_startswith", buildInstanceMethodSig(strStartsWithPs, MBool))

  val strEndsWithPs: List[MsilType] = newList()
  strEndsWithPs.add(MString)
  val tokStringEndsWith = 0x0A000000 + ctxAddMemberRef(
    lctx, trString, "EndsWith",
    "str_endswith", buildInstanceMethodSig(strEndsWithPs, MBool))

  val strContainsPs: List[MsilType] = newList()
  strContainsPs.add(MString)
  val tokStringContains = 0x0A000000 + ctxAddMemberRef(
    lctx, trString, "Contains",
    "str_contains", buildInstanceMethodSig(strContainsPs, MBool))

  // ToLowerInvariant / ToUpperInvariant (not the culture-sensitive
  // ToLower/ToUpper): protocol strings such as JWT algorithm names must
  // fold consistently regardless of thread culture (e.g. the Turkish-I
  // problem, where "I".ToLower() yields "ı" under tr-TR).
  val strToLowerPs: List[MsilType] = newList()
  val tokStringToLower = 0x0A000000 + ctxAddMemberRef(
    lctx, trString, "ToLowerInvariant",
    "str_tolower_inv", buildInstanceMethodSig(strToLowerPs, MString))

  val strToUpperPs: List[MsilType] = newList()
  val tokStringToUpper = 0x0A000000 + ctxAddMemberRef(
    lctx, trString, "ToUpperInvariant",
    "str_toupper_inv", buildInstanceMethodSig(strToUpperPs, MString))

  // 30. Object.Equals(object, object): bool  static
  val objEqPs: List[MsilType] = newList()
  objEqPs.add(MObject)
  objEqPs.add(MObject)
  val tokObjectStaticEquals = 0x0A000000 + ctxAddMemberRef(
    lctx, lctx.trObject, "Equals",
    "obj_static_eq", buildStaticMethodSig(objEqPs, MBool))

  // System.Action`N TypeRefs are registered lazily on first use for each N
  // (see internActionTypeRef); no static entries here.

  // Async support (Phase A, Band 3): Task and Task::Wait().
  // Task is in the System.Threading.Tasks assembly (per clrAssemblyForType).
  val arTasks = ctxAddAssemblyRef(lctx, "System.Threading.Tasks", 10, 0)
  val trTask  = ctxAddTypeRef(lctx, "System.Threading.Tasks", "Task",   arTasks)
  val trTask1 = ctxAddTypeRef(lctx, "System.Threading.Tasks", "Task`1", arTasks)
  // Task::Wait(): void  instance HASTHIS — used to block on void async externs.
  val tokTaskWait = 0x0A000000 + ctxAddMemberRef(
    lctx, trTask, "Wait",
    "task_wait", buildInstanceMethodSig(newList(), MVoid))

  // DateTime.ToString(string): string  — instance HASTHIS.  Used for the
  // ISO-8601 "o" round-trip format; mirrors Codegen.fs which calls
  // DateTime.ToString("o").  DateTime is type-forwarded from System.Runtime.
  val trDateTime        = ctxAddTypeRef(lctx, "System", "DateTime", lctx.arRuntime)
  val dtToStrFmtPs: List[MsilType] = newList()
  dtToStrFmtPs.add(MString)
  val tokDateTimeToStringFmt = 0x0A000000 + ctxAddMemberRef(
    lctx, trDateTime, "ToString",
    "dt_tostring_fmt", buildInstanceMethodSig(dtToStrFmtPs, MString))

  // Async SM synthesis (Phase B, Epic #2070).
  // AsyncTaskMethodBuilder and IAsyncStateMachine live in System.Runtime.
  val trAtmb  = ctxAddTypeRef(lctx, "System.Runtime.CompilerServices",
                               "AsyncTaskMethodBuilder",   lctx.arRuntime)
  val trAtmb1 = ctxAddTypeRef(lctx, "System.Runtime.CompilerServices",
                               "AsyncTaskMethodBuilder`1", lctx.arRuntime)
  val trIAsm  = ctxAddTypeRef(lctx, "System.Runtime.CompilerServices",
                               "IAsyncStateMachine",       lctx.arRuntime)

  // Void builder method signatures (struct methods — HASTHIS, called via `call`
  // on a managed pointer produced by `ldflda`).
  // ATMB.Create(): ATMB  (static)
  val atmbMsilTy   = MValueTypeRef(typeRefCode = tdrTypeRef(trAtmb),
                                   clrFqn = "System.Runtime.CompilerServices.AsyncTaskMethodBuilder")
  val atmbCreateSig = buildStaticMethodSig(newList(), atmbMsilTy)
  val tokAtmbCreate = 0x0A000000 + ctxAddMemberRef(
    lctx, trAtmb, "Create", "atmb_create", atmbCreateSig)

  // ATMB.SetResult(): void  (instance HASTHIS)
  val tokAtmbSetResult = 0x0A000000 + ctxAddMemberRef(
    lctx, trAtmb, "SetResult",
    "atmb_setresult", buildInstanceMethodSig(newList(), MVoid))

  // ATMB.get_Task(): Task  (instance HASTHIS; property getter)
  val taskMsilTy    = MClassRef(typeRefCode = tdrTypeRef(trTask),
                                clrFqn = "System.Threading.Tasks.Task")
  val getTaskArgs: List[MsilType] = newList()
  val tokAtmbGetTask = 0x0A000000 + ctxAddMemberRef(
    lctx, trAtmb, "get_Task",
    "atmb_gettask", buildInstanceMethodSig(getTaskArgs, taskMsilTy))

  // ATMB.Start<!!0>(ref !!0): void  (open-generic instance; method is
  // instantiated per-SM at Phase 5 lowering via MCallAtmbStart).
  val tokAtmbStartMr = ctxAddMemberRef(
    lctx, trAtmb, "Start",
    "atmb_start_open", buildAtmbStartOpenSig())

  // Phase B.1: TaskAwaiter`1 and TaskAwaiter TypeRefs (GetAwaiter/GetResult call sites).
  val trTaskAwaiter1 = ctxAddTypeRef(lctx, "System.Runtime.CompilerServices",
                                      "TaskAwaiter`1", lctx.arRuntime)
  val trTaskAwaiter  = ctxAddTypeRef(lctx, "System.Runtime.CompilerServices",
                                      "TaskAwaiter",   lctx.arRuntime)

  // Phase B.1: open MemberRef rows for AwaitUnsafeOnCompleted<!!0,!!1>(ref !!0, ref !!1): void.
  // These are parent-typed MemberRefs: the void-path parent is the ATMB TypeRef;
  // the non-void path parent is the ATMB`1 TypeRef.  At each call site, a
  // TypeSpec-parented MemberRef will be built lazily (for non-void), or the
  // ATMB TypeRef-parented one is used directly (for void).  Both are registered
  // here so the MemberRef table order is stable across all packages.
  val tokAtmbAwaitUnsafeMr = ctxAddMemberRef(
    lctx, trAtmb, "AwaitUnsafeOnCompleted",
    "atmb_awaitunafe_open", buildAwaitUnsafeOnCompletedOpenSig())
  val tokAtmb1AwaitUnsafeMr = ctxAddMemberRef(
    lctx, trAtmb1, "AwaitUnsafeOnCompleted",
    "atmb1_awaitunafe_open", buildAwaitUnsafeOnCompletedOpenSig())

  val recCtorToks: Map[String, Int] = newMap()
  val fieldToks:   Map[String, Int] = newMap()
  val funcToks:    Map[String, Int] = newMap()

  CodegenCtx(
    lctx                 = lctx,
    trConsole            = trConsole,
    trString             = trString,
    trInt32              = trInt32,
    trInt64              = trInt64,
    trDouble             = trDouble,
    trBoolean            = trBoolean,
    trChar               = trChar,
    trException          = trException,
    trCultureInfo        = trCultureInfo,
    tokWriteLineStr      = tokWLStr,
    tokWriteLineInt      = tokWLInt,
    tokWriteLineLong     = tokWLLong,
    tokWriteLineDbl      = tokWLDbl,
    tokWriteLineBool     = tokWLBool,
    tokWriteStr          = tokWStr,
    tokConcat2           = tokConcat2,
    tokConcat3           = tokConcat3,
    tokExceptionCtor     = tokExcCtor,
    tokStringFormat1     = tokFmt1,
    tokStringFormat2     = tokFmt2,
    tokStringFormat3     = tokFmt3,
    tokObjToString             = tokObjToStr,
    tokCultureInfoInvariantGet = tokCultInvGet,
    tokDoubleToStringInv       = tokDblToStrInv,
    tokExcGetMessage     = tokExcGetMessage,
    tokObjGetType        = tokObjGetType,
    tokTypeGetName       = tokTypeGetName,
    tokDateTimeToStringFmt  = tokDateTimeToStringFmt,
    tokListObjCtor       = tokListObjCtor,
    tokListObjAdd        = tokListObjAdd,
    tokListObjGetItem    = tokListObjGetItem,
    tokListObjSetItem    = tokListObjSetItem,
    tokListObjGetCount   = tokListObjGetCount,
    tokListObjContains   = tokListObjContains,
    tokListObjRemoveAt   = tokListObjRemoveAt,
    tokListObjTypeSpec   = 0x1B000000 + tsListObj,
    tokDictObjCtor       = tokDictObjCtor,
    tokDictObjAdd        = tokDictObjAdd,
    tokDictObjGetItem    = tokDictObjGetItem,
    tokDictObjSetItem    = tokDictObjSetItem,
    tokDictObjTypeSpec   = 0x1B000000 + tsDictObj,
    tokDictObjGetCount   = tokDictObjGetCount,
    tokDictObjContainsKey = tokDictObjContainsKey,
    tokDictObjRemove      = tokDictObjRemove,
    tokDictObjTryGetValue = tokDictObjTryGetValue,
    recordCtorTokens     = recCtorToks,
    fieldTokens          = fieldToks,
    fieldSigBytes        = newMap(),
    fieldDeclaredNames   = newMap(),
    fieldVarIndices      = newMap(),
    fieldMsilTypes       = newMap(),
    funcTokens           = funcToks,
    funcRetTypes         = newMap(),
    funcParamTypes       = newMap(),
    funcParamModes       = newMap(),
    funcParamFnInner     = newMap(),
    lambdaParamTypes     = newMap(),
    lambdaCaptureNames   = newMap(),
    lambdaCaptureTypes   = newMap(),
    lambdaCaptureCells   = newMap(),
    constValues          = newMap(),
    ffiAsmRefs           = newMap(),
    ffiTypeRefs          = newMap(),
    metadataTypeIndex    = newMap(),
    metadataPathIndex    = newMap(),
    metadataVtypeSet     = newMap(),
    metadataReady        = newList(),
    tokActionCtor        = tokActionCtor,
    tokActionInvoke      = tokActionInvoke,
    tokStringGetChars    = tokStringGetChars,
    tokStringGetLength   = tokStringGetLength,
    tokStringSubstring   = tokStringSubstring,
    tokStringReplace     = tokStringReplace,
    tokStringIsNormalized = tokStringIsNormalized,
    tokStringNormalize   = tokStringNormalize,
    tokStringTrim        = tokStringTrim,
    tokStringIndexOf     = tokStringIndexOf,
    tokStringLastIndexOf = tokStringLastIndexOf,
    tokStringStartsWith  = tokStringStartsWith,
    tokStringEndsWith    = tokStringEndsWith,
    tokStringContains    = tokStringContains,
    tokStringToLower     = tokStringToLower,
    tokStringToUpper     = tokStringToUpper,
    tokObjectStaticEquals = tokObjectStaticEquals,
    trTask               = trTask,
    trTask1              = trTask1,
    tokTaskWait          = tokTaskWait,
    fieldTokensByName    = newMap(),
    actionTypeRefs       = newMap(),
    externTypeNames      = newMap(),
    lambdaTicker         = newList(),
    methodTokens         = newMap(),
    methodRetTypes       = newMap(),
    methodParamTypes     = newMap(),
    methodParamModes     = newMap(),
    implEntries          = newList(),
    nextMethodDefRow     = newList(),
    nextFieldDefRow      = newList(),
    mainEntryToken       = newList(),
    pkgImports           = newMap(),
    unionCaseCtorByName  = newMap(),
    typeFqnByName        = newMap(),
    caseTypeParamCount   = newMap(),
    restoredArtifacts    = restoredArtifacts,
    singletonFieldTokens = newMap(),
    staticValTokens      = newMap(),
    staticValMsilTypes   = newMap(),
    trAtmb               = trAtmb,
    trAtmb1              = trAtmb1,
    trIAsm               = trIAsm,
    tokAtmbCreate        = tokAtmbCreate,
    tokAtmbSetResult     = tokAtmbSetResult,
    tokAtmbGetTask       = tokAtmbGetTask,
    tokAtmbStartMr       = tokAtmbStartMr,
    trTaskAwaiter1         = trTaskAwaiter1,
    trTaskAwaiter          = trTaskAwaiter,
    tokAtmbAwaitUnsafeMr   = tokAtmbAwaitUnsafeMr,
    tokAtmb1AwaitUnsafeMr  = tokAtmb1AwaitUnsafeMr,
    smTicker             = newList())
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Token pre-scan — addPackageTokens.
// ─────────────────────────────────────────────────────────────────────────────

// Record an instance/interface method's declared return MsilType under `key`
// ("FQClassName/methodName").  A body-less signature (`None` ret) maps to
// MVoid.  First registration wins so a concrete impl method does not clobber an
// already-recorded entry.  Consumed by `lowerMethodCallMsil` (#1602).
func registerMethodRetTy(cctx: in CodegenCtx, key: in String, ret: in Option[TypeExpr], pkgName: in String): Unit {
  if not cctx.methodRetTypes.containsKey(key) {
    val mty = match ret {
      case Some(te) -> typeExprToMsilCtx(cctx, te, pkgName)
      case None     -> MVoid
    }
    cctx.methodRetTypes.add(key, mty)
  }
}

// Record each declared parameter's MsilType under `<keyBase>#<idx>` so
// `lowerMethodCallMsil` can avoid boxing a value-type argument passed to a
// value-type parameter (#1784).  First registration wins (matches the
// interface signature when an impl re-registers the same slot).
func registerMethodParamTypes(cctx: in CodegenCtx, keyBase: in String, params: in List[Param], pkgName: in String): Unit {
  var i = 0
  while i < params.count {
    val pk = keyBase + "#" + toString(i)
    if not cctx.methodParamTypes.containsKey(pk) {
      cctx.methodParamTypes.add(pk, typeExprToMsilCtx(cctx, params[i].ty, pkgName))
    }
    i = i + 1
  }
}

// Track each method's parameter modes so an interface/impl call site in
// `lowerMethodCallMsil` can emit a byref (managed pointer) load for `out`/
// `inout` arguments — paralleling `registerMethodParamTypes` (#1955).
func registerMethodParamModes(cctx: in CodegenCtx, key: in String, params: in List[Param]): Unit {
  if not cctx.methodParamModes.containsKey(key) {
    cctx.methodParamModes.add(key, paramModesOf(params))
  }
}

// MsilType-direct variant of `registerMethodRetTy`; first registration wins.
func registerMethodRetTyMsil(cctx: in CodegenCtx, key: in String, mty: in MsilType): Unit {
  if not cctx.methodRetTypes.containsKey(key) {
    cctx.methodRetTypes.add(key, mty)
  }
}

// Pre-scan the AST and assign MethodDef/FieldDef row numbers for every
// record, function, union case, interface method, opaque type, and protected
// type in the package.  Must be called before any `lowerFuncMsil` invocations
// so that intra-package call and field-access tokens are available.
//
// Row numbering follows codegenMPackage + lowerMPackageWithCtx emit order:
//   1. Non-IFunc items in source order (IRecord, IUnion, IInterface, IOpaque,
//      IProtected, etc.) — each contributes MethodDef rows in the same order
//      as its lowerM* counterpart.
//   2. MPFuncs (added last by codegenMPackage): optional .cctor row (when any
//      IVal has a non-literal initialiser), then one row per IFunc item.
pub func addPackageTokens(cctx: in CodegenCtx, file: in SourceFile,
                          pkgName: in String): Unit {
  // Collect IExternType names so auto-FFI call interception can resolve them.
  scanExternTypesMsil(cctx, file)

  // Stash this package's import edges so call-site resolution can walk
  // them (#1183 Phase 2).  Each import contributes its dotted path; the
  // alias-as suffix (`import X.Y as Z`) is ignored — the codegen falls back
  // to the source package's FQN regardless of any rebinding the typechecker
  // already applied.
  val importedDottedNames: List[String] = newList()
  var mi = 0
  while mi < file.imports.count {
    val imp = file.imports[mi]
    importedDottedNames.add(joinSegsMsil(imp.path.segments, "."))
    mi = mi + 1
  }
  cctx.pkgImports.add(pkgName, importedDottedNames)

  // Resume row numbering from where the previous package's pre-scan left off
  // (#1183 — multi-package compilation).  For a single-package compile via
  // `Msil.Bridge.compileToMsil`, the cctx is fresh and both counters are
  // empty, so the starting rows are 1/1 — behaviour unchanged.
  var methodDefRow = cctx.nextMethodDefRow.count + 1
  var fieldDefRow  = cctx.nextFieldDefRow.count + 1

  // Threading `constEnv` lets `val b = a` (a literal val) stay literal; without it a phantom .cctor MethodDef row would shift every later IFunc token.
  val constEnv: Map[String, Bool] = newMap()
  var hasValCctor = false
  var pi = 0
  while pi < file.items.count {
    match file.items[pi].kind {
      case IVal(decl) -> {
        val isLit = isLiteralI4ExprMsilWithEnv(decl.init, constEnv)
        if not isLit {
          hasValCctor = true
        }
        match decl.pattern.kind {
          case PBinding(valName, _) -> constEnv.add(valName, isLit)
          case _                    -> {}  // non-simple bindings can't appear in EPath
        }
      }
      case _ -> {}
    }
    pi = pi + 1
  }

  // Pass 1: source-order scan for non-IFunc items that emit MethodDef rows.
  // #878: collect impl-method (target, name) pairs in two parallel flat lists
  // so the per-record row budget includes the injected impl methods.  A flat
  // list avoids the Map[String,List[String]] + inner newList() pattern that the
  // F# bootstrap emitter does not support.
  val implImplTargets: List[String] = newList()
  val implImplNames:   List[String] = newList()
  // Parallel to implImplNames: each impl method's declared return MsilType, so
  // the methodRetTypes registration below reports a real type to call sites
  // that dispatch on the concrete receiver (e.g. `self.save(updated)`) (#1602).
  val implImplRetTys:  List[MsilType] = newList()
  var ipi = 0
  while ipi < file.items.count {
    match file.items[ipi].kind {
      case IImpl(idecl) -> {
        val targetName = implTargetNameMsil(idecl, pkgName)
        var imi = 0
        while imi < idecl.members.count {
          match idecl.members[imi] {
            case IMplFunc(fn) -> {
              implImplTargets.add(targetName)
              implImplNames.add(fn.name)
              implImplRetTys.add(match fn.ret {
                case Some(te) -> typeExprToMsilCtx(cctx, te, pkgName)
                case None     -> MVoid
              })
              // Param types for the concrete-receiver dispatch key (#1784).
              registerMethodParamTypes(cctx, targetName + "/" + fn.name, fn.params, pkgName)
              // Param modes so a byref argument is passed by address (#1955).
              registerMethodParamModes(cctx, targetName + "/" + fn.name, fn.params)
            }
            case IMplAssoc(_) -> {}
          }
          imi = imi + 1
        }
      }
      case _ -> {}
    }
    ipi = ipi + 1
  }

  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IRecord(decl) -> {
        // lowerMRecord: FieldDef per field; .ctor MethodDef; RMFunc MethodDefs;
        // followed by injected impl-method MethodDefs (#878).
        val className = pkgName + "." + decl.name
        // Cross-package type-name index (#1183 codegen port).
        if not cctx.typeFqnByName.containsKey(decl.name) {
          cctx.typeFqnByName.add(decl.name, className)
        }
        var fi = 0
        var fpos = 0
        while fi < decl.members.count {
          match decl.members[fi] {
            case RMField(f) -> {
              val tok = 0x04000000 + fieldDefRow
              cctx.fieldTokens.add(className + "/" + f.name, tok)
              if not cctx.fieldTokensByName.containsKey(pkgName + "/" + f.name) {
                cctx.fieldTokensByName.add(pkgName + "/" + f.name, tok)
              }
              val fty = typeExprToMsilCtx(cctx, f.ty, pkgName)
              if not cctx.fieldMsilTypes.containsKey(className + "/" + f.name) {
                cctx.fieldMsilTypes.add(className + "/" + f.name, fty)
              }
              // Also register under the short key used by the fieldTokensByName
              // lookup path so that field accesses on MObject (list elements)
              // return the correct MSIL type rather than falling back to MObject.
              if not cctx.fieldMsilTypes.containsKey(pkgName + "/" + f.name) {
                cctx.fieldMsilTypes.add(pkgName + "/" + f.name, fty)
              }
              // Positional name map (#1730): records the declared field name at
              // each declaration position so a named-argument constructor call
              // (`R(c = …, a = …)`) can be reordered to field-declaration order
              // before the positional `newobj`.  Keyed `<className>/field<pos>`,
              // matching the cross-package registration in registerStdlibTypeItem.
              val byPosKey = className + "/field" + toString(fpos)
              if not cctx.fieldDeclaredNames.containsKey(byPosKey) {
                cctx.fieldDeclaredNames.add(byPosKey, f.name)
              }
              fpos = fpos + 1
              fieldDefRow = fieldDefRow + 1
            }
            case _ -> {}
          }
          fi = fi + 1
        }
        cctx.recordCtorTokens.add(className, 0x06000000 + methodDefRow)
        methodDefRow = methodDefRow + 1
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case RMFunc(fn) -> {
              cctx.methodTokens.add(className + "/" + fn.name,
                                    0x06000000 + methodDefRow)
              registerMethodRetTy(cctx, className + "/" + fn.name, fn.ret, pkgName)
              registerMethodParamTypes(cctx, className + "/" + fn.name, fn.params, pkgName)
              registerMethodParamModes(cctx, className + "/" + fn.name, fn.params)
              methodDefRow = methodDefRow + 1
            }
            case _ -> {}
          }
          mi = mi + 1
        }
        // Register impl-method tokens for this record (#878).
        var ni = 0
        while ni < implImplTargets.count {
          if implImplTargets[ni] == className {
            cctx.methodTokens.add(className + "/" + implImplNames[ni],
                                  0x06000000 + methodDefRow)
            registerMethodRetTyMsil(cctx, className + "/" + implImplNames[ni], implImplRetTys[ni])
            methodDefRow = methodDefRow + 1
          }
          ni = ni + 1
        }
        // Reserve MethodDef rows for the synthesised @derive Equals/GetHashCode
        // overrides (#1480), emitted last by `appendDeriveOverridesMsil`.  The
        // per-marker `hasDeriveMarkerMsil` checks here MUST stay in lock-step
        // with the matching emission checks in `appendDeriveOverridesMsil`
        // (and the mirror site below for protected types) — adding a new
        // marker requires touching all three.
        val recAnns = file.items[i].annotations
        if hasDeriveMarkerMsil(recAnns, "Equals") {
          if not cctx.methodTokens.containsKey(className + "/Equals") {
            cctx.methodTokens.add(className + "/Equals", 0x06000000 + methodDefRow)
          }
          methodDefRow = methodDefRow + 1
        }
        if hasDeriveMarkerMsil(recAnns, "Hash") {
          if not cctx.methodTokens.containsKey(className + "/GetHashCode") {
            cctx.methodTokens.add(className + "/GetHashCode", 0x06000000 + methodDefRow)
          }
          methodDefRow = methodDefRow + 1
        }
      }
      case IExposedRec(decl) -> {
        // Same layout as IRecord.
        val className = pkgName + "." + decl.name
        if not cctx.typeFqnByName.containsKey(decl.name) {
          cctx.typeFqnByName.add(decl.name, className)
        }
        var fi = 0
        while fi < decl.members.count {
          match decl.members[fi] {
            case RMField(f) -> {
              val tok = 0x04000000 + fieldDefRow
              cctx.fieldTokens.add(className + "/" + f.name, tok)
              if not cctx.fieldTokensByName.containsKey(pkgName + "/" + f.name) {
                cctx.fieldTokensByName.add(pkgName + "/" + f.name, tok)
              }
              val fty = typeExprToMsilCtx(cctx, f.ty, pkgName)
              if not cctx.fieldMsilTypes.containsKey(className + "/" + f.name) {
                cctx.fieldMsilTypes.add(className + "/" + f.name, fty)
              }
              if not cctx.fieldMsilTypes.containsKey(pkgName + "/" + f.name) {
                cctx.fieldMsilTypes.add(pkgName + "/" + f.name, fty)
              }
              fieldDefRow = fieldDefRow + 1
            }
            case _ -> {}
          }
          fi = fi + 1
        }
        cctx.recordCtorTokens.add(className, 0x06000000 + methodDefRow)
        methodDefRow = methodDefRow + 1
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case RMFunc(fn) -> {
              cctx.methodTokens.add(className + "/" + fn.name,
                                    0x06000000 + methodDefRow)
              registerMethodRetTy(cctx, className + "/" + fn.name, fn.ret, pkgName)
              registerMethodParamTypes(cctx, className + "/" + fn.name, fn.params, pkgName)
              registerMethodParamModes(cctx, className + "/" + fn.name, fn.params)
              methodDefRow = methodDefRow + 1
            }
            case _ -> {}
          }
          mi = mi + 1
        }
        var ni = 0
        while ni < implImplTargets.count {
          if implImplTargets[ni] == className {
            cctx.methodTokens.add(className + "/" + implImplNames[ni],
                                  0x06000000 + methodDefRow)
            registerMethodRetTyMsil(cctx, className + "/" + implImplNames[ni], implImplRetTys[ni])
            methodDefRow = methodDefRow + 1
          }
          ni = ni + 1
        }
        // Reserve rows for synthesised @derive overrides (#1480); see IRecord.
        val recAnnsX = file.items[i].annotations
        if hasDeriveMarkerMsil(recAnnsX, "Equals") {
          if not cctx.methodTokens.containsKey(className + "/Equals") {
            cctx.methodTokens.add(className + "/Equals", 0x06000000 + methodDefRow)
          }
          methodDefRow = methodDefRow + 1
        }
        if hasDeriveMarkerMsil(recAnnsX, "Hash") {
          if not cctx.methodTokens.containsKey(className + "/GetHashCode") {
            cctx.methodTokens.add(className + "/GetHashCode", 0x06000000 + methodDefRow)
          }
          methodDefRow = methodDefRow + 1
        }
      }
      case IUnion(decl) -> {
        // lowerMUnion: protected .ctor for abstract base + one lowerMRecord/lowerMNullaryUnionCase per case.
        // Account for the protected no-arg .ctor emitted on the abstract base by lowerMUnion.
        methodDefRow = methodDefRow + 1  // abstract base's protected .ctor
        val unionFqn = pkgName + "." + decl.name
        if not cctx.typeFqnByName.containsKey(decl.name) {
          cctx.typeFqnByName.add(decl.name, unionFqn)
        }
        var ci = 0
        while ci < decl.cases.count {
          val c = decl.cases[ci]
          val caseName = pkgName + "." + decl.name + "$" + c.name
          var fi = 0
          while fi < c.fields.count {
            match c.fields[fi] {
              case UFNamed(name, ufTy, _) -> {
                cctx.fieldTokens.add(caseName + "/" + name,
                                     0x04000000 + fieldDefRow)
                // Also register positional key so binding aliases work
                // (e.g. `case LSome(v)` where the field is named `value`).
                if not cctx.fieldTokens.containsKey(caseName + "/field" + toString(fi)) {
                  cctx.fieldTokens.add(caseName + "/field" + toString(fi),
                                       0x04000000 + fieldDefRow)
                }
                val ufTyMsil = typeExprToMsilCtx(cctx, ufTy, pkgName)
                if not cctx.fieldMsilTypes.containsKey(caseName + "/" + name) {
                  cctx.fieldMsilTypes.add(caseName + "/" + name, ufTyMsil)
                }
                if not cctx.fieldMsilTypes.containsKey(caseName + "/field" + toString(fi)) {
                  cctx.fieldMsilTypes.add(caseName + "/field" + toString(fi), ufTyMsil)
                }
                fieldDefRow = fieldDefRow + 1
              }
              case UFPos(ufPosTy, _) -> {
                cctx.fieldTokens.add(caseName + "/field" + toString(fi),
                                     0x04000000 + fieldDefRow)
                val ufPosTyMsil = typeExprToMsilCtx(cctx, ufPosTy, pkgName)
                if not cctx.fieldMsilTypes.containsKey(caseName + "/field" + toString(fi)) {
                  cctx.fieldMsilTypes.add(caseName + "/field" + toString(fi), ufPosTyMsil)
                }
                fieldDefRow = fieldDefRow + 1
              }
            }
            fi = fi + 1
          }
          // Nullary cases get an extra Instance FieldDef + .cctor MethodDef
          // emitted by lowerMNullaryUnionCase so that construction sites can
          // use ldsfld instead of newobj, making reference-equality work.
          if c.fields.count == 0 {
            cctx.singletonFieldTokens.add(caseName, 0x04000000 + fieldDefRow)
            fieldDefRow = fieldDefRow + 1  // Instance static field
          }
          cctx.recordCtorTokens.add(caseName, 0x06000000 + methodDefRow)
          // Index by simple case name for cross-package construction
          // (#1183 codegen port).  Allows a user package to write
          // `Some(value = X)` after `import Std.Core` even though the
          // case ctor lives under the imported package's FQN.  First
          // hit wins on collisions (Dictionary.Add throws on duplicates,
          // so we guard with containsKey).  Same-name cases across
          // different unions are vanishingly rare in practice.
          if not cctx.unionCaseCtorByName.containsKey(c.name) {
            cctx.unionCaseCtorByName.add(c.name, caseName)
          }
          methodDefRow = methodDefRow + 1  // .ctor
          if c.fields.count == 0 {
            methodDefRow = methodDefRow + 1  // .cctor
          }
          ci = ci + 1
        }
      }
      case IInterface(decl) -> {
        // lowerMInterface: one abstract MethodDef per IMSig/IMFunc (rva=0, no body).
        // Register each abstract slot in `methodTokens` so callvirt against an
        // interface-typed receiver can dispatch through the interface vtable
        // (#878).
        val ifaceName = pkgName + "." + decl.name
        if not cctx.typeFqnByName.containsKey(decl.name) {
          cctx.typeFqnByName.add(decl.name, ifaceName)
        }
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case IMSig(sig)  -> {
              cctx.methodTokens.add(ifaceName + "/" + sig.name,
                                    0x06000000 + methodDefRow)
              registerMethodRetTy(cctx, ifaceName + "/" + sig.name, sig.ret, pkgName)
              registerMethodParamTypes(cctx, ifaceName + "/" + sig.name, sig.params, pkgName)
              registerMethodParamModes(cctx, ifaceName + "/" + sig.name, sig.params)
              methodDefRow = methodDefRow + 1
            }
            case IMFunc(fn)  -> {
              cctx.methodTokens.add(ifaceName + "/" + fn.name,
                                    0x06000000 + methodDefRow)
              registerMethodRetTy(cctx, ifaceName + "/" + fn.name, fn.ret, pkgName)
              registerMethodParamTypes(cctx, ifaceName + "/" + fn.name, fn.params, pkgName)
              registerMethodParamModes(cctx, ifaceName + "/" + fn.name, fn.params)
              methodDefRow = methodDefRow + 1
            }
            case IMAssoc(_) -> {}
          }
          mi = mi + 1
        }
      }
      case IOpaque(decl) -> {
        // lowerMOpaque: FieldDef per OMField; .ctor MethodDef; no explicit methods.
        if decl.hasBody {
          val className = pkgName + "." + decl.name
          var fi = 0
          while fi < decl.members.count {
            match decl.members[fi] {
              case OMField(_)     -> { fieldDefRow = fieldDefRow + 1 }
              case OMInvariant(_) -> {}
            }
            fi = fi + 1
          }
          cctx.recordCtorTokens.add(className, 0x06000000 + methodDefRow)
          methodDefRow = methodDefRow + 1
        }
      }
      case IProtected(decl) -> {
        // lowerProtectedMsil emits an MPRecord:
        //   recFields from PMField; recMethods from PMEntry/PMFunc.
        // lowerMRecord then adds: FieldDef per field; .ctor; one MethodDef per method.
        val className = pkgName + "." + decl.name
        var fi = 0
        while fi < decl.members.count {
          match decl.members[fi] {
            case PMField(_) -> { fieldDefRow = fieldDefRow + 1 }
            case _          -> {}
          }
          fi = fi + 1
        }
        cctx.recordCtorTokens.add(className, 0x06000000 + methodDefRow)
        methodDefRow = methodDefRow + 1
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case PMEntry(_) -> { methodDefRow = methodDefRow + 1 }
            case PMFunc(_)  -> { methodDefRow = methodDefRow + 1 }
            case _          -> {}
          }
          mi = mi + 1
        }
      }
      // IDistinctType: lowerMDistinctType synthesises an MRecord with one
      // `value` field + a one-arg `.ctor(inner)`.  Reserve those rows AND
      // register the field token / ctor token / type FQN so member access
      // (`self.value` in derive-synthesised methods) and construction
      // (`Score(42)`) resolve correctly (#1917).
      case IDistinctType(decl) -> {
        val className = pkgName + "." + decl.name
        if not cctx.typeFqnByName.containsKey(decl.name) {
          cctx.typeFqnByName.add(decl.name, className)
        }
        val valueTok = 0x04000000 + fieldDefRow
        if not cctx.fieldTokens.containsKey(className + "/value") {
          cctx.fieldTokens.add(className + "/value", valueTok)
        }
        val innerTy = typeExprToMsilCtx(cctx, decl.underlying, pkgName)
        if not cctx.fieldMsilTypes.containsKey(className + "/value") {
          cctx.fieldMsilTypes.add(className + "/value", innerTy)
        }
        fieldDefRow = fieldDefRow + 1
        if not cctx.recordCtorTokens.containsKey(className) {
          cctx.recordCtorTokens.add(className, 0x06000000 + methodDefRow)
        }
        methodDefRow = methodDefRow + 1
      }
      // IRangeType, IEnum, IImpl: 0 MethodDef rows in non-MPFuncs.
      // IConst, IVal, IFunc: handled below (go to MPFuncs, emitted last).
      case _ -> {}
    }
    i = i + 1
  }

  // Pass 1b: MPFuncs static fields — IConst and non-literal IVal items emit
  // FieldDef rows into the host class (after all type FieldDef rows from Pass 1).
  // Record the token for each non-literal IVal so `EPath` can emit `ldsfld`.
  var pv = 0
  while pv < file.items.count {
    match file.items[pv].kind {
      case IConst(decl) -> {
        // IConst emits a single FieldDef row (literal).
        fieldDefRow = fieldDefRow + 1
      }
      case IVal(decl) -> {
        // Package-scope destructuring (e.g. `val (a, b) = f()`) is not supported
        // by the type checker or parser: only PBinding patterns are accepted at
        // item scope.  The `_` branch is therefore unreachable; it emits a
        // synthetic name to avoid a row-count mismatch if the invariant is ever
        // violated.  Each IVal item allocates exactly one FieldDef row.
        val valName = match decl.pattern.kind {
          case PBinding(n, _) -> n
          case _              -> "__val_" + toString(fieldDefRow)
        }
        val isLit = isLiteralI4ExprMsilWithEnv(decl.init, constEnv)
        if not isLit {
          val fieldTok = 0x04000000 + fieldDefRow
          val valTy = match decl.ty {
            case Some(te) -> typeExprToMsilCtx(cctx, te, pkgName)
            case None     -> MObject
          }
          cctx.staticValTokens.add(valName, fieldTok)
          cctx.staticValMsilTypes.add(valName, valTy)
        }
        fieldDefRow = fieldDefRow + 1
      }
      case _ -> {}
    }
    pv = pv + 1
  }
  // Phase B.0: Reserve MethodDef rows for synthesised SM classes.
  // Each async func that uses SM synthesis (isAsync, no yield, no @externTarget)
  // contributes 3 MethodDef rows emitted by MPRecord *before* MPFuncs:
  //   .ctor (no-arg), MoveNext, SetStateMachine.
  // These rows appear in the MethodDef table before the host-class .cctor and
  // kickoff functions, so we must advance methodDefRow past them here so that
  // funcTok for each kickoff (and main) points to the correct actual row.
  var smClassCountPts = 0
  var smkPts = 0
  while smkPts < file.items.count {
    match file.items[smkPts].kind {
      case IFunc(decl) -> {
        if decl.isAsync
           and not funcBodyContainsYieldMsil(decl)
           and not hasExternTargetMsil(decl.annotations) {
          smClassCountPts = smClassCountPts + 1
        }
      }
      case _ -> {}
    }
    smkPts = smkPts + 1
  }
  methodDefRow = methodDefRow + smClassCountPts * 3
  // Pass 2: MPFuncs — optional .cctor then IFunc items (in source order).
  if hasValCctor {
    methodDefRow = methodDefRow + 1
  }
  var j = 0
  while j < file.items.count {
    match file.items[j].kind {
      case IFunc(decl) -> {
        // FQN-keyed for #1183 Phase 2 — cross-package call sites resolve via
        // `<pkg>.<func>` so multiple packages can co-exist in one cctx without
        // colliding on simple names.  Single-package call sites that use a
        // bare `funcName` rebuild the FQN as `fctx.pkgName + "." + funcName`
        // before lookup (see `lowerBuiltinOrStaticCallMsil`); lambdas use
        // `fctx.pkgName + ".__lambda_<idx>"` for the same reason.
        val fqn = pkgName + "." + decl.name
        // Arity-qualified key (#1536) so same-name overloads don't collide on the bare FQN; bare FQN kept as a first-wins alias.
        val arityKey = fqn + "/" + toString(decl.params.count)
        val funcTok = 0x06000000 + methodDefRow
        if not cctx.funcTokens.containsKey(arityKey) {
          cctx.funcTokens.add(arityKey, funcTok)
        }
        if not cctx.funcTokens.containsKey(fqn) {
          cctx.funcTokens.add(fqn, funcTok)
        }
        // Record the first `main()` we see as the bundle entry point.  Later
        // packages' `main()` (if any) are recorded as regular functions but
        // do not displace the entry token; the F# emitter's host-main wiring
        // follows the same first-wins rule.
        if decl.name == "main" and cctx.mainEntryToken.count == 0 {
          cctx.mainEntryToken.add(funcTok)
        }
        // Generator functions always return List<object> (MObject) regardless of
        // the source-level annotation.  Use the same isGenerator logic as
        // lowerFuncMsil so that call sites in funcRetTypes agree with the actual
        // emitted signature — avoids void-typed locals when callers store the result.
        val isGen = decl.isAsync and funcBodyContainsYieldMsil(decl)
        val isSm  = decl.isAsync and not isGen and not hasExternTargetMsil(decl.annotations)
        val retTy = if isGen {
          MObject
        } else if isSm {
          // SM kickoffs return Task<T> or Task, not the bare T.  Call sites that
          // await the kickoff resolve via funcRetTypes — the EAwait handler then
          // unwraps the Task to T via GetAwaiter+GetResult.
          val bareRetTy = match decl.ret {
            case Some(te) -> {
              val r = typeExprToMsilCtx(cctx, te, pkgName)
              if elementTypeByte(r) == 0 { MVoid } else { r }
            }
            case None -> MVoid
          }
          if bareRetTy == MVoid {
            MClassRef(typeRefCode = tdrTypeRef(cctx.trTask),
                      clrFqn = "System.Threading.Tasks.Task")
          } else {
            val kfRetArgs: List[MsilType] = newList()
            kfRetArgs.add(bareRetTy)
            MGenericInst(typeRefCode = tdrTypeRef(cctx.trTask1),
                         headFqn = "System.Threading.Tasks.Task`1",
                         typeArgs = kfRetArgs)
          }
        } else if startsWith(decl.name, "__lambda_") {
          // For synthetic lambdas: the return type was set during lambda lifting based on
          // whether the body ends with an expression (implicit return) or not.
          // If ret is Some(...), use that; otherwise default to MVoid.
          match decl.ret {
            case Some(te) -> typeExprToMsilCtx(cctx, te, pkgName)
            case None     -> MVoid
          }
        } else {
          match decl.ret {
            case Some(te) -> typeExprToMsilCtx(cctx, te, pkgName)
            case None     -> MVoid
          }
        }
        // Mirror funcTokens' arity-qualified key + bare alias so the call site's lookup picks the matching overload's return type.
        if not cctx.funcRetTypes.containsKey(arityKey) {
          cctx.funcRetTypes.add(arityKey, retTy)
        }
        if not cctx.funcRetTypes.containsKey(fqn) {
          cctx.funcRetTypes.add(fqn, retTy)
        }
        // Record the declared parameter MsilTypes so call sites can thread an
        // argument's expected type into `contextHintTyArgs` (see funcParamTypes).
        val paramTys: List[MsilType] = newList()
        var ppi = 0
        while ppi < decl.params.count {
          paramTys.add(typeExprToMsilCtx(cctx, decl.params[ppi].ty, pkgName))
          ppi = ppi + 1
        }
        if not cctx.funcParamTypes.containsKey(arityKey) {
          cctx.funcParamTypes.add(arityKey, paramTys)
        }
        if not cctx.funcParamTypes.containsKey(fqn) {
          cctx.funcParamTypes.add(fqn, paramTys)
        }
        // Inner parameter types of each function-typed parameter (#1939), so a
        // call site can propagate them into a lambda passed directly as an arg.
        // Keyed "<fqn>#<paramIdx>" (flat List value) for both fqn aliases.
        var pfi = 0
        while pfi < decl.params.count {
          match decl.params[pfi].ty.kind {
            case TFunction(fnParams, _) -> {
              val inner: List[MsilType] = newList()
              var fpj = 0
              while fpj < fnParams.count {
                inner.add(typeExprToMsilCtx(cctx, fnParams[fpj], pkgName))
                fpj = fpj + 1
              }
              val aKey = arityKey + "#" + toString(pfi)
              val fKey = fqn + "#" + toString(pfi)
              if not cctx.funcParamFnInner.containsKey(aKey) { cctx.funcParamFnInner.add(aKey, inner) }
              if not cctx.funcParamFnInner.containsKey(fKey) { cctx.funcParamFnInner.add(fKey, inner) }
            }
            case _ -> {}
          }
          pfi = pfi + 1
        }
        val paramModes: List[ParamMode] = newList()
        var pmi = 0
        while pmi < decl.params.count {
          paramModes.add(decl.params[pmi].mode)
          pmi = pmi + 1
        }
        if not cctx.funcParamModes.containsKey(arityKey) {
          cctx.funcParamModes.add(arityKey, paramModes)
        }
        if not cctx.funcParamModes.containsKey(fqn) {
          cctx.funcParamModes.add(fqn, paramModes)
        }
        methodDefRow = methodDefRow + 1
      }
      case _ -> {}
    }
    j = j + 1
  }

  // Sync the persistent counters so a follow-up `addPackageTokens` call
  // (multi-package compile, #1183) starts where this one left off.  Pad the
  // counter list to length = (methodDefRow - 1) — the highest row this call
  // allocated — by appending zero-valued entries.  The list elements are
  // never read; only `.count` matters.
  while cctx.nextMethodDefRow.count < methodDefRow - 1 {
    cctx.nextMethodDefRow.add(0)
  }
  while cctx.nextFieldDefRow.count < fieldDefRow - 1 {
    cctx.nextFieldDefRow.add(0)
  }
}

// True when an IVal's init expression will produce a single MLdcI4 instruction
// (so no .cctor is needed after the literal-inlining fix).
func isLiteralI4ExprMsil(e: in Expr): Bool {
  val empty: Map[String, Bool] = newMap()
  isLiteralI4ExprMsilWithEnv(e, empty)
}

// Env-aware variant: consult `env` when the expression is a bare EPath whose
// segment matches a previously-seen `val` name.  Lets `val b = a` (with
// `val a = 7`) resolve to literal, so the pre-scan does not allocate a
// phantom `.cctor` (which would shift MethodDef tokens for all later IFuncs).
func isLiteralI4ExprMsilWithEnv(e: in Expr, env: in Map[String, Bool]): Bool {
  match e.kind {
    case ELiteral(lit) -> match lit {
      case LInt(v, suffix, _)  -> match suffix {
        case I64 | U64 -> false
        case _ -> v >= -2147483648i64 and v <= 2147483647i64
      }
      case LBool(_)    -> true
      case LChar(_)    -> true
      case LUnit       -> true  // 0 insns emitted; no .cctor needed
      case _           -> false
    }
    case EParen(inner) -> isLiteralI4ExprMsilWithEnv(inner, env)
    case EPath(path) -> {
      if path.segments.count == 1 and env.containsKey(path.segments[0]) {
        match mapGet(env, path.segments[0]) {
          case Some(b) -> b
          case None    -> false
        }
      } else {
        false
      }
    }
    case _             -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Per-function codegen context.
// ─────────────────────────────────────────────────────────────────────────────

// FuncCtx threads mutable state through expression and statement lowering.
// Parameters and locals share the `slots` map but use different namespaces:
//   • params: slots 0..paramCount-1, accessed via MLdarg(slot)
// ─────────────────────────────────────────────────────────────────────────────
// Phase B.1 async state machine context.
// Installed in FuncCtx.phaseBCtx (singleton) while synthesiseAsyncSmPhaseBMsil
// is lowering the MoveNext body.  The EAwait handler checks this to switch from
// the blocking shim to the real suspend/resume protocol.
// ─────────────────────────────────────────────────────────────────────────────
pub record PhaseBCtx {
  smFqn:             String        // FQN of the enclosing SM sealed class
  resumeLabels:      List[Int]     // pre-allocated label ID per await site (index = state N)
  suspendLeaveLabel: Int           // label to Leave to after AwaitUnsafeOnCompleted
  nextAwaitIndex:    List[Int]     // length = next await index (list-as-counter)
  awaiterFieldNames: List[String]  // "__awN" per state index (parallel to resumeLabels)
  isVoid:            Bool          // true when SM returns void (no result from GetResult)
  retTy:             MsilType      // bare return type (MVoid when isVoid)
  atmbMrRowForAwait: Int           // open MemberRef row for AwaitUnsafeOnCompleted
  // Promoted locals: val-bindings hoisted to SM fields so they survive suspension.
  // Populated on-the-fly as LBLet bindings are encountered during body lowering;
  // `emitPhaseBAwait` reads the current list when emitting each resume label so
  // every local defined before that await point is reloaded on the resume path.
  smFields:             List[MField]      // reference to the SM class field list
  promotedLocalNames:   List[String]      // val name → SM field "__local_<name>"
  promotedLocalSlots:   List[Int]         // local-relative slot index (slot - paramCount)
  promotedLocalTypes:   List[MsilType]    // type of the promoted local (parallel)
}

//   • locals: slots paramCount.., accessed via MLdloc(slot - paramCount)
// `locals` records MsilType entries in order for MFunc.locals.
// `slotTicker` and `labelTicker` are singleton lists whose `.count` is the
// current next-slot / next-label integer.
pub record FuncCtx {
  pkgName:     String
  className:   String
  funcName:    String
  slots:       Map[String, Int]
  types:       Map[String, MsilType]
  locals:      List[MsilType]       // ordered local variable types for MFunc.locals
  slotTicker:  List[Int]            // length = next slot index (params + locals combined)
  labelTicker: List[Int]            // length = next label index
  paramCount:  Int                  // number of parameters (fixed at creation)
  loopBreak:   List[Int]            // stack: top = innermost loop's exit label
  loopCont:    List[Int]            // stack: top = innermost loop's back-edge label
  // Parallel to loopBreak/loopCont: the protected-region (try) nesting depth in
  // effect when each loop was entered.  A `break`/`continue` whose innermost
  // loop was entered at a *shallower* try depth than the current one is jumping
  // out of one or more CLR protected regions and must emit `leave`, not `br`
  // (a `br` across a protected-region boundary is unverifiable IL).  #1481.
  loopTryDepth:  List[Int]
  // Try/catch nesting depth counter (values unused; only `.count` matters).  Pushed around each `try` body and each `catch` handler in lowerTryCatchMsil.
  tryRegionStack: List[Int]
  // Return-through-protected-region support.  A `return` lowered while inside
  // one or more open try/catch/finally regions cannot emit `ret` directly (a
  // `ret` out of a CLR protected region is invalid IL); it stores the value into
  // `retvalSlot` and `leave`s to `epilogueLabel`, a single function epilogue
  // that loads the value (if any) and rets.  `epilogueLabel` is allocated by
  // lowerFuncMsil / lowerImplMethodMsil; `retvalSlot` is lazily allocated on the
  // first value-returning escape; `epilogueUsed` is non-empty once any return
  // routed through the epilogue, so the epilogue block is only emitted when
  // needed.  #1477.
  var epilogueLabel: Int
  var retvalSlot:    Int
  epilogueUsed:      List[Int]
  // EYield support: slot of the List<object> yield collector when inside a generator.
  // Empty when the function is not a generator; singleton when it is.
  yieldSlots:    List[Int]
  // The function's declared return MsilType. Used by nullary union-case
  // construction (e.g. `return None`) to infer the concrete type argument T
  // when no arg is present (e.g. None in parseDigits(): Option[Long] → T=Long).
  declaredRetTy: MsilType
  // Transient type-arg hint set by local variable declarations with a generic
  // type annotation (e.g. `var x: Option[Int] = None`).  Populated just before
  // lowering the init expression and cleared immediately after, so nullary
  // generic case construction (None, Err, …) can produce the correct closed
  // generic type (Option_None<Int>) rather than Option_None<Object>.
  contextHintTyArgs: List[MsilType]
  // Slots of `out`/`inout` parameters, mapped to the *pointee* MsilType (the
  // declared value type, not the `T&`).  A slot present here is a managed
  // pointer: reads deref it (`ldarg; ldind`), writes store through it
  // (`ldarg; <value>; stind`), and the slot is never touched by `emitStoreSlot`
  // (the assignment path handles byref targets before reaching it).  See #1761.
  byrefSlotTypes: Map[Int, MsilType]
  // Declared return MsilType of function-typed locals/params (a `(A,...) -> R`
  // value), keyed by name.  `MVoid` means a void-returning delegate (the result
  // of `Func::Invoke` is discarded); a non-void entry materialises the boxed
  // result to `R`.  Consulted when a function-typed value is invoked (`f()`) so
  // the call yields the declared type.  Absent ⇒ default to `object`.  #1877.
  funcValRetTypes: Map[String, MsilType]
  // Logical type of a lifted lambda's parameter slot.  Lambda params arrive
  // boxed (`object`) in the `Func<object,…>` delegate signature; this records
  // the type each is logically used as so reads `unbox.any`/`castclass` it on
  // load.  Populated for `__lambda_*` from the param's annotation (or, later,
  // the propagated HOF parameter type).  #1939.
  boxedParamTypes: Map[Int, MsilType]
  // Capturing-closure resolution (#1479) inside a lifted `__lambda_*` body: a
  // captured enclosing variable's name maps to its index in the `object[] __caps`
  // parameter (slot 0) and its logical MsilType, so an `EPath` read emits
  // `ldarg.0; ldc.i4 i; ldelem.ref; <unbox/cast>`.  Empty for non-capturing
  // functions.
  captureNameToIndex: Map[String, Int]
  captureNameToType:  Map[String, MsilType]
  // Names of `var` (reassignable) locals declared in this function.  A closure
  // that captures one of these cannot use by-value capture (mutations would not
  // be shared) — such a `var` is instead hoisted to a heap cell (see below).
  mutableLocals:      List[String]
  // By-reference closure capture (#1479 v2).  `hoistedVarNames` is the pre-pass
  // set of names referenced inside any lambda in this function; a `var` local in
  // this set is hoisted to a one-element `List[object]` heap **cell** so the
  // closure and enclosing scope share one mutable location.  When such a `var`
  // is declared, its cell slot + logical element type are recorded in
  // `hoistedCellSlot`/`hoistedCellType`; reads/writes of the name (here and in
  // the closure) route through `get_Item(0)`/`set_Item(0)`.
  hoistedVarNames:    List[String]
  hoistedCellSlot:    Map[String, Int]
  hoistedCellType:    Map[String, MsilType]
  // Inside a lifted `__lambda_*`: capture names whose `__caps[i]` slot holds a
  // by-reference **cell** (a hoisted `var`) rather than a by-value boxed copy.
  // Reads emit `__caps[i]; get_Item(0); unbox`; writes emit `set_Item(0)`.
  captureCellNames:   List[String]
  // Phase B.1 async SM context.  Empty except when synthesiseAsyncSmPhaseBMsil
  // is lowering the MoveNext body (singleton then).  The EAwait handler checks
  // this to switch from the blocking shim to the real suspend/resume protocol.
  phaseBCtx: List[PhaseBCtx]
}

// Allocate a fresh label ID (0, 1, 2, …) for use with MLabel/MBr* instructions.
pub func freshLabelMsil(fctx: in FuncCtx): Int {
  val n = fctx.labelTicker.count
  fctx.labelTicker.add(0)
  n
}

// Returns the ELEMENT_TYPE byte a slot would get in buildLocalVarSig.
// Two types are LocalVarSig-compatible iff this function returns the same byte.
// MClass and MGenericInst both encode as 0x1C (object), so they are always
// compatible — only distinct primitive types conflict.
func localVarSlotByte(t: in MsilType): Int {
  match t {
    case MClass(_)             -> 0x1C
    case MGenericInst(_, _, _) -> 0x1C
    case other                 -> elementTypeByte(other)
  }
}

// Assign the next combined slot to `name` with MSIL type `ty`.
// Locals (slot >= paramCount) are appended to `fctx.locals`.
// Returns the combined slot index (used as the key in the slots map).
//
// If `name` is already registered with the same LocalVarSig-byte type, the
// existing slot is reused (MSIL locals are function-wide; disjoint branches
// sharing the same binding name safely reuse the same slot).  When the same
// name reappears with a different type byte (e.g. the same binding name in
// two match arms typed `MLong` and `MDouble`), a fresh slot is allocated and
// the name mapping is retargeted so subsequent EPath lookups in this arm see
// the correctly-typed local.
//
// CALLER CONSTRAINT: the retargeting path is only safe when no live code
// holds a cached reference to the old slot.  Today only `lowerPatternBindMsil`
// retargets (its `scrutSlot` snapshot is captured before bind), and cross-arm
// uses re-resolve via `lookupSlot` per arm.  A pattern that cross-references a
// pre-retargeting slot from a common after-block would emit a load from the
// wrong location; add a diagnostic at the cross-reference site if that pattern
// is ever introduced.
pub func allocSlotMsil(fctx: in FuncCtx, name: in String, ty: in MsilType): Int {
  match mapGet(fctx.slots, name) {
    case Some(existing) -> {
      val existingTy = match mapGet(fctx.types, name) {
        case Some(t) -> t
        case None    -> ty
      }
      if localVarSlotByte(existingTy) == localVarSlotByte(ty) {
        existing
      } else {
        val slot = fctx.slotTicker.count
        fctx.slots.remove(name)
        fctx.slots.add(name, slot)
        fctx.types.remove(name)
        fctx.types.add(name, ty)
        fctx.slotTicker.add(0)
        if slot >= fctx.paramCount {
          fctx.locals.add(ty)
        }
        slot
      }
    }
    case None -> {
      val slot = fctx.slotTicker.count
      fctx.slots.add(name, slot)
      fctx.types.add(name, ty)
      fctx.slotTicker.add(0)
      // Only add to locals if this is a local (not a param).
      if slot >= fctx.paramCount {
        fctx.locals.add(ty)
      }
      slot
    }
  }
}

// Finish a hoisted-`var` heap cell (#1479 v2).  Precondition: the stack holds
// `(cell, cell, rawValue)` — i.e. a freshly `newobj`'d `List[object]` duplicated,
// with the initial value on top.  Boxes the value, `Add`s it as element 0,
// allocates an object-typed slot for the cell, stores it, and records the cell
// slot + logical element type so reads/writes of the name route through it.
pub func finishHoistedCellMsil(cctx: in CodegenCtx, fctx: in FuncCtx,
                               insns: in List[MInsn], name: in String,
                               elemTy: in MsilType): Unit {
  boxIfNeededMsil(cctx, insns, elemTy)
  insns.add(MCallvirt(methodToken = cctx.tokListObjAdd))
  val cellSlot = allocSlotMsil(fctx, name, MObject)
  emitStoreSlot(insns, cellSlot, fctx.paramCount)
  fctx.mutableLocals.add(name)
  fctx.hoistedCellSlot.add(name, cellSlot)
  fctx.hoistedCellType.add(name, elemTy)
}

// True for parameter modes that pass a managed pointer (`T&`): `out` and `inout`.
// `in` (and the default) pass by value.  See #1761.
pub func isByrefMode(m: in ParamMode): Bool {
  match m {
    case PMOut   -> true
    case PMInout -> true
    case PMIn    -> false
  }
}

// Wrap each `out`/`inout` parameter's MsilType in `MByRef` so a method
// signature encodes a managed pointer (`T&`).  Result is index-aligned with
// `baseTypes`; `in` (and default) parameters pass through unchanged.  #1761.
func byrefWrapSigTypes(params: in List[Param], baseTypes: in List[MsilType]): List[MsilType] {
  val acc: List[MsilType] = newList()
  var i = 0
  while i < baseTypes.count {
    if i < params.count and isByrefMode(params[i].mode) {
      acc.add(MByRef(inner = baseTypes[i]))
    } else {
      acc.add(baseTypes[i])
    }
    i = i + 1
  }
  acc
}

// The arithmetic MInsn for a compound assignment op (`+=` → MAdd, …), or None
// for plain `=`.  Used by the byref-store path so `*ptr OP= rhs` lowers
// uniformly across ops.
func assignOpArithInsnMsil(op: in AssignOp): Option[MInsn] {
  match op {
    case AssEq      -> None
    case AssPlus    -> Some(value = MAdd)
    case AssMinus   -> Some(value = MSub)
    case AssStar    -> Some(value = MMul)
    case AssSlash   -> Some(value = MDiv)
    case AssPercent -> Some(value = MRem)
  }
}

// Convert a boxed `object` (top of stack — e.g. the result of a List/Dictionary
// `get_Item`) into a value of `elemTy` so a compound-assignment operator can be
// applied at the element's static type.  A String element calls `ToString()` (a
// string returns itself) to retype the stack slot from object to string without
// needing a dedicated String TypeSpec for `castclass`; a value-type element
// unboxes; an already-`object` element is left untouched.
func materializeBoxedElemMsil(cctx: in CodegenCtx, insns: in List[MInsn], elemTy: in MsilType): Unit {
  match elemTy {
    case MString -> insns.add(MCallvirt(methodToken = cctx.tokObjToString))
    case MObject -> {}
    case _       -> {
      if isValueType(elemTy) {
        // 0x01000000 = ECMA-335 TypeRef table token prefix; boxTypeRef returns a bare RID.
        insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, elemTy)))
      }
    }
  }
}

// Coerce the trailing value already on the stack (typed `valTy`) to a function's
// declared return type `retTy` before `ret`.  Only acts when the declared return
// is a reference type (`object`) but the produced value is a value type (box it)
// or absent (`MVoid` → push `null`).  This is what makes a lifted lambda whose
// body yields an `Int`/`Bool`/etc. return a valid boxed `object` to its `Func`
// delegate, and a void-bodied lambda return `null` (#1877).  Concrete value-type
// or reference returns are left untouched (the body already produced a matching
// value).
func coerceTrailingToRetMsil(cctx: in CodegenCtx, insns: in List[MInsn], valTy: in MsilType, retTy: in MsilType): Unit {
  match retTy {
    case MObject -> match valTy {
      case MVoid   -> insns.add(MLdNull)
      case MObject -> {}
      case MString -> {}
      case _       -> if isValueType(valTy) { boxIfNeededMsil(cctx, insns, valTy) }
    }
    case _ -> {}
  }
}

// Apply a compound-assignment operator to a current value already on the stack
// (typed `curTy`), consuming the right-hand `value` expression and leaving the
// combined result on the stack.  `+=` on a String performs `String.Concat`
// (coercing a non-string rhs via `ToString`); every other op emits the matching
// arithmetic instruction.  `AssEq` is handled by callers and never reaches here.
func emitCompoundCombineMsil(
  cctx:  in CodegenCtx,
  fctx:  in FuncCtx,
  insns: in List[MInsn],
  op:    in AssignOp,
  curTy: in MsilType,
  value: in Expr
): Unit {
  val isStringConcat = match op {
    case AssPlus -> match curTy { case MString -> true case _ -> false }
    case _       -> false
  }
  if isStringConcat {
    val rTy = lowerExprMsil(cctx, fctx, insns, value)
    match rTy {
      case MString -> {}
      case _ -> {
        if isValueType(rTy) { boxIfNeededMsil(cctx, insns, rTy) }
        insns.add(MCallvirt(methodToken = cctx.tokObjToString))
      }
    }
    insns.add(MCall(methodToken = cctx.tokConcat2))
  } else {
    lowerExprMsil(cctx, fctx, insns, value)
    match assignOpArithInsnMsil(op) {
      case Some(arith) -> insns.add(arith)
      case None        -> panic("Msil.Codegen: unhandled compound-assignment op in emitCompoundCombineMsil")
    }
  }
}

// Like `emitCompoundCombineMsil`, but the right-hand operand has already been
// evaluated into a local slot (`rSlot`, typed `rTy`).  Used by the indexed
// compound-assignment path, which evaluates the rhs up-front to recover the
// element's arithmetic type (List/Map elements are stored boxed and the
// receiver erases primitive element types to `object`).  The current value is
// already on the stack, typed `rTy`.
func emitCompoundCombineSlotMsil(
  cctx:  in CodegenCtx,
  fctx:  in FuncCtx,
  insns: in List[MInsn],
  op:    in AssignOp,
  rTy:   in MsilType,
  rSlot: in Int
): Unit {
  val isStringConcat = match op {
    case AssPlus -> match rTy { case MString -> true case _ -> false }
    case _       -> false
  }
  emitLoadSlot(insns, rSlot, fctx.paramCount)
  if isStringConcat {
    insns.add(MCall(methodToken = cctx.tokConcat2))
  } else {
    match assignOpArithInsnMsil(op) {
      case Some(arith) -> insns.add(arith)
      case None        -> panic("Msil.Codegen: unhandled compound-assignment op in emitCompoundCombineSlotMsil")
    }
  }
}

// The declared parameter modes, index-aligned with `params`.
func paramModesOf(params: in List[Param]): List[ParamMode] {
  val acc: List[ParamMode] = newList()
  var i = 0
  while i < params.count {
    acc.add(params[i].mode)
    i = i + 1
  }
  acc
}

// Load a variable that may be an `out`/`inout` parameter.  For a byref slot the
// slot holds a managed pointer, so we load the pointer and dereference it; for
// an ordinary param/local this is just `emitLoadSlot`.  Reads of `out` params
// are rejected by the mode checker (write-before-read), so in practice only
// `inout` reads reach the deref path.
func emitLoadVarMsil(fctx: in FuncCtx, insns: in List[MInsn], slot: in Int): Unit {
  match mapGet(fctx.byrefSlotTypes, slot) {
    case Some(elemTy) -> {
      insns.add(MLdarg(slot = slot))
      insns.add(MLdind(ty = elemTy))
    }
    case None -> emitLoadSlot(insns, slot, fctx.paramCount)
  }
}

// Push the managed pointer for an `out`/`inout` argument.  The argument must be
// an assignable variable (the mode checker guarantees this, V0001–V0006): a
// local → `ldloca`; a by-value parameter → `ldarga`; or an `out`/`inout`
// parameter being forwarded, whose slot already holds the pointer → `ldarg`.
// See #1761.
func emitByrefArgMsil(cctx: in CodegenCtx, fctx: in FuncCtx,
                      insns: in List[MInsn], argExpr: in Expr): Unit {
  match argExpr.kind {
    case EPath(path) -> {
      val name = lastSegmentMsil(path)
      match mapGet(fctx.slots, name) {
        case Some(slot) -> {
          match mapGet(fctx.byrefSlotTypes, slot) {
            case Some(_) -> insns.add(MLdarg(slot = slot))
            case None    -> {
              if slot < fctx.paramCount {
                insns.add(MLdarga(slot = slot))
              } else {
                insns.add(MLdloca(slot = slot - fctx.paramCount))
              }
            }
          }
        }
        case None -> panic("Msil.Codegen: out/inout argument '" + name
          + "' is not a local or parameter (mode checker should have rejected this)")
      }
    }
    case _ -> panic("Msil.Codegen: out/inout argument must be an assignable variable")
  }
}

// Emit the appropriate load instruction for a slot, distinguishing params
// (MLdarg) from locals (MLdloc with 0-based local index).
func emitLoadSlot(insns: in List[MInsn], slot: in Int, paramCount: in Int): Unit {
  if slot < paramCount {
    insns.add(MLdarg(slot = slot))
  } else {
    insns.add(MLdloc(slot = slot - paramCount))
  }
}

// Emit the appropriate store instruction for a slot.
func emitStoreSlot(insns: in List[MInsn], slot: in Int, paramCount: in Int): Unit {
  if slot < paramCount {
    insns.add(MStarg(slot = slot))
  } else {
    insns.add(MStloc(slot = slot - paramCount))
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Type mapping.
// ─────────────────────────────────────────────────────────────────────────────

// Return the last segment of a ModulePath.
func lastSegmentMsil(path: in ModulePath): String {
  val n = path.segments.count
  if n == 0 {
    return ""
  }
  path.segments[n - 1]
}

// Join path segments with a separator.
func joinSegsMsil(segs: in List[String], sep: in String): String {
  var result = ""
  var i = 0
  while i < segs.count {
    if i > 0 {
      result = result + sep
    }
    result = result + segs[i]
    i = i + 1
  }
  result
}

// Cross-package type-name resolution helper (#1183 codegen port).
// Given a simple type name like "Maybe" referenced in `pkgName`, find
// the FQN to use for the resulting `MClass`.
//
// Resolution: consult `typeFqnByName` (populated by `addPackageTokens`
// with first-pkg-wins semantics — local registration wins over later
// shadows from imported packages).  When a hit exists, it IS the
// resolution — either it points at this pkg's own declaration or at
// an imported pkg's.  Type-checking upstream is the line of defence
// that rejects un-imported references, so we accept any hit without
// re-validating against `pkgImports[pkgName]`.  When no entry exists,
// fall back to the local-pkg form so codegen doesn't regress on
// undeclared types (typecheck diagnostic surfaces upstream); the
// originally-documented pkgImports walk was redundant given the
// upstream guarantee and is no longer described here (#1221).
func resolveTypeFqn(cctx: in CodegenCtx, pkgName: in String, seg: in String): String {
  // `typeFqnByName` is keyed by simple type name with first-pkg-wins
  // semantics (per `addPackageTokens`).  When a hit exists, it IS the
  // resolution — either it points at this pkg's own declaration
  // (`pkgName + "." + seg`) or at an imported pkg's.  Type-checking
  // upstream is the line of defence that rejects un-imported references,
  // so we accept any hit here without re-validating it against
  // `pkgImports`.  When `typeFqnByName` has no entry the type was never
  // declared in the bundle, so fall back to the current-pkg form (the
  // existing pre-#1183 behaviour).
  match mapGet(cctx.typeFqnByName, seg) {
    case Some(fqn) -> fqn
    case None      -> pkgName + "." + seg
  }
}

// Map a `slice[T]` element type to its MSIL element type.  `Byte` lowers to
// `MByte` (U1) rather than the scalar `MInt` so a `slice[Byte]` serialises as
// `byte[]` (U1[]), matching the F#-compiled stdlib (`Std.Encoding.tryDecodeBase64
// -> Option[byte[]]`).  Other element types use the normal mapping.
//
// ASSUMPTION: the bare name `Byte` is reserved for the stdlib primitive (no
// user package may shadow it).  A user-defined `MyPkg.Byte` would also match
// the terminal-segment check and be mis-encoded as U1 — preventing that is
// the type checker's job via the reserved-name table.
func sliceElemMsilCtx(cctx: in CodegenCtx, elem: in TypeExpr, pkgName: in String): MsilType {
  match elem.kind {
    case TRef(path) -> if lastSegmentMsil(path) == "Byte" { MByte }
                       else { typeExprToMsilCtx(cctx, elem, pkgName) }
    case _          -> typeExprToMsilCtx(cctx, elem, pkgName)
  }
}

func sliceElemMsil(elem: in TypeExpr, pkgName: in String): MsilType {
  match elem.kind {
    case TRef(path) -> if lastSegmentMsil(path) == "Byte" { MByte }
                       else { typeExprToMsil(elem, pkgName) }
    case _          -> typeExprToMsil(elem, pkgName)
  }
}

// Map a Lyric TypeExpr to an MsilType, resolving cross-package
// Resolve a simple type name to an `MValueTypeRef` when it is an extern type
// mapping to a known BCL value type (struct or enum).  Returns `None` for
// reference-typed externs and non-extern names (the caller then uses MClass).
// Allocates / reuses a TypeRef for the CLR struct so the VALUETYPE signature
// entry points at the right type identity (#1602).
func externValueTypeMsil(cctx: in CodegenCtx, seg: in String): Option[MsilType] {
  match mapGet(cctx.externTypeNames, seg) {
    case None -> None
    case Some(clrFqn) -> {
      ensureMetadataIndex(cctx)
      val isVtype = Mdr.isValueTypeFqn(cctx.metadataVtypeSet, clrFqn)
      // Fall back to the hardcoded list when the ref pack isn't available
      // so value-type externs still encode correctly in SDK-less environments.
      if not isVtype and not clrIsValueType(clrFqn) { return None }
      val sp     = splitTypeFqn(clrFqn)
      val asm    = assemblyForTypeMsil(cctx, clrFqn)
      val refRow = internFfiTypeRef(cctx, asm, sp.ns, sp.name)
      Some(value = MValueTypeRef(typeRefCode = tdrTypeRef(refRow), clrFqn = clrFqn))
    }
  }
}

// type references via the codegen context (#1183 codegen port).
pub func typeExprToMsilCtx(cctx: in CodegenCtx, te: in TypeExpr, pkgName: in String): MsilType {
  match te.kind {
    case TUnit    -> MVoid
    case TNever   -> MVoid
    case TRef(path) -> {
      val seg = lastSegmentMsil(path)
      if seg == "Int" {
        MInt
      } else if seg == "Long" {
        MLong
      } else if seg == "Double" {
        MDouble
      } else if seg == "Float" {
        MDouble
      } else if seg == "Bool" {
        MBool
      } else if seg == "String" {
        MString
      } else if seg == "Char" {
        MChar
      } else if seg == "Byte" {
        MInt
      } else if seg == "Unit" {
        MVoid
      } else if seg == "Object" {
        MObject
      } else {
        // An extern type that maps to a BCL value type (e.g.
        // `extern type Uuid = "System.Guid"`) must carry its valuetype
        // identity so cross-package signatures encode VALUETYPE + TypeRef
        // rather than degrading to `object` (#1602).  Reference-typed
        // externs and ordinary user types fall through to MClass.
        match externValueTypeMsil(cctx, seg) {
          case Some(vt) -> vt
          case None     -> MClass(className = resolveTypeFqn(cctx, pkgName, seg))
        }
      }
    }
    case TGenericApp(head, args) -> {
      val headSeg = lastSegmentMsil(head)
      // Special case: List[T] — carry the element type so EIndex can
      // narrow each element to T.  For a user-defined `MClass` element this
      // enables castclass + ldfld on list-element field access (#1442); for a
      // *value-type* element (`Int`/`Long`/`Double`/`Bool`/`Char`) it lets
      // EIndex `unbox.any` the boxed `List<object>` slot back to the value so
      // a subsequent numeric op / comparison (`xs[i] <= 0`) sees the real
      // value rather than the object reference (#1779).  String / generic /
      // untyped elements stay plain `MObject` (their string/object operations
      // already treat the slot as a reference).
      if headSeg == "List" and args.count == 1 {
        match args[0] {
          case TAType(elemTe) -> {
            val elemTy = typeExprToMsilCtx(cctx, elemTe, pkgName)
            match elemTy {
              case MClass(_)             -> MListOf(elemTy = elemTy)
              // A generic-instance element (e.g. `Option[String]`, `Result[E, T]`)
              // lowers to `List<object>` at the IL level but is tracked as
              // `MListOf(MGenericInst(...))` so `.add` lowering can propagate
              // the element's concrete type arguments as a construction hint
              // (a bare `xs.add(None)` builds `Option_None<String>` instead of
              // `Option_None<Object>`, #1964).
              case MGenericInst(_, _, _) -> MListOf(elemTy = elemTy)
              case _         ->
                if isValueType(elemTy) { MListOf(elemTy = elemTy) }
                else                   { MObject }
            }
          }
          case TAValue(_) -> MObject
        }
      } else if headSeg == "Map" and args.count == 2 {
        // Map[K, V] — runtime representation is Dictionary<object,object>.
        // Track as MMapOf so `.count` dispatches to Dictionary.get_Count and so
        // the read path / `mapGet` know the value type.  Like List[T] (#1779),
        // only a *value-type* V is tracked (so the boxed `get_Item` result is
        // unboxed back to it); reference V stays `object` (its slot is genuinely
        // a reference).  The key is always boxed for `Dictionary<object,_>`, so
        // K is not tracked.
        val mapValTy = match args[1] {
          case TAType(vte) -> {
            val vt = typeExprToMsilCtx(cctx, vte, pkgName)
            if isValueType(vt) { vt } else { MObject }
          }
          case TAValue(_) -> MObject
        }
        MMapOf(keyTy = MObject, valTy = mapValTy)
      } else if headSeg == "Map" {
        MMapOf(keyTy = MObject, valTy = MObject)
      } else {
        // Silent `MObject` fallback for unresolved/unregistered generic heads.
        // Audit assumption: in-bundle generic types are always reached after
        // their `addPackageTokens` registration (single-package compile order),
        // and cross-package generics arrive via `registerStdlibArtifactTokens`
        // / `registerRestoredArtifactTokens` before user code references them.
        // A registration-ordering shift would surface here as a silent miscompile;
        // a diagnostic-grade rejection is a tracked follow-up under epic #1622.
        val headFqn = resolveTypeFqn(cctx, pkgName, headSeg)
        val dotIdx  = headFqn.lastIndexOf(".")
        if dotIdx < 0 {
          MObject
        } else {
          val headPkg    = headFqn.substring(0, dotIdx)
          val typeRefKey = headPkg + "/" + headFqn
          match mapGet(cctx.ffiTypeRefs, typeRefKey) {
            case None -> MObject
            case Some(row) -> {
              val codedIdx: Int = tdrTypeRef(row)
              val resolvedArgs: List[MsilType] = newList()
              var ai = 0
              while ai < args.count {
                match args[ai] {
                  case TAType(te2) ->
                    resolvedArgs.add(typeExprToMsilCtx(cctx, te2, pkgName))
                  case TAValue(_)  -> resolvedArgs.add(MObject)
                }
                ai = ai + 1
              }
              MGenericInst(typeRefCode = codedIdx, headFqn = headFqn, typeArgs = resolvedArgs)
            }
          }
        }
      }
    }
    case TSlice(elem)       -> MArray(elemTy = sliceElemMsilCtx(cctx, elem, pkgName))
    case TNullable(_)       -> MObject
    case TTuple(_)          -> MObject
    case TFunction(_, _)    -> MObject
    case TArray(_, _)       -> MObject
    case TRefined(_, _)     -> MInt
    case TParen(inner)      -> typeExprToMsilCtx(cctx, inner, pkgName)
    case TSelf              -> MObject
    case TError             -> MObject
  }
}

// Legacy entry point (kept for callers that don't yet thread `cctx`).
// Identical to `typeExprToMsilCtx` except `TRef` resolution always uses
// `pkgName + "." + seg` for non-primitives.  Migrate call sites to the
// ctx-aware variant when cross-package type references matter.
pub func typeExprToMsil(te: in TypeExpr, pkgName: in String): MsilType {
  match te.kind {
    case TUnit    -> MVoid
    case TNever   -> MVoid
    case TRef(path) -> {
      val seg = lastSegmentMsil(path)
      if seg == "Int" {
        MInt
      } else if seg == "Long" {
        MLong
      } else if seg == "Double" {
        MDouble
      } else if seg == "Float" {
        MDouble
      } else if seg == "Bool" {
        MBool
      } else if seg == "String" {
        MString
      } else if seg == "Char" {
        MChar
      } else if seg == "Byte" {
        MInt
      } else if seg == "Unit" {
        MVoid
      } else if seg == "Object" {
        MObject
      } else {
        MClass(className = pkgName + "." + seg)
      }
    }
    case TSlice(elem)       -> MArray(elemTy = sliceElemMsil(elem, pkgName))
    case TGenericApp(_, _)  -> MObject
    case TNullable(_)       -> MObject
    case TTuple(_)          -> MObject
    case TFunction(_, _)    -> MObject
    case TArray(_, _)       -> MObject
    case TRefined(_, _)     -> MInt
    case TParen(inner)      -> typeExprToMsil(inner, pkgName)
    case TSelf              -> MObject
    case TError             -> MObject
  }
}

// Return true if an MsilType is a value type that must be boxed before
// calling virtual/interface methods.
func isValueType(ty: in MsilType): Bool {
  match ty {
    case MInt     -> true
    case MLong    -> true
    case MDouble  -> true
    case MBool    -> true
    case MChar    -> true
    case _        -> false
  }
}

// Numeric / character primitives that the conversion-method intrinsics
// (`.toInt()`/`.toLong()`/`.toByte()`/`.toChar()`/`.toDouble()`, #1901) accept
// as a receiver.  `Bool` is deliberately excluded — it is not a numeric type.
func isNumericMsil(ty: in MsilType): Bool {
  match ty {
    case MInt    -> true
    case MLong   -> true
    case MDouble -> true
    case MChar   -> true
    case MByte   -> true
    case _       -> false
  }
}

// Cross-package call resolution helper (#1183 Phase 2).  Walks `imports`
// — the dotted-name list of packages imported by the calling site's
// package — and returns the first `<imp>.<funcName>` key that exists in
// `cctx.funcTokens`.  Returns "" when no import shadows `funcName`.
//
// Defined as a top-level helper rather than inline so the `match` over
// `mapGet` in the call site stays readable.
func findImportedFqn(cctx: in CodegenCtx, imports: in List[String],
                     funcName: in String): String {
  var i = 0
  while i < imports.count {
    val candidate = imports[i] + "." + funcName
    if cctx.funcTokens.containsKey(candidate) {
      return candidate
    }
    i = i + 1
  }
  ""
}

// Return the TypeRef row for boxing the given value type.
func boxTypeRef(cctx: in CodegenCtx, ty: in MsilType): Int {
  match ty {
    case MInt    -> cctx.trInt32
    case MLong   -> cctx.trInt64
    case MDouble -> cctx.trDouble
    case MBool   -> cctx.trBoolean
    case MChar   -> cctx.trChar
    case _       -> cctx.lctx.trObject
  }
}

// Box a value type on the stack.  Does nothing for reference types.
func boxIfNeededMsil(cctx: in CodegenCtx, insns: in List[MInsn], ty: in MsilType): Unit {
  if isValueType(ty) {
    insns.add(MBox(typeToken = 0x01000000 + boxTypeRef(cctx, ty)))
  }
}

// Convert an `object` on the stack to `ty`: `unbox.any` for value types
// (`Int`, `Bool`, …), `castclass` for reference types (string / user class /
// closed generic), no-op for `object` itself.  Used when feeding a
// `Dictionary.get_Item` result (typed `object`) into a concrete generic case
// constructor that expects the instantiated payload type — e.g. `mapGet` on a
// `Map[String, Int]` must `unbox.any int32` before the `Option_Some<int>` ctor.
func castObjectToMsil(cctx: in CodegenCtx, insns: in List[MInsn], ty: in MsilType): Unit {
  if isValueType(ty) {
    insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, ty)))
  } else {
    match ty {
      case MString                       -> insns.add(MCastclassByName(className = "System.String"))
      case MClass(c)                     -> insns.add(MCastclassByName(className = c))
      case MGenericInst(_, headFqn, tas) -> insns.add(MCastclassGeneric(className = headFqn, typeArgs = tas))
      case _                             -> {}
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Expression lowering.
// ─────────────────────────────────────────────────────────────────────────────

// Lower a single expression.  Pushes exactly one value onto the operand stack
// (or nothing for MVoid).  Returns the MsilType of the pushed value.
pub func lowerExprMsil(cctx: in CodegenCtx, fctx: in FuncCtx,
                       insns: in List[MInsn], expr: in Expr): MsilType {
  match expr.kind {

    // ── Literals ─────────────────────────────────────────────────────────────
    case ELiteral(lit) -> {
      match lit {
        case LInt(v, suffix, _) -> {
          match suffix {
            case I64 | U64 -> {
              insns.add(MLdcI8(v = v))
              MLong
            }
            case _ -> {
              if v >= -2147483648i64 and v <= 2147483647i64 {
                insns.add(MLdcI4(v = longToInt(v)))
                MInt
              } else {
                insns.add(MLdcI8(v = v))
                MLong
              }
            }
          }
        }
        case LFloat(v, _, _) -> {
          insns.add(MLdcR8(v = v))
          MDouble
        }
        case LString(s) -> {
          val token = ctxInternUs(cctx.lctx, s)
          insns.add(MLdStr(token = token))
          MString
        }
        case LTripleString(s) -> {
          val token = ctxInternUs(cctx.lctx, s)
          insns.add(MLdStr(token = token))
          MString
        }
        case LRawString(s) -> {
          val token = ctxInternUs(cctx.lctx, s)
          insns.add(MLdStr(token = token))
          MString
        }
        case LBool(value) -> {
          if value {
            insns.add(MLdcI4(v = 1))
          } else {
            insns.add(MLdcI4(v = 0))
          }
          MBool
        }
        case LUnit -> {
          // `()` as a *value* (e.g. the payload of `Ok(())` / `Err(())`, or a
          // `Result[Unit, E]` Ok arm) is represented as `null`/object — `Unit`
          // has no distinct runtime value but a payload slot still needs one.
          // Pushing nothing here left a stack imbalance at the enclosing
          // `newobj` (invalid program).  Statement-context `()` results are
          // popped like any other value by the block/statement lowering.
          insns.add(MLdNull)
          MObject
        }
        case LChar(cp) -> {
          insns.add(MLdcI4(v = cp))
          MChar
        }
      }
    }

    // ── Parenthesised expression ──────────────────────────────────────────────
    case EParen(inner) -> {
      lowerExprMsil(cctx, fctx, insns, inner)
    }

    // ── Path (variable or function reference) ─────────────────────────────────
    case EPath(path) -> {
      val name = lastSegmentMsil(path)
      // A `var` hoisted to a heap cell (#1479 v2): read element 0 of the cell
      // and unbox/cast.  Checked before the plain-slot path (the slot holds the
      // cell reference, not the value).
      match mapGet(fctx.hoistedCellSlot, name) {
        case Some(cellSlot) -> {
          val elemTy = match mapGet(fctx.hoistedCellType, name) { case Some(t) -> t case None -> MObject }
          emitLoadVarMsil(fctx, insns, cellSlot)
          insns.add(MLdcI4(v = 0))
          insns.add(MCallvirt(methodToken = cctx.tokListObjGetItem))
          castObjectToMsil(cctx, insns, elemTy)
          return elemTy
        }
        case None -> {}
      }
      match mapGet(fctx.slots, name) {
        case Some(slot) -> {
          val ty =
            match mapGet(fctx.types, name) {
              case Some(t) -> t
              case None    -> MObject
            }
          emitLoadVarMsil(fctx, insns, slot)
          // A lifted lambda's parameter is stored boxed (`object`); unbox/cast it
          // to its logical type on load (#1939).
          match mapGet(fctx.boxedParamTypes, slot) {
            case Some(logicalTy) -> { castObjectToMsil(cctx, insns, logicalTy); logicalTy }
            case None            -> ty
          }
        }
        case None -> {
          // Captured enclosing variable inside a lifted closure body (#1479):
          // read it from `object[] __caps` (slot 0) and unbox/cast to its type.
          // A by-reference capture (`captureCellNames`) holds a `List[object]`
          // cell in that slot — read element 0 of the cell instead of the slot.
          match mapGet(fctx.captureNameToIndex, name) {
            case Some(capIdx) -> {
              emitLoadVarMsil(fctx, insns, 0)
              insns.add(MLdcI4(v = capIdx))
              insns.add(MLdelemRef)
              val capTy = match mapGet(fctx.captureNameToType, name) { case Some(t) -> t case None -> MObject }
              if nameListContains(fctx.captureCellNames, name) {
                insns.add(MLdcI4(v = 0))
                insns.add(MCallvirt(methodToken = cctx.tokListObjGetItem))
              }
              castObjectToMsil(cctx, insns, capTy)
              return capTy
            }
            case None -> {}
          }
          // Check for a module-level compile-time const (inline ldc.i4).
          match mapGet(cctx.constValues, name) {
            case Some(v) -> {
              insns.add(MLdcI4(v = v))
              MInt
            }
            case None -> {
              // Nullary union case as a bare path (e.g. `val n = None`
              // — Lyric accepts the call-less form).  Same two-step
              // resolution as the `ECall` path: try the local pkg's
              // case ctor, then walk `unionCaseCtorByName` for cross-
              // package cases.  Mirrors the construction-side fix in
              // `lowerBuiltinOrStaticCallMsil` (#1183 codegen port).
              val localCtorKey = fctx.pkgName + "." + name
              val ctorKey =
                if cctx.recordCtorTokens.containsKey(localCtorKey) {
                  localCtorKey
                } else {
                  match mapGet(cctx.unionCaseCtorByName, name) {
                    case Some(fqn) -> fqn
                    case None      -> localCtorKey
                  }
                }
              match mapGet(cctx.recordCtorTokens, ctorKey) {
                case Some(ctorTok) -> {
                  // For nullary generic stdlib cases (e.g. None), infer T from the
                  // innermost context hint (local variable type annotation, e.g.
                  // `var x: Option[Int] = None` → T=Int), falling back to the
                  // function's declared return type (e.g. `return None` in a
                  // function returning Option[Long] → T=Long).
                  val nullCtxTyArgs: List[MsilType] = newList()
                  if fctx.contextHintTyArgs.count > 0 {
                    var hi = 0
                    while hi < fctx.contextHintTyArgs.count {
                      nullCtxTyArgs.add(fctx.contextHintTyArgs[hi])
                      hi = hi + 1
                    }
                  } else {
                    match fctx.declaredRetTy {
                      case MGenericInst(_, _, retArgTys) -> {
                        var rti = 0
                        while rti < retArgTys.count {
                          nullCtxTyArgs.add(retArgTys[rti])
                          rti = rti + 1
                        }
                      }
                      case _ -> {}
                    }
                  }
                  val nullArgTypes: List[MsilType] = newList()
                  val nullOutPTy: List[MsilType] = newList()
                  val nullGenTok = buildGenericCaseCtorTok(cctx, ctorKey, nullArgTypes, nullCtxTyArgs, nullOutPTy, insns)
                  if nullGenTok > 0 {
                    // MNewobjGenericCase already emitted to insns by buildGenericCaseCtorTok.
                    if nullOutPTy.count > 0 { nullOutPTy[0] }
                    else                    { MObject }
                  } else {
                    match mapGet(cctx.singletonFieldTokens, ctorKey) {
                      case Some(fldTok) -> {
                        insns.add(MLdsfld(fieldToken = fldTok))
                        val dollarIdx = ctorKey.lastIndexOf("$")
                        val classTy = if dollarIdx >= 0 { ctorKey.substring(0, dollarIdx) }
                                      else              { ctorKey }
                        MClass(className = classTy)
                      }
                      case None -> {
                        insns.add(MNewobj(ctorToken = ctorTok))
                        val dollarIdx = ctorKey.lastIndexOf("$")
                        val classTy = if dollarIdx >= 0 { ctorKey.substring(0, dollarIdx) }
                                      else              { ctorKey }
                        MClass(className = classTy)
                      }
                    }
                  }
                }
                case None -> {
                  // Module-level val: load from the static field emitted for this IVal.
                  match mapGet(cctx.staticValTokens, name) {
                    case Some(fieldTok) -> {
                      val ty = match mapGet(cctx.staticValMsilTypes, name) {
                        case Some(t) -> t
                        case None    -> MObject
                      }
                      insns.add(MLdsfld(fieldToken = fieldTok))
                      ty
                    }
                    case None -> {
                      insns.add(MLdNull)
                      MObject
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    // ── Arithmetic / logic binary ops ────────────────────────────────────────
    case EBinop(op, lhs, rhs) -> {
      lowerBinopMsil(cctx, fctx, insns, op, lhs, rhs)
    }

    // ── Prefix ops ────────────────────────────────────────────────────────────
    case EPrefix(op, operand) -> {
      match op {
        case PreNeg -> {
          val ty = lowerExprMsil(cctx, fctx, insns, operand)
          insns.add(MNeg)
          ty
        }
        case PreNot -> {
          lowerExprMsil(cctx, fctx, insns, operand)
          insns.add(MLdcI4(v = 1))
          insns.add(MXor)
          MBool
        }
        case PreRef -> {
          lowerExprMsil(cctx, fctx, insns, operand)
        }
      }
    }

    // ── Function calls ─────────────────────────────────────────────────────────
    case ECall(fn, args) -> {
      lowerCallMsil(cctx, fctx, insns, fn, args)
    }

    // ── Member access ──────────────────────────────────────────────────────────
    case EMember(recv, memberName) -> {
      val recvTy = lowerExprMsil(cctx, fctx, insns, recv)
      match recvTy {
        case MClass(cls) -> {
          val key = cls + "/" + memberName
          match mapGet(cctx.fieldTokens, key) {
            case Some(tok) -> {
              // Locals and return values of class type are declared as `object`
              // in LocalVarSig, so the stack type seen by the JIT is `object`.
              // castclass narrows the stack type to the concrete class before
              // ldfld so the verifier accepts the instruction (#1442).
              insns.add(MCastclassByName(className = cls))
              insns.add(MLdfld(fieldToken = tok))
              // Return the field's declared MSIL type so that downstream
              // operators (BEq/BNeq) use ceq for value types instead of
              // Object.Equals — passing an unboxed Bool/Int to Object.Equals
              // triggers StackUnexpected / InvalidProgramException (#1442).
              match mapGet(cctx.fieldMsilTypes, key) {
                case Some(fty) -> fty
                case None      -> MObject
              }
            }
            case None -> {
              if memberName == "count" {
                insns.add(MCallvirt(methodToken = cctx.tokListObjGetCount))
                MInt
              } else {
                insns.add(MPop)
                MObject
              }
            }
          }
        }
        case MMapOf(_, _) -> {
          // Map[K, V] receiver: dispatch to Dictionary<object,object> members.
          if memberName == "count" {
            insns.add(MCallvirt(methodToken = cctx.tokDictObjGetCount))
            MInt
          } else {
            // Unimplemented Map member: pop the receiver and emit a runtime
            // throw so the failure is loud rather than a silent miscompile.
            insns.add(MPop)
            val msgTok = ctxInternUs(cctx.lctx, "Msil.Codegen: unimplemented Map member access: " + memberName)
            insns.add(MLdStr(token = msgTok))
            insns.add(MNewobj(ctorToken = cctx.tokExceptionCtor))
            insns.add(MThrow)
            MObject
          }
        }
        case MArray(_) -> {
          // Real CLI array receiver: `.length` / `.count` is `ldlen` (which
          // pushes a native int; conv.i4 narrows it to the Int the rest of the
          // codegen expects).
          if memberName == "length" or memberName == "count" {
            insns.add(MLdlen)
            insns.add(MConvI4)
            MInt
          } else {
            insns.add(MPop)
            MObject
          }
        }
        case _ -> {
          // TyException built-in members: .message and .typeName.
          // Catch-clause exception bindings are stored as MObject; detect by member name.
          if memberName == "message" {
            insns.add(MCallvirt(methodToken = cctx.tokExcGetMessage))
            MString
          } else if memberName == "typeName" {
            insns.add(MCallvirt(methodToken = cctx.tokObjGetType))
            insns.add(MCallvirt(methodToken = cctx.tokTypeGetName))
            MString
          } else if memberName == "count" {
            // castclass makes the stack type explicit as List<object> so the JIT
            // can verify the callvirt when the receiver was produced by a call
            // returning Object (e.g. a generator function).
            insns.add(MCastclass(typeToken = cctx.tokListObjTypeSpec))
            insns.add(MCallvirt(methodToken = cctx.tokListObjGetCount))
            MInt
          } else if memberName == "length" {
            insns.add(MCallvirt(methodToken = cctx.tokStringGetLength))
            MInt
          } else {
            // KNOWN IL-VERIFICATION GAP: no preceding `castclass` before `ldfld`
            // on an `MObject` receiver; the primary `MClass` arm does emit
            // `MCastclassByName(cls)` first.  Plumbing the declaring class
            // name alongside the field token (so the cast can be named here
            // too) is tracked in #1868.  Currently safe because every caller that
            // reaches this fallback path holds a receiver compatible with the
            // field's declaring class at the source level (the type checker
            // has already verified field access); strict IL verification
            // (`peverify`) would still flag this.
            val fbyNameKey = fctx.pkgName + "/" + memberName
            match mapGet(cctx.fieldTokensByName, fbyNameKey) {
              case Some(tok) -> {
                insns.add(MLdfld(fieldToken = tok))
                match mapGet(cctx.fieldMsilTypes, fbyNameKey) {
                  case Some(fty) -> fty
                  case None      -> MObject
                }
              }
              case None -> {
                MObject
              }
            }
          }
        }
      }
    }

    // ── If / else ──────────────────────────────────────────────────────────────
    case EIf(cond, thenBranch, elseBranchOpt, _) -> {
      lowerIfExprMsil(cctx, fctx, insns, cond, thenBranch, elseBranchOpt)
    }

    // ── Block expression ───────────────────────────────────────────────────────
    case EBlock(block) -> {
      lowerBlockExprMsil(cctx, fctx, insns, block)
    }

    // ── Unsafe block (same as block for MSIL) ─────────────────────────────────
    case EUnsafe(block) -> {
      lowerBlockExprMsil(cctx, fctx, insns, block)
    }

    // ── Assignment expression ──────────────────────────────────────────────────
    case EAssign(target, op, value) -> {
      lowerAssignExprMsil(cctx, fctx, insns, target, op, value)
    }

    // ── Tuple ──────────────────────────────────────────────────────────────────
    // Tuples are represented at runtime as List<object> with each element boxed.
    case ETuple(exprs) -> {
      insns.add(MNewobj(ctorToken = cctx.tokListObjCtor))
      var etei = 0
      while etei < exprs.count {
        insns.add(MDup)
        val eteTy = lowerExprMsil(cctx, fctx, insns, exprs[etei])
        boxIfNeededMsil(cctx, insns, eteTy)
        insns.add(MCallvirt(methodToken = cctx.tokListObjAdd))
        etei = etei + 1
      }
      MObject
    }

    // ── List literal ───────────────────────────────────────────────────────────
    case EList(exprs) -> {
      // newobj List<object>(); then add each element.
      insns.add(MNewobj(ctorToken = cctx.tokListObjCtor))
      var eli = 0
      while eli < exprs.count {
        insns.add(MDup)
        val eTy = lowerExprMsil(cctx, fctx, insns, exprs[eli])
        boxIfNeededMsil(cctx, insns, eTy)
        insns.add(MCallvirt(methodToken = cctx.tokListObjAdd))
        eli = eli + 1
      }
      MObject
    }

    // ── Await ─────────────────────────────────────────────────────────────────
    // When inside a Phase B.1 SM MoveNext body, emit the full suspend/resume
    // protocol.  Otherwise emit a blocking synchronous shim (GetAwaiter+GetResult).
    // Non-Task values (blocking @externTarget async, or already-resolved results)
    // are passed through as-is: the value is already on the stack.
    case EAwait(inner) -> {
      val taskTy = lowerExprMsil(cctx, fctx, insns, inner)
      if not isTaskTypeMsil(cctx, taskTy) {
        // Value is already resolved (blocking extern async, etc.) — no await needed.
        taskTy
      } else if fctx.phaseBCtx.count > 0 {
        emitPhaseBAwait(cctx, fctx, insns, taskTy)
      } else {
        emitBlockingAwait(cctx, fctx, insns, taskTy)
      }
    }

    // ── Yield: collect-all model (R6) ────────────────────────────────────────
    // Each `yield e` appends e to the per-function List<object> collector that
    // was allocated at function entry by lowerFuncMsil when it detected the
    // @async_generator annotation.  Returns MVoid so the statement wrapper pops
    // nothing (void instructions push nothing).
    case EYield(inner) -> {
      if fctx.yieldSlots.count > 0 {
        val collSlot = fctx.yieldSlots[0]
        insns.add(MLdloc(slot = collSlot - fctx.paramCount))
        // The collector local is typed `object` (MObject) but `List<object>::Add`
        // expects `this` to be `List<object>`.  Castclass narrows the stack type
        // so the JIT verifier accepts the callvirt.
        insns.add(MCastclass(typeToken = cctx.tokListObjTypeSpec))
        val eTy = lowerExprMsil(cctx, fctx, insns, inner)
        boxIfNeededMsil(cctx, insns, eTy)
        insns.add(MCallvirt(methodToken = cctx.tokListObjAdd))
      } else {
        panic("Msil.Codegen: yield outside async generator — front-end should have rejected this")
      }
      MVoid
    }

    case ESpawn(inner) -> {
      lowerExprMsil(cctx, fctx, insns, inner)
    }

    // ── Propagate (?) — bootstrap: just lower inner ───────────────────────────
    case ETry(inner) -> {
      lowerExprMsil(cctx, fctx, insns, inner)
    }

    case EPropagate(inner) -> {
      lowerExprMsil(cctx, fctx, insns, inner)
    }

    // ── Match expression ───────────────────────────────────────────────────────
    case EMatch(scrutinee, arms) -> {
      lowerMatchExprMsil(cctx, fctx, insns, scrutinee, arms)
    }

    // ── Interpolated string ────────────────────────────────────────────────────
    case EInterpolated(segments) -> {
      lowerInterpolatedMsil(cctx, fctx, insns, segments)
    }

    // ── Type application — ignore type args and lower the callee ──────────────
    case ETypeApp(fn, _) -> {
      lowerExprMsil(cctx, fctx, insns, fn)
    }

    // ── Index access ───────────────────────────────────────────────────────────
    case EIndex(recv, indices) -> {
      val recvTy = lowerExprMsil(cctx, fctx, insns, recv)
      match recvTy {
        case MString -> {
          // String.get_Chars(int32): char — push index then callvirt.
          if indices.count > 0 {
            lowerExprMsil(cctx, fctx, insns, indices[0])
          }
          insns.add(MCallvirt(methodToken = cctx.tokStringGetChars))
          MChar
        }
        case MMapOf(_, valTy) -> {
          // Map[K, V] receiver: read via Dictionary<object,object>::get_Item,
          // which takes the boxed key (not an int32 index).  Routing a Map read
          // through List::get_Item (the historical `case _` fallthrough) pushed
          // a non-int key where an int32 index was expected and the JIT rejected
          // the body as invalid — the read-side counterpart of the indexed-store
          // fix (#1602).
          insns.add(MCastclass(typeToken = cctx.tokDictObjTypeSpec))
          if indices.count > 0 {
            val kTy = lowerExprMsil(cctx, fctx, insns, indices[0])
            boxIfNeededMsil(cctx, insns, kTy)
          }
          insns.add(MCallvirt(methodToken = cctx.tokDictObjGetItem))
          // get_Item returns the boxed value (object).  For a value-type V the
          // stack must carry the unboxed value to match the tracked `valTy`,
          // otherwise a later numeric op / comparison treats the object
          // reference as the value (#1779 / #1835).  Reference V stays object.
          if isValueType(valTy) {
            castObjectToMsil(cctx, insns, valTy)
          }
          valTy
        }
        case MListOf(elemTy) -> {
          // List[T] receiver with a known element type.  get_Item returns
          // object; we track the element type in the codegen type-flow layer
          // so the subsequent EMember handler emits castclass + ldfld against
          // the correct concrete type (#1442).
          insns.add(MCastclass(typeToken = cctx.tokListObjTypeSpec))
          if indices.count > 0 {
            lowerExprMsil(cctx, fctx, insns, indices[0])
          }
          insns.add(MCallvirt(methodToken = cctx.tokListObjGetItem))
          // get_Item returns a boxed `object`.  For a value-type element the
          // stack must carry the *unboxed* value to match the tracked `elemTy`
          // — otherwise a later numeric op / comparison (e.g. `xs[i] <= 0`)
          // treats the object reference as an i4, producing invalid IL or a
          // silently wrong result (#1779).  Reference-type elements stay as
          // `object`; the EMember handler narrows them with castclass (#1442).
          if isValueType(elemTy) {
            castObjectToMsil(cctx, insns, elemTy)
          }
          elemTy
        }
        case MArray(elem) -> {
          // Real CLI array receiver (e.g. `slice[String]` → `String[]` from a
          // stdlib call such as `Std.String.split`).  Push the index, then load
          // the element with the opcode matching the element type — the array
          // is already on the stack, so stack is [array, index] before ldelem.
          if indices.count > 0 {
            lowerExprMsil(cctx, fctx, insns, indices[0])
          }
          match elem {
            case MByte     -> { insns.add(MLdelemU1);  MInt }
            case MInt      -> { insns.add(MLdelemI4);  MInt }
            case MString   -> { insns.add(MLdelemRef); MString }
            case MClass(c) -> { insns.add(MLdelemRef); MClass(className = c) }
            case _         -> { insns.add(MLdelemRef); elem }
          }
        }
        case _ -> {
          // List<object>.get_Item(int32): object — castclass the receiver
          // BEFORE pushing the index so the IL stack is [List<object>, int32].
          // A receiver typed as `object` on the stack (e.g. an `in` parameter)
          // would otherwise fail JIT verification on get_Item; this mirrors the
          // get_Count / set_Item paths, keeping read and write receiver
          // handling symmetric (#1531).
          insns.add(MCastclass(typeToken = cctx.tokListObjTypeSpec))
          if indices.count > 0 {
            lowerExprMsil(cctx, fctx, insns, indices[0])
          }
          insns.add(MCallvirt(methodToken = cctx.tokListObjGetItem))
          MObject
        }
      }
    }

    // ── Unsupported forms ──────────────────────────────────────────────────────
    // Quantifier and old-state expressions are proof-only — the contract
    // elaborator either discharges them through the verifier or removes
    // them before codegen.  Reaching here means a `@runtime_checked`
    // contract leaked one into an executable position; report and abort.
    case EForall(_, _, _) -> {
      panic("Msil.Codegen: EForall is proof-only and cannot be lowered to MSIL")
    }
    case EExists(_, _, _) -> {
      panic("Msil.Codegen: EExists is proof-only and cannot be lowered to MSIL")
    }
    case EOld(_) -> {
      panic("Msil.Codegen: EOld is proof-only and cannot be lowered to MSIL")
    }
    case ESelf -> {
      insns.add(MLdarg(slot = 0))
      // Type `self` as its enclosing class so `self.method(...)` dispatches via
      // the MClass arm of `lowerMethodCallMsil`; MObject went to the BCL stub.
      if fctx.className.length > 0 {
        MClass(className = fctx.className)
      } else {
        MObject
      }
    }
    case EResult -> {
      // `result` is a contextual keyword: inside ensures clauses the contract
      // elaborator rewrites EResult to EPath([__lyric_result_N]) before codegen
      // sees it.  The only remaining case is a user-declared local or parameter
      // named "result" (valid because the pattern parser accepts KwResult in
      // binding position).  Check fctx.slots first; fall back to panic only
      // when no such binding exists (which should never happen after elaboration).
      match mapGet(fctx.slots, "result") {
        case Some(slot) -> {
          val ty =
            match mapGet(fctx.types, "result") {
              case Some(t) -> t
              case None    -> MObject
            }
          emitLoadSlot(insns, slot, fctx.paramCount)
          ty
        }
        case None -> {
          panic("Msil.Codegen: EResult outside contract context")
        }
      }
    }
    // ── Lambda: non-capturing, emitted as a lifted __lambda_<i> static method ──
    // Lambda-lifting pre-pass (liftLambdasMsil) has already extracted each
    // ELambda into a synthetic IFunc named __lambda_<i>.  Here we allocate
    // the next index from lambdaTicker and look up the pre-assigned MethodDef.
    // Uniform Func ABI (#1877): every lambda is built as System.Func`(N+1)
    // <object,…,object> (the lifted method returns a boxed object / null), so
    // construction and invocation agree.  Parameter-taking lambdas are not yet
    // supported (params arrive boxed and untyped — #1939) and are rejected below.
    case ELambda(lparams, lbody) -> {
      // Capturing closures (#1479): a lambda is lifted to a `__lambda_<i>`
      // static method.  When its body refers to a local/parameter of the
      // enclosing function, those values are captured by-value into an
      // `object[] __caps` that is bound as the delegate's (closed) target; the
      // lifted method takes `__caps` as its first parameter and reads each
      // capture from it (see lowerFuncMsil + EPath).  `lambdaCaptureNamesMsil`
      // computes the capture set (free idents ∩ enclosing slots); their types
      // come from the enclosing scope.
      val caps = lambdaCaptureNamesMsil(fctx, lparams, lbody)
      // Capture types (parallel to `caps`) and the subset captured by reference.
      // A captured `var` was hoisted to a heap cell at its declaration (#1479 v2,
      // pre-pass): its capture is the cell itself (by reference, element type =
      // `hoistedCellType`).  An immutable binding is captured by value (its
      // `fctx.types`).  A captured `var` that was *not* hoisted (a pre-pass miss)
      // must never be silently captured by value — fail loud as a safety net.
      val capTypes: List[MsilType] = newList()
      val capCells: List[String] = newList()
      var capTyI = 0
      while capTyI < caps.count {
        val cn = caps[capTyI]
        match mapGet(fctx.hoistedCellSlot, cn) {
          case Some(_) -> {
            capTypes.add(match mapGet(fctx.hoistedCellType, cn) { case Some(t) -> t case None -> MObject })
            capCells.add(cn)
          }
          case None -> {
            if nameListContains(fctx.mutableLocals, cn) {
              panic("Msil.Codegen: internal error — captured mutable (`var`) local '" +
                    cn + "' was not hoisted to a heap cell (#1479 v2 closure-capture " +
                    "pre-pass missed it).  Please report this with a reproducer.")
            }
            capTypes.add(match mapGet(fctx.types, cn) { case Some(t) -> t case None -> MObject })
          }
        }
        capTyI = capTyI + 1
      }
      // Parameter-taking lambdas (#1939): the delegate is Func<object,…,object>,
      // so arguments arrive boxed.  A param's logical type can come from an
      // annotation (`{ x: Int -> … }`) or be *propagated* from the higher-order
      // function's signature when the lambda is passed directly as an argument
      // (recorded in lambdaParamTypes under this lambda's index).  Reject only a
      // used param that has neither — its boxed value has no type to unbox to.
      if lparams.count > 0 {
        val lpRefs: List[String] = newList()
        collectRefNamesBlock(lbody, lpRefs)
        val propagated = match mapGet(cctx.lambdaParamTypes, "__lambda_" + toString(cctx.lambdaTicker.count)) {
          case Some(ts) -> ts
          case None     -> newList()
        }
        var lpi2 = 0
        while lpi2 < lparams.count {
          val lp = lparams[lpi2]
          val isUsed = nameListContains(lpRefs, lp.name)
          val isAnnotated = match lp.ty { case Some(_) -> true case None -> false }
          val isPropagated = lpi2 < propagated.count
          if isUsed and not isAnnotated and not isPropagated {
            panic("Msil.Codegen: a lambda that uses an un-annotated parameter " +
                  "('" + lp.name + "') outside a direct higher-order-function call " +
                  "is not yet supported on --target dotnet — the boxed argument has " +
                  "no type to unbox to (#1939).  Annotate the parameter type (e.g. " +
                  "`{ " + lp.name + ": Int -> … }`), pass the lambda directly to a " +
                  "function with a typed `(…) -> R` parameter, use a zero-argument " +
                  "lambda, or lift the lambda to a top-level function.")
          }
          lpi2 = lpi2 + 1
        }
      }
      val idx = cctx.lambdaTicker.count
      cctx.lambdaTicker.add(0)
      val lname = "__lambda_" + toString(idx)
      val nparams = lparams.count
      // Record the capture set so lowerFuncMsil's `__lambda_*` path prepends the
      // `object[] __caps` parameter and resolves captured reads (#1479).
      if caps.count > 0 {
        cctx.lambdaCaptureNames.add(lname, caps)
        cctx.lambdaCaptureTypes.add(lname, capTypes)
        cctx.lambdaCaptureCells.add(lname, capCells)
      }
      // FQN key (#1183 Phase 2): lambdas are package-scoped, registered by
      // `addPackageTokens` as `<pkg>.__lambda_<idx>`.
      val lambdaKey = fctx.pkgName + "." + lname
      match mapGet(cctx.funcTokens, lambdaKey) {
        case Some(tok) -> {
          // Determine delegate type based on lambda return type.
          // Lambdas that return void use System.Action; those with non-void returns use System.Func.
          val retType = mapGet(cctx.funcRetTypes, lambdaKey)
          val returnsVoid = match retType {
            case Some(MVoid) -> true
            case None        -> true
            case _           -> false
          }
          val ctorTok =
            if returnsVoid {
              if nparams == 0 { cctx.tokActionCtor }
              else            { buildActionNCtorTok(cctx, nparams) }
            } else {
              buildFuncNCtorTok(cctx, nparams)
            }
          // Delegate target: a closed-over `object[]` of captured values for a
          // capturing lambda (each boxed), else `null` for a static delegate.
          if caps.count > 0 {
            insns.add(MLdcI4(v = caps.count))
            insns.add(MNewarr(typeToken = 0x01000000 + boxTypeRef(cctx, MObject)))
            var capStI = 0
            while capStI < caps.count {
              insns.add(MDup)
              insns.add(MLdcI4(v = capStI))
              if nameListContains(capCells, caps[capStI]) {
                // By-reference: store the cell (a `List[object]` reference) itself
                // so the closure and enclosing scope share it — no box (#1479 v2).
                match mapGet(fctx.hoistedCellSlot, caps[capStI]) {
                  case Some(s) -> emitLoadVarMsil(fctx, insns, s)
                  case None    -> insns.add(MLdNull)
                }
              } else {
                match mapGet(fctx.slots, caps[capStI]) {
                  case Some(s) -> emitLoadVarMsil(fctx, insns, s)
                  case None    -> insns.add(MLdNull)
                }
                boxIfNeededMsil(cctx, insns, capTypes[capStI])
              }
              insns.add(MStelemRef)
              capStI = capStI + 1
            }
          } else {
            insns.add(MLdNull)
          }
          insns.add(MLdftn(methodToken = tok))
          insns.add(MNewobj(ctorToken = ctorTok))
          MObject
        }
        case None -> {
          panic("Msil.Codegen: lambda token missing for " + lname + " — liftLambdasMsil pre-pass was not run")
          MObject
        }
      }
    }
    case ERange(_) -> {
      // Ranges are supported as `for` iterators (`for i in lo .. hi`, see
      // `lowerForMsil`) and as match patterns; materialising `lo .. hi` as a
      // first-class value is not yet modelled on --target dotnet (no `Range`
      // value type in the self-hosted backend).  Fail loudly rather than emit
      // a bogus value (#1478).
      panic("Msil.Codegen: a range expression (`lo .. hi`) is only supported as a `for`-loop iterator or a match pattern on --target dotnet; first-class range values are not yet materialised (#1478).")
    }
    case EError -> {
      insns.add(MLdNull)
      MObject
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5a. Binary operation lowering.
// ─────────────────────────────────────────────────────────────────────────────

// Return the MethodDef token of a type's `@derive(Equals)`-synthesised
// `equals(self, other): Bool` (named `<TypeName>.equals` by `Lyric.Derives`,
// keyed `<typeFqn>.equals` in `funcTokens`), or -1 when the type has no derived
// structural-equality method.  Used by `BEq`/`BNeq` so `a == b` on a record /
// distinct type with `@derive(Equals)` compares structurally instead of by
// reference (#1480).  Map/HashSet key dispatch additionally needs real
// `Object.Equals`/`GetHashCode` overrides and is tracked as the remaining
// #1480 scope.
func derivedEqualsTokenMsil(cctx: in CodegenCtx, ty: in MsilType): Int {
  val fqn = match ty {
    case MClass(c)                   -> c
    case MGenericInst(_, headFqn, _) -> headFqn
    case _                           -> ""
  }
  if fqn.length == 0 { return 0 - 1 }
  match mapGet(cctx.funcTokens, fqn + ".equals") {
    case Some(t) -> t
    case None    -> 0 - 1
  }
}

func lowerBinopMsil(
  cctx:  in CodegenCtx,
  fctx:  in FuncCtx,
  insns: in List[MInsn],
  op:    in BinOp,
  lhs:   in Expr,
  rhs:   in Expr
): MsilType {
  match op {
    // Boolean short-circuit AND.
    case BAnd -> {
      val falseL = freshLabelMsil(fctx)
      val afterL = freshLabelMsil(fctx)
      lowerExprMsil(cctx, fctx, insns, lhs)
      insns.add(MBrFalse(label = falseL))
      lowerExprMsil(cctx, fctx, insns, rhs)
      insns.add(MBrFalse(label = falseL))
      insns.add(MLdcI4(v = 1))
      insns.add(MBr(label = afterL))
      insns.add(MLabel(id =falseL))
      insns.add(MLdcI4(v = 0))
      insns.add(MLabel(id =afterL))
      MBool
    }
    // Boolean short-circuit OR.
    case BOr -> {
      val trueL  = freshLabelMsil(fctx)
      val afterL = freshLabelMsil(fctx)
      lowerExprMsil(cctx, fctx, insns, lhs)
      insns.add(MBrTrue(label = trueL))
      lowerExprMsil(cctx, fctx, insns, rhs)
      insns.add(MBrTrue(label = trueL))
      insns.add(MLdcI4(v = 0))
      insns.add(MBr(label = afterL))
      insns.add(MLabel(id =trueL))
      insns.add(MLdcI4(v = 1))
      insns.add(MLabel(id =afterL))
      MBool
    }
    // Comparison operators — produce 0 or 1.
    case BEq -> {
      val beqLhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      // Equality is symmetric: treat as commutative — just ldloc spill after rhs.
      val beqSpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
        phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, beqLhsTy)
      } else { -1 }
      val beqRhsTy = lowerExprMsil(cctx, fctx, insns, rhs)
      if beqSpillIdx >= 0 { insns.add(MLdloc(slot = beqSpillIdx)) }
      match beqLhsTy {
        case MInt | MBool | MChar | MLong | MDouble -> {
          insns.add(MCeq)
          MBool
        }
        case _ -> {
          // A record / distinct type with `@derive(Equals)` compares
          // structurally via its synthesised `equals(self, other)` (#1480);
          // both operands are already on the stack in (self, other) order.
          val eqTok = derivedEqualsTokenMsil(cctx, beqLhsTy)
          if eqTok > 0 {
            insns.add(MCall(methodToken = eqTok))
            MBool
          } else {
            // Object.Equals(object, object): box rhs if it's a value type.
            boxIfNeededMsil(cctx, insns, beqRhsTy)
            insns.add(MCall(methodToken = cctx.tokObjectStaticEquals))
            MBool
          }
        }
      }
    }
    case BNeq -> {
      val bneqLhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      val bneqSpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
        phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, bneqLhsTy)
      } else { -1 }
      val bneqRhsTy = lowerExprMsil(cctx, fctx, insns, rhs)
      if bneqSpillIdx >= 0 { insns.add(MLdloc(slot = bneqSpillIdx)) }
      match bneqLhsTy {
        case MInt | MBool | MChar | MLong | MDouble -> {
          insns.add(MCeq)
          insns.add(MLdcI4(v = 1))
          insns.add(MXor)
          MBool
        }
        case _ -> {
          val neqTok = derivedEqualsTokenMsil(cctx, bneqLhsTy)
          if neqTok > 0 {
            insns.add(MCall(methodToken = neqTok))
          } else {
            boxIfNeededMsil(cctx, insns, bneqRhsTy)
            insns.add(MCall(methodToken = cctx.tokObjectStaticEquals))
          }
          insns.add(MLdcI4(v = 1))
          insns.add(MXor)
          MBool
        }
      }
    }
    // For non-commutative comparison/arithmetic ops, spill lhs before rhs evaluation,
    // then stash rhs result and reload [lhs, rhs] in correct order for the op.
    case BLt -> {
      val bltLhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      val bltSpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
        phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, bltLhsTy)
      } else { -1 }
      val bltRhsTy = lowerExprMsil(cctx, fctx, insns, rhs)
      if bltSpillIdx >= 0 {
        val rN = "__spill_r_" + toString(fctx.slotTicker.count)
        val rS = allocSlotMsil(fctx, rN, bltRhsTy)
        insns.add(MStloc(slot = rS - fctx.paramCount))
        insns.add(MLdloc(slot = bltSpillIdx))
        insns.add(MLdloc(slot = rS - fctx.paramCount))
      }
      if bltRhsTy == MObject and isValueType(bltLhsTy) {
        insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, bltLhsTy)))
      }
      insns.add(MClt)
      MBool
    }
    case BGt -> {
      val bgtLhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      val bgtSpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
        phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, bgtLhsTy)
      } else { -1 }
      val bgtRhsTy = lowerExprMsil(cctx, fctx, insns, rhs)
      if bgtSpillIdx >= 0 {
        val rN = "__spill_r_" + toString(fctx.slotTicker.count)
        val rS = allocSlotMsil(fctx, rN, bgtRhsTy)
        insns.add(MStloc(slot = rS - fctx.paramCount))
        insns.add(MLdloc(slot = bgtSpillIdx))
        insns.add(MLdloc(slot = rS - fctx.paramCount))
      }
      if bgtRhsTy == MObject and isValueType(bgtLhsTy) {
        insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, bgtLhsTy)))
      }
      insns.add(MCgt)
      MBool
    }
    case BLte -> {
      // a <= b  ≡  !(a > b)
      val blteLhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      val blteSpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
        phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, blteLhsTy)
      } else { -1 }
      val blteRhsTy = lowerExprMsil(cctx, fctx, insns, rhs)
      if blteSpillIdx >= 0 {
        val rN = "__spill_r_" + toString(fctx.slotTicker.count)
        val rS = allocSlotMsil(fctx, rN, blteRhsTy)
        insns.add(MStloc(slot = rS - fctx.paramCount))
        insns.add(MLdloc(slot = blteSpillIdx))
        insns.add(MLdloc(slot = rS - fctx.paramCount))
      }
      if blteRhsTy == MObject and isValueType(blteLhsTy) {
        insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, blteLhsTy)))
      }
      insns.add(MCgt)
      insns.add(MLdcI4(v = 1))
      insns.add(MXor)
      MBool
    }
    case BGte -> {
      // a >= b  ≡  !(a < b)
      val bgteLhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      val bgteSpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
        phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, bgteLhsTy)
      } else { -1 }
      val bgteRhsTy = lowerExprMsil(cctx, fctx, insns, rhs)
      if bgteSpillIdx >= 0 {
        val rN = "__spill_r_" + toString(fctx.slotTicker.count)
        val rS = allocSlotMsil(fctx, rN, bgteRhsTy)
        insns.add(MStloc(slot = rS - fctx.paramCount))
        insns.add(MLdloc(slot = bgteSpillIdx))
        insns.add(MLdloc(slot = rS - fctx.paramCount))
      }
      if bgteRhsTy == MObject and isValueType(bgteLhsTy) {
        insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, bgteLhsTy)))
      }
      insns.add(MClt)
      insns.add(MLdcI4(v = 1))
      insns.add(MXor)
      MBool
    }
    // Arithmetic.
    case BAdd -> {
      val lhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      match lhsTy {
        case MString -> {
          // String concatenation via String.Concat(string,string).
          // Store lhs temporarily; promote to SM field if rhs has an await so it
          // survives any suspension.  Then lower rhs (converting to string if needed),
          // stash rhs, and call Concat2(lhs, rhs).
          val saddName    = "__sadd_" + toString(fctx.slotTicker.count)
          val saddLhsSlot = allocSlotMsil(fctx, saddName, MString)
          val saddLhsLocalIdx = saddLhsSlot - fctx.paramCount
          insns.add(MStloc(slot = saddLhsLocalIdx))
          if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
            phaseBRegisterAndSyncLocal(fctx.phaseBCtx[0], insns, saddName, MString, saddLhsLocalIdx)
          }
          val saddRhsTy = lowerExprMsil(cctx, fctx, insns, rhs)
          match saddRhsTy {
            case MString -> {}
            case _ -> {
              // Convert non-string rhs to string: box value types, then call ToString().
              if isValueType(saddRhsTy) {
                boxIfNeededMsil(cctx, insns, saddRhsTy)
              }
              insns.add(MCallvirt(methodToken = cctx.tokObjToString))
            }
          }
          val saddRhsSlot = allocSlotMsil(fctx,
            "__sadd_r_" + toString(fctx.slotTicker.count), MString)
          insns.add(MStloc(slot = saddRhsSlot - fctx.paramCount))
          insns.add(MLdloc(slot = saddLhsLocalIdx))
          insns.add(MLdloc(slot = saddRhsSlot - fctx.paramCount))
          insns.add(MCall(methodToken = cctx.tokConcat2))
          MString
        }
        // Commutative numeric adds: spill lhs before rhs if rhs has await, then
        // reload lhs after rhs (operand order doesn't matter for add).
        case MLong -> {
          val baddLSpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
            phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, MLong)
          } else { -1 }
          lowerExprMsil(cctx, fctx, insns, rhs)
          if baddLSpillIdx >= 0 { insns.add(MLdloc(slot = baddLSpillIdx)) }
          insns.add(MAdd)
          MLong
        }
        case MDouble -> {
          val baddDSpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
            phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, MDouble)
          } else { -1 }
          lowerExprMsil(cctx, fctx, insns, rhs)
          if baddDSpillIdx >= 0 { insns.add(MLdloc(slot = baddDSpillIdx)) }
          insns.add(MAdd)
          MDouble
        }
        case _ -> {
          val baddISpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
            phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, MInt)
          } else { -1 }
          lowerExprMsil(cctx, fctx, insns, rhs)
          if baddISpillIdx >= 0 { insns.add(MLdloc(slot = baddISpillIdx)) }
          insns.add(MAdd)
          MInt
        }
      }
    }
    case BSub -> {
      val bsubLhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      val bsubSpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
        phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, bsubLhsTy)
      } else { -1 }
      val bsubRhsTy = lowerExprMsil(cctx, fctx, insns, rhs)
      if bsubSpillIdx >= 0 {
        val rN = "__spill_r_" + toString(fctx.slotTicker.count)
        val rS = allocSlotMsil(fctx, rN, bsubRhsTy)
        insns.add(MStloc(slot = rS - fctx.paramCount))
        insns.add(MLdloc(slot = bsubSpillIdx))
        insns.add(MLdloc(slot = rS - fctx.paramCount))
      }
      match bsubLhsTy {
        case MLong   -> { insns.add(MSub); MLong }
        case MDouble -> { insns.add(MSub); MDouble }
        case _       -> { insns.add(MSub); MInt }
      }
    }
    case BMul -> {
      val bmulLhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      // mul is commutative: just reload spill after rhs.
      val bmulSpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
        phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, bmulLhsTy)
      } else { -1 }
      lowerExprMsil(cctx, fctx, insns, rhs)
      if bmulSpillIdx >= 0 { insns.add(MLdloc(slot = bmulSpillIdx)) }
      match bmulLhsTy {
        case MLong   -> { insns.add(MMul); MLong }
        case MDouble -> { insns.add(MMul); MDouble }
        case _       -> { insns.add(MMul); MInt }
      }
    }
    case BDiv -> {
      val bdivLhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      val bdivSpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
        phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, bdivLhsTy)
      } else { -1 }
      val bdivRhsTy = lowerExprMsil(cctx, fctx, insns, rhs)
      if bdivSpillIdx >= 0 {
        val rN = "__spill_r_" + toString(fctx.slotTicker.count)
        val rS = allocSlotMsil(fctx, rN, bdivRhsTy)
        insns.add(MStloc(slot = rS - fctx.paramCount))
        insns.add(MLdloc(slot = bdivSpillIdx))
        insns.add(MLdloc(slot = rS - fctx.paramCount))
      }
      match bdivLhsTy {
        case MLong   -> { insns.add(MDiv); MLong }
        case MDouble -> { insns.add(MDiv); MDouble }
        case _       -> { insns.add(MDiv); MInt }
      }
    }
    case BMod -> {
      val bmodLhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      val bmodSpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
        phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, bmodLhsTy)
      } else { -1 }
      val bmodRhsTy = lowerExprMsil(cctx, fctx, insns, rhs)
      if bmodSpillIdx >= 0 {
        val rN = "__spill_r_" + toString(fctx.slotTicker.count)
        val rS = allocSlotMsil(fctx, rN, bmodRhsTy)
        insns.add(MStloc(slot = rS - fctx.paramCount))
        insns.add(MLdloc(slot = bmodSpillIdx))
        insns.add(MLdloc(slot = rS - fctx.paramCount))
      }
      match bmodLhsTy {
        case MLong -> { insns.add(MRem); MLong }
        case _     -> { insns.add(MRem); MInt }
      }
    }
    case BXor -> {
      val bxorLhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      // xor is commutative: just reload spill after rhs.
      val bxorSpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
        phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, bxorLhsTy)
      } else { -1 }
      lowerExprMsil(cctx, fctx, insns, rhs)
      if bxorSpillIdx >= 0 { insns.add(MLdloc(slot = bxorSpillIdx)) }
      insns.add(MXor)
      MInt
    }
    case BCoalesce -> {
      // Null-coalescing: if lhs is non-null use it, else use rhs.
      val lhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      val nullL  = freshLabelMsil(fctx)
      val afterL = freshLabelMsil(fctx)
      insns.add(MDup)
      insns.add(MBrFalse(label = nullL))
      insns.add(MBr(label = afterL))
      insns.add(MLabel(id =nullL))
      insns.add(MPop)
      lowerExprMsil(cctx, fctx, insns, rhs)
      insns.add(MLabel(id =afterL))
      lhsTy
    }
    case BImplies -> {
      // p => q  ≡  !p || q
      val trueL  = freshLabelMsil(fctx)
      val afterL = freshLabelMsil(fctx)
      lowerExprMsil(cctx, fctx, insns, lhs)
      insns.add(MBrFalse(label = trueL))   // if lhs false, result is true
      lowerExprMsil(cctx, fctx, insns, rhs)
      insns.add(MBr(label = afterL))
      insns.add(MLabel(id =trueL))
      insns.add(MLdcI4(v = 1))
      insns.add(MLabel(id =afterL))
      MBool
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5b. If expression lowering.
// ─────────────────────────────────────────────────────────────────────────────

func lowerExprOrBlockMsil(
  cctx:  in CodegenCtx,
  fctx:  in FuncCtx,
  insns: in List[MInsn],
  eob:   in ExprOrBlock
): MsilType {
  match eob {
    case EOBExpr(e)    -> lowerExprMsil(cctx, fctx, insns, e)
    case EOBBlock(blk) -> lowerBlockExprMsil(cctx, fctx, insns, blk)
  }
}

// INVARIANT: each branch must be label-self-contained (no MBr to a label defined outside).
// Cross-frame control flow across this boundary risks silent JIT failures (global label IDs in temp lists).
func lowerIfExprMsil(
  cctx:          in CodegenCtx,
  fctx:          in FuncCtx,
  insns:         in List[MInsn],
  cond:          in Expr,
  thenBranch:    in ExprOrBlock,
  elseBranchOpt: in Option[ExprOrBlock]
): MsilType {
  val elseL  = freshLabelMsil(fctx)
  val afterL = freshLabelMsil(fctx)

  lowerExprMsil(cctx, fctx, insns, cond)
  insns.add(MBrFalse(label = elseL))

  match elseBranchOpt {
    case Some(elseBranch) -> {
      // Lower both branches into temporary lists so we know both types before
      // deciding how to normalise the stack depth at the afterL join point.
      val thenInsns: List[MInsn] = newList()
      val thenTy = lowerExprOrBlockMsil(cctx, fctx, thenInsns, thenBranch)
      val elseInsns: List[MInsn] = newList()
      val elseTy = lowerExprOrBlockMsil(cctx, fctx, elseInsns, elseBranch)

      // Emit the then block.
      var ti = 0
      while ti < thenInsns.count {
        insns.add(thenInsns[ti])
        ti = ti + 1
      }
      // Case B (then=non-void, else=void): discard the then result BEFORE the
      // branch to afterL so both paths arrive at afterL with stack depth 0.
      // Inserting after the else block would leave a type mismatch (value type
      // vs null reference or similar) that causes PathStackUnexpected at JIT.
      if thenTy != MVoid and elseTy == MVoid {
        insns.add(MPop)
      }
      insns.add(MBr(label = afterL))
      insns.add(MLabel(id = elseL))

      // Emit the else block.
      var ei = 0
      while ei < elseInsns.count {
        insns.add(elseInsns[ei])
        ei = ei + 1
      }
      // Case A (then=void, else=non-void): discard the else result.
      if thenTy == MVoid and elseTy != MVoid {
        insns.add(MPop)
      }
      insns.add(MLabel(id = afterL))
      // Return the effective type: void when branches were normalised, otherwise thenTy.
      if thenTy == MVoid or elseTy == MVoid { MVoid } else { thenTy }
    }
    case None -> {
      // `if` without else: the cond-false path arrives at elseL with depth 0,
      // but the then path may have left a value.  Discard it so both paths
      // have depth 0 at elseL.
      val thenTy = lowerExprOrBlockMsil(cctx, fctx, insns, thenBranch)
      if thenTy != MVoid {
        insns.add(MPop)
      }
      insns.add(MLabel(id = elseL))
      MVoid
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5c. Block expression lowering.
//      Returns the MsilType of the trailing value (last SExpr), or MVoid.
// ─────────────────────────────────────────────────────────────────────────────

func lowerBlockExprMsil(
  cctx:  in CodegenCtx,
  fctx:  in FuncCtx,
  insns: in List[MInsn],
  block: in Block
): MsilType {
  lowerStmtsExprFromMsil(cctx, fctx, insns, block.statements, 0)
}

// Value-producing counterpart of `lowerStmtsFromMsil`: lower statements[start..]
// leaving the trailing value on the stack, honouring `defer`.  When a `defer`
// precedes the value-producing statements, those statements run inside a
// `try`/`finally(D)`; the trailing value is stashed in a temp before the `leave`
// (a `leave` requires an empty evaluation stack) and reloaded after the region,
// so the deferred block runs on scope exit while the block still yields its
// value.  #1477.
func lowerStmtsExprFromMsil(cctx: in CodegenCtx, fctx: in FuncCtx,
                            insns: in List[MInsn], stmts: in List[Statement],
                            start: in Int): MsilType {
  val n = stmts.count
  if start >= n {
    return MVoid
  }
  // Locate the first `defer` at or after `start`.
  var deferIdx = -1
  var di = start
  while di < n {
    match stmts[di].kind {
      case SDefer(_) -> { deferIdx = di; di = n }
      case _         -> { di = di + 1 }
    }
  }
  if deferIdx < 0 {
    // No defer in [start..]: lower as a plain trailing-value block.
    var i = start
    while i < n - 1 {
      lowerStmtMsil(cctx, fctx, insns, stmts[i])
      i = i + 1
    }
    val last = stmts[n - 1]
    return match last.kind {
      case SExpr(e) -> lowerExprMsil(cctx, fctx, insns, e)
      // A `try { … } catch … { … }` in trailing-value position yields the
      // branch values; lower it as a value rather than a discarded statement
      // (which left a non-void function with no return value → invalid IL, #1823).
      case STry(tbody, tcatches, tfinally) ->
        lowerTryCatchExprMsil(cctx, fctx, insns, tbody, tcatches, tfinally)
      case _        -> { lowerStmtMsil(cctx, fctx, insns, last); MVoid }
    }
  }
  // Statements before the defer run normally; the rest produce the value inside
  // a try/finally whose finally is the deferred block.
  var k = start
  while k < deferIdx {
    lowerStmtMsil(cctx, fctx, insns, stmts[k])
    k = k + 1
  }
  val deferBody = match stmts[deferIdx].kind {
    case SDefer(b) -> b
    case _         -> panic("Msil.Codegen: lowerStmtsExprFromMsil: deferIdx points at non-SDefer statement (unreachable)")
  }
  val tryStartL = freshLabelMsil(fctx)
  val afterL    = freshLabelMsil(fctx)
  insns.add(MLabel(id = tryStartL))
  fctx.tryRegionStack.add(0)
  val valTy = lowerStmtsExprFromMsil(cctx, fctx, insns, stmts, deferIdx + 1)
  var tmpSlot = -1
  match valTy {
    case MVoid -> {}
    case _ -> {
      tmpSlot = allocSlotMsil(fctx, "__deferval_" + toString(fctx.slotTicker.count), valTy)
      emitStoreSlot(insns, tmpSlot, fctx.paramCount)
    }
  }
  fctx.tryRegionStack.removeAt(fctx.tryRegionStack.count - 1)
  insns.add(MLeave(label = afterL))
  // NOTE: this finally region is emitted manually (rather than via
  // lowerTryCatchMsil, which the void/statement path uses) because the block
  // value must be captured before the `leave` and reloaded after the region.
  // Keep this EH-clause shape in sync with lowerTryCatchMsil's finally arm if
  // that changes (e.g. stackmap-frame or fault-region handling).  #1832.
  val finallyStartL = freshLabelMsil(fctx)
  val finallyEndL   = freshLabelMsil(fctx)
  insns.add(MLabel(id = finallyStartL))
  lowerBlockMsil(cctx, fctx, insns, deferBody)
  insns.add(MEndfinally)
  insns.add(MLabel(id = finallyEndL))
  insns.add(MEHClause(
    flags        = 2,
    tryStart     = tryStartL,
    tryEnd       = finallyStartL,
    handlerStart = finallyStartL,
    handlerEnd   = finallyEndL,
    catchToken   = 0))
  insns.add(MLabel(id = afterL))
  if tmpSlot >= 0 {
    emitLoadSlot(insns, tmpSlot, fctx.paramCount)
  }
  valTy
}

// Push a hoisted-`var` cell onto the stack (#1479 v2): either an enclosing-scope
// cell at a local slot (`isCapture=false`, `idx`=slot) or a by-reference cell
// captured into `object[] __caps` (`isCapture=true`, `idx`=capture index).
func emitCellLoadMsil(fctx: in FuncCtx, insns: in List[MInsn],
                      isCapture: in Bool, idx: in Int): Unit {
  if isCapture {
    emitLoadVarMsil(fctx, insns, 0)
    insns.add(MLdcI4(v = idx))
    insns.add(MLdelemRef)
  } else {
    emitLoadVarMsil(fctx, insns, idx)
  }
}

// Store to element 0 of a hoisted-`var` cell, honouring compound operators
// (#1479 v2).  `AssEq` overwrites; a compound op reads the current element,
// combines it with the rhs (String `+=` concatenates), and writes back.
func emitCellAssignMsil(cctx: in CodegenCtx, fctx: in FuncCtx, insns: in List[MInsn],
                        isCapture: in Bool, idx: in Int, elemTy: in MsilType,
                        op: in AssignOp, value: in Expr): Unit {
  emitCellLoadMsil(fctx, insns, isCapture, idx)
  insns.add(MLdcI4(v = 0))
  match op {
    case AssEq -> {
      val _ = lowerExprMsil(cctx, fctx, insns, value)
    }
    case _ -> {
      emitCellLoadMsil(fctx, insns, isCapture, idx)
      insns.add(MLdcI4(v = 0))
      insns.add(MCallvirt(methodToken = cctx.tokListObjGetItem))
      castObjectToMsil(cctx, insns, elemTy)
      emitCompoundCombineMsil(cctx, fctx, insns, op, elemTy, value)
    }
  }
  boxIfNeededMsil(cctx, insns, elemTy)
  insns.add(MCallvirt(methodToken = cctx.tokListObjSetItem))
}

// ─────────────────────────────────────────────────────────────────────────────
// §5d. Assignment expression lowering.
// ─────────────────────────────────────────────────────────────────────────────

func lowerAssignExprMsil(
  cctx:   in CodegenCtx,
  fctx:   in FuncCtx,
  insns:  in List[MInsn],
  target: in Expr,
  op:     in AssignOp,
  value:  in Expr
): MsilType {
  match target.kind {
    case EPath(path) -> {
      val name = lastSegmentMsil(path)
      // Write to a `var` hoisted to a heap cell (#1479 v2) — checked before the
      // plain-slot path (the slot holds the cell reference, not the value).
      match mapGet(fctx.hoistedCellSlot, name) {
        case Some(cellSlot) -> {
          val elemTy = match mapGet(fctx.hoistedCellType, name) { case Some(t) -> t case None -> MObject }
          emitCellAssignMsil(cctx, fctx, insns, false, cellSlot, elemTy, op, value)
          return MVoid
        }
        case None -> {}
      }
      match mapGet(fctx.slots, name) {
        case Some(slot) -> {
          val ty =
            match mapGet(fctx.types, name) {
              case Some(t) -> t
              case None    -> MObject
            }
          // Assignment to an `out`/`inout` parameter: the slot holds a managed
          // pointer, so we store *through* it (`stind`) with the address pushed
          // before the value.  Compound ops dereference the current value first
          // (`ldarg; dup; ldind; <rhs>; <op>; stind`).  This bypasses the
          // by-value `emitStoreSlot` path below entirely.  See #1761.
          match mapGet(fctx.byrefSlotTypes, slot) {
            case Some(elemTy) -> {
              insns.add(MLdarg(slot = slot))
              match assignOpArithInsnMsil(op) {
                case None -> {
                  lowerExprMsil(cctx, fctx, insns, value)
                }
                case Some(arith) -> {
                  insns.add(MDup)
                  insns.add(MLdind(ty = elemTy))
                  lowerExprMsil(cctx, fctx, insns, value)
                  insns.add(arith)
                }
              }
              insns.add(MStind(ty = elemTy))
              return MVoid
            }
            case None -> ()
          }
          match op {
            case AssEq -> {
              lowerExprMsil(cctx, fctx, insns, value)
              emitStoreSlot(insns, slot, fctx.paramCount)
              if fctx.phaseBCtx.count > 0 {
                phaseBSyncLocalIfPromoted(fctx.phaseBCtx[0], insns, name, slot - fctx.paramCount)
              }
            }
            case _ -> {
              // Compound assignment to a local: load the current value, then
              // apply the operator honouring the slot's static type (String
              // `+=` concatenates rather than emitting a numeric `add`).  #1481.
              emitLoadSlot(insns, slot, fctx.paramCount)
              emitCompoundCombineMsil(cctx, fctx, insns, op, ty, value)
              emitStoreSlot(insns, slot, fctx.paramCount)
              if fctx.phaseBCtx.count > 0 {
                phaseBSyncLocalIfPromoted(fctx.phaseBCtx[0], insns, name, slot - fctx.paramCount)
              }
            }
          }
          MVoid
        }
        case None -> {
          // Write to a by-reference cell captured into `object[] __caps` (a
          // hoisted enclosing `var` reassigned from inside the closure) — #1479 v2.
          match mapGet(fctx.captureNameToIndex, name) {
            case Some(capIdx) -> {
              if nameListContains(fctx.captureCellNames, name) {
                val capTy = match mapGet(fctx.captureNameToType, name) { case Some(t) -> t case None -> MObject }
                emitCellAssignMsil(cctx, fctx, insns, true, capIdx, capTy, op, value)
                return MVoid
              }
            }
            case None -> {}
          }
          lowerExprMsil(cctx, fctx, insns, value)
          insns.add(MPop)
          MVoid
        }
      }
    }
    case EResult -> {
      // `result` is a contextual keyword. When used as an assignment target it
      // refers to a user-declared local named "result" (the same path that
      // `lowerExprMsil`'s EResult arm takes for reads).
      match mapGet(fctx.slots, "result") {
        case Some(slot) -> {
          val ty =
            match mapGet(fctx.types, "result") {
              case Some(t) -> t
              case None    -> MObject
            }
          match op {
            case AssEq -> {
              lowerExprMsil(cctx, fctx, insns, value)
              emitStoreSlot(insns, slot, fctx.paramCount)
            }
            case _ -> {
              emitLoadSlot(insns, slot, fctx.paramCount)
              emitCompoundCombineMsil(cctx, fctx, insns, op, ty, value)
              emitStoreSlot(insns, slot, fctx.paramCount)
            }
          }
          MVoid
        }
        case None -> {
          lowerExprMsil(cctx, fctx, insns, value)
          insns.add(MPop)
          MVoid
        }
      }
    }
    case EMember(recv, memberName) -> {
      // Field assignment: recv.field op= value.  The receiver is lowered first
      // (leaving the instance on the stack); the value is lowered inside each
      // branch so a compound op can read the current field via `dup; ldfld`
      // before combining.  Previously the `op` was ignored and `r.f += v` only
      // stored `v` (#1481).
      val recvTy = lowerExprMsil(cctx, fctx, insns, recv)
      match recvTy {
        case MClass(cls) -> {
          val key = cls + "/" + memberName
          match mapGet(cctx.fieldTokens, key) {
            case Some(tok) -> {
              match op {
                case AssEq -> {
                  val _vt = lowerExprMsil(cctx, fctx, insns, value)
                  insns.add(MStfld(fieldToken = tok))
                }
                case _ -> {
                  val fldTy = match mapGet(cctx.fieldMsilTypes, key) {
                                case Some(t) -> t
                                case None    -> MObject
                              }
                  insns.add(MDup)                      // recv, recv
                  insns.add(MLdfld(fieldToken = tok))  // recv, current
                  emitCompoundCombineMsil(cctx, fctx, insns, op, fldTy, value)
                  insns.add(MStfld(fieldToken = tok))  // recv, newval -> stored
                }
              }
            }
            case None -> {
              // Unknown field: lower the value for side effects, then balance
              // the stack (pop value + receiver).
              lowerExprMsil(cctx, fctx, insns, value)
              insns.add(MPop)
              insns.add(MPop)
            }
          }
        }
        case _ -> {
          lowerExprMsil(cctx, fctx, insns, value)
          insns.add(MPop)
          insns.add(MPop)
        }
      }
      MVoid
    }
    case EIndex(recv, indices) -> {
      // Indexed assignment: a[i] = v.  The bootstrap models every `[]`
      // receiver as List<object> (the EIndex read arm calls get_Item on
      // List<object> unconditionally), so the store mirrors it via set_Item.
      if indices.count == 0 {
        // Malformed index target (no index expression) — the parser does
        // not produce this, but keep the stack balanced if it ever appears.
        lowerExprMsil(cctx, fctx, insns, value)
        insns.add(MPop)
        MVoid
      } else {
        match op {
          case AssEq -> {
            // Dispatch on the receiver type: a Map[K, V] store goes through
            // Dictionary<object,object>::set_Item(key, value) — the key is an
            // arbitrary boxed value, not an int32 index.  Routing a Map store
            // through List::set_Item (the historical unconditional path) pushed
            // a non-int key where an int32 index was expected and the JIT
            // rejected the body as invalid (#1602).  A List[T] / `slice`
            // receiver keeps the List::set_Item(int32, value) path.
            val recvTy = lowerExprMsil(cctx, fctx, insns, recv)
            match recvTy {
              case MMapOf(_, _) -> {
                insns.add(MCastclass(typeToken = cctx.tokDictObjTypeSpec))
                val kTy = lowerExprMsil(cctx, fctx, insns, indices[0])
                boxIfNeededMsil(cctx, insns, kTy)
                val vTy = lowerExprMsil(cctx, fctx, insns, value)
                boxIfNeededMsil(cctx, insns, vTy)
                insns.add(MCallvirt(methodToken = cctx.tokDictObjSetItem))
              }
              case _ -> {
                // Stack for callvirt set_Item: this(List<object>), int32 index, !0 value.
                insns.add(MCastclass(typeToken = cctx.tokListObjTypeSpec))
                lowerExprMsil(cctx, fctx, insns, indices[0])
                val vTy = lowerExprMsil(cctx, fctx, insns, value)
                boxIfNeededMsil(cctx, insns, vTy)
                insns.add(MCallvirt(methodToken = cctx.tokListObjSetItem))
              }
            }
            MVoid
          }
          case _ -> {
            // Compound assignment to an indexed element (a[i] op= v): read the
            // current element via get_Item, apply the operator, store it back
            // via set_Item.  The receiver and index are evaluated once and
            // stashed in temps so the read and the write share them.
            //
            // List/Map elements are stored boxed and the receiver erases
            // primitive element types to `object` (`List[Int]` → MObject,
            // `Map[K,V]` → MMapOf(object,object)), so the element's arithmetic
            // type cannot come from the receiver.  Instead the rhs is evaluated
            // up-front: for a well-typed compound assignment the element and the
            // rhs share a type, so the rhs type drives the unbox / combine /
            // re-box.  The receiver's tracked type still selects the container
            // shape (Dictionary vs List), mirroring the `AssEq` indexed path.
            // #1481.
            val recvTy = lowerExprMsil(cctx, fctx, insns, recv)
            val isMap  = match recvTy { case MMapOf(_, _) -> true case _ -> false }
            // The container ref is stashed in an `object`-typed temp, so the
            // static List/Dictionary type is re-asserted with `castclass` after
            // every reload — the JIT verifier rejects a callvirt of get_Item /
            // set_Item on a bare `object` receiver (mirrors the read path's
            // immediate castclass at the EIndex read arm above).
            val cTok = if isMap { cctx.tokDictObjTypeSpec } else { cctx.tokListObjTypeSpec }
            insns.add(MCastclass(typeToken = cTok))
            val cSlot = allocSlotMsil(fctx, "__cidx_c_" + toString(fctx.slotTicker.count), MObject)
            emitStoreSlot(insns, cSlot, fctx.paramCount)
            // Index/key: boxed for a Map, raw int32 for a List.
            val kRawTy = lowerExprMsil(cctx, fctx, insns, indices[0])
            if isMap { boxIfNeededMsil(cctx, insns, kRawTy) }
            val kSlotTy = if isMap { MObject } else { MInt }
            val kSlot = allocSlotMsil(fctx, "__cidx_k_" + toString(fctx.slotTicker.count), kSlotTy)
            emitStoreSlot(insns, kSlot, fctx.paramCount)
            // Right-hand operand up-front — its type is the element type.
            val rTy = lowerExprMsil(cctx, fctx, insns, value)
            val rSlot = allocSlotMsil(fctx, "__cidx_r_" + toString(fctx.slotTicker.count), rTy)
            emitStoreSlot(insns, rSlot, fctx.paramCount)
            // current = container[key]  (boxed object)
            emitLoadSlot(insns, cSlot, fctx.paramCount)
            insns.add(MCastclass(typeToken = cTok))
            emitLoadSlot(insns, kSlot, fctx.paramCount)
            if isMap { insns.add(MCallvirt(methodToken = cctx.tokDictObjGetItem)) }
            else     { insns.add(MCallvirt(methodToken = cctx.tokListObjGetItem)) }
            materializeBoxedElemMsil(cctx, insns, rTy)
            emitCompoundCombineSlotMsil(cctx, fctx, insns, op, rTy, rSlot)
            boxIfNeededMsil(cctx, insns, rTy)
            val vSlot = allocSlotMsil(fctx, "__cidx_v_" + toString(fctx.slotTicker.count), MObject)
            emitStoreSlot(insns, vSlot, fctx.paramCount)
            emitLoadSlot(insns, cSlot, fctx.paramCount)
            insns.add(MCastclass(typeToken = cTok))
            emitLoadSlot(insns, kSlot, fctx.paramCount)
            emitLoadSlot(insns, vSlot, fctx.paramCount)
            if isMap { insns.add(MCallvirt(methodToken = cctx.tokDictObjSetItem)) }
            else     { insns.add(MCallvirt(methodToken = cctx.tokListObjSetItem)) }
            MVoid
          }
        }
      }
    }
    case _ -> {
      lowerExprMsil(cctx, fctx, insns, value)
      insns.add(MPop)
      MVoid
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5e. Match expression lowering.
//      Bootstrap-grade: literal, binding, constructor, and wildcard patterns.
// ─────────────────────────────────────────────────────────────────────────────

func lowerMatchExprMsil(
  cctx:      in CodegenCtx,
  fctx:      in FuncCtx,
  insns:     in List[MInsn],
  scrutinee: in Expr,
  arms:      in List[MatchArm]
): MsilType {
  val scrutTy   = lowerExprMsil(cctx, fctx, insns, scrutinee)
  val scrutSlot = allocSlotMsil(fctx,
    "__scrut_" + toString(fctx.slotTicker.count), scrutTy)
  emitStoreSlot(insns, scrutSlot, fctx.paramCount)

  val afterL   = freshLabelMsil(fctx)
  var hasAfterBranch = false

  // Pass 1: lower each arm (pattern test + bind + guard + body) into its own
  // instruction buffer so every arm's result MsilType is known before any is
  // committed.  Arms of a `match` join at `afterL`, so they must all leave the
  // stack at the same depth.  When the arms' source types are all real values
  // the depths already agree; but a Unit-typed match can mix arm shapes that
  // disagree in MSIL — `()` lowers to a pushed `List<object>` (ETuple) while a
  // void call like `println(...)` pushes nothing.  Committing those directly
  // desynced the stack at `afterL` and the JIT rejected the body as an invalid
  // program (#1602).  Mirrors the value/void reconciliation `lowerIfExprMsil`
  // already performs across its then/else branches.
  val armBuffers: List[List[MInsn]] = newList()
  val armTys:     List[MsilType]    = newList()
  val armNextLs:  List[Int]         = newList()
  val armRets:    List[Bool]        = newList()
  var i = 0
  while i < arms.count {
    val arm       = arms[i]
    val nextArmL  = freshLabelMsil(fctx)
    val armInsns: List[MInsn] = newList()
    lowerPatternTestMsil(cctx, fctx, armInsns, arm.pattern, scrutSlot, scrutTy, nextArmL)
    lowerPatternBindMsil(cctx, fctx, armInsns, arm.pattern, scrutSlot, scrutTy)
    match arm.guard {
      case Some(g) -> {
        lowerExprMsil(cctx, fctx, armInsns, g)
        armInsns.add(MBrFalse(label = nextArmL))
      }
      case None -> {}
    }
    val armTy = lowerExprOrBlockMsil(cctx, fctx, armInsns, arm.body)
    armBuffers.add(armInsns)
    armTys.add(armTy)
    armNextLs.add(nextArmL)
    armRets.add(endsWithReturnMsil(armInsns))
    i = i + 1
  }

  // The match value type is the common type of the arms that actually FALL
  // THROUGH to `afterL`.  Arms ending in `return` / `throw` exit the method and
  // never reach the join, so they neither contribute a type nor need their
  // stack depth reconciled — excluding them is what lets a `match` mix an
  // early-return arm with a value-producing fall-through arm (the recurring
  // shape in `maskUrlCredentials`).  Among the fall-through arms the result
  // degrades to MVoid if any is void: those push nothing, so the
  // value-producing fall-through arms must discard their result to agree.
  var anyVoid = false
  var firstFallTy: MsilType = MVoid
  var sawFall = false
  var av = 0
  while av < armTys.count {
    if not armRets[av] {
      if not sawFall {
        firstFallTy = armTys[av]
        sawFall = true
      }
      if armTys[av] == MVoid { anyVoid = true }
    }
    av = av + 1
  }
  val resultTy: MsilType = if not sawFall { MVoid }
                           else if anyVoid { MVoid }
                           else { firstFallTy }

  // Pass 2: splice each arm's buffer in order, normalising the stack depth.
  var k = 0
  while k < arms.count {
    val buf = armBuffers[k]
    var bi = 0
    while bi < buf.count {
      insns.add(buf[bi])
      bi = bi + 1
    }
    // A value-producing arm whose result the match discards (resultTy == MVoid)
    // must pop, unless the arm already terminated with `return` / `throw`
    // (nothing is live on the stack past a terminal instruction).
    if resultTy == MVoid and armTys[k] != MVoid and not armRets[k] {
      insns.add(MPop)
    }
    if not armRets[k] {
      insns.add(MBr(label = afterL))
      hasAfterBranch = true
    }
    insns.add(MLabel(id = armNextLs[k]))
    k = k + 1
  }

  // If no arm matched: panic (include function, scrutinee type, and arm count for diagnosis).
  val matchErrMsg = "Msil.Codegen: match not exhaustive in " + fctx.className + "." + fctx.funcName + " scr=" + msilTypeKey(scrutTy) + " arms=" + toString(arms.count)
  val msgTok = ctxInternUs(cctx.lctx, matchErrMsg)
  insns.add(MLdStr(token = msgTok))
  insns.add(MNewobj(ctorToken = cctx.tokExceptionCtor))
  insns.add(MThrow)

  // Only emit the after-label when at least one arm branched to it.  When
  // every arm ends with an explicit `return`, no MBr(afterL) is emitted and
  // the label would be unreachable — leaving it in place makes
  // endsWithReturnMsil return false (it stops at labels), which causes
  // lowerFuncMsil to append a valueless MRet for non-void functions,
  // triggering an InvalidProgramException from the JIT verifier.
  if hasAfterBranch {
    insns.add(MLabel(id =afterL))
  }
  resultTy
}

// Emit a runtime test for a pattern.  Jumps to `failLabel` if the test fails.
func lowerPatternTestMsil(
  cctx:       in CodegenCtx,
  fctx:       in FuncCtx,
  insns:      in List[MInsn],
  pat:        in Pattern,
  scrutSlot:  in Int,
  scrutTy:    in MsilType,
  failLabel:  in Int
): Unit {
  match pat.kind {
    case PWildcard -> {}
    case PBinding(pBindName, innerOpt) -> {
      match innerOpt {
        case Some(inner) -> {
          lowerPatternTestMsil(cctx, fctx, insns, inner, scrutSlot, scrutTy, failLabel)
        }
        case None -> {
          // `case Foo ->` with a single-segment path parses as PBinding
          // (the parser can't tell at that point whether `Foo` names a
          // local-bind target or a nullary union case).  If `pBindName`
          // matches a known nullary union case (local or imported via
          // `unionCaseCtorByName`), emit the isinst test that
          // PConstructor would have emitted — otherwise treat it as a
          // bind-anything pattern (existing semantics).
          val localCtorKey = fctx.pkgName + "." + pBindName
          val ctorKeyOpt =
            if cctx.recordCtorTokens.containsKey(localCtorKey) {
              Some(value = localCtorKey)
            } else {
              mapGet(cctx.unionCaseCtorByName, pBindName)
            }
          match ctorKeyOpt {
            case Some(ctorKey) -> {
              // `ctorKey` is the FQN of the case class (e.g. `Std.Core.Option_None`
              // for stdlib or `<pkg>.<union>$<case>` for in-bundle cases).
              // Emit an isinst type test.  For MGenericInst scrutinees (e.g.
              // Option[Int]) the case class is itself generic, so we must build
              // a closed TypeSpec using the concrete type args — a bare open
              // TypeRef would fail the isinst at runtime.
              emitLoadSlot(insns, scrutSlot, fctx.paramCount)
              match scrutTy {
                case MGenericInst(_, _, typeArgs) -> {
                  // Canonical representation: a nullary generic case carries the
                  // union's concrete type arguments (e.g. `Option.None` on an
                  // `Option[byte[]]` value is `Option_None<byte[]>`), matching the
                  // F#-compiled stdlib and the construction side (which threads
                  // `contextHintTyArgs`).  Test the scrutinee's concrete args.
                  insns.add(MIsinstGeneric(className = ctorKey, typeArgs = typeArgs))
                }
                case _ -> {
                  // For generic nullary cases (e.g. Option_None) with an untyped
                  // MObject scrutinee (produced by mapGet), we cannot form a
                  // closed TypeSpec for isinst.  In the bootstrap representation
                  // nullary union cases are null, so a null-equality check is
                  // both correct and avoids a runtime TypeLoadException.
                  val nGenericParams = match mapGet(cctx.caseTypeParamCount, ctorKey) {
                    case Some(n) -> n
                    case None    -> 0
                  }
                  if nGenericParams > 0 {
                    insns.add(MLdNull)
                    insns.add(MCeq)
                  } else {
                    insns.add(MIsinstByName(className = ctorKey))
                  }
                }
              }
              insns.add(MBrFalse(label = failLabel))
            }
            case None -> {}  // Variable bind — always matches, no test emitted.
          }
        }
      }
    }
    case PLiteral(lit) -> {
      emitLoadSlot(insns, scrutSlot, fctx.paramCount)
      match lit {
        case LInt(v, suffix, _) -> {
          match suffix {
            case I64 | U64 -> {
              insns.add(MLdcI8(v = v))
            }
            case _ -> {
              if v >= -2147483648i64 and v <= 2147483647i64 {
                insns.add(MLdcI4(v = longToInt(v)))
              } else {
                insns.add(MLdcI8(v = v))
              }
            }
          }
          insns.add(MCeq)
          insns.add(MBrFalse(label = failLabel))
        }
        case LBool(value) -> {
          if value {
            insns.add(MLdcI4(v = 1))
          } else {
            insns.add(MLdcI4(v = 0))
          }
          insns.add(MCeq)
          insns.add(MBrFalse(label = failLabel))
        }
        case LString(s) -> {
          val sTok = ctxInternUs(cctx.lctx, s)
          insns.add(MLdStr(token = sTok))
          insns.add(MCeq)
          insns.add(MBrFalse(label = failLabel))
        }
        case LChar(cp) -> {
          // A `Char` scrutinee is an i4 code point on the stack; compare
          // against the pattern's code point.
          insns.add(MLdcI4(v = cp))
          insns.add(MCeq)
          insns.add(MBrFalse(label = failLabel))
        }
        case LFloat(v, _, _) -> {
          // A `Float` scrutinee is an r8 on the stack; compare with `ceq`
          // against the pattern's value.  Previously this fell to the `_`
          // wildcard arm below and `pop`ped the scrutinee, making every
          // Float literal pattern match unconditionally (#1481 item 1).
          insns.add(MLdcR8(v = v))
          insns.add(MCeq)
          insns.add(MBrFalse(label = failLabel))
        }
        case LUnit -> {
          insns.add(MPop)
        }
        case _ -> {
          // LATENT GAP: LFloat/LTripleString/LRawString silently match unconditionally — see #1792.
          insns.add(MPop)
        }
      }
    }
    case PConstructor(head, args) -> {
      // Use isinst to check the case type; branch to failLabel if null.
      val caseName = lastSegmentMsil(head)
      val baseCls = match scrutTy {
        case MClass(cls)             -> cls
        case MGenericInst(_, fqn, _) -> fqn
        case _                       -> ""
      }
      if baseCls.length > 0 {
        // Local (in-bundle) union cases use "$" as separator; cross-assembly
        // stdlib cases compiled by the F# bootstrap use "_" (e.g. Option_Some).
        // MGenericInst scrutinees are always cross-assembly generic types.
        val sep = match scrutTy {
          case MGenericInst(_, _, _) -> "_"
          case _                     -> "$"
        }
        val caseClass = baseCls + sep + caseName
        emitLoadSlot(insns, scrutSlot, fctx.paramCount)
        // For MGenericInst scrutinees (e.g. Option[Int]) the case class is itself
        // a generic type (Option_None<T>).  We must build a closed TypeSpec using
        // the concrete type args; a bare open TypeRef would fail isinst at runtime.
        match scrutTy {
          case MGenericInst(_, _, typeArgs) -> {
            insns.add(MIsinstGeneric(className = caseClass, typeArgs = typeArgs))
          }
          case _ -> {
            insns.add(MIsinstByName(className = caseClass))
          }
        }
        insns.add(MBrFalse(label = failLabel))
      } else {
        // MObject scrutinee (e.g. an erased `slice` element from
        // `list.toArray()`, or a `mapGet` result): the static type doesn't name
        // the union, so derive the case class from the PATTERN's case name (the
        // same resolution the nullary PBinding path uses) and emit a real
        // isinst.  The old behaviour here — "any non-null value matches a
        // non-nullary constructor pattern" — made `case Reg(v)` match a `Git`
        // value pulled out of a `for x in list.toArray()` loop, silently taking
        // the wrong arm (#2126).
        val mobjLocalCtorKey = fctx.pkgName + "." + caseName
        val mobjCtorKeyOpt =
          if cctx.recordCtorTokens.containsKey(mobjLocalCtorKey) {
            Some(value = mobjLocalCtorKey)
          } else {
            mapGet(cctx.unionCaseCtorByName, caseName)
          }
        emitLoadSlot(insns, scrutSlot, fctx.paramCount)
        match mobjCtorKeyOpt {
          case Some(mobjCtorKey) -> {
            val mobjNGen = match mapGet(cctx.caseTypeParamCount, mobjCtorKey) {
              case Some(n) -> n
              case None    -> 0
            }
            if mobjNGen > 0 {
              // Generic case with an erased scrutinee: we can't form a closed
              // TypeSpec for isinst, so keep the bootstrap non-null check.
              insns.add(MBrFalse(label = failLabel))
            } else {
              insns.add(MIsinstByName(className = mobjCtorKey))
              insns.add(MBrFalse(label = failLabel))
            }
          }
          case None -> {
            // Truly unknown case name: fall back to the non-null check.
            insns.add(MBrFalse(label = failLabel))
          }
        }
      }
    }
    case PTuple(_) -> {
      // Tuple patterns always match structurally; no runtime type test needed.
    }
    case POr(patterns) -> {
      val succeedL = freshLabelMsil(fctx)
      var ai = 0
      while ai < patterns.count {
        val nextAltL = freshLabelMsil(fctx)
        lowerPatternTestMsil(cctx, fctx, insns, patterns[ai],
                             scrutSlot, scrutTy, nextAltL)
        insns.add(MBr(label = succeedL))
        insns.add(MLabel(id =nextAltL))
        ai = ai + 1
      }
      insns.add(MBr(label = failLabel))
      insns.add(MLabel(id =succeedL))
    }
    case PError -> {}
  }
}

// Bind pattern variables after a successful match.
func lowerPatternBindMsil(
  cctx:      in CodegenCtx,
  fctx:      in FuncCtx,
  insns:     in List[MInsn],
  pat:       in Pattern,
  scrutSlot: in Int,
  scrutTy:   in MsilType
): Unit {
  match pat.kind {
    case PWildcard -> {}
    case PBinding(name, innerOpt) -> {
      match innerOpt {
        case Some(inner) -> {
          emitLoadSlot(insns, scrutSlot, fctx.paramCount)
          val bindSlot = allocSlotMsil(fctx, name, scrutTy)
          emitStoreSlot(insns, bindSlot, fctx.paramCount)
          lowerPatternBindMsil(cctx, fctx, insns, inner, bindSlot, scrutTy)
        }
        case None -> {
          // `case Foo ->` with a single-segment path parses as PBinding — the
          // parser cannot tell whether `Foo` is a nullary union case or a new
          // variable binding.  Mirror lowerPatternTestMsil: if `name` resolves
          // to a known nullary union case, skip slot allocation so that later
          // EPath("Foo") references are not hijacked by an uninitialized local.
          val localCtorKey = fctx.pkgName + "." + name
          val isNullaryCase =
            cctx.recordCtorTokens.containsKey(localCtorKey) or
            cctx.unionCaseCtorByName.containsKey(name)
          if not isNullaryCase {
            emitLoadSlot(insns, scrutSlot, fctx.paramCount)
            val bindSlot = allocSlotMsil(fctx, name, scrutTy)
            emitStoreSlot(insns, bindSlot, fctx.paramCount)
          }
        }
      }
    }
    case PLiteral(_) -> {}
    case PConstructor(head, fields) -> {
      val caseName = lastSegmentMsil(head)
      val baseCls = match scrutTy {
        case MClass(cls)             -> cls
        case MGenericInst(_, fqn, _) -> fqn
        case _                       -> ""
      }
      if baseCls.length > 0 {
        // Local (in-bundle) union cases use "$" as separator; cross-assembly
        // stdlib cases compiled by the F# bootstrap use "_" (e.g. Option_Some).
        val sep = match scrutTy {
          case MGenericInst(_, _, _) -> "_"
          case _                     -> "$"
        }
        val caseClass = baseCls + sep + caseName
        // For generic union scrutinees (e.g. Option[Int]) the case class is
        // also generic (e.g. Option_Some<T>).  The local variable must be
        // declared with the closed instantiation (GENERICINST CLASS TypeRef
        // <Int32>) rather than the bare open-generic class — the CLR rejects
        // open-generic types in LocalVarSig with TypeLoadException.
        val castTy = match scrutTy {
          case MGenericInst(_, _, typeArgs) -> {
            val dotIdx = caseClass.lastIndexOf(".")
            val caseKey = if dotIdx < 0 { "" }
                          else { caseClass.substring(0, dotIdx) + "/" + caseClass }
            match mapGet(cctx.ffiTypeRefs, caseKey) {
              case Some(refRow) ->
                MGenericInst(typeRefCode = tdrTypeRef(refRow),
                             headFqn = caseClass, typeArgs = typeArgs)
              case None -> MClass(className = caseClass)
            }
          }
          case _ -> MClass(className = caseClass)
        }
        // Load scrutinee; for generic case types emit MCastclassGeneric to
        // narrow the stack type from the open union type (e.g. Option<Int32>)
        // to the closed case type (e.g. Option_Some<Int32>) before stloc.
        // MCastclassGeneric defers TypeSpec construction to Phase 5 lowering
        // so the TypeDef for local type args (e.g. Keyword from lexer.l) is
        // present when the blob is built.
        emitLoadSlot(insns, scrutSlot, fctx.paramCount)
        match castTy {
          case MGenericInst(_, _, typeArgs) ->
            insns.add(MCastclassGeneric(className = caseClass, typeArgs = typeArgs))
          case _ -> {}
        }
        val castSlot = allocSlotMsil(fctx,
          "__cast_" + caseName + "_" + toString(fctx.slotTicker.count), castTy)
        emitStoreSlot(insns, castSlot, fctx.paramCount)
        // Bind each named field by reading the pre-computed field token.
        // Try the binding variable name first (works when the pattern uses the
        // declared field name, e.g. `case Rec(fieldName)`).  Fall back to the
        // positional key "/field<i>" for cross-assembly cases where the user
        // wrote a binding alias (`case Some(x)` instead of `case Some(value)`).
        var fi = 0
        while fi < fields.count {
          match fields[fi].kind {
            case PBinding(fname, _) -> {
              val fByName = cctx.fieldTokens.containsKey(caseClass + "/" + fname)
              val fTok =
                if fByName {
                  match mapGet(cctx.fieldTokens, caseClass + "/" + fname) {
                    case Some(t) -> t
                    case None    -> 0
                  }
                } else {
                  match mapGet(cctx.fieldTokens, caseClass + "/field" + toString(fi)) {
                    case Some(t) -> t
                    case None    -> 0
                  }
                }
              if fTok > 0 {
                val sigLookupKey =
                  if fByName { caseClass + "/" + fname }
                  else { caseClass + "/field" + toString(fi) }
                val fSig = match mapGet(cctx.fieldSigBytes, sigLookupKey) {
                  case Some(sigBytes) -> sigBytes
                  case None           -> buildFieldSig(MObject)
                }
                var vi = -1
                match castTy {
                  case MGenericInst(_, _, typeArgs) -> {
                    vi = match mapGet(cctx.fieldVarIndices, sigLookupKey) {
                      case Some(v) -> v
                      case None    -> -1
                    }
                  }
                  case _ -> {}
                }
                // For generic case classes (e.g. Option_Some<Keyword>) use
                // MLdfldGeneric so the TypeSpec and TypeSpec-parented MemberRef
                // are built at Phase 5 lowering time, when all TypeDefs are
                // present.  For non-generic cases use the pre-computed fTok.
                val actualFieldName =
                  if fByName { fname }
                  else {
                    match mapGet(cctx.fieldDeclaredNames, sigLookupKey) {
                      case Some(n) -> n
                      case None    -> fname
                    }
                  }
                var concreteFieldTy: MsilType = match mapGet(cctx.fieldMsilTypes, sigLookupKey) {
                  case Some(ty) -> ty
                  case None     -> MObject
                }
                if vi >= 0 {
                  match castTy {
                    case MGenericInst(_, _, typeArgs) -> {
                      concreteFieldTy = typeArgs[vi]
                    }
                    case _ -> {}
                  }
                }
                // A `Unit`-typed payload (e.g. binding the Ok value of
                // `Result[Unit, E]`) has no distinct runtime value; it is held
                // as `null`/object.  Binding it as `MVoid` would allocate a
                // void local and produce an invalid program, so erase to object.
                match concreteFieldTy {
                  case MVoid -> { concreteFieldTy = MObject }
                  case _     -> {}
                }
                emitLoadSlot(insns, castSlot, fctx.paramCount)
                match castTy {
                  case MGenericInst(_, _, typeArgs) ->
                    insns.add(MLdfldGeneric(baseClassName = caseClass, typeArgs = typeArgs,
                                            fieldName = actualFieldName, fieldSig = fSig))
                  case _ -> {
                    // castSlot is typed as `object` in LocalVarSig (MClass encodes as
                    // ELEMENT_TYPE_OBJECT = 0x1C), so the JIT sees `object` on the stack.
                    // castclass narrows to the concrete case class so ldfld verifies (#1442).
                    insns.add(MCastclassByName(className = caseClass))
                    insns.add(MLdfld(fieldToken = fTok))
                  }
                }
                val fSlot = allocSlotMsil(fctx, fname, concreteFieldTy)
                emitStoreSlot(insns, fSlot, fctx.paramCount)
                // Recurse into any inner pattern (e.g. `case Some(x @ (a, b))`).
                match fields[fi].kind {
                  case PBinding(_, Some(innerPat)) ->
                    lowerPatternBindMsil(cctx, fctx, insns, innerPat, fSlot, concreteFieldTy)
                  case _ -> {}
                }
              }
            }
            case PTuple(_) -> {
              // Positional field fi carries a tuple value; load it and recurse.
              val ptPosFldKey = caseClass + "/field" + toString(fi)
              val ptFTok = match mapGet(cctx.fieldTokens, ptPosFldKey) {
                case Some(t) -> t
                case None    -> 0
              }
              if ptFTok > 0 {
                var ptVi = -1
                match castTy {
                  case MGenericInst(_, _, typeArgs) -> {
                    ptVi = match mapGet(cctx.fieldVarIndices, ptPosFldKey) {
                      case Some(v) -> v
                      case None    -> -1
                    }
                  }
                  case _ -> {}
                }
                val ptFSig = match mapGet(cctx.fieldSigBytes, ptPosFldKey) {
                  case Some(s) -> s
                  case None    -> buildFieldSig(MObject)
                }
                val ptActualFieldName = match mapGet(cctx.fieldDeclaredNames, ptPosFldKey) {
                  case Some(n) -> n
                  case None    -> "field" + toString(fi)
                }
                var ptFieldTy: MsilType = match mapGet(cctx.fieldMsilTypes, ptPosFldKey) {
                  case Some(ty) -> ty
                  case None     -> MObject
                }
                if ptVi >= 0 {
                  match castTy {
                    case MGenericInst(_, _, typeArgs) -> {
                      ptFieldTy = typeArgs[ptVi]
                    }
                    case _ -> {}
                  }
                }
                emitLoadSlot(insns, castSlot, fctx.paramCount)
                match castTy {
                  case MGenericInst(_, _, typeArgs) ->
                    insns.add(MLdfldGeneric(baseClassName = caseClass, typeArgs = typeArgs,
                                            fieldName = ptActualFieldName, fieldSig = ptFSig))
                  case _ -> {
                    insns.add(MCastclassByName(className = caseClass))
                    insns.add(MLdfld(fieldToken = ptFTok))
                  }
                }
                val ptFldSlot = allocSlotMsil(fctx,
                  "__tup_fld_" + toString(fi) + "_" + toString(fctx.slotTicker.count),
                  ptFieldTy)
                emitStoreSlot(insns, ptFldSlot, fctx.paramCount)
                lowerPatternBindMsil(cctx, fctx, insns, fields[fi], ptFldSlot, ptFieldTy)
              }
            }
            case _ -> {}
          }
          fi = fi + 1
        }
      } else {
        // MObject scrutinee (e.g. from mapGet): bind each named field directly
        // to the scrutinee slot.  In the bootstrap representation the raw
        // mapGet value IS the inner value (e.g. Some.value), so no field load
        // is required — we store the scrutinee slot into the binding variable.
        // TODO(#1825): bootstrap runtime assumption — mapGet returns the
        // inner value unboxed; revisit when the F# shim is eliminated.
        var fi = 0
        while fi < fields.count {
          match fields[fi].kind {
            case PBinding(fname, innerOpt) -> {
              val fSlot = allocSlotMsil(fctx, fname, MObject)
              emitLoadSlot(insns, scrutSlot, fctx.paramCount)
              emitStoreSlot(insns, fSlot, fctx.paramCount)
              match innerOpt {
                case Some(innerPat) ->
                  lowerPatternBindMsil(cctx, fctx, insns, innerPat, fSlot, MObject)
                case None -> {}
              }
            }
            case _ -> {}
          }
          fi = fi + 1
        }
      }
    }
    case PTuple(tupleSubPats) -> {
      // Extract each element from the List<object> tuple representation.
      var pti = 0
      while pti < tupleSubPats.count {
        emitLoadSlot(insns, scrutSlot, fctx.paramCount)
        insns.add(MCastclass(typeToken = cctx.tokListObjTypeSpec))
        insns.add(MLdcI4(v = pti))
        insns.add(MCallvirt(methodToken = cctx.tokListObjGetItem))
        val ptElemSlot = allocSlotMsil(fctx,
          "__tup_" + toString(pti) + "_" + toString(fctx.slotTicker.count), MObject)
        emitStoreSlot(insns, ptElemSlot, fctx.paramCount)
        lowerPatternBindMsil(cctx, fctx, insns, tupleSubPats[pti], ptElemSlot, MObject)
        pti = pti + 1
      }
    }
    case POr(_) -> {}
    case PError -> {}
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5f. Interpolated string lowering.
// ─────────────────────────────────────────────────────────────────────────────

func lowerInterpolatedMsil(
  cctx:     in CodegenCtx,
  fctx:     in FuncCtx,
  insns:    in List[MInsn],
  segments: in List[InterpolatedSegment]
): MsilType {
  if segments.count == 0 {
    val emptyTok = ctxInternUs(cctx.lctx, "")
    insns.add(MLdStr(token = emptyTok))
    return MString
  }

  // Lower each segment to a string, then fold left via String.Concat.
  // We track an accumulator on the stack by chaining Concat2 calls.
  var i = 0
  var hasFirst = false
  while i < segments.count {
    match segments[i] {
      case ISText(text, _) -> {
        val tok = ctxInternUs(cctx.lctx, text)
        insns.add(MLdStr(token = tok))
      }
      case ISExpr(e) -> {
        val eTy = lowerExprMsil(cctx, fctx, insns, e)
        // Convert to string.
        if isValueType(eTy) {
          boxIfNeededMsil(cctx, insns, eTy)
          insns.add(MCallvirt(methodToken = cctx.tokObjToString))
        } else {
          match eTy {
            case MString -> {}
            case MVoid   -> {
              val emptyTok2 = ctxInternUs(cctx.lctx, "")
              insns.add(MLdStr(token = emptyTok2))
            }
            case _ -> {
              insns.add(MCallvirt(methodToken = cctx.tokObjToString))
            }
          }
        }
      }
    }
    // If we have an accumulator from a previous segment, concat.
    if hasFirst {
      insns.add(MCall(methodToken = cctx.tokConcat2))
    } else {
      hasFirst = true
    }
    i = i + 1
  }
  MString
}

// ─────────────────────────────────────────────────────────────────────────────
// §5g. Emit a panic from a string already on the stack.
// ─────────────────────────────────────────────────────────────────────────────

func emitMsilPanicFromStack(cctx: in CodegenCtx, insns: in List[MInsn]): Unit {
  insns.add(MNewobj(ctorToken = cctx.tokExceptionCtor))
  insns.add(MThrow)
}

// ─────────────────────────────────────────────────────────────────────────────
// §5h. Call lowering.
// ─────────────────────────────────────────────────────────────────────────────

// Lower a single call argument (positional or named).
func lowerCallArgMsil(cctx: in CodegenCtx, fctx: in FuncCtx,
                      insns: in List[MInsn], arg: in CallArg): MsilType {
  match arg {
    case CAPositional(e)    -> lowerExprMsil(cctx, fctx, insns, e)
    case CANamed(_, e, _)   -> lowerExprMsil(cctx, fctx, insns, e)
  }
}

// The underlying expression of a call argument (positional or named).  Used by
// the `out`/`inout` call path, which needs the argument as an lvalue. #1761.
func callArgExpr(arg: in CallArg): Expr {
  match arg {
    case CAPositional(e)  -> e
    case CANamed(_, e, _) -> e
  }
}

// Reorder a record/union-case constructor's arguments to field-declaration
// order (#1730).  A named-argument call (`R(c = …, a = …)`) may list fields in
// any order, but the constructor `newobj` consumes them positionally in
// declaration order — lowering them in call-site order stored each value into
// the wrong field slot, producing invalid IL / cross-typed fields.  Using the
// `<ctorKey>/field<pos>` → declared-name map (`fieldDeclaredNames`, populated
// for both in-bundle and restored records), build a new arg list where slot `i`
// holds the call arg whose name matches field `i`.  Returns `args` unchanged
// when: any arg is positional (no reorder possible/needed — already in order),
// or the field-name map is absent for this ctor (defensive — preserves the
// historical positional behaviour).
func reorderCtorNamedArgs(cctx: in CodegenCtx, ctorKey: in String,
                          args: in List[CallArg]): List[CallArg] {
  if args.count == 0 { return args }
  // Build name → arg index from the call site; bail to positional if any arg
  // is unnamed (a mixed/positional call is already in declaration order).
  val nameToArg: Map[String, CallArg] = newMap()
  var i = 0
  while i < args.count {
    match args[i] {
      case CANamed(nm, _, _) -> {
        if nameToArg.containsKey(nm) { return args }  // dup name — leave as-is
        nameToArg.add(nm, args[i])
      }
      case CAPositional(_)   -> { return args }
    }
    i = i + 1
  }
  // Reassemble in field-declaration order using the positional name map.
  val ordered: List[CallArg] = newList()
  var fp = 0
  while fp < args.count {
    val byPosKey = ctorKey + "/field" + toString(fp)
    match mapGet(cctx.fieldDeclaredNames, byPosKey) {
      case None -> return args   // no field-order info — preserve current behaviour
      case Some(fname) -> match mapGet(nameToArg, fname) {
        case Some(a) -> ordered.add(a)
        case None    -> return args   // a field has no matching arg — bail safely
      }
    }
    fp = fp + 1
  }
  ordered
}

// Lower a function call expression.
pub func lowerCallMsil(
  cctx:  in CodegenCtx,
  fctx:  in FuncCtx,
  insns: in List[MInsn],
  fn:    in Expr,
  args:  in List[CallArg]
): MsilType {
  match fn.kind {
    case EPath(path) -> {
      val funcName = lastSegmentMsil(path)
      lowerBuiltinOrStaticCallMsil(cctx, fctx, insns, funcName, path, args)
    }
    case ETypeApp(innerFn, _) -> {
      lowerCallMsil(cctx, fctx, insns, innerFn, args)
    }
    case EMember(recv, memberName) -> {
      lowerMethodCallMsil(cctx, fctx, insns, recv, memberName, args)
    }
    case _ -> {
      var i = 0
      while i < args.count {
        lowerCallArgMsil(cctx, fctx, insns, args[i])
        i = i + 1
      }
      MObject
    }
  }
}

// Lower a builtin or intra-package static call.
func lowerBuiltinOrStaticCallMsil(
  cctx:     in CodegenCtx,
  fctx:     in FuncCtx,
  insns:    in List[MInsn],
  funcName: in String,
  path:     in ModulePath,
  args:     in List[CallArg]
): MsilType {
  if funcName == "println" {
    if args.count > 0 {
      val argTy = lowerCallArgMsil(cctx, fctx, insns, args[0])
      match argTy {
        case MInt    -> insns.add(MCall(methodToken = cctx.tokWriteLineInt))
        case MLong   -> insns.add(MCall(methodToken = cctx.tokWriteLineLong))
        case MDouble -> insns.add(MCall(methodToken = cctx.tokWriteLineDbl))
        case MBool   -> insns.add(MCall(methodToken = cctx.tokWriteLineBool))
        case MChar   -> insns.add(MCall(methodToken = cctx.tokWriteLineInt))
        case MVoid   -> {
          val emptyTok = ctxInternUs(cctx.lctx, "")
          insns.add(MLdStr(token = emptyTok))
          insns.add(MCall(methodToken = cctx.tokWriteLineStr))
        }
        case _ -> insns.add(MCall(methodToken = cctx.tokWriteLineStr))
      }
    } else {
      val emptyTok = ctxInternUs(cctx.lctx, "")
      insns.add(MLdStr(token = emptyTok))
      insns.add(MCall(methodToken = cctx.tokWriteLineStr))
    }
    MVoid
  } else if funcName == "print" {
    if args.count > 0 {
      val argTy = lowerCallArgMsil(cctx, fctx, insns, args[0])
      match argTy {
        case MString -> insns.add(MCall(methodToken = cctx.tokWriteStr))
        case MVoid -> {
          val emptyTok = ctxInternUs(cctx.lctx, "")
          insns.add(MLdStr(token = emptyTok))
          insns.add(MCall(methodToken = cctx.tokWriteStr))
        }
        case _ -> {
          // Box value type and call ToString, then Write(string).
          boxIfNeededMsil(cctx, insns, argTy)
          insns.add(MCallvirt(methodToken = cctx.tokObjToString))
          insns.add(MCall(methodToken = cctx.tokWriteStr))
        }
      }
    } else {
      val emptyTok = ctxInternUs(cctx.lctx, "")
      insns.add(MLdStr(token = emptyTok))
      insns.add(MCall(methodToken = cctx.tokWriteStr))
    }
    MVoid
  } else if funcName == "panic" {
    if args.count > 0 {
      val _ = lowerCallArgMsil(cctx, fctx, insns, args[0])
    } else {
      val panicTok = ctxInternUs(cctx.lctx, "panic")
      insns.add(MLdStr(token = panicTok))
    }
    emitMsilPanicFromStack(cctx, insns)
    MVoid
  } else if funcName == "assert" {
    if args.count > 0 {
      val skipL = freshLabelMsil(fctx)
      lowerCallArgMsil(cctx, fctx, insns, args[0])
      insns.add(MBrTrue(label = skipL))
      if args.count > 1 {
        val _ = lowerCallArgMsil(cctx, fctx, insns, args[1])
      } else {
        val failTok = ctxInternUs(cctx.lctx, "assertion failed")
        insns.add(MLdStr(token = failTok))
      }
      emitMsilPanicFromStack(cctx, insns)
      insns.add(MLabel(id =skipL))
    }
    MVoid
  } else if funcName == "toString" {
    if args.count > 0 {
      val argTy = lowerCallArgMsil(cctx, fctx, insns, args[0])
      match argTy {
        case MString -> {}
        case MVoid -> {
          val emptyTok = ctxInternUs(cctx.lctx, "")
          insns.add(MLdStr(token = emptyTok))
        }
        case MDouble -> {
          // Covers both Double and Float: the self-hosted type system maps Lyric's
          // Float to MDouble (see lowerTypeMsil, "Float" -> MDouble), so no
          // separate MFloat arm is needed here.
          val tmpSlot = allocSlotMsil(fctx, "__tostring_dbl_tmp", MDouble)
          emitStoreSlot(insns, tmpSlot, fctx.paramCount)
          insns.add(MLdloca(slot = tmpSlot - fctx.paramCount))
          insns.add(MCall(methodToken = cctx.tokCultureInfoInvariantGet))
          insns.add(MCall(methodToken = cctx.tokDoubleToStringInv))
        }
        case MValueTypeRef(typeRefCode, clrFqn) -> {
          if clrFqn == "System.DateTime" {
            val tmpSlot = allocSlotMsil(fctx, "__tostring_dt_tmp", argTy)
            emitStoreSlot(insns, tmpSlot, fctx.paramCount)
            insns.add(MLdloca(slot = tmpSlot - fctx.paramCount))
            insns.add(MLdStr(token = ctxInternUs(cctx.lctx, "o")))
            insns.add(MCall(methodToken = cctx.tokDateTimeToStringFmt))
          } else {
            // typeRefCode is TypeDefOrRef-encoded (ECMA-335 §II.23.2.8) with TypeRef
            // tag 1: encoded = (row << 2) | 1.  Strip the tag to get the 1-based
            // TypeRef row, then build a 0x01xxxxxx metadata token (ECMA-335 §II.22.38).
            // This invariant holds for all extern value types (no user-defined Lyric
            // value types carry a TypeDef or TypeSpec code here today).
            val rawRow = (typeRefCode - 1) / 4
            insns.add(MBox(typeToken = 16777216 + rawRow))
            insns.add(MCallvirt(methodToken = cctx.tokObjToString))
          }
        }
        case _ -> {
          boxIfNeededMsil(cctx, insns, argTy)
          insns.add(MCallvirt(methodToken = cctx.tokObjToString))
        }
      }
    } else {
      val emptyTok = ctxInternUs(cctx.lctx, "")
      insns.add(MLdStr(token = emptyTok))
    }
    MString
  } else if funcName == "intToLong" {
    if args.count > 0 {
      lowerCallArgMsil(cctx, fctx, insns, args[0])
    }
    insns.add(MConvI8)
    MLong
  } else if funcName == "longToInt" {
    if args.count > 0 {
      lowerCallArgMsil(cctx, fctx, insns, args[0])
    }
    insns.add(MConvI4)
    MInt
  } else if funcName == "charToInt" {
    if args.count > 0 {
      lowerCallArgMsil(cctx, fctx, insns, args[0])
    }
    // Char is I4 in MSIL; no conversion needed.
    MInt
  } else if funcName == "intToDouble" {
    if args.count > 0 {
      lowerCallArgMsil(cctx, fctx, insns, args[0])
    }
    insns.add(MConvR8)
    MDouble
  } else if funcName == "default" {
    insns.add(MLdNull)
    MObject
  } else if funcName == "newList" {
    // Emit: newobj instance void class List`1<object>::.ctor()
    insns.add(MNewobj(ctorToken = cctx.tokListObjCtor))
    MObject
  } else if funcName == "newMap" {
    // Emit: newobj instance void class Dictionary`2<object,object>::.ctor()
    insns.add(MNewobj(ctorToken = cctx.tokDictObjCtor))
    MMapOf(keyTy = MObject, valTy = MObject)
  } else if funcName == "mapGet" {
    // `mapGet(m, key): Option[V]` — emit `if m.ContainsKey(key) {
    // Some(value = m[key]) } else { None }` with the concrete `Option[V]`
    // instantiation, so a consumer `match` finds the right arm (#1727).  `V`
    // comes from the call's context hint (the surrounding `Option[V]` type),
    // then the map argument's tracked value type (`Map[K, ValueType]` →
    // `MMapOf(_, valTy)`, #1835), and finally `object` when neither is known
    // (a correctly-shaped `Option<object>`, still a real Option).  The
    // map-type fallback is what makes a hint-less `match mapGet(m, k)` over a
    // value-type-valued map produce `Option[Int]` rather than an
    // `Option<object>` whose boxed payload faults when used as `Int`.
    if args.count >= 2 {
      // Stash m and key in temp locals — each is consumed by both ContainsKey
      // and get_Item, and the arg exprs may have side effects.
      val mSlot = allocSlotMsil(fctx, "__mapget_m_" + toString(fctx.slotTicker.count), MObject)
      val mArgTy = lowerCallArgMsil(cctx, fctx, insns, args[0])
      emitStoreSlot(insns, mSlot, fctx.paramCount)
      val mapValTy = match mArgTy {
        case MMapOf(_, vt) -> vt
        case _             -> MObject
      }
      val vTy: MsilType =
        if fctx.contextHintTyArgs.count > 0 { fctx.contextHintTyArgs[0] }
        else { mapValTy }
      val kSlot = allocSlotMsil(fctx, "__mapget_k_" + toString(fctx.slotTicker.count), MObject)
      val kArgTy = lowerCallArgMsil(cctx, fctx, insns, args[1])
      boxIfNeededMsil(cctx, insns, kArgTy)
      emitStoreSlot(insns, kSlot, fctx.paramCount)

      val elseL = freshLabelMsil(fctx)
      val endL  = freshLabelMsil(fctx)

      // ContainsKey(m, key)
      emitLoadSlot(insns, mSlot, fctx.paramCount)
      emitLoadSlot(insns, kSlot, fctx.paramCount)
      insns.add(MCallvirt(methodToken = cctx.tokDictObjContainsKey))
      insns.add(MBrFalse(label = elseL))

      // then: Some(value = (V) m[key])
      emitLoadSlot(insns, mSlot, fctx.paramCount)
      emitLoadSlot(insns, kSlot, fctx.paramCount)
      insns.add(MCallvirt(methodToken = cctx.tokDictObjGetItem))   // -> object
      castObjectToMsil(cctx, insns, vTy)
      val someArgTys: List[MsilType] = newList()
      someArgTys.add(vTy)
      val someCtx: List[MsilType] = newList()
      someCtx.add(vTy)
      val someParent: List[MsilType] = newList()
      val someOk = buildGenericCaseCtorTok(cctx, "Std.Core.Option_Some",
                                           someArgTys, someCtx, someParent, insns)
      insns.add(MBr(label = endL))

      // else: None
      insns.add(MLabel(id = elseL))
      val noneArgTys: List[MsilType] = newList()
      val noneCtx: List[MsilType] = newList()
      noneCtx.add(vTy)
      val noneParent: List[MsilType] = newList()
      val noneOk = buildGenericCaseCtorTok(cctx, "Std.Core.Option_None",
                                           noneArgTys, noneCtx, noneParent, insns)

      insns.add(MLabel(id = endL))
      if someOk == 1 and someParent.count > 0 { someParent[0] }
      else if noneOk == 1 and noneParent.count > 0 { noneParent[0] }
      else { MObject }
    } else {
      insns.add(MLdNull)
      MObject
    }
  } else if funcName == "format1" {
    if args.count >= 2 {
      lowerCallArgMsil(cctx, fctx, insns, args[0])
      val a1Ty = lowerCallArgMsil(cctx, fctx, insns, args[1])
      boxIfNeededMsil(cctx, insns, a1Ty)
      insns.add(MCall(methodToken = cctx.tokStringFormat1))
    } else if args.count == 1 {
      val _ = lowerCallArgMsil(cctx, fctx, insns, args[0])
    } else {
      val emptyTok = ctxInternUs(cctx.lctx, "")
      insns.add(MLdStr(token = emptyTok))
    }
    MString
  } else if funcName == "format2" {
    if args.count >= 3 {
      lowerCallArgMsil(cctx, fctx, insns, args[0])
      val a1Ty2 = lowerCallArgMsil(cctx, fctx, insns, args[1])
      boxIfNeededMsil(cctx, insns, a1Ty2)
      val a2Ty2 = lowerCallArgMsil(cctx, fctx, insns, args[2])
      boxIfNeededMsil(cctx, insns, a2Ty2)
      insns.add(MCall(methodToken = cctx.tokStringFormat2))
    } else if args.count >= 1 {
      val _ = lowerCallArgMsil(cctx, fctx, insns, args[0])
    } else {
      val emptyTok = ctxInternUs(cctx.lctx, "")
      insns.add(MLdStr(token = emptyTok))
    }
    MString
  } else if funcName == "format3" {
    if args.count >= 4 {
      lowerCallArgMsil(cctx, fctx, insns, args[0])
      val a1Ty3 = lowerCallArgMsil(cctx, fctx, insns, args[1])
      boxIfNeededMsil(cctx, insns, a1Ty3)
      val a2Ty3 = lowerCallArgMsil(cctx, fctx, insns, args[2])
      boxIfNeededMsil(cctx, insns, a2Ty3)
      val a3Ty3 = lowerCallArgMsil(cctx, fctx, insns, args[3])
      boxIfNeededMsil(cctx, insns, a3Ty3)
      insns.add(MCall(methodToken = cctx.tokStringFormat3))
    } else if args.count >= 1 {
      val _ = lowerCallArgMsil(cctx, fctx, insns, args[0])
    } else {
      val emptyTok = ctxInternUs(cctx.lctx, "")
      insns.add(MLdStr(token = emptyTok))
    }
    MString
  } else {
    // Record constructor call: EnglishGreeter(field1, field2, ...) → newobj .ctor.
    // Check recordCtorTokens before funcTokens so that record names are handled
    // even when they shadow a same-named function (which is disallowed by the
    // type checker anyway).
    //
    // Three-step resolution (#1183 codegen port + cross-pkg record fix):
    //   1. Local pkg key `<pkg>.<name>` — same-package record / union case.
    //   2. Cross-package union-case lookup via `unionCaseCtorByName[name]`
    //      — yields the FQN ctor key for an imported union case, e.g.
    //      `Std.Core.Option$Some`.
    //   3. Cross-package record lookup via `typeFqnByName[name]`
    //      — resolves imported records like `CfgGateFile(...)` when
    //      called from a different package.  Prevents arg-only codegen
    //      (which leaves args on the stack without a newobj, causing a
    //      stack-height mismatch that the JIT reports as InvalidProgramException).
    val localCtorKey = fctx.pkgName + "." + funcName
    val ctorKey =
      if cctx.recordCtorTokens.containsKey(localCtorKey) {
        localCtorKey
      } else {
        match mapGet(cctx.unionCaseCtorByName, funcName) {
          case Some(fqn) -> fqn
          case None      -> {
            // Cross-package record: look up simple name in typeFqnByName to
            // get the FQN, then verify it has a ctor registered.
            match mapGet(cctx.typeFqnByName, funcName) {
              case Some(fqn) ->
                if cctx.recordCtorTokens.containsKey(fqn) { fqn }
                else { localCtorKey }
              case None -> localCtorKey
            }
          }
        }
      }
    match mapGet(cctx.recordCtorTokens, ctorKey) {
      case Some(ctorTok) -> {
        // Reorder named arguments to field-declaration order before lowering, so
        // `R(c = …, a = …)` stores each value into its own field rather than the
        // positional slot it was written in (#1730).  Positional calls and
        // ctors without a field-name map pass through unchanged.
        val ctorArgs = reorderCtorNamedArgs(cctx, ctorKey, args)
        // Resolved before arg lowering so each payload gets its inner-type hint (#1687).
        val outerCtxTyArgs: List[MsilType] = newList()
        if fctx.contextHintTyArgs.count > 0 {
          var hci = 0
          while hci < fctx.contextHintTyArgs.count {
            outerCtxTyArgs.add(fctx.contextHintTyArgs[hci])
            hci = hci + 1
          }
        } else {
          match fctx.declaredRetTy {
            case MGenericInst(_, _, retArgTys) -> {
              var rci = 0
              while rci < retArgTys.count {
                outerCtxTyArgs.add(retArgTys[rci])
                rci = rci + 1
              }
            }
            case _ -> {}
          }
        }
        // Lower args, collecting their MSIL types for generic type inference.
        val argTypes: List[MsilType] = newList()
        var ci = 0
        while ci < ctorArgs.count {
          // Hint this slot with its concrete inner type so nested payloads instantiate right (#1687).
          val fldKeyH = ctorKey + "/field" + toString(ci)
          val viH = match mapGet(cctx.fieldVarIndices, fldKeyH) {
            case Some(v) -> v
            case None    -> -1
          }
          // Generic-case fields (`value: T` on `Some<T>`) resolve their hint from
          // the surrounding instantiation via the type-var slot.  Concrete generic
          // fields (`visibility: Option[String]` on a plain record) instead carry
          // their own `MGenericInst`; look it up by the field's declared name so a
          // bare `None` / `Some(...)` argument instantiates with the field's type
          // args rather than erasing to `object` — otherwise the stored nullary
          // case is `Option<object>` and a later `match` on the field fails
          // "match not exhaustive" (#1731 / the #1730 session blocker).
          val innerHint: MsilType =
            if viH >= 0 and viH < outerCtxTyArgs.count { outerCtxTyArgs[viH] }
            else {
              match mapGet(cctx.fieldDeclaredNames, fldKeyH) {
                case Some(fname) -> match mapGet(cctx.fieldMsilTypes, ctorKey + "/" + fname) {
                  case Some(fty) -> fty
                  case None      -> MObject
                }
                case None -> MObject
              }
            }
          val at = match innerHint {
            case MGenericInst(_, _, innerArgs) -> {
              val savedH: List[MsilType] = newList()
              var shi = 0
              while shi < fctx.contextHintTyArgs.count {
                savedH.add(fctx.contextHintTyArgs[shi])
                shi = shi + 1
              }
              while fctx.contextHintTyArgs.count > 0 {
                fctx.contextHintTyArgs.removeAt(fctx.contextHintTyArgs.count - 1)
              }
              var ihi = 0
              while ihi < innerArgs.count {
                fctx.contextHintTyArgs.add(innerArgs[ihi])
                ihi = ihi + 1
              }
              val lowered = lowerCallArgMsil(cctx, fctx, insns, ctorArgs[ci])
              while fctx.contextHintTyArgs.count > 0 {
                fctx.contextHintTyArgs.removeAt(fctx.contextHintTyArgs.count - 1)
              }
              var rhi = 0
              while rhi < savedH.count {
                fctx.contextHintTyArgs.add(savedH[rhi])
                rhi = rhi + 1
              }
              lowered
            }
            case _ -> lowerCallArgMsil(cctx, fctx, insns, ctorArgs[ci])
          }
          argTypes.add(at)
          ci = ci + 1
        }
        // For generic stdlib union cases, build a TypeSpec-based newobj token
        // (ECMA-335 §III.4.21 requires TypeSpec when the class is generic).
        // Infer T from the arg types; use fctx.declaredRetTy as fallback for
        // type-param slots not covered by any arg.
        val contextTyArgs: List[MsilType] = newList()
        var oci = 0
        while oci < outerCtxTyArgs.count {
          contextTyArgs.add(outerCtxTyArgs[oci])
          oci = oci + 1
        }
        val outParentTy: List[MsilType] = newList()
        val genericTok = buildGenericCaseCtorTok(cctx, ctorKey, argTypes, contextTyArgs, outParentTy, insns)
        if genericTok > 0 {
          // MNewobjGenericCase already emitted to insns by buildGenericCaseCtorTok.
          if outParentTy.count > 0 { outParentTy[0] }
          else                     { MObject }
        } else {
          // For nullary in-bundle union cases, load the singleton Instance field
          // instead of allocating a fresh object, so reference-equality works.
          match mapGet(cctx.singletonFieldTokens, ctorKey) {
            case Some(fldTok) -> {
              insns.add(MLdsfld(fieldToken = fldTok))
              val dollarIdx = ctorKey.lastIndexOf("$")
              val classTy = if dollarIdx >= 0 { ctorKey.substring(0, dollarIdx) }
                            else              { ctorKey }
              MClass(className = classTy)
            }
            case None -> {
              insns.add(MNewobj(ctorToken = ctorTok))
              // For local (in-bundle) cases, strip "$<case>" suffix from ctorKey to
              // recover the parent union FQN. For cross-assembly stdlib cases that
              // aren't generic (rare), pass through as-is.
              val dollarIdx = ctorKey.lastIndexOf("$")
              val classTy = if dollarIdx >= 0 { ctorKey.substring(0, dollarIdx) }
                            else              { ctorKey }
              MClass(className = classTy)
            }
          }
        }
      }
      case None -> {
        // Invoke a function-typed value (`f()` where `f` is a local/param holding
        // a lambda).  Lambdas use the uniform `Func`(N+1)<object,…,object>` ABI
        // (#1877), so load the delegate, push the (boxed) args, `callvirt
        // Func::Invoke`, then materialise the boxed `object` result to the call's
        // declared return type.
        match mapGet(fctx.slots, funcName) {
          case Some(slot) -> {
            // `emitLoadSlot` selects `ldarg` for a parameter and `ldloc` for a
            // local — a function-typed *parameter* was previously loaded with
            // `ldloc(slot - paramCount)`, which is invalid IL (#1877).
            emitLoadSlot(insns, slot, fctx.paramCount)
            var i = 0
            while i < args.count {
              val argTy = lowerCallArgMsil(cctx, fctx, insns, args[i])
              // Func<object,...>.Invoke expects object for every param — box value types.
              boxIfNeededMsil(cctx, insns, argTy)
              i = i + 1
            }
            insns.add(MCallvirt(methodToken = buildFuncNInvokeTok(cctx, args.count)))
            // The delegate's declared return type (tracked for function-typed
            // params/locals) drives result materialisation: a void delegate
            // discards the `object`; otherwise it is unboxed/cast to R.
            match mapGet(fctx.funcValRetTypes, funcName) {
              case Some(rt) -> match rt {
                case MVoid -> { insns.add(MPop); MVoid }
                case _     -> { materializeBoxedElemMsil(cctx, insns, rt); rt }
              }
              case None -> MObject
            }
          }
          case None -> {
            // Static call resolution.  Functions are registered FQN-keyed
            // by `addPackageTokens` (#1183 Phase 2), so a call site that
            // arrived here with `funcName` = the last path segment needs
            // to rebuild the FQN before looking it up.
            //
            // Two FQNs to try:
            //   1. The fully-qualified path the caller wrote, when the
            //      path has 2+ segments (e.g. `Session.inMemory()` →
            //      "Session.inMemory" in another package).
            //   2. The current package's FQN — `fctx.pkgName + "." +
            //      funcName` — for bare calls in the same package
            //      (single-package compile or an intra-package call in
            //      a multi-package bundle).
            //
            // The qualified form is tried first when present; this lets
            // a caller in package A unambiguously target package B even
            // when both packages happen to define a same-named helper.
            val qualifiedFqn =
              if path.segments.count >= 2 { joinSegsMsil(path.segments, ".") }
              else                        { "" }
            val localFqn = fctx.pkgName + "." + funcName
            // Fall through to each package this one imports, in declaration
            // order.  First hit wins — matches the typechecker's import
            // shadowing rule.  Packages with no recorded imports (e.g. the
            // single-package compile path) skip the loop entirely.
            val importedFqn =
              match mapGet(cctx.pkgImports, fctx.pkgName) {
                case Some(imps) -> findImportedFqn(cctx, imps, funcName)
                case None       -> ""
              }
            val resolvedFqn =
              if qualifiedFqn.length > 0
                and cctx.funcTokens.containsKey(qualifiedFqn) {
                qualifiedFqn
              } else if cctx.funcTokens.containsKey(localFqn) {
                localFqn
              } else if importedFqn.length > 0 {
                importedFqn
              } else {
                ""
              }
            if resolvedFqn.length > 0 {
              // Narrow to the arity-qualified token (#1536): a package may
              // declare overloads sharing `resolvedFqn` but registered under
              // distinct `<fqn>/<arity>` keys.  Prefer the key matching this
              // call's argument count; fall back to the bare FQN alias when no
              // arity-specific entry exists (non-overloaded funcs, or arities
              // that don't line up — e.g. default/named args, handled later).
              val callArityKey = resolvedFqn + "/" + toString(args.count)
              val tokKey =
                if cctx.funcTokens.containsKey(callArityKey) { callArityKey }
                else                                          { resolvedFqn }
              match mapGet(cctx.funcTokens, tokKey) {
                case Some(tok) -> {
                  val callParamTys = match mapGet(cctx.funcParamTypes, tokKey) {
                    case Some(pts) -> pts
                    case None      -> newList()
                  }
                  val callParamModes = match mapGet(cctx.funcParamModes, tokKey) {
                    case Some(ms) -> ms
                    case None     -> newList()
                  }
                  var i = 0
                  while i < args.count {
                    // #1939: a lambda passed *directly* to a function-typed
                    // parameter inherits that parameter's inner types — record
                    // them under the lambda's index (the next lambdaTicker value,
                    // which the ELambda arm will consume) so the lambda body
                    // unboxes its boxed params to the propagated types.
                    match callArgExpr(args[i]).kind {
                      case ELambda(_, _) -> {
                        match mapGet(cctx.funcParamFnInner, tokKey + "#" + toString(i)) {
                          case Some(inner) -> {
                            if inner.count > 0 {
                              val predName = "__lambda_" + toString(cctx.lambdaTicker.count)
                              if not cctx.lambdaParamTypes.containsKey(predName) {
                                cctx.lambdaParamTypes.add(predName, inner)
                              }
                            }
                          }
                          case None -> {}
                        }
                      }
                      case _ -> {}
                    }
                    // `out`/`inout` parameter: pass the argument's address (a
                    // managed pointer) rather than its value.  See #1761.
                    val isByrefArg =
                      if i < callParamModes.count { isByrefMode(callParamModes[i]) }
                      else { false }
                    if isByrefArg {
                      emitByrefArgMsil(cctx, fctx, insns, callArgExpr(args[i]))
                      i = i + 1
                    } else {
                    // Thread a generic parameter's type args as the construction
                    // context for this argument so a bare `None` (or other
                    // nullary case) builds `Option_None<concrete>` rather than
                    // erasing to `<object>`.  Save/replace/restore the hint stack
                    // (rather than append) so an enclosing val/return context for
                    // a *different* type doesn't leak into the argument.
                    val pTy = if i < callParamTys.count { callParamTys[i] } else { MObject }
                    match pTy {
                      case MGenericInst(_, _, pArgs) -> {
                        val savedHints: List[MsilType] = newList()
                        var sh = 0
                        while sh < fctx.contextHintTyArgs.count {
                          savedHints.add(fctx.contextHintTyArgs[sh])
                          sh = sh + 1
                        }
                        while fctx.contextHintTyArgs.count > 0 {
                          fctx.contextHintTyArgs.removeAt(fctx.contextHintTyArgs.count - 1)
                        }
                        var ph = 0
                        while ph < pArgs.count {
                          fctx.contextHintTyArgs.add(pArgs[ph])
                          ph = ph + 1
                        }
                        val _ = lowerCallArgMsil(cctx, fctx, insns, args[i])
                        while fctx.contextHintTyArgs.count > 0 {
                          fctx.contextHintTyArgs.removeAt(fctx.contextHintTyArgs.count - 1)
                        }
                        var rh = 0
                        while rh < savedHints.count {
                          fctx.contextHintTyArgs.add(savedHints[rh])
                          rh = rh + 1
                        }
                      }
                      case _ -> {
                        val _ = lowerCallArgMsil(cctx, fctx, insns, args[i])
                      }
                    }
                    i = i + 1
                    }
                  }
                  insns.add(MCall(methodToken = tok))
                  match mapGet(cctx.funcRetTypes, tokKey) {
                    case Some(rt) -> rt
                    case None     -> MObject
                  }
                }
                case None -> MObject  // unreachable; effectiveFqn was a hit above
              }
            } else if fctx.className.length > 0
                      and cctx.methodTokens.containsKey(fctx.className + "/" + funcName) {
              // Bare call to a sibling instance method (implicit `self`, slot 0).
              // Emit the callvirt the unresolved-call fallback below would have
              // dropped — leaving args on the stack with no call.
              val sibKey = fctx.className + "/" + funcName
              val sibTok = match mapGet(cctx.methodTokens, sibKey) {
                case Some(t) -> t
                case None    -> panic("Msil.Codegen: sibling method token vanished after containsKey for " + sibKey)
              }
              insns.add(MLdarg(slot = 0))
              var si = 0
              while si < args.count {
                val aTy = lowerCallArgMsil(cctx, fctx, insns, args[si])
                boxIfNeededMsil(cctx, insns, aTy)
                si = si + 1
              }
              insns.add(MCallvirt(methodToken = sibTok))
              match mapGet(cctx.methodRetTypes, sibKey) {
                case Some(rty) -> rty
                case None      -> MObject
              }
            } else {
              // Cross-package call without a registered token: walk args for
              // side effects and yield MObject as a defensive default.  In
              // pre-Phase-2 single-package builds this branch fired for
              // unknown imported funcs (where the call would crash at
              // runtime); same behaviour preserved here so we don't mask
              // a missing token with bogus IL.
              var i = 0
              while i < args.count {
                lowerCallArgMsil(cctx, fctx, insns, args[i])
                i = i + 1
              }
              MObject
            }
          }
        }
      }
    }
  }
}

// Lower a method call on a receiver: recv.memberName(args…).
// Dispatches by name to known BCL tokens for List<object> and
// Dictionary<object,object>; falls back to a safe stub for unknowns.
//
// #878: when the receiver is statically typed as a user-defined class (either
// a record or an interface), look up the corresponding instance MethodDef
// token in `cctx.methodTokens` and emit `callvirt` so virtual / interface
// dispatch happens at the call site.  Falls back to the BCL-name dispatch
// below for `MObject` receivers (e.g. List/Dict).
func lowerMethodCallMsil(
  cctx:       in CodegenCtx,
  fctx:       in FuncCtx,
  insns:      in List[MInsn],
  recv:       in Expr,
  memberName: in String,
  args:       in List[CallArg]
): MsilType {
  // Auto-FFI: if the receiver is an EPath whose name maps to an extern CLR type,
  // emit a direct callvirt to the CLR method rather than a stub.
  match recv.kind {
    case EPath(path) -> {
      val recvName = lastSegmentMsil(path)
      match mapGet(cctx.externTypeNames, recvName) {
        case Some(clrFqn) -> {
          return emitAutoFfiCallMsil(cctx, fctx, insns, recv, memberName, args, clrFqn)
        }
        case None -> {}
      }
    }
    case _ -> {}
  }
  val recvTy = lowerExprMsil(cctx, fctx, insns, recv)
  // Auto-FFI instance dispatch: an extern class-ref receiver (e.g. the result
  // of a class-returning static like `Type.GetType(...)`) dispatches its
  // instance methods via `callvirt` against the real CLR method, resolved from
  // metadata.  The receiver is already on the stack.
  match recvTy {
    case MClassRef(_, fqn) -> match tryInstanceAutoFfiFromMetadata(cctx, fctx, insns, fqn, memberName, args) {
      case Some(rt) -> { return rt }
      // An MClassRef receiver is exclusively produced by metadata-resolved
      // auto-FFI, so there is no other legitimate dispatch for it.  An
      // unresolved instance method means no matching instance method exists in
      // .NET metadata for the argument types.  Rather than abort the whole
      // build (a panic) or silently mis-bind to the null stub, emit a runtime
      // stub that throws a clear error at this call site — the same pattern the
      // unresolved-@externTarget path uses (#1041), honouring the language
      // reference's "never silently mis-bound" guarantee while keeping the
      // failure graceful and located at the offending call.
      case None     -> {
        val msg = "unresolved extern instance method '" + memberName + "' on '" + fqn
          + "': no matching instance method found in .NET metadata for the given argument "
          + "types.  Declare an @externTarget wrapper if a custom binding is intended."
        insns.add(MLdStr(token = ctxInternUs(cctx.lctx, msg)))
        insns.add(MNewobj(ctorToken = cctx.tokExceptionCtor))
        insns.add(MThrow)
        return MObject
      }
    }
    case _ -> {}
  }
  // User-defined instance / interface dispatch path (#878).
  match recvTy {
    case MClass(cls) -> {
      match mapGet(cctx.methodTokens, cls + "/" + memberName) {
        case Some(tok) -> {
          val methodModes = match mapGet(cctx.methodParamModes, cls + "/" + memberName) {
            case Some(ms) -> ms
            case None     -> newList()
          }
          var i = 0
          while i < args.count {
            // `out`/`inout` argument: load the argument's address (a managed
            // pointer) rather than its value so the impl method can write
            // back through it (#1955).  Without this the by-value load
            // mismatches the `int32&` parameter the interface slot declares.
            val isByrefArg =
              if i < methodModes.count { isByrefMode(methodModes[i]) }
              else { false }
            if isByrefArg {
              emitByrefArgMsil(cctx, fctx, insns, callArgExpr(args[i]))
            } else {
              val aTy = lowerCallArgMsil(cctx, fctx, insns, args[i])
              // The method signature declares each parameter's concrete type
              // (`typeExprToMsil`).  Box a value-type argument ONLY when the
              // parameter is a reference/object type — boxing it for a value-type
              // parameter passed `object` where `bool`/`int32` was expected, which
              // is invalid IL (#1784).  A missing registry entry falls back to the
              // conservative box-if-value behaviour.
              val paramIsValue = match mapGet(cctx.methodParamTypes, cls + "/" + memberName + "#" + toString(i)) {
                case Some(pt) -> isValueType(pt)
                case None     -> false
              }
              if not paramIsValue {
                boxIfNeededMsil(cctx, insns, aTy)
              }
            }
            i = i + 1
          }
          insns.add(MCallvirt(methodToken = tok))
          // Report the method's real declared return type so callers — most
          // importantly a `match` scrutinee — track the actual union/record
          // type rather than `object`.  Tracking `object` made union pattern
          // tests/binds mis-extract the payload (the wrong arm fired) (#1602).
          // Falls back to MObject when the return type was not pre-registered.
          return match mapGet(cctx.methodRetTypes, cls + "/" + memberName) {
            case Some(rty) -> rty
            case None      -> MObject
          }
        }
        case None -> {}   // fall through to BCL-name dispatch
      }
    }
    case _ -> {}
  }
  if memberName == "add" {
    // List<object>::Add(object): void  OR  Dict::Add(key,value): void
    //
    // Propagate the receiver's element generic-type args as a construction
    // hint so a bare `xs.add(None)` on a `List[Option[String]]` builds
    // `Option_None<String>` rather than `Option_None<Object>` (#1964).  The
    // typed val/return hint already covers cases where the call sits in
    // assignment position, but a bare statement like `items.add(None)`
    // bypasses that path entirely.
    val addPrevHintLen = fctx.contextHintTyArgs.count
    val addHintsPushed = match recvTy {
      case MListOf(MGenericInst(_, _, elemArgs)) -> {
        var ai = 0
        while ai < elemArgs.count {
          fctx.contextHintTyArgs.add(elemArgs[ai])
          ai = ai + 1
        }
        true
      }
      case MMapOf(_, MGenericInst(_, _, valArgs)) -> {
        var vi = 0
        while vi < valArgs.count {
          fctx.contextHintTyArgs.add(valArgs[vi])
          vi = vi + 1
        }
        true
      }
      case _ -> false
    }
    var i = 0
    while i < args.count {
      val aTy = lowerCallArgMsil(cctx, fctx, insns, args[i])
      boxIfNeededMsil(cctx, insns, aTy)
      i = i + 1
    }
    if addHintsPushed {
      while fctx.contextHintTyArgs.count > addPrevHintLen {
        fctx.contextHintTyArgs.removeAt(fctx.contextHintTyArgs.count - 1)
      }
    }
    if args.count >= 2 {
      insns.add(MCallvirt(methodToken = cctx.tokDictObjAdd))
    } else {
      insns.add(MCallvirt(methodToken = cctx.tokListObjAdd))
    }
    MVoid
  } else if memberName == "containsKey" {
    // Dictionary::ContainsKey(object): bool
    if args.count > 0 {
      val aTy = lowerCallArgMsil(cctx, fctx, insns, args[0])
      boxIfNeededMsil(cctx, insns, aTy)
    }
    insns.add(MCallvirt(methodToken = cctx.tokDictObjContainsKey))
    MBool
  } else if memberName == "contains" {
    match recvTy {
      case MString -> {
        // String.Contains(string): bool — receiver string already on stack.
        if args.count == 1 {
          lowerCallArgMsil(cctx, fctx, insns, args[0])
          insns.add(MCallvirt(methodToken = cctx.tokStringContains))
        } else {
          // Wrong arity: walk args for side effects, pop receiver, throw.
          var i = 0
          while i < args.count {
            lowerCallArgMsil(cctx, fctx, insns, args[i])
            insns.add(MPop)
            i = i + 1
          }
          insns.add(MPop)
          val msgTok = ctxInternUs(cctx.lctx, "Msil.Codegen: String.contains expects 1 argument, got " + toString(args.count))
          insns.add(MLdStr(token = msgTok))
          insns.add(MNewobj(ctorToken = cctx.tokExceptionCtor))
          insns.add(MThrow)
        }
        MBool
      }
      case _ -> {
        // List<object>::Contains(!0): bool — receiver List already on stack;
        // push the boxed element and call Contains.  Wrong-arity falls through
        // to a runtime-throw stub matching the unknown-method catch-all
        // (formerly a silent `false` return — #1481 item 4 / #1799).
        if args.count == 1 {
          val aTy = lowerCallArgMsil(cctx, fctx, insns, args[0])
          boxIfNeededMsil(cctx, insns, aTy)
          insns.add(MCallvirt(methodToken = cctx.tokListObjContains))
        } else {
          var i = 0
          while i < args.count {
            lowerCallArgMsil(cctx, fctx, insns, args[i])
            insns.add(MPop)
            i = i + 1
          }
          insns.add(MPop)
          val msgTok = ctxInternUs(cctx.lctx, "Msil.Codegen: List.contains expects 1 argument, got " + toString(args.count))
          insns.add(MLdStr(token = msgTok))
          insns.add(MNewobj(ctorToken = cctx.tokExceptionCtor))
          insns.add(MThrow)
        }
        MBool
      }
    }
  } else if memberName == "remove" {
    // `map.remove(key)` -> Dictionary<object,object>::Remove(!0): bool.  The
    // receiver Dictionary is already on the stack; push the boxed key and call
    // Remove.  (Previously a bootstrap stub that popped the args and returned
    // false, so `delete()` / `destroy()` were silent no-ops — #1602/#1727.)
    match recvTy {
      case MMapOf(_, _) -> {
        if args.count > 0 {
          val aTy = lowerCallArgMsil(cctx, fctx, insns, args[0])
          boxIfNeededMsil(cctx, insns, aTy)
        }
        insns.add(MCallvirt(methodToken = cctx.tokDictObjRemove))
        MBool
      }
      case _ -> {
        // Non-Map receiver: retain the conservative pop-only behaviour until a
        // real List/Set removal lowering lands.
        var i = 0
        while i < args.count {
          lowerCallArgMsil(cctx, fctx, insns, args[i])
          insns.add(MPop)
          i = i + 1
        }
        insns.add(MPop)
        insns.add(MLdcI4(v = 0))
        MBool
      }
    }
  } else if memberName == "removeAt" {
    // List<object>::RemoveAt(int32): void — receiver List already on stack;
    // push the int32 index and call RemoveAt.  Wrong-arity falls through to
    // a runtime-throw stub matching the unknown-method catch-all (formerly
    // a silent no-op — #1481 item 4 / #1799).
    if args.count == 1 {
      lowerCallArgMsil(cctx, fctx, insns, args[0])
      insns.add(MCallvirt(methodToken = cctx.tokListObjRemoveAt))
      MVoid
    } else {
      var i = 0
      while i < args.count {
        lowerCallArgMsil(cctx, fctx, insns, args[i])
        insns.add(MPop)
        i = i + 1
      }
      insns.add(MPop)
      val msgTok = ctxInternUs(cctx.lctx, "Msil.Codegen: List.removeAt expects 1 argument, got " + toString(args.count))
      insns.add(MLdStr(token = msgTok))
      insns.add(MNewobj(ctorToken = cctx.tokExceptionCtor))
      insns.add(MThrow)
      MVoid
    }
  } else if memberName == "toArray" {
    // List::toArray(): return the list itself as the iterable (bootstrap).
    // The SFor codegen iterates via get_Count / get_Item, which work on the
    // List<object> directly, so no conversion is needed.  Return the receiver's
    // tracked type (e.g. `MListOf(elem)`) rather than erasing to `MObject`, so a
    // `for x in xs.toArray()` loop can recover the element type and bind `x`
    // with it — an erased loop variable broke `match x` / field access on `x`
    // (#2126).
    recvTy
  } else if memberName == "toString" {
    insns.add(MCallvirt(methodToken = cctx.tokObjToString))
    MString
  } else if memberName == "substring" {
    // String.Substring(start, length): string.
    // 3-arg form: Str.substring(str, start, len) — module-qualified free function.
    //   The module receiver (null) is on the stack; pop it, push the 3 real args.
    // 2-arg form: str.substring(start, len) — instance method, receiver already on stack.
    // 1-arg form: stubbed.
    if args.count == 3 {
      insns.add(MPop)
      lowerCallArgMsil(cctx, fctx, insns, args[0])
      lowerCallArgMsil(cctx, fctx, insns, args[1])
      lowerCallArgMsil(cctx, fctx, insns, args[2])
      insns.add(MCallvirt(methodToken = cctx.tokStringSubstring))
      MString
    } else if args.count == 2 {
      lowerCallArgMsil(cctx, fctx, insns, args[0])
      lowerCallArgMsil(cctx, fctx, insns, args[1])
      insns.add(MCallvirt(methodToken = cctx.tokStringSubstring))
      MString
    } else if args.count == 1 {
      lowerCallArgMsil(cctx, fctx, insns, args[0])
      insns.add(MPop)
      insns.add(MPop)
      insns.add(MLdNull)
      MObject
    } else {
      insns.add(MPop)
      insns.add(MLdNull)
      MObject
    }
  } else if memberName == "replace" {
    // String.Replace(oldValue, newValue): string
    if args.count >= 2 {
      lowerCallArgMsil(cctx, fctx, insns, args[0])
      lowerCallArgMsil(cctx, fctx, insns, args[1])
      insns.add(MCallvirt(methodToken = cctx.tokStringReplace))
      MString
    } else {
      var i = 0
      while i < args.count {
        lowerCallArgMsil(cctx, fctx, insns, args[i])
        insns.add(MPop)
        i = i + 1
      }
      insns.add(MPop)
      insns.add(MLdNull)
      MObject
    }
  } else if memberName == "isNormalized" {
    // String.IsNormalized(): bool  instance HASTHIS
    insns.add(MCallvirt(methodToken = cctx.tokStringIsNormalized))
    MBool
  } else if memberName == "normalize" {
    // String.Normalize(): string  instance HASTHIS
    insns.add(MCallvirt(methodToken = cctx.tokStringNormalize))
    MString
  } else if memberName == "trim" and args.count == 0 {
    // String.Trim(): string  instance HASTHIS — receiver already on stack.
    insns.add(MCallvirt(methodToken = cctx.tokStringTrim))
    MString
  } else if memberName == "indexOf" and args.count == 1 {
    // String.IndexOf(string): int32 — BCL semantics (-1 when absent),
    // distinct from the Std.String free function returning Option[Int].
    lowerCallArgMsil(cctx, fctx, insns, args[0])
    insns.add(MCallvirt(methodToken = cctx.tokStringIndexOf))
    MInt
  } else if memberName == "lastIndexOf" and args.count == 1 {
    lowerCallArgMsil(cctx, fctx, insns, args[0])
    insns.add(MCallvirt(methodToken = cctx.tokStringLastIndexOf))
    MInt
  } else if memberName == "startsWith" and args.count == 1 {
    lowerCallArgMsil(cctx, fctx, insns, args[0])
    insns.add(MCallvirt(methodToken = cctx.tokStringStartsWith))
    MBool
  } else if memberName == "endsWith" and args.count == 1 {
    lowerCallArgMsil(cctx, fctx, insns, args[0])
    insns.add(MCallvirt(methodToken = cctx.tokStringEndsWith))
    MBool
  } else if memberName == "toLower" and args.count == 0 {
    insns.add(MCallvirt(methodToken = cctx.tokStringToLower))
    MString
  } else if memberName == "toUpper" and args.count == 0 {
    insns.add(MCallvirt(methodToken = cctx.tokStringToUpper))
    MString
  } else if (memberName == "and" or memberName == "or" or memberName == "xor"
             or memberName == "shl" or memberName == "shr") and args.count == 1 {
    // For `shl`/`shr` the operand is the Int shift count.  `shr` is an
    // arithmetic shift (MShr) — Lyric's Int/Long/Byte are signed and the
    // MSIL backend has no unsigned integer type yet, so logical shift
    // (MShrUn) is not reachable here.
    lowerCallArgMsil(cctx, fctx, insns, args[0])
    if memberName == "and" {
      insns.add(MAnd)
    } else if memberName == "or" {
      insns.add(MOr)
    } else if memberName == "xor" {
      insns.add(MXor)
    } else if memberName == "shl" {
      insns.add(MShl)
    } else {
      insns.add(MShr)
    }
    recvTy
  } else if (memberName == "toInt" or memberName == "toLong" or memberName == "toByte"
             or memberName == "toChar" or memberName == "toDouble")
            and args.count == 0 and isNumericMsil(recvTy) {
    // Numeric / character primitive conversion intrinsics (#1901).  The receiver
    // value is already on the stack; emit the CLI `conv.*` opcode for the target
    // width.  These are the surface conversions for moving between Lyric's
    // numeric primitives (e.g. `slice[Byte]` element -> `Int` for arithmetic),
    // replacing the legacy free-function forms (`intToLong`/`longToInt`).
    if memberName == "toByte" {
      insns.add(MConvU1)
      MByte
    } else if memberName == "toChar" {
      insns.add(MConvU2)
      MChar
    } else if memberName == "toLong" {
      insns.add(MConvI8)
      MLong
    } else if memberName == "toDouble" {
      insns.add(MConvR8)
      MDouble
    } else {
      insns.add(MConvI4)
      MInt
    }
  } else {
    // Unrecognised method on this receiver.  Previously this popped the
    // receiver/args and pushed `null` — a silent miscompile: the call appeared
    // to succeed and yielded a bogus null.  Instead emit a stub that throws a
    // clear error at this call site if it is ever reached, mirroring the
    // unresolved auto-FFI / @externTarget pattern above (#1041) and honouring
    // the language reference's "never silently mis-bound" guarantee.  Lowering
    // a runtime throw rather than a compile-time abort keeps programs whose
    // unreachable paths mention such a call compilable, while any path that
    // actually executes it fails loudly and located.  #1481 item 4.
    val msg = "unsupported method '" + memberName
      + "' on the receiver type at this call site (no matching user method, "
      + "extern binding, or built-in intrinsic)"
    insns.add(MLdStr(token = ctxInternUs(cctx.lctx, msg)))
    insns.add(MNewobj(ctorToken = cctx.tokExceptionCtor))
    insns.add(MThrow)
    MObject
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Statement lowering.
// ─────────────────────────────────────────────────────────────────────────────

// ── For-loop lowering (#1478) ────────────────────────────────────────────────
//
// `for <pat> in <iter> { body }` lowers two ways depending on the iterator:
//   * `<iter>` is a range literal (`lo .. hi` / `lo ..= hi`) — emit a counting
//     loop directly, with no materialised range value.
//   * otherwise `<iter>` is a `List`/array/slice — iterate by index using
//     `List<object>::get_Count` / `get_Item`, matching how `EIndex` reads
//     model every `[]` receiver as `List<object>` in the bootstrap.
//
// Both forms route `break` / `continue` through the standard `fctx.loopBreak`
// / `fctx.loopCont` label stacks; `continue` targets the increment step so the
// counter still advances.

// Bind a `for` loop variable from the value in `slot`.  A `for` binding is
// irrefutable: only a name, `_`, or a tuple of those is allowed.  Refutable
// forms (constructor / literal) reach this with a `panic` — proper span-
// carrying diagnostic (`F0xxx`) tracked in #1865; in practice the parser
// and type checker reject these earlier so the path is reached only on
// malformed AST input from a future feature.
func bindForPatternMsil(
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  pat:  in Pattern,
  slot: in Int,
  ty:   in MsilType
): Unit {
  match pat.kind {
    case PBinding(_, _) -> lowerPatternBindMsil(cctx, fctx, insns, pat, slot, ty)
    case PWildcard      -> {}
    case PTuple(_)      -> lowerPatternBindMsil(cctx, fctx, insns, pat, slot, ty)
    case _ ->
      panic("Msil.Codegen: a `for` loop variable must be an irrefutable pattern (a name, `_`, or a tuple of those); refutable patterns are not allowed in a `for` binding")
  }
}

// Emit a counting loop for `for <pat> in lo .. hi` (inclusive=false) or
// `lo ..= hi` (inclusive=true).  `lo` / `hi` are each evaluated exactly once.
func emitCountingForMsil(
  cctx:      in CodegenCtx,
  fctx:      in FuncCtx,
  insns:     in List[MInsn],
  pat:       in Pattern,
  lo:        in Expr,
  hi:        in Expr,
  inclusive: in Bool,
  body:      in Block
): Unit {
  // counter := lo
  val loTy  = lowerExprMsil(cctx, fctx, insns, lo)
  val iSlot = allocSlotMsil(fctx, "__for_i_" + toString(fctx.slotTicker.count), loTy)
  emitStoreSlot(insns, iSlot, fctx.paramCount)
  // bound := hi (evaluated once so `for i in 0 .. f()` does not re-call f)
  val hiTy   = lowerExprMsil(cctx, fctx, insns, hi)
  val hiSlot = allocSlotMsil(fctx, "__for_hi_" + toString(fctx.slotTicker.count), hiTy)
  emitStoreSlot(insns, hiSlot, fctx.paramCount)

  val loopL  = freshLabelMsil(fctx)
  val contL  = freshLabelMsil(fctx)
  val afterL = freshLabelMsil(fctx)

  insns.add(MLabel(id = loopL))
  // Continue while i < hi (half-open) or i <= hi (closed); else exit.
  emitLoadSlot(insns, iSlot, fctx.paramCount)
  emitLoadSlot(insns, hiSlot, fctx.paramCount)
  if inclusive {
    insns.add(MCgt)                       // i > hi ?
    insns.add(MBrTrue(label = afterL))    // exit once the counter passes hi
  } else {
    insns.add(MClt)                       // i < hi ?
    insns.add(MBrFalse(label = afterL))   // exit once i is no longer below hi
  }
  // Bind the loop pattern from the current counter value.
  bindForPatternMsil(cctx, fctx, insns, pat, iSlot, loTy)

  fctx.loopBreak.add(afterL)
  fctx.loopCont.add(contL)
  fctx.loopTryDepth.add(fctx.tryRegionStack.count)
  lowerBlockMsil(cctx, fctx, insns, body)
  fctx.loopTryDepth.removeAt(fctx.loopTryDepth.count - 1)
  fctx.loopBreak.removeAt(fctx.loopBreak.count - 1)
  fctx.loopCont.removeAt(fctx.loopCont.count - 1)

  // increment (continue target): i := i + 1
  insns.add(MLabel(id = contL))
  emitLoadSlot(insns, iSlot, fctx.paramCount)
  match loTy {
    case MLong -> insns.add(MLdcI8(v = 1i64))
    case _     -> insns.add(MLdcI4(v = 1))
  }
  insns.add(MAdd)
  emitStoreSlot(insns, iSlot, fctx.paramCount)
  insns.add(MBr(label = loopL))
  insns.add(MLabel(id = afterL))
}

// Emit an index-based loop for `for <pat> in <collection>`, modelling the
// collection as `List<object>` (the bootstrap representation shared with the
// `EIndex` read path).
func emitCollectionForMsil(
  cctx:  in CodegenCtx,
  fctx:  in FuncCtx,
  insns: in List[MInsn],
  pat:   in Pattern,
  iter:  in Expr,
  body:  in Block
): Unit {
  // list := <collection>.  Keep the iterable's tracked type so the loop
  // variable can be bound with its real element type rather than erased
  // `object` (#2126): a `for x in xs.toArray()` element bound as `MObject` made
  // `match x` / field access on `x` see an untyped scrutinee and misbehave.
  val iterTy = lowerExprMsil(cctx, fctx, insns, iter)
  // Narrow only reference (`MClass`) elements — user records / unions, the
  // affected case.  Value-type and unknown elements keep the existing
  // `MObject` binding to avoid changing their (working) lowering.
  val forElemRaw = match iterTy {
    case MArray(e)  -> e
    case MListOf(e) -> e
    case _          -> MObject
  }
  val forElemTy = match forElemRaw {
    case MClass(_) -> forElemRaw
    case _         -> MObject
  }
  val listSlot = allocSlotMsil(fctx, "__for_list_" + toString(fctx.slotTicker.count), MObject)
  emitStoreSlot(insns, listSlot, fctx.paramCount)
  // i := 0
  val iSlot = allocSlotMsil(fctx, "__for_ci_" + toString(fctx.slotTicker.count), MInt)
  insns.add(MLdcI4(v = 0))
  emitStoreSlot(insns, iSlot, fctx.paramCount)
  // count := list.Count
  val cntSlot = allocSlotMsil(fctx, "__for_cnt_" + toString(fctx.slotTicker.count), MInt)
  emitLoadSlot(insns, listSlot, fctx.paramCount)
  insns.add(MCastclass(typeToken = cctx.tokListObjTypeSpec))
  insns.add(MCallvirt(methodToken = cctx.tokListObjGetCount))
  emitStoreSlot(insns, cntSlot, fctx.paramCount)

  val loopL  = freshLabelMsil(fctx)
  val contL  = freshLabelMsil(fctx)
  val afterL = freshLabelMsil(fctx)

  insns.add(MLabel(id = loopL))
  emitLoadSlot(insns, iSlot, fctx.paramCount)
  emitLoadSlot(insns, cntSlot, fctx.paramCount)
  insns.add(MClt)
  insns.add(MBrFalse(label = afterL))
  // elem := list[i]
  emitLoadSlot(insns, listSlot, fctx.paramCount)
  insns.add(MCastclass(typeToken = cctx.tokListObjTypeSpec))
  emitLoadSlot(insns, iSlot, fctx.paramCount)
  insns.add(MCallvirt(methodToken = cctx.tokListObjGetItem))
  // get_Item returns `object`; narrow to the real element type (castclass) when
  // it is a known reference type so the loop variable is correctly typed.
  if forElemTy != MObject { castObjectToMsil(cctx, insns, forElemTy) }
  val elemSlot = allocSlotMsil(fctx, "__for_elem_" + toString(fctx.slotTicker.count), forElemTy)
  emitStoreSlot(insns, elemSlot, fctx.paramCount)
  bindForPatternMsil(cctx, fctx, insns, pat, elemSlot, forElemTy)

  fctx.loopBreak.add(afterL)
  fctx.loopCont.add(contL)
  fctx.loopTryDepth.add(fctx.tryRegionStack.count)
  lowerBlockMsil(cctx, fctx, insns, body)
  fctx.loopTryDepth.removeAt(fctx.loopTryDepth.count - 1)
  fctx.loopBreak.removeAt(fctx.loopBreak.count - 1)
  fctx.loopCont.removeAt(fctx.loopCont.count - 1)

  insns.add(MLabel(id = contL))
  emitLoadSlot(insns, iSlot, fctx.paramCount)
  insns.add(MLdcI4(v = 1))
  insns.add(MAdd)
  emitStoreSlot(insns, iSlot, fctx.paramCount)
  insns.add(MBr(label = loopL))
  insns.add(MLabel(id = afterL))
}

// Dispatch a `for` statement to the range or collection lowering.
func lowerForMsil(
  cctx:  in CodegenCtx,
  fctx:  in FuncCtx,
  insns: in List[MInsn],
  pat:   in Pattern,
  iter:  in Expr,
  body:  in Block
): Unit {
  match iter.kind {
    case ERange(bound) -> {
      match bound {
        case RBClosed(lo, hi)   -> emitCountingForMsil(cctx, fctx, insns, pat, lo, hi, true, body)
        case RBHalfOpen(lo, hi) -> emitCountingForMsil(cctx, fctx, insns, pat, lo, hi, false, body)
        case RBLowerOpen(_) ->
          panic("Msil.Codegen: an open-start range (`..= b`) cannot drive a `for` loop — it has no lower bound to count from (#1478).")
        case RBUpperOpen(_) ->
          panic("Msil.Codegen: an open-end range (`a ..`) cannot drive a `for` loop — it is unbounded (#1478).")
      }
    }
    case _ -> emitCollectionForMsil(cctx, fctx, insns, pat, iter, body)
  }
}

pub func lowerStmtMsil(cctx: in CodegenCtx, fctx: in FuncCtx,
                       insns: in List[MInsn], stmt: in Statement): Unit {
  match stmt.kind {

    // ── Local bindings ────────────────────────────────────────────────────────
    case SLocal(binding) -> {
      match binding {
        case LBVal(pat, tyOpt, init) -> {
          val annoTy = match tyOpt {
            case Some(te) -> typeExprToMsilCtx(cctx, te, fctx.pkgName)
            case None     -> MObject
          }
          val prevHintLen = fctx.contextHintTyArgs.count
          match annoTy {
            case MGenericInst(_, _, typeArgs) -> {
              var hi = 0
              while hi < typeArgs.count {
                fctx.contextHintTyArgs.add(typeArgs[hi])
                hi = hi + 1
              }
            }
            case _ -> {}
          }
          // Empty typed-slice literal (`val xs: slice[T] = []`): the generic
          // `[]` otherwise lowers to a `List<object>`, which then mis-reads as
          // a `T[]` at the MArray-typed local (#1497).  Emit a real empty
          // `T[]` via `System.Array.Empty<T>()` (open-generic BCL call →
          // MethodSpec).
          val initTy = match annoTy {
            case MArray(elem) -> {
              if isEmptyListExprMsil(init) {
                emitEmptyArrayMsil(cctx, insns, elem)
                annoTy
              } else {
                lowerExprMsil(cctx, fctx, insns, init)
              }
            }
            case _ -> lowerExprMsil(cctx, fctx, insns, init)
          }
          while fctx.contextHintTyArgs.count > prevHintLen {
            fctx.contextHintTyArgs.removeAt(fctx.contextHintTyArgs.count - 1)
          }
          val effectiveTy = if annoTy != MObject { annoTy } else { initTy }
          lowerLocalPatBindMsil(cctx, fctx, insns, pat, effectiveTy, tyOpt)
        }
        case LBLet(name, tyOpt, init) -> {
          val annoTy = match tyOpt {
            case Some(te) -> typeExprToMsilCtx(cctx, te, fctx.pkgName)
            case None     -> MObject
          }
          val prevHintLen = fctx.contextHintTyArgs.count
          match annoTy {
            case MGenericInst(_, _, typeArgs) -> {
              var hi = 0
              while hi < typeArgs.count {
                fctx.contextHintTyArgs.add(typeArgs[hi])
                hi = hi + 1
              }
            }
            case _ -> {}
          }
          val initTy = lowerExprMsil(cctx, fctx, insns, init)
          while fctx.contextHintTyArgs.count > prevHintLen {
            fctx.contextHintTyArgs.removeAt(fctx.contextHintTyArgs.count - 1)
          }
          val ty = if annoTy != MObject { annoTy } else { initTy }
          val slot = allocSlotMsil(fctx, name, ty)
          emitStoreSlot(insns, slot, fctx.paramCount)
          // Phase B.1 promoted-local: hoist val-binding to SM field so the value
          // survives suspension.  emitPhaseBAwait reloads all registered locals at
          // each resume label.
          if fctx.phaseBCtx.count > 0 {
            phaseBRegisterAndSyncLocal(fctx.phaseBCtx[0], insns, name, ty, slot - fctx.paramCount)
          }
        }
        case LBVar(name, tyOpt, initOpt) -> {
          // A `var` captured by a closure is hoisted to a heap cell (#1479 v2):
          // newobj List; dup; <value>; finishHoistedCell.  Reads/writes route
          // through the cell so the closure and this scope share the location.
          val isHoisted = nameListContains(fctx.hoistedVarNames, name)
          match initOpt {
            case Some(init) -> {
              val annoTy = match tyOpt {
                case Some(te) -> typeExprToMsilCtx(cctx, te, fctx.pkgName)
                case None     -> MObject
              }
              if isHoisted {
                insns.add(MNewobj(ctorToken = cctx.tokListObjCtor))
                insns.add(MDup)
              }
              val prevHintLen = fctx.contextHintTyArgs.count
              match annoTy {
                case MGenericInst(_, _, typeArgs) -> {
                  var hi = 0
                  while hi < typeArgs.count {
                    fctx.contextHintTyArgs.add(typeArgs[hi])
                    hi = hi + 1
                  }
                }
                case _ -> {}
              }
              val initTy = lowerExprMsil(cctx, fctx, insns, init)
              while fctx.contextHintTyArgs.count > prevHintLen {
                fctx.contextHintTyArgs.removeAt(fctx.contextHintTyArgs.count - 1)
              }
              val ty = if annoTy != MObject { annoTy } else { initTy }
              if isHoisted {
                finishHoistedCellMsil(cctx, fctx, insns, name, ty)
              } else {
                val slot = allocSlotMsil(fctx, name, ty)
                emitStoreSlot(insns, slot, fctx.paramCount)
                fctx.mutableLocals.add(name)
                if fctx.phaseBCtx.count > 0 {
                  phaseBRegisterAndSyncLocal(fctx.phaseBCtx[0], insns, name, ty, slot - fctx.paramCount)
                }
              }
            }
            case None -> {
              val ty =
                match tyOpt {
                  case Some(te) -> typeExprToMsilCtx(cctx, te, fctx.pkgName)
                  case None     -> MInt
                }
              if isHoisted and ty != MVoid {
                insns.add(MNewobj(ctorToken = cctx.tokListObjCtor))
                insns.add(MDup)
                match ty {
                  case MLong   -> { insns.add(MLdcI8(v = intToLong(0))) }
                  case MDouble -> { insns.add(MLdcR8(v = 0.0)) }
                  case _       -> { insns.add(MLdcI4(v = 0)) }
                }
                finishHoistedCellMsil(cctx, fctx, insns, name, ty)
              } else {
                val slot = allocSlotMsil(fctx, name, ty)
                fctx.mutableLocals.add(name)
                match ty {
                  case MLong   -> { insns.add(MLdcI8(v = intToLong(0))); emitStoreSlot(insns, slot, fctx.paramCount) }
                  case MDouble -> { insns.add(MLdcR8(v = 0.0)); emitStoreSlot(insns, slot, fctx.paramCount) }
                  case MVoid   -> {}
                  case _       -> { insns.add(MLdcI4(v = 0)); emitStoreSlot(insns, slot, fctx.paramCount) }
                }
                if fctx.phaseBCtx.count > 0 and ty != MVoid {
                  phaseBRegisterAndSyncLocal(fctx.phaseBCtx[0], insns, name, ty, slot - fctx.paramCount)
                }
              }
            }
          }
        }
      }
    }

    // ── Return ─────────────────────────────────────────────────────────────────
    case SReturn(valOpt) -> {
      if fctx.tryRegionStack.count > 0 {
        // Inside a protected region: a bare `ret` is invalid IL.  Stash the
        // value (if any) and `leave` to the function epilogue, which runs any
        // intervening `finally` handlers before loading the value and returning.
        // #1477.  `epilogueLabel` is always reserved by `lowerFuncMsil` /
        // `lowerImplMethodMsil` before body lowering; a missing label here
        // would silently emit a bare `ret` inside the protected region.
        if fctx.epilogueLabel < 0 {
          panic("Msil.Codegen: SReturn inside protected region but FuncCtx.epilogueLabel was not reserved (caller must invoke lowerFuncMsil / lowerImplMethodMsil)")
        }
        match valOpt {
          case Some(e) -> {
            lowerExprMsil(cctx, fctx, insns, e)
            if fctx.retvalSlot < 0 {
              fctx.retvalSlot = allocSlotMsil(fctx, "__retval", fctx.declaredRetTy)
            }
            emitStoreSlot(insns, fctx.retvalSlot, fctx.paramCount)
          }
          case None -> {}
        }
        fctx.epilogueUsed.add(0)
        insns.add(MLeave(label = fctx.epilogueLabel))
      } else {
        match valOpt {
          case Some(e) -> {
            lowerExprMsil(cctx, fctx, insns, e)
            insns.add(MRet)
          }
          case None -> {
            insns.add(MRet)
          }
        }
      }
    }

    // ── Expression statement ───────────────────────────────────────────────────
    case SExpr(e) -> {
      val ty = lowerExprMsil(cctx, fctx, insns, e)
      match ty {
        case MVoid -> {}
        case _     -> insns.add(MPop)
      }
    }

    // ── While loop ────────────────────────────────────────────────────────────
    case SWhile(_, cond, body) -> {
      val loopL  = freshLabelMsil(fctx)
      val afterL = freshLabelMsil(fctx)
      insns.add(MLabel(id =loopL))
      lowerExprMsil(cctx, fctx, insns, cond)
      insns.add(MBrFalse(label = afterL))
      fctx.loopBreak.add(afterL)
      fctx.loopCont.add(loopL)
      fctx.loopTryDepth.add(fctx.tryRegionStack.count)
      lowerBlockMsil(cctx, fctx, insns, body)
      fctx.loopTryDepth.removeAt(fctx.loopTryDepth.count - 1)
      fctx.loopBreak.removeAt(fctx.loopBreak.count - 1)
      fctx.loopCont.removeAt(fctx.loopCont.count - 1)
      insns.add(MBr(label = loopL))
      insns.add(MLabel(id =afterL))
    }

    // ── For loop (range fast-path + collection iteration, #1478) ──────────────
    case SFor(_, pat, iter, body) -> {
      lowerForMsil(cctx, fctx, insns, pat, iter, body)
    }

    // ── Loop (unconditional) ──────────────────────────────────────────────────
    case SLoop(_, body) -> {
      val loopL2  = freshLabelMsil(fctx)
      val afterL2 = freshLabelMsil(fctx)
      insns.add(MLabel(id =loopL2))
      fctx.loopBreak.add(afterL2)
      fctx.loopCont.add(loopL2)
      fctx.loopTryDepth.add(fctx.tryRegionStack.count)
      lowerBlockMsil(cctx, fctx, insns, body)
      fctx.loopTryDepth.removeAt(fctx.loopTryDepth.count - 1)
      fctx.loopBreak.removeAt(fctx.loopBreak.count - 1)
      fctx.loopCont.removeAt(fctx.loopCont.count - 1)
      insns.add(MBr(label = loopL2))
      insns.add(MLabel(id =afterL2))
    }

    // ── Assignment statement ───────────────────────────────────────────────────
    case SAssign(target, op, value) -> {
      val _ = lowerAssignExprMsil(cctx, fctx, insns, target, op, value)
    }

    // ── Throw ─────────────────────────────────────────────────────────────────
    case SThrow(e) -> {
      lowerExprMsil(cctx, fctx, insns, e)
      insns.add(MThrow)
    }

    // ── Break / continue ─────────────────────────────────────────────────────
    // A `break`/`continue` whose target loop was entered outside the current
    // protected region(s) jumps across a CLR try/catch boundary and must use
    // `leave` rather than `br` (a `br` out of a protected region is
    // unverifiable IL).  #1481.
    case SBreak(_) -> {
      emitLoopJumpMsil(fctx, insns, fctx.loopBreak[fctx.loopBreak.count - 1])
    }
    case SContinue(_) -> {
      emitLoopJumpMsil(fctx, insns, fctx.loopCont[fctx.loopCont.count - 1])
    }

    // ── Scope block ───────────────────────────────────────────────────────────
    case SScope(_, body) -> {
      lowerBlockMsil(cctx, fctx, insns, body)
    }

    // ── Defer (bootstrap: inline) ────────────────────────────────────────────
    case SDefer(body) -> {
      lowerBlockMsil(cctx, fctx, insns, body)
    }

    // ── Try/catch ─────────────────────────────────────────────────────────────
    case STry(body, catches, finally_) -> {
      lowerTryCatchMsil(cctx, fctx, insns, body, catches, finally_)
    }

    // ── Invariant annotation (runtime: skip) ──────────────────────────────────
    case SInvariant(_) -> {}

    // ── Inline item declaration (skip in bootstrap) ────────────────────────────
    case SItem(_) -> {}

    // ── Rule statement (skip) ─────────────────────────────────────────────────
    case SRule(_, _) -> {}
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6a. Local pattern binding.
// ─────────────────────────────────────────────────────────────────────────────

func lowerLocalPatBindMsil(
  cctx:   in CodegenCtx,
  fctx:   in FuncCtx,
  insns:  in List[MInsn],
  pat:    in Pattern,
  initTy: in MsilType,
  tyOpt:  in Option[TypeExpr]
): Unit {
  match pat.kind {
    case PBinding(name, _) -> {
      val ty =
        match tyOpt {
          case Some(te) -> typeExprToMsilCtx(cctx, te, fctx.pkgName)
          case None     -> initTy
        }
      val slot = allocSlotMsil(fctx, name, ty)
      emitStoreSlot(insns, slot, fctx.paramCount)
    }
    case PWildcard -> {
      match initTy {
        case MVoid -> {}
        case _     -> insns.add(MPop)
      }
    }
    case _ -> {
      val tmpSlot = allocSlotMsil(fctx,
        "__tmp_" + toString(fctx.slotTicker.count), initTy)
      emitStoreSlot(insns, tmpSlot, fctx.paramCount)
      lowerPatternBindMsil(cctx, fctx, insns, pat, tmpSlot, initTy)
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6b. Try/catch lowering.
// ─────────────────────────────────────────────────────────────────────────────

// Emit a `break`/`continue` jump to `target`.  When the innermost loop was
// entered at a shallower protected-region (try/catch) depth than the current
// one — i.e. the jump escapes one or more open `try`/`catch` regions — the CLR
// requires `leave`; otherwise a plain `br` suffices.  #1481 (H17).
func emitLoopJumpMsil(fctx: in FuncCtx, insns: in List[MInsn], target: in Int): Unit {
  val loopDepth =
    if fctx.loopTryDepth.count > 0 { fctx.loopTryDepth[fctx.loopTryDepth.count - 1] }
    else                          { 0 }
  if fctx.tryRegionStack.count > loopDepth {
    insns.add(MLeave(label = target))
  } else {
    insns.add(MBr(label = target))
  }
}

func lowerTryCatchMsil(
  cctx:     in CodegenCtx,
  fctx:     in FuncCtx,
  insns:    in List[MInsn],
  body:     in Block,
  catches:  in List[CatchClause],
  finally_: in Option[Block]
): Unit {
  val hasCatch   = catches.count > 0
  val hasFinally = match finally_ { case Some(_) -> true case None -> false }
  val tryStartL  = freshLabelMsil(fctx)
  val afterL     = freshLabelMsil(fctx)

  insns.add(MLabel(id = tryStartL))
  // The try body is a protected region: a break/continue out of it to an outer
  // loop must `leave` (tracked via tryRegionStack; see emitLoopJumpMsil).
  fctx.tryRegionStack.add(0)
  lowerBlockMsil(cctx, fctx, insns, body)
  fctx.tryRegionStack.removeAt(fctx.tryRegionStack.count - 1)
  if hasCatch or hasFinally {
    // `leave` is required (not `br`) when exiting a CLR protected region.
    insns.add(MLeave(label = afterL))
  }

  // The `tryEnd` label for all catch EHClauses = first insn after the try body.
  // It is placed right before the first catch handler (or before the finally
  // handler when there are no catch clauses).
  val tryBodyEndL = freshLabelMsil(fctx)
  insns.add(MLabel(id = tryBodyEndL))

  var i = 0
  while i < catches.count {
    val c = catches[i]
    val handlerStartL = freshLabelMsil(fctx)
    insns.add(MLabel(id = handlerStartL))
    match c.bindName {
      case Some(bname) -> {
        val exSlot = allocSlotMsil(fctx, bname, MObject)
        emitStoreSlot(insns, exSlot, fctx.paramCount)
      }
      case None -> {
        insns.add(MPop)
      }
    }
    // A catch handler is itself a protected-region context: a break/continue
    // out of it to an outer loop must also `leave`.
    fctx.tryRegionStack.add(0)
    lowerBlockMsil(cctx, fctx, insns, c.body)
    fctx.tryRegionStack.removeAt(fctx.tryRegionStack.count - 1)
    insns.add(MLeave(label = afterL))
    val handlerEndL = freshLabelMsil(fctx)
    insns.add(MLabel(id = handlerEndL))
    // System.Exception typed catch: flags=0, token = TypeRef RID for System.Exception.
    insns.add(MEHClause(
      flags        = 0,
      tryStart     = tryStartL,
      tryEnd       = tryBodyEndL,
      handlerStart = handlerStartL,
      handlerEnd   = handlerEndL,
      catchToken   = 0x01000000 + cctx.trException))
    i = i + 1
  }

  // Finally handler: covers the entire try+catch region ([tryStartL, finallyStartL)).
  // `leave` in the try/catch body transfers to afterL; the CLR runs the finally
  // handler before transferring.  `endfinally` resumes the leave target or
  // rethrows the in-flight exception.
  match finally_ {
    case None -> {}
    case Some(fb) -> {
      val finallyStartL = freshLabelMsil(fctx)
      val finallyEndL   = freshLabelMsil(fctx)
      insns.add(MLabel(id = finallyStartL))
      lowerBlockMsil(cctx, fctx, insns, fb)
      insns.add(MEndfinally)
      insns.add(MLabel(id = finallyEndL))
      insns.add(MEHClause(
        flags        = 2,
        tryStart     = tryStartL,
        tryEnd       = finallyStartL,
        handlerStart = finallyStartL,
        handlerEnd   = finallyEndL,
        catchToken   = 0))
    }
  }

  insns.add(MLabel(id = afterL))
}

// Value-producing counterpart of `lowerTryCatchMsil`: a `try { … } catch … { … }`
// used as an expression yields the branch values.  Each branch (the try body and
// every catch handler) is lowered as a value (`lowerBlockExprMsil`), stashed into
// a shared result temp *before* its `leave` (a `leave` requires an empty
// evaluation stack), and the temp is reloaded after the merge label.  Without
// this the statement lowering discarded the branch values, leaving a non-void
// function with no value on the stack → unverifiable IL (#1823).  A `finally`
// (if present) runs as void, exactly as in `lowerTryCatchMsil`.
func lowerTryCatchExprMsil(
  cctx:     in CodegenCtx,
  fctx:     in FuncCtx,
  insns:    in List[MInsn],
  body:     in Block,
  catches:  in List[CatchClause],
  finally_: in Option[Block]
): MsilType {
  val hasCatch   = catches.count > 0
  val hasFinally = match finally_ { case Some(_) -> true case None -> false }
  val tryStartL = freshLabelMsil(fctx)
  val afterL    = freshLabelMsil(fctx)

  insns.add(MLabel(id = tryStartL))
  fctx.tryRegionStack.add(0)
  val tryTy = lowerBlockExprMsil(cctx, fctx, insns, body)
  var resultTy   = tryTy
  var resultSlot = -1
  match tryTy {
    case MVoid -> {}
    case _ -> {
      resultSlot = allocSlotMsil(fctx, "__tryval_" + toString(fctx.slotTicker.count), tryTy)
      emitStoreSlot(insns, resultSlot, fctx.paramCount)
    }
  }
  fctx.tryRegionStack.removeAt(fctx.tryRegionStack.count - 1)
  // `leave` is only valid inside a protected region; mirror the statement-path
  // guard in `lowerTryCatchMsil` so a bare `try { … }` (no catch / no finally)
  // never emits an unverifiable `leave` if the parser is ever relaxed.
  if hasCatch or hasFinally {
    insns.add(MLeave(label = afterL))
  }

  val tryBodyEndL = freshLabelMsil(fctx)
  insns.add(MLabel(id = tryBodyEndL))

  var i = 0
  while i < catches.count {
    val c = catches[i]
    val handlerStartL = freshLabelMsil(fctx)
    insns.add(MLabel(id = handlerStartL))
    match c.bindName {
      case Some(bname) -> {
        val exSlot = allocSlotMsil(fctx, bname, MObject)
        emitStoreSlot(insns, exSlot, fctx.paramCount)
      }
      case None -> {
        insns.add(MPop)
      }
    }
    fctx.tryRegionStack.add(0)
    val catchTy = lowerBlockExprMsil(cctx, fctx, insns, c.body)
    match catchTy {
      case MVoid -> {}
      case _ -> {
        if resultSlot < 0 {
          resultSlot = allocSlotMsil(fctx, "__tryval_" + toString(fctx.slotTicker.count), catchTy)
          resultTy   = catchTy
        }
        emitStoreSlot(insns, resultSlot, fctx.paramCount)
      }
    }
    fctx.tryRegionStack.removeAt(fctx.tryRegionStack.count - 1)
    insns.add(MLeave(label = afterL))
    val handlerEndL = freshLabelMsil(fctx)
    insns.add(MLabel(id = handlerEndL))
    insns.add(MEHClause(
      flags        = 0,
      tryStart     = tryStartL,
      tryEnd       = tryBodyEndL,
      handlerStart = handlerStartL,
      handlerEnd   = handlerEndL,
      catchToken   = 0x01000000 + cctx.trException))
    i = i + 1
  }

  match finally_ {
    case None -> {}
    case Some(fb) -> {
      val finallyStartL = freshLabelMsil(fctx)
      val finallyEndL   = freshLabelMsil(fctx)
      insns.add(MLabel(id = finallyStartL))
      lowerBlockMsil(cctx, fctx, insns, fb)
      insns.add(MEndfinally)
      insns.add(MLabel(id = finallyEndL))
      insns.add(MEHClause(
        flags        = 2,
        tryStart     = tryStartL,
        tryEnd       = finallyStartL,
        handlerStart = finallyStartL,
        handlerEnd   = finallyEndL,
        catchToken   = 0))
    }
  }

  insns.add(MLabel(id = afterL))
  if resultSlot >= 0 {
    emitLoadSlot(insns, resultSlot, fctx.paramCount)
  }
  resultTy
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. Block lowering.
// ─────────────────────────────────────────────────────────────────────────────

pub func lowerBlockMsil(cctx: in CodegenCtx, fctx: in FuncCtx,
                        insns: in List[MInsn], block: in Block): Unit {
  lowerStmtsFromMsil(cctx, fctx, insns, block.statements, 0)
}

// Lower statements[start..] (statement / void context) honouring `defer`.  A
// `defer { D }` runs D at scope exit on every path — normal fall-off, `return`,
// `break`/`continue`, and exception unwind (grammar: "runs on scope exit,
// success or failure").  The statements that follow the defer are therefore
// lowered as `try { rest } finally { D }`; the `finally` runs on fall-off and
// exception, on `return` via the function epilogue's `leave` (D-progress-373),
// and on `break`/`continue` via their `leave` lowering (D-progress-371).
// Multiple defers nest, giving reverse-declaration execution order.  #1477.
func lowerStmtsFromMsil(cctx: in CodegenCtx, fctx: in FuncCtx,
                        insns: in List[MInsn], stmts: in List[Statement],
                        start: in Int): Unit {
  var i = start
  while i < stmts.count {
    match stmts[i].kind {
      case SDefer(deferBody) -> {
        val rest: List[Statement] = newList()
        var j = i + 1
        while j < stmts.count {
          rest.add(stmts[j])
          j = j + 1
        }
        val restBlock = Block(statements = rest, span = stmts[i].span)
        val noCatches: List[CatchClause] = newList()
        lowerTryCatchMsil(cctx, fctx, insns, restBlock, noCatches, Some(value = deferBody))
        return
      }
      case _ -> {
        lowerStmtMsil(cctx, fctx, insns, stmts[i])
      }
    }
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. Function lowering.
// ─────────────────────────────────────────────────────────────────────────────

// Create a fresh FuncCtx.  Parameters are added to `slots` and `types` but
// NOT to `locals` (they are accessed via MLdarg, not MLdloc).
func makeFuncCtxMsil(pkgName: in String, className: in String,
                     funcName: in String,
                     paramCount: in Int, declaredRetTy: in MsilType): FuncCtx {
  val slots:       Map[String, Int]       = newMap()
  val types:       Map[String, MsilType]  = newMap()
  val locals:      List[MsilType]         = newList()
  val slotTicker:  List[Int]              = newList()
  val labelTicker: List[Int]              = newList()
  val loopBreak:   List[Int]              = newList()
  val loopCont:    List[Int]              = newList()
  val loopTryDepth: List[Int]             = newList()
  val tryRegionStack: List[Int]           = newList()
  val epilogueUsed: List[Int]             = newList()
  val yieldSlots:  List[Int]              = newList()
  val contextHintTyArgs: List[MsilType]  = newList()
  val byrefSlotTypes: Map[Int, MsilType] = newMap()
  val funcValRetTypes: Map[String, MsilType] = newMap()
  val boxedParamTypes: Map[Int, MsilType] = newMap()
  val captureNameToIndex: Map[String, Int] = newMap()
  val captureNameToType: Map[String, MsilType] = newMap()
  val mutableLocals: List[String] = newList()
  val hoistedVarNames: List[String] = newList()
  val hoistedCellSlot: Map[String, Int] = newMap()
  val hoistedCellType: Map[String, MsilType] = newMap()
  val captureCellNames: List[String] = newList()
  FuncCtx(
    pkgName              = pkgName,
    className            = className,
    funcName             = funcName,
    slots                = slots,
    types                = types,
    locals               = locals,
    slotTicker           = slotTicker,
    labelTicker          = labelTicker,
    paramCount           = paramCount,
    loopBreak            = loopBreak,
    loopCont             = loopCont,
    loopTryDepth         = loopTryDepth,
    tryRegionStack       = tryRegionStack,
    epilogueLabel        = -1,
    retvalSlot           = -1,
    epilogueUsed         = epilogueUsed,
    yieldSlots           = yieldSlots,
    declaredRetTy        = declaredRetTy,
    contextHintTyArgs    = contextHintTyArgs,
    byrefSlotTypes       = byrefSlotTypes,
    funcValRetTypes      = funcValRetTypes,
    boxedParamTypes      = boxedParamTypes,
    captureNameToIndex   = captureNameToIndex,
    captureNameToType    = captureNameToType,
    mutableLocals        = mutableLocals,
    hoistedVarNames      = hoistedVarNames,
    hoistedCellSlot      = hoistedCellSlot,
    hoistedCellType      = hoistedCellType,
    captureCellNames     = captureCellNames,
    phaseBCtx            = newList())
}

// Check whether the last meaningful instruction in a list is a return or throw.
func endsWithReturnMsil(insns: in List[MInsn]): Bool {
  var i = insns.count - 1
  while i >= 0 {
    match insns[i] {
      case MRet      -> { return true }
      case MThrow    -> { return true }
      case MNop      -> { i = i - 1 }
      // A label may be a branch target from code above (e.g. the after-label
      // of a match expression), so we cannot treat instructions before it as
      // the effective end of the method.  Stop scanning and report "no terminal".
      case MLabel(_) -> { return false }
      case _         -> { return false }
    }
  }
  false
}

// ─────────────────────────────────────────────────────────────────────────────
// §8b. FFI emission for `@externTarget` (#370 + Phase R6).
// ─────────────────────────────────────────────────────────────────────────────

// True iff the annotation list contains `@externTarget("...")`.
func hasExternTargetMsil(anns: in List[Annotation]): Bool {
  var i = 0
  while i < anns.count {
    val segs = anns[i].name.segments
    if segs.count == 1 and segs[0] == "externTarget" { return true }
    i = i + 1
  }
  false
}

// Pull the `"Type.Member"` string out of `@externTarget("...")`.
// Returns "" when the annotation is malformed.
func externTargetStringMsil(anns: in List[Annotation]): String {
  var i = 0
  while i < anns.count {
    val segs = anns[i].name.segments
    if segs.count == 1 and segs[0] == "externTarget" {
      var j = 0
      while j < anns[i].args.count {
        match anns[i].args[j] {
          case ALiteral(v, _) -> match v {
            case AVString(s, _) -> { return s }
            case _              -> ()
          }
          case AAName(_, v, _) -> match v {
            case AVString(s, _) -> { return s }
            case _              -> ()
          }
          case _ -> ()
        }
        j = j + 1
      }
    }
    i = i + 1
  }
  ""
}

// Look up (or add) the AssemblyRef row index for an external
// assembly name.  System.Runtime / mscorlib reuse the pre-seeded
// `lctx.arRuntime` row so we don't write a duplicate.
func internFfiAssemblyRef(cctx: in CodegenCtx, asmName: in String): Int {
  match mapGet(cctx.ffiAsmRefs, asmName) {
    case Some(r) -> r
    case None    -> {
      val row = if asmName == "System.Runtime"
                  or asmName == "System.Private.CoreLib"
                  or asmName == "mscorlib" {
        cctx.lctx.arRuntime
      } else {
        ctxAddAssemblyRef(cctx.lctx, asmName, 10, 0)
      }
      cctx.ffiAsmRefs.add(asmName, row)
      row
    }
  }
}

// Look up (or add) the TypeRef row for a CLR type identified by
// (assembly, namespace, simple name).
func internFfiTypeRef(cctx: in CodegenCtx, asmName: in String,
                      ns: in String, typeName: in String): Int {
  val key = asmName + "/" + ns + "." + typeName
  match mapGet(cctx.ffiTypeRefs, key) {
    case Some(r) -> r
    case None    -> {
      val arRow = internFfiAssemblyRef(cctx, asmName)
      val tRow  = ctxAddTypeRef(cctx.lctx, ns, typeName, arRow)
      cctx.ffiTypeRefs.add(key, tRow)
      tRow
    }
  }
}

// True when `e` is an empty list/slice literal `[]`.
func isEmptyListExprMsil(e: in Expr): Bool {
  match e.kind {
    case EList(exprs) -> exprs.count == 0
    case _            -> false
  }
}

// Emit `System.Array.Empty<elem>()`, leaving the resulting `elem[]` on the
// stack (#1497).  This is the self-hosted backend's first open-generic BCL
// call: it references `System.Array.Empty\`1` via a GENERIC-convention
// MemberRef, instantiates it for `elem` with a MethodSpec row, and emits
// `call <0x2B token>`.  Used to lower an empty typed-slice literal
// (`val xs: slice[T] = []`) to a real empty `T[]` rather than a `List<object>`.
func emitEmptyArrayMsil(cctx: in CodegenCtx, insns: in List[MInsn], elem: in MsilType): Unit {
  // System.Array lives in System.Runtime.
  val arrTypeRef = internFfiTypeRef(cctx, "System.Runtime", "System", "Array")
  // Open-generic MemberRef: Array.Empty`1(): !!0[]  (GENERIC callconv).
  val openSig = buildArrayEmptyOpenSig()
  val mrRow = ctxAddMemberRef(cctx.lctx, arrTypeRef, "Empty", "array_empty_open", openSig)
  // MethodSpec instantiating Empty`1 with the concrete element type.
  val specArgs: List[MsilType] = newList()
  specArgs.add(elem)
  val specBlob = buildMethodSpecBlob(specArgs)
  val msRow = ctxAddMethodSpec(
    cctx.lctx, mdorMemberRef(mrRow),
    "array_empty_spec_" + msilTypeKey(elem), specBlob)
  insns.add(MCall(methodToken = 0x2B000000 + msRow))
}

// Return the TypeRef row for System.Action`N (N ≥ 1).
// TypeRefs are registered lazily on first use for each distinct N and cached
// in cctx.actionTypeRefs to avoid duplicate metadata rows.
func internActionTypeRef(cctx: in CodegenCtx, nparams: in Int): Int {
  val key = toString(nparams)
  match mapGet(cctx.actionTypeRefs, key) {
    case Some(r) -> r
    case None    -> {
      val typeName = "Action`" + key
      val tRow = ctxAddTypeRef(cctx.lctx, "System", typeName, cctx.lctx.arRuntime)
      cctx.actionTypeRefs.add(key, tRow)
      tRow
    }
  }
}

// Build a newobj token for System.Action`N<object,...> (N ≥ 1).
// Encodes a TypeSpec for the closed generic instantiation and returns
// the MemberRef token (0x0A...) for .ctor(object, native int).
func buildActionNCtorTok(cctx: in CodegenCtx, nparams: in Int): Int {
  val trN = internActionTypeRef(cctx, nparams)
  // TypeDefOrRef coded index for a TypeRef at row R: (R << 2) | 1
  val codedIdx = (trN * 4) + 1
  val objArgs: List[MsilType] = newList()
  var ai = 0
  while ai < nparams { objArgs.add(MObject); ai = ai + 1 }
  val gblob = buildGenericInstBlob(codedIdx, objArgs)
  val specKey = "ActionSpec_ctor_" + toString(nparams)
  val tsRow = ctxAddTypeSpec(cctx.lctx, specKey, gblob)
  val ctorPs: List[MsilType] = newList()
  ctorPs.add(MObject)
  ctorPs.add(MNativeInt)
  val ctorSig = buildInstanceMethodSig(ctorPs, MVoid)
  val mrRow = ctxAddMemberRefForTypeSpec(
    cctx.lctx, tsRow, ".ctor",
    "action_ctor_" + toString(nparams), ctorSig)
  0x0A000000 + mrRow
}

// Get or create a TypeRef for System.Func`(nparams+1) where nparams is the lambda parameter count.
// Reuses the actionTypeRefs map with a "func_N" key to avoid collisions.
func internFuncTypeRef(cctx: in CodegenCtx, nparams: in Int): Int {
  val key = "func_" + toString(nparams)
  match mapGet(cctx.actionTypeRefs, key) {
    case Some(r) -> r
    case None    -> {
      val funcArity = nparams + 1
      val typeName = "Func`" + toString(funcArity)
      val tRow = ctxAddTypeRef(cctx.lctx, "System", typeName, cctx.lctx.arRuntime)
      cctx.actionTypeRefs.add(key, tRow)
      tRow
    }
  }
}

// Intern the TypeSpec row for `System.Func`(nparams+1)<object,...,object>`.
// Both the .ctor and the Invoke MemberRef use the same generic-instantiation
// TypeSpec; caching the row here keeps the metadata heap lean (a HOF that
// both constructs and invokes a lambda hits this twice).  Cached in the
// existing `actionTypeRefs` map under a `funcSpec_N` key prefix so the
// underlying `Func`(N+1)` TypeRef cache and this TypeSpec cache share
// storage without colliding.
func internFuncNTypeSpec(cctx: in CodegenCtx, nparams: in Int): Int {
  val cacheKey = "funcSpec_" + toString(nparams)
  match mapGet(cctx.actionTypeRefs, cacheKey) {
    case Some(r) -> r
    case None -> {
      val trN = internFuncTypeRef(cctx, nparams)
      val codedIdx = (trN * 4) + 1
      val objArgs: List[MsilType] = newList()
      var ai = 0
      while ai < nparams + 1 { objArgs.add(MObject); ai = ai + 1 }
      val gblob = buildGenericInstBlob(codedIdx, objArgs)
      val tsRow = ctxAddTypeSpec(cctx.lctx, "FuncSpec_" + toString(nparams), gblob)
      cctx.actionTypeRefs.add(cacheKey, tsRow)
      tsRow
    }
  }
}

// Build a newobj token for System.Func`(nparams+1)<object,...,object>::.ctor(object, nativeint).
// All type parameters are object: nparams input parameters + 1 return type.
func buildFuncNCtorTok(cctx: in CodegenCtx, nparams: in Int): Int {
  val tsRow = internFuncNTypeSpec(cctx, nparams)
  val ctorPs: List[MsilType] = newList()
  ctorPs.add(MObject)
  ctorPs.add(MNativeInt)
  val ctorSig = buildInstanceMethodSig(ctorPs, MVoid)
  val mrRow = ctxAddMemberRefForTypeSpec(
    cctx.lctx, tsRow, ".ctor",
    "func_ctor_" + toString(nparams), ctorSig)
  0x0A000000 + mrRow
}

// Build a callvirt token for System.Func`(nparams+1)<object,...,object>::Invoke(object,...): object.
// Params are type vars 0..nparams-1; the return type is the last type var (nparams).
func buildFuncNInvokeTok(cctx: in CodegenCtx, nparams: in Int): Int {
  val tsRow = internFuncNTypeSpec(cctx, nparams)
  val invokePs: List[MsilType] = newList()
  var pi = 0
  while pi < nparams { invokePs.add(MTypeVar(index = pi)); pi = pi + 1 }
  val invokeSig = buildInstanceMethodSig(invokePs, MTypeVar(index = nparams))
  val mrRow = ctxAddMemberRefForTypeSpec(
    cctx.lctx, tsRow, "Invoke",
    "func_invoke_" + toString(nparams), invokeSig)
  0x0A000000 + mrRow
}

// Build the MSIL body for a `@externTarget`-bearing function.
// Returns true when emission succeeded (caller skips the default
// body lowering); false when the target could not be resolved.
//
// Coverage today:
//   * Static method with primitive / String parameter and return types.
//   * Instance method (receiver = Lyric arg 0) with primitive/string args.
//   * Constructor (..ctor) with primitive/string args.
//   * Extern class types as parameters and return values, lowered via
//     `resolveFfiClassTypeRef` into TypeRef-typed signature blobs.
//
// Deferred: generic types, with-defaults trailing arguments, property
// getters, static field reads.  Programs depending on those forms have
// no in-bundle path yet.
// Resolve an `MClass` FQN to a TypeRef row for use in an FFI method
// signature blob (#1504 part 1).  `className` is the FQN produced by
// `resolveTypeFqn` — either a declared Lyric extern type (mapped to its CLR
// FQN via `cctx.externTypeNames`) or, when it is itself a `System.*` type, a
// direct BCL reference.  Returns -1 for any class that is NOT an
// FFI-resolvable cross-assembly type — the caller falls back to
// `ELEMENT_TYPE_OBJECT` and preserves the prior behaviour rather than
// emitting a malformed TypeRef.  The -1 cases are:
//   - in-bundle user records/unions (no extern boundary at all)
//   - nested `Outer+Inner` types (different ResolutionScope encoding)
//   - external non-`System.*` class types that the user forgot to declare
//     via `extern type` — H8 (unresolved-extern-type hard diagnostic) from
//     the remaining #1504 parts is the long-term fix; the silent
//     `ELEMENT_TYPE_OBJECT` fallback here leaves runtime as the
//     diagnosis surface until that lands.
func resolveFfiClassTypeRef(cctx: in CodegenCtx, className: in String): Int {
  val simple = splitTypeFqn(className).name
  val clrFqn =
    match mapGet(cctx.externTypeNames, simple) {
      case Some(fqn) -> fqn
      case None      -> if startsWith(className, "System.") { className } else { "" }
    }
  if clrFqn == "" { return 0 - 1 }
  // Nested types (ResolutionScope = enclosing TypeRef, not AssemblyRef) need
  // a different encoding than `internFfiTypeRef` provides; skip them safely.
  if contains(clrFqn, "+") { return 0 - 1 }
  val sp  = splitTypeFqn(clrFqn)
  val asm = assemblyForTypeMsil(cctx, clrFqn)
  internFfiTypeRef(cctx, asm, sp.ns, sp.name)
}

// Encode one type into an FFI method-signature blob.  `MClass` resolves to
// `ELEMENT_TYPE_CLASS (0x12) + compressed TypeDefOrRef` when the class is an
// FFI-resolvable cross-assembly type; otherwise it degrades to
// `ELEMENT_TYPE_OBJECT` (the pre-#1504 behaviour).  All other types reuse the
// shared `bufMsilType` encoder.
func bufFfiType(cctx: in CodegenCtx, w: in ByteWriter, t: in MsilType): Unit {
  match t {
    case MClass(className) -> {
      val row = resolveFfiClassTypeRef(cctx, className)
      if row >= 0 {
        bufU1(w, 0x12)                          // ELEMENT_TYPE_CLASS
        writeCompressedInt(w, (row * 4) + 1)    // TypeDefOrRef coded index (TypeRef tag = 1)
      } else {
        bufU1(w, 0x1C)                          // ELEMENT_TYPE_OBJECT fallback
      }
    }
    case _ -> bufMsilType(w, t)
  }
}

// Produce a short, stable string key for a MsilType — used to derive unique
// blob-intern keys for lazily-built TypeSpec / MemberRef tokens (e.g. for
// Task<T>::get_Result() in async extern emission).
func msilTypeKeyStr(t: in MsilType): String {
  match t {
    case MInt             -> "i4"
    case MLong            -> "i8"
    case MDouble          -> "r8"
    case MBool            -> "bool"
    case MChar            -> "char"
    case MString          -> "str"
    case MVoid            -> "void"
    case MObject          -> "obj"
    case MByte            -> "u1"
    case MNativeInt       -> "nint"
    case MArray(elem)     -> "arr_" + msilTypeKeyStr(elem)
    case MClass(name)     -> "cls_" + name
    case MClassRef(_, fqn) -> "clsref_" + fqn
    case MValueTypeRef(_, fqn) -> "vt_" + fqn
    case MTypeVar(idx)    -> "tv" + toString(idx)
    case MByRef(inner)    -> "byref_" + msilTypeKeyStr(inner)
    case MListOf(elem)    -> "list_" + msilTypeKeyStr(elem)
    case MMapOf(k, v)     -> "map_" + msilTypeKeyStr(k) + "_" + msilTypeKeyStr(v)
    case MGenericInst(_, fqn, args) -> {
      var k = "gi_" + fqn
      var ai = 0
      while ai < args.count {
        k = k + "_" + msilTypeKeyStr(args[ai])
        ai = ai + 1
      }
      k
    }
  }
}

// Build a MethodSig blob for an FFI MemberRef, encoding class-typed params /
// return as real TypeRef-backed CLASS entries (#1504 part 1).  `hasThis`
// selects the HASTHIS calling convention (instance methods + ctors); the
// receiver is excluded from `params` by the caller.
func buildFfiMethodSigCtx(
  cctx:    in CodegenCtx,
  params:  in List[MsilType],
  ret:     in MsilType,
  hasThis: in Bool
): List[Byte] {
  val w = bufNew()
  bufU1(w, if hasThis { 0x20 } else { 0x00 })
  bufU1(w, params.count)
  bufFfiType(cctx, w, ret)
  var i = 0
  while i < params.count {
    bufFfiType(cctx, w, params[i])
    i = i + 1
  }
  bufToList(w)
}

func emitExternTargetBody(
  cctx:    in CodegenCtx,
  fctx:    in FuncCtx,
  insns:   in List[MInsn],
  decl:    in FunctionDecl,
  pkgName: in String
): Bool {
  val target = externTargetStringMsil(decl.annotations)
  if target == "" { return false }

  // F0002 (also emitted by the type checker for proof/lint paths,
  // but Msil.Bridge skips type checking — panic here so the user
  // build sees the diagnostic).
  if hasConflictingHints(decl.annotations) {
    panic("Msil.Codegen: function '" + decl.name + "' has both "
      + "@externStatic and @externInstance — pick one (the FFI "
      + "resolver cannot honour both).")
  }

  val hint = hintFromAnnotations(decl.annotations)
  match resolveExternTarget(target, hint) {
    case None -> {
      // The FFI resolver could not locate `target` in any loaded
      // reference assembly.  Falling through with a bare `MRet`
      // produced invalid IL for non-void returns and a runtime
      // VerificationException with no build-time signal (#1041).
      // Emit a runtime stub that throws on call so smoke-test
      // builds (declare-but-never-call) still build cleanly and
      // actual call sites get a clear runtime error.
      val msg = "FFI extern '" + target + "' on '" + decl.name
        + "' could not be resolved to a method on any loaded "
        + "reference assembly; check the @externTarget annotation."
      val msgTok = ctxInternUs(cctx.lctx, msg)
      insns.add(MLdStr(token = msgTok))
      insns.add(MNewobj(ctorToken = cctx.tokExceptionCtor))
      insns.add(MThrow)
      true
    }
    case Some(r) -> {
      // Map every Lyric param + return type to MSIL.  Use the ctx-aware
      // variant so cross-package type references in the signature
      // (e.g. `func describe(m: in Maybe[Int])` where `Maybe` lives in
      // an imported package) resolve to the correct FQN instead of the
      // legacy `<currentPkg>.<seg>` placeholder.
      val paramTypes: List[MsilType] = newList()
      var pi = 0
      while pi < decl.params.count {
        val baseTy = typeExprToMsilCtx(cctx, decl.params[pi].ty, pkgName)
        val finalTy = if isByrefMode(decl.params[pi].mode) { MByRef(inner = baseTy) } else { baseTy }
        paramTypes.add(finalTy)
        pi = pi + 1
      }
      val retTy = match decl.ret {
        case Some(te) -> typeExprToMsilCtx(cctx, te, pkgName)
        case None     -> MVoid
      }

      // The bootstrap-grade FFI resolver hasn't wired up TypeRef-
      // encoded MemberRef signatures yet, so externs whose Lyric
      // signature mentions a non-primitive class type can't emit a
      // direct call yet.  Earlier the codegen returned `false` and
      // the default lowering emitted bare `MRet` — invalid MSIL for
      // non-void returns and a runtime VerificationException with no
      // build-time signal (#791).  Now we emit a *runtime stub* that
      // unconditionally throws a System.Exception carrying the
      // diagnostic message.  The build succeeds (so examples that
      // declare these externs but never call them at runtime — the
      // smoke-test case — still build cleanly), and any call site
      // Class-typed params / return are now encoded as real TypeRef-backed
      // CLASS entries in the signature blob (#1504 part 1) via
      // `buildFfiMethodSigCtx`, so the runtime-throw bail that previously
      // fired for class-typed FFI signatures is gone.

      // An extern type the FFI cascade can't resolve to a known reference
      // assembly used to silently bind to `System.Runtime`, then fail at
      // runtime with an opaque `TypeLoadException`.  Fail the build with a
      // clear, type-specific diagnostic instead (matching the
      // `@externStatic`/`@externInstance` conflict panic above).
      val resolvedFqn =
        if r.namespaceStr == "" { r.typeName }
        else { r.namespaceStr + "." + r.typeName }
      if not clrAssemblyResolvable(resolvedFqn) {
        panic("Msil.Codegen: FFI extern '" + target + "' on '" + decl.name
          + "' references type '" + resolvedFqn + "', which cannot be resolved "
          + "to a known reference assembly (only System.* and the Lyric host "
          + "assemblies are supported); check the @externTarget annotation for "
          + "a typo or an unsupported type.")
      }

      val asmName = assemblyForTypeMsil(cctx, resolvedFqn)
      val tRefRow = internFfiTypeRef(
        cctx, asmName, r.namespaceStr, r.typeName)

      // Build the method signature blob, encoding class-typed params/return
      // against their resolved TypeRefs.
      //
      // For async externs the BCL method returns Task (void) or Task<T> (non-void T).
      // Encode the actual BCL return type in the MemberRef so the CLR can resolve the
      // method at JIT time.  retTy (the Lyric-declared T) is used only for the unwrap
      // callvirt appended below.  Ctors are never async in the BCL; skip them.
      val bclRetTy =
        if decl.isAsync and not r.isCtor {
          val isVoidRet = match retTy { case MVoid -> true case _ -> false }
          if isVoidRet {
            MClassRef(typeRefCode = tdrTypeRef(cctx.trTask),
                      clrFqn = "System.Threading.Tasks.Task")
          } else {
            val taskArgs: List[MsilType] = newList()
            taskArgs.add(retTy)
            MGenericInst(typeRefCode = tdrTypeRef(cctx.trTask1),
                         headFqn = "System.Threading.Tasks.Task",
                         typeArgs = taskArgs)
          }
        } else {
          retTy
        }
      val sig =
        if r.isStatic and not r.isCtor {
          buildFfiMethodSigCtx(cctx, paramTypes, bclRetTy, false)
        } else if r.isCtor {
          // .ctor: HASTHIS, void return, all params explicit.
          buildFfiMethodSigCtx(cctx, paramTypes, MVoid, true)
        } else {
          // Instance method: skip the first Lyric param (it's the
          // receiver — already on the stack as `this`).
          val instArgs: List[MsilType] = newList()
          var ii = 1
          while ii < paramTypes.count {
            instArgs.add(paramTypes[ii])
            ii = ii + 1
          }
          buildFfiMethodSigCtx(cctx, instArgs, bclRetTy, true)
        }
      val mrRow = ctxAddMemberRef(
        cctx.lctx, tRefRow, r.memberName,
        "ffi_" + target, sig)
      val tok = 0x0A000000 + mrRow

      // Load every Lyric param in order.  For instance calls the
      // receiver is param 0 and lands on the stack first; for static
      // calls every param is explicit.
      var li = 0
      while li < decl.params.count {
        insns.add(MLdarg(slot = li))
        li = li + 1
      }
      if r.isCtor {
        insns.add(MNewobj(ctorToken = tok))
      } else if r.isStatic {
        insns.add(MCall(methodToken = tok))
      } else {
        insns.add(MCallvirt(methodToken = tok))
      }
      // For `@externTarget async func`, the BCL method returns Task / Task<T>.
      // Synchronously unwrap to T so the Lyric caller sees the declared return
      // type directly — callers use `await` which is a no-op for synchronous
      // results, so the stack type is always T after this point (Phase A).
      if decl.isAsync {
        val isVoidRet = match retTy { case MVoid -> true case _ -> false }
        if isVoidRet {
          // BCL method returned Task (void). Call Task::Wait() to block.
          insns.add(MCallvirt(methodToken = cctx.tokTaskWait))
        } else {
          // BCL method returned Task<T>. Call Task<T>.get_Result() to unwrap to T.
          val tsArgs: List[MsilType] = newList()
          tsArgs.add(retTy)
          val tsBlob = buildGenericInstBlobWithCtx(cctx.lctx, tdrTypeRef(cctx.trTask1), tsArgs)
          val tsKey = "ts_task1_result_" + msilTypeKeyStr(retTy)
          val tsRow = ctxAddTypeSpec(cctx.lctx, tsKey, tsBlob)
          val mrSig = buildInstanceMethodSig(newList(), MTypeVar(0))
          val mrRow = ctxAddMemberRefForTypeSpec(
            cctx.lctx, tsRow, "get_Result",
            "mr_task_getresult_" + tsKey, mrSig)
          insns.add(MCallvirt(methodToken = 0x0A000000 + mrRow))
        }
      }
      insns.add(MRet)
      true
    }
  }
}

// True when a function body (or expression) contains at least one EYield node.
func exprContainsYieldMsil(e: in Expr): Bool {
  match e.kind {
    case EYield(_)         -> true
    case EBlock(b)         -> blockContainsYieldMsil(b)
    case EUnsafe(b)        -> blockContainsYieldMsil(b)
    case EIf(c, t, el, _) -> {
      if exprContainsYieldMsil(c) { return true }
      val tRes = match t {
        case EOBExpr(ex)   -> exprContainsYieldMsil(ex)
        case EOBBlock(blk) -> blockContainsYieldMsil(blk)
      }
      if tRes { return true }
      match el {
        case Some(elB) -> match elB {
          case EOBExpr(ex)   -> exprContainsYieldMsil(ex)
          case EOBBlock(blk) -> blockContainsYieldMsil(blk)
        }
        case None -> false
      }
    }
    case ECall(fn, args) -> {
      if exprContainsYieldMsil(fn) { return true }
      var ai = 0
      while ai < args.count {
        val res = match args[ai] {
          case CAPositional(ex) -> exprContainsYieldMsil(ex)
          case CANamed(_, ex, _) -> exprContainsYieldMsil(ex)
        }
        if res { return true }
        ai = ai + 1
      }
      false
    }
    case EBinop(_, l, r)  -> exprContainsYieldMsil(l) or exprContainsYieldMsil(r)
    case EPrefix(_, op)   -> exprContainsYieldMsil(op)
    case EParen(inner)    -> exprContainsYieldMsil(inner)
    case EMember(recv, _) -> exprContainsYieldMsil(recv)
    case EAwait(inner)    -> exprContainsYieldMsil(inner)
    case ESpawn(inner)    -> exprContainsYieldMsil(inner)
    case ETry(inner)      -> exprContainsYieldMsil(inner)
    case EPropagate(inner) -> exprContainsYieldMsil(inner)
    case EMatch(scr, arms) -> {
      if exprContainsYieldMsil(scr) { return true }
      var ai = 0
      while ai < arms.count {
        val res = match arms[ai].body {
          case EOBExpr(ex)   -> exprContainsYieldMsil(ex)
          case EOBBlock(blk) -> blockContainsYieldMsil(blk)
        }
        if res { return true }
        ai = ai + 1
      }
      false
    }
    case _ -> false
  }
}

func stmtContainsYieldMsil(s: in Statement): Bool {
  match s.kind {
    case SExpr(e)  -> exprContainsYieldMsil(e)
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init)    -> exprContainsYieldMsil(init)
        case LBLet(_, _, init)    -> exprContainsYieldMsil(init)
        case LBVar(_, _, initOpt) -> match initOpt {
          case Some(init) -> exprContainsYieldMsil(init)
          case None       -> false
        }
      }
    }
    case SReturn(valOpt) -> match valOpt {
      case Some(e) -> exprContainsYieldMsil(e)
      case None    -> false
    }
    case SAssign(_, _, v) -> exprContainsYieldMsil(v)
    case SThrow(e)        -> exprContainsYieldMsil(e)
    case SWhile(_, c, b)  -> exprContainsYieldMsil(c) or blockContainsYieldMsil(b)
    case SFor(_, _, i, b) -> exprContainsYieldMsil(i) or blockContainsYieldMsil(b)
    case SLoop(_, b)      -> blockContainsYieldMsil(b)
    case SScope(_, b)     -> blockContainsYieldMsil(b)
    case SDefer(b)        -> blockContainsYieldMsil(b)
    case STry(b, catches, finally_) -> {
      if blockContainsYieldMsil(b) { return true }
      var ci = 0
      while ci < catches.count {
        if blockContainsYieldMsil(catches[ci].body) { return true }
        ci = ci + 1
      }
      match finally_ {
        case None     -> false
        case Some(fb) -> blockContainsYieldMsil(fb)
      }
    }
    case _ -> false
  }
}

func blockContainsYieldMsil(block: in Block): Bool {
  var i = 0
  while i < block.statements.count {
    if stmtContainsYieldMsil(block.statements[i]) { return true }
    i = i + 1
  }
  false
}

func funcBodyContainsYieldMsil(decl: in FunctionDecl): Bool {
  match decl.body {
    case Some(body) -> match body {
      case FBBlock(blk) -> blockContainsYieldMsil(blk)
      case FBExpr(e)    -> exprContainsYieldMsil(e)
    }
    case None -> false
  }
}

func exprContainsAwaitMsil(e: in Expr): Bool {
  match e.kind {
    case EAwait(_)         -> true
    case EBlock(b)         -> blockContainsAwaitMsil(b)
    case EUnsafe(b)        -> blockContainsAwaitMsil(b)
    case EIf(c, t, el, _) -> {
      if exprContainsAwaitMsil(c) { return true }
      val tRes = match t {
        case EOBExpr(ex)   -> exprContainsAwaitMsil(ex)
        case EOBBlock(blk) -> blockContainsAwaitMsil(blk)
      }
      if tRes { return true }
      match el {
        case Some(elB) -> match elB {
          case EOBExpr(ex)   -> exprContainsAwaitMsil(ex)
          case EOBBlock(blk) -> blockContainsAwaitMsil(blk)
        }
        case None -> false
      }
    }
    case ECall(fn, args) -> {
      if exprContainsAwaitMsil(fn) { return true }
      var ai = 0
      while ai < args.count {
        val res = match args[ai] {
          case CAPositional(ex) -> exprContainsAwaitMsil(ex)
          case CANamed(_, ex, _) -> exprContainsAwaitMsil(ex)
        }
        if res { return true }
        ai = ai + 1
      }
      false
    }
    case EBinop(_, l, r)  -> exprContainsAwaitMsil(l) or exprContainsAwaitMsil(r)
    case EPrefix(_, op)   -> exprContainsAwaitMsil(op)
    case EParen(inner)    -> exprContainsAwaitMsil(inner)
    case EMember(recv, _) -> exprContainsAwaitMsil(recv)
    case ESpawn(inner)    -> exprContainsAwaitMsil(inner)
    case ETry(inner)      -> exprContainsAwaitMsil(inner)
    case EPropagate(inner) -> exprContainsAwaitMsil(inner)
    case EMatch(scr, arms) -> {
      if exprContainsAwaitMsil(scr) { return true }
      var ai = 0
      while ai < arms.count {
        val res = match arms[ai].body {
          case EOBExpr(ex)   -> exprContainsAwaitMsil(ex)
          case EOBBlock(blk) -> blockContainsAwaitMsil(blk)
        }
        if res { return true }
        ai = ai + 1
      }
      false
    }
    case _ -> false
  }
}

func stmtContainsAwaitMsil(s: in Statement): Bool {
  match s.kind {
    case SExpr(e)  -> exprContainsAwaitMsil(e)
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init)    -> exprContainsAwaitMsil(init)
        case LBLet(_, _, init)    -> exprContainsAwaitMsil(init)
        case LBVar(_, _, initOpt) -> match initOpt {
          case Some(init) -> exprContainsAwaitMsil(init)
          case None       -> false
        }
      }
    }
    case SReturn(valOpt) -> match valOpt {
      case Some(e) -> exprContainsAwaitMsil(e)
      case None    -> false
    }
    case SAssign(_, _, v) -> exprContainsAwaitMsil(v)
    case SThrow(e)        -> exprContainsAwaitMsil(e)
    case SWhile(_, c, b)  -> exprContainsAwaitMsil(c) or blockContainsAwaitMsil(b)
    case SFor(_, _, i, b) -> exprContainsAwaitMsil(i) or blockContainsAwaitMsil(b)
    case SLoop(_, b)      -> blockContainsAwaitMsil(b)
    case SScope(_, b)     -> blockContainsAwaitMsil(b)
    case SDefer(b)        -> blockContainsAwaitMsil(b)
    case STry(b, catches, finally_) -> {
      if blockContainsAwaitMsil(b) { return true }
      var ci = 0
      while ci < catches.count {
        if blockContainsAwaitMsil(catches[ci].body) { return true }
        ci = ci + 1
      }
      match finally_ {
        case None     -> false
        case Some(fb) -> blockContainsAwaitMsil(fb)
      }
    }
    case _ -> false
  }
}

func blockContainsAwaitMsil(block: in Block): Bool {
  var i = 0
  while i < block.statements.count {
    if stmtContainsAwaitMsil(block.statements[i]) { return true }
    i = i + 1
  }
  false
}

func funcBodyContainsAwaitMsil(decl: in FunctionDecl): Bool {
  match decl.body {
    case Some(body) -> match body {
      case FBBlock(blk) -> blockContainsAwaitMsil(blk)
      case FBExpr(e)    -> exprContainsAwaitMsil(e)
    }
    case None -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §9b. IAsyncStateMachine synthesis for user-defined `async func` (Phase B.0).
//
// Synthesises a sealed class (SM) implementing `IAsyncStateMachine` and
// rewrites the user function as a kickoff stub.  Phase B.0 covers the
// no-await case only: MoveNext runs the user body synchronously, sets
// state = -2, calls SetResult, and returns.  Phase B.1 (real suspension)
// is deferred to a follow-up.
//
// The synthesised SM class layout:
//   __state:   Int            state machine state (-1 = initial, -2 = done)
//   __builder: ATMB or ATMB<T>  task builder (void or non-void)
//   __p0..N:   param types   copy of the user function's parameters
//
// MoveNext body:
//   preamble: ldarg.0; ldfld __p_i; stloc local_i   (for each user param)
//   user body (normal lowering, params read from locals)
//   epilogue:
//     ldarg.0; ldc.i4 -2; stfld __state
//     ldarg.0; ldflda __builder; [result if non-void]; call SetResult
//     ret
//
// Kickoff body (replaces the user func declaration):
//   newobj SM; stloc sm
//   ldloc sm; call ATMB.Create(); stfld __builder   (or ATMB<T>.Create())
//   ldloc sm; ldc.i4 -1; stfld __state
//   ldloc sm; ldarg.0; stfld __p0   (for each user param)
//   ...
//   ldloc sm; ldflda __builder; ldloca sm; call ATMB.Start<SM>(ref SM)
//   ldloc sm; ldflda __builder; call get_Task
//   ret
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// Phase B.1 async SM helpers — GetAwaiter / IsCompleted / GetResult / pre-scan
// ─────────────────────────────────────────────────────────────────────────────

// Get the T from Task<T> (or MVoid for plain Task).
func taskResultType(taskTy: in MsilType): MsilType {
  match taskTy {
    case MGenericInst(_, _, args) -> if args.count > 0 { args[0] } else { MVoid }
    case _                        -> MVoid
  }
}

// Build the concrete MsilType for the awaiter from a Task MsilType.
// Task<T> → TaskAwaiter<T>  (value type generic)
// Task    → TaskAwaiter     (value type ref)
func taskTypeToAwaiterMsilType(cctx: in CodegenCtx, taskTy: in MsilType): MsilType {
  match taskTy {
    case MGenericInst(_, _, args) -> {
      if args.count > 0 {
        val tArgs: List[MsilType] = newList()
        tArgs.add(args[0])
        MValueTypeGenericInst(
          typeRefCode = tdrTypeRef(cctx.trTaskAwaiter1),
          headFqn     = "System.Runtime.CompilerServices.TaskAwaiter`1",
          typeArgs    = tArgs)
      } else {
        MValueTypeRef(typeRefCode = tdrTypeRef(cctx.trTaskAwaiter),
                      clrFqn = "System.Runtime.CompilerServices.TaskAwaiter")
      }
    }
    case _ -> MValueTypeRef(typeRefCode = tdrTypeRef(cctx.trTaskAwaiter),
                            clrFqn = "System.Runtime.CompilerServices.TaskAwaiter")
  }
}

// True when ty is the IL representation of Task (void) or Task<T> (non-void).
// Used by the EAwait handler and pre-scan to distinguish real async awaitables
// from already-resolved values — e.g. a blocking @externTarget async function
// returns T (not Task<T>) from its Lyric wrapper, so `await externFn()` should
// pass the value through without invoking GetAwaiter/GetResult again.
func isTaskTypeMsil(cctx: in CodegenCtx, ty: in MsilType): Bool {
  match ty {
    case MGenericInst(trCode, _, _) -> trCode == tdrTypeRef(cctx.trTask1)
    case MClassRef(trCode, _)       -> trCode == tdrTypeRef(cctx.trTask)
    case _                          -> false
  }
}

// Emit the GetAwaiter() call on the value currently on the stack (Task<T> or Task).
// Leaves the awaiter (value type) on the stack.
func emitGetAwaiterCallPB(cctx: in CodegenCtx, insns: in List[MInsn], taskTy: in MsilType): Unit {
  val lctx   = cctx.lctx
  val resT   = taskResultType(taskTy)
  val tyKey  = msilTypeKey(resT)
  if resT == MVoid {
    // Task.GetAwaiter() → TaskAwaiter  (non-generic)
    val awRetTy = MValueTypeRef(typeRefCode = tdrTypeRef(cctx.trTaskAwaiter),
                                clrFqn = "System.Runtime.CompilerServices.TaskAwaiter")
    val gaArgs: List[MsilType] = newList()
    val gaSig  = buildInstanceMethodSig(gaArgs, awRetTy)
    val gaMrRow = ctxAddMemberRef(lctx, cctx.trTask, "GetAwaiter",
                                  "task_getawaiter_void", gaSig)
    insns.add(MCall(methodToken = 0x0A000000 + gaMrRow))
  } else {
    // Task<T>.GetAwaiter() → TaskAwaiter<T>  (generic, TypeSpec parent)
    val tsArgs: List[MsilType] = newList()
    tsArgs.add(resT)
    val tsBlob = buildGenericInstBlobWithCtx(lctx, tdrTypeRef(cctx.trTask1), tsArgs)
    val tsRow  = ctxAddTypeSpec(lctx, "task1_ts_" + tyKey, tsBlob)
    // Return sig uses VAR 0 (class type param of Task`1)
    val awVarArgs: List[MsilType] = newList()
    awVarArgs.add(MTypeVar(index = 0))
    val awRetTy1 = MValueTypeGenericInst(typeRefCode = tdrTypeRef(cctx.trTaskAwaiter1),
                                         headFqn     = "System.Runtime.CompilerServices.TaskAwaiter`1",
                                         typeArgs    = awVarArgs)
    val gaArgs1: List[MsilType] = newList()
    val gaSig1  = buildInstanceMethodSig(gaArgs1, awRetTy1)
    val gaMrRow1 = ctxAddMemberRefForTypeSpec(lctx, tsRow, "GetAwaiter",
                                              "task1_getawaiter_" + tyKey, gaSig1)
    insns.add(MCall(methodToken = 0x0A000000 + gaMrRow1))
  }
}

// Emit get_IsCompleted on the awaiter at the address currently on the stack.
// Leaves a bool on the stack.
func emitGetIsCompletedCallPB(cctx: in CodegenCtx, insns: in List[MInsn],
                               awTy: in MsilType): Unit {
  val lctx  = cctx.lctx
  val icArgs: List[MsilType] = newList()
  val icSig  = buildInstanceMethodSig(icArgs, MBool)
  match awTy {
    case MValueTypeRef(_, _) -> {
      // TaskAwaiter (non-generic)
      val icMrRow = ctxAddMemberRef(lctx, cctx.trTaskAwaiter, "get_IsCompleted",
                                    "taskaw_iscomp_void", icSig)
      insns.add(MCall(methodToken = 0x0A000000 + icMrRow))
    }
    case MValueTypeGenericInst(_, _, tArgs) -> {
      // TaskAwaiter<T> — TypeSpec parent
      val awKey  = msilTypeKey(if tArgs.count > 0 { tArgs[0] } else { MVoid })
      val awTsArgs: List[MsilType] = newList()
      if tArgs.count > 0 { awTsArgs.add(tArgs[0]) }
      val awTsBlob = buildValueTypeGenericInstBlobWithCtx(lctx, tdrTypeRef(cctx.trTaskAwaiter1), awTsArgs)
      val awTsRow  = ctxAddTypeSpec(lctx, "taskaw1_ts_" + awKey, awTsBlob)
      val icMrRow1 = ctxAddMemberRefForTypeSpec(lctx, awTsRow, "get_IsCompleted",
                                                "taskaw1_iscomp_" + awKey, icSig)
      insns.add(MCall(methodToken = 0x0A000000 + icMrRow1))
    }
    case _ -> {}
  }
}

// Emit GetResult on the awaiter at the address on the stack.
// Leaves T on the stack (or nothing for void).  Returns the result MsilType.
func emitGetResultCallPB(cctx: in CodegenCtx, insns: in List[MInsn],
                          awTy: in MsilType): MsilType {
  val lctx  = cctx.lctx
  match awTy {
    case MValueTypeRef(_, _) -> {
      // TaskAwaiter.GetResult() → void
      val grArgs: List[MsilType] = newList()
      val grSig  = buildInstanceMethodSig(grArgs, MVoid)
      val grMrRow = ctxAddMemberRef(lctx, cctx.trTaskAwaiter, "GetResult",
                                    "taskaw_getresult_void", grSig)
      insns.add(MCall(methodToken = 0x0A000000 + grMrRow))
      MVoid
    }
    case MValueTypeGenericInst(_, _, tArgs) -> {
      // TaskAwaiter<T>.GetResult() → VAR 0  (TypeSpec parent)
      val resT   = if tArgs.count > 0 { tArgs[0] } else { MVoid }
      val awKey  = msilTypeKey(resT)
      val awTsArgs: List[MsilType] = newList()
      awTsArgs.add(resT)
      val awTsBlob = buildValueTypeGenericInstBlobWithCtx(lctx, tdrTypeRef(cctx.trTaskAwaiter1), awTsArgs)
      val awTsRow  = ctxAddTypeSpec(lctx, "taskaw1_ts_" + awKey, awTsBlob)
      val grArgs1: List[MsilType] = newList()
      val grSig1  = buildInstanceMethodSig(grArgs1, MTypeVar(index = 0))
      val grMrRow1 = ctxAddMemberRefForTypeSpec(lctx, awTsRow, "GetResult",
                                                "taskaw1_getresult_" + awKey, grSig1)
      insns.add(MCall(methodToken = 0x0A000000 + grMrRow1))
      resT
    }
    case _ -> MVoid
  }
}

// Blocking synchronous await for non-SM contexts (test bodies, plain funcs).
// Stack pre-condition:  Task<T> or Task.
// Stack post-condition: T (or nothing for void).
// Returns the result MsilType.
func emitBlockingAwait(cctx: in CodegenCtx, fctx: in FuncCtx,
                       insns: in List[MInsn], taskTy: in MsilType): MsilType {
  emitGetAwaiterCallPB(cctx, insns, taskTy)
  val awTy = taskTypeToAwaiterMsilType(cctx, taskTy)
  val awSlot = allocSlotMsil(fctx, "__bloaw_" + toString(fctx.slotTicker.count), awTy)
  val awLocalIdx = awSlot - fctx.paramCount
  insns.add(MStloc(slot = awLocalIdx))
  insns.add(MLdloca(slot = awLocalIdx))
  emitGetResultCallPB(cctx, insns, awTy)
}

// ── Pre-scan helpers: collect awaiter types in body-evaluation order ──────────

// Infer the MsilType that would be on the stack after evaluating expression `e`
// in the context of a Phase B pre-scan.  Only used to determine the awaiter type
// for EAwait sites, so precision matters only for expressions that produce Tasks.
//
// spawnNms/spawnTys are parallel lists tracking `val x = spawn f()` bindings:
// spawnNms[i] is the local name, spawnTys[i] is its Task<T> type.
// This lets `await x` resolve to the correct TaskAwaiter<T> field.
func inferCallReturnTypePB(cctx: in CodegenCtx, pkgName: in String, e: in Expr,
                            spawnNms: in List[String],
                            spawnTys: in List[MsilType]): MsilType {
  match e.kind {
    case EParen(inner) -> inferCallReturnTypePB(cctx, pkgName, inner, spawnNms, spawnTys)
    case ESpawn(inner) -> inferCallReturnTypePB(cctx, pkgName, inner, spawnNms, spawnTys)
    case EPath(path) -> {
      if path.segments.count == 1 {
        val lookupName = path.segments[0]
        var si = 0
        var found: MsilType = MObject
        while si < spawnNms.count {
          if spawnNms[si] == lookupName {
            found = spawnTys[si]
          }
          si = si + 1
        }
        found
      } else {
        MObject
      }
    }
    case ECall(callee, args) -> {
      match callee.kind {
        case EPath(path) -> {
          val cnt = args.count
          if path.segments.count == 1 {
            val fqn = pkgName + "." + path.segments[0] + "/" + toString(cnt)
            match mapGet(cctx.funcRetTypes, fqn) {
              case Some(ty) -> ty
              case None -> {
                val fqn2 = pkgName + "." + path.segments[0]
                match mapGet(cctx.funcRetTypes, fqn2) {
                  case Some(ty) -> ty
                  case None     -> MObject
                }
              }
            }
          } else if path.segments.count >= 2 {
            val fqn = joinSegsMsil(path.segments, ".") + "/" + toString(cnt)
            match mapGet(cctx.funcRetTypes, fqn) {
              case Some(ty) -> ty
              case None -> {
                val fqn2 = joinSegsMsil(path.segments, ".")
                match mapGet(cctx.funcRetTypes, fqn2) {
                  case Some(ty) -> ty
                  case None     -> MObject
                }
              }
            }
          } else {
            MObject
          }
        }
        case _ -> MObject
      }
    }
    case _ -> MObject
  }
}

func collectAwaitTypesExprPB(cctx: in CodegenCtx, pkgName: in String,
                              e: in Expr, acc: in List[MsilType],
                              spawnNms: in List[String],
                              spawnTys: in List[MsilType]): Unit {
  match e.kind {
    case EAwait(inner) -> {
      val taskTy = inferCallReturnTypePB(cctx, pkgName, inner, spawnNms, spawnTys)
      // Only allocate an awaiter field for real async Tasks.  Blocking
      // @externTarget async functions return T (not Task<T>) from their Lyric
      // wrapper; `await externFn()` is a pass-through and needs no field.
      if isTaskTypeMsil(cctx, taskTy) {
        val awTy = taskTypeToAwaiterMsilType(cctx, taskTy)
        acc.add(awTy)
      }
    }
    case EBlock(blk) -> collectAwaitTypesBlockPB(cctx, pkgName, blk, acc, spawnNms, spawnTys)
    case EParen(inner) -> collectAwaitTypesExprPB(cctx, pkgName, inner, acc, spawnNms, spawnTys)
    case ESpawn(inner) -> collectAwaitTypesExprPB(cctx, pkgName, inner, acc, spawnNms, spawnTys)
    case EIf(c, t, el, _) -> {
      collectAwaitTypesExprPB(cctx, pkgName, c, acc, spawnNms, spawnTys)
      match t {
        case EOBBlock(b)  -> collectAwaitTypesBlockPB(cctx, pkgName, b, acc, spawnNms, spawnTys)
        case EOBExpr(e2)  -> collectAwaitTypesExprPB(cctx, pkgName, e2, acc, spawnNms, spawnTys)
      }
      match el {
        case Some(els) -> match els {
          case EOBBlock(b)  -> collectAwaitTypesBlockPB(cctx, pkgName, b, acc, spawnNms, spawnTys)
          case EOBExpr(e3)  -> collectAwaitTypesExprPB(cctx, pkgName, e3, acc, spawnNms, spawnTys)
        }
        case None -> {}
      }
    }
    case ECall(callee, args) -> {
      collectAwaitTypesExprPB(cctx, pkgName, callee, acc, spawnNms, spawnTys)
      var aci = 0
      while aci < args.count {
        val argExpr = match args[aci] {
          case CAPositional(ex)    -> ex
          case CANamed(_, ex, _)   -> ex
        }
        collectAwaitTypesExprPB(cctx, pkgName, argExpr, acc, spawnNms, spawnTys)
        aci = aci + 1
      }
    }
    case EBinop(_, l, r) -> {
      collectAwaitTypesExprPB(cctx, pkgName, l, acc, spawnNms, spawnTys)
      collectAwaitTypesExprPB(cctx, pkgName, r, acc, spawnNms, spawnTys)
    }
    case _ -> {}
  }
}

func collectAwaitTypesBlockPB(cctx: in CodegenCtx, pkgName: in String,
                               blk: in Block, acc: in List[MsilType],
                               spawnNms: in List[String],
                               spawnTys: in List[MsilType]): Unit {
  var i = 0
  while i < blk.statements.count {
    collectAwaitTypesStmtPB(cctx, pkgName, blk.statements[i], acc, spawnNms, spawnTys)
    i = i + 1
  }
}

func collectAwaitTypesStmtPB(cctx: in CodegenCtx, pkgName: in String,
                               stmt: in Statement, acc: in List[MsilType],
                               spawnNms: in List[String],
                               spawnTys: in List[MsilType]): Unit {
  match stmt.kind {
    case SLocal(binding) -> match binding {
      case LBVal(_, _, init)    -> collectAwaitTypesExprPB(cctx, pkgName, init, acc, spawnNms, spawnTys)
      case LBLet(_, _, init)    -> collectAwaitTypesExprPB(cctx, pkgName, init, acc, spawnNms, spawnTys)
      case LBVar(_, _, initOpt) -> match initOpt {
        case Some(init) -> collectAwaitTypesExprPB(cctx, pkgName, init, acc, spawnNms, spawnTys)
        case None       -> {}
      }
    }
    case SExpr(e)        -> collectAwaitTypesExprPB(cctx, pkgName, e, acc, spawnNms, spawnTys)
    case SReturn(valOpt) -> match valOpt {
      case Some(e) -> collectAwaitTypesExprPB(cctx, pkgName, e, acc, spawnNms, spawnTys)
      case None    -> {}
    }
    case SAssign(_, _, value) -> collectAwaitTypesExprPB(cctx, pkgName, value, acc, spawnNms, spawnTys)
    case SThrow(expr)         -> collectAwaitTypesExprPB(cctx, pkgName, expr, acc, spawnNms, spawnTys)
    case SWhile(_, cond, body) -> {
      collectAwaitTypesExprPB(cctx, pkgName, cond, acc, spawnNms, spawnTys)
      collectAwaitTypesBlockPB(cctx, pkgName, body, acc, spawnNms, spawnTys)
    }
    case SFor(_, _, iter, body) -> {
      collectAwaitTypesExprPB(cctx, pkgName, iter, acc, spawnNms, spawnTys)
      collectAwaitTypesBlockPB(cctx, pkgName, body, acc, spawnNms, spawnTys)
    }
    case SLoop(_, body)  -> collectAwaitTypesBlockPB(cctx, pkgName, body, acc, spawnNms, spawnTys)
    case SScope(_, body) -> collectAwaitTypesBlockPB(cctx, pkgName, body, acc, spawnNms, spawnTys)
    case STry(body, catches, finally_) -> {
      collectAwaitTypesBlockPB(cctx, pkgName, body, acc, spawnNms, spawnTys)
      var ci = 0
      while ci < catches.count {
        collectAwaitTypesBlockPB(cctx, pkgName, catches[ci].body, acc, spawnNms, spawnTys)
        ci = ci + 1
      }
      match finally_ {
        case Some(fb) -> collectAwaitTypesBlockPB(cctx, pkgName, fb, acc, spawnNms, spawnTys)
        case None     -> {}
      }
    }
    case _ -> {}
  }
}

// Return a List<MsilType> of awaiter types for each real-async EAwait in the
// body, in the order they would be encountered during lowering.  Blocking
// @externTarget async awaits are excluded (their values are already resolved).
//
// Spawn tracking: `val h = spawn asyncFn(x)` bindings are collected in a flat
// pre-scan (top-level block statements only) before the recursive scan so that
// `await h` later resolves the correct TaskAwaiter<T> type.  Mutation of the
// spawn lists only happens on LOCAL variables in this function (not on params
// passed into recursion), which avoids the F# bootstrap emitter limitation where
// two-arg .add() and one-arg .add() on `in Map[K,V]` / `in List[T]` parameters
// may fail BCL dispatch when type args include non-BCL Lyric types.
func collectAwaitTypesPhaseBMsil(cctx: in CodegenCtx, pkgName: in String,
                                  decl: in FunctionDecl): List[MsilType] {
  val result:   List[MsilType] = newList()
  val spawnNms: List[String]   = newList()
  val spawnTys: List[MsilType] = newList()

  // Phase 1: flat top-level pre-scan to collect spawn bindings.
  // Only the outermost block's statements are scanned; nested spawn bindings
  // (inside if/match/loop bodies) are a deferred case.
  match decl.body {
    case None -> {}
    case Some(body) -> match body {
      case FBExpr(_)    -> {}
      case FBBlock(blk) -> {
        var si = 0
        while si < blk.statements.count {
          match blk.statements[si].kind {
            case SLocal(binding) -> match binding {
              case LBVal(pat, _, init) -> match pat.kind {
                case PBinding(bindName, _) -> match init.kind {
                  case ESpawn(spawnInner) -> {
                    val sTy = inferCallReturnTypePB(cctx, pkgName, spawnInner, spawnNms, spawnTys)
                    if isTaskTypeMsil(cctx, sTy) {
                      spawnNms.add(bindName)
                      spawnTys.add(sTy)
                    }
                  }
                  case _ -> {}
                }
                case _ -> {}
              }
              case _ -> {}
            }
            case _ -> {}
          }
          si = si + 1
        }
      }
    }
  }

  // Phase 2: recursive scan over the full body using the pre-built spawn lists
  // (read-only — no .add() on the lists inside recursion).
  match decl.body {
    case None -> {}
    case Some(body) -> match body {
      case FBBlock(blk) -> collectAwaitTypesBlockPB(cctx, pkgName, blk, result, spawnNms, spawnTys)
      case FBExpr(e)    -> collectAwaitTypesExprPB(cctx, pkgName, e, result, spawnNms, spawnTys)
    }
  }
  result
}

// Register a local as a promoted SM field (first time only) and emit a store
// from the local slot to the SM field.  Called from LBLet and LBVar handlers
// inside a Phase B.1 MoveNext context.
func phaseBRegisterAndSyncLocal(pbc: in PhaseBCtx, insns: in List[MInsn],
                                 name: in String, ty: in MsilType, localIdx: in Int): Unit {
  val fldName = "__local_" + name
  var alreadyReg = false
  var chk = 0
  while chk < pbc.promotedLocalNames.count {
    if pbc.promotedLocalNames[chk] == name {
      alreadyReg = true
      chk = pbc.promotedLocalNames.count
    }
    chk = chk + 1
  }
  if not alreadyReg {
    pbc.promotedLocalNames.add(name)
    pbc.promotedLocalSlots.add(localIdx)
    pbc.promotedLocalTypes.add(ty)
    pbc.smFields.add(MField(flags = FDA_PUBLIC, name = fldName, fieldType = ty))
  }
  insns.add(MLdarg(slot = 0))
  insns.add(MLdloc(slot = localIdx))
  insns.add(MStfldByName(ownerFqn = pbc.smFqn, fieldName = fldName))
}

// Sync an already-promoted local's slot value back to its SM field.  Called
// after each assignment to a `var` local that was registered by
// phaseBRegisterAndSyncLocal.
func phaseBSyncLocalIfPromoted(pbc: in PhaseBCtx, insns: in List[MInsn],
                                name: in String, localIdx: in Int): Unit {
  if nameListContains(pbc.promotedLocalNames, name) {
    insns.add(MLdarg(slot = 0))
    insns.add(MLdloc(slot = localIdx))
    insns.add(MStfldByName(ownerFqn = pbc.smFqn, fieldName = "__local_" + name))
  }
}

// Spill the current TOS value to a promoted SM field local so it survives
// any suspension that occurs while evaluating a subsequent sub-expression
// that contains EAwait.  Stack effect: pops the TOS.
// Returns localIdx (= slot - paramCount) for caller-side reload after rhs.
func phaseBSpillToLocal(pbc: in PhaseBCtx, fctx: in FuncCtx,
                         insns: in List[MInsn], ty: in MsilType): Int {
  val name     = "__spill_" + toString(fctx.slotTicker.count)
  val slot     = allocSlotMsil(fctx, name, ty)
  val localIdx = slot - fctx.paramCount
  insns.add(MStloc(slot = localIdx))
  phaseBRegisterAndSyncLocal(pbc, insns, name, ty, localIdx)
  localIdx
}



// Full Phase B.1 suspend/resume for one `await` point inside MoveNext.
// Stack pre-condition:  Task<T> or Task.
// Stack post-condition: T (or nothing for void).
// Returns the result MsilType.
// Side-effects: allocates locals, uses and increments phaseBCtx.nextAwaitIndex.
func emitPhaseBAwait(cctx: in CodegenCtx, fctx: in FuncCtx,
                     insns: in List[MInsn], taskTy: in MsilType): MsilType {
  val pbc   = fctx.phaseBCtx[0]
  val lctx  = cctx.lctx
  val N     = pbc.nextAwaitIndex.count
  pbc.nextAwaitIndex.add(0)                     // consume index N
  val resumeL   = pbc.resumeLabels[N]
  val awFldName = pbc.awaiterFieldNames[N]

  val resT  = taskResultType(taskTy)
  val awTy  = taskTypeToAwaiterMsilType(cctx, taskTy)
  val tyKey = msilTypeKey(resT)

  // Allocate temp local for the awaiter struct (used by both paths).
  val awSlot    = allocSlotMsil(fctx, "__awt_" + toString(N), awTy)
  val awLocalIdx = awSlot - fctx.paramCount

  // 1. GetAwaiter (stack: Task<T>|Task → awaiter value)
  emitGetAwaiterCallPB(cctx, insns, taskTy)
  insns.add(MStloc(slot = awLocalIdx))

  // 2. IsCompleted check
  insns.add(MLdloca(slot = awLocalIdx))
  emitGetIsCompletedCallPB(cctx, insns, awTy)
  val afterAwaitL = freshLabelMsil(fctx)
  insns.add(MBrTrue(label = afterAwaitL))

  // 3. Suspension path: save state + awaiter, call AwaitUnsafeOnCompleted, leave
  insns.add(MLdarg(slot = 0))
  insns.add(MLdcI4(v = N))
  insns.add(MStfldByName(ownerFqn = pbc.smFqn, fieldName = "__state"))
  // ldarg.0; ldloc awTemp; stfld __awN
  insns.add(MLdarg(slot = 0))
  insns.add(MLdloc(slot = awLocalIdx))
  insns.add(MStfldByName(ownerFqn = pbc.smFqn, fieldName = awFldName))
  // var sm = this
  val smLocalSlot = allocSlotMsil(fctx, "__sm_" + toString(N), MClass(className = pbc.smFqn))
  val smLocalIdx  = smLocalSlot - fctx.paramCount
  insns.add(MLdarg(slot = 0))
  insns.add(MStloc(slot = smLocalIdx))
  // builder.AwaitUnsafeOnCompleted(ref __awN, ref sm)
  insns.add(MLdarg(slot = 0))
  insns.add(MLdfldaByName(ownerFqn = pbc.smFqn, fieldName = "__builder"))
  insns.add(MLdarg(slot = 0))
  insns.add(MLdfldaByName(ownerFqn = pbc.smFqn, fieldName = awFldName))
  insns.add(MLdloca(slot = smLocalIdx))
  insns.add(MCallAwaitUnsafeOnCompleted(
    smFqn        = pbc.smFqn,
    atmbMrRow    = pbc.atmbMrRowForAwait,
    awaiterMsilTy = awTy))
  insns.add(MLeave(label = pbc.suspendLeaveLabel))

  // 4. Resume label: switch dispatch target for state = N
  insns.add(MLabel(id = resumeL))
  // Restore awaiter from SM field into temp local
  insns.add(MLdarg(slot = 0))
  insns.add(MLdfldByName(ownerFqn = pbc.smFqn, fieldName = awFldName))
  insns.add(MStloc(slot = awLocalIdx))
  // Zero SM field: ldarg.0; ldflda __awN; initobj <awaiter type>
  insns.add(MLdarg(slot = 0))
  insns.add(MLdfldaByName(ownerFqn = pbc.smFqn, fieldName = awFldName))
  val initobjTok = if resT == MVoid {
    0x01000000 + cctx.trTaskAwaiter
  } else {
    val awTsArgs: List[MsilType] = newList()
    awTsArgs.add(resT)
    val awTsBlob = buildValueTypeGenericInstBlobWithCtx(lctx, tdrTypeRef(cctx.trTaskAwaiter1), awTsArgs)
    val awTsKey  = "taskaw1_ts_" + tyKey
    val awTsRow  = ctxAddTypeSpec(lctx, awTsKey, awTsBlob)
    0x1B000000 + awTsRow
  }
  insns.add(MInitobj(typeToken = initobjTok))
  // Reset state to -1 (running)
  insns.add(MLdarg(slot = 0))
  insns.add(MLdcI4(v = -1))
  insns.add(MStfldByName(ownerFqn = pbc.smFqn, fieldName = "__state"))

  // Reload promoted locals from SM fields into their local slots.  Any `val`
  // binding encountered before this await point was saved to an SM field when
  // it was first assigned; reload it here so the post-resume code sees the
  // correct value in its slot rather than the default-zero that the JIT writes
  // at the start of each MoveNext invocation.
  var plReloadIdx = 0
  while plReloadIdx < pbc.promotedLocalNames.count {
    insns.add(MLdarg(slot = 0))
    insns.add(MLdfldByName(ownerFqn = pbc.smFqn,
                            fieldName = "__local_" + pbc.promotedLocalNames[plReloadIdx]))
    insns.add(MStloc(slot = pbc.promotedLocalSlots[plReloadIdx]))
    plReloadIdx = plReloadIdx + 1
  }

  // 5. After-await label: both the "already completed" and "resume" paths join here.
  insns.add(MLabel(id = afterAwaitL))

  // 6. GetResult (stack: address of awaiter → T or void)
  insns.add(MLdloca(slot = awLocalIdx))
  emitGetResultCallPB(cctx, insns, awTy)
}

func synthesizeAsyncSmMsil(cctx: in CodegenCtx, decl: in FunctionDecl,
                            pkgName: in String,
                            items: in List[MPackageItem],
                            fns:   in List[MFunc]): Unit {

  val tick  = cctx.smTicker.count
  cctx.smTicker.add(0)

  val smSimple = "<" + decl.name + ">__SM_" + toString(tick)
  val smFqn    = pkgName + "." + smSimple

  // Determine return type of the async func (the T in Task<T>, or void).
  val retTy = match decl.ret {
    case Some(te) -> {
      val r = typeExprToMsilCtx(cctx, te, pkgName)
      if elementTypeByte(r) == 0 { MVoid } else { r }
    }
    case None -> MVoid
  }
  val isVoid = retTy == MVoid

  // ── SM field list ─────────────────────────────────────────────────────────
  val smFields: List[MField] = newList()

  // field 0: __state
  smFields.add(MField(
    flags     = FDA_PUBLIC,
    name      = "__state",
    fieldType = MInt))

  // field 1: __builder (ATMB for void, ATMB<T> for non-void)
  val builderTy: MsilType =
    if isVoid {
      MValueTypeRef(
        typeRefCode = tdrTypeRef(cctx.trAtmb),
        clrFqn      = "System.Runtime.CompilerServices.AsyncTaskMethodBuilder")
    } else {
      val tArgs: List[MsilType] = newList()
      tArgs.add(retTy)
      MValueTypeGenericInst(
        typeRefCode = tdrTypeRef(cctx.trAtmb1),
        headFqn     = "System.Runtime.CompilerServices.AsyncTaskMethodBuilder`1",
        typeArgs    = tArgs)
    }
  smFields.add(MField(flags = FDA_PUBLIC, name = "__builder", fieldType = builderTy))

  // fields 2+: one per user param
  var smPi = 0
  while smPi < decl.params.count {
    val p    = decl.params[smPi]
    val pTy  = typeExprToMsilCtx(cctx, p.ty, pkgName)
    smFields.add(MField(flags = FDA_PUBLIC, name = "__p" + toString(smPi), fieldType = pTy))
    smPi = smPi + 1
  }

  // ── MoveNext() ────────────────────────────────────────────────────────────
  // paramCount = 1 (this = ldarg.0).
  // User params are pre-loaded from SM fields into LOCAL slots [0, N-1].
  val mnInsns: List[MInsn] = newList()
  val mnFctx = makeFuncCtxMsil(pkgName, smFqn, "MoveNext", 1, MVoid)

  // Pre-populate slotTicker with one entry for the `this` arg (slot 0) so
  // that the first allocSlotMsil call below gets slot 1 (a local, not an arg).
  // Without this, slot 0 < paramCount(1) causes the user-param local to be
  // misclassified as an arg, never added to fctx.locals, and the resulting
  // MStloc(slot = 0-1 = -1) encodes as stloc 65535 → UnrecognizedLocalNumber.
  mnFctx.slotTicker.add(0)

  // Preamble: load user params from SM fields into local slots.
  var mpre = 0
  while mpre < decl.params.count {
    val p    = decl.params[mpre]
    val pTy  = typeExprToMsilCtx(cctx, p.ty, pkgName)
    val pSlot = allocSlotMsil(mnFctx, p.name, pTy)
    // ldarg.0; ldfldByName (deferred); stloc <local-index>
    mnInsns.add(MLdarg(slot = 0))
    mnInsns.add(MLdfldByName(ownerFqn = smFqn, fieldName = "__p" + toString(mpre)))
    mnInsns.add(MStloc(slot = pSlot - 1))  // pSlot - paramCount(1) = local index
    mpre = mpre + 1
  }

  // Reserve the epilogue label.  Bind to a local so all references below are
  // provably the allocated value, not a default-zero coincidence (#2273).
  val epilogueLabel = freshLabelMsil(mnFctx)
  mnFctx.epilogueLabel = epilogueLabel

  // Lower the user body (Phase B.0: no EAwait nodes in the body).
  match decl.body {
    case Some(body) -> {
      match body {
        case FBBlock(block) -> {
          if retTy != MVoid {
            // Allocate the result stash slot before lowering the body: the stash
            // MStloc instructions emitted during patching reference this slot.
            val rSlot = allocSlotMsil(mnFctx, "__sm_result", retTy)
            val bodyInsns: List[MInsn] = newList()
            val trailTy = lowerBlockExprMsil(cctx, mnFctx, bodyInsns, block)
            // Inline patch: replace every MRet with [MStloc(rSlot-1); MBr(epilogueLabel)]
            // so that explicit `return` statements stash the result and branch to the SM
            // epilogue rather than exiting MoveNext before SetResult is called (#2256).
            // Track whether the last copied instruction was a patched-return to determine
            // whether the trailing-expression value is still on the stack.
            var lastWasPatchedRet = false
            var pbi = 0
            while pbi < bodyInsns.count {
              match bodyInsns[pbi] {
                case MRet -> {
                  mnInsns.add(MStloc(slot = rSlot - 1))
                  mnInsns.add(MBr(label = epilogueLabel))
                  lastWasPatchedRet = true
                }
                case _ -> {
                  mnInsns.add(bodyInsns[pbi])
                  lastWasPatchedRet = false
                }
              }
              pbi = pbi + 1
            }
            if not lastWasPatchedRet {
              // Trailing-expression path: value still on stack — coerce and stash.
              coerceTrailingToRetMsil(cctx, mnInsns, trailTy, retTy)
              mnInsns.add(MStloc(slot = rSlot - 1))
            }
            // SM epilogue — always reached (fall-through or patched branch).
            mnInsns.add(MLabel(id = epilogueLabel))
            mnInsns.add(MLdarg(slot = 0))
            mnInsns.add(MLdcI4(v = -2))
            mnInsns.add(MStfldByName(ownerFqn = smFqn, fieldName = "__state"))
            mnInsns.add(MLdarg(slot = 0))
            mnInsns.add(MLdfldaByName(ownerFqn = smFqn, fieldName = "__builder"))
            mnInsns.add(MLdloc(slot = rSlot - 1))
            // call ATMB`1<T>.SetResult(T): void via TypeSpec-parented MemberRef.
            // Signature uses VAR 0 per ECMA-335 §II.23.2.1.
            val tsArgs: List[MsilType] = newList()
            tsArgs.add(retTy)
            val tsBlob = buildValueTypeGenericInstBlobWithCtx(cctx.lctx, tdrTypeRef(cctx.trAtmb1), tsArgs)
            var taKey = msilTypeKey(retTy)
            val tsKey  = "atmb1_ts_" + taKey
            val tsRow  = ctxAddTypeSpec(cctx.lctx, tsKey, tsBlob)
            val srArgs: List[MsilType] = newList()
            srArgs.add(MTypeVar(index = 0))  // VAR 0, not the concrete retTy — see FBBlock note above
            val srSig  = buildInstanceMethodSig(srArgs, MVoid)
            val srKey  = "atmb1_setresult_mr_" + taKey
            val srMrRow = ctxAddMemberRefForTypeSpec(cctx.lctx, tsRow, "SetResult", srKey, srSig)
            mnInsns.add(MCall(methodToken = 0x0A000000 + srMrRow))
            mnInsns.add(MRet)
          } else {
            val bodyInsns2: List[MInsn] = newList()
            lowerBlockMsil(cctx, mnFctx, bodyInsns2, block)
            // Inline patch: replace every MRet with MBr(epilogueLabel) (#2256).
            var pbi2 = 0
            while pbi2 < bodyInsns2.count {
              match bodyInsns2[pbi2] {
                case MRet -> mnInsns.add(MBr(label = epilogueLabel))
                case _ -> mnInsns.add(bodyInsns2[pbi2])
              }
              pbi2 = pbi2 + 1
            }
            // SM epilogue — always reached.
            mnInsns.add(MLabel(id = epilogueLabel))
            mnInsns.add(MLdarg(slot = 0))
            mnInsns.add(MLdcI4(v = -2))
            mnInsns.add(MStfldByName(ownerFqn = smFqn, fieldName = "__state"))
            mnInsns.add(MLdarg(slot = 0))
            mnInsns.add(MLdfldaByName(ownerFqn = smFqn, fieldName = "__builder"))
            mnInsns.add(MCall(methodToken = cctx.tokAtmbSetResult))
            mnInsns.add(MRet)
          }
        }
        case FBExpr(e) -> {
          if retTy != MVoid {
            val eTy = lowerExprMsil(cctx, mnFctx, mnInsns, e)
            coerceTrailingToRetMsil(cctx, mnInsns, eTy, retTy)
            val rSlot2 = allocSlotMsil(mnFctx, "__sm_result2", retTy)
            mnInsns.add(MStloc(slot = rSlot2 - 1))
            mnInsns.add(MLdarg(slot = 0))
            mnInsns.add(MLdcI4(v = -2))
            mnInsns.add(MStfldByName(ownerFqn = smFqn, fieldName = "__state"))
            mnInsns.add(MLdarg(slot = 0))
            mnInsns.add(MLdfldaByName(ownerFqn = smFqn, fieldName = "__builder"))
            mnInsns.add(MLdloc(slot = rSlot2 - 1))
            val tsArgs2: List[MsilType] = newList()
            tsArgs2.add(retTy)
            val tsBlob2 = buildValueTypeGenericInstBlobWithCtx(cctx.lctx, tdrTypeRef(cctx.trAtmb1), tsArgs2)
            val taKey2  = msilTypeKey(retTy)
            val tsKey2  = "atmb1_ts_" + taKey2
            val tsRow2  = ctxAddTypeSpec(cctx.lctx, tsKey2, tsBlob2)
            val srArgs2: List[MsilType] = newList()
            srArgs2.add(MTypeVar(index = 0))  // VAR 0, not the concrete retTy — see FBBlock note above
            val srSig2  = buildInstanceMethodSig(srArgs2, MVoid)
            val srKey2  = "atmb1_setresult_mr_" + taKey2
            val srMrRow2 = ctxAddMemberRefForTypeSpec(cctx.lctx, tsRow2, "SetResult", srKey2, srSig2)
            mnInsns.add(MCall(methodToken = 0x0A000000 + srMrRow2))
            mnInsns.add(MRet)
          } else {
            lowerExprMsil(cctx, mnFctx, mnInsns, e)
            mnInsns.add(MPop)
            mnInsns.add(MLdarg(slot = 0))
            mnInsns.add(MLdcI4(v = -2))
            mnInsns.add(MStfldByName(ownerFqn = smFqn, fieldName = "__state"))
            mnInsns.add(MLdarg(slot = 0))
            mnInsns.add(MLdfldaByName(ownerFqn = smFqn, fieldName = "__builder"))
            mnInsns.add(MCall(methodToken = cctx.tokAtmbSetResult))
            mnInsns.add(MRet)
          }
        }
      }
    }
    case None -> {
      // Body-less async func: just complete immediately.
      mnInsns.add(MLdarg(slot = 0))
      mnInsns.add(MLdcI4(v = -2))
      mnInsns.add(MStfldByName(ownerFqn = smFqn, fieldName = "__state"))
      mnInsns.add(MLdarg(slot = 0))
      mnInsns.add(MLdfldaByName(ownerFqn = smFqn, fieldName = "__builder"))
      mnInsns.add(MCall(methodToken = cctx.tokAtmbSetResult))
      mnInsns.add(MRet)
    }
  }

  val mnFunc = MFunc(
    flags    = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG + MDA_FINAL,
    name     = "MoveNext",
    params   = newList(),
    ret      = MVoid,
    insns    = mnInsns,
    maxStack = 8,
    locals   = mnFctx.locals)

  // ── SetStateMachine() stub ─────────────────────────────────────────────────
  // The CLR calls this to notify the SM that it's been boxed; we don't
  // use the passed-in IAsyncStateMachine reference.  Emit a no-op body.
  val ssmInsns: List[MInsn] = newList()
  ssmInsns.add(MRet)
  val ssmParams: List[MsilType] = newList()
  ssmParams.add(MClassRef(
    typeRefCode = tdrTypeRef(cctx.trIAsm),
    clrFqn      = "System.Runtime.CompilerServices.IAsyncStateMachine"))
  val ssmFunc = MFunc(
    flags    = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG + MDA_FINAL,
    name     = "SetStateMachine",
    params   = ssmParams,
    ret      = MVoid,
    insns    = ssmInsns,
    maxStack = 1,
    locals   = newList())

  // ── SM MRecord ────────────────────────────────────────────────────────────
  val smMethods: List[MFunc] = newList()
  smMethods.add(mnFunc)
  smMethods.add(ssmFunc)
  val smRec = MRecord(
    className      = smFqn,
    namespace      = pkgName,
    baseClass      = "System.Object",
    fields         = smFields,
    methods        = smMethods,
    useDefaultCtor = true)
  items.add(MPRecord(rec = smRec))

  // ── IAsyncStateMachine MPImpl ─────────────────────────────────────────────
  val slots: List[MImplSlot] = newList()
  slots.add(MImplSlot(
    ifaceMethodToken = 0,
    implMethodToken  = 0,
    ifaceMethodName  = "MoveNext",
    implMethodName   = "MoveNext"))
  slots.add(MImplSlot(
    ifaceMethodToken = 0,
    implMethodToken  = 0,
    ifaceMethodName  = "SetStateMachine",
    implMethodName   = "SetStateMachine"))
  items.add(MPImpl(implData = MImplData(
    targetTypeDefRow = 0,
    ifaceTypeToken   = 0,
    slots            = slots,
    targetTypeName   = smFqn,
    ifaceTypeName    = "System.Runtime.CompilerServices.IAsyncStateMachine")))

  // ── Kickoff MFunc ─────────────────────────────────────────────────────────
  // The user-visible function signature is preserved (same name/params/ret).
  // The kickoff allocates the SM, wires it up, calls Start, and returns Task/Task<T>.
  val kfInsns: List[MInsn] = newList()
  val kfLocals: List[MsilType] = newList()
  kfLocals.add(MClass(smFqn))  // local 0: SM instance; typed as the SM class so ldloca → byref SM

  // newobj SM (no-arg ctor) — newobj zero-initialises all fields, so __builder
  // is already a valid default ATMB / ATMB<T> struct without any Create() call.
  // AsyncTaskMethodBuilder.Create() and AsyncTaskMethodBuilder`1.Create() were
  // removed from the .NET BCL in .NET 7+ (they returned `default` anyway).
  kfInsns.add(MNewobjByName(className = smFqn))
  kfInsns.add(MStloc(slot = 0))

  // sm.__state = -1
  kfInsns.add(MLdloc(slot = 0))
  kfInsns.add(MLdcI4(v = -1))
  kfInsns.add(MStfldByName(ownerFqn = smFqn, fieldName = "__state"))

  // Copy user params into SM fields: ldloc sm; ldarg <i>; stfld __p<i>
  var kpi = 0
  while kpi < decl.params.count {
    kfInsns.add(MLdloc(slot = 0))
    kfInsns.add(MLdarg(slot = kpi))
    kfInsns.add(MStfldByName(ownerFqn = smFqn, fieldName = "__p" + toString(kpi)))
    kpi = kpi + 1
  }

  // sm.__builder.Start<SM>(ref sm)
  //   ldloc sm; ldflda __builder; ldloca sm; call MethodSpec
  // For void path: MemberRef on TypeRef(ATMB).
  // For non-void path: MemberRef on TypeSpec(ATMB`1<T>) — ATMB and ATMB`1 have
  //   independent Start methods; using the wrong parent causes a CLR type mismatch.
  kfInsns.add(MLdloc(slot = 0))
  kfInsns.add(MLdfldaByName(ownerFqn = smFqn, fieldName = "__builder"))
  kfInsns.add(MLdloca(slot = 0))
  val startMrRow =
    if isVoid {
      cctx.tokAtmbStartMr
    } else {
      val tsArgsS: List[MsilType] = newList()
      tsArgsS.add(retTy)
      val tsBlobS = buildValueTypeGenericInstBlobWithCtx(cctx.lctx, tdrTypeRef(cctx.trAtmb1), tsArgsS)
      val tsKeyS  = "atmb1_ts_" + msilTypeKey(retTy)
      val tsRowS  = ctxAddTypeSpec(cctx.lctx, tsKeyS, tsBlobS)
      val startOpenSig = buildAtmbStartOpenSig()
      val startMrKey   = "atmb1_start_mr_" + msilTypeKey(retTy)
      ctxAddMemberRefForTypeSpec(cctx.lctx, tsRowS, "Start", startMrKey, startOpenSig)
    }
  kfInsns.add(MCallAtmbStart(
    smFqn     = smFqn,
    atmbMrRow = startMrRow,
    isGeneric = not isVoid))

  // The kickoff returns Task<T> (non-void) or Task (void).
  // Call sites must use `await` to unwrap the result; the test bodies
  // and any non-async code use the blocking EAwait shim (GetAwaiter+GetResult).
  if isVoid {
    // Void path: sm.__builder.get_Task() → Task; then ret.
    kfInsns.add(MLdloc(slot = 0))
    kfInsns.add(MLdfldaByName(ownerFqn = smFqn, fieldName = "__builder"))
    kfInsns.add(MCall(methodToken = cctx.tokAtmbGetTask))
  } else {
    // Non-void path: sm.__builder.get_Task() → Task<T>; then ret.
    val taKey4  = msilTypeKey(retTy)
    kfInsns.add(MLdloc(slot = 0))
    kfInsns.add(MLdfldaByName(ownerFqn = smFqn, fieldName = "__builder"))
    val tsArgs4: List[MsilType] = newList()
    tsArgs4.add(retTy)
    val tsBlob4 = buildValueTypeGenericInstBlobWithCtx(cctx.lctx, tdrTypeRef(cctx.trAtmb1), tsArgs4)
    val tsKey4  = "atmb1_ts_" + taKey4
    val tsRow4  = ctxAddTypeSpec(cctx.lctx, tsKey4, tsBlob4)
    // Method signature must use VAR 0, not the concrete retTy — the TypeSpec parent
    // already captures the concrete type arg; see ECMA-335 II.23.2.1.
    val taskVarArgs: List[MsilType] = newList()
    taskVarArgs.add(MTypeVar(index = 0))
    val taskRetTy: MsilType = MGenericInst(
      typeRefCode = tdrTypeRef(cctx.trTask1),
      headFqn     = "System.Threading.Tasks.Task`1",
      typeArgs    = taskVarArgs)
    val gtArgsTys4: List[MsilType] = newList()
    val gtSig4  = buildInstanceMethodSig(gtArgsTys4, taskRetTy)
    val gtKey4  = "atmb1_gettask_mr_" + taKey4
    val gtMrRow4 = ctxAddMemberRefForTypeSpec(cctx.lctx, tsRow4, "get_Task", gtKey4, gtSig4)
    kfInsns.add(MCall(methodToken = 0x0A000000 + gtMrRow4))
  }
  kfInsns.add(MRet)

  // Kickoff return type is Task<T> (non-void) or Task (void).
  val kfRetTy: MsilType =
    if isVoid {
      MClassRef(typeRefCode = tdrTypeRef(cctx.trTask),
                clrFqn      = "System.Threading.Tasks.Task")
    } else {
      val kfRetArgs: List[MsilType] = newList()
      kfRetArgs.add(retTy)
      MGenericInst(typeRefCode = tdrTypeRef(cctx.trTask1),
                   headFqn     = "System.Threading.Tasks.Task`1",
                   typeArgs    = kfRetArgs)
    }

  // Build parameter type list matching the user func.
  val kfParamTypes: List[MsilType] = newList()
  var kpi2 = 0
  while kpi2 < decl.params.count {
    kfParamTypes.add(typeExprToMsilCtx(cctx, decl.params[kpi2].ty, pkgName))
    kpi2 = kpi2 + 1
  }

  fns.add(MFunc(
    flags    = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG,
    name     = decl.name,
    params   = byrefWrapSigTypes(decl.params, kfParamTypes),
    ret      = kfRetTy,
    insns    = kfInsns,
    maxStack = 4,
    locals   = kfLocals))
}

// ── Phase B.1: IAsyncStateMachine synthesis with real `await` suspension ─────
//
// Emits a sealed class SM with:
//   __state    : Int            (-1 = initial, N = suspended at await N, -2 = done)
//   __builder  : ATMB / ATMB<T>
//   __p0..N-1  : user param types
//   __aw0..M-1 : awaiter types for each EAwait in the body
//
// MoveNext structure:
//   try {
//     tryStartL:
//     ldarg.0; ldfld __state; switch(resumeLabels); br bodyStartL
//     bodyStartL:
//       preamble + user body (EAwait nodes emit full suspend/resume inline)
//       [stash result if non-void]
//     normalDoneL:
//       state=-2; SetResult; leave afterTryL
//   } catch(Exception e) {
//     state=-2; SetException(e); leave afterTryL
//   }
//   afterTryL:
//   ret
//
// Resume path for state=N (inside the body, embedded after the suspend):
//   resumeLabelN: restore __awN → awTemp; zero __awN; state=-1; GetResult → stack
func synthesizeAsyncSmPhaseBMsil(cctx: in CodegenCtx, decl: in FunctionDecl,
                                  pkgName: in String,
                                  items: in List[MPackageItem],
                                  fns:   in List[MFunc]): Unit {
  val lctx = cctx.lctx

  val tick   = cctx.smTicker.count
  cctx.smTicker.add(0)
  val smSimple = "<" + decl.name + ">__SM_" + toString(tick)
  val smFqn    = pkgName + "." + smSimple

  // Return type analysis (same as Phase B.0)
  val retTy = match decl.ret {
    case Some(te) -> {
      val r = typeExprToMsilCtx(cctx, te, pkgName)
      if elementTypeByte(r) == 0 { MVoid } else { r }
    }
    case None -> MVoid
  }
  val isVoid = retTy == MVoid

  // Pre-scan: collect awaiter types in body-evaluation order
  val awaiterTypes = collectAwaitTypesPhaseBMsil(cctx, pkgName, decl)
  val awCount = awaiterTypes.count

  // ── SM field list ─────────────────────────────────────────────────────────
  val smFields: List[MField] = newList()
  smFields.add(MField(flags = FDA_PUBLIC, name = "__state",   fieldType = MInt))

  val builderTy: MsilType =
    if isVoid {
      MValueTypeRef(typeRefCode = tdrTypeRef(cctx.trAtmb),
                    clrFqn = "System.Runtime.CompilerServices.AsyncTaskMethodBuilder")
    } else {
      val tArgs: List[MsilType] = newList()
      tArgs.add(retTy)
      MValueTypeGenericInst(typeRefCode = tdrTypeRef(cctx.trAtmb1),
                            headFqn = "System.Runtime.CompilerServices.AsyncTaskMethodBuilder`1",
                            typeArgs = tArgs)
    }
  smFields.add(MField(flags = FDA_PUBLIC, name = "__builder", fieldType = builderTy))

  var smPi = 0
  while smPi < decl.params.count {
    val p   = decl.params[smPi]
    val pTy = typeExprToMsilCtx(cctx, p.ty, pkgName)
    smFields.add(MField(flags = FDA_PUBLIC, name = "__p" + toString(smPi), fieldType = pTy))
    smPi = smPi + 1
  }

  // Awaiter fields __aw0 .. __awM-1
  val awaiterFieldNames: List[String] = newList()
  var awi = 0
  while awi < awCount {
    val awName = "__aw" + toString(awi)
    awaiterFieldNames.add(awName)
    smFields.add(MField(flags = FDA_PUBLIC, name = awName, fieldType = awaiterTypes[awi]))
    awi = awi + 1
  }

  // ── MoveNext() ────────────────────────────────────────────────────────────
  val mnInsns: List[MInsn] = newList()
  val mnFctx = makeFuncCtxMsil(pkgName, smFqn, "MoveNext", 1, MVoid)
  mnFctx.slotTicker.add(0)  // reserve slot 0 for 'this' arg

  // Pre-allocate labels
  val tryStartL          = freshLabelMsil(mnFctx)
  val bodyStartL         = freshLabelMsil(mnFctx)
  val normalDoneL        = freshLabelMsil(mnFctx)
  val afterTryL          = freshLabelMsil(mnFctx)
  val tryBodyEndL        = freshLabelMsil(mnFctx)
  val catchHandlerStartL = freshLabelMsil(mnFctx)
  val catchHandlerEndL   = freshLabelMsil(mnFctx)

  // Pre-allocate resume labels (one per await point)
  val resumeLabels: List[Int] = newList()
  var rli = 0
  while rli < awCount {
    resumeLabels.add(freshLabelMsil(mnFctx))
    rli = rli + 1
  }

  // Epilogue for nested-try returns inside the body (points to normalDoneL)
  mnFctx.epilogueLabel = normalDoneL

  // Build the AwaitUnsafeOnCompleted MemberRef for this SM's ATMB type.
  // For void: use the pre-built ATMB void row.
  // For non-void: the CLR requires the MemberRef parent to be a TypeSpec
  // (closed instantiation ATMB`1<retTy>), not an open TypeRef — ECMA-335
  // §II.22.25 row 13.  The open-TypeRef row stored in cctx.tokAtmb1AwaitUnsafeMr
  // causes a TypeLoadException at runtime.
  val atmbMrRowForAwait =
    if isVoid {
      cctx.tokAtmbAwaitUnsafeMr
    } else {
      val awTsArgs: List[MsilType] = newList()
      awTsArgs.add(retTy)
      val awTsBlob = buildValueTypeGenericInstBlobWithCtx(cctx.lctx, tdrTypeRef(cctx.trAtmb1), awTsArgs)
      val awTaKey  = msilTypeKey(retTy)
      val awTsKey  = "atmb1_ts_await_" + awTaKey
      val awTsRow  = ctxAddTypeSpec(cctx.lctx, awTsKey, awTsBlob)
      val awSig    = buildAwaitUnsafeOnCompletedOpenSig()
      val awMrKey  = "atmb1_await_unsafe_mr_" + awTaKey
      ctxAddMemberRefForTypeSpec(cctx.lctx, awTsRow, "AwaitUnsafeOnCompleted", awMrKey, awSig)
    }

  // Install the PhaseBCtx singleton in mnFctx
  val pbCtx = PhaseBCtx(
    smFqn               = smFqn,
    resumeLabels        = resumeLabels,
    suspendLeaveLabel   = afterTryL,
    nextAwaitIndex      = newList(),
    awaiterFieldNames   = awaiterFieldNames,
    isVoid              = isVoid,
    retTy               = retTy,
    atmbMrRowForAwait   = atmbMrRowForAwait,
    smFields            = smFields,
    promotedLocalNames  = newList(),
    promotedLocalSlots  = newList(),
    promotedLocalTypes  = newList())
  mnFctx.phaseBCtx.add(pbCtx)

  // Pre-allocate result slot for non-void (must exist before body lowering
  // so patched returns can reference it).
  var rSlot = -1
  if not isVoid {
    rSlot = allocSlotMsil(mnFctx, "__sm_result", retTy)
  }

  // ── Preamble: load user params from SM fields into local slots ────────────
  var mpre = 0
  while mpre < decl.params.count {
    val p    = decl.params[mpre]
    val pTy  = typeExprToMsilCtx(cctx, p.ty, pkgName)
    val pSlot = allocSlotMsil(mnFctx, p.name, pTy)
    // pSlot - paramCount(1) = local index
    mnInsns.add(MLdarg(slot = 0))
    mnInsns.add(MLdfldByName(ownerFqn = smFqn, fieldName = "__p" + toString(mpre)))
    mnInsns.add(MStloc(slot = pSlot - 1))
    mpre = mpre + 1
  }

  // ── Try body start ────────────────────────────────────────────────────────
  mnInsns.add(MLabel(id = tryStartL))
  mnFctx.tryRegionStack.add(0)

  // State dispatch switch
  mnInsns.add(MLdarg(slot = 0))
  mnInsns.add(MLdfldByName(ownerFqn = smFqn, fieldName = "__state"))
  mnInsns.add(MSwitch(labels = resumeLabels))
  mnInsns.add(MBr(label = bodyStartL))

  // Body start label
  mnInsns.add(MLabel(id = bodyStartL))

  // ── Lower user body ───────────────────────────────────────────────────────
  match decl.body {
    case Some(body) -> {
      match body {
        case FBBlock(block) -> {
          if not isVoid {
            val bodyInsns: List[MInsn] = newList()
            val trailTy = lowerBlockExprMsil(cctx, mnFctx, bodyInsns, block)
            // Patch MRet → [stloc rSlot; br normalDoneL]
            var lastWasPatchedRet = false
            var pbi = 0
            while pbi < bodyInsns.count {
              match bodyInsns[pbi] {
                case MRet -> {
                  mnInsns.add(MStloc(slot = rSlot - 1))
                  mnInsns.add(MBr(label = normalDoneL))
                  lastWasPatchedRet = true
                }
                case _ -> {
                  mnInsns.add(bodyInsns[pbi])
                  lastWasPatchedRet = false
                }
              }
              pbi = pbi + 1
            }
            if not lastWasPatchedRet {
              coerceTrailingToRetMsil(cctx, mnInsns, trailTy, retTy)
              mnInsns.add(MStloc(slot = rSlot - 1))
            }
          } else {
            val bodyInsns2: List[MInsn] = newList()
            lowerBlockMsil(cctx, mnFctx, bodyInsns2, block)
            var pbi2 = 0
            while pbi2 < bodyInsns2.count {
              match bodyInsns2[pbi2] {
                case MRet -> mnInsns.add(MBr(label = normalDoneL))
                case _    -> mnInsns.add(bodyInsns2[pbi2])
              }
              pbi2 = pbi2 + 1
            }
          }
        }
        case FBExpr(e) -> {
          if not isVoid {
            val eTy = lowerExprMsil(cctx, mnFctx, mnInsns, e)
            coerceTrailingToRetMsil(cctx, mnInsns, eTy, retTy)
            mnInsns.add(MStloc(slot = rSlot - 1))
          } else {
            lowerExprMsil(cctx, mnFctx, mnInsns, e)
            mnInsns.add(MPop)
          }
        }
      }
    }
    case None -> {}
  }

  // ── Normal completion epilogue ────────────────────────────────────────────
  mnInsns.add(MLabel(id = normalDoneL))
  mnInsns.add(MLdarg(slot = 0))
  mnInsns.add(MLdcI4(v = -2))
  mnInsns.add(MStfldByName(ownerFqn = smFqn, fieldName = "__state"))
  mnInsns.add(MLdarg(slot = 0))
  mnInsns.add(MLdfldaByName(ownerFqn = smFqn, fieldName = "__builder"))
  if not isVoid {
    mnInsns.add(MLdloc(slot = rSlot - 1))
    val taKey = msilTypeKey(retTy)
    val tsArgsB: List[MsilType] = newList()
    tsArgsB.add(retTy)
    val tsBlobB = buildValueTypeGenericInstBlobWithCtx(lctx, tdrTypeRef(cctx.trAtmb1), tsArgsB)
    val tsKeyB  = "atmb1_ts_" + taKey
    val tsRowB  = ctxAddTypeSpec(lctx, tsKeyB, tsBlobB)
    val srArgsB: List[MsilType] = newList()
    srArgsB.add(MTypeVar(index = 0))
    val srSigB  = buildInstanceMethodSig(srArgsB, MVoid)
    val srKeyB  = "atmb1_setresult_mr_b1_" + taKey
    val srMrRowB = ctxAddMemberRefForTypeSpec(lctx, tsRowB, "SetResult", srKeyB, srSigB)
    mnInsns.add(MCall(methodToken = 0x0A000000 + srMrRowB))
  } else {
    mnInsns.add(MCall(methodToken = cctx.tokAtmbSetResult))
  }
  mnInsns.add(MLeave(label = afterTryL))

  // ── End of try body ───────────────────────────────────────────────────────
  mnFctx.tryRegionStack.removeAt(mnFctx.tryRegionStack.count - 1)
  mnInsns.add(MLabel(id = tryBodyEndL))

  // ── Catch handler ─────────────────────────────────────────────────────────
  mnInsns.add(MLabel(id = catchHandlerStartL))
  mnFctx.tryRegionStack.add(0)
  val exSlot = allocSlotMsil(mnFctx, "__sm_ex", MObject)
  mnInsns.add(MStloc(slot = exSlot - 1))
  mnInsns.add(MLdarg(slot = 0))
  mnInsns.add(MLdcI4(v = -2))
  mnInsns.add(MStfldByName(ownerFqn = smFqn, fieldName = "__state"))
  mnInsns.add(MLdarg(slot = 0))
  mnInsns.add(MLdfldaByName(ownerFqn = smFqn, fieldName = "__builder"))
  mnInsns.add(MLdloc(slot = exSlot - 1))
  // SetException signature: (Exception): void
  val seParam = MClassRef(typeRefCode = tdrTypeRef(cctx.trException),
                          clrFqn = "System.Exception")
  val seArgList: List[MsilType] = newList()
  seArgList.add(seParam)
  val seSig = buildInstanceMethodSig(seArgList, MVoid)
  if isVoid {
    val seMrRow = ctxAddMemberRef(lctx, cctx.trAtmb, "SetException", "atmb_setexception", seSig)
    mnInsns.add(MCall(methodToken = 0x0A000000 + seMrRow))
  } else {
    val taKeyEx  = msilTypeKey(retTy)
    val tsArgsEx: List[MsilType] = newList()
    tsArgsEx.add(retTy)
    val tsBlobEx = buildValueTypeGenericInstBlobWithCtx(lctx, tdrTypeRef(cctx.trAtmb1), tsArgsEx)
    val tsKeyEx  = "atmb1_ts_" + taKeyEx
    val tsRowEx  = ctxAddTypeSpec(lctx, tsKeyEx, tsBlobEx)
    val seMrRowEx = ctxAddMemberRefForTypeSpec(lctx, tsRowEx, "SetException",
                                               "atmb1_setexception_b1_" + taKeyEx, seSig)
    mnInsns.add(MCall(methodToken = 0x0A000000 + seMrRowEx))
  }
  mnInsns.add(MLeave(label = afterTryL))
  mnFctx.tryRegionStack.removeAt(mnFctx.tryRegionStack.count - 1)
  mnInsns.add(MLabel(id = catchHandlerEndL))

  // EH clause: typed catch(Exception)
  mnInsns.add(MEHClause(
    flags        = 0,
    tryStart     = tryStartL,
    tryEnd       = tryBodyEndL,
    handlerStart = catchHandlerStartL,
    handlerEnd   = catchHandlerEndL,
    catchToken   = 0x01000000 + cctx.trException))

  // ── After-try: ret ────────────────────────────────────────────────────────
  mnInsns.add(MLabel(id = afterTryL))
  mnInsns.add(MRet)

  val mnFunc = MFunc(
    flags    = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG + MDA_FINAL,
    name     = "MoveNext",
    params   = newList(),
    ret      = MVoid,
    insns    = mnInsns,
    maxStack = 8,
    locals   = mnFctx.locals)

  // ── SetStateMachine() stub (identical to Phase B.0) ───────────────────────
  val ssmInsns: List[MInsn] = newList()
  ssmInsns.add(MRet)
  val ssmParams: List[MsilType] = newList()
  ssmParams.add(MClassRef(typeRefCode = tdrTypeRef(cctx.trIAsm),
                          clrFqn = "System.Runtime.CompilerServices.IAsyncStateMachine"))
  val ssmFunc = MFunc(
    flags    = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG + MDA_FINAL,
    name     = "SetStateMachine",
    params   = ssmParams,
    ret      = MVoid,
    insns    = ssmInsns,
    maxStack = 1,
    locals   = newList())

  // ── SM MRecord (same as Phase B.0) ────────────────────────────────────────
  val smMethods2: List[MFunc] = newList()
  smMethods2.add(mnFunc)
  smMethods2.add(ssmFunc)
  val smRec2 = MRecord(
    className      = smFqn,
    namespace      = pkgName,
    baseClass      = "System.Object",
    fields         = smFields,
    methods        = smMethods2,
    useDefaultCtor = true)
  items.add(MPRecord(rec = smRec2))

  // ── IAsyncStateMachine MPImpl (same as Phase B.0) ─────────────────────────
  val slots2: List[MImplSlot] = newList()
  slots2.add(MImplSlot(ifaceMethodToken = 0, implMethodToken = 0,
                       ifaceMethodName = "MoveNext",      implMethodName = "MoveNext"))
  slots2.add(MImplSlot(ifaceMethodToken = 0, implMethodToken = 0,
                       ifaceMethodName = "SetStateMachine", implMethodName = "SetStateMachine"))
  items.add(MPImpl(implData = MImplData(
    targetTypeDefRow = 0,
    ifaceTypeToken   = 0,
    slots            = slots2,
    targetTypeName   = smFqn,
    ifaceTypeName    = "System.Runtime.CompilerServices.IAsyncStateMachine")))

  // ── Kickoff MFunc (same structure as Phase B.0) ───────────────────────────
  val kfInsns2: List[MInsn] = newList()
  val kfLocals2: List[MsilType] = newList()
  kfLocals2.add(MClass(smFqn))

  kfInsns2.add(MNewobjByName(className = smFqn))
  kfInsns2.add(MStloc(slot = 0))
  kfInsns2.add(MLdloc(slot = 0))
  kfInsns2.add(MLdcI4(v = -1))
  kfInsns2.add(MStfldByName(ownerFqn = smFqn, fieldName = "__state"))

  var kpi3 = 0
  while kpi3 < decl.params.count {
    kfInsns2.add(MLdloc(slot = 0))
    kfInsns2.add(MLdarg(slot = kpi3))
    kfInsns2.add(MStfldByName(ownerFqn = smFqn, fieldName = "__p" + toString(kpi3)))
    kpi3 = kpi3 + 1
  }

  // Start<SM>(ref sm)
  kfInsns2.add(MLdloc(slot = 0))
  kfInsns2.add(MLdfldaByName(ownerFqn = smFqn, fieldName = "__builder"))
  kfInsns2.add(MLdloca(slot = 0))
  val startMrRow2 =
    if isVoid {
      cctx.tokAtmbStartMr
    } else {
      val tsArgsS2: List[MsilType] = newList()
      tsArgsS2.add(retTy)
      val tsBlobS2 = buildValueTypeGenericInstBlobWithCtx(lctx, tdrTypeRef(cctx.trAtmb1), tsArgsS2)
      val tsKeyS2  = "atmb1_ts_" + msilTypeKey(retTy)
      val tsRowS2  = ctxAddTypeSpec(lctx, tsKeyS2, tsBlobS2)
      val startOpenSig2 = buildAtmbStartOpenSig()
      val startMrKey2   = "atmb1_start_mr_" + msilTypeKey(retTy)
      ctxAddMemberRefForTypeSpec(lctx, tsRowS2, "Start", startMrKey2, startOpenSig2)
    }
  kfInsns2.add(MCallAtmbStart(smFqn = smFqn, atmbMrRow = startMrRow2, isGeneric = not isVoid))

  // Return Task<T> or Task
  if isVoid {
    kfInsns2.add(MLdloc(slot = 0))
    kfInsns2.add(MLdfldaByName(ownerFqn = smFqn, fieldName = "__builder"))
    kfInsns2.add(MCall(methodToken = cctx.tokAtmbGetTask))
  } else {
    val taKey5   = msilTypeKey(retTy)
    kfInsns2.add(MLdloc(slot = 0))
    kfInsns2.add(MLdfldaByName(ownerFqn = smFqn, fieldName = "__builder"))
    val tsArgs5: List[MsilType] = newList()
    tsArgs5.add(retTy)
    val tsBlob5 = buildValueTypeGenericInstBlobWithCtx(lctx, tdrTypeRef(cctx.trAtmb1), tsArgs5)
    val tsKey5  = "atmb1_ts_" + taKey5
    val tsRow5  = ctxAddTypeSpec(lctx, tsKey5, tsBlob5)
    val taskVarArgs5: List[MsilType] = newList()
    taskVarArgs5.add(MTypeVar(index = 0))
    val taskRetTy5: MsilType = MGenericInst(typeRefCode = tdrTypeRef(cctx.trTask1),
                                             headFqn = "System.Threading.Tasks.Task`1",
                                             typeArgs = taskVarArgs5)
    val gtArgs5: List[MsilType] = newList()
    val gtSig5 = buildInstanceMethodSig(gtArgs5, taskRetTy5)
    val gtKey5 = "atmb1_gettask_mr_" + taKey5
    val gtMrRow5 = ctxAddMemberRefForTypeSpec(lctx, tsRow5, "get_Task", gtKey5, gtSig5)
    kfInsns2.add(MCall(methodToken = 0x0A000000 + gtMrRow5))
  }
  kfInsns2.add(MRet)

  val kfRetTy2: MsilType =
    if isVoid {
      MClassRef(typeRefCode = tdrTypeRef(cctx.trTask),
                clrFqn = "System.Threading.Tasks.Task")
    } else {
      val kfRetArgs2: List[MsilType] = newList()
      kfRetArgs2.add(retTy)
      MGenericInst(typeRefCode = tdrTypeRef(cctx.trTask1),
                   headFqn = "System.Threading.Tasks.Task`1",
                   typeArgs = kfRetArgs2)
    }

  val kfParamTypes2: List[MsilType] = newList()
  var kpi4 = 0
  while kpi4 < decl.params.count {
    kfParamTypes2.add(typeExprToMsilCtx(cctx, decl.params[kpi4].ty, pkgName))
    kpi4 = kpi4 + 1
  }
  fns.add(MFunc(
    flags    = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG,
    name     = decl.name,
    params   = byrefWrapSigTypes(decl.params, kfParamTypes2),
    ret      = kfRetTy2,
    insns    = kfInsns2,
    maxStack = 4,
    locals   = kfLocals2))
}

// Emit the function epilogue block when at least one `return` escaped a
// protected region through `leave` (#1477).  The epilogue loads the stashed
// return value (for non-void functions) and rets.  No-op when no return used
// it, so functions without a `return`-inside-`try` are byte-identical.
func emitEpilogueMsil(fctx: in FuncCtx, insns: in List[MInsn]): Unit {
  if fctx.epilogueUsed.count > 0 {
    insns.add(MLabel(id = fctx.epilogueLabel))
    if fctx.retvalSlot >= 0 {
      emitLoadSlot(insns, fctx.retvalSlot, fctx.paramCount)
    }
    insns.add(MRet)
  }
}

pub func lowerFuncMsil(cctx: in CodegenCtx, decl: in FunctionDecl,
                       pkgName: in String): MFunc {
  val isGenerator = decl.isAsync and funcBodyContainsYieldMsil(decl)

  // Generators return List<object> (the collected yield values), regardless
  // of what the source-level return type annotation says.
  val retTy =
    if isGenerator {
      MObject
    } else if startsWith(decl.name, "__lambda_") {
      // Uniform Func ABI (#1877): synthetic lambdas return `object` (a boxed
      // value, or `null` for a void body — coerced in the return path below).
      // liftLambdasMsil sets decl.ret to Object, and the funcRetTypes mirror
      // (used to pick the System.Func delegate at the construction site) reads
      // the same Object, so construction and the emitted method signature agree.
      // The earlier hardcoded `MVoid` made every lambda a void method wrapped in
      // a Func delegate, so invoking it returned garbage and faulted on use.
      MObject
    } else {
      match decl.ret {
        case Some(te) -> {
          val resolved = typeExprToMsilCtx(cctx, te, pkgName)
          if elementTypeByte(resolved) == 0 { MVoid } else { resolved }
        }
        case None -> MVoid
      }
    }

  val className = pkgName
  // Capturing closure (#1479): a capturing `__lambda_*` takes a synthetic leading
  // `object[] __caps` parameter (the closed-over delegate target).  It occupies
  // slot 0, shifting the lambda's own params to 1+, so paramCount grows by one.
  val lambdaCaps = match mapGet(cctx.lambdaCaptureNames, decl.name) { case Some(c) -> c case None -> newList() }
  val lambdaCapTys = match mapGet(cctx.lambdaCaptureTypes, decl.name) { case Some(t) -> t case None -> newList() }
  val hasCaps = lambdaCaps.count > 0
  val effectiveParamCount = if hasCaps { decl.params.count + 1 } else { decl.params.count }
  val fctx = makeFuncCtxMsil(pkgName, className, decl.name, effectiveParamCount, retTy)
  val insns: List[MInsn] = newList()

  // Allocate slots for parameters.  These occupy slots 0..N-1 in the
  // combined slot space but are NOT added to fctx.locals.
  val isLambdaFn = startsWith(decl.name, "__lambda_")
  // Reserve slot 0 for `object[] __caps` and register each captured name's array
  // index + logical type so EPath reads resolve to `__caps[i]` (#1479).
  if hasCaps {
    val capsSlot = fctx.slotTicker.count
    fctx.slots.add("__caps", capsSlot)
    fctx.types.add("__caps", MArray(elemTy = MObject))
    fctx.slotTicker.add(0)
    val capCells = match mapGet(cctx.lambdaCaptureCells, decl.name) { case Some(c) -> c case None -> newList() }
    var cni = 0
    while cni < lambdaCaps.count {
      fctx.captureNameToIndex.add(lambdaCaps[cni], cni)
      fctx.captureNameToType.add(lambdaCaps[cni], match (if cni < lambdaCapTys.count { Some(value = lambdaCapTys[cni]) } else { None }) { case Some(t) -> t case None -> MObject })
      // A by-reference capture: `__caps[cni]` holds the hoisted `var`'s cell.
      if nameListContains(capCells, lambdaCaps[cni]) { fctx.captureCellNames.add(lambdaCaps[cni]) }
      cni = cni + 1
    }
  }
  // Parameter types propagated from a higher-order-function call site (#1939),
  // used when a lambda param is un-annotated.  Empty for non-lambdas (decl.name
  // is never a "__lambda_*" key) and lambdas not passed directly to a typed
  // `(…) -> R` parameter.
  val lambdaPropagated =
    match mapGet(cctx.lambdaParamTypes, decl.name) {
      case Some(ts) -> ts
      case None     -> newList()
    }
  var pi = 0
  while pi < decl.params.count {
    val p = decl.params[pi]
    // A lambda parameter's logical type is its annotation if present, else the
    // type propagated from the call site (#1939); the signature stays `object`.
    val annotTy = typeExprToMsilCtx(cctx, p.ty, pkgName)
    val paramTy =
      if isLambdaFn and annotTy == MObject and pi < lambdaPropagated.count { lambdaPropagated[pi] }
      else { annotTy }
    val slot = fctx.slotTicker.count
    fctx.slots.add(p.name, slot)
    fctx.types.add(p.name, paramTy)
    if isByrefMode(p.mode) {
      fctx.byrefSlotTypes.add(slot, paramTy)
    }
    // A lambda parameter arrives boxed (`object`) in the Func delegate; when it
    // has a known non-object logical type (annotation or propagated), record it
    // so reads unbox/cast on load (#1939).  The signature itself stays `object`
    // (forced below).
    if isLambdaFn and paramTy != MObject {
      fctx.boxedParamTypes.add(slot, paramTy)
    }
    // Record the declared return type of a function-typed param (a `(A,...) -> R`
    // value) so invoking it (`f()`) yields R rather than a bare object (#1877).
    match p.ty.kind {
      case TFunction(_, retTe) -> {
        fctx.funcValRetTypes.add(p.name, typeExprToMsilCtx(cctx, retTe, pkgName))
      }
      case _ -> {}
    }
    fctx.slotTicker.add(0)
    pi = pi + 1
  }

  // By-reference closure capture pre-pass (#1479 v2): collect every name used
  // inside a lambda in this body.  A `var` local in this set is hoisted to a
  // heap cell at its declaration so the closure shares the mutable location.
  match decl.body {
    case Some(FBBlock(blk)) -> { collectInLambdaNamesBlock(blk, fctx.hoistedVarNames) }
    case Some(FBExpr(e))    -> { collectInLambdaNamesExpr(e, fctx.hoistedVarNames) }
    case None -> {}
  }

  // Reserve the function epilogue label up-front so a `return` inside a
  // protected region can `leave` to it (see SReturn / #1477).  The epilogue
  // block is only emitted below when at least one return actually used it.
  fctx.epilogueLabel = freshLabelMsil(fctx)

  // Generator preamble: allocate a List<object> yield collector and record
  // its slot index in fctx.yieldSlots so that EYield lowering can append to it.
  if isGenerator {
    insns.add(MNewobj(ctorToken = cctx.tokListObjCtor))
    val collSlot = allocSlotMsil(fctx, "__yield_collector", MObject)
    insns.add(MStloc(slot = collSlot - fctx.paramCount))
    fctx.yieldSlots.add(collSlot)
  }

  // FFI: a function carrying `@externTarget("Type.Member")` synthesises
  // its body from the BCL target (#370 / Phase R6).  Falls through to
  // the normal body lowering when the annotation is absent or the
  // resolver returns None (e.g. extern types in the signature).
  val externEmitted =
    if hasExternTargetMsil(decl.annotations) {
      emitExternTargetBody(cctx, fctx, insns, decl, pkgName)
    } else { false }

  if not externEmitted {
    // Lower the body.
    match decl.body {
      case Some(body) -> {
        match body {
          case FBBlock(block) -> {
            // Three-way dispatch based on function kind:
            //   generators     → lowerBlockMsil (discard) + yield-collector return
            //   non-void       → lowerBlockExprMsil (keep trailing value on stack)
            //   void/Unit      → lowerBlockMsil (discard) + bare MRet
            if isGenerator {
              lowerBlockMsil(cctx, fctx, insns, block)
              if not endsWithReturnMsil(insns) {
                val collSlot2 = fctx.yieldSlots[0]
                insns.add(MLdloc(slot = collSlot2 - fctx.paramCount))
                insns.add(MRet)
              }
            } else if retTy != MVoid {
              val trailTy = lowerBlockExprMsil(cctx, fctx, insns, block)
              if not endsWithReturnMsil(insns) {
                // Coerce the trailing value to the declared return type — boxes a
                // value-type result when the declared return is `object` (a
                // lifted lambda), or pushes `null` for a void body (#1877).
                coerceTrailingToRetMsil(cctx, insns, trailTy, retTy)
                insns.add(MRet)
              }
            } else {
              lowerBlockMsil(cctx, fctx, insns, block)
              if not endsWithReturnMsil(insns) {
                insns.add(MRet)
              }
            }
          }
          case FBExpr(e) -> {
            lowerExprMsil(cctx, fctx, insns, e)
            if isGenerator {
              insns.add(MPop)
              val collSlot3 = fctx.yieldSlots[0]
              insns.add(MLdloc(slot = collSlot3 - fctx.paramCount))
            }
            insns.add(MRet)
          }
        }
      }
      case None -> {
        if isGenerator {
          val collSlot4 = fctx.yieldSlots[0]
          insns.add(MLdloc(slot = collSlot4 - fctx.paramCount))
        }
        insns.add(MRet)
      }
    }
  }

  // Function epilogue: target of every `return` that escaped a protected region
  // via `leave` (#1477).  Reached only through those `leave`s — the body above
  // always ends in a terminal `ret`, so there is no fall-through into it.
  emitEpilogueMsil(fctx, insns)

  // Build parameter type list for MFunc.  A lifted lambda's signature params are
  // always `object` to match the `Func<object,…,object>` delegate it is wrapped
  // in (#1939) — its annotated/inferred logical types live in boxedParamTypes
  // and are unboxed on use, not in the signature.
  val paramTypes: List[MsilType] = newList()
  // Capturing lambda: the leading `object[] __caps` (closed-over target) is the
  // method's first parameter (#1479).
  if hasCaps { paramTypes.add(MArray(elemTy = MObject)) }
  var pi2 = 0
  while pi2 < decl.params.count {
    if isLambdaFn {
      paramTypes.add(MObject)
    } else {
      paramTypes.add(typeExprToMsil(decl.params[pi2].ty, pkgName))
    }
    pi2 = pi2 + 1
  }

  MFunc(
    flags    = 0x0016,   // Public | Static | HideBySig
    name     = decl.name,
    params   = byrefWrapSigTypes(decl.params, paramTypes),
    ret      = retTy,
    insns    = insns,
    maxStack = 16,
    locals   = fctx.locals)
}

// Lower an `impl Iface for Target { func m(…) { … } }` member into an MFunc
// that will be emitted as a virtual instance method on the target type.
//
// Differs from `lowerFuncMsil` in two ways:
//   1. Slot 0 is reserved for the implicit `this` (the receiver).  `self` in
//      the body lowers to `ldarg.0` (see `ESelf` in `lowerExprMsil`), so it
//      naturally points at the receiver.  User parameters occupy slots 1..N.
//      Lyric `impl` methods never include `self` in `decl.params`; the
//      receiver is always implicit, so no `hasExplicitSelf` check is needed.
//   2. The returned `MFunc.flags` carry `Public | Virtual | HideBySig` without
//      `NewSlot` or `Final` — the CLR wires the method to the interface slot
//      by name-matching.  See msil_self_test_m11.l for validation.
//
// The `MFunc.params` list excludes `this`; the signature builder
// (`buildInstanceMethodSig`) prepends the HASTHIS bit.
pub func lowerImplMethodMsil(cctx: in CodegenCtx, decl: in FunctionDecl,
                              pkgName: in String,
                              targetTypeName: in String): MFunc {
  // The method SIGNATURE keeps the legacy erased return type (generic / class
  // returns lower to `object`) so the emitted MethodDef matches the interface
  // slot and every existing cross-assembly consumer reference.
  val retTy = match decl.ret {
    case Some(te) -> typeExprToMsil(te, pkgName)
    case None     -> MVoid
  }
  // …but `declaredRetTy` (used purely for union-case construction inference,
  // not the signature) resolves CTX-AWARE so a generic return like
  // `Result[String, E]` carries its full `MGenericInst` with concrete type
  // args.  The body's `return Ok(x)` infers the case-class type arguments from
  // `declaredRetTy` for the slots its value argument can't cover (the error
  // slot `E`).  With the legacy erased `object` the construction baked
  // `Result_Ok<String, object>`, while a cross-package consumer's `match`
  // expected `Result_Ok<String, E>` — the closed generic types differed and
  // `isinst` never matched, panicking "match not exhaustive" (#1602).
  val declaredRetTyCtx = match decl.ret {
    case Some(te) -> typeExprToMsilCtx(cctx, te, pkgName)
    case None     -> MVoid
  }
  // paramCount = 1 (this) + declared params.  emitLoadSlot/emitStoreSlot
  // distinguish params from locals by comparing slot indices against this.
  // Use targetTypeName (e.g. "Pkg.EnglishGreeter") as className so that
  // `self.method()` dispatch via MClass(fctx.className) resolves to the
  // correct methodTokens key.
  val fctx = makeFuncCtxMsil(pkgName, targetTypeName, decl.name, 1 + decl.params.count, declaredRetTyCtx)
  fctx.slotTicker.add(0)   // slot 0 = this, no name binding

  val insns: List[MInsn] = newList()

  // Allocate slots 1..N for user parameters.
  var pi = 0
  while pi < decl.params.count {
    val p = decl.params[pi]
    val paramTy = typeExprToMsil(p.ty, pkgName)
    val slot = fctx.slotTicker.count   // 1, 2, …
    fctx.slots.add(p.name, slot)
    fctx.types.add(p.name, paramTy)
    if isByrefMode(p.mode) {
      fctx.byrefSlotTypes.add(slot, paramTy)
    }
    // Record the declared return type of a function-typed param (a `(A,...) -> R`
    // value) so invoking it (`f()`) yields R rather than a bare object (#1877).
    match p.ty.kind {
      case TFunction(_, retTe) -> {
        fctx.funcValRetTypes.add(p.name, typeExprToMsilCtx(cctx, retTe, pkgName))
      }
      case _ -> {}
    }
    fctx.slotTicker.add(0)
    pi = pi + 1
  }

  // Reserve the epilogue label so a `return` inside a protected region can
  // `leave` to it (see SReturn / #1477).
  fctx.epilogueLabel = freshLabelMsil(fctx)

  // Lower the body — mirrors `lowerFuncMsil`'s logic but always non-extern.
  match decl.body {
    case Some(body) -> {
      match body {
        case FBBlock(block) -> {
          if retTy != MVoid {
            val _ = lowerBlockExprMsil(cctx, fctx, insns, block)
          } else {
            lowerBlockMsil(cctx, fctx, insns, block)
          }
          if not endsWithReturnMsil(insns) {
            insns.add(MRet)
          }
        }
        case FBExpr(e) -> {
          lowerExprMsil(cctx, fctx, insns, e)
          insns.add(MRet)
        }
      }
    }
    case None -> insns.add(MRet)
  }

  // Function epilogue for any `return` that escaped a protected region (#1477).
  emitEpilogueMsil(fctx, insns)

  val paramTypes: List[MsilType] = newList()
  var pi2 = 0
  while pi2 < decl.params.count {
    paramTypes.add(typeExprToMsil(decl.params[pi2].ty, pkgName))
    pi2 = pi2 + 1
  }

  // Public | Virtual | HideBySig — no NewSlot/Final so CLR wires the
  // concrete method to the interface slot by name-matching, matching the
  // pattern used in msil_self_test_m11.l.
  val instanceFlags = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG

  MFunc(
    flags    = instanceFlags,
    name     = decl.name,
    params   = byrefWrapSigTypes(decl.params, paramTypes),
    ret      = retTy,
    insns    = insns,
    maxStack = 16,
    locals   = fctx.locals)
}

// Return the last `.`-separated segment of `qualified` (the simple type name).
// E.g. `"Pkg.Greeter"` → `"Greeter"`, `"Greeter"` → `"Greeter"`.
pub func simpleNameOfQualifiedMsil(qualified: in String): String {
  var i = qualified.length - 1
  while i >= 0 {
    if qualified[i] == '.' {
      return qualified.substring(i + 1, qualified.length - i - 1)
    }
    i = i - 1
  }
  qualified
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. Record lowering.
// ─────────────────────────────────────────────────────────────────────────────

pub func lowerRecordMsil(decl: in RecordDecl, pkgName: in String): MRecord {
  val className = pkgName + "." + decl.name

  val fields: List[MField] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMField(f) -> {
        fields.add(MField(
          // ECMA-335 §II.23.1.5: 0x0006 = Public, 0x0001 = Private,
          // 0x0000 = PrivateScope.  Previous code used 0x0001 (Private,
          // not PrivateScope as an earlier comment claimed); cross-package
          // ldfld then raised FieldAccessException (#1183 Phase 3, #1199).
          // Mirrors FDA_PUBLIC re-exported by Msil.Lowering.
          flags     = 0x0006,
          name      = f.name,
          fieldType = typeExprToMsil(f.ty, pkgName)))
      }
      case _ -> {}
    }
    i = i + 1
  }

  val methods: List[MFunc] = newList()
  MRecord(
    className      = className,
    namespace      = pkgName,
    baseClass      = "System.Object",
    fields         = fields,
    methods        = methods,
    useDefaultCtor = false)
}

// ─────────────────────────────────────────────────────────────────────────────
// §10. Union lowering.
// ─────────────────────────────────────────────────────────────────────────────

pub func lowerUnionMsil(decl: in UnionDecl, pkgName: in String): MUnion {
  val baseName = pkgName + "." + decl.name

  val cases: List[MUnionCase] = newList()
  var i = 0
  while i < decl.cases.count {
    val c = decl.cases[i]
    val caseName = baseName + "$" + c.name
    val caseFields: List[MField] = newList()
    var fi = 0
    while fi < c.fields.count {
      match c.fields[fi] {
        case UFNamed(name, ty, _) -> {
          caseFields.add(MField(
            flags     = FDA_PUBLIC,
            name      = name,
            fieldType = typeExprToMsil(ty, pkgName)))
        }
        case UFPos(ty, _) -> {
          caseFields.add(MField(
            flags     = FDA_PUBLIC,
            name      = "field" + toString(fi),
            fieldType = typeExprToMsil(ty, pkgName)))
        }
      }
      fi = fi + 1
    }
    cases.add(MUnionCase(name = caseName, fields = caseFields))
    i = i + 1
  }

  val methods: List[MFunc] = newList()
  MUnion(
    baseName  = baseName,
    namespace = pkgName,
    cases     = cases,
    methods   = methods)
}

// ─────────────────────────────────────────────────────────────────────────────
// §11. Band-2 helpers — aspect weaver, protected types, wire blocks.
// ─────────────────────────────────────────────────────────────────────────────

// Check whether an annotation list contains an annotation with the given head name.
func hasAnnotationMsil(anns: in List[Annotation], headName: in String): Bool {
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

// ── Aspect weaver ─────────────────────────────────────────────────────────────

// Check whether a function name matches a POSIX-ish glob pattern.
// Supports * (any substring), ? (any single char).  Returns true on full match.
func globMatchMsil(glob: in String, name: in String): Bool {
  if glob == "*" { return true }
  if glob == name { return true }
  // Simple linear scan for * wildcard.
  var gi = 0
  var ni = 0
  while gi < glob.length and ni < name.length {
    val gc = glob[gi]
    if gc == '*' {
      // Consume the star then try each remaining position in name.
      gi = gi + 1
      if gi >= glob.length { return true }
      while ni < name.length {
        if globMatchMsil(glob.substring(gi), name.substring(ni)) { return true }
        ni = ni + 1
      }
      return false
    } else if gc == '?' {
      gi = gi + 1
      ni = ni + 1
    } else if gc == name[ni] {
      gi = gi + 1
      ni = ni + 1
    } else {
      return false
    }
  }
  // Consume trailing stars.
  while gi < glob.length and glob[gi] == '*' {
    gi = gi + 1
  }
  gi >= glob.length and ni >= name.length
}

// Check whether a function matches an aspect matcher predicate.
func matchesAspectMatcherMsil(matcher: in AspectMatcher, fn: in FunctionDecl): Bool {
  match matcher {
    case AMNameLike(glob, _) -> globMatchMsil(glob, fn.name)
    case AMAnnotated(annotName, _) -> hasAnnotationMsil(fn.annotations, annotName)
    case AMVisibility(vis, _) -> {
      match vis {
        case "pub" -> match fn.visibility {
          case Some(v) -> match v { case VisPub(_) -> true; case _ -> false }
          case None    -> false
        }
        case _ -> true
      }
    }
    case AMSignatureReturns(_, _) -> true  // bootstrap: skip return-type glob
  }
}

// Check whether a function is excluded from matching `aspectName`.
// `@no_aspect` with no args opts the function out of every aspect;
// `@no_aspect(Foo)` (or `@no_aspect(Foo, Bar)`) opts out only the
// named aspects, leaving others free to match.
func isOptedOutMsil(fn: in FunctionDecl, aspectName: in String): Bool {
  var i = 0
  while i < fn.annotations.count {
    val ann = fn.annotations[i]
    val segs = ann.name.segments
    if segs.count > 0 and segs[0] == "no_aspect" {
      // Bare `@no_aspect` (no args) → opt out of everything.
      if ann.args.count == 0 { return true }
      // Targeted `@no_aspect(Name1, Name2, …)` → opt out only when
      // `aspectName` is in the arg list.  Both `AAName` and `ABare`
      // are accepted; only the leading identifier portion matters.
      var j = 0
      while j < ann.args.count {
        val argName = match ann.args[j] {
          case AAName(n, _, _) -> n
          case ABare(n, _)     -> n
        }
        if argName == aspectName { return true }
        j = j + 1
      }
    }
    i = i + 1
  }
  false
}

// Check whether a function matches an aspect (all matchers AND, not in exceptNames).
func matchesAspectMsil(aspect: in AspectDecl, fn: in FunctionDecl): Bool {
  if isOptedOutMsil(fn, aspect.name) { return false }
  var ei = 0
  while ei < aspect.exceptNames.count {
    if aspect.exceptNames[ei] == fn.name { return false }
    ei = ei + 1
  }
  if aspect.matches.count == 0 { return false }
  var mi = 0
  while mi < aspect.matches.count {
    if not matchesAspectMatcherMsil(aspect.matches[mi], fn) { return false }
    mi = mi + 1
  }
  true
}

// Rewrite `proceed(args)` → `targetFuncName(p1, p2, ...)` in an expression
// tree.  Mirrors `rewriteProceeds` in `bootstrap/src/Lyric.Emitter/Weaver.fs`
// and `Lyric.Weaver.rewriteBlock` — the F# version is the spec, this port
// is what the self-hosted MSIL pipeline runs.  Without a proper AST walk
// the call to `proceed()` inside an aspect `around` body is silently
// dropped: the wrapped function never executes.
//
// Bootstrap-grade parity: `proceed`'s own argument list is ignored; the
// substitute always forwards the wrapper's own parameter list (matches the
// F# Weaver and `args.field` is not supported in this slice).

// Make a single-segment EPath expression at a zero span.
func makeProceedPathExpr(name: in String): Expr {
  val sp  = makeSpan(initialPosition(), initialPosition())
  val seg: List[String] = newList()
  seg.add(name)
  val mp  = ModulePath(segments = seg, span = sp)
  Expr(kind = EPath(path = mp), span = sp)
}

// Build the replacement ECall `targetFuncName(p1, p2, ...)`.
func proceedSubstitutionMsil(targetFuncName: in String, paramNames: in List[String]): Expr {
  val args: List[CallArg] = newList()
  var i = 0
  while i < paramNames.count {
    args.add(CAPositional(expr = makeProceedPathExpr(paramNames[i])))
    i = i + 1
  }
  Expr(
    kind = ECall(fn = makeProceedPathExpr(targetFuncName), args = args),
    span = makeSpan(initialPosition(), initialPosition()))
}

func isProceedCallMsil(expr: in Expr): Bool {
  match expr.kind {
    case ECall(f, _) -> {
      match f.kind {
        case EPath(path) ->
          path.segments.count == 1 and path.segments[0] == "proceed"
        case _ -> false
      }
    }
    case _ -> false
  }
}

// True for any `proceed(...)` call whose argument list is non-empty.  The
// bootstrap-grade rewriter always forwards the wrapper's own parameters
// regardless of what the user passed, so a non-empty arg list is silently
// dropped — panic instead so the author sees a clear diagnostic at build
// time rather than a baffling runtime mismatch (#1141).
func isProceedCallWithArgsMsil(expr: in Expr): Bool {
  match expr.kind {
    case ECall(f, args) -> {
      match f.kind {
        case EPath(path) ->
          path.segments.count == 1 and path.segments[0] == "proceed" and args.count > 0
        case _ -> false
      }
    }
    case _ -> false
  }
}

func rewriteProceedExprMsil(targetFuncName: in String, paramNames: in List[String], expr: in Expr): Expr {
  if isProceedCallWithArgsMsil(expr) {
    panic("Msil.Codegen: proceed(...) with explicit arguments is not supported by the bootstrap aspect weaver; the wrapper's own parameter list is always forwarded.  Drop the arguments or wait for the v1.x weaver (#1141).")
  }
  if isProceedCallMsil(expr) {
    return proceedSubstitutionMsil(targetFuncName, paramNames)
  }
  val s = expr.span
  match expr.kind {
    case ECall(f, args) -> {
      val newArgs: List[CallArg] = newList()
      var i = 0
      while i < args.count {
        newArgs.add(rewriteProceedCallArgMsil(targetFuncName, paramNames, args[i]))
        i = i + 1
      }
      Expr(kind = ECall(
        fn   = rewriteProceedExprMsil(targetFuncName, paramNames, f),
        args = newArgs), span = s)
    }
    case EParen(inner) ->
      Expr(kind = EParen(inner = rewriteProceedExprMsil(targetFuncName, paramNames, inner)), span = s)
    case ETuple(xs) -> {
      val newXs: List[Expr] = newList()
      var i = 0
      while i < xs.count {
        newXs.add(rewriteProceedExprMsil(targetFuncName, paramNames, xs[i]))
        i = i + 1
      }
      Expr(kind = ETuple(exprs = newXs), span = s)
    }
    case EList(xs) -> {
      val newXs: List[Expr] = newList()
      var i = 0
      while i < xs.count {
        newXs.add(rewriteProceedExprMsil(targetFuncName, paramNames, xs[i]))
        i = i + 1
      }
      Expr(kind = EList(exprs = newXs), span = s)
    }
    case EAwait(inner) ->
      Expr(kind = EAwait(inner = rewriteProceedExprMsil(targetFuncName, paramNames, inner)), span = s)
    case EYield(inner) ->
      Expr(kind = EYield(inner = rewriteProceedExprMsil(targetFuncName, paramNames, inner)), span = s)
    case ESpawn(inner) ->
      Expr(kind = ESpawn(inner = rewriteProceedExprMsil(targetFuncName, paramNames, inner)), span = s)
    case ETry(inner) ->
      Expr(kind = ETry(inner = rewriteProceedExprMsil(targetFuncName, paramNames, inner)), span = s)
    case EOld(inner) ->
      Expr(kind = EOld(inner = rewriteProceedExprMsil(targetFuncName, paramNames, inner)), span = s)
    case EPropagate(inner) ->
      Expr(kind = EPropagate(inner = rewriteProceedExprMsil(targetFuncName, paramNames, inner)), span = s)
    case EPrefix(op, operand) ->
      Expr(kind = EPrefix(op = op, operand = rewriteProceedExprMsil(targetFuncName, paramNames, operand)), span = s)
    case EBinop(op, l, r) ->
      Expr(kind = EBinop(
        op  = op,
        lhs = rewriteProceedExprMsil(targetFuncName, paramNames, l),
        rhs = rewriteProceedExprMsil(targetFuncName, paramNames, r)), span = s)
    case EAssign(t, op, v) ->
      Expr(kind = EAssign(
        target = rewriteProceedExprMsil(targetFuncName, paramNames, t),
        op     = op,
        value  = rewriteProceedExprMsil(targetFuncName, paramNames, v)), span = s)
    case EMember(recv, n) ->
      Expr(kind = EMember(
        receiver   = rewriteProceedExprMsil(targetFuncName, paramNames, recv),
        memberName = n), span = s)
    case EIndex(recv, idxs) -> {
      val newIdxs: List[Expr] = newList()
      var i = 0
      while i < idxs.count {
        newIdxs.add(rewriteProceedExprMsil(targetFuncName, paramNames, idxs[i]))
        i = i + 1
      }
      Expr(kind = EIndex(
        receiver = rewriteProceedExprMsil(targetFuncName, paramNames, recv),
        indices  = newIdxs), span = s)
    }
    case ETypeApp(f, targs) ->
      Expr(kind = ETypeApp(
        fn   = rewriteProceedExprMsil(targetFuncName, paramNames, f),
        args = targs), span = s)
    case EIf(cond, thenB, elseB, form) -> {
      val newElse = match elseB {
        case None    -> None
        case Some(e) -> Some(value = rewriteProceedEOBMsil(targetFuncName, paramNames, e))
      }
      Expr(kind = EIf(
        cond       = rewriteProceedExprMsil(targetFuncName, paramNames, cond),
        thenBranch = rewriteProceedEOBMsil(targetFuncName, paramNames, thenB),
        elseBranch = newElse,
        thenForm   = form), span = s)
    }
    case EMatch(scrut, arms) ->
      Expr(kind = EMatch(
        scrutinee = rewriteProceedExprMsil(targetFuncName, paramNames, scrut),
        arms      = rewriteProceedMatchArmsMsil(targetFuncName, paramNames, arms)), span = s)
    case ELambda(lparams, body) ->
      Expr(kind = ELambda(
        lambdaParams = lparams,
        body         = rewriteProceedBlockMsil(targetFuncName, paramNames, body)), span = s)
    case EBlock(blk) ->
      Expr(kind = EBlock(block = rewriteProceedBlockMsil(targetFuncName, paramNames, blk)), span = s)
    case EUnsafe(blk) ->
      Expr(kind = EUnsafe(block = rewriteProceedBlockMsil(targetFuncName, paramNames, blk)), span = s)
    case EInterpolated(segs) -> {
      val newSegs: List[InterpolatedSegment] = newList()
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISText(t, sp) -> newSegs.add(ISText(text = t, span = sp))
          case ISExpr(e)     ->
            newSegs.add(ISExpr(expr = rewriteProceedExprMsil(targetFuncName, paramNames, e)))
        }
        i = i + 1
      }
      Expr(kind = EInterpolated(segments = newSegs), span = s)
    }
    // True leaves (no sub-expressions): ELiteral, EPath, ESelf, EResult, ERange, EError.
    // EForall / EExists carry body sub-expressions but are panic-rejected
    // by the bootstrap MSIL codegen before this rewriter runs (search
    // this file for "EForall not supported"), and aspect `around` bodies
    // cannot legally hold a `proceed()` call inside a contract predicate,
    // so leaving them in the catch-all is intentional rather than an
    // oversight (#1142).
    case _ -> expr
  }
}

func rewriteProceedCallArgMsil(targetFuncName: in String, paramNames: in List[String], arg: in CallArg): CallArg {
  match arg {
    case CAPositional(v)     -> CAPositional(expr = rewriteProceedExprMsil(targetFuncName, paramNames, v))
    case CANamed(n, v, span) -> CANamed(name = n, value = rewriteProceedExprMsil(targetFuncName, paramNames, v), span = span)
  }
}

func rewriteProceedEOBMsil(targetFuncName: in String, paramNames: in List[String], eob: in ExprOrBlock): ExprOrBlock {
  match eob {
    case EOBBlock(blk) -> EOBBlock(block = rewriteProceedBlockMsil(targetFuncName, paramNames, blk))
    case EOBExpr(e)    -> EOBExpr(expr = rewriteProceedExprMsil(targetFuncName, paramNames, e))
  }
}

func rewriteProceedMatchArmsMsil(targetFuncName: in String, paramNames: in List[String], arms: in List[MatchArm]): List[MatchArm] {
  val newArms: List[MatchArm] = newList()
  var i = 0
  while i < arms.count {
    val a = arms[i]
    val newGuard = match a.guard {
      case Some(g) -> Some(value = rewriteProceedExprMsil(targetFuncName, paramNames, g))
      case None    -> None
    }
    newArms.add(MatchArm(
      pattern = a.pattern,
      guard   = newGuard,
      body    = rewriteProceedEOBMsil(targetFuncName, paramNames, a.body),
      span    = a.span))
    i = i + 1
  }
  newArms
}

func rewriteProceedBindingMsil(targetFuncName: in String, paramNames: in List[String], b: in LocalBinding): LocalBinding {
  match b {
    case LBVal(pat, ty, init) ->
      LBVal(pat = pat, ty = ty, init = rewriteProceedExprMsil(targetFuncName, paramNames, init))
    case LBVar(name, ty, optInit) -> {
      val newInit = match optInit {
        case None    -> None
        case Some(e) -> Some(value = rewriteProceedExprMsil(targetFuncName, paramNames, e))
      }
      LBVar(name = name, ty = ty, init = newInit)
    }
    case LBLet(name, ty, init) ->
      LBLet(name = name, ty = ty, init = rewriteProceedExprMsil(targetFuncName, paramNames, init))
  }
}

func rewriteProceedStmtMsil(targetFuncName: in String, paramNames: in List[String], stmt: in Statement): Statement {
  val s = stmt.span
  match stmt.kind {
    case SExpr(e) ->
      Statement(kind = SExpr(expr = rewriteProceedExprMsil(targetFuncName, paramNames, e)), span = s)
    case SReturn(opt) -> {
      val newOpt = match opt {
        case None    -> None
        case Some(e) -> Some(value = rewriteProceedExprMsil(targetFuncName, paramNames, e))
      }
      Statement(kind = SReturn(value = newOpt), span = s)
    }
    case SLocal(binding) ->
      Statement(kind = SLocal(binding = rewriteProceedBindingMsil(targetFuncName, paramNames, binding)), span = s)
    case SAssign(t, op, v) ->
      Statement(kind = SAssign(
        target = rewriteProceedExprMsil(targetFuncName, paramNames, t),
        op     = op,
        value  = rewriteProceedExprMsil(targetFuncName, paramNames, v)), span = s)
    case SThrow(e) ->
      Statement(kind = SThrow(expr = rewriteProceedExprMsil(targetFuncName, paramNames, e)), span = s)
    case SFor(lbl, pat, iter, body) ->
      Statement(kind = SFor(
        label = lbl,
        pat   = pat,
        iter  = rewriteProceedExprMsil(targetFuncName, paramNames, iter),
        body  = rewriteProceedBlockMsil(targetFuncName, paramNames, body)), span = s)
    case SWhile(lbl, cond, body) ->
      Statement(kind = SWhile(
        label = lbl,
        cond  = rewriteProceedExprMsil(targetFuncName, paramNames, cond),
        body  = rewriteProceedBlockMsil(targetFuncName, paramNames, body)), span = s)
    case SLoop(lbl, body) ->
      Statement(kind = SLoop(label = lbl, body = rewriteProceedBlockMsil(targetFuncName, paramNames, body)), span = s)
    case SScope(b, body) ->
      Statement(kind = SScope(binding = b, body = rewriteProceedBlockMsil(targetFuncName, paramNames, body)), span = s)
    case STry(body, catches, finally_) -> {
      val newBody = rewriteProceedBlockMsil(targetFuncName, paramNames, body)
      val newCatches: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        val cc = catches[i]
        newCatches.add(CatchClause(
          typeName = cc.typeName,
          bindName = cc.bindName,
          body     = rewriteProceedBlockMsil(targetFuncName, paramNames, cc.body),
          span     = cc.span))
        i = i + 1
      }
      val newFinally = match finally_ {
        case None     -> None
        case Some(fb) -> Some(rewriteProceedBlockMsil(targetFuncName, paramNames, fb))
      }
      Statement(kind = STry(body = newBody, catches = newCatches, finally_ = newFinally), span = s)
    }
    case SDefer(body) ->
      Statement(kind = SDefer(body = rewriteProceedBlockMsil(targetFuncName, paramNames, body)), span = s)
    // SBreak, SContinue, SInvariant, SRule, SItem: pass through
    case _ -> stmt
  }
}

func rewriteProceedBlockMsil(targetFuncName: in String, paramNames: in List[String], blk: in Block): Block {
  val newStmts: List[Statement] = newList()
  var i = 0
  while i < blk.statements.count {
    newStmts.add(rewriteProceedStmtMsil(targetFuncName, paramNames, blk.statements[i]))
    i = i + 1
  }
  Block(statements = newStmts, span = blk.span)
}

// Public entry: rewrite `proceed()` in the aspect's around body to call
// the renamed target function with the original function's params.
func rewriteProceedMsil(body: in Block, targetFuncName: in String, paramNames: in List[String]): Block {
  rewriteProceedBlockMsil(targetFuncName, paramNames, body)
}

// Wrap a Block in Some(FBBlock(block = b)): Option[FunctionBody].
// The explicit return type annotation ensures the bootstrap emitter binds the
// generic type param T of Option to FunctionBody (using ctx.ReturnType as a
// hint) instead of falling back to obj, which would cause pattern matches on
// the resulting option to silently miss both Some and None branches.
func makeSomeFBBlock(b: in Block): Option[FunctionBody] {
  Some(FBBlock(block = b))
}

// Synthesise a wrapper FunctionDecl for an aspect application.
// The wrapper has the aspect's around body; any call to "proceed" in it
// is rewritten to call `targetFuncName`.
func buildAspectWrapperMsil(originalFn: in FunctionDecl, aspect: in AspectDecl,
                             targetFuncName: in String): Option[FunctionDecl] {
  match aspect.around {
    case None -> None
    case Some(around) -> {
      // Build the wrapper: same signature as the original function.
      // Forward the wrapper's parameter list into `proceed()` (matches
      // F# Weaver.fs bootstrap-grade behaviour: `proceed`'s own arg list
      // is ignored).
      val paramNames: List[String] = newList()
      var pi = 0
      while pi < originalFn.params.count {
        paramNames.add(originalFn.params[pi].name)
        pi = pi + 1
      }
      val wrapperBody = rewriteProceedMsil(around.body, targetFuncName, paramNames)
      val wrapper = FunctionDecl(
        docComments  = newList(),
        annotations  = originalFn.annotations,
        visibility   = originalFn.visibility,
        isAsync      = false,
        name         = originalFn.name,
        generics     = None,
        params       = originalFn.params,
        ret          = originalFn.ret,
        whereClause  = None,
        contracts    = originalFn.contracts,
        body         = makeSomeFBBlock(wrapperBody),
        span         = originalFn.span)
      Some(wrapper)
    }
  }
}

// Rename a function decl (returns a new decl with a different name).
func renameFuncMsil(fn: in FunctionDecl, newName: in String): FunctionDecl {
  FunctionDecl(
    docComments  = fn.docComments,
    annotations  = fn.annotations,
    visibility   = fn.visibility,
    isAsync      = fn.isAsync,
    name         = newName,
    generics     = fn.generics,
    params       = fn.params,
    ret          = fn.ret,
    whereClause  = fn.whereClause,
    contracts    = fn.contracts,
    body         = fn.body,
    span         = fn.span)
}

// Aspect-weaving pre-pass: collect all IAspect items, then for each IFunc that
// matches an aspect, rename the original to `__aspect_target_<i>_<name>` and
// synthesise a wrapper with the original name.  Returns the rewritten SourceFile.
pub func weaveAspectsMsil(file: in SourceFile): SourceFile {
  // Collect aspect declarations.
  val aspects: List[AspectDecl] = newList()
  var ai = 0
  while ai < file.items.count {
    match file.items[ai].kind {
      case IAspect(decl) -> aspects.add(decl)
      case _             -> {}
    }
    ai = ai + 1
  }

  if aspects.count == 0 {
    return file   // nothing to do
  }

  // Build the rewritten item list.
  val newItems: List[Item] = newList()
  var ii = 0
  while ii < file.items.count {
    val item = file.items[ii]
    match item.kind {
      case IFunc(fn) -> {
        // Find the first matching aspect (if any).
        var matched = false
        var asp = 0
        while asp < aspects.count and not matched {
          val aspect = aspects[asp]
          if matchesAspectMsil(aspect, fn) {
            match aspect.around {
              case None -> {}
              case Some(_) -> {
                val targetName = "__aspect_target_" + toString(asp) + "_" + fn.name
                val renamedFn  = renameFuncMsil(fn, targetName)
                val renamedItem = Item(docComments = item.docComments, annotations = item.annotations, visibility = item.visibility, kind = IFunc(decl = renamedFn), span = item.span)
                newItems.add(renamedItem)
                match buildAspectWrapperMsil(fn, aspect, targetName) {
                  case Some(wrapper) -> {
                    val wrapperItem = Item(docComments = item.docComments, annotations = item.annotations, visibility = item.visibility, kind = IFunc(decl = wrapper), span = item.span)
                    newItems.add(wrapperItem)
                  }
                  case None -> {}
                }
                matched = true
              }
            }
          }
          asp = asp + 1
        }
        if not matched {
          newItems.add(item)
        }
      }
      case IAspect(_) -> {}  // drop aspect declarations from the output
      case _ -> newItems.add(item)
    }
    ii = ii + 1
  }

  SourceFile(
    moduleDoc        = file.moduleDoc,
    fileAnnotations  = file.fileAnnotations,
    packageDecl      = file.packageDecl,
    imports          = file.imports,
    items            = newItems,
    span             = file.span)
}

// ── Protected type lowering ───────────────────────────────────────────────────

// Lower an IProtected declaration to a sealed class with Monitor-based entry locking.
// Each PMEntry becomes a public method that acquires the lock, runs the body, releases it.
// The lock object is a private `object __lock` field.
func lowerProtectedMsil(cctx: in CodegenCtx, decl: in ProtectedTypeDecl,
                         pkgName: in String, items: in List[MPackageItem],
                         fns: in List[MFunc]): Unit {
  // For Band-2 bootstrap: emit the protected type as a regular record.
  // Full Monitor locking (Enter/Exit in a try/finally) deferred to Phase R6.
  // The type's fields are emitted as a record; entries become public methods.
  val recFields: List[MField] = newList()
  val recMethods: List[MFunc] = newList()

  var mi = 0
  while mi < decl.members.count {
    match decl.members[mi] {
      case PMField(pf) -> {
        match pf {
          case PFVar(name, ty, _, _) -> {
            recFields.add(MField(
              flags     = FDA_PUBLIC,
              name      = name,
              fieldType = typeExprToMsil(ty, pkgName)))
          }
          case PFLet(name, ty, _, _) -> {
            recFields.add(MField(
              flags     = FDA_PUBLIC + FDA_INIT_ONLY,
              name      = name,
              fieldType = typeExprToMsil(ty, pkgName)))
          }
          case PFImmutable(f) -> {
            recFields.add(MField(
              flags     = FDA_PUBLIC + FDA_INIT_ONLY,
              name      = f.name,
              fieldType = typeExprToMsil(f.ty, pkgName)))
          }
        }
      }
      case PMEntry(ed) -> {
        // Entry method: for bootstrap, emit as a regular function without locking.
        // Note: `entry` is a Lyric reserved keyword so we bind to `ed` here.
        val pTypes: List[MsilType] = newList()
        var pi = 0
        while pi < ed.params.count {
          pTypes.add(typeExprToMsil(ed.params[pi].ty, pkgName))
          pi = pi + 1
        }
        val retTy = match ed.ret {
          case Some(te) -> typeExprToMsil(te, pkgName)
          case None     -> MVoid
        }
        val entryFctx = makeFuncCtxMsil(pkgName, pkgName + "." + decl.name, decl.name, ed.params.count, retTy)
        var epi = 0
        while epi < ed.params.count {
          val p     = ed.params[epi]
          val paramTy = typeExprToMsil(p.ty, pkgName)
          val slot  = entryFctx.slotTicker.count
          entryFctx.slots.add(p.name, slot)
          entryFctx.types.add(p.name, paramTy)
          entryFctx.slotTicker.add(0)
          epi = epi + 1
        }
        val entryInsns: List[MInsn] = newList()
        match ed.body {
          case FBBlock(block) -> {
            // Mirror the lowerFuncMsil retTy dispatch: non-void entry
            // bodies keep the trailing expression on the stack as the
            // return value; void/Unit entries discard it (#1039).
            if retTy != MVoid {
              val _ = lowerBlockExprMsil(cctx, entryFctx, entryInsns, block)
            } else {
              lowerBlockMsil(cctx, entryFctx, entryInsns, block)
            }
          }
          case FBExpr(e) -> {
            lowerExprMsil(cctx, entryFctx, entryInsns, e)
            entryInsns.add(MRet)
          }
        }
        if not endsWithReturnMsil(entryInsns) {
          entryInsns.add(MRet)
        }
        recMethods.add(MFunc(
          flags    = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG,
          name     = ed.name,
          params   = pTypes,
          ret      = retTy,
          insns    = entryInsns,
          maxStack = 16,
          locals   = entryFctx.locals))
      }
      case PMFunc(fn) -> {
        val mf = lowerFuncMsil(cctx, fn, pkgName + "." + decl.name)
        recMethods.add(MFunc(
          flags    = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG,
          name     = mf.name,
          params   = mf.params,
          ret      = mf.ret,
          insns    = mf.insns,
          maxStack = mf.maxStack,
          locals   = mf.locals))
      }
      case PMInvariant(_) -> {}
    }
    mi = mi + 1
  }

  items.add(MPRecord(rec = MRecord(
    className      = pkgName + "." + decl.name,
    namespace      = pkgName,
    baseClass      = "System.Object",
    fields         = recFields,
    methods        = recMethods,
    useDefaultCtor = false)))
}

// ── Wire block lowering ───────────────────────────────────────────────────────

// Lower a wire block to a static factory class with a `create()` method that
// instantiates the dependency graph in topological order.
// For Band-2 bootstrap, we support WMSingleton and WMLocal members.
func lowerWireMsil(cctx: in CodegenCtx, decl: in WireDecl,
                   pkgName: in String, items: in List[MPackageItem],
                   fns: in List[MFunc]): Unit {
  // Synthesise a static factory function `<wireName>_create()` that
  // allocates each singleton in dependency order and returns the root.
  val createInsns: List[MInsn] = newList()
  val createFctx  = makeFuncCtxMsil(pkgName, pkgName, "__wire_create", 0, MObject)
  val createLocals: List[MsilType] = newList()

  var mi = 0
  while mi < decl.members.count {
    match decl.members[mi] {
      case WMSingleton(name, ty, init, _) -> {
        // Allocate a local slot for this singleton.
        val localTy   = typeExprToMsil(ty, pkgName)
        val localSlot = allocSlotMsil(createFctx, name, localTy)
        lowerExprMsil(cctx, createFctx, createInsns, init)
        createInsns.add(MStloc(slot = localSlot - createFctx.paramCount))
      }
      case WMLocal(name, ty, init, _) -> {
        val localTy   = match ty {
          case Some(t) -> typeExprToMsil(t, pkgName)
          case None    -> MObject
        }
        val localSlot = allocSlotMsil(createFctx, name, localTy)
        lowerExprMsil(cctx, createFctx, createInsns, init)
        createInsns.add(MStloc(slot = localSlot - createFctx.paramCount))
      }
      case WMExpose(name, _) -> {
        // Return the exposed component.
        match mapGet(createFctx.slots, name) {
          case Some(slot) -> {
            createInsns.add(MLdloc(slot = slot - createFctx.paramCount))
          }
          case None -> {
            createInsns.add(MLdNull)
          }
        }
      }
      case _ -> {}
    }
    mi = mi + 1
  }
  createInsns.add(MRet)

  val createRetTy = MObject   // bootstrap: return object
  fns.add(MFunc(
    flags    = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG,
    name     = decl.name + "_create",
    params   = newList(),
    ret      = createRetTy,
    insns    = createInsns,
    maxStack = 16,
    locals   = createFctx.locals))
}

// ─────────────────────────────────────────────────────────────────────────────
// §11b. Lambda-lifting pre-pass (Band 2, R6).
// ─────────────────────────────────────────────────────────────────────────────
//
// Extracts every ELambda in the file into a synthetic IFunc named __lambda_<i>
// so that addPackageTokens assigns deterministic MethodDef tokens before codegen.
// The ELambda nodes themselves are left in place; ELambda codegen then looks up
// __lambda_<i> by index from lambdaTicker.

// A zero-span position for synthetic AST nodes.
func syntheticPosition(): Position {
  Position(offset = 0, line = 0, column = 0)
}

func syntheticSpan(): Span {
  val p = syntheticPosition()
  Span(startPos = p, endPos = p)
}

// Check if a Block ends with an expression statement (SExpr).
// If true, the block has an implicit return value; otherwise it returns Unit/void.
func blockEndsWithExpr(block: in Block): Bool {
  if block.statements.count == 0 {
    false
  } else {
    val lastStmt = block.statements[block.statements.count - 1]
    match lastStmt.kind {
      case SExpr(_) -> true
      case _ -> false
    }
  }
}

// Convert a LambdaParam to a full Param (mode=PMIn, ty=Object).
// All lifted lambda params are typed as Object because the delegate types used
// (System.Action`N<object,...>) expect object parameters.  If the lambda body
// uses a param typed Int/Bool/etc., the value arrives as a boxed object and the
// body works regardless (bootstrap-grade: unboxing is implicit via object field
// access or is unnecessary for void-body lambdas like the test cases here).
func lambdaParamToParam(lp: in LambdaParam): Param {
  // Preserve an explicit param annotation (`{ x: Int -> … }`) as the param's
  // logical type — lowerFuncMsil forces the lifted method's *signature* params
  // to `object` (to match the `Func<object,…>` delegate) but uses this type to
  // unbox the boxed argument on use (#1939).  Unannotated params default to
  // `object` (still rejected at construction until HOF-type propagation lands).
  val ty = match lp.ty {
    case Some(t) -> t
    case None    -> {
      val seg: List[String] = newList()
      seg.add("Object")
      TypeExpr(kind = TRef(path = ModulePath(segments = seg, span = syntheticSpan())),
               span = syntheticSpan())
    }
  }
  Param(mode = PMIn, modeExplicit = true, name = lp.name, ty = ty, dflt = None, span = lp.span)
}

// BFS lambda-lifting helpers — collect ELambda nodes in breadth-first order
// so that indices assigned here match the order codegenMsil encounters them.
//
// The BFS contract: when an ELambda is found, assign its index, create the
// synthetic IFunc, and push the lambda body onto `deferred` for later
// processing.  Do NOT recurse into the lambda body here.  The caller
// (liftLambdasMsil) drains `deferred` in FIFO order after all top-level
// expressions are processed, which naturally matches the codegen traversal
// order (outer lambdas numbered before any nested lambda in their bodies).
func collectLambdasBfsExpr(e: in Expr, ticker: in List[Int], synths: in List[Item], deferred: in List[Block]): Unit {
  match e.kind {
    case ELambda(lparams, body) -> {
      // BFS: assign index, create synthetic IFunc, defer body (no recursion here).
      val idx = ticker.count
      ticker.add(0)
      val lname = "__lambda_" + toString(idx)
      val params: List[Param] = newList()
      var lpi = 0
      while lpi < lparams.count {
        params.add(lambdaParamToParam(lparams[lpi]))
        lpi = lpi + 1
      }
      // Uniform Func ABI (#1877): every lambda is lowered to a delegate that
      // returns `object`.  A trailing value-expr returns the boxed value; a
      // statement-only or void-bodied lambda returns `null` (coerced in
      // lowerFuncMsil's return path).  This keeps construction (always
      // `System.Func`) and invocation (always `Func::Invoke`) consistent — the
      // earlier split (Func for trailing-expr bodies, Action otherwise) let a
      // value-returning lambda be built as a void delegate that discarded its
      // result, so invoking it through its declared `(…) -> R` type mismatched.
      val retSeg: List[String] = newList()
      retSeg.add("Object")
      val retTy: Option[TypeExpr] =
        Some(TypeExpr(kind = TRef(path = ModulePath(segments = retSeg, span = syntheticSpan())),
                      span = syntheticSpan()))
      val decl = FunctionDecl(
        docComments = newList(),
        annotations = newList(),
        visibility  = None,
        isAsync     = false,
        name        = lname,
        generics    = None,
        params      = params,
        ret         = retTy,
        whereClause = None,
        contracts   = newList(),
        body        = Some(FBBlock(block = body)),
        span        = syntheticSpan())
      synths.add(Item(
        docComments = newList(),
        annotations = newList(),
        visibility  = None,
        kind        = IFunc(decl = decl),
        span        = syntheticSpan()))
      deferred.add(body)
    }
    case ECall(fn, args) -> {
      collectLambdasBfsExpr(fn, ticker, synths, deferred)
      var ai = 0
      while ai < args.count {
        match args[ai] {
          case CAPositional(ex)    -> { collectLambdasBfsExpr(ex, ticker, synths, deferred) }
          case CANamed(_, ex, _)   -> { collectLambdasBfsExpr(ex, ticker, synths, deferred) }
        }
        ai = ai + 1
      }
    }
    case EBinop(_, lhs, rhs) -> {
      collectLambdasBfsExpr(lhs, ticker, synths, deferred)
      collectLambdasBfsExpr(rhs, ticker, synths, deferred)
    }
    case EPrefix(_, operand)  -> { collectLambdasBfsExpr(operand, ticker, synths, deferred) }
    case EParen(inner)        -> { collectLambdasBfsExpr(inner, ticker, synths, deferred) }
    case EMember(recv, _)     -> { collectLambdasBfsExpr(recv, ticker, synths, deferred) }
    case EIf(cond, thenB, elseOpt, _) -> {
      collectLambdasBfsExpr(cond, ticker, synths, deferred)
      match thenB {
        case EOBExpr(ex)   -> { collectLambdasBfsExpr(ex, ticker, synths, deferred) }
        case EOBBlock(blk) -> {
          var si = 0
          while si < blk.statements.count {
            collectLambdasBfsStmt(blk.statements[si], ticker, synths, deferred)
            si = si + 1
          }
        }
      }
      match elseOpt {
        case Some(elseB) -> {
          match elseB {
            case EOBExpr(ex)   -> { collectLambdasBfsExpr(ex, ticker, synths, deferred) }
            case EOBBlock(blk) -> {
              var ei = 0
              while ei < blk.statements.count {
                collectLambdasBfsStmt(blk.statements[ei], ticker, synths, deferred)
                ei = ei + 1
              }
            }
          }
        }
        case None -> {}
      }
    }
    case EBlock(block) -> {
      var si = 0
      while si < block.statements.count {
        collectLambdasBfsStmt(block.statements[si], ticker, synths, deferred)
        si = si + 1
      }
    }
    case EUnsafe(block) -> {
      var si = 0
      while si < block.statements.count {
        collectLambdasBfsStmt(block.statements[si], ticker, synths, deferred)
        si = si + 1
      }
    }
    case EMatch(scr, arms) -> {
      collectLambdasBfsExpr(scr, ticker, synths, deferred)
      var ai = 0
      while ai < arms.count {
        match arms[ai].body {
          case EOBExpr(ex)   -> { collectLambdasBfsExpr(ex, ticker, synths, deferred) }
          case EOBBlock(blk) -> {
            var si = 0
            while si < blk.statements.count {
              collectLambdasBfsStmt(blk.statements[si], ticker, synths, deferred)
              si = si + 1
            }
          }
        }
        ai = ai + 1
      }
    }
    case EList(exprs) -> {
      var ei = 0
      while ei < exprs.count {
        collectLambdasBfsExpr(exprs[ei], ticker, synths, deferred)
        ei = ei + 1
      }
    }
    case EIndex(recv, indices) -> {
      collectLambdasBfsExpr(recv, ticker, synths, deferred)
      var ii = 0
      while ii < indices.count {
        collectLambdasBfsExpr(indices[ii], ticker, synths, deferred)
        ii = ii + 1
      }
    }
    case EAwait(inner)     -> { collectLambdasBfsExpr(inner, ticker, synths, deferred) }
    case EYield(inner)     -> { collectLambdasBfsExpr(inner, ticker, synths, deferred) }
    case ESpawn(inner)     -> { collectLambdasBfsExpr(inner, ticker, synths, deferred) }
    case ETry(inner)       -> { collectLambdasBfsExpr(inner, ticker, synths, deferred) }
    case EPropagate(inner) -> { collectLambdasBfsExpr(inner, ticker, synths, deferred) }
    case EAssign(_, _, v)  -> { collectLambdasBfsExpr(v, ticker, synths, deferred) }
    case EInterpolated(segs) -> {
      var si = 0
      while si < segs.count {
        match segs[si] {
          case ISExpr(ex) -> { collectLambdasBfsExpr(ex, ticker, synths, deferred) }
          case _          -> {}
        }
        si = si + 1
      }
    }
    case ETuple(exprs) -> {
      var ei = 0
      while ei < exprs.count {
        collectLambdasBfsExpr(exprs[ei], ticker, synths, deferred)
        ei = ei + 1
      }
    }
    case ETypeApp(fn, _)  -> { collectLambdasBfsExpr(fn, ticker, synths, deferred) }
    case _ -> {}
  }
}

func collectLambdasBfsStmt(s: in Statement, ticker: in List[Int], synths: in List[Item], deferred: in List[Block]): Unit {
  match s.kind {
    case SLocal(binding) -> match binding {
      case LBVal(_, _, init)    -> { collectLambdasBfsExpr(init, ticker, synths, deferred) }
      case LBLet(_, _, init)    -> { collectLambdasBfsExpr(init, ticker, synths, deferred) }
      case LBVar(_, _, initOpt) -> match initOpt {
        case Some(init) -> { collectLambdasBfsExpr(init, ticker, synths, deferred) }
        case None       -> {}
      }
    }
    case SAssign(_, _, v)  -> { collectLambdasBfsExpr(v, ticker, synths, deferred) }
    case SReturn(valOpt)   -> match valOpt {
      case Some(e) -> { collectLambdasBfsExpr(e, ticker, synths, deferred) }
      case None    -> {}
    }
    case SExpr(e)  -> { collectLambdasBfsExpr(e, ticker, synths, deferred) }
    case SThrow(e) -> { collectLambdasBfsExpr(e, ticker, synths, deferred) }
    case SWhile(_, cond, body) -> {
      collectLambdasBfsExpr(cond, ticker, synths, deferred)
      var si = 0
      while si < body.statements.count {
        collectLambdasBfsStmt(body.statements[si], ticker, synths, deferred)
        si = si + 1
      }
    }
    case SFor(_, _, iter, body) -> {
      collectLambdasBfsExpr(iter, ticker, synths, deferred)
      var si = 0
      while si < body.statements.count {
        collectLambdasBfsStmt(body.statements[si], ticker, synths, deferred)
        si = si + 1
      }
    }
    case SLoop(_, body) -> {
      var si = 0
      while si < body.statements.count {
        collectLambdasBfsStmt(body.statements[si], ticker, synths, deferred)
        si = si + 1
      }
    }
    case SScope(_, body) -> {
      var si = 0
      while si < body.statements.count {
        collectLambdasBfsStmt(body.statements[si], ticker, synths, deferred)
        si = si + 1
      }
    }
    case SDefer(body) -> {
      var si = 0
      while si < body.statements.count {
        collectLambdasBfsStmt(body.statements[si], ticker, synths, deferred)
        si = si + 1
      }
    }
    case STry(body, catches, finally_) -> {
      var si = 0
      while si < body.statements.count {
        collectLambdasBfsStmt(body.statements[si], ticker, synths, deferred)
        si = si + 1
      }
      var ci = 0
      while ci < catches.count {
        val cblk = catches[ci].body
        var csi = 0
        while csi < cblk.statements.count {
          collectLambdasBfsStmt(cblk.statements[csi], ticker, synths, deferred)
          csi = csi + 1
        }
        ci = ci + 1
      }
      match finally_ {
        case None -> {}
        case Some(fb) -> {
          var fsi = 0
          while fsi < fb.statements.count {
            collectLambdasBfsStmt(fb.statements[fsi], ticker, synths, deferred)
            fsi = fsi + 1
          }
        }
      }
    }
    case SInvariant(e)   -> { collectLambdasBfsExpr(e, ticker, synths, deferred) }
    case SRule(lhs, rhs) -> {
      collectLambdasBfsExpr(lhs, ticker, synths, deferred)
      collectLambdasBfsExpr(rhs, ticker, synths, deferred)
    }
    case _ -> {}
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Free-variable capture analysis for lambdas (#1479).
//
// A lambda is lifted to a `__lambda_<i>` *static* method.  That is correct only
// when the lambda captures nothing.  A capturing lambda — one whose body refers
// to a local/parameter of the enclosing function — needs display-class
// synthesis (a heap object holding the captured variables, with the lambda as
// an instance method over it).  Until that lands, codegen must detect captures
// and fail loudly rather than emit a static method that reads out-of-scope
// slots (which the JIT rejects as an invalid program).
//
// `lambdaCaptureNamesMsil` returns the enclosing-scope names a lambda captures:
// single-segment identifiers referenced in the body, minus the names the lambda
// itself binds (its params and any locals / pattern binds in its body),
// intersected with the enclosing function's slots.  Over-approximation (a
// missed binder) only yields a spurious capture report, never a missed one, so
// the analysis is biased toward detection.
// ─────────────────────────────────────────────────────────────────────────────

func addNameOnce(acc: in List[String], nm: in String): Unit {
  var i = 0
  while i < acc.count {
    if acc[i] == nm { return }
    i = i + 1
  }
  acc.add(nm)
}

func nameListContains(xs: in List[String], nm: in String): Bool {
  var i = 0
  while i < xs.count {
    if xs[i] == nm { return true }
    i = i + 1
  }
  false
}

func collectRefNamesExpr(e: in Expr, acc: in List[String]): Unit {
  match e.kind {
    case EPath(path) -> {
      if path.segments.count == 1 { addNameOnce(acc, path.segments[0]) }
    }
    case ECall(fn, args) -> {
      collectRefNamesExpr(fn, acc)
      var ai = 0
      while ai < args.count {
        match args[ai] {
          case CAPositional(ex)  -> { collectRefNamesExpr(ex, acc) }
          case CANamed(_, ex, _) -> { collectRefNamesExpr(ex, acc) }
        }
        ai = ai + 1
      }
    }
    case EBinop(_, lhs, rhs) -> { collectRefNamesExpr(lhs, acc); collectRefNamesExpr(rhs, acc) }
    case EPrefix(_, operand) -> { collectRefNamesExpr(operand, acc) }
    case EParen(inner)       -> { collectRefNamesExpr(inner, acc) }
    case EMember(recv, _)    -> { collectRefNamesExpr(recv, acc) }
    case EIf(cond, thenB, elseOpt, _) -> {
      collectRefNamesExpr(cond, acc)
      collectRefNamesOrdBlock(thenB, acc)
      match elseOpt { case Some(eb) -> collectRefNamesOrdBlock(eb, acc) case None -> {} }
    }
    case EBlock(block)  -> { collectRefNamesBlock(block, acc) }
    case EUnsafe(block) -> { collectRefNamesBlock(block, acc) }
    case EMatch(scr, arms) -> {
      collectRefNamesExpr(scr, acc)
      var ai = 0
      while ai < arms.count {
        collectRefNamesOrdBlock(arms[ai].body, acc)
        ai = ai + 1
      }
    }
    case EList(exprs) -> {
      var ei = 0
      while ei < exprs.count { collectRefNamesExpr(exprs[ei], acc); ei = ei + 1 }
    }
    case ETuple(exprs) -> {
      var ei = 0
      while ei < exprs.count { collectRefNamesExpr(exprs[ei], acc); ei = ei + 1 }
    }
    case EIndex(recv, indices) -> {
      collectRefNamesExpr(recv, acc)
      var ii = 0
      while ii < indices.count { collectRefNamesExpr(indices[ii], acc); ii = ii + 1 }
    }
    case EAwait(inner)     -> { collectRefNamesExpr(inner, acc) }
    case EYield(inner)     -> { collectRefNamesExpr(inner, acc) }
    case ESpawn(inner)     -> { collectRefNamesExpr(inner, acc) }
    case ETry(inner)       -> { collectRefNamesExpr(inner, acc) }
    case EPropagate(inner) -> { collectRefNamesExpr(inner, acc) }
    case EAssign(target, _, v) -> { collectRefNamesExpr(target, acc); collectRefNamesExpr(v, acc) }
    case EInterpolated(segs) -> {
      var si = 0
      while si < segs.count {
        match segs[si] { case ISExpr(ex) -> { collectRefNamesExpr(ex, acc) } case _ -> {} }
        si = si + 1
      }
    }
    case ETypeApp(fn, _) -> { collectRefNamesExpr(fn, acc) }
    case ELambda(_, body) -> { collectRefNamesBlock(body, acc) }
    case _ -> {}
  }
}

func collectRefNamesOrdBlock(ob: in ExprOrBlock, acc: in List[String]): Unit {
  match ob {
    case EOBExpr(ex)   -> { collectRefNamesExpr(ex, acc) }
    case EOBBlock(blk) -> { collectRefNamesBlock(blk, acc) }
  }
}

func collectRefNamesBlock(b: in Block, acc: in List[String]): Unit {
  var i = 0
  while i < b.statements.count {
    collectRefNamesStmt(b.statements[i], acc)
    i = i + 1
  }
}

func collectRefNamesStmt(s: in Statement, acc: in List[String]): Unit {
  match s.kind {
    case SLocal(binding) -> match binding {
      case LBVal(_, _, init)    -> { collectRefNamesExpr(init, acc) }
      case LBLet(_, _, init)    -> { collectRefNamesExpr(init, acc) }
      case LBVar(_, _, initOpt) -> match initOpt { case Some(init) -> { collectRefNamesExpr(init, acc) } case None -> {} }
    }
    case SAssign(target, _, v) -> { collectRefNamesExpr(target, acc); collectRefNamesExpr(v, acc) }
    case SReturn(valOpt) -> match valOpt { case Some(e) -> { collectRefNamesExpr(e, acc) } case None -> {} }
    case SExpr(e)  -> { collectRefNamesExpr(e, acc) }
    case SThrow(e) -> { collectRefNamesExpr(e, acc) }
    case SWhile(_, cond, body) -> { collectRefNamesExpr(cond, acc); collectRefNamesBlock(body, acc) }
    case SFor(_, _, iter, body) -> { collectRefNamesExpr(iter, acc); collectRefNamesBlock(body, acc) }
    case SLoop(_, body)  -> { collectRefNamesBlock(body, acc) }
    case SScope(_, body) -> { collectRefNamesBlock(body, acc) }
    case SDefer(body)    -> { collectRefNamesBlock(body, acc) }
    case STry(body, catches, finally_) -> {
      collectRefNamesBlock(body, acc)
      var ci = 0
      while ci < catches.count { collectRefNamesBlock(catches[ci].body, acc); ci = ci + 1 }
      match finally_ { case Some(fb) -> { collectRefNamesBlock(fb, acc) } case None -> {} }
    }
    case SInvariant(e)   -> { collectRefNamesExpr(e, acc) }
    case SRule(lhs, rhs) -> { collectRefNamesExpr(lhs, acc); collectRefNamesExpr(rhs, acc) }
    case _ -> {}
  }
}

// Pre-pass for by-reference closure capture (#1479 v2): collect every name
// referenced *inside* a lambda body anywhere in this expression/block.  A `var`
// local whose name appears here is captured by some closure and must be hoisted
// to a heap cell (so the closure and the enclosing scope share one mutable
// location).  Mirrors `collectRefNamesExpr`'s case structure exactly; the only
// collecting action is at `ELambda`, where `collectRefNamesBlock` dumps every
// name the lambda body uses (it already descends into nested lambdas).  This
// over-approximates (a same-named non-captured var may be hoisted — harmless,
// reads/writes still route through the cell correctly).
func collectInLambdaNamesExpr(e: in Expr, acc: in List[String]): Unit {
  match e.kind {
    case ELambda(_, body) -> { collectRefNamesBlock(body, acc) }
    case ECall(fn, args) -> {
      collectInLambdaNamesExpr(fn, acc)
      var ai = 0
      while ai < args.count {
        match args[ai] {
          case CAPositional(ex)  -> { collectInLambdaNamesExpr(ex, acc) }
          case CANamed(_, ex, _) -> { collectInLambdaNamesExpr(ex, acc) }
        }
        ai = ai + 1
      }
    }
    case EBinop(_, lhs, rhs) -> { collectInLambdaNamesExpr(lhs, acc); collectInLambdaNamesExpr(rhs, acc) }
    case EPrefix(_, operand) -> { collectInLambdaNamesExpr(operand, acc) }
    case EParen(inner)       -> { collectInLambdaNamesExpr(inner, acc) }
    case EMember(recv, _)    -> { collectInLambdaNamesExpr(recv, acc) }
    case EIf(cond, thenB, elseOpt, _) -> {
      collectInLambdaNamesExpr(cond, acc)
      collectInLambdaNamesOrdBlock(thenB, acc)
      match elseOpt { case Some(eb) -> collectInLambdaNamesOrdBlock(eb, acc) case None -> {} }
    }
    case EBlock(block)  -> { collectInLambdaNamesBlock(block, acc) }
    case EUnsafe(block) -> { collectInLambdaNamesBlock(block, acc) }
    case EMatch(scr, arms) -> {
      collectInLambdaNamesExpr(scr, acc)
      var ai = 0
      while ai < arms.count {
        collectInLambdaNamesOrdBlock(arms[ai].body, acc)
        ai = ai + 1
      }
    }
    case EList(exprs) -> {
      var ei = 0
      while ei < exprs.count { collectInLambdaNamesExpr(exprs[ei], acc); ei = ei + 1 }
    }
    case ETuple(exprs) -> {
      var ei = 0
      while ei < exprs.count { collectInLambdaNamesExpr(exprs[ei], acc); ei = ei + 1 }
    }
    case EIndex(recv, indices) -> {
      collectInLambdaNamesExpr(recv, acc)
      var ii = 0
      while ii < indices.count { collectInLambdaNamesExpr(indices[ii], acc); ii = ii + 1 }
    }
    case EAwait(inner)     -> { collectInLambdaNamesExpr(inner, acc) }
    case EYield(inner)     -> { collectInLambdaNamesExpr(inner, acc) }
    case ESpawn(inner)     -> { collectInLambdaNamesExpr(inner, acc) }
    case ETry(inner)       -> { collectInLambdaNamesExpr(inner, acc) }
    case EPropagate(inner) -> { collectInLambdaNamesExpr(inner, acc) }
    case EAssign(target, _, v) -> { collectInLambdaNamesExpr(target, acc); collectInLambdaNamesExpr(v, acc) }
    case EInterpolated(segs) -> {
      var si = 0
      while si < segs.count {
        match segs[si] { case ISExpr(ex) -> { collectInLambdaNamesExpr(ex, acc) } case _ -> {} }
        si = si + 1
      }
    }
    case ETypeApp(fn, _) -> { collectInLambdaNamesExpr(fn, acc) }
    case _ -> {}
  }
}

func collectInLambdaNamesOrdBlock(ob: in ExprOrBlock, acc: in List[String]): Unit {
  match ob {
    case EOBExpr(ex)   -> { collectInLambdaNamesExpr(ex, acc) }
    case EOBBlock(blk) -> { collectInLambdaNamesBlock(blk, acc) }
  }
}

func collectInLambdaNamesBlock(b: in Block, acc: in List[String]): Unit {
  var i = 0
  while i < b.statements.count {
    collectInLambdaNamesStmt(b.statements[i], acc)
    i = i + 1
  }
}

func collectInLambdaNamesStmt(s: in Statement, acc: in List[String]): Unit {
  match s.kind {
    case SLocal(binding) -> match binding {
      case LBVal(_, _, init)    -> { collectInLambdaNamesExpr(init, acc) }
      case LBLet(_, _, init)    -> { collectInLambdaNamesExpr(init, acc) }
      case LBVar(_, _, initOpt) -> match initOpt { case Some(init) -> { collectInLambdaNamesExpr(init, acc) } case None -> {} }
    }
    case SAssign(target, _, v) -> { collectInLambdaNamesExpr(target, acc); collectInLambdaNamesExpr(v, acc) }
    case SReturn(valOpt) -> match valOpt { case Some(e) -> { collectInLambdaNamesExpr(e, acc) } case None -> {} }
    case SExpr(e)  -> { collectInLambdaNamesExpr(e, acc) }
    case SThrow(e) -> { collectInLambdaNamesExpr(e, acc) }
    case SWhile(_, cond, body) -> { collectInLambdaNamesExpr(cond, acc); collectInLambdaNamesBlock(body, acc) }
    case SFor(_, _, iter, body) -> { collectInLambdaNamesExpr(iter, acc); collectInLambdaNamesBlock(body, acc) }
    case SLoop(_, body)  -> { collectInLambdaNamesBlock(body, acc) }
    case SScope(_, body) -> { collectInLambdaNamesBlock(body, acc) }
    case SDefer(body)    -> { collectInLambdaNamesBlock(body, acc) }
    case STry(body, catches, finally_) -> {
      collectInLambdaNamesBlock(body, acc)
      var ci = 0
      while ci < catches.count { collectInLambdaNamesBlock(catches[ci].body, acc); ci = ci + 1 }
      match finally_ { case Some(fb) -> { collectInLambdaNamesBlock(fb, acc) } case None -> {} }
    }
    case SInvariant(e)   -> { collectInLambdaNamesExpr(e, acc) }
    case SRule(lhs, rhs) -> { collectInLambdaNamesExpr(lhs, acc); collectInLambdaNamesExpr(rhs, acc) }
    case _ -> {}
  }
}

// Names a lambda body binds locally (so a same-named enclosing slot is shadowed,
// not captured): local bindings, `for`/`match`/`catch` pattern binds, and nested
// lambda parameters.  Patterns contribute their bound identifiers.
func collectBoundNamesPattern(p: in Pattern, acc: in List[String]): Unit {
  match p.kind {
    case PBinding(name, _) -> { addNameOnce(acc, name) }
    case PTuple(elems) -> {
      var i = 0
      while i < elems.count { collectBoundNamesPattern(elems[i], acc); i = i + 1 }
    }
    case PConstructor(_, args) -> {
      var i = 0
      while i < args.count { collectBoundNamesPattern(args[i], acc); i = i + 1 }
    }
    case _ -> {}
  }
}

func collectBoundNamesBlock(b: in Block, acc: in List[String]): Unit {
  var i = 0
  while i < b.statements.count {
    collectBoundNamesStmt(b.statements[i], acc)
    i = i + 1
  }
}

func collectBoundNamesStmt(s: in Statement, acc: in List[String]): Unit {
  match s.kind {
    case SLocal(binding) -> match binding {
      case LBVal(pat, _, _) -> { collectBoundNamesPattern(pat, acc) }
      case LBLet(name, _, _) -> { addNameOnce(acc, name) }
      case LBVar(name, _, _) -> { addNameOnce(acc, name) }
    }
    case SWhile(_, _, body) -> { collectBoundNamesBlock(body, acc) }
    case SFor(_, pat, _, body) -> { collectBoundNamesPattern(pat, acc); collectBoundNamesBlock(body, acc) }
    case SLoop(_, body)  -> { collectBoundNamesBlock(body, acc) }
    case SScope(_, body) -> { collectBoundNamesBlock(body, acc) }
    case SDefer(body)    -> { collectBoundNamesBlock(body, acc) }
    case STry(body, catches, finally_) -> {
      collectBoundNamesBlock(body, acc)
      var ci = 0
      while ci < catches.count {
        match catches[ci].bindName { case Some(nm) -> { addNameOnce(acc, nm) } case None -> {} }
        collectBoundNamesBlock(catches[ci].body, acc)
        ci = ci + 1
      }
      match finally_ { case Some(fb) -> { collectBoundNamesBlock(fb, acc) } case None -> {} }
    }
    case _ -> {}
  }
}

// Return the enclosing-scope variable names captured by a lambda.
pub func lambdaCaptureNamesMsil(fctx: in FuncCtx, lparams: in List[LambdaParam], body: in Block): List[String] {
  val refs: List[String] = newList()
  collectRefNamesBlock(body, refs)
  val bound: List[String] = newList()
  var p = 0
  while p < lparams.count { addNameOnce(bound, lparams[p].name); p = p + 1 }
  collectBoundNamesBlock(body, bound)
  val caps: List[String] = newList()
  var i = 0
  while i < refs.count {
    val nm = refs[i]
    if not nameListContains(bound, nm) {
      if fctx.slots.containsKey(nm) {
        addNameOnce(caps, nm)
      }
    }
    i = i + 1
  }
  caps
}

// BFS-based liftLambdasMsil: extract all ELambda nodes into synthetic IFunc
// items in breadth-first order so lambda indices match the codegen traversal.
pub func liftLambdasMsil(file: in SourceFile): SourceFile {
  val ticker: List[Int] = newList()
  val synths: List[Item] = newList()
  val deferred: List[Block] = newList()

  // Phase 1: walk every top-level item's body, collecting direct lambdas.
  // Each ELambda body is pushed to `deferred` rather than recursed into.
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(decl) -> {
        match decl.body {
          case Some(body) -> {
            match body {
              case FBBlock(block) -> {
                var si = 0
                while si < block.statements.count {
                  collectLambdasBfsStmt(block.statements[si], ticker, synths, deferred)
                  si = si + 1
                }
              }
              case FBExpr(e) -> { collectLambdasBfsExpr(e, ticker, synths, deferred) }
            }
          }
          case None -> {}
        }
      }
      case IVal(decl)   -> { collectLambdasBfsExpr(decl.init, ticker, synths, deferred) }
      case IConst(decl) -> { collectLambdasBfsExpr(decl.init, ticker, synths, deferred) }
      case _ -> {}
    }
    i = i + 1
  }

  // Phase 2: BFS — process deferred lambda bodies in FIFO order.
  // New lambdas found inside lambda bodies are appended to `deferred` and
  // processed in subsequent iterations, ensuring outer lambdas are always
  // numbered before any lambdas nested inside their bodies.
  var di = 0
  while di < deferred.count {
    val blk = deferred[di]
    var si = 0
    while si < blk.statements.count {
      collectLambdasBfsStmt(blk.statements[si], ticker, synths, deferred)
      si = si + 1
    }
    di = di + 1
  }

  if synths.count == 0 {
    return file
  }

  // Build new items list: original items + synthetic lambdas.
  val newItems: List[Item] = newList()
  var j = 0
  while j < file.items.count {
    newItems.add(file.items[j])
    j = j + 1
  }
  var k = 0
  while k < synths.count {
    newItems.add(synths[k])
    k = k + 1
  }

  SourceFile(
    moduleDoc       = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl     = file.packageDecl,
    imports         = file.imports,
    items           = newItems,
    span            = file.span)
}

// ─────────────────────────────────────────────────────────────────────────────
// §11c. Auto-FFI scoring — extern type method resolution (Band 2, R6).
// ─────────────────────────────────────────────────────────────────────────────
//
// When a call site matches `recv.method(args)` and `recv` is an EPath that
// resolves to a name in cctx.externTypeNames (populated from IExternType items),
// emit a direct CLR MemberRef callvirt rather than falling back to the generic
// stub.

// Populate cctx.externTypeNames from IExternType items in the file.
// Called from addPackageTokens before the IFunc pre-scan.
func scanExternTypesMsil(cctx: in CodegenCtx, file: in SourceFile): Unit {
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IExternType(decl) -> {
        // Guard against a duplicate key: a user file may declare the same
        // extern (e.g. `extern type TimeSpan = "System.TimeSpan"`) that the
        // stdlib kernel already registered into `externTypeNames` (which now
        // happens via `registerStdlibTypeItem`, #1602).  Dictionary.Add throws
        // on a duplicate, so register first-wins.  Same-name externs are
        // expected to map to the same CLR type, so the surviving entry is
        // equivalent.
        if not cctx.externTypeNames.containsKey(decl.name) {
          cctx.externTypeNames.add(decl.name, decl.clrName)
        }
      }
      case _ -> {}
    }
    i = i + 1
  }
}

// ── Metadata-based auto-FFI resolution (epic #1622, Phase 3c) ─────────────────
//
// Resolve an auto-FFI call (`ExternTypeName.method(args)`) against real .NET
// metadata via `Msil.MetadataReader` instead of the legacy `(object…) : void`
// guess.  First cut: static methods whose parameter and return types are
// primitives / string / object and exactly match the argument types (no
// implicit numeric coercion yet).  Anything else returns None and falls back
// to the legacy path (`@externTarget` wrapper required).

// A primitive MsilType's ECMA element-type byte, or -1 for a type the metadata
// reader's `SigType` cannot represent exactly.
func msilToElemByte(t: in MsilType): Int {
  match t {
    case MBool   -> 0x02
    case MChar   -> 0x03
    case MByte   -> 0x05
    case MInt    -> 0x08
    case MLong   -> 0x0A
    case MDouble -> 0x0D
    case MString -> 0x0E
    case MObject -> 0x1C
    case _       -> -1
  }
}

// Inverse: an ECMA element-type byte to its MsilType, or None when unsupported.
func elemByteToMsil(b: in Int): Option[MsilType] {
  if b == 0x01 { Some(value = MVoid) }
  else if b == 0x02 { Some(value = MBool) }
  else if b == 0x03 { Some(value = MChar) }
  else if b == 0x05 { Some(value = MByte) }
  else if b == 0x08 { Some(value = MInt) }
  else if b == 0x0A { Some(value = MLong) }
  else if b == 0x0D { Some(value = MDouble) }
  else if b == 0x0E { Some(value = MString) }
  else if b == 0x1C { Some(value = MObject) }
  else { None }
}

// The CLR FQN of an extern reference (`MClassRef`) or value (`MValueTypeRef`)
// type, or "" for any other MsilType.
func externRefFqn(t: in MsilType): String {
  match t {
    case MValueTypeRef(_, fqn) -> fqn
    case MClassRef(_, fqn)     -> fqn
    case _                     -> ""
  }
}

// True when the MsilType is a value-type extern ref (vs a class-type ref).
func msilIsValueTypeRef(t: in MsilType): Bool {
  match t {
    case MValueTypeRef(_, _) -> true
    case _                   -> false
  }
}

// True when `t` is the CLR `System.DateTime` value type, routed through either
// the VALUETYPE (`MValueTypeRef`) or CLASS (`MClassRef`) encoding.  Used by the
// `toString` builtin to pin InvariantCulture formatting (#2184).
func isClrDateTimeMsil(t: in MsilType): Bool {
  match t {
    case MValueTypeRef(_, fqn) -> fqn == "System.DateTime"
    case MClassRef(_, fqn)     -> fqn == "System.DateTime"
    case _                     -> false
  }
}

// Resolve a CLR FQN to its owning assembly's simple name via the metadata
// type-index (built once over the reference pack and cached on `cctx`).
// Falls back to "Lyric.Emitter" for Lyric host types (F# shims that are
// compiled into Lyric.Emitter.dll and never appear in the reference pack),
// and to "System.Runtime" for any remaining System.* types (core types that
// are type-forwarded from System.Private.CoreLib via the System.Runtime
// facade).  The call to ensureMetadataIndex is a no-op after the first use.
func assemblyForTypeMsil(cctx: in CodegenCtx, clrFqn: in String): String {
  ensureMetadataIndex(cctx)
  match Mdr.assemblyForType(cctx.metadataTypeIndex, clrFqn) {
    case Some(asm) -> asm
    case None      ->
      if startsWith(clrFqn, "Lyric.Emitter") or startsWith(clrFqn, "Lyric.Stdlib") {
        "Lyric.Emitter"
      } else {
        "System.Runtime"
      }
  }
}

// Intern a TypeRef for the value type `fqn` (its owning assembly comes from the
// metadata index) and return the matching `MValueTypeRef`, or None when the
// type's assembly isn't indexed.
func internValueTypeRef(cctx: in CodegenCtx, fqn: in String): Option[MsilType] {
  match Mdr.assemblyForType(cctx.metadataTypeIndex, fqn) {
    case None -> None
    case Some(asm) -> {
      val sp     = splitTypeFqn(fqn)
      val refRow = internFfiTypeRef(cctx, asm, sp.ns, sp.name)
      Some(value = MValueTypeRef(typeRefCode = tdrTypeRef(refRow), clrFqn = fqn))
    }
  }
}

// Intern a TypeRef for the class (reference) type `fqn` and return the matching
// `MClassRef`, or None when the type's assembly isn't indexed.  The companion
// of `internValueTypeRef` for ref types — `MClassRef` carries its TypeRef so a
// method signature encodes CLASS + TypeRef (a MemberRef return/param that says
// `object` would fail to bind to a method that really returns the class).
func internClassRef(cctx: in CodegenCtx, fqn: in String): Option[MsilType] {
  match Mdr.assemblyForType(cctx.metadataTypeIndex, fqn) {
    case None -> None
    case Some(asm) -> {
      val sp     = splitTypeFqn(fqn)
      val refRow = internFfiTypeRef(cctx, asm, sp.ns, sp.name)
      Some(value = MClassRef(typeRefCode = tdrTypeRef(refRow), clrFqn = fqn))
    }
  }
}

// Map a resolved parameter / return `SigType` to its MsilType: primitives via
// the element byte, value types via an interned VALUETYPE TypeRef, class
// (reference) types via an interned CLASS TypeRef.  None for anything else (or
// when the type's assembly isn't indexed) — the caller falls back to legacy.
func resolvedSigToMsil(cctx: in CodegenCtx, sig: in Mdr.SigType): Option[MsilType] {
  val pb = Mdr.sigPrimByte(sig)
  if pb >= 0 {
    elemByteToMsil(pb)
  } else {
    val fqn = Mdr.sigNamedFqn(sig)
    if fqn.length == 0 {
      None
    } else if Mdr.sigNamedIsValueType(sig) {
      internValueTypeRef(cctx, fqn)
    } else {
      internClassRef(cctx, fqn)
    }
  }
}

// Map a lowered argument's MsilType to the `SigType` used for overload
// resolution: primitives by element byte, value/class externs by FQN.  None for
// argument types the metadata path can't describe (caller falls back).
func argTyToSig(t: in MsilType): Option[Mdr.SigType] {
  val eb = msilToElemByte(t)
  if eb >= 0 {
    Some(value = Mdr.mkPrimSig(eb))
  } else {
    val fqn = externRefFqn(t)
    if fqn.length > 0 { Some(value = Mdr.mkNamedSig(fqn, msilIsValueTypeRef(t))) } else { None }
  }
}

// A stable key fragment identifying a resolved `SigType` (primitive byte or
// value/class FQN) so the MemberRef blob-intern key distinguishes overloads.
func sigTypeKeyFrag(sig: in Mdr.SigType): String {
  val pb = Mdr.sigPrimByte(sig)
  if pb >= 0 { "p" + toString(pb) } else { "n" + Mdr.sigNamedFqn(sig) }
}

// Append every instruction of `src` to `dst`.
func appendInsnsMsil(dst: in List[MInsn], src: in List[MInsn]): Unit {
  var i = 0
  while i < src.count {
    dst.add(src[i])
    i = i + 1
  }
}

// Build the metadata type→assembly / assembly→path indexes over the .NET
// reference pack on first use, cached on `cctx` for the rest of the package.
// The index is the source of truth for all assembly resolution (auto-FFI and
// @externTarget) — it finds the assembly that actually defines a type.
// A no-op after the first call; if the reference pack can't be located the
// indexes stay empty and assemblyForTypeMsil falls back to "System.Runtime"
// (adequate for Lyric-host types and System.* core types).
func ensureMetadataIndex(cctx: in CodegenCtx): Unit {
  if cctx.metadataReady.count > 0 { return }
  cctx.metadataReady.add(true)
  match Mdr.refPackDir() {
    case None -> {}
    case Some(dir) -> {
      val asms = Mdr.enumRefAssemblies(dir)
      var i = 0
      while i < asms.count {
        Mdr.addAssemblyToIndexes(cctx.metadataTypeIndex, cctx.metadataPathIndex, asms[i])
        Mdr.addAssemblyValueTypes(cctx.metadataVtypeSet, asms[i])
        i = i + 1
      }
    }
  }
}

// Widening rank for the numeric element-type bytes the auto-FFI path maps to
// MsilTypes (-1 for non-numeric).  A narrower type implicitly converts to a
// wider one.
func elemNumericRank(b: in Int): Int {
  if b == 0x05 { 1 }       // U1   (MByte)
  else if b == 0x03 { 3 }  // CHAR (MChar)
  else if b == 0x08 { 4 }  // I4   (MInt)
  else if b == 0x0A { 5 }  // I8   (MLong)
  else if b == 0x0D { 7 }  // R8   (MDouble)
  else { -1 }
}

// Instructions to append after an `argTy`-typed value to make it a
// `paramByte`-typed argument: empty for an exact match, a `box` for an
// `object` parameter, or a widening `conv` (`Int`/`Long`→`Long`/`Double`).
// None when the conversion isn't supported (caller falls back to legacy).
func argCoercionInsns(cctx: in CodegenCtx, argTy: in MsilType, paramSig: in Mdr.SigType): Option[List[MInsn]] {
  val acc: List[MInsn] = newList()
  val paramByte = Mdr.sigPrimByte(paramSig)
  if paramByte < 0 {
    // Non-primitive parameter: an extern value or class type.  The argument
    // must be the same extern type (matched by FQN) — no coercion is emitted
    // (a value type is passed by value, a class by reference).
    val pfqn = Mdr.sigNamedFqn(paramSig)
    if pfqn.length > 0 and externRefFqn(argTy) == pfqn {
      Some(value = acc)
    } else {
      None
    }
  } else {
    val argByte = msilToElemByte(argTy)
    if argByte == paramByte {
      Some(value = acc)                       // exact: no coercion
    } else if paramByte == 0x1C {
      boxIfNeededMsil(cctx, acc, argTy)       // object param: box value types
      Some(value = acc)
    } else {
      val ra = elemNumericRank(argByte)
      val rp = elemNumericRank(paramByte)
      if ra < 0 or rp < 0 or ra > rp {
        None                                  // not a supported widening
      } else if paramByte == 0x0A {
        acc.add(MConvI8)                       // → long
        Some(value = acc)
      } else if paramByte == 0x0D {
        acc.add(MConvR8)                       // → double
        Some(value = acc)
      } else {
        None                                  // → R4 / narrower int: unsupported
      }
    }
  }
}

// Emit a metadata-resolved auto-FFI call, or None to fall back.  `argBufs`
// carry each argument's already-lowered IL; `argTys` their MsilTypes.
func emitResolvedAutoFfi(
  cctx:       in CodegenCtx,
  insns:      in List[MInsn],
  asmName:    in String,
  clrFqn:     in String,
  methodName: in String,
  argBufs:    in List[List[MInsn]],
  argTys:     in List[MsilType],
  m:          in Mdr.ResolvedMethod
): Option[MsilType] {
  // Auto-FFI's receiver is a type name, so only a static method can be called
  // this way; instance overloads need an @externTarget wrapper.
  if not m.isStatic { return None }
  if m.paramTypes.count != argTys.count { return None }
  // Build the parameter MsilTypes (from the resolved signature) and the
  // per-argument coercion (exact / widening conv / box) needed to adapt each
  // argument to its parameter.  Bail to the legacy path on any unsupported
  // parameter shape (non-primitive, or an unsupported conversion).
  val paramMsil: List[MsilType]     = newList()
  val coercions: List[List[MInsn]]  = newList()
  var pi = 0
  var ok = true
  while pi < m.paramTypes.count and ok {
    val psig = m.paramTypes[pi]
    match resolvedSigToMsil(cctx, psig) {
      case None     -> { ok = false }
      case Some(pm) -> match argCoercionInsns(cctx, argTys[pi], psig) {
        case None        -> { ok = false }
        case Some(cins)  -> { paramMsil.add(pm)  coercions.add(cins) }
      }
    }
    pi = pi + 1
  }
  if not ok { return None }
  match resolvedSigToMsil(cctx, m.returnType) {
    case None -> None
    case Some(retMsil) -> {
      val sp   = splitTypeFqn(clrFqn)
      val tRef = internFfiTypeRef(cctx, asmName, sp.ns, sp.name)
      val sig  = buildStaticMethodSig(paramMsil, retMsil)
      // The blob-intern key must distinguish overloads of the same name/arity
      // (e.g. Max(int,int) vs Max(long,long), or value-type vs primitive
      // overloads) — ctxAddMemberRef dedups the signature blob by key, so it
      // encodes each parameter's identity plus the return's; otherwise a second
      // overload would reuse the first's signature.
      var sigKey = "autoffi_" + clrFqn + "." + methodName
      var ki = 0
      while ki < m.paramTypes.count {
        sigKey = sigKey + "_" + sigTypeKeyFrag(m.paramTypes[ki])
        ki = ki + 1
      }
      sigKey = sigKey + "_r" + sigTypeKeyFrag(m.returnType)
      val mrRow = ctxAddMemberRef(cctx.lctx, tRef, methodName, sigKey, sig)
      val tok = 0x0A000000 + mrRow
      var bi = 0
      while bi < argBufs.count {
        appendInsnsMsil(insns, argBufs[bi])
        appendInsnsMsil(insns, coercions[bi])   // exact: empty; widening: conv; object: box
        bi = bi + 1
      }
      insns.add(MCall(methodToken = tok))
      Some(value = retMsil)
    }
  }
}

// Emit a metadata-resolved auto-FFI *instance* call, or None to fall back.  The
// receiver is already on the stack (lowered by the caller).  Builds an instance
// (HASTHIS) MethodSig and emits `callvirt` against the real CLR method —
// callvirt is valid for both virtual and non-virtual instance methods on a
// reference receiver and performs the null check.  `argBufs` carry each
// argument's already-lowered IL; `argTys` their MsilTypes.
func emitResolvedInstanceAutoFfi(
  cctx:       in CodegenCtx,
  insns:      in List[MInsn],
  asmName:    in String,
  clrFqn:     in String,
  methodName: in String,
  argBufs:    in List[List[MInsn]],
  argTys:     in List[MsilType],
  m:          in Mdr.ResolvedMethod
): Option[MsilType] {
  val paramMsil: List[MsilType]    = newList()
  val coercions: List[List[MInsn]] = newList()
  var pi = 0
  var ok = true
  while pi < m.paramTypes.count and ok {
    val psig = m.paramTypes[pi]
    match resolvedSigToMsil(cctx, psig) {
      case None     -> { ok = false }
      case Some(pm) -> match argCoercionInsns(cctx, argTys[pi], psig) {
        case None       -> { ok = false }
        case Some(cins) -> { paramMsil.add(pm)  coercions.add(cins) }
      }
    }
    pi = pi + 1
  }
  if not ok { return None }
  match resolvedSigToMsil(cctx, m.returnType) {
    case None -> None
    case Some(retMsil) -> {
      val sp   = splitTypeFqn(clrFqn)
      val tRef = internFfiTypeRef(cctx, asmName, sp.ns, sp.name)
      val sig  = buildInstanceMethodSig(paramMsil, retMsil)
      // Distinguish instance overloads (and from the static MemberRef key) by
      // type identity of every parameter plus the return.
      var sigKey = "autoffi_inst_" + clrFqn + "." + methodName
      var ki = 0
      while ki < m.paramTypes.count {
        sigKey = sigKey + "_" + sigTypeKeyFrag(m.paramTypes[ki])
        ki = ki + 1
      }
      sigKey = sigKey + "_r" + sigTypeKeyFrag(m.returnType)
      val mrRow = ctxAddMemberRef(cctx.lctx, tRef, methodName, sigKey, sig)
      val tok = 0x0A000000 + mrRow
      // Receiver is already on the stack; push args (with coercions) then callvirt.
      var bi = 0
      while bi < argBufs.count {
        appendInsnsMsil(insns, argBufs[bi])
        appendInsnsMsil(insns, coercions[bi])
        bi = bi + 1
      }
      insns.add(MCallvirt(methodToken = tok))
      Some(value = retMsil)
    }
  }
}

// Try to resolve and emit a metadata-resolved instance call on an extern
// class-ref receiver `expr.method(args)`.  The receiver is already on the
// stack.  Returns the result MsilType on success, or None to fall back (the
// stack is left holding just the receiver — args are buffered, not emitted —
// so the caller's legacy dispatch stays correct).
func tryInstanceAutoFfiFromMetadata(
  cctx:       in CodegenCtx,
  fctx:       in FuncCtx,
  insns:      in List[MInsn],
  fqn:        in String,
  memberName: in String,
  args:       in List[CallArg]
): Option[MsilType] {
  ensureMetadataIndex(cctx)
  val argBufs: List[List[MInsn]] = newList()
  val argTys:  List[MsilType]    = newList()
  val argSigs: List[Mdr.SigType] = newList()
  var ai = 0
  var bad = false
  while ai < args.count and not bad {
    val buf: List[MInsn] = newList()
    val t   = lowerCallArgMsil(cctx, fctx, buf, args[ai])
    match argTyToSig(t) {
      case None    -> { bad = true }
      case Some(s) -> { argBufs.add(buf)  argTys.add(t)  argSigs.add(s) }
    }
    ai = ai + 1
  }
  if bad {
    None
  } else {
    match Mdr.resolveExtern(cctx.metadataTypeIndex, cctx.metadataPathIndex,
                            fqn, memberName, argSigs) {
      case None     -> None
      case Some(re) ->
        // A receiver-based call needs an instance method; a resolved static
        // means the name only exists as a static — fall back rather than
        // emit a callvirt against a static (which would be malformed).
        if re.sig.isStatic { None }
        else { emitResolvedInstanceAutoFfi(cctx, insns, re.assemblyName, fqn, memberName, argBufs, argTys, re.sig) }
    }
  }
}

// Try to resolve and emit an auto-FFI call from .NET metadata.  Returns the
// real result MsilType on success, or None to fall back to the legacy path.
// The owning assembly is found from the metadata-derived type→assembly index
// (built once over the reference pack and cached on `cctx`) via
// assemblyForTypeMsil, so resolution is accurate for types the old prefix
// table would mis-hint (e.g. `System.IO.Path` lives in `System.Runtime`).
func tryAutoFfiFromMetadata(
  cctx:       in CodegenCtx,
  fctx:       in FuncCtx,
  insns:      in List[MInsn],
  methodName: in String,
  args:       in List[CallArg],
  clrFqn:     in String
): Option[MsilType] {
  ensureMetadataIndex(cctx)
  // Lower each argument into its own buffer, capturing IL + MsilType.
  val argBufs: List[List[MInsn]] = newList()
  val argTys:  List[MsilType]    = newList()
  val argSigs: List[Mdr.SigType] = newList()
  var ai = 0
  var bad = false
  while ai < args.count and not bad {
    val buf: List[MInsn] = newList()
    val t  = lowerCallArgMsil(cctx, fctx, buf, args[ai])
    match argTyToSig(t) {
      case None    -> { bad = true }    // unsupported argument type → legacy path
      case Some(s) -> {
        argBufs.add(buf)
        argTys.add(t)
        argSigs.add(s)
      }
    }
    ai = ai + 1
  }
  if bad {
    None
  } else {
    match Mdr.resolveExtern(cctx.metadataTypeIndex, cctx.metadataPathIndex,
                            clrFqn, methodName, argSigs) {
      case None     -> None
      case Some(re) -> emitResolvedAutoFfi(cctx, insns, re.assemblyName, clrFqn, methodName, argBufs, argTys, re.sig)
    }
  }
}

// Emit an auto-FFI method call for an extern-type receiver.
// `recvName` is the Lyric name; `clrFqn` is the CLR fully-qualified type name.
// Returns the MsilType of the result.
func emitAutoFfiCallMsil(
  cctx:       in CodegenCtx,
  fctx:       in FuncCtx,
  insns:      in List[MInsn],
  recvExpr:   in Expr,
  methodName: in String,
  args:       in List[CallArg],
  clrFqn:     in String
): MsilType {
  // Phase 3c: prefer real metadata-based resolution (handles argument-bearing
  // and non-void static methods).  Falls through to the legacy gating below
  // when the shape isn't yet supported (coercion, instance, class types).
  // The silent fallback is intentional for backward compatibility; emitting
  // a note-level diagnostic ("auto-FFI: could not resolve from metadata —
  // explicit @externTarget required") is tracked separately.
  match tryAutoFfiFromMetadata(cctx, fctx, insns, methodName, args, clrFqn) {
    case Some(retTy) -> return retTy
    case None        -> {}
  }
  // Reject an extern-type CLR name the FFI cascade can't resolve to a
  // known reference assembly, rather than silently mis-binding it to
  // `System.Runtime` (opaque runtime `TypeLoadException`).
  if not clrAssemblyResolvable(clrFqn) {
    panic("Msil.Codegen: auto-FFI call '" + methodName + "' on extern type '"
      + clrFqn + "' cannot be resolved to a known reference assembly (only "
      + "System.* and the Lyric host assemblies are supported); check the "
      + "extern type's CLR name for a typo or an unsupported type.")
  }
  // Auto-FFI cannot resolve a method's signature; fail loud on argument-bearing calls.
  if args.count > 0 {
    panic("Msil.Codegen: auto-FFI call '" + clrFqn + "." + methodName
      + "(...)' takes arguments, which the self-hosted emitter cannot resolve "
      + "without the method's real signature (it would emit an (object...):void "
      + "guess that mis-binds at runtime).  Declare an @externTarget wrapper "
      + "function with the BCL signature instead — e.g. "
      + "`@externTarget(\"" + clrFqn + "." + methodName + "\") @externStatic "
      + "func ...`.  (Metadata-based resolution is tracked in #1622.)")
  }

  val sp = splitTypeFqn(clrFqn)
  val asmName = assemblyForTypeMsil(cctx, clrFqn)
  val tRefRow = internFfiTypeRef(cctx, asmName, sp.ns, sp.name)

  // Static `()`-shape call registered as `() : void` — see D-progress-343.
  val argTypes: List[MsilType] = newList()
  val sig = buildStaticMethodSig(argTypes, MVoid)
  val mrRow = ctxAddMemberRef(cctx.lctx, tRefRow, methodName, "autoffi_" + methodName, sig)
  val tok = 0x0A000000 + mrRow
  insns.add(MCall(methodToken = tok))
  MVoid
}

// ─────────────────────────────────────────────────────────────────────────────
// §12. Package codegen — main entry point.
// ─────────────────────────────────────────────────────────────────────────────

// Determine whether a function is the program entry point.
func isMainFuncMsil(decl: in FunctionDecl): Bool {
  decl.name == "main" and decl.params.count == 0
}

// Resolve an `impl Iface for Target` block to its fully-qualified target and
// interface names.  Both names live in the current package today (cross-
// package resolution lands with the broader cross-assembly impl story), so
// the segments default to the local package prefix unless the iface is
// already multi-segment.
func implTargetNameMsil(decl: in ImplDecl, pkgName: in String): String {
  match decl.target.kind {
    case TRef(path) -> pkgName + "." + lastSegmentMsil(path)
    case _          -> pkgName + ".__impl_target"
  }
}

func implIfaceNameMsil(decl: in ImplDecl, pkgName: in String): String {
  val segs = decl.iface.head.segments
  if segs.count == 1 {
    pkgName + "." + segs[0]
  } else {
    joinSegsMsil(segs, ".")
  }
}

// Pre-pass: collect every IImpl block into `cctx.implEntries`.  Each impl
// method is lowered through `lowerImplMethodMsil` so it carries virtual
// instance-method flags and slot 0 = `this`; the methods are NOT added to
// any record yet — that injection happens in the IRecord arm of the main
// loop via `injectImplMethodsIntoRecord`.
pub func collectImplEntriesMsil(cctx: in CodegenCtx, file: in SourceFile,
                                 pkgName: in String): Unit {
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IImpl(decl) -> {
        val targetName = implTargetNameMsil(decl, pkgName)
        val ifaceName  = implIfaceNameMsil(decl, pkgName)
        val methods: List[MFunc] = newList()
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case IMplFunc(fn) -> methods.add(lowerImplMethodMsil(cctx, fn, pkgName, targetName))
            case IMplAssoc(_) -> {}
          }
          mi = mi + 1
        }
        cctx.implEntries.add(ImplEntryMsil(
          targetTypeName = targetName,
          ifaceTypeName  = ifaceName,
          methods        = methods))
      }
      case _ -> {}
    }
    i = i + 1
  }
}

// Append any pre-collected impl methods whose target matches `targetFqn` to
// the record's method list, producing a new `MRecord`.  The original record
// is left untouched.
pub func injectImplMethodsIntoRecord(cctx: in CodegenCtx, rec: in MRecord,
                                      targetFqn: in String): MRecord {
  val mergedMethods: List[MFunc] = newList()
  var bi = 0
  while bi < rec.methods.count {
    mergedMethods.add(rec.methods[bi])
    bi = bi + 1
  }
  var ei = 0
  while ei < cctx.implEntries.count {
    val implEntry = cctx.implEntries[ei]
    if implEntry.targetTypeName == targetFqn {
      var mi = 0
      while mi < implEntry.methods.count {
        mergedMethods.add(implEntry.methods[mi])
        mi = mi + 1
      }
    }
    ei = ei + 1
  }
  MRecord(
    className      = rec.className,
    namespace      = rec.namespace,
    baseClass      = rec.baseClass,
    fields         = rec.fields,
    methods        = mergedMethods,
    useDefaultCtor = rec.useDefaultCtor)
}

// True iff `anns` carries a `@derive(<marker>)` annotation.  Mirrors
// `Lyric.Derives.hasDeriveMarker` (codegen can't import that package).
func hasDeriveMarkerMsil(anns: in List[Annotation], marker: in String): Bool {
  var i = 0
  while i < anns.count {
    val a = anns[i]
    if a.name.segments.count == 1 and a.name.segments[0] == "derive" and a.args.count > 0 {
      val nm = match a.args[0] {
        case ABare(n, _)    -> n
        case ALiteral(v, _) -> match v {
          case AVIdent(n, _) -> n
          case _             -> ""
        }
        case AAName(_, _, _) -> ""
      }
      if nm == marker { return true }
    }
    i = i + 1
  }
  false
}

// Synthesise the `Object.Equals(object)` / `GetHashCode()` *overrides* on a
// `@derive(Equals)` / `@derive(Hash)` record so BCL `Map`/`HashSet` key lookup
// (which dispatches these virtually) is structural rather than identity-based,
// and `a.Equals(b)` agrees with `a == b` (#1480).  Each override is a thin
// virtual instance method delegating to the derived free `<Type>.equals(self,
// other)` / `<Type>.hash(self)` (emitted by `Lyric.Derives`; reachable since
// #1796).  Appended AFTER any injected impl methods so the MethodDef rows line
// up with the budget reserved in `addPackageTokens` (one row per `hasDeriveMarkerMsil` hit).
// `recordFqn` is the type's dotted FQN (e.g. `Pkg.Point`).
pub func appendDeriveOverridesMsil(cctx: in CodegenCtx, rec: in MRecord,
                                   recordFqn: in String,
                                   anns: in List[Annotation]): MRecord {
  val methods: List[MFunc] = newList()
  var bi = 0
  while bi < rec.methods.count {
    methods.add(rec.methods[bi])
    bi = bi + 1
  }

  if hasDeriveMarkerMsil(anns, "Equals") {
    val eqTok = match mapGet(cctx.funcTokens, recordFqn + ".equals") {
      case Some(t) -> t
      case None    -> panic("Msil.Codegen: @derive(Equals) record " + recordFqn
        + " has no synthesised `.equals` token — Lyric.Derives / mono regression (#1796)")
    }
    // bool Equals(object obj) {
    //   var c = obj as <Record>;       // isinst; stloc 0
    //   if (c == null) return false;   // brfalse RETFALSE
    //   return <Record>.equals(this, c);
    // RETFALSE: return false; }
    val insns: List[MInsn] = newList()
    insns.add(MLdarg(slot = 1))                      // obj
    insns.add(MIsinstByName(className = recordFqn))   // obj as <Record>
    insns.add(MStloc(slot = 0))
    insns.add(MLdloc(slot = 0))
    insns.add(MBrFalse(label = 0))
    insns.add(MLdarg(slot = 0))                       // this
    insns.add(MLdloc(slot = 0))                       // c
    insns.add(MCall(methodToken = eqTok))             // <Record>.equals(this, c): bool
    insns.add(MRet)
    insns.add(MLabel(id = 0))
    insns.add(MLdcI4(v = 0))
    insns.add(MRet)
    val eqParams: List[MsilType] = newList()
    eqParams.add(MObject)
    val eqLocals: List[MsilType] = newList()
    eqLocals.add(MClass(className = recordFqn))
    methods.add(MFunc(
      flags    = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG,
      name     = "Equals",
      params   = eqParams,
      ret      = MBool,
      insns    = insns,
      maxStack = 8,
      locals   = eqLocals))
  }

  if hasDeriveMarkerMsil(anns, "Hash") {
    val hashTok = match mapGet(cctx.funcTokens, recordFqn + ".hash") {
      case Some(t) -> t
      case None    -> panic("Msil.Codegen: @derive(Hash) record " + recordFqn
        + " has no synthesised `.hash` token — Lyric.Derives / mono regression (#1796)")
    }
    // int GetHashCode() { return <Record>.hash(this); }
    val insns: List[MInsn] = newList()
    insns.add(MLdarg(slot = 0))                       // this
    insns.add(MCall(methodToken = hashTok))           // <Record>.hash(this): int
    insns.add(MRet)
    val ghParams: List[MsilType] = newList()
    val ghLocals: List[MsilType] = newList()
    methods.add(MFunc(
      flags    = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG,
      name     = "GetHashCode",
      params   = ghParams,
      ret      = MInt,
      insns    = insns,
      maxStack = 4,
      locals   = ghLocals))
  }

  MRecord(
    className      = rec.className,
    namespace      = rec.namespace,
    baseClass      = rec.baseClass,
    fields         = rec.fields,
    methods        = methods,
    useDefaultCtor = rec.useDefaultCtor)
}

// The caller must subsequently call `lowerMPackageWithCtx(pkg, cctx.lctx, entryToken)`
// to emit the PE bytes.
pub func codegenMPackage(file: in SourceFile, cctx: in CodegenCtx): MPackage {
  val pkgSegs = file.packageDecl.path.segments
  val pkgName = joinSegsMsil(pkgSegs, ".")

  // Reset the lambda counter so each package's ELambda lookup walks from
  // `__lambda_0` (matching the per-package `liftLambdasMsil` numbering).
  // Without this reset, multi-package bundles with closures panic from the
  // second package onward with "lambda token missing for __lambda_<n>"
  // because `addPackageTokens` registered FQNs `<pkg>.__lambda_0...` while
  // codegen looked up `<pkg>.__lambda_<bundleIdx>` (#1194).
  cctx.lambdaTicker.clear()

  val fns:          List[MFunc]        = newList()
  val staticFields: List[MStaticField] = newList()
  val items:        List[MPackageItem] = newList()
  var hasMain = false

  // ── Band-2: aspect pre-pass ───────────────────────────────────────────────
  //
  // **Pre-condition:** every caller of `codegenMPackage` is expected to
  // have already woven the file via `Lyric.Weaver.weaveFileWithDiags`
  // (or equivalent) and aborted on any A0042 / A0043 / A0044 errors.
  // Today the only caller is `Msil.Bridge` (single-file and project
  // paths), which does this — so the second call below is an idempotent
  // safety net (the weaver short-circuits when no `IAspect` items
  // remain after the first weave).
  //
  // We hard-enforce the pre-condition: panic if the second weave
  // surfaces any diagnostics.  By construction, a properly-woven file
  // has no remaining `IAspect` items, so the weaver emits no diagnostics
  // — a non-empty list here means a caller bypassed the bridge and
  // is feeding raw source into codegen, which would otherwise silently
  // drop the diagnostics and produce wrong code.  Hard-fail instead of
  // quietly miscompiling.
  val weaveSafety = Weaver.weaveFileWithDiags(file)
  if weaveSafety.diagnostics.count > 0 {
    panic("codegenMPackage: weaver produced " +
          toString(weaveSafety.diagnostics.count) +
          " diagnostic(s) on the second-pass weave — caller bypassed " +
          "Msil.Bridge's pre-weave + reportAndAbort contract.  Call " +
          "Weaver.weaveFileWithDiags(file) first and abort on errors.")
  }
  val weavedFile = weaveSafety.file

  // ── #878: IImpl pre-pass ──────────────────────────────────────────────────
  // Mirrors the JVM backend's approach (`Jvm.Codegen.codegenPackage`): scan
  // every IImpl block up-front, lower each impl method to an instance-method
  // MFunc, and stash the result on `cctx.implEntries`.  The main loop below
  // then (a) injects matching entries' methods into each IRecord's method
  // list — emitted as virtual instance methods by `lowerMRecord` — and (b)
  // queues an `MPImpl(MImplData)` item per entry, processed after all
  // TypeDefs are emitted so `lowerMImpl` can resolve TypeDef rows and
  // MethodDef tokens by name.
  collectImplEntriesMsil(cctx, weavedFile, pkgName)

  var i = 0
  while i < weavedFile.items.count {
    val item = weavedFile.items[i]
    match item.kind {
      case IRecord(decl) -> {
        val baseRec = lowerRecordMsil(decl, pkgName)
        val rec0 = injectImplMethodsIntoRecord(cctx, baseRec, pkgName + "." + decl.name)
        val rec = appendDeriveOverridesMsil(cctx, rec0, pkgName + "." + decl.name, item.annotations)
        items.add(MPRecord(rec = rec))
      }
      case IExposedRec(decl) -> {
        val baseRec = lowerRecordMsil(decl, pkgName)
        val rec0 = injectImplMethodsIntoRecord(cctx, baseRec, pkgName + "." + decl.name)
        val rec = appendDeriveOverridesMsil(cctx, rec0, pkgName + "." + decl.name, item.annotations)
        items.add(MPRecord(rec = rec))
      }
      case IFunc(decl) -> {
        // Route async SM synthesis: Phase B.1 (with awaits) or Phase B.0 (no awaits).
        // Generators and @externTarget async funcs use their existing paths.
        val isGenerator = decl.isAsync and funcBodyContainsYieldMsil(decl)
        val isExternFunc = hasExternTargetMsil(decl.annotations)
        val useSm = decl.isAsync and not isGenerator and not isExternFunc
        if useSm {
          if funcBodyContainsAwaitMsil(decl) {
            synthesizeAsyncSmPhaseBMsil(cctx, decl, pkgName, items, fns)
          } else {
            synthesizeAsyncSmMsil(cctx, decl, pkgName, items, fns)
          }
        } else {
          fns.add(lowerFuncMsil(cctx, decl, pkgName))
        }
        if isMainFuncMsil(decl) {
          hasMain = true
        }
      }
      case IUnion(decl) -> {
        items.add(MPUnion(u = lowerUnionMsil(decl, pkgName)))
      }
      case IDistinctType(decl) -> {
        val inner = typeExprToMsil(decl.underlying, pkgName)
        items.add(MPDistinctType(d = MDistinctType(
          className = pkgName + "." + decl.name,
          namespace = pkgName,
          inner     = inner)))
      }
      case IConst(decl) -> {
        // Module-level compile-time constant → static literal field on the host class.
        val initFctx = makeFuncCtxMsil(pkgName, pkgName, "__const_" + decl.name, 0, MVoid)
        val initInsns: List[MInsn] = newList()
        lowerExprMsil(cctx, initFctx, initInsns, decl.init)
        // Fold the constant value from the first instruction (ldc.i4 for Int).
        val constVal = match initInsns.count {
          case n if n > 0 -> match initInsns[0] {
            case MLdcI4(v) -> v
            case _         -> 0
          }
          case _ -> 0
        }
        val sfield = MStaticField(
          flags      = FDA_PUBLIC + FDA_STATIC + FDA_LITERAL + FDA_HAS_DEFAULT,
          name       = decl.name,
          fieldType  = typeExprToMsil(decl.ty, pkgName),
          constValue = constVal,
          hasLiteral = true,
          initInsns  = newList())
        staticFields.add(sfield)
        // Register the inlined value so EPath references emit ldc.i4 directly.
        cctx.constValues.add(decl.name, constVal)
      }
      case IVal(decl) -> {
        // Module-level runtime value → static readonly field initialized in .cctor.
        val initFctx = makeFuncCtxMsil(pkgName, pkgName, "__val_init", 0, MVoid)
        val initInsns: List[MInsn] = newList()
        val valTy = lowerExprMsil(cctx, initFctx, initInsns, decl.init)
        val fieldTy = match decl.ty {
          case Some(te) -> typeExprToMsil(te, pkgName)
          case None     -> valTy
        }
        val fieldName = match decl.pattern.kind {
          case PBinding(name, _) -> name
          case _                 -> "__val_" + toString(staticFields.count)
        }
        // When the init is a single ldc.i4 (literal Int), inline into constValues
        // and pass an empty initInsns to avoid generating a .cctor for this field.
        // All uses of the val in this package will emit ldc.i4 directly.
        var sfInitInsns = initInsns
        if initInsns.count == 1 {
          match initInsns[0] {
            case MLdcI4(v) -> {
              cctx.constValues.add(fieldName, v)
              sfInitInsns = newList()
            }
            case _ -> {}
          }
        }
        val sfield = MStaticField(
          flags      = FDA_PUBLIC + FDA_STATIC + FDA_INIT_ONLY,
          name       = fieldName,
          fieldType  = fieldTy,
          constValue = 0,
          hasLiteral = false,
          initInsns  = sfInitInsns)
        staticFields.add(sfield)
      }
      case IEnum(decl) -> {
        // Band-2 #849: CLR enum type.
        val caseNames: List[String] = newList()
        var ci = 0
        while ci < decl.cases.count {
          caseNames.add(decl.cases[ci].name)
          ci = ci + 1
        }
        items.add(MPEnum(e = MEnum(
          className = pkgName + "." + decl.name,
          namespace = pkgName,
          cases     = caseNames)))
      }
      case IInterface(decl) -> {
        // Band-2 #850: interface declaration.
        val ifaceMethods: List[MInterfaceMethod] = newList()
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case IMSig(sig) -> {
              val pTypes: List[MsilType] = newList()
              var pi = 0
              while pi < sig.params.count {
                pTypes.add(typeExprToMsil(sig.params[pi].ty, pkgName))
                pi = pi + 1
              }
              val retTy = match sig.ret {
                case Some(te) -> typeExprToMsil(te, pkgName)
                case None     -> MVoid
              }
              ifaceMethods.add(MInterfaceMethod(
                name   = sig.name,
                params = byrefWrapSigTypes(sig.params, pTypes),
                ret    = retTy))
            }
            case IMFunc(fn) -> {
              // Default interface method — for now, emit as abstract signature.
              val pTypes: List[MsilType] = newList()
              var pi = 0
              while pi < fn.params.count {
                pTypes.add(typeExprToMsil(fn.params[pi].ty, pkgName))
                pi = pi + 1
              }
              val retTy = match fn.ret {
                case Some(te) -> typeExprToMsil(te, pkgName)
                case None     -> MVoid
              }
              ifaceMethods.add(MInterfaceMethod(
                name   = fn.name,
                params = byrefWrapSigTypes(fn.params, pTypes),
                ret    = retTy))
            }
            case IMAssoc(_) -> {}
          }
          mi = mi + 1
        }
        items.add(MPInterface(iface = MInterface(
          className = pkgName + "." + decl.name,
          namespace = pkgName,
          methods   = ifaceMethods)))
      }
      case IImpl(_) -> {
        // Handled by the `collectImplEntriesMsil` pre-pass above; both the
        // record-method injection and the InterfaceImpl/MethodImpl emission
        // happen elsewhere in this function so the source-order arm is a
        // no-op (#878).
      }
      case IOpaque(decl) -> {
        // Band-2 #853: opaque type.
        if decl.hasBody {
          val oFields: List[MField] = newList()
          var fi = 0
          while fi < decl.members.count {
            match decl.members[fi] {
              case OMField(f) -> {
                oFields.add(MField(
                  flags     = FDA_PRIVATE,
                  name      = f.name,
                  fieldType = typeExprToMsil(f.ty, pkgName)))
              }
              case OMInvariant(_) -> {}
            }
            fi = fi + 1
          }
          val isProj = hasAnnotationMsil(decl.annotations, "projectable")
          items.add(MPOpaque(opaqueData = MOpaque(
            className     = pkgName + "." + decl.name,
            namespace     = pkgName,
            fields        = oFields,
            methods       = newList(),
            isProjectable = isProj)))
        }
      }
      case IProtected(decl) -> {
        // Band-2 #855: protected type — Monitor-based locking.
        lowerProtectedMsil(cctx, decl, pkgName, items, fns)
      }
      case IWire(decl) -> {
        // Band-2 #855: wire block — static DI factory class.
        lowerWireMsil(cctx, decl, pkgName, items, fns)
      }
      case IAspect(_)       -> {}  // consumed by weaveAspectsMsil above
      case ITypeAlias(_)    -> {}
      case IScopeKind(_)    -> {}
      case IExtern(_)       -> {}
      case IExternType(_)   -> {}
      case ITest(_)         -> {}
      case IProperty(_)     -> {}
      case IFixture(_)      -> {}
      case IConfig(_)       -> {}
      case IError           -> {}
    }
    i = i + 1
  }

  // Emit the host class: functions + static fields (IConst/IVal).
  if fns.count > 0 or staticFields.count > 0 {
    items.add(MPFuncs(hostClass = pkgName, funcs = fns, staticFields = staticFields))
  }

  // ── #878: MPImpl emission ─────────────────────────────────────────────────
  // After every record/interface/host-class TypeDef has been added to `items`,
  // queue one `MPImpl(MImplData)` per pre-pass entry so the lowering layer
  // emits the InterfaceImpl row after all TypeDefs are in the table.  The row
  // numbers are resolved by name in `lowerMImpl` (`findTypeDefRowByName`).
  var ie = 0
  while ie < cctx.implEntries.count {
    val implEntry = cctx.implEntries[ie]
    // `slots` is reserved for future aliased-implementation support (impl
    // methods whose name differs from the interface slot they satisfy).
    // Today, Lyric `impl` blocks always use the same name as the interface
    // method, so CLR name-matching wires them without explicit MethodImpl rows
    // and `lowerMImpl` does not iterate slots.
    val mslots: List[MImplSlot] = newList()
    var mi = 0
    while mi < implEntry.methods.count {
      val mname = implEntry.methods[mi].name
      mslots.add(MImplSlot(
        ifaceMethodToken = 0,
        implMethodToken  = 0,
        ifaceMethodName  = mname,
        implMethodName   = mname))
      mi = mi + 1
    }
    items.add(MPImpl(implData = MImplData(
      targetTypeDefRow = 0,
      ifaceTypeToken   = 0,
      slots            = mslots,
      targetTypeName   = implEntry.targetTypeName,
      ifaceTypeName    = implEntry.ifaceTypeName)))
    ie = ie + 1
  }

  MPackage(packageName = pkgName, items = items)
}

// ─────────────────────────────────────────────────────────────────────────────
// §N. Restored-artifact symbol registration.
// ─────────────────────────────────────────────────────────────────────────────
//
// Walk each `SynthesisedArtifact` in `cctx.restoredArtifacts` and seed
// the cross-package symbol tables so consumer-side type references to
// restored packages resolve to TypeRef rows pointing at the foreign
// `AssemblyRef`.  Registers type-shaped decls only; MemberRef rows for
// record ctors / free functions / union case ctors require
// signature-blob encoding from the typechecker's `ResolvedSignature`
// map and ship in the c.3 slice.

// Allocate one AssemblyRef per restored artifact, keyed by package
// name → AssemblyRef row.  Cached in `ffiAsmRefs` so multiple
// `registerRestoredArtifactTokens` calls against the same package
// re-use the row.  Lyric-emitted assemblies use `<packageName>.dll`,
// so the simple assembly name matches the package name verbatim.
func ensureAssemblyRefForArtifact(cctx: in CodegenCtx,
                                  packageName: in String): Int {
  match mapGet(cctx.ffiAsmRefs, packageName) {
    case Some(row) -> return row
    case None      -> ()
  }
  // Match the restored artifact's Assembly version so the loader binds
  // against the actual producer DLL.  The artifact carries the version
  // string the producer's bundle was built with — populated by
  // `Lyric.RestoredPackages.loadRestoredPackage` from the embedded
  // `Lyric.Contract` resource (slice 2b / 2b-and-version, #1364).
  // Unknown package (not in `cctx.restoredArtifacts`) falls back to
  // `0.0` — that path only fires when an ad-hoc caller registers a
  // record / func TypeRef without going through `registerRestoredArtifactTokens`,
  // which is itself a bug; the fallback keeps the loader happy.
  val verStr = lookupRestoredArtifactVersion(cctx, packageName)
  val verParts = parseSemverMajorMinor(verStr)
  val row = ctxAddLyricPackageAssemblyRef(cctx.lctx, packageName,
                                           verParts[0], verParts[1])
  cctx.ffiAsmRefs.add(packageName, row)
  row
}

// Walk `cctx.restoredArtifacts` for the matching package and return its
// declared version string, or `""` when no match.  Linear scan is fine —
// the typical restored-deps count is a handful, and the lookup happens
// once per cross-assembly AssemblyRef (results cached in `ffiAsmRefs`).
func lookupRestoredArtifactVersion(cctx: in CodegenCtx,
                                   packageName: in String): String {
  var i = 0
  while i < cctx.restoredArtifacts.count {
    val art = cctx.restoredArtifacts[i]
    if art.packageName == packageName { return art.version }
    i = i + 1
  }
  ""
}

// True iff `c` is an identifier continuation (ASCII).
@pure
func isIdentChar(c: in Char): Bool {
  c == '_' or
  (c >= '0' and c <= '9') or
  (c >= 'a' and c <= 'z') or
  (c >= 'A' and c <= 'Z')
}

// Walk a union decl's `repr` for case names.  The contract `repr` for
// unions is the canonical source-level form, e.g.
// `pub union Maybe { case Some(v: Int), case None }`.  Case names
// follow the literal `case ` keyword and are terminated by `(`, ` `,
// `,`, or `}`.
func registerUnionCases(cctx: in CodegenCtx,
                        packageName: in String,
                        unionName: in String,
                        decl: in ContractDecl): Unit {
  val repr = decl.repr
  val needle = "case "
  var idx = 0
  // Loop exits via the early `return`s below (`indexOf` no-match
  // or `nameStart >= repr.length`); `idx` is non-negative by
  // construction (#1279).
  while true {
    val hit = repr.indexOf(needle, idx)
    if hit < 0 { return }
    val nameStart = hit + needle.length
    if nameStart >= repr.length { return }
    var j = nameStart
    while j < repr.length and isIdentChar(repr[j]) {
      j = j + 1
    }
    if j > nameStart {
      val caseName = repr.substring(nameStart, j - nameStart)
      val ctorKey  = packageName + "." + unionName + "$" + caseName
      if not cctx.unionCaseCtorByName.containsKey(caseName) {
        cctx.unionCaseCtorByName.add(caseName, ctorKey)
      }
    }
    idx = j
  }
}

// Register one type-shaped decl from a restored artifact: allocates
// the TypeRef row (cached in `ffiTypeRefs`), seeds the simple-name
// lookup in `typeFqnByName`, and for unions, also seeds case names
// in `unionCaseCtorByName`.  First-wins on collisions.
func registerRestoredTypeDecl(cctx: in CodegenCtx,
                              packageName: in String,
                              decl: in ContractDecl,
                              asmRefRow: in Int): Unit {
  val typeName = decl.name
  val typeFqn  = packageName + "." + typeName

  val typeRefKey = packageName + "/" + typeFqn
  if not cctx.ffiTypeRefs.containsKey(typeRefKey) {
    val row = ctxAddTypeRef(cctx.lctx, packageName, typeName, asmRefRow)
    cctx.ffiTypeRefs.add(typeRefKey, row)
  }

  if not cctx.typeFqnByName.containsKey(typeName) {
    cctx.typeFqnByName.add(typeName, typeFqn)
  }

  if decl.kind == "union" {
    registerUnionCases(cctx, packageName, typeName, decl)
  }
}

// Look up the TypeRef row previously allocated by registerRestoredTypeDecl.
// Returns 0 when no row exists (caller skips MemberRef allocation).
func lookupRestoredTypeRefRow(cctx: in CodegenCtx, packageName: in String,
                              typeName: in String): Int {
  val typeFqn    = packageName + "." + typeName
  val typeRefKey = packageName + "/" + typeFqn
  match mapGet(cctx.ffiTypeRefs, typeRefKey) {
    case Some(row) -> row
    case None      -> 0
  }
}

// Look up (or allocate) the TypeRef row for a foreign package's
// free-function host class.  Both the F# emitter and the self-hosted
// `lowerMFuncsToHostClass` name that class `<package>.Program` — the
// full package path is the CLR namespace and `Program` is the type
// name.  The cross-assembly TypeRef must name that exact pair or the
// CLR throws "Could not load type '<package>'" when the consumer
// invokes a function (this was the `Std.Testing` ecosystem-test
// failure: the old split-at-last-dot form referenced `(Std, Testing)`
// = full name `Std.Testing`, but the host class is `Std.Testing.Program`).
// Cached under "<pkg>/host" in `ffiTypeRefs` so multiple
// `registerRestoredFreeFunc` calls share one TypeRef.
func ensureHostClassTypeRefRow(cctx: in CodegenCtx,
                               packageName: in String,
                               asmRefRow: in Int): Int {
  val key = packageName + "/host"
  if cctx.ffiTypeRefs.containsKey(key) {
    match mapGet(cctx.ffiTypeRefs, key) {
      case Some(row) -> return row
      case None      -> ()
    }
  }
  // TypeDef convention matches the F# bootstrap emitter (and
  // `lowerMFuncsToHostClass` in lowering.l): namespace = full package
  // name, class = "Program".  E.g. "Std.Testing" → namespace="Std.Testing",
  // class="Program".
  val row = ctxAddTypeRef(cctx.lctx, packageName, "Program", asmRefRow)
  cctx.ffiTypeRefs.add(key, row)
  row
}

// Register a record's ctor as a cross-assembly MemberRef in
// `recordCtorTokens`.  The ctor's signature mirrors the in-bundle
// `lowerMRecord` convention: HASTHIS, returns void, one param per
// FIELD (class fields degrade to OBJECT in the sig blob, matching
// `bufMsilType`'s known limitation — the foreign DLL's ctor uses
// the same encoding so the runtime resolver matches).
func registerRestoredRecordCtor(cctx: in CodegenCtx,
                                packageName: in String,
                                rec: in RecordDecl): Unit {
  val className = packageName + "." + rec.name
  if cctx.recordCtorTokens.containsKey(className) { return }

  val typeRefRow = lookupRestoredTypeRefRow(cctx, packageName, rec.name)
  if typeRefRow == 0 { return }

  val ctorParams: List[MsilType] = newList()
  var fi = 0
  while fi < rec.members.count {
    match rec.members[fi] {
      case RMField(f) -> {
        ctorParams.add(typeExprToMsilCtx(cctx, f.ty, packageName))
      }
      case _ -> ()
    }
    fi = fi + 1
  }

  val ctorSig    = buildInstanceMethodSig(ctorParams, MVoid)
  val sigKey     = "restored_ctor_" + className
  val memberRow  = ctxAddMemberRef(cctx.lctx, typeRefRow, ".ctor",
                                    sigKey, ctorSig)
  cctx.recordCtorTokens.add(className, 0x0A000000 + memberRow)
}

// Register cross-assembly MemberRef rows for each field of a restored record
// so that `EMember` lowering can emit `ldfld` with a cross-assembly token
// instead of silently popping the receiver and returning MObject.
//
// The field MemberRef signature mirrors `buildFieldSig`: reference-type
// fields degrade to ELEMENT_TYPE_OBJECT (0x1C) to match the encoding that
// `lowerMRecord` produces in the foreign DLL.  `fieldMsilTypes` carries the
// "semantic" type (e.g. MListOf or MClass) so downstream codegen can still
// see the element type for correct EIndex handling.
func registerRestoredRecordFields(cctx: in CodegenCtx,
                                   packageName: in String,
                                   rec: in RecordDecl): Unit {
  val className  = packageName + "." + rec.name
  val typeRefRow = lookupRestoredTypeRefRow(cctx, packageName, rec.name)
  if typeRefRow == 0 { return }

  var fi = 0
  while fi < rec.members.count {
    match rec.members[fi] {
      case RMField(f) -> {
        val key = className + "/" + f.name
        if not cctx.fieldTokens.containsKey(key) {
          val fty    = typeExprToMsilCtx(cctx, f.ty, packageName)
          val fSig   = buildFieldSig(fty)
          val sigKey = "restored_field_" + key
          val memberRow = ctxAddMemberRef(cctx.lctx, typeRefRow, f.name, sigKey, fSig)
          cctx.fieldTokens.add(key, 0x0A000000 + memberRow)
          cctx.fieldMsilTypes.add(key, fty)
        }
      }
      case _ -> ()
    }
    fi = fi + 1
  }
}

// Register a free function's MemberRef on the restored package's
// host class (TypeDef matching the package name).  Signature uses
// the static method calling convention (no HASTHIS); returns the
// function's declared return type or MVoid when absent.  Skipped
// if `funcTokens` already has the FQN (in-bundle wins).
func registerRestoredFunc(cctx: in CodegenCtx,
                          packageName: in String,
                          fn: in FunctionDecl): Unit {
  // Only `pub` functions surface in the foreign DLL with a public
  // method; `internal` functions are emitted with internal accessibility
  // and a cross-assembly MemberRef pointing at them would fail to
  // resolve at runtime.
  val isPub = match fn.visibility {
    case Some(VisPub(_)) -> true
    case _               -> false
  }
  if not isPub { return }

  val fqn = packageName + "." + fn.name
  if cctx.funcTokens.containsKey(fqn) { return }

  val asmRefRow  = ensureAssemblyRefForArtifact(cctx, packageName)
  val hostRefRow = ensureHostClassTypeRefRow(cctx, packageName, asmRefRow)

  val paramTypes: List[MsilType] = newList()
  var pi = 0
  while pi < fn.params.count {
    paramTypes.add(typeExprToMsilCtx(cctx, fn.params[pi].ty, packageName))
    pi = pi + 1
  }
  val retType = match fn.ret {
    case Some(te) -> typeExprToMsilCtx(cctx, te, packageName)
    case None     -> MVoid
  }

  val funcSig   = buildStaticMethodSig(byrefWrapSigTypes(fn.params, paramTypes), retType)
  val sigKey    = "restored_func_" + fqn
  val memberRow = ctxAddMemberRef(cctx.lctx, hostRefRow, fn.name,
                                   sigKey, funcSig)
  cctx.funcTokens.add(fqn, 0x0A000000 + memberRow)
  // Record the return type so SExpr call sites don't emit a spurious
  // `pop` after void cross-assembly calls → InvalidProgramException.
  cctx.funcRetTypes.add(fqn, retType)
  cctx.funcParamModes.add(fqn, paramModesOf(fn.params))
}

// Allocate a TypeRef row for a union's case class (named
// `<UnionName>$<CaseName>`).  Cached in `ffiTypeRefs` under the
// case-class FQN so multiple `registerRestoredUnionCase` calls
// against the same case share one TypeRef row.
func ensureCaseClassTypeRefRow(cctx: in CodegenCtx,
                               packageName: in String,
                               caseClassName: in String,
                               asmRefRow: in Int): Int {
  // Cache key is the case-class FQN; sibling lookups
  // (`lookupRestoredTypeRefRow`) use the same `<pkg>/<fqn>` shape so
  // `<pkg>` deliberately appears twice (#1294).
  val caseFqn    = packageName + "." + caseClassName
  val typeRefKey = packageName + "/" + caseFqn
  match mapGet(cctx.ffiTypeRefs, typeRefKey) {
    case Some(row) -> return row
    case None      -> ()
  }
  val row = ctxAddTypeRef(cctx.lctx, packageName, caseClassName, asmRefRow)
  cctx.ffiTypeRefs.add(typeRefKey, row)
  row
}

// Extract a UnionField's type expression.  Both UFNamed and UFPos
// carry a TypeExpr; this helper unifies the access.
func unionFieldType(uf: in UnionField): TypeExpr {
  match uf {
    case UFNamed(_, ty, _) -> ty
    case UFPos(ty, _)      -> ty
  }
}

// Register one union case's ctor MemberRef and field MemberRef rows.
// The case class is named `<UnionName>$<CaseName>` and its ctor signature
// follows the same HASTHIS convention as record ctors — one param per field.
// Field MemberRefs are registered under both the declared field name
// (`<caseFqn>/<name>`) and the positional key (`<caseFqn>/field<i>`) so that
// pattern bindings using alias names (e.g. `case IFunc(fn)` where the field
// is declared as `decl`) resolve via the positional fallback.  Skipped if
// the case-class FQN is already registered.
func registerRestoredUnionCase(cctx: in CodegenCtx,
                               packageName: in String,
                               unionName: in String,
                               c: in UnionCase,
                               asmRefRow: in Int): Unit {
  val caseClassName = unionName + "$" + c.name
  val caseFqn       = packageName + "." + caseClassName
  if cctx.recordCtorTokens.containsKey(caseFqn) { return }

  val typeRefRow = ensureCaseClassTypeRefRow(cctx, packageName, caseClassName, asmRefRow)

  val ctorParams: List[MsilType] = newList()
  var fi = 0
  while fi < c.fields.count {
    val uf    = c.fields[fi]
    val fty   = typeExprToMsilCtx(cctx, unionFieldType(uf), packageName)
    ctorParams.add(fty)
    // Register field MemberRef rows under both the declared name and the
    // positional alias so pattern-match binding alias resolution finds them.
    // For UFNamed the actual DLL field name is the declared name; UFPos uses
    // "field<i>".  The positional alias entry points to the SAME MemberRef
    // row so `ldfld` resolves correctly against the real field name.
    val fSig = buildFieldSig(fty)
    match uf {
      case UFNamed(fname, _, _) -> {
        val nameKey = caseFqn + "/" + fname
        if not cctx.fieldTokens.containsKey(nameKey) {
          val nameSigKey   = "restored_ucfield_" + nameKey
          val nameFieldRow = ctxAddMemberRef(cctx.lctx, typeRefRow,
                                              fname, nameSigKey, fSig)
          val tok = 0x0A000000 + nameFieldRow
          cctx.fieldTokens.add(nameKey, tok)
          cctx.fieldMsilTypes.add(nameKey, fty)
          // Also register the positional alias pointing to the same MemberRef.
          val posKey = caseFqn + "/field" + toString(fi)
          if not cctx.fieldTokens.containsKey(posKey) {
            cctx.fieldTokens.add(posKey, tok)
            cctx.fieldMsilTypes.add(posKey, fty)
          }
        }
      }
      case UFPos(_, _) -> {
        // Positional-only case: the DLL field is named "field<i>".
        val posKey = caseFqn + "/field" + toString(fi)
        if not cctx.fieldTokens.containsKey(posKey) {
          val posSigKey   = "restored_ucfield_" + posKey
          val posFieldRow = ctxAddMemberRef(cctx.lctx, typeRefRow,
                                            "field" + toString(fi), posSigKey, fSig)
          cctx.fieldTokens.add(posKey, 0x0A000000 + posFieldRow)
          cctx.fieldMsilTypes.add(posKey, fty)
        }
      }
    }
    fi = fi + 1
  }

  val ctorSig   = buildInstanceMethodSig(ctorParams, MVoid)
  val sigKey    = "restored_ucase_" + caseFqn
  val memberRow = ctxAddMemberRef(cctx.lctx, typeRefRow, ".ctor",
                                   sigKey, ctorSig)
  cctx.recordCtorTokens.add(caseFqn, 0x0A000000 + memberRow)
}

// Walk every case of a union and register its case-class ctor.
func registerRestoredUnion(cctx: in CodegenCtx,
                           packageName: in String,
                           decl: in UnionDecl,
                           asmRefRow: in Int): Unit {
  var ci = 0
  while ci < decl.cases.count {
    registerRestoredUnionCase(cctx, packageName, decl.name,
                              decl.cases[ci], asmRefRow)
    ci = ci + 1
  }
}

// Walk the artifact's parsed source and seed MemberRef tokens for
// every record ctor, every public free function, and every union
// case's ctor.  Skips items whose TypeRef wasn't allocated and
// private funcs (no public surface).
func registerRestoredMembers(cctx: in CodegenCtx,
                              art:  in SynthesisedArtifact): Unit {
  val items = art.source.items
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IRecord(decl) -> {
        registerRestoredRecordCtor(cctx, art.packageName, decl)
        registerRestoredRecordFields(cctx, art.packageName, decl)
      }
      case IFunc(decl) -> {
        registerRestoredFunc(cctx, art.packageName, decl)
      }
      case IUnion(decl) -> {
        // Compute asmRefRow only when actually needed — the record /
        // func helpers re-resolve their own AssemblyRef internally, so
        // hoisting it eagerly was inconsistent (#1295).
        val asmRefRow = ensureAssemblyRefForArtifact(cctx, art.packageName)
        registerRestoredUnion(cctx, art.packageName, decl, asmRefRow)
      }
      case IInterface(decl) -> {
        registerRestoredInterface(cctx, art.packageName, decl)
      }
      case _ -> ()
    }
    i = i + 1
  }
  // Second pass: impl blocks.  A consumer that calls a method on a value typed
  // as the *concrete record* (e.g. `Session.inMemory(): InProcessSessionStore`
  // then `store.set(...)`) dispatches on `<pkg>.<Record>/<method>`, which the
  // record's own type surface does not carry.  The restored `impl I for R {}`
  // decl (head-only) tells us R implements I; we register each of I's methods
  // under the record key too, reusing the interface's signatures.  Runs after
  // the first pass so the matching `IInterface` is already in `methodTokens`
  // (#1602).
  var ii = 0
  while ii < items.count {
    match items[ii].kind {
      case IImpl(idecl) -> registerRestoredImpl(cctx, art, idecl)
      case _            -> ()
    }
    ii = ii + 1
  }
}

// Register a restored record's instance methods from an `impl I for R {}`
// binding.  The restored impl is head-only (empty body), so the method
// signatures come from the implemented interface `I` (looked up among the same
// artifact's items).  Each of I's methods is registered under the RECORD key
// `<pkg>.<Record>/<method>` — the receiver type the consumer sees when it
// calls a method on a value of the concrete record type — pointing at a
// MemberRef parented on the record's own TypeRef (the CLR resolves the
// interface-implementing method through the record's slot at run time) (#1602).
func registerRestoredImpl(cctx: in CodegenCtx,
                          art:  in SynthesisedArtifact,
                          idecl: in ImplDecl): Unit {
  val targetName = implTargetNameMsil(idecl, art.packageName)
  // implTargetNameMsil returns "<pkg>.<Name>" or a "__impl_target" sentinel.
  if endsWith(targetName, ".__impl_target") { return }
  val recordTypeRefRow = lookupRestoredTypeRefRowByFqn(cctx, art.packageName, targetName)
  if recordTypeRefRow == 0 { return }

  // The interface name the impl satisfies (last segment of the constraint head).
  val ifaceSimple = lastSegmentMsil(idecl.iface.head)
  // Find the implemented interface among the artifact's items to recover its
  // method signatures.
  val items = art.source.items
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IInterface(ix) -> {
        if ix.name == ifaceSimple {
          var mi = 0
          while mi < ix.members.count {
            match ix.members[mi] {
              case IMSig(sig) -> registerRestoredRecordMethod(cctx, targetName,
                                   recordTypeRefRow, art.packageName,
                                   sig.name, sig.params, sig.ret)
              case IMFunc(fn) -> registerRestoredRecordMethod(cctx, targetName,
                                   recordTypeRefRow, art.packageName,
                                   fn.name, fn.params, fn.ret)
              case IMAssoc(_) -> ()
            }
            mi = mi + 1
          }
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
}

// Allocate the MemberRef for one restored record instance method (the concrete
// implementation of an interface method) and record its token + return type.
// Mirrors `registerRestoredIfaceMethod` but parents the MemberRef on the
// record's TypeRef.  The signature uses the producer's erasing resolver
// (`typeExprToMsil`) so the blob byte-matches the record's MethodDef; the
// fully-resolved return type is recorded for the call site's `match` (#1602).
func registerRestoredRecordMethod(cctx: in CodegenCtx,
                                  recordFqn: in String,
                                  recordTypeRefRow: in Int,
                                  packageName: in String,
                                  methodName: in String,
                                  params: in List[Param],
                                  ret: in Option[TypeExpr]): Unit {
  val key = recordFqn + "/" + methodName
  if cctx.methodTokens.containsKey(key) { return }

  val sigParamTypes: List[MsilType] = newList()
  var spi = 0
  while spi < params.count {
    sigParamTypes.add(typeExprToMsil(params[spi].ty, packageName))
    spi = spi + 1
  }
  val sigRetType = match ret {
    case Some(te) -> typeExprToMsil(te, packageName)
    case None     -> MVoid
  }
  val sig       = buildInstanceMethodSig(sigParamTypes, sigRetType)
  val sigKey    = "restored_recmethod_" + key
  val memberRow = ctxAddMemberRef(cctx.lctx, recordTypeRefRow, methodName, sigKey, sig)
  cctx.methodTokens.add(key, 0x0A000000 + memberRow)
  if not cctx.methodRetTypes.containsKey(key) {
    val realRetType = match ret {
      case Some(te) -> typeExprToMsilCtx(cctx, te, packageName)
      case None     -> MVoid
    }
    cctx.methodRetTypes.add(key, realRetType)
  }
}

// Look up a restored type's TypeRef row by its fully-qualified `<pkg>.<Name>`
// form (the shape `implTargetNameMsil` produces).  Returns 0 when absent.
func lookupRestoredTypeRefRowByFqn(cctx: in CodegenCtx, packageName: in String,
                                   fqn: in String): Int {
  val typeRefKey = packageName + "/" + fqn
  match mapGet(cctx.ffiTypeRefs, typeRefKey) {
    case Some(row) -> row
    case None      -> 0
  }
}

// Register cross-assembly MemberRef tokens + return types for a restored
// interface's methods.  A consumer that holds a value typed as the interface
// (e.g. `inMemory(): Store`) dispatches `store.set(...)` via `callvirt` against
// the interface method slot in the foreign DLL; without a registered token the
// call fell through to the BCL-name stub returning `MObject`, so a `match` on
// the result saw `scr=O` and panicked "match not exhaustive" (#1602).
//
// The interface's full method signatures are carried in the contract repr and
// re-parsed into `art.source`, so they are available here.  Each method is
// keyed `<pkg>.<Iface>/<method>` in `methodTokens` — the same shape
// `lowerMethodCallMsil` looks up for an `MClass(interfaceFqn)` receiver — with
// the declared return type recorded in `methodRetTypes` so the call reports the
// real `Result[…]` / union type to its caller.
func registerRestoredInterface(cctx: in CodegenCtx,
                               packageName: in String,
                               decl: in InterfaceDecl): Unit {
  val ifaceFqn  = packageName + "." + decl.name
  val typeRefRow = lookupRestoredTypeRefRow(cctx, packageName, decl.name)
  if typeRefRow == 0 { return }
  var mi = 0
  while mi < decl.members.count {
    match decl.members[mi] {
      case IMSig(sig)  -> registerRestoredIfaceMethod(cctx, ifaceFqn, typeRefRow,
                                                       packageName, sig.name, sig.params, sig.ret)
      case IMFunc(fn)  -> registerRestoredIfaceMethod(cctx, ifaceFqn, typeRefRow,
                                                       packageName, fn.name, fn.params, fn.ret)
      case IMAssoc(_)  -> ()
    }
    mi = mi + 1
  }
}

// Allocate the MemberRef for one restored interface method and record its
// token + return type.  The signature is HASTHIS (instance dispatch); the
// receiver is the implicit `this`, so only the declared params are encoded.
func registerRestoredIfaceMethod(cctx: in CodegenCtx,
                                 ifaceFqn: in String,
                                 typeRefRow: in Int,
                                 packageName: in String,
                                 methodName: in String,
                                 params: in List[Param],
                                 ret: in Option[TypeExpr]): Unit {
  val key = ifaceFqn + "/" + methodName
  if cctx.methodTokens.containsKey(key) { return }

  // The MemberRef signature blob must byte-match the producer DLL's interface
  // MethodDef signature, or the CLR rejects the `callvirt` with
  // `MissingMethodException`.  The producer (`codegenMPackage` -> MInterface)
  // builds that signature with the *legacy* `typeExprToMsil`, which erases
  // every generic / class / slice type to `object` (it has no codegen context
  // to allocate TypeRefs).  Use the same erasing resolver here so the two
  // signatures agree (#1602).
  val sigParamTypes: List[MsilType] = newList()
  var spi = 0
  while spi < params.count {
    sigParamTypes.add(typeExprToMsil(params[spi].ty, packageName))
    spi = spi + 1
  }
  val sigRetType = match ret {
    case Some(te) -> typeExprToMsil(te, packageName)
    case None     -> MVoid
  }
  val sig       = buildInstanceMethodSig(sigParamTypes, sigRetType)
  val sigKey    = "restored_iface_" + key
  val memberRow = ctxAddMemberRef(cctx.lctx, typeRefRow, methodName, sigKey, sig)
  cctx.methodTokens.add(key, 0x0A000000 + memberRow)
  // Record the FULLY-RESOLVED return type (ctx-aware, so `Result[T, E]` keeps
  // its `MGenericInst` identity) for the call site.  This is what the
  // consumer's `match` on the call result needs to emit correct isinst tests —
  // distinct from the erased `object` used in the signature blob above.
  if not cctx.methodRetTypes.containsKey(key) {
    val realRetType = match ret {
      case Some(te) -> typeExprToMsilCtx(cctx, te, packageName)
      case None     -> MVoid
    }
    cctx.methodRetTypes.add(key, realRetType)
  }
}

/// Walk every `SynthesisedArtifact` in `cctx.restoredArtifacts` and
/// register its type-shaped public decls into the cross-package
/// symbol tables.  Call once after `newCodegenCtx`, before the
/// per-package `addPackageTokens` pre-scan.
pub func registerRestoredArtifactTokens(cctx: in CodegenCtx): Unit {
  var ai = 0
  while ai < cctx.restoredArtifacts.count {
    val art = cctx.restoredArtifacts[ai]
    // Standard-library packages (`Std.*`) are authoritatively registered by
    // `registerStdlibArtifactTokens` from the full `lyric-stdlib/std/*.l`
    // sources, which every project build loads unconditionally
    // (`emitProjectInProcess` -> `findStdlibSources`).  When `Lyric.Stdlib`
    // is also a declared `[dependencies]` entry — as it is in every project
    // — its bundle DLL arrives here as a restored artifact too.  Registering
    // it from the contract-repr round-trip would emit cross-assembly refs
    // using the self-hosted IN-BUNDLE conventions (`Option$None`, raw
    // `Std.Core` assembly name) which do not match the actually-deployed
    // stdlib (`Option_None` in assembly `Lyric.Stdlib.Core`), so the consumer
    // PE faults at run time with `Could not load file or assembly 'Std.Core'`
    // / `Could not load type 'Std.Core.Option$None'`.  Skip it here and let
    // the single, source-backed stdlib path own these symbols (#1602).
    //
    // The `Std.*` prefix is reserved for the standard library (the type
    // checker rejects user packages declaring it); see Q-name-001 for the
    // formal reservation note.
    if startsWith(art.packageName, "Std.") {
      ai = ai + 1
      continue
    }
    val asmRefRow = ensureAssemblyRefForArtifact(cctx, art.packageName)
    // Pass 1: types (TypeRef rows + name lookups).
    var di = 0
    while di < art.contract.decls.count {
      val decl = art.contract.decls[di]
      val k = decl.kind
      if k == "record" or k == "union" or k == "enum"
         or k == "interface" or k == "opaque" or k == "distinct" {
        registerRestoredTypeDecl(cctx, art.packageName, decl, asmRefRow)
      }
      di = di + 1
    }
    // Pass 2: record ctor MemberRef rows (depends on pass 1 having
    // allocated the TypeRefs).  Walks the parsed source instead of
    // the contract decls so we get structured field types for
    // signature encoding.  Free funcs and union case ctors land in
    // a follow-up slice.
    registerRestoredMembers(cctx, art)
    ai = ai + 1
  }
}

/// Per-package stdlib payload consumed by
/// `registerStdlibArtifactTokens`.  Holds the dotted package name
/// (`Std.Encoding`, `Std.CollectionsHost`, …) alongside the items
/// the bridge collected from the matching stdlib source.  Defined
/// here (rather than in `Msil.Bridge`) so the codegen registration
/// function can name the record type without `Msil.Codegen` having
/// to import `Msil.Bridge` and form a circular dependency.
pub record StdlibPkg {
  name:  String
  items: List[Item]
}

/// Walk every `StdlibPkg` and register its `pub func`s as
/// cross-assembly `MemberRef` rows in `cctx.funcTokens`, keyed by
/// the function's fully-qualified name (`<pkgName>.<fnName>`).  Call
/// once after `newCodegenCtx`, before the per-package
/// `addPackageTokens` pre-scan (#1378 codegen-side closure).
///
/// AssemblyRef naming convention matches the F# emitter
/// (`Lyric.Stdlib.<X>` for `Std.X`, `Lyric.<head>.<rest>` for non-
/// `Std` builtins).  Each stdlib package's `pub func`s live on a
/// host class `<pkgName>.Program` in the corresponding DLL — the
/// same shape `addPackageTokens` produces for user packages.
///
/// Empty `pkgs` is a no-op — single-package compiles with no stdlib
/// imports still work because their callsite codegen never reaches
/// the `funcTokens` lookup (handled by the hardcoded builtin arms in
/// `lowerBuiltinOrStaticCallMsil`).
pub func registerStdlibArtifactTokens(
  cctx: in CodegenCtx,
  pkgs: in List[StdlibPkg]
): Unit {
  // Pass 1: register all type items across every package first.  This
  // populates `typeFqnByName` and `ffiTypeRefs` before any function
  // signature is resolved, so cross-package generic return types (e.g.
  // `Option[Int]` in `Std.String.indexOf`) resolve to the correct
  // `MGenericInst` regardless of package order in `pkgs`.
  var pi = 0
  while pi < pkgs.count {
    val pkg: StdlibPkg = pkgs[pi]
    val asmRefRow = ensureStdlibAssemblyRef(cctx, pkg.name)
    var ii = 0
    while ii < pkg.items.count {
      val it: Item = pkg.items[ii]
      match it.kind {
        case IFunc(_) -> {}
        case _        -> registerStdlibTypeItem(cctx, pkg.name, it, asmRefRow)
      }
      ii = ii + 1
    }
    pi = pi + 1
  }
  // Pass 2: register all function items now that type resolution is complete.
  var pi2 = 0
  while pi2 < pkgs.count {
    val pkg: StdlibPkg = pkgs[pi2]
    val asmRefRow  = ensureStdlibAssemblyRef(cctx, pkg.name)
    val hostRefRow = ensureHostClassTypeRefRow(cctx, pkg.name, asmRefRow)
    var ii = 0
    while ii < pkg.items.count {
      val it: Item = pkg.items[ii]
      match it.kind {
        case IFunc(decl) -> registerStdlibFunc(cctx, pkg.name, hostRefRow, decl)
        case _           -> {}
      }
      ii = ii + 1
    }
    pi2 = pi2 + 1
  }
}

// Build a TypeSpec-based newobj token for a stdlib generic union case
// constructor. Required by ECMA-335 §III.4.21: "if typeTok is a generic
// class, the token shall be a TypeSpec token."
//
// `ctorKey`       — FQN case key (e.g. "Std.Core.Option_Some")
// `argTypes`      — MSIL types of the constructor arguments (empty for nullary)
// `contextTyArgs` — type args extracted from the surrounding context
//                   (e.g. from fctx.declaredRetTy); used to fill generic slots
//                   that cannot be inferred from argTypes alone (e.g. T in None)
//
// Emit a deferred generic case constructor newobj for a stdlib generic union
// case (e.g. `None` for `Option[Keyword]`).  The TypeSpec and TypeSpec-parented
// MemberRef are deferred to Phase 5 via `MNewobjGenericCase` so that in-bundle
// type arguments (e.g. `Lyric.Lexer.Keyword`) are in the TypeDef table when
// the GENERICINST blob is constructed.  Building the blob at Phase 3 (codegen)
// would degrade `MClass("Lyric.Lexer.Keyword")` to ELEMENT_TYPE_OBJECT because
// `lowerMUnion` (which adds the TypeDef) has not yet run — the resulting
// `Option_None<object>` newobj vs `Option_None<Keyword>` isinst mismatch causes
// the "match not exhaustive" panic (#1442).
//
// Returns 1 (success) after emitting `MNewobjGenericCase` to `insns`, or 0
// when `ctorKey` is not a known generic stdlib case.  The parent union type is
// written to `outParentTy` (populated on success, left empty otherwise) so
// callers can set the stack type correctly.
func buildGenericCaseCtorTok(cctx: in CodegenCtx, ctorKey: in String,
                              argTypes: in List[MsilType],
                              contextTyArgs: in List[MsilType],
                              outParentTy: in List[MsilType],
                              insns: in List[MInsn]): Int {
  val nTypeParams = match mapGet(cctx.caseTypeParamCount, ctorKey) {
    case Some(n) -> n
    case None    -> return 0
  }
  // Locate case-class TypeRef row.
  val dotIdx0 = ctorKey.lastIndexOf(".")
  if dotIdx0 < 0 { return 0 }
  val pkgPart = ctorKey.substring(0, dotIdx0)
  val caseRefKey = pkgPart + "/" + ctorKey
  val caseRefRow = match mapGet(cctx.ffiTypeRefs, caseRefKey) {
    case Some(r) -> r
    case None    -> return 0
  }
  // Build concrete type args: for each type-param slot, look through the
  // constructor fields to find one whose varIdx equals the param slot.
  // If no field covers the slot, fall back to the context type arg (if any),
  // then to MObject.
  val typeArgs: List[MsilType] = newList()
  var tpi = 0
  while tpi < nTypeParams {
    var foundTy: MsilType = MObject
    var fi = 0
    while fi < argTypes.count {
      val fldKey = ctorKey + "/field" + toString(fi)
      val vi = match mapGet(cctx.fieldVarIndices, fldKey) {
        case Some(v) -> v
        case None    -> -1
      }
      if vi == tpi { foundTy = argTypes[fi] }
      fi = fi + 1
    }
    if foundTy == MObject and tpi < contextTyArgs.count {
      val ctxTy = contextTyArgs[tpi]
      if ctxTy != MObject { foundTy = ctxTy }
    }
    typeArgs.add(foundTy)
    tpi = tpi + 1
  }
  // Build ctor parameter types: for each field, use MTypeVar(varIdx) if the
  // field's type is a generic parameter, otherwise MObject.
  val ctorPs: List[MsilType] = newList()
  var fi2 = 0
  while fi2 < argTypes.count {
    val fldKey2 = ctorKey + "/field" + toString(fi2)
    val vi2 = match mapGet(cctx.fieldVarIndices, fldKey2) {
      case Some(v) -> v
      case None    -> -1
    }
    val paramTy: MsilType = if vi2 >= 0 { MTypeVar(index = vi2) } else { MObject }
    ctorPs.add(paramTy)
    fi2 = fi2 + 1
  }
  // Emit the deferred newobj instruction.  TypeSpec and MemberRef construction
  // is deferred to Phase 5 so TypeDefs for in-bundle type arguments are present.
  insns.add(MNewobjGenericCase(typeRefRow = caseRefRow, typeArgs = typeArgs, ctorParams = ctorPs))
  // Derive parent union type for outParentTy.
  // ctorKey = "Pkg.UnionName_CaseName"; strip "_CaseName" to get "Pkg.UnionName".
  val caseLocal = ctorKey.substring(dotIdx0 + 1, ctorKey.length - dotIdx0 - 1)
  val undIdx = caseLocal.lastIndexOf("_")
  if undIdx > 0 {
    val unionLocal = caseLocal.substring(0, undIdx)
    val parentFqn  = pkgPart + "." + unionLocal
    val parentKey  = pkgPart + "/" + parentFqn
    match mapGet(cctx.ffiTypeRefs, parentKey) {
      case Some(parentRow) ->
        outParentTy.add(MGenericInst(typeRefCode = tdrTypeRef(parentRow),
                                     headFqn = parentFqn,
                                     typeArgs = typeArgs))
      case None -> outParentTy.add(MClass(className = parentFqn))
    }
  }
  1
}

// Register a type-shaped item from a stdlib package into `ffiTypeRefs`
// and `typeFqnByName` so that generic return types in stdlib function
// signatures (e.g. `Option[Int]` for `Std.String.indexOf`) resolve to
// a valid TypeRef coded index when building the MemberRef signature blob.
// For union types, also registers TypeRef rows for each case class
// (`Option$Some`, `Option$None`) so that `MIsinstByName` resolves to
// a TypeRef token rather than falling back to System.Object.
// Mirrors the `registerRestoredTypeDecl` + `registerRestoredUnionCase` logic.
func registerStdlibTypeItem(cctx: in CodegenCtx, packageName: in String,
                             it: in Item, asmRefRow: in Int): Unit {
  // Extern types declared in the stdlib `_kernel/` boundary (e.g.
  // `extern type Uuid = "System.Guid"`) carry the Lyric-name → CLR-FQN
  // mapping a consumer needs to encode the type correctly in cross-package
  // signatures.  Stdlib registration goes through this path (not the
  // in-bundle `addPackageTokens` → `scanExternTypesMsil`), so record the
  // mapping here too — otherwise a value-typed extern returned by a stdlib
  // `pub func` (Std.Uuid.newUuid: Uuid) degrades to `object` and mis-binds
  // at run time (#1602).
  match it.kind {
    case IExternType(decl) -> {
      if not cctx.externTypeNames.containsKey(decl.name) {
        cctx.externTypeNames.add(decl.name, decl.clrName)
      }
      return
    }
    case _ -> {}
  }
  val typeName = match it.kind {
    case IRecord(decl)       -> decl.name
    case IExposedRec(decl)   -> decl.name
    case IUnion(decl)        -> decl.name
    case IEnum(decl)         -> decl.name
    case IInterface(decl)    -> decl.name
    case IOpaque(decl)       -> decl.name
    case IDistinctType(decl) -> decl.name
    case _                   -> return
  }
  val typeFqn    = packageName + "." + typeName
  val typeRefKey = packageName + "/" + typeFqn
  if not cctx.ffiTypeRefs.containsKey(typeRefKey) {
    val row = ctxAddTypeRef(cctx.lctx, packageName, typeName, asmRefRow)
    cctx.ffiTypeRefs.add(typeRefKey, row)
  }
  if not cctx.typeFqnByName.containsKey(typeName) {
    cctx.typeFqnByName.add(typeName, typeFqn)
  }
  match it.kind {
    case IUnion(decl) -> {
      // Stdlib types compiled by the F# bootstrap emitter use `_` as the
      // separator between union name and case name (e.g. `Option_Some`,
      // `Result_Ok`).  Build a type-param name → VAR index map so that
      // fields whose type is a generic parameter (e.g. `value: T` on
      // `Option_Some<T>`) get the correct FIELD+VAR(n) signature blob
      // rather than the incorrect FIELD+Object blob.
      val typeParamVarIdx: Map[String, Int] = newMap()
      val unionTypeParamCount = match decl.generics {
        case Some(gps) -> {
          var gi = 0
          while gi < gps.params.count {
            match gps.params[gi] {
              case GPType(tpName, _) -> typeParamVarIdx.add(tpName, gi)
              case _                 -> {}
            }
            gi = gi + 1
          }
          gps.params.count
        }
        case None -> 0
      }
      var ci = 0
      while ci < decl.cases.count {
        val caseName      = decl.cases[ci].name
        val ctorKey       = packageName + "." + decl.name + "_" + caseName
        val caseClassName = decl.name + "_" + caseName
        val caseRefKey    = packageName + "/" + ctorKey
        // Register case-class TypeRef so MIsinstByName can find it via
        // findTypeRefRowByName instead of falling back to System.Object.
        if not cctx.ffiTypeRefs.containsKey(caseRefKey) {
          val caseRow = ctxAddTypeRef(cctx.lctx, packageName, caseClassName, asmRefRow)
          cctx.ffiTypeRefs.add(caseRefKey, caseRow)
        }
        val caseRow = match mapGet(cctx.ffiTypeRefs, caseRefKey) {
          case Some(r) -> r
          case None    -> 0
        }
        // Register field MemberRefs so `ldfld` can read fields of cross-assembly
        // union case instances.  Registered both by declared name ("value") and by
        // positional index ("field0") so that binding patterns like `case Some(x)`
        // resolve via the positional fallback.
        if caseRow > 0 {
          var fi = 0
          while fi < decl.cases[ci].fields.count {
            val field = decl.cases[ci].fields[fi]
            val declaredName = match field {
              case UFNamed(name, _, _) -> name
              case UFPos(_, _)         -> "field" + toString(fi)
            }
            // For generic-parameter fields (e.g. `value: T`), emit VAR(n) in the
            // field sig to match the F# bootstrap emitter's output.  For concrete
            // types, fall back to Object.  Also track the VAR index (-1 for
            // non-generic fields) in fieldVarIdx so lowerPatternBindMsil can
            // recover the concrete bound-variable type without byte-level access.
            var fieldVarIdx = -1
            val fieldSig = match field {
              case UFNamed(_, ty, _) -> {
                val seg = match ty.kind {
                  case TRef(path) ->
                    if path.segments.count == 1 { path.segments[0] } else { "" }
                  case _ -> ""
                }
                if seg.length > 0 {
                  match mapGet(typeParamVarIdx, seg) {
                    case Some(varIdx) -> {
                      fieldVarIdx = varIdx
                      buildGenericParamFieldSig(varIdx)
                    }
                    case None         -> buildFieldSig(MObject)
                  }
                } else {
                  buildFieldSig(MObject)
                }
              }
              case UFPos(ty, _) -> {
                val seg = match ty.kind {
                  case TRef(path) ->
                    if path.segments.count == 1 { path.segments[0] } else { "" }
                  case _ -> ""
                }
                if seg.length > 0 {
                  match mapGet(typeParamVarIdx, seg) {
                    case Some(varIdx) -> {
                      fieldVarIdx = varIdx
                      buildGenericParamFieldSig(varIdx)
                    }
                    case None         -> buildFieldSig(MObject)
                  }
                } else {
                  buildFieldSig(MObject)
                }
              }
            }
            val sigKey     = "stdlib_field_" + ctorKey + "_" + declaredName
            val fieldMrRow = ctxAddMemberRef(cctx.lctx, caseRow, declaredName,
                                              sigKey, fieldSig)
            val fieldTok   = 0x0A000000 + fieldMrRow
            val byNameKey = ctorKey + "/" + declaredName
            if not cctx.fieldTokens.containsKey(byNameKey) {
              cctx.fieldTokens.add(byNameKey, fieldTok)
            }
            if not cctx.fieldSigBytes.containsKey(byNameKey) {
              cctx.fieldSigBytes.add(byNameKey, fieldSig)
            }
            if not cctx.fieldVarIndices.containsKey(byNameKey) {
              cctx.fieldVarIndices.add(byNameKey, fieldVarIdx)
            }
            val byPosKey = ctorKey + "/field" + toString(fi)
            if not cctx.fieldTokens.containsKey(byPosKey) {
              cctx.fieldTokens.add(byPosKey, fieldTok)
            }
            if not cctx.fieldSigBytes.containsKey(byPosKey) {
              cctx.fieldSigBytes.add(byPosKey, fieldSig)
            }
            if not cctx.fieldVarIndices.containsKey(byPosKey) {
              cctx.fieldVarIndices.add(byPosKey, fieldVarIdx)
            }
            if not cctx.fieldDeclaredNames.containsKey(byPosKey) {
              cctx.fieldDeclaredNames.add(byPosKey, declaredName)
            }
            fi = fi + 1
          }
          // Register constructor MemberRef so `Some(value = x)`, `Ok(value = x)`, etc.
          // emit a `newobj` instruction.  Generic-parameter fields use MTypeVar(n) to
          // match the F# bootstrap emitter's generic ctor sig; concrete fields use MObject.
          val ctorParams2: List[MsilType] = newList()
          var cpi = 0
          while cpi < decl.cases[ci].fields.count {
            val cpField = decl.cases[ci].fields[cpi]
            val cpTy = match cpField {
              case UFNamed(_, ty, _) -> ty
              case UFPos(ty, _)      -> ty
            }
            val cpSeg = match cpTy.kind {
              case TRef(path) ->
                if path.segments.count == 1 { path.segments[0] } else { "" }
              case _ -> ""
            }
            val cpMsilTy: MsilType = if cpSeg.length > 0 {
              match mapGet(typeParamVarIdx, cpSeg) {
                case Some(varIdx) -> MTypeVar(index = varIdx)
                case None         -> MObject
              }
            } else {
              MObject
            }
            ctorParams2.add(cpMsilTy)
            cpi = cpi + 1
          }
          val ctorSig2   = buildInstanceMethodSig(ctorParams2, MVoid)
          val ctorSigKey = "stdlib_case_ctor_" + ctorKey
          val ctorMrRow  = ctxAddMemberRef(cctx.lctx, caseRow, ".ctor", ctorSigKey, ctorSig2)
          if not cctx.recordCtorTokens.containsKey(ctorKey) {
            cctx.recordCtorTokens.add(ctorKey, 0x0A000000 + ctorMrRow)
          }
          // Register type-param count for TypeSpec-based newobj building at
          // construction sites (ECMA-335 §III.4.21).
          if unionTypeParamCount > 0 and not cctx.caseTypeParamCount.containsKey(ctorKey) {
            cctx.caseTypeParamCount.add(ctorKey, unionTypeParamCount)
          }
        }
        if not cctx.unionCaseCtorByName.containsKey(caseName) {
          cctx.unionCaseCtorByName.add(caseName, ctorKey)
        }
        ci = ci + 1
      }
    }
    case _ -> ()
  }
}

// Allocate (or reuse) the AssemblyRef row for the stdlib DLL that
// contains `packageName`.  Stdlib DLLs follow the F# emitter's
// per-package naming convention so the user's PE references the same
// AssemblyRef identity the F# emitter would have produced — the same
// SDK-installed (or test-harness-staged) `Lyric.Stdlib.<X>.dll`
// satisfies the binding at runtime.
//
// Cached in `cctx.ffiAsmRefs` under the original package name (not
// the synthesised assembly name) so two `Std.X` references collapse
// to one AssemblyRef row.
func ensureStdlibAssemblyRef(cctx: in CodegenCtx,
                              packageName: in String): Int {
  if cctx.ffiAsmRefs.containsKey(packageName) {
    match mapGet(cctx.ffiAsmRefs, packageName) {
      case Some(row) -> return row
      case None      -> ()
    }
  }
  val asmName = stdlibAssemblyName(packageName)
  // Stdlib assemblies ship version 0.1.0; the loader binds against
  // the matching `Lyric.Stdlib.<X>.dll` regardless of patch.
  val row = ctxAddLyricPackageAssemblyRef(cctx.lctx, asmName, 0, 1)
  cctx.ffiAsmRefs.add(packageName, row)
  row
}

// Translate a Lyric package name into the F# emitter's stdlib
// assembly-name convention so cross-emitter PE bindings line up:
//   Std.Encoding              → Lyric.Stdlib.Encoding
//   Std.Collections           → Lyric.Stdlib.Collections
//   Std.CollectionsHost       → Lyric.Stdlib.CollectionsHost
//   Std.Collections.Host      → Lyric.Stdlib.Collections.Host  (3+ seg)
//   Lyric.Lexer               → Lyric.Lyric.Lexer
//   <single-segment>          → Lyric.<segment>
//
// Mirrors `bootstrap/src/Lyric.Emitter/Emitter.fs::ensureStdlibArtifact`'s
// `assemblyName` block.  Tail segments are joined with `.` so a
// 3+-segment package keeps its segment boundaries — every current
// stdlib package is 2-segment, but `Std.A.B` and `Std.AB` must yield
// distinct DLL names (`Lyric.Stdlib.A.B` vs `Lyric.Stdlib.AB`) when
// the surface grows (review #1427).
func stdlibAssemblyName(packageName: in String): String {
  val segs = splitDottedName(packageName)
  if segs.count == 0 { return "Lyric.Unknown" }
  val head = segs[0]
  var tail = ""
  var i = 1
  while i < segs.count {
    if i > 1 { tail = tail + "." }
    tail = tail + segs[i]
    i = i + 1
  }
  if head == "Std" {
    "Lyric.Stdlib." + tail
  } else if segs.count == 1 {
    "Lyric." + head
  } else {
    "Lyric." + head + "." + tail
  }
}

// Split `"A.B.C"` into `["A", "B", "C"]`.  Used by
// `stdlibAssemblyName` to take apart dotted package names without
// pulling in `Lyric.Parser` (which would make the codegen depend on
// the parser).  Uses `String.indexOf` so the implementation stays on
// supported BCL string operations.
func splitDottedName(name: in String): List[String] {
  val segs: List[String] = newList()
  var rest = name
  var idx = rest.indexOf(".")
  while idx >= 0 {
    segs.add(rest.substring(0, idx))
    rest = rest.substring(idx + 1, rest.length - idx - 1)
    idx = rest.indexOf(".")
  }
  if rest.length > 0 { segs.add(rest) }
  segs
}

// Register one stdlib `pub func` as a cross-assembly `MemberRef`
// row in `cctx.funcTokens`.  Skipped when:
//   * `fn` is not `pub` (private stdlib functions aren't reachable
//     across the package boundary and would fail to bind at runtime)
//   * `<pkgName>.<fnName>` is already in `funcTokens` (an in-bundle
//     package, restored artifact, or earlier stdlib pass already
//     registered it — first-in-wins).
//
// Reuses `buildStaticMethodSig` + `typeExprToMsilCtx` so the
// signature blob matches the encoding the F# emitter would emit on
// the producer side.  Errors during type resolution surface as
// `MObject` slots in the signature (matching the existing
// `registerRestoredFunc` policy).
func registerStdlibFunc(
  cctx:        in CodegenCtx,
  packageName: in String,
  hostRefRow:  in Int,
  fn:          in FunctionDecl
): Unit {
  val isPub = match fn.visibility {
    case Some(VisPub(_)) -> true
    case _               -> false
  }
  if not isPub { return }
  val fqn      = packageName + "." + fn.name
  val arityKey = fqn + "/" + toString(fn.params.count)

  val paramTypes: List[MsilType] = newList()
  var pi = 0
  while pi < fn.params.count {
    paramTypes.add(typeExprToMsilCtx(cctx, fn.params[pi].ty, packageName))
    pi = pi + 1
  }
  val retType = match fn.ret {
    case Some(te) -> typeExprToMsilCtx(cctx, te, packageName)
    case None     -> MVoid
  }
  val funcSig   = buildStaticMethodSig(byrefWrapSigTypes(fn.params, paramTypes), retType)
  val fnModes   = paramModesOf(fn.params)
  // Register with an arity-specific key so overloaded stdlib functions
  // (e.g. Str.substring/2 vs Str.substring/3) each get a distinct
  // MemberRef with the correct parameter count.  The plain FQN key is
  // also registered (first overload wins) so call sites that don't need
  // overload disambiguation continue to work unchanged.  Recording the
  // return type under both keys lets call-site lowering
  // (`lowerBuiltinOrStaticCallMsil`) emit the correct stack discipline —
  // without it the call site falls back to `MObject` and pops a value a
  // void-returning function (Unit → `MVoid`, e.g. `Std.Testing.assertTrue`)
  // never left on the stack, and the JIT rejects the body with
  // InvalidProgramException.
  if not cctx.funcTokens.containsKey(arityKey) {
    val sigKey    = "stdlib_func_" + arityKey
    val memberRow = ctxAddMemberRef(cctx.lctx, hostRefRow, fn.name,
                                     sigKey, funcSig)
    val tok = 0x0A000000 + memberRow
    cctx.funcTokens.add(arityKey, tok)
    cctx.funcRetTypes.add(arityKey, retType)
    cctx.funcParamTypes.add(arityKey, paramTypes)
    cctx.funcParamModes.add(arityKey, fnModes)
    if not cctx.funcTokens.containsKey(fqn) {
      cctx.funcTokens.add(fqn, tok)
      cctx.funcRetTypes.add(fqn, retType)
      cctx.funcParamTypes.add(fqn, paramTypes)
      cctx.funcParamModes.add(fqn, fnModes)
    }
  }
}
