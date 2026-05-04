/// Per-record info collected by the emitter so codegen can lower
/// `Point(x = 3, y = 4)` constructor calls and `p.x` field reads to
/// the matching IL.
///
/// Phase 1 keeps records minimal: a sealed CLR class with public
/// readonly fields in declaration order, and a single all-fields
/// constructor. The auto-generated `Equals` / `GetHashCode` / `copy`
/// machinery from the strategy doc lands in later slices.
module Lyric.Emitter.Records

open System.Collections.Generic
open System.Reflection
open System.Reflection.Emit

type private ClrType = System.Type

/// One field of a Lyric record, post-CLR-lowering.  `LyricType`
/// preserves the original shape so call-site type-arg inference can
/// recover structural information (record generics push their GTPBs
/// into the field's CLR type but the Lyric type still has the
/// original `TyVar` / compound shape).
type RecordField =
    { Name:      string
      Type:      ClrType
      LyricType: Lyric.TypeChecker.Type
      Field:     FieldBuilder }

/// What the codegen needs to know about a Lyric record.  `Generics`
/// is the user-declared type-parameter names in declaration order,
/// or `[]` for non-generic records.
type RecordInfo =
    { Name:     string
      Type:     TypeBuilder
      Fields:   RecordField list
      Ctor:     ConstructorBuilder
      Generics: string list }

/// Per-emit table of records visible at codegen time.
type RecordTable = Dictionary<string, RecordInfo>

/// One case of a Lyric enum, post-CLR-lowering.
type EnumCase =
    { Name:    string
      Ordinal: int }

/// What the codegen needs to know about a Lyric enum.
type EnumInfo =
    { Name:  string
      /// The closed CLR enum type backing the Lyric enum.
      Type:  ClrType
      Cases: EnumCase list }

type EnumTable = Dictionary<string, EnumInfo>

/// Reverse lookup: bare or qualified case name → (parent enum, ordinal).
/// Populated alongside `EnumTable` so codegen can resolve `Red` and
/// `Color.Red` symmetrically.
type EnumCaseLookup = Dictionary<string, EnumInfo * EnumCase>

// ---------------------------------------------------------------------------
// Variant-bearing unions (sum types with per-case payloads).
//
// Each union lowers to:
//   * An abstract sealed-hierarchy base class (the user-visible type).
//   * One sealed subclass per case carrying that case's payload as
//     public readonly fields plus an all-fields constructor.
// Per D035 the payload-field types are *erased* in M1.4: TyVar / TyUser
// arguments lower to `obj`. Reified generics is a Phase 2 follow-up.
// ---------------------------------------------------------------------------

/// One payload field of a union case. Named to avoid clashing with
/// the parser AST's `UnionField` discriminator.  `LyricType` is kept
/// (in addition to the lowered `Type`) so codegen can run reified-
/// generic type-arg inference when the union itself is generic.
type UnionPayloadField =
    { Name:      string
      Type:      ClrType
      LyricType: Lyric.TypeChecker.Type
      Field:     FieldBuilder }

/// One case of a Lyric union, post-CLR-lowering.
type UnionCaseInfo =
    { Name:    string
      /// Sealed CLR class implementing the case.
      Type:    TypeBuilder
      Fields:  UnionPayloadField list
      Ctor:    ConstructorBuilder }

/// What the codegen needs to know about a Lyric union.  `Generics` is
/// the (ordered) list of type-parameter names — empty for non-generic
/// unions, otherwise driving codegen's `MakeGenericType` calls.
type UnionInfo =
    { Name:     string
      /// Abstract base class — the union's user-visible CLR type.
      /// For generic unions this is the open generic definition.
      Type:     TypeBuilder
      Cases:    UnionCaseInfo list
      Generics: string list }

type UnionTable = Dictionary<string, UnionInfo>

/// Reverse lookup: bare or qualified case name → (parent union, case info).
type UnionCaseLookup = Dictionary<string, UnionInfo * UnionCaseInfo>

// ---------------------------------------------------------------------------
// Interfaces.
// ---------------------------------------------------------------------------

/// One declared method of a Lyric interface, lowered to an abstract
/// CLR interface method.
type InterfaceMember =
    { Name:    string
      Method:  MethodBuilder
      Params:  ClrType list
      Return:  ClrType }

type InterfaceInfo =
    { Name:    string
      Type:    TypeBuilder
      Members: InterfaceMember list }

type InterfaceTable = Dictionary<string, InterfaceInfo>

