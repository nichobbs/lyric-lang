# 70. Resolved names, a typed IR and checked package interfaces

_Status: **Accepted in D267** as the direction for the compiler's front and
middle end, the library boundary and cross-package contracts. Phase 1 shipped
in D280; the `Lyric.Tir` data model (§6.2) in D319, the verifier (§6.4) in D323 and node identity (§6.1) in D325 and the generic builtin signatures (§5.3) in D334; §13 is the plan for the rest. It supersedes docs/45 phases
2-5 (§9.9), the per-package import scope of docs/19 §4 step 2 and §8 (§4.1),
and the transitive bare-name half of D141 (§4.3). Open questions are §15._

## 1. Why

A review of the compiler (2026-10) looked for the cause of a recurring bug
class: a program the type checker accepts that a backend then rejects,
panics on, or miscompiles, most often across a package or library boundary,
and names that resolve in a file that never imports their package. About 85
tracker issues fall into ten classes. Every class traces back to five
structural causes. Each one is a property of the architecture, not a missing
case, so case-by-case fixes keep reopening the class on another position,
another backend or another kind of dependency.

1. **The checker's types are discarded.** `CheckResult` is
   `{file, symbols, sigs, diagnostics}` (`typechecker_checker.l:16`): no
   typed tree and no per-expression type table. The monomorphizer (about
   10.6k lines, with its own `inferExprTE` family) and the MSIL, JVM and
   native backends each infer types again from an untyped AST, and fall back
   to `Object` (`MObject` appears 711 times in MSIL codegen) or a hint when
   they cannot. About 46 `*Sites` maps on the symbol table carry individual
   facts across the gap, keyed by `"start:end"` byte offsets with no file or
   package, so synthesised nodes (`synSpan()`, all `0:0`) and bodies brought
   in from another package collide. When checker and backend disagree,
   nothing notices until the program runs.
2. **The checker has a type that equals every type.** `typeEquiv` returns
   true when either side is `TyError` or `TyVar` (`typechecker_types.l:251`).
   A heuristic count finds no nearby diagnostic at about 75% of the places
   that produce `TyError` in expression and statement checking. Unknown
   members are reported only on records and interfaces; other receivers
   yield a silent `TyError`.
3. **Errors in imported signatures are thrown away.** Imported and restored
   signatures resolve against a scratch list (`importedDiag`,
   `typechecker_checker.l:6247`) that is never reported; the comment says
   codegen tolerates the residual `TyError`. A type that fails to resolve
   across a package boundary becomes a wildcard with no error.
4. **Names are filtered at lookup, in many places, and backends look them up
   again.** One symbol table holds every loaded package and visibility is
   applied when a name is looked up, by about forty call sites with about
   fifteen that bypass the filter. Language reference §9.2 has grown a patch
   per syntactic position (#7345, #7495, #7548, #7591). A multi-file package
   is concatenated with the union of its files' imports
   (`package_merge.l`), so a file uses names only a sibling imports. Each
   backend reimplements the import rule and ends in a bundle-wide by-name
   fallback (MSIL `findBundleFqnByName`, JVM `ctorClassForBundle`).
5. **A restored library is a second front end.** Its metadata is JSON whose
   declarations are Lyric source fragments; the consumer synthesises source,
   parses it and checks it again with a whitelist of expected spurious
   diagnostics. Contracts are never emitted (`requiresClauses = newList()`
   at all three producers in `contract_meta.l`), range bounds are dropped
   (`reprForDistinct`), invariants and per-function verification levels are
   absent, an opaque type's representation is published as text, and
   generic bodies cross as text to be checked again in the consumer's scope.
   The verifier has no cross-package call rule (`vcgen.l:3`).

The design below removes each cause instead of patching its symptoms: one
resolver that binds every name once (§4), a type discipline with no wildcard
(§5), a typed IR that the checker produces and every later stage consumes
(§6-§8), a checked interface artifact instead of synthesised source (§9), and
contracts that cross the boundary as data (§10).

## 2. The pipeline today and after

Today:

```
files -> text merge -> parse -> AST passes -> check (types discarded)
      -> AST passes driven by span-keyed side tables -> mono (re-infers)
      -> weave (synthesises untyped AST) -> await-hoist
      -> backend (re-resolves names, re-infers types)
restored dep -> JSON repr strings -> synthesised source -> parse -> check
```

After:

```
files -> parse each file -> syntactic expansion (AST)
      -> resolve (names to SymbolIds, per-file scope)
      -> signatures -> declaration expansion (derive, weave) -> resolve + signatures of the expansion
      -> body check -> TIR (every node typed and resolved)
      -> TIR passes (verified after each) -> backend lowering (no inference)
dependency -> interface artifact (typed, resolved) -> symbol table and TIR
```

## 3. Goals and non-goals

Goals:

- A program that type-checks either compiles on every target or fails with a
  target diagnostic about a genuinely target-specific limit (for example a
  host API that does not exist on that target), never with a codegen panic,
  a verifier error or a wrong runtime type.
- One place decides what every name means, using the scope of the file it is
  written in.
- One place decides the type of every expression; nothing downstream infers.
- A library is consumed from a checked interface; nothing is re-parsed or
  re-checked.
- Contracts work across packages at runtime (caller-side preconditions with
  blame on the caller, naming the callee's contract) and statically (the
  verifier applies the call rule to imported functions).

Non-goals:

- Changing the surface language beyond §4.3 and the rules in §5.4.
- Changing the targets' runtime ABI beyond the contract entry points of §10.2
  and the linkage table of §9.5.
- Compatibility with metadata written by earlier compilers (§12.3). Breaking
  now is preferred to carrying two formats.

## 4. Packages, files and name resolution

### 4.1 Package model

A package stays the unit of declaration, visibility, compilation and
interface: the files of one directory (docs/19 §2-§3) that declare the same
`package`. What changes is that **imports are per file**, as in Go: a file's
imports determine which names that file may use, and the package's
declarations are visible in all of its files.

The alternatives considered:

- **One package per file.** Each file would need `pub` or `internal` on
  everything a sibling uses, private helpers could not be split across
  files, and every file would become an interface and a metadata unit.
  Rejected: it trades the import leak for a visibility tax on every split.
- **A file-private tier.** Not needed to fix the leak; deferred (§15,
  Q-TIR-004).
- **Keep the per-package union.** Rejected: it contradicts language
  reference §9.2, which already says a bare name must be made visible by
  "one of the file's imports", and it makes a file's meaning depend on its
  siblings.

The text merge goes away. Each file is parsed once; a package is a list of
parsed files. Every `Position` carries a `FileId`, so spans, diagnostics and
node identities never need the merge's line-origin table (`MergedLineOrigin`
is deleted). Lines and columns are the file's own. Offsets stay unique across
the package: file N is lexed at an offset base past the end of the files
before it (`Lyric.Parser.parseFile(source, fileId, offsetBase)`), so the
offset-keyed side tables the checker hands to later passes
(`recordCopySiteKey` and the site maps built on it) and every comparison of
spans by offset keep their meaning without carrying the file; code that
indexes a file's text subtracts the file's base. File-level annotations stay package-wide with the existing
`B0014` agreement rule; `B0012` (one alias bound two ways across files) is
no longer an error, because aliases are per file (once #8690 moves the
last readers of the union's aliases to each file's own).

### 4.2 Symbol identity

