# Native builds type-check the stdlib packages they bundle (#7933)

A `--target native` build compiles the `Std.*` packages from source into the
binary. `Lyric.LlvmBridge` ran the contract elaborator and `?`-propagation over
each bundled package but never the type check, so an ill-typed kernel or stdlib
body reached codegen. #7910 made the program's own type errors stop the build;
this does the same for the bundle.

## The check

`checkBundledStdlibPackage` (`lyric-compiler/lyric/llvm_bridge.l`) runs
`checkWithImportedPackagesForNative` over every package in the program's stdlib
import closure, on both the single-file and the project path, before the
package is elaborated. `NativePtr`/`NativeWeak`/`nativeAddrOf` are typed, and
`extern func` calls are checked against their declarations (#7921). An error
stops the build, labelled with the stdlib file's path:

```
…/std/_kernel_native/tcp_host.l: error[T0060] 931:3: val binding declared as Bool but initialiser has type Int
```

Stdlib warnings are not printed. Each package is checked against the packages
its own imports reach, in stdlib load order, not the whole stdlib.
`Lyric.Emitter.findStdlibSourcesNative` now returns each file with its path
(`LlvmBridge.NativeStdlibFile`), and the two bridge entry points share one
stdlib parse (`parseNativeStdlib`).

## What the check found

- `_kernel_native/http_host.l`: bare `TlsTrustSystemDefault`/`TlsTrustInsecure`
  (and the `Exclusive`/`Additive` cases) while importing `Std.TcpHost as Tcp`;
  now `Tcp.`-qualified. That spelling did not lower on native:
  `Lyric.LlvmCodegen` indexed a union case as `Case`, `Union.Case` and
  `pkg.Union.Case` but not `pkg.Case`, which is what the alias rewrite turns
  `Tcp.TlsTrustSystemDefault` into, so the value form failed with "qualified
  value reference ... is not yet supported". `registerUnionLayout` now adds the
  `pkg.Case` key too (item J of `llvm_enum_case_resolve_self_test.l`).
- `std/http_hpack.l`: a bare `toInt(c)` through the aliased `import Std.Char as
  Char`; now `Char.toInt(c)`.
- `Std.Console`, `Std.Environment`, `Std.ProcessCapture` and `Std.Directory`
  call kernel entry points the native kernels never declared. Every native
  program imports `Std.Console`, so each is now implemented in its
  `_kernel_native/` twin:
  - `console_host.l`: `hostReadLineOpt`, `StdinHandle`, `HostStdinRead`,
    `hostOpenStdin`, `hostStdinReadResult`, `hostStdinReadWithinResult`, over
    three new lyric-rt functions (`lyric_stdin_wait`/`_read`/`_read_line`,
    `poll(2)`/`read(2)` on fd 0, unbuffered; C unit tests added). A bounded
    read polls first, so a timed-out read consumes nothing.
    `Std.Console.openStdinReader`/`readStdin`/`readStdinWithin` now work on
    native; `readLine` still catches a host `Bug` and does not lower (D-N-003).
  - `process_capture_host.l`: `hostRunCapture`/`hostRunCaptureTimeout` decode
    the argument string with `Std.ProcessArgs.argvSplit` and run through
    `hostRunCaptureList`; `Std.ProcessCapture` now works on native.
  - `file_host.l`: `hostCreateDirectory`, `hostEnumerateFiles`,
    `hostEnumerateDirectories`, `hostEnumerateFileSystemEntries`,
    `hostDeleteDirectory`, `hostDeleteDirectoryRecursive`, over the existing
    Result seams, panicking on failure as the managed twins throw.
    `Std.Directory`'s own functions catch that throw and so still do not lower.
  - `environment_host.l`: `hostExit` over `exit(3)`. A function returning
    `Never` does not lower on native yet (#6901), so `Std.Environment.exitCode`
    still does not either.

## Tests

- `scripts/ci/native-stdlib-type-check-gate.sh` (run from
  `native-target-smoke-test.sh`): programs importing every `_kernel_native/`
  package and every public `Std` package build cleanly; with `LYRIC_STD_PATH`
  pointed at a temp copy of the stdlib whose `tcp_host.l` is ill-typed, a build
  that imports `Std.TcpHost`, and one that reaches it only through
  `Std.HttpHost`, fail with `error[T0060]` naming that file and write no
  binary. Before the change both builds succeeded.
- `lyric-stdlib/tests/native_kernel_twins_tests.l` (`lyric test --target
  native`): argv round-trip, stdout and timeout for `Std.ProcessCapture`, and
  create/enumerate/delete through the `Std.FileHost` directory entry points.
- `console_stdin_tests.l` runs on native through
  `scripts/ci/console-stdin-test.sh --target native`; only its negative-timeout
  `assertPanics` check is left out there, since a caught panic does not lower.

## Build time

`lyric build --target native` of a program importing `Std.Http`,
`Std.Collections` and `Std.Console`, 5 runs each, interleaved: 1.69 s before,
2.01 s after (+0.33 s). A program importing all 48 public `Std` packages: 1.62 s
before, 2.94 s after (+1.3 s).