/// Per-emit map from a record's TypeBuilder (the target of one or
/// more `impl Foo for Bar` blocks) to the set of interface names it
/// implements.  Built during Emitter Pass A.5 and consulted by
/// `Codegen.satisfiesMarker` so user-defined interface constraints
/// (`where T: SomeInterface`, Q021 sub-question #5) work without
/// relying on `TypeBuilder.GetInterfaces()` (unsupported pre-seal).
type ImplsTable = Dictionary<System.Type, HashSet<string>>

// ---------------------------------------------------------------------------
// Distinct types (and range subtypes).
//
// `type Foo = Int` and `type Score = Int range 0..=100` lower to CLR value
// types (structs) with a single public `Value` field of the underlying
// primitive type, plus a static `From(x)` factory.  Range subtypes add a
// bounds check inside `From` and expose a `TryFrom(x)` that returns the
// Lyric `Result` union.
// ---------------------------------------------------------------------------

type DistinctTypeInfo =
    { Name:       string
      /// The CLR struct type (value type, single `Value` field).
      Type:       TypeBuilder
      /// The backing primitive field named `Value`.
      ValueField: FieldBuilder
      /// Static factory: panics on range violation (or unconstrained).
      FromMethod: MethodBuilder
      /// Static factory returning Result; None for non-range types.
      TryFromMethod: MethodBuilder option
      /// Derive markers declared on this type (`Equals`, `Hash`,
      /// `Default`, `Compare`, `Add`, `Sub`, `Mul`, `Div`, `Mod`).
      /// Consulted by `satisfiesMarker` at generic call sites so that
      /// `f[Age] where Age: Hash` accepts when `type Age = Int derives Hash`.
      Derives:    string list }

type DistinctTypeTable = Dictionary<string, DistinctTypeInfo>

// ---------------------------------------------------------------------------
// Projectable opaque types — `opaque type X @projectable { … }`.
//
// Carries the synthesised `XView` exposed record and the `toView()`
// instance method on `X`.  Codegen consults this table to resolve the
// method dispatch since `TypeBuilder.GetMethods()` is unsupported on
// non-finalised types.
// ---------------------------------------------------------------------------

type ProjectableInfo =
    { OpaqueName:    string
      ToViewMethod:  MethodBuilder
      ViewType:      RecordInfo
      /// `<Name>View::tryInto(): Result[<Name>, String]` — synthesised
      /// when (a) `Std.Core.Result` is in the imported-union table and
      /// (b) the projectable has no nested `@projectable` fields (the
      /// nested-recursion variant is a follow-up).  `None` otherwise.
      TryIntoMethod: MethodBuilder option }

type ProjectableTable = Dictionary<string, ProjectableInfo>

// ---------------------------------------------------------------------------
// Protected types (D-progress-079).
//
// Bootstrap-grade lowering per the C2/D-progress-067 outline:
//   * One private CLR class per `protected type T { ... }`.
//   * One public field per `var`/`let`/immutable declaration.
//   * One private `<>__lock : object` field used as the Monitor target.
//   * Default ctor that allocates `<>__lock` and runs each field's init
//     expression (or leaves it as `default(T)` when no init).
//   * Per `entry name(...)` / `func name(...)` member: a public instance
//     method whose body is wrapped in
//       try { Monitor.Enter(this.<>__lock); <barrier?>; <user body>;
//             <invariant?> } finally { Monitor.Exit(this.<>__lock) }
//   * `when:` barriers throw `LyricAssertionException` on false (Ada-
//     style condition-variable waiting + queue signalling lands when the
//     C2 Phase C scope plumbing is mature; see D-progress-067).
//   * `invariant:` clauses re-evaluate inside the try after the body
//     produces its return value — same `emitContractCheck` machinery
//     the regular function-body path already uses for ensures clauses.
// ---------------------------------------------------------------------------

/// One protected-type entry or func member, lowered to a CLR
/// instance method with the Monitor wrapper.
type ProtectedMethod =
    { Name:    string
      Method:  MethodBuilder
      /// `true` for `entry`, `false` for `func`.  Both lock today;
      /// per `06-open-questions.md` Q008 the func-side may relax to
      /// `ReaderWriterLockSlim` once a real workload exercises the
      /// distinction.
      IsEntry: bool }

/// A `var`/`let`/immutable field on a protected type, exposed so
/// the implicit-self desugar can synthesise `self.<name>` member
/// access against the underlying FieldBuilder.
type ProtectedField =
    { Name:  string
      Type:  ClrType
      Field: FieldBuilder }

