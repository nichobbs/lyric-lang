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

// #6720: is `id` the TypeId of a `DKExternType` (an `extern type` binding,
// e.g. `Set[T]`/`JHttpStringCollection[T]`)?  Used by `SFor`'s single-type-
// param generic element-typing fallback (D-progress-818) to distinguish a
// genuine extern collection (the phantom-type-param FFI idiom this fallback
// exists for) from a Lyric-native single-param generic that merely happens
// to have one type parameter (e.g. `Option[T]`) but isn't iterable.  A
// linear scan — called once per `for` statement, not per element access —
// so no side index is warranted (contrast `externDelegateFlags`, consulted
// per call argument).
pub func symTableIsExternTypeId(tbl: in SymbolTable, id: in TypeId): Bool {
  var i = 0
  while i < tbl.symbols.count {
    match tbl.symbols[i].kind {
      case DKExternType(tid, _) -> if typeIdEq(tid, id) { return true }
      case _ -> {
      }
    }
    i = i + 1
  }
  false
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
  /// `"<originPackage>|<name>"` present ⇒ `name` is declared as a member of
  /// an `extern package <Path> { ... }` block somewhere in package
  /// `originPackage` (#6361). `registerItem`'s `IExtern` arm never adds these
  /// to `symbols` — the block's body-less signatures are resolved by codegen
  /// directly, not through the ordinary symbol table — so without this index
  /// a fully-qualified call into one (e.g. `Grpc.Kernel.Net.netOpenChannel`,
  /// called from the enclosing file's own package path) would look
  /// indistinguishable from a genuine unknown name to
  /// `resolveExprPath`'s qualified-name check.
  externBlockMembers: Map[String, Bool]
  /// `<originPackage>` present ⇒ at least one ordinary symbol (via
  /// `symTableAdd`, any `DeclKind`) was registered under that package.
  /// Side index so `symTablePackageHasAnySymbol` (consulted on every
  /// multi-segment qualified reference the checker resolves, #6361) is O(1)
  /// instead of a linear scan over `symbols`.
  symbolPackages: Map[String, Bool]
  /// `<originPackage>|<name>` present ⇒ a symbol named `name` was registered
  /// under that package. Side index so `symTablePackageHasMember` is O(1)
  /// instead of a linear scan over `symbols`.
  symbolPackageMembers: Map[String, Bool]
  /// `<originPackage>` present ⇒ that package contributed at least one
  /// `extern package { ... }` block member to `externBlockMembers` (#6378).
  /// A package whose file consists ENTIRELY of `extern package { ... }`
  /// block(s) — e.g. `AwsXRay.Kernel.Net` in `lyric-aws-xray/src/_kernel/
  /// xray_kernel_jvm.l` — never adds anything to `symbols` at all, so
  /// `symTablePackageHasAnySymbol` alone can't tell "package known, name
  /// typo'd" apart from "package never even resolved" for it;
  /// `resolveExprPath`'s #6361 T0020 gate consults this side index too so a
  /// typo'd qualified call into such a package is still flagged instead of
  /// silently falling through (the exact #6361 bug, reopened for this one
  /// package shape).
  externBlockPackages: Map[String, Bool]
  // One `impl Iface for Target` conformance, by resolved `TypeId`.
  /// `<originPackage>` -> the dotted import names that package's own file
  /// declared (#6689).  Populated once, per package, during signature
  /// collection (mirroring `symTableSetScope`'s `ip2.name`/`ip2.imports`
  /// pair). Consulted by `collectCtorFields` so a record/opaque's field
  /// TYPES resolve under the DECLARING package's own scope, not whatever
  /// scope happens to be active at the call site that triggered the lookup
  /// (a constructor call, field read, …) — without this, a field typed
  /// `List[Item]` in package A resolves `Item` against the CALLING file's
  /// imports, so a caller that transitively imports an unrelated same-named
  /// `Item` from package B silently picks B's `Item` instead of A's.
  packageImports: Map[String, List[String]]
  /// `<pkg>|<name>` -> whether `pkg` exports a function `name` to other
  /// packages (`symTablePackageExportsFunc`), filled on first use.
  funcExportCache: Map[String, Bool]
  /// Every validated record `.copy(...)` call, keyed by `recordCopySiteKey`
  /// of the call expression's span (see `Lyric.Parser.RecordCopySite`).
  recordCopySites: Map[String, RecordCopySite]
  /// Every construction (constructor call or `.copy(...)`) of a record or
  /// opaque type that declares `invariant:` clauses, keyed by
  /// `recordCopySiteKey` of the call's span, mapped to the dotted path of
  /// the type's synthesized construction checker (#7222).  Consumed by
  /// `Lyric.ContractElaborator.wrapInvariantConstructions`.
  invariantCtorSites: Map[String, String]
  /// Every cross-package function reference used as a value, keyed like
  /// `recordCopySites` (see `Lyric.Parser.FuncRefSite`).
  funcRefSites: Map[String, FuncRefSite]
  /// Span keys of call callees, whose function reference is a call rather
  /// than a value and is never desugared.
  funcRefCallees: Map[String, Bool]
  /// Implicit conversions made explicit after the check, keyed like
  /// `recordCopySites` (see `Lyric.Parser.ArgConversionSite`): widenings
  /// the backends cannot see, and unsigned operands whose lowering depends
  /// on signedness (#7812).
  argConversionSites: Map[String, ArgConversionSite]
  /// Result types of qualified and method calls and of field reads, keyed
  /// like `recordCopySites`: evidence for `Lyric.Mono`, which cannot see the
  /// signatures of other packages' non-generic functions (D-progress-969) or
  /// the fields of a restored package's records, so `mapKeys(o.inner.m)`
  /// infers its type arguments from the checked type of `o.inner.m` (#7441).
  callResultTypes: Map[String, TypeExpr]
  /// The checked type of an unannotated `val`/`var`/`let`, keyed by
  /// `recordCopySiteKey` of the initializer's span, where a backend needs it
  /// spelled out.  `Lyric.Mono.desugarCheckedFile` writes it onto the binding
  /// as its annotation.  Two kinds of binding are recorded:
  ///   * one whose initializer is a function value: a backend that erases
  ///     function values to a uniform boxed delegate must know a call's
  ///     result type to unbox it, and cannot infer it from a lambda body that
  ///     reads captured locals (#7711);
  ///   * an open binding (`openBindingSites`) whose later uses fixed its type
  ///     arguments: a backend with reified generics (MSIL) must build
  ///     `List<Seed>`, not `List<object>`, where it is constructed (#7788).
  localBindingTypeSites: Map[String, TypeExpr]
  /// Each open binding, keyed by `recordCopySiteKey` of its initializer's
  /// span (see `OpenBindingSite`, #7788).
  openBindingSites: Map[String, OpenBindingSite]
  /// Each call through a function value, keyed by `recordCopySiteKey` of the
  /// call's span (see `Lyric.Parser.FuncValueCallSite`, #7716).
  funcValueCallSites: Map[String, FuncValueCallSite]
  /// Each name a tuple pattern binds, and the name a `for` over a generator
  /// binds, keyed by `recordCopySiteKey` of the binding's span (see
  /// `Lyric.Parser.TuplePatternBindingSite`, #7728, #7750).
  tuplePatternBindingSites: Map[String, TuplePatternBindingSite]
  /// Each list literal checked with no collection type expected of it,
  /// keyed by `recordCopySiteKey` of the literal's span (see
  /// `Lyric.Parser.ListLiteralTypeSite`, #7818).
  listLiteralTypeSites: Map[String, ListLiteralTypeSite]
  /// Each operand evaluated before an `await` or a `?` in the same
  /// expression whose type is a generic instantiation, keyed by
  /// `recordCopySiteKey` of the operand's span (see
  /// `Lyric.Parser.HoistOperandTypeSite`, #7823).
  hoistOperandTypeSites: Map[String, HoistOperandTypeSite]
  /// The checked type of each unannotated module `val` the destructuring
  /// desugaring synthesized, keyed by its name; `annotateModuleVals` writes
  /// it onto the declaration (#7763).
  moduleValTypes: Map[String, TypeExpr]
  /// Span keys (`recordCopySiteKey`) of the calls whose resolved callee is a
  /// generator (a yield-bearing `async func`), written by the `ECall` arm
  /// from the signature the call actually binds to.  A `for` over a call
  /// consults it to decide whether the call's type is the loop's element
  /// type (#7771): a same-named method, type-associated function or local
  /// function value never counts.
  generatorCallSites: Map[String, Bool]
  /// Span keys (`recordCopySiteKey`) of the calls whose resolved callee is
  /// one of the stdlib's evidence-free collection constructors
  /// (`Std.CollectionsHost.newList` / `newListWithCapacity` / `newMap`),
  /// written by the `ECall` arm from the signature the call binds to.  An
  /// unannotated binding initialized by one is open (#7788); a same-named
  /// function of another package never is (#7801).
  emptyCollectionCtorSites: Map[String, Bool]
  /// Span keys (`recordCopySiteKey`) of the calls whose resolved callee is an
  /// `async func` (not a generator), written by the `ECall` arm from the
  /// signature the call binds to.  A direct call to an async function awaits
  /// in place (docs/01 §7.1); `Lyric.Propagate` makes that await explicit on
  /// targets whose lowering needs it (#7838).
  asyncCallSites: Map[String, Bool]
  /// The declaring package and name (`Pkg.Sub.Name`) of the record, union,
  /// opaque, protected or distinct type each field-access or method-call receiver
  /// has, keyed like
  /// `recordCopySites` by the receiver's span.  The JVM backend erases
  /// generics, so a receiver read out of a generic container or a generic
  /// call is statically `Object` there; this is the type it narrows to
  /// (#7378).  Also keyed by the span of each union-case pattern (never an
  /// expression's span): the union the pattern matches, which the JVM
  /// resolves the case name in before the enclosing package's unions (#7761).
  memberRecvClasses: Map[String, String]
  /// The first symbol declaring each type id, keyed by the id, filled lazily
  /// by `symTableTypeSymbolOf` as symbols are appended.
  typeSymbolsById: Map[String, Symbol]
  /// One entry per symbol already folded into `typeSymbolsById` (its count is
  /// the index cursor, the `TypeIdCounter` idiom).
  typeSymbolsIndexed: List[Int]
  /// The `TypeId` of each type `Std.CollectionsHost` declares (`List`, `Map`,
  /// `MapKeyCollection`, `MapValueCollection`, ...), keyed by name, filled
  /// lazily by `symTableStdCollectionsHostTypeId` as symbols are appended
  /// (#7765).
  stdCollectionsHostTypeIds: Map[String, TypeId]
  /// A one-element cursor: how many of `symbols` have been folded into
  /// `stdCollectionsHostTypeIds`.
  stdCollectionsHostIndexed: List[Int]
  /// Every operator applied to distinct-typed operands, keyed by
  /// `recordCopySiteKey` of the binop's span: `arith:<T>.from` for derived
  /// arithmetic (`a + b` via `derives Add`), `cmp` for `==`/`!=` and the
  /// derived comparisons.  A distinct value is a wrapper on the managed
  /// targets, so `Lyric.ContractElaborator.lowerDistinctOps` rewrites each
  /// site through `.value` and `T.from`, which also re-checks a range
  /// subtype's result (#7361, #7226).
  distinctOpSites: Map[String, String]
  /// A compound assignment (`c += d`) whose target is distinct-typed, keyed
  /// by the statement's span, mapped to `<T>.from`.
  distinctCompoundSites: Map[String, String]
  /// The package whose bare-name lookups obey its file's import list
  /// (docs/01 §9.2, #7463), boxed as a 0/1-element list; empty = no
  /// restriction.  Set for the file being checked only: an imported
  /// package's signatures were checked under the same rule when that
  /// package was itself compiled.
  importRulePkg: List[String]
  /// Packages whose every name is visible bare under `importRulePkg`: its
  /// whole imports (no selector, no alias) and, transitively, each reached
  /// package's own imports.
  importVisiblePkgs: Map[String, Bool]
  /// `<package>|<name>` for each name a selective import lists.
  importVisibleNames: Map[String, Bool]
  /// `<package>` -> the alias an `import P as Q` gives it.
  importAliases: Map[String, String]
}

