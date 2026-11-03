# D331 - A type parameter is rigid: `typeEquiv` no longer treats `TyParam` as a wildcard (docs/70 phase 3a, #8613)

**Status:** shipped. Step 2 of the docs/70 §5 type rules, after D329 (the
`TyParam`/`TyInfer` split).

## Context

Until now `typeEquiv` accepted a `TyParam` against any type, because the
checker compared a callee's own uninstantiated parameter types against the
call's argument types and relied on the wildcard to make that succeed. The same
leniency let a generic value flow wherever a concrete type was wanted.

## Decision

1. `typeEquiv` treats `TyParam(name, owner)` as equal only to a `TyParam` of
   the same name and owner (and to the holes `TyError` and `TyInfer`, which
   stay wildcards until the unsolved-variable step). `TyParam` against any
   other type, a value generic's `TyLen` included, is a mismatch.
2. A call's arguments are checked against the callee's signature instantiated
   from the call (`instantiateSigForArgs`): the type arguments the arguments
   bind replace the callee's parameters, and a parameter no argument fixes
   becomes `TyInfer`, the hole it always was, named. This is the migration of
   the one place the old leniency was load-bearing; the 17 checker cases that
   failed under the rigid rule all passed once it was in.
3. Source migration (docs/70 §12.2, in the same form the seed also accepts):
   the JVM reflection helpers `invoke1`-`invoke4` in
   `_kernel_jvm/http_host.l`, `_kernel_jvm/http_server.l` and
   `tests/tls_server_jvm_tests.l` put generic arguments into a
   `List[JObject]`. They now fill a `java.util.ArrayList` through the extern
   boundary, which takes any value (null included) and still yields a real
   `Object[]`.
4. **Correction to D329 item 4.** The "cannot infer a type argument"
   diagnostic is **T0224**. D329 named T0222, which D312 had already made the
   bare enum-case ambiguity (docs/01 §9.2, live on MSIL, JVM and native); the
   check missed it because it searched only `lyric-compiler/lyric/`. T0210
   stays the selective-import error, T0223 belongs to the package-interface
   work, and docs/70 §5.2, §13 and §14 now say T0224.
5. `owner` is still `""` at every construction, so two nested declarations
   that each bind a `T` compare equal. Threading the binder through
   `GenericContext` is tracked in #8747; it can only make more programs
   distinct, never fewer.

## Consequences

User-visible: a generic value is no longer accepted where a concrete type is
required (docs/01 §2.11). The census (`lyric check` over the manifests that
build here, the stdlib tests, the checker's 1063 cases, and CI for the
targets and platforms that do not) found the three migrated files.
