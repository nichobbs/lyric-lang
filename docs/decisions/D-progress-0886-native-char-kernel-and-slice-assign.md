# D-progress-886 — Native `Std.Char` kernel twin (#6811), `List`/`Map` indexed-assignment codegen, and a cross-package `?`-propagation gap (both new, found closing out #6811/#6808) — Hpack's decode path (and the full `Std.HttpEngine.H2Conn` FSM driving it) now compiles and runs correctly on `--target native`

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
native-reachable stdlib code before now. This is the THIRD known
occurrence of this exact defect (D-progress-823's `_kernel_native/
http_host.l` was the first; a second occurrence around the
`Std.HttpEngine.parseRequestLine` investigation was hand-patched the same
way) — filed as **issue #6954** so the general root cause (`Lyric.
Pipeline`'s native path not applying `Lyric.Propagate.lowerPropagateFile`
to bundled `Std.*` packages, only the entry file's own package) has a
tracked home instead of a fourth hand-rewrite next time. Root-caused to
the native compilation pipeline, not fixed at the compiler-internals level
here (out of this scope — belongs with the general native-backend work,
#6954); worked around, per the `_kernel_native/http_host.l` precedent, by
rewriting all 14 sites in `http_hpack.l` from `expr?` to the explicit
`match expr { case Ok(v) -> v; case Err(e) -> return Err(error = e) }` /
`case Ok(_) -> {}` form. `http_hpack.l` is target-independent (compiled
unchanged on all three targets), so this rewrite changes nothing observable
on dotnet/JVM — verified by the full existing `http_hpack_tests.l` (39/39)
and `http_h2conn_tests.l` (73/73) suites passing unmodified on both
`--target dotnet` and `--target jvm`.

**Verification.** `llvm_stdlib_self_test.l` gained three new committed
cases (21/21 passing, ASan): the `Std.Char` kernel's code-point bridge,
every classification/case-conversion predicate, and a real
`huffmanEncode`/`huffmanDecode`/`octetsToString` round-trip; a dedicated
indexed-assignment case exercising every combination this PR's own review
pass (see below) flagged as under-covered — `slice[Int]` `AssEq`,
`List[Int]` under all four compound operators (`+=`/`-=`/`*=`/`/=`/`%=`),
`List[String] +=` (the `lowerStringBinop` branch of
`combineIndexedAssignValue`), `Map[String, Int]` `AssEq` and all five
compound operators, and `Map[String, String] +=` (the map-side
`lowerStringBinop` branch); and a dedicated panic case confirming a
compound assignment against an absent map key (`m["missing"] += 1`)
panics rather than silently inserting. A **second review pass flagged an
evaluation-order divergence** from the JVM backend: `combineIndexedAssignValue`
originally read the container's current value BEFORE lowering the RHS
expression, while the JVM backend's `EIndex` compound-assign codegen
(`jvm/codegen/05_stmts.l`) lowers the RHS first — for an RHS with a side
effect that mutates the same container (`xs[i] += mutate(xs)`), the two
orders can observe different states. Fixed by reordering: `rhs` is now
evaluated at each `lowerIndexAssign` compound-branch call site BEFORE the
`lyric_list_get`/`lyric_map_get` read, and `combineIndexedAssignValue`
takes the pre-lowered `rhs: NVal` instead of the raw `Expr`, matching the
JVM backend's order exactly. Direct hand-built repros (not wired into CI,
used to isolate and confirm each fix during development) verified, with
`--target dotnet` producing byte-identical results: `Std.HttpEngine.Hpack.
decodeHeaderBlock`/`decodeStringLiteralAt`/`decodeIntegerAt`/
`resolveIndex`/`decodeLiteralField` (the full HPACK *decode* path) compile
and run correctly on native; and — the most significant check — a real
`Std.HttpEngine.H2Conn.newServerConnection` + `feed()` call, given real
wire bytes (connection preface + an empty SETTINGS frame + a
static-table-indexed HEADERS frame), correctly decodes through the full
FSM (38 `inout H2Connection` sites, the `inout FrameDecoder` chain, and
the HPACK decoder together) to a `H2RequestHeaders(streamId = 1, headers =
[":method": "GET"], endStream = true)` event, matching `--target dotnet`
exactly.

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

**Addendum (issue #7005, found by a third review pass on this PR).** The
review flagged that `slice[T]` compound index-assign on `--target jvm`
evaluates the RHS AFTER reading the container's current element
(`jvm/codegen/05_stmts.l`'s `JArray` arm — a real JVM array, distinct from
`List[T]`'s `java.util.ArrayList`), the opposite of every other receiver
kind (`List[T]`/`Map[K, V]` on JVM, and `slice[T]` itself on `--target
dotnet` and `--target native`, all of which evaluate the RHS first). For
`xs[i] op= f()` where `f()` mutates `xs[i]`, the two orders observably
disagree — confirmed by writing the regression test below and watching it
fail under the pre-fix order (`actual=15`) vs. pass under the fixed order
(`expected=1004`). Fixed by reordering the `JArray` compound-assign arm to
spill the RHS to a local BEFORE the array-load-plus-index sequence,
mirroring the `JRef` Map arm immediately below it in the same match.

**A second, previously-undiscovered bug surfaced while writing the
regression test for the above:** `slice[T]`'s JVM type is UNCONDITIONALLY
`JArray(elem = JRef("java/lang/Object"))` regardless of `T`
(`jvm/codegen/01_types.l`'s `TSlice(_) ->` arm, #5257's uniform
boxed-array ABI) — so a bare `xs[i] += e` on ANY `slice[T]` (not just the
`slice[Int]` #7005 named) reached `emitCompoundCombineJvm` with a
reference-typed (`Object`) target and panicked
("`Jvm.Codegen: compound assignment on a reference-typed target
('java/lang/Object')...`") for every element type except `String`,
independent of evaluation order. Confirmed via direct testing: even
`var xs: slice[Int] = [10, 20, 30]; xs[0] += 5` — no `inout`, no function
call, the simplest possible shape — panics at compile time on
unmodified `main`. The plain `AssEq` arm (`xs[i] = e`) already resolves
the receiver's TRUE declared element type via
`indexedElemTypeOverride`/`coerceScalarToSliceElem` (#6741) before storing;
the compound arm never had the equivalent treatment. Fixed by applying the
same `indexedElemTypeOverride`/`applyIndexedElemOverride` resolution the
`JRef` Map arm already uses (including its no-override
`emitUnboxObjectTo(vTy)` fallback) to narrow the loaded element to its
real type before combining, and re-boxing before the store when the
array's tracked storage is the erased `Object` shape.

**Verification.** `slice_compound_assign_eval_order_self_test.l` (new
`@test_module`, run via native `lyric test --target jvm`): a
`slice[Int]` and a `slice[Long]` case, each calling an `inout`-mutating
function as the RHS of `xs[0] += f(xs)` where `f` also writes `xs[0]`,
asserting the RHS-first combined result (`1004`) rather than the
read-first stale-combine result (`15`) the pre-fix order would produce —
confirmed both ways by temporarily reverting only the ordering change
(keeping the type-override fix) and watching both cases fail with
`actual=15` before restoring the fix. No committed test attempts a
reference-typed (`slice[String]`) compound-assign: `emitCompoundCombineJvm`
still only combines a `String` target via `AssPlus`, and (independent of
this fix) a `slice[String]`'s override resolution vs. the array's
`Object`-erased storage was not exercised end-to-end here — left
unattempted rather than guessed at. Full existing regression coverage
re-run on `--target jvm` with zero new failures: `inout_slice_self_test.l`
(4/4, `AssEq`-only slice writes across `Int`/`Long`/`Byte`/`String`
elements, unaffected since only the compound arm changed),
`list_value_compare_self_test.l` (10/10), `compound_string_assign_self_test.l`
(8/8, the `JRef` String arm this fix's `elemTy != elem` guard leaves
untouched). `llvm_stdlib_self_test.l` (21/21, native), `http_hpack_tests.l`
(39/39, dotnet), `http_h2conn_tests.l` (73/73, dotnet) re-confirmed
unaffected by the JVM-only change. `lyric fmt --write` clean on every
changed `.l` file.

**Related:** #7005 (this addendum, closed), the previously-undiscovered
`slice[T]` compound-assign type-erasure panic (filed nowhere separately —
fixed directly alongside #7005 in the same code region rather than split
into its own tracked-not-fixed issue, since leaving it unfixed would have
made #7005's own regression test uncompilable), #6741 (the
`indexedElemTypeOverride` mechanism this reuses), #5257 (the uniform
boxed-array ABI this is erased under).