/// An unannotated local binding whose initializer builds an empty
/// collection or `None` (`newList()`, `newListWithCapacity(n)`, `newMap()`,
/// `None`, #7788).  Nothing at the initializer fixes its type arguments, so
/// it types as `List[<error>]` / `Option[<error>]` and every later use is
/// accepted leniently.  Its uses do fix them, and are recorded here: a sink is
/// a position with a declared type the binding flows into (a call argument, a
/// returned or trailing value, a typed binding's initializer, a constructor
/// field, an assignment's value); a store is a value put into it
/// (`xs.add(x)`, `xs.add(i, x)`, `m.add(k, v)`, `xs[i] = x`, `o = Some(x)`).
/// `resolveOpenBindingSites` turns them into the binding's annotation.  Each
/// `List` field is a mutable 0/1-element box.
pub record OpenBindingSite {
  /// The initializer's span; the resolved annotation carries it, so
  /// `Lyric.Mono.desugarCheckedFile` finds the binding it belongs to.
  initSpan: Span
  /// The type the initializer inferred: the constructor, with holes.
  initTy: Type
  /// The first sink's type, and its source spelling.
  sinkTy: List[Type]
  sinkTe: List[TypeExpr]
  /// The type the first store fixes, and its source spelling.
  storeTy: List[Type]
  storeTe: List[TypeExpr]
  /// Non-empty once two sinks, or two stores, disagree.
  sinkConflict: List[Bool]
  storeConflict: List[Bool]
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
  val stdCollectionsHostIndexed: List[Int] = newList()
  stdCollectionsHostIndexed.add(0)
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
    memberCompleteTypes = newMap(),
    externBlockMembers = newMap(),
    externBlockPackages = newMap(),
    symbolPackages = newMap(),
    symbolPackageMembers = newMap(),
    packageImports = newMap(),
    funcExportCache = newMap(),
    recordCopySites = newMap(),
    invariantCtorSites = newMap(),
    funcRefSites = newMap(),
    funcRefCallees = newMap(),
    argConversionSites = newMap(),
    callResultTypes = newMap(),
    localBindingTypeSites = newMap(),
    openBindingSites = newMap(),
    funcValueCallSites = newMap(),
    tuplePatternBindingSites = newMap(),
    listLiteralTypeSites = newMap(),
    hoistOperandTypeSites = newMap(),
    moduleValTypes = newMap(),
    generatorCallSites = newMap(),
    emptyCollectionCtorSites = newMap(),
    asyncCallSites = newMap(),
    memberRecvClasses = newMap(),
    typeSymbolsById = newMap(),
    typeSymbolsIndexed = newList(),
    stdCollectionsHostTypeIds = newMap(),
    stdCollectionsHostIndexed = stdCollectionsHostIndexed,
    distinctOpSites = newMap(),
    distinctCompoundSites = newMap(),
    importRulePkg = newList(),
    importVisiblePkgs = newMap(),
    importVisibleNames = newMap(),
    importAliases = newMap()
  )
}

