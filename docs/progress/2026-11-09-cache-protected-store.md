# lyric-cache: InProcessCacheStore is a protected type; #7457 verified fixed on both targets

`impl <Interface> for <protected type>` was fixed by #7544 (D-progress-1009):
the impl methods become locked members of the protected type. Re-verified on
the released compiler: `protected_iface_impl_self_test.l` passes on
`--target dotnet` and `--target jvm`, and the native self-test is in the
native CI scripts, so no compiler change was needed.

`Cache.InProcessCacheStore` is now a `protected type` that still implements
`CacheStore`. Its `get`/`set`/`delete`/`clear` run under the instance lock, so
the process-wide stores shared by `Cache.Aspects` are safe across threads. The
hand-written `checkInvariant` calls are gone because a protected type's
invariant is checked after every member returns; the one behaviour change is
that constructing the type directly with `maxEntries < 1` panics on the first
operation, not at construction (the factories still reject it with `requires:`).
The WARNING and README workaround text were removed.

`tests/cache_concurrency_{dotnet,jvm}_tests.l` run four real threads against
one store (`Task.Run` on dotnet, `java.lang.Thread` on the JVM). Against the
previous record they failed on both targets with the invariant panic
(`insertionOrder.count` differing from `valueMap.count`); against the protected
type they pass, as do the existing 19 tests plus the 7 aspect-weaving tests on
both targets.

The `cache_aspects.l` header no longer claims the aspect weaver is unshipped
(already corrected on `main`). `Session.InProcessSessionStore`,
`Mq.InProcessDeadLetterStore` and `Flags.Registry` have the same shared-mutable
pattern; converting the first two changes construction-time invariant checks
their tests assert, so they are tracked in #8950 rather than folded in here.
`Flags.InProcessFlagStore` has no mutating operation and needs no change.
