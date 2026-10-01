# Stdlib collection members check their arguments against the element type (#7969)

`xs.add(v)` on a `List[T]` did not check that `v` is a `T`. A test appended a
`String` to a `List[NativeStdlibFile]`, the type checker accepted it, and the
mistake only showed up at run time.

Root cause: `List`, `Map` and `Set` are extern types declared in
`Std.CollectionsHost`, and the backends resolve their methods. The checker had
no signature for them, so the `ECall` arm of `inferExpr`
(`lyric-compiler/lyric/type_checker/typechecker_exprs.l`) typed the callee as
`TyError`, found no method, and accepted any arguments. Only `add`'s unsigned
widenings were recorded (`recordCollectionAddWidenings`, #7805); nothing
compared the arguments with the receiver's type arguments.

Fix: `stdCollectionMemberParams` gives the parameters of each member that
takes an element, key, value or index, keyed on the receiver's stdlib
identity (`isStdCollectionsHostType`), so a package's own type named `List` is
not affected:

| Receiver | Member | Parameters |
|---|---|---|
| `List[T]` | `add`, `contains`, `indexOf`, `lastIndexOf`, `remove` | `T` |
| `List[T]` | `add(index, item)` | `Int`, `T` |
| `List[T]` | `removeAt` | `Int` |
| `Map[K, V]` | `add` | `K`, `V` |
| `Map[K, V]` | `containsKey`, `remove` | `K` |
| `Set[T]` | `add`, `contains`, `remove` | `T` |

When no signature or method resolved the call, `checkStdCollectionMemberArgs`
checks each argument with the rules of an ordinary call argument
(`argSatisfiesParam` and `listLiteralArgSatisfiesParam`): lossless widening,
interface conformance and a bracket literal where the element is a `List` are
accepted. A mismatch is **T0043**, naming the slot and the expected type:

```
argument type String of '.add' does not match List[NativeStdlibFile]'s element type NativeStdlibFile
```

The same parameter types are the expected types of the deferred argument pass,
so a lambda added to a `List[(Int) -> Int]` gets `Int` parameters and a
`None` added to a `List[Option[T]]` adopts the element instantiation. The
unsigned-widening record now covers every member in the table
(`recordCollectionArgWidenings`), not only `add`. Inside a generic body a type
parameter is checked as at any other call: `xs.add(x)` with `xs: List[T]`,
`x: T` is accepted, and `List[Box[T]].add(<String>)` is rejected.

This also settles the first item of #7786: `List[Double].add(1)` and
`m.add(k, anInt)` on a `Map[K, Double]` were accepted although docs/01 §4.1
makes `Int` to `Double` an explicit conversion; they are now T0043, like
`m["a"] = 4` already was (T0063).

Mismatches the check found, each fixed at the source rather than by weakening
the check. An integer literal is an `Int`, so a `Byte` element takes a `u8`
literal; a computed byte takes `.toByte()`, which reduces modulo 256 to the
unsigned `0..255`.

Compiler and stdlib:

- `Msil.Kernel.bufU1` (`lyric-compiler/msil/_kernel/kernel.l`) added the `Int`
  `((v % 256) + 256) % 256` to the `List[Byte]` PE buffer. It now adds
  `v.toByte()`, the same byte.
- `Msil.Bridge.embedLyricContract` and `embedLyricAnnotationMeta`
  (`lyric-compiler/msil/bridge.l`) added the four `Int` bytes of a resource's
  length prefix. They now add `jsonLen.toByte()`, `(jsonLen / 256).toByte()`,
  and so on.
- `Lyric.AppHost` (`lyric-compiler/lyric/app_host.l`) added the literal `0` as
  the apphost path's NUL terminator and padding. It now adds `0u8`.
- The JVM kernels `hostEncodeUtf8`/`hostFromBase64`
  (`lyric-stdlib/std/_kernel_jvm/encoding_host.l`) and `urlDecode`
  (`lyric-stdlib/std/_kernel_jvm/http_server.l`) added computed UTF-8 and
  Base64 bytes as `Int`s. They now convert each with `.toByte()` (every value
  is already in `0..255`) and add the U+FFFD bytes as `u8` literals.

On dotnet these happened to work, because the IL for `List<byte>.Add` takes the
`int32` on the stack. The JVM kernels are not type-checked when the JVM stdlib
is built, so nothing reported them there.

Tests whose sources relied on the missing check:

- `List[Byte]` built from `Int` literals or values: `app_host_self_test.l`,
  `deflate_zip_self_test.l`, `slice_fastpath_self_test.l`,
  `stdlib_jvm_kernels_self_test.l`, `restored_slice_list_return_self_test.l`
  and `llvm_stdlib_self_test.l` (embedded sources),
  `lyric-compiler/jvm/file_jvm_self_test.l`,
  `lyric-compiler/jvm/static_type_recovery_jvm_self_test.l`, and
  `lyric-stdlib/tests/file_tests.l`/`hash_tests.l`. They use `u8` literals or
  `.toByte()`.
- `erased_slot_widen_self_test.l` and `list_insert_self_test.l` stored an
  `Int` into a `List[Double]`/`Map[K, Double]`. They convert with
  `.toDouble()`.
- `llvm_codegen_self_test.l`'s #7452 case added `(i * 31 + 7) % 256` to a
  `List[Byte]` to reach `coerceTo`'s implicit `trunc`. The argument is now
  converted with `.toByte()`; the implicit narrowing stays reachable through a
  type parameter in a generic body, and its comment in
  `lyric-compiler/lyric/llvm_codegen.l` says so.
- `emitter_project_self_test.l`'s #7452 containment case built a native
  `coerceTo` mismatch from `xs.add("hello")` on a `List[Int]`, which is now a
  T0043 before codegen. It reaches the same N0007 through a generic body,
  `put[T](xs: in List[Int], x: in T)` called with a `String`.

Tests: `typechecker_self_test.l` covers each member with a correct call, a
mismatch, a widening and an interface or literal case where one applies, the
cross-chain `Int` into `List[Double]` and `Int` literal into `List[Byte]`
cases, a generic receiver, a lambda element, and a package's own `List`.
Before the fix 7 of the 8 new tests failed (each clean case passed, no
mismatch was reported); after it all pass. `erased_slot_widen_self_test.l`
gains a dual-target case for a `UInt` argument of `contains`, `indexOf`,
`lastIndexOf` and `remove` on `List[ULong]`, `Map[ULong, Int]` and
`Set[ULong]`, which now zero-extends like `add`'s.
