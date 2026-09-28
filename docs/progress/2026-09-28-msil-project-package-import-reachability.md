# MSIL project builds report unimported qualified references (#7583)

In a multi-package `[project.packages]` build, `--target jvm` rejected a
qualified reference into a project package the file does not import
(`Lib.Net.Rest.someVal`, `val w: Lib.Net.Rest.Widget`, `Lib.Net.Rest.ping()`)
with T0020, as D-progress-1011/1012 require, while `--target dotnet` built
it silently.

The type checker's reachability check (`checkQualifiedPackageRef`,
`checkQualifiedTypePackageRef`) only fires for a package whose symbols are
registered, the same way every stdlib package is always registered and the
check decides visibility. `Jvm.Bridge`'s project path registers every
project package for each package's check (#6024). `Msil.Bridge`'s
`perPackageImportedPackages` registered only the packages in that package's
own import closure, so an out-of-closure project package had no symbols and
the check never ran.

`perPackageImportedPackages` now registers every in-bundle project package
(with its imports and whole imports), matching the JVM. Registration does
not widen what a file can name: bare names follow the file's own import rule
(D141, #7535) and qualified references into unimported packages are T0020.

Fallout: `lyric-otel/tests/otel_types_tests.l` used `SpanKind`/`MetricUnit`
from `OTel` while importing only `OTel.Types`; it now imports `OTel`.

New `scripts/ci/project-package-import-reachability-e2e.sh` (run from
`compiler-self-tests-batch.sh`) builds manifest projects on dotnet and the
JVM: unimported qualified value reads, type annotations and calls into a
project package are T0020 on both; the imported forms build and return the
right value on both; and a bare call whose name two sibling packages
declare resolves to the imported one on both (#7592, covered by D141).
