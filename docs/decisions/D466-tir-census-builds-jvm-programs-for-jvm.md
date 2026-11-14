# D466 - The TIR census builds JVM-targeted programs with `--target jvm` (docs/70 §12.2, #8613)

**Status:** shipped.

## Context

The wide census built every self-test and stdlib test for dotnet. 26 self-tests (`lyric-compiler/jvm/*`, `*_jvm_self_test.l`) are JVM programs: they name JDK externs (`java.lang.Math`, `StringBuilder` members) that the dotnet metadata resolver cannot see, so each counted as "an extern call the host metadata cannot resolve". That kind said nothing about the builder: it measured a program built for the wrong target.

## Decision

`scripts/ci/tir-census.sh` builds a program whose path or name says jvm (`lyric-compiler/jvm/`, `*_jvm_self_test*.l`, `*_jvm_tests.l`) with `--target jvm`. The JVM build prints the same `TIR build census` and `I0003 census` lines (checked on `closure_jvm_self_test.l`: 7 of 7 bodies built, 0 I0003, where the dotnet build failed on every JDK extern), so `absorb_log` is unchanged. The builder still resolves host members through the metadata the checker recorded for the target; a JVM resolver inside the builder is a phase 3c question. A state directory kept by `TIR_CENSUS_STATE` from before this change must be discarded (the key does not include the target).
