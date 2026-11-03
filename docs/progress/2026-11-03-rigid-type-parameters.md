# 2026-11-03 Rigid type parameters (docs/70 phase 3a, D331)

- `typeEquiv` no longer treats `TyParam` as a wildcard (`TyError` and `TyInfer` still are). A generic value is not accepted where a concrete type is required (docs/01 §2.11).
- Call arguments are checked against the signature instantiated from the call (`instantiateSigForArgs`); unsolved parameters become `TyInfer`. This fixed all 17 checker cases the rigid rule broke.
- Migrated the JVM reflection helpers (`_kernel_jvm/http_host.l`, `_kernel_jvm/http_server.l`, `tests/tls_server_jvm_tests.l`) off `List[JObject].add(<generic>)` onto a `java.util.ArrayList`.
- `owner` is still empty; threading the binder is next.
- Census method: `lyric check --manifest` cannot run manifests whose local dependencies are unbuilt, so CI is the complete census; the log of every failed job is read for T0043/T0060.