/// The first symbol that declares the type with id `tid`. Symbols appended
/// since the last lookup are indexed first, so a lookup costs amortised
/// constant time rather than a scan of the whole table.
pub func symTableTypeSymbolOf(tbl: in SymbolTable, tid: in TypeId): Option[Symbol] {
  while tbl.typeSymbolsIndexed.count < tbl.symbols.count {
    val sym = tbl.symbols[tbl.typeSymbolsIndexed.count]
    match symbolTypeIdOpt(sym) {
      case Some(sid) -> {
        val key = toString(sid.id)
        if not tbl.typeSymbolsById.containsKey(key) {
          tbl.typeSymbolsById.add(key, sym)
        }
      }
      case None -> ()
    }
    tbl.typeSymbolsIndexed.add(0)
  }
  mapGet(tbl.typeSymbolsById, toString(tid.id))
}

/// The `TypeId` of the type named `name` that the stdlib's
/// `Std.CollectionsHost` package declares, or `None` when no such type is
/// registered.  Equivalent to `symTableTryFindInPackage(tbl,
/// "Std.CollectionsHost", name)` followed by `symbolTypeIdOpt` -- the most
/// recently registered symbol wins -- but each symbol is examined once per
/// table instead of once per query: the stdlib-collection checks
/// (`isStdCollectionsHostType`) run on every iterated, indexed or
/// bracket-literal-typed collection, and a linear scan of the whole table at
/// each of them dominated large files (#7765).
pub func symTableStdCollectionsHostTypeId(tbl: in SymbolTable, name: in String): Option[TypeId] {
  var cursor = tbl.stdCollectionsHostIndexed[0]
  while cursor < tbl.symbols.count {
    val sym = tbl.symbols[cursor]
    if sym.originPackage == "Std.CollectionsHost" {
      if tbl.stdCollectionsHostTypeIds.containsKey(sym.name) {
        tbl.stdCollectionsHostTypeIds.remove(sym.name)
      }
      match symbolTypeIdOpt(sym) {
        case Some(tid) -> tbl.stdCollectionsHostTypeIds.add(sym.name, tid)
        case None -> ()
      }
    }
    cursor = cursor + 1
  }
  tbl.stdCollectionsHostIndexed[0] = cursor
  mapGet(tbl.stdCollectionsHostTypeIds, name)
}

