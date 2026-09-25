# D-progress-964 — `--target native`: `Std.String.isNormalized`/`normalize` infinite self-recursion fixed with an explicit compile-time panic (#7304)

**Status:** shipped

**Context.** PR #7188 added two new `Std.String` wrapper functions,
`isNormalized(s: in String): Bool` and `normalize(s: in String): String`
(`lyric-stdlib/std/string.l`), each with a body that calls the same-named
method via UFCS (`s.isNormalized()` / `s.normalize()`) — the same shape
every other wrapper in that file uses (`trim`, `toLower`, ...). That
shape is only safe on MSIL and JVM because both backends recognize the
method name as a hardcoded codegen intrinsic and never route the call
back through ordinary function resolution.

`lyric-compiler/lyric/llvm_codegen.l` (the `--target native` backend) had
no such intrinsic for either name, and no explicit guard. Native's
`lowerScalarMethodCall` falls through to `lowerUfcsCall` for any
unrecognized String method, which resolves the callee by
`<currentPackage>.<name>/<arity>` against `ctx.sigs`. While lowering
`Std.String.isNormalized`'s own body, that key is
`Std.String.isNormalized/1` — the very function being compiled. The
result was silent infinite self-recursion (a runtime stack overflow the
first time either method was ever called on native), not a diagnostic.
Before this PR, the identical call site would have compiled to a clean,
compile-time-reachable panic (`lowerScalarMethodCall`'s `return None`
falling through to the generic "no matching function" resolution failure)
— the wrapper functions simply didn't exist yet, so the vulnerable
call-into-self shape was unreachable. Adding them made it reachable for
the first time, silently regressing a real safety property.

Caught as a REQUIRED finding by `claude-review` on PR #7188 before merge.
Directly mirrors the same recursion-hazard class `indexOf`/`lastIndexOf`
already guard against (#6752): that code's own comment explicitly warns
"routing it back through itself would recurse forever ... even though
`Std.String` does not import itself today" — the exact failure mode this
entry fixes, just for a different pair of method names with no guard at
all.

**Fix.** `lowerScalarMethodCall`'s `isStringNType(v.ty)` branch now
intercepts `isNormalized`/`normalize` explicitly (zero-arg, matching the
UFCS receiver-only call shape) with a named panic —
`"String member '.<name>' is not yet supported for --target native
(Unicode normalization tables not yet ported to lyric-rt)"` — restoring
the pre-PR safety property: a compile-time failure instead of a runtime
crash. A full native NFC implementation (porting Unicode normalization
tables into `lyric-rt`) is out of scope for this fix and remains a
tracked gap; the panic message says so explicitly.

**Verification.** New `native_string_normalize_panic_self_test.l`
(`LYRIC_LOAD_COMPILER=1 lyric test`, no `clang`/`lyric-rt` build
required — only exercises the codegen-time panic, never links or runs a
binary): three cases — `s.isNormalized()` panics with a message naming
the method, `s.normalize()` panics with a message naming the method, and
unrelated native String methods (`trim`, `toLower`) are confirmed
unaffected by the new guard. 3/3 pass. Full regression sweep:
`typechecker_self_test.l` 437/437, `msil_project_bridge_self_test.l`
66/66 (both unaffected — this fix is native-only codegen). Full clean
`make lyric` succeeds.

**Related:** #7304 (this fix, filed by the review that caught it), #6752
(the `indexOf`/`lastIndexOf` self-recursion guard this mirrors), PR #7188
(where `isNormalized`/`normalize` were introduced and this regression was
caught before merge).
