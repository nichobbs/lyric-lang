# Package interface declaration detail on `Ty` (docs/70 phase 5a, D324)

Second slice of phase 5a: the interface carries each declaration's detail
(generic parameters with bounds, parameters with modes, results, fields, case
payloads, alias and range underlying types, `pub val` types and constant values,
extern host names, `@axiom`/`@pure`/async and per-function verification
level) using `Lyric.Tir`'s `Ty`. Types are written by DefPath key and re-interned
on read, so the bytes do not depend on a compilation's symbol ids. Format
version 2. `iface_self_test.l` gains round-trip coverage of every `Ty` form,
every detail kind, every literal form, cross-interner stability, the
unresolvable-symbol error, the nesting limit and a golden dump. Defaults,
contracts and bodies remain deferred; see D324.
