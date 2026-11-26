# A list literal of a range type range-checks its elements on TIR (docs/70 phase 3c, #8031)

## What shipped

- The TIR builder converts each element of a list literal the checker typed directly as a `List` of a range type (`val xs: List[Int range 0 ..= 3] = [at(10)]`) to the element type, so the range check applies as it does to an element added or assigned later (`rangeCheckedElems`). The literal had no check because the conversion that does it (`retypeListLiteral`) only runs for a literal the checker typed as a slice.
- Covered by the `literal` case of `scripts/ci/range-refinement-e2e.sh`, which now passes for `--target native` lowered from TIR (all 14 cases).
