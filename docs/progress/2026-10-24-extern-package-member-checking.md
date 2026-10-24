# Calls into `extern package` members are type-checked (#7934, D223)

A function member of an `extern package { ... }` block had no signature in the type checker, so a call to it was
never checked for arity or argument types and typed as `TyError`. `registerItem` and `addSigsFromItems` now register
each member as a body-less function under the block's own path (and under the enclosing package, unless that package
declares a function of the name and arity itself); the call path resolves `lyric.db.Postgres.connect(...)` and
`Grpc.Kernel.Jvm.netOpenChannel(a)` against them and reports `T0042`/`T0043` as for any call. The block's path needs
no import (no T0020), and its receiver chain is no longer inferred as a value. See D223.

The audit of lyric-db, lyric-grpc and lyric-aws-xray found no mismatch: the only live callers are grpc.l's calls into
`Grpc.Kernel.Jvm`, which agree with the declarations; the xray kernels are never called; the db JVM kernel does not
parse and is not part of the manifest (documented in lyric-db/README.md). The JVM grpc kernel still cannot run, since
JVM codegen has no lowering for extern-package members (J002), which is separate from this check.

Verified by 5 new `typechecker_self_test.l` cases (correct calls and result flow, wrong type, wrong arity, a call
through the enclosing package, a wrapper named like a member); all fail against the previous compiler. docs/01 §11.1
and book chapter 13 describe the check.
