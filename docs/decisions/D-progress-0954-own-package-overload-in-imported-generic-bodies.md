# D-progress-954 — A bare call in an imported generic body prefers its own package's overload

**Status:** shipped

## Problem

When a consumer imports two packages that both declare a function `f` at
the same arity, `Lyric.Mono` records `f` as ambiguous and resolves each
call site by argument compatibility. A generic body imported from one of
those packages (say `Ui.Testing.findButton`, whose body calls its own
`findAll`) is specialised into the consumer, and its bare `f(...)` call went
through the same resolution. When the arguments could not tell the
candidates apart (`Std.Xml.findAll(node, tag)` against
`Ui.Testing.findAll[Msg](v, kind)`), mono gave up: the call stayed generic
and MSIL codegen reported T0123 ("make 'findAll' `pub`"), although it
already was. With a non-stdlib collision the call bound the other package's
function and produced invalid IL.

## Decision

The body was type-checked in its own package, where that package's
declaration shadows every imported one of the same name. After arity
filtering, `resolveAmbiguousOverload` therefore picks the unique candidate
whose origin (`__lyric_origin`) is the package the body being specialised
came from (the top of `MonoState.originScope`). Argument compatibility
still decides when the body's own package declares none or several
candidates, and calls in the consumer's own code are unaffected.

## Verification

`emitter_project_self_test.l` gains the EPOv project (consumer first,
`EPOv.Core.findFirst` calling its own generic `findAll`, and
`EPOv.Other.findAll(String, String)` imported alongside) on MSIL and JVM.
