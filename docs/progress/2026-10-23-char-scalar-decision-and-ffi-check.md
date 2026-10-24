# `Char` is a Unicode scalar value: decision (D219) and the FFI boundary check (#8225)

The owner decided that `Char` is a Unicode scalar value (U+0000..U+10FFFF without surrogates) on every target. D219
records the semantics and the staging; this entry covers slice 1.

- A `char` returned by an auto-FFI call, a static property or field read, or a constant is checked at the boundary on
  .NET (`guardAutoFfiCharResultMsil`, `OverflowException`) and the JVM (`__lyricFfiChar`, `ArithmeticException`). A
  surrogate half used to become a Lyric `Char` (`Convert.ToChar(55296)`, `Character.highSurrogate(128512)`).
  Regression tests: `auto_ffi_self_test.l` (dotnet) and `auto_ffi_jvm_self_test.l` (jvm).
- docs/01 §2.1 and the book state the target definition and mark it not yet implemented. Supplementary literals,
  the 32-bit `Char` representation on .NET and the JVM, the scalar-based `Std.Char`/`Std.String` surface and the
  verifier range follow in #8225 (slices 2 and 3 of D219).
- Follow-up issues: #8508 (literals), #8509 (MSIL representation), #8510 (JVM representation), #8511 (Std.Char/Std.String and kernels), #8512 (verifier range, native).
