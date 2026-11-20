# D347 - The TIR gate: every body builds as TIR and verifies, on every build (docs/70 §12.2, phase 3a, #8613)

**Status:** shipped; completes phase 3a (D360, D323 introduced the census and the verifier behind `--verify-ir`; D385 made I0001 always-on).

## Context

The builder (`Lyric.Tir.Build`) and the verifier (`Lyric.Tir.Verify`) ran only under `lyric build --verify-ir` (or `LYRIC_VERIFY_IR=1`): a body the builder had no case for (I0002) or a node the verifier rejected (I0003) was a number in a census, and the backends built every body from the AST either way. Phase 3b onwards moves the backends onto the typed IR, which is only sound if every body builds and verifies on every build, as the checker's own holes (I0001, D385) already stop the build.

## Decision

`pipeCheckFront` always numbers the file's nodes (the checker's per-node tables are keyed by them), builds the package as TIR after a clean check and gates on two diagnostics, through the same sink as the checker's:

- **I0002**, an error at the node the builder has no case for, one per body that did not build: "internal compiler error in `f`: the builder has no case for ... at L:C".
- **I0003**, an error at the function, one per verifier finding in a body that built.

Both stop the build before any backend runs, in every package of a build (dependencies, the standard library and the compiler's own packages included), for `lyric build`, `lyric test`, `lyric run` and `lyric prove`. There is no opt-out. `--verify-ir` and `LYRIC_VERIFY_IR=1` keep their meaning of printing the census (counts per kind, the expression and callee censuses, sample sites); the expression and callee censuses stay informational because they count the exempt callee and qualifier positions that I0001 allows. The TIR build the gate makes is the one `opts.wantTir` consumers (the native backend, the interface builder) read, so a build builds the package once.

A program the checker rejects (a T, F, V or P error) never reaches the builder: the gate runs only after a clean check, so a fixture meant to fail checking has no I0002 or I0003 to count, and `tir-census.sh` lists such a build as rejected by the checker, not as an unchecked build.

This resolves Q-TIR-001 for I0002 and I0003: both always stop the build, in release builds too, because a body that does not build as TIR has a backend that would have to infer what the checker did not record.

## Results

The standard library, the compiler's packages, every ecosystem library manifest and the self-tests build with no I0002 or I0003 on both targets (the last wide census before the gate is in the progress entry). `scripts/ci/tir-census.sh` remains the regression measure, now with the gate behind it: a body that stops building is a failing build, not a number.
