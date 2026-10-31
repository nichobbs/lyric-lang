# macOS release link: add the GSS framework

Publish run 1831 (155623d) got past the Lyric.Pipeline error but both macOS
`Build stage 2` jobs failed at the NativeAOT link with undefined `_gss_*`
symbols referenced from `libSystem.Net.Security.Native.a` (`pal_gssapi.c.o`).
The macOS clang link line in `lyric-compiler/lyric/release.l` already links that
archive (and `--directpinvoke:System.Net.Security.Native`), but passed only the
Foundation and Security frameworks. It now also passes `-framework GSS`, which
provides the GSS-API symbols the .NET runtime's Net.Security native shim needs.
