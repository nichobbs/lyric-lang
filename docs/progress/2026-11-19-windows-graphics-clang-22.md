# Windows graphics job: HarfBuzz builds against the MSVC 14.52 headers with the image's Clang

The `graphics` job of the "Windows build" workflow began failing on some runs on 2026-11-19 while building HarfBuzz:

```
yvals_core.h:923:1: error: static assertion failed: error STL1000: Unexpected compiler version, expected Clang 22 or newer.
```

The `windows-2025-vs2026` runner image 20261116.315.1 ships MSVC 14.52, whose C++ standard library headers reject a Clang older than 22, and the image's LLVM is 20.1.8. Runs that landed on the previous image (20261103, MSVC 14.51) passed, so the failure followed the image rollout and not any change in the repository.

## First attempt, withdrawn (#9258)

#9258 installed LLVM 22.1.8 in the job. HarfBuzz then built, but the binding freshness check in `scripts/ci/windows-graphics-e2e.sh` failed on every runner: `lyric bindgen` misreads Clang 22's AST output (it skips record fields whose type is another record and orders declarations differently), so the regenerated kernels no longer matched the committed ones. That is #9262.

## What the job does now

The LLVM 22 install is removed, so bindgen runs on the image's LLVM 20 again. `scripts/ci/build-text-libs-windows.sh` builds HarfBuzz, the one C++ build, with `-D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH`, the switch the MSVC headers name for STL1000. When #9262 is fixed the job can install LLVM 22 and drop the define.

Not run on a Windows host locally. A CI run on the old image shows the define is harmless there; only a run on the new image shows it is sufficient.
