# D-progress-1044: Bool and Byte across component host imports

**Status:** shipped (W4 follow-up, #8117 item 3, first slice; #8118 item 1 for `Bool`/`Byte`)

## Decision

1. A host import in the `component` shape may take and return `Bool` (WIT `bool`) and `Byte`
   (WIT `u8`), as the `module` shape already did. Both are `i32` in the canonical flat form.
2. The generated C wrapper declares the core import with `int32_t` for both, narrowing the
   result (`(_Bool)(r != 0)`, `(uint8_t)r`); the Lyric side keeps its own `_Bool`/`uint8_t`.
3. Records across a host import still wait on the general import shim (lowering through an
   image and a return area); they stay a tracked part of #8117 item 3.
