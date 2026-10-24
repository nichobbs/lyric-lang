# JVM: bindings of an `if` or `match` over list literals are slices; lyric-game JVM tests in CI (#8516)

On `--target jvm`, `val xs = if c { [0, 4, 0] } else { [0] }` kept the literals'
construction-time `ArrayList`, so `xs.length` failed with J009 and `xs[i]` read
an erased `Object`. Only a bare literal binding was converted to the slice
representation (#7524). `Jvm.Codegen`'s `isListLiteralExpr` now accepts an
`if` with an `else`, a `match` or a block when every value it produces is a
list literal; arms that end in `return` or `throw` produce none. The element
type is inferred across all the literals' elements (`scrutineeGenericArgs`'s
new `EIf`/`EMatch` arms), so `xs[i]` keeps its type. Found through
lyric-game's PNG decoder (`Game.Image.rawSize`).

The other failure #8516 reported, `wav rejects damage` (`Buf.fromSlice` of a
list literal throwing `Illegal Capacity: -1`), no longer reproduces on main
after D226's buffer rework.

Tests: `static_type_recovery_jvm_self_test.l` case "an if or match choosing list
literals binds a slice (#8516)", run on both targets. lyric-game's core and
Breakout's rules now run under `lyric test` on dotnet and the JVM in CI (the
`game` entry of `ecosystem-tests`); before, only the native job ran them, on
dotnet, and only when native code changed.
