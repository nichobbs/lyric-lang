# JVM: dot-named calls bind by site, bare function values are package-scoped (D336)

Phase 2d, JVM leftovers (#8612). `Type.f(x)` calls bind by the checker's callee
site (`siteDotNamedSigJvm`) and then the calling package's scoped key; no
function registers a bundle-wide bare dotted key any more (a wire factory keeps
its own `Wire.method` key). The `bareref:` marker for a same-package function
used as a value is now `bareref:<package>::<name>`. Left for later slices: the
`~ctor-import~` and `~selimport~` maps and `importAwareRegistry`'s enum case and
module val overlay. See D336 item 10.
