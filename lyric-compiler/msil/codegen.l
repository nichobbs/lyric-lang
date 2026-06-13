//! msil/codegen.l — Msil.Codegen
//!
//! Bootstrap-grade AST-to-MSIL-IR lowering for the Lyric self-hosted compiler.
//! Walks a parsed `SourceFile` (from Lyric.Parser) and produces an `MPackage`
//! (from Msil.Lowering) suitable for further lowering to PE bytes by
//! `Msil.Lowering.lowerMPackageWithCtx`.
//!
//! Supported in this bootstrap pass:
//!   • Simple functions — arithmetic, locals, if/else, while
//!   • Hello-world programs (main with println)
//!   • Record types with fields
//!   • Union types (lowered to sealed-union IR)
//!   • Basic builtin calls: println, print, panic, toString, assert, newList,
//!     newMap, mapGet, default, format1..format3, intToLong, longToInt, charToInt
//!   • Interpolated strings via String.Concat chains
//!   • Match expressions with literal and binding patterns
//!   • Constructor calls and field access
//!
//! Unsupported forms panic at codegen time so failures are visible rather than
//! silently wrong.
//!
//! MSIL vs JVM differences captured here:
//!   • MLdloc/MStloc for locals (slot 0-based within locals list).
//!   • MLdarg for parameters (slot 0-based within params list).
//!   • MRet for all return types.
//!   • MLdStr(token) where token = 0x70000000 | US heap offset.
//!   • MCeq/MClt/MCgt + XOR for comparison results.
//!   • MNewobj(ctorToken) for construction; MBox(typeToken) for boxing.
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
  lctx: LoweringCtx
  // TypeRef row indices (1-based)
  trConsole: Int  // System.Console
  trString: Int  // System.String
  trInt32: Int  // System.Int32
  trInt64: Int  // System.Int64
  trDouble: Int  // System.Double
  trBoolean: Int  // System.Boolean
  trChar: Int  // System.Char
  trByte: Int  // System.Byte
  trException: Int  // System.Exception
  // MemberRef tokens (0x0A000000 | 1-based row)
  tokWriteLineStr: Int  // Console.WriteLine(string)
  tokWriteLineInt: Int  // Console.WriteLine(int32)
  tokWriteLineLong: Int  // Console.WriteLine(int64)
  tokWriteLineDbl: Int  // Console.WriteLine(double)
  tokWriteLineBool: Int  // Console.WriteLine(bool)
  tokWriteStr: Int  // Console.Write(string)
  tokConcat2: Int  // String.Concat(string,string)
  tokConcat3: Int  // String.Concat(string,string,string)
  tokExceptionCtor: Int  // Exception..ctor(string) — one-arg ctor (callers emit ldstr+newobj+throw and rely on this arity)
  tokInvalidOpExceptionCtor: Int  // InvalidOperationException..ctor(string) — for internal invariant violations only
  tokStringFormat1: Int  // String.Format(string,object)
  tokStringFormat2: Int  // String.Format(string,object,object)
  tokStringFormat3: Int  // String.Format(string,object,object,object)
  tokObjToString: Int  // Object.ToString() instance HASTHIS
  tokExcGetMessage: Int  // Exception.get_Message(): string  instance HASTHIS
  tokObjGetType: Int  // Object.GetType(): Type  instance HASTHIS
  tokTypeGetName: Int  // Type.get_Name: string  instance HASTHIS
  // List<object> via TypeSpec (for newList() and list operations)
  tokListObjCtor: Int  // List<object>::.ctor()  newobj
  tokListObjAdd: Int  // List<object>::Add(object): void  callvirt
  tokListObjGetItem: Int  // List<object>::get_Item(int32): object  callvirt
  tokListObjSetItem: Int  // List<object>::set_Item(int32, object): void  callvirt
  tokListObjGetCount: Int  // List<object>::get_Count(): int32  callvirt
  tokListObjContains: Int  // List<object>::Contains(object): bool  callvirt
  tokListObjRemoveAt: Int  // List<object>::RemoveAt(int32): void  callvirt
  tokListObjTypeSpec: Int  // TypeSpec token for List<object>  castclass
  // Non-generic IList / ICollection: the universal read path for a
  // receiver tracked as `object` that may hold EITHER a genuine `List<object>`
  // OR a concrete `List<Foo>` extracted from a type-erased container (tuple
  // element, generic payload).  `castclass List<object>` faults on a concrete
  // list (invariant generics); `System.Collections.IList` / `ICollection` are
  // implemented by every `List<T>` and `T[]`, so the cast and member calls bind
  // regardless of element type.
  tokIListCast: Int  // castclass System.Collections.IList (TypeRef token)
  tokIListGetItem: Int  // IList.get_Item(int32): object  callvirt
  tokICollGetCount: Int  // ICollection.get_Count(): int32  callvirt
  // String intrinsic members (instance HASTHIS)
  tokStringGetChars: Int  // String.get_Chars(int32): char
  tokStringGetLength: Int  // String.get_Length(): int32
  tokStringSubstring: Int  // String.Substring(int32,int32): string
  tokStringReplace: Int  // String.Replace(string,string): string
  tokStringIsNormalized: Int  // String.IsNormalized(): bool
  tokStringNormalize: Int  // String.Normalize(): string
  tokStringTrim: Int  // String.Trim(): string
  tokStringIndexOf: Int  // String.IndexOf(string): int32  (-1 if absent)
  tokStringLastIndexOf: Int  // String.LastIndexOf(string): int32  (-1 if absent)
  tokStringStartsWith: Int  // String.StartsWith(string): bool
  tokStringEndsWith: Int  // String.EndsWith(string): bool
  tokStringContains: Int  // String.Contains(string): bool
  tokStringToLower: Int  // String.ToLowerInvariant(): string
  tokStringToUpper: Int  // String.ToUpperInvariant(): string
  // Object.Equals(object,object): bool  static (for value-equal string comparisons)
  tokObjectStaticEquals: Int
  // String.CompareOrdinal(string,string): int32  static — backs the relational
  // operators (`<` / `>` / `<=` / `>=`) on `String` operands.  Without it the
  // relational arms emit a raw `clt` / `cgt`, which compares the two string
  // *references* as integers rather than lexicographically (#2539).
  tokStringCompareOrdinal: Int
  // Async support (Phase A, Band 3).
  // Task and Task`1 TypeRef rows — used to build TypeSpec+MemberRef tokens lazily
  // in `emitExternTargetBody` for `@externTarget async func` unwrapping.
  trTask: Int  // System.Threading.Tasks.Task (non-generic)
  trTask1: Int  // System.Threading.Tasks.Task`1 (open generic)
  tokTaskWait: Int  // Task::Wait(): void  instance HASTHIS (void async externs)
  // ISO-8601 toString(DateTime) via DateTime.ToString("o") (#2184).
  // The "o" round-trip format produces "1970-01-01T00:00:00.0000000Z" for UTC
  // DateTimes, matching the F# bootstrap emitter's DateTime.ToString("o") path
  // in Codegen.fs so stage-0 and stage-1 render DateTime byte-identically.
  tokInvariantCulture: Int  // CultureInfo.get_InvariantCulture(): CultureInfo  static
  tokDateTimeToStringO: Int    // DateTime.ToString(string): string  instance HASTHIS
  usDateTimeFormatO: Int       // ldstr token (0x70000000 | US heap offset) for the "o" format specifier
  tokDoubleToStringInv: Int    // Double.ToString(IFormatProvider): string  instance HASTHIS (#2462)
  // Reverse lookup: simple field name → FieldDef token.  Populated by
  // addPackageTokens for IRecord and IExposedRec fields so EMember can emit
  // ldfld on an MObject receiver when the static type is unknown.
  fieldTokensByName: Map[String, Int]
  // Parallel to fieldTokensByName: declaring class FQN for each field, so the
  // MObject-receiver fallback path can emit MCastclassByName before ldfld (#1868).
  fieldDeclaringClassByName: Map[String, String]
  // Dictionary<object,object> via TypeSpec (for newMap() and map operations)
  tokDictObjCtor: Int  // Dictionary<object,object>::.ctor()  newobj
  tokDictObjAdd: Int  // Dictionary<object,object>::Add(object,object): void  callvirt
  tokDictObjGetItem: Int  // Dictionary<object,object>::get_Item(object): object  callvirt
  tokDictObjSetItem: Int  // Dictionary<object,object>::set_Item(object,object): void  callvirt
  tokDictObjTypeSpec: Int  // TypeSpec token for Dictionary<object,object>  castclass
  tokDictObjGetCount: Int  // Dictionary<object,object>::get_Count(): int32  callvirt
  tokDictObjContainsKey: Int  // Dictionary<object,object>::ContainsKey(object): bool  callvirt
  tokDictObjRemove: Int  // Dictionary<object,object>::Remove(object): bool  callvirt
  tokDictObjTryGetValue: Int  // Dictionary<object,object>::TryGetValue(object, object): bool
  // Intra-package pre-computed tokens
  recordCtorTokens: Map[String, Int]  // className → MethodDef token
  // Distinct/range-subtype static factory tokens (#1501): className → MethodDef
  // token for the synthesised static `from`/`tryFrom`.  Resolved at a
  // `TypeName.from(x)` / `TypeName.tryFrom(x)` call site, which is a static call
  // on a type name (not an instance method), so it cannot go through the normal
  // `methodTokens` instance-dispatch path.
  distinctFromTokens: Map[String, Int]
  distinctTryFromTokens: Map[String, Int]
  distinctTryFromRetTypes: Map[String, MsilType]
  fieldTokens: Map[String, Int]  // "ClassName/fieldName" → FieldDef token
  // Field metadata for cross-assembly generic union cases.  Both maps use the
  // same "ClassName/fieldName" and "ClassName/fieldN" key space as fieldTokens.
  // fieldSigBytes  → raw FieldSig blob (06 13 00 for VAR(0), etc.) used to
  //                  build TypeSpec-parented MemberRefs at ldfld sites.
  // fieldDeclaredNames → positional key "ClassName/fieldN" → declared field name
  //                  (e.g. "Std.Core.Option_Some/field0" → "value") so that
  //                  lowerPatternBindMsil can name the TypeSpec MemberRef
  //                  correctly when the user writes a binding alias
  //                  (`case Some(x)` instead of `case Some(value)`).
  fieldSigBytes: Map[String, List[Byte]]
  fieldDeclaredNames: Map[String, String]
  // Default value expressions for record fields with `= expr` initialisers.
  // Keyed `<className>/field<pos>` (matching fieldDeclaredNames).  Populated by
  // addPackageTokens when a FieldDecl carries a dflt.  fillCtorDefaultArgs uses
  // these to complete a partial named-arg constructor call (e.g. `R(a = 1)` when
  // field `b` has a default) so the newobj stack arity matches the .ctor signature.
  ctorDefaultExprs: Map[String, Expr]
  fieldVarIndices: Map[String, Int]
  // MSIL type for in-package record/union-case fields.  Key = "FQClassName/fieldName".
  // Populated by addPackageTokens so EMember returns the actual ldfld type (MBool,
  // MInt, etc.) rather than always MObject — prevents StackUnexpected / IPE when
  // value-type fields are compared with ceq vs. Object.Equals (#1442).
  fieldMsilTypes: Map[String, MsilType]
  funcTokens: Map[String, Int]  // funcName → MethodDef token
  funcRetTypes: Map[String, MsilType]  // funcName → MsilType of declared return
  // funcName → declared parameter MsilTypes (same arity-qualified + bare keys
  // as funcTokens).  Used to thread a call argument's expected type into
  // `contextHintTyArgs` so a bare `f(None)` constructs `Option_None<concrete>`
  // rather than erasing to `<object>` (keeps the canonical nullary-case
  // representation consistent across construction positions).
  funcParamTypes: Map[String, List[MsilType]]
  // Declared parameter MODES per function (same keys as funcParamTypes:
  // arity-qualified + bare-FQN alias).  Lets a call site pass `out`/`inout`
  // arguments by managed pointer (address-load) instead of by value.  See #1761.
  funcParamModes: Map[String, List[ParamMode]]
  // Declared parameter names per function, flat-encoded as "/param<i>" keys.
  // Avoids nested-map allocation; simplifies key lookup for named-arg reordering (#2988, #1503).
  funcParamNames: Map[String, String]
  // Default value expressions for function parameters with `= expr` defaults.
  // Keyed `<fqn>/param<i>` and `<arityKey>/param<i>` (same key space as
  // funcParamNames).  Populated by addPackageTokens.  Lets reorderFuncNamedArgs
  // fill a missing named-arg slot from the declared default (#1503).
  funcDefaultExprs: Map[String, Expr]
  // Inner parameter MsilTypes of a function-typed parameter (`(A,B) -> R` ⇒
  // [MsilType(A), MsilType(B)]), keyed `"<fqn>#<paramIdx>"` (both the
  // arity-qualified and bare-FQN aliases).  Only function-typed parameters have
  // an entry.  Lets a call site propagate the expected parameter types of a
  // lambda passed directly as an argument into that lambda's body so its boxed
  // params unbox correctly (#1939).  Flat (not nested) to sidestep the stage-0
  // emitter's List[List[_]] indexing inference.
  funcParamFnInner: Map[String, List[MsilType]]
  // Propagated parameter MsilTypes for a lifted lambda, keyed by lambda name
  // ("__lambda_<idx>").  Recorded at the call site (from funcParamFnInner) before
  // the lambda arg is lowered; consumed by lowerFuncMsil's `__lambda_*` path to
  // seed boxedParamTypes for un-annotated params.  #1939.
  lambdaParamTypes: Map[String, List[MsilType]]
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
  constValues: Map[String, Int]  // constName → inlined Int value
  // Bare const/val names claimed by an earlier package's literal const
  // registration — the addPackageTokens pre-pass mirror of the emission
  // side's first-wins bare-name `constValues` adds (#2628).  The pre-pass
  // needs it to predict that a later package whose same-named literal IVal
  // loses the bare-name slot keeps its .cctor field init — and therefore
  // its .cctor MethodDef row; predicting "literal, no .cctor" there shifts
  // every later MethodDef token by one (the entry token then points at the
  // wrong method).
  // This is a SET: only containsKey is ever consulted and every stored value
  // is `true` — Map[String, Bool] with always-true values is the compiler's
  // pervasive set idiom (see e.g. Jvm.Lowering.collectBranchTargets); no
  // compiler package uses Std.Set (#3254).
  constBareClaimed: Map[String, Bool]
  // Lyric enums lower to ordinal Int values (mirroring the F# emitter's
  // EnumCaseLookup): type positions encode I4, a case reference emits
  // `ldc.i4 <ordinal>`, and a `case X` pattern compares ordinals.  A
  // CLASS-flavored signature/TypeRef to the enum TypeDef (a value type
  // extending System.Enum) is rejected by the loader (#3196).
  enumTypeNames: Map[String, Int]  // enum simple name → case count
  enumCaseOrdinals: Map[String, Int]  // case name (simple + pkg-qualified) → ordinal
  // FFI caches (#370 + Phase R6).  Populated lazily by
  // emitExternTargetBody as `@externTarget` declarations are walked.
  ffiAsmRefs: Map[String, Int]  // assembly simple name → AssemblyRef row index
  ffiTypeRefs: Map[String, Int]  // "asm/ns.name" key → TypeRef row index
  // Auto-FFI metadata resolution (epic #1622, Phase 3c + 4).  Lazily-built
  // once per package over the reference pack; `metadataReady` is a one-shot
  // flag holder (empty = not yet built) since record scalar fields can't be
  // reassigned.  `metadataVtypeSet` maps public value-type FQNs (structs /
  // enums) to true — used by externValueTypeMsil to detect value types from
  // metadata instead of the retired clrIsValueType hardcoded list (#1802).
  metadataTypeIndex: Map[String, String]
  metadataPathIndex: Map[String, String]
  metadataVtypeSet: Map[String, Bool]
  metadataReady: List[Bool]
  // Lambda / yield / extern-type support (Band 2, R6).
  tokActionCtor: Int  // System.Action::.ctor(object, native int)
  tokActionInvoke: Int  // System.Action::Invoke(): void
  actionTypeRefs: Map[String, Int]  // toString(nparams) → TypeRef row for System.Action`N
  externTypeNames: Map[String, String]  // Lyric name → CLR FQN (from IExternType items)
  lambdaTicker: List[Int]  // length = next __lambda_<i> index
  // Instance method MethodDef tokens, keyed by "FQClassName/methodName".  Populated
  // by `addPackageTokens` for record methods, interface methods (abstract slots),
  // and impl methods folded into the implementing record.  `lowerMethodCallMsil`
  // looks these up to emit `callvirt` for user-defined dispatch (#878).
  methodTokens: Map[String, Int]
  // Declared return MsilType per instance/interface method, keyed by the same
  // "FQClassName/methodName" form as `methodTokens`.  `lowerMethodCallMsil`
  // looks this up so a user-defined dispatch reports its real return type
  // (e.g. a `Result[Unit, E]` union) to its caller instead of a bare `object`.
  // Without it the scrutinee of a `match store.set(...)` was tracked as
  // `MObject`, so union pattern tests/binds mis-extracted the payload and the
  // wrong arm fired (#1602).  Mirrors `funcRetTypes` for direct static calls.
  methodRetTypes: Map[String, MsilType]
  // Declared MSIL parameter type per instance/interface/impl method parameter,
  // keyed `<FQClassName>/<methodName>#<paramIndex>` (0-based, excluding the
  // implicit `this`).  `lowerMethodCallMsil` consults it so a value-type
  // argument is passed as-is to a value-type parameter instead of being boxed —
  // the method signature declares the concrete value type, so boxing produced
  // `object` where `bool`/`int32` was expected (invalid IL, #1784).  A missing
  // entry falls back to the conservative box-if-value-type behaviour.
  methodParamTypes: Map[String, MsilType]
  // Per-method param-mode list keyed by `<className>/<methodName>`.  Used by
  // the interface/impl dispatch in `lowerMethodCallMsil` to emit a byref
  // (managed pointer) load for `out`/`inout` arguments instead of the
  // by-value load — without it interface calls with byref params bound to
  // signatures missing the `&` qualifier (#1955).
  methodParamModes: Map[String, List[ParamMode]]
  // Pending interface implementations discovered by the IImpl pre-pass.  Each
  // entry maps an implementing record's FQ name to its impl block(s); used to
  // (a) inject impl methods into the target MRecord, and (b) emit MPImpl items
  // after all TypeDefs are lowered so InterfaceImpl / MethodImpl rows can be
  // resolved by name (#878).
  implEntries: List[ImplEntryMsil]
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
  nextMethodDefRow: List[Int]
  nextFieldDefRow: List[Int]
  // Bundle-wide entry point.  When `addPackageTokens` walks a package and
  // encounters a top-level `func main()`, it records the MethodDef token
  // here.  At most one element — the first package whose `main()` is seen
  // wins, matching the F# `emitProject` host-entry policy.  Stays empty
  // when no package defines `main` (library-shaped bundle).  See #1183
  // Phase 2.
  mainEntryToken: List[Int]
  // Per-package import edges (#1183 Phase 2).  `pkgImports[pkgName]` is the
  // dotted-name list of every package that `pkgName` imports.  Populated by
  // `addPackageTokens` so that call-site resolution in
  // `lowerBuiltinOrStaticCallMsil` can fall back to each imported package's
  // FQN-keyed funcs when a bare call doesn't match the current package.
  pkgImports: Map[String, List[String]]
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
  // Changed to a multimap (Map[String, List[String]]) so that two unions
  // in different packages can share a simple case name without one
  // silently overwriting the other (#2899).  Disambiguation at each
  // lookup site uses `pickCaseFqnByScope` / `pickCaseFqnByScrutinee`.
  unionCaseCtorByName: Map[String, List[String]]
  // Parent union FQN for each case-class key (#2363 Stage 4).  Key = the case
  // class FQN (e.g. "Pkg.Union_Case"); value = the parent union FQN
  // ("Pkg.Union").  Construction sites use this to recover the parent union
  // type for the expression's result `MClass` WITHOUT string-splitting the case
  // key on the separator — once the separator is `_` (matching F#), splitting is
  // ambiguous (`_` is a valid identifier char), so the parent is looked up here.
  caseParentUnion: Map[String, String]
  // Cross-package type name lookup (#1183 codegen port).  Maps a type's
  // simple name (e.g. "Maybe", "Point") to its FQN
  // (e.g. "XPkgUnion.Lib.Maybe").  First-processed wins on collisions,
  // mirroring `unionCaseCtorByName`.  LEGACY: kept only for the
  // record-ctor call-resolution sites (`lowerBuiltinOrStaticCallMsil`'s
  // cross-package ctor lookup and the EMember receiver fallback), which
  // predate scope-tier resolution and have their own disambiguation
  // story.  TYPE-POSITION resolution must NOT consult this map directly —
  // use `resolveTypeFqn`, which walks the ordered `typeFqnCandidates`
  // multimap below with the type checker's scope tiers (#3085).
  typeFqnByName: Map[String, String]
  // Every FQN registered for a simple type name, in registration order
  // (#3085).  `resolveTypeFqn` walks this with the same scope tiers the
  // type checker's `symTableTryFindOne` uses — own package, then an
  // imported package, then last-registered — so a short name that
  // collides across packages (`Msil.Kernel.ByteWriter` vs the
  // transitively-loaded `Std.Stream.ByteWriter`) resolves to the same
  // declaration the type checker bound, not to whichever package
  // happened to register first.
  typeFqnCandidates: Map[String, List[String]]
  // Generic stdlib union case type-param count. Key = FQN ctor key of the
  // case class (e.g. "Std.Core.Option_Some"). Value = number of type params
  // on the parent union (e.g. 1 for Option[T], 2 for Result[T,E]). Used at
  // construction sites to build TypeSpec-based newobj tokens, which ECMA-335
  // §III.4.21 requires for generic types ("if typeTok is a generic class, the
  // token shall be a TypeSpec token").
  caseTypeParamCount: Map[String, Int]
  // In-bundle generic type arity (#2362 / docs/43).  Key = the type's dotted
  // FQN (e.g. "Pkg.Box", "Pkg.Maybe"); value = its type-parameter count (the
  // number of `GPType` params).  Populated by `addPackageTokens` for every
  // in-bundle generic record / union.  `typeExprToMsilCtx` consults this BEFORE
  // the `ffiTypeRefs` lookup so an in-bundle `Box[Int]` lowers to
  // `MGenericInstByName` (resolved to the in-bundle TypeDef at lowering) rather
  // than erasing to `MObject`; construction / field / match sites route through
  // the by-name generic instructions accordingly.
  genericTypeArity: Map[String, Int]
  // Constructor parameter MSIL types (in declaration order) for an in-bundle
  // generic record (#2362).  Key = the record FQN (e.g. "Pkg.Box"); value = the
  // field types in VAR form (e.g. [MTypeVar(0)] for `Box(value: T)`, or
  // [MTypeVar(0), MString] for `Pair(first: A, name: String)`).  These exactly
  // match the field-parameterised `.ctor` signature that `lowerMRecord` emits on
  // the generic TypeDef, so a construction site can build the TypeSpec-parented
  // `.ctor` MemberRef (via `MNewobjGenericByName`) without re-deriving them.
  genericCtorParams: Map[String, List[MsilType]]
  // Synthesised views of restored DLLs the bundle imports but doesn't ship; seeds cross-assembly tokens (#1272).
  restoredArtifacts: List[SynthesisedArtifact]
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
  staticValTokens: Map[String, Int]  // valName → 0x04000000 | fieldDefRow
  staticValMsilTypes: Map[String, MsilType]  // valName → declared MsilType
  // Config block field tokens (D046 / docs/25-config-blocks.md).
  // Keyed "BlockName/fieldName" → 0x04000000 | FieldDef row.  Pre-computed in
  // `addPackageTokens` (Pass 1, in source order alongside records/unions) so that
  // EMember on a config block receiver can emit ldsfld without evaluating the
  // (spurious) receiver expression.
  configFieldTokens: Map[String, Int]
  configFieldMsilTypes: Map[String, MsilType]
  // BCL tokens for the config .cctor body.  Registered in `newCodegenCtx` at stable
  // row positions (after the generator group) so callers can thread them through
  // MPConfig.configToks into lowerMConfig.
  tokCfgGetEnvVar: Int      // Environment.GetEnvironmentVariable(string): string
  tokCfgIsNullOrEmpty: Int  // String.IsNullOrEmpty(string): bool
  tokCfgConsoleError: Int   // Console.get_Error(): TextWriter  (static)
  tokCfgTwWriteLine: Int    // TextWriter.WriteLine(string): void  (HASTHIS)
  tokCfgEnvExit: Int        // Environment.Exit(int32): void  (static)
  tokCfgInt32Parse: Int     // Int32.Parse(string): int32  (static)
  tokCfgBoolParse: Int      // Boolean.Parse(string): bool  (static)
  tokCfgInt64Parse: Int     // Int64.Parse(string): int64  (static)
  tokCfgDoubleParse: Int    // Double.Parse(string, IFormatProvider): float64  (static)
  // Async SM synthesis (Phase B, Epic #2070).
  // TypeRef rows for System.Runtime.CompilerServices types.
  trAtmb: Int  // AsyncTaskMethodBuilder (void variant, row)
  trAtmb1: Int  // AsyncTaskMethodBuilder`1 (open generic, row)
  trIAsm: Int  // IAsyncStateMachine (interface, row)
  // MemberRef tokens for ATMB (void) instance methods.
  tokAtmbCreate: Int  // registered for MemberRef table ordering; not emitted (ATMB.Create() removed in .NET 7+, replaced by newobj zero-init)
  tokAtmbSetResult: Int  // ATMB::SetResult(): void  call (instance, on managed ptr)
  tokAtmbGetTask: Int  // registered for MemberRef table ordering; not emitted directly (get_Task() is called via TypeSpec-parented MemberRef in the kickoff, not through this field)
  tokAtmbStartMr: Int  // ATMB.Start<!!0>(ref !!0): void  open-generic MemberRef
  // Phase B.1 async suspension tokens.
  trTaskAwaiter1: Int  // System.Runtime.CompilerServices.TaskAwaiter`1 (open generic struct)
  trTaskAwaiter: Int  // System.Runtime.CompilerServices.TaskAwaiter   (non-generic struct)
  tokAtmbAwaitUnsafeMr: Int  // ATMB.AwaitUnsafeOnCompleted<!!0,!!1> open MemberRef row (void ATMB TypeRef parent)
  tokAtmb1AwaitUnsafeMr: Int  // ATMB`1.AwaitUnsafeOnCompleted<!!0,!!1> open MemberRef row (ATMB`1 TypeRef parent)
  // Monotonically-increasing counter for unique SM class names.
  // Pattern: "<funcName>__SM_<ticker>".  Matches AsyncStateMachine.fs convention.
  smTicker: List[Int]
  // Generator synthesis (Phase 5, Epic #2070).
  // TypeRef rows for IAsyncEnumerable/IAsyncEnumerator/IAsyncDisposable/ValueTask/CancellationToken.
  trIAE1: Int  // System.Collections.Generic.IAsyncEnumerable`1 (open generic, row)
  trIAET1: Int  // System.Collections.Generic.IAsyncEnumerator`1 (open generic, row)
  trIAsyncDisp: Int  // System.IAsyncDisposable
  trValueTask1: Int  // System.Threading.Tasks.ValueTask`1 (open generic struct, row)
  trValueTask: Int  // System.Threading.Tasks.ValueTask (non-generic struct, row)
  trCancToken: Int  // System.Threading.CancellationToken
  trTcs1: Int  // System.Threading.Tasks.TaskCompletionSource`1 (open generic, row)
  // Monotonically-increasing counter for unique generator class names.
  // Pattern: "<funcName>__Gen_<ticker>".  Both addPackageTokens and
  // synthesizeGeneratorMsil increment this in source-declaration order so
  // the computed FQN is consistent across the pre-scan and synthesis passes.
  genTicker: List[Int]
  // One impl block (`impl Iface for Target { … }`) captured by the pre-pass.
  // `methods` are produced by `lowerImplMethodMsil`, which reserves slot 0 for
  // the implicit `this` so `self` and user parameters resolve correctly when
  // the methods are emitted as virtual instance members of the target type.
}

pub record ImplEntryMsil {
  targetTypeName: String  // FQN, e.g. "Pkg.EnglishGreeter"
  ifaceTypeName: String  // FQN, e.g. "Pkg.Greeter"
  methods: List[MFunc]
  // Build and return a fresh CodegenCtx for the named package.
  // Registers all external AssemblyRef/TypeRef/MemberRef rows in a stable order
  // so that every instruction token is a predictable constant.
  // `major` / `minor` populate the Assembly row's version; both default to
  // zero for bootstrap-grade callers that don't thread a manifest version.
  // See `Msil.Bridge` entry points for the version threading wiring (#1364).
}

pub func newCodegenCtx(
  packageName: in String,
  restoredArtifacts: in List[SynthesisedArtifact],
  major: in Int,
  minor: in Int,
): CodegenCtx {
  val lctx = newLoweringCtx(packageName, major, minor)
  // After newLoweringCtx:
  //   arRuntime  = 1  (System.Runtime AssemblyRef)
  //   trObject   = 1  (System.Object TypeRef)

  // AssemblyRef[2]: System.Console
  val arConsole = ctxAddAssemblyRef(lctx, "System.Console", 10, 0)

  // TypeRef rows 2..8
  val trConsole = ctxAddTypeRef(lctx, "System", "Console", arConsole)
  val trString = ctxAddTypeRef(lctx, "System", "String", lctx.arRuntime)
  val trInt32 = ctxAddTypeRef(lctx, "System", "Int32", lctx.arRuntime)
  val trInt64 = ctxAddTypeRef(lctx, "System", "Int64", lctx.arRuntime)
  val trDouble = ctxAddTypeRef(lctx, "System", "Double", lctx.arRuntime)
  val trBoolean = ctxAddTypeRef(lctx, "System", "Boolean", lctx.arRuntime)
  val trChar = ctxAddTypeRef(lctx, "System", "Char", lctx.arRuntime)
  // System.Byte — needed so `Byte` values box/unbox correctly (e.g. reading
  // an element of a `slice[Byte]` through `IList.get_Item`, which returns a
  // boxed `object`).  Without it `boxTypeRef(MByte)` fell back to
  // `System.Object` and `unbox.any [Object]` was a no-op that leaked the
  // boxed reference (#2539 regression: garbage bytes broke HMAC verification).
  val trByte = ctxAddTypeRef(lctx, "System", "Byte", lctx.arRuntime)
  val trException = ctxAddTypeRef(lctx, "System", "Exception", lctx.arRuntime)
  val trInvalidOpException = ctxAddTypeRef(lctx, "System", "InvalidOperationException", lctx.arRuntime)

  // Build MemberRef signatures.
  // 1. Console.WriteLine(string): void  → MemberRef[1] → token 0x0A000001
  val wlStrPs: List[MsilType] = newList()
  wlStrPs.add(MString)
  val tokWLStr = 0x0A000000 +
    ctxAddMemberRef(lctx, trConsole, "WriteLine", "wl_str", buildStaticMethodSig(wlStrPs, MVoid))

  // 2. Console.WriteLine(int32): void  → 0x0A000002
  val wlIntPs: List[MsilType] = newList()
  wlIntPs.add(MInt)
  val tokWLInt = 0x0A000000 +
    ctxAddMemberRef(lctx, trConsole, "WriteLine", "wl_int", buildStaticMethodSig(wlIntPs, MVoid))

  // 3. Console.WriteLine(int64): void  → 0x0A000003
  val wlLongPs: List[MsilType] = newList()
  wlLongPs.add(MLong)
  val tokWLLong = 0x0A000000 +
    ctxAddMemberRef(lctx, trConsole, "WriteLine", "wl_long", buildStaticMethodSig(wlLongPs, MVoid))

  // 4. Console.WriteLine(double): void  → 0x0A000004
  val wlDblPs: List[MsilType] = newList()
  wlDblPs.add(MDouble)
  val tokWLDbl = 0x0A000000 +
    ctxAddMemberRef(lctx, trConsole, "WriteLine", "wl_dbl", buildStaticMethodSig(wlDblPs, MVoid))

  // 5. Console.WriteLine(bool): void  → 0x0A000005
  val wlBoolPs: List[MsilType] = newList()
  wlBoolPs.add(MBool)
  val tokWLBool = 0x0A000000 +
    ctxAddMemberRef(lctx, trConsole, "WriteLine", "wl_bool", buildStaticMethodSig(wlBoolPs, MVoid))

  // 6. Console.Write(string): void  → 0x0A000006
  val wStrPs: List[MsilType] = newList()
  wStrPs.add(MString)
  val tokWStr = 0x0A000000 + ctxAddMemberRef(lctx, trConsole, "Write", "w_str", buildStaticMethodSig(wStrPs, MVoid))

  // 7. String.Concat(string,string): string  → 0x0A000007
  val concat2Ps: List[MsilType] = newList()
  concat2Ps.add(MString)
  concat2Ps.add(MString)
  val tokConcat2 = 0x0A000000 +
    ctxAddMemberRef(lctx, trString, "Concat", "concat2", buildStaticMethodSig(concat2Ps, MString))

  // 8. String.Concat(string,string,string): string  → 0x0A000008
  val concat3Ps: List[MsilType] = newList()
  concat3Ps.add(MString)
  concat3Ps.add(MString)
  concat3Ps.add(MString)
  val tokConcat3 = 0x0A000000 +
    ctxAddMemberRef(lctx, trString, "Concat", "concat3", buildStaticMethodSig(concat3Ps, MString))

  // 9. Exception..ctor(string): void  instance HASTHIS  → 0x0A000009
  val excCtorPs: List[MsilType] = newList()
  excCtorPs.add(MString)
  val tokExcCtor = 0x0A000000 +
    ctxAddMemberRef(lctx, trException, ".ctor", "exc_ctor", buildInstanceMethodSig(excCtorPs, MVoid))

  // 9b. InvalidOperationException..ctor(string): void  instance HASTHIS
  // Used for internal-invariant violations (compiler bugs) only; user-facing
  // runtime errors keep tokExceptionCtor so stack traces distinguish the two.
  val ioExcCtorPs: List[MsilType] = newList()
  ioExcCtorPs.add(MString)
  val tokInvalidOpExcCtor = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trInvalidOpException,
      ".ctor",
      "inv_op_exc_ctor",
      buildInstanceMethodSig(ioExcCtorPs, MVoid)
    )

  // 10. String.Format(string,object): string  → 0x0A00000A
  val fmt1Ps: List[MsilType] = newList()
  fmt1Ps.add(MString)
  fmt1Ps.add(MObject)
  val tokFmt1 = 0x0A000000 + ctxAddMemberRef(lctx, trString, "Format", "fmt1", buildStaticMethodSig(fmt1Ps, MString))

  // 11. String.Format(string,object,object): string  → 0x0A00000B
  val fmt2Ps: List[MsilType] = newList()
  fmt2Ps.add(MString)
  fmt2Ps.add(MObject)
  fmt2Ps.add(MObject)
  val tokFmt2 = 0x0A000000 + ctxAddMemberRef(lctx, trString, "Format", "fmt2", buildStaticMethodSig(fmt2Ps, MString))

  // 12. String.Format(string,object,object,object): string  → 0x0A00000C
  val fmt3Ps: List[MsilType] = newList()
  fmt3Ps.add(MString)
  fmt3Ps.add(MObject)
  fmt3Ps.add(MObject)
  fmt3Ps.add(MObject)
  val tokFmt3 = 0x0A000000 + ctxAddMemberRef(lctx, trString, "Format", "fmt3", buildStaticMethodSig(fmt3Ps, MString))

  // 13. Object.ToString(): string  instance HASTHIS  → 0x0A00000D
  val toStrPs: List[MsilType] = newList()
  val tokObjToStr = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      lctx.trObject,
      "ToString",
      "obj_tostring",
      buildInstanceMethodSig(toStrPs, MString)
    )

  // System.Type TypeRef (needed for GetType / get_Name)
  val trType = ctxAddTypeRef(lctx, "System", "Type", lctx.arRuntime)

  // Exception.get_Message(): string  instance HASTHIS
  val excGetMsgPs: List[MsilType] = newList()
  val tokExcGetMessage = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trException,
      "get_Message",
      "exc_get_message",
      buildInstanceMethodSig(excGetMsgPs, MString)
    )

  // Object.GetType(): Type  instance HASTHIS
  val objGetTypePs: List[MsilType] = newList()
  val tokObjGetType = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      lctx.trObject,
      "GetType",
      "obj_gettype",
      buildInstanceMethodSig(objGetTypePs, MObject)
    )

  // Type.get_Name: string  instance HASTHIS  (Type is reference type; return MString)
  val typeGetNamePs: List[MsilType] = newList()
  val tokTypeGetName = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trType,
      "get_Name",
      "type_get_name",
      buildInstanceMethodSig(typeGetNamePs, MString)
    )

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
  val tokListObjCtor = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      lctx,
      tsListObj,
      ".ctor",
      "list_obj_ctor",
      buildInstanceMethodSig(listCtorPs, MVoid)
    )

  // 15. List<object>::Add(!0): void  — MemberRef on TypeSpec must use ELEMENT_TYPE_VAR
  val listAddPs: List[MsilType] = newList()
  listAddPs.add(MTypeVar(0))
  val tokListObjAdd = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      lctx,
      tsListObj,
      "Add",
      "list_obj_add",
      buildInstanceMethodSig(listAddPs, MVoid)
    )

  // 16. List<object>::get_Item(int32): !0  — return type is the generic type param
  val listGetPs: List[MsilType] = newList()
  listGetPs.add(MInt)
  val tokListObjGetItem = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      lctx,
      tsListObj,
      "get_Item",
      "list_obj_getitem",
      buildInstanceMethodSig(listGetPs, MTypeVar(0))
    )

  // 16b. List<object>::set_Item(int32, !0): void  — indexed assignment a[i] = v.
  // The value parameter is the generic element type (ELEMENT_TYPE_VAR 0); the
  // index is int32, matching get_Item.
  val listSetPs: List[MsilType] = newList()
  listSetPs.add(MInt)
  listSetPs.add(MTypeVar(0))
  val tokListObjSetItem = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      lctx,
      tsListObj,
      "set_Item",
      "list_obj_setitem",
      buildInstanceMethodSig(listSetPs, MVoid)
    )

  // 17. List<object>::get_Count(): int32  instance HASTHIS
  val listCntPs: List[MsilType] = newList()
  val tokListObjGetCount = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      lctx,
      tsListObj,
      "get_Count",
      "list_obj_count",
      buildInstanceMethodSig(listCntPs, MInt)
    )

  // 17b. List<object>::Contains(!0): bool  — element param is type var !0
  val listContainsPs: List[MsilType] = newList()
  listContainsPs.add(MTypeVar(index = 0))
  val tokListObjContains = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      lctx,
      tsListObj,
      "Contains",
      "list_obj_contains",
      buildInstanceMethodSig(listContainsPs, MBool)
    )

  // 17c. List<object>::RemoveAt(int32): void  instance HASTHIS
  val listRemoveAtPs: List[MsilType] = newList()
  listRemoveAtPs.add(MInt)
  val tokListObjRemoveAt = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      lctx,
      tsListObj,
      "RemoveAt",
      "list_obj_removeat",
      buildInstanceMethodSig(listRemoveAtPs, MVoid)
    )

  // ── Non-generic IList / ICollection (erased-list read path) ──────────────
  // Both live in System.Runtime (the non-generic collection interfaces, unlike
  // the generic List`1 in System.Collections).  Used to read a list whose
  // static type erased to `object` but whose runtime instance may be a concrete
  // `List<Foo>` (e.g. a `List[T]` extracted from a tuple) — `IList`/`ICollection`
  // bind regardless of the element type.
  val trIList = ctxAddTypeRef(lctx, "System.Collections", "IList", lctx.arRuntime)
  val trICollection = ctxAddTypeRef(lctx, "System.Collections", "ICollection", lctx.arRuntime)
  val ilistGetPs: List[MsilType] = newList()
  ilistGetPs.add(MInt)
  val tokIListGetItem = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trIList,
      "get_Item",
      "ilist_getitem",
      buildInstanceMethodSig(ilistGetPs, MObject)
    )
  val icollCntPs: List[MsilType] = newList()
  val tokICollGetCount = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trICollection,
      "get_Count",
      "icoll_count",
      buildInstanceMethodSig(icollCntPs, MInt)
    )
  val tokIListCast = 0x01000000 + trIList

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
  val tokDictObjCtor = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      lctx,
      tsDictObj,
      ".ctor",
      "dict_obj_ctor",
      buildInstanceMethodSig(dictCtorPs, MVoid)
    )

  // 19. Dictionary<object,object>::Add(!0, !1): void  — MemberRef on TypeSpec uses type vars
  val dictAddPs: List[MsilType] = newList()
  dictAddPs.add(MTypeVar(0))
  dictAddPs.add(MTypeVar(1))
  val tokDictObjAdd = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      lctx,
      tsDictObj,
      "Add",
      "dict_obj_add",
      buildInstanceMethodSig(dictAddPs, MVoid)
    )

  // 20. Dictionary<object,object>::get_Item(!0): !1  — key param !0, value return !1
  val dictGetPs: List[MsilType] = newList()
  dictGetPs.add(MTypeVar(0))
  val tokDictObjGetItem = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      lctx,
      tsDictObj,
      "get_Item",
      "dict_obj_getitem",
      buildInstanceMethodSig(dictGetPs, MTypeVar(1))
    )

  // 20b. Dictionary<object,object>::set_Item(!0, !1): void  — indexed
  // assignment `m[k] = v` on a Map.  Distinct from List<object>::set_Item
  // (which takes an int32 index): a Map store with a non-int key must go
  // through the dictionary indexer, or the codegen pushes a key of the wrong
  // stack type and the JIT rejects the body (#1602).
  val dictSetPs: List[MsilType] = newList()
  dictSetPs.add(MTypeVar(0))
  dictSetPs.add(MTypeVar(1))
  val tokDictObjSetItem = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      lctx,
      tsDictObj,
      "set_Item",
      "dict_obj_setitem",
      buildInstanceMethodSig(dictSetPs, MVoid)
    )

  // 21. Dictionary<object,object>::get_Count(): int32  instance HASTHIS
  val dictCntPs: List[MsilType] = newList()
  val tokDictObjGetCount = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      lctx,
      tsDictObj,
      "get_Count",
      "dict_obj_count",
      buildInstanceMethodSig(dictCntPs, MInt)
    )

  // 22. Dictionary<object,object>::ContainsKey(!0): bool  — key param is type var !0
  val dictCkPs: List[MsilType] = newList()
  dictCkPs.add(MTypeVar(0))
  val tokDictObjContainsKey = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      lctx,
      tsDictObj,
      "ContainsKey",
      "dict_obj_ck",
      buildInstanceMethodSig(dictCkPs, MBool)
    )

  // 22b. Dictionary<object,object>::Remove(!0): bool  HASTHIS — key is type var !0.
  val dictRmPs: List[MsilType] = newList()
  dictRmPs.add(MTypeVar(0))
  val tokDictObjRemove = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      lctx,
      tsDictObj,
      "Remove",
      "dict_obj_remove",
      buildInstanceMethodSig(dictRmPs, MBool)
    )

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
  val tokActionCtor = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trAction,
      ".ctor",
      "action_ctor",
      buildInstanceMethodSig(actionCtorPs, MVoid)
    )

  // 26. System.Action::Invoke(): void  HASTHIS
  val actionInvokePs: List[MsilType] = newList()
  val tokActionInvoke = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trAction,
      "Invoke",
      "action_invoke",
      buildInstanceMethodSig(actionInvokePs, MVoid)
    )

  // 27. String.get_Chars(int32): char  instance HASTHIS
  val strGetCharsPs: List[MsilType] = newList()
  strGetCharsPs.add(MInt)
  val tokStringGetChars = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trString,
      "get_Chars",
      "str_get_chars",
      buildInstanceMethodSig(strGetCharsPs, MChar)
    )

  // 28. String.get_Length(): int32  instance HASTHIS
  val strGetLengthPs: List[MsilType] = newList()
  val tokStringGetLength = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trString,
      "get_Length",
      "str_get_length",
      buildInstanceMethodSig(strGetLengthPs, MInt)
    )

  // 29. String.Substring(int32, int32): string  instance HASTHIS
  val strSubPs: List[MsilType] = newList()
  strSubPs.add(MInt)
  strSubPs.add(MInt)
  val tokStringSubstring = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trString,
      "Substring",
      "str_substring",
      buildInstanceMethodSig(strSubPs, MString)
    )

  // 29b. String.Replace(string, string): string  instance HASTHIS
  val strReplacePs: List[MsilType] = newList()
  strReplacePs.add(MString)
  strReplacePs.add(MString)
  val tokStringReplace = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trString,
      "Replace",
      "str_replace",
      buildInstanceMethodSig(strReplacePs, MString)
    )

  // 29c. String.IsNormalized(): bool  instance HASTHIS
  val strIsNormPs: List[MsilType] = newList()
  val tokStringIsNormalized = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trString,
      "IsNormalized",
      "str_is_normalized",
      buildInstanceMethodSig(strIsNormPs, MBool)
    )

  // 29d. String.Normalize(): string  instance HASTHIS
  val strNormPs: List[MsilType] = newList()
  val tokStringNormalize = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trString,
      "Normalize",
      "str_normalize",
      buildInstanceMethodSig(strNormPs, MString)
    )

  // 29e. Remaining String instance methods used via method syntax.
  val strTrimPs: List[MsilType] = newList()
  val tokStringTrim = 0x0A000000 +
    ctxAddMemberRef(lctx, trString, "Trim", "str_trim", buildInstanceMethodSig(strTrimPs, MString))

  val strIndexOfPs: List[MsilType] = newList()
  strIndexOfPs.add(MString)
  val tokStringIndexOf = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trString,
      "IndexOf",
      "str_indexof",
      buildInstanceMethodSig(strIndexOfPs, MInt)
    )

  val strLastIndexOfPs: List[MsilType] = newList()
  strLastIndexOfPs.add(MString)
  val tokStringLastIndexOf = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trString,
      "LastIndexOf",
      "str_lastindexof",
      buildInstanceMethodSig(strLastIndexOfPs, MInt)
    )

  val strStartsWithPs: List[MsilType] = newList()
  strStartsWithPs.add(MString)
  val tokStringStartsWith = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trString,
      "StartsWith",
      "str_startswith",
      buildInstanceMethodSig(strStartsWithPs, MBool)
    )

  val strEndsWithPs: List[MsilType] = newList()
  strEndsWithPs.add(MString)
  val tokStringEndsWith = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trString,
      "EndsWith",
      "str_endswith",
      buildInstanceMethodSig(strEndsWithPs, MBool)
    )

  val strContainsPs: List[MsilType] = newList()
  strContainsPs.add(MString)
  val tokStringContains = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trString,
      "Contains",
      "str_contains",
      buildInstanceMethodSig(strContainsPs, MBool)
    )

  // ToLowerInvariant / ToUpperInvariant (not the culture-sensitive
  // ToLower/ToUpper): protocol strings such as JWT algorithm names must
  // fold consistently regardless of thread culture (e.g. the Turkish-I
  // problem, where "I".ToLower() yields "ı" under tr-TR).
  val strToLowerPs: List[MsilType] = newList()
  val tokStringToLower = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trString,
      "ToLowerInvariant",
      "str_tolower_inv",
      buildInstanceMethodSig(strToLowerPs, MString)
    )

  val strToUpperPs: List[MsilType] = newList()
  val tokStringToUpper = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trString,
      "ToUpperInvariant",
      "str_toupper_inv",
      buildInstanceMethodSig(strToUpperPs, MString)
    )

  // 30. Object.Equals(object, object): bool  static
  val objEqPs: List[MsilType] = newList()
  objEqPs.add(MObject)
  objEqPs.add(MObject)
  val tokObjectStaticEquals = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      lctx.trObject,
      "Equals",
      "obj_static_eq",
      buildStaticMethodSig(objEqPs, MBool)
    )

  // String.CompareOrdinal(string, string): int32  static — lexicographic
  // ordinal comparison for the relational operators on `String` (#2539).
  val strCmpOrdPs: List[MsilType] = newList()
  strCmpOrdPs.add(MString)
  strCmpOrdPs.add(MString)
  val tokStringCompareOrdinal = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trString,
      "CompareOrdinal",
      "str_compare_ordinal",
      buildStaticMethodSig(strCmpOrdPs, MInt)
    )

  // System.Action`N TypeRefs are registered lazily on first use for each N
  // (see internActionTypeRef); no static entries here.

  // Async support (Phase A, Band 3): Task and Task::Wait().
  // Task is in the System.Threading.Tasks assembly (per clrAssemblyForType).
  val arTasks = ctxAddAssemblyRef(lctx, "System.Threading.Tasks", 10, 0)
  val trTask = ctxAddTypeRef(lctx, "System.Threading.Tasks", "Task", arTasks)
  val trTask1 = ctxAddTypeRef(lctx, "System.Threading.Tasks", "Task`1", arTasks)
  // Task::Wait(): void  instance HASTHIS — used to block on void async externs.
  val tokTaskWait = 0x0A000000 +
    ctxAddMemberRef(lctx, trTask, "Wait", "task_wait", buildInstanceMethodSig(newList(), MVoid))

  // ── Culture-invariant toString(DateTime) (#2184) ───────────────────────────
  // Counterpart of the F# bootstrap emitter's culture-invariant `toString`
  // path: pin InvariantCulture so a DateTime renders identically (the
  // "MM/dd/yyyy HH:mm:ss" invariant form) regardless of the host OS locale,
  // keeping stage-0 (F#) and stage-1 (self-hosted) output in lockstep.
  // CultureInfo / IFormatProvider / DateTime are type-forwarded from
  // System.Runtime, so the runtime AssemblyRef resolves all three.
  val trCultureInfo = ctxAddTypeRef(lctx, "System.Globalization", "CultureInfo", lctx.arRuntime)
  val trIFormatProvider = ctxAddTypeRef(lctx, "System", "IFormatProvider", lctx.arRuntime)
  val trDateTime = ctxAddTypeRef(lctx, "System", "DateTime", lctx.arRuntime)

  // CultureInfo.get_InvariantCulture(): CultureInfo  — static
  val ciRet: MsilType = MClassRef(typeRefCode = tdrTypeRef(trCultureInfo), clrFqn = "System.Globalization.CultureInfo")
  val tokInvariantCulture = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trCultureInfo,
      "get_InvariantCulture",
      "ci_get_invariant",
      buildStaticMethodSig(newList(), ciRet)
    )

  // DateTime.ToString(string): string  — ISO-8601 "o" format specifier path.
  // Called with ldstr "o" + ldloca(dtSlot) + call DateTime.ToString(string).
  // Produces "1970-01-01T00:00:00.0000000Z" for UTC DateTimes, matching the
  // F# bootstrap emitter's DateTime.ToString("o") path in Codegen.fs (#2184).
  val dtToStrOPs: List[MsilType] = newList()
  dtToStrOPs.add(MString)
  val tokDateTimeToStringO = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trDateTime,
      "ToString",
      "dt_tostring_o",
      buildInstanceMethodSig(dtToStrOPs, MString)
    )
  val usDateTimeFormatO = ctxInternUs(lctx, "o")

  // Double.ToString(IFormatProvider): string  — locale-invariant double serialisation (#2462).
  // The box-then-Object.ToString() path is locale-sensitive (German: "3,14" not "3.14").
  // Call sequence: stloc(dblSlot) + ldloca(dblSlot) + call get_InvariantCulture() + call Double::ToString.
  val dblToStrPs: List[MsilType] = newList()
  dblToStrPs.add(MClassRef(typeRefCode = tdrTypeRef(trIFormatProvider), clrFqn = "System.IFormatProvider"))
  val tokDoubleToStringInv = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trDouble,
      "ToString",
      "dbl_tostring_inv",
      buildInstanceMethodSig(dblToStrPs, MString)
    )

  // Async SM synthesis (Phase B, Epic #2070).
  // AsyncTaskMethodBuilder and IAsyncStateMachine live in System.Runtime.
  val trAtmb = ctxAddTypeRef(lctx, "System.Runtime.CompilerServices", "AsyncTaskMethodBuilder", lctx.arRuntime)
  val trAtmb1 = ctxAddTypeRef(lctx, "System.Runtime.CompilerServices", "AsyncTaskMethodBuilder`1", lctx.arRuntime)
  val trIAsm = ctxAddTypeRef(lctx, "System.Runtime.CompilerServices", "IAsyncStateMachine", lctx.arRuntime)

  // Void builder method signatures (struct methods — HASTHIS, called via `call`
  // on a managed pointer produced by `ldflda`).
  // ATMB.Create(): ATMB  (static)
  val atmbMsilTy = MValueTypeRef(
    typeRefCode = tdrTypeRef(trAtmb),
    clrFqn = "System.Runtime.CompilerServices.AsyncTaskMethodBuilder"
  )
  val atmbCreateSig = buildStaticMethodSig(newList(), atmbMsilTy)
  val tokAtmbCreate = 0x0A000000 + ctxAddMemberRef(lctx, trAtmb, "Create", "atmb_create", atmbCreateSig)

  // ATMB.SetResult(): void  (instance HASTHIS)
  val tokAtmbSetResult = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trAtmb,
      "SetResult",
      "atmb_setresult",
      buildInstanceMethodSig(newList(), MVoid)
    )

  // ATMB.get_Task(): Task  (instance HASTHIS; property getter)
  val taskMsilTy = MClassRef(typeRefCode = tdrTypeRef(trTask), clrFqn = "System.Threading.Tasks.Task")
  val getTaskArgs: List[MsilType] = newList()
  val tokAtmbGetTask = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trAtmb,
      "get_Task",
      "atmb_gettask",
      buildInstanceMethodSig(getTaskArgs, taskMsilTy)
    )

  // ATMB.Start<!!0>(ref !!0): void  (open-generic instance; method is
  // instantiated per-SM at Phase 5 lowering via MCallAtmbStart).
  val tokAtmbStartMr = ctxAddMemberRef(lctx, trAtmb, "Start", "atmb_start_open", buildAtmbStartOpenSig())

  // Phase B.1: TaskAwaiter`1 and TaskAwaiter TypeRefs (GetAwaiter/GetResult call sites).
  val trTaskAwaiter1 = ctxAddTypeRef(lctx, "System.Runtime.CompilerServices", "TaskAwaiter`1", lctx.arRuntime)
  val trTaskAwaiter = ctxAddTypeRef(lctx, "System.Runtime.CompilerServices", "TaskAwaiter", lctx.arRuntime)

  // Phase B.1: open MemberRef rows for AwaitUnsafeOnCompleted<!!0,!!1>(ref !!0, ref !!1): void.
  // These are parent-typed MemberRefs: the void-path parent is the ATMB TypeRef;
  // the non-void path parent is the ATMB`1 TypeRef.  At each call site, a
  // TypeSpec-parented MemberRef will be built lazily (for non-void), or the
  // ATMB TypeRef-parented one is used directly (for void).  Both are registered
  // here so the MemberRef table order is stable across all packages.
  val tokAtmbAwaitUnsafeMr = ctxAddMemberRef(
    lctx,
    trAtmb,
    "AwaitUnsafeOnCompleted",
    "atmb_awaitunafe_open",
    buildAwaitUnsafeOnCompletedOpenSig()
  )
  val tokAtmb1AwaitUnsafeMr = ctxAddMemberRef(
    lctx,
    trAtmb1,
    "AwaitUnsafeOnCompleted",
    "atmb1_awaitunafe_open",
    buildAwaitUnsafeOnCompletedOpenSig()
  )

  // Generator synthesis (Phase 5, Epic #2070).
  // IAsyncEnumerable`1, IAsyncEnumerator`1, IAsyncDisposable live in System.Runtime.
  // ValueTask`1, ValueTask, and CancellationToken also live in System.Runtime.
  val trIAE1 = ctxAddTypeRef(lctx, "System.Collections.Generic", "IAsyncEnumerable`1", lctx.arRuntime)
  val trIAET1 = ctxAddTypeRef(lctx, "System.Collections.Generic", "IAsyncEnumerator`1", lctx.arRuntime)
  val trIAsyncDisp = ctxAddTypeRef(lctx, "System", "IAsyncDisposable", lctx.arRuntime)
  val trValueTask1 = ctxAddTypeRef(lctx, "System.Threading.Tasks", "ValueTask`1", lctx.arRuntime)
  val trValueTask = ctxAddTypeRef(lctx, "System.Threading.Tasks", "ValueTask", lctx.arRuntime)
  val trCancToken = ctxAddTypeRef(lctx, "System.Threading", "CancellationToken", lctx.arRuntime)
  val trTcs1 = ctxAddTypeRef(lctx, "System.Threading.Tasks", "TaskCompletionSource`1", arTasks)

  // Config block BCL support (D046 / docs/25-config-blocks.md).
  // Registered in a stable order after the generator group so every MemberRef
  // row occupies a predictable slot in the binary.
  val trTextWriter = ctxAddTypeRef(lctx, "System.IO", "TextWriter", lctx.arRuntime)
  val trEnvironment = ctxAddTypeRef(lctx, "System", "Environment", lctx.arRuntime)

  val cfgGetEnvPs: List[MsilType] = newList()
  cfgGetEnvPs.add(MString)
  val tokCfgGetEnvVar = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trEnvironment,
      "GetEnvironmentVariable",
      "cfg_getenvvar",
      buildStaticMethodSig(cfgGetEnvPs, MString)
    )

  val cfgIsNullEmptyPs: List[MsilType] = newList()
  cfgIsNullEmptyPs.add(MString)
  val tokCfgIsNullOrEmpty = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trString,
      "IsNullOrEmpty",
      "cfg_isnullorempty",
      buildStaticMethodSig(cfgIsNullEmptyPs, MBool)
    )

  val twRet = MClassRef(typeRefCode = tdrTypeRef(trTextWriter), clrFqn = "System.IO.TextWriter")
  val tokCfgConsoleError = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trConsole,
      "get_Error",
      "cfg_console_error",
      buildStaticMethodSig(newList(), twRet)
    )

  val cfgTwWlPs: List[MsilType] = newList()
  cfgTwWlPs.add(MString)
  val tokCfgTwWriteLine = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trTextWriter,
      "WriteLine",
      "cfg_tw_writeline",
      buildInstanceMethodSig(cfgTwWlPs, MVoid)
    )

  val cfgExitPs: List[MsilType] = newList()
  cfgExitPs.add(MInt)
  val tokCfgEnvExit = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trEnvironment,
      "Exit",
      "cfg_env_exit",
      buildStaticMethodSig(cfgExitPs, MVoid)
    )

  val cfgInt32ParsePs: List[MsilType] = newList()
  cfgInt32ParsePs.add(MString)
  val tokCfgInt32Parse = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trInt32,
      "Parse",
      "cfg_int32_parse",
      buildStaticMethodSig(cfgInt32ParsePs, MInt)
    )

  val cfgBoolParsePs: List[MsilType] = newList()
  cfgBoolParsePs.add(MString)
  val tokCfgBoolParse = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trBoolean,
      "Parse",
      "cfg_bool_parse",
      buildStaticMethodSig(cfgBoolParsePs, MBool)
    )

  val cfgInt64ParsePs: List[MsilType] = newList()
  cfgInt64ParsePs.add(MString)
  val tokCfgInt64Parse = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trInt64,
      "Parse",
      "cfg_int64_parse",
      buildStaticMethodSig(cfgInt64ParsePs, MLong)
    )

  // Double.Parse(string, IFormatProvider): the .cctor loads InvariantCulture
  // (via tokInvariantCulture) before this call so Float/Double config fields
  // parse identically regardless of host locale (#2993).
  val cfgDoubleParsePs: List[MsilType] = newList()
  cfgDoubleParsePs.add(MString)
  cfgDoubleParsePs.add(MClassRef(typeRefCode = tdrTypeRef(trIFormatProvider), clrFqn = "System.IFormatProvider"))
  val tokCfgDoubleParse = 0x0A000000 +
    ctxAddMemberRef(
      lctx,
      trDouble,
      "Parse",
      "cfg_double_parse",
      buildStaticMethodSig(cfgDoubleParsePs, MDouble)
    )

  val recCtorToks: Map[String, Int] = newMap()
  val fieldToks: Map[String, Int] = newMap()
  val funcToks: Map[String, Int] = newMap()

  CodegenCtx(
    lctx = lctx,
    trConsole = trConsole,
    trString = trString,
    trInt32 = trInt32,
    trInt64 = trInt64,
    trDouble = trDouble,
    trBoolean = trBoolean,
    trChar = trChar,
    trByte = trByte,
    trException = trException,
    tokWriteLineStr = tokWLStr,
    tokWriteLineInt = tokWLInt,
    tokWriteLineLong = tokWLLong,
    tokWriteLineDbl = tokWLDbl,
    tokWriteLineBool = tokWLBool,
    tokWriteStr = tokWStr,
    tokConcat2 = tokConcat2,
    tokConcat3 = tokConcat3,
    tokExceptionCtor = tokExcCtor,
    tokInvalidOpExceptionCtor = tokInvalidOpExcCtor,
    tokStringFormat1 = tokFmt1,
    tokStringFormat2 = tokFmt2,
    tokStringFormat3 = tokFmt3,
    tokObjToString = tokObjToStr,
    tokExcGetMessage = tokExcGetMessage,
    tokObjGetType = tokObjGetType,
    tokTypeGetName = tokTypeGetName,
    tokInvariantCulture = tokInvariantCulture,
    tokDateTimeToStringO = tokDateTimeToStringO,
    usDateTimeFormatO = usDateTimeFormatO,
    tokDoubleToStringInv = tokDoubleToStringInv,
    tokListObjCtor = tokListObjCtor,
    tokListObjAdd = tokListObjAdd,
    tokListObjGetItem = tokListObjGetItem,
    tokListObjSetItem = tokListObjSetItem,
    tokListObjGetCount = tokListObjGetCount,
    tokListObjContains = tokListObjContains,
    tokListObjRemoveAt = tokListObjRemoveAt,
    tokListObjTypeSpec = 0x1B000000 + tsListObj,
    tokIListCast = tokIListCast,
    tokIListGetItem = tokIListGetItem,
    tokICollGetCount = tokICollGetCount,
    tokDictObjCtor = tokDictObjCtor,
    tokDictObjAdd = tokDictObjAdd,
    tokDictObjGetItem = tokDictObjGetItem,
    tokDictObjSetItem = tokDictObjSetItem,
    tokDictObjTypeSpec = 0x1B000000 + tsDictObj,
    tokDictObjGetCount = tokDictObjGetCount,
    tokDictObjContainsKey = tokDictObjContainsKey,
    tokDictObjRemove = tokDictObjRemove,
    tokDictObjTryGetValue = tokDictObjTryGetValue,
    recordCtorTokens = recCtorToks,
    distinctFromTokens = newMap(),
    distinctTryFromTokens = newMap(),
    distinctTryFromRetTypes = newMap(),
    fieldTokens = fieldToks,
    fieldSigBytes = newMap(),
    fieldDeclaredNames = newMap(),
    ctorDefaultExprs = newMap(),
    fieldVarIndices = newMap(),
    fieldMsilTypes = newMap(),
    funcTokens = funcToks,
    funcRetTypes = newMap(),
    funcParamTypes = newMap(),
    funcParamModes = newMap(),
    funcParamNames = newMap(),
    funcDefaultExprs = newMap(),
    // flat "fqn/paramN" → name
    funcParamFnInner = newMap(),
    lambdaParamTypes = newMap(),
    lambdaCaptureNames = newMap(),
    lambdaCaptureTypes = newMap(),
    lambdaCaptureCells = newMap(),
    constValues = newMap(),
    constBareClaimed = newMap(),
    enumTypeNames = newMap(),
    enumCaseOrdinals = newMap(),
    ffiAsmRefs = newMap(),
    ffiTypeRefs = newMap(),
    metadataTypeIndex = newMap(),
    metadataPathIndex = newMap(),
    metadataVtypeSet = newMap(),
    metadataReady = newList(),
    tokActionCtor = tokActionCtor,
    tokActionInvoke = tokActionInvoke,
    tokStringGetChars = tokStringGetChars,
    tokStringGetLength = tokStringGetLength,
    tokStringSubstring = tokStringSubstring,
    tokStringReplace = tokStringReplace,
    tokStringIsNormalized = tokStringIsNormalized,
    tokStringNormalize = tokStringNormalize,
    tokStringTrim = tokStringTrim,
    tokStringIndexOf = tokStringIndexOf,
    tokStringLastIndexOf = tokStringLastIndexOf,
    tokStringStartsWith = tokStringStartsWith,
    tokStringEndsWith = tokStringEndsWith,
    tokStringContains = tokStringContains,
    tokStringToLower = tokStringToLower,
    tokStringToUpper = tokStringToUpper,
    tokObjectStaticEquals = tokObjectStaticEquals,
    tokStringCompareOrdinal = tokStringCompareOrdinal,
    trTask = trTask,
    trTask1 = trTask1,
    tokTaskWait = tokTaskWait,
    fieldTokensByName = newMap(),
    fieldDeclaringClassByName = newMap(),
    actionTypeRefs = newMap(),
    externTypeNames = newMap(),
    lambdaTicker = newList(),
    methodTokens = newMap(),
    methodRetTypes = newMap(),
    methodParamTypes = newMap(),
    methodParamModes = newMap(),
    implEntries = newList(),
    nextMethodDefRow = newList(),
    nextFieldDefRow = newList(),
    mainEntryToken = newList(),
    pkgImports = newMap(),
    unionCaseCtorByName = newMap(),
    caseParentUnion = newMap(),
    typeFqnByName = newMap(),
    typeFqnCandidates = newMap(),
    caseTypeParamCount = newMap(),
    genericTypeArity = newMap(),
    genericCtorParams = newMap(),
    restoredArtifacts = restoredArtifacts,
    singletonFieldTokens = newMap(),
    staticValTokens = newMap(),
    staticValMsilTypes = newMap(),
    trAtmb = trAtmb,
    trAtmb1 = trAtmb1,
    trIAsm = trIAsm,
    tokAtmbCreate = tokAtmbCreate,
    tokAtmbSetResult = tokAtmbSetResult,
    tokAtmbGetTask = tokAtmbGetTask,
    tokAtmbStartMr = tokAtmbStartMr,
    trTaskAwaiter1 = trTaskAwaiter1,
    trTaskAwaiter = trTaskAwaiter,
    tokAtmbAwaitUnsafeMr = tokAtmbAwaitUnsafeMr,
    tokAtmb1AwaitUnsafeMr = tokAtmb1AwaitUnsafeMr,
    smTicker = newList(),
    trIAE1 = trIAE1,
    trIAET1 = trIAET1,
    trIAsyncDisp = trIAsyncDisp,
    trValueTask1 = trValueTask1,
    trValueTask = trValueTask,
    trCancToken = trCancToken,
    trTcs1 = trTcs1,
    genTicker = newList(),
    configFieldTokens = newMap(),
    configFieldMsilTypes = newMap(),
    tokCfgGetEnvVar = tokCfgGetEnvVar,
    tokCfgIsNullOrEmpty = tokCfgIsNullOrEmpty,
    tokCfgConsoleError = tokCfgConsoleError,
    tokCfgTwWriteLine = tokCfgTwWriteLine,
    tokCfgEnvExit = tokCfgEnvExit,
    tokCfgInt32Parse = tokCfgInt32Parse,
    tokCfgBoolParse = tokCfgBoolParse,
    tokCfgInt64Parse = tokCfgInt64Parse,
    tokCfgDoubleParse = tokCfgDoubleParse
  )
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
    val mty = match ret { case Some(te) -> typeExprToMsilCtx(cctx, te, pkgName); case None -> MVoid }
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

// Pre-populate lctx.allProjFqns with the FQNs of all @projectable opaque types
// declared across all bundle packages before any per-package addPackageTokens
// call.  This lets addPackageTokens detect cross-package nested projectable
// fields (i.e., a visible non-@projectionBoundary field whose type is a
// projectable from a different package in the same bundle), matching the check
// that lowerMOpaque uses via lctx.allProjFqns.
pub func prescanProjectableFqns(cctx: in CodegenCtx, files: in List[SourceFile], pkgNames: in List[String]): Unit {
  var i = 0
  while i < files.count {
    val file = files[i]
    val pkgName = pkgNames[i]
    var j = 0
    while j < file.items.count {
      match file.items[j].kind {
        case IOpaque(decl) -> {
          if decl.hasBody and hasAnnotationMsil(decl.annotations, "projectable") {
            val pfqn = pkgName + "." + decl.name
            if not cctx.lctx.allProjFqns.containsKey(pfqn) {
              cctx.lctx.allProjFqns.add(pfqn, true)
              cctx.lctx.allProjFqnKeys.add(pfqn)
            }
          }
        }
        case _ -> ()
      }
      j = j + 1
    }
    i = i + 1
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
// Register a Lyric enum's ordinal model (F#-emitter parity: enum values ARE
// I4 ordinals at the IL level).  The simple type name maps type positions to
// MInt in `typeExprToMsilCtx`; each case name maps to its declaration-order
// ordinal for expression references (`ldc.i4`) and `case X` pattern tests.
// Simple names are first-wins (cross-package collisions keep the first
// registration, like every other simple-name index here); the pkg-qualified
// form is always recorded.
pub func registerEnumDeclMsil(cctx: in CodegenCtx, pkgName: in String, decl: in EnumDecl): Unit {
  if not cctx.enumTypeNames.containsKey(decl.name) {
    cctx.enumTypeNames.add(decl.name, decl.cases.count)
  }
  var ei = 0
  while ei < decl.cases.count {
    val cn = decl.cases[ei].name
    if not cctx.enumCaseOrdinals.containsKey(cn) {
      cctx.enumCaseOrdinals.add(cn, ei)
    }
    val qn = pkgName + "." + cn
    if not cctx.enumCaseOrdinals.containsKey(qn) {
      cctx.enumCaseOrdinals.add(qn, ei)
    }
    // Type-scoped key `<EnumType>.<Case>` so a qualified `Enum.Case` reference
    // resolves the ordinal of the *named* enum even when two in-bundle enums
    // share a case name with different ordinals (#3346).
    val tn = decl.name + "." + cn
    if not cctx.enumCaseOrdinals.containsKey(tn) {
      cctx.enumCaseOrdinals.add(tn, ei)
    }
    ei = ei + 1
  }
}

pub func addPackageTokens(cctx: in CodegenCtx, file: in SourceFile, pkgName: in String): Unit {
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
  var fieldDefRow = cctx.nextFieldDefRow.count + 1

  // Threading `constEnv` lets `val b = a` (a literal val) stay literal; without it a phantom .cctor MethodDef row would shift every later IFunc token.
  // IConst names are registered too: a subsequent IVal `val b = SomeConst` can
  // then be recognised as literal without a .cctor row (#1508).
  val constEnv: Map[String, Bool] = newMap()
  var hasValCctor = false
  var pi = 0
  while pi < file.items.count {
    match file.items[pi].kind {
      case IConst(decl) -> {
        val isLit = isLiteralI4ExprMsilWithEnv(decl.init, constEnv)
        if not isLit {
          hasValCctor = true
        }
        // Claim with the RAW literal check — the emission side registers an
        // IConst's bare `constValues` name only in its raw-literal branch.
        if isLiteralI4ExprMsil(decl.init) and not cctx.constBareClaimed.containsKey(decl.name) {
          cctx.constBareClaimed.add(decl.name, true)
        }
        constEnv.add(decl.name, isLit)
      }
      case IVal(decl) -> {
        val isLit = isLiteralI4ExprMsilWithEnv(decl.init, constEnv)
        if not isLit {
          hasValCctor = true
        }
        match decl.pattern.kind {
          case PBinding(valName, _) -> {
            // A literal IVal whose BARE name was already claimed by an earlier
            // package loses the first-wins `constValues` slot at emission, so
            // its field keeps the .cctor init — predict the .cctor row here
            // too or every later MethodDef token shifts by one (#2628).
            if isLit {
              if cctx.constBareClaimed.containsKey(valName) {
                hasValCctor = true
              } else {
                cctx.constBareClaimed.add(valName, true)
              }
            }
            constEnv.add(valName, isLit)
          }
          case _ -> {
          }
        }  // non-simple bindings can't appear in EPath
      }
      case _ -> {
      }
    }
    pi = pi + 1
  }

  // Pre-scan: collect the FQNs of all @projectable opaque types declared in this
  // file so the IOpaque handler can determine hasNestedProjField (a visible
  // non-@projectionBoundary field of a projectable type suppresses tryInto()).
  // Uses pkgName + "." + decl.name as key, mirroring lowerMOpaque's check
  // against ctx.projectableToViewMDef.
  val projFqns: Map[String, Bool] = newMap()
  var projPrescan = 0
  while projPrescan < file.items.count {
    match file.items[projPrescan].kind {
      case IOpaque(decl) -> {
        if decl.hasBody and hasAnnotationMsil(decl.annotations, "projectable") {
          val pfqn = pkgName + "." + decl.name
          if not projFqns.containsKey(pfqn) {
            projFqns.add(pfqn, true)
          }
        }
      }
      case _ -> ()
    }
    projPrescan = projPrescan + 1
  }

  // Pass 1: source-order scan for non-IFunc items that emit MethodDef rows.
  // #878: collect impl-method (target, name) pairs in two parallel flat lists
  // so the per-record row budget includes the injected impl methods.  A flat
  // list avoids the Map[String,List[String]] + inner newList() pattern that the
  // F# bootstrap emitter does not support.
  val implImplTargets: List[String] = newList()
  val implImplNames: List[String] = newList()
  // Parallel to implImplNames: each impl method's declared return MsilType, so
  // the methodRetTypes registration below reports a real type to call sites
  // that dispatch on the concrete receiver (e.g. `self.save(updated)`) (#1602).
  val implImplRetTys: List[MsilType] = newList()
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
              implImplRetTys.add(match fn.ret { case Some(te) -> typeExprToMsilCtx(cctx, te, pkgName); case None -> MVoid })
              // Param types for the concrete-receiver dispatch key (#1784).
              registerMethodParamTypes(cctx, targetName + "/" + fn.name, fn.params, pkgName)
              // Param modes so a byref argument is passed by address (#1955).
              registerMethodParamModes(cctx, targetName + "/" + fn.name, fn.params)
            }
            case IMplAssoc(_) -> {
            }
          }
          imi = imi + 1
        }
      }
      case _ -> {
      }
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
        registerTypeFqnCandidate(cctx, decl.name, className)
        // In-bundle generic record support (#2362 / docs/43): a `value: T` field
        // is reified as VAR(n) rather than erased to object, so the field's
        // var-index, its FIELD VAR(n) signature, and the VAR-form ctor params are
        // registered for the construction / field-read routing.
        val recGenerics = genericNamesOf(decl.generics)
        val recCtorParams: List[MsilType] = newList()
        var fi = 0
        var fpos = 0
        while fi < decl.members.count {
          match decl.members[fi] {
            case RMField(f) -> {
              val tok = 0x04000000 + fieldDefRow
              cctx.fieldTokens.add(className + "/" + f.name, tok)
              if not cctx.fieldTokensByName.containsKey(pkgName + "/" + f.name) {
                cctx.fieldTokensByName.add(pkgName + "/" + f.name, tok)
                cctx.fieldDeclaringClassByName.add(pkgName + "/" + f.name, className)
              }
              // For a generic record, a field whose declared type is one of the
              // record's parameters lowers to the VAR form (MTypeVar); `ftyG`
              // exactly mirrors what `lowerMRecord` records as the field type and
              // the `.ctor` parameter, so the construction MemberRef signature
              // byte-matches the TypeDef ctor.  Concrete fields keep their
              // ctx-aware MSIL type for accurate (cross-package) field-read typing.
              val ftyG = typeExprToMsilG(cctx, f.ty, pkgName, recGenerics)
              val gIdx = match ftyG { case MTypeVar(ix) -> ix; case _ -> -1 }
              recCtorParams.add(ftyG)
              val fty = if gIdx >= 0 { ftyG } else { typeExprToMsilCtx(cctx, f.ty, pkgName) }
              if not cctx.fieldMsilTypes.containsKey(className + "/" + f.name) {
                cctx.fieldMsilTypes.add(className + "/" + f.name, fty)
              }
              // Also register under the short key used by the fieldTokensByName
              // lookup path so that field accesses on MObject (list elements)
              // return the correct MSIL type rather than falling back to MObject.
              if not cctx.fieldMsilTypes.containsKey(pkgName + "/" + f.name) {
                cctx.fieldMsilTypes.add(pkgName + "/" + f.name, fty)
              }
              if recGenerics.count > 0 {
                // For a generic record, EMember reads a field through a closed
                // GENERICINST TypeSpec via MLdfldGeneric, which needs the exact
                // FIELD signature: VAR(n) for a type-parameter field, the concrete
                // FIELD sig otherwise.  Register both the var-index (-1 = concrete)
                // and the signature under the by-name and positional keys (mirrors
                // the stdlib path in registerStdlibTypeItem).
                val fSig = if gIdx >= 0 { buildGenericParamFieldSig(gIdx) } else { buildFieldSig(fty) }
                cctx.fieldVarIndices.add(className + "/" + f.name, gIdx)
                cctx.fieldSigBytes.add(className + "/" + f.name, fSig)
                val byPosVarKey = className + "/field" + toString(fpos)
                cctx.fieldVarIndices.add(byPosVarKey, gIdx)
                cctx.fieldSigBytes.add(byPosVarKey, fSig)
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
              match f.dflt {
                case Some(dfltExpr) -> {
                  if not cctx.ctorDefaultExprs.containsKey(byPosKey) {
                    cctx.ctorDefaultExprs.add(byPosKey, dfltExpr)
                  }
                }
                case None -> ()
              }
              fpos = fpos + 1
              fieldDefRow = fieldDefRow + 1
            }
            case _ -> {
            }
          }
          fi = fi + 1
        }
        if recGenerics.count > 0 {
          if not cctx.genericTypeArity.containsKey(className) {
            cctx.genericTypeArity.add(className, recGenerics.count)
          }
          if not cctx.genericCtorParams.containsKey(className) {
            cctx.genericCtorParams.add(className, recCtorParams)
          }
        }
        cctx.recordCtorTokens.add(className, 0x06000000 + methodDefRow)
        methodDefRow = methodDefRow + 1
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case RMFunc(fn) -> {
              // Arity-qualified key guards against duplicate-key crashes and
              // makes overloaded-method lookup unambiguous (same pattern as
              // IFunc / registerStdlibFunc — arity key first, bare key as
              // first-overload fallback for call sites that don't arity-disambiguate).
              val rmArityKey = className + "/" + fn.name + "/" + toString(fn.params.count)
              val rmKey = className + "/" + fn.name
              if not cctx.methodTokens.containsKey(rmArityKey) {
                cctx.methodTokens.add(rmArityKey, 0x06000000 + methodDefRow)
                registerMethodRetTy(cctx, rmArityKey, fn.ret, pkgName)
                registerMethodParamTypes(cctx, rmArityKey, fn.params, pkgName)
                registerMethodParamModes(cctx, rmArityKey, fn.params)
                // Bare name: first overload wins so existing unqualified call sites work.
                if not cctx.methodTokens.containsKey(rmKey) {
                  cctx.methodTokens.add(rmKey, 0x06000000 + methodDefRow)
                  registerMethodRetTy(cctx, rmKey, fn.ret, pkgName)
                  registerMethodParamTypes(cctx, rmKey, fn.params, pkgName)
                  registerMethodParamModes(cctx, rmKey, fn.params)
                }
              }
              methodDefRow = methodDefRow + 1
            }
            case _ -> {
            }
          }
          mi = mi + 1
        }
        // Register impl-method tokens for this record (#878).
        var ni = 0
        while ni < implImplTargets.count {
          if implImplTargets[ni] == className {
            cctx.methodTokens.add(className + "/" + implImplNames[ni], 0x06000000 + methodDefRow)
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
        registerTypeFqnCandidate(cctx, decl.name, className)
        var fi = 0
        while fi < decl.members.count {
          match decl.members[fi] {
            case RMField(f) -> {
              val tok = 0x04000000 + fieldDefRow
              cctx.fieldTokens.add(className + "/" + f.name, tok)
              if not cctx.fieldTokensByName.containsKey(pkgName + "/" + f.name) {
                cctx.fieldTokensByName.add(pkgName + "/" + f.name, tok)
                cctx.fieldDeclaringClassByName.add(pkgName + "/" + f.name, className)
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
            case _ -> {
            }
          }
          fi = fi + 1
        }
        cctx.recordCtorTokens.add(className, 0x06000000 + methodDefRow)
        methodDefRow = methodDefRow + 1
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case RMFunc(fn) -> {
              // Arity-qualified key; see IRecord RMFunc above.
              val xrmArityKey = className + "/" + fn.name + "/" + toString(fn.params.count)
              val xrmKey = className + "/" + fn.name
              if not cctx.methodTokens.containsKey(xrmArityKey) {
                cctx.methodTokens.add(xrmArityKey, 0x06000000 + methodDefRow)
                registerMethodRetTy(cctx, xrmArityKey, fn.ret, pkgName)
                registerMethodParamTypes(cctx, xrmArityKey, fn.params, pkgName)
                registerMethodParamModes(cctx, xrmArityKey, fn.params)
                if not cctx.methodTokens.containsKey(xrmKey) {
                  cctx.methodTokens.add(xrmKey, 0x06000000 + methodDefRow)
                  registerMethodRetTy(cctx, xrmKey, fn.ret, pkgName)
                  registerMethodParamTypes(cctx, xrmKey, fn.params, pkgName)
                  registerMethodParamModes(cctx, xrmKey, fn.params)
                }
              }
              methodDefRow = methodDefRow + 1
            }
            case _ -> {
            }
          }
          mi = mi + 1
        }
        var ni = 0
        while ni < implImplTargets.count {
          if implImplTargets[ni] == className {
            cctx.methodTokens.add(className + "/" + implImplNames[ni], 0x06000000 + methodDefRow)
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
        registerTypeFqnCandidate(cctx, decl.name, unionFqn)
        // In-bundle generic union support (#2362): the union and every case are
        // reified, so register the union's arity (the cases share it).  A generic
        // nullary case is lowered as a zero-field generic record (plain `.ctor`,
        // no singleton) — see lowerMUnion — so the row accounting and the
        // singleton registration below branch on `uArity`.
        val uGenerics = genericNamesOf(decl.generics)
        val uArity = uGenerics.count
        if uArity > 0 and not cctx.genericTypeArity.containsKey(unionFqn) {
          cctx.genericTypeArity.add(unionFqn, uArity)
        }
        var ci = 0
        while ci < decl.cases.count {
          val c = decl.cases[ci]
          // #2363 Stage 4: case classes are named `Union_Case` (matching the F#
          // emitter), not `Union$Case`.  Record the parent union FQN so
          // construction sites recover it by lookup rather than splitting on `_`.
          val caseName = pkgName + "." + decl.name + "_" + c.name
          if not cctx.caseParentUnion.containsKey(caseName) {
            cctx.caseParentUnion.add(caseName, pkgName + "." + decl.name)
          }
          // VAR-form ctor parameter types for a generic case (mirrors the
          // generic-record registration): a type-parameter field lowers to
          // MTypeVar(n), everything else to its concrete MSIL type.
          val caseCtorParams: List[MsilType] = newList()
          var fi = 0
          while fi < c.fields.count {
            match c.fields[fi] {
              case UFNamed(name, ufTy, _) -> {
                cctx.fieldTokens.add(caseName + "/" + name, 0x04000000 + fieldDefRow)
                // Also register positional key so binding aliases work
                // (e.g. `case LSome(v)` where the field is named `value`).
                if not cctx.fieldTokens.containsKey(caseName + "/field" + toString(fi)) {
                  cctx.fieldTokens.add(caseName + "/field" + toString(fi), 0x04000000 + fieldDefRow)
                }
                val ftyG = typeExprToMsilG(cctx, ufTy, pkgName, uGenerics)
                val gIdx = match ftyG { case MTypeVar(ix) -> ix; case _ -> -1 }
                caseCtorParams.add(ftyG)
                val ufTyMsil = if gIdx >= 0 { ftyG } else { typeExprToMsilCtx(cctx, ufTy, pkgName) }
                if not cctx.fieldMsilTypes.containsKey(caseName + "/" + name) {
                  cctx.fieldMsilTypes.add(caseName + "/" + name, ufTyMsil)
                }
                if not cctx.fieldMsilTypes.containsKey(caseName + "/field" + toString(fi)) {
                  cctx.fieldMsilTypes.add(caseName + "/field" + toString(fi), ufTyMsil)
                }
                if uArity > 0 {
                  // FIELD VAR(n) for a type-parameter field, the concrete FIELD sig
                  // otherwise; consumed by the generic pattern-match field reads.
                  val fSig = if gIdx >= 0 { buildGenericParamFieldSig(gIdx) } else { buildFieldSig(ufTyMsil) }
                  cctx.fieldVarIndices.add(caseName + "/" + name, gIdx)
                  cctx.fieldSigBytes.add(caseName + "/" + name, fSig)
                  if not cctx.fieldVarIndices.containsKey(caseName + "/field" + toString(fi)) {
                    cctx.fieldVarIndices.add(caseName + "/field" + toString(fi), gIdx)
                    cctx.fieldSigBytes.add(caseName + "/field" + toString(fi), fSig)
                  }
                  if not cctx.fieldDeclaredNames.containsKey(caseName + "/field" + toString(fi)) {
                    cctx.fieldDeclaredNames.add(caseName + "/field" + toString(fi), name)
                  }
                }
                fieldDefRow = fieldDefRow + 1
              }
              case UFPos(ufPosTy, _) -> {
                cctx.fieldTokens.add(caseName + "/field" + toString(fi), 0x04000000 + fieldDefRow)
                val ftyGp = typeExprToMsilG(cctx, ufPosTy, pkgName, uGenerics)
                val gIdxP = match ftyGp { case MTypeVar(ix) -> ix; case _ -> -1 }
                caseCtorParams.add(ftyGp)
                val ufPosTyMsil = if gIdxP >= 0 { ftyGp } else { typeExprToMsilCtx(cctx, ufPosTy, pkgName) }
                if not cctx.fieldMsilTypes.containsKey(caseName + "/field" + toString(fi)) {
                  cctx.fieldMsilTypes.add(caseName + "/field" + toString(fi), ufPosTyMsil)
                }
                if uArity > 0 {
                  val fSigP = if gIdxP >= 0 { buildGenericParamFieldSig(gIdxP) } else { buildFieldSig(ufPosTyMsil) }
                  cctx.fieldVarIndices.add(caseName + "/field" + toString(fi), gIdxP)
                  cctx.fieldSigBytes.add(caseName + "/field" + toString(fi), fSigP)
                }
                fieldDefRow = fieldDefRow + 1
              }
            }
            fi = fi + 1
          }
          // Generic cases: register the arity (keyed by the case ctorKey, used by
          // the in-bundle construction helper) and the VAR-form ctor params.
          if uArity > 0 {
            if not cctx.genericTypeArity.containsKey(caseName) {
              cctx.genericTypeArity.add(caseName, uArity)
            }
            if not cctx.genericCtorParams.containsKey(caseName) {
              cctx.genericCtorParams.add(caseName, caseCtorParams)
            }
          }
          // A NON-generic nullary case gets an extra Instance FieldDef + .cctor
          // MethodDef (lowerMNullaryUnionCase) so construction can use ldsfld
          // (reference equality).  A GENERIC nullary case is a zero-field generic
          // record: plain `.ctor`, no Instance field, no .cctor, no singleton —
          // constructed via newobj each time (Q-GEN-001).
          if c.fields.count == 0 and uArity == 0 {
            cctx.singletonFieldTokens.add(caseName, 0x04000000 + fieldDefRow)
            fieldDefRow = fieldDefRow + 1  // Instance static field
          }
          cctx.recordCtorTokens.add(caseName, 0x06000000 + methodDefRow)
          // Index by simple case name for cross-package construction
          // (#1183 codegen port, multimap since #2899).  Allows a user
          // package to write `Some(value = X)` after `import Std.Core`
          // even though the case ctor lives under the imported package's
          // FQN.  All same-named cases from different unions are stored;
          // `pickCaseFqnByScope` disambiguates at the call site.
          if cctx.unionCaseCtorByName.containsKey(c.name) {
            match mapGet(cctx.unionCaseCtorByName, c.name) {
              case Some(lst) -> {
                if not lst.contains(caseName) {
                  lst.add(caseName)
                }
              }
              case None -> ()
            }
          } else {
            val caseNameList1: List[String] = newList()
            caseNameList1.add(caseName)
            cctx.unionCaseCtorByName.add(c.name, caseNameList1)
          }
          methodDefRow = methodDefRow + 1  // .ctor
          if c.fields.count == 0 and uArity == 0 {
            methodDefRow = methodDefRow + 1  // .cctor (non-generic nullary only)
          }
          ci = ci + 1
        }
      }
      case IInterface(decl) -> {
        // lowerMInterface: one MethodDef per IMSig (abstract) and per IMFunc
        // (concrete DIM body).  Token layout is the same (1 row each) regardless
        // of whether the body is abstract or concrete.  Register each slot in
        // `methodTokens` so callvirt against an interface-typed receiver dispatches
        // through the correct interface vtable slot (#878).
        val ifaceName = pkgName + "." + decl.name
        registerTypeFqnCandidate(cctx, decl.name, ifaceName)
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case IMSig(sig) -> {
              // Arity-qualified key; see IRecord RMFunc above.
              val imsArityKey = ifaceName + "/" + sig.name + "/" + toString(sig.params.count)
              val imsKey = ifaceName + "/" + sig.name
              if not cctx.methodTokens.containsKey(imsArityKey) {
                cctx.methodTokens.add(imsArityKey, 0x06000000 + methodDefRow)
                registerMethodRetTy(cctx, imsArityKey, sig.ret, pkgName)
                registerMethodParamTypes(cctx, imsArityKey, sig.params, pkgName)
                registerMethodParamModes(cctx, imsArityKey, sig.params)
                if not cctx.methodTokens.containsKey(imsKey) {
                  cctx.methodTokens.add(imsKey, 0x06000000 + methodDefRow)
                  registerMethodRetTy(cctx, imsKey, sig.ret, pkgName)
                  registerMethodParamTypes(cctx, imsKey, sig.params, pkgName)
                  registerMethodParamModes(cctx, imsKey, sig.params)
                }
              }
              methodDefRow = methodDefRow + 1
            }
            case IMFunc(fn) -> {
              // Arity-qualified key; see IRecord RMFunc above.
              val imfArityKey = ifaceName + "/" + fn.name + "/" + toString(fn.params.count)
              val imfKey = ifaceName + "/" + fn.name
              if not cctx.methodTokens.containsKey(imfArityKey) {
                cctx.methodTokens.add(imfArityKey, 0x06000000 + methodDefRow)
                registerMethodRetTy(cctx, imfArityKey, fn.ret, pkgName)
                registerMethodParamTypes(cctx, imfArityKey, fn.params, pkgName)
                registerMethodParamModes(cctx, imfArityKey, fn.params)
                if not cctx.methodTokens.containsKey(imfKey) {
                  cctx.methodTokens.add(imfKey, 0x06000000 + methodDefRow)
                  registerMethodRetTy(cctx, imfKey, fn.ret, pkgName)
                  registerMethodParamTypes(cctx, imfKey, fn.params, pkgName)
                  registerMethodParamModes(cctx, imfKey, fn.params)
                }
              }
              methodDefRow = methodDefRow + 1
            }
            case IMAssoc(_) -> {
            }
          }
          mi = mi + 1
        }
      }
      case IOpaque(decl) -> {
        // Token pre-allocation mirrors lowerMOpaque in lowering.l (func lowerMOpaque,
        // ~line 4000).  The MethodDef row numbers assigned here MUST stay in lock-step
        // with lowerMOpaque's emission order: Phase 1 (view fields + view .ctor +
        // tryInto) before Phase 2 (opaque fields + opaque .ctor + toView).  Any future
        // change to lowerMOpaque's method order must be mirrored here or the CLR will
        // resolve callvirt slots to the wrong MethodDef (#3046).
        //
        // Non-@projectable types emit only: opaque FieldDef ×N, opaque .ctor.
        if decl.hasBody {
          val className = pkgName + "." + decl.name
          val isProj = hasAnnotationMsil(decl.annotations, "projectable")
          if isProj {
            val viewSimpleName = decl.name + "View"
            val viewFqn = pkgName + "." + viewSimpleName
            // Register view type name so resolveTypeFqn finds <Name>View references.
            registerTypeFqnCandidate(cctx, viewSimpleName, viewFqn)
            // Phase 1: view FieldDef rows (visible fields only) + view .ctor + tryInto().
            // Mirrors lowerMOpaque's Phase 1 exactly, including token registration.
            var hasHiddenProj = false
            var hasNestedProjField = false
            var vfi = 0
            while vfi < decl.members.count {
              match decl.members[vfi] {
                case OMField(f) -> {
                  if hasAnnotationMsil(f.annotations, "hidden") {
                    hasHiddenProj = true
                  } else {
                    // hasNestedProjField: visible non-@projectionBoundary field whose
                    // type is another projectable type → tryInto() is suppressed.
                    // Checks projFqns (current file) AND cctx.lctx.allProjFqns
                    // (all bundle packages, pre-seeded by prescanProjectableFqns)
                    // so cross-package nested projectables are detected correctly.
                    val isBoundary = hasAnnotationMsil(f.annotations, "projectionBoundary")
                    val fMsilTy = typeExprToMsilCtx(cctx, f.ty, pkgName)
                    if not isBoundary {
                      match fMsilTy {
                        case MClass(srcFqn) -> {
                          if projFqns.containsKey(srcFqn) or cctx.lctx.allProjFqns.containsKey(srcFqn) {
                            hasNestedProjField = true
                          }
                        }
                        case _ -> ()
                      }
                    }
                    // View field type: projectable non-boundary → <FType>View; else original.
                    val viewFieldTy = if not isBoundary {
                      match fMsilTy {
                        case MClass(srcFqn2) -> {
                          if projFqns.containsKey(srcFqn2) or cctx.lctx.allProjFqns.containsKey(srcFqn2) {
                            MClass(className = srcFqn2 + "View")
                          } else {
                            fMsilTy
                          }
                        }
                        case _ -> fMsilTy
                      }
                    } else {
                      fMsilTy
                    }
                    // Register view field token and MSIL type for EMember dispatch.
                    val vfKey = viewFqn + "/" + f.name
                    if not cctx.fieldTokens.containsKey(vfKey) {
                      cctx.fieldTokens.add(vfKey, 0x04000000 + fieldDefRow)
                    }
                    if not cctx.fieldMsilTypes.containsKey(vfKey) {
                      cctx.fieldMsilTypes.add(vfKey, viewFieldTy)
                    }
                    fieldDefRow = fieldDefRow + 1
                  }
                }
                case _ -> ()
              }
              vfi = vfi + 1
            }
            // view .ctor token (registered before increment, matching lowerMOpaque row).
            if not cctx.recordCtorTokens.containsKey(viewFqn) {
              cctx.recordCtorTokens.add(viewFqn, 0x06000000 + methodDefRow)
            }
            methodDefRow = methodDefRow + 1  // view .ctor
            // tryInto() eligibility mirrors lowerMOpaque exactly (including the
            // isDiscover branch that always emits a stub in the discover pass).
            if not hasHiddenProj and not hasNestedProjField and cctx.lctx.stdCoreResultOk2Row.count > 0 and cctx.lctx.stdCoreResultRow.count > 0 {
              val tryIntoKey = viewFqn + "/tryInto"
              if not cctx.methodTokens.containsKey(tryIntoKey) {
                cctx.methodTokens.add(tryIntoKey, 0x06000000 + methodDefRow)
              }
              if not cctx.methodRetTypes.containsKey(tryIntoKey) {
                val triRetArgs: List[MsilType] = newList()
                triRetArgs.add(MClass(className = className))
                triRetArgs.add(MString)
                // typeRefCode uses stdCoreResultRow[0]: both stdCoreResultOk2Row and
                // stdCoreResultRow are non-empty, checked independently by the enclosing guard.
                cctx.methodRetTypes.add(
                  tryIntoKey,
                  MGenericInst(
                    typeRefCode = tdrTypeRef(cctx.lctx.stdCoreResultRow[0]),
                    headFqn = "Std.Core.Result",
                    typeArgs = triRetArgs
                  )
                )
              }
              methodDefRow = methodDefRow + 1  // tryInto()
            }
          }
          // Phase 2: opaque FieldDef + opaque .ctor (+ toView for projectable types).
          // Register opaque field tokens so same-package ldfld (e.g. via a
          // @projectionBoundary view field returning the raw opaque) resolves correctly.
          var fi = 0
          while fi < decl.members.count {
            match decl.members[fi] {
              case OMField(f2) -> {
                val ofKey = className + "/" + f2.name
                val ofTok = 0x04000000 + fieldDefRow
                if not cctx.fieldTokens.containsKey(ofKey) {
                  cctx.fieldTokens.add(ofKey, ofTok)
                }
                val ofTy = typeExprToMsilCtx(cctx, f2.ty, pkgName)
                if not cctx.fieldMsilTypes.containsKey(ofKey) {
                  cctx.fieldMsilTypes.add(ofKey, ofTy)
                }
                // Also register under the package-level reverse-lookup key so that
                // MObject-typed receivers (e.g. a match binding on `tryInto()`'s Ok
                // result) can emit ldfld via the fieldTokensByName fallback path.
                val ofByNameKey = pkgName + "/" + f2.name
                if not cctx.fieldTokensByName.containsKey(ofByNameKey) {
                  cctx.fieldTokensByName.add(ofByNameKey, ofTok)
                  cctx.fieldDeclaringClassByName.add(ofByNameKey, className)
                }
                if not cctx.fieldMsilTypes.containsKey(ofByNameKey) {
                  cctx.fieldMsilTypes.add(ofByNameKey, ofTy)
                }
                fieldDefRow = fieldDefRow + 1
              }
              case OMInvariant(_) -> {
              }
            }
            fi = fi + 1
          }
          cctx.recordCtorTokens.add(className, 0x06000000 + methodDefRow)
          methodDefRow = methodDefRow + 1  // opaque .ctor
          if isProj {
            // toView() on the opaque type; return type is the view class.
            val viewFqn2 = pkgName + "." + decl.name + "View"
            val toViewKey = className + "/toView"
            if not cctx.methodTokens.containsKey(toViewKey) {
              cctx.methodTokens.add(toViewKey, 0x06000000 + methodDefRow)
            }
            if not cctx.methodRetTypes.containsKey(toViewKey) {
              cctx.methodRetTypes.add(toViewKey, MClass(className = viewFqn2))
            }
            methodDefRow = methodDefRow + 1  // toView()
          }
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
            case PMField(pf) -> {
              val fieldTok = 0x04000000 + fieldDefRow
              match pf {
                case PFVar(fname, fty, _, _) -> {
                  val fKey = className + "/" + fname
                  if not cctx.fieldTokens.containsKey(fKey) {
                    cctx.fieldTokens.add(fKey, fieldTok)
                    cctx.fieldMsilTypes.add(fKey, typeExprToMsilCtx(cctx, fty, pkgName))
                  }
                  if not cctx.fieldTokensByName.containsKey(pkgName + "/" + fname) {
                    cctx.fieldTokensByName.add(pkgName + "/" + fname, fieldTok)
                    cctx.fieldDeclaringClassByName.add(pkgName + "/" + fname, className)
                  }
                }
                case PFLet(fname, fty, _, _) -> {
                  val fKey = className + "/" + fname
                  if not cctx.fieldTokens.containsKey(fKey) {
                    cctx.fieldTokens.add(fKey, fieldTok)
                    cctx.fieldMsilTypes.add(fKey, typeExprToMsilCtx(cctx, fty, pkgName))
                  }
                  if not cctx.fieldTokensByName.containsKey(pkgName + "/" + fname) {
                    cctx.fieldTokensByName.add(pkgName + "/" + fname, fieldTok)
                    cctx.fieldDeclaringClassByName.add(pkgName + "/" + fname, className)
                  }
                }
                case PFImmutable(f) -> {
                  val fKey = className + "/" + f.name
                  if not cctx.fieldTokens.containsKey(fKey) {
                    cctx.fieldTokens.add(fKey, fieldTok)
                    cctx.fieldMsilTypes.add(fKey, typeExprToMsilCtx(cctx, f.ty, pkgName))
                  }
                  if not cctx.fieldTokensByName.containsKey(pkgName + "/" + f.name) {
                    cctx.fieldTokensByName.add(pkgName + "/" + f.name, fieldTok)
                    cctx.fieldDeclaringClassByName.add(pkgName + "/" + f.name, className)
                  }
                }
              }
              fieldDefRow = fieldDefRow + 1
            }
            case _ -> {
            }
          }
          fi = fi + 1
        }
        cctx.recordCtorTokens.add(className, 0x06000000 + methodDefRow)
        methodDefRow = methodDefRow + 1
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case PMEntry(ed) -> {
              val pmKey = className + "/" + ed.name
              if not cctx.methodTokens.containsKey(pmKey) {
                cctx.methodTokens.add(pmKey, 0x06000000 + methodDefRow)
                registerMethodRetTy(cctx, pmKey, ed.ret, pkgName)
                registerMethodParamTypes(cctx, pmKey, ed.params, pkgName)
                registerMethodParamModes(cctx, pmKey, ed.params)
              }
              methodDefRow = methodDefRow + 1
            }
            case PMFunc(fn) -> {
              val pmKey = className + "/" + fn.name
              if not cctx.methodTokens.containsKey(pmKey) {
                cctx.methodTokens.add(pmKey, 0x06000000 + methodDefRow)
                registerMethodRetTy(cctx, pmKey, fn.ret, pkgName)
                registerMethodParamTypes(cctx, pmKey, fn.params, pkgName)
                registerMethodParamModes(cctx, pmKey, fn.params)
              }
              methodDefRow = methodDefRow + 1
            }
            case _ -> {
            }
          }
          mi = mi + 1
        }
      }
      // IDistinctType: lowerMDistinctType synthesises a sealed type with one
      // `value` field and the construction API — `.ctor(value)`, static `from`,
      // static `tryFrom` (when Result is imported), and an inherent `toX`
      // projection (#1501).  Reserve those rows AND register the tokens so
      // member access (`self.value`), construction (`Score(42)`), and the
      // `TypeName.from`/`TypeName.tryFrom`/`v.toInt()` call sites resolve.
      // The emission order here MUST match `lowerMDistinctType`.
      case IDistinctType(decl) -> {
        val className = pkgName + "." + decl.name
        registerTypeFqnCandidate(cctx, decl.name, className)
        val valueTok = 0x04000000 + fieldDefRow
        if not cctx.fieldTokens.containsKey(className + "/value") {
          cctx.fieldTokens.add(className + "/value", valueTok)
        }
        val innerTy = typeExprToMsilCtx(cctx, decl.underlying, pkgName)
        if not cctx.fieldMsilTypes.containsKey(className + "/value") {
          cctx.fieldMsilTypes.add(className + "/value", innerTy)
        }
        fieldDefRow = fieldDefRow + 1
        // Method 0: .ctor
        if not cctx.recordCtorTokens.containsKey(className) {
          cctx.recordCtorTokens.add(className, 0x06000000 + methodDefRow)
        }
        methodDefRow = methodDefRow + 1
        // Method 1: static from
        if not cctx.distinctFromTokens.containsKey(className) {
          cctx.distinctFromTokens.add(className, 0x06000000 + methodDefRow)
        }
        methodDefRow = methodDefRow + 1
        // Method 2: static tryFrom (only when Result Ok/Err/base are seeded).
        val hasTryFrom = cctx.lctx.stdCoreResultOk2Row.count > 0 and cctx.lctx.stdCoreResultErr2Row.count > 0 and
          cctx.lctx.stdCoreResultRow.count > 0
        if hasTryFrom {
          if not cctx.distinctTryFromTokens.containsKey(className) {
            cctx.distinctTryFromTokens.add(className, 0x06000000 + methodDefRow)
            val triArgs: List[MsilType] = newList()
            triArgs.add(MClass(className = className))
            triArgs.add(MString)
            // typeRefCode comes from stdCoreResultRow[0] (guaranteed non-empty by
            // hasTryFrom guard above) so callers that inspect this MGenericInst for
            // TypeSpec construction get a valid IL token, not a zero sentinel.
            cctx.distinctTryFromRetTypes.add(
              className,
              MGenericInst(
                typeRefCode = tdrTypeRef(cctx.lctx.stdCoreResultRow[0]),
                headFqn = "Std.Core.Result",
                typeArgs = triArgs
              )
            )
          }
          methodDefRow = methodDefRow + 1
        }
        // Method 3: inherent toX projection (instance dispatch via methodTokens).
        val convName = distinctConvName(innerTy)
        if convName.length > 0 {
          val convKey = className + "/" + convName
          if not cctx.methodTokens.containsKey(convKey) {
            cctx.methodTokens.add(convKey, 0x06000000 + methodDefRow)
            cctx.methodRetTypes.add(convKey, innerTy)
          }
          methodDefRow = methodDefRow + 1
        }
      }
      case IConfig(decl) -> {
        // Config block: N FieldDef rows (one per field) + 1 MethodDef row (.cctor),
        // emitted as MPConfig before MPFuncs so the row budget matches source order.
        var cfi = 0
        while cfi < decl.fields.count {
          val cfKey = decl.name + "/" + decl.fields[cfi].name
          val fieldTok = 0x04000000 + fieldDefRow
          if not cctx.configFieldTokens.containsKey(cfKey) {
            cctx.configFieldTokens.add(cfKey, fieldTok)
          }
          val cfTy = typeExprToMsilCtx(cctx, decl.fields[cfi].ty, pkgName)
          if not cctx.configFieldMsilTypes.containsKey(cfKey) {
            cctx.configFieldMsilTypes.add(cfKey, cfTy)
          }
          fieldDefRow = fieldDefRow + 1
          cfi = cfi + 1
        }
        // .cctor is emitted only when the block has at least one field.
        if decl.fields.count > 0 {
          methodDefRow = methodDefRow + 1
        }
      }
      // lowerMEnum: one `value__` FieldDef + one static literal FieldDef per
      // case; no MethodDef rows.  Without this arm every FieldDef token
      // predicted for items AFTER an enum in the same package was off by
      // (1 + cases.count), so e.g. a following record's `ldfld` bound the
      // enum's `value__` row instead of the record field — rejected by the
      // JIT as an invalid program (#3196, Std.Log's LogLevel + LogField).
      // Deliberately NOT registered in typeFqnByName: enum values are I4
      // ordinals, never CLASS-typed references (see registerEnumDeclMsil).
      case IEnum(decl) -> {
        registerEnumDeclMsil(cctx, pkgName, decl)
        fieldDefRow = fieldDefRow + 1 + decl.cases.count
      }
      // IRangeType, IImpl: 0 MethodDef rows in non-MPFuncs.
      // IConst, IVal, IFunc: handled below (go to MPFuncs, emitted last).
      case _ -> {
      }
    }
    i = i + 1
  }

  // Pass 1b: MPFuncs static fields — IConst and non-literal IVal items emit
  // FieldDef rows into the host class (after all type FieldDef rows from Pass 1).
  // Record the token for each non-literal IVal (and non-literal IConst) so
  // `EPath` can emit `ldsfld` (#1508: non-Int constants need ldsfld, not ldc.i4).
  var pv = 0
  while pv < file.items.count {
    match file.items[pv].kind {
      case IConst(decl) -> {
        val isLit = isLiteralI4ExprMsilWithEnv(decl.init, constEnv)
        if not isLit {
          val fieldTok = 0x04000000 + fieldDefRow
          val constTy = typeExprToMsilCtx(cctx, decl.ty, pkgName)
          cctx.staticValTokens.add(decl.name, fieldTok)
          cctx.staticValMsilTypes.add(decl.name, constTy)
        }
        fieldDefRow = fieldDefRow + 1
      }
      case IVal(decl) -> {
        // Package-scope destructuring (e.g. `val (a, b) = f()`) is not supported
        // by the type checker or parser: only PBinding patterns are accepted at
        // item scope.  The `_` branch is therefore unreachable; it emits a
        // synthetic name to avoid a row-count mismatch if the invariant is ever
        // violated.  Each IVal item allocates exactly one FieldDef row.
        val valName = match decl.pattern.kind { case PBinding(n, _) -> n; case _ -> "__val_" + toString(fieldDefRow) }
        val isLit = isLiteralI4ExprMsilWithEnv(decl.init, constEnv)
        if not isLit {
          val fieldTok = 0x04000000 + fieldDefRow
          val valTy = match decl.ty { case Some(te) -> typeExprToMsilCtx(cctx, te, pkgName); case None -> MObject }
          cctx.staticValTokens.add(valName, fieldTok)
          cctx.staticValMsilTypes.add(valName, valTy)
        }
        fieldDefRow = fieldDefRow + 1
      }
      case _ -> {
      }
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
        if decl.isAsync and not funcBodyContainsYieldMsil(decl) and not hasExternTargetMsil(decl.annotations) {
          smClassCountPts = smClassCountPts + 1
        }
      }
      case _ -> {
      }
    }
    smkPts = smkPts + 1
  }
  methodDefRow = methodDefRow + smClassCountPts * 3
  // Reserve MethodDef rows for synthesised generator classes (Phase 5, Epic #2070).
  // Each async generator contributes 6 rows before MPFuncs:
  //   .ctor (useDefaultCtor), MoveNext, SetStateMachine, GetAsyncEnumerator, MoveNextAsync, get_Current, DisposeAsync.
  //
  // Ordering note (#2466): this pre-scan reserves ALL SM rows then ALL generator rows,
  // but codegenMPackage emits SM and generator MPRecord items in source-declaration order
  // (interleaved).  The ordering mismatch is safe because addPackageTokens never assigns
  // specific MethodDef tokens to individual SM/generator class methods — it only advances
  // methodDefRow by the total count (smClassCount*3 + genClassCount*6) so that the
  // IFunc kickoff token assignments start at the correct offset.  lowerMPackageWithCtx
  // assigns the actual SM/generator method rows in the order it encounters MPRecord items,
  // which is source order; the total reserved count is identical regardless of SM vs
  // generator interleaving, so IFunc token assignments are unaffected.
  var genClassCountPts = 0
  var gkPts = 0
  while gkPts < file.items.count {
    match file.items[gkPts].kind {
      case IFunc(decl) -> {
        if decl.isAsync and funcBodyContainsYieldMsil(decl) {
          genClassCountPts = genClassCountPts + 1
        }
      }
      case _ -> {
      }
    }
    gkPts = gkPts + 1
  }
  // 7 methods: .ctor, MoveNext, SetStateMachine, GetAsyncEnumerator, MoveNextAsync,
  //            get_Current, DisposeAsync.
  methodDefRow = methodDefRow + genClassCountPts * 7
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
        // Generator functions return IAsyncEnumerable<object> (the synthesised generator
        // class, erased to MIAsyncEnumerable(MObject) in funcRetTypes so that
        // emitCollectionForMsil can dispatch to the async-enumerator protocol rather than
        // the List<object> index-loop protocol.
        val isGen = decl.isAsync and funcBodyContainsYieldMsil(decl)
        val isSm = decl.isAsync and not isGen and not hasExternTargetMsil(decl.annotations)
        // Hoisted so both return-type and param-type lowering share the same
        // computation (#2597: removed the duplicate declGenericsP).
        val declGenerics = genericNamesOf(decl.generics)
        val retTy = if isGen {
          val genElemTy = match decl.ret { case Some(te) -> typeExprToMsilCtx(cctx, te, pkgName); case None -> MObject }
          MIAsyncEnumerable(elemTy = genElemTy)
        } else if isSm {
          // SM kickoffs return Task<T> or Task, not the bare T.  Call sites that
          // await the kickoff resolve via funcRetTypes — the EAwait handler then
          // unwraps the Task to T via GetAwaiter+GetResult.
          val bareRetTy = match decl.ret {
            case Some(te) -> {
              val r = typeExprToMsilCtx(cctx, te, pkgName)
              if elementTypeByte(r) == 0 {
                MVoid
              } else {
                r
              }
            }
            case None -> MVoid
          }
          if bareRetTy == MVoid {
            MClassRef(typeRefCode = tdrTypeRef(cctx.trTask), clrFqn = "System.Threading.Tasks.Task")
          } else {
            val kfRetArgs: List[MsilType] = newList()
            kfRetArgs.add(bareRetTy)
            MGenericInst(typeRefCode = tdrTypeRef(cctx.trTask1), headFqn = "System.Threading.Tasks.Task`1", typeArgs = kfRetArgs)
          }
        } else if startsWith(decl.name, "__lambda_") {
          // For synthetic lambdas: the return type was set during lambda lifting based on
          // whether the body ends with an expression (implicit return) or not.
          // If ret is Some(...), use that; otherwise default to MVoid.
          match decl.ret {
            case Some(te) -> typeExprToMsilCtx(cctx, te, pkgName)
            case None -> MVoid
          }
        } else {
          // A generic function's `slice[T]` / bare-`T` return is List-backed at
          // run time (#2557): the caller must track it as `MArray(MObject)` (so
          // `.length` / indexing route through the IList slice path) or `MObject`
          // (a bare erased element), never as `MClass(pkg + ".T")` which names no
          // real CLR type and would emit a faulting `castclass`.
          // declGenerics is hoisted above retTy and shared with the param loop.
          match decl.ret {
            case Some(te) -> {
              if declGenerics.count > 0 {
                typeExprToMsilGenBody(cctx, te, pkgName, declGenerics)
              } else {
                typeExprToMsilCtx(cctx, te, pkgName)
              }
            }
            case None -> MVoid
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
        // A generic function's `slice[T]` / bare-`T` parameter is recorded in the
        // erased List-backed form (#2557) so the call-site collExpect builds a
        // List-backed argument, matching the erased parameter slot.
        // declGenerics (computed above for the return type) covers the same decl,
        // so we reuse it here (#2597: no need for a separate declGenericsP).
        val paramTys: List[MsilType] = newList()
        var ppi = 0
        while ppi < decl.params.count {
          if declGenerics.count > 0 {
            paramTys.add(typeExprToMsilGenBody(cctx, decl.params[ppi].ty, pkgName, declGenerics))
          } else {
            paramTys.add(typeExprToMsilCtx(cctx, decl.params[ppi].ty, pkgName))
          }
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
              if not cctx.funcParamFnInner.containsKey(aKey) {
                cctx.funcParamFnInner.add(aKey, inner)
              }
              if not cctx.funcParamFnInner.containsKey(fKey) {
                cctx.funcParamFnInner.add(fKey, inner)
              }
            }
            case _ -> {
            }
          }
          pfi = pfi + 1
        }
        val paramModes: List[ParamMode] = newList()
        var pmi = 0
        while pmi < decl.params.count {
          paramModes.add(decl.params[pmi].mode)
          // Flat-encode parameter names to allow both FQN and arity-suffix lookups.
          // Key: "<fqn>/param<i>" and "<arityKey>/param<i>".
          val pnKey = fqn + "/param" + toString(pmi)
          val pnKeyA = arityKey + "/param" + toString(pmi)
          if not cctx.funcParamNames.containsKey(pnKey) {
            cctx.funcParamNames.add(pnKey, decl.params[pmi].name)
          }
          if not cctx.funcParamNames.containsKey(pnKeyA) {
            cctx.funcParamNames.add(pnKeyA, decl.params[pmi].name)
          }
          match decl.params[pmi].dflt {
            case Some(dfltExpr) -> {
              if not cctx.funcDefaultExprs.containsKey(pnKey) {
                cctx.funcDefaultExprs.add(pnKey, dfltExpr)
              }
              if not cctx.funcDefaultExprs.containsKey(pnKeyA) {
                cctx.funcDefaultExprs.add(pnKeyA, dfltExpr)
              }
            }
            case None -> ()
          }
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
      // IWire emits exactly one static factory method (<name>_create) in MPFuncs.
      // Reserve its MethodDef row so subsequent IFunc token assignments remain correct.
      case IWire(_) -> {
        methodDefRow = methodDefRow + 1
      }
      case _ -> {
      }
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
    case ELiteral(lit) -> match lit { case LInt(v, suffix, _) -> match suffix { case I64 | U64 -> false; case _ -> v >= -2147483648i64 and v <= 2147483647i64 }; case LBool(_) -> true; case LChar(_) -> true; case LUnit -> true; case _ -> false }  // 0 insns emitted; no .cctor needed
    case EParen(inner) -> isLiteralI4ExprMsilWithEnv(inner, env)
    case EPath(path) -> {
      if path.segments.count == 1 and env.containsKey(path.segments[0]) {
        match mapGet(env, path.segments[0]) {
          case Some(b) -> b
          case None -> false
        }
      } else {
        false
      }
    }
    case _ -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Per-function codegen context.
// ─────────────────────────────────────────────────────────────────────────────
// FuncCtx threads mutable state through expression and statement lowering.
// Parameters and locals share the `slots` map but use different namespaces:
//   • params: slots 0..paramCount-1, accessed via MLdarg(slot)
// ─────────────────────────────────────────────────────────────────────────────
// Lazy generator state-machine context (#1490).
// Installed in FuncCtx.lazyGenCtx (singleton) while synthesizeGeneratorMsil
// is lowering the MoveNext body.  The EYield handler uses it to emit the
// lazy TCS-based suspend protocol instead of eager list appends.
// ─────────────────────────────────────────────────────────────────────────────
pub record LazyGenCtx {
  genFqn: String  // FQN of the generator sealed class
  resumeLabels: List[Int]  // pre-allocated label ID per yield site (index = state N − 1)
  nextYieldIndex: List[Int]  // length = next yield index (list-as-counter)
  leaveLabel: Int  // label to MLeave to after each yield (the after-try label)
  tokTcsSetResult: Int  // 0x0A000000 | MemberRef row for TCS<bool>::SetResult(bool)
  tokTcsSetException: Int  // 0x0A000000 | MemberRef row for TCS<bool>::SetException(Exception)
  tcsTypeSpecToken: Int  // 0x1B000000 | TypeSpec row for TCS<bool> (for castclass)
}

// Phase B.1 async state machine context.
// Installed in FuncCtx.phaseBCtx (singleton) while synthesiseAsyncSmPhaseBMsil
// is lowering the MoveNext body.  The EAwait handler checks this to switch from
// the blocking shim to the real suspend/resume protocol.
// ─────────────────────────────────────────────────────────────────────────────
pub record PhaseBCtx {
  smFqn: String  // FQN of the enclosing SM sealed class
  resumeLabels: List[Int]  // pre-allocated label ID per await site (index = state N)
  suspendLeaveLabel: Int  // label to Leave to after AwaitUnsafeOnCompleted
  nextAwaitIndex: List[Int]  // length = next await index (list-as-counter)
  awaiterFieldNames: List[String]  // "__awN" per state index (parallel to resumeLabels)
  isVoid: Bool  // true when SM returns void (no result from GetResult)
  retTy: MsilType  // bare return type (MVoid when isVoid)
  atmbMrRowForAwait: Int  // open MemberRef row for AwaitUnsafeOnCompleted
  // Promoted locals: val-bindings hoisted to SM fields so they survive suspension.
  // Populated on-the-fly as LBLet bindings are encountered during body lowering;
  // `emitPhaseBAwait` reads the current list when emitting each resume label so
  // every local defined before that await point is reloaded on the resume path.
  smFields: List[MField]  // reference to the SM class field list
  promotedLocalNames: List[String]  // val name → SM field "__local_<name>"
  promotedLocalSlots: List[Int]  // local-relative slot index (slot - paramCount)
  promotedLocalTypes: List[MsilType]
  // type of the promoted local (parallel)
}

pub record FuncCtx {
  pkgName: String
  className: String
  funcName: String
  slots: Map[String, Int]
  types: Map[String, MsilType]
  //   • locals: slots paramCount.., accessed via MLdloc(slot - paramCount)
  // `locals` records MsilType entries in order for MFunc.locals.
  locals: List[MsilType]  // ordered local variable types for MFunc.locals
  // `slotTicker` and `labelTicker` are singleton lists whose `.count` is the
  // current next-slot / next-label integer.
  slotTicker: List[Int]  // length = next slot index (params + locals combined)
  labelTicker: List[Int]  // length = next label index
  paramCount: Int  // number of parameters (fixed at creation)
  loopBreak: List[Int]  // stack: top = innermost loop's exit label
  loopCont: List[Int]  // stack: top = innermost loop's back-edge label
  // Parallel to loopBreak/loopCont: the protected-region (try) nesting depth in
  // effect when each loop was entered.  A `break`/`continue` whose innermost
  // loop was entered at a *shallower* try depth than the current one is jumping
  // out of one or more CLR protected regions and must emit `leave`, not `br`
  // (a `br` across a protected-region boundary is unverifiable IL).  #1481.
  loopTryDepth: List[Int]
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
  var retvalSlot: Int
  epilogueUsed: List[Int]
  // EYield support: slot of the List<object> yield collector when inside a generator.
  // Empty when the function is not a generator; singleton when it is.
  yieldSlots: List[Int]
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
  // Expected construction-type stack: the surrounding context
  // (binding annotation, return type, call-arg / record-field type, enclosing
  // list element) pushes the `MConcreteList`/`MConcreteMap` it wants so that an
  // `EList` / `newList()` / `newMap()` builds the concrete instance instead of a
  // `List<object>`.  Distinct from `contextHintTyArgs` (which carries generic
  // type *args* for case-class construction) — keeping them separate avoids the
  // mis-typings that shared use caused.
  collExpect: List[MsilType]
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
  captureNameToType: Map[String, MsilType]
  // Names of `var` (reassignable) locals declared in this function.  A closure
  // that captures one of these cannot use by-value capture (mutations would not
  // be shared) — such a `var` is instead hoisted to a heap cell (see below).
  mutableLocals: List[String]
  // By-reference closure capture (#1479 v2).  `hoistedVarNames` is the pre-pass
  // set of names referenced inside any lambda in this function; a `var` local in
  // this set is hoisted to a one-element `List[object]` heap **cell** so the
  // closure and enclosing scope share one mutable location.  When such a `var`
  // is declared, its cell slot + logical element type are recorded in
  // `hoistedCellSlot`/`hoistedCellType`; reads/writes of the name (here and in
  // the closure) route through `get_Item(0)`/`set_Item(0)`.
  hoistedVarNames: List[String]
  hoistedCellSlot: Map[String, Int]
  hoistedCellType: Map[String, MsilType]
  // Inside a lifted `__lambda_*`: capture names whose `__caps[i]` slot holds a
  // by-reference **cell** (a hoisted `var`) rather than a by-value boxed copy.
  // Reads emit `__caps[i]; get_Item(0); unbox`; writes emit `set_Item(0)`.
  captureCellNames: List[String]
  // Phase B.1 async SM context.  Empty except when synthesiseAsyncSmPhaseBMsil
  // is lowering the MoveNext body (singleton then).  The EAwait handler checks
  // this to switch from the blocking shim to the real suspend/resume protocol.
  phaseBCtx: List[PhaseBCtx]
  // Lazy generator SM context (#1490).  Empty except when synthesizeGeneratorMsil
  // is lowering the MoveNext body (singleton then).  The EYield handler checks
  // this to emit the TCS-based lazy suspend protocol.
  lazyGenCtx: List[LazyGenCtx]
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
    case MClass(_) -> 0x1C
    case MGenericInst(_, _, _) -> 0x1C
    // Concrete collections occupy object slots (they degrade to 0x1C in the
    // LocalVarSig), so slot-compatibility keys them as object too.
    case MConcreteList(_) -> 0x1C
    case MConcreteMap(_, _) -> 0x1C
    case other -> elementTypeByte(other)
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
      val existingTy = match mapGet(fctx.types, name) { case Some(t) -> t; case None -> ty }
      if localVarSlotByte(existingTy) == localVarSlotByte(ty) {
        // Slot reused, but the tracked type must still be refreshed to the new
        // binding's type: two same-named locals that share an object-byte slot
        // (e.g. a `List[InterpolatedSegment]` then a `List[String]` in two
        // match arms) must each see their own element type, or the stale type
        // mis-routes a later EIndex/`.add` (harmless while every list is
        // `List<object>`, a fault once element types are concrete).
        // Short-circuit the remove+add mutation when the type is already correct
        // to avoid gratuitous map churn on same-type re-binds.
        if existingTy != ty {
          fctx.types.remove(name)
          fctx.types.add(name, ty)
        }
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
pub func finishHoistedCellMsil(
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  name: in String,
  elemTy: in MsilType,
): Unit {
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
    case PMOut -> true
    case PMInout -> true
    case PMIn -> false
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
    case AssEq -> None
    case AssPlus -> Some(value = MAdd)
    case AssMinus -> Some(value = MSub)
    case AssStar -> Some(value = MMul)
    case AssSlash -> Some(value = MDiv)
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
    case MObject -> {
    }
    case _ -> {
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
    case MObject -> match valTy { case MVoid -> insns.add(MLdNull); case MObject -> {  }; case MString -> {  }; case _ -> if isValueType(valTy) { boxIfNeededMsil(cctx, insns, valTy) } }
    case _ -> {
    }
  }
}

// Apply a compound-assignment operator to a current value already on the stack
// (typed `curTy`), consuming the right-hand `value` expression and leaving the
// combined result on the stack.  `+=` on a String performs `String.Concat`
// (coercing a non-string rhs via `ToString`); every other op emits the matching
// arithmetic instruction.  `AssEq` is handled by callers and never reaches here.
func emitCompoundCombineMsil(
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  op: in AssignOp,
  curTy: in MsilType,
  value: in Expr,
): Unit {
  val isStringConcat = match op {
    case AssPlus -> match curTy { case MString -> true; case _ -> false }
    case _ -> false
  }
  if isStringConcat {
    val rTy = lowerExprMsil(cctx, fctx, insns, value)
    match rTy {
      case MString -> {
      }
      case _ -> {
        if isValueType(rTy) {
          boxIfNeededMsil(cctx, insns, rTy)
        }
        insns.add(MCallvirt(methodToken = cctx.tokObjToString))
      }
    }
    insns.add(MCall(methodToken = cctx.tokConcat2))
  } else {
    lowerExprMsil(cctx, fctx, insns, value)
    match assignOpArithInsnMsil(op) {
      case Some(arith) -> insns.add(arith)
      case None -> panic("Msil.Codegen: unhandled compound-assignment op in emitCompoundCombineMsil")
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
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  op: in AssignOp,
  rTy: in MsilType,
  rSlot: in Int,
): Unit {
  val isStringConcat = match op { case AssPlus -> match rTy { case MString -> true; case _ -> false }; case _ -> false }
  emitLoadSlot(insns, rSlot, fctx.paramCount)
  if isStringConcat {
    insns.add(MCall(methodToken = cctx.tokConcat2))
  } else {
    match assignOpArithInsnMsil(op) {
      case Some(arith) -> insns.add(arith)
      case None -> panic("Msil.Codegen: unhandled compound-assignment op in emitCompoundCombineSlotMsil")
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
func emitByrefArgMsil(cctx: in CodegenCtx, fctx: in FuncCtx, insns: in List[MInsn], argExpr: in Expr): Unit {
  match argExpr.kind {
    case EPath(path) -> {
      val name = lastSegmentMsil(path)
      match mapGet(fctx.slots, name) {
        case Some(slot) -> {
          match mapGet(fctx.byrefSlotTypes, slot) {
            case Some(_) -> insns.add(MLdarg(slot = slot))
            case None -> {
              if slot < fctx.paramCount {
                insns.add(MLdarga(slot = slot))
              } else {
                insns.add(MLdloca(slot = slot - fctx.paramCount))
              }
            }
          }
        }
        case None -> panic("Msil.Codegen: out/inout argument '" + name + "' is not a local or parameter (mode checker should have rejected this)")
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

// Flatten a pure dotted-path expression — an `EPath`, or a chain of `EMember`
// accesses bottoming out in an `EPath` (`Grpc.Types` parses as
// `EMember(EPath["Grpc"], "Types")`) — into its segment list.  Returns an empty
// list for any expression that is not a pure identifier path (e.g. a member
// access on a real value), so a caller can distinguish a package-qualified
// reference from value member access.  Used to recognise a fully-qualified
// free-function call (`Grpc.Types.statusCodeFromInt(...)`) whose multi-segment
// package prefix the parser left as nested `EMember`s.
func flattenPathExprSegs(e: in Expr): List[String] {
  match e.kind {
    case EPath(path) -> path.segments
    case EMember(receiver, memberName) -> {
      val pre = flattenPathExprSegs(receiver)
      if pre.count == 0 {
        return newList()
      }
      val segs: List[String] = newList()
      var i = 0
      while i < pre.count {
        segs.add(pre[i])
        i = i + 1
      }
      segs.add(memberName)
      segs
    }
    case _ -> newList()
  }
}

// Qualified enum-case *value* in expression position (`Color.Red` passed as an
// argument, returned, or used as a `match` scrutinee).  `Color.Red` parses as
// `EMember(EPath["Color"], "Red")`; a multi-segment package prefix
// (`Acme.Types.Color.Red`) parses as nested `EMember`s.  An enum value is an
// Int ordinal at the IL level (F#-emitter parity, see `registerEnumDeclMsil`),
// so it must lower to `ldc.i4 <ordinal>` — exactly like the bare `Red` form
// (the `EPath` arm) and the qualified `case Color.Red ->` pattern (#3343).
//
// Returns the case ordinal when `expr` is such a reference, or -1 otherwise.
// The lookup is scoped to the named enum type (`<EnumType>.<Case>` key) so two
// in-bundle enums sharing a case name can't collide (#3346).  A receiver whose
// first segment names a local takes precedence — it's a real value, not an
// enum type reference — so a member-access chain rooted in a same-named local
// (single- or multi-segment) is left to the normal `EMember` arm.
//
// Resolved here (before the `EMember` arm of `lowerExprMsil`) rather than
// inside that arm: restructuring the arm's control flow mis-lowers ordinary
// field access in the self-hosted compiler (the #3344 dead-end), so the arm is
// left byte-identical and the enum case is short-circuited at function entry.
func tryQualifiedEnumOrdinalMsil(cctx: in CodegenCtx, fctx: in FuncCtx, expr: in Expr): Int {
  match expr.kind {
    case EMember(recv, memberName) -> {
      val segs = flattenPathExprSegs(recv)
      if segs.count == 0 {
        return -1
      }
      val enumTy = segs[segs.count - 1]
      if not cctx.enumTypeNames.containsKey(enumTy) {
        return -1
      }
      // A receiver whose first segment names a local is a value member-access
      // chain (`x.Color.Red`, or a bare `Color.Red` shadowed by a local
      // `Color`), not a package-qualified enum reference — even if a middle
      // segment coincidentally matches an enum type name and the member matches
      // a case.  Leave it to the normal `EMember` arm.
      if fctx.slots.containsKey(segs[0]) {
        return -1
      }
      match mapGet(cctx.enumCaseOrdinals, enumTy + "." + memberName) {
        case Some(ord) -> ord
        case None -> -1
      }
    }
    case _ -> -1
  }
}

// Cross-package type-name resolution (#1183 codegen port, scope tiers
// added in #3085).  Given a simple type name like "Maybe" referenced in
// `pkgName`, find the FQN to use for the resulting `MClass`.
//
// Record `typeFqn` as a resolution candidate for the simple name
// `typeName`: keeps the legacy first-wins `typeFqnByName` entry (still
// consulted by the record-ctor call resolution sites) and appends to the
// ordered `typeFqnCandidates` multimap that `resolveTypeFqn` walks with
// scope tiers (#3085).
pub func registerTypeFqnCandidate(cctx: in CodegenCtx, typeName: in String, typeFqn: in String): Unit {
  if not cctx.typeFqnByName.containsKey(typeName) {
    cctx.typeFqnByName.add(typeName, typeFqn)
  }
  match mapGet(cctx.typeFqnCandidates, typeName) {
    case Some(lst) -> {
      if not lst.contains(typeFqn) {
        lst.add(typeFqn)
      }
    }
    case None -> {
      val lst1: List[String] = newList()
      lst1.add(typeFqn)
      cctx.typeFqnCandidates.add(typeName, lst1)
    }
  }
}

func resolveTypeFqn(cctx: in CodegenCtx, pkgName: in String, seg: in String): String {
  // Scope-tier resolution over every registered candidate, mirroring the
  // type checker's `symTableTryFindOne` (#3085): (1) the referencing
  // package's own declaration, (2) the newest candidate declared by a
  // package the referencing package imports, (3) the newest registration
  // (stdlib registers first, restored deps second, in-bundle packages
  // last — so "newest" prefers the most local declaration, exactly like
  // the type checker's last-registered-wins fallback).  Tiers 1/2 keep a
  // short name that collides across packages (`Msil.Kernel.ByteWriter`
  // vs the transitively-loaded `Std.Stream.ByteWriter`) bound to the
  // declaration the type checker chose.  When no candidate exists the
  // type was never declared in the bundle, so fall back to the
  // current-pkg form (the pre-#1183 behaviour).
  match mapGet(cctx.typeFqnCandidates, seg) {
    case Some(cands) -> {
      val ownFqn = pkgName + "." + seg
      if cands.contains(ownFqn) {
        return ownFqn
      }
      match mapGet(cctx.pkgImports, pkgName) {
        case Some(imports) -> {
          var i = cands.count - 1
          while i >= 0 {
            val fqn = cands[i]
            if fqn.length > seg.length + 1 {
              val pkgPart = fqn.substring(0, fqn.length - seg.length - 1)
              if imports.contains(pkgPart) {
                return fqn
              }
            }
            i = i - 1
          }
        }
        case None -> {
        }
      }
      cands[cands.count - 1]
    }
    case None -> pkgName + "." + seg
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
    case TRef(path) -> if lastSegmentMsil(path) == "Byte" { MByte } else { typeExprToMsilCtx(cctx, elem, pkgName) }
    case _ -> typeExprToMsilCtx(cctx, elem, pkgName)
  }
}

func sliceElemMsil(elem: in TypeExpr, pkgName: in String): MsilType {
  match elem.kind {
    case TRef(path) -> if lastSegmentMsil(path) == "Byte" { MByte } else { typeExprToMsil(elem, pkgName) }
    case _ -> typeExprToMsil(elem, pkgName)
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
      if not isVtype and not clrIsValueType(clrFqn) {
        return None
      }
      val sp = splitTypeFqn(clrFqn)
      val asm = assemblyForTypeMsil(cctx, clrFqn)
      val refRow = internFfiTypeRef(cctx, asm, sp.ns, sp.name)
      Some(value = MValueTypeRef(typeRefCode = tdrTypeRef(refRow), clrFqn = clrFqn))
    }
  }
}

// `Unit` / `Never` as a generic type ARGUMENT lower to `System.ValueTuple`,
// not `void`.  The F# emitter (`TypeMap.fs`: `PtUnit`/`PtNever -> ValueTuple`
// at value position, `-> Void` only at the method-return slot) follows the
// same split: `void` is not a legal generic instantiation argument, so a
// cross-package `Result[Unit, E]` / `Option[Unit]` reference must encode
// `Result<[corelib]System.ValueTuple, E>` to byte-match the F#-built producer
// (`[corelib]` = whichever core assembly is in use; on .NET Core / .NET 5+ this
// is `System.Runtime`, not `mscorlib` — the code calls `assemblyForTypeMsil` so
// the correct name is resolved dynamically at emit time; #2893)
// (a self-hosted `Unit` arg otherwise degraded to `object`/`void` and failed
// to bind with MissingMethodException).  `System.ValueTuple` is the empty
// (non-generic) struct, so it serialises as VALUETYPE + TypeRef exactly like
// any other BCL value-type generic argument (the #1602 Guid-in-Option path).
func valueTupleMsilCtx(cctx: in CodegenCtx): MsilType {
  val asm = assemblyForTypeMsil(cctx, "System.ValueTuple")
  val refRow = internFfiTypeRef(cctx, asm, "System", "ValueTuple")
  MValueTypeRef(typeRefCode = tdrTypeRef(refRow), clrFqn = "System.ValueTuple")
}

// Rewrite the type-ARGUMENT lists of every generic instantiation in `ty`
// (recursively), replacing a `MVoid` argument with `System.ValueTuple`.  A
// `MVoid` reaches a generic-argument slot only from a `Unit` / `Never` type
// argument (`typeExprToMsilCtx` maps both to `MVoid`), so this is an exact
// "`Unit`-at-value-position" rewrite.  The TOP-LEVEL type is left untouched —
// a function returning bare `Unit` still returns `void`.
//
// This is applied ONLY when encoding a cross-package REFERENCE to an
// F#-built producer (`registerStdlibFunc`).  The F# emitter encodes a
// `Unit`/`Never` generic argument as `System.ValueTuple` at value position
// (`TypeMap.fs`), so a self-hosted consumer's MemberRef must match to bind
// (otherwise `Result[Unit, E]` degrades to `Result<object, E>` and faults with
// MissingMethodException).  It is deliberately NOT applied to the in-bundle
// definition / value-construction path (`typeExprToMsilCtx` proper): a
// self-hosted package's own `Result[Unit, E]` values are represented with an
// `object` argument end-to-end (def, ctor, and match all agree), and lifting
// only the type to `ValueTuple` without changing the value representation
// silently miscompiles them.
func xrefUnitArgsToValueTuple(cctx: in CodegenCtx, ty: in MsilType): MsilType {
  match ty {
    case MGenericInst(trc, fqn, targs) -> MGenericInst(typeRefCode = trc, headFqn = fqn, typeArgs = xrefRewriteArgList(cctx, targs))
    case MGenericInstByName(fqn, targs) -> MGenericInstByName(headFqn = fqn, typeArgs = xrefRewriteArgList(cctx, targs))
    case MValueTypeGenericInst(trc, fqn, targs) -> MValueTypeGenericInst(typeRefCode = trc, headFqn = fqn, typeArgs = xrefRewriteArgList(cctx, targs))
    case _ -> ty
  }
}

func xrefRewriteArgList(cctx: in CodegenCtx, args: in List[MsilType]): List[MsilType] {
  val acc: List[MsilType] = newList()
  var i = 0
  while i < args.count {
    val a = args[i]
    match a {
      case MVoid -> acc.add(valueTupleMsilCtx(cctx))
      case _ -> acc.add(xrefUnitArgsToValueTuple(cctx, a))
    }
    i = i + 1
  }
  acc
}

// type references via the codegen context (#1183 codegen port).
pub func typeExprToMsilCtx(cctx: in CodegenCtx, te: in TypeExpr, pkgName: in String): MsilType {
  match te.kind {
    case TUnit -> MVoid
    case TNever -> MVoid
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
      } else if cctx.enumTypeNames.containsKey(seg) {
        // Lyric enum: ordinal-int representation (F# parity).  Encoding the
        // enum as CLASS + TypeDef would name a value type with reference
        // semantics — a loader-level "value type mismatch" (#3196).
        MInt
      } else {
        // An extern type that maps to a BCL value type (e.g.
        // `extern type Uuid = "System.Guid"`) must carry its valuetype
        // identity so cross-package signatures encode VALUETYPE + TypeRef
        // rather than degrading to `object` (#1602).  Reference-typed
        // externs (e.g. `extern type SB = "System.Text.StringBuilder"`)
        // similarly must carry their identity so field/method signatures
        // encode CLASS + TypeRef rather than degrading to `object` (#1576).
        // Ordinary user types fall through to MClass.
        match externValueTypeMsil(cctx, seg) {
          case Some(vt) -> vt
          case None -> {
            match mapGet(cctx.externTypeNames, seg) {
              case Some(clrFqn) -> {
                // Lyric-internal extern types (CLR FQN starts with "Lyric.") are
                // in-process Lyric packages, not BCL assemblies.  assemblyForTypeMsil
                // returns "Lyric.Emitter" for them as a fallback, and internFfiAssemblyRef
                // would then create AssemblyRef with the Microsoft signing key (Version=10.0,
                // PublicKeyToken=b03f5f7f11d50a3a), which is wrong for a Lyric DLL.
                // Fall through to MClass for these — MClass is the correct encoding for
                // in-bundle and cross-Lyric-package types.
                if startsWith(clrFqn, "Lyric.") {
                  MClass(className = resolveTypeFqn(cctx, pkgName, seg))
                } else {
                  ensureMetadataIndex(cctx)
                  val sp = splitTypeFqn(clrFqn)
                  val asm = assemblyForTypeMsil(cctx, clrFqn)
                  val refRow = internFfiTypeRef(cctx, asm, sp.ns, sp.name)
                  MClassRef(typeRefCode = tdrTypeRef(refRow), clrFqn = clrFqn)
                }
              }
              case None -> MClass(className = resolveTypeFqn(cctx, pkgName, seg))
            }
          }
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
            // `Byte` elements map to `MByte` (U1) — not the scalar `MInt`
            // mapping — so a `List[Byte]` encodes as `List`1<uint8>`, matching
            // the F#-emitted producer ABI (`Msil.Kernel.bufToList` returns
            // `List`1[System.Byte]`); a `List`1<int32>` MemberRef faults with
            // MissingMethodException at the call site.  Mirrors the
            // `slice[Byte]` special case (`sliceElemMsilCtx`).
            val elemTy = sliceElemMsilCtx(cctx, elemTe, pkgName)
            // A reference or concrete-collection/array element gets a closed
            // generic `List`1<elem>` — construction, operation tokens, and
            // signatures all match the instantiation and bind against any consumer.
            // Value elements keep the legacy `List<object>` (read-narrow `MListOf`,
            // unboxed on `get_Item`) because their unboxed stores need the concrete
            // token machinery that is handled in the concrete (Stage B) path.
            if collElemConcrete(elemTy) {
              MConcreteList(elemTy = elemTy)
            } else if isValueType(elemTy) {
              MListOf(elemTy = elemTy)
            } else {
              MObject
            }
          }
          case TAValue(_) -> MObject
        }
      } else if headSeg == "Map" and args.count == 2 {
        // Map[K, V] — a concrete `Dictionary`2<K,V>` instance when BOTH key and
        // value are reference types; value-typed keys/values keep
        // the legacy `Dictionary<object,object>` (box/unbox is Stage B).  In the
        // legacy form only a *value-type* V is tracked (so the boxed `get_Item`
        // result is unboxed back); reference V stays `object`; the key is always
        // boxed for `Dictionary<object,_>`, so K is not tracked.
        val keyTy = match args[0] { case TAType(kte) -> typeExprToMsilCtx(cctx, kte, pkgName); case TAValue(_) -> MObject }
        val valTyRaw = match args[1] { case TAType(vte) -> typeExprToMsilCtx(cctx, vte, pkgName); case TAValue(_) -> MObject }
        if collElemConcrete(keyTy) and collElemConcrete(valTyRaw) {
          MConcreteMap(keyTy = keyTy, valTy = valTyRaw)
        } else {
          val mapValTy = if isValueType(valTyRaw) { valTyRaw } else { MObject }
          MMapOf(keyTy = MObject, valTy = mapValTy)
        }
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
        // In-bundle generic type (#2362): `Box[Int]` resolves to a by-name
        // GENERICINST over the in-bundle TypeDef (resolved at lowering), checked
        // BEFORE the cross-assembly `ffiTypeRefs` path so an in-bundle head wins.
        match mapGet(cctx.genericTypeArity, headFqn) {
          case Some(arity) -> {
            val inBundleArgs: List[MsilType] = newList()
            var iai = 0
            while iai < args.count {
              match args[iai] {
                case TAType(te2) -> inBundleArgs.add(typeExprToMsilCtx(cctx, te2, pkgName))
                case TAValue(_) -> inBundleArgs.add(MObject)
              }
              iai = iai + 1
            }
            MGenericInstByName(headFqn = genericBacktickFqn(headFqn, arity), typeArgs = inBundleArgs)
          }
          case None -> {
            val dotIdx = headFqn.lastIndexOf(".")
            if dotIdx < 0 {
              MObject
            } else {
              val headPkg = headFqn.substring(0, dotIdx)
              val typeRefKey = headPkg + "/" + headFqn
              match mapGet(cctx.ffiTypeRefs, typeRefKey) {
                case None -> MObject
                case Some(row) -> {
                  val codedIdx: Int = tdrTypeRef(row)
                  val resolvedArgs: List[MsilType] = newList()
                  var ai = 0
                  while ai < args.count {
                    match args[ai] {
                      case TAType(te2) -> resolvedArgs.add(typeExprToMsilCtx(cctx, te2, pkgName))
                      case TAValue(_) -> resolvedArgs.add(MObject)
                    }
                    ai = ai + 1
                  }
                  MGenericInst(typeRefCode = codedIdx, headFqn = headFqn, typeArgs = resolvedArgs)
                }
              }
            }
          }
        }
      }
    }
    case TSlice(elem) -> MArray(elemTy = sliceElemMsilCtx(cctx, elem, pkgName))
    case TNullable(_) -> MObject
    case TTuple(_) -> MObject
    case TFunction(params, ret) -> {
      // Map Lyric function types to the CLR delegate types the bootstrap F# emitter uses
      // (#1877 uniform ABI). All Lyric values are boxed to System.Object in the
      // bootstrap model, so params always erase to object.
      // `() -> Unit` maps to System.Action (no type parameters).
      // All other arities and return types remain System.Object for now; a full
      // multi-arity mapping lands with epic #1877.
      // Note: the parser produces TRef(["Unit"]) for the `Unit` name, not TUnit,
      // so we resolve `ret` recursively and check for MVoid.
      val retMsil = typeExprToMsilCtx(cctx, ret, pkgName)
      val isVoidRet = match retMsil { case MVoid -> true; case _ -> false }
      if params.count == 0 and isVoidRet {
        MClass("System.Action")
      } else {
        MObject
      }
    }
    case TArray(_, _) -> MObject
    case TRefined(_, _) -> MInt
    case TParen(inner) -> typeExprToMsilCtx(cctx, inner, pkgName)
    case TSelf -> MObject
    case TError -> MObject
  }
}

// Legacy entry point (kept for callers that don't yet thread `cctx`).
// Identical to `typeExprToMsilCtx` except `TRef` resolution always uses
// `pkgName + "." + seg` for non-primitives.  Migrate call sites to the
// ctx-aware variant when cross-package type references matter.
pub func typeExprToMsil(te: in TypeExpr, pkgName: in String): MsilType {
  match te.kind {
    case TUnit -> MVoid
    case TNever -> MVoid
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
    case TSlice(elem) -> MArray(elemTy = sliceElemMsil(elem, pkgName))
    case TGenericApp(_, _) -> MObject
    case TNullable(_) -> MObject
    case TTuple(_) -> MObject
    case TFunction(_, _) -> MObject
    case TArray(_, _) -> MObject
    case TRefined(_, _) -> MInt
    case TParen(inner) -> typeExprToMsil(inner, pkgName)
    case TSelf -> MObject
    case TError -> MObject
  }
}

// Return true if an MsilType is a value type that must be boxed before
// calling virtual/interface methods.
func isValueType(ty: in MsilType): Bool {
  match ty {
    case MInt -> true
    case MLong -> true
    case MDouble -> true
    case MBool -> true
    case MChar -> true
    case MByte -> true
    case _ -> false
  }
}

// Numeric / character primitives that the conversion-method intrinsics
// (`.toInt()`/`.toLong()`/`.toByte()`/`.toChar()`/`.toDouble()`, #1901) accept
// as a receiver.  `Bool` is deliberately excluded — it is not a numeric type.
func isNumericMsil(ty: in MsilType): Bool {
  match ty {
    case MInt -> true
    case MLong -> true
    case MDouble -> true
    case MChar -> true
    case MByte -> true
    case _ -> false
  }
}

// Cross-package call resolution helper (#1183 Phase 2).  Walks `imports`
// — the dotted-name list of packages imported by the calling site's
// package — and returns the first `<imp>.<funcName>` key that exists in
// `cctx.funcTokens`.  Returns "" when no import shadows `funcName`.
//
// Defined as a top-level helper rather than inline so the `match` over
// `mapGet` in the call site stays readable.
func findImportedFqn(cctx: in CodegenCtx, imports: in List[String], funcName: in String): String {
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
    case MInt -> cctx.trInt32
    case MLong -> cctx.trInt64
    case MDouble -> cctx.trDouble
    case MBool -> cctx.trBoolean
    case MChar -> cctx.trChar
    case MByte -> cctx.trByte
    case _ -> cctx.lctx.trObject
  }
}

// Box a value type on the stack.  Does nothing for reference types.
func boxIfNeededMsil(cctx: in CodegenCtx, insns: in List[MInsn], ty: in MsilType): Unit {
  if isValueType(ty) {
    insns.add(MBox(typeToken = 0x01000000 + boxTypeRef(cctx, ty)))
  }
}

// TypeRef token for an array element type, suitable for `newarr` / `stelem`.
// Covers the value-type elements (via their `System.*` TypeRefs), `String`,
// and the erased `Object` element.  Returns `None` for element types we cannot
// yet name a token for here (user classes, nested generics / collections);
// callers fall back to the List-backed slice path for those.  This is the basis
// for representing a `slice[T]` value as a genuine CLR `T[]` (matching the F#
// emitter's `TypeMap.fs` `MakeArrayType()` lowering) so a self-hosted-built
// slice passed to an array-typed boundary (e.g. the F#-compiled
// `Std.Sort.sortInts(Int[])`) is a real array, not a `List` (#2592).
func arrayElemTokenOpt(cctx: in CodegenCtx, e: in MsilType): Option[Int] {
  match e {
    case MInt -> Some(value = 0x01000000 + cctx.trInt32)
    case MLong -> Some(value = 0x01000000 + cctx.trInt64)
    case MDouble -> Some(value = 0x01000000 + cctx.trDouble)
    case MBool -> Some(value = 0x01000000 + cctx.trBoolean)
    case MChar -> Some(value = 0x01000000 + cctx.trChar)
    case MByte -> Some(value = 0x01000000 + cctx.trByte)
    case MString -> Some(value = 0x01000000 + cctx.trString)
    case MObject -> Some(value = 0x01000000 + cctx.lctx.trObject)
    case _ -> None
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
      case MString -> insns.add(MCastclassByName(className = "System.String"))
      case MClass(c) -> insns.add(MCastclassByName(className = c))
      case MGenericInst(_, headFqn, tas) -> insns.add(MCastclassGeneric(className = headFqn, typeArgs = tas))
      // Concrete collections: narrow an `object` back to the closed
      // generic TypeSpec (e.g. a nested `List[List[Foo]]` element read).
      case MConcreteList(e) -> insns.add(MListOp(op = LoCastclass, elemTy = e))
      case MConcreteMap(k, v) -> insns.add(MDictOp(op = DoCastclass, keyTy = k, valTy = v))
      case _ -> {
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4b. Concrete collection support.
// ─────────────────────────────────────────────────────────────────────────────
// Stage A gate: an element/key/value type for which a concrete `List`1<T>` /
// `Dictionary`2<K,V>` instance is built (refs only — they need no box/unbox).
// Value types (Int/Long/Double/Bool/Char/Byte) and the erased `MObject` /
// legacy `MListOf`/`MMapOf` cases keep the `List<object>` object path; their
// box/unbox removal is Stage B.  Concrete collections and arrays are included
// so a nested `List[List[Foo]]` / `List[slice[Foo]]` stays consistent end to
// end (the inner instance is a real `List<Foo>` / `Foo[]`, so the outer must
// track it concretely, or a read-back-as-object then concrete op would fault).
func collElemConcrete(t: in MsilType): Bool {
  match t {
    case MString -> true
    case MClass(_) -> true
    case MClassRef(_, _) -> true
    case MGenericInst(_, _, _) -> true
    case MConcreteList(_) -> true
    case MConcreteMap(_, _) -> true
    case MArray(_) -> true
    // Value-element collections are concrete — a `List[Int]` is a genuine
    // `List<int32>` storing unboxed `int`.  The element MemberRefs use `!0`, so
    // the same TypeSpec machinery instantiates with a value type; the codegen
    // drops the box on store and the unbox on read at concrete sites (see
    // `collBoxIfNeeded`).
    case MInt -> true
    case MLong -> true
    case MDouble -> true
    case MBool -> true
    case MChar -> true
    case MByte -> true
    case _ -> false
  }
}

// True when `t` is a closed-generic concrete collection type (`MConcreteList` or
// `MConcreteMap`).  Used to gate boxing/unboxing at call sites where the
// concrete store/read path skips the box/unbox that the legacy `object` path
// requires.
func isConcreteCollTy(t: in MsilType): Bool {
  match t {
    case MConcreteList(_) -> true
    case MConcreteMap(_, _) -> true
    case _ -> false
  }
}

// Box the just-lowered value (typed `elemTy`) for storage into a collection,
// UNLESS the collection is concrete — a concrete `List<int32>` /
// `Dictionary<…>` stores the value unboxed (the MemberRef's `!0`/`!1` binds to
// the value type).  For a concrete reference element this is a no-op either way.
func collBoxIfNeeded(cctx: in CodegenCtx, insns: in List[MInsn], elemTy: in MsilType, recvTy: in MsilType): Unit {
  if not isConcreteCollTy(recvTy) {
    boxIfNeededMsil(cctx, insns, elemTy)
  }
}

// The expected construction type at the current site (top of the collExpect
// stack), or MObject when none is set.  Consulted by EList / newList / newMap
// so a list/map literal builds the concrete instance the surrounding context
// (binding annotation, return type, call-arg/field type) wants.
func collExpectTop(fctx: in FuncCtx): MsilType {
  if fctx.collExpect.count > 0 {
    fctx.collExpect[fctx.collExpect.count - 1]
  } else {
    MObject
  }
}

func pushCollExpect(fctx: in FuncCtx, t: in MsilType): Unit {
  fctx.collExpect.add(t)
}

func popCollExpect(fctx: in FuncCtx): Unit {
  if fctx.collExpect.count > 0 {
    fctx.collExpect.removeAt(fctx.collExpect.count - 1)
  }
}

// Recover the parent union FQN for a case-class ctor key (#2363 Stage 4).
// Case classes are named `Union_Case`; since `_` is a valid identifier char the
// parent can't be recovered by splitting the key, so it is looked up in the
// structured `caseParentUnion` map populated at registration.  The split on the
// last `_` is a defensive fallback for any unregistered key (registered cases
// always hit the map).
func caseParentFqnMsil(cctx: in CodegenCtx, ctorKey: in String): String {
  match mapGet(cctx.caseParentUnion, ctorKey) {
    case Some(p) -> p
    case None -> {
      // INVARIANT: every case-class key that reaches a construction site was
      // registered (in-bundle via `addPackageTokens`, restored via
      // `registerUnionCases` / `registerRestoredUnionCase`), so the map lookup
      // above always hits.  This last-`_` split is a defensive fallback only;
      // it is INHERENTLY AMBIGUOUS when the union or case name contains `_`
      // (e.g. `Pkg.My_Union_Case` → `Pkg.My_Union` is wrong) and must never be
      // the live path — if it ever fires, a registration site was missed.
      val us = ctorKey.lastIndexOf("_")
      if us >= 0 {
        ctorKey.substring(0, us)
      } else {
        ctorKey
      }
    }
  }
}

// ── Concrete-aware collection op emission ──
// Each routes a concrete `MConcreteList`/`MConcreteMap` receiver through the
// lowering-time `MListOp`/`MDictOp` (which intern the closed-generic tokens at
// lowering time) and every other tracked type through the legacy
// `tokListObj*`/`tokDictObj*` object path.  Structure (castclass-or-not, box,
// index push order) is preserved by the call sites; these helpers only swap the
// specific token.  Box/unbox stays unchanged because Stage A is refs-only —
// `boxIfNeededMsil` is a no-op for references and `get_Item` on a concrete list
// already returns the typed element.
func emitListCastRecv(cctx: in CodegenCtx, insns: in List[MInsn], recvTy: in MsilType): Unit {
  match recvTy {
    case MConcreteList(e) -> insns.add(MListOp(op = LoCastclass, elemTy = e))
    // `MArray` (the static type of `slice[T]`) may hold either a genuine CLI
    // array or a `List`-backed slice; the non-generic `IList` is implemented by
    // both, so cast through it rather than the `List<object>`-specific TypeSpec
    // (which faults on a real array — #2539).
    case MArray(_) -> insns.add(MCastclass(typeToken = cctx.tokIListCast))
    case _ -> insns.add(MCastclass(typeToken = cctx.tokListObjTypeSpec))
  }
}

func emitListAdd(cctx: in CodegenCtx, insns: in List[MInsn], recvTy: in MsilType): Unit {
  match recvTy {
    case MConcreteList(e) -> insns.add(MListOp(op = LoAdd, elemTy = e))
    case _ -> insns.add(MCallvirt(methodToken = cctx.tokListObjAdd))
  }
}

func emitListGetItem(cctx: in CodegenCtx, insns: in List[MInsn], recvTy: in MsilType): Unit {
  match recvTy {
    case MConcreteList(e) -> insns.add(MListOp(op = LoGetItem, elemTy = e))
    // `MArray` slice: read through `IList.get_Item` so a genuine array iterable
    // (`for x in str.split(...)`) works alongside a `List`-backed slice (#2539).
    case MArray(_) -> insns.add(MCallvirt(methodToken = cctx.tokIListGetItem))
    case _ -> insns.add(MCallvirt(methodToken = cctx.tokListObjGetItem))
  }
}

func emitListSetItem(cctx: in CodegenCtx, insns: in List[MInsn], recvTy: in MsilType): Unit {
  match recvTy {
    case MConcreteList(e) -> insns.add(MListOp(op = LoSetItem, elemTy = e))
    case _ -> insns.add(MCallvirt(methodToken = cctx.tokListObjSetItem))
  }
}

func emitListGetCount(cctx: in CodegenCtx, insns: in List[MInsn], recvTy: in MsilType): Unit {
  match recvTy {
    case MConcreteList(e) -> insns.add(MListOp(op = LoGetCount, elemTy = e))
    // `MArray` slice: count through the non-generic `ICollection`, implemented by
    // both `System.Array` and `List<T>` (#2539).
    case MArray(_) -> insns.add(MCallvirt(methodToken = cctx.tokICollGetCount))
    case _ -> insns.add(MCallvirt(methodToken = cctx.tokListObjGetCount))
  }
}

func emitListContains(cctx: in CodegenCtx, insns: in List[MInsn], recvTy: in MsilType): Unit {
  match recvTy {
    case MConcreteList(e) -> insns.add(MListOp(op = LoContains, elemTy = e))
    case _ -> insns.add(MCallvirt(methodToken = cctx.tokListObjContains))
  }
}

func emitListRemoveAt(cctx: in CodegenCtx, insns: in List[MInsn], recvTy: in MsilType): Unit {
  match recvTy {
    case MConcreteList(e) -> insns.add(MListOp(op = LoRemoveAt, elemTy = e))
    case _ -> insns.add(MCallvirt(methodToken = cctx.tokListObjRemoveAt))
  }
}

func emitDictCastRecv(cctx: in CodegenCtx, insns: in List[MInsn], recvTy: in MsilType): Unit {
  match recvTy {
    case MConcreteMap(k, v) -> insns.add(MDictOp(op = DoCastclass, keyTy = k, valTy = v))
    case _ -> insns.add(MCastclass(typeToken = cctx.tokDictObjTypeSpec))
  }
}

func emitDictAdd(cctx: in CodegenCtx, insns: in List[MInsn], recvTy: in MsilType): Unit {
  match recvTy {
    case MConcreteMap(k, v) -> insns.add(MDictOp(op = DoAdd, keyTy = k, valTy = v))
    case _ -> insns.add(MCallvirt(methodToken = cctx.tokDictObjAdd))
  }
}

func emitDictGetItem(cctx: in CodegenCtx, insns: in List[MInsn], recvTy: in MsilType): Unit {
  match recvTy {
    case MConcreteMap(k, v) -> insns.add(MDictOp(op = DoGetItem, keyTy = k, valTy = v))
    case _ -> insns.add(MCallvirt(methodToken = cctx.tokDictObjGetItem))
  }
}

func emitDictSetItem(cctx: in CodegenCtx, insns: in List[MInsn], recvTy: in MsilType): Unit {
  match recvTy {
    case MConcreteMap(k, v) -> insns.add(MDictOp(op = DoSetItem, keyTy = k, valTy = v))
    case _ -> insns.add(MCallvirt(methodToken = cctx.tokDictObjSetItem))
  }
}

func emitDictGetCount(cctx: in CodegenCtx, insns: in List[MInsn], recvTy: in MsilType): Unit {
  match recvTy {
    case MConcreteMap(k, v) -> insns.add(MDictOp(op = DoGetCount, keyTy = k, valTy = v))
    case _ -> insns.add(MCallvirt(methodToken = cctx.tokDictObjGetCount))
  }
}

func emitDictContainsKey(cctx: in CodegenCtx, insns: in List[MInsn], recvTy: in MsilType): Unit {
  match recvTy {
    case MConcreteMap(k, v) -> insns.add(MDictOp(op = DoContainsKey, keyTy = k, valTy = v))
    case _ -> insns.add(MCallvirt(methodToken = cctx.tokDictObjContainsKey))
  }
}

func emitDictRemove(cctx: in CodegenCtx, insns: in List[MInsn], recvTy: in MsilType): Unit {
  match recvTy {
    case MConcreteMap(k, v) -> insns.add(MDictOp(op = DoRemove, keyTy = k, valTy = v))
    case _ -> insns.add(MCallvirt(methodToken = cctx.tokDictObjRemove))
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Expression lowering.
// ─────────────────────────────────────────────────────────────────────────────
// Lower a single expression.  Pushes exactly one value onto the operand stack
// (or nothing for MVoid).  Returns the MsilType of the pushed value.
pub func lowerExprMsil(cctx: in CodegenCtx, fctx: in FuncCtx, insns: in List[MInsn], expr: in Expr): MsilType {
  // Qualified enum-case value (`Color.Red` as an argument / scrutinee / return
  // value): lower to its Int ordinal directly (#3344).  Short-circuited here so
  // the `EMember` arm below stays byte-identical — see
  // `tryQualifiedEnumOrdinalMsil` for why restructuring that arm is unsafe.
  val qEnumOrd = tryQualifiedEnumOrdinalMsil(cctx, fctx, expr)
  if qEnumOrd >= 0 {
    insns.add(MLdcI4(v = qEnumOrd))
    return MInt
  }
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
          val elemTy = match mapGet(fctx.hoistedCellType, name) { case Some(t) -> t; case None -> MObject }
          emitLoadVarMsil(fctx, insns, cellSlot)
          insns.add(MLdcI4(v = 0))
          insns.add(MCallvirt(methodToken = cctx.tokListObjGetItem))
          castObjectToMsil(cctx, insns, elemTy)
          return elemTy
        }
        case None -> {
        }
      }
      match mapGet(fctx.slots, name) {
        case Some(slot) -> {
          val ty = match mapGet(fctx.types, name) { case Some(t) -> t; case None -> MObject }
          emitLoadVarMsil(fctx, insns, slot)
          // A lifted lambda's parameter is stored boxed (`object`); unbox/cast it
          // to its logical type on load (#1939).
          match mapGet(fctx.boxedParamTypes, slot) {
            case Some(logicalTy) -> {
              castObjectToMsil(cctx, insns, logicalTy)
              logicalTy
            }
            case None -> ty
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
              val capTy = match mapGet(fctx.captureNameToType, name) { case Some(t) -> t; case None -> MObject }
              if nameListContains(fctx.captureCellNames, name) {
                insns.add(MLdcI4(v = 0))
                insns.add(MCallvirt(methodToken = cctx.tokListObjGetItem))
              }
              castObjectToMsil(cctx, insns, capTy)
              return capTy
            }
            case None -> {
            }
          }
          // Check for a module-level compile-time const (inline ldc.i4).
          // Package-qualified key first (#2627): the consuming package's own
          // constant always wins, so a same-named, different-valued const in
          // another package can never silently inline the wrong value here.
          // The bare-name key remains the cross-package fallback (first-wins).
          val constHit = match mapGet(cctx.constValues, fctx.pkgName + "/" + name) {
            case Some(qv) -> Some(value = qv)
            case None -> mapGet(cctx.constValues, name)
          }
          match constHit {
            case Some(v) -> {
              insns.add(MLdcI4(v = v))
              MInt
            }
            case None -> {
              // Enum case reference (`val l = Debug`): emit the ordinal
              // directly — enum values are I4 at the IL level (#3196).
              match mapGet(cctx.enumCaseOrdinals, name) {
                case Some(ordv) -> {
                  insns.add(MLdcI4(v = ordv))
                  return MInt
                }
                case None -> {
                }
              }
              // Nullary union case as a bare path (e.g. `val n = None`
              // — Lyric accepts the call-less form).  Same two-step
              // resolution as the `ECall` path: try the local pkg's
              // case ctor, then walk `unionCaseCtorByName` for cross-
              // package cases.  Mirrors the construction-side fix in
              // `lowerBuiltinOrStaticCallMsil` (#1183 codegen port).
              val localCtorKey = fctx.pkgName + "." + name
              val ctorKey = if cctx.recordCtorTokens.containsKey(localCtorKey) {
                localCtorKey
              } else {
                match mapGet(cctx.unionCaseCtorByName, name) {
                  case Some(candidates) -> pickCaseFqnByScope(cctx, fctx, candidates)
                  case None -> localCtorKey
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
                      case MGenericInstByName(_, retArgTys) -> {
                        var rti = 0
                        while rti < retArgTys.count {
                          nullCtxTyArgs.add(retArgTys[rti])
                          rti = rti + 1
                        }
                      }
                      case _ -> {
                      }
                    }
                  }
                  val nullArgTypes: List[MsilType] = newList()
                  val nullOutPTy: List[MsilType] = newList()
                  val nullGenTok = buildGenericCaseCtorTok(cctx, ctorKey, nullArgTypes, nullCtxTyArgs, nullOutPTy, insns)
                  if nullGenTok > 0 {
                    // MNewobjGenericCase already emitted to insns by buildGenericCaseCtorTok.
                    if nullOutPTy.count > 0 {
                      nullOutPTy[0]
                    } else {
                      MObject
                    }
                  } else {
                    // In-bundle generic nullary case (e.g. a bare `Nothing` for
                    // `Maybe[Int]`): construct via newobj on the closed TypeSpec
                    // (#2362).  A generic nullary case has no singleton — see
                    // lowerMUnion / Q-GEN-001.
                    val nullInb: List[MsilType] = newList()
                    val nullInbTok = buildInBundleGenericCtorTok(cctx, ctorKey, nullArgTypes, nullCtxTyArgs, nullInb, insns)
                    if nullInbTok > 0 {
                      nullInb[0]
                    } else {
                      match mapGet(cctx.singletonFieldTokens, ctorKey) {
                        case Some(fldTok) -> {
                          insns.add(MLdsfld(fieldToken = fldTok))
                          MClass(className = caseParentFqnMsil(cctx, ctorKey))
                        }
                        case None -> {
                          insns.add(MNewobj(ctorToken = ctorTok))
                          MClass(className = caseParentFqnMsil(cctx, ctorKey))
                        }
                      }
                    }
                  }
                }
                case None -> {
                  // Module-level val: load from the static field emitted for this IVal.
                  match mapGet(cctx.staticValTokens, name) {
                    case Some(fieldTok) -> {
                      val ty = match mapGet(cctx.staticValMsilTypes, name) { case Some(t) -> t; case None -> MObject }
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
      // Config block short-circuit: `Settings.port` parses as
      // EMember(EPath(["Settings"]), "port").  If the single-segment receiver
      // matches a config block name and the "blockName/fieldName" key is in
      // configFieldTokens, emit ldsfld directly without evaluating the receiver.
      val cfKey = match recv.kind {
        case EPath(path) -> if path.segments.count == 1 { path.segments[0] + "/" + memberName } else { "" }
        case _ -> ""
      }
      if cfKey != "" and cctx.configFieldTokens.containsKey(cfKey) {
        val cfTok = match mapGet(cctx.configFieldTokens, cfKey) { case Some(t) -> t; case None -> 0 }
        insns.add(MLdsfld(fieldToken = cfTok))
        match mapGet(cctx.configFieldMsilTypes, cfKey) {
          case Some(cfMty) -> cfMty
          case None -> MObject
        }
      } else {
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
                  case None -> MObject
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
          case MGenericInstByName(fqn, typeArgs) -> {
            // Field read on an in-bundle generic record instance (#2362).  The
            // receiver is a closed `MGenericInstByName` (e.g. `Box<Int>`); read the
            // field through a TypeSpec-parented MemberRef via MLdfldGeneric (TypeSpec
            // built at Phase 5).  The result type is the concrete type argument for a
            // type-parameter field, else the field's registered concrete type.  The
            // codegen maps are keyed by the plain FQN; the instruction carries the
            // arity-suffixed `fqn` so it resolves against the suffixed TypeDef.
            val key = stripGenericArity(fqn) + "/" + memberName
            val vi = match mapGet(cctx.fieldVarIndices, key) { case Some(v) -> v; case None -> -1 }
            val fSig = match mapGet(cctx.fieldSigBytes, key) { case Some(s) -> s; case None -> buildFieldSig(MObject) }
            if cctx.fieldSigBytes.containsKey(key) {
              // The receiver slot is `object` in IL; narrow it to the closed
              // GENERICINST TypeSpec (in-bundle TypeDef) so `ldfld` verifies.
              insns.add(MCastclassGeneric(className = fqn, typeArgs = typeArgs))
              insns.add(MLdfldGeneric(baseClassName = fqn, typeArgs = typeArgs, fieldName = memberName, fieldSig = fSig))
              if vi >= 0 {
                if vi < typeArgs.count {
                  typeArgs[vi]
                } else {
                  MObject
                }
              } else {
                match mapGet(cctx.fieldMsilTypes, key) {
                  case Some(fty) -> fty
                  case None -> MObject
                }
              }
            } else {
              insns.add(MPop)
              MObject
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
          case MConcreteList(_) -> {
            // Concrete List[T] receiver: `.count` / `.length` via the
            // concrete `get_Count`; castclass first so the callvirt is well-typed
            // when the receiver came from an object-typed slot.  `slice[T]` values
            // are List-backed at runtime (slice literals and `toArray()` both yield
            // a `List`), so `.length` is the element count, not a real-array `ldlen`
            // (#2539).
            if memberName == "count" or memberName == "length" {
              emitListCastRecv(cctx, insns, recvTy)
              emitListGetCount(cctx, insns, recvTy)
              MInt
            } else {
              insns.add(MPop)
              val msgTok = ctxInternUs(cctx.lctx, "Msil.Codegen: unimplemented List member access: " + memberName)
              insns.add(MLdStr(token = msgTok))
              insns.add(MNewobj(ctorToken = cctx.tokExceptionCtor))
              insns.add(MThrow)
              MObject
            }
          }
          case MConcreteMap(_, _) -> {
            if memberName == "count" {
              emitDictCastRecv(cctx, insns, recvTy)
              emitDictGetCount(cctx, insns, recvTy)
              MInt
            } else {
              insns.add(MPop)
              val msgTok = ctxInternUs(cctx.lctx, "Msil.Codegen: unimplemented Map member access: " + memberName)
              insns.add(MLdStr(token = msgTok))
              insns.add(MNewobj(ctorToken = cctx.tokExceptionCtor))
              insns.add(MThrow)
              MObject
            }
          }
          case MArray(_) -> {
            // `MArray` is the lowered static type of `slice[T]` (codegen ~2686:
            // `TSlice(elem) -> MArray(...)`), but slice *values* have two runtime
            // representations behind that one static type: genuine CLI arrays
            // (e.g. `String[]` from a `String.Split` extern) and `List`-backed
            // slices (slice literals, `toArray()` results, sub-slice copies).  A
            // raw `ldlen` faults / reads garbage on the List-backed case (#2539).
            // Both `System.Array` and `List<T>` implement the non-generic
            // `System.Collections.IList` / `ICollection`, so `.length` / `.count`
            // route through `ICollection.get_Count`, which is correct for either
            // representation.
            if memberName == "length" or memberName == "count" {
              insns.add(MCastclass(typeToken = cctx.tokIListCast))
              insns.add(MCallvirt(methodToken = cctx.tokICollGetCount))
              MInt
            } else {
              insns.add(MPop)
              MObject
            }
          }
          case MString -> {
            // Genuine `String` receiver: `.length` is `String.get_Length`.  This
            // arm is explicit so a `String` value never falls through to the
            // `case _` collection-count path below (#2539): both used to share the
            // fallback, which routed `.length` to `String.get_Length` and so
            // silently miscompiled `.length` on a `List`-backed slice that also
            // lowered to `MObject`.
            if memberName == "length" {
              insns.add(MCallvirt(methodToken = cctx.tokStringGetLength))
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
              // Read `.count` through the non-generic ICollection so the cast works
              // whether the receiver holds a genuine `List<object>` or a concrete
              // `List<Foo>` extracted from a type-erased container — `castclass
              // List<object>` faults on the latter because generics are invariant.
              insns.add(MCastclass(typeToken = cctx.tokIListCast))
              insns.add(MCallvirt(methodToken = cctx.tokICollGetCount))
              MInt
            } else if memberName == "length" {
              // An `object`-typed receiver reaching here is a `List`-backed slice
              // (slice literal / `toArray()` result whose static type erased to
              // `MObject`); `.length` is its element count.  Read it through the
              // non-generic `ICollection` exactly like `.count` above so it works
              // whether the value is a genuine `List<object>` or a concrete
              // `List<Foo>` (#2539).  Genuine `String` receivers take the explicit
              // `MString` arm above, not this path.
              insns.add(MCastclass(typeToken = cctx.tokIListCast))
              insns.add(MCallvirt(methodToken = cctx.tokICollGetCount))
              MInt
            } else {
              // Emit castclass before ldfld on MObject receivers, mirroring the
              // MClass arm.  fieldDeclaringClassByName carries the declaring FQN
              // registered at addPackageTokens time (#1868).
              val fbyNameKey = fctx.pkgName + "/" + memberName
              match mapGet(cctx.fieldTokensByName, fbyNameKey) {
                case Some(tok) -> {
                  match mapGet(cctx.fieldDeclaringClassByName, fbyNameKey) {
                    case Some(declCls) -> insns.add(MCastclassByName(className = declCls))
                    case None -> ()
                  }
                  insns.add(MLdfld(fieldToken = tok))
                  match mapGet(cctx.fieldMsilTypes, fbyNameKey) {
                    case Some(fty) -> fty
                    case None -> MObject
                  }
                }
                case None -> {
                  MObject
                }
              }
            }
          }
        }
      }  // else: not a config field access
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
      // When the surrounding context expects a concrete `List<Foo>` (binding
      // annotation / return / call-arg / field), build the genuine instance and
      // add each element through the concrete `Add` (no box for refs).  Each
      // element is lowered with the element type pushed onto collExpect so a
      // nested `[[...]]` literal also builds concretely.  Otherwise fall back to
      // the legacy `List<object>` (returns MObject).
      match collExpectTop(fctx) {
        case MConcreteList(e) -> {
          insns.add(MListOp(op = LoCtor, elemTy = e))
          var celi = 0
          while celi < exprs.count {
            insns.add(MDup)
            pushCollExpect(fctx, e)
            val ceTy = lowerExprMsil(cctx, fctx, insns, exprs[celi])
            popCollExpect(fctx)
            collBoxIfNeeded(cctx, insns, ceTy, MConcreteList(elemTy = e))
            insns.add(MListOp(op = LoAdd, elemTy = e))
            celi = celi + 1
          }
          MConcreteList(elemTy = e)
        }
        // A slice-typed context (`slice[T]` lowers to `MArray`): build a genuine
        // CLR `T[]` via `newarr` + `stelem`, not a `List`.  This makes a
        // self-hosted slice value byte-compatible with the F# emitter's array
        // representation, so passing it to an array-typed boundary — notably the
        // F#-compiled `Std.Sort.sortInts(Int[])` — works instead of silently
        // mis-binding a `List` to an array parameter (#2592).  Element types we
        // can't name a token for fall through to the legacy List path below.
        case MArray(e) -> {
          match arrayElemTokenOpt(cctx, e) {
            case Some(elemTok) -> {
              insns.add(MLdcI4(v = exprs.count))
              insns.add(MNewarr(typeToken = elemTok))
              var ali = 0
              while ali < exprs.count {
                insns.add(MDup)
                insns.add(MLdcI4(v = ali))
                pushCollExpect(fctx, e)
                val aeTy = lowerExprMsil(cctx, fctx, insns, exprs[ali])
                popCollExpect(fctx)
                // An `object[]` stores boxed value elements; a typed array
                // (`Int[]`, `String[]`, …) stores them unboxed via `stelem <T>`.
                match e {
                  case MObject -> boxIfNeededMsil(cctx, insns, aeTy)
                  case _ -> ()
                }
                insns.add(MStelem(typeToken = elemTok))
                ali = ali + 1
              }
              MArray(elemTy = e)
            }
            case None -> {
              insns.add(MNewobj(ctorToken = cctx.tokListObjCtor))
              var eli2 = 0
              while eli2 < exprs.count {
                insns.add(MDup)
                val eTy2 = lowerExprMsil(cctx, fctx, insns, exprs[eli2])
                boxIfNeededMsil(cctx, insns, eTy2)
                insns.add(MCallvirt(methodToken = cctx.tokListObjAdd))
                eli2 = eli2 + 1
              }
              MObject
            }
          }
        }
        case _ -> {
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
      }
    }

    // ── Await ─────────────────────────────────────────────────────────────────
    // When inside a Phase B.1 SM MoveNext body, emit the full suspend/resume
    // protocol.  Otherwise emit a blocking synchronous shim (GetAwaiter+GetResult).
    // Non-Task values (blocking @externTarget async, or already-resolved results)
    // are passed through as-is: the value is already on the stack.
    //
    // TODO(#2737): await inside a try/catch/finally region is unsupported —
    // the CLR protected region would span a suspend/resume point — and causes
    // InvalidProgramException at runtime.  The mode checker does not reject it
    // yet; V0012 covers return-in-try but not await-in-try.
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
      if fctx.lazyGenCtx.count > 0 {
        val lgctx = fctx.lazyGenCtx[0]
        val idx = lgctx.nextYieldIndex.count
        lgctx.nextYieldIndex.add(0)
        val resumeLabel = lgctx.resumeLabels[idx]
        // this.__current = box(inner)
        insns.add(MLdarg(slot = 0))
        val eTy = lowerExprMsil(cctx, fctx, insns, inner)
        boxIfNeededMsil(cctx, insns, eTy)
        insns.add(MStfldByName(ownerFqn = lgctx.genFqn, fieldName = "__current"))
        // this._state = idx  (0-based; switch(resumeLabels)[idx] dispatches here next call)
        insns.add(MLdarg(slot = 0))
        insns.add(MLdcI4(v = idx))
        insns.add(MStfldByName(ownerFqn = lgctx.genFqn, fieldName = "_state"))
        // this._tcs.SetResult(true)
        insns.add(MLdarg(slot = 0))
        insns.add(MLdfldByName(ownerFqn = lgctx.genFqn, fieldName = "_tcs"))
        insns.add(MCastclass(typeToken = lgctx.tcsTypeSpecToken))
        insns.add(MLdcI4(v = 1))
        insns.add(MCallvirt(methodToken = lgctx.tokTcsSetResult))
        // leave AFTER_TRY  (exit the try block; stack is clear after leave)
        insns.add(MLeave(label = lgctx.leaveLabel))
        // Resume label: next MoveNextAsync call dispatches here via state switch
        insns.add(MLabel(id = resumeLabel))
      } else if fctx.yieldSlots.count > 0 {
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
      if indices.count == 0 {
        // Malformed index expression with no subscript — the parser does not
        // produce this, but mirror the assign-arm guard so the stack stays
        // balanced and we don't emit a dangling get_Item with no index argument.
        lowerExprMsil(cctx, fctx, insns, recv)
        insns.add(MPop)
        MObject
      } else {
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
          case MConcreteList(elemTy) -> {
            // Concrete List[T] read: `get_Item` returns the element typed
            // (`!0` = elemTy), so no read-narrow cast is needed.
            emitListCastRecv(cctx, insns, recvTy)
            if indices.count > 0 {
              lowerExprMsil(cctx, fctx, insns, indices[0])
            }
            emitListGetItem(cctx, insns, recvTy)
            elemTy
          }
          case MConcreteMap(_, valTy) -> {
            // Concrete Map[K, V] read: the key is passed unboxed (the
            // `get_Item(!0)` MemberRef binds to the concrete key type, ref or
            // value) and `get_Item` returns the value typed (`!1` = valTy), so no
            // box on the key and no unbox on the result.
            emitDictCastRecv(cctx, insns, recvTy)
            if indices.count > 0 {
              lowerExprMsil(cctx, fctx, insns, indices[0])
            }
            emitDictGetItem(cctx, insns, recvTy)
            valTy
          }
          case MArray(elem) -> {
            // `MArray` is the lowered static type of `slice[T]`, but a slice value
            // is one of two runtime representations behind that single static type:
            // a genuine CLI array (e.g. `String[]` from `String.Split`) or a
            // `List`-backed slice (slice literal, `toArray()` / sub-slice copy,
            // or a `List` value passed into a `slice[T]` parameter whose signature
            // declares `T[]`).  A raw `ldelem` faults / reads garbage on the
            // `List`-backed case (#2539: `Std.Sort` indexes its `slice[T]` params,
            // which receive `List`-backed values).  Both `System.Array` and
            // `List<T>` implement the non-generic `System.Collections.IList`, so
            // indexing routes through `IList.get_Item(int32)` (returns `object`),
            // then unboxes / narrows to the element type — correct for either
            // representation.
            insns.add(MCastclass(typeToken = cctx.tokIListCast))
            if indices.count > 0 {
              lowerExprMsil(cctx, fctx, insns, indices[0])
            }
            insns.add(MCallvirt(methodToken = cctx.tokIListGetItem))
            if isValueType(elem) {
              castObjectToMsil(cctx, insns, elem)
              elem
            } else {
              match elem {
                case MString -> {
                  insns.add(MCastclassByName(className = "System.String"))
                  MString
                }
                case MClass(c) -> {
                  insns.add(MCastclassByName(className = c))
                  MClass(className = c)
                }
                case _ -> elem
              }
            }
          }
          case _ -> {
            // Read through the non-generic IList so an `object`-typed receiver works
            // whether it holds a genuine `List<object>` or a concrete `List<Foo>`
            // from a type-erased container — `castclass List<object>` faults on the
            // latter because generics are invariant; IList is implemented by every
            // List<T> and T[].  IList.get_Item(int32) returns `object`.
            insns.add(MCastclass(typeToken = cctx.tokIListCast))
            if indices.count > 0 {
              lowerExprMsil(cctx, fctx, insns, indices[0])
            }
            insns.add(MCallvirt(methodToken = cctx.tokIListGetItem))
            MObject
          }
        }
      } // else indices.count > 0
    }

    // ── Quantifiers and old-state ─────────────────────────────────────────────
    // `forall`/`exists` are proof-time quantifiers that can express properties
    // over infinite or unbounded domains.  In `@runtime_checked` modules the
    // contract elaborator substitutes snapshot variables for `old(e)` before
    // reaching here, and quantifiers are approximated as `true` at runtime
    // (a sound overapproximation — the assert passes, no false-negative crash).
    // W0002 informs the user so they aren't surprised by the unenforced clause.
    case EForall(_, _, _) -> {
      println(
        "W0002: forall quantifier in @runtime_checked contract is not evaluated at runtime " +
          "(sound overapproximation as true; consider restricting the domain or using @proof_required)"
      )
      insns.add(MLdcI4(v = 1))
      MBool
    }
    case EExists(_, _, _) -> {
      println(
        "W0002: exists quantifier in @runtime_checked contract is not evaluated at runtime " +
          "(sound overapproximation as true; consider restricting the domain or using @proof_required)"
      )
      insns.add(MLdcI4(v = 1))
      MBool
    }
    // `EOld` is materialised as `let __old_N = e` by the contract elaborator;
    // reaching codegen means the elaborator was bypassed — compiler bug.
    case EOld(_) -> {
      panic("Msil.Codegen: EOld reached codegen — contract elaborator must run before emitting MSIL")
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
          val ty = match mapGet(fctx.types, "result") { case Some(t) -> t; case None -> MObject }
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
        if fctx.captureNameToIndex.containsKey(cn) {
          // Re-captured from the enclosing lambda's own capture array (#1479 multi-level).
          // Propagate the cell if the outer closure marked it as a cell capture;
          // otherwise propagate the value type from captureNameToType.
          // capTypes is added unconditionally; capCells only for cell captures (#2948).
          capTypes.add(match mapGet(fctx.captureNameToType, cn) { case Some(t) -> t; case None -> MObject })
          if nameListContains(fctx.captureCellNames, cn) {
            capCells.add(cn)
          }
        } else {
          match mapGet(fctx.hoistedCellSlot, cn) {
            case Some(_) -> {
              capTypes.add(match mapGet(fctx.hoistedCellType, cn) { case Some(t) -> t; case None -> MObject })
              capCells.add(cn)
            }
            case None -> {
              if nameListContains(fctx.mutableLocals, cn) {
                panic(
                  "Msil.Codegen: internal error — captured mutable (`var`) local '" + cn +
                    "' was not hoisted to a heap cell (#1479 v2 closure-capture " +
                    "pre-pass missed it).  Please report this with a reproducer."
                )
              }
              capTypes.add(match mapGet(fctx.types, cn) { case Some(t) -> t; case None -> MObject })
            }
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
          case None -> newList()
        }
        var lpi2 = 0
        while lpi2 < lparams.count {
          val lp = lparams[lpi2]
          val isUsed = nameListContains(lpRefs, lp.name)
          val isAnnotated = match lp.ty { case Some(_) -> true; case None -> false }
          val isPropagated = lpi2 < propagated.count
          if isUsed and not isAnnotated and not isPropagated {
            panic(
              "Msil.Codegen: a lambda that uses an un-annotated parameter " + "('" + lp.name +
                "') outside a direct higher-order-function call " +
                "is not yet supported on --target dotnet — the boxed argument has " +
                "no type to unbox to (#1939).  Annotate the parameter type (e.g. " +
                "`{ " +
                lp.name +
                ": Int -> … }`), pass the lambda directly to a " +
                "function with a typed `(…) -> R` parameter, use a zero-argument " +
                "lambda, or lift the lambda to a top-level function."
            )
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
          val returnsVoid = match retType { case Some(MVoid) -> true; case None -> true; case _ -> false }
          val ctorTok = if returnsVoid {
            if nparams == 0 {
              cctx.tokActionCtor
            } else {
              buildActionNCtorTok(cctx, nparams)
            }
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
              val capName = caps[capStI]
              if fctx.captureNameToIndex.containsKey(capName) {
                // Re-capture from outer closure's __caps array (#1479 multi-level).
                // Load __caps (slot 0), then index into it.  If it's a cell
                // capture, the cell reference is already boxed as object in __caps
                // and is forwarded directly.  If it's a value capture, the value
                // is already boxed as object in __caps and is forwarded directly.
                val outerIdx = match mapGet(fctx.captureNameToIndex, capName) { case Some(n) -> n; case None -> 0 }
                emitLoadVarMsil(fctx, insns, 0)
                insns.add(MLdcI4(v = outerIdx))
                insns.add(MLdelemRef)
              } else if nameListContains(capCells, capName) {
                // By-reference: store the cell (a `List[object]` reference) itself
                // so the closure and enclosing scope share it — no box (#1479 v2).
                match mapGet(fctx.hoistedCellSlot, capName) {
                  case Some(s) -> emitLoadVarMsil(fctx, insns, s)
                  case None -> panic("Msil.Codegen ICE: captured name '" + capName + "' not found in fctx.hoistedCellSlot — lambdaCaptureNamesMsil should only return names present in the enclosing scope")
                }
              } else {
                match mapGet(fctx.slots, capName) {
                  case Some(s) -> emitLoadVarMsil(fctx, insns, s)
                  case None -> panic("Msil.Codegen ICE: captured name '" + capName + "' not found in fctx.slots — lambdaCaptureNamesMsil should only return names present in the enclosing scope")
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
      panic(
        "Msil.Codegen: a range expression (`lo .. hi`) is only supported as a `for`-loop iterator or a match pattern on --target dotnet; first-class range values are not yet materialised (#1478)."
      )
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
  val fqn = match ty { case MClass(c) -> c; case MGenericInst(_, headFqn, _) -> headFqn; case _ -> "" }
  if fqn.length == 0 {
    return 0 - 1
  }
  match mapGet(cctx.funcTokens, fqn + ".equals") {
    case Some(t) -> t
    case None -> 0 - 1
  }
}

func lowerBinopMsil(
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  op: in BinOp,
  lhs: in Expr,
  rhs: in Expr,
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
      insns.add(MLabel(id = falseL))
      insns.add(MLdcI4(v = 0))
      insns.add(MLabel(id = afterL))
      MBool
    }
    // Boolean short-circuit OR.
    case BOr -> {
      val trueL = freshLabelMsil(fctx)
      val afterL = freshLabelMsil(fctx)
      lowerExprMsil(cctx, fctx, insns, lhs)
      insns.add(MBrTrue(label = trueL))
      lowerExprMsil(cctx, fctx, insns, rhs)
      insns.add(MBrTrue(label = trueL))
      insns.add(MLdcI4(v = 0))
      insns.add(MBr(label = afterL))
      insns.add(MLabel(id = trueL))
      insns.add(MLdcI4(v = 1))
      insns.add(MLabel(id = afterL))
      MBool
    }
    // Comparison operators — produce 0 or 1.
    case BEq -> {
      val beqLhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      // Equality is symmetric: treat as commutative — just ldloc spill after rhs.
      val beqSpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
        phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, beqLhsTy)
      } else {
        -1
      }
      val beqRhsTy = lowerExprMsil(cctx, fctx, insns, rhs)
      if beqSpillIdx >= 0 {
        insns.add(MLdloc(slot = beqSpillIdx))
      }
      match beqLhsTy {
        case MInt | MBool | MChar | MLong | MDouble | MByte -> {
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
      } else {
        -1
      }
      val bneqRhsTy = lowerExprMsil(cctx, fctx, insns, rhs)
      if bneqSpillIdx >= 0 {
        insns.add(MLdloc(slot = bneqSpillIdx))
      }
      match bneqLhsTy {
        case MInt | MBool | MChar | MLong | MDouble | MByte -> {
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
      } else {
        -1
      }
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
      if bltLhsTy == MObject and isValueType(bltRhsTy) {
        // Lhs arrived as an erased object while rhs is a concrete value type;
        // spill rhs, unbox lhs to match rhs's numeric type, reload rhs so that
        // clt receives two operands of the same type (required by ECMA-335 III.3.27).
        val bltLhsUnboxN = "__blt_lhu_" + toString(fctx.slotTicker.count)
        val bltLhsUnboxS = allocSlotMsil(fctx, bltLhsUnboxN, bltRhsTy)
        insns.add(MStloc(slot = bltLhsUnboxS - fctx.paramCount))
        insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, bltRhsTy)))
        insns.add(MLdloc(slot = bltLhsUnboxS - fctx.paramCount))
      }
      match bltLhsTy {
        case MString -> {
          // `a < b`  ≡  `String.CompareOrdinal(a, b) < 0` (#2539): a raw `clt`
          // on two string references compares pointers, not text.
          insns.add(MCall(methodToken = cctx.tokStringCompareOrdinal))
          insns.add(MLdcI4(v = 0))
          insns.add(MClt)
        }
        case _ -> insns.add(MClt)
      }
      MBool
    }
    case BGt -> {
      val bgtLhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      val bgtSpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
        phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, bgtLhsTy)
      } else {
        -1
      }
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
      if bgtLhsTy == MObject and isValueType(bgtRhsTy) {
        // Symmetric lhs-unbox: lhs is erased object, rhs is a concrete value type.
        // Spill rhs, unbox lhs to rhs's numeric type, reload rhs so that
        // cgt receives two operands of the same type (ECMA-335 III.3.26).
        val bgtLhsUnboxN = "__bgt_lhu_" + toString(fctx.slotTicker.count)
        val bgtLhsUnboxS = allocSlotMsil(fctx, bgtLhsUnboxN, bgtRhsTy)
        insns.add(MStloc(slot = bgtLhsUnboxS - fctx.paramCount))
        insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, bgtRhsTy)))
        insns.add(MLdloc(slot = bgtLhsUnboxS - fctx.paramCount))
      }
      match bgtLhsTy {
        case MString -> {
          // `a > b`  ≡  `String.CompareOrdinal(a, b) > 0` (#2539).
          insns.add(MCall(methodToken = cctx.tokStringCompareOrdinal))
          insns.add(MLdcI4(v = 0))
          insns.add(MCgt)
        }
        case _ -> insns.add(MCgt)
      }
      MBool
    }
    case BLte -> {
      // a <= b  ≡  !(a > b)
      val blteLhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      val blteSpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
        phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, blteLhsTy)
      } else {
        -1
      }
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
      if blteLhsTy == MObject and isValueType(blteRhsTy) {
        // Symmetric lhs-unbox: lhs is erased object, rhs is a concrete value type.
        // Spill rhs, unbox lhs to rhs's numeric type, reload rhs so that
        // cgt (for <=  ≡  !(a>b)) receives two operands of the same type.
        val blteLhsUnboxN = "__blte_lhu_" + toString(fctx.slotTicker.count)
        val blteLhsUnboxS = allocSlotMsil(fctx, blteLhsUnboxN, blteRhsTy)
        insns.add(MStloc(slot = blteLhsUnboxS - fctx.paramCount))
        insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, blteRhsTy)))
        insns.add(MLdloc(slot = blteLhsUnboxS - fctx.paramCount))
      }
      match blteLhsTy {
        case MString -> {
          // `a <= b`  ≡  `!(String.CompareOrdinal(a, b) > 0)` (#2539).
          insns.add(MCall(methodToken = cctx.tokStringCompareOrdinal))
          insns.add(MLdcI4(v = 0))
          insns.add(MCgt)
        }
        case _ -> insns.add(MCgt)
      }
      insns.add(MLdcI4(v = 1))
      insns.add(MXor)
      MBool
    }
    case BGte -> {
      // a >= b  ≡  !(a < b)
      val bgteLhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      val bgteSpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
        phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, bgteLhsTy)
      } else {
        -1
      }
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
      if bgteLhsTy == MObject and isValueType(bgteRhsTy) {
        // Symmetric lhs-unbox: lhs is erased object, rhs is a concrete value type.
        // Spill rhs, unbox lhs to rhs's numeric type, reload rhs so that
        // clt (for >=  ≡  !(a<b)) receives two operands of the same type.
        val bgteLhsUnboxN = "__bgte_lhu_" + toString(fctx.slotTicker.count)
        val bgteLhsUnboxS = allocSlotMsil(fctx, bgteLhsUnboxN, bgteRhsTy)
        insns.add(MStloc(slot = bgteLhsUnboxS - fctx.paramCount))
        insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, bgteRhsTy)))
        insns.add(MLdloc(slot = bgteLhsUnboxS - fctx.paramCount))
      }
      match bgteLhsTy {
        case MString -> {
          // `a >= b`  ≡  `!(String.CompareOrdinal(a, b) < 0)` (#2539).
          insns.add(MCall(methodToken = cctx.tokStringCompareOrdinal))
          insns.add(MLdcI4(v = 0))
          insns.add(MClt)
        }
        case _ -> insns.add(MClt)
      }
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
          val saddName = "__sadd_" + toString(fctx.slotTicker.count)
          val saddLhsSlot = allocSlotMsil(fctx, saddName, MString)
          val saddLhsLocalIdx = saddLhsSlot - fctx.paramCount
          insns.add(MStloc(slot = saddLhsLocalIdx))
          if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
            phaseBRegisterAndSyncLocal(fctx.phaseBCtx[0], insns, saddName, MString, saddLhsLocalIdx)
          }
          val saddRhsTy = lowerExprMsil(cctx, fctx, insns, rhs)
          match saddRhsTy {
            case MString -> {
            }
            case _ -> {
              // Convert non-string rhs to string: box value types, then call ToString().
              if isValueType(saddRhsTy) {
                boxIfNeededMsil(cctx, insns, saddRhsTy)
              }
              insns.add(MCallvirt(methodToken = cctx.tokObjToString))
            }
          }
          val saddRhsSlot = allocSlotMsil(fctx, "__sadd_r_" + toString(fctx.slotTicker.count), MString)
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
          } else {
            -1
          }
          lowerExprMsil(cctx, fctx, insns, rhs)
          if baddLSpillIdx >= 0 {
            insns.add(MLdloc(slot = baddLSpillIdx))
          }
          insns.add(MAdd)
          MLong
        }
        case MDouble -> {
          val baddDSpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
            phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, MDouble)
          } else {
            -1
          }
          lowerExprMsil(cctx, fctx, insns, rhs)
          if baddDSpillIdx >= 0 {
            insns.add(MLdloc(slot = baddDSpillIdx))
          }
          insns.add(MAdd)
          MDouble
        }
        case _ -> {
          val baddISpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
            phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, MInt)
          } else {
            -1
          }
          lowerExprMsil(cctx, fctx, insns, rhs)
          if baddISpillIdx >= 0 {
            insns.add(MLdloc(slot = baddISpillIdx))
          }
          insns.add(MAdd)
          MInt
        }
      }
    }
    case BSub -> {
      val bsubLhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      val bsubSpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
        phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, bsubLhsTy)
      } else {
        -1
      }
      val bsubRhsTy = lowerExprMsil(cctx, fctx, insns, rhs)
      if bsubSpillIdx >= 0 {
        val rN = "__spill_r_" + toString(fctx.slotTicker.count)
        val rS = allocSlotMsil(fctx, rN, bsubRhsTy)
        insns.add(MStloc(slot = rS - fctx.paramCount))
        insns.add(MLdloc(slot = bsubSpillIdx))
        insns.add(MLdloc(slot = rS - fctx.paramCount))
      }
      match bsubLhsTy {
        case MLong -> {
          insns.add(MSub)
          MLong
        }
        case MDouble -> {
          insns.add(MSub)
          MDouble
        }
        case _ -> {
          insns.add(MSub)
          MInt
        }
      }
    }
    case BMul -> {
      val bmulLhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      // mul is commutative: just reload spill after rhs.
      val bmulSpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
        phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, bmulLhsTy)
      } else {
        -1
      }
      lowerExprMsil(cctx, fctx, insns, rhs)
      if bmulSpillIdx >= 0 {
        insns.add(MLdloc(slot = bmulSpillIdx))
      }
      match bmulLhsTy {
        case MLong -> {
          insns.add(MMul)
          MLong
        }
        case MDouble -> {
          insns.add(MMul)
          MDouble
        }
        case _ -> {
          insns.add(MMul)
          MInt
        }
      }
    }
    case BDiv -> {
      val bdivLhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      val bdivSpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
        phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, bdivLhsTy)
      } else {
        -1
      }
      val bdivRhsTy = lowerExprMsil(cctx, fctx, insns, rhs)
      if bdivSpillIdx >= 0 {
        val rN = "__spill_r_" + toString(fctx.slotTicker.count)
        val rS = allocSlotMsil(fctx, rN, bdivRhsTy)
        insns.add(MStloc(slot = rS - fctx.paramCount))
        insns.add(MLdloc(slot = bdivSpillIdx))
        insns.add(MLdloc(slot = rS - fctx.paramCount))
      }
      match bdivLhsTy {
        case MLong -> {
          insns.add(MDiv)
          MLong
        }
        case MDouble -> {
          insns.add(MDiv)
          MDouble
        }
        case _ -> {
          insns.add(MDiv)
          MInt
        }
      }
    }
    case BMod -> {
      val bmodLhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      val bmodSpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
        phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, bmodLhsTy)
      } else {
        -1
      }
      val bmodRhsTy = lowerExprMsil(cctx, fctx, insns, rhs)
      if bmodSpillIdx >= 0 {
        val rN = "__spill_r_" + toString(fctx.slotTicker.count)
        val rS = allocSlotMsil(fctx, rN, bmodRhsTy)
        insns.add(MStloc(slot = rS - fctx.paramCount))
        insns.add(MLdloc(slot = bmodSpillIdx))
        insns.add(MLdloc(slot = rS - fctx.paramCount))
      }
      match bmodLhsTy {
        case MLong -> {
          insns.add(MRem)
          MLong
        }
        case _ -> {
          insns.add(MRem)
          MInt
        }
      }
    }
    case BXor -> {
      val bxorLhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      // xor is commutative: just reload spill after rhs.
      val bxorSpillIdx = if fctx.phaseBCtx.count > 0 and exprContainsAwaitMsil(rhs) {
        phaseBSpillToLocal(fctx.phaseBCtx[0], fctx, insns, bxorLhsTy)
      } else {
        -1
      }
      lowerExprMsil(cctx, fctx, insns, rhs)
      if bxorSpillIdx >= 0 {
        insns.add(MLdloc(slot = bxorSpillIdx))
      }
      insns.add(MXor)
      MInt
    }
    case BCoalesce -> {
      // Null-coalescing: if lhs is non-null use it, else use rhs.
      val lhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      val nullL = freshLabelMsil(fctx)
      val afterL = freshLabelMsil(fctx)
      insns.add(MDup)
      insns.add(MBrFalse(label = nullL))
      insns.add(MBr(label = afterL))
      insns.add(MLabel(id = nullL))
      insns.add(MPop)
      lowerExprMsil(cctx, fctx, insns, rhs)
      insns.add(MLabel(id = afterL))
      lhsTy
    }
    case BImplies -> {
      // p => q  ≡  !p || q
      val trueL = freshLabelMsil(fctx)
      val afterL = freshLabelMsil(fctx)
      lowerExprMsil(cctx, fctx, insns, lhs)
      insns.add(MBrFalse(label = trueL))  // if lhs false, result is true
      lowerExprMsil(cctx, fctx, insns, rhs)
      insns.add(MBr(label = afterL))
      insns.add(MLabel(id = trueL))
      insns.add(MLdcI4(v = 1))
      insns.add(MLabel(id = afterL))
      MBool
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5b. If expression lowering.
// ─────────────────────────────────────────────────────────────────────────────
func lowerExprOrBlockMsil(cctx: in CodegenCtx, fctx: in FuncCtx, insns: in List[MInsn], eob: in ExprOrBlock): MsilType {
  match eob {
    case EOBExpr(e) -> lowerExprMsil(cctx, fctx, insns, e)
    case EOBBlock(blk) -> lowerBlockExprMsil(cctx, fctx, insns, blk)
  }
}

// INVARIANT: each branch must be label-self-contained (no MBr to a label defined outside).
// Cross-frame control flow across this boundary risks silent JIT failures (global label IDs in temp lists).
func lowerIfExprMsil(
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  cond: in Expr,
  thenBranch: in ExprOrBlock,
  elseBranchOpt: in Option[ExprOrBlock],
): MsilType {
  val elseL = freshLabelMsil(fctx)
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
      if thenTy == MVoid or elseTy == MVoid {
        MVoid
      } else {
        thenTy
      }
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
func lowerBlockExprMsil(cctx: in CodegenCtx, fctx: in FuncCtx, insns: in List[MInsn], block: in Block): MsilType {
  lowerStmtsExprFromMsil(cctx, fctx, insns, block.statements, 0)
}

// Value-producing counterpart of `lowerStmtsFromMsil`: lower statements[start..]
// leaving the trailing value on the stack, honouring `defer`.  When a `defer`
// precedes the value-producing statements, those statements run inside a
// `try`/`finally(D)`; the trailing value is stashed in a temp before the `leave`
// (a `leave` requires an empty evaluation stack) and reloaded after the region,
// so the deferred block runs on scope exit while the block still yields its
// value.  #1477.
func lowerStmtsExprFromMsil(
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  stmts: in List[Statement],
  start: in Int,
): MsilType {
  val n = stmts.count
  if start >= n {
    return MVoid
  }
  // Locate the first `defer` at or after `start`.
  var deferIdx = -1
  var di = start
  while di < n {
    match stmts[di].kind {
      case SDefer(_) -> {
        deferIdx = di
        di = n
      }
      case _ -> {
        di = di + 1
      }
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
      case STry(tbody, tcatches, tfinally) -> lowerTryCatchExprMsil(cctx, fctx, insns, tbody, tcatches, tfinally)
      case _ -> {
        lowerStmtMsil(cctx, fctx, insns, last)
        MVoid
      }
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
    case _ -> panic("Msil.Codegen: lowerStmtsExprFromMsil: deferIdx points at non-SDefer statement (compiler bug)")
  }
  val tryStartL = freshLabelMsil(fctx)
  val afterL = freshLabelMsil(fctx)
  insns.add(MLabel(id = tryStartL))
  fctx.tryRegionStack.add(0)
  val valTy = lowerStmtsExprFromMsil(cctx, fctx, insns, stmts, deferIdx + 1)
  var tmpSlot = -1
  match valTy {
    case MVoid -> {
    }
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
  val finallyEndL = freshLabelMsil(fctx)
  insns.add(MLabel(id = finallyStartL))
  lowerBlockMsil(cctx, fctx, insns, deferBody)
  insns.add(MEndfinally)
  insns.add(MLabel(id = finallyEndL))
  insns.add(
    MEHClause(
      flags = 2,
      tryStart = tryStartL,
      tryEnd = finallyStartL,
      handlerStart = finallyStartL,
      handlerEnd = finallyEndL,
      catchToken = 0
    )
  )
  insns.add(MLabel(id = afterL))
  if tmpSlot >= 0 {
    emitLoadSlot(insns, tmpSlot, fctx.paramCount)
  }
  valTy
}

// Push a hoisted-`var` cell onto the stack (#1479 v2): either an enclosing-scope
// cell at a local slot (`isCapture=false`, `idx`=slot) or a by-reference cell
// captured into `object[] __caps` (`isCapture=true`, `idx`=capture index).
func emitCellLoadMsil(fctx: in FuncCtx, insns: in List[MInsn], isCapture: in Bool, idx: in Int): Unit {
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
func emitCellAssignMsil(
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  isCapture: in Bool,
  idx: in Int,
  elemTy: in MsilType,
  op: in AssignOp,
  value: in Expr,
): Unit {
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
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  target: in Expr,
  op: in AssignOp,
  value: in Expr,
): MsilType {
  match target.kind {
    case EPath(path) -> {
      val name = lastSegmentMsil(path)
      // Write to a `var` hoisted to a heap cell (#1479 v2) — checked before the
      // plain-slot path (the slot holds the cell reference, not the value).
      match mapGet(fctx.hoistedCellSlot, name) {
        case Some(cellSlot) -> {
          val elemTy = match mapGet(fctx.hoistedCellType, name) { case Some(t) -> t; case None -> MObject }
          emitCellAssignMsil(cctx, fctx, insns, false, cellSlot, elemTy, op, value)
          return MVoid
        }
        case None -> {
        }
      }
      match mapGet(fctx.slots, name) {
        case Some(slot) -> {
          val ty = match mapGet(fctx.types, name) { case Some(t) -> t; case None -> MObject }
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
                  pushCollExpect(fctx, elemTy)
                  lowerExprMsil(cctx, fctx, insns, value)
                  popCollExpect(fctx)
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
              // A `xs = newList()` reassignment must build the concrete instance
              // the local's tracked type expects — a later concrete op would fault
              // if handed a plain `List<object>` where `List<Foo>` is required.
              pushCollExpect(fctx, ty)
              lowerExprMsil(cctx, fctx, insns, value)
              popCollExpect(fctx)
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
                val capTy = match mapGet(fctx.captureNameToType, name) { case Some(t) -> t; case None -> MObject }
                emitCellAssignMsil(cctx, fctx, insns, true, capIdx, capTy, op, value)
                return MVoid
              }
            }
            case None -> {
            }
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
          val ty = match mapGet(fctx.types, "result") { case Some(t) -> t; case None -> MObject }
          match op {
            case AssEq -> {
              pushCollExpect(fctx, ty)
              lowerExprMsil(cctx, fctx, insns, value)
              popCollExpect(fctx)
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
                  // A `recv.field = newList()` assignment must build the concrete
                  // instance the field's tracked type expects (e.g.
                  // `state.pendingTrivia = newList()` for a `List[Trivia]` field).
                  val fldTyA = match mapGet(cctx.fieldMsilTypes, key) { case Some(t) -> t; case None -> MObject }
                  pushCollExpect(fctx, fldTyA)
                  val _vt = lowerExprMsil(cctx, fctx, insns, value)
                  popCollExpect(fctx)
                  insns.add(MStfld(fieldToken = tok))
                }
                case _ -> {
                  val fldTy = match mapGet(cctx.fieldMsilTypes, key) { case Some(t) -> t; case None -> MObject }
                  insns.add(MDup)  // recv, recv
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
              case MConcreteMap(_, _) -> {
                // Concrete Dictionary store: key/value stored unboxed
                // (the `!0`/`!1` MemberRef binds to the concrete K/V).
                emitDictCastRecv(cctx, insns, recvTy)
                val kTy = lowerExprMsil(cctx, fctx, insns, indices[0])
                collBoxIfNeeded(cctx, insns, kTy, recvTy)
                val vTy = lowerExprMsil(cctx, fctx, insns, value)
                collBoxIfNeeded(cctx, insns, vTy, recvTy)
                emitDictSetItem(cctx, insns, recvTy)
              }
              case MConcreteList(_) -> {
                // Concrete List store: set_Item(int32, !0); value stored
                // unboxed.
                emitListCastRecv(cctx, insns, recvTy)
                lowerExprMsil(cctx, fctx, insns, indices[0])
                val vTy = lowerExprMsil(cctx, fctx, insns, value)
                collBoxIfNeeded(cctx, insns, vTy, recvTy)
                emitListSetItem(cctx, insns, recvTy)
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
            val isMap = match recvTy { case MMapOf(_, _) -> true; case MConcreteMap(_, _) -> true; case _ -> false }
            // The container ref is stashed in an `object`-typed temp, so the
            // static List/Dictionary type is re-asserted with `castclass` after
            // every reload — the JIT verifier rejects a callvirt of get_Item /
            // set_Item on a bare `object` receiver (mirrors the read path's
            // immediate castclass at the EIndex read arm above).  The
            // concrete-aware helpers emit the closed-generic castclass /
            // get_Item / set_Item when `recvTy` is `MConcreteList`/`MConcreteMap`.
            if isMap {
              emitDictCastRecv(cctx, insns, recvTy)
            } else {
              emitListCastRecv(cctx, insns, recvTy)
            }
            // For a concrete collection the key/value live unboxed — the `!0`/`!1`
            // MemberRefs bind to the concrete K/V, so the box on the key, the unbox
            // after `get_Item`, and the box before `set_Item` are all dropped; the
            // key/value temps take the real element type rather than `object`.
            val isConcreteColl = isConcreteCollTy(recvTy)
            val ckTy = match recvTy {
              case MConcreteMap(k, _) -> k
              case MConcreteList(_) -> MInt
              case _ -> if isMap { MObject } else { MInt }
            }
            val cSlot = allocSlotMsil(fctx, "__cidx_c_" + toString(fctx.slotTicker.count), MObject)
            emitStoreSlot(insns, cSlot, fctx.paramCount)
            // Index/key: boxed for a legacy Map, raw for a List / concrete coll.
            val kRawTy = lowerExprMsil(cctx, fctx, insns, indices[0])
            if isMap {
              collBoxIfNeeded(cctx, insns, kRawTy, recvTy)
            }
            val kSlot = allocSlotMsil(fctx, "__cidx_k_" + toString(fctx.slotTicker.count), ckTy)
            emitStoreSlot(insns, kSlot, fctx.paramCount)
            // Right-hand operand up-front — its type is the element type.
            val rTy = lowerExprMsil(cctx, fctx, insns, value)
            val rSlot = allocSlotMsil(fctx, "__cidx_r_" + toString(fctx.slotTicker.count), rTy)
            emitStoreSlot(insns, rSlot, fctx.paramCount)
            // current = container[key]
            emitLoadSlot(insns, cSlot, fctx.paramCount)
            if isMap {
              emitDictCastRecv(cctx, insns, recvTy)
            } else {
              emitListCastRecv(cctx, insns, recvTy)
            }
            emitLoadSlot(insns, kSlot, fctx.paramCount)
            if isMap {
              emitDictGetItem(cctx, insns, recvTy)
            } else {
              emitListGetItem(cctx, insns, recvTy)
            }
            if not isConcreteColl {
              materializeBoxedElemMsil(cctx, insns, rTy)
            }
            emitCompoundCombineSlotMsil(cctx, fctx, insns, op, rTy, rSlot)
            collBoxIfNeeded(cctx, insns, rTy, recvTy)
            val vSlotTy = if isConcreteColl { rTy } else { MObject }
            val vSlot = allocSlotMsil(fctx, "__cidx_v_" + toString(fctx.slotTicker.count), vSlotTy)
            emitStoreSlot(insns, vSlot, fctx.paramCount)
            emitLoadSlot(insns, cSlot, fctx.paramCount)
            if isMap {
              emitDictCastRecv(cctx, insns, recvTy)
            } else {
              emitListCastRecv(cctx, insns, recvTy)
            }
            emitLoadSlot(insns, kSlot, fctx.paramCount)
            emitLoadSlot(insns, vSlot, fctx.paramCount)
            if isMap {
              emitDictSetItem(cctx, insns, recvTy)
            } else {
              emitListSetItem(cctx, insns, recvTy)
            }
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
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  scrutinee: in Expr,
  arms: in List[MatchArm],
): MsilType {
  val scrutTy = lowerExprMsil(cctx, fctx, insns, scrutinee)
  val scrutSlot = allocSlotMsil(fctx, "__scrut_" + toString(fctx.slotTicker.count), scrutTy)
  emitStoreSlot(insns, scrutSlot, fctx.paramCount)

  val afterL = freshLabelMsil(fctx)
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
  val armTys: List[MsilType] = newList()
  val armNextLs: List[Int] = newList()
  val armRets: List[Bool] = newList()
  var i = 0
  while i < arms.count {
    val arm = arms[i]
    val nextArmL = freshLabelMsil(fctx)
    val armInsns: List[MInsn] = newList()
    lowerPatternTestMsil(cctx, fctx, armInsns, arm.pattern, scrutSlot, scrutTy, nextArmL)
    lowerPatternBindMsil(cctx, fctx, armInsns, arm.pattern, scrutSlot, scrutTy)
    match arm.guard {
      case Some(g) -> {
        lowerExprMsil(cctx, fctx, armInsns, g)
        armInsns.add(MBrFalse(label = nextArmL))
      }
      case None -> {
      }
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
      } else if armTys[av] != MVoid and firstFallTy != MVoid {
        // Internal-invariant check: the type checker should ensure all non-void
        // fall-through arms have the same type.  If this fires, a type-checker
        // regression reached codegen.
        // Compare canonical keys, not structure: MsilType has multiple
        // representations (by-name vs by-row generic instances) for the
        // same type.  Erased-object arms legitimately mix with concrete
        // arms under erasure, so only a concrete-vs-concrete divergence is
        // suspicious; warn loudly rather than abort the build (#1663).
        //
        // Suppression heuristic: a key is treated as "erased" when it is
        // exactly "O" (bare Object), contains "<O," (a generic instantiation
        // whose first type argument is Object, e.g. Result<O,...>), or
        // contains "[O]" (an array of Object).  These patterns cover the
        // common erasure cases produced by the self-hosted emitter.
        //
        // Caveat: "<O," and "[O]" may also match concrete Object
        // instantiations (e.g. a user type genuinely parameterised with
        // Object).  The W0004 diagnostic is advisory — a missed warning for
        // a legitimate erased arm is acceptable; a noisy warning for a
        // correctly-typed arm is not.
        val k1w = msilTypeKey(firstFallTy)
        val k2w = msilTypeKey(armTys[av])
        val erased1w = k1w == "O" or contains(k1w, "<O,") or contains(k1w, "[O]")
        val erased2w = k2w == "O" or contains(k2w, "<O,") or contains(k2w, "[O]")
        if k1w != k2w and not erased1w and not erased2w {
          println(
            "warning[W0004]: Msil.Codegen: lowerMatchExprMsil fall-through arm type mismatch: first arm " + k1w +
              " vs later arm " +
              k2w +
              " — result uses the first arm's type (possible type-checker regression, #1663)"
          )
        }
      }
      if armTys[av] == MVoid {
        anyVoid = true
      }
    }
    av = av + 1
  }
  val resultTy: MsilType = if not sawFall { MVoid } else if anyVoid { MVoid } else { firstFallTy }

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
  val matchErrMsg = "Msil.Codegen: match not exhaustive in " + fctx.className + "." + fctx.funcName + " scr=" +
    msilTypeKey(scrutTy) +
    " arms=" +
    toString(arms.count)
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
    insns.add(MLabel(id = afterL))
  }
  resultTy
}

// Given a list of union-case FQN candidates that share the same simple
// case name (from `unionCaseCtorByName`), return the best match for a
// call site in `fctx.pkgName`.  Used to resolve same-named cases across
// different packages (#2899).
//
// Resolution order:
//   1. A candidate whose FQN starts with the current package name
//      (same-package construction — `Std.Xml.XmlError_InvalidDocument`
//      wins over `Std.Yaml.YamlError_InvalidDocument` inside Std.Xml).
//   2. A candidate in one of the packages imported by the current package
//      (first import wins, matching the type-checker's shadowing rule).
//   3. First candidate (original first-wins fallback for unresolvable cases).
func pickCaseFqnByScope(cctx: in CodegenCtx, fctx: in FuncCtx, candidates: in List[String]): String {
  if candidates.count == 1 {
    return candidates[0]
  }
  val currentPkg = fctx.pkgName
  val prefix1 = currentPkg + "."
  var i = 0
  while i < candidates.count {
    if startsWith(candidates[i], prefix1) {
      return candidates[i]
    }
    i = i + 1
  }
  match mapGet(cctx.pkgImports, currentPkg) {
    case Some(imps) -> {
      var ii = 0
      while ii < imps.count {
        val prefix2 = imps[ii] + "."
        var j = 0
        while j < candidates.count {
          if startsWith(candidates[j], prefix2) {
            return candidates[j]
          }
          j = j + 1
        }
        ii = ii + 1
      }
    }
    case None -> ()
  }
  candidates[0]
}

// Pattern-matching variant of `pickCaseFqnByScope`.  When `scrutTy`
// names a concrete union class the case whose registered parent union
// matches it is preferred, because the scrutinee's type is the most
// precise signal available.  Falls back to `pickCaseFqnByScope` when
// the scrutinee type is erased (`MObject`) or the parent-union map has
// no entry for any candidate.
func pickCaseFqnByScrutinee(
  cctx: in CodegenCtx, fctx: in FuncCtx, candidates: in List[String], scrutTy: in MsilType
): String {
  if candidates.count == 1 {
    return candidates[0]
  }
  val parentFqn = match scrutTy { case MClass(cls) -> cls; case MGenericInst(_, fqn, _) -> fqn; case _ -> "" }
  if parentFqn.length > 0 {
    var i = 0
    while i < candidates.count {
      match mapGet(cctx.caseParentUnion, candidates[i]) {
        case Some(p) -> {
          if p == parentFqn {
            return candidates[i]
          }
        }
        case None -> ()
      }
      i = i + 1
    }
  }
  pickCaseFqnByScope(cctx, fctx, candidates)
}

// Emit a runtime test for a pattern.  Jumps to `failLabel` if the test fails.
func lowerPatternTestMsil(
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  pat: in Pattern,
  scrutSlot: in Int,
  scrutTy: in MsilType,
  failLabel: in Int,
): Unit {
  match pat.kind {
    case PWildcard -> {
    }
    case PBinding(pBindName, innerOpt) -> {
      match innerOpt {
        case Some(inner) -> {
          lowerPatternTestMsil(cctx, fctx, insns, inner, scrutSlot, scrutTy, failLabel)
        }
        case None -> {
          // `case Debug ->` over an enum scrutinee: the parser produced a
          // PBinding, but the name is a known enum case — compare ordinals
          // (mirrors the F# emitter's EnumCases-first lookup).  An MObject
          // scrutinee (boxed) is unboxed to I4 first.
          match mapGet(cctx.enumCaseOrdinals, pBindName) {
            case Some(ordv) -> {
              emitLoadSlot(insns, scrutSlot, fctx.paramCount)
              match scrutTy {
                case MObject -> insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, MInt)))
                case _ -> {
                }
              }
              insns.add(MLdcI4(v = ordv))
              insns.add(MCeq)
              insns.add(MBrFalse(label = failLabel))
              return
            }
            case None -> {
            }
          }
          // `case Foo ->` with a single-segment path parses as PBinding
          // (the parser can't tell at that point whether `Foo` names a
          // local-bind target or a nullary union case).  If `pBindName`
          // matches a known nullary union case (local or imported via
          // `unionCaseCtorByName`), emit the isinst test that
          // PConstructor would have emitted — otherwise treat it as a
          // bind-anything pattern (existing semantics).
          val localCtorKey = fctx.pkgName + "." + pBindName
          val ctorKeyOpt = if cctx.recordCtorTokens.containsKey(localCtorKey) {
            Some(value = localCtorKey)
          } else {
            match mapGet(cctx.unionCaseCtorByName, pBindName) {
              case Some(cands) -> Some(value = pickCaseFqnByScrutinee(cctx, fctx, cands, scrutTy))
              case None -> None
            }
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
                case MGenericInstByName(_, typeArgs) -> {
                  // In-bundle generic union case (#2362): the case is a real
                  // generic TypeDef and the nullary case is a real object (newobj
                  // each time, no singleton), so test with a closed `isinst`
                  // against the arity-suffixed case TypeSpec.
                  insns.add(MIsinstGeneric(className = genericBacktickFqn(ctorKey, typeArgs.count), typeArgs = typeArgs))
                }
                case _ -> {
                  // For generic nullary cases (e.g. Option_None) with an untyped
                  // MObject scrutinee (produced by mapGet), we cannot form a
                  // closed TypeSpec for isinst.  In the bootstrap representation
                  // nullary union cases are null, so a null-equality check is
                  // both correct and avoids a runtime TypeLoadException.
                  // TODO(#1825): bootstrap runtime assumption — nullary cases are
                  // CLR null; revisit when the F# shim is eliminated.
                  val nGenericParams = match mapGet(cctx.caseTypeParamCount, ctorKey) { case Some(n) -> n; case None -> 0 }
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
            case None -> {
            }
          }  // Variable bind — always matches, no test emitted.
        }
      }
    }
    case PLiteral(lit) -> {
      emitLoadSlot(insns, scrutSlot, fctx.paramCount)
      // A boxed (`object`) scrutinee — e.g. a tuple element pulled from the
      // `List<object>` representation — must be unboxed to the literal's value
      // type before a `ceq` comparison.
      val scrutBoxed = match scrutTy { case MObject -> true; case _ -> false }
      match lit {
        case LInt(v, suffix, _) -> {
          val isLongLit = match suffix {
            case I64 -> true
            case U64 -> true
            case _ -> (v < -2147483648i64 or v > 2147483647i64)
          }
          if scrutBoxed {
            if isLongLit {
              insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, MLong)))
            } else {
              insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, MInt)))
            }
          }
          if isLongLit {
            insns.add(MLdcI8(v = v))
          } else {
            insns.add(MLdcI4(v = longToInt(v)))
          }
          insns.add(MCeq)
          insns.add(MBrFalse(label = failLabel))
        }
        case LBool(value) -> {
          if scrutBoxed {
            insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, MBool)))
          }
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
          if scrutBoxed {
            insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, MChar)))
          }
          insns.add(MLdcI4(v = cp))
          insns.add(MCeq)
          insns.add(MBrFalse(label = failLabel))
        }
        case LFloat(v, _, _) -> {
          if scrutBoxed {
            insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, MDouble)))
          }
          // A `Float` scrutinee is an r8 on the stack; compare with `ceq`
          // against the pattern's value.  Previously this fell to the `_`
          // wildcard arm below and `pop`ped the scrutinee, making every
          // Float literal pattern match unconditionally (#1481 item 1).
          insns.add(MLdcR8(v = v))
          insns.add(MCeq)
          insns.add(MBrFalse(label = failLabel))
        }
        case LTripleString(s) -> {
          // Triple-quoted and raw string literals carry a plain String payload,
          // so they compare exactly like LString (#1792).
          val sTok = ctxInternUs(cctx.lctx, s)
          insns.add(MLdStr(token = sTok))
          insns.add(MCeq)
          insns.add(MBrFalse(label = failLabel))
        }
        case LRawString(s) -> {
          val sTok = ctxInternUs(cctx.lctx, s)
          insns.add(MLdStr(token = sTok))
          insns.add(MCeq)
          insns.add(MBrFalse(label = failLabel))
        }
        case LUnit -> {
          insns.add(MPop)
        }
      }
    }
    case PConstructor(head, args) -> {
      // Use isinst to check the case type; branch to failLabel if null.
      val caseName = lastSegmentMsil(head)
      // Qualified enum-case pattern (`case Color.Red ->`): an enum value is an
      // Int ordinal, not a union case class, so the isinst path below would never
      // match.  When the penultimate path segment names a known enum type, this
      // is an enum case test — compare the scrutinee ordinal directly, mirroring
      // the single-segment `case Red ->` PBinding path above.  (The single-segment
      // form parses as PBinding; the `Enum.Case` form parses as PConstructor.)
      val enumPenult = if head.segments.count >= 2 { head.segments[head.segments.count - 2] } else { "" }
      if cctx.enumTypeNames.containsKey(enumPenult) {
        // Prefer the type-scoped ordinal (`<EnumType>.<Case>`) so two in-bundle
        // enums sharing a case name don't collide on the bare-name key (#3346);
        // fall back to the bare name for robustness.
        val scopedOrd = match mapGet(cctx.enumCaseOrdinals, enumPenult + "." + caseName) {
          case Some(o) -> Some(value = o)
          case None -> mapGet(cctx.enumCaseOrdinals, caseName)
        }
        match scopedOrd {
          case Some(ordv) -> {
            emitLoadSlot(insns, scrutSlot, fctx.paramCount)
            match scrutTy {
              case MObject -> insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, MInt)))
              case _ -> {
              }
            }
            insns.add(MLdcI4(v = ordv))
            insns.add(MCeq)
            insns.add(MBrFalse(label = failLabel))
            return
          }
          case None -> {
          }
        }
      }
      // For an in-bundle generic union the scrutinee FQN carries the arity suffix
      // (`Pkg.Maybe`1`); strip it before splicing the case name (#2362).
      val baseCls = match scrutTy {
        case MClass(cls) -> cls
        case MGenericInst(_, fqn, _) -> fqn
        case MGenericInstByName(fqn, _) -> stripGenericArity(fqn)
        case _ -> ""
      }
      if baseCls.length > 0 {
        // #2363 Stage 4: case classes are named `Union_Case` everywhere —
        // in-bundle and restored — matching the F# emitter, so the separator is
        // a constant `_` (no in-bundle-vs-cross-assembly fork).
        val sep = "_"
        val caseClass = baseCls + sep + caseName
        emitLoadSlot(insns, scrutSlot, fctx.paramCount)
        // For MGenericInst scrutinees (e.g. Option[Int]) the case class is itself
        // a generic type (Option_None<T>).  We must build a closed TypeSpec using
        // the concrete type args; a bare open TypeRef would fail isinst at runtime.
        match scrutTy {
          case MGenericInst(_, _, typeArgs) -> {
            insns.add(MIsinstGeneric(className = caseClass, typeArgs = typeArgs))
          }
          case MGenericInstByName(_, typeArgs) -> {
            insns.add(MIsinstGeneric(className = genericBacktickFqn(caseClass, typeArgs.count), typeArgs = typeArgs))
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
        val mobjCtorKeyOpt = if cctx.recordCtorTokens.containsKey(mobjLocalCtorKey) {
          Some(value = mobjLocalCtorKey)
        } else {
          match mapGet(cctx.unionCaseCtorByName, caseName) {
            case Some(cands) -> Some(value = pickCaseFqnByScope(cctx, fctx, cands))
            case None -> None
          }
        }
        emitLoadSlot(insns, scrutSlot, fctx.paramCount)
        match mobjCtorKeyOpt {
          case Some(mobjCtorKey) -> {
            val mobjNGen = match mapGet(cctx.caseTypeParamCount, mobjCtorKey) { case Some(n) -> n; case None -> 0 }
            if mobjNGen > 0 {
              // Generic case with an erased scrutinee: we can't form a closed
              // TypeSpec for isinst because the type argument is unknown at this
              // point.  The non-null check is a conservative fallback that passes
              // any non-null value — the first pattern arm always matches for
              // generic union cases on an erased scrutinee.  Tracked in issue
              // #2233 for a proper closed-TypeSpec isinst once the type argument
              // can be recovered from the surrounding binding context.
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
    case PTuple(tuplePats) -> {
      // A tuple structurally matches; recurse the test into each element (read
      // from the `List<object>` representation) so refutable sub-patterns
      // (literals, ranges, nested cases) are honoured rather than the tuple
      // matching unconditionally.
      var pti = 0
      while pti < tuplePats.count {
        emitLoadSlot(insns, scrutSlot, fctx.paramCount)
        insns.add(MCastclass(typeToken = cctx.tokListObjTypeSpec))
        insns.add(MLdcI4(v = pti))
        insns.add(MCallvirt(methodToken = cctx.tokListObjGetItem))
        val ptElemSlot = allocSlotMsil(fctx, "__tuptest_" + toString(pti) + "_" + toString(fctx.slotTicker.count), MObject)
        emitStoreSlot(insns, ptElemSlot, fctx.paramCount)
        lowerPatternTestMsil(cctx, fctx, insns, tuplePats[pti], ptElemSlot, MObject, failLabel)
        pti = pti + 1
      }
    }
    case PParen(inner) -> {
      lowerPatternTestMsil(cctx, fctx, insns, inner, scrutSlot, scrutTy, failLabel)
    }
    case PRange(lo, inclusive, hi) -> {
      // Numeric range test: fail unless `lo <= scrut (<|<=) hi`.  `clt`/`cgt`
      // work for i4/i8/r8 alike, so no per-width branching is needed.  An erased
      // (boxed) scrutinee — e.g. a tuple element — is unboxed to the width the
      // range bounds denote, so a Long/Double range is not truncated to int.
      val rangeNumTy = match scrutTy { case MObject -> rangeBoundTypeMsil(lo); case _ -> scrutTy }
      emitLoadSlot(insns, scrutSlot, fctx.paramCount)
      match scrutTy {
        case MObject -> insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, rangeNumTy)))
        case _ -> ()
      }
      lowerExprMsil(cctx, fctx, insns, lo)
      insns.add(MClt)
      insns.add(MBrTrue(label = failLabel))   // scrut < lo
      emitLoadSlot(insns, scrutSlot, fctx.paramCount)
      match scrutTy {
        case MObject -> insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, rangeNumTy)))
        case _ -> ()
      }
      lowerExprMsil(cctx, fctx, insns, hi)
      if inclusive {
        insns.add(MCgt)
        insns.add(MBrTrue(label = failLabel))  // scrut > hi
      } else {
        insns.add(MClt)
        insns.add(MBrFalse(label = failLabel)) // not (scrut < hi) → scrut >= hi
      }
    }
    case PRecord(head, fields, _) -> {
      // A record is single-shape, so the structural test is a no-op; recurse the
      // test into each named field's sub-pattern so refutable field patterns
      // (`Point{x = 0}`) are honoured.
      val recClass = match scrutTy {
        case MClass(c) -> c
        case MGenericInst(_, fqn, _) -> fqn
        case _ -> fctx.pkgName + "." + lastSegmentMsil(head)
      }
      var rfi = 0
      while rfi < fields.count {
        match fields[rfi] {
          case RPFNamed(fname, subPat, _) -> {
            val rkey = recClass + "/" + fname
            match mapGet(cctx.fieldTokens, rkey) {
              case Some(fTok) -> {
                val fty = match mapGet(cctx.fieldMsilTypes, rkey) { case Some(t) -> t; case None -> MObject }
                emitLoadSlot(insns, scrutSlot, fctx.paramCount)
                insns.add(MCastclassByName(className = recClass))
                insns.add(MLdfld(fieldToken = fTok))
                val tSlot = allocSlotMsil(fctx, "__rtest_" + fname + "_" + toString(fctx.slotTicker.count), fty)
                emitStoreSlot(insns, tSlot, fctx.paramCount)
                lowerPatternTestMsil(cctx, fctx, insns, subPat, tSlot, fty, failLabel)
              }
              case None -> {
              }
            }
          }
          case RPFShort(_, _) -> {
          }
        }
        rfi = rfi + 1
      }
    }
    case PTypeTest(_, ty) -> {
      val testTy = typeExprToMsilCtx(cctx, ty, fctx.pkgName)
      match testTy {
        case MClass(cls) -> {
          emitLoadSlot(insns, scrutSlot, fctx.paramCount)
          insns.add(MIsinstByName(className = cls))
          insns.add(MBrFalse(label = failLabel))
        }
        case _ -> {
        }
      }
    }
    case POr(patterns) -> {
      val succeedL = freshLabelMsil(fctx)
      var ai = 0
      while ai < patterns.count {
        val nextAltL = freshLabelMsil(fctx)
        lowerPatternTestMsil(cctx, fctx, insns, patterns[ai], scrutSlot, scrutTy, nextAltL)
        insns.add(MBr(label = succeedL))
        insns.add(MLabel(id = nextAltL))
        ai = ai + 1
      }
      insns.add(MBr(label = failLabel))
      insns.add(MLabel(id = succeedL))
    }
    case PError -> {
    }
  }
}

// Bind pattern variables after a successful match.
func lowerPatternBindMsil(
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  pat: in Pattern,
  scrutSlot: in Int,
  scrutTy: in MsilType,
): Unit {
  match pat.kind {
    case PWildcard -> {
    }
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
          val isNullaryCase = cctx.recordCtorTokens.containsKey(localCtorKey) or cctx.unionCaseCtorByName.containsKey(name) or
            cctx.enumCaseOrdinals.containsKey(name)
          if not isNullaryCase {
            emitLoadSlot(insns, scrutSlot, fctx.paramCount)
            val bindSlot = allocSlotMsil(fctx, name, scrutTy)
            emitStoreSlot(insns, bindSlot, fctx.paramCount)
          }
        }
      }
    }
    case PLiteral(_) -> {
    }
    case PConstructor(head, fields) -> {
      val caseName = lastSegmentMsil(head)
      val baseCls = match scrutTy {
        case MClass(cls) -> cls
        case MGenericInst(_, fqn, _) -> fqn
        case MGenericInstByName(fqn, _) -> stripGenericArity(fqn)
        case _ -> ""
      }
      if baseCls.length > 0 {
        // #2363 Stage 4: case classes are `Union_Case` everywhere (in-bundle +
        // restored), matching the F# emitter — separator is a constant `_`.
        val sep = "_"
        val caseClass = baseCls + sep + caseName
        // The arity-suffixed case name (`Maybe_Just`1`) for an in-bundle generic
        // union: the codegen maps stay keyed by the plain `caseClass`, but the
        // generic instructions must name the suffixed TypeDef (#2362).
        val caseClassBt = match scrutTy {
          case MGenericInstByName(_, typeArgsB) -> genericBacktickFqn(caseClass, typeArgsB.count)
          case _ -> caseClass
        }
        // For generic union scrutinees (e.g. Option[Int]) the case class is
        // also generic (e.g. Option_Some<T>).  The local variable must be
        // declared with the closed instantiation (GENERICINST CLASS TypeRef
        // <Int32>) rather than the bare open-generic class — the CLR rejects
        // open-generic types in LocalVarSig with TypeLoadException.
        val castTy = match scrutTy {
          case MGenericInst(_, _, typeArgs) -> {
            val dotIdx = caseClass.lastIndexOf(".")
            val caseKey = if dotIdx < 0 { "" } else { caseClass.substring(0, dotIdx) + "/" + caseClass }
            match mapGet(cctx.ffiTypeRefs, caseKey) {
              case Some(refRow) -> MGenericInst(typeRefCode = tdrTypeRef(refRow), headFqn = caseClass, typeArgs = typeArgs)
              case None -> MClass(className = caseClass)
            }
          }
          case MGenericInstByName(_, typeArgs) -> MGenericInstByName(headFqn = caseClassBt, typeArgs = typeArgs)
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
          case MGenericInst(_, _, typeArgs) -> insns.add(MCastclassGeneric(className = caseClass, typeArgs = typeArgs))
          case MGenericInstByName(_, typeArgs) -> insns.add(MCastclassGeneric(className = caseClassBt, typeArgs = typeArgs))
          case _ -> {
          }
        }
        val castSlot = allocSlotMsil(fctx, "__cast_" + caseName + "_" + toString(fctx.slotTicker.count), castTy)
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
              val fTok = if fByName {
                match mapGet(cctx.fieldTokens, caseClass + "/" + fname) {
                  case Some(t) -> t
                  case None -> 0
                }
              } else {
                match mapGet(cctx.fieldTokens, caseClass + "/field" + toString(fi)) {
                  case Some(t) -> t
                  case None -> 0
                }
              }
              if fTok > 0 {
                val sigLookupKey = if fByName { caseClass + "/" + fname } else { caseClass + "/field" + toString(fi) }
                val fSig = match mapGet(cctx.fieldSigBytes, sigLookupKey) {
                  case Some(sigBytes) -> sigBytes
                  case None -> buildFieldSig(MObject)
                }
                var vi = -1
                match castTy {
                  case MGenericInst(_, _, typeArgs) -> {
                    vi = match mapGet(cctx.fieldVarIndices, sigLookupKey) { case Some(v) -> v; case None -> -1 }
                  }
                  case MGenericInstByName(_, _) -> {
                    vi = match mapGet(cctx.fieldVarIndices, sigLookupKey) { case Some(v) -> v; case None -> -1 }
                  }
                  case _ -> {
                  }
                }
                // For generic case classes (e.g. Option_Some<Keyword>) use
                // MLdfldGeneric so the TypeSpec and TypeSpec-parented MemberRef
                // are built at Phase 5 lowering time, when all TypeDefs are
                // present.  For non-generic cases use the pre-computed fTok.
                val actualFieldName = if fByName {
                  fname
                } else {
                  match mapGet(cctx.fieldDeclaredNames, sigLookupKey) {
                    case Some(n) -> n
                    case None -> fname
                  }
                }
                var concreteFieldTy: MsilType = match mapGet(cctx.fieldMsilTypes, sigLookupKey) {
                  case Some(ty) -> ty
                  case None -> MObject
                }
                if vi >= 0 {
                  match castTy {
                    case MGenericInst(_, _, typeArgs) -> {
                      concreteFieldTy = typeArgs[vi]
                    }
                    case MGenericInstByName(_, typeArgs) -> {
                      if vi < typeArgs.count {
                        concreteFieldTy = typeArgs[vi]
                      }
                    }
                    case _ -> {
                    }
                  }
                }
                // Unit-typed payload has no runtime value (null/object); MVoid local would be invalid — erase to object.
                match concreteFieldTy {
                  case MVoid -> {
                    concreteFieldTy = MObject
                  }
                  case _ -> {
                  }
                }
                emitLoadSlot(insns, castSlot, fctx.paramCount)
                match castTy {
                  case MGenericInst(_, _, typeArgs) -> insns.add(MLdfldGeneric(baseClassName = caseClass, typeArgs = typeArgs, fieldName = actualFieldName, fieldSig = fSig))
                  case MGenericInstByName(_, typeArgs) -> insns.add(MLdfldGeneric(baseClassName = caseClassBt, typeArgs = typeArgs, fieldName = actualFieldName, fieldSig = fSig))
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
                  case PBinding(_, Some(innerPat)) -> lowerPatternBindMsil(cctx, fctx, insns, innerPat, fSlot, concreteFieldTy)
                  case _ -> {
                  }
                }
              }
            }
            case PTuple(_) -> {
              // Positional field fi carries a tuple value; load it and recurse.
              val ptPosFldKey = caseClass + "/field" + toString(fi)
              val ptFTok = match mapGet(cctx.fieldTokens, ptPosFldKey) { case Some(t) -> t; case None -> 0 }
              if ptFTok > 0 {
                var ptVi = -1
                match castTy {
                  case MGenericInst(_, _, typeArgs) -> {
                    ptVi = match mapGet(cctx.fieldVarIndices, ptPosFldKey) { case Some(v) -> v; case None -> -1 }
                  }
                  case MGenericInstByName(_, _) -> {
                    ptVi = match mapGet(cctx.fieldVarIndices, ptPosFldKey) { case Some(v) -> v; case None -> -1 }
                  }
                  case _ -> {
                  }
                }
                val ptFSig = match mapGet(cctx.fieldSigBytes, ptPosFldKey) { case Some(s) -> s; case None -> buildFieldSig(MObject) }
                val ptActualFieldName = match mapGet(cctx.fieldDeclaredNames, ptPosFldKey) {
                  case Some(n) -> n
                  case None -> "field" + toString(fi)
                }
                var ptFieldTy: MsilType = match mapGet(cctx.fieldMsilTypes, ptPosFldKey) { case Some(ty) -> ty; case None -> MObject }
                if ptVi >= 0 {
                  match castTy {
                    case MGenericInst(_, _, typeArgs) -> {
                      ptFieldTy = typeArgs[ptVi]
                    }
                    case MGenericInstByName(_, typeArgs) -> {
                      if ptVi < typeArgs.count {
                        ptFieldTy = typeArgs[ptVi]
                      }
                    }
                    case _ -> {
                    }
                  }
                }
                emitLoadSlot(insns, castSlot, fctx.paramCount)
                match castTy {
                  case MGenericInst(_, _, typeArgs) -> insns.add(MLdfldGeneric(baseClassName = caseClass, typeArgs = typeArgs, fieldName = ptActualFieldName, fieldSig = ptFSig))
                  case MGenericInstByName(_, typeArgs) -> insns.add(MLdfldGeneric(baseClassName = caseClassBt, typeArgs = typeArgs, fieldName = ptActualFieldName, fieldSig = ptFSig))
                  case _ -> {
                    insns.add(MCastclassByName(className = caseClass))
                    insns.add(MLdfld(fieldToken = ptFTok))
                  }
                }
                val ptFldSlot = allocSlotMsil(fctx, "__tup_fld_" + toString(fi) + "_" + toString(fctx.slotTicker.count), ptFieldTy)
                emitStoreSlot(insns, ptFldSlot, fctx.paramCount)
                lowerPatternBindMsil(cctx, fctx, insns, fields[fi], ptFldSlot, ptFieldTy)
              }
            }
            case _ -> {
            }
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
                case Some(innerPat) -> lowerPatternBindMsil(cctx, fctx, insns, innerPat, fSlot, MObject)
                case None -> {
                }
              }
            }
            case _ -> {
            }
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
        val ptElemSlot = allocSlotMsil(fctx, "__tup_" + toString(pti) + "_" + toString(fctx.slotTicker.count), MObject)
        emitStoreSlot(insns, ptElemSlot, fctx.paramCount)
        lowerPatternBindMsil(cctx, fctx, insns, tupleSubPats[pti], ptElemSlot, MObject)
        pti = pti + 1
      }
    }
    case PParen(inner) -> {
      lowerPatternBindMsil(cctx, fctx, insns, inner, scrutSlot, scrutTy)
    }
    case PRange(_, _, _) -> {
      // Range patterns bind nothing.
    }
    case PTypeTest(inner, ty) -> {
      // Narrow to the tested type, then bind the inner pattern at that type.
      val testTy = typeExprToMsilCtx(cctx, ty, fctx.pkgName)
      match testTy {
        case MClass(cls) -> {
          emitLoadSlot(insns, scrutSlot, fctx.paramCount)
          insns.add(MCastclassByName(className = cls))
          val nSlot = allocSlotMsil(fctx, "__typetest_" + toString(fctx.slotTicker.count), testTy)
          emitStoreSlot(insns, nSlot, fctx.paramCount)
          lowerPatternBindMsil(cctx, fctx, insns, inner, nSlot, testTy)
        }
        case _ -> lowerPatternBindMsil(cctx, fctx, insns, inner, scrutSlot, scrutTy)
      }
    }
    case PRecord(head, fields, _) -> {
      // Downcast to the record class and bind each named field by its declared
      // field token (records are single-shape, so no case selector is needed).
      val recClass = match scrutTy {
        case MClass(c) -> c
        case MGenericInst(_, fqn, _) -> fqn
        case _ -> fctx.pkgName + "." + lastSegmentMsil(head)
      }
      val rCastSlot = allocSlotMsil(fctx, "__reccast_" + toString(fctx.slotTicker.count), MClass(className = recClass))
      emitLoadSlot(insns, scrutSlot, fctx.paramCount)
      insns.add(MCastclassByName(className = recClass))
      emitStoreSlot(insns, rCastSlot, fctx.paramCount)
      var rbi = 0
      while rbi < fields.count {
        match fields[rbi] {
          case RPFNamed(fname, subPat, _) -> {
            val rkey = recClass + "/" + fname
            match mapGet(cctx.fieldTokens, rkey) {
              case Some(fTok) -> {
                val fty = match mapGet(cctx.fieldMsilTypes, rkey) { case Some(t) -> t; case None -> MObject }
                match subPat.kind {
                  case PBinding(bname, _) -> {
                    emitLoadSlot(insns, rCastSlot, fctx.paramCount)
                    insns.add(MLdfld(fieldToken = fTok))
                    val bSlot = allocSlotMsil(fctx, bname, fty)
                    emitStoreSlot(insns, bSlot, fctx.paramCount)
                  }
                  case _ -> {
                    emitLoadSlot(insns, rCastSlot, fctx.paramCount)
                    insns.add(MLdfld(fieldToken = fTok))
                    val tSlot = allocSlotMsil(fctx, "__rfld_" + fname + "_" + toString(fctx.slotTicker.count), fty)
                    emitStoreSlot(insns, tSlot, fctx.paramCount)
                    lowerPatternBindMsil(cctx, fctx, insns, subPat, tSlot, fty)
                  }
                }
              }
              case None -> {
              }
            }
          }
          case RPFShort(fname, _) -> {
            val rkey = recClass + "/" + fname
            match mapGet(cctx.fieldTokens, rkey) {
              case Some(fTok) -> {
                val fty = match mapGet(cctx.fieldMsilTypes, rkey) { case Some(t) -> t; case None -> MObject }
                emitLoadSlot(insns, rCastSlot, fctx.paramCount)
                insns.add(MLdfld(fieldToken = fTok))
                val bSlot = allocSlotMsil(fctx, fname, fty)
                emitStoreSlot(insns, bSlot, fctx.paramCount)
              }
              case None -> {
              }
            }
          }
        }
        rbi = rbi + 1
      }
    }
    case POr(_) -> {
    }
    case PError -> {
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5f. Interpolated string lowering.
// ─────────────────────────────────────────────────────────────────────────────
func lowerInterpolatedMsil(
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  segments: in List[InterpolatedSegment],
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
            case MString -> {
            }
            case MVoid -> {
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
func lowerCallArgMsil(cctx: in CodegenCtx, fctx: in FuncCtx, insns: in List[MInsn], arg: in CallArg): MsilType {
  match arg {
    case CAPositional(e) -> lowerExprMsil(cctx, fctx, insns, e)
    case CANamed(_, e, _) -> lowerExprMsil(cctx, fctx, insns, e)
  }
}

// The underlying expression of a call argument (positional or named).  Used by
// the `out`/`inout` call path, which needs the argument as an lvalue. #1761.
func callArgExpr(arg: in CallArg): Expr {
  match arg {
    case CAPositional(e) -> e
    case CANamed(_, e, _) -> e
  }
}

// Reorder a record/union-case constructor's arguments to field-declaration
// order (#1730).  A named-argument call (`R(c = …, a = …)`) may list fields in
// any order, but the constructor `newobj` consumes them positionally in
// declaration order.  Build a complete positional arg list in field-declaration
// order: named args are matched by name, and fields with no matching arg are
// filled from `ctorDefaultExprs` (populated by addPackageTokens for fields
// that carry a `= expr` default).  Returns `args` unchanged when: any arg is
// positional (already in order), the field-name map is absent (defensive), or
// a required field has neither a named arg nor a registered default.
func fillCtorDefaultArgs(cctx: in CodegenCtx, ctorKey: in String, args: in List[CallArg]): List[CallArg] {
  if args.count == 0 {
    return args
  }
  // Build name → arg from the call site; bail if any arg is positional.
  val nameToArg: Map[String, CallArg] = newMap()
  var i = 0
  while i < args.count {
    match args[i] {
      case CANamed(nm, _, _) -> {
        if nameToArg.containsKey(nm) {
          return args
        }  // dup name — leave as-is
        nameToArg.add(nm, args[i])
      }
      case CAPositional(_) -> {
        return args
      }
    }
    i = i + 1
  }
  // Count total fields by probing fieldDeclaredNames until a key is absent.
  var totalFields = 0
  while cctx.fieldDeclaredNames.containsKey(ctorKey + "/field" + toString(totalFields)) {
    totalFields = totalFields + 1
  }
  if totalFields == 0 {
    return args  // no field-order info — preserve current behaviour
  }
  // Reassemble in field-declaration order, injecting defaults for missing fields.
  val ordered: List[CallArg] = newList()
  var fp = 0
  while fp < totalFields {
    val byPosKey = ctorKey + "/field" + toString(fp)
    match mapGet(cctx.fieldDeclaredNames, byPosKey) {
      case None -> return args  // defensive
      case Some(fname) -> {
        match mapGet(nameToArg, fname) {
          case Some(a) -> ordered.add(a)
          case None -> {
            match mapGet(cctx.ctorDefaultExprs, byPosKey) {
              case Some(dflt) -> ordered.add(CAPositional(expr = dflt))
              case None -> return args  // required field missing — bail
            }
          }
        }
      }
    }
    fp = fp + 1
  }
  ordered
}

// Reorder a static/method function call's arguments to parameter-declaration
// order (#1503).  Mirrors fillCtorDefaultArgs but uses `funcParamNames` (the
// declared parameter-name list keyed by `tokKey`) instead of `fieldDeclaredNames`.
// Returns `args` unchanged when: any arg is positional, the name map is absent
// for this function (e.g. a cross-package restored function), or a named arg
// doesn't match any declared parameter name.
func reorderFuncNamedArgs(cctx: in CodegenCtx, tokKey: in String, args: in List[CallArg]): List[CallArg] {
  if args.count == 0 {
    return args
  }
  // Build name → arg from the call site; bail if any arg is positional
  // (mixed positional/named calls are already in declaration order).
  val nameToArg: Map[String, CallArg] = newMap()
  var i = 0
  while i < args.count {
    match args[i] {
      case CANamed(nm, _, _) -> {
        if nameToArg.containsKey(nm) {
          return args
        }
        nameToArg.add(nm, args[i])
      }
      case CAPositional(_) -> {
        return args
      }
    }
    i = i + 1
  }
  // Count total declared params by probing the flat map until a key is absent.
  var totalParams = 0
  while cctx.funcParamNames.containsKey(tokKey + "/param" + toString(totalParams)) {
    totalParams = totalParams + 1
  }
  if totalParams == 0 {
    return args  // no param-order info — preserve current behaviour
  }
  val ordered: List[CallArg] = newList()
  var pi = 0
  while pi < totalParams {
    val pnKey = tokKey + "/param" + toString(pi)
    match mapGet(cctx.funcParamNames, pnKey) {
      case None -> return args  // defensive
      case Some(pname) -> match mapGet(nameToArg, pname) {
        case Some(a) -> ordered.add(a)
        case None -> match mapGet(cctx.funcDefaultExprs, pnKey) {
          case Some(dflt) -> ordered.add(CAPositional(expr = dflt))
          case None -> return args  // required param missing — bail
        }
      }
    }
    pi = pi + 1
  }
  ordered
}

// Fill in trailing default arguments for a positional call site that provides
// fewer arguments than the declared parameter count (#1503).  Returns `args`
// unchanged when: all args are positional but count already matches declared
// params, no param-name info is available for this function, or a missing
// trailing param has no registered default.
func fillPositionalFuncDefaults(cctx: in CodegenCtx, tokKey: in String, args: in List[CallArg]): List[CallArg] {
  // Only applies when args.count < declared param count.
  var totalParams = 0
  while cctx.funcParamNames.containsKey(tokKey + "/param" + toString(totalParams)) {
    totalParams = totalParams + 1
  }
  if totalParams <= args.count {
    return args
  }
  // Verify all provided args are positional (mixed calls are already in order).
  var i = 0
  while i < args.count {
    match args[i] {
      case CAPositional(_) -> ()
      case CANamed(_, _, _) -> return args  // named args handled by reorderFuncNamedArgs
    }
    i = i + 1
  }
  // Copy existing positional args then append defaults for trailing params.
  val filled: List[CallArg] = newList()
  var j = 0
  while j < args.count {
    filled.add(args[j])
    j = j + 1
  }
  var k = args.count
  while k < totalParams {
    val pnKey = tokKey + "/param" + toString(k)
    match mapGet(cctx.funcDefaultExprs, pnKey) {
      case Some(dflt) -> filled.add(CAPositional(expr = dflt))
      case None -> return args  // required param with no default — bail
    }
    k = k + 1
  }
  filled
}

// Lower a function call expression.
pub func lowerCallMsil(
  cctx: in CodegenCtx, fctx: in FuncCtx, insns: in List[MInsn], fn: in Expr, args: in List[CallArg]
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

// Unbox a boxed (`object`) call argument to its declared value-type parameter.
// Reached when a value of erased static type — e.g. a tuple element pulled from
// the `List<object>` representation and bound by `PTuple` — is passed to a
// value-typed parameter (`assertEqualInt(a, …)`); without the `unbox.any` the
// CLR rejects the program ("invalid program").  A no-op unless the argument is
// `object` and the parameter is a primitive value type.
func coerceCallArgMsil(cctx: in CodegenCtx, insns: in List[MInsn], fromTy: in MsilType, toTy: in MsilType): Unit {
  val fromObj = match fromTy { case MObject -> true; case _ -> false }
  if fromObj {
    match toTy {
      case MInt -> insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, MInt)))
      case MLong -> insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, MLong)))
      case MDouble -> insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, MDouble)))
      case MBool -> insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, MBool)))
      case MChar -> insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, MChar)))
      case MByte -> insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, MByte)))
      case _ -> ()
    }
  } else {
    // A concrete `List<T>` value being passed to a `slice[T]` (= `T[]`) parameter:
    // emit `ToArray()` so the callee — typically an F#-built stdlib function that
    // declares a genuine CLR `!0[]` parameter — receives a real array rather than
    // a `List`-backed value (#2592 slice 4).
    match fromTy {
      case MConcreteList(fromElem) -> {
        match toTy {
          case MArray(_) -> insns.add(MListOp(op = LoToArray, elemTy = fromElem))
          case _ -> ()
        }
      }
      case _ -> ()
    }
  }
}

// The numeric width an integer/float literal denotes — used to unbox an erased
// (boxed) `PRange` scrutinee to the right value type rather than a hard-coded
// int.  `clt`/`cgt` then compare at that width (they work for i4/i8/r8 alike).
func rangeBoundTypeMsil(e: in Expr): MsilType {
  match e.kind {
    case ELiteral(lit) -> {
      match lit {
        case LInt(_, suffix, _) -> match suffix { case I64 -> MLong; case U64 -> MLong; case _ -> MInt }
        case LFloat(_, _, _) -> MDouble
        case _ -> MInt
      }
    }
    case _ -> MInt
  }
}

// Lower a builtin or intra-package static call.
func lowerBuiltinOrStaticCallMsil(
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  funcName: in String,
  path: in ModulePath,
  args: in List[CallArg],
): MsilType {
  if funcName == "println" {
    if args.count > 0 {
      val argTy = lowerCallArgMsil(cctx, fctx, insns, args[0])
      match argTy {
        case MInt -> insns.add(MCall(methodToken = cctx.tokWriteLineInt))
        case MLong -> insns.add(MCall(methodToken = cctx.tokWriteLineLong))
        case MDouble -> insns.add(MCall(methodToken = cctx.tokWriteLineDbl))
        case MBool -> insns.add(MCall(methodToken = cctx.tokWriteLineBool))
        case MChar -> insns.add(MCall(methodToken = cctx.tokWriteLineInt))
        case MVoid -> {
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
      insns.add(MLabel(id = skipL))
    }
    MVoid
  } else if funcName == "toString" {
    if args.count > 0 {
      val argTy = lowerCallArgMsil(cctx, fctx, insns, args[0])
      match argTy {
        case MString -> {
        }
        case MVoid -> {
          val emptyTok = ctxInternUs(cctx.lctx, "")
          insns.add(MLdStr(token = emptyTok))
        }
        case MDouble -> {
          // Locale-invariant: Double.ToString(CultureInfo.InvariantCulture) (#2462).
          // Object.ToString() is locale-sensitive; German/French locales render "3,14".
          // Double is a struct — take its address via ldloca for the HASTHIS call.
          val dblSlot = allocSlotMsil(fctx, "__inv_dbl_" + toString(fctx.slotTicker.count), MDouble)
          emitStoreSlot(insns, dblSlot, fctx.paramCount)
          insns.add(MLdloca(slot = dblSlot - fctx.paramCount))
          insns.add(MCall(methodToken = cctx.tokInvariantCulture))
          insns.add(MCall(methodToken = cctx.tokDoubleToStringInv))
        }
        case _ -> {
          if isClrDateTimeMsil(argTy) {
            // ISO-8601 round-trip format via DateTime.ToString("o") (#2184).
            // The DateTime is an unboxed value type on the stack; stash it in
            // a value-type local so we can take its address for the instance
            // call, then push the "o" format-specifier string.
            // Produces "1970-01-01T00:00:00.0000000Z" for UTC DateTimes,
            // matching the F# bootstrap emitter's DateTime.ToString("o") path.
            val dtSlot = allocSlotMsil(fctx, "__o_dt_" + toString(fctx.slotTicker.count), argTy)
            emitStoreSlot(insns, dtSlot, fctx.paramCount)
            insns.add(MLdloca(slot = dtSlot - fctx.paramCount))
            insns.add(MLdStr(token = cctx.usDateTimeFormatO))
            insns.add(MCall(methodToken = cctx.tokDateTimeToStringO))
          } else {
            boxIfNeededMsil(cctx, insns, argTy)
            insns.add(MCallvirt(methodToken = cctx.tokObjToString))
          }
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
    // Build a concrete `List`1<Foo>` when the context expects one (the
    // annotated-accumulator pattern `val acc: List[Foo] = newList()` flows the
    // element type here via collExpect); otherwise the legacy `List<object>`.
    match collExpectTop(fctx) {
      case MConcreteList(e) -> {
        insns.add(MListOp(op = LoCtor, elemTy = e))
        MConcreteList(elemTy = e)
      }
      case _ -> {
        insns.add(MNewobj(ctorToken = cctx.tokListObjCtor))
        MObject
      }
    }
  } else if funcName == "newMap" {
    // Build a concrete `Dictionary`2<K,V>` when the context expects one;
    // otherwise the legacy `Dictionary<object,object>`.
    match collExpectTop(fctx) {
      case MConcreteMap(k, v) -> {
        insns.add(MDictOp(op = DoCtor, keyTy = k, valTy = v))
        MConcreteMap(keyTy = k, valTy = v)
      }
      case _ -> {
        insns.add(MNewobj(ctorToken = cctx.tokDictObjCtor))
        MMapOf(keyTy = MObject, valTy = MObject)
      }
    }
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
      val mapValTy = match mArgTy { case MMapOf(_, vt) -> vt; case MConcreteMap(_, vt) -> vt; case _ -> MObject }
      val vTy: MsilType = if fctx.contextHintTyArgs.count > 0 { fctx.contextHintTyArgs[0] } else { mapValTy }
      // A concrete `Dictionary<K,V>` keys and reads unboxed — the `!0` MemberRef
      // binds to the concrete key type, so the key temp is not boxed.
      val mapKeyTy = match mArgTy { case MConcreteMap(kt, _) -> kt; case _ -> MObject }
      val kSlot = allocSlotMsil(fctx, "__mapget_k_" + toString(fctx.slotTicker.count), mapKeyTy)
      val kArgTy = lowerCallArgMsil(cctx, fctx, insns, args[1])
      collBoxIfNeeded(cctx, insns, kArgTy, mArgTy)
      emitStoreSlot(insns, kSlot, fctx.paramCount)

      val elseL = freshLabelMsil(fctx)
      val endL = freshLabelMsil(fctx)

      // ContainsKey(m, key) — concrete `Dictionary`2` tokens when the map arg
      // is concrete; castclass the reloaded object-slot receiver first.
      emitLoadSlot(insns, mSlot, fctx.paramCount)
      emitDictCastRecv(cctx, insns, mArgTy)
      emitLoadSlot(insns, kSlot, fctx.paramCount)
      emitDictContainsKey(cctx, insns, mArgTy)
      insns.add(MBrFalse(label = elseL))

      // then: Some(value = (V) m[key])
      emitLoadSlot(insns, mSlot, fctx.paramCount)
      emitDictCastRecv(cctx, insns, mArgTy)
      emitLoadSlot(insns, kSlot, fctx.paramCount)
      emitDictGetItem(cctx, insns, mArgTy)  // concrete returns V typed; legacy -> object
      // Concrete map returns the value already typed; the legacy object path
      // narrows it (ref castclass / value unbox) into the `Option_Some<V>` ctor.
      match mArgTy {
        case MConcreteMap(_, _) -> ()
        case _ -> castObjectToMsil(cctx, insns, vTy)
      }
      val someArgTys: List[MsilType] = newList()
      someArgTys.add(vTy)
      val someCtx: List[MsilType] = newList()
      someCtx.add(vTy)
      val someParent: List[MsilType] = newList()
      val someOk = buildGenericCaseCtorTok(cctx, "Std.Core.Option_Some", someArgTys, someCtx, someParent, insns)
      insns.add(MBr(label = endL))

      // else: None
      insns.add(MLabel(id = elseL))
      val noneArgTys: List[MsilType] = newList()
      val noneCtx: List[MsilType] = newList()
      noneCtx.add(vTy)
      val noneParent: List[MsilType] = newList()
      val noneOk = buildGenericCaseCtorTok(cctx, "Std.Core.Option_None", noneArgTys, noneCtx, noneParent, insns)

      insns.add(MLabel(id = endL))
      if someOk == 1 and someParent.count > 0 {
        someParent[0]
      } else if noneOk == 1 and noneParent.count > 0 {
        noneParent[0]
      } else {
        MObject
      }
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
    val ctorKey = if cctx.recordCtorTokens.containsKey(localCtorKey) {
      localCtorKey
    } else {
      match mapGet(cctx.unionCaseCtorByName, funcName) {
        case Some(candidates) -> pickCaseFqnByScope(cctx, fctx, candidates)
        case None -> {
          // Cross-package record: look up simple name in typeFqnByName to
          // get the FQN, then verify it has a ctor registered.
          match mapGet(cctx.typeFqnByName, funcName) {
            case Some(fqn) -> if cctx.recordCtorTokens.containsKey(fqn) { fqn } else { localCtorKey }
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
        val ctorArgs = fillCtorDefaultArgs(cctx, ctorKey, args)
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
            case MGenericInstByName(_, retArgTys) -> {
              var rci = 0
              while rci < retArgTys.count {
                outerCtxTyArgs.add(retArgTys[rci])
                rci = rci + 1
              }
            }
            case _ -> {
            }
          }
        }
        // Lower args, collecting their MSIL types for generic type inference.
        val argTypes: List[MsilType] = newList()
        var ci = 0
        while ci < ctorArgs.count {
          // Hint this slot with its concrete inner type so nested payloads instantiate right (#1687).
          val fldKeyH = ctorKey + "/field" + toString(ci)
          val viH = match mapGet(cctx.fieldVarIndices, fldKeyH) { case Some(v) -> v; case None -> -1 }
          // Generic-case fields (`value: T` on `Some<T>`) resolve their hint from
          // the surrounding instantiation via the type-var slot.  Concrete generic
          // fields (`visibility: Option[String]` on a plain record) instead carry
          // their own `MGenericInst`; look it up by the field's declared name so a
          // bare `None` / `Some(...)` argument instantiates with the field's type
          // args rather than erasing to `object` — otherwise the stored nullary
          // case is `Option<object>` and a later `match` on the field fails
          // "match not exhaustive" (#1731 / the #1730 session blocker).
          val innerHint: MsilType = if viH >= 0 and viH < outerCtxTyArgs.count {
            outerCtxTyArgs[viH]
          } else {
            match mapGet(cctx.fieldDeclaredNames, fldKeyH) {
              case Some(fname) -> match mapGet(cctx.fieldMsilTypes, ctorKey + "/" + fname) { case Some(fty) -> fty; case None -> MObject }
              // Non-generic union cases omit fieldDeclaredNames; fall back to positional key to recover concrete field type (avoids List<object> + InvalidCastException — #2592/D-progress-469 facet 4).
              case None -> match mapGet(cctx.fieldMsilTypes, fldKeyH) { case Some(fty) -> fty; case None -> MObject }
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
            case _ -> {
              // A record/case field typed `List[Foo]`/`Map[..]` pushes the expected
              // concrete type so a bare `[...]` / `newList()` argument builds the
              // concrete instance the field's signature requires.
              pushCollExpect(fctx, innerHint)
              val loweredC = lowerCallArgMsil(cctx, fctx, insns, ctorArgs[ci])
              popCollExpect(fctx)
              loweredC
            }
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
          if outParentTy.count > 0 {
            outParentTy[0]
          } else {
            MObject
          }
        } else {
          // In-bundle generic record (#2362): construct the closed instantiation
          // via a TypeSpec-parented `.ctor` MemberRef (a direct MethodDef token on
          // a generic TypeDef is invalid per ECMA-335 §III.4.21 and faults at load).
          val outResultTy: List[MsilType] = newList()
          val inBundleGen = buildInBundleGenericCtorTok(cctx, ctorKey, argTypes, contextTyArgs, outResultTy, insns)
          if inBundleGen > 0 {
            // MNewobjGenericByName already emitted; result is the closed instance.
            outResultTy[0]
          } else {
            // For nullary in-bundle union cases, load the singleton Instance field
            // instead of allocating a fresh object, so reference-equality works.
            match mapGet(cctx.singletonFieldTokens, ctorKey) {
              case Some(fldTok) -> {
                insns.add(MLdsfld(fieldToken = fldTok))
                MClass(className = caseParentFqnMsil(cctx, ctorKey))
              }
              case None -> {
                insns.add(MNewobj(ctorToken = ctorTok))
                // The construction result type is the parent union, recovered from
                // the registered `caseParentUnion` map (#2363 Stage 4).
                MClass(className = caseParentFqnMsil(cctx, ctorKey))
              }
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
              case Some(rt) -> match rt { case MVoid -> { insns.add(MPop); MVoid }; case _ -> { materializeBoxedElemMsil(cctx, insns, rt); rt } }
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
            val qualifiedFqn = if path.segments.count >= 2 { joinSegsMsil(path.segments, ".") } else { "" }
            val localFqn = fctx.pkgName + "." + funcName
            // Fall through to each package this one imports, in declaration
            // order.  First hit wins — matches the typechecker's import
            // shadowing rule.  Packages with no recorded imports (e.g. the
            // single-package compile path) skip the loop entirely.
            val importedFqn = match mapGet(cctx.pkgImports, fctx.pkgName) {
              case Some(imps) -> findImportedFqn(cctx, imps, funcName)
              case None -> ""
            }
            val resolvedFqn = if qualifiedFqn.length > 0 and cctx.funcTokens.containsKey(qualifiedFqn) {
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
              val tokKey = if cctx.funcTokens.containsKey(callArityKey) { callArityKey } else { resolvedFqn }
              match mapGet(cctx.funcTokens, tokKey) {
                case Some(tok) -> {
                  val callParamTys = match mapGet(cctx.funcParamTypes, tokKey) { case Some(pts) -> pts; case None -> newList() }
                  val callParamModes = match mapGet(cctx.funcParamModes, tokKey) { case Some(ms) -> ms; case None -> newList() }
                  val reorderedArgs = reorderFuncNamedArgs(cctx, tokKey, args)
                  val callArgs = fillPositionalFuncDefaults(cctx, tokKey, reorderedArgs)
                  var i = 0
                  while i < callArgs.count {
                    // #1939: a lambda passed *directly* to a function-typed
                    // parameter inherits that parameter's inner types — record
                    // them under the lambda's index (the next lambdaTicker value,
                    // which the ELambda arm will consume) so the lambda body
                    // unboxes its boxed params to the propagated types.
                    match callArgExpr(callArgs[i]).kind {
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
                          case None -> {
                          }
                        }
                      }
                      case _ -> {
                      }
                    }
                    // `out`/`inout` parameter: pass the argument's address (a
                    // managed pointer) rather than its value.  See #1761.
                    val isByrefArg = if i < callParamModes.count { isByrefMode(callParamModes[i]) } else { false }
                    if isByrefArg {
                      emitByrefArgMsil(cctx, fctx, insns, callArgExpr(callArgs[i]))
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
                          pushCollExpect(fctx, pTy)
                          val _ = lowerCallArgMsil(cctx, fctx, insns, callArgs[i])
                          popCollExpect(fctx)
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
                          // A concrete-collection parameter pushes the expected type
                          // so a bare `newList()` / `[...]` argument builds the
                          // concrete instance the callee's signature requires.
                          pushCollExpect(fctx, pTy)
                          val aTy = lowerCallArgMsil(cctx, fctx, insns, callArgs[i])
                          popCollExpect(fctx)
                          // #2455: unbox a boxed (object) argument — e.g. a bound
                          // tuple element — to a value-type parameter.
                          coerceCallArgMsil(cctx, insns, aTy, pTy)
                        }
                      }
                      i = i + 1
                    }
                  }
                  insns.add(MCall(methodToken = tok))
                  match mapGet(cctx.funcRetTypes, tokKey) {
                    case Some(rt) -> rt
                    case None -> MObject
                  }
                }
                case None -> MObject
              }  // unreachable; effectiveFqn was a hit above
            } else if fctx.className.length > 0 and cctx.methodTokens.containsKey(fctx.className + "/" + funcName) {
              // Bare call to a sibling instance method (implicit `self`, slot 0).
              // Emit the callvirt the unresolved-call fallback below would have
              // dropped — leaving args on the stack with no call.
              // Arity-qualified key first (#2713) so a same-name, different-
              // arity sibling overload binds the right MethodDef.
              val sibArityKey = fctx.className + "/" + funcName + "/" + toString(args.count)
              val sibKey = if cctx.methodTokens.containsKey(sibArityKey) { sibArityKey } else { fctx.className + "/" + funcName }
              val sibTok = match mapGet(cctx.methodTokens, sibKey) {
                case Some(t) -> t
                case None -> panic("Msil.Codegen: sibling method token vanished after containsKey for " + sibKey)
              }
              insns.add(MLdarg(slot = 0))
              val sibModes = match mapGet(cctx.methodParamModes, sibKey) { case Some(ms) -> ms; case None -> newList() }
              var si = 0
              while si < args.count {
                val sibByref = if si < sibModes.count { isByrefMode(sibModes[si]) } else { false }
                if sibByref {
                  emitByrefArgMsil(cctx, fctx, insns, callArgExpr(args[si]))
                } else {
                  val aTy = lowerCallArgMsil(cctx, fctx, insns, args[si])
                  // Mirror the MClass dispatch arm: box only when the declared
                  // parameter is a reference/object type — boxing an Int arg
                  // for an `int32` parameter is invalid IL (#1723 / #1784).
                  val sibParamIsValue = match mapGet(cctx.methodParamTypes, sibKey + "#" + toString(si)) {
                    case Some(pt) -> isValueType(pt)
                    case None -> false
                  }
                  if not sibParamIsValue {
                    boxIfNeededMsil(cctx, insns, aTy)
                  }
                }
                si = si + 1
              }
              insns.add(MCallvirt(methodToken = sibTok))
              match mapGet(cctx.methodRetTypes, sibKey) {
                case Some(rty) -> rty
                case None -> MObject
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
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  recv: in Expr,
  memberName: in String,
  args: in List[CallArg],
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
        case None -> {
        }
      }
      // Distinct/range-subtype static factories (#1501): `Type.from(x)` and
      // `Type.tryFrom(x)` are static calls on a type NAME, so they cannot route
      // through instance dispatch (which would first evaluate the type name as a
      // value and emit invalid IL).  Guard against a local variable shadowing a
      // type name: a real local takes precedence and falls through to the value
      // path below.
      val recvIsLocal = path.segments.count == 1 and fctx.slots.containsKey(recvName)
      if not recvIsLocal {
        match mapGet(cctx.typeFqnByName, recvName) {
          case Some(distFqn) -> {
            if memberName == "from" {
              match mapGet(cctx.distinctFromTokens, distFqn) {
                case Some(tok) -> {
                  if args.count > 0 {
                    val _ = lowerCallArgMsil(cctx, fctx, insns, args[0])
                  }
                  insns.add(MCall(methodToken = tok))
                  return MClass(className = distFqn)
                }
                case None -> ()
              }
            }
            if memberName == "tryFrom" {
              match mapGet(cctx.distinctTryFromTokens, distFqn) {
                case Some(tok) -> {
                  if args.count > 0 {
                    val _ = lowerCallArgMsil(cctx, fctx, insns, args[0])
                  }
                  insns.add(MCall(methodToken = tok))
                  return match mapGet(cctx.distinctTryFromRetTypes, distFqn) { case Some(rt) -> rt; case None -> MObject }
                }
                case None -> ()
              }
            }
          }
          case None -> ()
        }
      }
    }
    case _ -> {
    }
  }
  // Fully-qualified free-function call whose multi-segment package prefix the
  // parser left as nested `EMember`s (`Grpc.Types.statusCodeFromInt(...)` parses
  // as `EMember(EMember(EPath["Grpc"], "Types"), "statusCodeFromInt")`, not an
  // `EPath`).  If the receiver flattens to a pure dotted path and
  // `<prefix>.<member>` names a registered free function — route to static-call
  // lowering.  `funcTokens` check disambiguates package-qualified calls from value
  // member access; single-segment package calls resolve elsewhere.
  val recvSegs = flattenPathExprSegs(recv)
  if recvSegs.count > 0 {
    recvSegs.add(memberName)
    val callFqn = joinSegsMsil(recvSegs, ".")
    val callArityFqn = callFqn + "/" + toString(args.count)
    if cctx.funcTokens.containsKey(callArityFqn) or cctx.funcTokens.containsKey(callFqn) {
      val staticPath = ModulePath(segments = recvSegs, span = recv.span)
      return lowerBuiltinOrStaticCallMsil(cctx, fctx, insns, memberName, staticPath, args)
    }
  }
  val recvTy = lowerExprMsil(cctx, fctx, insns, recv)
  // Auto-FFI instance dispatch: an extern class-ref receiver (e.g. the result
  // of a class-returning static like `Type.GetType(...)`) dispatches its
  // instance methods via `callvirt` against the real CLR method, resolved from
  // metadata.  The receiver is already on the stack.
  match recvTy {
    case MClassRef(_, fqn) -> match tryInstanceAutoFfiFromMetadata(cctx, fctx, insns, fqn, memberName, args) { case Some(rt) -> { return rt }; case None -> { val msg = "unresolved extern instance method '" + memberName + "' on '" + fqn + "': no matching instance method found in .NET metadata for the given argument " + "types.  Declare an @externTarget wrapper if a custom binding is intended."; insns.add(MLdStr(token = ctxInternUs(cctx.lctx, msg))); insns.add(MNewobj(ctorToken = cctx.tokExceptionCtor)); insns.add(MThrow); return MObject } }
    // An MClassRef receiver is exclusively produced by metadata-resolved
    // auto-FFI, so there is no other legitimate dispatch for it.  An
    // unresolved instance method means no matching instance method exists in
    // .NET metadata for the argument types.  Rather than abort the whole
    // build (a panic) or silently mis-bind to the null stub, emit a runtime
    // stub that throws a clear error at this call site — the same pattern the
    // unresolved-@externTarget path uses (#1041), honouring the language
    // reference's "never silently mis-bound" guarantee while keeping the
    // failure graceful and located at the offending call.
    case _ -> {
    }
  }
  // User-defined instance / interface dispatch path (#878).
  match recvTy {
    case MClass(cls) -> {
      // Arity-qualified key first (#2713): the bare `class/name` key maps to
      // whichever overload registered first, so a call to a same-name,
      // different-arity overload through the bare key would silently bind the
      // wrong MethodDef.  The registration side writes `class/name/arity`
      // for every overload; prefer it when present.
      val arityDispatchKey = cls + "/" + memberName + "/" + toString(args.count)
      val dispatchKey = if cctx.methodTokens.containsKey(arityDispatchKey) {
        arityDispatchKey
      } else {
        cls + "/" + memberName
      }
      match mapGet(cctx.methodTokens, dispatchKey) {
        case Some(tok) -> {
          val methodModes = match mapGet(cctx.methodParamModes, dispatchKey) { case Some(ms) -> ms; case None -> newList() }
          var i = 0
          while i < args.count {
            // `out`/`inout` argument: load the argument's address (a managed
            // pointer) rather than its value so the impl method can write
            // back through it (#1955).  Without this the by-value load
            // mismatches the `int32&` parameter the interface slot declares.
            val isByrefArg = if i < methodModes.count { isByrefMode(methodModes[i]) } else { false }
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
              val paramIsValue = match mapGet(cctx.methodParamTypes, dispatchKey + "#" + toString(i)) {
                case Some(pt) -> isValueType(pt)
                case None -> false
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
          return match mapGet(cctx.methodRetTypes, dispatchKey) { case Some(rty) -> rty; case None -> MObject }
        }
        case None -> {
          // Synthesized free functions callable as instance methods (#1507):
          // @derive(Equals/Hash/Show/Ord) appends free functions TypeName.method(self, args...)
          // registered in funcTokens as `cls + "." + memberName`.  The receiver is already
          // on the stack as the first (self) argument; load the remaining args and emit a
          // static call.  Mirrors the BEq `derivedEqualsTokenMsil` path but for named calls.
          match mapGet(cctx.funcTokens, cls + "." + memberName) {
            case Some(funcTok) -> {
              val funcParamList = match mapGet(cctx.funcParamTypes, cls + "." + memberName) {
                case Some(pts) -> pts
                case None -> newList()
              }
              var i = 0
              while i < args.count {
                // Free-function param 0 is `self` (already on the stack); arg i maps to param i+1.
                val paramIsValue = if (i + 1) < funcParamList.count { isValueType(funcParamList[i + 1]) } else { false }
                val aTy = lowerCallArgMsil(cctx, fctx, insns, args[i])
                if not paramIsValue {
                  boxIfNeededMsil(cctx, insns, aTy)
                }
                i = i + 1
              }
              insns.add(MCall(methodToken = funcTok))
              return match mapGet(cctx.funcRetTypes, cls + "." + memberName) { case Some(rty) -> rty; case None -> MObject }
            }
            case None -> {
            }
          }
        }
      }  // fall through to BCL-name dispatch
    }
    case _ -> {
    }
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
      case MConcreteList(MGenericInst(_, _, elemArgs)) -> {
        var ai = 0
        while ai < elemArgs.count {
          fctx.contextHintTyArgs.add(elemArgs[ai])
          ai = ai + 1
        }
        true
      }
      case MMapOf(MGenericInst(_, _, keyArgs), MGenericInst(_, _, valArgs)) -> {
        var ki = 0
        while ki < keyArgs.count {
          fctx.contextHintTyArgs.add(keyArgs[ki])
          ki = ki + 1
        }
        var vi = 0
        while vi < valArgs.count {
          fctx.contextHintTyArgs.add(valArgs[vi])
          vi = vi + 1
        }
        true
      }
      case MMapOf(MGenericInst(_, _, keyArgs), _) -> {
        var ki = 0
        while ki < keyArgs.count {
          fctx.contextHintTyArgs.add(keyArgs[ki])
          ki = ki + 1
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
      case MConcreteMap(MGenericInst(_, _, keyArgs), MGenericInst(_, _, valArgs)) -> {
        var ki = 0
        while ki < keyArgs.count {
          fctx.contextHintTyArgs.add(keyArgs[ki])
          ki = ki + 1
        }
        var vi = 0
        while vi < valArgs.count {
          fctx.contextHintTyArgs.add(valArgs[vi])
          vi = vi + 1
        }
        true
      }
      case MConcreteMap(MGenericInst(_, _, keyArgs), _) -> {
        var ki = 0
        while ki < keyArgs.count {
          fctx.contextHintTyArgs.add(keyArgs[ki])
          ki = ki + 1
        }
        true
      }
      case MConcreteMap(_, MGenericInst(_, _, valArgs)) -> {
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
      // A concrete `List<int32>` / `Dictionary<…>` stores arguments unboxed via
      // the closed generic `!0` MemberRef; only the legacy `List<object>` boxes.
      collBoxIfNeeded(cctx, insns, aTy, recvTy)
      i = i + 1
    }
    if addHintsPushed {
      while fctx.contextHintTyArgs.count > addPrevHintLen {
        fctx.contextHintTyArgs.removeAt(fctx.contextHintTyArgs.count - 1)
      }
    }
    if args.count >= 2 {
      emitDictAdd(cctx, insns, recvTy)
    } else {
      emitListAdd(cctx, insns, recvTy)
    }
    MVoid
  } else if memberName == "containsKey" {
    // Dictionary::ContainsKey(key): bool — concrete maps pass the key unboxed.
    if args.count > 0 {
      val aTy = lowerCallArgMsil(cctx, fctx, insns, args[0])
      collBoxIfNeeded(cctx, insns, aTy, recvTy)
    }
    emitDictContainsKey(cctx, insns, recvTy)
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
          val msgTok = ctxInternUs(
            cctx.lctx,
            "Msil.Codegen: String.contains expects 1 argument, got " + toString(args.count) +
              " (compiler bug: type checker should have validated arity)"
          )
          insns.add(MLdStr(token = msgTok))
          insns.add(MNewobj(ctorToken = cctx.tokInvalidOpExceptionCtor))
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
          collBoxIfNeeded(cctx, insns, aTy, recvTy)
          emitListContains(cctx, insns, recvTy)
        } else {
          var i = 0
          while i < args.count {
            lowerCallArgMsil(cctx, fctx, insns, args[i])
            insns.add(MPop)
            i = i + 1
          }
          insns.add(MPop)
          val msgTok = ctxInternUs(
            cctx.lctx,
            "Msil.Codegen: List.contains expects 1 argument, got " + toString(args.count) +
              " (compiler bug: type checker should have validated arity)"
          )
          insns.add(MLdStr(token = msgTok))
          insns.add(MNewobj(ctorToken = cctx.tokInvalidOpExceptionCtor))
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
      case MConcreteMap(_, _) -> {
        if args.count > 0 {
          val aTy = lowerCallArgMsil(cctx, fctx, insns, args[0])
          collBoxIfNeeded(cctx, insns, aTy, recvTy)
        }
        emitDictRemove(cctx, insns, recvTy)
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
      emitListRemoveAt(cctx, insns, recvTy)
      MVoid
    } else {
      var i = 0
      while i < args.count {
        lowerCallArgMsil(cctx, fctx, insns, args[i])
        insns.add(MPop)
        i = i + 1
      }
      insns.add(MPop)
      val msgTok = ctxInternUs(
        cctx.lctx,
        "Msil.Codegen: List.removeAt expects 1 argument, got " + toString(args.count) +
          " (compiler bug: type checker should have validated arity)"
      )
      insns.add(MLdStr(token = msgTok))
      insns.add(MNewobj(ctorToken = cctx.tokInvalidOpExceptionCtor))
      insns.add(MThrow)
      MVoid
    }
  } else if memberName == "toArray" {
    // `List.toArray()`: for a concrete `List<e>` (a genuine `List`1<e>` at
    // runtime) materialise a real CLR `e[]` via `ToArray()`, so
    // the result binds at an array-typed boundary — notably the F#-compiled,
    // array-based stdlib (`Std.Sort.sortStrings(String[])`, …).  This is the
    // conversion half of #2592 (the literal half is the `EList` `MArray` arm).
    //
    // For an erased / legacy `List<object>` receiver (`MListOf` / `MObject`) the
    // call stays a no-op returning the receiver: those iterate via
    // `get_Count` / `get_Item` (which work on the list directly), and returning
    // the tracked `MListOf(elem)` keeps the element type a `for x in
    // xs.toArray()` loop binds `x` with (an erased loop variable broke
    // `match x` / field access, #2126).
    match recvTy {
      case MConcreteList(e) -> {
        insns.add(MListOp(op = LoToArray, elemTy = e))
        MArray(elemTy = e)
      }
      case _ -> recvTy
    }
  } else if memberName == "toString" {
    // `callvirt Object.ToString()` requires a boxed reference on the stack.
    // Value types (Int, Long, Double, Bool, Char, Byte) must be boxed first
    // — without the `box` instruction the JIT treats the raw value bits as an
    // object pointer, causing a NullReferenceException at runtime.
    boxIfNeededMsil(cctx, insns, recvTy)
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
  } else if (memberName == "and" or memberName == "or" or memberName == "xor" or memberName == "shl" or memberName == "shr") and args.count == 1 {
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
  } else if (memberName == "toInt" or memberName == "toLong" or memberName == "toByte" or memberName == "toChar" or memberName == "toDouble") and args.count == 0 and isNumericMsil(recvTy) {
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
    val msg = "unsupported method '" + memberName + "' on the receiver type at this call site (no matching user method, " +
      "extern binding, or built-in intrinsic)"
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
// `for` loop patterns must be irrefutable: only a name, `_`, or a tuple of
// those is allowed.  Refutable forms emit F0021 so the user gets a span.
func bindForPatternMsil(
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  pat: in Pattern,
  slot: in Int,
  ty: in MsilType,
): Unit {
  match pat.kind {
    case PBinding(_, _) -> lowerPatternBindMsil(cctx, fctx, insns, pat, slot, ty)
    case PWildcard -> {
    }
    case PTuple(_) -> lowerPatternBindMsil(cctx, fctx, insns, pat, slot, ty)
    case PParen(inner) -> bindForPatternMsil(cctx, fctx, insns, inner, slot, ty)
    case _ -> {
      // Defensive only: the type checker rejects refutable `for` patterns
      // with T0112 (`forPatternIrrefutable` in typechecker_stmts.l, #3187),
      // so this branch should be unreachable.  If it is ever reached, no IL
      // is emitted for the binding and the produced assembly is invalid —
      // do not treat this path as a safe fallthrough.
      val spanStr = toString(pat.span.startPos.line) + ":" + toString(pat.span.startPos.column)
      println(
        "F0021: " + spanStr + ": a `for` loop variable must be an irrefutable pattern " +
          "(a name, `_`, or a tuple of those); refutable patterns are not allowed in a `for` binding"
      )
    }
  }
}

// Emit a counting loop for `for <pat> in lo .. hi` (inclusive=false) or
// `lo ..= hi` (inclusive=true).  `lo` / `hi` are each evaluated exactly once.
func emitCountingForMsil(
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  pat: in Pattern,
  lo: in Expr,
  hi: in Expr,
  inclusive: in Bool,
  body: in Block,
): Unit {
  // counter := lo
  val loTy = lowerExprMsil(cctx, fctx, insns, lo)
  val iSlot = allocSlotMsil(fctx, "__for_i_" + toString(fctx.slotTicker.count), loTy)
  emitStoreSlot(insns, iSlot, fctx.paramCount)
  // bound := hi (evaluated once so `for i in 0 .. f()` does not re-call f)
  val hiTy = lowerExprMsil(cctx, fctx, insns, hi)
  val hiSlot = allocSlotMsil(fctx, "__for_hi_" + toString(fctx.slotTicker.count), hiTy)
  emitStoreSlot(insns, hiSlot, fctx.paramCount)

  val loopL = freshLabelMsil(fctx)
  val contL = freshLabelMsil(fctx)
  val afterL = freshLabelMsil(fctx)

  insns.add(MLabel(id = loopL))
  // Continue while i < hi (half-open) or i <= hi (closed); else exit.
  emitLoadSlot(insns, iSlot, fctx.paramCount)
  emitLoadSlot(insns, hiSlot, fctx.paramCount)
  if inclusive {
    insns.add(MCgt)  // i > hi ?
    insns.add(MBrTrue(label = afterL))  // exit once the counter passes hi
  } else {
    insns.add(MClt)  // i < hi ?
    insns.add(MBrFalse(label = afterL))  // exit once i is no longer below hi
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
    case _ -> insns.add(MLdcI4(v = 1))
  }
  insns.add(MAdd)
  emitStoreSlot(insns, iSlot, fctx.paramCount)
  insns.add(MBr(label = loopL))
  insns.add(MLabel(id = afterL))
}

// Emit an index-based loop for `for <pat> in <collection>`, modelling the
// collection as `List<object>` (the bootstrap representation shared with the
// `EIndex` read path).  When the iterator expression's type is
// `MIAsyncEnumerable`, uses the async-enumerator protocol instead
// (GetAsyncEnumerator / MoveNextAsync / get_Current).
func emitCollectionForMsil(
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  pat: in Pattern,
  iter: in Expr,
  body: in Block,
): Unit {
  // list := <collection>.  Keep the iterable's tracked type so the loop
  // variable can be bound with its real element type rather than erased
  // `object` (#2126): a `for x in xs.toArray()` element bound as `MObject` made
  // `match x` / field access on `x` see an untyped scrutinee and misbehave.
  val iterTy = lowerExprMsil(cctx, fctx, insns, iter)

  // ── Async enumerator protocol for MIAsyncEnumerable (Phase 5, Epic #2070) ────
  // The synthesised generator class implements IAsyncEnumerable<object>.
  // Protocol: GetAsyncEnumerator(default(CancellationToken)) → enumerator;
  //   while MoveNextAsync().get_Result() { elem = get_Current(); body }
  match iterTy {
    case MIAsyncEnumerable(iaeElemTy) -> {
      val lctx = cctx.lctx

      // TypeSpecs (idempotent — same key → same row across calls)
      val iaeArgs2: List[MsilType] = newList()
      iaeArgs2.add(MObject)
      val iaeBlob2 = buildGenericInstBlob(tdrTypeRef(cctx.trIAE1), iaeArgs2)
      val tsIAERow2 = ctxAddTypeSpec(lctx, "ts_iae_obj", iaeBlob2)

      val iaetArgs2: List[MsilType] = newList()
      iaetArgs2.add(MObject)
      val iaetBlob2 = buildGenericInstBlob(tdrTypeRef(cctx.trIAET1), iaetArgs2)
      val tsIAETRow2 = ctxAddTypeSpec(lctx, "ts_iaet_obj", iaetBlob2)

      val vtBoolArgs2: List[MsilType] = newList()
      vtBoolArgs2.add(MBool)
      val vtBoolBlob2 = buildValueTypeGenericInstBlobWithCtx(lctx, tdrTypeRef(cctx.trValueTask1), vtBoolArgs2)
      val tsVtBoolRow2 = ctxAddTypeSpec(lctx, "ts_vt_bool", vtBoolBlob2)

      // MemberRef: IAsyncEnumerable<obj>::GetAsyncEnumerator(CancToken) → IAET<!0>
      // Return type uses MTypeVar(0) (= !0), the open form required by ECMA-335 for
      // TypeSpec-parented MemberRef signatures.  Using MObject (closed) prevents the CLR
      // from matching the MethodImpl MethodDeclaration → MissingMethodException.
      val ctTy2 = MValueTypeRef(typeRefCode = tdrTypeRef(cctx.trCancToken), clrFqn = "System.Threading.CancellationToken")
      val getEnumPs2: List[MsilType] = newList()
      getEnumPs2.add(ctTy2)
      val getEnumRet2Args: List[MsilType] = newList()
      getEnumRet2Args.add(MTypeVar(index = 0))
      val getEnumRet2 = MGenericInst(
        typeRefCode = tdrTypeRef(cctx.trIAET1),
        headFqn = "System.Collections.Generic.IAsyncEnumerator`1",
        typeArgs = getEnumRet2Args
      )
      val tokGetEnum2 = 0x0A000000 +
        ctxAddMemberRefForTypeSpec(
          lctx,
          tsIAERow2,
          "GetAsyncEnumerator",
          "iae_obj_getenum",
          buildInstanceMethodSig(getEnumPs2, getEnumRet2)
        )

      // MemberRef: IAsyncEnumerator<obj>::MoveNextAsync() → ValueTask<bool>
      val moveNextPs2: List[MsilType] = newList()
      val moveNextRet2Args: List[MsilType] = newList()
      moveNextRet2Args.add(MBool)
      val moveNextRet2 = MValueTypeGenericInst(
        typeRefCode = tdrTypeRef(cctx.trValueTask1),
        headFqn = "System.Threading.Tasks.ValueTask`1",
        typeArgs = moveNextRet2Args
      )
      val tokMoveNext2 = 0x0A000000 +
        ctxAddMemberRefForTypeSpec(
          lctx,
          tsIAETRow2,
          "MoveNextAsync",
          "iaet_obj_movenext",
          buildInstanceMethodSig(moveNextPs2, moveNextRet2)
        )

      // MemberRef: IAsyncEnumerator<obj>::get_Current() → !0
      val getCurrentPs2: List[MsilType] = newList()
      val tokGetCurrent2 = 0x0A000000 +
        ctxAddMemberRefForTypeSpec(
          lctx,
          tsIAETRow2,
          "get_Current",
          "iaet_obj_getcurrent",
          buildInstanceMethodSig(getCurrentPs2, MTypeVar(index = 0))
        )

      // MemberRef: ValueTask<bool>::get_Result() → !0
      val vtResPs2: List[MsilType] = newList()
      val tokVtRes2 = 0x0A000000 +
        ctxAddMemberRefForTypeSpec(
          lctx,
          tsVtBoolRow2,
          "get_Result",
          "vt_bool_getresult",
          buildInstanceMethodSig(vtResPs2, MTypeVar(index = 0))
        )

      // Store the generator (already on stack) into a local
      val genSlot2 = allocSlotMsil(fctx, "__iae_gen_" + toString(fctx.slotTicker.count), MObject)
      emitStoreSlot(insns, genSlot2, fctx.paramCount)

      // Allocate CancellationToken local and zero-init it via initobj
      val ctLocalTy2 = MValueTypeRef(
        typeRefCode = tdrTypeRef(cctx.trCancToken),
        clrFqn = "System.Threading.CancellationToken"
      )
      val ctSlot2 = allocSlotMsil(fctx, "__iae_ct_" + toString(fctx.slotTicker.count), ctLocalTy2)
      insns.add(MLdloca(slot = ctSlot2 - fctx.paramCount))
      insns.add(MInitobj(typeToken = 0x01000000 + cctx.trCancToken))

      // GetAsyncEnumerator(ct) → enumerator
      emitLoadSlot(insns, genSlot2, fctx.paramCount)
      insns.add(MLdloc(slot = ctSlot2 - fctx.paramCount))
      insns.add(MCallvirt(methodToken = tokGetEnum2))
      val enumSlot2 = allocSlotMsil(fctx, "__iae_enum_" + toString(fctx.slotTicker.count), MObject)
      emitStoreSlot(insns, enumSlot2, fctx.paramCount)

      // Allocate ValueTask<bool> struct local for MoveNextAsync result
      val vtBoolLocalTy2Args: List[MsilType] = newList()
      vtBoolLocalTy2Args.add(MBool)
      val vtBoolLocalTy2 = MValueTypeGenericInst(
        typeRefCode = tdrTypeRef(cctx.trValueTask1),
        headFqn = "System.Threading.Tasks.ValueTask`1",
        typeArgs = vtBoolLocalTy2Args
      )
      val vtSlot2 = allocSlotMsil(fctx, "__iae_vt_" + toString(fctx.slotTicker.count), vtBoolLocalTy2)

      val loopL2 = freshLabelMsil(fctx)
      val contL2 = freshLabelMsil(fctx)
      val afterL2 = freshLabelMsil(fctx)

      insns.add(MLabel(id = loopL2))
      // MoveNextAsync() → ValueTask<bool>; store struct; extract bool via get_Result
      emitLoadSlot(insns, enumSlot2, fctx.paramCount)
      insns.add(MCallvirt(methodToken = tokMoveNext2))
      insns.add(MStloc(slot = vtSlot2 - fctx.paramCount))
      insns.add(MLdloca(slot = vtSlot2 - fctx.paramCount))
      insns.add(MCall(methodToken = tokVtRes2))
      insns.add(MBrFalse(label = afterL2))

      // get_Current() returns `object` (box-erased IAsyncEnumerator<object>).
      // Unbox/cast to the generator's declared element type so value-type
      // arithmetic and pattern-matching on the loop variable work correctly
      // (e.g. `total + x` where x comes from a genUpTo(5): Int generator).
      emitLoadSlot(insns, enumSlot2, fctx.paramCount)
      insns.add(MCallvirt(methodToken = tokGetCurrent2))
      castObjectToMsil(cctx, insns, iaeElemTy)
      val elemSlot2 = allocSlotMsil(fctx, "__iae_elem_" + toString(fctx.slotTicker.count), iaeElemTy)
      emitStoreSlot(insns, elemSlot2, fctx.paramCount)
      bindForPatternMsil(cctx, fctx, insns, pat, elemSlot2, iaeElemTy)

      fctx.loopBreak.add(afterL2)
      fctx.loopCont.add(contL2)
      fctx.loopTryDepth.add(fctx.tryRegionStack.count)
      lowerBlockMsil(cctx, fctx, insns, body)
      fctx.loopTryDepth.removeAt(fctx.loopTryDepth.count - 1)
      fctx.loopBreak.removeAt(fctx.loopBreak.count - 1)
      fctx.loopCont.removeAt(fctx.loopCont.count - 1)

      insns.add(MLabel(id = contL2))
      insns.add(MBr(label = loopL2))
      insns.add(MLabel(id = afterL2))
      // Call DisposeAsync on the enumerator when loop exits (either exhausted or
      // via break) to satisfy the IAsyncEnumerator<T> consumption protocol.
      // Currently a no-op (returns default(ValueTask)) for the eager-producer
      // generator, but required for correctness once lazy/cancellable generators
      // land.  Discard the returned ValueTask (the loop result is not async here).
      val dispAsyncVtTy = MValueTypeRef(
        typeRefCode = tdrTypeRef(cctx.trValueTask),
        clrFqn = "System.Threading.Tasks.ValueTask"
      )
      val dispAsyncPs: List[MsilType] = newList()
      val dispAsyncSig = buildInstanceMethodSig(dispAsyncPs, dispAsyncVtTy)
      val tokDispAsync = 0x0A000000 +
        ctxAddMemberRef(lctx, cctx.trIAsyncDisp, "DisposeAsync", "iasyncdisp_disposeasync", dispAsyncSig)
      val dispVtSlot = allocSlotMsil(fctx, "__iae_disp_vt_" + toString(fctx.slotTicker.count), dispAsyncVtTy)
      emitLoadSlot(insns, enumSlot2, fctx.paramCount)
      insns.add(MCallvirt(methodToken = tokDispAsync))
      insns.add(MStloc(slot = dispVtSlot - fctx.paramCount))  // discard ValueTask by storing to unused local
    }
    case _ -> {
      // ── List<object> / Array index-loop protocol (existing path) ─────────────
      // Narrow only reference (`MClass`) elements — user records / unions, the
      // affected case.  Value-type and unknown elements keep the existing
      // `MObject` binding to avoid changing their (working) lowering.
      // A concrete `List<Foo>` iterable yields its element type directly and is
      // counted/indexed through the concrete closed-generic tokens.  The container
      // kind (`iterTy`) is threaded to the count/get_Item helpers below.
      val forElemRaw = match iterTy {
        case MArray(e) -> e
        case MListOf(e) -> e
        case MConcreteList(e) -> e
        case _ -> MObject
      }
      // A concrete list's `get_Item` returns the element already typed (ref OR
      // value), so the loop variable takes the exact element type and needs no
      // read-narrow.  A genuine array (`MArray`) is read through
      // `IList.get_Item`, which returns `object`, so the loop variable takes the
      // array's element type and the value is narrowed (unbox value types,
      // castclass refs) below — without this an `Int[]` element read garbage and
      // a `String[]` element mis-dispatched (#2592, exposed once concrete
      // `List.toArray()` yields a real array).  Other legacy/erased iterables
      // keep the existing behaviour: narrow only `MClass` refs.
      val forElemTy = match iterTy {
        case MConcreteList(e) -> e
        case MArray(e) -> e
        case _ -> match forElemRaw { case MClass(_) -> forElemRaw; case _ -> MObject }
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
      emitListCastRecv(cctx, insns, iterTy)
      emitListGetCount(cctx, insns, iterTy)
      emitStoreSlot(insns, cntSlot, fctx.paramCount)

      val loopL = freshLabelMsil(fctx)
      val contL = freshLabelMsil(fctx)
      val afterL = freshLabelMsil(fctx)

      insns.add(MLabel(id = loopL))
      emitLoadSlot(insns, iSlot, fctx.paramCount)
      emitLoadSlot(insns, cntSlot, fctx.paramCount)
      insns.add(MClt)
      insns.add(MBrFalse(label = afterL))
      // elem := list[i]
      emitLoadSlot(insns, listSlot, fctx.paramCount)
      emitListCastRecv(cctx, insns, iterTy)
      emitLoadSlot(insns, iSlot, fctx.paramCount)
      emitListGetItem(cctx, insns, iterTy)
      // Legacy `get_Item` returns `object`; narrow to the real element type when
      // it is a known reference type.  A concrete list already returns the typed
      // element (ref or value), so no narrow is emitted.
      match iterTy {
        case MConcreteList(_) -> ()
        case _ -> if forElemTy != MObject { castObjectToMsil(cctx, insns, forElemTy) }
      }
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
  }
}

// Dispatch a `for` statement to the range or collection lowering.
func lowerForMsil(
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  pat: in Pattern,
  iter: in Expr,
  body: in Block,
): Unit {
  match iter.kind {
    case ERange(bound) -> {
      match bound {
        case RBClosed(lo, hi) -> emitCountingForMsil(cctx, fctx, insns, pat, lo, hi, true, body)
        case RBHalfOpen(lo, hi) -> emitCountingForMsil(cctx, fctx, insns, pat, lo, hi, false, body)
        case RBLowerOpen(_) -> panic("Msil.Codegen: an open-start range (`..= b`) cannot drive a `for` loop — it has no lower bound to count from (#1478).")
        case RBUpperOpen(_) -> panic("Msil.Codegen: an open-end range (`a ..`) cannot drive a `for` loop — it is unbounded (#1478).")
      }
    }
    case _ -> emitCollectionForMsil(cctx, fctx, insns, pat, iter, body)
  }
}

pub func lowerStmtMsil(cctx: in CodegenCtx, fctx: in FuncCtx, insns: in List[MInsn], stmt: in Statement): Unit {
  match stmt.kind {

    // ── Local bindings ────────────────────────────────────────────────────────
    case SLocal(binding) -> {
      match binding {
        case LBVal(pat, tyOpt, init) -> {
          val annoTy = match tyOpt { case Some(te) -> typeExprToMsilCtx(cctx, te, fctx.pkgName); case None -> MObject }
          val prevHintLen = fctx.contextHintTyArgs.count
          match annoTy {
            case MGenericInst(_, _, typeArgs) -> {
              var hi = 0
              while hi < typeArgs.count {
                fctx.contextHintTyArgs.add(typeArgs[hi])
                hi = hi + 1
              }
            }
            // An in-bundle generic type annotation (`val m: Maybe[Int] = Nothing`)
            // threads its concrete args so a payload-light construction (a nullary
            // case, or a case that pins only some params) instantiates at the
            // annotated args rather than erasing the rest to `object` — otherwise
            // the value's runtime instantiation won't match the `match` scrutinee
            // type and every arm's `isinst` fails (#2362).
            case MGenericInstByName(_, typeArgs) -> {
              var hi = 0
              while hi < typeArgs.count {
                fctx.contextHintTyArgs.add(typeArgs[hi])
                hi = hi + 1
              }
            }
            case _ -> {
            }
          }
          // Empty typed-slice literal (`val xs: slice[T] = []`): the generic
          // `[]` otherwise lowers to a `List<object>`, which then mis-reads as
          // a `T[]` at the MArray-typed local (#1497).  Emit a real empty
          // `T[]` via `System.Array.Empty<T>()` (open-generic BCL call →
          // MethodSpec).
          pushCollExpect(fctx, annoTy)
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
          popCollExpect(fctx)
          while fctx.contextHintTyArgs.count > prevHintLen {
            fctx.contextHintTyArgs.removeAt(fctx.contextHintTyArgs.count - 1)
          }
          val effectiveTy = if annoTy != MObject { annoTy } else { initTy }
          lowerLocalPatBindMsil(cctx, fctx, insns, pat, effectiveTy, tyOpt)
        }
        case LBLet(name, tyOpt, init) -> {
          val annoTy = match tyOpt { case Some(te) -> typeExprToMsilCtx(cctx, te, fctx.pkgName); case None -> MObject }
          val prevHintLen = fctx.contextHintTyArgs.count
          match annoTy {
            case MGenericInst(_, _, typeArgs) -> {
              var hi = 0
              while hi < typeArgs.count {
                fctx.contextHintTyArgs.add(typeArgs[hi])
                hi = hi + 1
              }
            }
            // An in-bundle generic type annotation (`val m: Maybe[Int] = Nothing`)
            // threads its concrete args so a payload-light construction (a nullary
            // case, or a case that pins only some params) instantiates at the
            // annotated args rather than erasing the rest to `object` — otherwise
            // the value's runtime instantiation won't match the `match` scrutinee
            // type and every arm's `isinst` fails (#2362).
            case MGenericInstByName(_, typeArgs) -> {
              var hi = 0
              while hi < typeArgs.count {
                fctx.contextHintTyArgs.add(typeArgs[hi])
                hi = hi + 1
              }
            }
            case _ -> {
            }
          }
          pushCollExpect(fctx, annoTy)
          val initTy = lowerExprMsil(cctx, fctx, insns, init)
          popCollExpect(fctx)
          while fctx.contextHintTyArgs.count > prevHintLen {
            fctx.contextHintTyArgs.removeAt(fctx.contextHintTyArgs.count - 1)
          }
          val ty = if annoTy != MObject { annoTy } else { initTy }
          val slot = allocSlotMsil(fctx, name, ty)
          emitStoreSlot(insns, slot, fctx.paramCount)
          // Register the declared return type for function-typed locals so an
          // invocation `f()` yields the correct type rather than a bare object.
          // Mirrors the param-side registration that guards against the
          // InvalidCastException footgun (#1951).
          match tyOpt {
            case Some(te) -> {
              match te.kind {
                case TFunction(_, retTe) -> {
                  if not fctx.funcValRetTypes.containsKey(name) {
                    fctx.funcValRetTypes.add(name, typeExprToMsilCtx(cctx, retTe, fctx.pkgName))
                  }
                }
                case _ -> ()
              }
            }
            case None -> ()
          }
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
              val annoTy = match tyOpt { case Some(te) -> typeExprToMsilCtx(cctx, te, fctx.pkgName); case None -> MObject }
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
                case _ -> {
                }
              }
              pushCollExpect(fctx, annoTy)
              val initTy = lowerExprMsil(cctx, fctx, insns, init)
              popCollExpect(fctx)
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
              val ty = match tyOpt { case Some(te) -> typeExprToMsilCtx(cctx, te, fctx.pkgName); case None -> MInt }
              if isHoisted and ty != MVoid {
                insns.add(MNewobj(ctorToken = cctx.tokListObjCtor))
                insns.add(MDup)
                match ty {
                  case MLong -> {
                    insns.add(MLdcI8(v = intToLong(0)))
                  }
                  case MDouble -> {
                    insns.add(MLdcR8(v = 0.0))
                  }
                  case _ -> {
                    insns.add(MLdcI4(v = 0))
                  }
                }
                finishHoistedCellMsil(cctx, fctx, insns, name, ty)
              } else {
                val slot = allocSlotMsil(fctx, name, ty)
                fctx.mutableLocals.add(name)
                match ty {
                  case MLong -> {
                    insns.add(MLdcI8(v = intToLong(0)))
                    emitStoreSlot(insns, slot, fctx.paramCount)
                  }
                  case MDouble -> {
                    insns.add(MLdcR8(v = 0.0))
                    emitStoreSlot(insns, slot, fctx.paramCount)
                  }
                  case MVoid -> {
                  }
                  case _ -> {
                    insns.add(MLdcI4(v = 0))
                    emitStoreSlot(insns, slot, fctx.paramCount)
                  }
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
          panic(
            "Msil.Codegen: SReturn inside protected region but FuncCtx.epilogueLabel was not reserved (caller must invoke lowerFuncMsil / lowerImplMethodMsil)"
          )
        }
        match valOpt {
          case Some(e) -> {
            pushCollExpect(fctx, fctx.declaredRetTy)
            lowerExprMsil(cctx, fctx, insns, e)
            popCollExpect(fctx)
            if fctx.retvalSlot < 0 {
              fctx.retvalSlot = allocSlotMsil(fctx, "__retval", fctx.declaredRetTy)
            }
            emitStoreSlot(insns, fctx.retvalSlot, fctx.paramCount)
          }
          case None -> {
          }
        }
        fctx.epilogueUsed.add(0)
        insns.add(MLeave(label = fctx.epilogueLabel))
      } else {
        match valOpt {
          case Some(e) -> {
            pushCollExpect(fctx, fctx.declaredRetTy)
            lowerExprMsil(cctx, fctx, insns, e)
            popCollExpect(fctx)
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
        case MVoid -> {
        }
        case _ -> insns.add(MPop)
      }
    }

    // ── While loop ────────────────────────────────────────────────────────────
    case SWhile(_, cond, body) -> {
      val loopL = freshLabelMsil(fctx)
      val afterL = freshLabelMsil(fctx)
      insns.add(MLabel(id = loopL))
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
      insns.add(MLabel(id = afterL))
    }

    // ── For loop (range fast-path + collection iteration, #1478) ──────────────
    case SFor(_, pat, iter, body) -> {
      lowerForMsil(cctx, fctx, insns, pat, iter, body)
    }

    // ── Loop (unconditional) ──────────────────────────────────────────────────
    case SLoop(_, body) -> {
      val loopL2 = freshLabelMsil(fctx)
      val afterL2 = freshLabelMsil(fctx)
      insns.add(MLabel(id = loopL2))
      fctx.loopBreak.add(afterL2)
      fctx.loopCont.add(loopL2)
      fctx.loopTryDepth.add(fctx.tryRegionStack.count)
      lowerBlockMsil(cctx, fctx, insns, body)
      fctx.loopTryDepth.removeAt(fctx.loopTryDepth.count - 1)
      fctx.loopBreak.removeAt(fctx.loopBreak.count - 1)
      fctx.loopCont.removeAt(fctx.loopCont.count - 1)
      insns.add(MBr(label = loopL2))
      insns.add(MLabel(id = afterL2))
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
    case SInvariant(_) -> {
    }

    // ── Inline item declaration (skip in bootstrap) ────────────────────────────
    case SItem(_) -> {
    }

    // ── Rule statement (skip) ─────────────────────────────────────────────────
    case SRule(_, _) -> {
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6a. Local pattern binding.
// ─────────────────────────────────────────────────────────────────────────────
func lowerLocalPatBindMsil(
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  pat: in Pattern,
  initTy: in MsilType,
  tyOpt: in Option[TypeExpr],
): Unit {
  match pat.kind {
    case PBinding(name, _) -> {
      val ty = match tyOpt { case Some(te) -> typeExprToMsilCtx(cctx, te, fctx.pkgName); case None -> initTy }
      val slot = allocSlotMsil(fctx, name, ty)
      emitStoreSlot(insns, slot, fctx.paramCount)
    }
    case PWildcard -> {
      match initTy {
        case MVoid -> {
        }
        case _ -> insns.add(MPop)
      }
    }
    case _ -> {
      val tmpSlot = allocSlotMsil(fctx, "__tmp_" + toString(fctx.slotTicker.count), initTy)
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
  val loopDepth = if fctx.loopTryDepth.count > 0 { fctx.loopTryDepth[fctx.loopTryDepth.count - 1] } else { 0 }
  if fctx.tryRegionStack.count > loopDepth {
    insns.add(MLeave(label = target))
  } else {
    insns.add(MBr(label = target))
  }
}

func lowerTryCatchMsil(
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  body: in Block,
  catches: in List[CatchClause],
  finally_: in Option[Block],
): Unit {
  val hasCatch = catches.count > 0
  val hasFinally = match finally_ { case Some(_) -> true; case None -> false }
  val tryStartL = freshLabelMsil(fctx)
  val afterL = freshLabelMsil(fctx)

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
    insns.add(
      MEHClause(
        flags = 0,
        tryStart = tryStartL,
        tryEnd = tryBodyEndL,
        handlerStart = handlerStartL,
        handlerEnd = handlerEndL,
        catchToken = 0x01000000 + cctx.trException
      )
    )
    i = i + 1
  }

  // Finally handler: covers the entire try+catch region ([tryStartL, finallyStartL)).
  // `leave` in the try/catch body transfers to afterL; the CLR runs the finally
  // handler before transferring.  `endfinally` resumes the leave target or
  // rethrows the in-flight exception.
  match finally_ {
    case None -> {
    }
    case Some(fb) -> {
      val finallyStartL = freshLabelMsil(fctx)
      val finallyEndL = freshLabelMsil(fctx)
      insns.add(MLabel(id = finallyStartL))
      lowerBlockMsil(cctx, fctx, insns, fb)
      insns.add(MEndfinally)
      insns.add(MLabel(id = finallyEndL))
      insns.add(
        MEHClause(
          flags = 2,
          tryStart = tryStartL,
          tryEnd = finallyStartL,
          handlerStart = finallyStartL,
          handlerEnd = finallyEndL,
          catchToken = 0
        )
      )
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
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  body: in Block,
  catches: in List[CatchClause],
  finally_: in Option[Block],
): MsilType {
  val hasCatch = catches.count > 0
  val hasFinally = match finally_ { case Some(_) -> true; case None -> false }
  val tryStartL = freshLabelMsil(fctx)
  val afterL = freshLabelMsil(fctx)

  insns.add(MLabel(id = tryStartL))
  fctx.tryRegionStack.add(0)
  val tryTy = lowerBlockExprMsil(cctx, fctx, insns, body)
  var resultTy = tryTy
  var resultSlot = -1
  match tryTy {
    case MVoid -> {
    }
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
      case MVoid -> {
      }
      case _ -> {
        if resultSlot < 0 {
          resultSlot = allocSlotMsil(fctx, "__tryval_" + toString(fctx.slotTicker.count), catchTy)
          resultTy = catchTy
        }
        emitStoreSlot(insns, resultSlot, fctx.paramCount)
      }
    }
    fctx.tryRegionStack.removeAt(fctx.tryRegionStack.count - 1)
    insns.add(MLeave(label = afterL))
    val handlerEndL = freshLabelMsil(fctx)
    insns.add(MLabel(id = handlerEndL))
    insns.add(
      MEHClause(
        flags = 0,
        tryStart = tryStartL,
        tryEnd = tryBodyEndL,
        handlerStart = handlerStartL,
        handlerEnd = handlerEndL,
        catchToken = 0x01000000 + cctx.trException
      )
    )
    i = i + 1
  }

  match finally_ {
    case None -> {
    }
    case Some(fb) -> {
      val finallyStartL = freshLabelMsil(fctx)
      val finallyEndL = freshLabelMsil(fctx)
      insns.add(MLabel(id = finallyStartL))
      lowerBlockMsil(cctx, fctx, insns, fb)
      insns.add(MEndfinally)
      insns.add(MLabel(id = finallyEndL))
      insns.add(
        MEHClause(
          flags = 2,
          tryStart = tryStartL,
          tryEnd = finallyStartL,
          handlerStart = finallyStartL,
          handlerEnd = finallyEndL,
          catchToken = 0
        )
      )
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
pub func lowerBlockMsil(cctx: in CodegenCtx, fctx: in FuncCtx, insns: in List[MInsn], block: in Block): Unit {
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
func lowerStmtsFromMsil(
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  stmts: in List[Statement],
  start: in Int,
): Unit {
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
func makeFuncCtxMsil(
  pkgName: in String,
  className: in String,
  funcName: in String,
  paramCount: in Int,
  declaredRetTy: in MsilType,
): FuncCtx {
  val slots: Map[String, Int] = newMap()
  val types: Map[String, MsilType] = newMap()
  val locals: List[MsilType] = newList()
  val slotTicker: List[Int] = newList()
  val labelTicker: List[Int] = newList()
  val loopBreak: List[Int] = newList()
  val loopCont: List[Int] = newList()
  val loopTryDepth: List[Int] = newList()
  val tryRegionStack: List[Int] = newList()
  val epilogueUsed: List[Int] = newList()
  val yieldSlots: List[Int] = newList()
  val contextHintTyArgs: List[MsilType] = newList()
  val collExpect: List[MsilType] = newList()
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
    pkgName = pkgName,
    className = className,
    funcName = funcName,
    slots = slots,
    types = types,
    locals = locals,
    slotTicker = slotTicker,
    labelTicker = labelTicker,
    paramCount = paramCount,
    loopBreak = loopBreak,
    loopCont = loopCont,
    loopTryDepth = loopTryDepth,
    tryRegionStack = tryRegionStack,
    epilogueLabel = -1,
    retvalSlot = -1,
    epilogueUsed = epilogueUsed,
    yieldSlots = yieldSlots,
    declaredRetTy = declaredRetTy,
    contextHintTyArgs = contextHintTyArgs,
    collExpect = collExpect,
    byrefSlotTypes = byrefSlotTypes,
    funcValRetTypes = funcValRetTypes,
    boxedParamTypes = boxedParamTypes,
    captureNameToIndex = captureNameToIndex,
    captureNameToType = captureNameToType,
    mutableLocals = mutableLocals,
    hoistedVarNames = hoistedVarNames,
    hoistedCellSlot = hoistedCellSlot,
    hoistedCellType = hoistedCellType,
    captureCellNames = captureCellNames,
    phaseBCtx = newList(),
    lazyGenCtx = newList()
  )
}

// Check whether the last meaningful instruction in a list is a return or throw.
func endsWithReturnMsil(insns: in List[MInsn]): Bool {
  var i = insns.count - 1
  while i >= 0 {
    match insns[i] {
      case MRet -> {
        return true
      }
      case MThrow -> {
        return true
      }
      case MNop -> {
        i = i - 1
      }
      // A label may be a branch target from code above (e.g. the after-label
      // of a match expression), so we cannot treat instructions before it as
      // the effective end of the method.  Stop scanning and report "no terminal".
      case MLabel(_) -> {
        return false
      }
      case _ -> {
        return false
      }
    }
  }
  false
}

// ─────────────────────────────────────────────────────────────────────────────
// §8b-pre. computeMaxStackMsil — conservative maxStack from instruction stream.
// Linear scan; for instructions with unknown arity (MCall, MCallvirt, MNewobj,
// etc.) we use +1 as a conservative upper-bound delta so the actual peak
// (captured during arg-push sequences) is never underestimated.  The result
// is always >= 8 to handle fixed preamble/epilogue code in generated SMs.
// ─────────────────────────────────────────────────────────────────────────────
func listOpStackDelta(op: in ListOp): Int {
  match op {
    case LoCastclass -> 0
    case _ -> 1
  }
}

func dictOpStackDelta(op: in DictOp): Int {
  match op {
    case DoCastclass -> 0
    case _ -> 1
  }
}

func insnStackDelta(insn: in MInsn): Int {
  match insn {
    case MLabel(_) -> 0
    case MBr(_) -> 0
    case MBrTrue(_) -> -1
    case MBrFalse(_) -> -1
    case MBrEq(_) -> -2
    case MBrNe(_) -> -2
    case MBrLt(_) -> -2
    case MBrGt(_) -> -2
    case MBrLe(_) -> -2
    case MBrGe(_) -> -2
    case MNop -> 0
    case MRet -> 0
    case MLdNull -> 1
    case MLdcI4(_) -> 1
    case MLdcI8(_) -> 1
    case MLdcR8(_) -> 1
    case MLdStr(_) -> 1
    case MLdarg(_) -> 1
    case MStarg(_) -> -1
    case MLdloc(_) -> 1
    case MStloc(_) -> -1
    case MLdloca(_) -> 1
    case MLdarga(_) -> 1
    case MLdind(_) -> 0
    case MStind(_) -> -2
    case MAdd -> -1
    case MSub -> -1
    case MMul -> -1
    case MDiv -> -1
    case MRem -> -1
    case MAnd -> -1
    case MOr -> -1
    case MXor -> -1
    case MNeg -> 0
    case MNot -> 0
    case MShl -> -1
    case MShr -> -1
    case MShrUn -> -1
    case MCeq -> -1
    case MClt -> -1
    case MCgt -> -1
    case MConvI4 -> 0
    case MConvI8 -> 0
    case MConvR8 -> 0
    case MConvU1 -> 0
    case MConvU2 -> 0
    case MNewobj(_) -> 1
    case MLdfld(_) -> 0
    case MLdflda(_) -> 0
    case MStfld(_) -> -2
    case MLdsfld(_) -> 1
    case MStsfld(_) -> -1
    case MCall(_) -> 1
    case MCallvirt(_) -> 1
    case MCastclass(_) -> 0
    case MCastclassByName(_) -> 0
    case MIsinst(_) -> 0
    case MIsinstByName(_) -> 0
    case MIsinstGeneric(_, _) -> 0
    case MCastclassGeneric(_, _) -> 0
    case MListOp(op, _) -> listOpStackDelta(op)
    case MDictOp(op, _, _) -> dictOpStackDelta(op)
    case MLdfldGeneric(_, _, _, _) -> 0
    case MNewobjGenericCase(_, _, _) -> 1
    case MNewobjGenericByName(_, _, _) -> 1
    case MBox(_) -> 0
    case MUnboxAny(_) -> 0
    case MNewarr(_) -> 0
    case MStelemRef -> -3
    case MStelem(_) -> -3
    case MDup -> 1
    case MPop -> -1
    case MThrow -> 0
    case MLdlen -> 0
    case MLdelemRef -> -1
    case MLdelemU1 -> -1
    case MLdelemI4 -> -1
    case MLdftn(_) -> 1
    case MLeave(_) -> 0
    case MEndfinally -> 0
    case MEHClause(_, _, _, _, _, _) -> 0
    case MLdfldByName(_, _) -> 0
    case MLdfldaByName(_, _) -> 0
    case MStfldByName(_, _) -> -2
    case MNewobjByName(_) -> 1
    case MCallAtmbStart(_, _, _) -> 1
    case MSwitch(_) -> -1
    case MInitobj(_) -> -1
    case MCallAwaitUnsafeOnCompleted(_, _, _) -> 1
    case MCallByName(_, _) -> 1
  }
}

pub func computeMaxStackMsil(insns: in List[MInsn]): Int {
  var cur = 0
  var peak = 0
  var i = 0
  while i < insns.count {
    cur = cur + insnStackDelta(insns[i])
    if cur > peak {
      peak = cur
    }
    i = i + 1
  }
  if peak < 8 {
    8
  } else {
    peak
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §8b. FFI emission for `@externTarget` (#370 + Phase R6).
// ─────────────────────────────────────────────────────────────────────────────
// True iff the annotation list contains `@externTarget("...")`.
func hasExternTargetMsil(anns: in List[Annotation]): Bool {
  var i = 0
  while i < anns.count {
    val segs = anns[i].name.segments
    if segs.count == 1 and segs[0] == "externTarget" {
      return true
    }
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
          case ALiteral(v, _) -> match v { case AVString(s, _) -> { return s }; case _ -> () }
          case AAName(_, v, _) -> match v { case AVString(s, _) -> { return s }; case _ -> () }
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
    case None -> {
      val row = if asmName == "System.Runtime" or asmName == "System.Private.CoreLib" or asmName == "mscorlib" {
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
func internFfiTypeRef(cctx: in CodegenCtx, asmName: in String, ns: in String, typeName: in String): Int {
  val key = asmName + "/" + ns + "." + typeName
  match mapGet(cctx.ffiTypeRefs, key) {
    case Some(r) -> r
    case None -> {
      val arRow = internFfiAssemblyRef(cctx, asmName)
      val tRow = ctxAddTypeRef(cctx.lctx, ns, typeName, arRow)
      cctx.ffiTypeRefs.add(key, tRow)
      tRow
    }
  }
}

// True when `e` is an empty list/slice literal `[]`.
func isEmptyListExprMsil(e: in Expr): Bool {
  match e.kind {
    case EList(exprs) -> exprs.count == 0
    case _ -> false
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
  val msRow = ctxAddMethodSpec(cctx.lctx, mdorMemberRef(mrRow), "array_empty_spec_" + msilTypeKey(elem), specBlob)
  insns.add(MCall(methodToken = 0x2B000000 + msRow))
}

// Return the TypeRef row for System.Action`N (N ≥ 1).
// TypeRefs are registered lazily on first use for each distinct N and cached
// in cctx.actionTypeRefs to avoid duplicate metadata rows.
func internActionTypeRef(cctx: in CodegenCtx, nparams: in Int): Int {
  val key = toString(nparams)
  match mapGet(cctx.actionTypeRefs, key) {
    case Some(r) -> r
    case None -> {
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
  while ai < nparams {
    objArgs.add(MObject)
    ai = ai + 1
  }
  val gblob = buildGenericInstBlob(codedIdx, objArgs)
  val specKey = "ActionSpec_ctor_" + toString(nparams)
  val tsRow = ctxAddTypeSpec(cctx.lctx, specKey, gblob)
  val ctorPs: List[MsilType] = newList()
  ctorPs.add(MObject)
  ctorPs.add(MNativeInt)
  val ctorSig = buildInstanceMethodSig(ctorPs, MVoid)
  val mrRow = ctxAddMemberRefForTypeSpec(cctx.lctx, tsRow, ".ctor", "action_ctor_" + toString(nparams), ctorSig)
  0x0A000000 + mrRow
}

// Get or create a TypeRef for System.Func`(nparams+1) where nparams is the lambda parameter count.
// Reuses the actionTypeRefs map with a "func_N" key to avoid collisions.
func internFuncTypeRef(cctx: in CodegenCtx, nparams: in Int): Int {
  val key = "func_" + toString(nparams)
  match mapGet(cctx.actionTypeRefs, key) {
    case Some(r) -> r
    case None -> {
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
      while ai < nparams + 1 {
        objArgs.add(MObject)
        ai = ai + 1
      }
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
  val mrRow = ctxAddMemberRefForTypeSpec(cctx.lctx, tsRow, ".ctor", "func_ctor_" + toString(nparams), ctorSig)
  0x0A000000 + mrRow
}

// Build a callvirt token for System.Func`(nparams+1)<object,...,object>::Invoke(object,...): object.
// Params are type vars 0..nparams-1; the return type is the last type var (nparams).
func buildFuncNInvokeTok(cctx: in CodegenCtx, nparams: in Int): Int {
  val tsRow = internFuncNTypeSpec(cctx, nparams)
  val invokePs: List[MsilType] = newList()
  var pi = 0
  while pi < nparams {
    invokePs.add(MTypeVar(index = pi))
    pi = pi + 1
  }
  val invokeSig = buildInstanceMethodSig(invokePs, MTypeVar(index = nparams))
  val mrRow = ctxAddMemberRefForTypeSpec(cctx.lctx, tsRow, "Invoke", "func_invoke_" + toString(nparams), invokeSig)
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
  val clrFqn = match mapGet(cctx.externTypeNames, simple) {
    case Some(fqn) -> fqn
    case None -> if startsWith(className, "System.") { className } else { "" }
  }
  if clrFqn == "" {
    return 0 - 1
  }
  // Nested types (ResolutionScope = enclosing TypeRef, not AssemblyRef) need
  // a different encoding than `internFfiTypeRef` provides; skip them safely.
  if contains(clrFqn, "+") {
    return 0 - 1
  }
  val sp = splitTypeFqn(clrFqn)
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
        bufU1(w, 0x12)  // ELEMENT_TYPE_CLASS
        writeCompressedInt(w, (row * 4) + 1)  // TypeDefOrRef coded index (TypeRef tag = 1)
      } else {
        bufU1(w, 0x1C)  // ELEMENT_TYPE_OBJECT fallback
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
    case MInt -> "i4"
    case MLong -> "i8"
    case MDouble -> "r8"
    case MBool -> "bool"
    case MChar -> "char"
    case MString -> "str"
    case MVoid -> "void"
    case MObject -> "obj"
    case MByte -> "u1"
    case MNativeInt -> "nint"
    case MArray(elem) -> "arr_" + msilTypeKeyStr(elem)
    case MClass(name) -> "cls_" + name
    case MClassRef(_, fqn) -> "clsref_" + fqn
    case MValueTypeRef(_, fqn) -> "vt_" + fqn
    case MTypeVar(idx) -> "tv" + toString(idx)
    case MByRef(inner) -> "byref_" + msilTypeKeyStr(inner)
    case MListOf(elem) -> "list_" + msilTypeKeyStr(elem)
    case MMapOf(k, v) -> "map_" + msilTypeKeyStr(k) + "_" + msilTypeKeyStr(v)
    case MConcreteList(elem) -> "clist_" + msilTypeKeyStr(elem)
    case MConcreteMap(k, v) -> "cmap_" + msilTypeKeyStr(k) + "_" + msilTypeKeyStr(v)
    case MIAsyncEnumerable(e) -> "iasyncen_" + msilTypeKeyStr(e)
    case MGenericInst(_, fqn, args) -> {
      var k = "gi_" + fqn
      var ai = 0
      while ai < args.count {
        k = k + "_" + msilTypeKeyStr(args[ai])
        ai = ai + 1
      }
      k
    }
    case MGenericInstByName(fqn, args) -> {
      var k = "gibn_" + fqn
      var ai = 0
      while ai < args.count {
        k = k + "_" + msilTypeKeyStr(args[ai])
        ai = ai + 1
      }
      k
    }
    case MValueTypeGenericInst(_, fqn, args) -> {
      var k = "vgi_" + fqn
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
  cctx: in CodegenCtx, params: in List[MsilType], ret: in MsilType, hasThis: in Bool
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

// Parse the `\`N` generic-arity suffix of a simple type name (e.g.
// `ConcurrentDictionary`2` -> 2).  Returns 0 when there is no suffix.
func decimalDigitValue(c: in Char): Int {
  if c == '0' {
    0
  } else if c == '1' {
    1
  } else if c == '2' {
    2
  } else if c == '3' {
    3
  } else if c == '4' {
    4
  } else if c == '5' {
    5
  } else if c == '6' {
    6
  } else if c == '7' {
    7
  } else if c == '8' {
    8
  } else if c == '9' {
    9
  } else {
    0 - 1
  }
}

func genericArityOfName(simpleName: in String): Int {
  val bt = simpleName.lastIndexOf("`")
  if bt < 0 {
    return 0
  }
  var n = 0
  var i = bt + 1
  while i < simpleName.length {
    val d = decimalDigitValue(simpleName[i])
    if d >= 0 {
      n = n * 10 + d
    }
    i = i + 1
  }
  n
}

// Emit the body of a generic `@externTarget` member whose *declaring type* is a
// generic BCL type (`ConcurrentDictionary`2`, …).  A member of a generic type
// cannot be referenced through an open-generic TypeRef with a concrete-typed
// signature (ECMA-335 §II.22.25 / §II.23.2): it needs a closed GENERICINST
// TypeSpec parent and a `!0`/`!1`-encoded member signature.
//
// The type arguments are erased to `<object,…>`, matching how
// `typeExprToMsilCtx` already erases the Lyric extern wrapper type
// (`ConcurrentDict[K, V]`) to `MObject` — so the receiver value, the field that
// stores it, and every call site are all `object`-shaped, and the runtime
// instance produced by the `..ctor` extern is `T<object,…>`.  VAR positions are
// read from reference-assembly metadata (so they are exact, not guessed); a
// value-type by-value argument is boxed, and an `out`/`inout` argument whose
// Lyric pointee is concrete is marshalled through an `object` temp because the
// BCL position is `!1&` (= `object&`) after erasure.
//
// Does not append `MRet` (the caller does).  Returns false — having emitted
// nothing — when the metadata signature can't be resolved or carries a shape
// this path can't encode, so the caller falls back to the legacy path.
func emitGenericExternMember(
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  decl: in FunctionDecl,
  r: in FfiResolved,
  resolvedFqn: in String,
  paramTypes: in List[MsilType],
): Bool {
  val arity = genericArityOfName(r.typeName)
  if arity <= 0 {
    return false
  }
  // Resolve the BCL member's true signature (hasThis + exact VAR positions).
  // Build `sigOpt` via a typed `var` + assignment rather than a `match`
  // expression: the bootstrap F# emitter unifies a `match`'s `None` arm with the
  // `Some(...)` arm to `Option<object>`, after which `sig.paramTypes` below
  // would be an `Object` field read it cannot resolve.
  val asmName = assemblyForTypeMsil(cctx, resolvedFqn)
  var sigOpt: Option[Mdr.DecodedMethodSig] = None
  match mapGet(cctx.metadataPathIndex, asmName) {
    case None -> {
    }
    case Some(path) -> {
      sigOpt = Mdr.decodeExternMethodSig(path, resolvedFqn, r.memberName, decl.params.count)
    }
  }
  match sigOpt {
    case None -> false
    case Some(sig) -> {
      // Convert the BCL param/return SigTypes to MsilType, preserving VARs.
      val memberParams: List[MsilType] = newList()
      var convOk = true
      var ci = 0
      while ci < sig.paramTypes.count {
        match genericMemberSigToMsil(cctx, sig.paramTypes[ci]) {
          case Some(m) -> memberParams.add(m)
          case None -> {
            convOk = false
          }
        }
        ci = ci + 1
      }
      val memberRet = match genericMemberSigToMsil(cctx, sig.returnType) {
        case Some(m) -> m
        case None -> {
          convOk = false
          MVoid
        }
      }
      val isInstance = sig.hasThis and not r.isCtor
      // Arg-count sanity: BCL params + (instance receiver) must equal the
      // Lyric wrapper's declared parameter count, or our positional mapping
      // would be wrong.
      val expectedDeclParams = if isInstance { memberParams.count + 1 } else { memberParams.count }
      if not convOk or expectedDeclParams != decl.params.count {
        return false
      }

      // Closed GENERICINST TypeSpec `T<object,…>`.
      val ns = r.namespaceStr
      val typeRefRow = internFfiTypeRef(cctx, asmName, ns, r.typeName)
      val objArgs: List[MsilType] = newList()
      var ai = 0
      while ai < arity {
        objArgs.add(MObject)
        ai = ai + 1
      }
      val tsKey = "ts_genextern_" + resolvedFqn
      val tsBlob = buildGenericInstBlobWithCtx(cctx.lctx, tdrTypeRef(typeRefRow), objArgs)
      val tsRow = ctxAddTypeSpec(cctx.lctx, tsKey, tsBlob)
      val tsTok = 0x1B000000 + tsRow

      // MemberRef on the TypeSpec.  Constructors and instance methods are
      // HASTHIS; the (unused-here) static case uses the default convention.
      val memberSig = if isInstance or r.isCtor {
        buildInstanceMethodSig(memberParams, if r.isCtor { MVoid } else { memberRet })
      } else {
        buildStaticMethodSigWithCtx(memberParams, memberRet, cctx.lctx)
      }
      // The MemberRef intern key must encode the full signature, not just the
      // member name: two overloads of the same name on the same generic type
      // (e.g. distinct-arity `TryGetValue`s, or a `.ctor()` vs `.ctor(int,int)`)
      // would otherwise alias to the first-registered MemberRef (#3429).
      var mrKey = "mr_genextern_" + resolvedFqn + "." + r.memberName + "/" + toString(memberParams.count)
      var mki = 0
      while mki < memberParams.count {
        mrKey = mrKey + "_" + msilTypeKeyStr(memberParams[mki])
        mki = mki + 1
      }
      mrKey = mrKey + "_ret_" + msilTypeKeyStr(if r.isCtor { MVoid } else { memberRet })
      val mrRow = ctxAddMemberRefForTypeSpec(cctx.lctx, tsRow, r.memberName, mrKey, memberSig)
      val mrTok = 0x0A000000 + mrRow

      // Pre-allocate marshalling temps for concrete `out`/`inout` pointee types
      // (the BCL position is `!1&` = `object&`, the Lyric param is `RateEntry&`).
      // Parallel lists: byref BCL param index j -> (objTempLocal, lyricParamIdx,
      // pointeeMsil).
      val marshalBclIdx: List[Int] = newList()
      val marshalTmp: List[Int] = newList()
      val marshalPointee: List[MsilType] = newList()
      var pj = 0
      while pj < memberParams.count {
        val lyIdx = if isInstance { pj + 1 } else { pj }
        match memberParams[pj] {
          case MByRef(_) -> {
            val lyInner = match paramTypes[lyIdx] { case MByRef(inner) -> inner; case other -> other }
            match lyInner {
              case MObject -> {
              }
              case _ -> {
                val tmpIdx = fctx.locals.count
                fctx.locals.add(MObject)
                marshalBclIdx.add(pj)
                marshalTmp.add(tmpIdx)
                marshalPointee.add(lyInner)
              }
            }
          }
          case _ -> {
          }
        }
        pj = pj + 1
      }

      // ── Emit ──────────────────────────────────────────────────────────────
      // Push the receiver (instance calls) then every argument BEFORE the call
      // or `newobj`.  Emitting `newobj` ahead of the argument-push loop would
      // fire it against an empty stack for a ctor wrapper that takes arguments
      // (#3419); only the zero-argument ctor happened to be correct.
      if isInstance {
        insns.add(MLdarg(slot = 0))
        insns.add(MCastclass(typeToken = tsTok))
      }
      var ej = 0
      while ej < memberParams.count {
        val lyIdx = if isInstance { ej + 1 } else { ej }
        val mTy = memberParams[ej]
        match mTy {
          case MByRef(_) -> {
            val mi = listIndexOfInt(marshalBclIdx, ej)
            if mi >= 0 {
              insns.add(MLdloca(slot = marshalTmp[mi]))
            } else {
              // pointee already `object` (erased generic copy): pass directly.
              insns.add(MLdarg(slot = lyIdx))
            }
          }
          case _ -> {
            insns.add(MLdarg(slot = lyIdx))
            // Box a value-type argument when the BCL position is a type
            // parameter (erased to `object`).
            val isVarPos = match mTy { case MTypeVar(_) -> true; case MObject -> true; case _ -> false }
            if isVarPos and isValueType(paramTypes[lyIdx]) {
              boxIfNeededMsil(cctx, insns, paramTypes[lyIdx])
            }
          }
        }
        ej = ej + 1
      }
      if r.isCtor {
        insns.add(MNewobj(ctorToken = mrTok))
      } else if isInstance {
        insns.add(MCallvirt(methodToken = mrTok))
      } else {
        insns.add(MCall(methodToken = mrTok))
      }

      // Marshal `out` temps back into the Lyric byref locations.  A ctor never
      // has `out` parameters, so `marshalBclIdx` is empty and this is a no-op.
      if marshalBclIdx.count > 0 {
        val retIsVoid = match memberRet { case MVoid -> true; case _ -> false }
        val resIdx = if retIsVoid {
          0 - 1
        } else {
          val ri = fctx.locals.count
          fctx.locals.add(memberRet)
          insns.add(MStloc(slot = ri))
          ri
        }
        var mk = 0
        while mk < marshalBclIdx.count {
          val lyIdx = if isInstance { marshalBclIdx[mk] + 1 } else { marshalBclIdx[mk] }
          insns.add(MLdarg(slot = lyIdx))         // the byref pointer
          insns.add(MLdloc(slot = marshalTmp[mk]))  // the object the BCL wrote
          val pointee = marshalPointee[mk]
          if isValueType(pointee) {
            insns.add(MUnboxAny(typeToken = 0x01000000 + boxTypeRef(cctx, pointee)))
          } else {
            match pointee {
              case MClass(cn) -> insns.add(MCastclassByName(className = cn))
              case _ -> ()
            }
          }
          insns.add(MStind(ty = pointee))
          mk = mk + 1
        }
        if resIdx >= 0 {
          insns.add(MLdloc(slot = resIdx))
        }
      }
      true
    }
  }
}

// Index of the first occurrence of `v` in `xs`, or -1.
func listIndexOfInt(xs: in List[Int], v: in Int): Int {
  var i = 0
  while i < xs.count {
    if xs[i] == v {
      return i
    }
    i = i + 1
  }
  0 - 1
}

func emitExternTargetBody(
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  decl: in FunctionDecl,
  pkgName: in String,
): Bool {
  val target = externTargetStringMsil(decl.annotations)
  if target == "" {
    return false
  }

  // F0002 (also emitted by the type checker for proof/lint paths,
  // but Msil.Bridge skips type checking — panic here so the user
  // build sees the diagnostic).
  if hasConflictingHints(decl.annotations) {
    panic(
      "Msil.Codegen: function '" + decl.name + "' has both " + "@externStatic and @externInstance — pick one (the FFI " +
        "resolver cannot honour both)."
    )
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
      val msg = "FFI extern '" + target + "' on '" + decl.name + "' could not be resolved to a method on any loaded " +
        "reference assembly; check the @externTarget annotation."
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
      val retTy = match decl.ret { case Some(te) -> typeExprToMsilCtx(cctx, te, pkgName); case None -> MVoid }

      // Phase 4: prefer the metadata type index over the prefix-based guard so
      // types from NuGet-restored assemblies (not `System.*` / `Lyric.*`) are
      // accepted when their DLL is in the index (added by ensureMetadataIndex).
      val resolvedFqn = if r.namespaceStr == "" { r.typeName } else { r.namespaceStr + "." + r.typeName }
      ensureMetadataIndex(cctx)
      val isKnownFqn = match Mdr.assemblyForType(cctx.metadataTypeIndex, resolvedFqn) {
        case Some(_) -> true
        case None -> clrAssemblyResolvable(resolvedFqn)
      }
      // Generic declaring type (e.g. `ConcurrentDictionary`2`): a member of a
      // generic type cannot be referenced through a plain open-generic TypeRef
      // with a concrete-typed signature — ECMA-335 §II.22.25 requires a closed
      // GENERICINST TypeSpec parent and a `!0`/`!1`-encoded member signature.
      // Route these through the dedicated emitter, which erases the type
      // arguments to `<object,…>` (matching how `typeExprToMsilCtx` already
      // erases the Lyric `ConcurrentDict[K,V]` value to `MObject`) and marshals
      // `out`/value-type arguments across the erasure boundary (#3392).
      if isKnownFqn and contains(r.typeName, "`") {
        if emitGenericExternMember(cctx, fctx, insns, decl, r, resolvedFqn, paramTypes) {
          insns.add(MRet)
          return true
        }
      }
      if not isKnownFqn {
        panic(
          "Msil.Codegen: FFI extern '" + target + "' on '" + decl.name + "' references type '" + resolvedFqn +
            "', which cannot be resolved to any indexed reference assembly or Lyric host " +
            "assembly; check the @externTarget annotation for a typo or an unsupported type."
        )
      }

      val asmName = assemblyForTypeMsil(cctx, resolvedFqn)
      val tRefRow = internFfiTypeRef(cctx, asmName, r.namespaceStr, r.typeName)

      // Phase 4 (F0015): verify the declared @externTarget signature against
      // reference-assembly metadata so a mis-transcribed Lyric signature is
      // caught at build time rather than surfacing as a MissingMethodException.
      // Skipped when: (a) any declared param is MByRef (out/inout, complex to
      // resolve via overload scoring), (b) any param type maps to None in
      // argTyToSig (generic or unsupported shapes), (c) the type is absent
      // from the metadata index (Lyric host types in Lyric.Emitter.dll), or
      // (d) the caller did not supply @externStatic — without an explicit
      // static annotation the codegen defaults to static but the BCL method
      // may be instance, producing a false positive; verification is only
      // reliable when the caller's intent is unambiguous.
      val isExplicitStatic = match hint { case RHStaticOnly -> true; case _ -> false }
      if not r.isCtor and isExplicitStatic {
        val verifyStart = if r.isStatic { 0 } else { 1 }
        val verifySigs: List[Mdr.SigType] = newList()
        var vpi = verifyStart
        var canVerify = true
        while vpi < paramTypes.count and canVerify {
          val pTy = paramTypes[vpi]
          val isByRef = match pTy { case MByRef(_) -> true; case _ -> false }
          if isByRef {
            canVerify = false
          } else {
            match argTyToSig(pTy) {
              case None -> {
                canVerify = false
              }
              case Some(s) -> verifySigs.add(s)
            }
          }
          vpi = vpi + 1
        }
        if canVerify {
          match Mdr.assemblyForType(cctx.metadataTypeIndex, resolvedFqn) {
            case None -> {
            }
            case Some(_) -> {
              match Mdr.resolveExtern(cctx.metadataTypeIndex, cctx.metadataPathIndex, resolvedFqn, r.memberName, verifySigs) {
                case Some(_) -> {
                }
                case None -> {
                  var declSigStr = "("
                  var dsi = 0
                  while dsi < verifySigs.count {
                    if dsi > 0 {
                      declSigStr = declSigStr + ", "
                    }
                    declSigStr = declSigStr + msilTypeKeyStr(paramTypes[verifyStart + dsi])
                    dsi = dsi + 1
                  }
                  declSigStr = declSigStr + ") -> " + msilTypeKeyStr(retTy)
                  panic(
                    "F0015: @externTarget '" + target + "' on '" + decl.name + "': " + "declared signature " + declSigStr +
                      " does not match any overload of '" +
                      resolvedFqn +
                      "." +
                      r.memberName +
                      "' in reference-assembly metadata. " +
                      "Verify the Lyric parameter/return types match the BCL method."
                  )
                }
              }
            }
          }
        }
      }

      // Build the method signature blob, encoding class-typed params/return
      // against their resolved TypeRefs.
      //
      // For async externs the BCL method returns Task (void) or Task<T> (non-void T).
      // Encode the actual BCL return type in the MemberRef so the CLR can resolve the
      // method at JIT time.  retTy (the Lyric-declared T) is used only for the unwrap
      // callvirt appended below.  Ctors are never async in the BCL; skip them.
      val bclRetTy = if decl.isAsync and not r.isCtor {
        val isVoidRet = match retTy { case MVoid -> true; case _ -> false }
        if isVoidRet {
          MClassRef(typeRefCode = tdrTypeRef(cctx.trTask), clrFqn = "System.Threading.Tasks.Task")
        } else {
          val taskArgs: List[MsilType] = newList()
          taskArgs.add(retTy)
          MGenericInst(typeRefCode = tdrTypeRef(cctx.trTask1), headFqn = "System.Threading.Tasks.Task", typeArgs = taskArgs)
        }
      } else {
        retTy
      }
      val sig = if r.isStatic and not r.isCtor {
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
      val mrRow = ctxAddMemberRef(cctx.lctx, tRefRow, r.memberName, "ffi_" + target, sig)
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
        val isVoidRet = match retTy { case MVoid -> true; case _ -> false }
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
          val mrRow = ctxAddMemberRefForTypeSpec(cctx.lctx, tsRow, "get_Result", "mr_task_getresult_" + tsKey, mrSig)
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
    case EYield(_) -> true
    case EBlock(b) -> blockContainsYieldMsil(b)
    case EUnsafe(b) -> blockContainsYieldMsil(b)
    case EIf(c, t, el, _) -> {
      if exprContainsYieldMsil(c) {
        return true
      }
      val tRes = match t {
        case EOBExpr(ex) -> exprContainsYieldMsil(ex)
        case EOBBlock(blk) -> blockContainsYieldMsil(blk)
      }
      if tRes {
        return true
      }
      match el {
        case Some(elB) -> match elB { case EOBExpr(ex) -> exprContainsYieldMsil(ex); case EOBBlock(blk) -> blockContainsYieldMsil(blk) }
        case None -> false
      }
    }
    case ECall(fn, args) -> {
      if exprContainsYieldMsil(fn) {
        return true
      }
      var ai = 0
      while ai < args.count {
        val res = match args[ai] {
          case CAPositional(ex) -> exprContainsYieldMsil(ex)
          case CANamed(_, ex, _) -> exprContainsYieldMsil(ex)
        }
        if res {
          return true
        }
        ai = ai + 1
      }
      false
    }
    case EBinop(_, l, r) -> exprContainsYieldMsil(l) or exprContainsYieldMsil(r)
    case EPrefix(_, op) -> exprContainsYieldMsil(op)
    case EParen(inner) -> exprContainsYieldMsil(inner)
    case EMember(recv, _) -> exprContainsYieldMsil(recv)
    case EAwait(inner) -> exprContainsYieldMsil(inner)
    case ESpawn(inner) -> exprContainsYieldMsil(inner)
    case ETry(inner) -> exprContainsYieldMsil(inner)
    case EPropagate(inner) -> exprContainsYieldMsil(inner)
    case EMatch(scr, arms) -> {
      if exprContainsYieldMsil(scr) {
        return true
      }
      var ai = 0
      while ai < arms.count {
        val res = match arms[ai].body {
          case EOBExpr(ex) -> exprContainsYieldMsil(ex)
          case EOBBlock(blk) -> blockContainsYieldMsil(blk)
        }
        if res {
          return true
        }
        ai = ai + 1
      }
      false
    }
    case _ -> false
  }
}

func stmtContainsYieldMsil(s: in Statement): Bool {
  match s.kind {
    case SExpr(e) -> exprContainsYieldMsil(e)
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init) -> exprContainsYieldMsil(init)
        case LBLet(_, _, init) -> exprContainsYieldMsil(init)
        case LBVar(_, _, initOpt) -> match initOpt { case Some(init) -> exprContainsYieldMsil(init); case None -> false }
      }
    }
    case SReturn(valOpt) -> match valOpt { case Some(e) -> exprContainsYieldMsil(e); case None -> false }
    case SAssign(_, _, v) -> exprContainsYieldMsil(v)
    case SThrow(e) -> exprContainsYieldMsil(e)
    case SWhile(_, c, b) -> exprContainsYieldMsil(c) or blockContainsYieldMsil(b)
    case SFor(_, _, i, b) -> exprContainsYieldMsil(i) or blockContainsYieldMsil(b)
    case SLoop(_, b) -> blockContainsYieldMsil(b)
    case SScope(_, b) -> blockContainsYieldMsil(b)
    case SDefer(b) -> blockContainsYieldMsil(b)
    case STry(b, catches, finally_) -> {
      if blockContainsYieldMsil(b) {
        return true
      }
      var ci = 0
      while ci < catches.count {
        if blockContainsYieldMsil(catches[ci].body) {
          return true
        }
        ci = ci + 1
      }
      match finally_ {
        case None -> false
        case Some(fb) -> blockContainsYieldMsil(fb)
      }
    }
    case _ -> false
  }
}

func blockContainsYieldMsil(block: in Block): Bool {
  var i = 0
  while i < block.statements.count {
    if stmtContainsYieldMsil(block.statements[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func funcBodyContainsYieldMsil(decl: in FunctionDecl): Bool {
  match decl.body {
    case Some(body) -> match body { case FBBlock(blk) -> blockContainsYieldMsil(blk); case FBExpr(e) -> exprContainsYieldMsil(e) }
    case None -> false
  }
}

// Count all EYield nodes in an expression / statement / block.
// Used by synthesizeGeneratorMsil to pre-allocate the correct number of
// resume labels before lowering the generator body.
func countYieldsInExpr(e: in Expr): Int {
  match e.kind {
    case EYield(_) -> 1
    case EBlock(b) -> countYieldsInBlock(b)
    case EUnsafe(b) -> countYieldsInBlock(b)
    case EIf(c, t, el, _) -> {
      var n = countYieldsInExpr(c)
      n = n + match t { case EOBExpr(ex) -> countYieldsInExpr(ex); case EOBBlock(blk) -> countYieldsInBlock(blk) }
      n = n +
        match el {
          case Some(elB) -> match elB { case EOBExpr(ex) -> countYieldsInExpr(ex); case EOBBlock(blk) -> countYieldsInBlock(blk) }
          case None -> 0
        }
      n
    }
    case ECall(fn, args) -> {
      var n = countYieldsInExpr(fn)
      var ai = 0
      while ai < args.count {
        n = n +
          match args[ai] {
            case CAPositional(ex) -> countYieldsInExpr(ex)
            case CANamed(_, ex, _) -> countYieldsInExpr(ex)
          }
        ai = ai + 1
      }
      n
    }
    case EBinop(_, l, r) -> countYieldsInExpr(l) + countYieldsInExpr(r)
    case EPrefix(_, op) -> countYieldsInExpr(op)
    case EParen(inner) -> countYieldsInExpr(inner)
    case EMember(recv, _) -> countYieldsInExpr(recv)
    case EAwait(inner) -> countYieldsInExpr(inner)
    case ESpawn(inner) -> countYieldsInExpr(inner)
    case ETry(inner) -> countYieldsInExpr(inner)
    case EPropagate(inner) -> countYieldsInExpr(inner)
    case EMatch(scr, arms) -> {
      var n = countYieldsInExpr(scr)
      var ai = 0
      while ai < arms.count {
        n = n +
          match arms[ai].body { case EOBExpr(ex) -> countYieldsInExpr(ex); case EOBBlock(blk) -> countYieldsInBlock(blk) }
        ai = ai + 1
      }
      n
    }
    case ETuple(elems) -> {
      var n = 0
      var ti = 0
      while ti < elems.count {
        n = n + countYieldsInExpr(elems[ti])
        ti = ti + 1
      }
      n
    }
    case EList(elems) -> {
      var n = 0
      var li = 0
      while li < elems.count {
        n = n + countYieldsInExpr(elems[li])
        li = li + 1
      }
      n
    }
    case EAssign(lhs, _, rhs) -> countYieldsInExpr(lhs) + countYieldsInExpr(rhs)
    case EIndex(recv, indices) -> {
      var n = countYieldsInExpr(recv)
      var idi = 0
      while idi < indices.count {
        n = n + countYieldsInExpr(indices[idi])
        idi = idi + 1
      }
      n
    }
    case EInterpolated(segs) -> {
      var n = 0
      var ipi = 0
      while ipi < segs.count {
        match segs[ipi] {
          case ISExpr(ex) -> {
            n = n + countYieldsInExpr(ex)
          }
          case ISText(_, _) -> ()
        }
        ipi = ipi + 1
      }
      n
    }
    // ELambda: yields inside a nested lambda are NOT counted here — a lambda
    // is an independent generator scope; its yields drive its own resumeLabels,
    // not the outer generator's.
    case ELambda(_, _) -> 0
    case ETypeApp(inner, _) -> countYieldsInExpr(inner)
    case ERange(bound) -> {
      match bound {
        case RBClosed(lo, hi) -> countYieldsInExpr(lo) + countYieldsInExpr(hi)
        case RBHalfOpen(lo, hi) -> countYieldsInExpr(lo) + countYieldsInExpr(hi)
        case RBLowerOpen(hi) -> countYieldsInExpr(hi)
        case RBUpperOpen(lo) -> countYieldsInExpr(lo)
      }
    }
    case _ -> 0
  }
}

func countYieldsInStmt(s: in Statement): Int {
  match s.kind {
    case SExpr(e) -> countYieldsInExpr(e)
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init) -> countYieldsInExpr(init)
        case LBLet(_, _, init) -> countYieldsInExpr(init)
        case LBVar(_, _, initOpt) -> match initOpt { case Some(init) -> countYieldsInExpr(init); case None -> 0 }
      }
    }
    case SReturn(valOpt) -> match valOpt { case Some(e) -> countYieldsInExpr(e); case None -> 0 }
    case SAssign(_, _, v) -> countYieldsInExpr(v)
    case SThrow(e) -> countYieldsInExpr(e)
    case SWhile(_, c, b) -> countYieldsInExpr(c) + countYieldsInBlock(b)
    case SFor(_, _, i, b) -> countYieldsInExpr(i) + countYieldsInBlock(b)
    case SLoop(_, b) -> countYieldsInBlock(b)
    case SScope(_, b) -> countYieldsInBlock(b)
    case SDefer(b) -> countYieldsInBlock(b)
    case STry(b, catches, finally_) -> {
      var n = countYieldsInBlock(b)
      var ci = 0
      while ci < catches.count {
        n = n + countYieldsInBlock(catches[ci].body)
        ci = ci + 1
      }
      n = n + match finally_ { case None -> 0; case Some(fb) -> countYieldsInBlock(fb) }
      n
    }
    case _ -> 0
  }
}

func countYieldsInBlock(block: in Block): Int {
  var n = 0
  var i = 0
  while i < block.statements.count {
    n = n + countYieldsInStmt(block.statements[i])
    i = i + 1
  }
  n
}

func countYieldsInFuncBody(decl: in FunctionDecl): Int {
  match decl.body {
    case Some(body) -> match body { case FBBlock(blk) -> countYieldsInBlock(blk); case FBExpr(e) -> countYieldsInExpr(e) }
    case None -> 0
  }
}

func exprContainsAwaitMsil(e: in Expr): Bool {
  match e.kind {
    case EAwait(_) -> true
    case EBlock(b) -> blockContainsAwaitMsil(b)
    case EUnsafe(b) -> blockContainsAwaitMsil(b)
    case EIf(c, t, el, _) -> {
      if exprContainsAwaitMsil(c) {
        return true
      }
      val tRes = match t {
        case EOBExpr(ex) -> exprContainsAwaitMsil(ex)
        case EOBBlock(blk) -> blockContainsAwaitMsil(blk)
      }
      if tRes {
        return true
      }
      match el {
        case Some(elB) -> match elB { case EOBExpr(ex) -> exprContainsAwaitMsil(ex); case EOBBlock(blk) -> blockContainsAwaitMsil(blk) }
        case None -> false
      }
    }
    case ECall(fn, args) -> {
      if exprContainsAwaitMsil(fn) {
        return true
      }
      var ai = 0
      while ai < args.count {
        val res = match args[ai] {
          case CAPositional(ex) -> exprContainsAwaitMsil(ex)
          case CANamed(_, ex, _) -> exprContainsAwaitMsil(ex)
        }
        if res {
          return true
        }
        ai = ai + 1
      }
      false
    }
    case EBinop(_, l, r) -> exprContainsAwaitMsil(l) or exprContainsAwaitMsil(r)
    case EPrefix(_, op) -> exprContainsAwaitMsil(op)
    case EParen(inner) -> exprContainsAwaitMsil(inner)
    case EMember(recv, _) -> exprContainsAwaitMsil(recv)
    case ESpawn(inner) -> exprContainsAwaitMsil(inner)
    case ETry(inner) -> exprContainsAwaitMsil(inner)
    case EPropagate(inner) -> exprContainsAwaitMsil(inner)
    case EMatch(scr, arms) -> {
      if exprContainsAwaitMsil(scr) {
        return true
      }
      var ai = 0
      while ai < arms.count {
        val res = match arms[ai].body {
          case EOBExpr(ex) -> exprContainsAwaitMsil(ex)
          case EOBBlock(blk) -> blockContainsAwaitMsil(blk)
        }
        if res {
          return true
        }
        ai = ai + 1
      }
      false
    }
    case _ -> false
  }
}

func stmtContainsAwaitMsil(s: in Statement): Bool {
  match s.kind {
    case SExpr(e) -> exprContainsAwaitMsil(e)
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init) -> exprContainsAwaitMsil(init)
        case LBLet(_, _, init) -> exprContainsAwaitMsil(init)
        case LBVar(_, _, initOpt) -> match initOpt { case Some(init) -> exprContainsAwaitMsil(init); case None -> false }
      }
    }
    case SReturn(valOpt) -> match valOpt { case Some(e) -> exprContainsAwaitMsil(e); case None -> false }
    case SAssign(_, _, v) -> exprContainsAwaitMsil(v)
    case SThrow(e) -> exprContainsAwaitMsil(e)
    case SWhile(_, c, b) -> exprContainsAwaitMsil(c) or blockContainsAwaitMsil(b)
    case SFor(_, _, i, b) -> exprContainsAwaitMsil(i) or blockContainsAwaitMsil(b)
    case SLoop(_, b) -> blockContainsAwaitMsil(b)
    case SScope(_, b) -> blockContainsAwaitMsil(b)
    case SDefer(b) -> blockContainsAwaitMsil(b)
    case STry(b, catches, finally_) -> {
      if blockContainsAwaitMsil(b) {
        return true
      }
      var ci = 0
      while ci < catches.count {
        if blockContainsAwaitMsil(catches[ci].body) {
          return true
        }
        ci = ci + 1
      }
      match finally_ {
        case None -> false
        case Some(fb) -> blockContainsAwaitMsil(fb)
      }
    }
    case _ -> false
  }
}

func blockContainsAwaitMsil(block: in Block): Bool {
  var i = 0
  while i < block.statements.count {
    if stmtContainsAwaitMsil(block.statements[i]) {
      return true
    }
    i = i + 1
  }
  false
}

func funcBodyContainsAwaitMsil(decl: in FunctionDecl): Bool {
  match decl.body {
    case Some(body) -> match body { case FBBlock(blk) -> blockContainsAwaitMsil(blk); case FBExpr(e) -> exprContainsAwaitMsil(e) }
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
    case _ -> MVoid
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
          headFqn = "System.Runtime.CompilerServices.TaskAwaiter`1",
          typeArgs = tArgs
        )
      } else {
        MValueTypeRef(typeRefCode = tdrTypeRef(cctx.trTaskAwaiter), clrFqn = "System.Runtime.CompilerServices.TaskAwaiter")
      }
    }
    case _ -> MValueTypeRef(typeRefCode = tdrTypeRef(cctx.trTaskAwaiter), clrFqn = "System.Runtime.CompilerServices.TaskAwaiter")
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
    case MClassRef(trCode, _) -> trCode == tdrTypeRef(cctx.trTask)
    case _ -> false
  }
}

// Emit the GetAwaiter() call on the value currently on the stack (Task<T> or Task).
// Leaves the awaiter (value type) on the stack.
func emitGetAwaiterCallPB(cctx: in CodegenCtx, insns: in List[MInsn], taskTy: in MsilType): Unit {
  val lctx = cctx.lctx
  val resT = taskResultType(taskTy)
  val tyKey = msilTypeKey(resT)
  if resT == MVoid {
    // Task.GetAwaiter() → TaskAwaiter  (non-generic)
    val awRetTy = MValueTypeRef(
      typeRefCode = tdrTypeRef(cctx.trTaskAwaiter),
      clrFqn = "System.Runtime.CompilerServices.TaskAwaiter"
    )
    val gaArgs: List[MsilType] = newList()
    val gaSig = buildInstanceMethodSig(gaArgs, awRetTy)
    val gaMrRow = ctxAddMemberRef(lctx, cctx.trTask, "GetAwaiter", "task_getawaiter_void", gaSig)
    insns.add(MCall(methodToken = 0x0A000000 + gaMrRow))
  } else {
    // Task<T>.GetAwaiter() → TaskAwaiter<T>  (generic, TypeSpec parent)
    val tsArgs: List[MsilType] = newList()
    tsArgs.add(resT)
    val tsBlob = buildGenericInstBlobWithCtx(lctx, tdrTypeRef(cctx.trTask1), tsArgs)
    val tsRow = ctxAddTypeSpec(lctx, "task1_ts_" + tyKey, tsBlob)
    // Return sig uses VAR 0 (class type param of Task`1)
    val awVarArgs: List[MsilType] = newList()
    awVarArgs.add(MTypeVar(index = 0))
    val awRetTy1 = MValueTypeGenericInst(
      typeRefCode = tdrTypeRef(cctx.trTaskAwaiter1),
      headFqn = "System.Runtime.CompilerServices.TaskAwaiter`1",
      typeArgs = awVarArgs
    )
    val gaArgs1: List[MsilType] = newList()
    val gaSig1 = buildInstanceMethodSig(gaArgs1, awRetTy1)
    val gaMrRow1 = ctxAddMemberRefForTypeSpec(lctx, tsRow, "GetAwaiter", "task1_getawaiter_" + tyKey, gaSig1)
    insns.add(MCall(methodToken = 0x0A000000 + gaMrRow1))
  }
}

// Emit get_IsCompleted on the awaiter at the address currently on the stack.
// Leaves a bool on the stack.
func emitGetIsCompletedCallPB(cctx: in CodegenCtx, insns: in List[MInsn], awTy: in MsilType): Unit {
  val lctx = cctx.lctx
  val icArgs: List[MsilType] = newList()
  val icSig = buildInstanceMethodSig(icArgs, MBool)
  match awTy {
    case MValueTypeRef(_, _) -> {
      // TaskAwaiter (non-generic)
      val icMrRow = ctxAddMemberRef(lctx, cctx.trTaskAwaiter, "get_IsCompleted", "taskaw_iscomp_void", icSig)
      insns.add(MCall(methodToken = 0x0A000000 + icMrRow))
    }
    case MValueTypeGenericInst(_, _, tArgs) -> {
      // TaskAwaiter<T> — TypeSpec parent
      val awKey = msilTypeKey(if tArgs.count > 0 { tArgs[0] } else { MVoid })
      val awTsArgs: List[MsilType] = newList()
      if tArgs.count > 0 {
        awTsArgs.add(tArgs[0])
      }
      val awTsBlob = buildValueTypeGenericInstBlobWithCtx(lctx, tdrTypeRef(cctx.trTaskAwaiter1), awTsArgs)
      val awTsRow = ctxAddTypeSpec(lctx, "taskaw1_ts_" + awKey, awTsBlob)
      val icMrRow1 = ctxAddMemberRefForTypeSpec(lctx, awTsRow, "get_IsCompleted", "taskaw1_iscomp_" + awKey, icSig)
      insns.add(MCall(methodToken = 0x0A000000 + icMrRow1))
    }
    case _ -> {
    }
  }
}

// Emit GetResult on the awaiter at the address on the stack.
// Leaves T on the stack (or nothing for void).  Returns the result MsilType.
func emitGetResultCallPB(cctx: in CodegenCtx, insns: in List[MInsn], awTy: in MsilType): MsilType {
  val lctx = cctx.lctx
  match awTy {
    case MValueTypeRef(_, _) -> {
      // TaskAwaiter.GetResult() → void
      val grArgs: List[MsilType] = newList()
      val grSig = buildInstanceMethodSig(grArgs, MVoid)
      val grMrRow = ctxAddMemberRef(lctx, cctx.trTaskAwaiter, "GetResult", "taskaw_getresult_void", grSig)
      insns.add(MCall(methodToken = 0x0A000000 + grMrRow))
      MVoid
    }
    case MValueTypeGenericInst(_, _, tArgs) -> {
      // TaskAwaiter<T>.GetResult() → VAR 0  (TypeSpec parent)
      val resT = if tArgs.count > 0 { tArgs[0] } else { MVoid }
      val awKey = msilTypeKey(resT)
      val awTsArgs: List[MsilType] = newList()
      awTsArgs.add(resT)
      val awTsBlob = buildValueTypeGenericInstBlobWithCtx(lctx, tdrTypeRef(cctx.trTaskAwaiter1), awTsArgs)
      val awTsRow = ctxAddTypeSpec(lctx, "taskaw1_ts_" + awKey, awTsBlob)
      val grArgs1: List[MsilType] = newList()
      val grSig1 = buildInstanceMethodSig(grArgs1, MTypeVar(index = 0))
      val grMrRow1 = ctxAddMemberRefForTypeSpec(lctx, awTsRow, "GetResult", "taskaw1_getresult_" + awKey, grSig1)
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
func emitBlockingAwait(cctx: in CodegenCtx, fctx: in FuncCtx, insns: in List[MInsn], taskTy: in MsilType): MsilType {
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
func inferCallReturnTypePB(
  cctx: in CodegenCtx,
  pkgName: in String,
  e: in Expr,
  spawnNms: in List[String],
  spawnTys: in List[MsilType],
): MsilType {
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
            // First-definition-wins: stop at the earliest binding so that when a
            // name is rebound with a different type the awaiter pre-scan produces
            // the same type the first `await` site will encounter at runtime.
            si = spawnNms.count
          } else {
            si = si + 1
          }
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
                  case None -> MObject
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
                  case None -> MObject
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

func collectAwaitTypesExprPB(
  cctx: in CodegenCtx,
  pkgName: in String,
  e: in Expr,
  acc: in List[MsilType],
  spawnNms: in List[String],
  spawnTys: in List[MsilType],
): Unit {
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
        case EOBBlock(b) -> collectAwaitTypesBlockPB(cctx, pkgName, b, acc, spawnNms, spawnTys)
        case EOBExpr(e2) -> collectAwaitTypesExprPB(cctx, pkgName, e2, acc, spawnNms, spawnTys)
      }
      match el {
        case Some(els) -> match els { case EOBBlock(b) -> collectAwaitTypesBlockPB(cctx, pkgName, b, acc, spawnNms, spawnTys); case EOBExpr(e3) -> collectAwaitTypesExprPB(cctx, pkgName, e3, acc, spawnNms, spawnTys) }
        case None -> {
        }
      }
    }
    case ECall(callee, args) -> {
      collectAwaitTypesExprPB(cctx, pkgName, callee, acc, spawnNms, spawnTys)
      var aci = 0
      while aci < args.count {
        val argExpr = match args[aci] { case CAPositional(ex) -> ex; case CANamed(_, ex, _) -> ex }
        collectAwaitTypesExprPB(cctx, pkgName, argExpr, acc, spawnNms, spawnTys)
        aci = aci + 1
      }
    }
    case EBinop(_, l, r) -> {
      collectAwaitTypesExprPB(cctx, pkgName, l, acc, spawnNms, spawnTys)
      collectAwaitTypesExprPB(cctx, pkgName, r, acc, spawnNms, spawnTys)
    }
    case _ -> {
    }
  }
}

func collectAwaitTypesBlockPB(
  cctx: in CodegenCtx,
  pkgName: in String,
  blk: in Block,
  acc: in List[MsilType],
  spawnNms: in List[String],
  spawnTys: in List[MsilType],
): Unit {
  var i = 0
  while i < blk.statements.count {
    collectAwaitTypesStmtPB(cctx, pkgName, blk.statements[i], acc, spawnNms, spawnTys)
    i = i + 1
  }
}

func collectAwaitTypesStmtPB(
  cctx: in CodegenCtx,
  pkgName: in String,
  stmt: in Statement,
  acc: in List[MsilType],
  spawnNms: in List[String],
  spawnTys: in List[MsilType],
): Unit {
  match stmt.kind {
    case SLocal(binding) -> match binding { case LBVal(_, _, init) -> collectAwaitTypesExprPB(cctx, pkgName, init, acc, spawnNms, spawnTys); case LBLet(_, _, init) -> collectAwaitTypesExprPB(cctx, pkgName, init, acc, spawnNms, spawnTys); case LBVar(_, _, initOpt) -> match initOpt { case Some(init) -> collectAwaitTypesExprPB(cctx, pkgName, init, acc, spawnNms, spawnTys); case None -> {  } } }
    case SExpr(e) -> collectAwaitTypesExprPB(cctx, pkgName, e, acc, spawnNms, spawnTys)
    case SReturn(valOpt) -> match valOpt { case Some(e) -> collectAwaitTypesExprPB(cctx, pkgName, e, acc, spawnNms, spawnTys); case None -> {  } }
    case SAssign(_, _, value) -> collectAwaitTypesExprPB(cctx, pkgName, value, acc, spawnNms, spawnTys)
    case SThrow(expr) -> collectAwaitTypesExprPB(cctx, pkgName, expr, acc, spawnNms, spawnTys)
    case SWhile(_, cond, body) -> {
      collectAwaitTypesExprPB(cctx, pkgName, cond, acc, spawnNms, spawnTys)
      collectAwaitTypesBlockPB(cctx, pkgName, body, acc, spawnNms, spawnTys)
    }
    case SFor(_, _, iter, body) -> {
      collectAwaitTypesExprPB(cctx, pkgName, iter, acc, spawnNms, spawnTys)
      collectAwaitTypesBlockPB(cctx, pkgName, body, acc, spawnNms, spawnTys)
    }
    case SLoop(_, body) -> collectAwaitTypesBlockPB(cctx, pkgName, body, acc, spawnNms, spawnTys)
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
        case None -> {
        }
      }
    }
    case _ -> {
    }
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
func collectAwaitTypesPhaseBMsil(cctx: in CodegenCtx, pkgName: in String, decl: in FunctionDecl): List[MsilType] {
  val result: List[MsilType] = newList()
  val spawnNms: List[String] = newList()
  val spawnTys: List[MsilType] = newList()

  // Phase 1: flat top-level pre-scan to collect spawn bindings.
  // Only the outermost block's statements are scanned; nested spawn bindings
  // (inside if/match/loop bodies) are a deferred case.
  match decl.body {
    case None -> {
    }
    case Some(body) -> match body { case FBExpr(_) -> {  }; case FBBlock(blk) -> { var si = 0; while si < blk.statements.count { match blk.statements[si].kind { case SLocal(binding) -> match binding { case LBVal(pat, _, init) -> match pat.kind { case PBinding(bindName, _) -> match init.kind { case ESpawn(spawnInner) -> { val sTy = inferCallReturnTypePB(cctx, pkgName, spawnInner, spawnNms, spawnTys); if isTaskTypeMsil(cctx, sTy) { spawnNms.add(bindName); spawnTys.add(sTy) } }; case _ -> {  } }; case _ -> {  } }; case _ -> {  } }; case _ -> {  } }; si = si + 1 } } }
  }

  // Phase 2: recursive scan over the full body using the pre-built spawn lists
  // (read-only — no .add() on the lists inside recursion).
  match decl.body {
    case None -> {
    }
    case Some(body) -> match body { case FBBlock(blk) -> collectAwaitTypesBlockPB(cctx, pkgName, blk, result, spawnNms, spawnTys); case FBExpr(e) -> collectAwaitTypesExprPB(cctx, pkgName, e, result, spawnNms, spawnTys) }
  }
  result
}

// Register a local as a promoted SM field (first time only) and emit a store
// from the local slot to the SM field.  Called from LBLet and LBVar handlers
// inside a Phase B.1 MoveNext context.
func phaseBRegisterAndSyncLocal(
  pbc: in PhaseBCtx,
  insns: in List[MInsn],
  name: in String,
  ty: in MsilType,
  localIdx: in Int,
): Unit {
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
func phaseBSyncLocalIfPromoted(pbc: in PhaseBCtx, insns: in List[MInsn], name: in String, localIdx: in Int): Unit {
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
func phaseBSpillToLocal(pbc: in PhaseBCtx, fctx: in FuncCtx, insns: in List[MInsn], ty: in MsilType): Int {
  val name = "__spill_" + toString(fctx.slotTicker.count)
  val slot = allocSlotMsil(fctx, name, ty)
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
func emitPhaseBAwait(cctx: in CodegenCtx, fctx: in FuncCtx, insns: in List[MInsn], taskTy: in MsilType): MsilType {
  val pbc = fctx.phaseBCtx[0]
  val lctx = cctx.lctx
  val N = pbc.nextAwaitIndex.count
  pbc.nextAwaitIndex.add(0)  // consume index N
  val resumeL = pbc.resumeLabels[N]
  val awFldName = pbc.awaiterFieldNames[N]

  val resT = taskResultType(taskTy)
  val awTy = taskTypeToAwaiterMsilType(cctx, taskTy)
  val tyKey = msilTypeKey(resT)

  // Allocate temp local for the awaiter struct (used by both paths).
  val awSlot = allocSlotMsil(fctx, "__awt_" + toString(N), awTy)
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
  val smLocalIdx = smLocalSlot - fctx.paramCount
  insns.add(MLdarg(slot = 0))
  insns.add(MStloc(slot = smLocalIdx))
  // builder.AwaitUnsafeOnCompleted(ref __awN, ref sm)
  insns.add(MLdarg(slot = 0))
  insns.add(MLdfldaByName(ownerFqn = pbc.smFqn, fieldName = "__builder"))
  insns.add(MLdarg(slot = 0))
  insns.add(MLdfldaByName(ownerFqn = pbc.smFqn, fieldName = awFldName))
  insns.add(MLdloca(slot = smLocalIdx))
  insns.add(MCallAwaitUnsafeOnCompleted(smFqn = pbc.smFqn, atmbMrRow = pbc.atmbMrRowForAwait, awaiterMsilTy = awTy))
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
    val awTsKey = "taskaw1_ts_" + tyKey
    val awTsRow = ctxAddTypeSpec(lctx, awTsKey, awTsBlob)
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
    insns.add(MLdfldByName(ownerFqn = pbc.smFqn, fieldName = "__local_" + pbc.promotedLocalNames[plReloadIdx]))
    insns.add(MStloc(slot = pbc.promotedLocalSlots[plReloadIdx]))
    plReloadIdx = plReloadIdx + 1
  }

  // 5. After-await label: both the "already completed" and "resume" paths join here.
  insns.add(MLabel(id = afterAwaitL))

  // 6. GetResult (stack: address of awaiter → T or void)
  insns.add(MLdloca(slot = awLocalIdx))
  emitGetResultCallPB(cctx, insns, awTy)
}

func synthesizeAsyncSmMsil(
  cctx: in CodegenCtx,
  decl: in FunctionDecl,
  pkgName: in String,
  items: in List[MPackageItem],
  fns: in List[MFunc],
): Unit {

  val tick = cctx.smTicker.count
  cctx.smTicker.add(0)

  val smSimple = "<" + decl.name + ">__SM_" + toString(tick)
  val smFqn = pkgName + "." + smSimple

  // Determine return type of the async func (the T in Task<T>, or void).
  val retTy = match decl.ret {
    case Some(te) -> {
      val r = typeExprToMsilCtx(cctx, te, pkgName)
      if elementTypeByte(r) == 0 {
        MVoid
      } else {
        r
      }
    }
    case None -> MVoid
  }
  val isVoid = retTy == MVoid

  // ── SM field list ─────────────────────────────────────────────────────────
  val smFields: List[MField] = newList()

  // field 0: __state
  smFields.add(MField(flags = FDA_PUBLIC, name = "__state", fieldType = MInt))

  // field 1: __builder (ATMB for void, ATMB<T> for non-void)
  val builderTy: MsilType = if isVoid {
    MValueTypeRef(
      typeRefCode = tdrTypeRef(cctx.trAtmb),
      clrFqn = "System.Runtime.CompilerServices.AsyncTaskMethodBuilder"
    )
  } else {
    val tArgs: List[MsilType] = newList()
    tArgs.add(retTy)
    MValueTypeGenericInst(
      typeRefCode = tdrTypeRef(cctx.trAtmb1),
      headFqn = "System.Runtime.CompilerServices.AsyncTaskMethodBuilder`1",
      typeArgs = tArgs
    )
  }
  smFields.add(MField(flags = FDA_PUBLIC, name = "__builder", fieldType = builderTy))

  // fields 2+: one per user param
  var smPi = 0
  while smPi < decl.params.count {
    val p = decl.params[smPi]
    val pTy = typeExprToMsilCtx(cctx, p.ty, pkgName)
    smFields.add(MField(flags = FDA_PUBLIC, name = "__p" + toString(smPi), fieldType = pTy))
    smPi = smPi + 1
  }

  // ── MoveNext() ────────────────────────────────────────────────────────────
  // paramCount = 1 (this = ldarg.0).
  // User params are pre-loaded from SM fields into LOCAL slots [0, N-1].
  val mnInsns: List[MInsn] = newList()
  // declaredRetTy is the async func's return type (not MVoid): a `return` lowered
  // inside a protected region (try/catch/finally) stashes into `retvalSlot` and
  // `leave`s to the epilogue, so that slot must be typed as the result and the
  // SReturn collExpect must match the result type (#2289).
  val mnFctx = makeFuncCtxMsil(pkgName, smFqn, "MoveNext", 1, retTy)

  // Pre-populate slotTicker with one entry for the `this` arg (slot 0) so
  // that the first allocSlotMsil call below gets slot 1 (a local, not an arg).
  // Without this, slot 0 < paramCount(1) causes the user-param local to be
  // misclassified as an arg, never added to fctx.locals, and the resulting
  // MStloc(slot = 0-1 = -1) encodes as stloc 65535 → UnrecognizedLocalNumber.
  mnFctx.slotTicker.add(0)

  // Preamble: load user params from SM fields into local slots.
  var mpre = 0
  while mpre < decl.params.count {
    val p = decl.params[mpre]
    val pTy = typeExprToMsilCtx(cctx, p.ty, pkgName)
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
            // Route protected-region returns (`return` inside try/catch/finally)
            // into the same slot the epilogue reads: SReturn stores into
            // `retvalSlot` and `leave`s to `epilogueLabel`, and the epilogue below
            // loads `rSlot` for SetResult.  Without this they diverge and the
            // returned value is lost (#2289).
            mnFctx.retvalSlot = rSlot
            val bodyInsns: List[MInsn] = newList()
            pushCollExpect(mnFctx, retTy)
            val trailTy = lowerBlockExprMsil(cctx, mnFctx, bodyInsns, block)
            popCollExpect(mnFctx)
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
            val tsKey = "atmb1_ts_" + taKey
            val tsRow = ctxAddTypeSpec(cctx.lctx, tsKey, tsBlob)
            val srArgs: List[MsilType] = newList()
            srArgs.add(MTypeVar(index = 0))  // VAR 0, not the concrete retTy — see FBBlock note above
            val srSig = buildInstanceMethodSig(srArgs, MVoid)
            val srKey = "atmb1_setresult_mr_" + taKey
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
            pushCollExpect(mnFctx, retTy)
            val eTy = lowerExprMsil(cctx, mnFctx, mnInsns, e)
            popCollExpect(mnFctx)
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
            val taKey2 = msilTypeKey(retTy)
            val tsKey2 = "atmb1_ts_" + taKey2
            val tsRow2 = ctxAddTypeSpec(cctx.lctx, tsKey2, tsBlob2)
            val srArgs2: List[MsilType] = newList()
            srArgs2.add(MTypeVar(index = 0))  // VAR 0, not the concrete retTy — see FBBlock note above
            val srSig2 = buildInstanceMethodSig(srArgs2, MVoid)
            val srKey2 = "atmb1_setresult_mr_" + taKey2
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
    flags = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG + MDA_FINAL,
    name = "MoveNext",
    params = newList(),
    ret = MVoid,
    insns = mnInsns,
    maxStack = computeMaxStackMsil(mnInsns),
    locals = mnFctx.locals
  )

  // ── SetStateMachine() stub ─────────────────────────────────────────────────
  // The CLR calls this to notify the SM that it's been boxed; we don't
  // use the passed-in IAsyncStateMachine reference.  Emit a no-op body.
  val ssmInsns: List[MInsn] = newList()
  ssmInsns.add(MRet)
  val ssmParams: List[MsilType] = newList()
  ssmParams.add(
    MClassRef(typeRefCode = tdrTypeRef(cctx.trIAsm), clrFqn = "System.Runtime.CompilerServices.IAsyncStateMachine")
  )
  val ssmFunc = MFunc(
    flags = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG + MDA_FINAL,
    name = "SetStateMachine",
    params = ssmParams,
    ret = MVoid,
    insns = ssmInsns,
    maxStack = 1,
    locals = newList()
  )

  // ── SM MRecord ────────────────────────────────────────────────────────────
  val smMethods: List[MFunc] = newList()
  smMethods.add(mnFunc)
  smMethods.add(ssmFunc)
  val smRec = MRecord(
    className = smFqn,
    namespace = pkgName,
    baseClass = "System.Object",
    fields = smFields,
    methods = smMethods,
    useDefaultCtor = true,
    generics = newList()
  )
  items.add(MPRecord(rec = smRec))

  // ── IAsyncStateMachine MPImpl ─────────────────────────────────────────────
  val slots: List[MImplSlot] = newList()
  slots.add(
    MImplSlot(ifaceMethodToken = 0, implMethodToken = 0, ifaceMethodName = "MoveNext", implMethodName = "MoveNext")
  )
  slots.add(
    MImplSlot(
      ifaceMethodToken = 0,
      implMethodToken = 0,
      ifaceMethodName = "SetStateMachine",
      implMethodName = "SetStateMachine"
    )
  )
  items.add(
    MPImpl(
      implData = MImplData(
        targetTypeDefRow = 0,
        ifaceTypeToken = 0,
        slots = slots,
        targetTypeName = smFqn,
        ifaceTypeName = "System.Runtime.CompilerServices.IAsyncStateMachine"
      )
    )
  )

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
  val startMrRow = if isVoid {
    cctx.tokAtmbStartMr
  } else {
    val tsArgsS: List[MsilType] = newList()
    tsArgsS.add(retTy)
    val tsBlobS = buildValueTypeGenericInstBlobWithCtx(cctx.lctx, tdrTypeRef(cctx.trAtmb1), tsArgsS)
    val tsKeyS = "atmb1_ts_" + msilTypeKey(retTy)
    val tsRowS = ctxAddTypeSpec(cctx.lctx, tsKeyS, tsBlobS)
    val startOpenSig = buildAtmbStartOpenSig()
    val startMrKey = "atmb1_start_mr_" + msilTypeKey(retTy)
    ctxAddMemberRefForTypeSpec(cctx.lctx, tsRowS, "Start", startMrKey, startOpenSig)
  }
  kfInsns.add(MCallAtmbStart(smFqn = smFqn, atmbMrRow = startMrRow, isGeneric = not isVoid))

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
    val taKey4 = msilTypeKey(retTy)
    kfInsns.add(MLdloc(slot = 0))
    kfInsns.add(MLdfldaByName(ownerFqn = smFqn, fieldName = "__builder"))
    val tsArgs4: List[MsilType] = newList()
    tsArgs4.add(retTy)
    val tsBlob4 = buildValueTypeGenericInstBlobWithCtx(cctx.lctx, tdrTypeRef(cctx.trAtmb1), tsArgs4)
    val tsKey4 = "atmb1_ts_" + taKey4
    val tsRow4 = ctxAddTypeSpec(cctx.lctx, tsKey4, tsBlob4)
    // Method signature must use VAR 0, not the concrete retTy — the TypeSpec parent
    // already captures the concrete type arg; see ECMA-335 II.23.2.1.
    val taskVarArgs: List[MsilType] = newList()
    taskVarArgs.add(MTypeVar(index = 0))
    val taskRetTy: MsilType = MGenericInst(
      typeRefCode = tdrTypeRef(cctx.trTask1),
      headFqn = "System.Threading.Tasks.Task`1",
      typeArgs = taskVarArgs
    )
    val gtArgsTys4: List[MsilType] = newList()
    val gtSig4 = buildInstanceMethodSig(gtArgsTys4, taskRetTy)
    val gtKey4 = "atmb1_gettask_mr_" + taKey4
    val gtMrRow4 = ctxAddMemberRefForTypeSpec(cctx.lctx, tsRow4, "get_Task", gtKey4, gtSig4)
    kfInsns.add(MCall(methodToken = 0x0A000000 + gtMrRow4))
  }
  kfInsns.add(MRet)

  // Kickoff return type is Task<T> (non-void) or Task (void).
  val kfRetTy: MsilType = if isVoid {
    MClassRef(typeRefCode = tdrTypeRef(cctx.trTask), clrFqn = "System.Threading.Tasks.Task")
  } else {
    val kfRetArgs: List[MsilType] = newList()
    kfRetArgs.add(retTy)
    MGenericInst(typeRefCode = tdrTypeRef(cctx.trTask1), headFqn = "System.Threading.Tasks.Task`1", typeArgs = kfRetArgs)
  }

  // Build parameter type list matching the user func.
  val kfParamTypes: List[MsilType] = newList()
  var kpi2 = 0
  while kpi2 < decl.params.count {
    kfParamTypes.add(typeExprToMsilCtx(cctx, decl.params[kpi2].ty, pkgName))
    kpi2 = kpi2 + 1
  }

  fns.add(
    MFunc(
      flags = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG,
      name = decl.name,
      params = byrefWrapSigTypes(decl.params, kfParamTypes),
      ret = kfRetTy,
      insns = kfInsns,
      maxStack = 4,
      locals = kfLocals
    )
  )
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
func synthesizeAsyncSmPhaseBMsil(
  cctx: in CodegenCtx,
  decl: in FunctionDecl,
  pkgName: in String,
  items: in List[MPackageItem],
  fns: in List[MFunc],
): Unit {
  val lctx = cctx.lctx

  val tick = cctx.smTicker.count
  cctx.smTicker.add(0)
  val smSimple = "<" + decl.name + ">__SM_" + toString(tick)
  val smFqn = pkgName + "." + smSimple

  // Return type analysis (same as Phase B.0)
  val retTy = match decl.ret {
    case Some(te) -> {
      val r = typeExprToMsilCtx(cctx, te, pkgName)
      if elementTypeByte(r) == 0 {
        MVoid
      } else {
        r
      }
    }
    case None -> MVoid
  }
  val isVoid = retTy == MVoid

  // Pre-scan: collect awaiter types in body-evaluation order
  val awaiterTypes = collectAwaitTypesPhaseBMsil(cctx, pkgName, decl)
  val awCount = awaiterTypes.count

  // ── SM field list ─────────────────────────────────────────────────────────
  val smFields: List[MField] = newList()
  smFields.add(MField(flags = FDA_PUBLIC, name = "__state", fieldType = MInt))

  val builderTy: MsilType = if isVoid {
    MValueTypeRef(
      typeRefCode = tdrTypeRef(cctx.trAtmb),
      clrFqn = "System.Runtime.CompilerServices.AsyncTaskMethodBuilder"
    )
  } else {
    val tArgs: List[MsilType] = newList()
    tArgs.add(retTy)
    MValueTypeGenericInst(
      typeRefCode = tdrTypeRef(cctx.trAtmb1),
      headFqn = "System.Runtime.CompilerServices.AsyncTaskMethodBuilder`1",
      typeArgs = tArgs
    )
  }
  smFields.add(MField(flags = FDA_PUBLIC, name = "__builder", fieldType = builderTy))

  var smPi = 0
  while smPi < decl.params.count {
    val p = decl.params[smPi]
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
  // declaredRetTy is the async func's return type so a `return` inside a
  // protected region stashes into a correctly-typed `retvalSlot` and the
  // SReturn collExpect matches the result type (#2289).
  val mnFctx = makeFuncCtxMsil(pkgName, smFqn, "MoveNext", 1, retTy)
  mnFctx.slotTicker.add(0)  // reserve slot 0 for 'this' arg

  // Pre-allocate labels
  val tryStartL = freshLabelMsil(mnFctx)
  val bodyStartL = freshLabelMsil(mnFctx)
  val normalDoneL = freshLabelMsil(mnFctx)
  val afterTryL = freshLabelMsil(mnFctx)
  val tryBodyEndL = freshLabelMsil(mnFctx)
  val catchHandlerStartL = freshLabelMsil(mnFctx)
  val catchHandlerEndL = freshLabelMsil(mnFctx)

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
  val atmbMrRowForAwait = if isVoid {
    cctx.tokAtmbAwaitUnsafeMr
  } else {
    val awTsArgs: List[MsilType] = newList()
    awTsArgs.add(retTy)
    val awTsBlob = buildValueTypeGenericInstBlobWithCtx(cctx.lctx, tdrTypeRef(cctx.trAtmb1), awTsArgs)
    val awTaKey = msilTypeKey(retTy)
    // Use the canonical "atmb1_ts_" prefix so ctxAddTypeSpec deduplicates against
    // the same key used by SetResult / SetException / Start / get_Task; a distinct
    // "await_"-prefixed key produced a redundant TypeSpec row for the same type.
    val awTsKey = "atmb1_ts_" + awTaKey
    val awTsRow = ctxAddTypeSpec(cctx.lctx, awTsKey, awTsBlob)
    val awSig = buildAwaitUnsafeOnCompletedOpenSig()
    val awMrKey = "atmb1_await_unsafe_mr_" + awTaKey
    ctxAddMemberRefForTypeSpec(cctx.lctx, awTsRow, "AwaitUnsafeOnCompleted", awMrKey, awSig)
  }

  // Install the PhaseBCtx singleton in mnFctx
  val pbCtx = PhaseBCtx(
    smFqn = smFqn,
    resumeLabels = resumeLabels,
    suspendLeaveLabel = afterTryL,
    nextAwaitIndex = newList(),
    awaiterFieldNames = awaiterFieldNames,
    isVoid = isVoid,
    retTy = retTy,
    atmbMrRowForAwait = atmbMrRowForAwait,
    smFields = smFields,
    promotedLocalNames = newList(),
    promotedLocalSlots = newList(),
    promotedLocalTypes = newList()
  )
  mnFctx.phaseBCtx.add(pbCtx)

  // Pre-allocate result slot for non-void (must exist before body lowering
  // so patched returns can reference it).
  var rSlot = -1
  if not isVoid {
    rSlot = allocSlotMsil(mnFctx, "__sm_result", retTy)
    // Protected-region returns (`return` inside try/catch/finally) `leave` to
    // normalDoneL after stashing into retvalSlot; route that into the same slot
    // the normal-completion epilogue reads for SetResult (#2289).
    mnFctx.retvalSlot = rSlot
  }

  // ── Preamble: load user params from SM fields into local slots ────────────
  var mpre = 0
  while mpre < decl.params.count {
    val p = decl.params[mpre]
    val pTy = typeExprToMsilCtx(cctx, p.ty, pkgName)
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
            pushCollExpect(mnFctx, retTy)
            val trailTy = lowerBlockExprMsil(cctx, mnFctx, bodyInsns, block)
            popCollExpect(mnFctx)
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
                case _ -> mnInsns.add(bodyInsns2[pbi2])
              }
              pbi2 = pbi2 + 1
            }
          }
        }
        case FBExpr(e) -> {
          if not isVoid {
            pushCollExpect(mnFctx, retTy)
            val eTy = lowerExprMsil(cctx, mnFctx, mnInsns, e)
            popCollExpect(mnFctx)
            coerceTrailingToRetMsil(cctx, mnInsns, eTy, retTy)
            mnInsns.add(MStloc(slot = rSlot - 1))
          } else {
            lowerExprMsil(cctx, mnFctx, mnInsns, e)
            mnInsns.add(MPop)
          }
        }
      }
    }
    case None -> {
    }
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
    val tsKeyB = "atmb1_ts_" + taKey
    val tsRowB = ctxAddTypeSpec(lctx, tsKeyB, tsBlobB)
    val srArgsB: List[MsilType] = newList()
    srArgsB.add(MTypeVar(index = 0))
    val srSigB = buildInstanceMethodSig(srArgsB, MVoid)
    val srKeyB = "atmb1_setresult_mr_b1_" + taKey
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
  // Type the exception local as System.Exception (not MObject) so the local
  // declaration matches what the CLR pushes on the catch stack and the IL
  // verifier sees a type-correct load before the SetException(Exception) call.
  val exTy = MClassRef(typeRefCode = tdrTypeRef(cctx.trException), clrFqn = "System.Exception")
  val exSlot = allocSlotMsil(mnFctx, "__sm_ex", exTy)
  mnInsns.add(MStloc(slot = exSlot - 1))
  mnInsns.add(MLdarg(slot = 0))
  mnInsns.add(MLdcI4(v = -2))
  mnInsns.add(MStfldByName(ownerFqn = smFqn, fieldName = "__state"))
  mnInsns.add(MLdarg(slot = 0))
  mnInsns.add(MLdfldaByName(ownerFqn = smFqn, fieldName = "__builder"))
  mnInsns.add(MLdloc(slot = exSlot - 1))
  // SetException signature: (Exception): void
  val seParam = MClassRef(typeRefCode = tdrTypeRef(cctx.trException), clrFqn = "System.Exception")
  val seArgList: List[MsilType] = newList()
  seArgList.add(seParam)
  val seSig = buildInstanceMethodSig(seArgList, MVoid)
  if isVoid {
    val seMrRow = ctxAddMemberRef(lctx, cctx.trAtmb, "SetException", "atmb_setexception", seSig)
    mnInsns.add(MCall(methodToken = 0x0A000000 + seMrRow))
  } else {
    val taKeyEx = msilTypeKey(retTy)
    val tsArgsEx: List[MsilType] = newList()
    tsArgsEx.add(retTy)
    val tsBlobEx = buildValueTypeGenericInstBlobWithCtx(lctx, tdrTypeRef(cctx.trAtmb1), tsArgsEx)
    val tsKeyEx = "atmb1_ts_" + taKeyEx
    val tsRowEx = ctxAddTypeSpec(lctx, tsKeyEx, tsBlobEx)
    val seMrRowEx = ctxAddMemberRefForTypeSpec(lctx, tsRowEx, "SetException", "atmb1_setexception_b1_" + taKeyEx, seSig)
    mnInsns.add(MCall(methodToken = 0x0A000000 + seMrRowEx))
  }
  mnInsns.add(MLeave(label = afterTryL))
  mnFctx.tryRegionStack.removeAt(mnFctx.tryRegionStack.count - 1)
  mnInsns.add(MLabel(id = catchHandlerEndL))

  // EH clause: typed catch(Exception)
  mnInsns.add(
    MEHClause(
      flags = 0,
      tryStart = tryStartL,
      tryEnd = tryBodyEndL,
      handlerStart = catchHandlerStartL,
      handlerEnd = catchHandlerEndL,
      catchToken = 0x01000000 + cctx.trException
    )
  )

  // ── After-try: ret ────────────────────────────────────────────────────────
  mnInsns.add(MLabel(id = afterTryL))
  mnInsns.add(MRet)

  val mnFunc = MFunc(
    flags = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG + MDA_FINAL,
    name = "MoveNext",
    params = newList(),
    ret = MVoid,
    insns = mnInsns,
    maxStack = computeMaxStackMsil(mnInsns),
    locals = mnFctx.locals
  )

  // ── SetStateMachine() stub (identical to Phase B.0) ───────────────────────
  val ssmInsns: List[MInsn] = newList()
  ssmInsns.add(MRet)
  val ssmParams: List[MsilType] = newList()
  ssmParams.add(
    MClassRef(typeRefCode = tdrTypeRef(cctx.trIAsm), clrFqn = "System.Runtime.CompilerServices.IAsyncStateMachine")
  )
  val ssmFunc = MFunc(
    flags = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG + MDA_FINAL,
    name = "SetStateMachine",
    params = ssmParams,
    ret = MVoid,
    insns = ssmInsns,
    maxStack = 1,
    locals = newList()
  )

  // ── SM MRecord (same as Phase B.0) ────────────────────────────────────────
  val smMethods2: List[MFunc] = newList()
  smMethods2.add(mnFunc)
  smMethods2.add(ssmFunc)
  val smRec2 = MRecord(
    className = smFqn,
    namespace = pkgName,
    baseClass = "System.Object",
    fields = smFields,
    methods = smMethods2,
    useDefaultCtor = true,
    generics = newList()
  )
  items.add(MPRecord(rec = smRec2))

  // ── IAsyncStateMachine MPImpl (same as Phase B.0) ─────────────────────────
  val slots2: List[MImplSlot] = newList()
  slots2.add(
    MImplSlot(ifaceMethodToken = 0, implMethodToken = 0, ifaceMethodName = "MoveNext", implMethodName = "MoveNext")
  )
  slots2.add(
    MImplSlot(
      ifaceMethodToken = 0,
      implMethodToken = 0,
      ifaceMethodName = "SetStateMachine",
      implMethodName = "SetStateMachine"
    )
  )
  items.add(
    MPImpl(
      implData = MImplData(
        targetTypeDefRow = 0,
        ifaceTypeToken = 0,
        slots = slots2,
        targetTypeName = smFqn,
        ifaceTypeName = "System.Runtime.CompilerServices.IAsyncStateMachine"
      )
    )
  )

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
  val startMrRow2 = if isVoid {
    cctx.tokAtmbStartMr
  } else {
    val tsArgsS2: List[MsilType] = newList()
    tsArgsS2.add(retTy)
    val tsBlobS2 = buildValueTypeGenericInstBlobWithCtx(lctx, tdrTypeRef(cctx.trAtmb1), tsArgsS2)
    val tsKeyS2 = "atmb1_ts_" + msilTypeKey(retTy)
    val tsRowS2 = ctxAddTypeSpec(lctx, tsKeyS2, tsBlobS2)
    val startOpenSig2 = buildAtmbStartOpenSig()
    val startMrKey2 = "atmb1_start_mr_" + msilTypeKey(retTy)
    ctxAddMemberRefForTypeSpec(lctx, tsRowS2, "Start", startMrKey2, startOpenSig2)
  }
  kfInsns2.add(MCallAtmbStart(smFqn = smFqn, atmbMrRow = startMrRow2, isGeneric = not isVoid))

  // Return Task<T> or Task
  if isVoid {
    kfInsns2.add(MLdloc(slot = 0))
    kfInsns2.add(MLdfldaByName(ownerFqn = smFqn, fieldName = "__builder"))
    kfInsns2.add(MCall(methodToken = cctx.tokAtmbGetTask))
  } else {
    val taKey5 = msilTypeKey(retTy)
    kfInsns2.add(MLdloc(slot = 0))
    kfInsns2.add(MLdfldaByName(ownerFqn = smFqn, fieldName = "__builder"))
    val tsArgs5: List[MsilType] = newList()
    tsArgs5.add(retTy)
    val tsBlob5 = buildValueTypeGenericInstBlobWithCtx(lctx, tdrTypeRef(cctx.trAtmb1), tsArgs5)
    val tsKey5 = "atmb1_ts_" + taKey5
    val tsRow5 = ctxAddTypeSpec(lctx, tsKey5, tsBlob5)
    val taskVarArgs5: List[MsilType] = newList()
    taskVarArgs5.add(MTypeVar(index = 0))
    val taskRetTy5: MsilType = MGenericInst(
      typeRefCode = tdrTypeRef(cctx.trTask1),
      headFqn = "System.Threading.Tasks.Task`1",
      typeArgs = taskVarArgs5
    )
    val gtArgs5: List[MsilType] = newList()
    val gtSig5 = buildInstanceMethodSig(gtArgs5, taskRetTy5)
    val gtKey5 = "atmb1_gettask_mr_" + taKey5
    val gtMrRow5 = ctxAddMemberRefForTypeSpec(lctx, tsRow5, "get_Task", gtKey5, gtSig5)
    kfInsns2.add(MCall(methodToken = 0x0A000000 + gtMrRow5))
  }
  kfInsns2.add(MRet)

  val kfRetTy2: MsilType = if isVoid {
    MClassRef(typeRefCode = tdrTypeRef(cctx.trTask), clrFqn = "System.Threading.Tasks.Task")
  } else {
    val kfRetArgs2: List[MsilType] = newList()
    kfRetArgs2.add(retTy)
    MGenericInst(typeRefCode = tdrTypeRef(cctx.trTask1), headFqn = "System.Threading.Tasks.Task`1", typeArgs = kfRetArgs2)
  }

  val kfParamTypes2: List[MsilType] = newList()
  var kpi4 = 0
  while kpi4 < decl.params.count {
    kfParamTypes2.add(typeExprToMsilCtx(cctx, decl.params[kpi4].ty, pkgName))
    kpi4 = kpi4 + 1
  }
  fns.add(
    MFunc(
      flags = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG,
      name = decl.name,
      params = byrefWrapSigTypes(decl.params, kfParamTypes2),
      ret = kfRetTy2,
      insns = kfInsns2,
      maxStack = 4,
      locals = kfLocals2
    )
  )
}

// ── Phase 5: IAsyncEnumerable<T> generator synthesis (Epic #2070) ─────────────
//
// Emits a sealed class `<funcName>__Gen_N` that implements:
//   IAsyncEnumerable<object>, IAsyncEnumerator<object>, IAsyncDisposable,
//   IAsyncStateMachine
//
// Lazy-producer state-machine pattern (#1490).  MoveNextAsync creates a fresh
// TaskCompletionSource<bool>, calls MoveNext() (which drives the SM one step and
// synchronously calls TCS.SetResult/SetException), then returns
// new ValueTask<bool>(_tcs.Task).  Each `yield expr` stores the value in
// __current, updates _state, calls _tcs.SetResult(true), and leaves the try
// block.  End-of-body calls _tcs.SetResult(false).
//
// Class fields: _state (Int), _tcs (object), __current (object), __pN (params)
// Methods (7 MethodDef rows):
//   .ctor (useDefaultCtor) — zero-initialises; kickoff sets _state = -1
//   MoveNext()                          — IAsyncStateMachine.MoveNext (SM body)
//   SetStateMachine(IAsyncStateMachine) — stub (no-op)
//   GetAsyncEnumerator(CancellationToken) — resets _state=-1, returns this
//   MoveNextAsync()                     — creates TCS, drives MoveNext, returns ValueTask<bool>
//   get_Current                         — returns __current
//   DisposeAsync()                      — no-op, returns default(ValueTask)
func synthesizeGeneratorMsil(
  cctx: in CodegenCtx,
  decl: in FunctionDecl,
  pkgName: in String,
  items: in List[MPackageItem],
  fns: in List[MFunc],
): Unit {
  val lctx = cctx.lctx

  val tick = cctx.genTicker.count
  cctx.genTicker.add(0)
  val genSimple = "<" + decl.name + ">__Gen_" + toString(tick)
  val genFqn = pkgName + "." + genSimple

  val yieldCount = countYieldsInFuncBody(decl)

  // ── TypeSpecs for generic interfaces (idempotent — shared across generators) ──

  // IAsyncEnumerable<object> TypeSpec
  val iaeArgs: List[MsilType] = newList()
  iaeArgs.add(MObject)
  val iaeBlob = buildGenericInstBlob(tdrTypeRef(cctx.trIAE1), iaeArgs)
  val tsIAERow = ctxAddTypeSpec(lctx, "ts_iae_obj", iaeBlob)

  // IAsyncEnumerator<object> TypeSpec
  val iaetArgs: List[MsilType] = newList()
  iaetArgs.add(MObject)
  val iaetBlob = buildGenericInstBlob(tdrTypeRef(cctx.trIAET1), iaetArgs)
  val tsIAETRow = ctxAddTypeSpec(lctx, "ts_iaet_obj", iaetBlob)

  // ValueTask<bool> TypeSpec (value type)
  val vtBoolArgs: List[MsilType] = newList()
  vtBoolArgs.add(MBool)
  val vtBoolBlob = buildValueTypeGenericInstBlobWithCtx(lctx, tdrTypeRef(cctx.trValueTask1), vtBoolArgs)
  val tsVtBoolRow = ctxAddTypeSpec(lctx, "ts_vt_bool", vtBoolBlob)

  // TaskCompletionSource<bool> TypeSpec (reference type, CLASS encoding)
  val tcsBoolArgs: List[MsilType] = newList()
  tcsBoolArgs.add(MBool)
  val tcsBoolBlob = buildGenericInstBlobWithCtx(lctx, tdrTypeRef(cctx.trTcs1), tcsBoolArgs)
  val tsTcsBoolRow = ctxAddTypeSpec(lctx, "ts_tcs_bool", tcsBoolBlob)

  // ── MemberRefs for interface dispatch ─────────────────────────────────────

  // IAsyncEnumerator<object>::MoveNextAsync() → ValueTask<bool>
  val moveNextPs: List[MsilType] = newList()
  val vtBoolInlineTy: List[MsilType] = newList()
  vtBoolInlineTy.add(MBool)
  val moveNextRetTy = MValueTypeGenericInst(
    typeRefCode = tdrTypeRef(cctx.trValueTask1),
    headFqn = "System.Threading.Tasks.ValueTask`1",
    typeArgs = vtBoolInlineTy
  )
  val tokIAETMoveNext = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      lctx,
      tsIAETRow,
      "MoveNextAsync",
      "iaet_obj_movenext",
      buildInstanceMethodSig(moveNextPs, moveNextRetTy)
    )

  // IAsyncEnumerator<object>::get_Current() → !0
  val getCurrentPs: List[MsilType] = newList()
  val tokIAETGetCurrent = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      lctx,
      tsIAETRow,
      "get_Current",
      "iaet_obj_getcurrent",
      buildInstanceMethodSig(getCurrentPs, MTypeVar(index = 0))
    )

  // IAsyncEnumerable<object>::GetAsyncEnumerator(CancellationToken) → IAsyncEnumerator<!0>
  // Per ECMA-335 II.22.25: MemberRef signatures on TypeSpec-parented rows must use the
  // OPEN (type-variable) form.  IAsyncEnumerable<T>.GetAsyncEnumerator returns
  // IAsyncEnumerator<T> where T is !0 of the enclosing generic type.  Using MObject here
  // instead of MTypeVar(0) produces the wrong (closed) signature, which the CLR JIT
  // cannot match against the interface slot → MissingMethodException at dispatch.
  val getEnumPs: List[MsilType] = newList()
  val ctTy = MValueTypeRef(typeRefCode = tdrTypeRef(cctx.trCancToken), clrFqn = "System.Threading.CancellationToken")
  getEnumPs.add(ctTy)
  val iaetTypeVarArgs: List[MsilType] = newList()
  iaetTypeVarArgs.add(MTypeVar(index = 0))
  val getEnumRetTy = MGenericInst(
    typeRefCode = tdrTypeRef(cctx.trIAET1),
    headFqn = "System.Collections.Generic.IAsyncEnumerator`1",
    typeArgs = iaetTypeVarArgs
  )
  val tokIAEGetEnum = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      lctx,
      tsIAERow,
      "GetAsyncEnumerator",
      "iae_obj_getenum",
      buildInstanceMethodSig(getEnumPs, getEnumRetTy)
    )

  // ── MemberRefs for TCS<bool> ──────────────────────────────────────────────

  // TCS<bool>::.ctor() → void
  val tokTcsCtor = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      lctx,
      tsTcsBoolRow,
      ".ctor",
      "tcs_bool_ctor",
      buildInstanceMethodSig(newList(), MVoid)
    )

  // TCS<bool>::SetResult(!0) → void  (type variable for open form)
  val tcsSetResultPs: List[MsilType] = newList()
  tcsSetResultPs.add(MTypeVar(index = 0))
  val tokTcsSetResult = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      lctx,
      tsTcsBoolRow,
      "SetResult",
      "tcs_bool_setresult",
      buildInstanceMethodSig(tcsSetResultPs, MVoid)
    )

  // TCS<bool>::SetException(Exception) → void
  val tcsSetExcPs: List[MsilType] = newList()
  tcsSetExcPs.add(MClassRef(typeRefCode = tdrTypeRef(cctx.trException), clrFqn = "System.Exception"))
  val tokTcsSetException = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      lctx,
      tsTcsBoolRow,
      "SetException",
      "tcs_bool_setexception",
      buildInstanceMethodSig(tcsSetExcPs, MVoid)
    )

  // TCS<bool>::get_Task → Task<!0>  (open type-variable for MemberRef on TypeSpec)
  val tcsGetTaskVarArgs: List[MsilType] = newList()
  tcsGetTaskVarArgs.add(MTypeVar(index = 0))
  val tcsGetTaskRetTy = MGenericInst(
    typeRefCode = tdrTypeRef(cctx.trTask1),
    headFqn = "System.Threading.Tasks.Task`1",
    typeArgs = tcsGetTaskVarArgs
  )
  val tokTcsGetTask = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      lctx,
      tsTcsBoolRow,
      "get_Task",
      "tcs_bool_gettask",
      buildInstanceMethodSig(newList(), tcsGetTaskRetTy)
    )

  // ── MemberRefs for ValueTask<bool> ────────────────────────────────────────

  // ValueTask<bool>::.ctor(Task<!0>) → void  — task-based ctor for MoveNextAsync
  val vtTaskVarArgs: List[MsilType] = newList()
  vtTaskVarArgs.add(MTypeVar(index = 0))
  val vtBoolFromTaskCtorPs: List[MsilType] = newList()
  vtBoolFromTaskCtorPs.add(
    MGenericInst(
      typeRefCode = tdrTypeRef(cctx.trTask1),
      headFqn = "System.Threading.Tasks.Task`1",
      typeArgs = vtTaskVarArgs
    )
  )
  val tokVtBoolFromTaskCtor = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      lctx,
      tsVtBoolRow,
      ".ctor",
      "vt_bool_task_ctor",
      buildInstanceMethodSig(vtBoolFromTaskCtorPs, MVoid)
    )

  // ValueTask<bool>::get_Result() → !0 — needed by the consumer for-await loop
  val vtBoolResPs: List[MsilType] = newList()
  val tokVtBoolGetResult = 0x0A000000 +
    ctxAddMemberRefForTypeSpec(
      lctx,
      tsVtBoolRow,
      "get_Result",
      "vt_bool_getresult",
      buildInstanceMethodSig(vtBoolResPs, MTypeVar(index = 0))
    )

  // ── Generator class fields ─────────────────────────────────────────────────
  val genFields: List[MField] = newList()
  genFields.add(MField(flags = FDA_PUBLIC, name = "_state", fieldType = MInt))
  genFields.add(MField(flags = FDA_PUBLIC, name = "_tcs", fieldType = MObject))
  genFields.add(MField(flags = FDA_PUBLIC, name = "__current", fieldType = MObject))
  var gfi = 0
  while gfi < decl.params.count {
    val p = decl.params[gfi]
    val pTy = typeExprToMsilCtx(cctx, p.ty, pkgName)
    genFields.add(MField(flags = FDA_PUBLIC, name = "__p" + toString(gfi), fieldType = pTy))
    gfi = gfi + 1
  }

  // Closed TypeSpec token for TCS<bool> castclass (TypeSpec table = 0x1B).
  val tsTcsBoolToken = 0x1B000000 + tsTcsBoolRow

  // ── MoveNext() — IAsyncStateMachine body wrapped in try/catch ─────────────
  // paramCount = 1 (slot 0 = 'this').
  val mnInsns: List[MInsn] = newList()
  val mnFctx = makeFuncCtxMsil(pkgName, genFqn, "MoveNext", 1, MVoid)
  mnFctx.slotTicker.add(0)  // reserve slot 0 for 'this'

  // Pre-allocate labels.
  val tryStartL = freshLabelMsil(mnFctx)
  val bodyStartL = freshLabelMsil(mnFctx)
  val normalDoneL = freshLabelMsil(mnFctx)
  val afterTryL = freshLabelMsil(mnFctx)
  val tryBodyEndL = freshLabelMsil(mnFctx)
  val catchHandlerStartL = freshLabelMsil(mnFctx)
  val catchHandlerEndL = freshLabelMsil(mnFctx)

  // One resume label per yield site (0-based; EYield stores state = idx).
  val resumeLabels: List[Int] = newList()
  var rli = 0
  while rli < yieldCount {
    resumeLabels.add(freshLabelMsil(mnFctx))
    rli = rli + 1
  }

  // epilogueLabel points to normalDoneL so any `return` inside the body
  // (patched by emitEpilogueMsil if used) reaches the end-of-sequence path.
  mnFctx.epilogueLabel = normalDoneL

  // Install LazyGenCtx so EYield emits the lazy TCS protocol.
  val lgCtx = LazyGenCtx(
    genFqn = genFqn,
    resumeLabels = resumeLabels,
    nextYieldIndex = newList(),
    leaveLabel = afterTryL,
    tokTcsSetResult = tokTcsSetResult,
    tokTcsSetException = tokTcsSetException,
    tcsTypeSpecToken = tsTcsBoolToken
  )
  mnFctx.lazyGenCtx.add(lgCtx)

  // Preamble: load user params from fields into local slots (before the try).
  var mpre = 0
  while mpre < decl.params.count {
    val p = decl.params[mpre]
    val pTy = typeExprToMsilCtx(cctx, p.ty, pkgName)
    val pSlot = allocSlotMsil(mnFctx, p.name, pTy)
    mnInsns.add(MLdarg(slot = 0))
    mnInsns.add(MLdfldByName(ownerFqn = genFqn, fieldName = "__p" + toString(mpre)))
    mnInsns.add(MStloc(slot = pSlot - 1))
    mpre = mpre + 1
  }

  // ── Try block ────────────────────────────────────────────────────────────────
  mnInsns.add(MLabel(id = tryStartL))
  mnFctx.tryRegionStack.add(0)

  // State dispatch: switch(resumeLabels) dispatches state 0→labels[0], etc.
  // state -1 (initial) and -2 (done) are negative → switch falls through → br bodyStartL.
  mnInsns.add(MLdarg(slot = 0))
  mnInsns.add(MLdfldByName(ownerFqn = genFqn, fieldName = "_state"))
  mnInsns.add(MSwitch(labels = resumeLabels))
  mnInsns.add(MBr(label = bodyStartL))
  mnInsns.add(MLabel(id = bodyStartL))

  // Lower user body.
  match decl.body {
    case Some(body) -> {
      match body {
        case FBBlock(block) -> {
          lowerBlockMsil(cctx, mnFctx, mnInsns, block)
        }
        case FBExpr(e) -> {
          lowerExprMsil(cctx, mnFctx, mnInsns, e)
          mnInsns.add(MPop)
        }
      }
    }
    case None -> {
    }
  }

  // Normal-completion epilogue (also reached by patched returns if any).
  mnInsns.add(MLabel(id = normalDoneL))
  mnInsns.add(MLdarg(slot = 0))
  mnInsns.add(MLdcI4(v = -2))
  mnInsns.add(MStfldByName(ownerFqn = genFqn, fieldName = "_state"))
  mnInsns.add(MLdarg(slot = 0))
  mnInsns.add(MLdfldByName(ownerFqn = genFqn, fieldName = "_tcs"))
  mnInsns.add(MCastclass(typeToken = tsTcsBoolToken))
  mnInsns.add(MLdcI4(v = 0))
  mnInsns.add(MCallvirt(methodToken = tokTcsSetResult))
  mnInsns.add(MLeave(label = afterTryL))

  mnFctx.tryRegionStack.removeAt(mnFctx.tryRegionStack.count - 1)
  mnInsns.add(MLabel(id = tryBodyEndL))

  // ── Catch handler ─────────────────────────────────────────────────────────────
  mnInsns.add(MLabel(id = catchHandlerStartL))
  mnFctx.tryRegionStack.add(0)
  val exTy = MClassRef(typeRefCode = tdrTypeRef(cctx.trException), clrFqn = "System.Exception")
  val exSlot = allocSlotMsil(mnFctx, "__gen_ex", exTy)
  mnInsns.add(MStloc(slot = exSlot - 1))
  mnInsns.add(MLdarg(slot = 0))
  mnInsns.add(MLdfldByName(ownerFqn = genFqn, fieldName = "_tcs"))
  mnInsns.add(MCastclass(typeToken = tsTcsBoolToken))
  mnInsns.add(MLdloc(slot = exSlot - 1))
  mnInsns.add(MCallvirt(methodToken = tokTcsSetException))
  mnInsns.add(MLeave(label = afterTryL))
  mnFctx.tryRegionStack.removeAt(mnFctx.tryRegionStack.count - 1)
  mnInsns.add(MLabel(id = catchHandlerEndL))

  // EH clause: typed catch(Exception).
  mnInsns.add(
    MEHClause(
      flags = 0,
      tryStart = tryStartL,
      tryEnd = tryBodyEndL,
      handlerStart = catchHandlerStartL,
      handlerEnd = catchHandlerEndL,
      catchToken = 0x01000000 + cctx.trException
    )
  )

  // After-try: ret.
  mnInsns.add(MLabel(id = afterTryL))
  mnInsns.add(MRet)

  // ── Hoist loop-carried locals to generator fields ─────────────────────────
  // Locals that survive across yield points are zeroed on each MoveNext call;
  // they must be stored in instance fields and saved/restored at each yield
  // boundary.  Local indices 0..decl.params.count-1 are param aliases that the
  // preamble re-loads from __pN fields on every call, so they are excluded.
  // All other locals (user body locals + __gen_ex) are hoisted.
  val hoistParamCount = decl.params.count
  val hoistSeen: Map[Int, Bool] = newMap()
  val hoistLocalIndices: List[Int] = newList()
  var hsiScan = 0
  while hsiScan < mnInsns.count {
    val hInsn = mnInsns[hsiScan]
    val hSlot = match hInsn { case MLdloc(s) -> s; case MStloc(s) -> s; case _ -> -1 }
    if hSlot >= hoistParamCount {
      if not hoistSeen.containsKey(hSlot) {
        hoistSeen.add(hSlot, true)
        hoistLocalIndices.add(hSlot)
      }
    }
    hsiScan = hsiScan + 1
  }
  val hoistFieldNames: List[String] = newList()
  var hfScan = 0
  while hfScan < hoistLocalIndices.count {
    val localIdx = hoistLocalIndices[hfScan]
    val fname = "__local_" + toString(localIdx)
    val fty = mnFctx.locals[localIdx]
    genFields.add(MField(flags = FDA_PUBLIC, name = fname, fieldType = fty))
    hoistFieldNames.add(fname)
    hfScan = hfScan + 1
  }
  // Rebuild instruction list with save/restore inserted at each yield boundary.
  val hoistedInsns: List[MInsn] = newList()
  var hriScan = 0
  while hriScan < mnInsns.count {
    val hInsn = mnInsns[hriScan]
    match hInsn {
      case MLeave(lbl) -> {
        // Yield-leave: MLeave(afterTryL) immediately followed by a resume MLabel.
        val isYieldLeave = lbl == afterTryL and hriScan + 1 < mnInsns.count and
          (
            match mnInsns[hriScan + 1] {
              case MLabel(nxtId) -> resumeLabels.contains(nxtId)
              case _ -> false
            }
          )
        if isYieldLeave {
          var sv = 0
          while sv < hoistLocalIndices.count {
            hoistedInsns.add(MLdarg(slot = 0))
            hoistedInsns.add(MLdloc(slot = hoistLocalIndices[sv]))
            hoistedInsns.add(MStfldByName(ownerFqn = genFqn, fieldName = hoistFieldNames[sv]))
            sv = sv + 1
          }
        }
        hoistedInsns.add(hInsn)
      }
      case MLabel(labelId) -> {
        hoistedInsns.add(hInsn)
        if resumeLabels.contains(labelId) {
          var rv = 0
          while rv < hoistLocalIndices.count {
            hoistedInsns.add(MLdarg(slot = 0))
            hoistedInsns.add(MLdfldByName(ownerFqn = genFqn, fieldName = hoistFieldNames[rv]))
            hoistedInsns.add(MStloc(slot = hoistLocalIndices[rv]))
            rv = rv + 1
          }
        }
      }
      case _ -> hoistedInsns.add(hInsn)
    }
    hriScan = hriScan + 1
  }

  val mnFunc = MFunc(
    flags = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG + MDA_FINAL,
    name = "MoveNext",
    params = newList(),
    ret = MVoid,
    insns = hoistedInsns,
    maxStack = computeMaxStackMsil(hoistedInsns),
    locals = mnFctx.locals
  )

  // ── SetStateMachine() stub ─────────────────────────────────────────────────
  val ssmInsns: List[MInsn] = newList()
  ssmInsns.add(MRet)
  val ssmParams: List[MsilType] = newList()
  ssmParams.add(
    MClassRef(typeRefCode = tdrTypeRef(cctx.trIAsm), clrFqn = "System.Runtime.CompilerServices.IAsyncStateMachine")
  )
  val ssmFunc = MFunc(
    flags = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG + MDA_FINAL,
    name = "SetStateMachine",
    params = ssmParams,
    ret = MVoid,
    insns = ssmInsns,
    maxStack = 1,
    locals = newList()
  )

  // ── GetAsyncEnumerator(CancellationToken) → IAsyncEnumerator<object> ──────
  // Resets _state to -1 (restarts iteration) and returns this.
  val gaeInsns: List[MInsn] = newList()
  gaeInsns.add(MLdarg(slot = 0))
  gaeInsns.add(MLdcI4(v = -1))
  gaeInsns.add(MStfldByName(ownerFqn = genFqn, fieldName = "_state"))
  gaeInsns.add(MLdarg(slot = 0))
  gaeInsns.add(MRet)
  val gaeParams: List[MsilType] = newList()
  gaeParams.add(ctTy)
  val gaeRetArgs: List[MsilType] = newList()
  gaeRetArgs.add(MObject)
  val gaeRetTy = MGenericInst(
    typeRefCode = tdrTypeRef(cctx.trIAET1),
    headFqn = "System.Collections.Generic.IAsyncEnumerator`1",
    typeArgs = gaeRetArgs
  )
  val gaeFunc = MFunc(
    flags = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG + MDA_FINAL,
    name = "GetAsyncEnumerator",
    params = gaeParams,
    ret = gaeRetTy,
    insns = gaeInsns,
    maxStack = 2,
    locals = newList()
  )

  // ── MoveNextAsync() → ValueTask<bool> ────────────────────────────────────
  // Creates a fresh TCS<bool>, calls this.MoveNext() (which drives the SM one
  // step and synchronously calls TCS.SetResult/SetException), then returns
  // new ValueTask<bool>(_tcs.Task).
  val mnaInsns: List[MInsn] = newList()

  // this._tcs = new TaskCompletionSource<bool>()
  mnaInsns.add(MLdarg(slot = 0))
  mnaInsns.add(MNewobj(ctorToken = tokTcsCtor))
  mnaInsns.add(MStfldByName(ownerFqn = genFqn, fieldName = "_tcs"))

  // this.MoveNext()
  mnaInsns.add(MLdarg(slot = 0))
  mnaInsns.add(MCallByName(className = genFqn, methodName = "MoveNext"))

  // return new ValueTask<bool>(_tcs.Task)
  mnaInsns.add(MLdarg(slot = 0))
  mnaInsns.add(MLdfldByName(ownerFqn = genFqn, fieldName = "_tcs"))
  mnaInsns.add(MCastclass(typeToken = tsTcsBoolToken))
  mnaInsns.add(MCallvirt(methodToken = tokTcsGetTask))
  mnaInsns.add(MNewobj(ctorToken = tokVtBoolFromTaskCtor))
  mnaInsns.add(MRet)

  val mnaRetArgs: List[MsilType] = newList()
  mnaRetArgs.add(MBool)
  val mnaRetTy = MValueTypeGenericInst(
    typeRefCode = tdrTypeRef(cctx.trValueTask1),
    headFqn = "System.Threading.Tasks.ValueTask`1",
    typeArgs = mnaRetArgs
  )
  val mnaFunc = MFunc(
    flags = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG + MDA_FINAL,
    name = "MoveNextAsync",
    params = newList(),
    ret = mnaRetTy,
    insns = mnaInsns,
    maxStack = computeMaxStackMsil(mnaInsns),
    locals = newList()
  )

  // ── get_Current() → object ────────────────────────────────────────────────
  val gcInsns: List[MInsn] = newList()
  gcInsns.add(MLdarg(slot = 0))
  gcInsns.add(MLdfldByName(ownerFqn = genFqn, fieldName = "__current"))
  gcInsns.add(MRet)
  val gcFunc = MFunc(
    flags = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG + MDA_FINAL + MDA_SPECIAL_NAME,
    name = "get_Current",
    params = newList(),
    ret = MObject,
    insns = gcInsns,
    maxStack = 1,
    locals = newList()
  )

  // ── DisposeAsync() → ValueTask ────────────────────────────────────────────
  val daFctx = makeFuncCtxMsil(pkgName, genFqn, "DisposeAsync", 1, MVoid)
  daFctx.slotTicker.add(0)
  val daVtTy = MValueTypeRef(typeRefCode = tdrTypeRef(cctx.trValueTask), clrFqn = "System.Threading.Tasks.ValueTask")
  val daVtSlot = allocSlotMsil(daFctx, "__gen_da_vt", daVtTy)
  val daInsns: List[MInsn] = newList()
  daInsns.add(MLdloca(slot = daVtSlot - 1))
  daInsns.add(MInitobj(typeToken = 0x01000000 + cctx.trValueTask))
  daInsns.add(MLdloc(slot = daVtSlot - 1))
  daInsns.add(MRet)
  val daRetTy = MValueTypeRef(typeRefCode = tdrTypeRef(cctx.trValueTask), clrFqn = "System.Threading.Tasks.ValueTask")
  val daFunc = MFunc(
    flags = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG + MDA_FINAL,
    name = "DisposeAsync",
    params = newList(),
    ret = daRetTy,
    insns = daInsns,
    maxStack = 2,
    locals = daFctx.locals
  )

  // ── Generator MRecord ──────────────────────────────────────────────────────
  val genMethods: List[MFunc] = newList()
  genMethods.add(mnFunc)
  genMethods.add(ssmFunc)
  genMethods.add(gaeFunc)
  genMethods.add(mnaFunc)
  genMethods.add(gcFunc)
  genMethods.add(daFunc)
  val genRec = MRecord(
    className = genFqn,
    namespace = pkgName,
    baseClass = "System.Object",
    fields = genFields,
    methods = genMethods,
    useDefaultCtor = true,
    generics = newList()
  )
  items.add(MPRecord(rec = genRec))

  // ── IAsyncStateMachine MPImpl ─────────────────────────────────────────────
  val smImplSlots: List[MImplSlot] = newList()
  smImplSlots.add(
    MImplSlot(ifaceMethodToken = 0, implMethodToken = 0, ifaceMethodName = "MoveNext", implMethodName = "MoveNext")
  )
  smImplSlots.add(
    MImplSlot(
      ifaceMethodToken = 0,
      implMethodToken = 0,
      ifaceMethodName = "SetStateMachine",
      implMethodName = "SetStateMachine"
    )
  )
  items.add(
    MPImpl(
      implData = MImplData(
        targetTypeDefRow = 0,
        ifaceTypeToken = 0,
        slots = smImplSlots,
        targetTypeName = genFqn,
        ifaceTypeName = "System.Runtime.CompilerServices.IAsyncStateMachine"
      )
    )
  )

  // ── IAsyncEnumerable<object> MPImpl ───────────────────────────────────────
  val iaeSlots: List[MImplSlot] = newList()
  iaeSlots.add(
    MImplSlot(
      ifaceMethodToken = tokIAEGetEnum - 0x0A000000,
      implMethodToken = 0,
      ifaceMethodName = "GetAsyncEnumerator",
      implMethodName = "GetAsyncEnumerator"
    )
  )
  items.add(
    MPImpl(
      implData = MImplData(
        targetTypeDefRow = 0,
        ifaceTypeToken = tdrTypeSpec(tsIAERow),
        slots = iaeSlots,
        targetTypeName = genFqn,
        ifaceTypeName = "IAsyncEnumerable`1<object>"
      )
    )
  )

  // ── IAsyncEnumerator<object> MPImpl ───────────────────────────────────────
  val iaetSlots: List[MImplSlot] = newList()
  iaetSlots.add(
    MImplSlot(
      ifaceMethodToken = tokIAETMoveNext - 0x0A000000,
      implMethodToken = 0,
      ifaceMethodName = "MoveNextAsync",
      implMethodName = "MoveNextAsync"
    )
  )
  iaetSlots.add(
    MImplSlot(
      ifaceMethodToken = tokIAETGetCurrent - 0x0A000000,
      implMethodToken = 0,
      ifaceMethodName = "get_Current",
      implMethodName = "get_Current"
    )
  )
  items.add(
    MPImpl(
      implData = MImplData(
        targetTypeDefRow = 0,
        ifaceTypeToken = tdrTypeSpec(tsIAETRow),
        slots = iaetSlots,
        targetTypeName = genFqn,
        ifaceTypeName = "IAsyncEnumerator`1<object>"
      )
    )
  )

  // ── IAsyncDisposable MPImpl ────────────────────────────────────────────────
  val iasyncDispSlots: List[MImplSlot] = newList()
  iasyncDispSlots.add(
    MImplSlot(
      ifaceMethodToken = 0,
      implMethodToken = 0,
      ifaceMethodName = "DisposeAsync",
      implMethodName = "DisposeAsync"
    )
  )
  items.add(
    MPImpl(
      implData = MImplData(
        targetTypeDefRow = 0,
        ifaceTypeToken = tdrTypeRef(cctx.trIAsyncDisp),
        slots = iasyncDispSlots,
        targetTypeName = genFqn,
        ifaceTypeName = "System.IAsyncDisposable"
      )
    )
  )

  // ── Kickoff MFunc ──────────────────────────────────────────────────────────
  // Creates the generator, sets _state=-1 (initial), copies user params, returns it.
  val kfInsns: List[MInsn] = newList()
  val kfLocals: List[MsilType] = newList()
  kfLocals.add(MClass(genFqn))

  kfInsns.add(MNewobjByName(className = genFqn))
  kfInsns.add(MStloc(slot = 0))

  // gen._state = -1  (useDefaultCtor zeroes fields; -1 is the correct initial state)
  kfInsns.add(MLdloc(slot = 0))
  kfInsns.add(MLdcI4(v = -1))
  kfInsns.add(MStfldByName(ownerFqn = genFqn, fieldName = "_state"))

  // Copy user params into gen fields.
  var kpi = 0
  while kpi < decl.params.count {
    kfInsns.add(MLdloc(slot = 0))
    kfInsns.add(MLdarg(slot = kpi))
    kfInsns.add(MStfldByName(ownerFqn = genFqn, fieldName = "__p" + toString(kpi)))
    kpi = kpi + 1
  }

  // return gen (as IAsyncEnumerable<object>)
  kfInsns.add(MLdloc(slot = 0))
  kfInsns.add(MRet)

  val kfRetArgs: List[MsilType] = newList()
  kfRetArgs.add(MObject)
  val kfRetTy: MsilType = MGenericInst(
    typeRefCode = tdrTypeRef(cctx.trIAE1),
    headFqn = "System.Collections.Generic.IAsyncEnumerable`1",
    typeArgs = kfRetArgs
  )
  val kfParamTypes: List[MsilType] = newList()
  var kpi2 = 0
  while kpi2 < decl.params.count {
    kfParamTypes.add(typeExprToMsilCtx(cctx, decl.params[kpi2].ty, pkgName))
    kpi2 = kpi2 + 1
  }
  fns.add(
    MFunc(
      flags = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG,
      name = decl.name,
      params = byrefWrapSigTypes(decl.params, kfParamTypes),
      ret = kfRetTy,
      insns = kfInsns,
      maxStack = 3 + decl.params.count,
      locals = kfLocals
    )
  )
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

pub func lowerFuncMsil(cctx: in CodegenCtx, decl: in FunctionDecl, pkgName: in String): MFunc {
  val className = pkgName
  // Generic-function type parameters (#2557).  When non-empty, a `slice[T]` /
  // bare-`T` parameter, return, and local must use the erased List-backed
  // representation (see typeExprToMsilGenBody / typeExprToMsilGenSig) instead of
  // a bogus `MClass(pkg + ".T")` that names no real CLR type.
  val fnGenerics = genericNamesOf(decl.generics)
  val retTy = if startsWith(decl.name, "__lambda_") {
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
        // A generic-function `slice[T]` / bare-`T` return is emitted as plain
        // `object` so a List-backed return value matches the signature; the
        // caller tracks it via funcRetTypes and reads it through the IList path
        // (#2557).
        val resolved = if fnGenerics.count > 0 {
          typeExprToMsilGenSig(cctx, te, pkgName, fnGenerics)
        } else {
          typeExprToMsilCtx(cctx, te, pkgName)
        }
        if elementTypeByte(resolved) == 0 {
          MVoid
        } else {
          resolved
        }
      }
      case None -> MVoid
    }
  }
  // Capturing closure (#1479): a capturing `__lambda_*` takes a synthetic leading
  // `object[] __caps` parameter (the closed-over delegate target).  It occupies
  // slot 0, shifting the lambda's own params to 1+, so paramCount grows by one.
  val lambdaCaps = match mapGet(cctx.lambdaCaptureNames, decl.name) { case Some(c) -> c; case None -> newList() }
  val lambdaCapTys = match mapGet(cctx.lambdaCaptureTypes, decl.name) { case Some(t) -> t; case None -> newList() }
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
    val capCells = match mapGet(cctx.lambdaCaptureCells, decl.name) { case Some(c) -> c; case None -> newList() }
    var cni = 0
    while cni < lambdaCaps.count {
      fctx.captureNameToIndex.add(lambdaCaps[cni], cni)
      fctx.captureNameToType.add(
        lambdaCaps[cni],
        match (if cni < lambdaCapTys.count { Some(value = lambdaCapTys[cni]) } else { None }) {
          case Some(t) -> t
          case None -> MObject
        }
      )
      // A by-reference capture: `__caps[cni]` holds the hoisted `var`'s cell.
      if nameListContains(capCells, lambdaCaps[cni]) {
        fctx.captureCellNames.add(lambdaCaps[cni])
      }
      cni = cni + 1
    }
  }
  // Parameter types propagated from a higher-order-function call site (#1939),
  // used when a lambda param is un-annotated.  Empty for non-lambdas (decl.name
  // is never a "__lambda_*" key) and lambdas not passed directly to a typed
  // `(…) -> R` parameter.
  val lambdaPropagated = match mapGet(cctx.lambdaParamTypes, decl.name) { case Some(ts) -> ts; case None -> newList() }
  var pi = 0
  while pi < decl.params.count {
    val p = decl.params[pi]
    // A lambda parameter's logical type is its annotation if present, else the
    // type propagated from the call site (#1939); the signature stays `object`.
    // A generic-function `slice[T]` / bare-`T` param tracks as the erased
    // List-backed form (#2557) so the body uses the non-generic IList path.
    val annotTy = if fnGenerics.count > 0 {
      typeExprToMsilGenBody(cctx, p.ty, pkgName, fnGenerics)
    } else {
      typeExprToMsilCtx(cctx, p.ty, pkgName)
    }
    val paramTy = if isLambdaFn and annotTy == MObject and pi < lambdaPropagated.count {
      lambdaPropagated[pi]
    } else {
      annotTy
    }
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
      case _ -> {
      }
    }
    fctx.slotTicker.add(0)
    pi = pi + 1
  }

  // By-reference closure capture pre-pass (#1479 v2): collect every name used
  // inside a lambda in this body.  A `var` local in this set is hoisted to a
  // heap cell at its declaration so the closure shares the mutable location.
  match decl.body {
    case Some(FBBlock(blk)) -> {
      collectInLambdaNamesBlock(blk, fctx.hoistedVarNames)
    }
    case Some(FBExpr(e)) -> {
      collectInLambdaNamesExpr(e, fctx.hoistedVarNames)
    }
    case None -> {
    }
  }

  // Reserve the function epilogue label up-front so a `return` inside a
  // protected region can `leave` to it (see SReturn / #1477).  The epilogue
  // block is only emitted below when at least one return actually used it.
  fctx.epilogueLabel = freshLabelMsil(fctx)

  // FFI: a function carrying `@externTarget("Type.Member")` synthesises
  // its body from the BCL target (#370 / Phase R6).  Falls through to
  // the normal body lowering when the annotation is absent or the
  // resolver returns None (e.g. extern types in the signature).
  val externEmitted = if hasExternTargetMsil(decl.annotations) {
    emitExternTargetBody(cctx, fctx, insns, decl, pkgName)
  } else {
    false
  }

  if not externEmitted {
    // Lower the body.
    match decl.body {
      case Some(body) -> {
        match body {
          case FBBlock(block) -> {
            // Two-way dispatch: non-void keeps trailing value; void discards.
            if retTy != MVoid {
              // The block's trailing expression is the implicit return, so expect
              // the declared return type — a tail `newList()` (e.g.
              // `func f(): List[String] { newList() }`) builds the concrete
              // instance the return signature requires.  Intermediate statements
              // push/pop their own collExpect on top, so only the tail inherits it.
              pushCollExpect(fctx, retTy)
              val trailTy = lowerBlockExprMsil(cctx, fctx, insns, block)
              popCollExpect(fctx)
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
            pushCollExpect(fctx, retTy)
            lowerExprMsil(cctx, fctx, insns, e)
            popCollExpect(fctx)
            insns.add(MRet)
          }
        }
      }
      case None -> {
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
  if hasCaps {
    paramTypes.add(MArray(elemTy = MObject))
  }
  var pi2 = 0
  while pi2 < decl.params.count {
    if isLambdaFn {
      paramTypes.add(MObject)
    } else if fnGenerics.count > 0 {
      // Generic function (#2557): a `slice[T]` / bare-`T` parameter is emitted
      // as plain `object` in the signature so a List-backed argument matches the
      // slot; the body uses the IList slice path, never genuine array ops.
      paramTypes.add(typeExprToMsilGenSig(cctx, decl.params[pi2].ty, pkgName, fnGenerics))
    } else {
      // Non-generic free function: the parameter signature uses the ctx-aware
      // concrete encoding (`Option[String]` → `Option`1<String>`, a record →
      // its real TypeRef), matching the F# emitter, this function's own body
      // slot type (`typeExprToMsilCtx` at the param-slot registration above),
      // and the cross-package call REFERENCE (`registerRestoredFunc` /
      // `registerStdlibFunc`, both `…WithCtx`).  The context-free
      // `typeExprToMsil` erased a reference-typed param to `object`, so a
      // self-hosted-built function with such a param did not bind from another
      // assembly (MissingMethodException).  Generic functions stay on the
      // `typeExprToMsilGenSig` branch above (the consumer skips them entirely).
      paramTypes.add(typeExprToMsilCtx(cctx, decl.params[pi2].ty, pkgName))
    }
    pi2 = pi2 + 1
  }

  MFunc(
    flags = 0x0016,
    // Public | Static | HideBySig
    name = decl.name,
    params = byrefWrapSigTypes(decl.params, paramTypes),
    ret = retTy,
    insns = insns,
    maxStack = computeMaxStackMsil(insns),
    locals = fctx.locals
  )
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
pub func lowerImplMethodMsil(
  cctx: in CodegenCtx, decl: in FunctionDecl, pkgName: in String, targetTypeName: in String
): MFunc {
  // The method SIGNATURE keeps the legacy erased return type (generic / class
  // returns lower to `object`) so the emitted MethodDef matches the interface
  // slot and every existing cross-assembly consumer reference.
  val retTy = match decl.ret { case Some(te) -> typeExprToMsilCtx(cctx, te, pkgName); case None -> MVoid }
  // …but `declaredRetTy` (used purely for union-case construction inference,
  // not the signature) resolves CTX-AWARE so a generic return like
  // `Result[String, E]` carries its full `MGenericInst` with concrete type
  // args.  The body's `return Ok(x)` infers the case-class type arguments from
  // `declaredRetTy` for the slots its value argument can't cover (the error
  // slot `E`).  With the legacy erased `object` the construction baked
  // `Result_Ok<String, object>`, while a cross-package consumer's `match`
  // expected `Result_Ok<String, E>` — the closed generic types differed and
  // `isinst` never matched, panicking "match not exhaustive" (#1602).
  val declaredRetTyCtx = match decl.ret { case Some(te) -> typeExprToMsilCtx(cctx, te, pkgName); case None -> MVoid }
  // paramCount = 1 (this) + declared params.  emitLoadSlot/emitStoreSlot
  // distinguish params from locals by comparing slot indices against this.
  // Use targetTypeName (e.g. "Pkg.EnglishGreeter") as className so that
  // `self.method()` dispatch via MClass(fctx.className) resolves to the
  // correct methodTokens key.
  val fctx = makeFuncCtxMsil(pkgName, targetTypeName, decl.name, 1 + decl.params.count, declaredRetTyCtx)
  fctx.slotTicker.add(0)  // slot 0 = this, no name binding

  val insns: List[MInsn] = newList()

  // Allocate slots 1..N for user parameters.
  var pi = 0
  while pi < decl.params.count {
    val p = decl.params[pi]
    // Body tracking must be CTX-aware: a `List[Int]` param is a concrete
    // `List<int32>` instance at run time, so the body's `log.add(99)` must emit
    // `List<int32>::Add(int32)`, not the legacy `List<object>::Add(object)` —
    // the latter, called on a `List<int32>`, corrupts memory (different backing
    // layout) and segfaults.  The method SIGNATURE still uses the erased
    // `typeExprToMsil` below so the MethodDef matches the interface slot.
    val paramTy = typeExprToMsilCtx(cctx, p.ty, pkgName)
    val slot = fctx.slotTicker.count  // 1, 2, …
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
      case _ -> {
      }
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
            // The tail expression is the implicit return: expect the CTX-aware
            // return type (`declaredRetTyCtx`), not the erased signature `retTy`,
            // so a tail `newList()` builds the concrete `List<Foo>` the caller
            // (which tracks the return type concretely) expects to read.
            pushCollExpect(fctx, declaredRetTyCtx)
            val _ = lowerBlockExprMsil(cctx, fctx, insns, block)
            popCollExpect(fctx)
          } else {
            lowerBlockMsil(cctx, fctx, insns, block)
          }
          if not endsWithReturnMsil(insns) {
            insns.add(MRet)
          }
        }
        case FBExpr(e) -> {
          pushCollExpect(fctx, declaredRetTyCtx)
          lowerExprMsil(cctx, fctx, insns, e)
          popCollExpect(fctx)
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
    paramTypes.add(typeExprToMsilCtx(cctx, decl.params[pi2].ty, pkgName))
    pi2 = pi2 + 1
  }

  // Public | Virtual | HideBySig — no NewSlot/Final so CLR wires the
  // concrete method to the interface slot by name-matching, matching the
  // pattern used in msil_self_test_m11.l.
  val instanceFlags = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG

  MFunc(
    flags = instanceFlags,
    name = decl.name,
    params = byrefWrapSigTypes(decl.params, paramTypes),
    ret = retTy,
    insns = insns,
    maxStack = computeMaxStackMsil(insns),
    locals = fctx.locals
  )
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
// Collect the type-parameter names (GPType only) of an optional GenericParams,
// in declaration order (#2362 / docs/43).  Value/const generics (GPValue) are
// skipped — they are specialised by the monomorphizer, not reified as CLI
// generic parameters.
pub func genericNamesOf(gp: in Option[GenericParams]): List[String] {
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

// The CLR-canonical name of an in-bundle generic type: its plain FQN plus the
// arity suffix (`Pkg.Box` + arity 1 → `Pkg.Box`1`), matching the .NET naming
// convention the lowering layer stamps onto the TypeDef (#2362).  The generic
// by-name instructions (MGenericInstByName / MNewobjGenericByName /
// MCastclassGeneric / MLdfldGeneric) carry this suffixed form so their lowering
// resolves against the suffixed TypeDef; codegen maps stay keyed by the plain
// FQN, recovered via `stripGenericArity`.
func genericBacktickFqn(plainFqn: in String, arity: in Int): String {
  plainFqn + "`" + toString(arity)
}

// Drop a trailing `\`N` arity suffix from a generic type FQN, recovering the
// plain FQN used as the codegen map key (`Pkg.Box`1` → `Pkg.Box`).  Returns the
// input unchanged when there is no suffix.
func stripGenericArity(fqn: in String): String {
  val bt = fqn.lastIndexOf("`")
  if bt < 0 {
    fqn
  } else {
    fqn.substring(0, bt)
  }
}

// Index of `name` in `generics`, or -1 if absent.
func genericIndexOf(generics: in List[String], name: in String): Int {
  var i = 0
  while i < generics.count {
    if generics[i] == name {
      return i
    }
    i = i + 1
  }
  -1
}

// Generics-aware field/parameter type lowering (#2362).  A bare type reference
// whose last segment is one of the enclosing type's parameters lowers to
// ELEMENT_TYPE_VAR (`MTypeVar(index)`); everything else delegates to the legacy
// `typeExprToMsil`.  Used for the fields of an in-bundle generic record/union so
// `value: T` encodes `FIELD VAR(0)` (`06 13 00`), byte-matching the F# emitter.
func typeExprToMsilG(cctx: in CodegenCtx, te: in TypeExpr, pkgName: in String, generics: in List[String]): MsilType {
  match te.kind {
    case TRef(path) -> {
      val seg = lastSegmentMsil(path)
      val idx = genericIndexOf(generics, seg)
      if idx >= 0 {
        MTypeVar(index = idx)
      } else {
        typeExprToMsilCtx(cctx, te, pkgName)
      }
    }
    case TParen(inner) -> typeExprToMsilG(cctx, inner, pkgName, generics)
    case _ -> typeExprToMsilCtx(cctx, te, pkgName)
  }
}

// True when `te` mentions one of the enclosing generic-function's type
// parameters as its (terminal-segment) name — i.e. it is a bare type variable
// like `T`.  Used to decide whether a parameter/return/local must use the
// erased generic-slice representation (#2557).
func isGenericTypeVar(te: in TypeExpr, generics: in List[String]): Bool {
  match te.kind {
    case TRef(path) -> genericIndexOf(generics, lastSegmentMsil(path)) >= 0
    case TParen(inner) -> isGenericTypeVar(inner, generics)
    case _ -> false
  }
}

// Generic-function BODY-tracking type lowering (#2557).  Inside a generic
// function a bare type variable `T` and a `slice[T]` cannot name a concrete CLR
// type, so they reuse the List-backed slice representation that #2558 made the
// non-generic slice path route through: a `slice[T]` value is tracked as
// `MArray(MObject)` so `.length` / indexing / `for` dispatch through the
// (already-correct) non-generic `IList`/`ICollection` path, and a bare `T` is
// tracked as `MObject` (the erased element).  Element reads therefore yield
// `object` (no `castclass` to the non-existent `Pkg.T`), matching the erased
// runtime value.  Non-type-variable annotations delegate to the legacy
// context-aware lowering so a generic function over concrete types is unaffected.
func typeExprToMsilGenBody(
  cctx: in CodegenCtx, te: in TypeExpr, pkgName: in String, generics: in List[String]
): MsilType {
  match te.kind {
    case TRef(_) -> {
      if isGenericTypeVar(te, generics) {
        MObject
      } else {
        typeExprToMsilCtx(cctx, te, pkgName)
      }
    }
    case TSlice(elem) -> {
      if isGenericTypeVar(elem, generics) {
        MArray(elemTy = MObject)
      } else {
        typeExprToMsilCtx(cctx, te, pkgName)
      }
    }
    case TParen(inner) -> typeExprToMsilGenBody(cctx, inner, pkgName, generics)
    case _ -> typeExprToMsilCtx(cctx, te, pkgName)
  }
}

// Generic-function SIGNATURE type lowering (#2557).  A bare type variable `T`
// or `slice[T]` parameter/return is emitted as plain `object` in the method
// signature so a List-backed argument value (the runtime representation of a
// slice) matches the parameter slot directly — the body never performs genuine
// array ops on it, so the `object[]` shape would be a lie that buys nothing.
// Non-type-variable annotations delegate to the legacy (erasure) signature
// lowering, preserving every existing signature byte.
func typeExprToMsilGenSig(cctx: in CodegenCtx, te: in TypeExpr, pkgName: in String, generics: in List[String]): MsilType {
  match te.kind {
    case TRef(_) -> {
      if isGenericTypeVar(te, generics) {
        MObject
      } else {
        typeExprToMsilCtx(cctx, te, pkgName)
      }
    }
    case TSlice(elem) -> {
      if isGenericTypeVar(elem, generics) {
        MObject
      } else {
        typeExprToMsilCtx(cctx, te, pkgName)
      }
    }
    case TParen(inner) -> typeExprToMsilGenSig(cctx, inner, pkgName, generics)
    case _ -> typeExprToMsilCtx(cctx, te, pkgName)
  }
}

// Field type for a record/union case field on the PRODUCER side (the TypeDef
// FieldDef and the `.ctor` parameter, both emitted by `lowerMRecord` /
// `lowerMUnion`).
//
// Non-generic: ctx-aware `typeExprToMsilCtx` for concrete List/Map fields (DEF matches REF; D-progress-469). Generic: context-free `typeExprToMsilG` so fields erase to object (#2845; D-progress-469).
func recordFieldMsilType(cctx: in CodegenCtx, te: in TypeExpr, pkgName: in String, generics: in List[String]): MsilType {
  if generics.count > 0 {
    typeExprToMsilG(cctx, te, pkgName, generics)
  } else {
    typeExprToMsilCtx(cctx, te, pkgName)
  }
}

pub func lowerRecordMsil(cctx: in CodegenCtx, decl: in RecordDecl, pkgName: in String): MRecord {
  val className = pkgName + "." + decl.name
  val generics = genericNamesOf(decl.generics)

  val fields: List[MField] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMField(f) -> {
        fields.add(
          MField(
            // ECMA-335 §II.23.1.5: 0x0006 = Public, 0x0001 = Private,
            // 0x0000 = PrivateScope.  Previous code used 0x0001 (Private,
            // not PrivateScope as an earlier comment claimed); cross-package
            // ldfld then raised FieldAccessException (#1183 Phase 3, #1199).
            // Mirrors FDA_PUBLIC re-exported by Msil.Lowering.
            flags = 0x0006,
            name = f.name,
            fieldType = recordFieldMsilType(cctx, f.ty, pkgName, generics)
          )
        )
      }
      case _ -> {
      }
    }
    i = i + 1
  }

  val methods: List[MFunc] = newList()
  MRecord(
    className = className,
    namespace = pkgName,
    baseClass = "System.Object",
    fields = fields,
    methods = methods,
    useDefaultCtor = false,
    generics = generics
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// §10. Union lowering.
// ─────────────────────────────────────────────────────────────────────────────
pub func lowerUnionMsil(cctx: in CodegenCtx, decl: in UnionDecl, pkgName: in String): MUnion {
  val baseName = pkgName + "." + decl.name
  val generics = genericNamesOf(decl.generics)

  val cases: List[MUnionCase] = newList()
  var i = 0
  while i < decl.cases.count {
    val c = decl.cases[i]
    // #2363 Stage 4: emit the case-class TypeDef as `Union_Case` (matching F#).
    val caseName = baseName + "_" + c.name
    val caseFields: List[MField] = newList()
    var fi = 0
    while fi < c.fields.count {
      match c.fields[fi] {
        case UFNamed(name, ty, _) -> {
          caseFields.add(MField(flags = FDA_PUBLIC, name = name, fieldType = recordFieldMsilType(cctx, ty, pkgName, generics)))
        }
        case UFPos(ty, _) -> {
          caseFields.add(
            MField(
              flags = FDA_PUBLIC,
              name = "field" + toString(fi),
              fieldType = recordFieldMsilType(cctx, ty, pkgName, generics)
            )
          )
        }
      }
      fi = fi + 1
    }
    // In-bundle generic unions are reified (#2362): every case re-declares the
    // union's full type-parameter list (matching the F# emitter — `Option_Some`
    // and `Option_None` both carry `[T]`), and type-parameter fields lower to
    // VAR(n) via typeExprToMsilG.
    cases.add(MUnionCase(name = caseName, fields = caseFields, generics = generics))
    i = i + 1
  }

  val methods: List[MFunc] = newList()
  MUnion(baseName = baseName, namespace = pkgName, cases = cases, methods = methods, generics = generics)
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
  if glob == "*" {
    return true
  }
  if glob == name {
    return true
  }
  // Simple linear scan for * wildcard.
  var gi = 0
  var ni = 0
  while gi < glob.length and ni < name.length {
    val gc = glob[gi]
    if gc == '*' {
      // Consume the star then try each remaining position in name.
      gi = gi + 1
      if gi >= glob.length {
        return true
      }
      while ni < name.length {
        if globMatchMsil(glob.substring(gi), name.substring(ni)) {
          return true
        }
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
    case AMNameIn(names, _) -> nameListContains(names, fn.name)
    case AMAnnotated(annotName, _) -> hasAnnotationMsil(fn.annotations, annotName)
    case AMVisibility(vis, _) -> {
      match vis {
        case "pub" -> match fn.visibility { case Some(v) -> match v { case VisPub(_) -> true; case _ -> false }; case None -> false }
        case _ -> true
      }
    }
    case AMSignatureReturns(_, _) -> true
  }  // bootstrap: skip return-type glob
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
      if ann.args.count == 0 {
        return true
      }
      // Targeted `@no_aspect(Name1, Name2, …)` → opt out only when
      // `aspectName` is in the arg list.  Both `AAName` and `ABare`
      // are accepted; only the leading identifier portion matters.
      var j = 0
      while j < ann.args.count {
        val argName = match ann.args[j] { case AAName(n, _, _) -> n; case ABare(n, _) -> n; case ALiteral(_, _) -> "" }
        if argName == aspectName {
          return true
        }
        j = j + 1
      }
    }
    i = i + 1
  }
  false
}

// Check whether a function matches an aspect (all matchers AND, not in exceptNames).
func matchesAspectMsil(aspect: in AspectDecl, fn: in FunctionDecl): Bool {
  if isOptedOutMsil(fn, aspect.name) {
    return false
  }
  var ei = 0
  while ei < aspect.exceptNames.count {
    if aspect.exceptNames[ei] == fn.name {
      return false
    }
    ei = ei + 1
  }
  if aspect.matches.count == 0 {
    return false
  }
  var mi = 0
  while mi < aspect.matches.count {
    if not matchesAspectMatcherMsil(aspect.matches[mi], fn) {
      return false
    }
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
  val sp = makeSpan(initialPosition(), initialPosition())
  val seg: List[String] = newList()
  seg.add(name)
  val mp = ModulePath(segments = seg, span = sp)
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
    span = makeSpan(initialPosition(), initialPosition())
  )
}

func isProceedCallMsil(expr: in Expr): Bool {
  match expr.kind {
    case ECall(f, _) -> {
      match f.kind {
        case EPath(path) -> path.segments.count == 1 and path.segments[0] == "proceed"
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
        case EPath(path) -> path.segments.count == 1 and path.segments[0] == "proceed" and args.count > 0
        case _ -> false
      }
    }
    case _ -> false
  }
}

func rewriteProceedExprMsil(targetFuncName: in String, paramNames: in List[String], expr: in Expr): Expr {
  if isProceedCallWithArgsMsil(expr) {
    panic(
      "Msil.Codegen: proceed(...) with explicit arguments is not supported by the bootstrap aspect weaver; the wrapper's own parameter list is always forwarded.  Drop the arguments or wait for the v1.x weaver (#1141)."
    )
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
      Expr(kind = ECall(fn = rewriteProceedExprMsil(targetFuncName, paramNames, f), args = newArgs), span = s)
    }
    case EParen(inner) -> Expr(kind = EParen(inner = rewriteProceedExprMsil(targetFuncName, paramNames, inner)), span = s)
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
    case EAwait(inner) -> Expr(kind = EAwait(inner = rewriteProceedExprMsil(targetFuncName, paramNames, inner)), span = s)
    case EYield(inner) -> Expr(kind = EYield(inner = rewriteProceedExprMsil(targetFuncName, paramNames, inner)), span = s)
    case ESpawn(inner) -> Expr(kind = ESpawn(inner = rewriteProceedExprMsil(targetFuncName, paramNames, inner)), span = s)
    case ETry(inner) -> Expr(kind = ETry(inner = rewriteProceedExprMsil(targetFuncName, paramNames, inner)), span = s)
    case EOld(inner) -> Expr(kind = EOld(inner = rewriteProceedExprMsil(targetFuncName, paramNames, inner)), span = s)
    case EPropagate(inner) -> Expr(kind = EPropagate(inner = rewriteProceedExprMsil(targetFuncName, paramNames, inner)), span = s)
    case EPrefix(op, operand) -> Expr(kind = EPrefix(op = op, operand = rewriteProceedExprMsil(targetFuncName, paramNames, operand)), span = s)
    case EBinop(op, l, r) -> Expr(kind = EBinop(op = op, lhs = rewriteProceedExprMsil(targetFuncName, paramNames, l), rhs = rewriteProceedExprMsil(targetFuncName, paramNames, r)), span = s)
    case EAssign(t, op, v) -> Expr(kind = EAssign(target = rewriteProceedExprMsil(targetFuncName, paramNames, t), op = op, value = rewriteProceedExprMsil(targetFuncName, paramNames, v)), span = s)
    case EMember(recv, n) -> Expr(kind = EMember(receiver = rewriteProceedExprMsil(targetFuncName, paramNames, recv), memberName = n), span = s)
    case EIndex(recv, idxs) -> {
      val newIdxs: List[Expr] = newList()
      var i = 0
      while i < idxs.count {
        newIdxs.add(rewriteProceedExprMsil(targetFuncName, paramNames, idxs[i]))
        i = i + 1
      }
      Expr(kind = EIndex(receiver = rewriteProceedExprMsil(targetFuncName, paramNames, recv), indices = newIdxs), span = s)
    }
    case ETypeApp(f, targs) -> Expr(kind = ETypeApp(fn = rewriteProceedExprMsil(targetFuncName, paramNames, f), args = targs), span = s)
    case EIf(cond, thenB, elseB, form) -> {
      val newElse = match elseB {
        case None -> None
        case Some(e) -> Some(value = rewriteProceedEOBMsil(targetFuncName, paramNames, e))
      }
      Expr(
        kind = EIf(
          cond = rewriteProceedExprMsil(targetFuncName, paramNames, cond),
          thenBranch = rewriteProceedEOBMsil(targetFuncName, paramNames, thenB),
          elseBranch = newElse,
          thenForm = form
        ),
        span = s
      )
    }
    case EMatch(scrut, arms) -> Expr(kind = EMatch(scrutinee = rewriteProceedExprMsil(targetFuncName, paramNames, scrut), arms = rewriteProceedMatchArmsMsil(targetFuncName, paramNames, arms)), span = s)
    case ELambda(lparams, body) -> Expr(kind = ELambda(lambdaParams = lparams, body = rewriteProceedBlockMsil(targetFuncName, paramNames, body)), span = s)
    case EBlock(blk) -> Expr(kind = EBlock(block = rewriteProceedBlockMsil(targetFuncName, paramNames, blk)), span = s)
    case EUnsafe(blk) -> Expr(kind = EUnsafe(block = rewriteProceedBlockMsil(targetFuncName, paramNames, blk)), span = s)
    case EInterpolated(segs) -> {
      val newSegs: List[InterpolatedSegment] = newList()
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISText(t, sp) -> newSegs.add(ISText(text = t, span = sp))
          case ISExpr(e) -> newSegs.add(ISExpr(expr = rewriteProceedExprMsil(targetFuncName, paramNames, e)))
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
    case CAPositional(v) -> CAPositional(expr = rewriteProceedExprMsil(targetFuncName, paramNames, v))
    case CANamed(n, v, span) -> CANamed(name = n, value = rewriteProceedExprMsil(targetFuncName, paramNames, v), span = span)
  }
}

func rewriteProceedEOBMsil(targetFuncName: in String, paramNames: in List[String], eob: in ExprOrBlock): ExprOrBlock {
  match eob {
    case EOBBlock(blk) -> EOBBlock(block = rewriteProceedBlockMsil(targetFuncName, paramNames, blk))
    case EOBExpr(e) -> EOBExpr(expr = rewriteProceedExprMsil(targetFuncName, paramNames, e))
  }
}

func rewriteProceedMatchArmsMsil(
  targetFuncName: in String, paramNames: in List[String], arms: in List[MatchArm]
): List[MatchArm] {
  val newArms: List[MatchArm] = newList()
  var i = 0
  while i < arms.count {
    val a = arms[i]
    val newGuard = match a.guard {
      case Some(g) -> Some(value = rewriteProceedExprMsil(targetFuncName, paramNames, g))
      case None -> None
    }
    newArms.add(
      MatchArm(
        pattern = a.pattern,
        guard = newGuard,
        body = rewriteProceedEOBMsil(targetFuncName, paramNames, a.body),
        span = a.span
      )
    )
    i = i + 1
  }
  newArms
}

func rewriteProceedBindingMsil(targetFuncName: in String, paramNames: in List[String], b: in LocalBinding): LocalBinding {
  match b {
    case LBVal(pat, ty, init) -> LBVal(pat = pat, ty = ty, init = rewriteProceedExprMsil(targetFuncName, paramNames, init))
    case LBVar(name, ty, optInit) -> {
      val newInit = match optInit {
        case None -> None
        case Some(e) -> Some(value = rewriteProceedExprMsil(targetFuncName, paramNames, e))
      }
      LBVar(name = name, ty = ty, init = newInit)
    }
    case LBLet(name, ty, init) -> LBLet(name = name, ty = ty, init = rewriteProceedExprMsil(targetFuncName, paramNames, init))
  }
}

func rewriteProceedStmtMsil(targetFuncName: in String, paramNames: in List[String], stmt: in Statement): Statement {
  val s = stmt.span
  match stmt.kind {
    case SExpr(e) -> Statement(kind = SExpr(expr = rewriteProceedExprMsil(targetFuncName, paramNames, e)), span = s)
    case SReturn(opt) -> {
      val newOpt = match opt {
        case None -> None
        case Some(e) -> Some(value = rewriteProceedExprMsil(targetFuncName, paramNames, e))
      }
      Statement(kind = SReturn(value = newOpt), span = s)
    }
    case SLocal(binding) -> Statement(kind = SLocal(binding = rewriteProceedBindingMsil(targetFuncName, paramNames, binding)), span = s)
    case SAssign(t, op, v) -> Statement(kind = SAssign(target = rewriteProceedExprMsil(targetFuncName, paramNames, t), op = op, value = rewriteProceedExprMsil(targetFuncName, paramNames, v)), span = s)
    case SThrow(e) -> Statement(kind = SThrow(expr = rewriteProceedExprMsil(targetFuncName, paramNames, e)), span = s)
    case SFor(lbl, pat, iter, body) -> Statement(kind = SFor(label = lbl, pat = pat, iter = rewriteProceedExprMsil(targetFuncName, paramNames, iter), body = rewriteProceedBlockMsil(targetFuncName, paramNames, body)), span = s)
    case SWhile(lbl, cond, body) -> Statement(kind = SWhile(label = lbl, cond = rewriteProceedExprMsil(targetFuncName, paramNames, cond), body = rewriteProceedBlockMsil(targetFuncName, paramNames, body)), span = s)
    case SLoop(lbl, body) -> Statement(kind = SLoop(label = lbl, body = rewriteProceedBlockMsil(targetFuncName, paramNames, body)), span = s)
    case SScope(b, body) -> Statement(kind = SScope(binding = b, body = rewriteProceedBlockMsil(targetFuncName, paramNames, body)), span = s)
    case STry(body, catches, finally_) -> {
      val newBody = rewriteProceedBlockMsil(targetFuncName, paramNames, body)
      val newCatches: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        val cc = catches[i]
        newCatches.add(
          CatchClause(
            typeName = cc.typeName,
            bindName = cc.bindName,
            body = rewriteProceedBlockMsil(targetFuncName, paramNames, cc.body),
            span = cc.span
          )
        )
        i = i + 1
      }
      val newFinally = match finally_ {
        case None -> None
        case Some(fb) -> Some(rewriteProceedBlockMsil(targetFuncName, paramNames, fb))
      }
      Statement(kind = STry(body = newBody, catches = newCatches, finally_ = newFinally), span = s)
    }
    case SDefer(body) -> Statement(kind = SDefer(body = rewriteProceedBlockMsil(targetFuncName, paramNames, body)), span = s)
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
func buildAspectWrapperMsil(
  originalFn: in FunctionDecl, aspect: in AspectDecl, targetFuncName: in String
): Option[FunctionDecl] {
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
        docComments = newList(),
        annotations = originalFn.annotations,
        visibility = originalFn.visibility,
        isAsync = false,
        name = originalFn.name,
        generics = None,
        params = originalFn.params,
        ret = originalFn.ret,
        whereClause = None,
        contracts = originalFn.contracts,
        body = makeSomeFBBlock(wrapperBody),
        span = originalFn.span
      )
      Some(wrapper)
    }
  }
}

// Rename a function decl (returns a new decl with a different name).
func renameFuncMsil(fn: in FunctionDecl, newName: in String): FunctionDecl {
  FunctionDecl(
    docComments = fn.docComments,
    annotations = fn.annotations,
    visibility = fn.visibility,
    isAsync = fn.isAsync,
    name = newName,
    generics = fn.generics,
    params = fn.params,
    ret = fn.ret,
    whereClause = fn.whereClause,
    contracts = fn.contracts,
    body = fn.body,
    span = fn.span
  )
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
      case _ -> {
      }
    }
    ai = ai + 1
  }

  if aspects.count == 0 {
    return file  // nothing to do
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
              case None -> {
              }
              case Some(_) -> {
                val targetName = "__aspect_target_" + toString(asp) + "_" + fn.name
                val renamedFn = renameFuncMsil(fn, targetName)
                val renamedItem = Item(
                  docComments = item.docComments,
                  annotations = item.annotations,
                  visibility = item.visibility,
                  kind = IFunc(decl = renamedFn),
                  span = item.span
                )
                newItems.add(renamedItem)
                match buildAspectWrapperMsil(fn, aspect, targetName) {
                  case Some(wrapper) -> {
                    val wrapperItem = Item(
                      docComments = item.docComments,
                      annotations = item.annotations,
                      visibility = item.visibility,
                      kind = IFunc(decl = wrapper),
                      span = item.span
                    )
                    newItems.add(wrapperItem)
                  }
                  case None -> {
                  }
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
      case IAspect(_) -> {
      }  // drop aspect declarations from the output
      case _ -> newItems.add(item)
    }
    ii = ii + 1
  }

  SourceFile(
    moduleDoc = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = file.imports,
    items = newItems,
    span = file.span
  )
}

// ── Protected type body desugaring ───────────────────────────────────────────
// Bare field references inside a protected type entry/func body are written as
// `EPath([fieldName])` by the parser.  The F# bootstrap emitter rewrites these
// to `EMember(ESelf, fieldName)` via `desugarSelfFields` before codegen.  The
// self-hosted path performs the equivalent rewrite here, guided by the set of
// field names declared in the protected type.
//
// Structure mirrors alias_rewriter.l — early returns per arm avoid the
// bootstrap emitter's match-expression union-variant inference bug (#1170).
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
          case CANamed(name, value, span) -> args2.add(CANamed(name = name, value = desugarProtectedExpr(fieldNames, value), span = span))
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
    case EPropagate(inner) -> return Expr(kind = EPropagate(inner = desugarProtectedExpr(fieldNames, inner)), span = e.span)
    case EAssign(target, op, value) -> return Expr(
      kind = EAssign(
        target = desugarProtectedExpr(fieldNames, target),
        op = op,
        value = desugarProtectedExpr(fieldNames, value)
      ),
      span = e.span
    )
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
    // Recurse into lambda body, await, and spawn expressions so protected-type
    // field references inside them are correctly desugared (#3128).
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
    case SAssign(target, op, value) -> return Statement(
      kind = SAssign(
        target = desugarProtectedExpr(fieldNames, target),
        op = op,
        value = desugarProtectedExpr(fieldNames, value)
      ),
      span = s.span
    )
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
    case SWhile(label, cond, body) -> return Statement(
      kind = SWhile(
        label = label,
        cond = desugarProtectedExpr(fieldNames, cond),
        body = desugarProtectedBlock(fieldNames, body)
      ),
      span = s.span
    )
    case SFor(label, pat, iter, body) -> return Statement(
      kind = SFor(
        label = label,
        pat = pat,
        iter = desugarProtectedExpr(fieldNames, iter),
        body = desugarProtectedBlock(fieldNames, body)
      ),
      span = s.span
    )
    case SThrow(expr) -> return Statement(kind = SThrow(expr = desugarProtectedExpr(fieldNames, expr)), span = s.span)
    case STry(body, catches, finally_) -> {
      val cs: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        cs.add(
          CatchClause(
            typeName = catches[i].typeName,
            bindName = catches[i].bindName,
            body = desugarProtectedBlock(fieldNames, catches[i].body),
            span = catches[i].span
          )
        )
        i = i + 1
      }
      val fn = match finally_ { case Some(blk) -> Some(value = desugarProtectedBlock(fieldNames, blk)); case None -> None }
      return Statement(
        kind = STry(body = desugarProtectedBlock(fieldNames, body), catches = cs, finally_ = fn),
        span = s.span
      )
    }
    case SLoop(label, body) -> return Statement(kind = SLoop(label = label, body = desugarProtectedBlock(fieldNames, body)), span = s.span)
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

func desugarProtectedFuncDecl(fieldNames: in Map[String, Bool], fn: in FunctionDecl): FunctionDecl {
  val newBody = match fn.body {
    case Some(b) -> Some(value = desugarProtectedFuncBody(fieldNames, b))
    case None -> None
  }
  FunctionDecl(
    docComments = fn.docComments,
    annotations = fn.annotations,
    visibility = fn.visibility,
    isAsync = fn.isAsync,
    name = fn.name,
    generics = fn.generics,
    params = fn.params,
    ret = fn.ret,
    whereClause = fn.whereClause,
    contracts = fn.contracts,
    body = newBody,
    span = fn.span
  )
}

func makeProtectedFieldNames(decl: in ProtectedTypeDecl): Map[String, Bool] {
  val result: Map[String, Bool] = newMap()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case PMField(pf) -> {
        match pf {
          case PFVar(name, _, _, _) -> result.add(name, true)
          case PFLet(name, _, _, _) -> result.add(name, true)
          case PFImmutable(f) -> result.add(f.name, true)
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  result
}

// ── Protected type lowering ───────────────────────────────────────────────────
// Lower an IProtected declaration to a sealed class with Monitor-based entry locking.
// Each PMEntry becomes a public method that acquires Monitor(this), runs the body in
// a try block, and releases Monitor(this) in the finally handler.
// Using `this` as the lock object avoids an extra field: every CLR object has a
// built-in sync-block, and `lock (this)` is the canonical per-instance pattern.
func lowerProtectedMsil(
  cctx: in CodegenCtx,
  decl: in ProtectedTypeDecl,
  pkgName: in String,
  items: in List[MPackageItem],
  fns: in List[MFunc],
): Unit {
  val typeFqn = pkgName + "." + decl.name

  // Build Monitor.Enter(object) and Monitor.Exit(object) MemberRef tokens.
  // These are registered lazily here so they appear in the MemberRef table only
  // when at least one protected type is compiled (not unconditionally).
  // System.Threading.Monitor lives in System.Threading, not System.Runtime
  // (it is not type-forwarded through System.Runtime in .NET 10+).
  val arThreading = ctxAddAssemblyRef(cctx.lctx, "System.Threading", 10, 0)
  val trMonitor = ctxAddTypeRef(cctx.lctx, "System.Threading", "Monitor", arThreading)
  val enterPs: List[MsilType] = newList()
  enterPs.add(MObject)
  val tokEnter = 0x0A000000 +
    ctxAddMemberRef(cctx.lctx, trMonitor, "Enter", "monitor_enter", buildStaticMethodSig(enterPs, MVoid))
  val exitPs: List[MsilType] = newList()
  exitPs.add(MObject)
  val tokExit = 0x0A000000 +
    ctxAddMemberRef(cctx.lctx, trMonitor, "Exit", "monitor_exit", buildStaticMethodSig(exitPs, MVoid))

  val recFields: List[MField] = newList()
  val recMethods: List[MFunc] = newList()
  // Collect field names once so the desugar pass can rewrite bare field
  // references in entry/func bodies to EMember(ESelf, name).
  val fieldNames = makeProtectedFieldNames(decl)

  var mi = 0
  while mi < decl.members.count {
    match decl.members[mi] {
      case PMField(pf) -> {
        match pf {
          case PFVar(name, ty, _, _) -> {
            recFields.add(MField(flags = FDA_PUBLIC, name = name, fieldType = typeExprToMsilCtx(cctx, ty, pkgName)))
          }
          case PFLet(name, ty, _, _) -> {
            recFields.add(
              MField(flags = FDA_PUBLIC + FDA_INIT_ONLY, name = name, fieldType = typeExprToMsilCtx(cctx, ty, pkgName))
            )
          }
          case PFImmutable(f) -> {
            recFields.add(
              MField(flags = FDA_PUBLIC + FDA_INIT_ONLY, name = f.name, fieldType = typeExprToMsilCtx(cctx, f.ty, pkgName))
            )
          }
        }
      }
      case PMEntry(ed) -> {
        // Entry method: acquires Monitor(this) before the body and releases it in
        // a finally handler so the lock is released on any exit path.
        // Note: `entry` is a Lyric reserved keyword so we bind to `ed` here.
        val pTypes: List[MsilType] = newList()
        var pi = 0
        while pi < ed.params.count {
          pTypes.add(typeExprToMsilCtx(cctx, ed.params[pi].ty, pkgName))
          pi = pi + 1
        }
        val retTy = match ed.ret { case Some(te) -> typeExprToMsilCtx(cctx, te, pkgName); case None -> MVoid }
        // paramCount = 1 (this) + declared params, matching lowerImplMethodMsil.
        val entryFctx = makeFuncCtxMsil(pkgName, typeFqn, ed.name, 1 + ed.params.count, retTy)
        // Reserve slot 0 for the implicit `this` receiver (no name binding).
        entryFctx.slotTicker.add(0)
        var epi = 0
        while epi < ed.params.count {
          val p = ed.params[epi]
          // Body tracking is CTX-aware so a collection param is operated on
          // concretely (same fix as `lowerImplMethodMsil` — a non-ctx `List[Int]`
          // tracked as `MObject` emits `List<object>` ops on a real `List<int32>`
          // and segfaults).  The signature (`pTypes` above) stays erased.
          val paramTy = typeExprToMsilCtx(cctx, p.ty, pkgName)
          val slot = entryFctx.slotTicker.count  // 1, 2, … (slot 0 = this)
          entryFctx.slots.add(p.name, slot)
          entryFctx.types.add(p.name, paramTy)
          entryFctx.slotTicker.add(0)
          epi = epi + 1
        }
        // Desugar bare field references in the body to EMember(ESelf, fieldName)
        // so lowerExprMsil/lowerStmtMsil can emit ldarg.0 + ldfld/stfld.
        val desugaredEntryBody = desugarProtectedFuncBody(fieldNames, ed.body)
        val entryInsns: List[MInsn] = newList()

        // Monitor.Enter(this): acquire the per-instance lock.
        entryInsns.add(MLdarg(slot = 0))
        entryInsns.add(MCall(methodToken = tokEnter))

        // Open the try region.
        val tryStartL = freshLabelMsil(entryFctx)
        val afterL = freshLabelMsil(entryFctx)
        entryInsns.add(MLabel(id = tryStartL))
        entryFctx.tryRegionStack.add(0)
        // Set epilogueLabel BEFORE lowering the body so that any explicit `return`
        // statement inside the try region can stash its value (via retvalSlot) and
        // `leave` to afterL instead of emitting an illegal bare `ret` inside a
        // protected region (#1499 / SReturn case in lowerStmtMsil).
        entryFctx.epilogueLabel = afterL

        // Shared helper: emit the try/finally EH structure and afterL epilogue.
        // Inlined per arm since each arm builds its own finallyStart/End labels.
        match desugaredEntryBody {
          case FBBlock(block) -> {
            if retTy != MVoid {
              // Non-void block body.  Lower the block; if it fell through normally
              // the result is on the stack — stash it to retvalSlot and leave.
              // If it ended with an explicit `return` (epilogueUsed > 0), SReturn
              // already stashed the value and emitted leave(afterL); skip the
              // fall-through path so we don't try to store a void stack value.
              val _ = lowerBlockExprMsil(cctx, entryFctx, entryInsns, block)
              if entryFctx.epilogueUsed.count == 0 {
                if entryFctx.retvalSlot < 0 {
                  entryFctx.retvalSlot = allocSlotMsil(entryFctx, "__retval", retTy)
                }
                emitStoreSlot(entryInsns, entryFctx.retvalSlot, entryFctx.paramCount)
                entryInsns.add(MLeave(label = afterL))
              }
              val finallyStartL = freshLabelMsil(entryFctx)
              val finallyEndL = freshLabelMsil(entryFctx)
              entryInsns.add(MLabel(id = finallyStartL))
              entryInsns.add(MLdarg(slot = 0))
              entryInsns.add(MCall(methodToken = tokExit))
              entryInsns.add(MEndfinally)
              entryInsns.add(MLabel(id = finallyEndL))
              entryInsns.add(
                MEHClause(
                  flags = 2,
                  tryStart = tryStartL,
                  tryEnd = finallyStartL,
                  handlerStart = finallyStartL,
                  handlerEnd = finallyEndL,
                  catchToken = 0
                )
              )
              entryInsns.add(MLabel(id = afterL))
              if entryFctx.retvalSlot >= 0 {
                emitLoadSlot(entryInsns, entryFctx.retvalSlot, entryFctx.paramCount)
              }
              entryInsns.add(MRet)
            } else {
              // Void block body.
              lowerBlockMsil(cctx, entryFctx, entryInsns, block)
              if entryFctx.epilogueUsed.count == 0 {
                entryInsns.add(MLeave(label = afterL))
              }
              val finallyStartL = freshLabelMsil(entryFctx)
              val finallyEndL = freshLabelMsil(entryFctx)
              entryInsns.add(MLabel(id = finallyStartL))
              entryInsns.add(MLdarg(slot = 0))
              entryInsns.add(MCall(methodToken = tokExit))
              entryInsns.add(MEndfinally)
              entryInsns.add(MLabel(id = finallyEndL))
              entryInsns.add(
                MEHClause(
                  flags = 2,
                  tryStart = tryStartL,
                  tryEnd = finallyStartL,
                  handlerStart = finallyStartL,
                  handlerEnd = finallyEndL,
                  catchToken = 0
                )
              )
              entryInsns.add(MLabel(id = afterL))
              entryInsns.add(MRet)
            }
          }
          case FBExpr(e) -> {
            // Expression body: expressions cannot contain SReturn, so no epilogue
            // escape is possible.  Lower the expression, stash the result, leave.
            lowerExprMsil(cctx, entryFctx, entryInsns, e)
            if entryFctx.retvalSlot < 0 {
              entryFctx.retvalSlot = allocSlotMsil(entryFctx, "__retval", retTy)
            }
            emitStoreSlot(entryInsns, entryFctx.retvalSlot, entryFctx.paramCount)
            entryInsns.add(MLeave(label = afterL))
            val finallyStartL = freshLabelMsil(entryFctx)
            val finallyEndL = freshLabelMsil(entryFctx)
            entryInsns.add(MLabel(id = finallyStartL))
            entryInsns.add(MLdarg(slot = 0))
            entryInsns.add(MCall(methodToken = tokExit))
            entryInsns.add(MEndfinally)
            entryInsns.add(MLabel(id = finallyEndL))
            entryInsns.add(
              MEHClause(
                flags = 2,
                tryStart = tryStartL,
                tryEnd = finallyStartL,
                handlerStart = finallyStartL,
                handlerEnd = finallyEndL,
                catchToken = 0
              )
            )
            entryInsns.add(MLabel(id = afterL))
            if entryFctx.retvalSlot >= 0 {
              emitLoadSlot(entryInsns, entryFctx.retvalSlot, entryFctx.paramCount)
            }
            entryInsns.add(MRet)
          }
        }
        entryFctx.tryRegionStack.removeAt(entryFctx.tryRegionStack.count - 1)

        recMethods.add(
          MFunc(
            flags = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG,
            name = ed.name,
            params = pTypes,
            ret = retTy,
            insns = entryInsns,
            maxStack = computeMaxStackMsil(entryInsns),
            locals = entryFctx.locals
          )
        )
      }
      case PMFunc(fn) -> {
        // Desugar bare field references in the func body then lower as an
        // instance method (lowerImplMethodMsil sets paramCount = 1 + params,
        // reserves slot 0 for `this`, and handles ESelf/EMember correctly).
        val desugaredFn = desugarProtectedFuncDecl(fieldNames, fn)
        val mf = lowerImplMethodMsil(cctx, desugaredFn, pkgName, typeFqn)
        recMethods.add(
          MFunc(
            flags = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG,
            name = mf.name,
            params = mf.params,
            ret = mf.ret,
            insns = mf.insns,
            maxStack = mf.maxStack,
            locals = mf.locals
          )
        )
      }
      case PMInvariant(_) -> {
      }
    }
    mi = mi + 1
  }

  items.add(
    MPRecord(
      rec = MRecord(
        className = typeFqn,
        namespace = pkgName,
        baseClass = "System.Object",
        fields = recFields,
        methods = recMethods,
        useDefaultCtor = false,
        generics = newList()
      )
    )
  )
}

// ── Wire dependency extraction and topological sort ──────────────────────────
// Extract the set of wire member names that an expression directly references.
// Walks EPath nodes with a single segment; any name matching a known wire
// member name is recorded as a dependency.
func wireExprDepsMsil(e: in Expr, knownNames: in Map[String, Bool], acc: in List[String]): Unit {
  match e.kind {
    case EPath(path) -> {
      if path.segments.count == 1 {
        val name = path.segments[0]
        if knownNames.containsKey(name) {
          acc.add(name)
        }
      }
    }
    case ECall(fn, args) -> {
      wireExprDepsMsil(fn, knownNames, acc)
      var ai = 0
      while ai < args.count {
        match args[ai] {
          case CAPositional(expr) -> wireExprDepsMsil(expr, knownNames, acc)
          case CANamed(_, value, _) -> wireExprDepsMsil(value, knownNames, acc)
        }
        ai = ai + 1
      }
    }
    case EMember(receiver, _) -> wireExprDepsMsil(receiver, knownNames, acc)
    case EBlock(block) -> wireBlockDepsMsil(block, knownNames, acc)
    case EIf(cond, thenBranch, elseBranch, _) -> {
      wireExprDepsMsil(cond, knownNames, acc)
      wireExprOrBlockDepsMsil(thenBranch, knownNames, acc)
      match elseBranch {
        case Some(eb) -> wireExprOrBlockDepsMsil(eb, knownNames, acc)
        case None -> ()
      }
    }
    case EParen(inner) -> wireExprDepsMsil(inner, knownNames, acc)
    case EBinop(_, lhs, rhs) -> {
      wireExprDepsMsil(lhs, knownNames, acc)
      wireExprDepsMsil(rhs, knownNames, acc)
    }
    case EPrefix(_, operand) -> wireExprDepsMsil(operand, knownNames, acc)
    case _ -> ()
  }
}

func wireExprOrBlockDepsMsil(eob: in ExprOrBlock, knownNames: in Map[String, Bool], acc: in List[String]): Unit {
  match eob {
    case EOBExpr(expr) -> wireExprDepsMsil(expr, knownNames, acc)
    case EOBBlock(block) -> wireBlockDepsMsil(block, knownNames, acc)
  }
}

func wireBlockDepsMsil(blk: in Block, knownNames: in Map[String, Bool], acc: in List[String]): Unit {
  var si = 0
  while si < blk.statements.count {
    wireStmtDepsMsil(blk.statements[si], knownNames, acc)
    si = si + 1
  }
}

func wireStmtDepsMsil(s: in Statement, knownNames: in Map[String, Bool], acc: in List[String]): Unit {
  match s.kind {
    case SExpr(expr) -> wireExprDepsMsil(expr, knownNames, acc)
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init) -> wireExprDepsMsil(init, knownNames, acc)
        case LBLet(_, _, init) -> wireExprDepsMsil(init, knownNames, acc)
        case LBVar(_, _, initOpt) -> match initOpt { case Some(init) -> wireExprDepsMsil(init, knownNames, acc); case None -> () }
      }
    }
    case SAssign(target, _, value) -> {
      wireExprDepsMsil(target, knownNames, acc)
      wireExprDepsMsil(value, knownNames, acc)
    }
    case SReturn(valOpt) -> match valOpt { case Some(e) -> wireExprDepsMsil(e, knownNames, acc); case None -> () }
    case _ -> ()
  }
}

// Result of wire topological sort.
union WireTopoResult {
  case WTRSorted(members: List[WireMember])
  case WTRCycle(path: List[String])
}

// Extract the init expression from a WireMember (None for members with no init).
func wireMemberInitMsil(m: in WireMember): Option[Expr] {
  match m {
    case WMSingleton(_, _, init, _) -> Some(value = init)
    case WMLocal(_, _, init, _) -> Some(value = init)
    case WMScoped(_, _, _, init, _) -> Some(value = init)
    case WMBind(_, provider, _) -> Some(value = provider)
    case WMProvided(_, _, _) -> None
    case WMExpose(_, _) -> None
  }
}

// Name of a WireMember, or "" for unnamed members.
func wireMemberNameMsil(m: in WireMember): String {
  match m {
    case WMSingleton(name, _, _, _) -> name
    case WMLocal(name, _, _, _) -> name
    case WMScoped(_, name, _, _, _) -> name
    case WMBind(iface, _, _) -> match iface.kind { case TRef(path) -> lastSegmentMsil(path); case _ -> "__bind" }
    case WMProvided(name, _, _) -> name
    case WMExpose(name, _) -> name
  }
}

// Topologically sort wire members by their init-expression dependencies using
// Kahn's BFS algorithm.  Returns WTRSorted with members in dependency order,
// or WTRCycle with the names of members involved in the cycle.
// WMExpose members are separated out before sorting (they have no init of
// their own and share a name with the member they expose) and re-appended at
// the end.  WMProvided members have zero in-degree and sort to the front.
func wireTopoSortMsil(members: in List[WireMember]): WireTopoResult {
  // Separate expose members — they are pass-through and must not participate
  // in the dep graph (they share names with sortable members, which would
  // cause duplicate-key crashes and false cycle detection).
  val sortable: List[WireMember] = newList()
  val exposeMembers: List[WireMember] = newList()
  var sep = 0
  while sep < members.count {
    match members[sep] {
      case WMExpose(_, _) -> exposeMembers.add(members[sep])
      case _ -> sortable.add(members[sep])
    }
    sep = sep + 1
  }

  // Build name → member index and known-name set.
  val nameToIdx: Map[String, Int] = newMap()
  val knownNames: Map[String, Bool] = newMap()
  var i = 0
  while i < sortable.count {
    val n = wireMemberNameMsil(sortable[i])
    if n.length > 0 and not nameToIdx.containsKey(n) {
      nameToIdx.add(n, i)
      knownNames.add(n, true)
    }
    i = i + 1
  }

  // Build adjacency list: name → list of dependency names (deps it references).
  val depsOf: Map[String, List[String]] = newMap()
  var j = 0
  while j < sortable.count {
    val n = wireMemberNameMsil(sortable[j])
    val initDeps: List[String] = newList()
    match wireMemberInitMsil(sortable[j]) {
      case Some(e) -> {
        val raw: List[String] = newList()
        wireExprDepsMsil(e, knownNames, raw)
        var di = 0
        while di < raw.count {
          if raw[di] != n {
            initDeps.add(raw[di])
          }
          di = di + 1
        }
      }
      case None -> ()
    }
    if not depsOf.containsKey(n) {
      depsOf.add(n, initDeps)
    }
    j = j + 1
  }

  // Compute in-degree for sortable members only.
  val inDegree: Map[String, Int] = newMap()
  var k = 0
  while k < sortable.count {
    val n = wireMemberNameMsil(sortable[k])
    if not inDegree.containsKey(n) {
      inDegree.add(n, 0)
    }
    k = k + 1
  }
  var m2 = 0
  while m2 < sortable.count {
    // WMProvided has no init; skip so it keeps in-degree 0 and sorts first.
    match wireMemberInitMsil(sortable[m2]) {
      case None -> ()
      case Some(_) -> {
        val n = wireMemberNameMsil(sortable[m2])
        match mapGet(depsOf, n) {
          case Some(dList) -> {
            val seen: Map[String, Bool] = newMap()
            var di = 0
            while di < dList.count {
              val dep = dList[di]
              if not seen.containsKey(dep) {
                seen.add(dep, true)
                match mapGet(inDegree, n) {
                  case Some(cur) -> {
                    inDegree.remove(n)
                    inDegree.add(n, cur + 1)
                  }
                  case None -> inDegree.add(n, 1)
                }
              }
              di = di + 1
            }
          }
          case None -> ()
        }
      }
    }
    m2 = m2 + 1
  }

  // Kahn's BFS: start with all sortable nodes with in-degree 0.
  val queue: List[String] = newList()
  var qi = 0
  while qi < sortable.count {
    val n = wireMemberNameMsil(sortable[qi])
    match mapGet(inDegree, n) {
      case Some(deg) -> {
        if deg == 0 {
          queue.add(n)
        }
      }
      case None -> queue.add(n)
    }
    qi = qi + 1
  }

  val sortedNames: List[String] = newList()
  var head = 0
  while head < queue.count {
    val current = queue[head]
    sortedNames.add(current)
    var ri = 0
    while ri < sortable.count {
      val rn = wireMemberNameMsil(sortable[ri])
      match mapGet(depsOf, rn) {
        case Some(dList) -> {
          var found = false
          var dj = 0
          while dj < dList.count {
            if dList[dj] == current {
              found = true
            }
            dj = dj + 1
          }
          if found {
            match mapGet(inDegree, rn) {
              case Some(deg) -> {
                val newDeg = deg - 1
                inDegree.remove(rn)
                inDegree.add(rn, newDeg)
                if newDeg == 0 {
                  queue.add(rn)
                }
              }
              case None -> ()
            }
          }
        }
        case None -> ()
      }
      ri = ri + 1
    }
    head = head + 1
  }

  // Cycle detection compares against sortable (not total) member count.
  if sortedNames.count < sortable.count {
    val sortedSet: Map[String, Bool] = newMap()
    var si = 0
    while si < sortedNames.count {
      sortedSet.add(sortedNames[si], true)
      si = si + 1
    }
    val cyclePath: List[String] = newList()
    var ci = 0
    while ci < sortable.count {
      val cn = wireMemberNameMsil(sortable[ci])
      if not sortedSet.containsKey(cn) {
        cyclePath.add(cn)
      }
      ci = ci + 1
    }
    return WTRCycle(path = cyclePath)
  }

  // Reassemble in sorted order, then append expose members.
  val sorted: List[WireMember] = newList()
  var sni = 0
  while sni < sortedNames.count {
    val sn = sortedNames[sni]
    match mapGet(nameToIdx, sn) {
      case Some(idx) -> sorted.add(sortable[idx])
      case None -> ()
    }
    sni = sni + 1
  }
  var ei = 0
  while ei < exposeMembers.count {
    sorted.add(exposeMembers[ei])
    ei = ei + 1
  }
  WTRSorted(members = sorted)
}

// ── Wire block lowering ───────────────────────────────────────────────────────
// Lower a wire block to a static factory class with a `<wireName>_create()`
// method that instantiates the dependency graph in topological order.
// Supported member kinds:
//   singleton / local — evaluated once, stored as a local
//   scoped[X]         — AsyncLocal<T>-backed scoping deferred to #2972
//   bind I -> impl    — impl evaluated and stored under interface's simple name
//   @provided n: T    — becomes a parameter of the create() function
//   expose n          — loads n and leaves it on the stack for return
func lowerWireMsil(
  cctx: in CodegenCtx,
  decl: in WireDecl,
  pkgName: in String,
  items: in List[MPackageItem],
  fns: in List[MFunc],
): Unit {
  // Topologically sort members and detect dependency cycles before emitting code.
  val sortedMembers: List[WireMember] = match wireTopoSortMsil(decl.members) {
    case WTRSorted(sm) -> sm
    case WTRCycle(path) -> {
      val cycleStr = if path.count > 0 { path[0] } else { "<unknown>" }
      panic("W0001: wire '" + decl.name + "' has a dependency cycle involving: " + cycleStr)
    }
  }

  // Pre-pass: collect @provided members to determine the factory's param count.
  val providedNames: List[String] = newList()
  val providedTypes: List[MsilType] = newList()
  var fpi = 0
  while fpi < sortedMembers.count {
    match sortedMembers[fpi] {
      case WMProvided(pname, pty, _) -> {
        providedNames.add(pname)
        providedTypes.add(typeExprToMsilCtx(cctx, pty, pkgName))
      }
      case _ -> {
      }
    }
    fpi = fpi + 1
  }

  val providedCount = providedNames.count
  val createInsns: List[MInsn] = newList()
  val createFctx = makeFuncCtxMsil(pkgName, pkgName, "__wire_create", providedCount, MObject)

  // Register provided parameters as argument slots (0..providedCount-1) so that
  // init expressions in subsequent members can reference them by name.
  var ppi = 0
  while ppi < providedCount {
    val pSlot = createFctx.slotTicker.count
    createFctx.slots.add(providedNames[ppi], pSlot)
    createFctx.types.add(providedNames[ppi], providedTypes[ppi])
    createFctx.slotTicker.add(0)
    ppi = ppi + 1
  }

  var mi = 0
  while mi < sortedMembers.count {
    match sortedMembers[mi] {
      case WMProvided(_, _, _) -> {
        // Already registered as a param above; no instructions needed.
      }
      case WMSingleton(name, ty, init, _) -> {
        val localTy = typeExprToMsilCtx(cctx, ty, pkgName)
        val localSlot = allocSlotMsil(createFctx, name, localTy)
        lowerExprMsil(cctx, createFctx, createInsns, init)
        createInsns.add(MStloc(slot = localSlot - createFctx.paramCount))
      }
      case WMLocal(name, ty, init, _) -> {
        val localTy = match ty { case Some(t) -> typeExprToMsilCtx(cctx, t, pkgName); case None -> MObject }
        val localSlot = allocSlotMsil(createFctx, name, localTy)
        lowerExprMsil(cctx, createFctx, createInsns, init)
        createInsns.add(MStloc(slot = localSlot - createFctx.paramCount))
      }
      case WMScoped(_, memberName, _, _, _) -> {
        // AsyncLocal<T>-backed scoping is deferred to #2972.  A scoped member that
        // is also exposed (WMExpose) would silently emit ldnull because its name is
        // never added to createFctx.slots.  Fail loudly here so the gap (#2972) is
        // caught at build time rather than manifesting as a NullReferenceException
        // at the call site.
        panic(
          "Msil.Codegen: wire block member '" + memberName +
            "' uses WMScoped, which is not yet implemented (see issue #2972). " +
            "Remove the `scoped` modifier or avoid exposing this member until #2972 ships."
        )
      }
      case WMBind(iface, provider, _) -> {
        // Evaluate the provider and store it under the interface's simple name
        // so subsequent member inits can reference the bound value by that name.
        val ifaceName = match iface.kind { case TRef(path) -> lastSegmentMsil(path); case _ -> "__bind" }
        val localTy = typeExprToMsilCtx(cctx, iface, pkgName)
        val localSlot = allocSlotMsil(createFctx, ifaceName, localTy)
        lowerExprMsil(cctx, createFctx, createInsns, provider)
        createInsns.add(MStloc(slot = localSlot - createFctx.paramCount))
      }
      case WMExpose(name, _) -> {
        match mapGet(createFctx.slots, name) {
          case Some(slot) -> {
            emitLoadSlot(createInsns, slot, createFctx.paramCount)
          }
          case None -> {
            createInsns.add(MLdNull)
          }
        }
      }
    }
    mi = mi + 1
  }
  createInsns.add(MRet)

  val createParams: List[MsilType] = newList()
  var cpi = 0
  while cpi < providedCount {
    createParams.add(providedTypes[cpi])
    cpi = cpi + 1
  }

  fns.add(
    MFunc(
      flags = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG,
      name = decl.name + "_create",
      params = createParams,
      ret = MObject,
      insns = createInsns,
      maxStack = computeMaxStackMsil(createInsns),
      locals = createFctx.locals
    )
  )
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
    case None -> {
      val seg: List[String] = newList()
      seg.add("Object")
      TypeExpr(kind = TRef(path = ModulePath(segments = seg, span = syntheticSpan())), span = syntheticSpan())
    }
  }
  val noAnns: List[Annotation] = newList()
  Param(mode = PMIn, modeExplicit = true, name = lp.name, ty = ty, dflt = None, annotations = noAnns, span = lp.span)
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
      val retTy: Option[TypeExpr] = Some(
        TypeExpr(
          kind = TRef(path = ModulePath(segments = retSeg, span = syntheticSpan())),
          span = syntheticSpan()
        )
      )
      val decl = FunctionDecl(
        docComments = newList(),
        annotations = newList(),
        visibility = None,
        isAsync = false,
        name = lname,
        generics = None,
        params = params,
        ret = retTy,
        whereClause = None,
        contracts = newList(),
        body = Some(FBBlock(block = body)),
        span = syntheticSpan()
      )
      synths.add(
        Item(
          docComments = newList(),
          annotations = newList(),
          visibility = None,
          kind = IFunc(decl = decl),
          span = syntheticSpan()
        )
      )
      deferred.add(body)
    }
    case ECall(fn, args) -> {
      collectLambdasBfsExpr(fn, ticker, synths, deferred)
      var ai = 0
      while ai < args.count {
        match args[ai] {
          case CAPositional(ex) -> {
            collectLambdasBfsExpr(ex, ticker, synths, deferred)
          }
          case CANamed(_, ex, _) -> {
            collectLambdasBfsExpr(ex, ticker, synths, deferred)
          }
        }
        ai = ai + 1
      }
    }
    case EBinop(_, lhs, rhs) -> {
      collectLambdasBfsExpr(lhs, ticker, synths, deferred)
      collectLambdasBfsExpr(rhs, ticker, synths, deferred)
    }
    case EPrefix(_, operand) -> {
      collectLambdasBfsExpr(operand, ticker, synths, deferred)
    }
    case EParen(inner) -> {
      collectLambdasBfsExpr(inner, ticker, synths, deferred)
    }
    case EMember(recv, _) -> {
      collectLambdasBfsExpr(recv, ticker, synths, deferred)
    }
    case EIf(cond, thenB, elseOpt, _) -> {
      collectLambdasBfsExpr(cond, ticker, synths, deferred)
      match thenB {
        case EOBExpr(ex) -> {
          collectLambdasBfsExpr(ex, ticker, synths, deferred)
        }
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
            case EOBExpr(ex) -> {
              collectLambdasBfsExpr(ex, ticker, synths, deferred)
            }
            case EOBBlock(blk) -> {
              var ei = 0
              while ei < blk.statements.count {
                collectLambdasBfsStmt(blk.statements[ei], ticker, synths, deferred)
                ei = ei + 1
              }
            }
          }
        }
        case None -> {
        }
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
          case EOBExpr(ex) -> {
            collectLambdasBfsExpr(ex, ticker, synths, deferred)
          }
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
    case EAwait(inner) -> {
      collectLambdasBfsExpr(inner, ticker, synths, deferred)
    }
    case EYield(inner) -> {
      collectLambdasBfsExpr(inner, ticker, synths, deferred)
    }
    case ESpawn(inner) -> {
      collectLambdasBfsExpr(inner, ticker, synths, deferred)
    }
    case ETry(inner) -> {
      collectLambdasBfsExpr(inner, ticker, synths, deferred)
    }
    case EPropagate(inner) -> {
      collectLambdasBfsExpr(inner, ticker, synths, deferred)
    }
    case EAssign(_, _, v) -> {
      collectLambdasBfsExpr(v, ticker, synths, deferred)
    }
    case EInterpolated(segs) -> {
      var si = 0
      while si < segs.count {
        match segs[si] {
          case ISExpr(ex) -> {
            collectLambdasBfsExpr(ex, ticker, synths, deferred)
          }
          case _ -> {
          }
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
    case ETypeApp(fn, _) -> {
      collectLambdasBfsExpr(fn, ticker, synths, deferred)
    }
    case _ -> {
    }
  }
}

func collectLambdasBfsStmt(s: in Statement, ticker: in List[Int], synths: in List[Item], deferred: in List[Block]): Unit {
  match s.kind {
    case SLocal(binding) -> match binding { case LBVal(_, _, init) -> { collectLambdasBfsExpr(init, ticker, synths, deferred) }; case LBLet(_, _, init) -> { collectLambdasBfsExpr(init, ticker, synths, deferred) }; case LBVar(_, _, initOpt) -> match initOpt { case Some(init) -> { collectLambdasBfsExpr(init, ticker, synths, deferred) }; case None -> {  } } }
    case SAssign(_, _, v) -> {
      collectLambdasBfsExpr(v, ticker, synths, deferred)
    }
    case SReturn(valOpt) -> match valOpt { case Some(e) -> { collectLambdasBfsExpr(e, ticker, synths, deferred) }; case None -> {  } }
    case SExpr(e) -> {
      collectLambdasBfsExpr(e, ticker, synths, deferred)
    }
    case SThrow(e) -> {
      collectLambdasBfsExpr(e, ticker, synths, deferred)
    }
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
        case None -> {
        }
        case Some(fb) -> {
          var fsi = 0
          while fsi < fb.statements.count {
            collectLambdasBfsStmt(fb.statements[fsi], ticker, synths, deferred)
            fsi = fsi + 1
          }
        }
      }
    }
    case SInvariant(e) -> {
      collectLambdasBfsExpr(e, ticker, synths, deferred)
    }
    case SRule(lhs, rhs) -> {
      collectLambdasBfsExpr(lhs, ticker, synths, deferred)
      collectLambdasBfsExpr(rhs, ticker, synths, deferred)
    }
    case _ -> {
    }
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
    if acc[i] == nm {
      return
    }
    i = i + 1
  }
  acc.add(nm)
}

func nameListContains(xs: in List[String], nm: in String): Bool {
  var i = 0
  while i < xs.count {
    if xs[i] == nm {
      return true
    }
    i = i + 1
  }
  false
}

func collectRefNamesExpr(e: in Expr, acc: in List[String]): Unit {
  match e.kind {
    case EPath(path) -> {
      if path.segments.count == 1 {
        addNameOnce(acc, path.segments[0])
      }
    }
    case ECall(fn, args) -> {
      collectRefNamesExpr(fn, acc)
      var ai = 0
      while ai < args.count {
        match args[ai] {
          case CAPositional(ex) -> {
            collectRefNamesExpr(ex, acc)
          }
          case CANamed(_, ex, _) -> {
            collectRefNamesExpr(ex, acc)
          }
        }
        ai = ai + 1
      }
    }
    case EBinop(_, lhs, rhs) -> {
      collectRefNamesExpr(lhs, acc)
      collectRefNamesExpr(rhs, acc)
    }
    case EPrefix(_, operand) -> {
      collectRefNamesExpr(operand, acc)
    }
    case EParen(inner) -> {
      collectRefNamesExpr(inner, acc)
    }
    case EMember(recv, _) -> {
      collectRefNamesExpr(recv, acc)
    }
    case EIf(cond, thenB, elseOpt, _) -> {
      collectRefNamesExpr(cond, acc)
      collectRefNamesOrdBlock(thenB, acc)
      match elseOpt {
        case Some(eb) -> collectRefNamesOrdBlock(eb, acc)
        case None -> {
        }
      }
    }
    case EBlock(block) -> {
      collectRefNamesBlock(block, acc)
    }
    case EUnsafe(block) -> {
      collectRefNamesBlock(block, acc)
    }
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
      while ei < exprs.count {
        collectRefNamesExpr(exprs[ei], acc)
        ei = ei + 1
      }
    }
    case ETuple(exprs) -> {
      var ei = 0
      while ei < exprs.count {
        collectRefNamesExpr(exprs[ei], acc)
        ei = ei + 1
      }
    }
    case EIndex(recv, indices) -> {
      collectRefNamesExpr(recv, acc)
      var ii = 0
      while ii < indices.count {
        collectRefNamesExpr(indices[ii], acc)
        ii = ii + 1
      }
    }
    case EAwait(inner) -> {
      collectRefNamesExpr(inner, acc)
    }
    case EYield(inner) -> {
      collectRefNamesExpr(inner, acc)
    }
    case ESpawn(inner) -> {
      collectRefNamesExpr(inner, acc)
    }
    case ETry(inner) -> {
      collectRefNamesExpr(inner, acc)
    }
    case EPropagate(inner) -> {
      collectRefNamesExpr(inner, acc)
    }
    case EAssign(target, _, v) -> {
      collectRefNamesExpr(target, acc)
      collectRefNamesExpr(v, acc)
    }
    case EInterpolated(segs) -> {
      var si = 0
      while si < segs.count {
        match segs[si] {
          case ISExpr(ex) -> {
            collectRefNamesExpr(ex, acc)
          }
          case _ -> {
          }
        }
        si = si + 1
      }
    }
    case ETypeApp(fn, _) -> {
      collectRefNamesExpr(fn, acc)
    }
    case ELambda(lparams, body) -> {
      // Collect refs from the nested lambda body into a scratch list, then
      // merge only those names that are NOT bound by the nested lambda's own
      // params — a nested param shadows the outer binding and is not a capture.
      val nestedRefs: List[String] = newList()
      collectRefNamesBlock(body, nestedRefs)
      var nri = 0
      while nri < nestedRefs.count {
        val ref = nestedRefs[nri]
        var isNestedParam = false
        var npi = 0
        while npi < lparams.count {
          if lparams[npi].name == ref {
            isNestedParam = true
          }
          npi = npi + 1
        }
        if not isNestedParam {
          acc.add(ref)
        }
        nri = nri + 1
      }
    }
    case _ -> {
    }
  }
}

func collectRefNamesOrdBlock(ob: in ExprOrBlock, acc: in List[String]): Unit {
  match ob {
    case EOBExpr(ex) -> {
      collectRefNamesExpr(ex, acc)
    }
    case EOBBlock(blk) -> {
      collectRefNamesBlock(blk, acc)
    }
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
    case SLocal(binding) -> match binding { case LBVal(_, _, init) -> { collectRefNamesExpr(init, acc) }; case LBLet(_, _, init) -> { collectRefNamesExpr(init, acc) }; case LBVar(_, _, initOpt) -> match initOpt { case Some(init) -> { collectRefNamesExpr(init, acc) }; case None -> {  } } }
    case SAssign(target, _, v) -> {
      collectRefNamesExpr(target, acc)
      collectRefNamesExpr(v, acc)
    }
    case SReturn(valOpt) -> match valOpt { case Some(e) -> { collectRefNamesExpr(e, acc) }; case None -> {  } }
    case SExpr(e) -> {
      collectRefNamesExpr(e, acc)
    }
    case SThrow(e) -> {
      collectRefNamesExpr(e, acc)
    }
    case SWhile(_, cond, body) -> {
      collectRefNamesExpr(cond, acc)
      collectRefNamesBlock(body, acc)
    }
    case SFor(_, _, iter, body) -> {
      collectRefNamesExpr(iter, acc)
      collectRefNamesBlock(body, acc)
    }
    case SLoop(_, body) -> {
      collectRefNamesBlock(body, acc)
    }
    case SScope(_, body) -> {
      collectRefNamesBlock(body, acc)
    }
    case SDefer(body) -> {
      collectRefNamesBlock(body, acc)
    }
    case STry(body, catches, finally_) -> {
      collectRefNamesBlock(body, acc)
      var ci = 0
      while ci < catches.count {
        collectRefNamesBlock(catches[ci].body, acc)
        ci = ci + 1
      }
      match finally_ {
        case Some(fb) -> {
          collectRefNamesBlock(fb, acc)
        }
        case None -> {
        }
      }
    }
    case SInvariant(e) -> {
      collectRefNamesExpr(e, acc)
    }
    case SRule(lhs, rhs) -> {
      collectRefNamesExpr(lhs, acc)
      collectRefNamesExpr(rhs, acc)
    }
    case _ -> {
    }
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
    case ELambda(_, body) -> {
      collectRefNamesBlock(body, acc)
    }
    case ECall(fn, args) -> {
      collectInLambdaNamesExpr(fn, acc)
      var ai = 0
      while ai < args.count {
        match args[ai] {
          case CAPositional(ex) -> {
            collectInLambdaNamesExpr(ex, acc)
          }
          case CANamed(_, ex, _) -> {
            collectInLambdaNamesExpr(ex, acc)
          }
        }
        ai = ai + 1
      }
    }
    case EBinop(_, lhs, rhs) -> {
      collectInLambdaNamesExpr(lhs, acc)
      collectInLambdaNamesExpr(rhs, acc)
    }
    case EPrefix(_, operand) -> {
      collectInLambdaNamesExpr(operand, acc)
    }
    case EParen(inner) -> {
      collectInLambdaNamesExpr(inner, acc)
    }
    case EMember(recv, _) -> {
      collectInLambdaNamesExpr(recv, acc)
    }
    case EIf(cond, thenB, elseOpt, _) -> {
      collectInLambdaNamesExpr(cond, acc)
      collectInLambdaNamesOrdBlock(thenB, acc)
      match elseOpt {
        case Some(eb) -> collectInLambdaNamesOrdBlock(eb, acc)
        case None -> {
        }
      }
    }
    case EBlock(block) -> {
      collectInLambdaNamesBlock(block, acc)
    }
    case EUnsafe(block) -> {
      collectInLambdaNamesBlock(block, acc)
    }
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
      while ei < exprs.count {
        collectInLambdaNamesExpr(exprs[ei], acc)
        ei = ei + 1
      }
    }
    case ETuple(exprs) -> {
      var ei = 0
      while ei < exprs.count {
        collectInLambdaNamesExpr(exprs[ei], acc)
        ei = ei + 1
      }
    }
    case EIndex(recv, indices) -> {
      collectInLambdaNamesExpr(recv, acc)
      var ii = 0
      while ii < indices.count {
        collectInLambdaNamesExpr(indices[ii], acc)
        ii = ii + 1
      }
    }
    case EAwait(inner) -> {
      collectInLambdaNamesExpr(inner, acc)
    }
    case EYield(inner) -> {
      collectInLambdaNamesExpr(inner, acc)
    }
    case ESpawn(inner) -> {
      collectInLambdaNamesExpr(inner, acc)
    }
    case ETry(inner) -> {
      collectInLambdaNamesExpr(inner, acc)
    }
    case EPropagate(inner) -> {
      collectInLambdaNamesExpr(inner, acc)
    }
    case EAssign(target, _, v) -> {
      collectInLambdaNamesExpr(target, acc)
      collectInLambdaNamesExpr(v, acc)
    }
    case EInterpolated(segs) -> {
      var si = 0
      while si < segs.count {
        match segs[si] {
          case ISExpr(ex) -> {
            collectInLambdaNamesExpr(ex, acc)
          }
          case _ -> {
          }
        }
        si = si + 1
      }
    }
    case ETypeApp(fn, _) -> {
      collectInLambdaNamesExpr(fn, acc)
    }
    case _ -> {
    }
  }
}

func collectInLambdaNamesOrdBlock(ob: in ExprOrBlock, acc: in List[String]): Unit {
  match ob {
    case EOBExpr(ex) -> {
      collectInLambdaNamesExpr(ex, acc)
    }
    case EOBBlock(blk) -> {
      collectInLambdaNamesBlock(blk, acc)
    }
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
    case SLocal(binding) -> match binding { case LBVal(_, _, init) -> { collectInLambdaNamesExpr(init, acc) }; case LBLet(_, _, init) -> { collectInLambdaNamesExpr(init, acc) }; case LBVar(_, _, initOpt) -> match initOpt { case Some(init) -> { collectInLambdaNamesExpr(init, acc) }; case None -> {  } } }
    case SAssign(target, _, v) -> {
      collectInLambdaNamesExpr(target, acc)
      collectInLambdaNamesExpr(v, acc)
    }
    case SReturn(valOpt) -> match valOpt { case Some(e) -> { collectInLambdaNamesExpr(e, acc) }; case None -> {  } }
    case SExpr(e) -> {
      collectInLambdaNamesExpr(e, acc)
    }
    case SThrow(e) -> {
      collectInLambdaNamesExpr(e, acc)
    }
    case SWhile(_, cond, body) -> {
      collectInLambdaNamesExpr(cond, acc)
      collectInLambdaNamesBlock(body, acc)
    }
    case SFor(_, _, iter, body) -> {
      collectInLambdaNamesExpr(iter, acc)
      collectInLambdaNamesBlock(body, acc)
    }
    case SLoop(_, body) -> {
      collectInLambdaNamesBlock(body, acc)
    }
    case SScope(_, body) -> {
      collectInLambdaNamesBlock(body, acc)
    }
    case SDefer(body) -> {
      collectInLambdaNamesBlock(body, acc)
    }
    case STry(body, catches, finally_) -> {
      collectInLambdaNamesBlock(body, acc)
      var ci = 0
      while ci < catches.count {
        collectInLambdaNamesBlock(catches[ci].body, acc)
        ci = ci + 1
      }
      match finally_ {
        case Some(fb) -> {
          collectInLambdaNamesBlock(fb, acc)
        }
        case None -> {
        }
      }
    }
    case SInvariant(e) -> {
      collectInLambdaNamesExpr(e, acc)
    }
    case SRule(lhs, rhs) -> {
      collectInLambdaNamesExpr(lhs, acc)
      collectInLambdaNamesExpr(rhs, acc)
    }
    case _ -> {
    }
  }
}

// Names a lambda body binds locally (so a same-named enclosing slot is shadowed,
// not captured): local bindings, `for`/`match`/`catch` pattern binds, and nested
// lambda parameters.  Patterns contribute their bound identifiers.
func collectBoundNamesPattern(p: in Pattern, acc: in List[String]): Unit {
  match p.kind {
    case PBinding(name, _) -> {
      addNameOnce(acc, name)
    }
    case PTuple(elems) -> {
      var i = 0
      while i < elems.count {
        collectBoundNamesPattern(elems[i], acc)
        i = i + 1
      }
    }
    case PConstructor(_, args) -> {
      var i = 0
      while i < args.count {
        collectBoundNamesPattern(args[i], acc)
        i = i + 1
      }
    }
    case _ -> {
    }
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
    case SLocal(binding) -> match binding { case LBVal(pat, _, _) -> { collectBoundNamesPattern(pat, acc) }; case LBLet(name, _, _) -> { addNameOnce(acc, name) }; case LBVar(name, _, _) -> { addNameOnce(acc, name) } }
    case SWhile(_, _, body) -> {
      collectBoundNamesBlock(body, acc)
    }
    case SFor(_, pat, _, body) -> {
      collectBoundNamesPattern(pat, acc)
      collectBoundNamesBlock(body, acc)
    }
    case SLoop(_, body) -> {
      collectBoundNamesBlock(body, acc)
    }
    case SScope(_, body) -> {
      collectBoundNamesBlock(body, acc)
    }
    case SDefer(body) -> {
      collectBoundNamesBlock(body, acc)
    }
    case STry(body, catches, finally_) -> {
      collectBoundNamesBlock(body, acc)
      var ci = 0
      while ci < catches.count {
        match catches[ci].bindName {
          case Some(nm) -> {
            addNameOnce(acc, nm)
          }
          case None -> {
          }
        }
        collectBoundNamesBlock(catches[ci].body, acc)
        ci = ci + 1
      }
      match finally_ {
        case Some(fb) -> {
          collectBoundNamesBlock(fb, acc)
        }
        case None -> {
        }
      }
    }
    case _ -> {
    }
  }
}

// Return the enclosing-scope variable names captured by a lambda.
pub func lambdaCaptureNamesMsil(fctx: in FuncCtx, lparams: in List[LambdaParam], body: in Block): List[String] {
  val refs: List[String] = newList()
  collectRefNamesBlock(body, refs)
  val bound: List[String] = newList()
  var p = 0
  while p < lparams.count {
    addNameOnce(bound, lparams[p].name)
    p = p + 1
  }
  collectBoundNamesBlock(body, bound)
  val caps: List[String] = newList()
  var i = 0
  while i < refs.count {
    val nm = refs[i]
    if not nameListContains(bound, nm) {
      if fctx.slots.containsKey(nm) {
        addNameOnce(caps, nm)
      } else if fctx.captureNameToIndex.containsKey(nm) {
        // Multi-level nesting: this lambda is itself inside another lambda.
        // The name is not a local slot of the outer lambda but is one of its
        // own captures.  Re-capture it so the inner lambda can read it via
        // its own __caps array (#1479).
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
              case FBExpr(e) -> {
                collectLambdasBfsExpr(e, ticker, synths, deferred)
              }
            }
          }
          case None -> {
          }
        }
      }
      case IVal(decl) -> {
        collectLambdasBfsExpr(decl.init, ticker, synths, deferred)
      }
      case IConst(decl) -> {
        collectLambdasBfsExpr(decl.init, ticker, synths, deferred)
      }
      case _ -> {
      }
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
    moduleDoc = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = file.imports,
    items = newItems,
    span = file.span
  )
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
      case _ -> {
      }
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
    case MBool -> 0x02
    case MChar -> 0x03
    case MByte -> 0x05
    case MInt -> 0x08
    case MLong -> 0x0A
    case MDouble -> 0x0D
    case MString -> 0x0E
    case MObject -> 0x1C
    case _ -> -1
  }
}

// Inverse: an ECMA element-type byte to its MsilType, or None when unsupported.
func elemByteToMsil(b: in Int): Option[MsilType] {
  if b == 0x01 {
    Some(value = MVoid)
  } else if b == 0x02 {
    Some(value = MBool)
  } else if b == 0x03 {
    Some(value = MChar)
  } else if b == 0x05 {
    Some(value = MByte)
  } else if b == 0x08 {
    Some(value = MInt)
  } else if b == 0x0A {
    Some(value = MLong)
  } else if b == 0x0D {
    Some(value = MDouble)
  } else if b == 0x0E {
    Some(value = MString)
  } else if b == 0x1C {
    Some(value = MObject)
  } else {
    None
  }
}

// The CLR FQN of an extern reference (`MClassRef`) or value (`MValueTypeRef`)
// type, or "" for any other MsilType.
func externRefFqn(t: in MsilType): String {
  match t {
    case MValueTypeRef(_, fqn) -> fqn
    case MClassRef(_, fqn) -> fqn
    case _ -> ""
  }
}

// True when the MsilType is a value-type extern ref (vs a class-type ref).
func msilIsValueTypeRef(t: in MsilType): Bool {
  match t {
    case MValueTypeRef(_, _) -> true
    case _ -> false
  }
}

// True when `t` is the CLR `System.DateTime` value type, routed through either
// the VALUETYPE (`MValueTypeRef`) or CLASS (`MClassRef`) encoding.  Used by the
// `toString` builtin to pin InvariantCulture formatting (#2184).
func isClrDateTimeMsil(t: in MsilType): Bool {
  match t {
    case MValueTypeRef(_, fqn) -> fqn == "System.DateTime"
    case MClassRef(_, fqn) -> fqn == "System.DateTime"
    case _ -> false
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
    case None -> if startsWith(clrFqn, "Lyric.Emitter") or startsWith(clrFqn, "Lyric.Stdlib") { "Lyric.Emitter" } else { "System.Runtime" }
  }
}

// Intern a TypeRef for the value type `fqn` (its owning assembly comes from the
// metadata index) and return the matching `MValueTypeRef`, or None when the
// type's assembly isn't indexed.
func internValueTypeRef(cctx: in CodegenCtx, fqn: in String): Option[MsilType] {
  match Mdr.assemblyForType(cctx.metadataTypeIndex, fqn) {
    case None -> None
    case Some(asm) -> {
      val sp = splitTypeFqn(fqn)
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
      val sp = splitTypeFqn(fqn)
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

// Map a decoded BCL member `SigType` to the `MsilType` used to build a
// TypeSpec-parented MemberRef signature for a generic declaring type — unlike
// `resolvedSigToMsil`, this preserves `STVar` as `MTypeVar` (ELEMENT_TYPE_VAR)
// and `STByRef` as `MByRef`, because a member of a generic type must reference
// its declaring type's generic parameters (`!0`/`!1`), per ECMA-335 §II.23.2.
// `STNamed` class/value types are interned as concrete refs (a non-generic
// parameter such as the `out int` of `Dictionary.TryGetValue` keeps its real
// type).  None for any shape the emitter can't encode (caller falls back).
func genericMemberSigToMsil(cctx: in CodegenCtx, sig: in Mdr.SigType): Option[MsilType] {
  // Each `Option`-producing arm assigns into a typed `var` rather than yielding
  // a `match` whose `None`/`Some` arms the bootstrap F# emitter would unify to
  // `Option<object>` (the same erasure that breaks `sig.paramTypes` elsewhere).
  match sig {
    case Mdr.STPrim(b) -> elemByteToMsil(b)
    case Mdr.STVar(i) -> Some(value = MTypeVar(index = i))
    case Mdr.STByRef(inner) -> {
      var res: Option[MsilType] = None
      match genericMemberSigToMsil(cctx, inner) {
        case Some(m) -> {
          res = Some(value = MByRef(inner = m))
        }
        case None -> {
        }
      }
      res
    }
    case Mdr.STSzArray(e) -> {
      var res: Option[MsilType] = None
      match genericMemberSigToMsil(cctx, e) {
        case Some(m) -> {
          res = Some(value = MArray(elemTy = m))
        }
        case None -> {
        }
      }
      res
    }
    case Mdr.STNamed(fqn, vt) -> if vt { internValueTypeRef(cctx, fqn) } else { internClassRef(cctx, fqn) }
    case _ -> None
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
    if fqn.length > 0 {
      Some(value = Mdr.mkNamedSig(fqn, msilIsValueTypeRef(t)))
    } else {
      None
    }
  }
}

// A stable key fragment identifying a resolved `SigType` (primitive byte or
// value/class FQN) so the MemberRef blob-intern key distinguishes overloads.
func sigTypeKeyFrag(sig: in Mdr.SigType): String {
  val pb = Mdr.sigPrimByte(sig)
  if pb >= 0 {
    "p" + toString(pb)
  } else {
    "n" + Mdr.sigNamedFqn(sig)
  }
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
  if cctx.metadataReady.count > 0 {
    return
  }
  cctx.metadataReady.add(true)
  match Mdr.refPackDir() {
    case None -> {
    }
    case Some(dir) -> {
      val asms = Mdr.enumRefAssemblies(dir)
      var i = 0
      while i < asms.count {
        // Single read + parse per assembly fills the type, path, and
        // value-type indexes in one pass (#2147).
        Mdr.addAssemblyToIndexesAndValueTypes(cctx.metadataTypeIndex, cctx.metadataPathIndex, cctx.metadataVtypeSet, asms[i])
        i = i + 1
      }
    }
  }
  // Phase 4: feed restored-dependency DLLs into the same indexes so types from
  // NuGet-restored assemblies (outside the BCL ref pack) are discoverable.
  // `SynthesisedArtifact.dllPath` is the on-disk path of the restored DLL;
  // an empty path means the artifact has no file (e.g. an in-memory-only entry).
  var ri = 0
  while ri < cctx.restoredArtifacts.count {
    val dllPath = cctx.restoredArtifacts[ri].dllPath
    if dllPath.length > 0 {
      Mdr.addAssemblyToIndexesAndValueTypes(cctx.metadataTypeIndex, cctx.metadataPathIndex, cctx.metadataVtypeSet, dllPath)
    }
    ri = ri + 1
  }
}

// Widening rank for the numeric element-type bytes the auto-FFI path maps to
// MsilTypes (-1 for non-numeric).  A narrower type implicitly converts to a
// wider one.
func elemNumericRank(b: in Int): Int {
  if b == 0x05 {
    1
  } else if b == 0x03 {
    // U1   (MByte)
    3
  } else if b == 0x08 {
    // CHAR (MChar)
    4
  } else if b == 0x0A {
    // I4   (MInt)
    5
  } else if b == 0x0D {
    // I8   (MLong)
    7
  } else {
    // R8   (MDouble)
    -1
  }
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
      Some(value = acc)  // exact: no coercion
    } else if paramByte == 0x1C {
      boxIfNeededMsil(cctx, acc, argTy)  // object param: box value types
      Some(value = acc)
    } else {
      val ra = elemNumericRank(argByte)
      val rp = elemNumericRank(paramByte)
      if ra < 0 or rp < 0 or ra > rp {
        None  // not a supported widening
      } else if paramByte == 0x0A {
        acc.add(MConvI8)  // → long
        Some(value = acc)
      } else if paramByte == 0x0D {
        acc.add(MConvR8)  // → double
        Some(value = acc)
      } else {
        None  // → R4 / narrower int: unsupported
      }
    }
  }
}

// Emit a metadata-resolved auto-FFI call, or None to fall back.  `argBufs`
// carry each argument's already-lowered IL; `argTys` their MsilTypes.
func emitResolvedAutoFfi(
  cctx: in CodegenCtx,
  insns: in List[MInsn],
  asmName: in String,
  clrFqn: in String,
  methodName: in String,
  argBufs: in List[List[MInsn]],
  argTys: in List[MsilType],
  m: in Mdr.ResolvedMethod,
): Option[MsilType] {
  // Auto-FFI's receiver is a type name, so only a static method can be called
  // this way; instance overloads need an @externTarget wrapper.
  if not m.isStatic {
    return None
  }
  if m.paramTypes.count != argTys.count {
    return None
  }
  // Build the parameter MsilTypes (from the resolved signature) and the
  // per-argument coercion (exact / widening conv / box) needed to adapt each
  // argument to its parameter.  Bail to the legacy path on any unsupported
  // parameter shape (non-primitive, or an unsupported conversion).
  val paramMsil: List[MsilType] = newList()
  val coercions: List[List[MInsn]] = newList()
  var pi = 0
  var ok = true
  while pi < m.paramTypes.count and ok {
    val psig = m.paramTypes[pi]
    match resolvedSigToMsil(cctx, psig) {
      case None -> {
        ok = false
      }
      case Some(pm) -> match argCoercionInsns(cctx, argTys[pi], psig) { case None -> { ok = false }; case Some(cins) -> { paramMsil.add(pm); coercions.add(cins) } }
    }
    pi = pi + 1
  }
  if not ok {
    return None
  }
  match resolvedSigToMsil(cctx, m.returnType) {
    case None -> None
    case Some(retMsil) -> {
      val sp = splitTypeFqn(clrFqn)
      val tRef = internFfiTypeRef(cctx, asmName, sp.ns, sp.name)
      val sig = buildStaticMethodSig(paramMsil, retMsil)
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
        appendInsnsMsil(insns, coercions[bi])  // exact: empty; widening: conv; object: box
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
  cctx: in CodegenCtx,
  insns: in List[MInsn],
  asmName: in String,
  clrFqn: in String,
  methodName: in String,
  argBufs: in List[List[MInsn]],
  argTys: in List[MsilType],
  m: in Mdr.ResolvedMethod,
): Option[MsilType] {
  val paramMsil: List[MsilType] = newList()
  val coercions: List[List[MInsn]] = newList()
  var pi = 0
  var ok = true
  while pi < m.paramTypes.count and ok {
    val psig = m.paramTypes[pi]
    match resolvedSigToMsil(cctx, psig) {
      case None -> {
        ok = false
      }
      case Some(pm) -> match argCoercionInsns(cctx, argTys[pi], psig) { case None -> { ok = false }; case Some(cins) -> { paramMsil.add(pm); coercions.add(cins) } }
    }
    pi = pi + 1
  }
  if not ok {
    return None
  }
  match resolvedSigToMsil(cctx, m.returnType) {
    case None -> None
    case Some(retMsil) -> {
      val sp = splitTypeFqn(clrFqn)
      val tRef = internFfiTypeRef(cctx, asmName, sp.ns, sp.name)
      val sig = buildInstanceMethodSig(paramMsil, retMsil)
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
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  fqn: in String,
  memberName: in String,
  args: in List[CallArg],
): Option[MsilType] {
  ensureMetadataIndex(cctx)
  val argBufs: List[List[MInsn]] = newList()
  val argTys: List[MsilType] = newList()
  val argSigs: List[Mdr.SigType] = newList()
  var ai = 0
  var bad = false
  while ai < args.count and not bad {
    val buf: List[MInsn] = newList()
    val t = lowerCallArgMsil(cctx, fctx, buf, args[ai])
    match argTyToSig(t) {
      case None -> {
        bad = true
      }
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
    match Mdr.resolveExtern(cctx.metadataTypeIndex, cctx.metadataPathIndex, fqn, memberName, argSigs) {
      case None -> None
      case Some(re) -> if re.sig.isStatic { None } else { emitResolvedInstanceAutoFfi(cctx, insns, re.assemblyName, fqn, memberName, argBufs, argTys, re.sig) }
    }
    // A receiver-based call needs an instance method; a resolved static
    // means the name only exists as a static — fall back rather than
    // emit a callvirt against a static (which would be malformed).
  }
}

// Try to resolve and emit an auto-FFI call from .NET metadata.  Returns the
// real result MsilType on success, or None to fall back to the legacy path.
// The owning assembly is found from the metadata-derived type→assembly index
// (built once over the reference pack and cached on `cctx`) via
// assemblyForTypeMsil, so resolution is accurate for types the old prefix
// table would mis-hint (e.g. `System.IO.Path` lives in `System.Runtime`).
func tryAutoFfiFromMetadata(
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  methodName: in String,
  args: in List[CallArg],
  clrFqn: in String,
): Option[MsilType] {
  ensureMetadataIndex(cctx)
  // Snapshot fctx counters before speculative argument lowering so we can roll
  // back orphan locals if a later argument triggers fallback.  The map fields
  // (slots, types) may retain stale entries for rolled-back names, but those
  // names are unique-per-count (every temp name embeds slotTicker.count at
  // allocation time) and will never be re-accessed after truncation.
  // INVARIANT: every speculative temp name MUST embed the live slotTicker count
  // at allocation time.  Any future temp that does NOT follow this convention
  // must explicitly remove its fctx.slots/fctx.types entries on rollback instead.
  val snapSlot = fctx.slotTicker.count
  val snapLabel = fctx.labelTicker.count
  val snapLocals = fctx.locals.count
  // Lower each argument into its own buffer, capturing IL + MsilType.
  val argBufs: List[List[MInsn]] = newList()
  val argTys: List[MsilType] = newList()
  val argSigs: List[Mdr.SigType] = newList()
  var ai = 0
  var bad = false
  while ai < args.count and not bad {
    val buf: List[MInsn] = newList()
    val t = lowerCallArgMsil(cctx, fctx, buf, args[ai])
    match argTyToSig(t) {
      case None -> {
        bad = true
      }  // unsupported argument type → legacy path
      case Some(s) -> {
        argBufs.add(buf)
        argTys.add(t)
        argSigs.add(s)
      }
    }
    ai = ai + 1
  }
  if bad {
    // Roll back any locals allocated during the speculative pass so the
    // LocalVarSig blob does not declare orphan slots that the legacy path
    // will never reference.
    while fctx.slotTicker.count > snapSlot {
      fctx.slotTicker.removeAt(fctx.slotTicker.count - 1)
    }
    while fctx.labelTicker.count > snapLabel {
      fctx.labelTicker.removeAt(fctx.labelTicker.count - 1)
    }
    while fctx.locals.count > snapLocals {
      fctx.locals.removeAt(fctx.locals.count - 1)
    }
    None
  } else {
    match Mdr.resolveExtern(cctx.metadataTypeIndex, cctx.metadataPathIndex, clrFqn, methodName, argSigs) {
      case None -> {
        // Metadata resolved nothing — still roll back to keep counters clean.
        while fctx.slotTicker.count > snapSlot {
          fctx.slotTicker.removeAt(fctx.slotTicker.count - 1)
        }
        while fctx.labelTicker.count > snapLabel {
          fctx.labelTicker.removeAt(fctx.labelTicker.count - 1)
        }
        while fctx.locals.count > snapLocals {
          fctx.locals.removeAt(fctx.locals.count - 1)
        }
        None
      }
      case Some(re) -> emitResolvedAutoFfi(cctx, insns, re.assemblyName, clrFqn, methodName, argBufs, argTys, re.sig)
    }
  }
}

// Emit an auto-FFI method call for an extern-type receiver.
// `recvName` is the Lyric name; `clrFqn` is the CLR fully-qualified type name.
// Returns the MsilType of the result.
func emitAutoFfiCallMsil(
  cctx: in CodegenCtx,
  fctx: in FuncCtx,
  insns: in List[MInsn],
  recvExpr: in Expr,
  methodName: in String,
  args: in List[CallArg],
  clrFqn: in String,
): MsilType {
  // Phase 3c: prefer real metadata-based resolution (handles argument-bearing
  // and non-void static methods).  Falls through to the legacy gating below
  // when the shape isn't yet supported (coercion, instance, class types).
  // The silent fallback is intentional for backward compatibility; emitting
  // a note-level diagnostic ("auto-FFI: could not resolve from metadata —
  // explicit @externTarget required") is tracked separately.
  match tryAutoFfiFromMetadata(cctx, fctx, insns, methodName, args, clrFqn) {
    case Some(retTy) -> return retTy
    case None -> {
    }
  }
  // Reject an extern-type CLR name the FFI cascade can't resolve to a known
  // reference assembly.  The metadata type index is guaranteed to be populated
  // here because `tryAutoFfiFromMetadata` (called above) unconditionally calls
  // `ensureMetadataIndex` before attempting resolution — so this check is never
  // racing against an empty index (#2944).
  val isKnownAutoFfiFqn = match Mdr.assemblyForType(cctx.metadataTypeIndex, clrFqn) {
    case Some(_) -> true
    case None -> clrAssemblyResolvable(clrFqn)
  }
  if not isKnownAutoFfiFqn {
    panic(
      "Msil.Codegen: auto-FFI call '" + methodName + "' on extern type '" + clrFqn +
        "' cannot be resolved to any indexed reference assembly or Lyric host assembly; " +
        "check the extern type's CLR name for a typo or an unsupported type."
    )
  }
  // Auto-FFI cannot resolve a method's signature; fail loud on argument-bearing calls.
  if args.count > 0 {
    panic(
      "Msil.Codegen: auto-FFI call '" + clrFqn + "." + methodName +
        "(...)' takes arguments, which the self-hosted emitter cannot resolve " +
        "without the method's real signature (it would emit an (object...):void " +
        "guess that mis-binds at runtime).  Declare an @externTarget wrapper " +
        "function with the BCL signature instead — e.g. " +
        "`@externTarget(\"" +
        clrFqn +
        "." +
        methodName +
        "\") @externStatic " +
        "func ...`.  (Metadata-based resolution is tracked in #1622.)"
    )
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
    case _ -> pkgName + ".__impl_target"
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
pub func collectImplEntriesMsil(cctx: in CodegenCtx, file: in SourceFile, pkgName: in String): Unit {
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IImpl(decl) -> {
        val targetName = implTargetNameMsil(decl, pkgName)
        val ifaceName = implIfaceNameMsil(decl, pkgName)
        val methods: List[MFunc] = newList()
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case IMplFunc(fn) -> methods.add(lowerImplMethodMsil(cctx, fn, pkgName, targetName))
            case IMplAssoc(_) -> {
            }
          }
          mi = mi + 1
        }
        cctx.implEntries.add(ImplEntryMsil(targetTypeName = targetName, ifaceTypeName = ifaceName, methods = methods))
      }
      case _ -> {
      }
    }
    i = i + 1
  }
}

// Append any pre-collected impl methods whose target matches `targetFqn` to
// the record's method list, producing a new `MRecord`.  The original record
// is left untouched.
pub func injectImplMethodsIntoRecord(cctx: in CodegenCtx, rec: in MRecord, targetFqn: in String): MRecord {
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
    className = rec.className,
    namespace = rec.namespace,
    baseClass = rec.baseClass,
    fields = rec.fields,
    methods = mergedMethods,
    useDefaultCtor = rec.useDefaultCtor,
    generics = rec.generics
  )
}

// True iff `anns` carries a `@derive(<marker>)` annotation.  Mirrors
// `Lyric.Derives.hasDeriveMarker` (codegen can't import that package).
func hasDeriveMarkerMsil(anns: in List[Annotation], marker: in String): Bool {
  var i = 0
  while i < anns.count {
    val a = anns[i]
    if a.name.segments.count == 1 and a.name.segments[0] == "derive" and a.args.count > 0 {
      val nm = match a.args[0] {
        case ABare(n, _) -> n
        case ALiteral(v, _) -> match v { case AVIdent(n, _) -> n; case _ -> "" }
        case AAName(_, _, _) -> ""
      }
      if nm == marker {
        return true
      }
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
pub func appendDeriveOverridesMsil(
  cctx: in CodegenCtx, rec: in MRecord, recordFqn: in String, anns: in List[Annotation]
): MRecord {
  val methods: List[MFunc] = newList()
  var bi = 0
  while bi < rec.methods.count {
    methods.add(rec.methods[bi])
    bi = bi + 1
  }

  if hasDeriveMarkerMsil(anns, "Equals") {
    val eqTok = match mapGet(cctx.funcTokens, recordFqn + ".equals") {
      case Some(t) -> t
      case None -> panic("Msil.Codegen: @derive(Equals) record " + recordFqn + " has no synthesised `.equals` token — Lyric.Derives / mono regression (#1796)")
    }
    // bool Equals(object obj) {
    //   var c = obj as <Record>;       // isinst; stloc 0
    //   if (c == null) return false;   // brfalse RETFALSE
    //   return <Record>.equals(this, c);
    // RETFALSE: return false; }
    val insns: List[MInsn] = newList()
    insns.add(MLdarg(slot = 1))  // obj
    insns.add(MIsinstByName(className = recordFqn))  // obj as <Record>
    insns.add(MStloc(slot = 0))
    insns.add(MLdloc(slot = 0))
    insns.add(MBrFalse(label = 0))
    insns.add(MLdarg(slot = 0))  // this
    insns.add(MLdloc(slot = 0))  // c
    insns.add(MCall(methodToken = eqTok))  // <Record>.equals(this, c): bool
    insns.add(MRet)
    insns.add(MLabel(id = 0))
    insns.add(MLdcI4(v = 0))
    insns.add(MRet)
    val eqParams: List[MsilType] = newList()
    eqParams.add(MObject)
    val eqLocals: List[MsilType] = newList()
    eqLocals.add(MClass(className = recordFqn))
    methods.add(
      MFunc(
        flags = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG,
        name = "Equals",
        params = eqParams,
        ret = MBool,
        insns = insns,
        maxStack = 8,
        locals = eqLocals
      )
    )
  }

  if hasDeriveMarkerMsil(anns, "Hash") {
    val hashTok = match mapGet(cctx.funcTokens, recordFqn + ".hash") {
      case Some(t) -> t
      case None -> panic("Msil.Codegen: @derive(Hash) record " + recordFqn + " has no synthesised `.hash` token — Lyric.Derives / mono regression (#1796)")
    }
    // int GetHashCode() { return <Record>.hash(this); }
    val insns: List[MInsn] = newList()
    insns.add(MLdarg(slot = 0))  // this
    insns.add(MCall(methodToken = hashTok))  // <Record>.hash(this): int
    insns.add(MRet)
    val ghParams: List[MsilType] = newList()
    val ghLocals: List[MsilType] = newList()
    methods.add(
      MFunc(
        flags = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG,
        name = "GetHashCode",
        params = ghParams,
        ret = MInt,
        insns = insns,
        maxStack = 4,
        locals = ghLocals
      )
    )
  }

  MRecord(
    className = rec.className,
    namespace = rec.namespace,
    baseClass = rec.baseClass,
    fields = rec.fields,
    methods = methods,
    useDefaultCtor = rec.useDefaultCtor,
    generics = rec.generics
  )
}

// Lower one config-field default literal into `insns` (D046).  `neg` folds a
// leading unary minus (the parser represents `-1` as EPrefix(PreNeg, LInt(1))).
// The emitted instruction is directed by the declared field type so an Int
// literal initialises a Long field via ldc.i8 and a Float/Double field via
// ldc.r8 (#2993).  Returns false when the literal kind cannot initialise a
// field of type `fieldTy`; callers turn that into an ICE panic, since the
// type checker's G0010 guard rejects non-literal / mismatched defaults.
func emitConfigDefaultLiteralMsil(
  cctx: in CodegenCtx,
  fieldTy: in MsilType,
  lit: in Literal,
  neg: in Bool,
  insns: in List[MInsn],
): Bool {
  match lit {
    case LInt(v0, _, _) -> {
      val v = if neg { 0i64 - v0 } else { v0 }
      match fieldTy {
        case MInt -> {
          insns.add(MLdcI4(v = longToInt(v)))
          true
        }
        case MLong -> {
          insns.add(MLdcI8(v = v))
          true
        }
        case MDouble -> {
          insns.add(MLdcR8(v = v.toDouble()))
          true
        }
        case _ -> false
      }
    }
    case LFloat(f0, _, _) -> {
      match fieldTy {
        case MDouble -> {
          insns.add(MLdcR8(v = if neg { 0.0 - f0 } else { f0 }))
          true
        }
        case _ -> false
      }
    }
    case LBool(bv) -> {
      match fieldTy {
        case MBool -> {
          if neg {
            false
          } else {
            insns.add(MLdcI4(v = if bv { 1 } else { 0 }))
            true
          }
        }
        case _ -> false
      }
    }
    case LString(sv) -> {
      match fieldTy {
        case MString -> {
          if neg {
            false
          } else {
            insns.add(MLdStr(token = ctxInternUs(cctx.lctx, sv)))
            true
          }
        }
        case _ -> false
      }
    }
    case _ -> false
  }
}

// Derive the environment variable name for a config block field (D046):
// LYRIC_CONFIG_<PKG_UPPER>_<BLOCK_UPPER>_<FIELD_UPPER>
// Dots in pkgName are replaced with underscores before uppercasing.
func deriveConfigEnvVarName(pkgName: in String, blockName: in String, fieldName: in String): String {
  val pkgUpper = pkgName.replace(".", "_").toUpper()
  val blockUpper = blockName.toUpper()
  val fieldUpper = fieldName.toUpper()
  "LYRIC_CONFIG_" + pkgUpper + "_" + blockUpper + "_" + fieldUpper
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

  val fns: List[MFunc] = newList()
  val staticFields: List[MStaticField] = newList()
  val items: List[MPackageItem] = newList()
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
    panic(
      "codegenMPackage: weaver produced " + toString(weaveSafety.diagnostics.count) +
        " diagnostic(s) on the second-pass weave — caller bypassed " +
        "Msil.Bridge's pre-weave + reportAndAbort contract.  Call " +
        "Weaver.weaveFileWithDiags(file) first and abort on errors."
    )
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
        val baseRec = lowerRecordMsil(cctx, decl, pkgName)
        val rec0 = injectImplMethodsIntoRecord(cctx, baseRec, pkgName + "." + decl.name)
        val rec = appendDeriveOverridesMsil(cctx, rec0, pkgName + "." + decl.name, item.annotations)
        items.add(MPRecord(rec = rec))
      }
      case IExposedRec(decl) -> {
        val baseRec = lowerRecordMsil(cctx, decl, pkgName)
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
        } else if isGenerator {
          synthesizeGeneratorMsil(cctx, decl, pkgName, items, fns)
        } else {
          fns.add(lowerFuncMsil(cctx, decl, pkgName))
        }
        if isMainFuncMsil(decl) {
          hasMain = true
        }
      }
      case IUnion(decl) -> {
        items.add(MPUnion(u = lowerUnionMsil(cctx, decl, pkgName)))
      }
      case IDistinctType(decl) -> {
        val inner = typeExprToMsilCtx(cctx, decl.underlying, pkgName)
        items.add(MPDistinctType(d = mkDistinctTypeIR(pkgName + "." + decl.name, pkgName, inner, decl.rangeClause)))
      }
      case IConst(decl) -> {
        // Module-level compile-time constant → static field on the host class.
        // Int-range literals use FDA_LITERAL so .NET tools see a compile-time
        // constant; other types (Float, String, etc.) use FDA_INIT_ONLY with
        // .cctor initialisation — same observable semantics, simpler blob format.
        val initFctx = makeFuncCtxMsil(pkgName, pkgName, "__const_" + decl.name, 0, MVoid)
        val initInsns: List[MInsn] = newList()
        lowerExprMsil(cctx, initFctx, initInsns, decl.init)
        val fieldTy = typeExprToMsilCtx(cctx, decl.ty, pkgName)
        if isLiteralI4ExprMsil(decl.init) {
          val constVal = match initInsns.count {
            case n if n > 0 -> match initInsns[0] { case MLdcI4(v) -> v; case _ -> 0 }
            case _ -> 0
          }
          staticFields.add(
            MStaticField(
              flags = FDA_PUBLIC + FDA_STATIC + FDA_LITERAL + FDA_HAS_DEFAULT,
              name = decl.name,
              fieldType = fieldTy,
              constValue = constVal,
              hasLiteral = true,
              initInsns = newList()
            )
          )
          // Register inlined value so EPath emits ldc.i4 directly.  The
          // package-qualified key makes same-package reads exact (#2627);
          // the bare name stays as the cross-package fallback (first-wins).
          val qualConstKey = pkgName + "/" + decl.name
          if not cctx.constValues.containsKey(qualConstKey) {
            cctx.constValues.add(qualConstKey, constVal)
          }
          if not cctx.constValues.containsKey(decl.name) {
            cctx.constValues.add(decl.name, constVal)
          }
        } else {
          // Non-Int constant (Float, String, …): initialise in .cctor.
          staticFields.add(
            MStaticField(
              flags = FDA_PUBLIC + FDA_STATIC + FDA_INIT_ONLY,
              name = decl.name,
              fieldType = fieldTy,
              constValue = 0,
              hasLiteral = false,
              initInsns = initInsns
            )
          )
        }
      }
      case IVal(decl) -> {
        // Module-level runtime value → static readonly field initialized in .cctor.
        val initFctx = makeFuncCtxMsil(pkgName, pkgName, "__val_init", 0, MVoid)
        val initInsns: List[MInsn] = newList()
        val valTy = lowerExprMsil(cctx, initFctx, initInsns, decl.init)
        val fieldTy = match decl.ty { case Some(te) -> typeExprToMsilCtx(cctx, te, pkgName); case None -> valTy }
        val fieldName = match decl.pattern.kind {
          case PBinding(name, _) -> name
          case _ -> "__val_" + toString(staticFields.count)
        }
        // When the init is a single ldc.i4 (literal Int), inline into constValues
        // and pass an empty initInsns to avoid generating a .cctor for this field.
        // All uses of the val in this package will emit ldc.i4 directly.
        var sfInitInsns = initInsns
        if initInsns.count == 1 {
          match initInsns[0] {
            case MLdcI4(v) -> {
              // Guard with containsKey: same first-wins semantics as IConst above.
              // Only suppress the .cctor when we successfully register the inline
              // value; if the name is already taken, keep initInsns so the field
              // receives its proper runtime initialization.  The package-
              // qualified key makes same-package reads exact (#2627).
              val qualValKey = pkgName + "/" + fieldName
              if not cctx.constValues.containsKey(qualValKey) {
                cctx.constValues.add(qualValKey, v)
              }
              if not cctx.constValues.containsKey(fieldName) {
                cctx.constValues.add(fieldName, v)
                sfInitInsns = newList()
              }
            }
            case _ -> {
            }
          }
        }
        val sfield = MStaticField(
          flags = FDA_PUBLIC + FDA_STATIC + FDA_INIT_ONLY,
          name = fieldName,
          fieldType = fieldTy,
          constValue = 0,
          hasLiteral = false,
          initInsns = sfInitInsns
        )
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
        items.add(MPEnum(e = MEnum(className = pkgName + "." + decl.name, namespace = pkgName, cases = caseNames)))
      }
      case IInterface(decl) -> {
        val ifaceMembers: List[MIfaceItem] = newList()
        val ifaceFqn = pkgName + "." + decl.name
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case IMSig(sig) -> {
              val pTypes: List[MsilType] = newList()
              var pi = 0
              while pi < sig.params.count {
                pTypes.add(typeExprToMsilCtx(cctx, sig.params[pi].ty, pkgName))
                pi = pi + 1
              }
              val retTy = match sig.ret { case Some(te) -> typeExprToMsilCtx(cctx, te, pkgName); case None -> MVoid }
              ifaceMembers.add(
                MIAbstract(m = MInterfaceMethod(name = sig.name, params = byrefWrapSigTypes(sig.params, pTypes), ret = retTy))
              )
            }
            case IMFunc(fn) -> {
              // Default interface method — compile body; `lowerMInterface` emits as
              // a concrete DIM MethodDef (Virtual+HideBySig+NewSlot, no Abstract),
              // in the same declaration-order position so token numbers match the
              // addPackageTokens pre-pass.
              ifaceMembers.add(MIDim(fn = lowerImplMethodMsil(cctx, fn, pkgName, ifaceFqn)))
            }
            case IMAssoc(_) -> {
            }
          }
          mi = mi + 1
        }
        items.add(MPInterface(iface = MInterface(className = ifaceFqn, namespace = pkgName, members = ifaceMembers)))
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
          val visMask: List[Bool] = newList()
          val projMask: List[Bool] = newList()
          var fi = 0
          while fi < decl.members.count {
            match decl.members[fi] {
              case OMField(f) -> {
                oFields.add(MField(flags = FDA_PRIVATE, name = f.name, fieldType = typeExprToMsilCtx(cctx, f.ty, pkgName)))
                visMask.add(not hasAnnotationMsil(f.annotations, "hidden"))
                projMask.add(hasAnnotationMsil(f.annotations, "projectionBoundary"))
              }
              case OMInvariant(_) -> {
              }
            }
            fi = fi + 1
          }
          val isProj = hasAnnotationMsil(decl.annotations, "projectable")
          items.add(
            MPOpaque(
              opaqueData = MOpaque(
                className = pkgName + "." + decl.name,
                namespace = pkgName,
                fields = oFields,
                methods = newList(),
                isProjectable = isProj,
                visibleFieldMask = visMask,
                projBoundaryMask = projMask
              )
            )
          )
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
      case IAspect(_) -> {
      }  // consumed by weaveAspectsMsil above
      case ITypeAlias(_) -> {
      }
      case IScopeKind(_) -> {
      }
      case IExtern(_) -> {
      }
      case IExternType(_) -> {
      }
      case ITest(_) -> {
      }
      case IProperty(_) -> {
      }
      case IFixture(_) -> {
      }
      case IConfig(decl) -> {
        // Build an MPConfig item for each non-empty config block.  The field tokens
        // were pre-allocated by addPackageTokens (Pass 1, IConfig arm) so each
        // field's 0x04000000|row is already in cctx.configFieldTokens.
        if decl.fields.count > 0 {
          val cfieldsList: List[MConfigField] = newList()
          var cfi = 0
          while cfi < decl.fields.count {
            val cf = decl.fields[cfi]
            val envVarName = deriveConfigEnvVarName(pkgName, decl.name, cf.name)
            val envVarTok = ctxInternUs(cctx.lctx, envVarName)
            val cfTy = typeExprToMsilCtx(cctx, cf.ty, pkgName)
            val hasDefault = match cf.default { case Some(_) -> true; case None -> false }
            val defaultInsnsList: List[MInsn] = newList()
            if hasDefault {
              match cf.default {
                case Some(defExpr) -> {
                  val lowered = match defExpr.kind {
                    case ELiteral(lit) -> emitConfigDefaultLiteralMsil(cctx, cfTy, lit, false, defaultInsnsList)
                    case EPrefix(op, inner) -> match op { case PreNeg -> match inner.kind { case ELiteral(lit2) -> emitConfigDefaultLiteralMsil(cctx, cfTy, lit2, true, defaultInsnsList); case _ -> false }; case _ -> false }
                    case _ -> false
                  }
                  if not lowered {
                    // A silent fall-through here leaves the field at its
                    // zero-initialised value regardless of the declared
                    // default (#2993); the front-end's G0010 guard rejects
                    // these shapes before codegen.
                    panic(
                      "Msil.Codegen ICE: config default for '" + decl.name + "." + cf.name +
                        "' is not a literal of the declared type — the type checker (G0010) should have rejected this"
                    )
                  }
                }
                case None -> ()
              }
            }
            val requiredMsgTok = if hasDefault {
              0
            } else {
              val msg = "error: required config field " + decl.name + "." + cf.name + " (env var " + envVarName + ") is not set"
              ctxInternUs(cctx.lctx, msg)
            }
            cfieldsList.add(
              MConfigField(
                name = cf.name,
                fieldType = cfTy,
                envVarTok = envVarTok,
                hasDefault = hasDefault,
                defaultInsns = defaultInsnsList,
                requiredMsgTok = requiredMsgTok
              )
            )
            cfi = cfi + 1
          }
          items.add(
            MPConfig(
              ns = pkgName,
              typeName = decl.name,
              fields = cfieldsList,
              configToks = ConfigTokens(
                tokGetEnvVar = cctx.tokCfgGetEnvVar,
                tokIsNullOrEmpty = cctx.tokCfgIsNullOrEmpty,
                tokConsoleError = cctx.tokCfgConsoleError,
                tokTwWriteLine = cctx.tokCfgTwWriteLine,
                tokEnvExit = cctx.tokCfgEnvExit,
                tokInt32Parse = cctx.tokCfgInt32Parse,
                tokBoolParse = cctx.tokCfgBoolParse,
                tokInt64Parse = cctx.tokCfgInt64Parse,
                tokDoubleParse = cctx.tokCfgDoubleParse,
                tokInvariantCulture = cctx.tokInvariantCulture
              )
            )
          )
        }
      }
      case IError -> {
      }
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
      mslots.add(MImplSlot(ifaceMethodToken = 0, implMethodToken = 0, ifaceMethodName = mname, implMethodName = mname))
      mi = mi + 1
    }
    items.add(
      MPImpl(
        implData = MImplData(
          targetTypeDefRow = 0,
          ifaceTypeToken = 0,
          slots = mslots,
          targetTypeName = implEntry.targetTypeName,
          ifaceTypeName = implEntry.ifaceTypeName
        )
      )
    )
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
// Scan `cctx.restoredArtifacts` for the matching package and return its
// originating DLL file path, or `""` when no match.  Mirrors
// `lookupRestoredArtifactVersion`'s linear scan.
func lookupRestoredArtifactDllPath(cctx: in CodegenCtx, packageName: in String): String {
  var i = 0
  while i < cctx.restoredArtifacts.count {
    val art = cctx.restoredArtifacts[i]
    if art.packageName == packageName {
      return art.dllPath
    }
    i = i + 1
  }
  ""
}

// Derive the actual assembly simple name from a DLL file path: strip the
// directory prefix and the `.dll` extension.  A consumer's AssemblyRef
// must match the producer's assembly simple name verbatim or the loader
// can't bind.  For ordinary restored deps the file is `<packageName>.dll`,
// so the stem equals the package name — but Lyric-emitted *bundle* DLLs
// can prefix every member package (the compiler bundle ships package
// `Lyric.Weaver` as `Lyric.Lyric.Weaver.dll`, assembly simple name
// `Lyric.Lyric.Weaver`).  Naming the AssemblyRef after the file stem is
// correct in both cases; `fallback` (the package name) covers a missing
// path.
func assemblySimpleNameFromDll(dllPath: in String, fallback: in String): String {
  if dllPath == "" {
    return fallback
  }
  var base = dllPath
  val slashIdx = base.lastIndexOf("/")
  if slashIdx >= 0 {
    base = base.substring(slashIdx + 1, base.length - slashIdx - 1)
  }
  val bslashIdx = base.lastIndexOf("\\")
  if bslashIdx >= 0 {
    base = base.substring(bslashIdx + 1, base.length - bslashIdx - 1)
  }
  val dotIdx = base.lastIndexOf(".")
  if dotIdx >= 0 {
    base = base.substring(0, dotIdx)
  }
  if base == "" {
    return fallback
  }
  base
}

// Allocate one AssemblyRef per restored artifact, keyed by package
// name → AssemblyRef row.  Cached in `ffiAsmRefs` so multiple
// `registerRestoredArtifactTokens` calls against the same package
// re-use the row.  The AssemblyRef NAME is the producer DLL's actual
// assembly simple name (its file stem), which equals `packageName` for
// ordinary `<packageName>.dll` deps but differs for prefixed bundle DLLs
// (see `assemblySimpleNameFromDll`).
func ensureAssemblyRefForArtifact(cctx: in CodegenCtx, packageName: in String): Int {
  match mapGet(cctx.ffiAsmRefs, packageName) {
    case Some(row) -> return row
    case None -> ()
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
  val dllPath = lookupRestoredArtifactDllPath(cctx, packageName)
  val asmName = assemblySimpleNameFromDll(dllPath, packageName)
  val row = ctxAddLyricPackageAssemblyRef(cctx.lctx, asmName, verParts[0], verParts[1])
  cctx.ffiAsmRefs.add(packageName, row)
  row
}

// Walk `cctx.restoredArtifacts` for the matching package and return its
// declared version string, or `""` when no match.  Linear scan is fine —
// the typical restored-deps count is a handful, and the lookup happens
// once per cross-assembly AssemblyRef (results cached in `ffiAsmRefs`).
func lookupRestoredArtifactVersion(cctx: in CodegenCtx, packageName: in String): String {
  var i = 0
  while i < cctx.restoredArtifacts.count {
    val art = cctx.restoredArtifacts[i]
    if art.packageName == packageName {
      return art.version
    }
    i = i + 1
  }
  ""
}

// True iff `c` is an identifier continuation (ASCII).
@pure
func isIdentChar(c: in Char): Bool {
  c == '_' or (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')
}

// Walk a union decl's `repr` for case names.  The contract `repr` for
// unions is the canonical source-level form, e.g.
// `pub union Maybe { case Some(v: Int), case None }`.  Case names
// follow the literal `case ` keyword and are terminated by `(`, ` `,
// `,`, or `}`.
func registerUnionCases(cctx: in CodegenCtx, packageName: in String, unionName: in String, decl: in ContractDecl): Unit {
  val repr = decl.repr
  val needle = "case "
  var idx = 0
  // Loop exits via the early `return`s below (`indexOf` no-match
  // or `nameStart >= repr.length`); `idx` is non-negative by
  // construction (#1279).
  while true {
    val hit = repr.indexOf(needle, idx)
    if hit < 0 {
      return
    }
    val nameStart = hit + needle.length
    if nameStart >= repr.length {
      return
    }
    var j = nameStart
    while j < repr.length and isIdentChar(repr[j]) {
      j = j + 1
    }
    if j > nameStart {
      val caseName = repr.substring(nameStart, j - nameStart)
      val ctorKey = packageName + "." + unionName + "_" + caseName
      if cctx.unionCaseCtorByName.containsKey(caseName) {
        match mapGet(cctx.unionCaseCtorByName, caseName) {
          case Some(lst) -> {
            if not lst.contains(ctorKey) {
              lst.add(ctorKey)
            }
          }
          case None -> ()
        }
      } else {
        val ctorKeyList1: List[String] = newList()
        ctorKeyList1.add(ctorKey)
        cctx.unionCaseCtorByName.add(caseName, ctorKeyList1)
      }
      if not cctx.caseParentUnion.containsKey(ctorKey) {
        cctx.caseParentUnion.add(ctorKey, packageName + "." + unionName)
      }
    }
    idx = j
  }
}

// Register one type-shaped decl from a restored artifact: allocates
// the TypeRef row (cached in `ffiTypeRefs`), seeds the simple-name
// lookup in `typeFqnByName`, and for unions, also seeds case names
// in `unionCaseCtorByName` (multimap since #2899; same-named cases from
// different unions are all stored and disambiguated at lookup sites via
// `pickCaseFqnByScope` / `pickCaseFqnByScrutinee`).
func registerRestoredTypeDecl(
  cctx: in CodegenCtx, packageName: in String, decl: in ContractDecl, asmRefRow: in Int
): Unit {
  val typeName = decl.name
  val typeFqn = packageName + "." + typeName

  val typeRefKey = packageName + "/" + typeFqn
  if not cctx.ffiTypeRefs.containsKey(typeRefKey) {
    val row = ctxAddTypeRef(cctx.lctx, packageName, typeName, asmRefRow)
    cctx.ffiTypeRefs.add(typeRefKey, row)
  }

  registerTypeFqnCandidate(cctx, typeName, typeFqn)

  if decl.kind == "union" {
    registerUnionCases(cctx, packageName, typeName, decl)
  }
}

// Look up the TypeRef row previously allocated by registerRestoredTypeDecl.
// Returns 0 when no row exists (caller skips MemberRef allocation).
func lookupRestoredTypeRefRow(cctx: in CodegenCtx, packageName: in String, typeName: in String): Int {
  val typeFqn = packageName + "." + typeName
  val typeRefKey = packageName + "/" + typeFqn
  match mapGet(cctx.ffiTypeRefs, typeRefKey) {
    case Some(row) -> row
    case None -> 0
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
func ensureHostClassTypeRefRow(cctx: in CodegenCtx, packageName: in String, asmRefRow: in Int): Int {
  val key = packageName + "/host"
  if cctx.ffiTypeRefs.containsKey(key) {
    match mapGet(cctx.ffiTypeRefs, key) {
      case Some(row) -> return row
      case None -> ()
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

// Register a record's ctor MemberRef in `recordCtorTokens`; signature mirrors lowerMRecord (HASTHIS void + one OBJECT param per field — foreign DLL uses same encoding).
func registerRestoredRecordCtor(cctx: in CodegenCtx, packageName: in String, rec: in RecordDecl): Unit {
  val className = packageName + "." + rec.name
  if cctx.recordCtorTokens.containsKey(className) {
    return
  }

  val typeRefRow = lookupRestoredTypeRefRow(cctx, packageName, rec.name)
  if typeRefRow == 0 {
    return
  }

  val recGenerics = genericNamesOf(rec.generics)

  // Generic records: CLR name needs arity suffix (Box`1); seeds genericTypeArity so typeExprToMsilCtx returns MGenericInstByName (#3099).
  if recGenerics.count > 0 {
    val asmRefRow = ensureAssemblyRefForArtifact(cctx, packageName)
    val arityName = rec.name + "`" + toString(recGenerics.count)
    ctxAddTypeRef(cctx.lctx, packageName, arityName, asmRefRow)
    if not cctx.genericTypeArity.containsKey(className) {
      cctx.genericTypeArity.add(className, recGenerics.count)
    }
  }

  val ctorParams: List[MsilType] = newList()
  var fi = 0
  while fi < rec.members.count {
    match rec.members[fi] {
      case RMField(f) -> {
        val fty = if recGenerics.count > 0 {
          typeExprToMsilG(cctx, f.ty, packageName, recGenerics)
        } else {
          typeExprToMsilCtx(cctx, f.ty, packageName)
        }
        ctorParams.add(fty)
      }
      case _ -> ()
    }
    fi = fi + 1
  }

  // For generic records, seed genericCtorParams with the VAR-form parameter list
  // so buildInBundleGenericCtorTok can construct the TypeSpec-parented .ctor
  // MemberRef at Phase 5.  The same ctorParams list drives the fallback
  // recordCtorTokens MemberRef below (plain TypeRef, not used for generic construction
  // but needed as the "this case exists" marker for ctorKeyOpt lookups).
  if recGenerics.count > 0 and not cctx.genericCtorParams.containsKey(className) {
    cctx.genericCtorParams.add(className, ctorParams)
  }

  val ctorSig = buildInstanceMethodSigWithCtx(ctorParams, MVoid, cctx.lctx)
  val sigKey = "restored_ctor_" + className
  val memberRow = ctxAddMemberRef(cctx.lctx, typeRefRow, ".ctor", sigKey, ctorSig)
  cctx.recordCtorTokens.add(className, 0x0A000000 + memberRow)
}

// Register cross-assembly FieldRef MemberRefs for a restored record; sig mirrors lowerMRecord's buildFieldSigWithCtx (concrete reference types, not degraded to OBJECT — mismatch faults with Field not found #2359). fieldMsilTypes carries semantic type for EIndex element-type tracking.
func registerRestoredRecordFields(cctx: in CodegenCtx, packageName: in String, rec: in RecordDecl): Unit {
  val className = packageName + "." + rec.name
  val typeRefRow = lookupRestoredTypeRefRow(cctx, packageName, rec.name)
  if typeRefRow == 0 {
    return
  }

  val recGenerics = genericNamesOf(rec.generics)

  var fi = 0
  var fpos = 0
  while fi < rec.members.count {
    match rec.members[fi] {
      case RMField(f) -> {
        val key = className + "/" + f.name
        if not cctx.fieldTokens.containsKey(key) {
          val fty = if recGenerics.count > 0 {
            typeExprToMsilG(cctx, f.ty, packageName, recGenerics)
          } else {
            typeExprToMsilCtx(cctx, f.ty, packageName)
          }
          // MTypeVar fields: VAR-form sig to byte-match the DLL declaration; seeds fieldSigBytes/fieldVarIndices for the MLdfldGeneric Phase 5 path (#3099).
          val gIdx = match fty { case MTypeVar(idx) -> idx; case _ -> -1 }
          val fSig = if gIdx >= 0 { buildGenericParamFieldSig(gIdx) } else { buildFieldSigWithCtx(fty, cctx.lctx) }
          val sigKey = "restored_field_" + key
          val memberRow = ctxAddMemberRef(cctx.lctx, typeRefRow, f.name, sigKey, fSig)
          cctx.fieldTokens.add(key, 0x0A000000 + memberRow)
          // Store MObject for type-variable fields so pushCollExpect doesn't treat the arg as a collection element; VAR index tracked separately in fieldVarIndices for the MLdfldGeneric path.
          cctx.fieldMsilTypes.add(key, if gIdx >= 0 { MObject } else { fty })
          if not cctx.fieldSigBytes.containsKey(key) {
            cctx.fieldSigBytes.add(key, fSig)
          }
          if not cctx.fieldVarIndices.containsKey(key) {
            cctx.fieldVarIndices.add(key, gIdx)
          }
        }
        // Positional name map: mirrors in-bundle record registration so construction sites resolve concrete field types (avoids List<object> + InvalidCastException — #1730/#2592).
        val byPosKey = className + "/field" + toString(fpos)
        if not cctx.fieldDeclaredNames.containsKey(byPosKey) {
          cctx.fieldDeclaredNames.add(byPosKey, f.name)
        }
        // Also mirror fieldSigBytes / fieldVarIndices at the positional key so
        // MLdfldGeneric and pattern field-binding can resolve by position.
        if not cctx.fieldSigBytes.containsKey(byPosKey) {
          val byNameSig = match mapGet(cctx.fieldSigBytes, key) { case Some(s) -> s; case None -> buildFieldSig(MObject) }
          cctx.fieldSigBytes.add(byPosKey, byNameSig)
        }
        if not cctx.fieldVarIndices.containsKey(byPosKey) {
          val byNameVi = match mapGet(cctx.fieldVarIndices, key) { case Some(v) -> v; case None -> -1 }
          cctx.fieldVarIndices.add(byPosKey, byNameVi)
        }
        fpos = fpos + 1
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
func registerRestoredFunc(cctx: in CodegenCtx, packageName: in String, fn: in FunctionDecl): Unit {
  // Only `pub` functions surface in the foreign DLL with a public
  // method; `internal` functions are emitted with internal accessibility
  // and a cross-assembly MemberRef pointing at them would fail to
  // resolve at runtime.
  val isPub = match fn.visibility { case Some(VisPub(_)) -> true; case _ -> false }
  if not isPub {
    return
  }
  // Generic public free functions require monomorphized-form MemberRef
  // signatures — a raw type-variable `T` resolves to a non-existent
  // `<pkg>.T` class and the runtime raises TypeLoadException.  Deferred
  // until cross-assembly generic call sites are supported.
  val fnIsGeneric = match fn.generics { case Some(_) -> true; case None -> false }
  if fnIsGeneric {
    return
  }

  val fqn = packageName + "." + fn.name
  if cctx.funcTokens.containsKey(fqn) {
    return
  }

  val asmRefRow = ensureAssemblyRefForArtifact(cctx, packageName)
  val hostRefRow = ensureHostClassTypeRefRow(cctx, packageName, asmRefRow)

  val paramTypes: List[MsilType] = newList()
  var pi = 0
  while pi < fn.params.count {
    paramTypes.add(typeExprToMsilCtx(cctx, fn.params[pi].ty, packageName))
    pi = pi + 1
  }
  val retType = match fn.ret { case Some(te) -> typeExprToMsilCtx(cctx, te, packageName); case None -> MVoid }

  val funcSig = buildStaticMethodSigWithCtx(byrefWrapSigTypes(fn.params, paramTypes), retType, cctx.lctx)
  val sigKey = "restored_func_" + fqn
  val memberRow = ctxAddMemberRef(cctx.lctx, hostRefRow, fn.name, sigKey, funcSig)
  cctx.funcTokens.add(fqn, 0x0A000000 + memberRow)
  // Record the return type so SExpr call sites don't emit a spurious
  // `pop` after void cross-assembly calls → InvalidProgramException.
  cctx.funcRetTypes.add(fqn, retType)
  cctx.funcParamModes.add(fqn, paramModesOf(fn.params))
}

// Allocate or reuse a cached TypeRef row for a union case class; arity > 0 stamps the suffix (e.g. "Maybe_Just`1`") matching lowerMUnion — CLR loader requires it; 0 keeps plain name for non-generic unions and stdlib.
func ensureCaseClassTypeRefRow(
  cctx: in CodegenCtx,
  packageName: in String,
  caseClassName: in String,
  asmRefRow: in Int,
  arity: in Int,
): Int {
  // Cache key is the case-class FQN; sibling lookups
  // (`lookupRestoredTypeRefRow`) use the same `<pkg>/<fqn>` shape so
  // `<pkg>` deliberately appears twice (#1294).
  val caseFqn = packageName + "." + caseClassName
  val typeRefKey = packageName + "/" + caseFqn
  match mapGet(cctx.ffiTypeRefs, typeRefKey) {
    case Some(row) -> return row
    case None -> ()
  }
  val typeRefName = if arity > 0 { caseClassName + "`" + toString(arity) } else { caseClassName }
  val row = ctxAddTypeRef(cctx.lctx, packageName, typeRefName, asmRefRow)
  cctx.ffiTypeRefs.add(typeRefKey, row)
  row
}

// Extract a UnionField's type expression.  Both UFNamed and UFPos
// carry a TypeExpr; this helper unifies the access.
func unionFieldType(uf: in UnionField): TypeExpr {
  match uf {
    case UFNamed(_, ty, _) -> ty
    case UFPos(ty, _) -> ty
  }
}

// Register ctor + field MemberRefs for one union case; fields registered under both declared name and positional key for alias-binding resolution. Generic cases use MTypeVar so sigs byte-match DLL FIELD VAR(n) declarations; arity-suffixed TypeRef for TypeSpec-parented instructions (#3099).
func registerRestoredUnionCase(
  cctx: in CodegenCtx,
  packageName: in String,
  unionName: in String,
  c: in UnionCase,
  asmRefRow: in Int,
  uGenerics: in List[String],
): Unit {
  val caseClassName = unionName + "_" + c.name
  val caseFqn = packageName + "." + caseClassName
  if cctx.recordCtorTokens.containsKey(caseFqn) {
    return
  }
  if not cctx.caseParentUnion.containsKey(caseFqn) {
    cctx.caseParentUnion.add(caseFqn, packageName + "." + unionName)
  }

  val typeRefRow = ensureCaseClassTypeRefRow(cctx, packageName, caseClassName, asmRefRow, uGenerics.count)

  val ctorParams: List[MsilType] = newList()
  var fi = 0
  while fi < c.fields.count {
    val uf = c.fields[fi]
    val rawTy = unionFieldType(uf)
    val fty = if uGenerics.count > 0 {
      typeExprToMsilG(cctx, rawTy, packageName, uGenerics)
    } else {
      typeExprToMsilCtx(cctx, rawTy, packageName)
    }
    val gIdx = match fty { case MTypeVar(idx) -> idx; case _ -> -1 }
    val fSig = if gIdx >= 0 { buildGenericParamFieldSig(gIdx) } else { buildFieldSigWithCtx(fty, cctx.lctx) }
    ctorParams.add(fty)
    // Register field MemberRef under declared name + positional alias; seeds fieldSigBytes/fieldVarIndices for MLdfldGeneric Phase 5 path (#3099).
    match uf {
      case UFNamed(fname, _, _) -> {
        val nameKey = caseFqn + "/" + fname
        if not cctx.fieldTokens.containsKey(nameKey) {
          val nameSigKey = "restored_ucfield_" + nameKey
          val nameFieldRow = ctxAddMemberRef(cctx.lctx, typeRefRow, fname, nameSigKey, fSig)
          val tok = 0x0A000000 + nameFieldRow
          cctx.fieldTokens.add(nameKey, tok)
          // Store MObject for type-variable fields so pushCollExpect doesn't treat arg as a collection element; VAR index tracked in fieldVarIndices for MLdfldGeneric path.
          val hintTy = if gIdx >= 0 { MObject } else { fty }
          cctx.fieldMsilTypes.add(nameKey, hintTy)
          if not cctx.fieldSigBytes.containsKey(nameKey) {
            cctx.fieldSigBytes.add(nameKey, fSig)
          }
          if not cctx.fieldVarIndices.containsKey(nameKey) {
            cctx.fieldVarIndices.add(nameKey, gIdx)
          }
          // Also register the positional alias pointing to the same MemberRef.
          val posKey = caseFqn + "/field" + toString(fi)
          if not cctx.fieldTokens.containsKey(posKey) {
            cctx.fieldTokens.add(posKey, tok)
            cctx.fieldMsilTypes.add(posKey, hintTy)
          }
          if not cctx.fieldSigBytes.containsKey(posKey) {
            cctx.fieldSigBytes.add(posKey, fSig)
          }
          if not cctx.fieldVarIndices.containsKey(posKey) {
            cctx.fieldVarIndices.add(posKey, gIdx)
          }
          if not cctx.fieldDeclaredNames.containsKey(posKey) {
            cctx.fieldDeclaredNames.add(posKey, fname)
          }
        }
      }
      case UFPos(_, _) -> {
        // Positional-only case: the DLL field is named "field<i>".
        val posKey = caseFqn + "/field" + toString(fi)
        if not cctx.fieldTokens.containsKey(posKey) {
          val posSigKey = "restored_ucfield_" + posKey
          val posFieldRow = ctxAddMemberRef(cctx.lctx, typeRefRow, "field" + toString(fi), posSigKey, fSig)
          cctx.fieldTokens.add(posKey, 0x0A000000 + posFieldRow)
          cctx.fieldMsilTypes.add(posKey, if gIdx >= 0 { MObject } else { fty })
          if not cctx.fieldSigBytes.containsKey(posKey) {
            cctx.fieldSigBytes.add(posKey, fSig)
          }
          if not cctx.fieldVarIndices.containsKey(posKey) {
            cctx.fieldVarIndices.add(posKey, gIdx)
          }
        }
      }
    }
    fi = fi + 1
  }

  val ctorSig = buildInstanceMethodSigWithCtx(ctorParams, MVoid, cctx.lctx)
  val sigKey = "restored_ucase_" + caseFqn
  val memberRow = ctxAddMemberRef(cctx.lctx, typeRefRow, ".ctor", sigKey, ctorSig)
  cctx.recordCtorTokens.add(caseFqn, 0x0A000000 + memberRow)

  // For generic union cases, route construction through buildInBundleGenericCtorTok
  // (which emits MNewobjGenericByName → TypeSpec-parented .ctor at Phase 5) and
  // produce an MGenericInstByName result type (needed for correct isinst / ldfld
  // via MIsinstGeneric / MLdfldGeneric with arity-suffixed class names).
  if uGenerics.count > 0 {
    if not cctx.genericTypeArity.containsKey(caseFqn) {
      cctx.genericTypeArity.add(caseFqn, uGenerics.count)
    }
    if not cctx.genericCtorParams.containsKey(caseFqn) {
      cctx.genericCtorParams.add(caseFqn, ctorParams)
    }
  }
}

// Walk every case of a union and register its case-class ctor.
// For generic unions, also seeds the arity-suffixed TypeRef for the union base
// and genericTypeArity so typeExprToMsilCtx returns MGenericInstByName for
// type annotations like `val m: Maybe[Int]`.
func registerRestoredUnion(cctx: in CodegenCtx, packageName: in String, decl: in UnionDecl, asmRefRow: in Int): Unit {
  val uGenerics = genericNamesOf(decl.generics)
  val uArity = uGenerics.count
  val unionFqn = packageName + "." + decl.name

  // The self-hosted MSIL emitter names generic union TypeDefs with an arity
  // suffix (e.g. "Maybe`1`").  Register the suffixed TypeRef so that
  // bufMsilTypeWithCtx correctly encodes MGenericInstByName in method and
  // field signatures.  Also register genericTypeArity so typeExprToMsilCtx
  // routes `Maybe[Int]` through the by-name path rather than the plain
  // ffiTypeRefs path (which carries the wrong TypeRef name).
  if uArity > 0 {
    val arityName = decl.name + "`" + toString(uArity)
    ctxAddTypeRef(cctx.lctx, packageName, arityName, asmRefRow)
    if not cctx.genericTypeArity.containsKey(unionFqn) {
      cctx.genericTypeArity.add(unionFqn, uArity)
    }
  }

  var ci = 0
  while ci < decl.cases.count {
    registerRestoredUnionCase(cctx, packageName, decl.name, decl.cases[ci], asmRefRow, uGenerics)
    ci = ci + 1
  }
}

// Walk the artifact's parsed source and seed MemberRef tokens for
// every record ctor, every public free function, and every union
// case's ctor.  Skips items whose TypeRef wasn't allocated and
// private funcs (no public surface).
func registerRestoredMembers(cctx: in CodegenCtx, art: in SynthesisedArtifact): Unit {
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
      case IEnum(decl) -> {
        // Restored enums use the same ordinal-int model as in-bundle ones
        // (#3196): the type name maps signature positions to I4 and each
        // case resolves to its ldc.i4 ordinal at consumer call sites.
        registerEnumDeclMsil(cctx, art.packageName, decl)
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
  //
  // Build a simple-name → InterfaceDecl map first so each registerRestoredImpl
  // call is O(1) instead of O(N) (avoids O(N×M) total across all impl blocks).
  val ifaceByName: Map[String, InterfaceDecl] = newMap()
  var ib = 0
  while ib < items.count {
    match items[ib].kind {
      case IInterface(idecl) -> {
        if not ifaceByName.containsKey(idecl.name) {
          ifaceByName.add(idecl.name, idecl)
        }
      }
      case _ -> ()
    }
    ib = ib + 1
  }
  var ii = 0
  while ii < items.count {
    match items[ii].kind {
      case IImpl(idecl) -> registerRestoredImpl(cctx, art, idecl, ifaceByName)
      case _ -> ()
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
func registerRestoredImpl(
  cctx: in CodegenCtx,
  art: in SynthesisedArtifact,
  idecl: in ImplDecl,
  ifaceByName: in Map[String, InterfaceDecl],
): Unit {
  val targetName = implTargetNameMsil(idecl, art.packageName)
  // implTargetNameMsil returns "<pkg>.<Name>" or a "__impl_target" sentinel.
  if endsWith(targetName, ".__impl_target") {
    return
  }
  val recordTypeRefRow = lookupRestoredTypeRefRowByFqn(cctx, art.packageName, targetName)
  if recordTypeRefRow == 0 {
    return
  }

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
              case IMSig(sig) -> registerRestoredRecordMethod(cctx, targetName, recordTypeRefRow, art.packageName, sig.name, sig.params, sig.ret)
              case IMFunc(fn) -> registerRestoredRecordMethod(cctx, targetName, recordTypeRefRow, art.packageName, fn.name, fn.params, fn.ret)
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
func registerRestoredRecordMethod(
  cctx: in CodegenCtx,
  recordFqn: in String,
  recordTypeRefRow: in Int,
  packageName: in String,
  methodName: in String,
  params: in List[Param],
  ret: in Option[TypeExpr],
): Unit {
  val key = recordFqn + "/" + methodName
  if cctx.methodTokens.containsKey(key) {
    return
  }

  val sigParamTypes: List[MsilType] = newList()
  var spi = 0
  while spi < params.count {
    sigParamTypes.add(typeExprToMsilCtx(cctx, params[spi].ty, packageName))
    spi = spi + 1
  }
  val sigRetType = match ret { case Some(te) -> typeExprToMsilCtx(cctx, te, packageName); case None -> MVoid }
  val sig = buildInstanceMethodSig(sigParamTypes, sigRetType)
  val sigKey = "restored_recmethod_" + key
  val memberRow = ctxAddMemberRef(cctx.lctx, recordTypeRefRow, methodName, sigKey, sig)
  cctx.methodTokens.add(key, 0x0A000000 + memberRow)
  if not cctx.methodRetTypes.containsKey(key) {
    val realRetType = match ret { case Some(te) -> typeExprToMsilCtx(cctx, te, packageName); case None -> MVoid }
    cctx.methodRetTypes.add(key, realRetType)
  }
}

// Look up a restored type's TypeRef row by its fully-qualified `<pkg>.<Name>`
// form (the shape `implTargetNameMsil` produces).  Returns 0 when absent.
func lookupRestoredTypeRefRowByFqn(cctx: in CodegenCtx, packageName: in String, fqn: in String): Int {
  val typeRefKey = packageName + "/" + fqn
  match mapGet(cctx.ffiTypeRefs, typeRefKey) {
    case Some(row) -> row
    case None -> 0
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
func registerRestoredInterface(cctx: in CodegenCtx, packageName: in String, decl: in InterfaceDecl): Unit {
  val ifaceFqn = packageName + "." + decl.name
  val typeRefRow = lookupRestoredTypeRefRow(cctx, packageName, decl.name)
  if typeRefRow == 0 {
    return
  }
  var mi = 0
  while mi < decl.members.count {
    match decl.members[mi] {
      case IMSig(sig) -> registerRestoredIfaceMethod(cctx, ifaceFqn, typeRefRow, packageName, sig.name, sig.params, sig.ret)
      case IMFunc(fn) -> registerRestoredIfaceMethod(cctx, ifaceFqn, typeRefRow, packageName, fn.name, fn.params, fn.ret)
      case IMAssoc(_) -> ()
    }
    mi = mi + 1
  }
}

// Allocate the MemberRef for one restored interface method and record its
// token + return type.  The signature is HASTHIS (instance dispatch); the
// receiver is the implicit `this`, so only the declared params are encoded.
func registerRestoredIfaceMethod(
  cctx: in CodegenCtx,
  ifaceFqn: in String,
  typeRefRow: in Int,
  packageName: in String,
  methodName: in String,
  params: in List[Param],
  ret: in Option[TypeExpr],
): Unit {
  val key = ifaceFqn + "/" + methodName
  if cctx.methodTokens.containsKey(key) {
    return
  }

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
    sigParamTypes.add(typeExprToMsilCtx(cctx, params[spi].ty, packageName))
    spi = spi + 1
  }
  val sigRetType = match ret { case Some(te) -> typeExprToMsilCtx(cctx, te, packageName); case None -> MVoid }
  val sig = buildInstanceMethodSig(sigParamTypes, sigRetType)
  val sigKey = "restored_iface_" + key
  val memberRow = ctxAddMemberRef(cctx.lctx, typeRefRow, methodName, sigKey, sig)
  cctx.methodTokens.add(key, 0x0A000000 + memberRow)
  // Record the FULLY-RESOLVED return type (ctx-aware, so `Result[T, E]` keeps
  // its `MGenericInst` identity) for the call site.  This is what the
  // consumer's `match` on the call result needs to emit correct isinst tests —
  // distinct from the erased `object` used in the signature blob above.
  if not cctx.methodRetTypes.containsKey(key) {
    val realRetType = match ret { case Some(te) -> typeExprToMsilCtx(cctx, te, packageName); case None -> MVoid }
    cctx.methodRetTypes.add(key, realRetType)
  }
}

// ── Range-subtype bound folding (#1501) ──────────────────────────────────────
// A folded numeric range bound.  `ok` is false when the bound is not a literal
// (named const, arithmetic, …) the codegen folder can evaluate — in which case
// no runtime bounds check is emitted (rather than a silently wrong one).
record RangeBoundVal {
  ok: Bool
  isFloat: Bool
  l: Long
  d: Double
}

func foldRangeBound(e: in Expr): RangeBoundVal {
  val failVal = RangeBoundVal(ok = false, isFloat = false, l = 0, d = 0.0)
  match e.kind {
    case ELiteral(lit) -> {
      match lit {
        case LInt(v, _, _) -> RangeBoundVal(ok = true, isFloat = false, l = v, d = 0.0)
        case LFloat(v, _, _) -> RangeBoundVal(ok = true, isFloat = true, l = 0, d = v)
        case _ -> failVal
      }
    }
    case EPrefix(op, operand) -> {
      match op {
        case PreNeg -> {
          val inner = foldRangeBound(operand)
          if inner.ok {
            RangeBoundVal(ok = true, isFloat = inner.isFloat, l = 0 - inner.l, d = 0.0 - inner.d)
          } else {
            failVal
          }
        }
        case _ -> failVal
      }
    }
    case _ -> failVal
  }
}

func mkDistinctRanged(
  className: in String,
  namespace: in String,
  inner: in MsilType,
  loE: in Expr,
  hiE: in Expr,
  upperExcl: in Bool,
): MDistinctType {
  val lo = foldRangeBound(loE)
  val hi = foldRangeBound(hiE)
  val isFloatInner = match inner { case MDouble -> true; case _ -> false }
  if lo.ok and hi.ok {
    val loF = if lo.isFloat { lo.d } else { lo.l.toDouble() }
    val hiF = if hi.isFloat { hi.d } else { hi.l.toDouble() }
    MDistinctType(
      className = className,
      namespace = namespace,
      inner = inner,
      hasRange = true,
      rangeIsFloat = isFloatInner,
      minI = lo.l,
      maxI = hi.l,
      minF = loF,
      maxF = hiF,
      upperExclusive = upperExcl
    )
  } else {
    MDistinctType(
      className = className,
      namespace = namespace,
      inner = inner,
      hasRange = false,
      rangeIsFloat = false,
      minI = 0,
      maxI = 0,
      minF = 0.0,
      maxF = 0.0,
      upperExclusive = false
    )
  }
}

// Build the distinct-type IR item, folding any range clause to integer/float
// bounds for the synthesised `from`/`tryFrom` validation.
func mkDistinctTypeIR(
  className: in String, namespace: in String, inner: in MsilType, rangeClause: in Option[RangeBound]
): MDistinctType {
  val noRange = MDistinctType(
    className = className,
    namespace = namespace,
    inner = inner,
    hasRange = false,
    rangeIsFloat = false,
    minI = 0,
    maxI = 0,
    minF = 0.0,
    maxF = 0.0,
    upperExclusive = false
  )
  match rangeClause {
    case Some(rb) -> {
      match rb {
        case RBClosed(loE, hiE) -> mkDistinctRanged(className, namespace, inner, loE, hiE, false)
        case RBHalfOpen(loE, hiE) -> mkDistinctRanged(className, namespace, inner, loE, hiE, true)
        // Unknown RangeBound variant: emit no-range guard so future variants
        // don't silently skip range validation (#3116).
        case _ -> noRange
      }
    }
    case None -> noRange
  }
}

// Fold a module-level const/val initializer to its inlined Int value,
// mirroring the `addPackageTokens` IConst/IVal fold: lower the init and
// take the leading `ldc.i4`.  Used to register a restored package's
// compile-time constants for cross-package inlining.
func foldConstInitToInt(cctx: in CodegenCtx, pkgName: in String, init: in Expr): Int {
  val fctx = makeFuncCtxMsil(pkgName, pkgName, "__const_fold", 0, MVoid)
  val insns: List[MInsn] = newList()
  lowerExprMsil(cctx, fctx, insns, init)
  match insns.count {
    // Unreachable fallback: contract_meta.l only emits integer-literal inits
    // into the contract repr, so lowerExprMsil always produces MLdcI4 here.
    // If the invariant were violated the consumer would silently inline 0 (#2741).
    case n if n > 0 -> match insns[0] { case MLdcI4(v) -> v; case _ -> 0 }
    case _ -> 0
  }
}

/// Walk every `SynthesisedArtifact` in `cctx.restoredArtifacts` and
/// register its type-shaped public decls into the cross-package
/// symbol tables.  Call once after `newCodegenCtx`, before the
/// per-package `addPackageTokens` pre-scan.
pub func registerRestoredArtifactTokens(cctx: in CodegenCtx): Unit {
  // Global two-pass registration (mirrors `registerStdlibArtifactTokens`):
  // ALL types across ALL artifacts are registered before ANY member
  // signature is encoded.  A per-artifact pass would resolve a function
  // whose signature references a *sibling* package's type before that
  // sibling's TypeRef exists, silently erasing the cross-package type to
  // `System.Object` — so the consumer's MemberRef physical signature
  // (`Object parse(String)`) no longer matches the producer DLL's real
  // method (`ParseResult parse(String)`) and the loader faults with
  // `Method not found` at run time.  The global ordering guarantees, e.g.,
  // `Lyric.Parser`'s `ParseResult` TypeRef exists before `Lyric.Weaver`'s
  // functions (which return Parser-typed values) are encoded.
  //
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
  //
  // Pass 1: types (TypeRef rows + name lookups) for every artifact.
  var ai = 0
  while ai < cctx.restoredArtifacts.count {
    val art = cctx.restoredArtifacts[ai]
    if startsWith(art.packageName, "Std.") {
      ai = ai + 1
      continue
    }
    val asmRefRow = ensureAssemblyRefForArtifact(cctx, art.packageName)
    var di = 0
    while di < art.contract.decls.count {
      val decl = art.contract.decls[di]
      val k = decl.kind
      if k == "record" or k == "union" or k == "enum" or k == "interface" or k == "opaque" or k == "distinct" {
        registerRestoredTypeDecl(cctx, art.packageName, decl, asmRefRow)
      }
      di = di + 1
    }
    ai = ai + 1
  }
  // Pass 2: member MemberRef rows (record ctors / fields, free funcs,
  // union cases, impl methods) now that every type's TypeRef exists.
  // Walks the parsed source instead of the contract decls so we get
  // structured field types for signature encoding.
  var aj = 0
  while aj < cctx.restoredArtifacts.count {
    val art = cctx.restoredArtifacts[aj]
    if startsWith(art.packageName, "Std.") {
      aj = aj + 1
      continue
    }
    registerRestoredMembers(cctx, art)
    aj = aj + 1
  }
  // Pass 3: cross-package compile-time constant inlining.  A module-level
  // `pub const` / `pub val` with an integer-literal initializer is inlined
  // at every use site as `ldc.i4` (codegen `addPackageTokens`).  In a
  // per-package build the consumer compiles separately from the producer,
  // so register each restored package's inlinable constants into
  // `cctx.constValues` here.  The contract writer emits only the
  // integer-literal const/val forms, so every IConst/IVal in the restored
  // synthesised source is registrable.  First-wins (containsKey guard)
  // matches the other cross-package registration guards; Std.* is included
  // (a no-op unless the stdlib contract carries inlinable constants, since
  // const inlining emits `ldc.i4` with no cross-assembly ref — the reason
  // Std.* is skipped in passes 1/2 does not apply here).
  var ac = 0
  while ac < cctx.restoredArtifacts.count {
    val art = cctx.restoredArtifacts[ac]
    var ci = 0
    while ci < art.source.items.count {
      match art.source.items[ci].kind {
        case IConst(decl) -> {
          if not cctx.constValues.containsKey(decl.name) {
            cctx.constValues.add(decl.name, foldConstInitToInt(cctx, art.packageName, decl.init))
          }
        }
        case IVal(decl) -> match decl.pattern.kind { case PBinding(name, _) -> { if not cctx.constValues.containsKey(name) { cctx.constValues.add(name, foldConstInitToInt(cctx, art.packageName, decl.init)) } }; case _ -> () }
        case _ -> ()
      }
      ci = ci + 1
    }
    ac = ac + 1
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
  name: String
  items: List[Item]
  /// Dotted names of the packages this stdlib package itself imports.  Threaded
  /// into `ImportedPackage.imports` so the package's own signatures resolve a
  /// same-named sibling type through its declared imports (tier 2) instead of
  /// last-registered-wins (#2282).
  imports: List[String]
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
pub func registerStdlibArtifactTokens(cctx: in CodegenCtx, pkgs: in List[StdlibPkg]): Unit {
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
        case IFunc(_) -> {
        }
        case _ -> registerStdlibTypeItem(cctx, pkg.name, it, asmRefRow)
      }
      ii = ii + 1
    }
    pi = pi + 1
  }
  // Pass 2: register all function items now that type resolution is complete.
  var pi2 = 0
  while pi2 < pkgs.count {
    val pkg: StdlibPkg = pkgs[pi2]
    val asmRefRow = ensureStdlibAssemblyRef(cctx, pkg.name)
    val hostRefRow = ensureHostClassTypeRefRow(cctx, pkg.name, asmRefRow)
    var ii = 0
    while ii < pkg.items.count {
      val it: Item = pkg.items[ii]
      match it.kind {
        case IFunc(decl) -> registerStdlibFunc(cctx, pkg.name, hostRefRow, decl)
        case _ -> {
        }
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
// Construction helper for an IN-BUNDLE generic record (#2362 / docs/43).
// Counterpart of `buildGenericCaseCtorTok` for in-bundle (TypeDef-backed)
// generic records: emits `MNewobjGenericByName` so the closed-instantiation
// TypeSpec + TypeSpec-parented `.ctor` MemberRef are built at Phase 5 lowering,
// when the record's TypeDef row exists (a direct MethodDef token on a generic
// TypeDef is invalid per ECMA-335 §III.4.21 and faults at load).
//
// `ctorKey`       — the record FQN (e.g. "Pkg.Box").
// `argTypes`      — the lowered constructor-argument MSIL types, in field order.
// `contextTyArgs` — outer instantiation hints for slots not pinned by an arg.
// `outResultTy`   — populated on success with the closed `MGenericInstByName`.
//
// Returns 1 (and emits the newobj) when `ctorKey` is a registered in-bundle
// generic record; 0 otherwise (so the caller falls back to the plain path).
func buildInBundleGenericCtorTok(
  cctx: in CodegenCtx,
  ctorKey: in String,
  argTypes: in List[MsilType],
  contextTyArgs: in List[MsilType],
  outResultTy: in List[MsilType],
  insns: in List[MInsn],
): Int {
  val nTypeParams = match mapGet(cctx.genericTypeArity, ctorKey) { case Some(n) -> n; case None -> return 0 }
  val ctorParams = match mapGet(cctx.genericCtorParams, ctorKey) { case Some(p) -> p; case None -> return 0 }
  // Infer one concrete argument per type-parameter slot: find a ctor param that
  // is `MTypeVar(slot)` and take the matching argument's lowered type; fall back
  // to the outer context hint, then to MObject.
  val typeArgs: List[MsilType] = newList()
  var slot = 0
  while slot < nTypeParams {
    var foundTy: MsilType = MObject
    var i = 0
    while i < ctorParams.count {
      match ctorParams[i] {
        case MTypeVar(ix) -> {
          if ix == slot and i < argTypes.count {
            foundTy = argTypes[i]
          }
        }
        case _ -> {
        }
      }
      i = i + 1
    }
    if foundTy == MObject and slot < contextTyArgs.count {
      val ctxTy = contextTyArgs[slot]
      if ctxTy != MObject {
        foundTy = ctxTy
      }
    }
    typeArgs.add(foundTy)
    slot = slot + 1
  }
  // The CLR-canonical (arity-suffixed) name resolves against the suffixed
  // TypeDef the lowering layer emits; the plain `ctorKey` remains the codegen
  // map key.  `newobj` allocates the concrete CASE class.
  val headFqn = genericBacktickFqn(ctorKey, nTypeParams)
  insns.add(MNewobjGenericByName(headFqn = headFqn, typeArgs = typeArgs, ctorParams = ctorParams))
  // The static result type is the PARENT union for a union case (`Just(5)` has
  // type `Maybe[Int]`, not `Maybe_Just[Int]`), or the type itself for a plain
  // generic record.  Both share the same type-argument list.
  val parentFqn = match mapGet(cctx.caseParentUnion, ctorKey) { case Some(p) -> p; case None -> ctorKey }
  val parentArity = match mapGet(cctx.genericTypeArity, parentFqn) { case Some(n) -> n; case None -> nTypeParams }
  outResultTy.add(MGenericInstByName(headFqn = genericBacktickFqn(parentFqn, parentArity), typeArgs = typeArgs))
  1
}

func buildGenericCaseCtorTok(
  cctx: in CodegenCtx,
  ctorKey: in String,
  argTypes: in List[MsilType],
  contextTyArgs: in List[MsilType],
  outParentTy: in List[MsilType],
  insns: in List[MInsn],
): Int {
  val nTypeParams = match mapGet(cctx.caseTypeParamCount, ctorKey) { case Some(n) -> n; case None -> return 0 }
  // Locate case-class TypeRef row.
  val dotIdx0 = ctorKey.lastIndexOf(".")
  if dotIdx0 < 0 {
    return 0
  }
  val pkgPart = ctorKey.substring(0, dotIdx0)
  val caseRefKey = pkgPart + "/" + ctorKey
  val caseRefRow = match mapGet(cctx.ffiTypeRefs, caseRefKey) { case Some(r) -> r; case None -> return 0 }
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
      val vi = match mapGet(cctx.fieldVarIndices, fldKey) { case Some(v) -> v; case None -> -1 }
      if vi == tpi {
        foundTy = argTypes[fi]
      }
      fi = fi + 1
    }
    if foundTy == MObject and tpi < contextTyArgs.count {
      val ctxTy = contextTyArgs[tpi]
      if ctxTy != MObject {
        foundTy = ctxTy
      }
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
    val vi2 = match mapGet(cctx.fieldVarIndices, fldKey2) { case Some(v) -> v; case None -> -1 }
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
    val parentFqn = pkgPart + "." + unionLocal
    val parentKey = pkgPart + "/" + parentFqn
    match mapGet(cctx.ffiTypeRefs, parentKey) {
      case Some(parentRow) -> outParentTy.add(MGenericInst(typeRefCode = tdrTypeRef(parentRow), headFqn = parentFqn, typeArgs = typeArgs))
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
func registerStdlibTypeItem(cctx: in CodegenCtx, packageName: in String, it: in Item, asmRefRow: in Int): Unit {
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
    // Stdlib enums use the ordinal-int model (#3196) — no TypeRef rows are
    // needed because enum values never appear as reference types in IL.
    case IEnum(decl) -> {
      registerEnumDeclMsil(cctx, packageName, decl)
      return
    }
    case _ -> {
    }
  }
  val typeName = match it.kind {
    case IRecord(decl) -> decl.name
    case IExposedRec(decl) -> decl.name
    case IUnion(decl) -> decl.name
    case IEnum(decl) -> decl.name
    case IInterface(decl) -> decl.name
    case IOpaque(decl) -> decl.name
    case IDistinctType(decl) -> decl.name
    case IProtected(decl) -> decl.name
    case _ -> return
  }
  val typeFqn = packageName + "." + typeName
  val typeRefKey = packageName + "/" + typeFqn
  if not cctx.ffiTypeRefs.containsKey(typeRefKey) {
    val row = ctxAddTypeRef(cctx.lctx, packageName, typeName, asmRefRow)
    cctx.ffiTypeRefs.add(typeRefKey, row)
  }
  registerTypeFqnCandidate(cctx, typeName, typeFqn)
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
              case _ -> {
              }
            }
            gi = gi + 1
          }
          gps.params.count
        }
        case None -> 0
      }
      var ci = 0
      while ci < decl.cases.count {
        val caseName = decl.cases[ci].name
        val ctorKey = packageName + "." + decl.name + "_" + caseName
        val caseClassName = decl.name + "_" + caseName
        val caseRefKey = packageName + "/" + ctorKey
        // Register case-class TypeRef so MIsinstByName can find it via
        // findTypeRefRowByName instead of falling back to System.Object.
        if not cctx.ffiTypeRefs.containsKey(caseRefKey) {
          val caseRow = ctxAddTypeRef(cctx.lctx, packageName, caseClassName, asmRefRow)
          cctx.ffiTypeRefs.add(caseRefKey, caseRow)
        }
        val caseRow = match mapGet(cctx.ffiTypeRefs, caseRefKey) { case Some(r) -> r; case None -> 0 }
        // Register field MemberRefs so `ldfld` can read fields of cross-assembly
        // union case instances.  Registered both by declared name ("value") and by
        // positional index ("field0") so that binding patterns like `case Some(x)`
        // resolve via the positional fallback.
        if caseRow > 0 {
          var fi = 0
          while fi < decl.cases[ci].fields.count {
            val field = decl.cases[ci].fields[fi]
            val declaredName = match field { case UFNamed(name, _, _) -> name; case UFPos(_, _) -> "field" + toString(fi) }
            // For generic-parameter fields (e.g. `value: T`), emit VAR(n) in the
            // field sig to match the F# bootstrap emitter's output.  For concrete
            // types, fall back to Object.  Also track the VAR index (-1 for
            // non-generic fields) in fieldVarIdx so lowerPatternBindMsil can
            // recover the concrete bound-variable type without byte-level access.
            var fieldVarIdx = -1
            val fieldSig = match field {
              case UFNamed(_, ty, _) -> {
                val seg = match ty.kind {
                  case TRef(path) -> if path.segments.count == 1 { path.segments[0] } else { "" }
                  case _ -> ""
                }
                if seg.length > 0 {
                  match mapGet(typeParamVarIdx, seg) {
                    case Some(varIdx) -> {
                      fieldVarIdx = varIdx
                      buildGenericParamFieldSig(varIdx)
                    }
                    case None -> buildFieldSig(MObject)
                  }
                } else {
                  buildFieldSig(MObject)
                }
              }
              case UFPos(ty, _) -> {
                val seg = match ty.kind {
                  case TRef(path) -> if path.segments.count == 1 { path.segments[0] } else { "" }
                  case _ -> ""
                }
                if seg.length > 0 {
                  match mapGet(typeParamVarIdx, seg) {
                    case Some(varIdx) -> {
                      fieldVarIdx = varIdx
                      buildGenericParamFieldSig(varIdx)
                    }
                    case None -> buildFieldSig(MObject)
                  }
                } else {
                  buildFieldSig(MObject)
                }
              }
            }
            val sigKey = "stdlib_field_" + ctorKey + "_" + declaredName
            val fieldMrRow = ctxAddMemberRef(cctx.lctx, caseRow, declaredName, sigKey, fieldSig)
            val fieldTok = 0x0A000000 + fieldMrRow
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
            val cpTy = match cpField { case UFNamed(_, ty, _) -> ty; case UFPos(ty, _) -> ty }
            val cpSeg = match cpTy.kind {
              case TRef(path) -> if path.segments.count == 1 { path.segments[0] } else { "" }
              case _ -> ""
            }
            val cpMsilTy: MsilType = if cpSeg.length > 0 {
              match mapGet(typeParamVarIdx, cpSeg) {
                case Some(varIdx) -> MTypeVar(index = varIdx)
                case None -> MObject
              }
            } else {
              MObject
            }
            ctorParams2.add(cpMsilTy)
            cpi = cpi + 1
          }
          val ctorSig2 = buildInstanceMethodSig(ctorParams2, MVoid)
          val ctorSigKey = "stdlib_case_ctor_" + ctorKey
          val ctorMrRow = ctxAddMemberRef(cctx.lctx, caseRow, ".ctor", ctorSigKey, ctorSig2)
          if not cctx.recordCtorTokens.containsKey(ctorKey) {
            cctx.recordCtorTokens.add(ctorKey, 0x0A000000 + ctorMrRow)
          }
          // Register type-param count for TypeSpec-based newobj building at
          // construction sites (ECMA-335 §III.4.21).
          if unionTypeParamCount > 0 and not cctx.caseTypeParamCount.containsKey(ctorKey) {
            cctx.caseTypeParamCount.add(ctorKey, unionTypeParamCount)
          }
        }
        if cctx.unionCaseCtorByName.containsKey(caseName) {
          match mapGet(cctx.unionCaseCtorByName, caseName) {
            case Some(lst) -> {
              if not lst.contains(ctorKey) {
                lst.add(ctorKey)
              }
            }
            case None -> ()
          }
        } else {
          val ctorKeyList2: List[String] = newList()
          ctorKeyList2.add(ctorKey)
          cctx.unionCaseCtorByName.add(caseName, ctorKeyList2)
        }
        if not cctx.caseParentUnion.containsKey(ctorKey) {
          cctx.caseParentUnion.add(ctorKey, packageName + "." + decl.name)
        }
        ci = ci + 1
      }
    }
    case IRecord(decl) -> registerStdlibRecordLikeType(cctx, decl, typeRefKey, typeFqn, packageName)
    case IExposedRec(decl) -> registerStdlibRecordLikeType(cctx, decl, typeRefKey, typeFqn, packageName)
    case _ -> ()
  }
}

// Shared by the IRecord and IExposedRec arms of `registerStdlibTypeItem`
// (#2922): both carry a `RecordDecl` and register identical metadata — field
// MemberRefs (by declared name and positional fallback), field MsilTypes, and
// the ctor MemberRef.  The exposed/opaque distinction does not change what a
// cross-assembly consumer references.
func registerStdlibRecordLikeType(
  cctx: in CodegenCtx,
  decl: in RecordDecl,
  typeRefKey: in String,
  typeFqn: in String,
  packageName: in String,
): Unit {
  val typeRefRow = match mapGet(cctx.ffiTypeRefs, typeRefKey) { case Some(r) -> r; case None -> 0 }
  if typeRefRow > 0 {
    var fi = 0
    var fpos = 0
    while fi < decl.members.count {
      match decl.members[fi] {
        case RMField(f) -> {
          val key = typeFqn + "/" + f.name
          if not cctx.fieldTokens.containsKey(key) {
            val fty = typeExprToMsilCtx(cctx, f.ty, packageName)
            val fSig = buildFieldSigWithCtx(fty, cctx.lctx)
            val sigKey = "stdlib_field_" + key
            val memberRow = ctxAddMemberRef(cctx.lctx, typeRefRow, f.name, sigKey, fSig)
            cctx.fieldTokens.add(key, 0x0A000000 + memberRow)
            if not cctx.fieldMsilTypes.containsKey(key) {
              cctx.fieldMsilTypes.add(key, fty)
            }
          }
          val byPosKey = typeFqn + "/field" + toString(fpos)
          if not cctx.fieldDeclaredNames.containsKey(byPosKey) {
            cctx.fieldDeclaredNames.add(byPosKey, f.name)
          }
          fpos = fpos + 1
        }
        case _ -> ()
      }
      fi = fi + 1
    }
    val ctorParams: List[MsilType] = newList()
    var ci = 0
    while ci < decl.members.count {
      match decl.members[ci] {
        case RMField(f) -> ctorParams.add(typeExprToMsilCtx(cctx, f.ty, packageName))
        case _ -> ()
      }
      ci = ci + 1
    }
    val ctorSig = buildInstanceMethodSig(ctorParams, MVoid)
    val ctorSigKey = "stdlib_ctor_" + typeFqn
    val ctorMrRow = ctxAddMemberRef(cctx.lctx, typeRefRow, ".ctor", ctorSigKey, ctorSig)
    if not cctx.recordCtorTokens.containsKey(typeFqn) {
      cctx.recordCtorTokens.add(typeFqn, 0x0A000000 + ctorMrRow)
    }
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
func ensureStdlibAssemblyRef(cctx: in CodegenCtx, packageName: in String): Int {
  if cctx.ffiAsmRefs.containsKey(packageName) {
    match mapGet(cctx.ffiAsmRefs, packageName) {
      case Some(row) -> return row
      case None -> ()
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
  if segs.count == 0 {
    return "Lyric.Unknown"
  }
  val head = segs[0]
  // Concatenate tail segments WITHOUT separators — mirrors the F# emitter's
  // `String.concat "" rest` convention (Emitter.fs).  E.g. "Std.Testing.Mocking"
  // → tail = "TestingMocking" → "Lyric.Stdlib.TestingMocking", matching the
  // F#-emitted DLL name.  Single-segment tails are unaffected.
  var tail = ""
  var i = 1
  while i < segs.count {
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
  if rest.length > 0 {
    segs.add(rest)
  }
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
// Reuses `buildStaticMethodSigWithCtx` + `typeExprToMsilCtx` so the
// signature blob matches the encoding the F# emitter would emit on
// the producer side.  The ctx-aware encoder is required so a generic
// return whose type argument is a reference type (`MClass`) — e.g.
// `Std.File.readText : Result[String, IOError]` — resolves the arg to its
// real TypeRef (`Result<String, Std.Errors.IOError>`) instead of degrading
// it to `object` (`Result<String, object>`), which would not bind against
// the F#-built producer's concrete signature at run time.  Mirrors
// `registerRestoredFunc`, which already uses the ctx-aware builder.
// On resolution error, inherits `registerRestoredFunc`'s policy: the
// unresolvable slot degrades to MObject in the encoded signature (#2821).
func registerStdlibFunc(cctx: in CodegenCtx, packageName: in String, hostRefRow: in Int, fn: in FunctionDecl): Unit {
  val isPub = match fn.visibility { case Some(VisPub(_)) -> true; case _ -> false }
  if not isPub {
    return
  }
  val fqn = packageName + "." + fn.name
  val arityKey = fqn + "/" + toString(fn.params.count)

  // F#-built producer: a `Unit`/`Never` generic ARGUMENT encodes as
  // System.ValueTuple at value position (xrefUnitArgsToValueTuple), so this
  // cross-package reference byte-matches `Result[Unit, E]` / `Option[Unit]`
  // returns and binds (D-progress-469 facet 3).  In-bundle definitions keep
  // the object-argument representation, so they are untouched.
  val paramTypes: List[MsilType] = newList()
  var pi = 0
  while pi < fn.params.count {
    paramTypes.add(xrefUnitArgsToValueTuple(cctx, typeExprToMsilCtx(cctx, fn.params[pi].ty, packageName)))
    pi = pi + 1
  }
  val retType = match fn.ret {
    case Some(te) -> xrefUnitArgsToValueTuple(cctx, typeExprToMsilCtx(cctx, te, packageName))
    case None -> MVoid
  }
  val funcSig = buildStaticMethodSigWithCtx(byrefWrapSigTypes(fn.params, paramTypes), retType, cctx.lctx)
  val fnModes = paramModesOf(fn.params)
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
    val sigKey = "stdlib_func_" + arityKey
    val memberRow = ctxAddMemberRef(cctx.lctx, hostRefRow, fn.name, sigKey, funcSig)
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
