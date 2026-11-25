# D853: the native TIR lowering takes the raw `String.indexOf` and `String.lastIndexOf` builtins

Status: accepted (docs/70 phase 4a, part 7; D520 slice 43).

## Decision

`s.indexOf(x)` and `s.lastIndexOf(x)` type-check as the builtin returning the raw `-1`-sentinel `Int` when the calling file does not import `Std.String` (with the import they are the `Option[Int]` free functions, an ordinary `Direct` call; `Std.String`'s own wrappers call the raw form). The builtin lowers to `lyric_string_index_of` / `lyric_string_last_index_of` with the result narrowed to `i32`, as on the AST path. This removes the `builtin String.lastIndexOf with 2 arguments` census fallback, including the one in the bundled standard library.

## Not done

`String.split`, `String.normalize`, `format1`/`format2`, `array.toSlice`, `List.set`, `Int.wrappingAdd` and `default` stay on the AST path with their census reasons.

## Verification

`scripts/ci/native-via-tir/builtins.l` gains `positions` (found, last found and missing needle); it lowers 11 of 11 functions from TIR with the AST path's output and runs clean under AddressSanitizer.
