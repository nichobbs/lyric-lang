# MSIL: extern members of `List<T>`/`Dictionary<K,V>` bind on concrete receivers; unknown collection methods fail the build (#7422)

An `@externInstance` binding to a member of the BCL's generic `List`1` or
`Dictionary`2` (for example `List<T>.AddRange`) compiled, but its wrapper cast
the receiver to the `<object,…>` erasure. A Lyric `List[Byte]` or
`Map[String, Int]` is a real `List<byte>`/`Dictionary<string, long>` at run
time, so every call threw `InvalidCastException` on entry.
`emitGenericExternMember` now takes the closed instantiation from a concrete
`List`/`Map` receiver, as it already did for an `MGenericInst` receiver.

A method that no collection intrinsic, `Std.Collections` function or extern
binding implements (`list.addRange(xs)`, `list.toSlice()`) on a `List`, `Map`
or `Set` receiver used to compile to a stub that threw only when the call ran.
It is now a build error, as it already was on the JVM (J008) and as the
`String` case became in #7099.

The build error found one such call in shipped code: `lyric-generator-sdk`'s
request decoder called `List.toSlice()`, which no backend implements, so on
dotnet `runGenerator` threw for any request whose type had fields or type
parameters. It now uses `toArray()`, and the decoder is exposed as
`parseRequest` (the inverse of `serializeRequest`) with round-trip tests.

With the binding fixed, the dotnet HTTP server kernel appends each
request-body chunk with one `List<byte>.AddRange` instead of an `Add` per byte
(#7269), matching the native kernel (#7423).

Verified by two `msil_project_bridge_self_test.l` cases (the unknown `List`
method is a build error; `List`1.AddRange` and `Dictionary`2.TryAdd` bound on
concrete receivers run correctly), `http_server_dotnet_tests.l` (25/25,
including an HTTP/2 body far larger than the receive window), the 38 dotnet
stdlib runtime suites, the dotnet test suites of every ecosystem library, and
the example packages.
