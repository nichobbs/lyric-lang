# D155 — Native graphics building blocks: f32 `Float`, `buffer[T]`, `Plain`, `foreign record`, `webgpu.h`

**Status:** accepted (specified; not yet implemented — docs/67 phases G1 onward)

Backs `docs/67-native-graphics-plan.md` and resolves its Q-GFX-001 to
Q-GFX-004.

## Context

docs/67 plans native graphical programs (windowed applications, GPU
rendering, games) on `--target native`. Its audit (§3) found that the
language has no way to hold packed, mutable bulk data, that `Float` is
lowered as a 64-bit `double` on MSIL and native (JVM has used a real
32-bit `float` since D-progress-464) although §2.1 specifies a 32-bit type, that the native FFI cannot describe a C struct, and that
`docs/00` and `docs/04` describe a narrower language than such programs
need.

## Decision

1. **`Float` is 32-bit on every backend** (Q-GFX-002). §2.1 already says
   so, and the JVM already complies (D-progress-464); MSIL and native are
   brought onto the specification. A float literal is
   `Double` unless it carries the `f32` suffix or is the other operand of a
   `Float`, mirroring the integer-literal rule (#7346). `.toFloat()` is
   defined on the numeric primitives, narrowing with round-to-nearest-even.
   Existing `Float` uses that meant 64-bit move to `Double` in the change
   that switches the representation.

2. **`buffer[T]` has value semantics, implemented by copy-on-write**
   (Q-GFX-001). A buffer is a contiguous, packed, runtime-length sequence
   of `Plain` elements. Assigning it, passing it as `in`, storing it, or
   capturing it in a closure or `spawn` is a logical copy; storage is
   copied only when a write meets shared storage. Element writes
   (`b[i] = v`) need a writable place (`var`, `out`/`inout`, a `var`
   field). On native the ARC count decides sharing; on MSIL and JVM the
   compiler marks a buffer shared when it copies the value, and the mark
   is never cleared except by the copy a write makes. Rejected:
   reference-semantic buffers (aliased mutation, data races, verifier
   frame conditions; the shared mutable state `protected type` exists to
   fence) and ownership/borrowing (`docs/00`).

3. **`Plain` is a compiler-derived marker.** A type is `Plain` when its
   bit pattern is its whole meaning: scalars; distinct types over `Plain`
   without a range constraint; records whose fields are all `Plain` and
   which declare no `invariant:`; `array[N, T]` of `Plain`; enums. Range
   subtypes and invariant-carrying records are excluded because foreign
   code and the GPU write buffers without running construction checks;
   opaque types are excluded outside their defining package because a byte
   view would expose their representation. `Plain` cannot be implemented
   or derived by users and is not valid in a `derives` clause. It fills
   the gap D034's `Copyable` left (dropped by D-progress-807 because it
   needed backend layout information): `Plain` is structural, so the front
   end computes it alone.

4. **`array[N, T]` has value semantics.** Inline storage; assignment and
   passing copy; element writes need a writable place. No backend
   implements this yet: MSIL and JVM erase the type to an object
   reference and native does not lower it.

5. **Component-wise `derives Add, Sub` on homogeneous numeric records**
   (Q-GFX-004). A record whose fields all have the same numeric type may
   derive `Add` and `Sub`; the operators apply field by field and accept
   only two values of the same record type. Other vector operations
   (scaling, dot and cross products, matrix products) are methods. This
   widens the constrained-derive mechanism `docs/04` already accepts; it
   adds no user-defined operators.

6. **`foreign record`** declares a C-layout struct. It is allowed only in
   kernel files (`_kernel_native/`, and a library's own kernel directory),
   it is not generic, its fields are `Plain`, `NativePtr[T]`, `array[N, T]`
   or other foreign records, laid out by the target's C rules, and it never
   appears in a library's public API: the kernel's safe wrappers take
   ordinary Lyric types. `foreign` is a contextual keyword, recognised only directly
   before `record`.

7. **`@userdata` marks the closure-pointer parameter of a C callback
   type**, so callbacks whose userdata is not the last parameter (SDL3,
   current `webgpu.h`) get trampolines.

8. **Buffer memory reaches C only through non-escaping closures.**
   `withPointer` and `withMutPointer` (the latter makes the storage unique
   first) are available in kernel files and `@unsafe_ffi` functions, and
   the pointer may not escape the closure, extending the `N0100` rule.

9. **GPU API: `webgpu.h`, implemented by wgpu-native** (Q-GFX-003). One
   shader language (WGSL) on every platform, compute shaders, two
   independent implementations of one header (wgpu-native, Dawn), and the
   same API in the browser for the later WASM target (docs/35). SDL3's
   GPU API was rejected because it needs a shader format per backend
   (SPIR-V, MSL, DXIL) and an offline cross-compilation toolchain. SDL3
   remains the windowing, input and audio layer. The binding is generated
   from a pinned `webgpu.yml`, so header revisions are upgraded
   deliberately.

10. **Graphics libraries are native-only; the language features above are
    defined for every target.** MSIL and JVM implement items 1 to 5 for
    correctness (tracked per phase); performance is a native goal.

## Consequences

- `docs/01` specifies the items above, each marked as not yet
  implemented with its docs/67 phase (§2.1, §2.4, §2.7, §2.11, §11.6).
- `docs/00` no longer lists game developers as outside the audience and
  describes the native memory model; `docs/04`'s operator-overloading
  entry admits item 5, and its intrinsics entry notes that buffers and
  vector records are not intrinsics.
- `docs/grammar.ebnf` gains `BufferTypeForm` and `ForeignRecordDecl`.
- Q-GFX-005 to Q-GFX-010 stay open in docs/67 §10.
