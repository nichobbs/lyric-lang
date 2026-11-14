# 2026-11-14 - TIR builder: defaults declared in another package (D482)

A call or record construction that leaves out a defaulted argument whose declaration is in another package now builds: the
default is read from the declaring package's interface, renumbered into the consumer's symbols, with the declarations it
names added to the body. Interface format 5 (`IfParam`/`IfField` `dfltEntries`, record field defaults). A build shares a
`DepDefaults` store of interfaces among its packages (`MiddleEndOptions.depDefaults`), filled as each package is checked and
from the embedded `Lyric.Interface.<Pkg>` resources of restored dotnet dependencies.

Compiler census (dotnet): 11708 -> 12152 of 12767 bodies built; the kind `a default argument declared in another package`
65 -> 12 (stdlib-declared defaults; the stdlib is source-loaded, so no interface is registered); I0003 0. Tests:
`iface_self_test.l` (default entries round trip), `scripts/ci/tir-foreign-defaults-e2e.sh` (run by the typed-IR census CI job).
