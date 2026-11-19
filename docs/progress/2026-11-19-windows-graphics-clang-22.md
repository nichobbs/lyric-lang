# Windows graphics job installs LLVM 22

The `graphics` job of the "Windows build" workflow began failing on some runs on 2026-11-19 while building HarfBuzz:

```
yvals_core.h:923:1: error: static assertion failed: error STL1000: Unexpected compiler version, expected Clang 22 or newer.
```

The `windows-2025-vs2026` runner image 20261116.315.1 ships MSVC 14.52, whose C++ standard library headers reject a Clang older than 22, and the image's LLVM is 20.1.8. Runs that landed on the previous image (20261103, MSVC 14.51) passed, so the failure followed the image rollout and not any change in the repository.

The job now installs LLVM 22.1.8 with Chocolatey before it builds anything (it replaces the image's LLVM in `C:\Program Files\LLVM`, already on `PATH`) and prints `clang --version`. The other Windows jobs compile only C with the image's Clang and are unchanged.
