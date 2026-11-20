# docs/70 phase 3a: carried defaults of protected types and executables, host calls the metadata cannot resolve (D615, D616, #8613)

The census over the tail self-tests, run on a container with the Maven resolver built and lyric-web and lyric-ws restored as CI does, left no `Ws.Kernel.Jvm` or `Web.Kernel.Runtime` body unbuilt: the 26 earlier ones were the self-test's build lacking the jars.

- D615: a protected type's field initialisers are its fields' defaults and are written to the package interface (`IfDRecord` for a protected type, as the model describes); an executable's interface is built and embedded too, so the compiler's own `Lyric.Cli`, imported by its self-tests, carries the defaults of `ResolvedManifestDeps` and the rest. `interface-embed-e2e.sh` checks it.
- D616: `toString`, `hashCode` and `equals` on a value of an `extern type` the metadata cannot locate are the root object's members; `new` on an abstract class, a call of an unknown member and a field read on a located class that has none are rejections under the backend's own `J005`, `J008` and `J009`, marked `rejected` in the census, not unbuilt bodies.
- D617: a native project build shares one store of carried defaults across its packages.
- D618: `?` of an `if`, `match` or block whose every branch fails, members of a value that never exists, `item = None` into a generic protected field, and a protected entry's parameter defaults (numbered by `mapFileNodes`).
- D619: a `val` of another package takes the type its interface recorded; a bare case name the package declares exactly once is its own; `lyric-validation` annotates two accumulators.
