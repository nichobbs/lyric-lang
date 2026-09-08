# D-progress-886 — MSIL codegen: confirmed a hoisted Byte closure cell shared by an ESCAPING closure pair now wraps correctly on overflow; added the regression coverage the original #5520 fix's own test comment called out as missing (#6524)

**Status:** shipped

**Context.** #6524 was a follow-up to #5520 (which fixed `Byte` compound-assignment overflow wrapping for record fields). It tracked the analogous fix for a HOISTED closure-captured `var` cell, specifically for the shape `byte_arithmetic_self_test.l`'s own "hoisted closure variables wrap on overflow" test comment called out as untested: a `Byte` cell shared by two closures that both ESCAPE their declaring function (returned out via a record — the setter/getter callback-pair idiom), rather than a closure that stays within the declaring function's own scope and is called directly.

**Investigation.** A prior attempt (documented in the issue) found that a logically-inert-looking fix to the hoisted-cell array machinery (`LBVar`'s handling in `lowerStmtMsil`) reproducibly corrupted an unrelated `lyric-mq` closure test, with no root cause isolated beyond "the diff is present in this function." Before attempting any further code change, this session reproduced the issue's exact repro shape against current `main`:

```lyric
record Pair { setter: () -> Unit, getter: () -> Int }
func makeIncrementer(): Pair {
  var b: Byte = 200.toByte()
  return Pair(setter = { -> b += 100.toByte() }, getter = { -> b.toInt() })
}
```

(adapted to bind each field to a named local before calling it — `val doSet = p.setter; doSet()` — since a bare `p.setter()` call syntax on a function-typed record field is a separate, pre-existing limitation unrelated to this issue: it fails with "unsupported method 'setter' on the receiver type," the same shape `record_field_closure_self_test.l`'s own established pattern works around.)

**Result: already fixed.** The repro now prints the correctly-wrapped `44` (not `300`), for all three compound-assignment operators (`+=`, `*=`, `-=`) tested independently, and for repeated get/set cycles on the same escaping cell. The previously-corrupted `lyric-mq` "in-memory broker round-trips a published message" test (`lyric-mq/tests/mq_tests.l`) also passes cleanly (10/10) against the same build, confirming the earlier attempt's mysterious cross-test corruption is no longer present either. No specific fixing commit was isolated — extensive closure/hoisting-related work has landed since this issue was filed, and no single decision-log entry names this exact escaping-closure-pair shape.

**Coverage.** Added the missing regression test to `byte_arithmetic_self_test.l` (already CI-wired on both `--target dotnet` and `--target jvm`): a `BytePair6524` record whose `setter`/`getter` fields close over a shared `Byte` `var`, constructed and returned from three factory functions (one per compound operator), asserting the wrapped value after invocation through locals bound from the record's fields. A fourth case exercises repeated get/set cycles on the same escaping cell (200 → wraps to 44 → 144, no re-overflow) to catch any state that only corrupts after the cell has already wrapped once. Verified green on both targets against a from-source `make lyric` build (17/17, including the 4 new cases).

**Related:** #6524, #5520 (the original record-field fix this is the hoisted-cell follow-up to).
