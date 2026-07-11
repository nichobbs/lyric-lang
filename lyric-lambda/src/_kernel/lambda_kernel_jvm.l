//! Lambda.Kernel.Runtime (jvm) — AWS Java managed runtime: NOT IMPLEMENTED.
//!
//! This file used to declare `extern package com.amazonaws.lambda` with an
//! `@axiom`-trusted `serve()` binding — an unbacked claim: no code anywhere
//! in this repository (or any consumer) ever implemented that extern
//! target, and it could not have worked as declared even in principle. The
//! JVM managed Lambda runtime is **host-calls-into-Lyric**: AWS reflectively
//! instantiates a class implementing
//! `com.amazonaws.services.lambda.runtime.RequestStreamHandler` and calls
//! `handleRequest(...)` on it — the reverse of what `extern type` /
//! auto-FFI / docs/51's `impl <ExternInterface>` solve (those make *Lyric*
//! call *the host*; this needs *the host* to call *Lyric* through a
//! synthesized entry-point class), so it cannot be fixed by porting the
//! extern to a real binding the way `aws`/`local` were (see
//! `Lambda.Dispatch`, `src/dispatch.l`).
//!
//! Two designs are live candidates; neither has been decided (tracked in
//! the issue this file's fix closes):
//!
//!   (a) New self-hosted JVM emitter codegen that synthesizes a
//!       host-invoked entry-point class implementing
//!       `RequestStreamHandler`, reading the raw JSON from the handler's
//!       `InputStream` and writing the response to its `OutputStream`
//!       (docs/35-lambda-library.md §12.2's original design).
//!   (b) Redesign the JVM target onto the same HTTP long-polling
//!       custom-runtime protocol `Lambda.Dispatch` already implements for
//!       `aws`/`local`, via a small bootstrap executable (AWS supports
//!       "provided" custom runtimes on the JVM execution environment too;
//!       this would let the JVM target reuse `Lambda.Dispatch`'s dispatch
//!       logic almost unchanged, at the cost of losing the managed
//!       runtime's automatic handler-class wiring).
//!
//! Until that decision lands, `serve()` panics instead of silently
//! claiming a working extern boundary — calling `Lambda.serve` under
//! `feature = "jvm"` fails loudly and immediately, matching the standard
//! this repository holds every other genuinely-unimplemented backend to
//! (see e.g. `lyric-mq`'s and `lyric-storage`'s `NOT_IMPLEMENTED` errors).
//!
//! Enabled only when the "jvm" feature flag is active.
//! See docs/35-lambda-library.md §12.2, docs/18-jvm-emission.md, D064.
@cfg(feature = "jvm")
package Lambda.Kernel.Runtime

import Lambda

/// Not implemented — see this file's header comment for the two candidate
/// designs and why neither has been decided yet.
pub func serve(app: in LambdaApp, localPort: in Int): Unit {
  return panic(
    "Lambda.Kernel.Runtime (jvm): the JVM Lambda managed-runtime kernel is not implemented. " +
      "See lambda_kernel_jvm.l's header comment for the two candidate designs (a synthesized " +
      "RequestStreamHandler entry-point class vs. reusing Lambda.Dispatch's custom-runtime HTTP " +
      "polling loop via a bootstrap executable) -- this needs a product decision before " +
      "implementation can start."
  )
}
