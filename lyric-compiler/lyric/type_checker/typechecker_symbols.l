//! typechecker_symbols.l — symbol table entries and symbol table.
//! Mirrors compiler/src/Lyric.TypeChecker/Symbol.fs.
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. DeclKind — what kind of declaration each symbol represents.
// ─────────────────────────────────────────────────────────────────────────────
@stable(since = "0.1")
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
  // ─────────────────────────────────────────────────────────────────────────────
  // §2. Symbol — one entry in the symbol table.
  // ─────────────────────────────────────────────────────────────────────────────
}

@stable(since = "0.1")
pub record Symbol {
  name: String
  kind: DeclKind
  declSpan: Span
  visibility: Option[Visibility]
  isImported: Bool
  /// Dotted declaring-package name; empty = no package context (the flat
  /// `checkWithImports` shim, i.e. historical last-registered-wins).
  originPackage: String
  /// Derive markers extracted from `@derive(...)` annotations on the item.
  /// Non-empty only for records, unions, and distinct types.
  derives: List[String]
  // ─────────────────────────────────────────────────────────────────────────────
  // §3. Symbol helpers.
  // ─────────────────────────────────────────────────────────────────────────────
}

pub func symbolIsType(s: in Symbol): Bool {
  match s.kind {
    case DKRecord(_, _) -> true
    case DKExposedRec(_, _) -> true
    case DKUnion(_, _) -> true
    case DKEnum(_, _) -> true
    case DKOpaque(_, _) -> true
    case DKProtected(_, _) -> true
    case DKDistinctType(_, _) -> true
    case DKTypeAlias(_) -> true
    case DKInterface(_, _) -> true
    case DKExternType(_, _) -> true
    case _ -> false
  }
}

pub func symbolTypeIdOpt(s: in Symbol): Option[TypeId] {
  match s.kind {
    case DKRecord(id, _) -> Some(value = id)
    case DKExposedRec(id, _) -> Some(value = id)
    case DKUnion(id, _) -> Some(value = id)
    case DKEnum(id, _) -> Some(value = id)
    case DKOpaque(id, _) -> Some(value = id)
    case DKProtected(id, _) -> Some(value = id)
    case DKDistinctType(id, _) -> Some(value = id)
    case DKInterface(id, _) -> Some(value = id)
    case DKExternType(id, _) -> Some(value = id)
    case _ -> None
  }
}

