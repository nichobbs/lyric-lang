# D493 - A host method called on a `String` value is an extern call with the value as receiver (docs/70 phase 3a, #8613)

**Status:** shipped; extends D365 (extern calls through host metadata) and D479.

## Context

The JVM kernels call `java.lang.String` methods on a Lyric `String` directly (`a.compareTo(b)` in `Std.StringHost.hostCompareOrdinal`; `--target jvm` reaches a `String`'s host methods by name, docs/01 section 12.1). The checker types the call but records no callee, because the receiver is not an `extern type`, so the body stayed counted (I0002, "a call the checker did not resolve"). The host's string is Lyric's `String`, so the receiver needs no conversion.

## Decision

In `buildCall`, a call `s.m(args)` whose receiver is typed `String`, with no callee recorded, is an extern call on whichever host string type (`java.lang.String`, `System.String`) the host metadata says declares `m` for that argument count. `buildExternCall` takes the `String` value itself as the receiver (its parameter type is `String`, not `TExtern`), and treats a `String` receiver like a host value for overload choice, so an instance overload wins over a same-named static one (D479). No checker change: the checker's result type for the call is unchanged.

## Withdrawn alternative

Typing a host class result as the `extern type` that names it (an earlier D493 draft, #9175) was withdrawn: docs/01 section 2.11 deliberately leaves a host class result unchecked so a kernel can bind it at a subtype (`val c: JX509Certificate = cf.generateCertificate(in)` in `tls_server_jvm_tests.l`), and CI found that source. A chain of host calls through such a result still needs a design that keeps the checker's result unchecked.

## Results

`tir_build_self_test.l` gains a case (`a.compareTo(b)` on a `String` builds as an extern call with the receiver first, 0 I0003).
