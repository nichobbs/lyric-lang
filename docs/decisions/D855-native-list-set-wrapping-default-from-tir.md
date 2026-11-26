# D855: the native TIR lowering takes `List.set`, the wrapping integer methods and `default()`

Status: accepted (docs/70 phase 4a, part 8; D520 slice 44).

## Decision

1. **`xs.set(i, v)`** is the `lyric_list_set` kernel call, as `add(index, v)` is `lyric_list_insert`.
2. **`wrappingAdd`, `wrappingSub`, `wrappingMul` and `wrappingNeg`** on an integer are the plain two's complement `add`, `sub`, `mul` and `0 - x`, with none of the D163 overflow checks `lowerBinary` adds, whatever the build profile.
3. **`default()`** is the zero value of its expected type: 0, false, 0.0 or null for a reference. An aggregate falls back (the census names the type).

## Not done

`String.split`, `format1`/`format2`, `array.toSlice` and `String.normalize` (a compile-time panic on the AST path too) still fall back.
