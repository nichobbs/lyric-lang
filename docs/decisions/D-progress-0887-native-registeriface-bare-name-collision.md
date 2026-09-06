# D-progress-887 — Native codegen: `registerIfaceInfo` fails loudly on a bare-name interface collision instead of silently picking one (#4900)

**Status:** shipped

**Context.** `registerIfaceInfo` (`llvm_codegen.l`) registers each interface
under three keys: qualified (`Pkg.Name`), bare (`Name`), and box-struct
(`__iface.<mangled qualified>`). Flagged during review of PR #4899 (#4900):
if two interfaces from different packages share a bare name, they overwrite
each other in the bare-name slot, and any lookup that resolves by bare name
silently binds to whichever registered last — wrong vtable dispatch, no
diagnostic. Triaged three times (2026-07-03 through 2026-07-29) as
confirmed-but-unreachable: native builds were single-package only, and even
within a single package the bridge (`llvm_bridge.l`'s `unitOf`) only
collected interfaces for the driver unit (`lowerAll = true`), so at most one
package's interfaces were ever in scope for one build.

**Why this is reachable now.** #6809 (D-progress-854, `lyric build
--manifest ... --target native`) shipped multi-package native project
builds via `compileProjectToNativeWithFlags`. Its own doc comment states
"every entry in `packages` is always fully lowered (`lowerAll = true`) —
exactly like the single-source path's own package", and `unitOf`'s
interface collection (`IInterface`/`IImpl` cases) is gated on `lowerAll` —
so EVERY own project package now contributes its interfaces to the shared
registry, not just one. Both of #4900's original gating conditions no
longer hold; two same-bare-name interfaces from different own-project
packages are now a real, reachable collision.

**Why the bare-name key can't simply be dropped.** `typeToN`'s `TRef` case
(the native type resolver) joins a single-segment type path to itself
(`modulePathJoin` of one segment is that segment) — so for the
overwhelmingly common unqualified interface reference (`x: in Shape`, not
`x: in Pkg.Shape`), the bare-name key is the ONLY key ever consulted; it is
not a lookup-performance fallback. Both alternatives #4900 originally
floated (qualified-name-only resolution, or eliminating the bare-name
lookup) would require threading resolved-symbol qualification through
every single-segment interface type reference in the native backend — a
larger design change out of scope here.

**Fix.** Added `ifaceBareNameOwners: Map[String, String]` to `Ctx` (bare
name -> the qualified name currently occupying it). `registerIfaceInfo`
checks it before overwriting the bare-name key: if a DIFFERENT qualified
interface already owns the bare name, `panic`s with a clear message naming
both qualified interfaces (matching this file's established convention for
native-specific compile errors — e.g. the open-range `for`-loop panics).
Re-registering the SAME interface (phase A's names-only pass, then phase
B's full-signature pass) is unaffected — the owner check compares qualified
names, not identity.

**Verification.** New self-test in `llvm_project_self_test.l`: two
own-project packages each declaring an interface named `Shape` (with
different `impl`s) now panics with "ambiguous interface name" instead of
compiling; asserted via `assertPanicsWith`, matching the file's existing
`@cfg`-gating regression test's pattern for an expected native-codegen
panic. Full `llvm_project_self_test.l` suite passes (ASan-clean).
