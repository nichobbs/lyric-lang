# D336 - The checker's resolved callee reaches the backends per call site (docs/70 phase 2d, #8612)

**Status:** shipped for MSIL bare and package-qualified calls; the other
backends and the deletion of the name tiers follow (see Consequences).

## Context

After 2c every name question of the checked package is answered by
`Lyric.Resolve`, but the backends re-answer them: MSIL's bare and qualified
call lowering walks a chain of its own tiers (`originFqn`, the local package,
`findBareImportedFqnMsil`, `findBundleFqnByName`) over a bundle-wide
name-to-FQN map, and the JVM and native bridges have their own. A checker change
that narrows a name's candidates therefore still miscompiles, and
a bare name two files import from different packages stays T0123 (#8690).
An audit of the compiler's own build found the class is real: `Lyric.LlvmBridge`
called `isLiteralInit` and MSIL bound it to the package-private function of that
name in `Lyric.TypeChecker`, not the `pub` one the checker and the resolver
chose; `Jvm.Bridge` did the same with `funcBodyContainsYield`.

docs/70 §13 (2d) asks for the callee `SymbolId` per call through the existing
`MiddleEndOptions` channel. Phase 4 replaces that channel with TIR (`Callee` in
`Lyric.Tir`), so this is the smallest form, not a second IR.

## Decision

1. **`SymbolTable.calleeSites: Map[String, String]`.** For each call whose
   callee is a bare or package-qualified path, or a member of a package
   (`Pkg.f`), the checker records the rendered DefPath of the declaration the
   call resolved to (`Pkg::name(P1,P2)`, `Lyric.Resolve.funcDefPath`, the key an
   interface artifact records), under `Lyric.Parser.methodCallSiteKey` of the
   callee: the key the backends already share for method calls. The signature
   is matched to its declaration by span; a dependency's signature, whose
   spans no declaration of the checked package has, takes the one same-named
   function of its package with its parameter count (a bare or path callee
   only). A call with no such declaration (a built-in, a dot-named type
   function, an extern member) records nothing.
2. **`MiddleEndOptions.calleeSitesOut`** receives it from `pipeCheckAndMono`,
   as `methodCallAritiesOut` does; each bridge hands one package's map to its
   code generator, whose spans mean something only within that package.
3. **MSIL binds a call to its site first.** `sitedCalleeFqnMsil` returns the
   recorded function when its name is the callee being lowered (a call a later
   pass renamed, such as a monomorphised copy, does not match) and the bundle
   has it. It comes before every other tier, in the static-call path and in the
   package-member path (`Pkg.f`, `Alias.f`), where it replaces the alias
   lookup.
   The site names the declaring package and function, not an overload: the
   backend still picks among a package's overloads of that name by the
   checker's resolved arity (`methodCallArities`, #7828) and its own argument
   matching, as before. The DefPath's parameter list is recorded for
   phase 4, where `Callee` carries the full identity.
   A call's site is keyed by its span alone for a path callee, so a call Mono
   renames to a specialisation (`f` to `f__Int`) keeps it; MSIL then looks the
   specialisation up in the declaring package, then the calling one. A
   specialised copy of another package's generic carries that package's spans
   and never consults this package's sites.
   A call through a type, `Type.f(x)` or the constructor shorthand
   `Type.new(...)`, records the dot-named function (`Type.f`, registered under
   that name in its declaring package) the same way, found in a dependency by
   name and arity; MSIL routes it through the site, ahead of the import-order
   search for `Type.f`.
4. **MSIL's bundle-wide name search is deleted.** `findBundleFqnByName` and
   `bundleFuncFqnByName` are gone. The calls that still reached it were the
   `println` / `print` builtins (now an explicit rule: the function in scope,
   else `Std.Console`), the async pre-scan's duplicate of the call resolution
   (`resolveQualifiedFreeCallRetTypePB`, now given the call's site key), and a
   default expression spliced from another package: a function's defaults are
   lowered in its callers' packages but mean the declaring package's names, so
   each package registers its defaults qualified with its own recorded
   callees (`qualifyDefaultCalleesMsil`), and the bridge loads a package's
   sites before registering its tokens.
5. **The JVM binds a call to its site first too.** `calleeSitesOut` reaches the
   JVM bridges as `~callee~<site key>` seed entries (as `~arity~` does) and
   `Jvm.Codegen.siteFuncSigJvm` looks the function up under the declaring
   package, or for a Mono specialisation under it or the calling package,
   before the bare-name keys. The bare-name keys stay: a census of the JVM
   self-tests and the session, cache and auth libraries finds 888 calls still
   resolved by name without a site (the `println` builtin, 724; synthesised
   `__lyric_checked_*` helpers and the weaver's `__aspect_target` and
   `__lyric_bmode_*` names; specialisations inside another package's generic
   bodies; and a few functions whose site is not recorded, `get`,
   `setWithTtl`, `verifyApiKey`), each tracked on #8612.
6. **MSIL's bare-import search (`findBareImportedFqnMsil`) is deleted.** It
   was kept for the calls the checker recorded no callee for: a call spliced
   from an aspect library template into the caller, a call the weaver
   synthesises, and a call inside an imported generic whose declaring package
   recorded none. Phase 3b weaves before the check (D390-D392), so the first
   two have sites like user code; the third was a keying bug (item 9). The
   import search had also been computed for every call whatever won; it is
   reached now only for the calls nothing above resolved, and a census over
   every `TEST_EMITTER_FILES` self-test and 24 ecosystem libraries found it
   used by none.
   What is removed: `pkgImportAliases` and the pre-scan's alias candidates (an
   alias-qualified call binds through its site), and the origin-scoped import
   search is reached only after the site. A body specialised from another
   package's generic reads that package's sites, kept bundle-wide under
   `<package>|<key>` (`CodegenCtx.originCalleeSites`, as arities and receiver
   classes are).
   A default expression (a function parameter's, a record field's) is lowered
   in whichever package calls the function or builds the record but means the
   declaring package's names. A callee in the declaring package is qualified
   from the package's sites when the default is registered; any other bare
   callee is resolved when the default is fetched, in the declaring package's
   own scope (its functions, then the imports its contract records,
   `CodegenCtx.defaultDeclPkg`), which also covers restored and stdlib
   packages, whose defaults have no sites. `emitter_project_self_test.l` has a
   record field default calling a function of its package.
7. **A re-check in an origin package's scope uses that package's imports.**
   A specialisation of another package's generic is checked as if inside its
   declaring package (`Lyric.Pipeline.checkInOriginScope`). Two things leaked
   the consumer's scope into it: `addOriginScope` made every import of the
   origin a whole import (losing `import P.{g}`), and the check file carried
   the consumer's per-file header table, from which the resolver builds the
   file scopes, so the origin's bare `pick()` saw the consumer's `EPOs.P` as
   well as its own `EPOs.Q`, reported T0123, and recorded no callee. The origin
   check now uses the package's declared imports (`ImportedPackage.importDecls`)
   and an empty header table. This corrects the scope of every `foreign*`
   re-check (callee sites, arities, receiver classes, unit lambdas). The JVM
   reads these as `<origin>|<key>` entries (`foreignCalleeSites`,
   `Jvm.Codegen.originScopedExternTypes`). `emitter_project_self_test.l` has
   the selective-import and same-named-export cases on both targets.
8. **The JVM resolves a call by its site, its package's scoped key or its
   qualified key, and no longer by a bare name.** `resolveGeneralFuncSig` is
   `resolveGeneralFuncSigExact`: the checker's site, then `<package>::<name>`
   (a package-private function included), then the `Pkg/name` key of the
   qualified path. A default expression is lowered in whichever package calls
   the function or builds the record but means the names of the package that
   declares it, so `Lyric.Pipeline.pipeCheckedDefaults` (which checks a bundled
   package before the entry package's code is generated) writes each bare call
   of a parameter or field default as the callee's package-qualified path,
   from the checker's sites (`qualifyCheckedCallees`, #8850). A plain function
   has no bundle-wide bare key any more: `closureInvokeRetType` and
   `funcSigRetType` read its signature through `resolveGeneralFuncSig` too. A
   dot-named function (`Type.member`) kept its bare dotted key for the
   member-call lookups until item 10, and the package overlay (`importAwareRegistry`) now
   re-points enum cases and module vals only. The `println`/`print` and
   collection-intrinsic override check (`hasFuncOverrideJvm`) uses the same
   exact stage: a `Std.*` result never overrides an intrinsic, so a user
   function overrides one only when its site, its own package's scoped key or
   a qualified path names it. A census over the JVM self-tests
   (`lyric-compiler/jvm/`, bitwise, aspect-weave, async-spawn, block-shadow,
   pattern-lowering, the kernel tests) and the auth, cache, validation,
   resilience and mq libraries found the bare keys needed for: a specialised
   generic's call (Mono's renamed callee carried the whole expression's span,
   not the path's the checker keyed the site by), a specialisation and a
   weaver-synthesised function registered without the package-scoped key, the
   intrinsic override check, and, until phase 3b, the calls spliced from an
   aspect-library template (`checkRetryConfig` in `lyric-resilience`). Mono's
   renamed callee now keeps the path's span (`renamedCalleeExpr`), which also
   makes MSIL's sites for alias-qualified generic calls hit, and both
   registrations add the scoped keys.
9. **Sites for a body specialised from a package outside the bundle.** A
   consumer that specialises a restored or prebuilt package's generic (a test
   package over a built library) records that body's callees by re-checking the
   generic in its declaring package's scope (`foreignCalleeSites`, item 7),
   under `<origin>|<key>` in its own `calleeSitesOut`. The MSIL bridge prefixed
   every entry with the consumer's name again, so none was found and the
   import search answered (147 calls in `lyric-ui` alone); an entry whose key
   already holds `|` is kept as it is. The re-check also checks the generic as
   written, not a specialisation, whose type arguments name the consumer's
   types (T0010).

10. **The JVM's dot-named functions and bare function values no longer use
   bundle-wide bare keys.** A call through a type, `Type.f(x)`, binds by the
   checker's site first (`siteDotNamedSigJvm`: the rendered
   `Pkg::Type.f(...)` names the declaring package, whose `pkg/Type.f` or
   `pkg::Type.f` key answers), then the calling package's scoped key. A
   function (a dot-named one included) registers no bare key; only a wire
   factory (`AppWire.bootstrap`), which is not a function and has no checker
   site, keeps its `Wire.method` key. The `bareref:` marker of a same-package
   function used as a value is keyed `bareref:<package>::<name>` and read with
   the calling package. `~byref~<name>` stays name-keyed on purpose: it only
   decides whether a `var` argument gets a heap cell (never which function a
   call binds) and runs before any call is resolved.

   A call whose callee has no recorded site (a dependency package compiled
   without one, or a default lowered in another package) binds through the
   file's import-scoped type map (`typeOwnerDotNamedSigJvm`: `externTypes[Type]`
   names the declaring package, so `Std.HttpHost`'s `Identity.rawHandle` binds
   to `Std.Tls`), never a bundle-wide name. The rendered callee is
   `Pkg::Type.member(P1,P2)`; `siteDotNamedSigJvm` and `qualifiedCalleeSegments`
   (in `Lyric.Pipeline`) both read it by splitting at `::` and `(`.
   `qualifyCheckedCallees`, shared by both backends, writes a dot-named callee
   of a default as `Pkg.Type.f` the way it writes a bare one, and leaves a call
   on a local (`w.f(x)`) alone because only a `Type` receiver has a site. Two
   packages that each declare a same-named type with a same-named dot-named
   function still bind by the checker's choice of callee (#8874).

   Verified by the compiler-self-tests-jvm files (all but two that need CI's
   `LYRIC_FFI_JARS` fixture and `config_block` environment variables),
   `emitter_project_self_test.l` (a default calling a dot-named function of a
   package only its declaring package imports, MSIL and JVM) and
   `multi-file-package-merge-e2e.sh dotnet jvm`.

## Consequences

- A bare call resolves to what the checker resolved, whatever the bundle holds
  under that name: the two silent mis-bindings above are fixed
  (`msil_project_bridge_self_test.l`, "a bare call binds to the checker's callee").
- No source changed: the full stdlib, compiler and ecosystem bundles build and
  every self-test passes.
- The JVM and native bridges receive the same map and still use their own
  lookups; each backend is a separate slice, as docs/70 §13 plans.
