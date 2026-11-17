# 2026-11-17: interface method defaults are carried in the package interface (D442)

`interfaceDefaultSites` (`tir/build/build_members.l`) wraps each non-generic interface method that declares a parameter default as a body-less member site, and `buildPackageDefaults` builds it with the other members. A call through a restored interface that leaves the argument out now finds the default in the declaring package's interface. `tir_build_self_test.l` checks that the interface method and its `impl` method each carry their own default. Docs/70 status updated.

The cause of the missing numbering was the shared node mapper skipping `IMSig` parameters; `mapFileWith` now maps them, so `renumberNodeIds` numbers an interface default.
