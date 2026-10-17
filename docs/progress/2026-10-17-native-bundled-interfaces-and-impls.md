# Native: bundled stdlib interfaces and impls (D-progress-1050)

`unitOf` collected interfaces, impls and protected types only for the user's package, so a
native program naming `Std.Http.HttpClient` or `Std.Log.Logger` failed to lower. Interfaces
now collect for every package; a bundled impl is lowered when reachable code constructs its
record. Closes the limit disclosed in D-progress-1049: `HttpClientBuilder.build()` and its
TLS refusal now run in the wasm32 module shape. Tests in `llvm_stdlib_self_test.l` and
`llvm_wasm32_module_self_test.l`.
