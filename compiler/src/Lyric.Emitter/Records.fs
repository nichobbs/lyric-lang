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

/// One field of a Lyric record, post-CLR-lowering.
type RecordField =
    { Name:   string
      Type:   ClrType
      Field:  FieldBuilder }

/// What the codegen needs to know about a Lyric record.
type RecordInfo =
    { Name:   string
      Type:   TypeBuilder
      Fields: RecordField list
      Ctor:   ConstructorBuilder }

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
