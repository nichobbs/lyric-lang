# `b.toSlice()` on a `buffer[T]` is typed as the slice it returns (docs/70 phase 3a, #8613)

**Status:** shipped; type checker member types.

## Context

An array's `.toSlice()` has a built-in member type (a function from nothing to `slice[T]`), so the call is typed and recorded as the built-in. A `buffer[T]` is a `TyUser` of the built-in buffer type and its member table had only `.length`, so `bytes.toSlice()` was left untyped with no diagnostic and the typed IR builder reported I0002 (`buffer_self_test.l`). The function form `toSlice(bytes)` was typed.

## Decision

The built-in member table gives a buffer's `.toSlice()` the type of a function from nothing to `slice[T]`, as an array has, so the call is typed and recorded as the built-in member call.

## Results

`buffer_self_test.l` builds on dotnet, the JVM and native.
