# `for` over an auto-FFI call result iterates through the host enumerator (#8604, #7770, D308)

`for line in File.ReadLines(path)` (with `import extern System.IO.{ File }`)
compiled on `--target dotnet` and failed with `InvalidCastException:
ReadLinesIterator -> List<object>`: the checker does not type an auto-FFI call
result, so D302's marked-loop lowering never applied. `emitCollectionForMsil`
now reads the lowered host type's iteration protocol from the reference-pack
metadata (`hostIterElemOfMsilType`) and uses the enumerator protocol, with
element type `T` of `IEnumerable<T>` (the type's arguments substituted), so the
loop variable is a `String` here and the enumerator is disposed on every exit.

#7770: `for_loop_dispose_extern_self_test.l` (dotnet) and
`for_loop_dispose_extern_jvm_self_test.l` (JVM) iterate a Lyric record that
implements the host's `IEnumerable`/`IEnumerator`/`IDisposable`
(`Iterable`/`Iterator`/`AutoCloseable`) and count disposals: exactly once on
end, `break`, `return`, `?`, `break outer`, `continue outer` and a caught panic;
a panicking disposal reaches the caller on a normal exit and loses to the
consumer's panic (D143). `extern_iter_self_test.l` and
`extern_iter_jvm_self_test.l` cover the call-result shapes. The dotnet disposal
and extern-iter tests also run under `make ilverify`.
