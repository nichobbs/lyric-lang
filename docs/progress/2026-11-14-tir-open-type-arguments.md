# 2026-11-14 - TIR builder: open type arguments, branch and construction conversions, package-qualified callees (D483)

A generic call whose type arguments the checker left open reads them from the type its context fixes; an annotated binding
settles its initializer; a `match` or `if` whose branches all leave is `Never`; a branch or construction converts like an
argument (interface upcast, `Some(x)` at another `Option`), a `Task[T]` passes as a host `Task`, `Pkg.Type.f(x)` and
`Pkg.Type.tryFrom(s)` resolve, and a stdlib literal default builds without an interface. Compiler census (dotnet): 12152 ->
12673 of 12818 bodies built, I0003 0. Test: `scripts/ci/tir-builder-shapes-e2e.sh`.
