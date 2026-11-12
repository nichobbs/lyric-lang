# 2026-11-12 - macOS NativeAOT link: direct P/Invoke for the Apple crypto shim

Publish run 1833 failed on both macOS legs in `bootstrap.sh --stage 3` (hard-failing since D567's script change): the stage-2 binary, linked by `lyric build --release-from-dll` (`Lyric.Release`), died with "Unable to load shared library 'libSystem.Security.Cryptography.Native.Apple'" as soon as the manifest reproducibility check used SHA hashing. `buildLinkerArgsMac` links `libSystem.Security.Cryptography.Native.Apple.a`, but the ILC response file only declared `--directpinvoke:System.Security.Cryptography.Native.OpenSsl`, so the Apple shim's DllImports stayed dynamic and fell back to `dlopen` at runtime (the same class of gap as the GSS framework fix of 2026-10-31).

`release.l` now emits `--directpinvoke` for the Apple shim (unprefixed and `lib`-prefixed spellings) on `osx` and the OpenSsl one on every other RID. Not verified locally (no macOS host); verified by the next Publish run's macOS legs.
