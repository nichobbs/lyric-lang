# JVM dot-named method mangling and cross-package derive signatures (#7501, #7502)

Two `@generate(Json)` records (or any two hand-written dot-named functions
with the same member name and parameter list) in one package now load on
the JVM: the backend mangles a dot-named function's classfile method name
into `TypeName$member` — matching the existing `Type$Case` union-case-class
convention — instead of the bare member name alone, which previously
collided across different types on the package's shared host class
(`ClassFormatError: Duplicate method name`). A synthesised per-type static
(a distinct/range-subtype's `from`/`tryFrom`, a wire factory's accessor)
lives on its own dedicated class already and keeps its plain method name.
Which case a call site is looking at is decided at REGISTRATION time —
`JvmFuncSig.jvmMethodName` records the exact classfile name — not guessed
from owner/receiver-name comparisons at the call site: an owner-comparison
heuristic was tried and rejected once it turned up a narrow but genuine
false positive (a package whose own last dotted path segment matches a
type it declares), pinned by the new
`dot_named_mangle_owner_match_jvm_self_test.l`.

Calling a `@generate(Json)`/`@derive`-synthesised function from a DIFFERENT
project package (`Person.fromJson(body)` with `Person` imported) now
resolves and decodes on the JVM: `Jvm.Bridge` pre-registers every
bundled/sibling package's derive-synthesised signatures via a lightweight
`Lyric.Derives.deriveFile` pass before the user's own entry package is
codegen'd, closing a gap where the entry package's own codegen ran before
any sibling's derive signatures were ever registered. The decoded `Result[T,
String]`'s `Ok` payload also no longer needs an explicit type annotation to
narrow correctly on a later `match` — `collectDeriveFreeSigs` now eagerly
resolves a derive-synthesised function's declared return-type generic args
against its own package, exactly like every other free-function
registration already does.

Nested `@generate(Json)` decoding (which needs two records, and therefore
needed the mangling fix) now works on the JVM;
`lyric-stdlib/tests/json_generate_tests.l` runs on `--target jvm` in CI
(`scripts/ci/json-generate-jvm-test.sh`) alongside its existing
`--target dotnet` run, both unmodified. See D-progress-1020 for the full
design, disambiguation rules, and verification list.

Verified: `lyric-compiler/jvm/derive_dot_name_mangle_jvm_self_test.l` and
`lyric-compiler/jvm/dot_named_mangle_owner_match_jvm_self_test.l` (both new,
wired into `scripts/ci/jvm-generics-self-tests-batch.sh`),
`scripts/ci/derive-json-cross-package-jvm-e2e.sh` (new, wired into
`scripts/ci/compiler-self-tests-batch.sh`, both dotnet and jvm),
`json_generate_tests.l` and `json_tests.l` on both targets, the full
`compiler-self-tests-batch.sh`, `jvm-generics-self-tests-batch.sh` (0
`not ok`), and `jvm-ecosystem-suites.sh`.

A separate, pre-existing gap found along the way — `Jvm.Codegen.
scrutineeGenericArgs` has no `EPropagate` (`?`) arm, so an unannotated `val
p = someCall(...)?` binding still fails JVM codegen with J007 on a later
field/method read — is tracked separately as #7630, not part of this fix.

Docs: docs/18-jvm-emission.md §11.6 (new), docs/decisions/D-progress-1020.
