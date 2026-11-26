# The native backend lowers from TIR by default (docs/70 phase 4a, part 8)

Decision: D859.

## What shipped

- `viaTirRequested()` is true unless `LYRIC_NATIVE_VIA_TIR=0`; `lyric build --no-via-tir` sets it.
- The census prints only for `--via-tir`, `LYRIC_NATIVE_VIA_TIR=1` or the trace.
- The AST baselines of `native-via-tir-e2e.sh` and `native-via-tir-overflow-e2e.sh` use `--no-via-tir`; the book's quick reference describes the flags.

## Remaining

The fallbacks on #8613, then deleting the AST path.
