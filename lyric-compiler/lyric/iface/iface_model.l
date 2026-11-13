//! iface_model.l - Lyric.Iface data model (docs/70 §9.2, phase 5a).
//!
//! A package interface is the checked, resolved surface of a built package:
//! what a consumer loads into its symbol table instead of re-reading source
//! or synthesised contract metadata.  This file holds the in-memory model;
//! `iface_codec.l` and `iface_encode.l` define its canonical binary form and
//! `iface_dump.l` its text form.
//!
//! Declarations are identified by their `DefPath` (`Lyric.Symbols`, docs/70
//! §4.2), the same path the resolver gives them.  Types are `Lyric.Tir`'s `Ty`:
//! it names a declaration by `SymbolId`, which exists only within one
//! compilation, so the codec writes the DefPath key and a reader interns it
//! again (`iface_ty.l`).  A declaration carries the detail of its kind
//! (`IfDetail`).  Bodies, contracts, the linkage table and hidden exports
//! are not in the model yet; a function parameter's default value is (D460): they need the TIR builder and the
//! consumer work of docs/70 phases 3a and 5b (D321, D324).
package Lyric.Iface

import Std.Core
import Std.Collections
import Lyric.Symbols
import Lyric.Tir

/// A package's verification level (language reference §6): the file-level
/// annotation the mode checker reads.
pub union IfVerif {
  case IfRuntimeChecked
  case IfProofRequired
  case IfProofRequiredUnsafe
  case IfProofRequiredChecked
  case IfAxiom
}

/// How far a declaration is visible: `pub` and `internal` cross a package
/// boundary, an undecorated one does not.
pub union IfVis {
  case IfPrivate
  case IfInternal
  case IfPublic
}

/// What a declaration is.  A member of a type (a union or enum case, a
/// method) nests its DefPath under its type's.
pub union IfKind {
  case IfKFunc
  case IfKMethod
  case IfKVal
  case IfKConst
  case IfKRecord
  case IfKExposedRecord
  case IfKUnion
  case IfKEnum
  case IfKOpaque
  case IfKProtected
  case IfKDistinct
  case IfKAlias
  case IfKInterface
  case IfKExternType
  case IfKWire
  case IfKScope
  case IfKConfig
  case IfKAspect
  case IfKUnionCase
  case IfKEnumCase
}

/// An interface the package was built against (§9.2): its package, version and
/// interface hash.  A dependent is rebuilt only when one of these changes.
pub record IfBuiltAgainst {
  pkg: String
  version: String
  hash: String
}

/// The header of §9.2.  `consumerAnnotations` lists the file-level
/// annotations that change how a consumer treats the package (`pure`, `io`);
/// `targets` the backends the build produced (`dotnet`, `jvm`, `native`).
pub record IfHeader {
  formatVersion: Int
  pkg: String
  builtAgainst: List[IfBuiltAgainst]
  verification: IfVerif
  consumerAnnotations: List[String]
  targets: List[String]
}

/// A parameter of a function.  `hasDefault` records that a call may omit it;
/// `dflt` is the default's value as a typed TIR expression (D460), absent when the
/// declaration has none or the producer could not record the one it has.
pub record IfParam {
  name: String
  mode: TMode
  ty: Ty
  hasDefault: Bool
  dflt: Option[TExpr] = None
}

/// A field of a record, a protected type or a union case.
pub record IfField {
  name: String
  ty: Ty
  mutable: Bool
  hasDefault: Bool
}

/// What a declaration is, beyond its kind and visibility.
///
/// - `IfDNone`: a wire, scope, config or aspect, whose content is code.
/// - `IfDFunc`: a function, method or interface member.  A function's level is
///   the package's unless it is `@axiom`.
/// - `IfDRecord`: a record, exposed record or protected type.
/// - `IfDType`: a union, enum, opaque type or interface (cases and members
///   are declarations of their own, nested under it).
/// - `IfDAlias`: an alias or distinct type, with its underlying type (a
///   refinement for a range subtype).
/// - `IfDCase`: a union or enum case and its payload.
/// - `IfDValue`: a `val`, `const` or `var` global; `value` is a constant's
///   literal.
/// - `IfDExtern`: an extern type and the host type it names.
pub union IfDetail {
  case IfDNone
  case IfDFunc(typeParams: List[TTypeParam], params: List[IfParam], ret: Ty, isAsync: Bool, isAxiom: Bool, isPure: Bool)
  case IfDRecord(typeParams: List[TTypeParam], fields: List[IfField])
  case IfDType(typeParams: List[TTypeParam])
  case IfDAlias(typeParams: List[TTypeParam], underlying: Ty)
  case IfDCase(fields: List[IfField])
  case IfDValue(ty: Ty, mutable: Bool, value: Option[TLit])
  case IfDExtern(typeParams: List[TTypeParam], host: String)
}

