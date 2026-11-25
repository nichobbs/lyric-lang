# HTTP/2 engine property and fuzz suite (docs/72 slice 2)

Decision: D801.

## What shipped

- `lyric-stdlib/tests/http_h2fuzz_tests.l`: 20 seeded tests over the frame codec, HPACK and `H2Conn` in both roles (chunking invariance, mutation fuzz with structural invariants, bounded-work assertions for Rapid Reset, CONTINUATION floods, header-list overflow, HPACK bombs, oversized frames, dribbling and PING/SETTINGS/DATA floods).
- `scripts/ci/h2conn-tests.sh` runs it on dotnet and the JVM (no `ci.yml` change); `.github/workflows/stage2-self-test.yml` runs a 3000-iteration long run nightly on both targets.
- `LYRIC_H2_FUZZ_ITERS` and `LYRIC_H2_FUZZ_SEED` scale and replay the suite; a failure prints `seed=<n>`.
- No engine defect was found; no stdlib code changed.

## Verification

Toolchain: a private copy of the installed one (`cp -r /home/user/tc-s8 /home/user/tc-72-s2`), with the dotnet stdlib bundle rebuilt from this tree (`lyric build --manifest lyric-stdlib/lyric.full.toml -o /home/user/tc-72-s2/b/Lyric.Stdlib.dll --target dotnet --no-restore`, copied over `bin/lib/Lyric.Stdlib.dll`); `LYRIC_STD_PATH` points at the worktree.

- `lyric test lyric-stdlib/tests/http_h2fuzz_tests.l`: 20 of 20 (dotnet); `--target jvm`: 20 of 20.
- `LYRIC_H2_FUZZ_ITERS=5000 LYRIC_H2_FUZZ_SEED=1` on dotnet (39 s) and `LYRIC_H2_FUZZ_ITERS=3000 LYRIC_H2_FUZZ_SEED=900000` on the JVM (74 s): 20 of 20.
- `http_h2conn_tests.l` 82 of 82, `http_h2conn_client_tests.l` 70 of 70, `http_h2frame_tests.l` 70 of 70 (dotnet), unmodified.

Not run here: the `nghttpd` interop half of `h2conn-tests.sh` (no package install), native (not claimed), the nightly workflow itself.
