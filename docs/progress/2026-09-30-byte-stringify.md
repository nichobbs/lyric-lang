# A `Byte` prints and stringifies unsigned on both targets (#7852)

`Byte` is unsigned, 0..255. Printing or stringifying one was broken on both
backends:

```lyric
val b: Byte = 200u8
println(b)            // dotnet: InvalidProgramException
toString(128u8)       // JVM: "-128"
byteId(200u8).toString()  // JVM: "-56"
```

Root causes:

- **dotnet `println` had no `Byte` arm.** `lowerBuiltinOrStaticCallMsil`'s
  `println` match covered `Int`, `Long`, `Double`, `Bool` and `Char`; a
  `Byte` fell through to the catch-all, which calls
  `Console.WriteLine(string)` with an int32 on the stack. The CLR rejected
  the method. Every other dotnet site was already correct: `toString`,
  interpolation, `String +` and `format1`/`format2` box a `Byte` as
  `System.Byte`, whose `ToString()` is unsigned.
- **JVM `toString(<Byte>)` boxed to a signed `java.lang.Byte`.** Boxing
  narrows with `i2b` (the wrapper's invariant), so `Byte.toString()`
  printed 128..255 as negatives.
- **A JVM call returning `Byte` returned the signed byte.** A Lyric function
  returning `Byte` has descriptor return type `B`. `ireturn` narrows as if by
  `i2b` (JVMS §6.5), and the caller did not re-mask the result to the
  canonical unsigned form (docs/59 §4.3). Interpolation and `String +`
  already re-masked defensively, but `.toString()` on a primitive receiver
  and `println` did not.

Fixes:

- MSIL: `println` has an `MByte` arm that calls `Console.WriteLine(int32)`.
  Every `Byte` load (`ldloc`, `ldfld`, `ldelem.u1`, `conv.u1`, a call
  return) zero-extends, so the int32 overload prints the unsigned value
  (`lowerBuiltinOrStaticCallMsil`, `lyric-compiler/msil/codegen.l`).
- JVM:
  - The `ECall` arm of `lowerExpr` (`02_exprs.l`) re-masks a `JByte` call
    result with `maskByteUnsigned`. This is the single point every call
    expression's value passes through.
  - The builtin `toString` routes a `JByte` argument through
    `coerceToStringForConcat`, which masks and calls `String.valueOf(int)`.
  - `.toString()` on a primitive receiver masks a `JByte` before
    `String.valueOf`.
  - `println` and `print` normalise a `JByte` argument to a masked `int`
    with the new `normalizeBytePrintArg`.

  These touch `lowerBuiltinOrStaticCall` and `lowerMethodCall`'s
  primitive-`toString` block in `04_calls.l`. None of them changes `UInt`
  or `ULong` handling.

Tests:

- `lyric-compiler/lyric/byte_stringify_self_test.l` (dual target, 7 cases)
  covers `toString(b)`, `b.toString()`, `"${b}"`, `String + b` and
  `println(b)`. It reads the `Byte` from a local, a record field, a slice
  element, a call result and a generic `Box[Byte]` field, with values 0, 127,
  128 and 255.
- `byte_stringify_dotnet_self_test.l` (2 cases) covers
  `format1`/`format2`. It is dotnet-only because the JVM `format*` builtins
  are stubs that return the template unformatted (#7367/#7840).
- A test cannot capture its own stdout, so `scripts/ci/byte-println-e2e.sh`
  runs the dual-target test on both targets and compares the lines
  `println` wrote.

Results:

- dotnet before: the println case threw `InvalidProgramException`.
- JVM before: 4 of 7 cases failed: toString of a local, a call result and a
  generic field; `.toString()` of a call result; and `println` of a call
  result printed `-56`.
- After: 7/7 on both targets, plus 2/2 dotnet format cases. Both test DLLs
  pass ilverify.

Wiring:

- Both tests are in `compiler-self-tests-batch.sh`, as is the println e2e
  (as a sharded entry).
- The dual-target test is also in `jvm-generics-self-tests-batch.sh`.
- Both test DLLs are in `scripts/ilverify-selfhosted.sh` phase 4.
