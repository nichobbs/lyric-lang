# D427 - A pointer in one spelling of a C callback's userdata slot used as the other is `CvUserdataSlot` (docs/70 phase 3a, #8613)

**Status:** shipped; extends D494 (C callback conversions) and D189 (the two spellings of the slot).

## Context

A C callback's userdata slot is spelled `NativeUserdata`, or, older, a trailing `NativePtr[Byte]` (D189), and `nativeKeepCallback(f)` returns a `NativePtr[Byte]`. A program passes that pointer where a `NativeUserdata` parameter is declared (`cbtEachLong(f, ud, 2)`): the checker accepts it, the two are the same pointer, and the builder had no conversion between the two spellings, so the body was counted ("an argument conversion", I0002): `ExternCallbackSelfTest::keptUserdataFirst`.

## Decision

`ConvKind` gains `CvUserdataSlot`: the operand and the node are both spellings of the userdata slot (`isUserdataSlotTy`), and the value is the same pointer. The builder converts one to the other with it, the verifier checks both types, and the interface format gives it the next tag (17, appended: no existing tag changes).

## Results

`extern_callback_self_test.l` builds every body with the verifier clean; `tir_verify_self_test.l` covers the rule in both directions and with a type that is not a slot.
