# D-progress-1050: bundled stdlib interfaces and impls on the native backend

**Status:** shipped (corrects the "known limit" in D-progress-1049; supersedes its claim that `HttpClient` cannot be lowered on native)

## Decision

1. Native codegen units now carry every package's interface declarations, not only the
   user's. An interface is only a box and a vtable type, so collecting it is as cheap as
   collecting a record, and another package's signature may name it. Before this, any native
   program that named a stdlib interface (`Std.Http.HttpClient`, `Std.Log.Logger`,
   `Std.Stream.*`) failed with "type 'HttpClient' is not yet supported for --target native".
2. A bundled package's `impl` is lowered whole, because its vtable references every method,
   and only when it is needed. The reachability walk records an `impl:<Pkg>.<Record>` marker
   when reachable code constructs the implementing record, and seeds that impl's methods so
   their callees are followed. An interface-typed value is always built from an implementing
   record, so no construction means no vtable is read. A program that imports `Std.Http`
   but never builds a client does not compile `HttpClientImpl`.
3. Generic impls and protected types are unchanged: bundled generic impls stay out, and
   bundled protected types still collect only for the user's package (no stdlib module other
   than `Std.Testing.Mocking` declares one).
4. With this, `defaultClient()`, `HttpClientBuilder.build()` and the other `HttpClient`
   factories work on `--target native` and in the wasm32 module shape, so the TLS-option
   refusal described in D-progress-1049 is reachable and tested there
   (`tls=connection-failed`). D-progress-1049 attributed the gap to async interface methods;
   that was wrong: async interface dispatch landed in #8194, and the real cause was this
   bundled-interface collection.
5. Three `val` bindings in `HttpClientBuilder.build()` gain an `Option[String]` annotation.
   The native lowerer cannot infer the type arguments of a bare `None` in an `if`/`match`
   whose other branches are `Some(...)`; the diagnostic names the annotation as the remedy.
   The inference gap itself is tracked as its own issue.

## Tests

`llvm_stdlib_self_test.l` (ASan): a user `impl Logger for ...` dispatching through the vtable,
`defaultClient().get("")` returning `InvalidUrl` through the interface with no network, and a
program that imports `Std.Http` without constructing a client. `llvm_wasm32_module_self_test.l`
gains the `HttpClientBuilder` TLS refusal and a `defaultClient().get` through the host fetch.
