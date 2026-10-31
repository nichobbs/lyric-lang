# D297 — Release contract policy, `--shape standalone`, and defines on the packaging shapes (#6263, #6262)

**Status:** accepted, implemented

Closes the remaining parts of #6263 (D163 settled overflow) and #6262, both
docs/63 band B0 follow-ups. #7971 is not part of this decision (see
Consequences).

## Context

The profile axis reached integer overflow (D163) and the native `-O` level, but
not contracts: book chapter 17 section 17.4 described a release policy
(`requires:` on `pub` functions kept, internal `requires:` and `ensures:`
elided, `--release-contracts` to opt back in) that no pass implemented.
`--shape standalone` was rejected with `F0044` on every target. The packaging
shapes also rejected `--define` and `[build.define]`, although the staging
artifact they package is compiled by the ordinary build.

## Decision

1. **Contracts follow the profile.** In a `release` build, for a free function,
   `ensures:` is not checked and `requires:` is checked only when the function
   is `pub`. Range subtype checks, type invariants, loop invariants and
   `@proof_required` packages are never elided; the standard library is never
   elided (like D163 it behaves the same prebuilt or compiled into the
   program). Two ways to keep every check: `--release-contracts` (which sets the
   `release_contracts=full` define) and `@runtime_checked(release_contracts =
   full)` on the package. The clauses stay on the `FunctionDecl`, so contract
   metadata and the verifier see what the author wrote.
   Mechanism: `Lyric.Pipeline.pipeParseAndErase` marks a file
   (`__lyric_release_elide`) from the resolved `build_profile` and
   `release_contracts` defines and the package annotation, and
   `Lyric.ContractElaborator.elaborateItem` elaborates a marked free function
   from a view without the elided clauses. No backend changes: all three
   targets behave the same.
   Methods in `impl` blocks, records and protected types keep every check for
   now (partial: tracked in #8680).

2. **`--shape standalone` is a directory with a bundled runtime** that is still
   JIT-compiled (.NET) or interpreted (JVM), so reflection and dynamic loading
   keep working.
   - dotnet: the apphost template from the SDK's `Microsoft.NETCore.App.Host.<rid>`
     pack with the application name patched over its placeholder, the installed
     shared runtime and `hostfxr` copied beside the program, and a
     `runtimeconfig.json` with `includedFrameworks` instead of `framework`. No
     `dotnet publish`, no NuGet restore: everything comes from the installation
     that runs the compiler. Linux hosts.
   - jvm: `jdeps` finds the modules the program needs, `jlink` builds a runtime
     image from them (plus the modules the runtime support classes reach
     without a static reference), the program and Maven jars go in `lib/` and a
     shell launcher runs `runtime/bin/java -cp lib/*`. Linux and macOS hosts.
   - Only the host RID can be built (the runtime is the one on the build
     machine). A directory a previous standalone build wrote is replaced
     (a marker file identifies it); any other non-empty directory is refused.
   - `F0044` is retired and its number not reused.

3. **Defines reach the packaging shapes.** `buildReleaseSingle` and
   `buildReleaseProject` pass `--define` values to the staging compile, and
   `manifestDefineGateError` is removed; `defineBuildGateError` rejects only
   `--watch` and a non-consumable target.

## Consequences

- #6263 is complete: profile reaches overflow (D163), the native `-O` level
  (D-progress-913) and contracts (here). The remaining line of its original
  list, "no optimization difference on dotnet/jvm", is not a defect: Lyric has
  no IL or bytecode optimizer to gate, and the runtime JITs.
- #6262 is complete for the supported hosts; macOS and Windows hosts and
  cross-RID bundles are #8681.
- #7971 (cache the bundled-stdlib type check) is not done. The check returns
  the lowered package, not only a verdict, so a cache must store a `SourceFile`
  and the AST has no serialised form; see the plan on that issue.
