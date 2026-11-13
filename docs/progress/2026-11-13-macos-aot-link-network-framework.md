# 2026-11-13 - macOS NativeAOT link: Network.framework

Publish run 1834 (with the Apple crypto `--directpinvoke` fix of 2026-11-12 in place) failed both macOS legs at the stage-2 clang link: `libSystem.Security.Cryptography.Native.Apple.a[pal_networkframework.m.o]` references the `nw_*` Network.framework API (`nw_connection_*`, `nw_framer_*`, `nw_tls_*`, ...) and `buildLinkerArgsMac` linked only Foundation, Security and GSS. Before the directpinvoke fix the shim was unreferenced, so the archive member was never pulled in and the gap was hidden.

`release.l` now also links `-framework Network` on macOS. Every undefined symbol in the log was `nw_*`, so no other framework is missing. Not verified locally (no macOS host); verified by the next Publish run's macOS legs.
