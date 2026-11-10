# lyric restore restores only what its target links (2026-11-10)

`lyric restore --target dotnet|jvm|native` (and `lyric build`'s auto-restore, which passes its own target)
now restores only what that target links: the Maven resolver runs for `jvm` only, so neither a native nor a
.NET build needs a Java 21+ runtime to restore; the `[nuget]` `dotnet restore` is skipped for `jvm` and
`native` unless the project has registry dependencies, whose packages it also downloads to record their
SHA-512 in `lyric.lock` (the lock does not depend on the target). With no `--target`, restore does
everything, as before (#8836, which #8867 began for `native`).

The Windows `graphics` job's Java 22 setup step is removed and its script restores with `--target native`;
its CI run is the check on the Windows runner.
