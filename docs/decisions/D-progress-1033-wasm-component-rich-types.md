# D-progress-1033 — Component shape: rich types via generated Lyric shims

**Status:** shipped (W4 slice 2)

Extends D-progress-1032; supersedes its decision 3 (C wrappers that lift strings
only).

## Context

Slice 1 lifted scalars and strings in generated C. Lifting a record, option,
list or variant from C needs the native layout of that type: records and small
unions are LLVM by-value aggregates (docs/67), generic unions are classified per
instantiation, and ARC rules decide who owns what. Mirroring that in a C
generator would duplicate the backend's type knowledge and drift from it.

## Decision

1. **Lift and lower in Lyric.** For every exporting package the compiler appends
   generated Lyric shims to the package's AST before type checking
   (`Lyric.ComponentGlue.componentRewriteFile`): `__cabi_lift_<n>` (flat core
   argument stream), `__cabi_load_<n>` / `__cabi_store_<n>` (linear memory),
   `__cabi_free_<n>` (what a stored value allocated), and one `__cabi_ex_<i>` per
   export. The type checker, monomorphizer and ARC passes then handle the types,
   so nothing aggregate crosses a C boundary and the shims follow whatever
   layout the backend chooses.
2. **C is memory and slots only.** The generated `<stem>.cabi.c` holds the
   argument/result slot array, raw loads and stores, string copy in/out,
   `cabi_realloc`, and one core wrapper per export that pushes its flat
   parameters, calls the shim and returns the result slot or return-area
   pointer (plus `cabi_post_*`). Single-threaded v1 makes the static slots safe.
3. **Canonical ABI coverage.** Flat parameters up to 16, spilled parameters
   through memory above that, single-value flat results, return areas for the
   rest, variant payload `join` (slots are raw 64-bit patterns, so `i32`/`f32`
   and `i64`/`f64` joins need no coercion code), discriminant-only sums, and
   caller-allocated buffers freed after reading.
4. **Resolution.** Types resolve from the package's own declarations: non-generic
   records, enums and unions whose cases carry at most one field, plus `Option`,
   `Result`, `List` and `T?`. Anything else (generics, aliases, other packages'
   types, multi-field cases, `Unit` parameters/elements, recursion) leaves the
   export out with a `W0040` naming the reason. A function whose WIT name
   collides with a type's is likewise left out, since WIT shares one namespace.
5. **One mechanism.** The slice-1 C lifting of strings is removed; strings and
   scalars take the same shim path, so there is a single code path to test.

## Not in this slice

Tuples, cross-package types, WIT imports, `--wit-out`/`--js-bindings`, the
publish bundle, async exports (Q-JS-006), the `[wasm]` table. A multi-package
program where several packages export declares the C primitives once per
package; it is untested and tracked as follow-up work.
