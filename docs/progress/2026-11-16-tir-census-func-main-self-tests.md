# 2026-11-16 - TIR census: `func main` self-tests are judged (D523)

docs/70 phase 3a, #8613. `scripts/ci/tir-census.sh --wide` runs a self-test that is a `func main` program and fails the ordinary build through `LYRIC_LOAD_COMPILER=1 lyric run`, the path `scripts/run-numbered-self-tests.sh` uses, and reads its census lines, so the 220 numbered programs are counted instead of listed unchecked. Checked on `self_test_b3.l` and `msil_self_test_m87.l` (both judged, I0003 0).
