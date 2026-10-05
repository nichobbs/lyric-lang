# Value generic parameters on protected types (#8149, D178)

- A protected type may take a value generic parameter (`protected type Ring[N: Nat] { var buf: array[N, Int] ... }`). Each length is specialised whole (`Ring__V3`, `N` replaced in the field types and member bodies) by the middle end, on every target.
- The JVM registers the per-length protected types and the functions naming them after the middle end; native registers protected members under the receiver's type name too.
- Such a type cannot be `pub` yet (T0168); cross-package use is follow-up work.
- Tests: `value_generic_protected_self_test.l` (dotnet, JVM, native); checker self-test updated (T0160 no longer fires for a protected type).
