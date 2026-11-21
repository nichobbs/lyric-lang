# Calls through a wire's generated factory are typed IR intrinsics (docs/70 phase 3a, #8613)

**Status:** shipped; checker (the type of the call), builder, model and interface codec.

## Context

A `wire W { ... }` block generates a static factory: `W.bootstrap(provided...)` builds the bindings, and each exposed binding has a zero-argument accessor `W.binding()` of its declared type. The backends register these signatures themselves (`registerStaticWireSig`); the checker typed the call as an error and recorded no callee, so everything downstream of it was untyped as well, and the TIR gate (D347) stopped every body that used a wire (`examples/agent/di-and-async.l`, `Pu`-style facade apps, the wire alias fixtures).

## Decision

- `IntrinsicOp` gains `IoWire(wire, member)`: `wire` is the wire's `Pkg::Name` key, `member` is `bootstrap` or the binding's name. The node's type is `Unit` for `bootstrap` and the binding's declared type for an accessor.
- The checker types the call (`wireFactoryType`): `bootstrap` takes the wire's `@provided` members in declaration order, each argument checked against its type, and is `Unit`; an accessor of an exposed `singleton` or annotated `val` binding is its declared type. A value read from an accessor is thereby typed, with its fields and methods.
- The builder recognises `W.bootstrap(args)` and `W.binding()` when `W` names a wire in the table and no local shadows it (`wireCallOf`): `bootstrap` takes the wire's `@provided` members in declaration order; an accessor needs the binding exposed and, as the JVM registers them, a `singleton` or an annotated `val`. Each argument is built at its parameter's type. Anything else about a wire stays counted.
- The interface codec writes the intrinsic as code 18 with two strings; the dump prints `wire W.member`.
- The ported native lowering reports a call through a wire as unsupported; native wire lowering is phase 5 work, as the native backend consumes no wire factories from TIR yet.

## Results

`tir_build_self_test.l` builds a function that bootstraps a wire and reads an exposed binding; `examples/agent/di-and-async.l` builds under `--verify-ir`.
