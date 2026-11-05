# D410 - `lyric bindgen`: C unions as sized storage, function-pointer results as addresses

**Status:** accepted, implemented (docs/67 §5.3, #8404); extends D190 and D219

## Decision

1. **Unions.** A C union, named or an unnamed union (or struct) member, becomes a `foreign record` with one field,
   `storage: array[N, T]`, of the union's size and alignment: `T` is `Long`, `Int` or `Byte` for alignment 8, 4 or 1
   (alignment 2 has no Lyric element type and is skipped with a note). A Lyric record has no overlapping fields, so the
   members are not fields; a program writes the member it uses at offset 0, through the storage's address or by copying
   the member's own record, which is bound beside the union. An unnamed member is named `<Record>_<member>`
   (`WGPUNativeDisplayHandle_data`); clang declares the nested record just before the member, and bindgen maps the
   member's type spelling ("union (unnamed union at ...)") to it. The generated record carries a doc comment listing
   the members, the size and the alignment.
2. **No unions by value.** A record that holds a union, directly, in a member record or in an array, is not passed by
   value to or from a C function: the C ABI classifies a union by its members (`union { float a; float b; }` travels in
   an SSE register), and the storage array has other members. Only pointers to it are bound; a by-value parameter or
   result is skipped with "holds a union, which cannot be passed by value".
3. **Function-pointer results.** A function pointer a C function returns (`wgpuGetProcAddress`'s `WGPUProc`) is bound as
   `NativePtr[Byte]`: an address to hand on to C or to store in a record field. Lyric does not call through it, so it
   is not a callback type and needs no userdata parameter.
4. **Regenerated kernels.** `Gpu.Kernel.Wgpu` gains `WGPUNativeDisplayHandle` and `WGPUInstanceExtras` (instance
   backends, flags, the GLES display handle) and `wgpuGetProcAddress`; `Window.Kernel.Sdl` gains `SDL_Event` and its
   member event records, and `SDL_PollEvent`, `SDL_WaitEventTimeout` and `SDL_PushEvent` take `NativePtr[SDL_Event]`;
   `Text.Kernel.Harfbuzz` gains `hb_glyph_info_t` and `hb_glyph_position_t`, which the glyph getters now return;
   `Text.Kernel.Freetype` gains `FT_StreamDesc`. The safe layers keep reading those through their checked offsets
   (`lyric-text` binds the glyph arrays as `NativePtr[Byte]`); `wgpu_layout_check.c` asserts the display handle's size
   and union offset.
