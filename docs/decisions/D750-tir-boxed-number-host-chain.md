# A boxed number a host call returns keeps its host class as a chain receiver (docs/70 phase 3a, #8613)

**Status:** shipped; builder only, the checker is unchanged.

## Context

`JInteger.valueOf(42).intValue()` and other calls on a boxed number a host call returned (`Long.valueOf(n).longValue()`, `Character.valueOf(c).charValue()`) were stopped by the TIR gate (D347) as "a call the checker did not resolve". The checker leaves the result of the inner host call untyped (docs/01 section 2.11), and the builder types such a chain from the host metadata (D444), but `hostChainResult` refused every boxed number class: the checker maps them to a Lyric type, so "the checker's own type applies". Where the checker recorded no type there is none to apply, and the member that follows is the box's own. `java.lang.Boolean` was already an exception for this reason.

## Decision

`hostChainResult` keeps `java.lang.Integer`, `Long`, `Short`, `Byte` and `Character` as the host class, as it does `Boolean` (`isJvmBoxedName`). It is consulted only for a call the checker recorded no type for, so a boxed result the checker typed is unaffected.

## Not covered

The CLR's boxed numbers are `System.Int32` and the like, which the dotnet checker types; nothing here changes them.
