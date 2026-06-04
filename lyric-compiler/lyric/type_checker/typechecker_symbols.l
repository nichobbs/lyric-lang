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
  /// Treated as a static namespace whose fields are read once at
  /// process startup; field access is resolved like a record's
  /// fields with an implicit instance.
  case DKConfig(decl: ConfigDecl)
  /// `aspect Name { ... }` per `docs/26-aspects.md` (D047).  v1
  /// surface registers the aspect under its name; the weaver
  /// (deferred slice) walks the AST directly.
  case DKAspect(decl: AspectDecl)
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
  /// Dotted name of the package that declared this symbol (e.g.
  /// `"Std.Regex"`).  Empty string means "no package context": that is the
  /// state the flat `checkWithImports` shim produces, and it preserves the
  /// historical last-registered-wins resolution.  Scoped resolution
  /// (`symTableTryFindOne`) prefers a symbol whose `originPackage` matches the
  /// table's current resolution package, so two sibling packages that each
  /// export a same-named type (the `Std.Regex` / `Std.RegexSafe` `RegexError`
  /// collision) no longer shadow one another inside the other package's
  /// signatures.
  originPackage: String
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
  /// One-element box (the `TypeIdCounter.ticks` idiom — Lyric records do not
  /// reassign scalar fields, so a `List` carries the mutable marker) holding
  /// the dotted name of the package whose declarations resolution should
  /// prefer.  Empty list means "no scope" → pure last-registered-wins, which
  /// is exactly the historical behaviour.  Set via `symTableSetScope` around
  /// each package's signature/body resolution.
  scopePkg: List[String]
  /// The dotted names of packages the current scope explicitly imports.  When
  /// a reference's simple name is ambiguous across imported packages,
  /// resolution prefers a symbol declared in one of these packages before
  /// falling back to last-registered-wins.
  scopeImports: List[String]
}

pub func newSymbolTable(): SymbolTable {
  SymbolTable(symbols = newList(), scopePkg = newList(), scopeImports = newList())
}

pub func symTableAdd(tbl: in SymbolTable, sym: in Symbol): Unit {
  tbl.symbols.add(sym)
}

// ─────────────────────────────────────────────────────────────────────────────
// §4a. Resolution scope — package preference for name lookup.
// ─────────────────────────────────────────────────────────────────────────────

// Set the current resolution scope: `pkg` is the package whose declarations
// take precedence, and `imports` are the packages it explicitly imports (used
// as the second-tier preference).  Passing `pkg = ""` clears the
// current-package preference, restoring pure last-registered-wins resolution.
pub func symTableSetScope(
  tbl:     in SymbolTable,
  pkg:     in String,
  imports: in List[String]
): Unit {
  while tbl.scopePkg.count > 0 {
    tbl.scopePkg.removeAt(tbl.scopePkg.count - 1)
  }
  if pkg.length > 0 { tbl.scopePkg.add(pkg) }
  while tbl.scopeImports.count > 0 {
    tbl.scopeImports.removeAt(tbl.scopeImports.count - 1)
  }
  var i = 0
  while i < imports.count {
    tbl.scopeImports.add(imports[i])
    i = i + 1
  }
}

func symTableScopePkg(tbl: in SymbolTable): String {
  if tbl.scopePkg.count > 0 { tbl.scopePkg[0] } else { "" }
}

func symTableScopeAllows(tbl: in SymbolTable, pkg: in String): Bool {
  if pkg.length == 0 { return false }
  var i = 0
  while i < tbl.scopeImports.count {
    if tbl.scopeImports[i] == pkg { return true }
    i = i + 1
  }
  false
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

// Resolve `name` to a single symbol, honouring the current resolution scope.
// Tiers, in order of preference (each scans newest-to-oldest so a later
// declaration still shadows an earlier one of the same tier):
//   1. a symbol declared in the current package (`scopePkg`);
//   2. a symbol declared in a package the current scope imports
//      (`scopeImports`);
//   3. any symbol with a matching name (last-registered-wins).
// With no scope set (the flat `checkWithImports` shim, where every symbol's
// `originPackage` is empty), tiers 1 and 2 never match and resolution reduces
// to tier 3 — byte-for-byte the historical behaviour.
pub func symTableTryFindOne(tbl: in SymbolTable, name: in String): Option[Symbol] {
  val curPkg = symTableScopePkg(tbl)
  if curPkg.length > 0 {
    var i1 = tbl.symbols.count - 1
    while i1 >= 0 {
      val s = tbl.symbols[i1]
      if s.name == name and s.originPackage == curPkg { return Some(value = s) }
      i1 = i1 - 1
    }
  }
  if tbl.scopeImports.count > 0 {
    var i2 = tbl.symbols.count - 1
    while i2 >= 0 {
      val s = tbl.symbols[i2]
      if s.name == name and symTableScopeAllows(tbl, s.originPackage) {
        return Some(value = s)
      }
      i2 = i2 - 1
    }
  }
  var i3 = tbl.symbols.count - 1
  while i3 >= 0 {
    if tbl.symbols[i3].name == name { return Some(value = tbl.symbols[i3]) }
    i3 = i3 - 1
  }
  None
}
