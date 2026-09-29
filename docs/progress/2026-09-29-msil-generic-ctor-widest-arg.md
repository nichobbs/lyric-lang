# MSIL: a generic record's instantiation comes from its widest argument (#7794)

A `--target dotnet` silent miscompile. For a generic record whose fields are
a bare type parameter,

```
record Two[T] { a: T  b: T }
func longFromCall(): Long { 3000000000 }
val t = Two(a = longFromCall(), b = 4)
t.a + t.b   // read back -1294967292, not 3000000004
```

`Msil.Codegen` lowers the constructor's arguments in order, then infers the
closed instantiation (`Two`1<?>`) from their lowered MSIL types
(`buildInBundleGenericCtorTok`; `buildGenericCaseCtorTok` for a
cross-assembly generic record or union case). The per-type-parameter scan let
every later argument overwrite the earlier one, so the trailing literal `4`
pinned `T` to `Int32` and the `int64` argument was stored into an `int32`
field. The reverse order (`Two(a = 4, b = longFromCall())`) only worked by
luck: `T` became `Int64` but the literal was still pushed as an `int32` where
the constructor takes an `int64` (unverifiable IL the JIT tolerated). Any
wider argument shape before a narrower one was affected — a call, a binary
operation, a field read — whenever the value needed more than 32 bits.

Generic *functions* were not affected: the monomorphizer (`Lyric.Mono`)
already specialises them at the widest numeric argument by the checker's rule
(`unifyArgMono`), and the specialised parameters widen their arguments at the
call boundary.

**Fix.** Both inference scans now never narrow: a type parameter already
pinned to a wider primitive (`Byte < Int < Long < Double`,
`isWiderPrimMsil`) is not replaced by a narrower argument's type. The
argument loop records where each argument's instructions end, and once the
instantiation is known `widenGenericCtorArgsMsil` splices the widening
conversion (`widenPrimToSlotMsil`: `conv.i8` into `Long`, `conv.r8` into
`Double`) directly after each narrower argument bound to a bare type
parameter, last argument first so the recorded positions stay valid. This
also widens arguments whose instantiation comes from the context (the
enclosing function's declared return type). No temporaries are introduced, so
generator/async-state-machine slot accounting is unchanged.

**Before / after** (`--target dotnet`, `t.a + t.b`):

| construction | before | after |
|---|---|---|
| `Two(a = longFromCall(), b = 4)` | `-1294967292` | `3000000004` |
| `Two(a = big * 1, b = 4)` (`big = 3000000000`) | `-1294967292` | `3000000004` |
| `Two(a = h.n, b = 4)` (`h.n: Long`) | `-1294967292` | `3000000004` |
| `Two(a = longFromCall(), b = n)` (`n: Int = 5`) | `-1294967291` | `3000000005` |

**Tests.** The `Two(a = longFromCall(), b = 4)` case moved from the JVM-only
`lyric-compiler/jvm/erased_slot_widen_jvm_self_test.l` into the dual-target
`lyric-compiler/lyric/erased_slot_widen_self_test.l`, joined by call,
binary-operation and field-read arguments against a literal and an `Int`
expression in both orders (values past `Int32` range, so truncation shows),
a negative wider argument, and the same shapes as generic-function
arguments. Passes on `--target dotnet` and `--target jvm`.
