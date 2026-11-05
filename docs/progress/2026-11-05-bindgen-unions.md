# lyric bindgen: C unions as sized storage, function-pointer results as addresses (D410)

#8404. A C union (named, or an unnamed member named `<Record>_<member>`) becomes a foreign record with one storage
array of its size and alignment, with its member records bound beside it; a record holding a union is bound by pointer
only. A function pointer a function returns is a `NativePtr[Byte]`. The wgpu, SDL, FreeType and HarfBuzz kernels are
regenerated (`WGPUInstanceExtras`, `wgpuGetProcAddress`, `SDL_Event`, the HarfBuzz glyph records); two new
`bindgen_self_test.l` cases cover the union and the function-pointer result.
