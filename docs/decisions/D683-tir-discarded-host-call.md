# A discarded call on a generic host class settles at the host's root object (docs/70 phase 3a, #8613)

**Status:** shipped; builder only, the checker is unchanged.

## Context

`hostChainResult` types a call the checker left untyped from the host's metadata, and it declines the host's erased root `Object` result when the host class is generic and applied to concrete arguments (`ConcurrentHashMap<String, String>.put(K, V)` returns the erased `V`): a use of that value would need the argument's type, and the builder does not guess it. A statement `d.put("a", "1")` does not use the value, so the decline made the body unbuilt (`Alias6338Generic.Helper::makeDict`, `XDictHelper::makeDict`, and any `Unit` function ending in such a call), which the TIR gate (D347) reports as I0002.

## Decision

- `settleDiscardedHostCall` runs for every expression statement and for the last expression of a `Unit` function body (whose value `discardTailValue` drops). When the checker recorded no type for a call on a host receiver and every candidate of the member returns the host's root object, the node settles at that object; a used value keeps `hostChainResult`'s rule.
- A member any of whose candidates returns something else, or whose static-ness differs from the receiver's, settles nothing.

## Results

`tir_build_self_test.l` holds the case (a local bound from an `@externTarget` constructor, and a `Unit` function whose only statement is the call); the two fixture bodies build under `--verify-ir`.
