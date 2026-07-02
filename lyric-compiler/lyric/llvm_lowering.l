//! llvm/lowering.l — Lyric.LlvmLowering (N1.1).
//!
//! Thin delegation layer between the codegen's `NPackage` and the `.ll`
//! text serialiser, mirroring the `Msil.Lowering` / `Jvm.Lowering`
//! package boundary so the bridge composes the same way on every
//! backend.  The IR data types live in `Lyric.LlvmIr` (they are shared by
//! the serialiser); this package owns the "IR → text" step.
package Lyric.LlvmLowering

import Std.Core
import Std.Collections
import Lyric.LlvmTypes
import Lyric.LlvmIr

/// Render one function: a `declare` line for externs, a full
/// `define { ... }` block otherwise.
pub func lowerNativeFunc(f: in NFunc): String {
  if f.isExtern {
    emitFuncDecl(f)
  } else {
    emitFuncDefn(f)
  }
}

/// Render the whole package as `.ll` module text.
pub func lowerNativePackage(pkg: in NPackage): String {
  emitModule(pkg)
}
