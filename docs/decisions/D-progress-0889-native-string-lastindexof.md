# D-progress-889 — Native `String` gains `.lastIndexOf` (#6755, fast-follow to #6588)

**Status:** shipped

**Context.** D-progress-831 (#6588) shipped native (`--target native`)
`String.trim`/`.toLower`/`.indexOf`/`.startsWith`/`.contains`/`.endsWith`,
deliberately scoping out `.lastIndexOf` — the issue's own ask list only
named the six methods above. `.lastIndexOf` is documented in
`docs/01-language-reference.md` §12.1 alongside `.indexOf` as the same
import-sensitive pair, and both MSIL and JVM already implement
`.lastIndexOf` with that exact same gate `.indexOf` uses. Native had no
`.lastIndexOf` scalar-method arm at all, so it fell straight to
`Std.String.lastIndexOf`'s free-function UFCS form unconditionally —
correct when `Std.String` is imported, but panicking ("method not yet
supported") without the import, unlike `.indexOf`'s dual raw/`Option`
behavior.

**Fix.** `lyric_string_last_index_of` (`lyric-rt/src/lyric_string.c`) is
a new backward variant of the existing `find_substring` helper `.indexOf`
already uses: scans from `hlen - nlen` down to 0 for the last matching
byte offset, or -1; an empty needle matches at `haystack.length` (not
offset 0), mirroring the dotnet (`String.LastIndexOf("")`) and JVM
(`lastIndexOf("")`) twins. `Lyric.LlvmCodegen`'s `.indexOf` scalar-method
arm (`lowerScalarMethodCall`) is refactored into one shared arm keyed on
`name == "indexOf" or name == "lastIndexOf"`, dispatching to
`lyric_string_index_of`/`lyric_string_last_index_of` by a local `sym`
variable — applying the identical `ctx.pkgImportsStdString` /
`ctx.curPkg[0] != "Std.String"` import-sensitivity gate (#6752) to both
method names rather than duplicating the ~25-line gate logic. A new
`lyric_string_last_index_of` entry is added to `runtimeDecls()`.

**Verification.** New cases in `lyric-rt/test/lyric_rt_test.c`: a
repeated-needle haystack (`"hello world hello"`) where `.lastIndexOf`
finds the occurrence at byte 12 while `.indexOf` finds byte 0 on the
same string (distinguishing the two, not just testing each in
isolation); the not-found (-1) and empty-haystack/-needle cases already
covered for `.indexOf` are mirrored for `.lastIndexOf`, including the
empty-needle-matches-at-length case that has no `.indexOf` analog.  A new
end-to-end case in `llvm_codegen_self_test.l` (the no-import raw-sentinel
path, matching `.indexOf`'s existing test's structure) and a new
`.lastIndexOf` test in `indexof_native_self_test.l` (the with-import
`Option[Int]` path plus the explicit `lastIndexOfRaw` sentinel-int form)
mirror `.indexOf`'s existing coverage of the identical import-gate rule.
`make -C lyric-rt test`, `make self-test NAME=llvm_codegen` (using the
freshly staged `<libdir>/selfhosted/` compiler DLLs), and
`lyric test lyric-compiler/lyric/indexof_native_self_test.l --target
native` all pass with zero regressions across the full existing native
self-test suite.

`native/plan/08-work-items.md`'s N9.3 write-up is updated to record
#6755 as shipped.

**Related:** #6755 (this fix), #6588/D-progress-831 (the fix this
extends), #6752 (the import-sensitivity gate `.indexOf`'s arm
introduced, now shared by `.lastIndexOf` too), #6240 (the broader native
`String` search-method audit this issue was split out of),
`docs/01-language-reference.md` §12.1 (updated), `native/plan/03-type-mapping.md`
(D-N-006, native's byte-indexed `String` model both `.indexOf` and
`.lastIndexOf` share).
