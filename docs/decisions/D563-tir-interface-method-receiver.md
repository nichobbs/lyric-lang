# D563 - A call of an interface method passes the value as the receiver (docs/70 phase 3a, #8613)

**Status:** shipped; extends D389 and D553.

## Context

An interface declares its methods without a receiver parameter (`func get(url: in String)`), so the
signature the checker records for `client.get(url)` on an `HttpClient` has no `recvMode`. The method
call builder counted that as `a method call with no declared receiver` (30 over the stdlib census,
the largest part of it calls on `HttpClient`, `Std.Testing` and `Std.Log` interfaces), and the
function never built.

## Decision

A method call recorded as dispatched on an interface (`MethodCallSite.iface`) whose signature
declares no receiver mode takes the value it is called on as its receiver, passed `in`, exactly as a
protected-type entry does (D553); the callee is `Interface(iface, method)` with the receiver first.
A signature with a declared mode keeps that mode, and a mutating receiver is still counted.

## Measured

`scripts/ci/tir-census.sh` over the 98 programs, on top of D562: bodies built 1039 -> 1053 of 1165,
I0003 0; `a method call with no declared receiver` 30 -> 11 (what is left is calls on receivers that are
neither protected types nor interfaces).
