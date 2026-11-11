# TIR census: the compiler, ecosystem libraries and self-tests (#8613)

Docs/70 phase 3a: `scripts/ci/tir-census.sh --wide` reports I0002/I0003 per area (compiler, ecosystem
libraries, compiler self-tests) and per kind with a sample site, beside the unchanged standard-library
gate. Counts only: the wide areas are not gated, because phase 3a has not driven them to zero. The
compiler is checked through the stage-1 per-package emit over a `Lyric.Cli` driver (it has no buildable
manifest); `TIR_CENSUS_LINKED=1` also judges the self-tests that import compiler packages by running them
under `lyric test` (about 25 s each, so CI leaves it off). The script now sums every census line of a
project build (one per package) instead of the first. `library-tyerr-census.sh` runs it with `--wide`.

First numbers (bodies built / total, I0002 not built, I0003): stdlib tests 1082/1165, 83, 0; compiler
11070/12379, 1309, 255; ecosystem 3074/3964, 890, 89; self-tests (plain build, 385 of 753 judged)
2146/2944, 798, 76. I0003 is not zero outside the stdlib tests: `assign-mutable` (one cause,
`TFieldSig.mutable` is always false in `build_syms.l`), `call-result-type`, `pattern-arity` and
`construct-field-type`; the declaration slice fixes them.
