# JVM: a return whose operand already ended the method (2026-11-08)

`@derive(Hash)` on a union builds `return match self { case C(f0) -> { var h = ...; return h } ... }`, a
`match` in the operand of a `return` whose arms all `return`. The JVM lowered the `match` correctly (no
join label, since no arm falls through) but `SReturn` then coerced the missing value and emitted another
`ireturn` in unreachable code with an empty operand stack, so the class failed verification with
"Operand stack underflow" (#8828). `SReturn` now emits nothing more when its operand already ended the
method (a `match` whose arms all `return` or `throw`, a `panic`). The same applies to any hand-written
`return match { ... return ... }`. Covered by a union `@derive(Hash)` case in `map_key_self_test.l`
(dotnet and JVM).
