# D-progress-1046: Compound values across component host imports

**Status:** shipped (W4 follow-up, #8117 item 3; unblocks the records part of #8118 item 1)

## Decision

1. A `@wasmImport` extern in the `component` shape may take and return anything an export can:
   records, enums, unions, `Option`, `Result`, `List` and tuples, nested freely, defined in the
   importing package. Scalar-and-`String` signatures of at most 16 flat core parameters keep the
   earlier direct C wrapper; every other signature goes through the memory image below.
2. An image import is rewritten to a raw extern bound to the generated C function
   `cSym(image, area)` plus a generated Lyric function with the extern's own name and signature.
   The Lyric function stores the arguments into a memory image (the canonical layout of a tuple
   of the parameters, using the same `store` shims exports use), calls the raw extern, frees
   what it allocated (`free` shims, then the image), and loads the result from a return area.
3. The C function reads the flat core arguments out of the image with generated expressions (a
   variant's payload slots are a ternary chain over the discriminant, coerced to the joined slot
   kind: widen `i32` to `i64`, reinterpret `f32`/`f64` bits), or passes the image itself when the
   flat parameters exceed 16. A scalar result is returned directly; a one-slot compound result
   is stored into the area; a larger one is written by the host through the return pointer.
4. The import's WIT interface declares the named types its signatures use. Two different types
   with one WIT name in a module, and a function sharing a name with a type, are `N0019`.
5. Imports that take more than 16 flat parameters, previously an error, now spill into the image.

## Not covered

Types declared in another Lyric package (#8117 item 2). The module shape still carries scalars
and `String` only.
