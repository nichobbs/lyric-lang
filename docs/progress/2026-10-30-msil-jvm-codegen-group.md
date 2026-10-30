# MSIL/JVM codegen group: Param rows, JVM `Self` bridge, operand guards, regression tests (#7445, #8426, #8313, #8344, #7676, #7963)

- **#7445** `Msil.Lowering` wrote one placeholder Param row (`sequence = 0`,
  `name = 0`) per method, so the metadata reader's `testTableRows` (orphaned
  since the F# emitter was deleted) failed. Every Param-row site now emits one
  row per declared parameter through `addParamRows`: `sequence` 1..n, the
  declared name, flags `PRA_NONE`. `MFunc` and `MInterfaceMethod` carry a
  defaulted `paramNames`, set from the declaration at every user-function
  site in `Msil.Codegen`; synthesised methods name no parameters. A
  zero-parameter method has no Param row. The D-progress-659 invariant ("a
  Lyric-emitted assembly never trips default admission") holds because the
  only consumers of Param rows (`paramDefaultAt`, `paramSeqOptional`) act on
  the Optional/HasDefault flags, which stay unset; real sequences change
  nothing there. `metadata_reader_tests.l` now passes (its
  `clrIsValueType` audit had also drifted: `TaskCreationOptions` is a kernel
  extern enum missing from the closed set in `ffi.l`, now listed in both) and
  runs in CI with the MSIL backend M2a-M2d step.
- **#8426** The JVM backend now emits a synthetic bridge method (flags
  `ACC_PUBLIC | ACC_BRIDGE | ACC_SYNTHETIC`) for an `impl` method whose
  descriptor is narrower than the interface slot it implements (the slot
  erases `Self` to `Object`). `implBridgeJvm` compares the lowered impl
  method with the registered `ifaceClass#method` signature and, when only
  reference types differ, forwards through `checkcast`; an interface-typed
  call used to fail with `AbstractMethodError`. `impl_self_spelling_self_test.l`
  now covers `in`, `inout` and return positions through an interface-typed
  binding and runs on both targets (JVM batch added).
- **#8313** Fixed by #8432 (`implSelfSpellingMsil`); this change adds the
  interface-typed cases to its test and runs it on the JVM.
- **#8344** Beyond #8432's arithmetic guard, the `+` arms for a `Long` or
  floating-point left operand, the ordering comparisons (`<`, `>`, `<=`, `>=`)
  and unary `-` now report a spanned `T0120` instead of an unverifiable
  opcode when an operand's static type is only `object`.
- **#7676** Part 1 (shared ldfld/stfld TypeSpec and MemberRef keys) shipped
  in #8432. `restored_generic_field_write_self_test.l` covers part 2: plain
  and compound writes to `var` fields of generic records declared in a
  restored dependency, on both targets.
- **#7963** Not reproducible with the current emitter.
  `module_val_shadow_import_self_test.l` pins a module `val` shadowing an
  imported `pub val` in a restored consumer, on the JVM, and with both
  packages in one assembly.
