# D359 - The last classes of silent TyError and their rules (docs/70 phase 3a, #8613)

**Status:** shipped. Completes the census D357 left open; D385 switches the gate on.

## Context

D357 listed the classes of silent `TyError` (a typed expression with no type and
no diagnostic) the census found beyond the library and compiler builds: open
collections after a tuple pattern, a tuple scrutinee, host arrays and constants,
extern property reads, an open receiver, an upcast operand, `result.field` in an
`ensures:` of a protected type, a generic distinct type's constructor and the
JVM-only sites. Each needs a typing rule or a named unchecked kind, or the I0001
gate would reject programs the backends compile.

## Decision

1. **An unsolved type argument is the named open hole `tyErrorOpen()`** (`DiagId`
   index -4, not counted by the gate). `inferOneGenericArg` returns it when no
   argument binds the parameter, so `val xs = newList(); xs.add(3); xs[0]`, a list
   destructured from a tuple, a tuple scrutinee and an open receiver are named
   until a later use fixes them (`resolveOpenBindingSites`) or `reportUnsolvedTypeArgs`
   reports T0224. This covers classes 1, 2 and 5.
2. **`T.new(args)` on an extern type the file declares or imports binds the host
   constructor** even when a package the file imports exports a same-named Lyric
   type with its own `new` (`import extern System.Text.{StringBuilder}` against
   `Std.String.StringBuilder`). The checker had typed the value as the Lyric type,
   so every host member read of it was untyped; the backends already bound the host
   type. This covers the extern property reads and writes (class 4).
3. **`NetChar.MaxValue.toInt()`**: a member of an extern type named through the
   type is a host constant or property, a value the member read types; only the type
   name is a qualifier position. A conversion method (`toInt`, `toLong`, ...) of an
   unchecked host value is as unchecked as the value, with its cause (D354 4), so
   `xs[0].toInt()` on a host array is named.
4. **`externAsObject(x)` of an unchecked operand** is the root extern object type
   (the operand is a host call's result); a silent operand stays silent.
5. **A protected type's field read** (`result.tokens` in an `ensures:`) has the
   field's declared type, from the protected declaration, as an opaque type's field
   does. T0221 still refuses a read outside the type's own members and contract
   clauses.
6. **A generic distinct type's constructor call** (`Wrapped(xs)`) takes its type
   arguments from the wrapped value (`inferGenericArgsDeep`) and checks the value
   against the substituted underlying type; an argument nothing fixes is the open
   hole.
7. **A universal method name with another arity is an ordinary member**:
   `Arrays.toString(xs)` and `Objects.hash(xs)` on an extern type were typed by the
   arity-0 intrinsic rule and came out untyped on the JVM.

8. **A package-qualified config read** (`P.Cfg.field`) is typed only inside `P`:
   config blocks are package-private (docs/25 2.2), so a read through another
   package's name is not resolved, and a read no rule resolves whose receiver is
   a package-qualified name is the error T0020 ("unknown name"), never a silent
   or merely named value. `examples/jobqueue` read `Worker`'s config from
   another package; it now goes through a `pub func pollIntervalMs()`.

9. **A member read off a primitive or a slice** (`n.bogus`, `xs.bogus`) that names
   none of its built-in members is the error T0113 ("no member"), as a call of
   one already was. A `String` is no exception for a plain member read (`s.bogus`);
   a call of an open host `String` method is a call and is handled apart. The backends' J010
   and J011 aborts stay as defence in depth; the two JVM source tests that could
   reach them only through the checker's silence (`jvm_trycatch_bridge_self_test.l`)
   are replaced by a checker test, since no source reaches them any more.

New user-visible diagnostics: T0020 for a package-qualified read no rule resolves
(item 8) and T0113 for an unknown member of a primitive or slice (item 9); both
codes already existed and their book rows cover them.

## Tests

`typechecker_self_test.l`: the open generic value, the protected field (and T0221
and a wrong type), the generic distinct constructor, the host conversion. The
shapes that need a bridge are covered by the gate in `import_extern_self_test.l`,
`extern_upcast_self_test.l`, `auto_ffi_self_test.l`,
`expected_type_propagation_self_test.l`, `await_hoist_typed_self_test.l`,
`auto_ffi_jvm_self_test.l` and `examples/token_bucket_proof.l`, which are now
clean under it.
