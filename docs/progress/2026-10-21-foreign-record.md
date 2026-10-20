# `foreign record` (docs/67 G3 S1, #7942, D188)

`foreign record` declares a C-layout struct in a `_kernel_native/` file.

- Parser: contextual `foreign` item head; `RecordDecl.isForeign`, threaded through
  every AST rebuilder (mono, hoist, propagate, array lowering, alias resolution,
  elaborator); formatter and `lyric doc` keep the keyword.
- Checker: `typechecker_foreign.l` (T0178 shape, T0179 field types, T0180 in-place
  write roots); a foreign record is `Plain`.
- Mode checker: N0101 outside kernel files.
- Native codegen: forced by-value struct (pointer fields included), field and
  array-element writes through place addresses, C ABI by value and by pointer.
- Tests: parser, formatter, type checker, mode checker, and a C round trip under
  AddressSanitizer in `llvm_c_abi_self_test.l`.
- Docs: language reference (already specified), book chapter 13, D188.
