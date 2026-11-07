# Native: a call binds the function the checker resolved it to (D336 item 11)

Phase 2d, native slice (#8612). The native bridge receives `calleeSitesOut` per
own file and codegen binds a call to the recorded function (`sitedSig`) before
its own-package and import-narrowed bare-name lookups (reachability pruning is
unchanged). A project whose entry imports two packages
that both declare `pick`, one of them package-private, ran the private one
before; `llvm_project_self_test.l` pins the exported one. The name lookups stay
for bundled stdlib units (unchecked, so no sites) and for calls with no site.
