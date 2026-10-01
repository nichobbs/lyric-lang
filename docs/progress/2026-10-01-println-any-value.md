# `println(x)` prints `toString(x)` for any value; native `Byte` printing (#7858)

`println` is a built-in whose argument may have any type. The dotnet and JVM
backends only converted the types their console APIs have an overload for.
Everything else was passed through unconverted:

```lyric
extern type Ts = "System.TimeSpan"

println(Ts.FromMinutes(90.0))  // dotnet: InvalidProgramException
println(Point(x = 1, y = 2))   // dotnet: prints raw memory, then AccessViolationException
                               // JVM: VerifyError
```

On native, `println(<Byte>)` did not compile in a program that imports
`Std.Console`, `String + <Byte>` was rejected, and a `u8` literal was an `Int`.

Root causes:

- **dotnet.** The `println` match in `lowerBuiltinOrStaticCallMsil`
  (`lyric-compiler/msil/codegen.l`) sent every type it did not list to
  `Console.WriteLine(string)`. A value type (an extern struct such as
  `System.TimeSpan`, `System.DateTime`, `System.Guid`, `System.Decimal`,
  `System.IntPtr`, or a `System.Single`, which auto-FFI maps to an extern value
  type) was invalid IL. A reference type (a record, union, `List`, slice) was
  read as if it were a `String`: the CLR does not check the argument, so the
  object's fields were used as a string length and characters.
- **JVM.** `printArgType` (`lyric-compiler/jvm/codegen/04_calls.l`) chose
  `PrintStream.println(String)` for every reference other than `Object`. A
  record, a list, an array or an extern object such as `java.time.Duration`
  failed verification.
- **native, `println`.** The prelude `println` was only a fallback, reached
  when name resolution failed. With `Std.Console` in the import closure (as in
  every `@test_module`, through `Std.Testing`), `println(<Byte>)` resolved to
  `Std.Console.println(String)` and was rejected.
- **native, `String +`.** `lowerBinop` (`lyric-compiler/lyric/llvm_codegen.l`)
  only stringified a `Char` operand.
- **native, `u8` literals.** `lowerLiteral` ignored the `u8` suffix. Where no
  expected type narrowed it, the literal was an `Int`: `val b = 200u8` was an
  `Int` binding, `b + 100u8` was `300` instead of `44`, and
  `Box(value = 255u8)` was a `Box[Int]`.

Fixes:

- dotnet: the `toString` builtin's lowering is now the helper
  `emitStackValueToStringMsil`. `println`'s catch-all, `print`'s catch-all and
  `toString` all use it, so `println(x)` prints `toString(x)`. That includes
  `Double`, which now prints in the invariant culture like `toString`, instead
  of through the culture-sensitive `WriteLine(double)`. The helper also boxes
  an open generic parameter (`MTypeVar`) through its VAR TypeSpec before
  `ToString()`. The unused `Console.WriteLine(double)` MemberRef keeps its row
  so the rows after it do not move.
- JVM: `normalizeByteAndRefPrintArg` (formerly `normalizeBytePrintArg`)
  stringifies every non-`String` reference and every array through
  `coerceToStringForConcat`, the helper `toString(x)` uses.
- native: `println` is intercepted with the other builtins in `lowerCallEx`,
  unless a non-`Std` package declares its own `println`. `String + x`
  stringifies a `Byte`, `Long`, `Bool` or `Double` operand. An `Int` operand
  is still rejected, because `Int` and `Char` share `i32` and the
  best-effort `Char` tracking cannot always tell them apart. A `u8` literal
  lowers as `i8`.

Native was already right for `toString(b)`, `b.toString()`, interpolation, and
`Byte` arithmetic on typed bindings (wrapping, unsigned `/`, `%` and
comparison).

Tests:

- `lyric-compiler/lyric/println_stringify_self_test.l` (dotnet and JVM)
  prints a record, two union cases, a `List`, a slice, a generic payload and
  two `Double`s, each followed by its `toString`.
- `println_extern_struct_dotnet_self_test.l` covers `TimeSpan`, `DateTime`,
  `Guid`, `Decimal`, `Single` and `IntPtr` through auto-FFI.
- `println_extern_jvm_self_test.l` covers `java.time.Duration` and
  `java.time.LocalDate`.
- `scripts/ci/println-stringify-e2e.sh` runs those three and checks that each
  printed value equals the `toString` printed after it.
- `byte_native_self_test.l` (`--target native`, 8 cases) covers `toString`,
  `.toString()`, interpolation and `String +` of a `Byte` from a local, a
  field, a slice element, a call result and a `Box[Byte]` field, plus
  wrapping arithmetic, unannotated `u8` literals and `println`.
  `byte-println-e2e.sh native` checks the printed text.

Results before the fix:

- dotnet: `println_extern_struct_dotnet_self_test` failed with
  `InvalidProgramException`. `println_stringify_self_test` printed raw memory
  and crashed with `AccessViolationException`. ilverify reported 6 and 7
  `StackUnexpected` errors in the two DLLs.
- JVM: both tests failed with `VerifyError`.
- native: `byte_native_self_test` did not compile (the `println` and
  `String +` cases). With those removed, the unannotated-literal case failed
  with `expected=44 actual=300`.

After the fix, all pass on every target, both DLLs pass ilverify with 0
errors, and both e2e scripts pass.

Wiring:

- The dotnet tests are in `compiler-self-tests-batch.sh` and
  `scripts/ilverify-selfhosted.sh`.
- The dual-target test and the JVM test are in
  `jvm-generics-self-tests-batch.sh`.
- `println-stringify-e2e.sh` is a sharded entry in
  `compiler-self-tests-batch.sh`.
- `byte_native_self_test.l` and `byte-println-e2e.sh native` run in
  `scripts/ci/native-backend-self-tests.sh`.
