# `NativeUserdata`: callback userdata at any position (docs/67 G3 S2, #7942, D189)

- Checker: built-in native type `NativeUserdata`; a callback parameter's closure type
  drops the marked slot (first marker, else the trailing `NativePtr[Byte]`).
- Mode checker: `NativeUserdata` is under N0100.
- Codegen: plain and C-ABI trampolines honour the slot index; `externCallbackClosureWant`
  builds the reduced closure type from it.
- Tests: checker case; `llvm_c_abi_self_test.l` calls C with userdata first and in the
  middle, with scalars and by-value records, under AddressSanitizer.
- Docs: D189, language reference §11.6, docs/67 §4.8.
