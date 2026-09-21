# D-progress-941 — ecosystem-wide F0027 hint-less-extern audit clears; surfaces a real proto3 float encoding bug (#5704)

**Status:** shipped (partial — see "Still open")

**Context.** #5704 tracks turning the `F0027` hint-less-`@externTarget`
warning (a hint-less instance extern whose calling convention the metadata
reader can't confirm silently defaults to a STATIC call, faulting at
runtime with `MissingMethodException` if the member is actually an
instance method — the `warnHintlessExternUnverifiedMsil` warning added for
D-progress-667) into a build-gating error. The issue explicitly deferred
that promotion pending "a full ecosystem audit... every `lyric-*/`
`_kernel/` and any user `@externTarget`", since turning F0027 into a hard
error before the ecosystem is annotated would break every build that still
carries a hint-less instance extern the metadata reader can't verify.

**This entry performs that audit.** Built every package with a
`lyric.toml` at the repo root (`lyric-stdlib` plus all ~28 ecosystem
libraries) via `./bin/lyric build --manifest <pkg>/lyric.toml` and grepped
for `F0027` in the output. Result: exactly two root-cause patterns,
repeated across a handful of files:

1. `System.Threading.Monitor.Enter`/`Exit` — hint-less in
   `lyric-web/src/_kernel/net/web_kernel.l`,
   `lyric-mq/src/_kernel/net/mq_kernel.l`,
   `lyric-jobs/src/_kernel/net/jobs_kernel.l`, and
   `lyric-resilience/src/_kernel/net/resilience_kernel.l` (`lyric-ws` and
   `lyric-grpc` already carried `@externStatic` on their own copies of this
   same pattern — an established, just-not-universally-applied precedent).
2. `System.BitConverter.SingleToInt32Bits` — hint-less in
   `lyric-proto/src/proto_main.l` (`lyric-compiler/msil/_kernel/kernel.l`
   and `lyric-compiler/jvm/_kernel/kernel.l` already carried
   `@externStatic` on their own copies).

Both BCL members are unambiguously `static` (`Monitor.Enter(object)` /
`Monitor.Exit(object)`, `BitConverter.SingleToInt32Bits(float)`), so adding
the missing `@externStatic` hint is a correctness-neutral, behavior-neutral
change — it does not switch *what* is invoked, only removes reliance on the
unverified static guess. `lyric-lambda`, `lyric-testing`, and `lyric-otel`
inherited their own F0027 warnings transitively (via `lyric-web`'s,
`lyric-mq`'s, and `lyric-proto`'s kernels respectively) and needed no
direct edit — fixing the root kernel file cleared the warning at every
importer.

**A real bug surfaced.** Adding `@externStatic` to `floatToInt32Bits`
(`lyric-proto/src/proto_main.l`) additionally enables the codegen's F0015
declared-signature verification pre-check (gated on an *explicit* static
hint — see `emitExternTargetBody`'s `isExplicitStatic` guard,
`lyric-compiler/msil/codegen.l`), which had never run against this extern
before. It immediately failed build with:

```
error[F0015] @externTarget 'System.BitConverter.SingleToInt32Bits' on
'floatToInt32Bits': declared signature (r8) -> i4 does not match any
overload...
```

Root cause: `floatToInt32Bits(v: in Float): Int = ()` declared the extern
directly against a Lyric `Float` parameter — but Lyric's `Float` erases to
the CLR `double` (`typeExprToMsilCtx`'s `Float -> MDouble` mapping, no
distinct 32-bit float surface type), while `SingleToInt32Bits` takes a real
32-bit `System.Single`. The pre-existing hint-less path silently
static-guessed a `(double) -> int32` MemberRef signature that matches no
real overload — this was **already broken** (a runtime
`MissingMethodException` on any real call, not merely unverified), just
never caught because F0015 was gated behind the very hint this audit was
adding. Confirmed via `lyric-proto/tests/proto_types_tests.l`'s own
pre-existing comment: *"floatField's round-trip is blocked by a separate
Float->BitConverter.SingleToInt32Bits(Double) extern miscompile, tracked
separately, so it is not asserted here."*

**Fix.** Rewrote `floatToInt32Bits` to narrow through a real 32-bit
`System.Single` first, mirroring the identical, already-correct idiom
`Msil.Kernel.bufF4Le` uses (`lyric-compiler/msil/_kernel/kernel.l`):

```lyric
import extern System.{Single}

@externTarget("System.Convert.ToSingle")
@externStatic
func dblToSingle(v: in Double): Single = ()

@externTarget("System.BitConverter.SingleToInt32Bits")
@externStatic
func singleToInt32Bits(v: in Single): Int = ()

pub func floatToInt32Bits(v: in Float): Int {
  singleToInt32Bits(dblToSingle(v))
}
```

The public `floatToInt32Bits(v: in Float): Int` signature is unchanged (no
consumer-visible API break); only its body changed from a direct
mis-declared extern to a two-step narrow-then-reinterpret.

**Verification.** Replaced the stale "round-trip blocked" test comment in
`proto_types_tests.l` with a real test asserting `floatField(7, 2.5f32)`
round-trips to `2.5`'s exact known IEEE-754 binary32 bit pattern
(`0x40200000`) — not `doubleToInt32Bits(2.5)`'s bits, which would assert
the wrong (binary64-truncated) value and defeat the point of the
regression test. `lyric-proto` test suite: 25/25 pass (was 24, all
pre-existing tests unaffected). Re-ran the full ecosystem build sweep
after the fix: zero `F0027` warnings and zero build errors across every
`lyric-*/` package plus `lyric-stdlib`. Ran the full test suites for
`lyric-web`, `lyric-mq`, `lyric-jobs`, and `lyric-resilience` (all consume
`monitorEnter`/`monitorExit` internally for lock-protected state) — all
green, confirming the `@externStatic` hint change is behavior-neutral for
the lock path.

**Still open.** This entry does **not** promote F0027 from a warning to a
build-gating error — that is #5704's own next step, and per the issue's
own scoping this audit only clears the *known* ecosystem repos in this
checkout. A user's own out-of-tree `@externTarget` code is not (and cannot
be) covered by this pass. Promoting F0027 to an error, and the negative/
positive test coverage #5704 additionally asks for (a deliberately-
mismatched-arity hint-less extern asserting F0015 fires; an SDK-less
harness asserting F0027 rather than a silent bad build), remain unshipped
follow-up work.

**Related:** #5704 (partially addressed — audit complete, promotion to
error still open), D-progress-667 (the original F0027 warning), #5577/#5560
(the enforcement half's own predecessors), the pre-existing `lyric-ws`/
`lyric-grpc`/`lyric-compiler` kernel files (the established `@externStatic`
precedent this audit applied uniformly).
