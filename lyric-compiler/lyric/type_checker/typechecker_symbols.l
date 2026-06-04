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
  /// Dotted declaring-package name; empty = no package context (the flat
  /// `checkWithImports` shim, i.e. historical last-registered-wins).
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
  /// Preferred-package marker, boxed as a 0/1-element list (the
  /// `TypeIdCounter.ticks` idiom); empty = no scope = last-registered-wins.
  scopePkg: List[String]
  /// Dotted names the current scope imports (second-tier resolution preference).
  scopeImports: List[String]
  /// Interface-conformance relations from `impl I for T` declarations, used
  /// for interface subtyping at argument positions (#1488): an arg of type `T`
  /// is accepted where the parameter is interface `I` when `(T, I)` is present.
  /// Keyed by `TypeId` (not simple name) so a same-simple-name interface in a
  /// different package can never satisfy the check (#2303 soundness).
  impls: List[ImplPair]
}

// One `impl Iface for Target` conformance, by resolved `TypeId`.
pub record ImplPair {
  target: TypeId
  iface:  TypeId
}

pub func newSymbolTable(): SymbolTable {
  SymbolTable(symbols = newList(), scopePkg = newList(), scopeImports = newList(), impls = newList())
}

// Record that the type with id `target` implements the interface with id
// `iface` (idempotent).
pub func symTableAddImpl(tbl: in SymbolTable, target: in TypeId, iface: in TypeId): Unit {
  var i = 0
  while i < tbl.impls.count {
    if typeIdEq(tbl.impls[i].target, target) and typeIdEq(tbl.impls[i].iface, iface) { return }
    i = i + 1
  }
  tbl.impls.add(ImplPair(target = target, iface = iface))
}

// True when some `impl iface for target` was registered.
pub func symTableTypeImplements(tbl: in SymbolTable, target: in TypeId, iface: in TypeId): Bool {
  var i = 0
  while i < tbl.impls.count {
    if typeIdEq(tbl.impls[i].target, target) and typeIdEq(tbl.impls[i].iface, iface) { return true }
    i = i + 1
  }
  false
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
// Preference, highest first: (1) current package, (2) an imported package,
// (3) any match (last-registered-wins).  A single newest-to-oldest pass keeps
// the newest candidate in each tier, returning early on a tier-1 hit.  With no
// scope set every symbol's `originPackage` is empty, so only tier 3 fires —
// byte-for-byte the historical behaviour.
pub func symTableTryFindOne(tbl: in SymbolTable, name: in String): Option[Symbol] {
  val curPkg     = symTableScopePkg(tbl)
  val hasScope   = curPkg.length > 0
  val hasImports = tbl.scopeImports.count > 0
  var best2: Option[Symbol] = None
  var best3: Option[Symbol] = None
  var i = tbl.symbols.count - 1
  while i >= 0 {
    val s = tbl.symbols[i]
    if s.name == name {
      if hasScope and s.originPackage == curPkg { return Some(value = s) }
      if hasImports and symTableScopeAllows(tbl, s.originPackage) {
        match best2 { case None -> { best2 = Some(value = s) }; case Some(_) -> {} }
      }
      match best3 { case None -> { best3 = Some(value = s) }; case Some(_) -> {} }
    }
    i = i - 1
  }
  match best2 {
    case Some(_) -> best2
    case None    -> best3
  }
}
