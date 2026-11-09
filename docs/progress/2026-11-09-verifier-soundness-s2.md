# Verifier soundness stream S2: re-verified #8142/#8354/#8157/#8141/#8306, closed the method-call hole of #8110

Re-ran each issue of stream S2 against `main` (`make lyric`, then
`lyric test lyric-compiler/lyric/verifier_self_test.l`: 246 cases, all five
fixes have regression tests and pass). New: method calls on values the
verifier has no heap model for (collections, mutable records, protected
objects, closures, unmodelled values) fail closed with `V0033` instead of
being congruent uninterpreted functions, with a regression test
(`a read of a value after a non-@pure method call on it is not the earlier
read (#8110)`). See D546 and docs/15 §"Method calls".
