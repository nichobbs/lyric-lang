# The library census restores [maven] dependencies, and the stdlib bundle is a .NET package (docs/70 phase 3a, #8613)

**Status:** shipped; CI script and manifest only, no compiler change.

## Context

The TIR gate (D347) stops a body the builder cannot type. On `--target jvm` the builder types a host call from the host's metadata (D444), and the JVM metadata reads a `[maven]` class from the jars `lyric restore` puts under `target/restore/`. `library-tyerr-census.sh` built every manifest without restoring, so the host metadata could not name an Undertow, Jakarta Mail or gRPC class and the gate reported 30 to 40 I0002 bodies per library (`lyric-grpc`, `lyric-mail`, `lyric-web`, `lyric-ws`, and `lyric-testing` through mail). With the jars restored the same four libraries build with no I0002.

`lyric-stdlib/lyric.toml --target jvm` compiled the `.NET` kernel files (`std/_kernel/string_host.l` declares `System.Text.StringBuilder`), which no JVM build ever does: the source loader prefers the `std/_kernel_jvm/` twin of each kernel. The JDK metadata cannot name `System.Text.StringBuilder`, so `hostNewBuilder` was stopped.

## Decision

1. The census restores before each JVM build (`lyric restore --manifest M --target jvm`), building the Maven resolver first when `LYRIC_MAVEN_RESOLVER` names no jar. A restore that fails leaves the build unchecked (D386), never clean. This is what a real JVM build does, with no exemption list.
2. `lyric-stdlib/lyric.toml` declares `targets = ["dotnet"]` (D603): it is the `.NET` assembly `Lyric.Stdlib.dll`. The JVM reads the standard library through the loader, and every JVM program the self-tests build covers those packages.

## Results

`lyric-grpc`, `lyric-mail`, `lyric-web`, `lyric-ws` and `lyric-testing` build for the JVM with no I0002 on a binary built from the gate branch. `lyric build --manifest lyric-stdlib/lyric.toml --target jvm` reports F0054.
