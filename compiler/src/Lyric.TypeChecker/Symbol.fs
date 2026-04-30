/// Symbol-table entries — what the resolver records about each
/// declaration in scope. The resolver builds a `SymbolTable` per
/// package and consults it whenever it encounters a name in the AST.
namespace Lyric.TypeChecker

open Lyric.Lexer
open Lyric.Parser.Ast

/// Kinds of named declarations that contribute to the symbol table.
/// Each carries enough information for the type checker to resolve
/// references; the original AST node is kept in `Decl` for spans and
/// downstream metadata (annotations, contracts, etc.).
type DeclKind =
    /// Type-level declarations: their names appear in type-expression
    /// position. Each is assigned a stable TypeId at registration.
    | DKRecord       of TypeId * RecordDecl
    | DKExposedRec   of TypeId * RecordDecl
    | DKUnion        of TypeId * UnionDecl
    | DKEnum         of TypeId * EnumDecl
    | DKOpaque       of TypeId * OpaqueTypeDecl
    | DKProtected    of TypeId * ProtectedTypeDecl
    | DKDistinctType of TypeId * DistinctTypeDecl
    | DKTypeAlias    of TypeAliasDecl
    | DKInterface    of TypeId * InterfaceDecl
    /// `extern type Foo = "System.Foo"` — opaque CLR-mapped type.
    | DKExternType   of TypeId * ExternTypeDecl

    /// Term-level declarations: they appear in expression position.
    | DKConst    of ConstDecl
    | DKVal      of ValDecl
    | DKFunc     of FunctionDecl
    | DKWire     of WireDecl
    | DKExtern   of ExternPackageDecl
    | DKScopeKind of ScopeKindDecl

    /// Test-only declarations. Always rejected outside @test_module.
    | DKTest     of TestDecl
    | DKProperty of PropertyDecl
    | DKFixture  of FixtureDecl

    /// Union variants. Visible at the union's enclosing scope as a
    /// tag (and as a constructor function).
    | DKUnionCase of parent: TypeId * UnionCase
    | DKEnumCase  of parent: TypeId * EnumCase

/// A single entry in the symbol table. One per top-level item plus
/// one per union/enum variant case.
type Symbol =
    { Name:    string
      Kind:    DeclKind
      DeclSpan: Span
      Visibility: Visibility option }

module Symbol =

    let name (s: Symbol) = s.Name

    let isType (s: Symbol) =
        match s.Kind with
        | DKRecord _ | DKExposedRec _ | DKUnion _
        | DKEnum _ | DKOpaque _ | DKProtected _
        | DKDistinctType _ | DKTypeAlias _
        | DKInterface _ | DKExternType _ -> true
        | _ -> false

    let typeIdOpt (s: Symbol) : TypeId option =
        match s.Kind with
        | DKRecord(id, _) | DKExposedRec(id, _) | DKUnion(id, _)
        | DKEnum(id, _) | DKOpaque(id, _) | DKProtected(id, _)
        | DKDistinctType(id, _) | DKInterface(id, _)
        | DKExternType(id, _) -> Some id
        | _ -> None
