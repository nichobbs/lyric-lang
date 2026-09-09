# D-progress-0899 — Native `Std.Char` kernel twin (#6811), `List`/`Map` indexed-assignment codegen, and a cross-package `?`-propagation gap (both new, found closing out #6811/#6808) — Hpack's decode path (and the full `Std.HttpEngine.H2Conn` FSM driving it) now compiles and runs correctly on `--target native`

**Status:** shipped

**#6811 — `Std.Char` had no `_kernel_native` twin.** Added
`lyric-stdlib/std/_kernel_native/char_host.l`. The code-point bridge
(`hostCharToInt`/`hostIntToChar`) needs no extern at all: `Char` and `Int`
are both lowered to `i32` on native (`native/plan/03-type-mapping.md`), so
the bridge is exactly the identity conversion the `.toInt()`/`.toChar()`
numeric-conversion builtin methods (#1901) already perform — `c.toInt()` /
`n.toChar()` compile to the same no-op the BCL/JDK twins need a real
`Convert.ToInt32`/`Character.hashCode` call for. Classification
(`isLetter`/`isDigit`/`isLetterOrDigit`/`isUpper`/`isLower`/
`isPunctuation`/`isControl`) and case conversion (`toUpper`/`toLower`) ship
as a genuinely complete ASCII-range (U+0000..U+007F) slice, matching
`System.Char`'s Unicode-category verdict exactly in that range, in pure
Lyric with **no** extern/libc dependency (avoids glibc/musl locale
divergence entirely — `lyric-rt` has no ICU/Unicode-table dependency and
building one is a substantial separate undertaking). Every code point above
U+007F falls through to the conservative default per predicate (`false` for
every `isX` check, identity for the case-conversion functions) — a real,
tracked, dated gap, filed as **issue #6858** (full non-ASCII Unicode
classification on native), not a silent divergence.

**Two more compiler-level gaps surfaced while verifying the fix against the
real motivating consumer (`Std.HttpEngine.Hpack`'s Huffman codec and the
full HPACK decode path), both fixed here — neither is Hpack-specific:**

**1. `List[T]`/`Map[K, V]` indexed assignment (`xs[i] = e`, `m[k] = e`,
compound forms) had no native codegen at all.** `Hpack.buildHuffTrie`
mutates `List[Int]` parallel arrays by index
(`zero[node] = newIdx`) — `Lyric.LlvmCodegen.lowerAssign`'s fallback
(`assignTargetName`) panics on any assignment target that isn't a bare
name or `EMember` field access, so `EIndex` targets fell straight through
to "assignment to this target form is not yet supported for --target
native (fields are Phase N2)". Fixed by adding an `EIndex` arm to
`lowerAssign` (`lowerIndexAssign` + a shared `combineIndexedAssignValue`
compound-op helper, `llvm_codegen.l`) that mirrors the JVM backend's
`EIndex`-assignment shape (`jvm/codegen/05_stmts.l`): `List[T]` lowers
through the same `lyric_list_get`/`lyric_list_set` runtime calls the
existing `.set(i, v)` method-call codegen already uses, `Map[K, V]`
through `lyric_map_get`/`lyric_map_set` (panicking on a missing key for a
compound `m[k] op= e`, matching the read-path `EIndex` panic message). No
ARC dance is needed in the codegen itself: `lyric_list_set`/`lyric_map_set`
already retain-new/release-old internally (`lyric-rt/src/lyric_collections.c`),
unlike the plain-variable/field assignment paths, which must do that dance
themselves since there is no runtime call to do it for them. Both `AssEq`
and compound (`+=`/`-=`/`*=`/`/=`/`%=`) forms are supported, matching the
JVM backend's coverage. Because the fix reuses `listElemOfType` (the same
receiver-type test the pre-existing read-path `EIndex` and `.set(i, v)`
codegen already use), it covers `slice[T]` too, not just `List[T]` —
`slice[T]` shares `List[T]`'s runtime representation (D-N-015) — confirmed
by direct repro (`xs[1] = 99` on a `slice[Int]`, matching `--target
dotnet`).

