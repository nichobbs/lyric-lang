# Native builds stop on type errors (#7910)

`lyric build --target native` and `lyric run --target native` printed
type-checker errors and carried on. A file with a `T0042` built with exit 0,
and its binary ran:

```lyric
func main(): Int {
  println()          // T0042 on every target
  val b: Bool = 1    // T0060 on every target
  println(toString(b))
  0
}
```

The native build failed only when LLVM codegen itself failed (`N0007`), so
any type error that codegen happened to lower shipped as a native binary.

**Root cause.** `Lyric.Pipeline.pipeCheckAndMono` gates on type-check errors
when `MiddleEndOptions.tcFatal` is set (D-progress-647). `Msil.Bridge` sets it
for every user package and `Jvm.Bridge` for every project package, but
`Lyric.LlvmBridge` built its options with `tcFatal = false, tcReport = true`
at both of its entry points (`compileToNativeWithFlags` for single files and
`compileProjectToNativeWithFlags` for projects and their source-compiled
dependencies, #7833). The pipeline then only echoed the diagnostics. Every
native command goes through those two functions, so single-file `build`,
`run`, `test`, `--define` builds, project builds and path or workspace
dependencies all shipped ill-typed code. The other passes (mode check,
contract elaboration, `?`-propagation, mono, weave) already gated.

The type check was left advisory because the checker did not know the native
FFI intrinsics of docs/01 §11.6. Any program using them got spurious
`T0010`/`T0020` errors: `NativePtr[T]`, `NativeWeak[T]`, `nativeAddrOf`,
`nativeNullPtr`, and `upgrade()` on a weak reference.

**Fix.**

- `Lyric.LlvmBridge` builds both `MiddleEndOptions` with `tcFatal = true`,
  `tcReport = false`, the same as `Msil.Bridge`. Errors fail the build before
  codegen and no binary is written. The diagnostics are printed in the same
  `<path>: error[T....] line:col: ...` form the other targets use, followed by
  `B0001 ... native compilation failed`. Warnings (e.g. `W0002`) still only
  print.
- The type checker types the native intrinsics, on a native check only.
  `MiddleEndOptions.nativeIntrinsics` (set by the native bridge) selects the
  new `checkWithImportedPackagesForNative`. That function registers
  `NativePtr[T]` and `NativeWeak[T]` as package-less types
  (`SymbolTable.nativeIntrinsicTypes`). It also types the calls
  `Lyric.LlvmCodegen` intercepts by name: `nativeNullPtr()` is a
  `NativePtr[Byte]`, `nativeAddrOf(x: T)` is a `NativePtr[T]`,
  `NativeWeak(x: T)` is a `NativeWeak[T]`, and `upgrade()` on a
  `NativeWeak[T]` is a `Std.Core.Option[T]`. On dotnet and JVM these stay
  `T0010`/`T0020`, since neither backend can lower them.

**Tests that only passed because type errors were ignored.**

- `llvm_tls_self_test.l`, "Std.TcpHost native plain round-trip": the test
  program called `encodeUtf8`/`tryDecodeUtf8` without `import Std.Encoding`
  (`T0020`). It now imports it.
- `llvm_tls_self_test.l`, `llvm_http_client_self_test.l` and
  `llvm_http_server_self_test.l`: their pthread client threads use
  `NativePtr`/`nativeAddrOf`/`nativeNullPtr`. These errors were spurious and
  are fixed by the type checker change above. The programs are unchanged.
- `llvm_self_test_self_iface.l`, "Self nested inside a generic type argument
  fails the full native build cleanly": the program used `List`/`newList`
  with no stdlib and no import. It passed only because the type check was
  advisory and the `N0006` pre-pass failed the build later. The program now
  imports `Std.Collections` and the build bundles the real native stdlib, so
  `N0006` is still the error that fails it.
- `llvm_project_self_test.l`, the `@cfg(feature = ...)` gating test (#6818):
  it expected the call to an erased function to panic in codegen ("cannot
  resolve call target"). The call is now a `T0020` that fails the build
  cleanly before codegen, which is what the test now asserts.

**Regression test.** `scripts/ci/native-type-error-gate.sh`, run from
`native-target-smoke-test.sh` in the `native-backend-self-tests` CI job. A
program with a `T0042` and a `T0060` must fail each of these with a non-zero
exit and both diagnostics, writing no binary and printing no program output:
single-file `build`, `build --define`, `run`, `test` (a `@test_module`), a
project build, and a project build whose path dependency has the error. A
clean program whose only diagnostic is a `W0002` warning must still build and
run, through both `build` and `run`. Before the fix all six rejection checks
failed: exit 0, a binary was written, and the program ran.
`typechecker_self_test.l` adds three cases for the intrinsics: they type
cleanly on a native check, are `T0010`/`T0020` on a managed check, and are
type-checked like any other value (`T0060`, `T0042`).
