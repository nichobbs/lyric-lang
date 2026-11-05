# D400 - No kernel extern writes the elements of a slice Lyric code holds (#8730)

**Status:** accepted, implemented.

## Context

T0157 (#8731, docs/01 §2.7) stops Lyric code writing a slice element, but
three dotnet kernels still handed `System.IO.Stream.Read(byte[], int, int)` a
`slice[Byte]` held in a record field and read it back
(`_kernel/tcp_host.l`, `_kernel/console_host.l`,
`_kernel/process_piped_host.l`). `process_piped_host.l` also bound a
`MemoryStream`'s backing array, which later `Write` calls change, as a
`slice[Byte]`, and `_kernel_jvm/http_host.l` bound a `ByteBuffer`'s backing
array, which the next `SocketChannel.read` overwrites. Because a slice's
storage could change under a binding, `lyric prove` read a slice element as a
fresh value at each read (#8728), so a contract could not rely on two reads of
`xs[i]` agreeing.

## Decision

1. **Invariant.** No extern writes the elements of a `slice[T]` that Lyric
   code holds (a variable, parameter or field of slice type). A slice's
   elements never change once it exists. docs/14 §10.2 states the rule per
   target.
2. **dotnet kernels.** Read scratch storage is a host `MemoryStream`
   (`MemStream` field). Its backing array is fetched with `GetBuffer()` as the
   argument of the call that fills it, or indexed straight off that call, and
   the bytes a read produced are returned as a copy (`.slice(0, n)`). The
   reused per-connection and per-handle scratch (#7269) is kept, so a read
   still allocates only the bytes it returns.
3. **JVM.** `readToEnd` passes `buf.array()` straight to
   `ByteArrayOutputStream.write` instead of binding it. The other JVM kernels
   already read into fresh arrays.
4. **Ecosystem.** `lyric-mail` wraps attachment bytes in a read-only
   `MemoryStream(byte[], false)`. No other ecosystem kernel passes a slice to
   a host method that writes it; native kernels return fresh slices from
   `lyric-rt`.
5. **Verifier.** With the invariant in place, `lyric prove` models a slice
   element read as `select` of the slice's elements, as it does for arrays
   and buffers (docs/15 §5.2), and a contract can speak of slice elements.

## Alternatives considered

- **A host `byte[]` extern type alias** (`extern type ByteArray =
  "System.Byte[]"`) as the scratch. Cleaner types, but the MSIL backend
  erases an array alias to `object` in `@externTarget` signatures, so
  `Stream.Read` binds as `Read(object, int, int)`. Fixing that in the compiler
  does not help the stdlib the CLI itself runs, which stage 1 builds with the
  released seed; the kernels would have been broken in the CLI until the next
  release.
- **`buffer[Byte]`.** On dotnet and the JVM a buffer is a `List[T]` (D185),
  which `Stream.Read` cannot fill without `Span<byte>`, and the FFI cannot
  pass a by-ref-like type (docs/66 gap 1b).
