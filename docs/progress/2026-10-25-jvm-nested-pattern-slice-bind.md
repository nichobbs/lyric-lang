# JVM: a slice bound through a nested constructor pattern keeps its type

On `--target jvm`, `case Ok(Some(bytes))` against a
`Result[Option[slice[Byte]], String]` bound `bytes` as an erased `Object`,
so `for b in bytes` took the `Iterable` loop path against a raw `Byte[]` and
threw `IncompatibleClassChangeError` at run time. A single-level
`case Some(bytes)` was fine, as was dotnet.

`bindCaseField` (`lyric-compiler/jvm/codegen/03_match.l`) recursed into a
nested constructor, record or tuple sub-pattern with an empty
instantiation, so the inner case's type-parameter payload could not resolve.
It now passes the field's own type arguments (the scrutinee-resolved
`Option[slice[Byte]]`, or the field's declared instantiation when the field
is not a type-parameter payload), and the inner bind narrows the slice exactly
as the single-level form does.

Verified by two new cases in `nested_constructor_pattern_self_test.l`
(`for` over a nested-bound `slice[Byte]` and `slice[Int]`, values checked),
passing on dotnet and JVM. `lyric-stdlib/tests/process_piped_bytes_tests.l`
drops its index-loop `appendBytes` workaround for a plain `for`, passing on
dotnet, JVM and native.
