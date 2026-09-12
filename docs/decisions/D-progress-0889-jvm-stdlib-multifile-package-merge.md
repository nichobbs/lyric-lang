# D-progress-889 — JVM codegen: a package assembled from more than one bundled stdlib source file now codegens ALL of them into one class instead of silently dropping one file's methods (#5932)

**Status:** shipped

**Context.** Every existing multi-file `_kernel_jvm/` split in the stdlib is
mutually exclusive BY BASENAME — `_kernel_jvm/http_server.l` REPLACES
`_kernel/http_server.l` for the same package, never adds alongside it.
Introducing a package assembled from BOTH a top-level `lyric-stdlib/std/
<pkg>.l` (always loaded) PLUS a distinctly-named, additive `_kernel_jvm/
<other>.l` declaring the SAME `package` (the natural way to add a JVM-only
extension to an existing stdlib package without touching its shared file)
compiled cleanly — the type checker accepted declarations from both files
without complaint, and cross-references between them resolved fine — but at
runtime, a PRE-EXISTING, unrelated, unmodified call site in the FIRST file
broke with `NoSuchMethodError`, purely from the SECOND file's mere presence.

**Root cause.** `Jvm.Bridge.compileProjectToJarBundledWithRestored`'s
stdlib-parsing loop populates `stdlibByPkg: Map[String, SourceFile]` with a
FIRST-WINS guard (`if pn.length > 0 and not stdlibByPkg.containsKey(pn)`).
This map feeds BOTH the transitive-import reachability walk AND the
per-package codegen loop (`toBundle`) — so for a two-file package, only the
file that happened to parse FIRST (per `findStdlibSourcesForTarget`'s
`_kernel_jvm/` -before-top-level ordering) ever reached `codegenPackageInto`;
the other file's declarations reached `importedPkgs` (hence type-checked
fine and let OTHER packages resolve calls into it) but its BYTECODE was
never written to the JAR — a call into ANY of its functions, including one
made from inside the WINNING file itself, threw `NoSuchMethodError` at
runtime.

**Fix.** When a package name is already present in `stdlibByPkg`, the new
file's `items`/`imports` are merged into a combined `SourceFile` (same
`packageDecl`, concatenated `items` and `imports`) rather than being
discarded, so the reachability walk and codegen both see EVERY bundled
file's full contribution to the package as one class.

**Review follow-up (#6980).** `docs/10-bootstrap-progress.md` and
`docs/61-https-tls-http-versions.md` both described this same-package
multi-file limitation as an architectural gap to route around (the reason
`_kernel_jvm/http_server.l`'s `SSLContext` construction lives where it does
instead of a new `Std.Tls`-package file). Correction notes were added to
both now that the root cause is fixed; the already-shipped workaround
itself was left in place since there is no functional reason to move
working code.

**Verification.** New `jvm_registry_rollback_self_test.l` case bundles TWO
stdlib sources both declaring `package SplitPkg` (one exporting `first()`,
the other `second()`), consumed by an entry package that calls both —
`jvm_registry_rollback_self_test` 2/2. No regression in
`jvm_cross_package_collision_self_test` (7/7),
`jvm_manifest_package_cycle_self_test` (3/3), and
`jvm_stdlib_compiled_bundle_self_test` (3/3).
