# D-progress-964 — Generic calls inside protected-type members are specialised

**Status:** shipped

## Problem

`Lyric.Mono` specialised generic calls in functions, `impl` and interface
methods and module-level `val` initializers, but never walked a protected
type's `entry` or `func` bodies. A generic call there (`mapValues(rows)` over
a protected `Map` field) stayed generic, and MSIL codegen, which needs the
specialisation, failed with T0123 ("no function token could be resolved").
The JVM, which erases, compiled it.

## Decision

Mono rewrites each `entry` and `func` of a non-generic protected type like a
method body. The member's scope holds its parameters, then every protected
field (`var`, `let` or immutable) a parameter does not shadow, so a generic
call over a field infers its type arguments from the field's declared type.
A generic protected type's members mention its type parameters and are left
unchanged, as before.

## Verification

`mono_self_test.l` specialises a generic call over a protected field, and
`synthesized_method_self_test.l` calls `mapValues` over a protected `Map`
field at run time on MSIL and the JVM.