**2. `?` (Result/Option propagation) silently failed to desugar for ANY
`Std.*` stdlib package function reachable from a *different* package's
entry point, when compiling for `--target native`.** Confirmed via
extensive bisection (see below) that this is a genuine, general, previously
undiscovered gap in `Lyric.Pipeline`'s native compilation path — not
specific to Hpack, not related to `inout`, record shape, union arity,
`slice[Byte]` payloads, or `?`-chaining depth (all individually ruled out
by minimal repro). A `?` inside a function *reachable only via the stdlib
bundle* (i.e. defined in a `Std.*` package other than the entry file's own
package) reaches `Lyric.LlvmCodegen` as a raw, un-rewritten `EPropagate`
node and panics ("this expression form (EPropagate) is not yet supported
for --target native (Phase N1)") — even though the exact same code,
compiled as a *single-file, single-package* program, desugars and runs
correctly. This matches (and generalizes) the narrower symptom
`_kernel_native/http_host.l`'s own header already documented and worked
around by hand (D-progress-823): "the `?` operator fails specifically when
the enclosing function is reachable from a different package than the one
that defines it." Grepping the entire non-kernel `lyric-stdlib/std/` tree
found exactly two files using `?` at all — `http_hpack.l` (14 sites) and
one false-positive in `http_h2conn.l` (a `?` inside a doc-comment, not
code) — meaning this gap has simply never been exercised by any other
native-reachable stdlib code before now. Root-caused to the native
compilation pipeline, not fixed at the compiler-internals level (out of
this scope — belongs with the general native-backend work); worked around,
per the `_kernel_native/http_host.l` precedent, by rewriting all 14 sites
in `http_hpack.l` from `expr?` to the explicit
`match expr { case Ok(v) -> v; case Err(e) -> return Err(error = e) }` /
`case Ok(_) -> {}` form. `http_hpack.l` is target-independent (compiled
unchanged on all three targets), so this rewrite changes nothing observable
on dotnet/JVM — verified by the full existing `http_hpack_tests.l` (39/39)
and `http_h2conn_tests.l` (73/73) suites passing unmodified on both
`--target dotnet` and `--target jvm`.

**Verification.** `llvm_stdlib_self_test.l` gained a new case exercising
the `Std.Char` kernel's code-point bridge, every classification/
case-conversion predicate, and a real `huffmanEncode`/`huffmanDecode`/
`octetsToString` round-trip on `--target native` (ASan) — 19/19 passing.
Direct hand-built repros (not wired into CI, used to isolate and confirm
each fix) verified, with `--target dotnet` producing byte-identical
results: `Std.HttpEngine.Hpack.decodeHeaderBlock`/`decodeStringLiteralAt`/
`decodeIntegerAt`/`resolveIndex`/`decodeLiteralField` (the full HPACK
*decode* path) compile and run correctly on native; and — the most
significant check — a real `Std.HttpEngine.H2Conn.newServerConnection` +
`feed()` call, given real wire bytes (connection preface + an empty
SETTINGS frame + a static-table-indexed HEADERS frame), correctly decodes
through the full FSM (38 `inout H2Connection` sites, the `inout
FrameDecoder` chain, and the HPACK decoder together) to a
`H2RequestHeaders(streamId = 1, headers = [":method": "GET"], endStream =
true)` event, matching `--target dotnet` exactly.

**Not fixed here, blocking the HPACK *encode* path (`encodeHeaderList`/
`encodeHeaderField`) specifically:** `Std.HttpEngine.Hpack.stringToOctets`
calls `Std.String.charAt`, which bracket-indexes a `String` receiver
(`s[index]`) — the pre-existing native gap already tracked (and owned by a
different group) as **issue #6237** (`group:native-string-runtime`). This
is out of scope here; #6808 stays open, re-scoped to exactly this one
remaining blocker (decode-side HPACK/H2Conn is now verified working).

**Also confirmed, not a regression:** three unrelated native self-tests
(`llvm_tls_self_test.l` intermittently, `llvm_http_client_self_test.l`,
`llvm_http_server_self_test.l`) fail with `unknown name 'nativeAddrOf'` /
`unknown type name 'NativePtr'` type-check errors when run via `lyric test
<file>` (no `--target` flag, i.e. compiled to the default `--target
dotnet`) in this session's from-source sandbox build. Confirmed via
`git stash` that this reproduces identically on an unmodified tree (before
any of this entry's changes) — pre-existing and environment-specific to
this build, not investigated further here (out of scope for #6811/#6808).
