# 2026-11-13 - Package interface: parameter defaults as typed expressions (D460)

`IfParam.dflt` carries a function's or method's parameter default as a TIR expression (literals, names, calls, constructions,
conversions, lists, tuples), encoded by `iface_expr.l` (interface format 4) and printed by the dump so the I0005 round trip
covers it. The producer builds the defaults with `Lyric.Tir.Build.buildPackageDefaults` from the package's own checker tables;
the pipeline numbers a library's nodes when it writes an interface. Tests: `iface_self_test.l` (round trip of every carried
kind, a rejected kind), `iface_build_self_test.l` (producer, functions and methods). The consumer side is the main builder's.
