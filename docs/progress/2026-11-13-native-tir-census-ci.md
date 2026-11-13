# Native backend on TIR: the census in CI (docs/70 phase 4a, D520)

`scripts/ci/native-via-tir-census.sh` runs the bridge-driven native self-tests with the TIR
lowering on and is part of the native lane. Seventeen cross-target suites and the stdlib,
collections and invariant-boundary suites pass; `named_arg_eval_order_self_test.l` waits for
#9076 (a TIR builder bug). Float literal and range-pattern handling, negative integer literals
and mixed-width operators were fixed in the lowering on the way.
