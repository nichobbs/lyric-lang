# D283 - `@nativeDtor`: a destructor hook for native opaque types (#6234 part 2)

**Status:** shipped on `--target native`.

## Context

#6234 part 1 (D-progress-713) made `opaque type` compile on native by
reshaping it into a record. Part 2 stayed open: the destructor the backend
synthesises for a heap type only releases ARC-managed fields. A type that
wraps a raw OS or C handle (a socket, a TLS context, a `malloc`ed buffer)
held in a `NativePtr[T]`, `Long` or `Int` field had no way to run `free` or
`close` when its last reference dropped. The kernels that needed this
(`Std.TcpHost`, `Std.TlsHost`) fell back to records with an explicit close.

Two designs were scoped in the issue thread. A reserved method name resolved
through the function registry would collide on the arity-only mangling of
record methods (two types in a package, each with a `nativeFinalize(self)`,
mangle to one symbol). An annotation naming a C symbol sidesteps that.

## Decision

1. **`@nativeDtor("symbol")` on an `opaque type`**, written in the trailing
   annotation position (`opaque type Handle @nativeDtor("close_fd") { fd: Int }`).
2. **Contract.** When the last reference drops, the synthesised destructor
   calls `void symbol(<first field>)` with the value of the type's first
   field, then releases the ref-typed fields (ARC Rule 7: custom cleanup while
   every field is still valid). The call happens exactly once per object, also
   for a value shared by several owners.
3. **A type with the annotation always gets a destructor**, even when no field
   is ARC-managed (`recHasRefFields` is true for it). Opaque types are
   heap-only, so they never take the by-value struct form.
4. **Validation, `N0104`** (a panic led by the code, as `N0101`): the annotation
   needs exactly one string argument that is a C identifier (it is written
   into the IR); the type must not be generic; the first field must exist and
   hold a scalar or raw pointer, not an ARC-managed value or `Unit`.
5. **Declaration.** The destructor emits its own `declare` for the symbol
   (`void (<field 0 type>)`) once per module; an `extern func` or runtime
   declaration of the same symbol is not declared twice.
6. **Plumbing.** `CodegenUnit.nativeDtors` (defaulted) carries the symbol from
   `nativeDtorOf` at item collection, on both the single-file and bundled paths,
   into `Ctx.nativeDtors` and `NRecInfo.customDtor`, which every record
   destructor site already consults through `recHasRefFields`.

## Consequences

- Opaque handle wrappers in `_kernel_native/` can get ARC-driven cleanup. The
  `Std.TcpHost` and `Std.TlsHost` records stay as they are until a follow-up
  moves them; nothing in this change alters their close contract.
- The C function receives the handle as stored. A `NativePtr` field set to
  `nativeNullPtr()` reaches it as NULL, so the symbol must accept that (`free`
  and `lyric_cstring_free` do).
- Only the first field reaches the C function. A type needing several values
  keeps them in one pointed-to structure.
- `@projectable` on native stays `N0101`.

## Verification

`llvm_opaque_self_test.l` runs under AddressSanitizer: a `lyric_cstring_free`
handle in a 2000-iteration loop is leak-free, the same program without the
annotation fails LeakSanitizer (the control), a handle shared by two owners is
freed once, a handle-only type with no ref fields still gets a destructor, and
each `N0104` rejection is pinned.
