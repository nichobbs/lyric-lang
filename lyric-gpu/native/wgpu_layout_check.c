/* Checks the struct sizes lyric-gpu/src/gpu.l packs into C arrays (it copies one record
 * per element, so the element size is spelled out there).  Compiled, not run, by
 * scripts/ci/gpu-examples-e2e.sh: a mismatch is a compile error. */
#include "include/wgpu_bindings.h"

_Static_assert(sizeof(WGPUBindGroupEntry) == 56, "bind group entry size");
_Static_assert(sizeof(WGPUVertexAttribute) == 32, "vertex attribute size");
_Static_assert(sizeof(WGPUVertexBufferLayout) == 40, "vertex buffer layout size");
/* lyric bindgen binds the display-handle union as 2 Longs after the 4-byte type and its padding. */
_Static_assert(sizeof(WGPUNativeDisplayHandle) == 24, "native display handle size");
_Static_assert(__builtin_offsetof(WGPUNativeDisplayHandle, data) == 8, "native display handle union offset");

int main(void) { return 0; }