Every declaration has a **`DefPath`**: the declaring package plus a path
inside it (`Std.Collections::List`, `Money::Amount::add`,
`Money::Amount::$impl(Show)::show`, a union case
`Shapes::Shape::Circle`). The DefPath is stable across compilations and is
what an interface artifact records. Within one compilation each DefPath is
interned to a dense **`SymbolId`**; every later stage refers to declarations
only by `SymbolId`. Locals, parameters and pattern bindings get a
**`LocalId`**, dense within their function. `TypeId` (today a per-compilation
counter, which let one package registered from two sources get two ids,
36d2734) is replaced by `SymbolId`.

The rendered DefPath joins the package and the path with `::`. A type is
`Pkg::Name`. An extern type bound to a host type is `extern::<host name>`
(`extern::System.Collections.Generic.List`1`), so every extern type naming
one host type is one declaration wherever it is written. A declaration with
no package (the checker's flat entry point) has no DefPath and a fresh id.

### 4.3 Visibility rules

A bare name in file F of package P resolves, in order, to:

1. a local, parameter or pattern binding in scope;
2. a declaration of P (any file of P);
3. a name F imports: every `pub` name of a package F imports whole, or a name
   F imports selectively (a listed union or enum brings its cases, as
   today), under its rename if it has one;
4. the prelude (`Option`, `Result` and their cases).

Two candidates at the same step are **T0123**. A name found nowhere is
**T0020** (T0010 in type position), with the existing hint when a loaded
package declares it.

A qualified name `Q.x` resolves when `Q` is an alias F declares, or the full
path of a package F imports in any form, or `P` itself. A package F does not
import cannot be named, even when an imported package imports it.

**Change to D141.** Today a whole import makes visible, bare, every name of
each package the imported package itself imports whole, and a qualified name
may name any package reachable through imports. Both are removed. The
kernel/host idiom that relied on them (`Std.Collections` re-exporting
`Std.CollectionsHost`'s `List` and `newList`) uses the existing re-export,
`pub use` (language reference §9.3), which makes the re-exported names part
of the facade's own surface. The migration (adding `pub use` to facades,
adding imports to files that leaned on transitive reach) is mechanical and is
done in the compiler, stdlib and ecosystem sources before the rule is
switched on (§12.2).

Visibility of the declaration itself (`pub`, `internal`, package-private) is
checked at the same time, so **T0097** comes from the resolver for every
position (call, value, type, pattern head, constructor, method receiver)
without per-position code.

### 4.4 The resolver

`Lyric.Resolve` runs after the syntactic expansions (cfg erasure, build
defines, wire expansion, plugin expansion, stubbable synthesis, interface
default methods) and before type checking. Its input is the package's parsed
files plus the symbol tables of its dependencies (from their interfaces,
§9). Its output, `ResolvedPackage`, maps every name occurrence (by `NodeId`,
§6.1) to a `SymbolId`, a `LocalId`, or a deferred member name to be resolved
by the checker against a type (§4.5). It emits every name diagnostic
(T0010, T0020, T0097, T0123, T0148) and nothing after it emits one.

Rules that make it a single authority:

- **No unfiltered lookup.** The only lookup function takes the file's scope;
  there is no "find any symbol named x" entry point, so no later pass can
  reach a declaration the file cannot see.
- **No empty origin.** Every symbol has a declaring package; the flat
  `checkWithImports` shim and the LSP's `ImportedPackage(name = "")`
  flattening are removed. The LSP builds the same `ResolvedPackage` as
  `lyric build`.
- **`AliasRewriter` and `TypeAliasResolve` are folded in.** Aliases and
  `import ... as` are scope entries, not rewrites.
- **Specialisations and expansions are resolved in their own scope.** A
  generic body from another package arrives already resolved (§9.4); a
  declaration expansion (derive, weave) is resolved in the scope of the
  package that receives it, with the names the expansion introduces bound to
  the `SymbolId`s the generator chose, never by text.

### 4.5 Member resolution

`x.m(...)` and `x.f` cannot be resolved before the type of `x` is known, so
the resolver leaves them to the checker, which resolves them against the
receiver type only: the type's fields, its methods (`func T.m` and methods in
the type body), impl methods of interfaces the type implements, and UFCS
functions **visible in the file** whose first parameter accepts the receiver.
Nothing else is searched. In particular the shortcut that accepts a method
call on a union receiver when *any* loaded package has a function of that
name (`anyFunctionNamed`, `typechecker_exprs.l:4985`) is removed, and a
member that is not found is **T0113** on every receiver type (§5.3).

## 5. Types and the error discipline

### 5.1 The checker's types

The checker's internal `Type` keeps its shape with three changes:

- `TyUser(id: TypeId, ...)` becomes `TyNamed(sym: SymbolId, args)`.
- `TyVar(name)` is split into `TyParam(owner: SymbolId, index)`, a rigid
  generic parameter that equals only itself, and `TyInfer(id)`, an inference
  variable that exists only while one call or one binding is being solved.
- `TyError` carries the diagnostic that caused it: `TyError(diag: DiagId)`.

`typeEquiv` treats neither `TyParam` nor `TyInfer` as a wildcard. `TyError`
still suppresses cascades (a node whose input is an error does not report a
second error), but it can only be constructed with a recorded diagnostic.

### 5.2 Inference variables

Generic calls solve their type arguments from argument types and the
expected type. An unsolved inference variable at the end of solving is
**T0224** (`cannot infer type argument T of f; write f[...]`), never a
default. This replaces the monomorphizer's defaulting of unbound parameters
to `Object` (`mono.l:3508`), which produced `View[Object]` (afe3b73).

### 5.3 No silent acceptance

- **Imported signatures are checked fatally.** A dependency's interface is
  already checked (§9), so resolving it can only fail if the interface is
  corrupt or a dependency is missing; both are errors (**T0211**, naming the
  dependency and the unresolvable DefPath). The scratch `importedDiag` and
  `implDiag` lists are deleted.
- **Unknown members are errors on every receiver.** Extern types resolve
  members from host metadata at check time (`Msil.MetadataReader`,
  `Jvm.AutoFfi`, already used by auto-FFI); an extern member that metadata
  does not have is T0113. `isUniversalMethodName` is replaced by real
  declarations of the universal methods (`toString`, `equals`, `hash`) on
  the types that have them.
- **Polymorphic builtins get real signatures.** `println`, `toString`,
  `format1`-`format4` and the others are typed as generic functions over a
  `Show` (or `Any`) bound instead of taking `TyError` parameters.
- **Stdlib bodies are checked fatally on every target.** The JVM's advisory
  `tcFatal = false` for bundled stdlib sources goes away with §9.6.
- **A gate before the middle end.** If the checked package contains any
  `TyError` and the diagnostic list has no error, the compiler reports
  **I0001** (internal compiler error: a `TyError` with no diagnostic, naming
  the node). This turns any remaining silent degradation into a visible
  compiler bug at once.

### 5.4 Rules that move from codegen into the checker

Several behaviours are today decided by a backend because the checker
returned `TyError` for them ("codegen owns exotic receiver behaviour",
`typechecker_exprs.l:3125`). Each gets a typing rule in the checker and the
language reference: indexing of every indexable type (records with an
`index` method, host collections through extern metadata), integer literal
range and suffix rules (#7346), mixed-width arithmetic and comparison
(#7350, #7382), and the conversions in §6.3. A shape with no rule is an
error, not a pass-through.

## 6. The typed IR (TIR)

### 6.1 Node identity

The parser gives every expression, statement and pattern a `NodeId`, and
`Lyric.Resolve` renumbers the package after the syntactic expansions so ids
are dense and unique per package, whatever generated the node. The
`*Sites` side tables are replaced by tables keyed by `NodeId` while the
checker still emits them (§13 phase 3), then by TIR itself.

### 6.2 Data model

`Lyric.Tir` is a separate set of types, not an annotated AST, so that a
TIR value cannot exist without its types:

```
record TExpr  { id: NodeId, ty: Ty, span: Span, kind: TExprKind }
union  Ty     { TPrim | TTuple | TFunc(params: List[TParamTy], ret, isAsync)
              | TArray | TSlice | TNamed(sym: SymbolId, args) | TParam(owner, index)
              | TRefined(underlying, lo, hi, hiInclusive) | TLen | TNever | TExtern(host: HostTypeRef) }
union  Callee { Direct(sym, typeArgs) | Interface(iface, method, typeArgs)
              | Indirect(fnValue: TExpr) | Extern(member: HostMemberRef) | Intrinsic(op) }
union  TExprKind {
  XLit | XLocal(LocalId) | XGlobal(sym, typeArgs) | XCall(callee, args: List[TArg])
  | XConstruct(sym, fields: List[TExpr]) | XField(recv, field: FieldRef) | XIndex(recv, idx, how: IndexKind)
  | XConvert(kind: ConvKind, inner) | XIf | XMatch(scrutinee, arms: List[TArm], exhaustive: Bool)
  | XBlock | XLambda(params, captures: List[Capture], body) | XAwait | XSpawn | XPropagate
  | XOld | XResult | XAssign(place: TPlace, op, value) | ...
}
```

`Ty` has no error and no inference case: TIR is built only from a package
that type-checked without errors. A call's arguments are in parameter order
with defaults filled in, each with its mode (`in`, `out`, `inout`) and, for
`out`/`inout`, a `TPlace`. Every implicit operation is explicit:
`ConvKind` covers numeric widening, distinct-type wrap and unwrap, range
checks, interface upcasts, boxing to a host type, slice and list
conversions, and `Option` lifting. UFCS, method syntax and operator
overloading are all `XCall` with a resolved `Callee`. Closures list their
captures with capture mode. Patterns are typed and bind `LocalId`s.

A protected type's entry (or `func`) is a callable symbol of kind `TSkEntry` whose first parameter
is the protected value, passed `in`; `t.add(n)` is a direct `XCall` of it and `Total()` an
`XConstruct`. A `TFnDecl` carries the entry's `when:` guard as `barrier: Option[TExpr]`, a `Bool`
over the receiver's fields and the entry's parameters, which the verifier checks. The TIR carries
no locks: backends lower locking and the barrier wait from the declaration (D553).

### 6.3 Who builds it

The checker builds TIR. The first step (§13 phase 3) has the checker record,
per `NodeId`, the type, the resolved callee and instantiation, the chosen
conversion and the argument order, and a builder walks the AST with those
tables to produce TIR, failing with **I0002** on any node with a missing
entry. Over the same phase the checker's inference functions are changed to
return TIR directly, and the tables are deleted. Either way TIR is the only
output of checking, and its completeness is checked, not assumed.

### 6.4 The verifier

`Lyric.Tir.Verify` checks a TIR package and reports **I0003** (pass X
produced an ill-formed node, with the node and the rule) for:

- every `Ty` closed: a `TParam` only inside its owner's generic scope, and
  none at all after monomorphisation on a target that monomorphises;
- every call's argument types equal to its callee's parameter types under
  its instantiation, exactly (conversions are explicit);
- every `SymbolId` defined in the package or a loaded interface, every
  `LocalId` defined before use and owned by one function or captured;
- branch and match arm types equal to the node's type; `XAssign` to a
  mutable place; `NodeId`s unique.

It runs after building and after every TIR pass in CI, in every self-test,
and under `lyric build --verify-ir`. It is the property that turns "a
backend found the wrong type at runtime" into "this pass produced an
ill-typed node", reported at the pass.

## 7. The middle end

### 7.1 Expansion moves before body checking

Passes that generate declarations run on AST before the bodies are checked,
so everything they generate is checked like code the user wrote:

- **Syntactic** (unchanged, before resolve): cfg erasure, build defines,
  wire expansion, plugin expansion, stubbable synthesis, interface default
  methods.
- **Declaration expansion** (new placement, after signatures are resolved,
  before bodies are checked): derives and aspect weaving. Both need resolved
  signatures (field types for derives, signatures for `matches:` and
  B′-mode shapes) but not checked bodies. The weaver generates the wrapper
  and the renamed target as AST items with resolved names; their bodies,
  including advice bodies and composed contracts, are checked in the
  receiving package. `synSpan()` goes away: a generated node's span is the
  span of the declaration that caused it (the aspect clause or the
  `@derive`), which is also the right place for its diagnostics.

### 7.2 TIR passes

Each pass maps TIR to TIR and is verified after it runs:

| Pass | Today | On TIR |
|---|---|---|
| Contract elaboration | AST rewrite after check | generates contract entry points and call-site checks (§10.2) |
| `?` propagation | AST rewrite | `XPropagate` lowered to a match and early return |
| Desugars driven by side tables (covariant conversion, distinct ops, record and array lowering, overflow, range checks, format builtins) | AST rewrites keyed by span | mostly gone: the checker emits the explicit node (`XConvert`, `XCall(Intrinsic)`); what remains is a typed lowering |
| Monomorphisation | 10.6k lines with its own inference | substitutes `TParam` in typed trees using the instantiations on call nodes; no inference |
| Await hoisting | AST rewrite, last | TIR pass, last |

`recheckSpecs` and the `__lyric_origin_imports` annotation (30e5c51) are
deleted: specialised bodies are typed by substitution and resolved before
they arrive.

### 7.3 Generic strategy per target

Which generics are monomorphised is a target policy passed to the mono pass,
not a property of the IR: native monomorphises everything, MSIL keeps
reified in-bundle generics (docs/43) and monomorphises the rest, the JVM
erases with explicit `XConvert(Unerase)` nodes inserted by a JVM-specific
TIR pass, so every `checkcast` the JVM backend emits is decided from a type,
not from `scrutineeGenericArgs`-style inference.

## 8. Backends

A backend lowers TIR. It may not look up a name, infer a type, or decide an
overload; the information is on the node. Concretely:

- The `lowerExpr*`, `infer*` and hint functions (`inferCallReturnTypePB`,
  `collExpect`, `joinBranchResultType`, `erasedSlotJvmType` and their kin)
  are deleted, not adapted; types come from `TExpr.ty`.
- The backends' own import rules and bundle-wide fallbacks
  (`findBareImportedFqnMsil`, `findBundleFqnByName`, `ctorClassForBundle`,
  `typeFqnCandidates`) are deleted; callees are `SymbolId`s mapped through
  the linkage table (§9.5).
- A backend error is a target limit with a target diagnostic code, never a
  panic. A panic in a backend on verified TIR is a compiler bug (I0004) with
  the node id.

The backends are ported one at a time (§13 phase 4). The order is native,
then JVM, then MSIL: native is the newest and already monomorphises, the JVM
verifier catches mistakes MSIL silently miscompiles, and MSIL is last
because it is the target the compiler itself runs on, so stage 2 of the
bootstrap (§12) exercises it on the whole compiler.

## 9. Package interfaces

### 9.1 What replaces contract metadata

A built package carries a **package interface**: the checked, resolved
surface of the package, the way a `.swiftmodule`, an OCaml `.cmi` or Kotlin
metadata is. A consumer loads it straight into its symbol table and TIR;
nothing is synthesised as source, parsed or checked again. This replaces
`Lyric.ContractMeta`, `Lyric.ContractMetaEmit`, `Lyric.RestoredPackages`'
synthesis, `checkContractSurface` and its whitelist, and
`stdlibSourcesFromCompiledBundle`.

### 9.2 Contents

- Header: format version, package name, the interfaces it was built against
  (package, version, interface hash), the package's verification level and
  file-level annotations that affect consumers (`@pure`/`@io`), the build's
  target set.
- Declarations, by DefPath: kind, visibility, generic parameters with bounds
  and `where` clauses, and full types (`Ty` with DefPath references). Records
  and exposed records with fields and defaults; unions and enums with cases;
  distinct types with their underlying type **and range**; interfaces with
  members, contracts and default methods; protected types with entries and
  barriers; type invariants; `pub val`s with type (and value when it is a
  constant); `pub use` re-exports as references to the original DefPath.
- Functions: signature, parameter modes, defaults as TIR expressions (shipped for functions and methods, D460: literals, names, calls, constructions, conversions, lists and tuples; another shape is not carried and the consumer counts the call),
  contracts as TIR expressions (§10), per-function verification level, proof
  status (§10.3), `@axiom`, `@pure`, async.
- Bodies: as TIR, **after** contract elaboration's declaration step, for
  generic functions, `@inline_template` and B′-mode aspect templates, and
  hidden exports (§9.4).
- Opaque types: the Lyric-visible part says only that the type exists with
  its generic parameters. Layout a backend needs (size and fields of a
  by-value opaque record on native) is in the target section (§9.5), which
  the resolver and checker never read.

### 9.3 Producer validation

A library build validates its own interface before writing it:

- A `pub` (or `internal`) signature may name only types at least as visible
  (**T0212**, #7214).
- Anything a carried body, default or contract references is `pub`, or a
  hidden export (§9.4), or is reported (**T0213**).
- The interface is written, read back, and compared with the in-memory one;
  a difference is I0005. This round trip is what makes "the consumer sees
  exactly what the library's checker saw" a tested property.

### 9.4 Hidden exports

A private declaration that a carried body, default or contract reaches is a
**hidden export**: it is in the interface with its DefPath and (for bodies)
its TIR, it can be referenced from carried TIR by `SymbolId`, and the
resolver never binds a name in consumer source to it. A non-generic hidden
export is called in place, in the library's binary, through its linkage name
(emitted public at the ABI level and marked hidden: a `[LyricHidden]`
attribute on MSIL, the `ACC_SYNTHETIC` flag on the JVM, hidden visibility
for a native shared object). A generic one is specialised in the consumer
like a `pub` generic. This replaces the copying of private generic helpers
under package-unique names (#8427, `generic_carry.l`).

### 9.5 Linkage table

Per target, the interface maps each exported and hidden-exported DefPath to
its emitted name: the CLR type and member (with signature blob shape) for
MSIL, the JVM class, member and descriptor, the native symbol and ABI
layout. A consumer's backend reads names from here and never reconstructs a
mangled name or owner class. This removes the JVM class-owner class of bugs
(#7652, #7357, #6338) at the source.

### 9.6 Encoding, embedding and the stdlib

- Encoding: a canonical, deterministic binary format defined in
  `Lyric.Iface` (tagged records, LEB128 integers, one string table), with
  `lyric interface dump <dll|jar|lyri>` printing it as text. Deterministic
  bytes keep the bootstrap's reproducibility check meaningful.
- Embedding: a `Lyric.Interface.<Pkg>` manifest resource in a DLL, a
  `META-INF/lyric/<Pkg>.lyri` entry in a JAR, and a `<Pkg>.lyri` file next to
  a native library.
- Interface hash: a hash of the canonical bytes. A dependent package is
  rebuilt only when an interface it consumes changes; a body change to a
  non-generic function does not change it.
- The stdlib is consumed through its interfaces on every target. User builds
  stop compiling stdlib sources (the JVM bundler copies the prebuilt stdlib
  classes it needs instead), which removes the advisory stdlib check.

## 10. Contracts across packages

### 10.1 Contracts as data

A function's `requires:` and `ensures:`, a type's invariant and a range
subtype's bounds are TIR expressions in the interface. A contract may
reference parameters, `result`, `old(...)`, and `@pure` functions; a private
pure helper it uses becomes a hidden export (§9.4). This one representation
serves the runtime checks (§10.2), the verifier (§10.3) and generic
specialisation.

### 10.2 Runtime checks: caller blame, callee reference

Each function with a `requires:` or with parameters of a type that has an
invariant is emitted with three entry points:

- `__lyric_pre_<f>(args, site)`: evaluates the precondition and parameter
  invariants in the callee's package (so private helpers are reachable) and,
  on failure, raises `PreconditionViolated` with **the caller's call site**
  and **the callee's clause and its declaration site**, for example
  `precondition of Money.withdraw violated at app/main.l:42:7: requires
  amount <= balance (declared at money/account.l:18:3)`;
- `__lyric_body_<f>(args)`: the body with its postcondition and return-side
  invariant checks, which stay callee-side (a violated `ensures:` is the
  callee's fault and names the callee);
- `<f>`: the public, checked entry that host code (C#, Java, C), function
  values and interface dispatch use. It calls the pre-check with an
  "indirect call" site and then the body.

A direct Lyric call, in the same or another package, calls
`__lyric_pre_<f>` with its own site and then `__lyric_body_<f>`. A call
through an interface checks the interface method's precondition with the
caller's site; the clauses an implementation adds (language reference
§6.1.1 makes them additive) are checked by the implementation's checked
entry, which dispatch reaches, and report the dispatch as the site. A
generic function's specialisation in the consumer gets its pre-check
specialised from the interface's TIR. Construction-time invariant checks
keep their existing form (`__lyric_checked_<Type>` in the declaring
package) and gain the same site argument; the gaps language reference §6.2
lists (generic specialisations in another package, restored packages,
code synthesised after type checking) close because every one of those
paths now goes through TIR and the interface. docs/08 §9's rule that
public-boundary checks are never elided stays.

docs/08 §6.1's premise order is unchanged; only who evaluates the
precondition premise, and therefore what the failure reports, changes. The
§6.1 Bug table gains the call site and clause site in the message.

### 10.3 Static checks

The verifier loads imported functions' contracts from interfaces and
applies the call rule of docs/08 §10.4 to them: the precondition is a goal at
the call site, the postcondition is assumed after it. The interface records
each function's verification level and **proof status**: `Proven` (its
package was verified with `lyric prove`, and the interface records the
verifier version and goal hash), `RuntimeChecked`, or `Axiom`. The existing
rule that a `@proof_required` caller may call only `@proof_required` or
`@axiom` code is enforced per function from the interface, replacing the
package-level proxy in V0001/V0002 (`modechecker_check.l:177`). Assuming the
postcondition of a `RuntimeChecked` callee is sound for partial correctness,
because execution cannot continue past a violated `ensures:`; whether to
allow it for `@proof_required` callers is open (§15, Q-TIR-002).

A call site whose precondition the verifier discharges records that fact;
using it to drop the runtime pre-check in a `@proof_required` package is a
later optimisation (§15, Q-TIR-003), not part of this plan.

### 10.4 Why not plugins

The suggestion that a library's own code could be called to verify uses of
it was assessed against the plugin mechanism (docs/69):

- Static proof needs the precondition and postcondition as formulas in the
  caller's SMT context. A plugin can either return the formula (which is
  shipping it as data, produced by untrusted code) or decide the obligation
  itself, which makes every such proof as strong as a third-party `@axiom`
  and unauditable by docs/17.
- Type checking and specialisation need signatures and bodies before any
  code runs; plugin boundary types exclude generic, opaque, range and
  interface types.
- A query per call site over a pipe costs 0.1 to 1.4 ms (D231), process
  start is per dependency, and trusted in-process mode is unavailable in the
  AOT `lyric` binary.
- Build output would depend on plugin behaviour, versions and I/O, which the
  bootstrap's byte-compare cannot allow, and a JVM or native library would
  need a payload the build host can run.

The runtime part of the idea is kept, as §10.2's exported pre-check entry
points: the library's own code does evaluate its precondition, in its own
package, with the caller's site. The static part is better served by
contracts as data. Library-specific static checks (SQL strings, protocol
misuse, usage rules) are a good fit for a future advisory `CallSiteChecker`
plugin point modelled on source generators and run under wasm; that is
outside this plan (§15, Q-TIR-005).

## 11. Testing

- **TIR verification** after every pass in CI and in every self-test (§6.4).
- **A compile-fail corpus.** `lyric-compiler/lyric/testdata/reject/` holds
  programs (single- and multi-package) that must fail with a given code, run
  by a `@test_module` that checks the codes on every target's check path.
  It starts with the repros from this review: a file using a name only a
  sibling file imports, transitive bare and qualified reach, `Some(1).frob()`
  with `frob` declared in an unimported package, `val w: Nope.Widget`, an
  unknown uppercase receiver, a `pub` signature naming a private type, an
  unsolvable type argument.
- **Cross-target agreement.** The check is target-independent, so the
  corpus asserts the same diagnostics for every target; a test that is
  accepted on one target and rejected on another fails. Until the targets'
  project builds check packages in one order, a case's `expect` line may
  list alternatives (`T0211|T0010`) for an error the targets report at
  different sites: `dependency_surface_unresolved` is reported in the
  dependency itself on dotnet and against its consumer on the JVM (D306).
- **Interface round trip** on every package the bootstrap builds (§9.3).
- **Differential runs during each backend port.** The backend's self-test
  set runs on the old and new lowering in the porting PR; the old lowering
  is deleted in the same PR once they agree.
- The existing JVM fuzzer (`jvm/fuzzer.l`) is retargeted at TIR construction
  and verification.

## 12. Bootstrap, seeds and releases

### 12.1 The constraint

The compiler is compiled by the latest released `lyric` (the seed, stage
0), and the resulting compiler rebuilds itself and the stdlib (stage 2,
`scripts/bootstrap.sh`). So the compiler's own sources may use only what
the seed accepts, and the new compiler must accept the compiler's sources.

### 12.2 Stricter rules land in two steps

Per-file imports (§4.1), the D141 change (§4.3), the error discipline (§5)
and producer validation (§9.3) all reject code the current compiler accepts.
Each lands as: first, fix every source that relies on the old behaviour
(compiler, stdlib, ecosystem libraries, examples, book snippets) in a form
the seed also accepts (adding imports and `pub use` is accepted by any
seed); then switch the rule on. Where the fix itself needs a feature the
seed lacks, a release is cut between the two steps.

### 12.3 The format break

The interface format replaces contract metadata outright; the new compiler
does not read the old format. Stage 2 rebuilds the stdlib and every compiler
package from source before consuming them, so it needs no old-format
reader. If phase 5 finds a stage-2 step that reads seed-emitted metadata, a
release that writes both formats is cut first and the old writer is removed
in the next release; the reader of the old format is never added to the new
compiler. Every ecosystem library and published package is rebuilt and
republished with the format change.

### 12.4 Releases along the way

A release is cut after each phase that changes accepted source or the
format (phases 2, 5 and 6), so the next phase's seed has the stricter rules
and later phases can rely on them.

## 13. Plan

Each phase lists its streams; streams in one phase can run in parallel in
separate sessions. Each stream is one PR, or a small number of large PRs,
reviewed by the review workflow.

### Phase 1: strictness on the current architecture

One PR. Cheap and independent; it stops the bleeding while the rest is built.

- Report imported signature diagnostics instead of `importedDiag`
  (T0211); delete `implDiag`.
- Remove `anyFunctionNamed` for union receivers; T0113 on every receiver
  type the checker can enumerate.
- Unknown uppercase receiver and unknown type qualifier (`Nope.Widget`) are
  errors, not a fallback to a same-named type.
- The LSP keeps import origins (no `name = ""` packages).
- T0212: a `pub` signature naming a less-visible type (#7214).
- Fix the sources that each rule rejects, in the same PR.

Shipped in D280. The I0001 gate moved to phase 3a: the current checker
produces about 11.5k `TyError`s with no diagnostic on the compiler's own
sources, mostly benign callee positions, so the gate is enforced by the TIR
builder (I0002) rather than on the current checker.

### Phase 2: resolver and symbol identity

- **2a** `FileId` in `Position`; parse each file of a package separately;
  replace the text merge with a list of parsed files (docs/19 §4 is
  rewritten); per-file import scopes.
- **2b** `DefPath`, `SymbolId`, `LocalId`; `TypeId` replaced.

  Status: `SymbolId` has replaced `TypeId`, and a type's id is its
  interned DefPath (`Pkg::Name`, or `extern::<host name>` for an extern type
  with one), so every registration of one type in a compilation has one id
  (D306). DefPaths for functions and values, whose overloads need a
  discriminator, come with 2c, which is their first consumer; `LocalId`
  comes with 3a, where TIR binds locals.
- **2c** `Lyric.Resolve` with the rules of §4.3-§4.4, D141 change, folding
  in `AliasRewriter` and `TypeAliasResolve`; the checker consumes resolutions
  and its own lookups are deleted; source migration (`pub use`, imports)
  first, rule second (§12.2).

  Status: step 1 (D309) gives `pub use P` its re-export meaning (whole
  package; recorded in contract metadata) and puts the D141 change in
  warning mode: a name reached only through a whole import that is not
  re-exported, and a qualified reference to a package reached only through
  imports' imports, are `W0033`. The stdlib facades `Std.Collections` and
  `Std.Json` re-export their hosts, and the compiler, stdlib, ecosystem and
  examples were migrated. Step 2 (D311) makes it the rule: a whole import
  reaches only what the imported package re-exports, a qualified reference
  through a package resolves only to what it re-exports, and a package the
  file does not import cannot be named; `W0033` is retired. Step 3 (D313)
  adds `Lyric.Symbols` (`SymbolId`, `DefPath` and the interner, moved out of
  the checker) and `Lyric.Resolve`: the declaration table with a DefPath for
  every declaration kind (a function's path carries its parameter types as
  written, the overload discriminator), a per-file import scope, and the
  §4.3 lookup (`resolveBare`, `resolvePath`) with the tier rule of #8709, a
  name ranked by how the file sees it. Step 4 (D314) makes the checker take
  bare-name answers from the resolver for the checked package (fixing
  #8709), keeping its scan for dependency scopes, built-ins and the
  sibling-file cases. Step 5 (D315) adds `visibleDecls` and answers "what a
  bare name can mean" from it; the unfiltered name scan is renamed
  `symTableTryFindAllNamed` and left to callers that narrow by a qualifier or
  an owner id. Step 6 (D316) takes the bare-function tier, the import hint and bare-name
  ambiguity from the resolver and deletes the checker's versions. Next: the
  Step 7 (D318) takes the single lookup and T0219 from the resolver's per-file
  scopes and deletes the checker's import-rule tables and the differential
  mode. Step 8 (D322) gives each dependency a scope built from its own imports
  as declarations and deletes the checker's scan. Step 9 (D328) makes a bare
  union case need a name the file can reach (#8722) and keeps a restored
  dependency's selective and aliased imports in their form. Step 10 (D330)
  moves what an import binds (heads, renames) into `Lyric.Resolve`; the
  `AliasRewriter` tree walk becomes its projection and stays until 2d, which
  is when backends stop reading rewritten names. Step 11 (D333) resolves
  qualified type paths through `resolvePath` and deletes the checker's owner
  scans. `TypeAliasResolve` waits for 2d (D333).
- **2d** Backends receive the resolved callee `SymbolId` per call through
  the existing `MiddleEndOptions` channel, and their name lookups
  (`findBundleFqnByName` and kin) are deleted.

  Status: step 1 (D336) records each bare or package-qualified call's resolved
  declaration (`SymbolTable.calleeSites`, a rendered DefPath keyed by
  `methodCallSiteKey`) and passes it through `MiddleEndOptions.calleeSitesOut`;
  MSIL binds such a call to it before any of its own tiers, which fixed two
  calls the tiers bound to a package-private function of another package.
  Specialised generic calls and `Type.f(x)` calls keep their site too, and
  MSIL's bundle-wide name search (`findBundleFqnByName`) is deleted. MSIL's
  bare-import search (`findBareImportedFqnMsil`) is deleted; `pkgImportAliases`
  is deleted, a copy of another package's generic reads that package's sites
  (`<package>|<key>`), and defaults mean the declaring package's names; the JVM
  binds a call to its site, scoped key or qualified key, and a default
  expression's callees are qualified where their package is checked (#8850); a
  plain function has no bare key on the JVM any more, and neither has a
  dot-named one (#8869: `Type.f(x)` binds by its site, then the file's
  import-scoped type map; only a wire factory keeps a `Wire.method` key), and a
  `Type.f` call binds the function of the package whose `Type` is in scope on
  both backends (#8878). Native binds a call to its site (`sitedSig`, D336
  item 11), and a default expression of another package binds that package's
  names without a port of the JVM's qualification (#8850). The alias table the
  passes read comes from `Lyric.Resolve.aliasTargetsFor` (D344, #8888): an alias
  of a renamed-import type now names its own package. Dot-named overloads that
  both fit by argument count are chosen by type, and all three backends lower the
  declaration the site names by its own parameter count (D345, #8893).

  What 2d leaves, and where it goes. Phase 4 (backends lowering TIR) deletes:
  the `AliasRewriter` tree walk, `TypeAliasResolve` and the backends' alias layers
  (#8894); the JVM's constructor, pattern and type import-scope maps
  (`~ctor-import~`, `~selimport~`, `importAwareRegistry`'s overlays; #8895); and
  native's name lookups for bundled stdlib units, Mono-renamed specialisations and
  synthesised calls (#8896). Two overloads with the same parameter count are
  keyed alike by the backends only in the sense #8897 described: two same-arity
  dot-named functions of one package are the duplicate name `T0001`, so it cannot
  arise (pinned by the reject corpus, #8914).

  Imports are per file everywhere the phase-2 passes read them (D346, #8690):
  plugin expansion (the checked package and its dependencies), component glue, the
  weaver's A0047 row-type check and the alias rewriter's synthesised items read the
  imports of the file a name is written in, `perFileImports` lives in
  `Lyric.Resolve`, and `B0012` is retired: an alias two files bind to different
  packages is each file's own (e2e on dotnet, the JVM and native).

  Phase 2 is complete as far as it can be without TIR; what remains moved to phase
  4, with the reason. The cross-file `T0148` and `T0123` stay: the checker's
  bare-name tables hold one symbol per name, so a name two files import from
  different packages (a function, or two types called `Pt`) still resolves to one
  of them and the other file is told T0219 or T0060; narrowing the candidates to
  the file's own imports is per-file symbol selection, which the TIR resolver does
  by construction (`SymbolId`s; #8894, #8896). The alias rewriter's sibling-rename
  fallback (what turns a name only a sibling imports into T0219) cannot tell a file
  that sees the name another way without the declaration table (#8894), and the JVM
  rename maps are #8895. Phase 4 therefore retires `T0148` and `T0123` when it
  deletes those lookups.

2a and 2b can run in parallel; 2c needs both; 2d needs 2c. Release after.

Phase 2a status: positions name their file and packages assemble from
separately parsed files (steps 1-2), and every build path compiles the
assembled package, with the text merge and its line-origin table deleted
(step 3, docs/19 §4). Step 4 gave each file its own import scope in
warning mode: the checker builds one rule per file and checks each item in
its file's scope, aliases and renames rewrite per file, and a name a file
saw only through a sibling's import was the warning `W0032`; the compiler,
stdlib, ecosystem and examples were fixed to build without it. Step 5
(D300) makes it the error `T0219`. Candidates for a bare name are still
the union's, so a name two files import from different packages stays
`T0123`, and the cross-file `T0148` stay (`B0012` was retired by #8690, D346), until the passes that
read the union of the files' imports (plugin expansion, component glue, the
alias rewriter's synthesised items, MSIL and JVM lookups and the backends'
bare-name resolution) read each file's own or receive resolved symbols
(#8690, with 2c and 2d). Phase 2a is otherwise complete.

### Phase 3: TIR and the middle end

- **3a** the I0001 gate (moved from phase 1, D280); `Lyric.Tir` types, `Lyric.Tir.Verify`, `NodeId`s, the checker's
  per-node tables and the TIR builder (§6.3); type rules of §5 (`TyParam`,
  `TyInfer`, T0224, real builtin signatures, the §5.4 rules).

  Status: extern members are typed from host metadata and the silent non-callee `TyError` census of the compiler and stdlib is 0, with `tyErrorHost`, `tyErrorGeneric` and `tyErrorUnresolved` naming what is left unchecked (D354); the same census over every ecosystem library manifest, both targets, is 0 after D355 typed config field reads, enum and union cases named through their type or package, and package-qualified extern types, and named the erased generic and unresolved ones; the `TyParam(name, owner)` / `TyInfer(id)` split is in the checker's `Type` (D329); `TyParam` is rigid in `typeEquiv` and a call's arguments are checked against the signature instantiated from the call (D331; `TyInfer` and `TyError` are still wildcards), `TyParam.owner` is the declaring function, member, type or impl block for every signature, body scope and type declaration, with every site carrying its binder, an empty owner an I0001 internal error and `TyArray.sizeVar` a `TyParam` (D337, D343), T0224 is the error for an unpinned type argument of an imported generic call and Mono's `Object` default is deleted for ordinary generics (D335), `TyError` has the `TyError(diag: DiagId)` shape with `tyErrorFor`/`tyErrorSilent` (D340; construction sites record their diagnostic file by file), the polymorphic builtins have real signatures (D334), and the I0001 gate is the always-on error (the opt-in warning W0036 in D341, the error in D385; callee and qualifier positions exempt) after the last rules of D359 (an unsolved type argument is the named hole `tyErrorOpen`, extern `.new` binds the host constructor over a same-named Lyric type, host constants, conversions and protected-type field reads are typed, a generic distinct type's constructor takes its arguments from the value, a package path a local shadows is checked as the package's, and an unresolvable package-qualified read is T0020); the unchecked kinds that remain are named and inventoried by `rg` (at D385: `tyErrorHost` 8 sites, `tyErrorGeneric` 7, `tyErrorUnresolved` 13, `tyErrorOpen` 3), so growth in them stays visible. D357 types a distinct type's constructor call and D358 makes `.count` on a slice the error T0228. A temporary census of silent `TyError`s (D338) found 11,654 sites, about 90% callee positions, and decided Q-TIR-001 (I0001 always stops the build; callee positions exempt until the builder). D342 typed the first non-callee classes (qualified builtin calls, universal method results, `Map`/`Set` `.count`): non-callee silent sites 1,163 -> 386. D351 typed `default()` against its expected type (386 -> 355); D352 added host-hierarchy assignability for extern types (the bridge's `resolveBases`) and typed extern `.new` results: 355 -> 327. D360 recorded each expression's type per `NodeId` (`SymbolTable.exprTypes`) and added `Lyric.Tir.Build` with the `Type` to `Ty` conversion and the I0002 census (`LYRIC_VERIFY_IR=1`); D361 added the callee table keyed by the call's `NodeId` (`calleeByNode`, beside `calleeSites`) for calls to declared functions and a callee census; method calls and record and union-case constructors record theirs too, and the census ranks the rest; D362 records built-in functions and built-in members, collection members included, by name (`builtinByNode`); D363 covers primitive-receiver members, numeric conversions and dependency union cases, D364 marks calls through function values (`indirectByNode`) and records the `Result`/`Option` accessors and integer bitwise methods, D365 records method, interface, protected-type and extern member calls (by declaration span and `externByNode`), leaving distinct-type factories, `.copy` and a few host calls in the census; D366 is the expression builder's first slice (`buildFnBody`: literals, locals, operators, `if`, blocks and the structural statements, with an I0002 per kind it cannot build and a ranked census); D367 adds calls (`buildCall`: built-ins, function values and direct calls with arguments in parameter order and widening made explicit, from `callSigByNode`); D368 adds names that are not locals (`refByNode`: vals, consts, nullary cases and non-generic function values become `XGlobal` and `XConstruct`); D369 adds `match` and patterns (pattern types, resolved case and record symbols, and a sound exhaustiveness proof per `match`; or-, range, type-test and constant patterns stay counted); D388 adds record and union-case constructions (`ctorSigByNode`, shared argument placement, `XConstruct`); D389 adds method calls (`methodCallByNode`, `recvMode`, receiver-first `XCall` with a `Direct` or `Interface` callee); D387 adds extern member calls (`ExternIterResolver.resolveMemberSigs`, overload selection from the argument types, a `HostMemberRef` with the receiver first); D394 adds calls to generic functions from non-generic bodies (`genericArgsByNode`, substituted parameters, `Direct` with its type arguments); D395 builds the bodies of generic top-level functions (the function's own generics bound to its symbol); D396 adds annotated bindings and the implicit conversions derivable from two types (`convKindOf`: widening, `Never`, nullable lift, range check, unrefine); D397 adds record field reads (`XField` with the field's declared position); D398 adds assignments and index expressions (`TPlace`, `AssignKind`, `IndexKind`); D399 adds lambdas with their captures (`XLambda`, found while building); D540 assembles `TFnDecl`s and the declarations they reach and runs the verifier in the `LYRIC_VERIFY_IR` census (I0003 is 0 over every built stdlib test body tried); D541 lets a closed expected type settle a hole-bearing expression type and builds property reads, generic union-case constructions and explicit type-argument calls; D542 adds `lyric build --verify-ir` and the TIR census (`scripts/ci/tir-census.sh`, run by the `library-tyerr-census` CI job), which fails on any I0003 over the stdlib test programs; D543 builds qualified and static calls and `out`/`inout` arguments (stdlib test bodies built 809 -> 913 of 1165); D544 builds `val` of a pattern, `var x: T` without an initializer and `for` loops (range iterators as `XRange`) and has the checker's `val`/`for` binder record pattern types and binding nodes; D545 places a literal or constant default at a call that leaves the argument out (`ResolvedParam.dfltExpr`, parameter defaults numbered by `renumberNodeIds`); D547 places a record construction's literal or constant field defaults (the kind `a defaulted argument` is 0 over the stdlib census; a package restored from a DLL still has none, phase 4); D550 has the census print where each uncovered kind was first met; D551 records a package-qualified built-in call such as `Console.println(x)` as the built-in; the other callee routes, the instantiation, conversion and argument-order tables and the rest of the expression builder are open. An unsolved union-case construction is the error T0224 like an unsolved generic call (D353 reported it as the warning W0038, D381 made it the error and retired W0038); the checker reads the contexts that already fix one (D380: a `try`'s join, tuple and list elements, `?` operand branches, nested constructor fields, explicit type-argument calls, lambda bodies and their `return`s), and `Lyric.Mono`'s `ctorFill`/`importedFill` `Object` fills in result-type inference are deleted (D382). The checker reports T0224 for the unsolved type arguments of package-qualified and method calls too (D383), judges `@externTarget` generic calls (D356) and records the type arguments an expected type fixes; `Lyric.Mono`'s own T0224 backstop and `noteUnpinnedTypeArgs` are deleted (D384), an unrecorded unpinned imported call is an internal M0002, and its one remaining exemption is a function value (#8760 is closed). Members of generic records, generic protected types and generic `impl`s are `TFnDecl`s too (D579, calls D580, D582, D593): the owner's parameters are the member's leading type parameters (`TParam(member symbol, i)`, `typeParams` = the owner's then its own, `ownerParamCount` of them the owner's), so a call instantiates them like any generic call; a generic protected type's fields are fields of its receiver. An extern call's arguments widen as the host resolves overloads, so an integer argument to a `Float` or `Double` parameter is a `CvWiden` node (D600). A value passed to a host `object`, an `Int` or `Long` narrowed to a small host integer, and a `Float` passed as `Single` are `CvBoxToHost` nodes ranked below every widening (D597). A host property read is a call of its getter with the receiver first and a write a call of its setter (`HMPropertyGet`/`HMFieldGet`/`HMPropertySet`, D598). A host value passed as a host supertype and a `Byte` slice passed for a host array are `CvBoxToHost` arguments too (D599). A stdlib collection's `clear()` is the built-in member `List.clear`/`Map.clear`/`Set.clear` (D461). The fields of an opaque type read in its own package (D592). A bare field name in an `impl` method is a field of the receiver (D594). A member whose body does not build is still described by its declaration, as a body-less signature, not by a call site's instantiated one (D595). A function that yields is a `TFnDecl` with `isGenerator`: its `ret` is the yield type and its body is the generator's `Unit` code (D590); `s += x` on a `String` appends `toString(x)`, a bare sibling call is called on the enclosing `self`, and `default()` and `wrapping*` are builtins (D590). An or-pattern's alternatives bind the first alternative's locals, `@NAME` is `TpConst`, a shorthand record field is a typed binding, and an `inout`/`out` receiver is a place argument (D591). A constructor pattern names every field of its case (T0229, D480), so `TpCtor` carries exactly the sub-patterns written and the builder pads none. When names reorder a call's arguments, a name read before a later call argument is bound to a temporary in source order (D481). An opaque type is constructed by its fields inside its own package (D462: the checker records the construction signature, so `SqlText(...)`, `StringBuilder(host = ...)` and `SubsegmentHandle()` build).
- **3b** Declaration expansion before body check: derives and the weaver
  (§7.1).

  Status: designed in D370 (one `pipeExpandDeclarations` step before the check; generated nodes take allocator spans mapped back to the causing declaration until the tables are keyed by `NodeId`; slices S1 derives, S2 weaver wrappers, S3 templates and B′-mode, S4 cleanup). S1 (derives before the check) shipped in D390. The spans of generated nodes (the weaver's `synSpan()`/`noSourceSpan()` and the `isNoSourceSpan` guards, which need another marker for generated code) wait for S2 and S4, which need `NodeId`-keyed tables; the builder cannot replace them first (deferred 2026-11-12, #8613).
- **3c** TIR passes: contract elaboration (declaration step only; caller
  checks come in phase 6), propagation, typed lowerings, monomorphisation on
  TIR, await hoisting.

3b can run in parallel with 3a; 3c needs 3a.

### Phase 4: backends on TIR

- **4a** native, **4b** JVM (with the erasure pass of §7.3), **4c** MSIL.
  Each is a separate stream once 3c lands, and each deletes its inference,
  lookups and the legacy AST middle-end entry it used. When 4c lands, the
  AST middle end and the side tables are deleted.

  Status of 4a: started ahead of 3c, behind a switch. `Lyric.LlvmTir` lowers a monomorphic scalar function from TIR alone (D520: arithmetic, comparisons, checked division, `if`, `match` on scalars, `while`, `loop`, `for` over ranges, direct calls), `lyric build --target native --via-tir` builds the user file as a TIR package and splices the lowered functions over the AST lowering, and every function that stays on the AST path is counted with its reason. Strings are lowered with an explicit ownership model (D520, checked under AddressSanitizer); records, by value and in the heap with their destructors (construction, field reads, `.copy`; layout stays the code generator's, checked under AddressSanitizer), are lowered too, and so are non-generic unions (inline and heap, built and matched with bindings), string interpolation, matches on strings and floats, string indexing, enums, tuples (construction, destructuring and tuple patterns), closures (function types, lambdas with by-value captures, calls through function values), `out`/`inout` parameters, assignment to heap record fields, integer overflow checks (D163), the bundled standard library packages and project builds (every own package), and lists and slices of scalar and reference elements (literals, `newList`, `add`/`removeAt`/`clear`, `count`/`length`, indexing, element assignment, `for`, D520 slice 18) and `Map[K, V]` with `String` or scalar keys and `NativePtr[T]` types (D520 slice 19), and async functions with `await`, `spawn` and `scope` (D520 slice 20), and non-generic interfaces (upcast and plain-method dispatch, D520 slice 21); generic unions (until monomorphisation), calls into the standard library, arrays, interfaces and protected entries are the next slices; the AST path stays the default until the TIR path passes everything it does.

### Phase 5: package interfaces

- **5a** `Lyric.Iface` model, codec and `lyric interface dump`; producer
  validation (T0213) and the round trip. Can start after phase 2 for
  declarations; bodies need 3a's TIR types.
- **5b** Consumers: symbol table and TIR loaded from interfaces; linkage
  tables (§9.5) used by the backends ported in phase 4; hidden exports.
- **5c** Stdlib through interfaces on every target; JVM bundling of
  prebuilt stdlib classes; delete `ContractMeta*`, `RestoredPackages`
  synthesis and `stdlibSourcesFromCompiledBundle`.

Release after; republish the ecosystem.

### Phase 6: contracts across packages

- **6a** Contract entry points and caller-side checks (§10.2) on every
  target, with the blame message.
- **6b** Verifier: imported contracts, per-function level and proof status
  (§10.3); V0001/V0002 per function.

6a and 6b run in parallel. Release after.

### Exit criteria

The plan is done when: no backend contains a type inference or name lookup
function; `TyError` cannot reach the middle end; every package is consumed
through its interface; the compile-fail corpus passes on every target; and a
cross-package contract violation reports the caller's site and the callee's
clause on MSIL, JVM and native.

## 14. Diagnostics

| Code | Meaning |
|---|---|
| T0210 | a selective import names a declaration the package does not declare (shipped in phase 1; the "cannot infer" meaning formerly written here is T0224; T0222 is the bare-enum-case ambiguity of D312) |
| T0211 | a dependency's interface names a declaration that cannot be resolved (corrupt or missing dependency) |
| T0212 | a `pub` or `internal` signature names a less-visible type |
| T0213 | a carried body, default or contract references a declaration that is neither public nor a hidden export |
| W0033 | retired (D311): a name reached only through a whole import of a package that is not re-exported, the warning mode of §4.3's D141 change; such a name is now T0020 |
| T0224 | cannot infer a type argument; write it explicitly |
| T0219 | a name a file sees only through a sibling file's import (§4.1; the warning `W0032` until D300) |
| I0001 | internal: a `TyError` with no diagnostic reached the gate |
| I0002 | internal: the TIR builder found a node the checker did not record |
| I0003 | internal: a pass produced ill-formed TIR |
| I0004 | internal: a backend panicked on verified TIR |
| T0223 | a library's package interface cannot record a declaration (a type the checker did not resolve, `Self` outside an interface) |
| I0005 | internal: an interface did not round-trip |

Existing name codes (T0010, T0020, T0097, T0123, T0148) keep their meaning
and move to the resolver. `B0012` is retired with #8690 (§4.1).

## 15. Open questions

- **Q-TIR-001:** Should the `I` internal codes stop the build in release
  builds, or only in CI and `--verify-ir`? (Proposed: I0001, I0002 and
  I0004 always stop the build; I0003 verification runs only in CI,
  self-tests and `--verify-ir` for speed.) Resolved for I0001 in D338: it
  always stops the build, callee positions exempt until the TIR builder.
- **Q-TIR-002:** May a `@proof_required` caller assume the postcondition of
  a `RuntimeChecked` callee? It is sound for partial correctness; docs/08
  §10.4 currently forbids such calls.
- **Q-TIR-003:** Should a discharged precondition remove the runtime
  pre-check at that call site?
- **Q-TIR-004:** Is a file-private visibility tier wanted now that imports
  are per file?
- **Q-TIR-005:** An advisory `CallSiteChecker` plugin point for
  library-specific static checks (§10.4).

## 16. Relationship to other documents

- docs/19: §4 step 2 (the union of imports), the text merge, `B0012`, and §8's
  "no per-file visibility scopes" are superseded by §4.1.
- docs/45: phases 2-5 are superseded by §9; phase 1's v3 emitter is deleted
  with `ContractMetaEmit`.
- D141: the transitive bare-name rule and transitive qualified reach are
  superseded by §4.3.
- docs/41 (self-hosted gap analysis) and docs/59 (deep review): the
  "backends bypass the middle end" and "MSIL/JVM duplication" findings are
  addressed by §6-§8.
- docs/08: §6.1 failure reporting (§10.2) and §10.4's application across
  packages (§10.3).
