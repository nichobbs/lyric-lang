# FFI delegate bridge reads the delegate type from member metadata (D288; #5525, #5800, #5947)

A lambda passed to an `@externTarget` function's function-typed parameter is
now built as the delegate the BCL member actually declares, on `--target
dotnet`.

## Shipped

- `externDelegateSlotMsil` (`lyric-compiler/msil/codegen.l`) resolves each
  bridged parameter once from metadata: the overload (a delegate parameter
  taking as many arguments as the Lyric function type, other parameters scored
  against the declared types), whether it is `Func`/`Action` or a named
  delegate, and which delegate positions are the declaring generic type's `!N`
  when the call erases those to `object`. Registration, the wrapper's own
  signature, the extern body and lambda construction all use that answer.
- #5525 / #5800: `List<T>.ForEach`, `ConcurrentDictionary<K,V>.GetOrAdd` and
  `AddOrUpdate` and similar members are called with a delegate over `object` at
  the erased positions; the lambda unboxes its arguments and boxes its result.
  The `TypeLoadException` of the original report was already fixed on main; the
  remaining `InvalidCastException` (`Action<Int32>` to `Action<Object>`) is
  what this closes.
- #5947: a parameter typed with a named delegate (`Predicate<T>`,
  `Comparison<T>`, `ThreadStart`, `RemoteCertificateValidationCallback`) binds
  with that delegate's own `.ctor` (`buildNamedDelegateCtorTok`). A delegate
  can be the receiver of its own `Invoke`.
- `scoreSigType` ranks an argument that instantiates the same generic type as an
  open-generic parameter above a bare type variable.
- `Mdr.typeBaseFqnCached` for the delegate check.
- Tests: `typed_ffi_delegate_self_test.l` (13 cases, delegates are invoked, not
  just constructed) and `generic_extern_self_test.l` (generic wrappers whose own
  type parameters appear in a callback).

## Not done

Lifting the Unix-socket plus TLS gate in `Std.Http` (docs/61 section 3.2): the
bridge now exists, but wiring `SocketsHttpHandler.SslOptions` end to end needs a
TLS-over-Unix-socket server to test against. Tracked on #5947. A member that has
its own generic parameters (`List<T>.ConvertAll<TOutput>`) is still unsupported.
