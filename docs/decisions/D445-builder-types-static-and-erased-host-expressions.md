# D445 - The builder types static host members, string results and type-parameter receivers (docs/70 phase 3a, #8613)

**Status:** shipped; extends D444. The checker is unchanged: docs/01 section 2.11 still leaves a host result unchecked.

## Context

D444 typed a call or property read on a receiver whose host class is already known. Four further shapes left the standard library's JVM kernels and their tests counted, because the checker records no type (`<error>`) or no callee for them.

## Decision

Each shape is one more case beside `openHostChainTy` and `buildHostMethodOnChain`:

- **Static members.** A receiver that is a bare `extern type` name with no type arguments (and no local of that name) is a static host receiver (`hostStaticReceiver`: the host name is the declaration's `clrName`). `openHostChainTy` and `hostChainResult` take a `wantStatic` flag, so `JCharacter.TYPE` and `JKeyManagerFactory.getInstance(..)` are typed from the host's static candidates, and a call on that result chains as before. `buildHostStaticRead` builds the static field or property read as an extern `HMFieldGet`/`HMPropertyGet` with no arguments.
- **String results.** A host call's string is typed `String?`, as the checker types a typed host call. A `String?` argument for a host string parameter takes `CvBoxToHost` (the host takes the reference, null included).
- **Type-parameter receivers.** `target.getClass()` where `target` has a type parameter's type resolves the member on the host's root object class (`hostMethodOnTypeParam`), and `buildExternCall` boxes the receiver to it with `CvBoxToHost`.
- **Root object and arrays.** A non-generic host class's root-`Object` result is typed `Object` (`Method.invoke`); an untyped host array result of bytes or plain host classes is typed as the slice of its element and converts with `CvFromHost` (`hostArrayAsSlice`). A typed array result keeps the checker's slice, as D444 requires.
- **Narrowing.** A host result the checker lets flow into a more specific declared host class (`val c: X509Certificate = cf.generateCertificate(in)`) takes `CvFromHost` when the declared class has the host's result among its bases (`hostResultNarrowsTo`).

## Results

The standard-library census builds 2590 of 2651 bodies with 0 I0003; `tls_server_jvm_tests.l` builds all 12 of its bodies (4 before). `tir-builder-shapes-e2e.sh` gains `jvm_host_static_shapes` (built with `--target jvm --verify-ir` and run).
