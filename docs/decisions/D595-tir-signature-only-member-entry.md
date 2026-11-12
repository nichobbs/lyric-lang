# D595 - A member whose body does not build keeps a signature-only entry (docs/70 phase 3a, #8613)

**Status:** shipped; extends D579 and D582.

## Context

`buildPackage` describes a member the package builds by its declaration (`ownFnEntry`), because the entry a call site
records is the call's instantiated signature: a call of `Chan[Int].put` sees `Chan[Int]`, not the owner's `T`. A member
whose body failed to build had no declaration, so its entry stayed the first call site's. A second call at another
instantiation then failed `call-arg-type` (`protected_exclusion_dotnet_self_test.l`: `Chan[String]` expected, `Chan[Int]`
found).

## Decision

`buildFnCore` takes `sigOnly`, which builds the symbol, type parameters (the owner's first), parameters and return type
and skips defaults, contracts and the body; `FnCore.body` is an `Option`. `buildFnSigDecl` and `buildMemberSig` return the
body-less `TFnDecl`, and `buildPackage` builds one for every member whose body failed and describes the symbol with
`ownFnEntry` like a built member (an entry stays `TSkEntry`). The body-less declaration is not added to `funcs`, and its
errors are not folded into the package's counts. A signature that itself cannot be converted still leaves the call site's
entry.
