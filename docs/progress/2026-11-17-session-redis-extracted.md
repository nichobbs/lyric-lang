# lyric-session loses its Redis backend; Lyric.Session.Redis replaces it (D614)

`NativeSessionStore`, `connectRedis()`, `Session.Kernel.Net` / `Session.Kernel.Jvm`, the `dotnet` / `jvm` features, the `[nuget]` / `[maven]` tables, the unused `Lyric.Cache` dependency and `tests/session_redis_jvm_tests.l` are removed from `lyric-session`. The package is pure Lyric: `lyric test --manifest lyric-session/lyric.toml` passes on `--target dotnet`, `--target jvm` and `--target native` with no `--features` flag and no `lyric restore`, and its manifest now says `targets = ["dotnet", "jvm", "native"]`.

The Redis store is `Lyric.Session.Redis` (`session-redis`) in lyric-ecosystem: one Lua script per read-modify-write, conformance suite against a real server, no third-party library. `lyric-session/README.md` carries the migration note (option mapping, different key layout and id format, existing sessions are not carried over).

CI: `scripts/ci/session-tests.sh` is now a plain `lyric test`; the JVM ecosystem runner no longer Maven-restores `session`; the `session` `ECO_DEPS` / matrix `deps` are empty (`ci.yml` shrank by 22 bytes, 499467 of 500000). Docs updated: `docs/71` phase 4 progress, the book's ecosystem matrix (chapter 29) and quick reference, `README.md`, `CLAUDE.md`, `docs/05`, `docs/24`.

Phase 4 of docs/71 (D552, D561, D614).
