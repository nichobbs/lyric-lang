# D607 - `lyric test --manifest --target native` (#6815 item 3(b))

**Status:** shipped.

## Context

D-progress-912 left the native manifest test run out: the dotnet and JVM
implementation resolved dependencies as built DLLs, and native has no built
form of a Lyric package. Since #7833 a native project build compiles `path`
and `{ workspace = true }` dependencies from source, which is all a test run
needs.

## Decision

1. `cmdTestManifest` serves the three targets. Native takes the JVM's route
   through it: no dependency is built on its own, the dependencies' packages
   are collected as source (transitively, each with its own manifest's
   features) and compiled with the project's packages. A registry or git
   dependency is an error, as in `lyric build --target native`.
2. One executable per `[project.tests]` entry, built by
   `Emitter.emitNativeProject` from the synthesised test package, the
   project's packages and the dependencies' packages. The synthesised package
   is first, so its `main` is the entry point; a test module that declares a
   `[project.packages]` package is merged into it, as on the other targets.
3. No shared library build. Dotnet and the JVM build the `[project.packages]`
   library once and link each entry against it (#8648, #8667); a native binary
   is one whole-program compile, so each entry compiles the library again.
4. The binary is built for the host, since the command runs it. The
   manifest's `[native] opt_level`, `extra_libs` and `[native.libs]` (its own
   and its dependencies') apply; `[native] triple` does not.
5. A native test runs straight through with no exception unwinding (D-N-003,
   D-N-018), so a failed assertion ends the entry's process. The runner reads
   the TAP text the binary wrote: when it exits nonzero without its summary,
   the runner prints `not ok <n> - <title>` for the test after the last `ok`
   or `# skip` line and a line saying how many later tests did not run. The
   entry counts as failed and the remaining entries run. The single-file form
   reports the same way.
6. `--properties` and `--coverage` stay unavailable on native, for the reasons
   their own diagnostics give.

## Alternatives

- A process per test, so every test of an entry runs whatever the others do.
  It multiplies the run time of suites that start servers in a test and gives
  module-level state a different lifetime from the other targets.
- Linking each entry against a native static library of the project. The
  native backend lowers generics, reachability and module initialisers over
  the whole program; it has no separate compilation to link against yet.
