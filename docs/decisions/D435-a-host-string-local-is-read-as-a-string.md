# D435 - A local holding a host string is read as a `String` through `CvFromHost` (docs/70 phase 3a, #8613)

**Status:** shipped; extends D433. The checker is unchanged: docs/01 section 2.11 leaves a host result unchecked.

## Context

The checker types a host call's string `String?` (the host may return null) and then lets it flow where a `String` is wanted. `val path = exchange.getRequestPath()` followed by `Request(path = path)` (`Web.Kernel.Runtime.buildJvmRequest`) gave the local the type `String?` and the read the checker's `String`, so the verifier rejected the read (`local-type: local path: expected String? but found String`). D433 handled a local bound to a host `Object`; a host string was the other half.

## Decision

A read of a local whose declared type is `String?` where the checker's type for the read is `String` is built as `CvFromHost` over the local (`hostStringReadAsString`). The verifier accepts `CvFromHost` over a `String?` operand as well as a host-typed one. A `String?` read as `String` is a checker error everywhere else, so only an unchecked host string reaches this case.

## Results

`jvm_host_kernel_shapes` in `tir-builder-shapes-e2e.sh` builds and runs the shape; `Web.Kernel.Runtime::buildJvmRequest` builds with 0 I0003.
