# D-progress-959 — `isNormalized`/`normalize` MSIL↔JVM parity fix; a T0113-for-`String` type-check-time diagnostic attempt for #7099 was reverted before merge

**Status:** partially shipped (`isNormalized`/`normalize` parity shipped; the T0113 diagnostic attempt reverted)

**Context.** #7099 reports that a call to a nonexistent `String` method (a
typo, or a BCL method the language never implemented, e.g.
`"x".toLowerInvariant()`) type-checks clean and only fails once the
compiled program runs, with the issue asking for "a compile-time
diagnostic at the call site."

**First attempt — a `TyPrim(PtString)` arm in `maybeUnknownMemberDiag`.**
`maybeUnknownMemberDiag` (`lyric-compiler/lyric/type_checker/typechecker_exprs.l`)
already emitted T0113 for an unknown member on a `TyUser` receiver, but had
no arm for `TyPrim(PtString)`. Added one, gated on an explicit
`isBackendIntrinsicStringMethodName` allowlist of the 15 names both
backends' hardcoded `String`-method dispatch cascades implement
(`contains`, `substring`, `replace`, `isNormalized`, `normalize`, `trim`,
`trimStart`, `trimEnd`, `indexOf`, `lastIndexOf`, `startsWith`, `endsWith`,
`split`, `toLower`, `toUpper`) plus the universal methods, `builtinMember`
accessors, and `sigs`-visible bare-name functions.

**Self-discovered, independently-valid fix along the way: `isNormalized`/
`normalize` had zero JVM support.** Validating the allowlist against real
code surfaced that `isNormalized`/`normalize` were MSIL-only:
`lyric-stdlib/std/string.l` had no `pub func isNormalized`/`normalize`
wrapper at all, and `lyric-compiler/jvm/codegen/04_calls.l` had no JVM
intrinsic for either name — `lyric-compiler/lyric/lexer.l:1235`'s real,
pre-existing `buf.isNormalized() { buf } else { buf.normalize() }` call
would have broken on `--target jvm` had this gone unnoticed. Fixed both
gaps and kept them (this part shipped, independent of the T0113 revert
below):

- `lyric-stdlib/std/string.l`: added `pub func isNormalized(s): Bool` /
  `pub func normalize(s): String` thin UFCS wrappers.
- `lyric-compiler/jvm/codegen/04_calls.l`: added the JVM intrinsic, routing
  through `java.text.Normalizer`'s **static** methods
  (`LGetstatic(Normalizer$Form.NFC)` + `LInvokestatic`), since Java has no
  `String`-instance-method equivalent for Unicode normalization.

Verified end-to-end on both targets (build **and** run, not just compile):
MSIL and JVM both print `true` / `hello` for an already-NFC `"hello"`
input.

**Why the T0113 diagnostic was reverted.** CI caught the allowlist
false-positiving on real, legitimate JVM code:
`lyric-compiler/lyric/hash_jvm_self_test.l` and
`lyric-compiler/jvm/try_catch_expr_jvm_self_test.l` both call
`s.getBytes()` on a `String` receiver — a real `java.lang.String` method,
resolved not through JVM's hardcoded intrinsic cascade but through
`lowerAutoFfiInstanceCall` (`lyric-compiler/jvm/codegen/04_calls.l`
~L4629), JVM's generic auto-FFI instance-method resolver: when a method
name isn't one of the ~15 hardcoded intrinsics, JVM falls through to
looking the method up directly against real JDK class metadata
(`Jvm.AutoFfi.findBestInstanceMethod`), resolving *any* real
`java.lang.String` method this way. MSIL has no equivalent fallback — its
`String` handling is a genuinely closed, hardcoded cascade that panics at
codegen time for anything outside it (`lowerMethodCallMsil`'s `case
MString -> panic(...)` fallback, unconditional on every MSIL build,
predating this PR in commit `f2718787`).

This means the two backends do NOT share one "fully known" `String`
member surface, contrary to what the first attempt assumed: MSIL's is
closed (the 15-name allowlist really is everything), JVM's is open
(anything resolvable against real `java.lang.String` metadata is valid,
a much larger set no static Lyric-side allowlist can enumerate). The
shared, target-agnostic `Lyric.TypeChecker` has no way to distinguish
which target a given check-pass is feeding, so a single allowlist-gated
diagnostic there is structurally unable to be correct for both targets at
once: it either under-covers JVM (rejecting real methods like
`getBytes`) or would need to duplicate JDK metadata resolution inside the
middle-end type checker (a layering violation, and a much larger change
than this PR's scope).

**Reverted:** the `TyPrim(PtString)` arm and `isBackendIntrinsicStringMethodName`
from `typechecker_exprs.l`; the two new `typechecker_self_test.l` tests for
it; the two `msil_project_bridge_self_test.l` test edits (restored to
their pre-existing `catch Bug`-based form, since MSIL's own `f2718787`
codegen panic — unaffected by this revert — already covers MSIL's closed
surface at build time, just one stage later than type-check); the
`docs/01-language-reference.md` and `book/chapters/appendix-b-quick-reference.md`
T0113-for-`String` prose. `isNormalized`/`normalize` and the #6886 work in
the same PR are unaffected by this revert.

**Follow-up.** #7099 stays open; a design note was added there. The real
fix needs either target-awareness threaded through the shared type
checker (so the check can consult each backend's actual resolvable-name
set) or the check moved into each backend's own bridge as a
target-specific pre-codegen pass — for JVM, that pass could genuinely
resolve against JDK metadata (mirroring what `Jvm.AutoFfi` already does
for auto-FFI `extern type` receivers, which is exactly what the original
issue's own last paragraph suggested as the correct fix shape) instead of
a static allowlist.

**Verification of the final (reverted) state.** `typechecker_self_test.l`:
430/430 (back to pre-#7099 baseline). `msil_project_bridge_self_test.l`:
66/66 (both edited tests restored to their pre-#7099 form, the `#6886`
regression test still present). `jvm_cross_package_collision_self_test.l`:
10/10. Full `make lyric` rebuild; `hash_jvm_self_test.l` and
`try_catch_expr_jvm_self_test.l` both pass again on `--target jvm`.

**Related:** #7099 (still open), #7204 (the follow-up filed with this
entry's design note), the JVM regression this entry documents and
reverts.
