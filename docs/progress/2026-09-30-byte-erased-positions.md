# A `Byte` survives erased positions on both targets (#7852)

Follow-up to `2026-09-30-byte-stringify.md`. A `Byte` function value crashed
on dotnet:

```lyric
val f: () -> Byte = { -> 128u8 }
val b: Byte = f()   // InvalidCastException: Int32 -> Byte
```

On dotnet a lambda is a `Func<object,…,object>`. Its result and arguments
are boxed, and the reader unboxes them by the declared type. Three `Byte`
producers were typed `MInt`, so they boxed as `System.Int32` and the
reader's `unbox.any System.Byte` threw:

- **A `u8` literal.** `lowerExprMsil` typed it `MInt`, even though the
  list-literal element predictor already typed it `MByte`.
- **`Byte op Byte` arithmetic.** `+`, `-` and `*` returned `MInt` and never
  narrowed. So `{ x -> x + 1u8 }` crashed the same way, and
  `toString(200u8 + 100u8)` was `"300"` on both targets, although every
  `Byte` store wraps it to 44.
- **An inlined literal module `val`/`const`.** Every read returned `MInt`
  whatever the val's type. `{ -> LIT }` threw the same way for a `Byte`,
  `Bool` or `Char` val, and `println(LIT_BOOL)` printed `1`.

The JVM had two related bugs:

- A `u8` literal was an `int`. It boxed as `java.lang.Integer` into a
  generic position (`Some(200u8)`, `Box(value = 203u8)`, a `List[Byte]`
  element), and the `Byte` checkcast failed. `Byte op u8` did not wrap.
- An erased `Object` holding a boxed `java.lang.Byte`, such as a lambda
  parameter typed by a type argument, stringified through
  `Byte.toString()`. It printed 128..255 as negatives through `toString`,
  `.toString()`, interpolation, `+` and `println`.

Fixes (functions touched):

- **MSIL** (`lyric-compiler/msil/codegen.l`):
  - The `ELiteral` arm of `lowerExprMsil` types a `u8` literal `MByte`, and
    `inferUntypedStaticValMsilType` predicts it the same way.
  - The new `wrapByteArithMsil` makes a `Byte op Byte` result `conv.u1` and
    `MByte`. It is used in `lowerBinopMsil`'s `BAdd`/`BSub`/`BMul` int arms.
    A mixed `Byte op Int` pair still widens to `MInt`.
  - The `BAdd`/`BSub`/`BMul` predictors in `inferUntypedStaticValMsilType`
    and `inferLambdaBodyExprMsilType` match (`byteArithRhsMsilType`).
  - New `CodegenCtx.constValueTypes`, written by `addConstValueMsil` at all
    three literal-const registration sites (`registerLiteralConstMsil`, and
    the `IConst`/`IVal` static-field emission). The bare and qualified const
    reads return the recorded type through `constValueTypeMsil`.
- **JVM** (`lyric-compiler/jvm/codegen/`):
  - `lowerExpr`'s literal arm types a `u8` literal `JByte`.
  - The new `wrapByteArithJvm` masks a `Byte op Byte` result and keeps it
    `JByte`, in `BAdd`/`BSub`/`BMul`.
  - A new lazily emitted `__lyricErasedToString(Object)` helper
    (`makeErasedToStringHelperFunc`) renders a boxed `Byte` unsigned and
    anything else through `String.valueOf(Object)`. It is reached from
    `coerceToStringForConcat` (an erased `Object` operand),
    `normalizeBytePrintArg` (`println`/`print`) and `lowerMethodCall`'s
    `.toString()` on an erased receiver.

The language reference (docs/01 §2.1) now states that `Byte op Byte` is a
`Byte` that wraps modulo 256.

Tests:

- `lyric-compiler/lyric/byte_erased_positions_self_test.l` is new and dual
  target, with 8 cases:
  - `Byte` literals as a function value's result (local, returned, generic,
    from a list) and as its argument;
  - captured `Byte`s;
  - wrapping `Byte` arithmetic, including inside a function value;
  - a `u8` literal in `Option`, a generic field and a `List`;
  - erased `Byte` stringification;
  - literal `Byte`/`Bool`/`Char` module vals through function values and
    generic fields;
  - `UInt`/`ULong`/`Char`/`Bool`/`Double`/`Long` through function values.
- `byte_stringify_self_test.l` gains "a Byte from an erased position widens
  unsigned" (generic payload, list element and function-value result
  through `.toUInt()`/`.toULong()`).

Results:

- Before, measured with the same cases as standalone programs on the
  pre-fix compiler:
  - dotnet failed every function-value case that used a `u8` literal, a
    `Byte op Byte` result or a literal module val, with InvalidCastException.
    Arithmetic read back `"300"`.
  - The JVM failed the arithmetic case (`"300"`, `"400"`), the generic
    literal case (`Integer` cannot be cast to `Byte`) and erased
    stringification (`"-50"`).
- After: 8/8 on both targets. `byte_stringify_self_test.l` is 8/8 on both,
  and `byte_arithmetic_self_test.l` is 17/17 on both.
- The new test is in `compiler-self-tests-batch.sh`,
  `jvm-generics-self-tests-batch.sh` and `scripts/ilverify-selfhosted.sh`
  phase 4.
