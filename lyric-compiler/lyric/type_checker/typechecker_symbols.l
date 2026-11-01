//! typechecker_symbols.l — symbol table entries and symbol table.
//! Mirrors compiler/src/Lyric.TypeChecker/Symbol.fs.
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.Symbols
import Lyric.Resolve.{ResolverContext, resolveBare, scopeOfFile, declOfId, funcDefPath, NameUse, UseValue, Resolution, RSymbol, ROverloads, RUnresolved, RPackage, RDeferred}

// ─────────────────────────────────────────────────────────────────────────────
// §1. DeclKind — what kind of declaration each symbol represents.
// ─────────────────────────────────────────────────────────────────────────────
@stable(since = "0.1")
pub union DeclKind {
  // Type-level declarations.
  case DKRecord(id: SymbolId, decl: RecordDecl)
  case DKExposedRec(id: SymbolId, decl: RecordDecl)
  case DKUnion(id: SymbolId, decl: UnionDecl)
  case DKEnum(id: SymbolId, decl: EnumDecl)
  case DKOpaque(id: SymbolId, decl: OpaqueTypeDecl)
  case DKProtected(id: SymbolId, decl: ProtectedTypeDecl)
  case DKDistinctType(id: SymbolId, decl: DistinctTypeDecl)
  case DKTypeAlias(decl: TypeAliasDecl)
  case DKInterface(id: SymbolId, decl: InterfaceDecl)
  case DKExternType(id: SymbolId, decl: ExternTypeDecl)
  // Term-level declarations.
  case DKConst(decl: ConstDecl)
  case DKVal(decl: ValDecl)
  case DKFunc(decl: FunctionDecl)
  case DKWire(decl: WireDecl)
  case DKExtern(decl: ExternPackageDecl)
  case DKScopeKind(decl: ScopeKindDecl)
  // Test-only declarations.  A `fixture` is registered as the `DKVal` it
  // becomes under `lyric test` (#8308).
  case DKTest(decl: TestDecl)
  case DKProperty(decl: PropertyDecl)
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
  case DKUnionCase(parentId: SymbolId, uc: UnionCase)
  case DKEnumCase(parentId: SymbolId, ec: EnumCase)
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

pub func symbolTypeIdOpt(s: in Symbol): Option[SymbolId] {
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
pub func symTableIsExternDelegateType(tbl: in SymbolTable, id: in SymbolId): Bool {
  match mapGet(tbl.externDelegateFlags, toString(id.id)) {
    case Some(v) -> v
    case None -> false
  }
}

// #6720: is `id` the SymbolId of a `DKExternType` (an `extern type` binding,
// e.g. `Set[T]`/`JHttpStringCollection[T]`)?  Used by `SFor`'s single-type-
// param generic element-typing fallback (D-progress-818) to distinguish a
// genuine extern collection (the phantom-type-param FFI idiom this fallback
// exists for) from a Lyric-native single-param generic that merely happens
// to have one type parameter (e.g. `Option[T]`) but isn't iterable.  A
// linear scan — called once per `for` statement, not per element access —
// so no side index is warranted (contrast `externDelegateFlags`, consulted
// per call argument).
pub func symTableIsExternTypeId(tbl: in SymbolTable, id: in SymbolId): Bool {
  var i = 0
  while i < tbl.symbols.count {
    match tbl.symbols[i].kind {
      case DKExternType(tid, _) -> if symbolIdEq(tid, id) { return true }
      case _ -> {
      }
    }
    i = i + 1
  }
  false
}

// The `ExternTypeDecl` an extern type id names, or None.
pub func symTableExternDeclOf(tbl: in SymbolTable, id: in SymbolId): Option[ExternTypeDecl] {
  match symTableTypeSymbolOf(tbl, id) {
    case Some(sym) -> match sym.kind { case DKExternType(_, decl) -> Some(value = decl); case _ -> None }
    case None -> None
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. SymbolTable — package-level symbol store (bootstrap: linear scan).
// ─────────────────────────────────────────────────────────────────────────────
/// A call to an `@io` function (`isEntry` false) or to a protected type's
/// `entry` (`isEntry` true), for the layer rules (D149).
pub record EffectCallSite {
  span: Span
  callee: String
  isEntry: Bool
}

/// A module-level `val` holding shared mutable state; `what` names its kind
/// for the diagnostic ("a List", "an instance of protected type Cell").
pub record MutableModuleVal {
  name: String
  span: Span
  what: String
}

/// A call to a generic dot-named function: the function's name, and whether
/// it was written as a method call, whose receiver becomes the first
/// argument (`b.get()`), rather than through the type (`Box.get(b)`).
pub record DottedGenericCall {
  name: String
  receiverFirst: Bool
  /// The declaring package when it is not the calling one, so the call is
  /// written through it and a caller's same-named function or type cannot
  /// capture it (#8179); "" for the calling package's own function.
  originPkg: String
}

/// A call of a dot-named function with an `out`/`inout` parameter (#8179,
/// #8183), written as a method call (`p.m(x)`, `receiverFirst`) or through
/// its type (`T.m(p, x)`): the function's name (`T.m`), and the package that
/// declares it when that is another package and the function is not generic
/// ("" otherwise).  `Lyric.Pipeline` rewrites the call into a plain call of
/// the function, so the receiver is an ordinary argument and an `out`/`inout`
/// one is passed by reference.
pub record ByRefDotCall {
  name: String
  receiverFirst: Bool
  originPkg: String
  /// A call through the type that binds a method in the type's body
  /// (D181): `T.m(x, args)` becomes the method call `x.m(args)`, `name`
  /// being `m`.
  asMethod: Bool = false
}

/// A construction of a case of a union with value generic parameters
/// (#8149): the union, and the value arguments of the instance it builds, in
/// parameter order, as a literal length or the name of an enclosing value
/// generic parameter.
pub record ValueUnionCtorSite {
  unionName: String
  lengths: List[TypeArg]
}

/// A `?` operand that fixes no success type (see
/// `SymbolTable.openPropagateOperands`): the operand, the enclosing function's
/// own monad instantiation it takes when nothing consuming it gives it a
/// success type, and that function's type parameters.
pub record OpenPropagateOperand {
  operand: Expr
  fallback: Type
  typeParams: List[String]
}

/// Which methods a `String` receiver has on the target being checked for
/// (#7204, docs/01 §12.1).  The two backends do not share a surface: the
/// `--target dotnet` lowering is a closed cascade, so a name outside it
/// can never be lowered, while `--target jvm` falls back to the JDK's own
/// `java.lang.String` by auto-FFI, so any method the JDK has is valid.
pub union StringMethodSurface {
  /// The target is unknown (the language server, the contract checks, a
  /// direct `check`) or does not say: no method call on a `String` is
  /// reported as unknown.
  case SMSUnchecked
  /// Only the built-in methods (`stringHostMethodType`, `indexOf`,
  /// `lastIndexOf`, `length`, `isEmpty`, the universal methods), the
  /// dot-named `String` functions and the extensions the imports reach.
  case SMSClosed
  /// The above, and every instance method of `java.lang.String` and its
  /// supertypes, named in `hostMethods`.
  case SMSOpen(hostMethods: List[String])
}

/// What a `for` loop over an extern type binds, as one element type the host
/// declares for the type's iteration protocol, written in terms of the extern
/// type's own type parameters and host types (docs/42 section 9, D302).  A
/// bridge reads the host metadata (`Msil.MetadataReader`, `Jvm.AutoFfi`);
/// `Lyric.TypeChecker` is target-agnostic and cannot.
pub union ExternIterElem {
  /// The extern type's own type argument at this position (`Dict[K, V]`'s `K`).
  case EIEArg(index: Int)
  /// A Lyric primitive the host element type maps to (`Int`, `String`, ...).
  case EIEPrim(name: String)
  /// A host class or interface, by its host name without the arity suffix
  /// (`System.Collections.Generic.KeyValuePair`), applied to element types.
  /// It types as the `extern type` bound to that host name in scope.
  case EIEHost(hostName: String, args: List[ExternIterElem])
}

/// Answers, on demand, how the host type behind an `extern type` iterates.
/// A backend bridge implements it over the host metadata it can read; the
/// checker asks only for the types a `for` actually iterates, so a build does
/// not read the metadata of every extern type it imports.  None means the
/// bridge cannot say (a type it cannot locate): the loop variable is then left
/// unchecked.
pub interface ExternIterResolver {
  func resolveIter(clrName: in String, arity: in Int): Option[ExternIterInfo]
}

/// How a host type iterates: what a bridge found in its metadata.
pub union ExternIterInfo {
  /// Neither `IEnumerable` nor `Iterable`: not iterable (T0126).
  case EIINone
  /// Only the untyped protocol (`System.Collections.IEnumerable`, a raw
  /// `Iterable`): the elements are the host's `Object`.
  case EIIObject
  /// The typed protocol: `IEnumerable<T>` / `Iterable<T>` with this `T`.
  case EIIElem(elem: ExternIterElem)
}

@stable(since = "0.1")
pub record SymbolTable {
  symbols: List[Symbol]
  /// Preferred-package marker, boxed as a 0/1-element list (the
  /// list-boxing idiom); empty = no scope = last-registered-wins.
  scopePkg: List[String]
  /// Dotted names the current scope imports (second-tier resolution preference).
  scopeImports: List[String]
  /// Interface-conformance relations from `impl I for T` declarations, used
  /// for interface subtyping at argument positions (#1488): an arg of type `T`
  /// is accepted where the parameter is interface `I` when `(T, I)` is present.
  /// Keyed by `SymbolId` (not simple name) so a same-simple-name interface in a
  /// different package can never satisfy the check (#2303 soundness).
  impls: List[ImplPair]
  /// `toString(SymbolId.id)` → declared name of an *imported* opaque type.
  /// Side index populated by `symTableAdd` so `importedOpaqueName` (called
  /// once per `EMatch`) is O(1) instead of a full symbol scan (#2027).
  importedOpaqueNames: Map[String, String]
  /// `toString(SymbolId.id)` → index into `unionDeclList`.  Side index populated
  /// by `symTableAdd` so `parentUnionDeclOf` (called at least twice per
  /// union-constructor call) is O(1) instead of a full symbol scan (#2178).
  /// The decl itself lives in the parallel `unionDeclList` because the stage-0
  /// bootstrap emitter miscompiles `Map` values of cross-package record types
  /// (`UnionDecl` is a `Lyric.Parser` record); an `Int` map value plus a
  /// `List` read is the established safe pattern.
  unionDeclIndex: Map[String, Int]
  unionDeclList: List[UnionDecl]
  /// `toString(SymbolId.id)` → whether the `DKExternType` with that id is a
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
  /// `toString(SymbolId.id)` present ⇒ the type is declared in the file being
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
  /// `<path>` present ⇒ `path` is the declared path of an `extern package
  /// <path> { ... }` block (`lyric.db.Postgres`).  Such a path is a host
  /// binding named by its own spelling, never an importable Lyric package,
  /// so a qualified call through it is not subject to the import-reachability
  /// check (#7934).
  externPathPackages: Map[String, Bool]
  // One `impl Iface for Target` conformance, by resolved `SymbolId`.
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
  /// Each package's whole re-exports (`pub use P`), as registered with
  /// `symTableRegisterPackageReexports`.
  packageReexports: Map[String, List[String]]
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
  /// Every function of the package being checked referenced bare as a value
  /// (never a call callee), keyed like `funcRefSites`.  A package's own
  /// function values need no desugar in its own code (a forwarding thunk
  /// stands for them); this is read for a specialisation of this package's
  /// generic in another package, whose body must name the function there
  /// (`Lyric.Pipeline.foreignFuncValueSites`, #8329).
  ownFuncValueSites: Map[String, FuncRefSite]
  /// Callees of the form `f[A, B]` (an index of a name, as the parser leaves
  /// explicit type arguments written in source) that name a generic
  /// function under type arguments, keyed by `recordCopySiteKey` of the
  /// callee's span (#8279).  The `?` and `await` hoists leave such a callee
  /// in its call: it evaluates nothing.  Any other indexed callee
  /// (`handlers[i](x)`, including an imported `pub val`) is a value, read
  /// before the arguments.
  typeArgCalleeSites: Map[String, Bool]
  /// Implicit conversions made explicit after the check, keyed like
  /// `recordCopySites` (see `Lyric.Parser.ArgConversionSite`): widenings
  /// the backends cannot see, and unsigned operands whose lowering depends
  /// on signedness (#7812).
  argConversionSites: Map[String, ArgConversionSite]
  /// Values of a generic type that flow into a place of the same type over
  /// a supertype of its type argument (`Result[English, E]` into a
  /// `Result[Greeter, E]` place, D211), keyed like `recordCopySites`, with
  /// the name of the helper in `covariantHelpers` that converts the value.
  /// A backend whose instantiations are distinct runtime types applies
  /// them after the check (`Lyric.Pipeline`).
  covariantSites: Map[String, String]
  /// The conversion functions `covariantSites` name, synthesized by the
  /// checker (`covariantHelperName`) for the file being checked.
  covariantHelpers: List[FunctionDecl]
  /// `covariantHelpers` by the source and target types they convert between.
  covariantHelperNames: Map[String, String]
  /// Stringified operands of a structured type (a record, union, enum,
  /// tuple, `List`, `Map`, `Set` or slice), keyed like `recordCopySites`, with
  /// the name of the function in `showHelpers` that renders the operand
  /// (D282).  `Lyric.Pipeline` wraps each in a call of it.
  showSites: Map[String, String]
  /// The rendering functions `showSites` name, synthesized by the checker
  /// (`showHelperName`) for the file being checked.
  showHelpers: List[FunctionDecl]
  /// `showHelpers` by the rendered type.
  showHelperNames: Map[String, String]
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
  /// A tuple literal matched directly is recorded as an open binding's
  /// initializer is, keyed by the literal's span; Mono binds it to an
  /// annotated local (#7863).
  localBindingTypeSites: Map[String, TypeExpr]
  /// Each open binding, keyed by `recordCopySiteKey` of its initializer's
  /// span (see `OpenBindingSite`, #7788); a tuple literal matched directly,
  /// by its own span; a name a pattern binds to a sub-tuple holding open
  /// elements, by the name's span (#7863).
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
  /// expression whose type is a generic instantiation, each argument of
  /// a generic constructor that leaves its own type open (#7844), and each
  /// operand of `?` built at an instantiation its context would otherwise
  /// give it (#8181), keyed by `recordCopySiteKey` of the operand's span (see
  /// `Lyric.Parser.HoistOperandTypeSite`, #7823).
  hoistOperandTypeSites: Map[String, HoistOperandTypeSite]
  /// Each `?` operand that fixes no success type (`Err(error = x)?`,
  /// `None?`) and has none expected yet, keyed like `hoistOperandTypeSites`:
  /// what consumes the value gives it one (#8181).
  openPropagateOperands: Map[String, OpenPropagateOperand]
  /// The never-taken instantiation each operand left in
  /// `openPropagateOperands` takes on a native build, keyed like
  /// `hoistOperandTypeSites` (see `collectPropagateFallbacks`, #8181).
  propagateFallbackSites: Map[String, HoistOperandTypeSite]
  /// Each `?` whose operand's error type widens to the enclosing function's
  /// (`Int` into a `Result[_, Long]`), keyed by `recordCopySiteKey` of the
  /// `?` expression's span: the conversion method (`toLong`) the lowering
  /// applies to the re-wrapped error (#8181).
  propagateErrWidenings: Map[String, PropagateErrWidening]
  /// Each call whose arguments must be evaluated into temporaries to run in
  /// source order (D171), keyed by `recordCopySiteKey` of the call's span
  /// (see `Lyric.Parser.ArgOrderSite`).
  argOrderSites: Map[String, ArgOrderSite]
  /// The type expected of a method call's result, keyed by
  /// `recordCopySiteKey` of the call's span, while the call is checked
  /// against it: the hoisted receiver's type can come from it (#7844).
  methodCallResultExpected: Map[String, Type]
  /// One frame per lambda being checked with no expected return type: the
  /// types of the values its `return` statements produce.  A lambda body that
  /// ends in `return` has the type `Never`; its function type's result is the
  /// type of the returned values (`inferLambda`).
  lambdaReturnFrames: List[List[Type]]
  /// The type arguments of each call to a generic function whose type
  /// arguments are all closed, keyed by `recordCopySiteKey` of the callee's span
  /// (see `Lyric.Parser.GenericCallTypeArgsSite`, #7865).
  genericCallTypeArgSites: Map[String, GenericCallTypeArgsSite]
  /// Each call to a generic dot-named function (`func Box.get[T](self: in
  /// Box[T])`), written as a method call (`b.get()`) or through its type
  /// (`Box.get(b)`), keyed by `recordCopySiteKey` of the callee's span.
  /// `Lyric.Pipeline` rewrites such a call into a plain call of the
  /// function, which `Lyric.Mono` specialises (#8173).
  dottedGenericCallSites: Map[String, DottedGenericCall]
  /// Each call of a dot-named function with an `out`/`inout` parameter
  /// (#8179), and each method call of one on a primitive receiver (#8217),
  /// keyed by `recordCopySiteKey` of the callee's span: `Lyric.Pipeline`
  /// rewrites it into a plain call of the function.
  byRefDotCallSites: Map[String, ByRefDotCall]
  /// Each dot-named function declared through a type alias (`func Num.neg`
  /// for `alias Num = Int`), keyed `<package>|<declared name>`, to the name
  /// it is registered and compiled under, the aliased type's (`Int.neg`,
  /// #8217): `Lyric.Pipeline` renames the declaration.
  dotNameRenames: Map[String, String]
  /// Each bare identifier pattern in a `match` arm that names a union or
  /// enum case rather than binding a name, keyed by `recordCopySiteKey` of
  /// the pattern's span.  `Lyric.SelfFields` reads it: such a pattern hides
  /// no field of a member's type (#8264).
  casePatternSites: Map[String, Bool]
  /// The enum a bare case-name pattern matches (`case Select ->` against a
  /// `WidgetKind`), keyed by `recordCopySiteKey` of the pattern's span, as
  /// `<originPackage>.<EnumName>`.  A backend that erases an enum to its
  /// ordinal resolves a bare case name bundle-wide, first enum wins; the
  /// pipeline qualifies the pattern from this table instead (#8421).
  enumCasePatternSites: Map[String, String]
  /// The types each lambda's unannotated parameters took from the function
  /// type it was checked against, keyed by `recordCopySiteKey` of the lambda's
  /// span (see `Lyric.Parser.LambdaParamTypesSite`, #7865).
  lambdaParamTypeSites: Map[String, LambdaParamTypesSite]
  /// Whether each lambda's checked type returns `Unit`, keyed by
  /// `recordCopySiteKey` of the lambda's span: `true` when every check of the
  /// lambda gave it a `Unit` result, `false` when one did not.  `Lyric.Mono`
  /// ends the body of each `true` lambda in `()`, so every backend builds it as
  /// the `Unit`-returning function its type is, wherever it is copied
  /// (#8299).
  lambdaUnitSites: Map[String, Bool]
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
  /// How each extern type's host type iterates, keyed by the `clrName` its
  /// `extern type` spells (D302).  Filled by the backend bridge before the
  /// check from host metadata; a `for` over an extern type of no type
  /// parameters or of two or more consults it.  An absent key means the
  /// bridge could not say (a check with no references): the loop variable is
  /// then left unchecked rather than guessed.
  externIterElems: Map[String, ExternIterInfo]
  /// The bridge's lazy answer for an extern type `externIterElems` lacks: a
  /// 0/1-element list holding the resolver (the `scopePkg` idiom).
  externIterResolver: List[ExternIterResolver]
  /// Span keys (`recordCopySiteKey`) of the `for` iterables whose extern type
  /// the checker typed from `externIterElems`, each with the iterable's start
  /// offset: `Lyric.Mono` marks the loop for the backends and binds its loop
  /// variable through a local annotated with the element type (D302).
  externHostLoopSites: Map[String, Int]
  /// One entry per enclosing lenient first pass of a deferred call argument
  /// (the scratch-diagnostics pass of `ECall`, A2 / #7865).  A call checked
  /// inside one skips its own lambda-argument second pass: the enclosing
  /// argument is re-checked against its expectation anyway, which re-runs this
  /// call with both passes, so repeating the second pass here made nested
  /// lambda arguments cost 2^depth checks (#7879).
  lenientArgDepth: List[Int]
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
  /// The calls whose resolved callee is an `@io` function or a protected
  /// type's `entry`, keyed like `asyncCallSites` and written by the same
  /// arm (D149).  `Lyric.Pipeline` reports them in a package that may not
  /// do I/O (Y0003, Y0008).
  effectCallSites: Map[String, EffectCallSite]
  /// Module-level values that are shared mutable state (D149): a collection
  /// or other extern host object, or a protected-type instance.
  /// `Lyric.Pipeline` reports them in a package that may not do I/O (Y0007).
  mutableModuleVals: List[MutableModuleVal]
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
  /// The callee each method call resolved to, keyed by `methodCallSiteKey`
  /// of its callee (`Lyric.Parser.methodCallTargetCode`: its parameter count
  /// with the receiver not counted, negated for a dot-named function), for
  /// every call that leaves out a defaulted argument or resolves to a
  /// dot-named function.  A backend looks the callee up by this entry, not
  /// by the number of arguments written, so the call binds to the overload
  /// the checker chose (#7828), and to a dot-named function even when the
  /// type has a same-named method (#8098).
  methodCallArities: Map[String, Int]
  /// The first symbol declaring each type id, keyed by the id, filled lazily
  /// by `symTableTypeSymbolOf` as symbols are appended.
  typeSymbolsById: Map[String, Symbol]
  /// One entry per symbol already folded into `typeSymbolsById` (its count is
  /// the index cursor).
  typeSymbolsIndexed: List[Int]
  /// The `SymbolId` of each type `Std.CollectionsHost` declares (`List`, `Map`,
  /// `MapKeyCollection`, `MapValueCollection`, ...), keyed by name, filled
  /// lazily by `symTableStdCollectionsHostTypeId` as symbols are appended
  /// (#7765).
  stdCollectionsHostTypeIds: Map[String, SymbolId]
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
  /// Derived component-wise arithmetic on a homogeneous numeric record
  /// (`a + b` on a `Vec3` that derives `Add`, D155), keyed by the binop's
  /// span, or by the statement's span for `a += b`.  Lowered by
  /// `Lyric.ContractElaborator.lowerRecordArith`.
  recordArithSites: Map[String, RecordArithSite]
  recordEqSites: Map[String, RecordEqSite]
  /// `==` / `!=` on two `array[N, T]` operands (D167), keyed by the binop's
  /// span.
  arrayEqSites: Map[String, ArrayEqSite]
  wrapEqSites: Map[String, WrapEqSite]
  /// One entry per `buildEqShape` call in progress: the nesting across the
  /// record and array sites it builds, which restart their own depth.
  eqShapeNesting: List[Int]
  /// One entry per value-generic function body being checked (D167 item 6):
  /// an array whose length is a value generic parameter has no length there,
  /// and each specialisation is checked again with the length bound.
  valueGenericBodies: List[Int]
  /// The value generic parameters a call binds from its array arguments'
  /// lengths, keyed by the callee's span, for `Lyric.Mono`.
  valueGenericCallSites: Map[String, Map[String, Int]]
  /// Values flowing into an inline range type at a position nothing else
  /// checks, keyed by the value's span (`RangeCheckSite`, #8031).
  rangeCheckSites: Map[String, RangeCheckSite]
  /// Compound assignments (`r.f += 1`) whose target is a range-refined
  /// field or element, keyed by the assignment's span (#8031).
  rangeCompoundSites: Map[String, RangeCheckSite]
  /// Every `a[i]` on an `array[N, T]` (D167), keyed by the index
  /// expression's span.
  arrayIndexSites: Map[String, ArrayIndexSite]
  /// `a.length` on an `array[N, T]`, keyed by the member expression's span,
  /// mapped to `N`.
  arrayLenSites: Map[String, Int]
  /// `a.toSlice()`, keyed by the span of the `a.toSlice` member expression.
  arraySliceSites: Map[String, ArraySite]
  /// The iterable of a `for x in a` over an array, keyed by its span.
  arrayForSites: Map[String, ArraySite]
  /// A place read (`a`, `r.f`, `xs[i]`) of array type, keyed by its span:
  /// storing it anywhere copies it (D167).  A read whose consumer only
  /// inspects the array (an index receiver, `.length`, an `==` operand, an
  /// assignment target) is removed again.
  arrayCopySites: Map[String, ArraySite]
  /// The place reads (by span) no consumer ever stores, so none is copied;
  /// kept apart from `arrayCopySites` because an expression the checker
  /// infers again (a scratch inference of a receiver) is recorded again.
  arrayCopyExempt: Map[String, Bool]
  /// The resolved length of each `array[N, T]` type expression of the file
  /// whose `N` is a constant or an expression rather than a literal, keyed by
  /// `recordCopySiteKey` of the type expression; the pipeline rewrites each to
  /// its literal before a backend runs.  `arrayLenPkg` names the file's own
  /// package: a type expression resolved in another package's scope (an
  /// imported record's field) has a span of another file and is not recorded.
  arrayTypeLens: Map[String, Int]
  arrayLenPkg: List[String]
  /// The zero value of an initializer-less array-typed local (keyed by the
  /// statement's span) or of an array-typed field with no default (keyed by
  /// the field declaration's span).
  arrayZeroSites: Map[String, Expr]
  /// The zero-valued named arguments a record construction leaves out,
  /// keyed by the construction's span (D167, #8042).
  arrayCtorZeroArgs: Map[String, List[CallArg]]
  /// The `array[N, T]` each bracket literal typed as an array builds, keyed
  /// by the literal's span: a backend with typed primitive arrays builds it
  /// through `arrayOfIntrinsic` (#8041).
  arrayLiteralSites: Map[String, TypeExpr]
  /// The result type of each `b.withPointer(f)` / `b.withMutPointer(f)` call, by
  /// the call's span, for `lowerArrays` to bind the closure to an annotated
  /// `val` (D187): the backends need a closure literal's function type.
  bufferPointerSites: Map[String, TypeExpr]
  /// Each construction of a value-generic record (D169), keyed by the call's
  /// span: the value arguments of the instance it builds, in parameter order,
  /// as a literal length or the name of an enclosing value generic
  /// parameter.  The middle end spells them on the call before
  /// monomorphisation, so a specialised body's constructions are concrete.
  valueRecordCtorSites: Map[String, List[TypeArg]]
  /// Each construction of a case of a union with value generic parameters,
  /// keyed by the construction's span, at the instance it is typed as
  /// (#8149).  Native specialises such a union per length, so the middle end
  /// names the specialisation on each construction.
  valueUnionCtorSites: Map[String, ValueUnionCtorSite]
  /// A value-generic record's length argument written as a constant
  /// (`Grid[Width, 2]`), keyed by the argument's span: its value.
  valueTypeArgSites: Map[String, Int]
  /// Integer arithmetic that can overflow (D163), keyed by span:
  /// `add:<T>` / `sub:<T>` / `mul:<T>` for a binop, `neg:<T>` for unary
  /// minus, `compound:<T>` for `x += y` / `-=` / `*=` (keyed by the
  /// statement), and `wrap:<T>` for a `.wrappingAdd(...)`-style call.  `<T>` is
  /// `Int`, `Long`, `UInt`, `ULong` or `Byte`.  Lowered by
  /// `Lyric.ContractElaborator.lowerOverflowChecks`.
  overflowSites: Map[String, String]
  /// For a `compound:<T>` site whose target is not a side-effect-free path,
  /// the types of its receiver and index temporaries (D163).
  overflowCompoundTemps: Map[String, CompoundTemps]
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
  /// Each file's own import rule (docs/70 §4.1), indexed by
  /// `Position.fileId`; empty for a package of fewer than two files.
  fileRules: List[FileImportRule]
  /// The file whose scope is entered, boxed as a 0/1-element list; empty =
  /// the package union (`symTableEnterFile`).
  curFile: List[Int]
  /// T0219: names a file uses that only a sibling file's import makes
  /// visible, keyed `<fileId>|<name>` so each is reported once per file.
  siblingImportKeys: Map[String, Bool]
  siblingImportErrors: List[Diagnostic]
  /// Non-empty when the checked file is `@contract_source`: a restored
  /// dependency's metadata synthesised back into source, whose preamble copies
  /// sibling packages' types into the file's own package, so a qualified type
  /// there may resolve to the copy (docs/70 phase 5 removes the synthesis).
  contractSourceFile: List[Bool]
  /// The `String` method surface of the target being checked for (one slot,
  /// empty while unset, which is `SMSUnchecked`).
  stringSurface: List[StringMethodSurface]
  /// The native target's FFI intrinsic types (`NativePtr`, `NativeWeak`,
  /// docs/01 §11.6), by name, when the file is checked for `--target
  /// native`; empty for every other target, which has no representation for
  /// them.
  nativeIntrinsicTypes: Map[String, SymbolId]
  /// SymbolId interning (docs/70 §4.2): DefPath key -> id, and by id - 1
  /// the key of each id ("" for one no DefPath names).
  /// The DefPath interner, shared with the resolver (docs/70 §4.2).
  interner: DefPathInterner
  /// The resolver's context while `LYRIC_RESOLVE_DIFF` is set (docs/70 phase 2c,
  /// D313): every bare lookup is also put to `Lyric.Resolve`, and a
  /// disagreement is an `R0001` warning in `diffLog`.
  resolveCtx: List[ResolverContext]
  diffSeen: Map[String, Bool]
  diffLog: List[Diagnostic]
  /// Non-empty while `LYRIC_RESOLVE_DIFF` is set: every bare lookup is also
  /// answered by the checker's own scan and a difference is an `R0001`.
  diffOn: List[Bool]
  /// The span of the item being checked, for a diagnostic with no node of its own.
  curItemSpan: List[Span]
  /// Symbols indexed by the DefPath id the resolver gives their declaration
  /// (`toString(SymbolId.id)`), newest registration winning; `defIdIndexed`
  /// counts the symbols already indexed.
  symByDefId: Map[String, Symbol]
  defIdIndexed: List[Int]
  /// Resolutions of a bare name per file (`<file>|<name>`): an index into
  /// `resolutionList`.
  resolutionIndex: Map[String, Int]
  resolutionList: List[Resolution]
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
  /// A tuple literal's site (#7855): `(None, 5)`, `(newList(), (None, 1))`.
  /// Each element whose type is open is itself an open site: an element
  /// the site owns (an evidence-free construction), or an open local the
  /// literal holds.  `childKeys[i]` is that site's key and `childPaths[i]`
  /// its position, the element index at each nesting level (`[1, 0]`).  A type recorded
  /// for the tuple is recorded for each child at its position, a name a
  /// tuple pattern binds to a child's position is bound open to the child,
  /// and the tuple's annotation is its own type with each child's resolved
  /// type in place.  Empty for any other site.
  childKeys: List[String]
  childPaths: List[List[Int]]
  /// The tuple site owning this element's site, or "".  Only the tuple's
  /// annotation is written; an element has no binding of its own.  A site
  /// for a name bound to a sub-tuple (`inner` in `val (inner, n) = t`) is
  /// owned by the site it was bound from, and its children are that site's
  /// children under the name's position (#7863).
  parentKey: String
  /// The elements of the tuple the await / `?` hoist binds one by one, with
  /// their positions, and the enclosing function's type parameters: the
  /// resolved annotation records each one's type at its position in
  /// `SymbolTable.hoistOperandTypeSites`, which the checker could not do
  /// while nothing fixed it (#7823).
  hoistExprs: List[Expr]
  hoistPaths: List[List[Int]]
  typeParams: List[String]
  /// Each name a tuple pattern binds at a child's position (its pattern's
  /// span, and the position): once the tuple is typed, the name is recorded
  /// in `SymbolTable.tuplePatternBindingSites` at its element's type (#7728),
  /// so a backend that erases the element (the JVM) reads it at that type.
  patSpans: List[Span]
  patPaths: List[List[Int]]
  /// A name a `match` arm's constructor pattern binds to a payload typed by a
  /// type parameter of an open union value (`case Err(e)` on `val r = Ok(value = true)`)
  /// is open to that type argument (#8250).  `argKeys[i]` is the site of the
  /// name bound to type argument `argIdx[i]` of this site's type; its sink or
  /// store type fixes that argument, and `resolveOpenBindingSites` folds the
  /// fixed arguments into this site's own type.  Empty for any other site.
  argKeys: List[String]
  argIdx: List[Int]
}

pub record ImplPair {
  target: SymbolId
  iface: SymbolId
}

/// One method signature attached to a nominal type — a record-body method
/// (`RMFunc`, leading `self` dropped), an `impl` block method (`IMplFunc`,
/// receiver implicit), or an interface member (`IMSig`/`IMFunc`).  The stored
/// `sig` is the *call-facing* signature: its params never include the
/// receiver, so a call site validates `x.m(a, b)`'s two arguments directly
/// against `sig.params` (docs/59 A4).
pub record MethodEntry {
  owner: SymbolId
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
    contractSourceFile = newList(),
    stringSurface = newList(),
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
    externPathPackages = newMap(),
    symbolPackages = newMap(),
    symbolPackageMembers = newMap(),
    packageImports = newMap(),
    packageReexports = newMap(),
    funcExportCache = newMap(),
    recordCopySites = newMap(),
    invariantCtorSites = newMap(),
    funcRefSites = newMap(),
    funcRefCallees = newMap(),
    ownFuncValueSites = newMap(),
    typeArgCalleeSites = newMap(),
    argConversionSites = newMap(),
    covariantSites = newMap(),
    covariantHelpers = newList(),
    covariantHelperNames = newMap(),
    showSites = newMap(),
    showHelpers = newList(),
    showHelperNames = newMap(),
    callResultTypes = newMap(),
    localBindingTypeSites = newMap(),
    openBindingSites = newMap(),
    funcValueCallSites = newMap(),
    tuplePatternBindingSites = newMap(),
    listLiteralTypeSites = newMap(),
    hoistOperandTypeSites = newMap(),
    openPropagateOperands = newMap(),
    propagateFallbackSites = newMap(),
    propagateErrWidenings = newMap(),
    argOrderSites = newMap(),
    methodCallResultExpected = newMap(),
    lambdaReturnFrames = newList(),
    genericCallTypeArgSites = newMap(),
    dottedGenericCallSites = newMap(),
    byRefDotCallSites = newMap(),
    dotNameRenames = newMap(),
    casePatternSites = newMap(),
    enumCasePatternSites = newMap(),
    lambdaParamTypeSites = newMap(),
    lambdaUnitSites = newMap(),
    moduleValTypes = newMap(),
    generatorCallSites = newMap(),
    externIterElems = newMap(),
    externIterResolver = newList(),
    externHostLoopSites = newMap(),
    lenientArgDepth = newList(),
    emptyCollectionCtorSites = newMap(),
    asyncCallSites = newMap(),
    effectCallSites = newMap(),
    mutableModuleVals = newList(),
    memberRecvClasses = newMap(),
    methodCallArities = newMap(),
    typeSymbolsById = newMap(),
    typeSymbolsIndexed = newList(),
    stdCollectionsHostTypeIds = newMap(),
    stdCollectionsHostIndexed = stdCollectionsHostIndexed,
    distinctOpSites = newMap(),
    distinctCompoundSites = newMap(),
    recordArithSites = newMap(),
    recordEqSites = newMap(),
    arrayEqSites = newMap(),
    wrapEqSites = newMap(),
    eqShapeNesting = newList(),
    valueGenericBodies = newList(),
    valueGenericCallSites = newMap(),
    rangeCheckSites = newMap(),
    rangeCompoundSites = newMap(),
    arrayIndexSites = newMap(),
    arrayLenSites = newMap(),
    arraySliceSites = newMap(),
    arrayForSites = newMap(),
    arrayCopySites = newMap(),
    arrayCopyExempt = newMap(),
    arrayTypeLens = newMap(),
    arrayLenPkg = newList(),
    arrayZeroSites = newMap(),
    arrayCtorZeroArgs = newMap(),
    arrayLiteralSites = newMap(),
    bufferPointerSites = newMap(),
    valueRecordCtorSites = newMap(),
    valueUnionCtorSites = newMap(),
    valueTypeArgSites = newMap(),
    overflowSites = newMap(),
    overflowCompoundTemps = newMap(),
    importRulePkg = newList(),
    importVisiblePkgs = newMap(),
    importVisibleNames = newMap(),
    importAliases = newMap(),
    fileRules = newList(),
    curFile = newList(),
    siblingImportKeys = newMap(),
    siblingImportErrors = newList(),
    nativeIntrinsicTypes = newMap(),
    interner = newDefPathInterner(),
    resolveCtx = newList(),
    diffSeen = newMap(),
    diffLog = newList(),
    diffOn = newList(),
    curItemSpan = newList(),
    symByDefId = newMap(),
    defIdIndexed = newList(),
    resolutionIndex = newMap(),
    resolutionList = newList()
  )
}

/// The `SymbolId` of the declaration at `path`: the same id for every
/// registration of it in this compilation (docs/70 §4.2).
pub func symTableInternDefPath(tbl: in SymbolTable, path: in DefPath): SymbolId {
  internDefPath(tbl.interner, path)
}

/// A fresh `SymbolId` for a declaration with no DefPath: one registered with
/// no package (the checker's flat `checkWithImports` form), whose identity is
/// its registration.
pub func symTableFreshSymbolId(tbl: in SymbolTable): SymbolId {
  freshSymbolId(tbl.interner)
}

/// The DefPath key `id` was interned from, or `None` for an id no DefPath
/// names (a fresh id, or a built-in type's).
pub func symTableDefPathKeyOf(tbl: in SymbolTable, id: in SymbolId): Option[String] {
  defPathKeyOf(tbl.interner, id)
}

/// The `SymbolId` of the type `name` that package `pkg` declares: interned
/// from its DefPath, or fresh when `pkg` is "" (no package context).
pub func symTableTypeSymbolId(tbl: in SymbolTable, pkg: in String, name: in String): SymbolId {
  if pkg.length == 0 {
    symTableFreshSymbolId(tbl)
  } else {
    symTableInternDefPath(tbl, typeDefPath(pkg, name))
  }
}

/// The newest symbol that declares the type with id `tid`: when a type is
/// registered more than once (one DefPath, docs/70 §4.2), the registration
/// every name lookup picks (`symTableTryFindOne`, `symTableTryFindInPackage`
/// scan newest-first).  Symbols appended since the last lookup are indexed
/// first, so a lookup costs amortised constant time rather than a scan of
/// the whole table.
pub func symTableTypeSymbolOf(tbl: in SymbolTable, tid: in SymbolId): Option[Symbol] {
  while tbl.typeSymbolsIndexed.count < tbl.symbols.count {
    val sym = tbl.symbols[tbl.typeSymbolsIndexed.count]
    match symbolTypeIdOpt(sym) {
      case Some(sid) -> {
        val key = toString(sid.id)
        if tbl.typeSymbolsById.containsKey(key) {
          tbl.typeSymbolsById.remove(key)
        }
        tbl.typeSymbolsById.add(key, sym)
      }
      case None -> ()
    }
    tbl.typeSymbolsIndexed.add(0)
  }
  mapGet(tbl.typeSymbolsById, toString(tid.id))
}

/// The `SymbolId` of the type named `name` that the stdlib's
/// `Std.CollectionsHost` package declares, or `None` when no such type is
/// registered.  Equivalent to `symTableTryFindInPackage(tbl,
/// "Std.CollectionsHost", name)` followed by `symbolTypeIdOpt` -- the most
/// recently registered symbol wins -- but each symbol is examined once per
/// table instead of once per query: the stdlib-collection checks
/// (`isStdCollectionsHostType`) run on every iterated, indexed or
/// bracket-literal-typed collection, and a linear scan of the whole table at
/// each of them dominated large files (#7765).
pub func symTableStdCollectionsHostTypeId(tbl: in SymbolTable, name: in String): Option[SymbolId] {
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

/// Record the packages `pkg` re-exports whole (`pub use P`).  The first
/// registration for a package wins, as for its imports.
pub func symTableRegisterPackageReexports(tbl: in SymbolTable, pkg: in String, reexports: in List[String]): Unit {
  if not tbl.packageReexports.containsKey(pkg) {
    tbl.packageReexports.add(pkg, reexports)
  }
}

/// The packages `pkg` re-exports, directly or through their own re-exports
/// (`pub use`).
pub func symTableReexportClosure(tbl: in SymbolTable, pkg: in String): List[String] {
  val acc: List[String] = newList()
  val queue: List[String] = newList()
  queue.add(pkg)
  var qi = 0
  while qi < queue.count {
    match mapGet(tbl.packageReexports, queue[qi]) {
      case Some(rs) -> {
        for r in rs {
          if r != pkg and not acc.contains(r) {
            acc.add(r)
            queue.add(r)
          }
        }
      }
      case None -> ()
    }
    qi = qi + 1
  }
  acc
}

/// Whether package `pkg` re-exports package `dep` whole.
pub func symTablePackageReexports(tbl: in SymbolTable, pkg: in String, dep: in String): Bool {
  match mapGet(tbl.packageReexports, pkg) {
    case Some(rs) -> rs.contains(dep)
    case None -> false
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

// Record `path` as the declared path of an `extern package` block (#7934).
pub func symTableAddExternPathPackage(tbl: in SymbolTable, path: in String): Unit {
  if not tbl.externPathPackages.containsKey(path) {
    tbl.externPathPackages.add(path, true)
  }
}

// True when `pkg` is the declared path of an `extern package` block.
pub func symTableIsExternPathPackage(tbl: in SymbolTable, pkg: in String): Bool {
  tbl.externPathPackages.containsKey(pkg)
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
pub func symTableMethodSigs(tbl: in SymbolTable, owner: in SymbolId, name: in String): List[MethodEntry] {
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
pub func symTableIsMemberComplete(tbl: in SymbolTable, tid: in SymbolId): Bool {
  tbl.memberCompleteTypes.containsKey(toString(tid.id))
}

// Record that the type with id `target` implements the interface with id
// `iface` (idempotent).
pub func symTableAddImpl(tbl: in SymbolTable, target: in SymbolId, iface: in SymbolId): Unit {
  var i = 0
  while i < tbl.impls.count {
    if symbolIdEq(tbl.impls[i].target, target) and symbolIdEq(tbl.impls[i].iface, iface) {
      return
    }
    i = i + 1
  }
  tbl.impls.add(ImplPair(target = target, iface = iface))
}

// True when some `impl iface for target` was registered.
pub func symTableTypeImplements(tbl: in SymbolTable, target: in SymbolId, iface: in SymbolId): Bool {
  var i = 0
  while i < tbl.impls.count {
    if symbolIdEq(tbl.impls[i].target, target) and symbolIdEq(tbl.impls[i].iface, iface) {
      return true
    }
    i = i + 1
  }
  false
}

pub func symTableAdd(tbl: in SymbolTable, sym: in Symbol): Unit {
  // Maintain the SymbolId-keyed side indexes (#2027, #2178, #3903).  Each
  // registration gets a fresh SymbolId, so first-in-wins guards only against
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

pub func symTableScopePkg(tbl: in SymbolTable): String {
  if tbl.scopePkg.count > 0 {
    tbl.scopePkg[0]
  } else {
    ""
  }
}

pub func symTableScopeAllows(tbl: in SymbolTable, pkg: in String): Bool {
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
  val resolved = resolverPick(tbl, name)
  if tbl.diffOn.count > 0 {
    diffCompareBare(tbl, name, tryFindOneCore(tbl, name))
  }
  match resolved {
    case Some(_) -> resolved
    case None -> tryFindOneCore(tbl, name)
  }
}

// The resolver's context when a bare name written in the file being checked is
// answered by it (docs/70 §4.4, D314): the checked package's own scope under
// its import rule.  `None` for a dependency's signature scope, a synthesised
// item of a package of several files (judged by the union of the files'
// imports), or when no context was built.
func resolverFileFor(tbl: in SymbolTable): Option[Int] {
  if tbl.resolveCtx.count == 0 {
    return None
  }
  val curPkg = symTableScopePkg(tbl)
  if curPkg.length == 0 or not symTableImportRuleApplies(tbl, curPkg) {
    return None
  }
  val cur = symTableCurrentFile(tbl)
  if cur == -2 {
    return None
  }
  if cur >= 0 {
    Some(value = cur)
  } else if tbl.fileRules.count < 2 {
    Some(value = 0)
  } else {
    None
  }
}

// What the resolver says `name` means in file `fid`, cached per file and name.
func resolutionOf(tbl: in SymbolTable, fid: in Int, name: in String): Resolution {
  val key = toString(fid) + "|" + name
  match mapGet(tbl.resolutionIndex, key) {
    case Some(ix) -> return tbl.resolutionList[ix]
    case None -> ()
  }
  val ctx = tbl.resolveCtx[0]
  val res = resolveBare(ctx.tbl, scopeOfFile(ctx, fid), name, UseValue)
  tbl.resolutionIndex.add(key, tbl.resolutionList.count)
  tbl.resolutionList.add(res)
  res
}

// The `SymbolId` the resolver gives the declaration `sym` registers, when it
// has one (docs/70 §4.2).
func symbolDefId(tbl: in SymbolTable, sym: in Symbol): Option[SymbolId] {
  match sym.kind {
    case DKRecord(id, _) -> return Some(value = id)
    case DKExposedRec(id, _) -> return Some(value = id)
    case DKUnion(id, _) -> return Some(value = id)
    case DKEnum(id, _) -> return Some(value = id)
    case DKOpaque(id, _) -> return Some(value = id)
    case DKProtected(id, _) -> return Some(value = id)
    case DKDistinctType(id, _) -> return Some(value = id)
    case DKInterface(id, _) -> return Some(value = id)
    case DKExternType(id, _) -> return Some(value = id)
    case DKUnionCase(pid, uc) -> return caseDefId(tbl, pid, uc.name)
    case DKEnumCase(pid, ec) -> return caseDefId(tbl, pid, ec.name)
    case DKFunc(decl) -> {
      return symbolIdOfKey(tbl.interner, defPathKey(funcDefPath(sym.originPackage, sym.name, decl.params)))
    }
    case _ -> ()
  }
  if sym.originPackage.length == 0 {
    return None
  }
  symbolIdOfKey(tbl.interner, defPathKey(topDefPath(sym.originPackage, sym.name)))
}

func caseDefId(tbl: in SymbolTable, parent: in SymbolId, caseName: in String): Option[SymbolId] {
  match defPathKeyOf(tbl.interner, parent) {
    case Some(pk) -> symbolIdOfKey(tbl.interner, pk + "::" + caseName)
    case None -> None
  }
}

// The newest symbol that registers the declaration with resolver id `id`.
// Symbols registered since the last call are indexed first.
func symbolOfDefId(tbl: in SymbolTable, id: in SymbolId): Option[Symbol] {
  while tbl.defIdIndexed.count < tbl.symbols.count {
    val sym = tbl.symbols[tbl.defIdIndexed.count]
    match symbolDefId(tbl, sym) {
      case Some(did) -> {
        val key = toString(did.id)
        if tbl.symByDefId.containsKey(key) {
          tbl.symByDefId.remove(key)
        }
        tbl.symByDefId.add(key, sym)
      }
      case None -> ()
    }
    tbl.defIdIndexed.add(0)
  }
  mapGet(tbl.symByDefId, toString(id.id))
}

// The symbol the resolver binds a bare `name` to in the file being checked, or
// `None` when it does not answer: no context, an unresolved name (a built-in,
// a name only a sibling file imports, a diagnostic the caller reports), or a
// declaration with no symbol.  An overload set answers with its newest
// function; the overload pick is the caller's.
func resolverPick(tbl: in SymbolTable, name: in String): Option[Symbol] {
  match resolverFileFor(tbl) {
    case None -> None
    case Some(fid) -> match resolutionOf(tbl, fid, name) {
      case RSymbol(id) -> symbolOfDefId(tbl, id)
      case ROverloads(ids) -> {
        var i = ids.count - 1
        while i >= 0 {
          match symbolOfDefId(tbl, ids[i]) {
            case Some(s) -> return Some(value = s)
            case None -> ()
          }
          i = i - 1
        }
        None
      }
      case _ -> None
    }
  }
}

// The packages declaring what the resolver binds `name` to in the file being
// checked; `None` when it does not answer.
func resolverPackagesFor(tbl: in SymbolTable, name: in String): Option[List[String]] {
  match resolverFileFor(tbl) {
    case None -> None
    case Some(fid) -> {
      val ctx = tbl.resolveCtx[0]
      val pkgs: List[String] = newList()
      match resolutionOf(tbl, fid, name) {
        case RSymbol(id) -> {
          pkgs.add(declPkgOf(ctx, id))
        }
        case ROverloads(ids) -> {
          for id in ids {
            val p = declPkgOf(ctx, id)
            if not pkgs.contains(p) {
              pkgs.add(p)
            }
          }
        }
        case _ -> return None
      }
      Some(value = pkgs)
    }
  }
}

// Put a bare lookup the checker's own scan answered to the resolver and note a
// disagreement.  Only lookups under the checked package's own import rule are
// comparable: an imported package's signatures resolve in that package's scope.
func diffCompareBare(tbl: in SymbolTable, name: in String, found: in Option[Symbol]): Unit {
  val fid = match resolverFileFor(tbl) { case Some(f) -> f; case None -> return }
  // A symbol with no package is a built-in or an `import extern` binding, which
  // the resolver reaches through its own scope entries.
  match found {
    case Some(s) -> {
      if s.originPackage.length == 0 {
        return
      }
    }
    case None -> ()
  }
  val ctx = tbl.resolveCtx[0]
  val res = resolutionOf(tbl, fid, name)
  val theirs = match found { case Some(s) -> s.originPackage; case None -> "no declaration" }
  val ours = match res {
    case RSymbol(id) -> declPkgOf(ctx, id)
    case ROverloads(ids) -> declPkgOf(ctx, ids[0])
    case RUnresolved(code, _) -> code
    case RPackage(p) -> "package " + p
    case RDeferred -> "a member"
  }
  var agree = theirs == ours
  match res {
    case RUnresolved(code, _) -> {
      if code == "T0123" and symTableAmbiguousImportPackages(tbl, name).count >= 2 {
        agree = true
      }
      if theirs == "no declaration" and (code == "T0020" or code == "T0010") {
        agree = true
      }
    }
    case _ -> ()
  }
  if agree {
    return
  }
  val key = toString(fid) + "|" + name + "|" + theirs + "|" + ours
  if tbl.diffSeen.containsKey(key) {
    return
  }
  tbl.diffSeen.add(key, true)
  val at = if tbl.curItemSpan.count > 0 { tbl.curItemSpan[0] } else { makeSpan(initialPosition(), initialPosition()) }
  tbl.diffLog.add(
    warningDiagnostic(
      "R0001",
      "resolver disagrees on '" + name + "' (file " + toString(fid) + "): checker " + theirs + ", resolver " + ours,
      at
    )
  )
}

func declPkgOf(ctx: in ResolverContext, id: in SymbolId): String {
  match declOfId(ctx.tbl, id) {
    case Some(d) -> d.pkg
    case None -> "unknown declaration"
  }
}

func tryFindOneCore(tbl: in SymbolTable, name: in String): Option[Symbol] {
  val curPkg = symTableScopePkg(tbl)
  val hasScope = curPkg.length > 0
  val hasImports = tbl.scopeImports.count > 0
  val ruled = hasScope and symTableImportRuleApplies(tbl, curPkg)
  var best2: Option[Symbol] = None
  var best2b: Option[Symbol] = None
  var has2b = false
  val reach: Map[String, Bool] = newMap()
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
      // An imported package's signature scope also sees what the packages
      // it imports declare (the kernel re-export idiom: `Std.Uuid` imports
      // the `Uuid` type from its host package), ahead of an unrelated
      // same-named declaration of whichever package is being checked
      // (#7372).  The user package's own bare lookups are bound by the
      // import rule above instead.
      if hasImports and not ruled and hasScope and not has2b and reachableOnce(tbl, reach, s.originPackage) {
        best2b = Some(value = s)
        has2b = true
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
    case None -> match best2b { case Some(_) -> best2b; case None -> best3 }
  }
}

// True when `pkg` is imported, at any depth, by a package the current scope
// imports.  The registered import lists record only a package's own imports,
// so the walk follows them with a visited set.  `reach` holds the set once
// built, for one `symTableTryFindOne` call; it is empty until the first
// candidate needs it.
func reachableOnce(tbl: in SymbolTable, reach: in Map[String, Bool], pkg: in String): Bool {
  if pkg.length == 0 {
    return false
  }
  if reach.count == 0 {
    val pending: List[String] = newList()
    for imp in tbl.scopeImports {
      pending.add(imp)
    }
    while pending.count > 0 {
      val cur = pending[pending.count - 1]
      pending.removeAt(pending.count - 1)
      if not reach.containsKey(cur) {
        reach.add(cur, true)
        for dep in symTablePackageImportsOf(tbl, cur) {
          pending.add(dep)
        }
      }
    }
  }
  reach.containsKey(pkg)
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

func typeNameOfId(tbl: in SymbolTable, tid: in SymbolId): String {
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
  // The resolver's answer is the lowest tier that declares the name; a
  // function of any other package is shadowed or hidden (D314).
  match resolverPackagesFor(tbl, name) {
    case Some(pkgs) -> return if origin.length == 0 or pkgs.contains(origin) { 0 } else { -1 }
    case None -> ()
  }
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

// ─────────────────────────────────────────────────────────────────────────────
// §4c. Per-file import scopes (docs/70 §4.1, phase 2a).
// ─────────────────────────────────────────────────────────────────────────────
/// One file's own imports, as the rule for the names that file may use
/// (docs/70 §4.1).  Each map pairs what an import makes visible with that
/// import as written (`import P`, `import P.{X}`), which T0219 tells a file
/// to add when it relies on a sibling's.
pub record FileImportRule {
  /// The file's path ("" when the caller has none).
  path: String
  /// Package -> the whole import that makes every name of it visible bare:
  /// `import P`, or a whole import whose own whole imports reach `P` (D141).
  wholeVia: Map[String, String]
  /// `<package>|<name>` -> the selective import that lists the name.
  namesVia: Map[String, String]
  /// Package -> the file's import of it, in any form: a qualified `P.x`
  /// needs one.
  directVia: Map[String, String]
  /// Package -> the import through whose own imports the file reaches it,
  /// for the qualified references that accept a package reached that way.
  reachVia: Map[String, String]
  /// The local name an `import extern` binds -> that import.
  externVia: Map[String, String]
}

/// Install one rule per file of the package being checked, indexed by
/// `Position.fileId`.  A package with fewer than two files needs none: its
/// one file's imports are the union.
pub func symTableSetFileRules(tbl: in SymbolTable, rules: in List[FileImportRule]): Unit {
  while tbl.fileRules.count > 0 {
    tbl.fileRules.removeAt(tbl.fileRules.count - 1)
  }
  for r in rules {
    tbl.fileRules.add(r)
  }
}

/// Enter the scope of file `fileId` of the package being checked: a name
/// written at no source position of its own (a synthesised node) is judged
/// by that file's imports.  -2 enters a synthesised item, whose every name
/// (whatever positions its nodes were copied from) is judged by the package
/// union; any other id with no rule (-1) leaves no file entered, so a name is
/// judged by the file its own position lies in.
pub func symTableEnterFile(tbl: in SymbolTable, fileId: in Int): Unit {
  while tbl.curFile.count > 0 {
    tbl.curFile.removeAt(tbl.curFile.count - 1)
  }
  if fileId == -2 or (fileId >= 0 and fileId < tbl.fileRules.count) {
    tbl.curFile.add(fileId)
  }
}

/// The file whose scope is entered, -2 for a synthesised item, or -1 for
/// none.
pub func symTableCurrentFile(tbl: in SymbolTable): Int {
  if tbl.curFile.count > 0 {
    tbl.curFile[0]
  } else {
    -1
  }
}

/// The file of the package being checked that `sp` lies in, or -1 when the
/// span has no source position (a synthesised item or node: an empty span,
/// or line 0) or the package has no file table.
pub func symTableFileOfSpan(tbl: in SymbolTable, sp: in Span): Int {
  if tbl.fileRules.count == 0 or sp.startPos.line == 0 or sp.startPos.offset == sp.endPos.offset {
    return -1
  }
  val f = sp.startPos.fileId
  if f >= 0 and f < tbl.fileRules.count {
    f
  } else {
    -1
  }
}

/// Enter the file `sp` lies in: the file an item is checked in.  A
/// synthesised item (no source position) enters the package union (-2).
pub func symTableEnterSpanFile(tbl: in SymbolTable, sp: in Span): Unit {
  while tbl.curItemSpan.count > 0 {
    tbl.curItemSpan.removeAt(tbl.curItemSpan.count - 1)
  }
  tbl.curItemSpan.add(sp)
  val f = symTableFileOfSpan(tbl, sp)
  if f < 0 and tbl.fileRules.count > 0 {
    symTableEnterFile(tbl, -2)
  } else {
    symTableEnterFile(tbl, f)
  }
}

// The file whose imports judge a name written at `sp`, when T0219 applies:
// the file the span lies in, else the entered file; -1 when no per-file rule
// applies (fewer than two files, a synthetic item, or a scope other than the
// checked package's own).
func useFileForSiblingCheck(tbl: in SymbolTable, sp: in Span): Int {
  if tbl.fileRules.count < 2 {
    return -1
  }
  val curPkg = symTableScopePkg(tbl)
  if curPkg.length == 0 or not symTableImportRuleApplies(tbl, curPkg) {
    return -1
  }
  val cur = symTableCurrentFile(tbl)
  if cur == -2 {
    return -1
  }
  val f = symTableFileOfSpan(tbl, sp)
  if f >= 0 {
    f
  } else {
    cur
  }
}

// Whether some file of the package binds `name` with an `import extern`.
func anyFileExternImports(tbl: in SymbolTable, name: in String): Bool {
  for r in tbl.fileRules {
    if r.externVia.containsKey(name) {
      return true
    }
  }
  false
}

// How `rule` makes `sym` nameable bare from package `curPkg`: `Some("")`
// when no import is needed (a declaration of the package, the prelude, a
// binding with no package), `Some(import)` through one of the file's
// imports, `None` when the file's imports hide it.  Mirrors
// `symTableImportVisible` for one file's imports.
func fileBareVia(tbl: in SymbolTable, rule: in FileImportRule, curPkg: in String, sym: in Symbol): Option[String] {
  val origin = sym.originPackage
  if origin.length == 0 {
    val isExtern = match sym.kind { case DKExternType(_, _) -> true; case _ -> false }
    if isExtern and anyFileExternImports(tbl, sym.name) {
      return mapGet(rule.externVia, sym.name)
    }
    return Some(value = "")
  }
  if origin == curPkg {
    return Some(value = "")
  }
  match mapGet(rule.wholeVia, origin) {
    case Some(via) -> return Some(value = via)
    case None -> ()
  }
  match mapGet(rule.namesVia, origin + "|" + sym.name) {
    case Some(via) -> return Some(value = via)
    case None -> ()
  }
  val parent = caseParentName(tbl, sym)
  if origin == "Std.Core" {
    val preludeName = if parent.length > 0 { parent } else { sym.name }
    if isPreludeName(preludeName) {
      return Some(value = "")
    }
  }
  if parent.length > 0 {
    return mapGet(rule.namesVia, origin + "|" + parent)
  }
  None
}

// `fileBareVia` for a function `name` declared in `origin` (the by-name form
// `symTableBareFuncVisible` takes).
func fileBareFuncVia(rule: in FileImportRule, curPkg: in String, origin: in String, name: in String): Option[String] {
  if origin.length == 0 or origin == curPkg {
    return Some(value = "")
  }
  match mapGet(rule.wholeVia, origin) {
    case Some(via) -> return Some(value = via)
    case None -> ()
  }
  mapGet(rule.namesVia, origin + "|" + name)
}

// How `rule` lets a qualified reference name package `pkg`: an import of it
// in any form, or, when `transitive`, one whose own imports reach it.
func fileQualifiedVia(rule: in FileImportRule, curPkg: in String, pkg: in String, transitive: in Bool): Option[String] {
  if pkg == curPkg or pkg == "Std.Core" {
    return Some(value = "")
  }
  match mapGet(rule.directVia, pkg) {
    case Some(via) -> return Some(value = via)
    case None -> ()
  }
  if transitive {
    return mapGet(rule.reachVia, pkg)
  }
  None
}

// T0219 for the name `shown`, written in file `f`, that only file `other`'s
// import `via` makes visible.  One error per name and file.
func reportSiblingImport(
  tbl: in SymbolTable, f: in Int, other: in Int, shown: in String, via: in String, sp: in Span
): Unit {
  val key = toString(f) + "|" + shown
  if tbl.siblingImportKeys.containsKey(key) {
    return
  }
  tbl.siblingImportKeys.add(key, true)
  val otherPath = tbl.fileRules[other].path
  val location = if otherPath.length > 0 { otherPath } else { "another file of this package" }
  tbl.siblingImportErrors.add(
    errorDiagnostic(
      "T0219",
      "'" + shown + "' is not imported by this file; only `" + via + "` in " + location +
        " makes it visible, and a file's imports are its own: add `" +
        via +
        "` to this file",
      sp
    )
  )
}

/// Note a bare name, written at `sp`, that resolved to `sym` through the
/// union of the package's imports: T0219 when the file it is written in does
/// not make it visible and a sibling file's import does (docs/70 §4.1).  The
/// name still resolves, so the use is reported once rather than as an
/// unknown name.  Candidates stay the union's, so a name two files import
/// from different packages is T0123, as the backends still resolve bare
/// names package-wide (#8690).
pub func symTableNoteBareUse(tbl: in SymbolTable, sym: in Symbol, sp: in Span): Unit {
  val f = useFileForSiblingCheck(tbl, sp)
  if f < 0 {
    return
  }
  val curPkg = symTableScopePkg(tbl)
  if not symTableImportVisible(tbl, curPkg, sym) {
    return
  }
  match fileBareVia(tbl, tbl.fileRules[f], curPkg, sym) {
    case Some(_) -> {
      return
    }
    case None -> ()
  }
  var j = 0
  while j < tbl.fileRules.count {
    if j != f {
      match fileBareVia(tbl, tbl.fileRules[j], curPkg, sym) {
        case Some(via) -> if via.length > 0 { reportSiblingImport(tbl, f, j, sym.name, via, sp); return }
        case None -> ()
      }
    }
    j = j + 1
  }
}

/// `symTableNoteBareUse` for a bare call or function value `name` bound to a
/// function of `origin`.
pub func symTableNoteBareFuncUse(tbl: in SymbolTable, origin: in String, name: in String, sp: in Span): Unit {
  val f = useFileForSiblingCheck(tbl, sp)
  if f < 0 {
    return
  }
  if not symTableBareFuncVisible(tbl, origin, name) {
    return
  }
  val curPkg = symTableScopePkg(tbl)
  match fileBareFuncVia(tbl.fileRules[f], curPkg, origin, name) {
    case Some(_) -> {
      return
    }
    case None -> ()
  }
  var j = 0
  while j < tbl.fileRules.count {
    if j != f {
      match fileBareFuncVia(tbl.fileRules[j], curPkg, origin, name) {
        case Some(via) -> if via.length > 0 { reportSiblingImport(tbl, f, j, name, via, sp); return }
        case None -> ()
      }
    }
    j = j + 1
  }
}

/// `symTableNoteBareUse` for a qualified reference `pkg.member` written at
/// `sp` that the union of the package's imports lets name `pkg`: an import
/// of `pkg` in any form, or, when `transitive`, one whose own imports reach
/// it.  An alias rewritten to its package (`Q.f` to `P.f`) is checked here
/// too, so the advice names the sibling's `import P as Q`.
pub func symTableNoteQualifiedUse(
  tbl: in SymbolTable,
  pkg: in String,
  member: in String,
  sp: in Span,
  transitive: in Bool,
): Unit {
  val f = useFileForSiblingCheck(tbl, sp)
  if f < 0 {
    return
  }
  val curPkg = symTableScopePkg(tbl)
  match fileQualifiedVia(tbl.fileRules[f], curPkg, pkg, transitive) {
    case Some(_) -> {
      return
    }
    case None -> ()
  }
  var j = 0
  while j < tbl.fileRules.count {
    if j != f {
      match fileQualifiedVia(tbl.fileRules[j], curPkg, pkg, transitive) {
        case Some(via) -> if via.length > 0 { reportSiblingImport(tbl, f, j, pkg + "." + member, via, sp); return }
        case None -> ()
      }
    }
    j = j + 1
  }
}

/// Whether the file a name written at `sp` is judged by imports, itself,
/// every package of `pkgs`; true outside a package of several files.  A
/// T0123 between packages that different files import says so.
pub func symTableFileImportsAll(tbl: in SymbolTable, pkgs: in List[String], sp: in Span): Bool {
  val f = useFileForSiblingCheck(tbl, sp)
  if f < 0 {
    return true
  }
  val rule = tbl.fileRules[f]
  for p in pkgs {
    if not rule.wholeVia.containsKey(p) and not rule.directVia.containsKey(p) {
      return false
    }
  }
  true
}

/// The T0219 errors noted while checking the package, in the order noted.
pub func symTableSiblingImportErrors(tbl: in SymbolTable): List[Diagnostic] {
  tbl.siblingImportErrors
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
  // The resolver decides whether the file's imports make the name ambiguous
  // (D314).  A package of several files is still judged by the union of its
  // files' imports, as the backends resolve a bare name package-wide (#8690).
  match resolverFileFor(tbl) {
    case Some(fid) -> {
      if tbl.fileRules.count < 2 {
        match resolutionOf(tbl, fid, name) {
          case RUnresolved(code, _) -> if code != "T0123" { return pkgs }
          case _ -> return pkgs
        }
      }
    }
    case None -> ()
  }
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
