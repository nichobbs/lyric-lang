# D-progress-889 — Cross-package bridges: `internal` items now visible to a project's own sibling packages (#6580)

**Status:** shipped

**Context.** A qualified cross-package call to an `internal` (not `pub`)
function failed at compile time with `T0020: unknown name`, even though
`docs/01-language-reference.md` §3.1 documents `internal` as visible across
packages WITHIN THE SAME PROJECT (unlike a fully private, unmarked
declaration). Found while building `lyric-grpc`'s real channel-lifecycle
kernel: an opaque type's "authoring function" idiom (docs/01 §2.8) — a
same-project sibling kernel package needs to construct the opaque's private
representation — was forced to widen every authoring function to `pub`,
needlessly leaking implementation-detail functions into the public API.

A second, textually similar symptom was reported alongside this ("UFCS
cross-package calls fail at runtime") but does NOT reproduce on a real
build: `id.someFreeFunction()` calling a plain free function via receiver-
dot syntax fails identically SAME-package (confirmed with a minimal repro,
`ArgumentException`-style "unsupported method" at runtime) and is rejected
at COMPILE TIME with a clean `T0113` for a record receiver. Lyric's actual,
documented UFCS mechanism — a D037 dot-named method (`func Type.method`) —
already works correctly cross-package with no changes needed. General
free-function-via-receiver-dot-syntax was never a supported Lyric
construct; the original report's "same-package works" premise didn't hold
against a real `main` build (it used a flagged-as-suspect 0.5.1 NuGet-tool
sandbox). See the #6580 issue thread for the full re-investigation.

**Root cause.** `Lyric.Pipeline.pipeIsCrossPackageItem` — the single shared
cross-package-item-visibility filter all three backend bridges (MSIL/JVM/
native) use — only ever admitted `pub` functions/vals. It served two
conceptually different purposes that got conflated:
1. A restored cross-project dependency or bundled stdlib DLL, where
   `internal` genuinely has no cross-assembly binding to call through
   (`pub`-only is correct here).
2. A build's own in-project SIBLING packages (the `[project.packages]`
   multi-file case), where `internal` is documented as visible.

Every "own project sibling package" call site on all three backends used
the pub-only filter for case 2 too: `msil/bridge.l`'s in-bundle package
loop, `jvm/bridge.l`'s entry-package and sibling-package loops, and
`llvm_bridge.l`'s own-package loop (the last one doubly relevant: #6809's
multi-package native project builds made this reachable there for the
first time, alongside #4900's interface-collision fix in the same release
window).

**Fix.** Added `pipeIsCrossPackageItemProject`/`pipeAddCrossPackageItemsProject`
(pub-OR-internal) to `Lyric.Pipeline`, and switched every own-project-
sibling call site on all three backends to it. Stdlib/restored-dependency
call sites are untouched (still pub-only, correctly).

**Verification.** New self-tests: `msil_project_bridge_self_test.l` and
`jvm_cross_package_collision_self_test.l` each gained a "qualified call to
an internal cross-package function resolves" test (two own-project
packages, the callee's function `internal`, called via qualified syntax
from a sibling). `lyric-grpc/src/types.l`'s `wrapChannelHandle`/
`channelHandleId` reverted from `pub` back to `internal` per that file's
own workaround comment; `lyric-grpc`/`lyric-auth`/`lyric-resilience` all
still build clean. Following a `claude-review` SUGGESTION, a matching
native-target regression test was added to `llvm_project_self_test.l`
(the fix's third call site, `llvm_bridge.l`'s own-package loop, had no
dedicated end-to-end test) — it type-checks and lowers to LLVM IR
identically to the file's other ASan-linked tests, confirming the fix is
exercised; this sandbox cannot execute it end-to-end (pre-existing missing
`libclang_rt.asan-*.a`, same gap noted in D-progress-887/PR #6900).
