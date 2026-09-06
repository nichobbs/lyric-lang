# D-progress-888 — Native `String` gains `.trimStart`, `.trimEnd`, and `.replace` (#6240)

**Status:** shipped

**Context.** #6240 audited every method in the language reference's
`String` table against `--target native`, following on from #6588's six
shipped methods. `Std.String.trimStart`/`.trimEnd` call the builtin
`.trimStart()`/`.trimEnd()` scalar methods directly (not composed from
other primitives), and `.replace` calls the builtin `.replace()` — none
of the three existed in `Lyric.LlvmCodegen`'s scalar-method dispatch, so
all three panicked ("method not yet supported") on native. The rest of
`Std.String`'s surface (`.repeat`, `.split`, `.join`, `.joinList`,
`.compare`, `.equals`, `.equalsCaseInsensitive`) was checked and found to
already be native-compatible: each composes from primitives this
backend already lowered (`+`, `<`/`>`, `==`, `.substring`, `.indexOf`,
list/slice indexing) rather than calling an unimplemented builtin
method.

**Fix.** `lyric_string_trim`'s existing leading/trailing-whitespace scan
(`lyric-rt/src/lyric_string.c`) is refactored into a shared static
`trim_bounds` helper computing both the start and end byte offsets in
one forward UTF-8 pass; `lyric_string_trim`, the new
`lyric_string_trim_start`, and the new `lyric_string_trim_end` all build
on it, so the one-sided variants share `.trim()`'s exact `White_Space`
code-point set and Unicode-aware (not ASCII-only) behavior with zero
duplicated scanning logic. `lyric_string_replace(s, oldValue, newValue)`
replaces every non-overlapping occurrence of `oldValue` left to right:
a first pass counts occurrences so the output is allocated at its exact
final size (matching this file's existing preference for exact
allocation over realloc churn — see `lyric_string_to_lower`'s own
comment on the same tradeoff), then a second pass builds it. An empty
`oldValue` is a deliberate native-specific no-op: the dotnet twin
(`String.Replace`) throws `ArgumentException` on an empty old value,
while the JVM twin (`String.replace`) instead interleaves `newValue`
between every character — two host-specific quirks with nothing in
common, and this runtime has no exception mechanism to surface the
dotnet behavior, so copying neither is the honest choice rather than
picking one arbitrarily. All three new methods are wired into
`Lyric.LlvmCodegen.lowerScalarMethodCall`'s String arm alongside the
existing `.trim`/`.toLower`/etc. methods, with matching `runtimeDecls()`
entries.

**Verification.** New cases in `lyric-rt/test/lyric_rt_test.c`:
`.trimStart`/`.trimEnd` across a padded string, an all-whitespace
string, an already-clean string, and the existing NBSP (U+00A0)
Unicode-whitespace case (each one-sided variant strips only its own end,
confirmed against both the padded and NBSP inputs); `.replace` across a
growing replacement, a shrinking (empty-`newValue`) replacement, a
not-found `oldValue` (unchanged output), and the empty-`oldValue` no-op.
Two new end-to-end ASan-compiled cases in `llvm_codegen_self_test.l`
mirror the same matrix through the real `--target native` pipeline.
`make -C lyric-rt test` and the full `native-backend-self-tests`
self-test list (via `make self-test NAME=llvm_codegen` and direct
`LYRIC_LOAD_COMPILER=1` runs, using the freshly staged
`<libdir>/selfhosted/` compiler DLLs) both pass with zero regressions,
including every ASan-linked case.

**Related:** #6240 (this fix), #6588/D-progress-831 (the fix this closes
out), #6779 (native `.toLower`/`.toUpper` script-coverage widening,
explicitly out of scope here), #6237 (native `s[i]` bracket indexing and
`String + Char` concatenation), #6755 (native `.lastIndexOf`) — the
latter two shipped as separate PRs from the same audit,
`docs/01-language-reference.md` §12.1 (updated).
