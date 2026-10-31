# `lyric test` compiles a project's library once per run (#8648)

Project-mode `lyric test` used to compile every `[project.packages]` package
together with each `[project.tests]` entry, so a project with N entries
compiled its library N times. On nichobbs/cloud-agents (93 packages, 70
entries) that was ~37 s of compile per entry and ~44 minutes per run, with
under a second of tests in each.

On `--target dotnet`, `cmdTestManifest` now compiles the library once, into
`.lyric-test/LyricTestLibrary.dll` (a stem no entry uses), the first time an
entry needs it. Each entry then compiles only its synthesised test package,
with the library as a restored dependency (the path a workspace or path
dependency already takes) and the library's sources as template sources, so
aspect, wire and plugin templates still resolve. The library's diagnostics,
warnings included, print once instead of once per entry; if it fails to
compile, every entry that links it fails with a message that points at them.

Linking never changes a result. Before compiling an entry linked,
`cmdTestManifest` type-checks the linked form (`Emitter.typeCheckProject`,
which collects diagnostics instead of printing them); if that reports an error,
or the linked compile itself fails, the entry is compiled with the library as
before and a `note:` line gives the reason. The known case is a `pub val` with a
non-literal initializer, which a restored assembly does not carry (#6133): read
bare it fails the type check, read qualified it is a codegen-time T0115 (whose
message the emitter has already printed). A real error in the test module
surfaces from that full compile exactly as before.

Restored packages: a package whose contract names a type of another package
in the same restored set by its qualified path, such as
`pub alias TenantScope = CloudAgents.Scope.TenantScope`, failed to synthesise
("unknown qualified type", T0014). The standalone re-check sees sibling types
only through a flattened, unqualified preamble, which cannot resolve a qualified
path (and leaves out a sibling type whose name the package also declares).
`Lyric.RestoredPackages.synthesiseArtifactAmong` takes the sibling package
names, and that T0014 is left to the consumer's full type check, which sees the
sibling's items, as the qualified `Std.*` case already was. The emitter passes
the siblings on both targets; `synthesiseArtifact` keeps its signature. Any
multi-package restored assembly with such a reference (a path dependency as
well as the test library) was affected. Covered by two new cases in
`restored_packages_self_test.l`.

Unchanged: an entry that declares the package of a `[project.packages]` entry
is merged into that package and needs its non-`pub` items, so it still compiles
the library with it, as do doctests (merged the same way) and every entry on
`--target jvm`, where dependencies are compiled from source into each bundle
(#6750).

Restored extern types: a restored package's `extern type` declarations were
never registered in the consumer's `externTypeNames` (only the stdlib's were,
#1602), so a `pub func` returning or taking one, such as
`pub func newTable(): Hashtable` over a package-private
`extern type Hashtable = "System.Collections.Hashtable"`, was encoded as
`object` in the consumer's MemberRef and failed at run time with
MissingMethodException. The restored-artifact pass in `Msil.Codegen` now
registers them, first-wins as the stdlib path does. A path dependency hit the
same failure.

Restored enum cases: a bare enum case with no expected enum type in scope
resolved to the first-registered enum with that case name. In a bundle the user
packages' enums register before the stdlib's; with the library restored,
`Std.File.EntryKind.Other` registered first, so `categoryToString(Other)` in
`examples/product-catalog` passed that ordinal. A restored function now records
its parameters' enum types (`funcParamEnumTypeNames`, as an in-bundle function
does), and `resolveBareEnumCaseOrdinalByScope` resolves a bare case to the
current package's enum, then an imported package's, before falling back to
registration order. A path dependency had the same exposure.
Match patterns (`case Other ->` and `case Kind.Other ->`) on a scrutinee
whose enum type is unknown, such as a field of a restored record, now use the
same resolution. Before, an expression resolved the case by scope and the
pattern by registration order, so `lyric-forms/derive`'s
`case Error -> failed = true` never matched a `severity = Error` it had just
built.

Restored distinct types: only the `value` field was registered, so
`Score.from(40)` on a restored `Score` lowered to the unresolved-call stub.
`registerRestoredDistinct` now also registers `.ctor`, `from`, `tryFrom` (when
`Result` is seeded) and the `toX` conversion, with the signatures
`lowerMDistinctType` emits.

Restored invariants: the contract `repr` of a record or opaque type carries no
`invariant:` clauses, so a consumer constructed a restored invariant-bearing
type unchecked (`lyric-health`, `lyric-session`). For an imported record or
opaque type the type checker now wraps construction when the declaring package
exports `__lyric_checked_<Name>`, which is synthesized only for a type with
invariants. A path dependency had the same gap.

Unresolved calls: code generation lowers a call it cannot bind to a throw of
"unsupported method '...'" instead of failing the build. A linked entry whose
assembly contains that stub is compiled again with the library, with a note,
so a restored-package gap of that kind costs time instead of changing a
result (`lyric-testing`'s mocks called through restored interfaces).

Verified by `scripts/ci/test-runner-project-mode-e2e.sh` (a fixture covering a
literal and two non-literal `pub val` reads, a union, a generic record, a
merged module, an extern type in `pub` signatures, a library that does not
compile, and jvm), `restored_packages_self_test.l`, and nichobbs/cloud-agents'
73 entries against a live Postgres: all pass, the two that read a non-literal
`pub val` compiled with the library. On the same machine the run took 24
minutes against ~88 minutes before (about 20 s an entry after a one-off ~70 s
library build, against ~72 s an entry).
