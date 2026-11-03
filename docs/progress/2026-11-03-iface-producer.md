# Interface producer: `Lyric.IfaceBuild` (docs/70 phase 5a, D327)

Third slice of phase 5a: `buildIface` builds a package's `Iface` from its
type-checked source, converting the checker's resolved types to `Lyric.Tir.Ty`
and taking DefPaths from the resolver's helpers. Records every `pub` and
`internal` declaration with generic parameters and bounds, signatures, fields,
cases, range subtypes, constants, extern types, methods and interface members.
`MiddleEndOptions.buildInterface` builds it from `pipeCheckAndMono` (off by
default). File-level `@axiom` joins the verification levels (format version 3).
Covered by `iface_build_self_test.l`. Embedding, I0005 and T0213 follow; see
D327 for what is not recorded yet.

Embedding (MSIL): a .NET library build embeds its interface as the
`Lyric.Interface.<Pkg>` resource after the producer's write, read back and
compare (I0005); an unrecordable library declaration is T0223. `lyric interface
dump` reads assemblies. `scripts/ci/interface-embed-e2e.sh` runs in the compiler
self-test batch. JVM and native embedding follow.