/// Tri-modal lock flavour selection per Q008 + D-progress-087:
///   * `PLSemaphore` — entry-only, no `when:` barriers.  Cheapest:
///     binary `SemaphoreSlim(1, 1)`.  Every call takes the slot via
///     `Wait()` / `Release()` (D-progress-083).
///   * `PLRwLock` — declares at least one `func` AND no `when:`
///     barriers.  Funcs take the read lock for concurrent reads;
///     entries take the write lock (D-progress-081).
///   * `PLMonitor` — declares at least one `when:` barrier on any
///     entry / func.  Funcs lose concurrent reads (Monitor is the
///     only BCL primitive that supports `Wait` / `PulseAll` for
///     Ada-style condition-variable waiting).  Entries call
///     `Monitor.PulseAll` after the body so blocked callers wake
///     and re-evaluate their barriers (D-progress-087).
type ProtectedLockFlavour =
    | PLSemaphore
    | PLRwLock
    | PLMonitor

type ProtectedTypeInfo =
    { Name:        string
      /// Open generic definition for `protected type Foo[T]`; the
      /// concrete CLR type for non-generic protected types.
      Type:        TypeBuilder
      Ctor:        ConstructorBuilder
      LockField:   FieldBuilder
      /// Tri-modal lock-flavour split per Q008 + D-progress-087.
      /// Drives the lock field's CLR type, the ctor's `Newobj`
      /// argument, and the wrapper's acquire / release / barrier
      /// shape.
      LockFlavour: ProtectedLockFlavour
      Fields:      ProtectedField list
      Methods:     ProtectedMethod list
      /// User-declared type-parameter names in declaration order, or
      /// `[]` for non-generic protected types.  Drives call-site
      /// `MakeGenericType` for `Box()` construction (closed via
      /// `ctx.ExpectedType` per D-progress-079 follow-up: LHS-driven
      /// type-arg inference) and `TypeBuilder.GetMethod` for
      /// dispatching method calls on closed receivers.
      Generics:    string list }

type ProtectedTypeTable = Dictionary<string, ProtectedTypeInfo>

// ---------------------------------------------------------------------------
// Imported types and functions — pulled in from a precompiled package
// (e.g. `Lyric.Stdlib.Core.dll` via `import Std.Core`).  These mirror
// the local-emit shapes above but use runtime-reflection types because
// they reference an already-finalised assembly.
// ---------------------------------------------------------------------------

type ImportedField =
    { Name:      string
      Type:      ClrType
      /// The Lyric-side type of this field, with any union/record
      /// generic parameters surviving as `TyVar`.  Codegen needs it
      /// to infer call-site type-args without trusting reflection on
      /// the open-generic case type's field types (which would just
      /// give back `T` and lose the structural shape).
      LyricType: Lyric.TypeChecker.Type
      Field:     FieldInfo }

type ImportedRecordInfo =
    { Name:     string
      /// Open generic definition for generic records; the concrete
      /// runtime type for non-generic records.
      Type:     ClrType
      Fields:   ImportedField list
      Ctor:     ConstructorInfo
      Generics: string list }

type ImportedRecordTable = Dictionary<string, ImportedRecordInfo>

type ImportedUnionCaseInfo =
    { Name:   string
      /// Open generic definition for cases of generic unions; the
      /// concrete runtime type for non-generic unions.
      Type:   ClrType
      Fields: ImportedField list
      Ctor:   ConstructorInfo }

type ImportedUnionInfo =
    { Name:     string
      /// Open generic definition for generic unions.
      Type:     ClrType
      Cases:    ImportedUnionCaseInfo list
      Generics: string list }

type ImportedUnionTable = Dictionary<string, ImportedUnionInfo>

type ImportedUnionCaseLookup =
    Dictionary<string, ImportedUnionInfo * ImportedUnionCaseInfo>

/// Imported function carries its `MethodInfo` plus the Lyric-side
/// signature so the call-site emitter can run reified-generic type-
/// arg inference.  Ordering follows the local `FuncSigs` shape.
type ImportedFuncInfo =
    { Method: MethodInfo
      Sig:    Lyric.TypeChecker.ResolvedSignature }

type ImportedFuncTable = Dictionary<string, ImportedFuncInfo>

type ImportedDistinctTypeInfo =
    { Name:          string
      Type:          ClrType
      ValueField:    FieldInfo
      FromMethod:    MethodInfo
      TryFromMethod: MethodInfo option }

type ImportedDistinctTypeTable = Dictionary<string, ImportedDistinctTypeInfo>
