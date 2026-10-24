//! std/_kernel_native/annotation_meta_host.l - native twin of
//! `_kernel/annotation_meta_host.l`.
//!
//! The native backend does not yet embed `Lyric.AnnotationMeta` metadata in
//! its output (the compile-time half of #6866 covers the MSIL and JVM
//! bridges only), so there is nothing to read.  The kernel reports that
//! honestly through `hostAnnotationMetaSupported`, and `Std.AnnotationMeta`
//! turns it into an `Unsupported` error rather than an empty answer that
//! would be indistinguishable from "no annotated fields".  Native emission
//! and this twin's real implementation are tracked in #8524.
@axiom("The native backend embeds no annotation metadata; the probe reports false")
@io
package Std.AnnotationMetaHost

import Std.Core

/// False: the native backend embeds no annotation metadata.
pub func hostAnnotationMetaSupported(): Bool {
  false
}

/// Always empty; callers gate on `hostAnnotationMetaSupported`.
pub func hostAnnotationMetaDocuments(): slice[String] {
  val none: slice[String] = []
  none
}
