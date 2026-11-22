# A method call on a bounded type parameter is a call through the bound's interface member (docs/70 phase 3a, #8613)

**Status:** shipped; checker (the call's type, callee and site) with no builder change.

## Context

`func talk[T](x: in T): Int where T: Speaker { x.say(1) }` is valid: only the methods of the `where` bounds can be called on a value of a type parameter (T0197). The checker's method-call resolution (`resolveMethodCallPick`) knows concrete receivers only, so the call had no type, no callee and no call site, and the TIR gate (D347) stopped the body (`AliasRewriterSelfTest::logAndReport`).

## Decision

For a member call whose receiver is a value of a type parameter in scope, `resolveBoundMethodPick` picks the member of that name, with `Self` the parameter, from the interfaces its `where` clause names, the first whose parameters the call fits. The call is typed from that signature and records the interface member as its callee and a call site with the interface (`MethodCallPick.boundIface`, `recordMethodCallSite`), as a call on an interface-typed value does; the builder builds it as a `Callee.Interface` call with the parameter-typed receiver, the form the verifier already checks.

## Results

`tir_build_self_test.l` builds `talk` and checks the callee is an interface call with the receiver first.
