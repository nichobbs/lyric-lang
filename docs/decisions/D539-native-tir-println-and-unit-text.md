# D539: the native TIR lowering takes `println()`, Unit text, unsigned distinct text and Unit pattern bindings

Status: accepted (docs/70 phase 4a, part 7; D520 slice 39).

## Decision

1. `println()` with no argument writes an empty line, as on the AST path.
2. `toString` and `println` of a Unit value render `()`.
3. `toString` of a value of a distinct type wrapping `UInt`, `ULong` or `Byte` formats it unsigned: the formatter reads the wrapped primitive (`opTy`, D538), not the distinct type's own symbol.
4. A pattern that binds a Unit union field or a Unit tuple element declares a Unit local (D536's marker slot) instead of refusing.

## Not done

`String.lastIndexOf`/`indexOf`/`split`, `format1`/`format2`, `array.toSlice`, and the `ULong.toLong`/`toDouble`/`toFloat` family (which the AST path routes through the contract elaborator's D278 rewrite) stay on the AST path with a census reason.

## Verification

`scripts/ci/native-via-tir/unit.l` gains `println()`, `println(toString(note(2)))` and a union with a Unit field matched by binding; it lowers 5 of 5 functions from TIR with the AST path's output and runs clean under AddressSanitizer.
