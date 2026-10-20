# D185 - `buffer[T]`: the built-in type, and its managed-target representation

**Status:** accepted, implemented for `--target dotnet` and `--target jvm` (docs/67 phase G2, #7941); native is the next slice

Completes the managed half of what D155 specifies for `buffer[T]` (docs/01 §2.7 "Buffers").

## Decision

1. **`buffer[T]` is a built-in generic type**, like `Task[T]` (D166): the checker
   resolves `buffer[T]` unless a type called `buffer` is in scope, to a type
   with a reserved id that no declaring symbol backs. The element must be
   `Plain` (D155, the `Plain` marker of the previous slice): **T0173** names
   the part of the element type that defeats it. An element that is still a
   type parameter is checked where it is bound.
2. **Surface.** `b[i]` reads and `b[i] = v` / `b[i] op= v` write an element
   (**T0157** unless the buffer is in a writable place, as for arrays);
   `b.length` is the runtime length; `for x in b` iterates the value the loop
   started with. Any other member is **T0113**. A record that holds a buffer
   derives none of `Equals`, `Hash`, `Show` or an ordering (**T0159**). The
   receiver of an index is a variable, a field path, or an element of one
   selected by a literal or variable (**T0174**), because an index reads the
   receiver's length as well as its element.
3. **Value semantics.** A buffer follows D167's place rules for arrays: every
   writable place exclusively owns its storage, and a buffer is copied when it
   is stored into a writable place or read from one and the read escapes. The
   checker reuses the array copy sites (`SymbolTable.arrayCopySites` and
   friends); a buffer's site records the length `-1`, which means "read the
   receiver's own length", so no pipeline plumbing changed.
4. **Managed representation.** On dotnet and the JVM a `buffer[T]` is a
   `List[T]`, and the copy is eager (one copy at each logical copy). The
   shared-mark scheme in docs/67 §4.4 would copy lazily; eager copying is
   always correct and only more conservative, which the plan allows the
   managed targets (native is the performance target). The lazy form is
   tracked in #8389.
5. **`Std.Buffer`** (`filled`, `fromSlice`, `view`, `toSlice`, `grow`,
   `truncate`) is written in Lyric against the buffer's own operations. Two
   members, `__lyric_buffer_from_list` and `__lyric_buffer_as_list`, move
   between a buffer and its list; the checker accepts them only inside
   `Std.Buffer`, and the managed lowering makes them the identity. The package
   is marked `# seed: current` in `lyric.full.toml`, since the released seed
   compiler does not know `buffer`.
6. **A generic from another package** whose signature holds a buffer is
   checked again per specialisation (`Lyric.Mono`), because another package's
   generic is lowered only through that check. Before this a buffer operation
   in such a body reached the JVM backend unlowered.

## Not in this decision

Native lowering (packed ARC storage, the `rc == 1` write check), `withPointer`
and `withMutPointer`, the verifier's array model, the `lyric lint` rule, and
the shared-mark form for the managed targets. They remain docs/67 G2 and are
tracked in #7941.
