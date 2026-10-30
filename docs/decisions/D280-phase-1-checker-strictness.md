# D280 - Checker strictness on the current architecture (docs/70 phase 1, #8611)

**Status:** shipped. Implements docs/70 §13 phase 1 (D267), except the I0001
gate, which moves to phase 3 (below).

## Context

docs/70 §1 traced the "the checker accepts it, a backend fails" class to
structural causes that phases 2-6 remove. Phase 1 closes the cheapest holes
on the existing checker first, each reproduced by a compile-fail case that
passed the checker on both targets before this change (three compiled; the
fourth failed only in each backend's code generation, T0115 on MSIL and J008
on the JVM).

## Decision

1. **T0211: a dependency whose surface does not resolve is an error.** Each
   imported package's signatures and impls resolve under its own scope; the
   first error is reported once per dependency, naming it, instead of being
   collected in a discarded scratch list (`importedDiag`, `implDiag`) and
   leaving `TyError` in the signature.
2. **Visibility checks know the declaring package.** `checkImportedVisibility`
   no longer reports T0097 for a package's reference to its own private
   type while its signatures and impls are registered. Measured before the
   change: 27 such false reports per check (every `impl` of a private type in
   `Std.Plugin`, `Std.PluginWasm`, `Std.JsonRpc` and others), all discarded.
3. **Method calls on a union bind only visible functions (T0113).** A method
   call on a union, `Option` or `Result` value is accepted as a call of a plain
   function by its first argument only when the file can call that function
   bare; a function of that name in a package the file does not import no
   longer makes the call valid.
4. **Qualified types resolve in the named package (T0014).** `Pkg.Widget`
   resolves to a type `Pkg` declares or re-exports through its imports; a
   qualifier naming another package, or none, is T0014 instead of resolving to
   whatever visible `Widget` the last segment matches. A host namespace on an
   extern type, and an import alias in a dependency's own (not yet
   alias-rewritten) signatures, are accepted.
5. **An uppercase receiver naming nothing is T0020 at check time.** A dotted
   call whose receiver names no declaration, package, import alias or generic
   parameter is reported by the checker.
6. **T0212: exported signatures name only exported types (#7214).** A `pub`
   or `internal` declaration's exposed types (parameters, return, record
   fields, union payloads, interface method signatures, distinct underlying,
   alias target, `pub val`/`const` type, at any depth) may not name a type of
   its own package that is less visible, checked against the declaration's
   effective visibility (a method in a type body and a dot-named `func T.m`
   reach no further than `T`). Language reference §3.1's sentence that a `pub`
   signature "may mention a package-private type" is withdrawn. Thirteen
   files in the stdlib (the HTTP/2 engine and three kernels), `lyric-ws`,
   `lyric-draw`, the native `lyric-ui` host, two examples, a `lyric-game` test
   and one self-test's embedded programs exposed such types through `pub` record fields or
   signatures; each type is now `pub`, since its values were already
   reachable through the exposing declaration.
7. **The LSP checks against named packages.** It passed every imported
   workspace package as one package with no name, which made every name of a
   selectively imported package visible bare and bypassed T0097; each
   workspace package now keeps its name and imports, as in `lyric build`.
8. **A compile-fail corpus.** `lyric-compiler/lyric/testdata/reject/` holds
   projects that must fail `lyric check` with listed codes on dotnet and the
   JVM; `scripts/ci/reject-corpus.sh` runs it in CI (docs/70 §11).

## The I0001 gate moves to phase 3

docs/70 §5.3 put the gate (a `TyError` with no diagnostic stops the build) in
phase 1. Instrumenting the checker over the compiler's own packages found
11,561 `TyError` results with no error reported, the large majority from
callee expressions in call position (a function or constructor name is
typed `TyError` and the call itself is typed from the signature) and from the
documented leniencies (polymorphic builtins, extern members). A gate on the
current checker would fire on valid programs, and removing those sites one by
one is the work phase 3's TIR builder does structurally: TIR has no error
type, so a node the checker left untyped is I0002 there. The gate lands with
phase 3a (#8613).
