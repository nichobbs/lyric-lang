# lyric restore skips the Maven resolver for native builds (2026-11-06)

`lyric restore --target native` no longer runs `restoreMavenJars`, and `lyric build --target native`'s
auto-restore passes `native`. A native build never links Maven artifacts (docs/01 section 3.6), so a
native-only project that reaches lyric-web or lyric-ws through its path dependencies restores without a
Java 21+ runtime (#8836). `--target dotnet|jvm` and no flag restore as before.

Not done in this slice, tracked on #8836: skipping the NuGet `dotnet restore` for non-dotnet targets, and
dropping the Java 22 setup step from `windows-build.yml`'s `graphics` job (needs the Windows runner to
verify).
