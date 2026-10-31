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

Verified with a fixture project covering a top-level `pub val`, a union, a
generic record and a merged test module, and on nichobbs/cloud-agents' 70
entries against a live Postgres; see the PR for timings.
