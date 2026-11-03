# MSIL binds calls to the checker's resolved callee (docs/70 phase 2d, D336, #8612)

The checker records the declaration each bare or package-qualified call
resolved to (`SymbolTable.calleeSites`) and `MiddleEndOptions.calleeSitesOut`
carries it to the backends. MSIL uses it ahead of its own name tiers, which
fixed two calls that bound to a package-private function of another package
(`isLiteralInit` in `Lyric.LlvmBridge`, `funcBodyContainsYield` in
`Jvm.Bridge`). A census of the build shows what still lacks a site: builtins,
dot-named type functions and monomorphised specialisations; the tiers stay
until those have one. The JVM and native bridges, #8752 and #8690 follow.
