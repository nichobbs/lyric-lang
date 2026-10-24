# Restored contracts resolve bare names through their own `Std.*` imports (#7668)

A project depending on a library whose `pub` signatures name a stdlib type bare (for example `Lyric.Search`'s
`esParseIndexResult(elem: in JsonElement)`, reached through the library's `import Std.Json`) failed to build with
`synthesised contract source did not type-check ... unknown type name 'JsonElement'`.

The standalone contract recheck in `Lyric.RestoredPackages.synthesiseArtifact` renders no imports and loads no
stdlib, so it tolerated bare names only from a fixed anchor list. It now also accepts a bare `T0010` when the
contract's recorded imports cover the name: any whole `Std.*` import covers every bare name (the recheck cannot tell
which package supplies it), and a selective `Std.X.{Name}` import covers just `Name`. A contract with no such import
still reports the error.

Tests: three cases in `restored_packages_self_test.l` (whole import, selective import, and the rejecting cases: no
import, non-`Std` import, selective import of a different name).
