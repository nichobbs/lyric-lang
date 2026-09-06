# D-progress-886 — Native codegen: `&&`/`||` short-circuit releases the right operand's ARC temps in a block the skip edge also reaches, corrupting the heap (#6645, #6719, #6722)

**Status:** shipped

**Context.** #6645 reported that changing a package-private native
function's return type from `slice[Byte]` to `Result[slice[Byte],
String]` (read at its one call site via a `match` whose `Err` arm ran a
statement before `return Err(...)`) compiled with zero diagnostics but
corrupted the heap at runtime — an ASan SEGV inside `lyric_release`, or
`malloc(): unaligned tcache chunk detected` at `-O0`, surfacing LATER
inside an entirely unrelated function call, not inside the changed
function itself. #6719 and #6722 hit the same failure signature (a
clean, unrelated `Err` return, or a crash) from small, independent,
well-precedented edits elsewhere in the same file
(`_kernel_native/http_host.l`'s `resolveRedirectUrl` and `parseUrl`) —
strong evidence of a general native-codegen bug rather than anything
specific to `Result`-returning functions.

**Root cause.** `Lyric.LlvmCodegen.lowerShortCircuit` (`lyric-compiler/lyric/llvm_codegen.l`),
which lowers `&&`/`||`, evaluates the right operand directly into
whichever ARC temp scope is active in the CALLER's context — it never
pushes one of its own:

```
insns.add(NLabel(name = evalL))
val b = lowerExpr(ctx, insns, rhs)          // <- registers ref-typed temps
insns.add(NStore(ty = NI1, value = b.value, ptr = NLocal(name = slot)))
insns.add(NBr(label = doneL))
insns.add(NLabel(name = doneL))
```

Any ref-typed ARC temp created while lowering `rhs` (e.g. a `String`
from a `.substring(...)` call feeding a `==` comparison — exactly
`resolveRedirectUrl`'s and `parseUrl`'s `isAbsolute`/`isProtocolRelative`
checks, and `trimSpaces`'s own left/right-trim loops) registers into the
scope active when `lowerShortCircuit` was invoked — typically a `while`
condition's temp scope (`SWhile`'s `pushTempScope`/`popTempScope` pair
in `lowerStmt`). That scope's `popTempScope` release call is emitted
into whatever block `insns` is positioned in when `lowerExpr(cond)`
returns to its caller — which, for a short-circuit expression, is
`doneL` (`sc.done`). `sc.done` has TWO predecessors: `evalL` (`sc.rhs`,
where the temp was actually created) and the short-circuit-SKIP edge
straight from the condition test (where `rhs`, and its temp, was NEVER
evaluated). Releasing the temp unconditionally in `sc.done` is therefore
a genuine SSA dominance violation — confirmed directly: `opt
-passes=verify` on a bundle built from the pre-fix `http_host.l` reports
`Instruction does not dominate all uses!` for exactly this shape, 7+
times (`trimSpaces`'s two trims among them) — and, worse, a real runtime
bug: whenever the skip edge is taken, `lyric_release` is called on
whatever garbage/leftover value the SSA register happens to hold at that
program point, corrupting the heap allocator's free-list bookkeeping.
This reproduces #6645's exact reported symptoms bit-for-bit: `clang -O2`
crashes compiling the resulting module (`CloneAndPruneFunctionInto` /
`ValueMapper::remapInstruction`, matching the issue's own stack trace),
and a `-O0` build corrupts memory detectably under `valgrind` (`Invalid
read`, `Use of uninitialised value`, ending in SIGSEGV inside
`lyric_release`) — see the Verification section below for the exact
before/after repro. It also explains #6719/#6722's reports precisely:
neither change touched ARC-relevant logic at all, but both changed
label/branch layout in a file already full of `and`/`or`-over-`.substring()`
checks, shifting WHICH later, unrelated call's temp got corrupted by
this pre-existing bug — never a property of the specific edits
themselves.

**Fix.** `lowerShortCircuit` now pushes its own temp scope around
lowering the right operand and pops it (releasing any ref-typed temps
the right operand created) INSIDE `evalL`, before branching to `doneL`:

```
insns.add(NLabel(name = evalL))
pushTempScope(ctx)
val b = lowerExpr(ctx, insns, rhs)
popTempScope(ctx, insns)
insns.add(NStore(ty = NI1, value = b.value, ptr = NLocal(name = slot)))
insns.add(NBr(label = doneL))
insns.add(NLabel(name = doneL))
```

This mirrors the pattern `lowerIf`'s then/else branches already use for
the identical reason (each branch's temps are released inside that
branch's own block, before the branch merges). `b` itself is always
`NI1` (a short-circuit's result is always `Bool`), so no ref-typed value
crosses the block boundary — only the RIGHT OPERAND's byproduct temps
needed scoping.

**With the codegen fixed:** `_kernel_native/http_host.l`'s
`buildRequestBytes` reverts to its natural `Result[slice[Byte], String]`
return type (the `BuiltRequestBytes` plain-record workaround #6645's
discovery originally shipped is removed — CLAUDE.md's "no lingering
workarounds once the root cause ships" standard), `doSendOnce`'s call
site goes back to a plain `match`, and #6719's protocol-relative
`Location` handling (`resolveRedirectUrl` gains an `isProtocolRelative`
branch: `//host[:port]/path` switches authority to `host[:port]` while
keeping the ORIGINAL request's scheme) and #6722's two fixes
(`hasForbiddenSpaceForRequestLine`, a request-line-only — method/target
— bare-space guard, since header VALUES legitimately contain spaces;
and a `p > 65535` bound in `parseUrl`'s port-parsing arm) all land as
originally attempted.

**Verification.** `opt -passes=verify` on a bundle built from the FIXED
`llvm_codegen.l` reports zero dominance violations (previously 7+, as
above); `clang -O2` compiles the same module without the inliner crash.
A real (non-sandboxed) reproduction — a driver program calling
`Std.HttpHost.hostGetSafe` in a loop against a local Python HTTP server,
with `buildRequestBytes`'s signature temporarily restored to the
originally-reported `Result[slice[Byte], String]` shape to match #6645
exactly — reproduces the `-O2` inliner segfault bit-for-bit on the
UNFIXED compiler; the same driver runs 50,000 iterations clean (`-O2`)
and 1,500 iterations clean under `valgrind` (`-O0`, zero errors) on the
FIXED compiler. This sandbox has no clang-ABI-compatible ASan runtime
available (`libclang_rt.asan-x86_64.a` missing, network-blocked `apt`),
so `valgrind` substitutes for the project's usual ASan self-test
verification here — a minimal standalone repro
(`countLeadingX`/`startsWithYOrIsShort`, the same shape as the two new
`llvm_heap_self_test.l` cases below) was bisected the same way: `opt
-passes=verify` flags the dominance violation on the unfixed compiler,
`clang -O2` segfaults (exit 139) running it, and `valgrind` reports
`Invalid read`/`Use of uninitialised value` inside `lyric_release`
ending in SIGSEGV — all three symptoms disappear with the fix rebuilt
in. Two new `-fsanitize=address` cases in `llvm_heap_self_test.l` cover
the `and` and `or` forms directly (each loops over inputs that take BOTH
the skip edge and the evaluated edge, so CI's real ASan run catches any
regression here even though this session's sandbox could not); three
new items (R, S, T) in `llvm_http_client_self_test.l` cover the
`_kernel_native/http_host.l` fixes: a real two-listener protocol-relative
redirect, a request-line bare-space rejection, and a port-out-of-range
rejection.

**Related:** #6645 (root-caused and fixed here), #6719, #6722 (both
unblocked and landed here), D-progress-827 (the original discovery + the
`BuiltRequestBytes` workaround this entry removes), `native/plan/08-work-items.md`
N9.9, `native/plan/04-arc-design.md` (the temp-scope release rules this
bug violated).
