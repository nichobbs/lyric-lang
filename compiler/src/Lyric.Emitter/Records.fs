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

/// One field of a Lyric record, post-CLR-lowering.  `LyricType` is
/// kept (in addition to the lowered `Type`) so codegen can run
/// reified-generic type-arg inference when the record is generic.
type RecordField =
    { Name:      string
      Type:      ClrType
      LyricType: Lyric.TypeChecker.Type
      Field:     FieldBuilder }

/// What the codegen needs to know about a Lyric record.  `Generics`
/// is the (ordered) list of type-parameter names — empty for non-
/// generic records, otherwise driving codegen's `MakeGenericType`
/// calls.
type RecordInfo =
    { Name:     string
      /// For generic records this is the open generic definition.
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
      TryFromMethod: MethodBuilder option }

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
      ViewType:      RecordInfo }

type ProjectableTable = Dictionary<string, ProjectableInfo>

// ---------------------------------------------------------------------------
// Imported types and functions — pulled in from a precompiled package
// (e.g. `Lyric.Stdlib.Core.dll` via `import Std.Core`).  These mirror
// the local-emit shapes above but use runtime-reflection types because
// they reference an already-finalised assembly.
// ---------------------------------------------------------------------------

type ImportedField =
    { Name:  string
      Type:  ClrType
      Field: FieldInfo }

type ImportedRecordInfo =
    { Name:   string
      Type:   ClrType
      Fields: ImportedField list
      Ctor:   ConstructorInfo }

type ImportedRecordTable = Dictionary<string, ImportedRecordInfo>

type ImportedUnionCaseInfo =
    { Name:   string
      Type:   ClrType
      Fields: ImportedField list
      Ctor:   ConstructorInfo }

type ImportedUnionInfo =
    { Name:  string
      Type:  ClrType
      Cases: ImportedUnionCaseInfo list }

type ImportedUnionTable = Dictionary<string, ImportedUnionInfo>

type ImportedUnionCaseLookup =
    Dictionary<string, ImportedUnionInfo * ImportedUnionCaseInfo>

type ImportedFuncTable = Dictionary<string, MethodInfo>

type ImportedDistinctTypeInfo =
    { Name:          string
      Type:          ClrType
      ValueField:    FieldInfo
      FromMethod:    MethodInfo
      TryFromMethod: MethodInfo option }

type ImportedDistinctTypeTable = Dictionary<string, ImportedDistinctTypeInfo>
