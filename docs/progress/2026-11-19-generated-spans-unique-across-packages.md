# A generated span stays unique when the build's packages share one origins map (D370)

A project build with `@generate(Json)` (or any derive or woven aspect) in two packages failed with `T0120` "a call to 'X.fromJsonElement/1' reached code generation with arguments the type checker should have rejected (T0042): expected at most 1 argument(s), got 2", depending only on the byte sizes of the packages' files.

`DiagSink.origins` is one map for the whole build, and `Expand.freshSpan` took `base + 2 * origins.count`, where `base` is per package. When a later package's next offset equalled a key an earlier package had recorded, the `add` left the map unchanged, so `count` stopped growing and every later generated node of that package took the same span. The checker's span-keyed tables (`calleeSites`, keyed by the callee path's span alone) then held one entry for unrelated calls, and the backend bound a two-argument call to a one-parameter callee.

`freshSpan` now steps past keys already in `origins`, so generated spans are unique across the build, and so within each package. `derives_self_test.l` derives a package after a slightly larger one over a shared map and asserts that no two generated spans of the second repeat.

Generated spans are the D370 mechanism, so that is the decision this entry and the test cite. The title first cited D390 (derives run before the check), which is a different decision: with derives expanded before the check, the checker's span-keyed tables depend on these spans, but the span arithmetic itself is D370's.
