# 2026-11-14 - TIR census: JVM-targeted programs are built with --target jvm (D466)

docs/70 §12.2, #8613. `scripts/ci/tir-census.sh` builds `lyric-compiler/jvm/*`, `*_jvm_self_test*.l` and `*_jvm_tests.l` with `--target jvm`, removing the 26 "host metadata cannot resolve" self-test sites that came from building JVM programs under dotnet.