// #6689: record `pkg`'s own declared import list, so a later cross-package
// field-type resolution (`collectCtorFields`) can temporarily resolve under
// `pkg`'s scope instead of the caller's. Idempotent — the first registration
// for a given `pkg` wins (mirrors `addSigsFromItems`'s imported-first-wins
// policy; a package's import list does not change mid-build).
pub func symTableRegisterPackageImports(tbl: in SymbolTable, pkg: in String, imports: in List[String]): Unit {
  if not tbl.packageImports.containsKey(pkg) {
    tbl.packageImports.add(pkg, imports)
  }
}

// The import list registered for `pkg` via `symTableRegisterPackageImports`,
// or an empty list if `pkg` was never registered (e.g. a synthesised/
// contract-surface check that never ran the T3 signature-collection pass).
pub func symTablePackageImportsOf(tbl: in SymbolTable, pkg: in String): List[String] {
  match mapGet(tbl.packageImports, pkg) {
    case Some(imports) -> imports
    case None -> newList()
  }
}

// Record that `name` is a member of an `extern package { ... }` block
// declared within package `pkg` (#6361). Idempotent.
pub func symTableAddExternBlockMember(tbl: in SymbolTable, pkg: in String, name: in String): Unit {
  val key = pkg + "|" + name
  if not tbl.externBlockMembers.containsKey(key) {
    tbl.externBlockMembers.add(key, true)
  }
  if not tbl.externBlockPackages.containsKey(pkg) {
    tbl.externBlockPackages.add(pkg, true)
  }
}

