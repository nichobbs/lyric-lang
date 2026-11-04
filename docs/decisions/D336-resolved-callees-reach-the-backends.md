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
4. **The name tiers stay for the calls with no site.** They are not deleted
   here: a census of the stdlib, compiler and ecosystem build shows the calls
   still without a site are builtins (`println`), dot-named type functions
   (`IOError.message`, `StringBuilder.new`) and monomorphised specialisations.
   Each needs the channel extended (mono recording the specialised callee's
   site, a site for a type-qualified call) before `findBundleFqnByName` and
   `findBareImportedFqnMsil` can go, which is tracked on #8612.

## Consequences

- A bare call resolves to what the checker resolved, whatever the bundle holds
  under that name: the two silent mis-bindings above are fixed
  (`msil_project_bridge_self_test.l`, "a bare call binds to the checker's callee").
- No source changed: the full stdlib, compiler and ecosystem bundles build and
  every self-test passes.
- The JVM and native bridges receive the same map and still use their own
  lookups; each backend is a separate slice, as docs/70 §13 plans.
