// typechecker_symbols.l — symbol table entries and symbol table.
// Mirrors compiler/src/Lyric.TypeChecker/Symbol.fs.
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. DeclKind — what kind of declaration each symbol represents.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub union DeclKind {
  // Type-level declarations.
  case DKRecord(id: TypeId, decl: RecordDecl)
  case DKExposedRec(id: TypeId, decl: RecordDecl)
  case DKUnion(id: TypeId, decl: UnionDecl)
  case DKEnum(id: TypeId, decl: EnumDecl)
  case DKOpaque(id: TypeId, decl: OpaqueTypeDecl)
  case DKProtected(id: TypeId, decl: ProtectedTypeDecl)
  case DKDistinctType(id: TypeId, decl: DistinctTypeDecl)
  case DKTypeAlias(decl: TypeAliasDecl)
  case DKInterface(id: TypeId, decl: InterfaceDecl)
  case DKExternType(id: TypeId, decl: ExternTypeDecl)
  // Term-level declarations.
  case DKConst(decl: ConstDecl)
  case DKVal(decl: ValDecl)
  case DKFunc(decl: FunctionDecl)
  case DKWire(decl: WireDecl)
  case DKExtern(decl: ExternPackageDecl)
  case DKScopeKind(decl: ScopeKindDecl)
  // Test-only declarations.
  case DKTest(decl: TestDecl)
  case DKProperty(decl: PropertyDecl)
  case DKFixture(decl: FixtureDecl)
  /// `config Name { ... }` per `docs/25-config-blocks.md` (D046).
  case DKConfig(decl: ConfigDecl)
  // Union / enum variant cases.
  case DKUnionCase(parentId: TypeId, uc: UnionCase)
  case DKEnumCase(parentId: TypeId, ec: EnumCase)
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Symbol — one entry in the symbol table.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub record Symbol {
  name:       String
  kind:       DeclKind
  declSpan:   Span
  visibility: Option[Visibility]
  isImported: Bool
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Symbol helpers.
// ─────────────────────────────────────────────────────────────────────────────

pub func symbolIsType(s: in Symbol): Bool {
  match s.kind {
    case DKRecord(_,_)       -> true
    case DKExposedRec(_,_)   -> true
    case DKUnion(_,_)        -> true
    case DKEnum(_,_)         -> true
    case DKOpaque(_,_)       -> true
    case DKProtected(_,_)    -> true
    case DKDistinctType(_,_) -> true
    case DKTypeAlias(_)      -> true
    case DKInterface(_,_)    -> true
    case DKExternType(_,_)   -> true
    case _                   -> false
  }
}

pub func symbolTypeIdOpt(s: in Symbol): Option[TypeId] {
  match s.kind {
    case DKRecord(id,_)       -> Some(value = id)
    case DKExposedRec(id,_)   -> Some(value = id)
    case DKUnion(id,_)        -> Some(value = id)
    case DKEnum(id,_)         -> Some(value = id)
    case DKOpaque(id,_)       -> Some(value = id)
    case DKProtected(id,_)    -> Some(value = id)
    case DKDistinctType(id,_) -> Some(value = id)
    case DKInterface(id,_)    -> Some(value = id)
    case DKExternType(id,_)   -> Some(value = id)
    case _                    -> None
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. SymbolTable — package-level symbol store (bootstrap: linear scan).
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub record SymbolTable {
  symbols: List[Symbol]
}

pub func newSymbolTable(): SymbolTable {
  SymbolTable(symbols = newList())
}

pub func symTableAdd(tbl: in SymbolTable, sym: in Symbol): Unit {
  tbl.symbols.add(sym)
}

pub func symTableTryFindAll(tbl: in SymbolTable, name: in String): List[Symbol] {
  val result: List[Symbol] = newList()
  var i = 0
  while i < tbl.symbols.count {
    if tbl.symbols[i].name == name { result.add(tbl.symbols[i]) }
    i = i + 1
  }
  result
}

pub func symTableTryFindOne(tbl: in SymbolTable, name: in String): Option[Symbol] {
  var i = 0
  while i < tbl.symbols.count {
    if tbl.symbols[i].name == name { return Some(value = tbl.symbols[i]) }
    i = i + 1
  }
  None
}