// True when `name` was registered as an extern-package-block member of `pkg`.
pub func symTableHasExternBlockMember(tbl: in SymbolTable, pkg: in String, name: in String): Bool {
  tbl.externBlockMembers.containsKey(pkg + "|" + name)
}

// True when `pkg` contributed at least one `extern package { ... }` block
// member (#6378) — i.e. the package is known to the checker even though it
// may have added nothing to `tbl.symbols` (a file that is nothing but one
// or more `extern package { ... }` blocks never does).
pub func symTablePackageHasAnyExternBlockMember(tbl: in SymbolTable, pkg: in String): Bool {
  tbl.externBlockPackages.containsKey(pkg)
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

// True when unknown-member diagnostics may fire for the type `tid`: a record,
// exposed record or interface, whose member surface is fully known whether it
// is declared in the file being checked or imported.  Imported types were once
// exempt because contract reprs dropped record-body methods; the repr carries
// them since #6440, so the exemption only hid typos (#7575).
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
      val key = toString(rid.id)
      if not tbl.memberCompleteTypes.containsKey(key) {
        tbl.memberCompleteTypes.add(key, true)
      }
    }
    case DKExposedRec(xid, _) -> {
      val key = toString(xid.id)
      if not tbl.memberCompleteTypes.containsKey(key) {
        tbl.memberCompleteTypes.add(key, true)
      }
    }
    case DKInterface(iid, _) -> {
      val key = toString(iid.id)
      if not tbl.memberCompleteTypes.containsKey(key) {
        tbl.memberCompleteTypes.add(key, true)
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
  if not tbl.symbolPackages.containsKey(sym.originPackage) {
    tbl.symbolPackages.add(sym.originPackage, true)
  }
  val memberKey = sym.originPackage + "|" + sym.name
  if not tbl.symbolPackageMembers.containsKey(memberKey) {
    tbl.symbolPackageMembers.add(memberKey, true)
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

/// Resolve `name` to a symbol declared by EXACTLY the package `pkg`
/// (dotted origin-package name), newest-first.  The package-qualified
/// counterpart of `symTableTryFindOne`: a qualified reference must never
/// fall back to a same-named symbol from a different package (#6287 —
/// last-registered-wins silently resolved `PkgA.Ping(...)` to a colliding
/// case from PkgB, despite the explicit qualifier).
pub func symTableTryFindInPackage(tbl: in SymbolTable, pkg: in String, name: in String): Option[Symbol] {
  var i = tbl.symbols.count - 1
  while i >= 0 {
    val s = tbl.symbols[i]
    if s.name == name and s.originPackage == pkg {
      return Some(value = s)
    }
    i = i - 1
  }
  None
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

// `symTableTryFindAll` narrowed to the symbols a bare `name` may mean under
// the current scope's import rule (docs/01 §9.2); every match when no rule
// applies.
pub func symTableTryFindAllVisible(tbl: in SymbolTable, name: in String): List[Symbol] {
  val curPkg = symTableScopePkg(tbl)
  val ruled = curPkg.length > 0 and symTableImportRuleApplies(tbl, curPkg)
  val result: List[Symbol] = newList()
  var i = 0
  while i < tbl.symbols.count {
    val s = tbl.symbols[i]
    if s.name == name and (not ruled or symTableImportVisible(tbl, curPkg, s)) {
      result.add(s)
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
//
// Under the import rule of the file being checked (`symTableSetImportRule`,
// docs/01 §9.2, D141) a candidate from another package counts only when the
// file's imports make it visible bare, so tiers 2 and 3 never reach a name
// that is unimported, behind an alias, or left out of a selective import
// (#7463, #6703).  Internal lookups outside that scope (an imported
// package's own signatures) stay unrestricted.
pub func symTableTryFindOne(tbl: in SymbolTable, name: in String): Option[Symbol] {
  val curPkg = symTableScopePkg(tbl)
  val hasScope = curPkg.length > 0
  val hasImports = tbl.scopeImports.count > 0
  val ruled = hasScope and symTableImportRuleApplies(tbl, curPkg)
  var best2: Option[Symbol] = None
  var best3: Option[Symbol] = None
  var i = tbl.symbols.count - 1
  while i >= 0 {
    val s = tbl.symbols[i]
    if s.name == name and (not ruled or symTableImportVisible(tbl, curPkg, s)) {
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

// ─────────────────────────────────────────────────────────────────────────────
// §4b. Import visibility (docs/01 §9.2, #7463).
// ─────────────────────────────────────────────────────────────────────────────
// Record the import rule for `pkg`: `whole` are its whole imports, already
// widened to their transitive closure; `names` are `<package>|<name>` keys of
// selectively imported names; `aliases` pairs each aliased package with its
// alias.  From here on a bare lookup under `pkg`'s scope sees only these.
pub func symTableSetImportRule(
  tbl: in SymbolTable,
  pkg: in String,
  whole: in List[String],
  names: in List[String],
  aliasPkgs: in List[String],
  aliasNames: in List[String],
): Unit {
  while tbl.importRulePkg.count > 0 {
    tbl.importRulePkg.removeAt(tbl.importRulePkg.count - 1)
  }
  tbl.importRulePkg.add(pkg)
  var i = 0
  while i < whole.count {
    if not tbl.importVisiblePkgs.containsKey(whole[i]) {
      tbl.importVisiblePkgs.add(whole[i], true)
    }
    i = i + 1
  }
  var j = 0
  while j < names.count {
    if not tbl.importVisibleNames.containsKey(names[j]) {
      tbl.importVisibleNames.add(names[j], true)
    }
    j = j + 1
  }
  var k = 0
  while k < aliasPkgs.count and k < aliasNames.count {
    if not tbl.importAliases.containsKey(aliasPkgs[k]) {
      tbl.importAliases.add(aliasPkgs[k], aliasNames[k])
    }
    k = k + 1
  }
}

func symTableImportRuleApplies(tbl: in SymbolTable, pkg: in String): Bool {
  tbl.importRulePkg.count > 0 and tbl.importRulePkg[0] == pkg
}

// The implicit prelude: `Option` and `Result` from `Std.Core`, with their cases.
func isPreludeName(name: in String): Bool {
  name == "Option" or name == "Result"
}

// The name of the type a union or enum case belongs to, for a case symbol;
// "" for any other symbol.
func caseParentName(tbl: in SymbolTable, sym: in Symbol): String {
  match sym.kind {
    case DKUnionCase(pid, _) -> typeNameOfId(tbl, pid)
    case DKEnumCase(pid, _) -> typeNameOfId(tbl, pid)
    case _ -> ""
  }
}

func typeNameOfId(tbl: in SymbolTable, tid: in TypeId): String {
  match symTableTypeSymbolOf(tbl, tid) {
    case Some(parent) -> parent.name
    case None -> ""
  }
}

// Whether `sym` may be named bare from package `curPkg` under its import
// rule.  A case is visible when its type is: `import P.{Color}` makes
// `case Red ->` resolve.
func symTableImportVisible(tbl: in SymbolTable, curPkg: in String, sym: in Symbol): Bool {
  val origin = sym.originPackage
  if origin.length == 0 or origin == curPkg or tbl.importVisiblePkgs.containsKey(origin) {
    return true
  }
  if tbl.importVisibleNames.containsKey(origin + "|" + sym.name) {
    return true
  }
  val parent = caseParentName(tbl, sym)
  if origin == "Std.Core" {
    val preludeName = if parent.length > 0 { parent } else { sym.name }
    if isPreludeName(preludeName) {
      return true
    }
  }
  parent.length > 0 and tbl.importVisibleNames.containsKey(origin + "|" + parent)
}

// Whether a function `name` declared in `origin` may be called bare under
// the current scope's import rule (functions resolve through the signature
// map, not a `Symbol`, so this is the by-name form of the rule).
pub func symTableBareFuncVisible(tbl: in SymbolTable, origin: in String, name: in String): Bool {
  val curPkg = symTableScopePkg(tbl)
  if curPkg.length == 0 or not symTableImportRuleApplies(tbl, curPkg) {
    return true
  }
  origin.length == 0 or origin == curPkg or tbl.importVisiblePkgs.containsKey(origin) or
    tbl.importVisibleNames.containsKey(origin + "|" + name)
}

// The resolution tier of a function `name` declared in `origin` for a bare
// reference under the current scope, as `symTableTryFindOne` orders other
// names: 0 for the current package (or no import rule), 1 for a direct
// import, 2 for a package reached only transitively or the prelude, and -1
// when the import rule hides it.  A lower tier shadows a higher one.
pub func symTableBareFuncTier(tbl: in SymbolTable, origin: in String, name: in String): Int {
  val curPkg = symTableScopePkg(tbl)
  if curPkg.length == 0 or not symTableImportRuleApplies(tbl, curPkg) or origin.length == 0 or origin == curPkg {
    return 0
  }
  if not symTableBareFuncVisible(tbl, origin, name) or not symTablePackageExportsFunc(tbl, origin, name) {
    return -1
  }
  if symTableScopeAllows(tbl, origin) {
    1
  } else {
    2
  }
}

// Whether package `pkg`'s functions named `name` include one another package
// may call (`pub` or `internal`); a name whose declarations there are all
// package-private is never a bare-call candidate outside the package.  A
// signature with no function symbol behind it (a synthesised one) counts.
func symTablePackageExportsFunc(tbl: in SymbolTable, pkg: in String, name: in String): Bool {
  val key = pkg + "|" + name
  match mapGet(tbl.funcExportCache, key) {
    case Some(known) -> return known
    case None -> ()
  }
  val exported = scanPackageExportsFunc(tbl, pkg, name)
  tbl.funcExportCache.add(key, exported)
  exported
}

func scanPackageExportsFunc(tbl: in SymbolTable, pkg: in String, name: in String): Bool {
  var sawFunc = false
  var i = 0
  while i < tbl.symbols.count {
    val s = tbl.symbols[i]
    if s.name == name and s.originPackage == pkg {
      match s.kind {
        case DKFunc(_) -> {
          if symIsCrossPackageVisible(s) {
            return true
          }
          sawFunc = true
        }
        case _ -> ()
      }
    }
    i = i + 1
  }
  not sawFunc
}

// When a bare `name` failed to resolve only because the import rule hides
// it, the hint that says how to import it (with a leading space); otherwise
// "".  Used by the unknown-name diagnostics.
pub func symTableHiddenImportHint(tbl: in SymbolTable, name: in String): String {
  val curPkg = symTableScopePkg(tbl)
  if curPkg.length == 0 or not symTableImportRuleApplies(tbl, curPkg) {
    return ""
  }
  // Extern types carry no visibility, so the second pass accepts any
  // declaration from another package.
  var pass = 0
  while pass < 2 {
    val hint = hiddenImportHintPass(tbl, curPkg, name, pass == 0)
    if hint.length > 0 {
      return hint
    }
    pass = pass + 1
  }
  ""
}

// The package a file imports to reach `pkg`: for the kernel host naming
// convention (`Std.XHost` behind `Std.X`) the public package when it is
// loaded and imports the host, otherwise `pkg` itself.
func publicPackageOf(tbl: in SymbolTable, pkg: in String): String {
  if not pkg.endsWith("Host") {
    return pkg
  }
  val home = pkg.substring(0, pkg.length - 4)
  match mapGet(tbl.packageImports, home) {
    case Some(imports) -> {
      var i = 0
      while i < imports.count {
        if imports[i] == pkg {
          return home
        }
        i = i + 1
      }
      pkg
    }
    case None -> pkg
  }
}

func hiddenImportHintPass(tbl: in SymbolTable, curPkg: in String, name: in String, visibleOnly: Bool): String {
  var i = tbl.symbols.count - 1
  while i >= 0 {
    val s = tbl.symbols[i]
    if s.name == name and s.originPackage.length > 0 and s.originPackage != curPkg and (not visibleOnly or symIsCrossPackageVisible(s)) and not symTableImportVisible(tbl, curPkg, s) {
      val origin = s.originPackage
      match mapGet(tbl.importAliases, origin) {
        case Some(alias) -> {
          return " (declared in " + origin + ", imported as " + alias + "; write " + alias + "." + name + ")"
        }
        case None -> ()
      }
      val parentName = caseParentName(tbl, s)
      val shown = if parentName.length > 0 { parentName } else { name }
      // A kernel host package (`Std.CollectionsHost`) is imported through
      // its public package (`Std.Collections`), whose whole import reaches it.
      val home = publicPackageOf(tbl, origin)
      if home != origin {
        return " (declared in " + origin + "; add import " + home + ")"
      }
      return " (declared in " + origin + "; add import " + origin + " or import " + origin + ".{" + shown + "})"
    }
    i = i - 1
  }
  ""
}

// The interface a `where` constraint names: a bare name resolves in scope, a
// package-qualified one (`Std.Log.Logger`, also what an aliased
// `Log.Logger` becomes) in that package.
pub func constraintInterfaceSym(tbl: in SymbolTable, name: in String): Option[Symbol] {
  var dot = -1
  var i = 0
  while i < name.length {
    if name.substring(i, 1) == "." {
      dot = i
    }
    i = i + 1
  }
  val found = if dot > 0 {
    symTableTryFindInPackage(tbl, name.substring(0, dot), name.substring(dot + 1))
  } else {
    symTableTryFindOne(tbl, name)
  }
  match found {
    case Some(sym) -> match sym.kind { case DKInterface(_, _) -> found; case _ -> None }
    case None -> None
  }
}

// True when `sym` is reachable from another package (`pub` or `internal`) —
// mirrors the visibility gate `checkImportedVisibility` (T0097) already
// enforces post-resolution; a package-private symbol in some other imported
// package was never a *legal* candidate, so it must not count toward an
// ambiguity diagnosis either (#6287).
func symIsCrossPackageVisible(sym: in Symbol): Bool {
  match sym.visibility {
    case Some(_) -> true
    case None -> false
  }
}

// The distinct imported packages (in encounter order, each listed once) that
// each contribute a cross-package-visible symbol named `name` under the
// CURRENT resolution scope (#6287 — bare-name ambiguity).  Length 0 or 1
// means `name` is not ambiguous; 2+ means a bare reference to `name` cannot
// tell which package's declaration is meant and must be qualified.  Only
// examines tier-2 candidates (an imported package match) — the current
// package's own declaration (tier 1) always wins outright and is never
// ambiguous with anything.
pub func symTableAmbiguousImportPackages(tbl: in SymbolTable, name: in String): List[String] {
  val pkgs: List[String] = newList()
  if tbl.scopeImports.count == 0 {
    return pkgs
  }
  val curPkg = symTableScopePkg(tbl)
  // Tier 1 (current package) always wins outright over any import, so a
  // same-named declaration in the CURRENT package makes any cross-import
  // collision moot — it is never reachable via bare-name resolution.
  if curPkg.length > 0 {
    var ci = 0
    while ci < tbl.symbols.count {
      if tbl.symbols[ci].name == name and tbl.symbols[ci].originPackage == curPkg {
        return pkgs
      }
      ci = ci + 1
    }
  }
  // A candidate the import rule hides cannot be meant by a bare reference.
  // Under the rule a package reached only through a whole import's own
  // imports is as visible as a direct one, so two such packages collide too;
  // a directly imported candidate still shadows every transitive one, as it
  // does in `symTableTryFindOne`.
  val ruled = curPkg.length > 0 and symTableImportRuleApplies(tbl, curPkg)
  val transitive: List[String] = newList()
  val seen: Map[String, Bool] = newMap()
  var i = 0
  while i < tbl.symbols.count {
    val s = tbl.symbols[i]
    if s.name == name and s.originPackage != curPkg and symIsCrossPackageVisible(s) and (not ruled or symTableImportVisible(tbl, curPkg, s)) {
      if not seen.containsKey(s.originPackage) {
        if symTableScopeAllows(tbl, s.originPackage) {
          seen.add(s.originPackage, true)
          pkgs.add(s.originPackage)
        } else if ruled and s.originPackage.length > 0 {
          seen.add(s.originPackage, true)
          transitive.add(s.originPackage)
        }
      }
    }
    i = i + 1
  }
  if pkgs.count > 0 {
    return pkgs
  }
  transitive
}

// Whether `pkg` is one of the current scope's direct imports, as opposed to
// a package it reaches through a whole import's own imports.
pub func symTableIsDirectImport(tbl: in SymbolTable, pkg: in String): Bool {
  symTableScopeAllows(tbl, pkg)
}
