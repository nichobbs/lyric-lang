# D857: the native TIR lowering takes `mapGet` and `mapSize` of a map

Status: accepted (docs/70 phase 4a, part 8; D520 slice 46).

## Decision

1. **`mapSize(m)` and `mapGet(m, k)` are intrinsics of the TIR lowering**, registered for each instantiation like `mapKeys` and `mapValues`: `mapSize` is `lyric_map_len`, and `mapGet` calls `lyric_map_get`, which writes the value's slot into a stack cell and answers whether the key was present, then builds `Some` of the value (a reference value is retained by the `Some`, as the kernel's get does not retain) or `None` in the `Option` the call's type names. A result that is not a two-case `Std.Core::Option` falls back.
2. The `h2c*`, `findStream` and `findNameIndex` functions of the HTTP/2 engine, which fell back for "a call with no IR name", lower from TIR.

## Not done

`mapGet` over a map the layout does not cover still falls back through `tyLowers`.