/// One declaration of the package's interface.
pub record IfDecl {
  path: DefPath
  kind: IfKind
  vis: IfVis
  detail: IfDetail
}

/// A package interface.  `reexports` lists the packages the package re-exports
/// whole (`pub use P`, D309); a re-exported declaration is reached through
/// them, never copied.
pub record Iface {
  header: IfHeader
  decls: List[IfDecl]
  reexports: List[String]
}

pub func ifVerifCode(v: in IfVerif): Int {
  match v {
    case IfRuntimeChecked -> 0
    case IfProofRequired -> 1
    case IfProofRequiredUnsafe -> 2
    case IfProofRequiredChecked -> 3
    case IfAxiom -> 4
  }
}

pub func ifVerifOfCode(c: in Int): Option[IfVerif] {
  match c {
    case 0 -> Some(value = IfRuntimeChecked)
    case 1 -> Some(value = IfProofRequired)
    case 2 -> Some(value = IfProofRequiredUnsafe)
    case 3 -> Some(value = IfProofRequiredChecked)
    case 4 -> Some(value = IfAxiom)
    case _ -> None
  }
}

pub func ifVerifName(v: in IfVerif): String {
  match v {
    case IfRuntimeChecked -> "@runtime_checked"
    case IfProofRequired -> "@proof_required"
    case IfProofRequiredUnsafe -> "@proof_required(unsafe_blocks_allowed)"
    case IfProofRequiredChecked -> "@proof_required(checked_arithmetic)"
    case IfAxiom -> "@axiom"
  }
}

pub func ifVisCode(v: in IfVis): Int {
  match v {
    case IfPrivate -> 0
    case IfInternal -> 1
    case IfPublic -> 2
  }
}

pub func ifVisOfCode(c: in Int): Option[IfVis] {
  match c {
    case 0 -> Some(value = IfPrivate)
    case 1 -> Some(value = IfInternal)
    case 2 -> Some(value = IfPublic)
    case _ -> None
  }
}

pub func ifVisName(v: in IfVis): String {
  match v {
    case IfPrivate -> "private"
    case IfInternal -> "internal"
    case IfPublic -> "pub"
  }
}

pub func ifKindCode(k: in IfKind): Int {
  match k {
    case IfKFunc -> 0
    case IfKMethod -> 1
    case IfKVal -> 2
    case IfKConst -> 3
    case IfKRecord -> 4
    case IfKExposedRecord -> 5
    case IfKUnion -> 6
    case IfKEnum -> 7
    case IfKOpaque -> 8
    case IfKProtected -> 9
    case IfKDistinct -> 10
    case IfKAlias -> 11
    case IfKInterface -> 12
    case IfKExternType -> 13
    case IfKWire -> 14
    case IfKScope -> 15
    case IfKConfig -> 16
    case IfKAspect -> 17
    case IfKUnionCase -> 18
    case IfKEnumCase -> 19
  }
}

pub func ifKindOfCode(c: in Int): Option[IfKind] {
  match c {
    case 0 -> Some(value = IfKFunc)
    case 1 -> Some(value = IfKMethod)
    case 2 -> Some(value = IfKVal)
    case 3 -> Some(value = IfKConst)
    case 4 -> Some(value = IfKRecord)
    case 5 -> Some(value = IfKExposedRecord)
    case 6 -> Some(value = IfKUnion)
    case 7 -> Some(value = IfKEnum)
    case 8 -> Some(value = IfKOpaque)
    case 9 -> Some(value = IfKProtected)
    case 10 -> Some(value = IfKDistinct)
    case 11 -> Some(value = IfKAlias)
    case 12 -> Some(value = IfKInterface)
    case 13 -> Some(value = IfKExternType)
    case 14 -> Some(value = IfKWire)
    case 15 -> Some(value = IfKScope)
    case 16 -> Some(value = IfKConfig)
    case 17 -> Some(value = IfKAspect)
    case 18 -> Some(value = IfKUnionCase)
    case 19 -> Some(value = IfKEnumCase)
    case _ -> None
  }
}

pub func ifKindName(k: in IfKind): String {
  match k {
    case IfKFunc -> "func"
    case IfKMethod -> "method"
    case IfKVal -> "val"
    case IfKConst -> "const"
    case IfKRecord -> "record"
    case IfKExposedRecord -> "exposed record"
    case IfKUnion -> "union"
    case IfKEnum -> "enum"
    case IfKOpaque -> "opaque"
    case IfKProtected -> "protected"
    case IfKDistinct -> "distinct"
    case IfKAlias -> "alias"
    case IfKInterface -> "interface"
    case IfKExternType -> "extern type"
    case IfKWire -> "wire"
    case IfKScope -> "scope"
    case IfKConfig -> "config"
    case IfKAspect -> "aspect"
    case IfKUnionCase -> "union case"
    case IfKEnumCase -> "enum case"
  }
}
