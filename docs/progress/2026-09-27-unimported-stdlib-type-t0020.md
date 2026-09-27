# 2026-09-27 — Unimported stdlib type as a call receiver is T0020

D-progress-1001, #7345.

`Type.method(...)` on a type declared by a stdlib or ecosystem package the
file never imports (`RestClient.create(...)` with no `import Std.Rest`)
used to type-check silently and fail only at run time — MSIL threw
"unsupported method" from the generic erased-dispatch stub; JVM threw
`NoClassDefFoundError` naming the type under the calling package. The type
checker now emits **T0020** (`unknown name 'RestClient' (declared in
Std.Rest; add import Std.Rest)`) whenever the receiver names a real type
whose declaring package is not reachable — directly or transitively —
from the file's own imports, and is not part of the implicit `Std.Core`
prelude. A type reachable through the current package, an import (direct
or transitive, covering the stdlib's kernel/host re-export idiom), or the
prelude is unaffected. Both backends' generic unresolved-call runtime
stubs are left as-is: they remain the legitimate fallback for a call whose
receiver's concrete type is only known dynamically, and are simply
unreachable now for this one bare-type-name-receiver shape.

See D-progress-1001 for the full root-cause writeup, the scope this fix
does not cover (a fully package-qualified but still-unimported call), and
why the backends' runtime fallbacks were left unchanged.
