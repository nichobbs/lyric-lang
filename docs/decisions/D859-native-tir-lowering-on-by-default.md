# D859: the native backend lowers from TIR by default

Status: accepted (docs/70 phase 4a, part 8; D520 slice 48; item 4 of the 4a plan).

## Decision

1. **`--target native` lowers every function TIR covers from TIR and keeps the rest on the AST path**, the behaviour `--via-tir` switched on (D520). `LlvmTir.viaTirRequested()` is true unless `LYRIC_NATIVE_VIA_TIR=0`; `lyric build --no-via-tir` sets that for the build, and `--via-tir` still sets `1`.
2. **The census prints only when asked** (`--via-tir`, `LYRIC_NATIVE_VIA_TIR=1`, or the trace), so a default build's stderr is what the AST path's was. `LlvmTir.tirCensusRequested()` decides.
3. **The AST baseline of the typed-IR tests is `--no-via-tir`**: every AST build in `native-via-tir-e2e.sh` and `native-via-tir-overflow-e2e.sh` says so, so the comparison with the TIR build still compares two lowerings.

## Not done

The AST lowering, its middle end entry and the inference and lookups it holds stay until the fallbacks listed on #8613 reach zero (docs/70 §13, phase 4a); the default flip is what lets 4b and 4c start.
