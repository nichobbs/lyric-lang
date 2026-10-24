# JVM `if`/`match` joining a bracket literal with a slice no longer fails class verification (#7541)

`val xs = match o { case None -> []; case Some(v) -> f(v) }` (and the `if`
equivalent) where `f` returns a `slice[T]` produced a `VerifyError: Inconsistent
stackmap frames` on `--target jvm`. The bracket literal lowers to a
`java/util/ArrayList` while a slice is a real `Object[]`; `joinBranchResultType`
(`lyric-compiler/jvm/codegen/01_types.l`) only widened two distinct `JRef`
classes, so the result local stayed framed as the first arm's `ArrayList` and the
`Object[]` arm violated it. It now widens a `JRef`/`JArray` mix to `Object`, and
the consuming position's erased-to-slice coercion converts either
representation, so the empty-literal path also yields a correct slice at
runtime. This was the root cause of `Mq.messageFromJson` failing (its
`headers` arm) and, through the failed `Mq.Aspects` class initialisation, of the
Idempotent/DeadLetter aspect-weaving failures in `lyric-mq`.

Tests: `lyric-compiler/jvm/match_return_defer_jvm_self_test.l` (JVM and dotnet,
registered in `jvm-generics-self-tests-batch.sh` and
`compiler-self-tests-batch.sh`). `lyric-mq` is added to
`scripts/ci/jvm-ecosystem-suites.sh`; all 24 of its tests pass on `--target jvm`.