// Check if an extern type is a Func or Action delegate (Phase 1 scope).
// Phase 1 (M5.2-M5.3) supports only System.Func and System.Action delegates.
// Other delegate types (Predicate, EventHandler, Comparison, Converter, etc.)
// are deferred to Phase 2 for proper support with metadata-based detection.
// For other extern types, conservatively reject to prevent assigning lambdas
// to non-delegate types (System.Exception, System.String, HttpClientHandler,
// etc.).  Unknown delegate types should be wrapped in a Lyric interface
// (docs/51) until metadata-based detection is available.
// O(1) via `externDelegateFlags`, a side index `symTableAdd` maintains
// alongside `importedOpaqueNames`/`unionDeclIndex` (#2027, #2178) — this
// function is called from `argSatisfiesParam` for every `TyUser`-typed call
// argument, so a full symbol scan per call does not scale (#3903).
pub func symTableIsExternDelegateType(tbl: in SymbolTable, id: in TypeId): Bool {
  match mapGet(tbl.externDelegateFlags, toString(id.id)) {
    case Some(v) -> v
    case None -> false
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. SymbolTable — package-level symbol store (bootstrap: linear scan).
// ─────────────────────────────────────────────────────────────────────────────
@stable(since = "0.1")
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
  /// `toString(TypeId.id)` → declared name of an *imported* opaque type.
  /// Side index populated by `symTableAdd` so `importedOpaqueName` (called
  /// once per `EMatch`) is O(1) instead of a full symbol scan (#2027).
  importedOpaqueNames: Map[String, String]
  /// `toString(TypeId.id)` → index into `unionDeclList`.  Side index populated
  /// by `symTableAdd` so `parentUnionDeclOf` (called at least twice per
  /// union-constructor call) is O(1) instead of a full symbol scan (#2178).
  /// The decl itself lives in the parallel `unionDeclList` because the stage-0
  /// bootstrap emitter miscompiles `Map` values of cross-package record types
  /// (`UnionDecl` is a `Lyric.Parser` record); an `Int` map value plus a
  /// `List` read is the established safe pattern.
  unionDeclIndex: Map[String, Int]
  unionDeclList: List[UnionDecl]
  /// `toString(TypeId.id)` → whether the `DKExternType` with that id is a
  /// `System.Func`/`System.Action` delegate.  Side index populated by
  /// `symTableAdd` so `symTableIsExternDelegateType` (called on every
  /// `TyUser`-typed call argument in `argSatisfiesParam`) is O(1) instead of
  /// a full symbol scan (#3903).
  externDelegateFlags: Map[String, Bool]
  /// Method-signature space for value-receiver method calls (docs/59 A4).
  /// Entries live in `methodSigs`; `methodSigIndex` maps the probing key
  /// `toString(owner.id) + "#" + name + "@" + i` to an index (the
  /// `registerOverloadCandidate` idiom, so same-name overloads on one type
  /// occupy `@0`, `@1`, …).  An `Int`-valued map plus a `List` read is the
  /// established safe pattern (see `unionDeclIndex`).
  methodSigs: List[MethodEntry]
  methodSigIndex: Map[String, Int]
  /// `toString(TypeId.id)` present ⇒ the type is declared in the file being
  /// checked (not imported) AND its full member surface is known to the
  /// checker (records, exposed records, interfaces).  Unknown-member
  /// diagnostics (docs/59 A5) fire only for these types: imported records
  /// may originate from restored contract metadata, whose record reprs drop
  /// method members, so an unknown-member error there would be a false
  /// positive.
  memberCompleteTypes: Map[String, Bool]
  // One `impl Iface for Target` conformance, by resolved `TypeId`.
}

pub record ImplPair {
  target: TypeId
  iface: TypeId
}

/// One method signature attached to a nominal type — a record-body method
/// (`RMFunc`, leading `self` dropped), an `impl` block method (`IMplFunc`,
/// receiver implicit), or an interface member (`IMSig`/`IMFunc`).  The stored
/// `sig` is the *call-facing* signature: its params never include the
/// receiver, so a call site validates `x.m(a, b)`'s two arguments directly
/// against `sig.params` (docs/59 A4).
pub record MethodEntry {
  owner: TypeId
  ownerName: String
  /// The owning type's generic parameter names (`Box[T]` → `["T"]`), so a
  /// call site can substitute the receiver's type args into `sig`.
  ownerGenerics: List[String]
  name: String
  sig: ResolvedSignature
}

pub func newSymbolTable(): SymbolTable {
  SymbolTable(
    symbols = newList(),
    scopePkg = newList(),
    scopeImports = newList(),
    impls = newList(),
    importedOpaqueNames = newMap(),
    unionDeclIndex = newMap(),
    unionDeclList = newList(),
    externDelegateFlags = newMap(),
    methodSigs = newList(),
    methodSigIndex = newMap(),
    memberCompleteTypes = newMap()
  )
}

// Register one method signature for `entry.owner`, probing `@0`, `@1`, … for
// the first free slot (same-name overloads on one type append).
pub func symTableAddMethodSig(tbl: in SymbolTable, entry: in MethodEntry): Unit {
  val base = toString(entry.owner.id) + "#" + entry.name + "@"
  var i = 0
  var placed = false
  while not placed {
    val k = base + toString(i)
    if not tbl.methodSigIndex.containsKey(k) {
      tbl.methodSigs.add(entry)
      tbl.methodSigIndex.add(k, tbl.methodSigs.count - 1)
      placed = true
    } else {
      i = i + 1
    }
  }
}

// Every method entry registered for (`owner`, `name`), in registration order.
pub func symTableMethodSigs(tbl: in SymbolTable, owner: in TypeId, name: in String): List[MethodEntry] {
  val acc: List[MethodEntry] = newList()
  val base = toString(owner.id) + "#" + name + "@"
  var i = 0
  var more = true
  while more {
    match mapGet(tbl.methodSigIndex, base + toString(i)) {
      case Some(ix) -> {
        acc.add(tbl.methodSigs[ix])
        i = i + 1
      }
      case None -> {
        more = false
      }
    }
  }
  acc
}

// True when unknown-member diagnostics may fire for the type `tid` — it is
// declared in the file being checked and its member surface is fully known.
pub func symTableIsMemberComplete(tbl: in SymbolTable, tid: in TypeId): Bool {
  tbl.memberCompleteTypes.containsKey(toString(tid.id))
}

// Record that the type with id `target` implements the interface with id
// `iface` (idempotent).
pub func symTableAddImpl(tbl: in SymbolTable, target: in TypeId, iface: in TypeId): Unit {
  var i = 0
  while i < tbl.impls.count {
    if typeIdEq(tbl.impls[i].target, target) and typeIdEq(tbl.impls[i].iface, iface) {
      return
    }
    i = i + 1
  }
  tbl.impls.add(ImplPair(target = target, iface = iface))
}

// True when some `impl iface for target` was registered.
pub func symTableTypeImplements(tbl: in SymbolTable, target: in TypeId, iface: in TypeId): Bool {
  var i = 0
  while i < tbl.impls.count {
    if typeIdEq(tbl.impls[i].target, target) and typeIdEq(tbl.impls[i].iface, iface) {
      return true
    }
    i = i + 1
  }
  false
}

pub func symTableAdd(tbl: in SymbolTable, sym: in Symbol): Unit {
  // Maintain the TypeId-keyed side indexes (#2027, #2178, #3903).  Each
  // registration gets a fresh TypeId, so first-in-wins guards only against
  // pathological double-adds of the same symbol.
  match sym.kind {
    case DKOpaque(oid, _) -> {
      if sym.isImported {
        val key = toString(oid.id)
        if not tbl.importedOpaqueNames.containsKey(key) {
          tbl.importedOpaqueNames.add(key, sym.name)
        }
      }
    }
    case DKRecord(rid, _) -> {
      if not sym.isImported {
        val key = toString(rid.id)
        if not tbl.memberCompleteTypes.containsKey(key) {
          tbl.memberCompleteTypes.add(key, true)
        }
      }
    }
    case DKExposedRec(xid, _) -> {
      if not sym.isImported {
        val key = toString(xid.id)
        if not tbl.memberCompleteTypes.containsKey(key) {
          tbl.memberCompleteTypes.add(key, true)
        }
      }
    }
    case DKInterface(iid, _) -> {
      if not sym.isImported {
        val key = toString(iid.id)
        if not tbl.memberCompleteTypes.containsKey(key) {
          tbl.memberCompleteTypes.add(key, true)
        }
      }
    }
    case DKUnion(uid, decl) -> {
      val key = toString(uid.id)
      if not tbl.unionDeclIndex.containsKey(key) {
        tbl.unionDeclList.add(decl)
        tbl.unionDeclIndex.add(key, tbl.unionDeclList.count - 1)
      }
    }
    case DKExternType(tid, decl) -> {
      val key = toString(tid.id)
      if not tbl.externDelegateFlags.containsKey(key) {
        val clr = decl.clrName
        val isDelegate = clr.startsWith("System.Func") or clr.startsWith("System.Action")
        tbl.externDelegateFlags.add(key, isDelegate)
      }
    }
    case _ -> {
    }
  }
  tbl.symbols.add(sym)
}

// ─────────────────────────────────────────────────────────────────────────────
// §4a. Resolution scope — package preference for name lookup.
// ─────────────────────────────────────────────────────────────────────────────
// Set the current resolution scope: `pkg` is the package whose declarations
// take precedence, and `imports` are the packages it explicitly imports (used
// as the second-tier preference).  Passing `pkg = ""` clears the
// current-package preference, restoring pure last-registered-wins resolution.
pub func symTableSetScope(tbl: in SymbolTable, pkg: in String, imports: in List[String]): Unit {
  while tbl.scopePkg.count > 0 {
    tbl.scopePkg.removeAt(tbl.scopePkg.count - 1)
  }
  if pkg.length > 0 {
    tbl.scopePkg.add(pkg)
  }
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
  if tbl.scopePkg.count > 0 {
    tbl.scopePkg[0]
  } else {
    ""
  }
}

func symTableScopeAllows(tbl: in SymbolTable, pkg: in String): Bool {
  if pkg.length == 0 {
    return false
  }
  var i = 0
  while i < tbl.scopeImports.count {
    if tbl.scopeImports[i] == pkg {
      return true
    }
    i = i + 1
  }
  false
}

pub func symTableTryFindAll(tbl: in SymbolTable, name: in String): List[Symbol] {
  val result: List[Symbol] = newList()
  var i = 0
  while i < tbl.symbols.count {
    if tbl.symbols[i].name == name {
      result.add(tbl.symbols[i])
    }
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
  val curPkg = symTableScopePkg(tbl)
  val hasScope = curPkg.length > 0
  val hasImports = tbl.scopeImports.count > 0
  var best2: Option[Symbol] = None
  var best3: Option[Symbol] = None
  var i = tbl.symbols.count - 1
  while i >= 0 {
    val s = tbl.symbols[i]
    if s.name == name {
      if hasScope and s.originPackage == curPkg {
        return Some(value = s)
      }
      if hasImports and symTableScopeAllows(tbl, s.originPackage) {
        match best2 {
          case None -> {
            best2 = Some(value = s)
          }
          case Some(_) -> {
          }
        }
      }
      match best3 {
        case None -> {
          best3 = Some(value = s)
        }
        case Some(_) -> {
        }
      }
    }
    i = i - 1
  }
  match best2 {
    case Some(_) -> best2
    case None -> best3
  }
}
