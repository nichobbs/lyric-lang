// msil/bridge.l — Self-hosted MSIL compilation pipeline stub (Phase R6).
//
// Provides the public entry point `compileToMsil(source, outputPath): Bool`
// that will eventually chain:
//   Lyric.Parser.parse → Lyric.TypeChecker.check → Msil.Codegen.codegenPackage
//   → Msil.Lowering.lowerMPackage → write bytes to outputPath
//
// Phase R5 shipped Msil.Lowering (the PE byte layer).  The missing piece for
// R6 is Msil.Codegen — the AST-to-MPackage lowering that mirrors Jvm.Codegen.
// Until Msil.Codegen is implemented, this bridge panics with a clear message
// so callers get a visible error rather than a silent no-op.
//
// The F# bootstrap emitter (Lyric.Emitter) continues to handle the dotnet
// target for all production builds.  This self-hosted path is a Phase 6
// deliverable intended to eventually replace the F# emitter for cross-platform
// (non-.NET-hosted) scenarios.
//
// See docs/33-platform-parity-remediation.md §5.5 (Phase R6) for the plan.

package Msil.Bridge

import Std.Core

/// Compile Lyric source to a .NET PE DLL using the self-hosted MSIL emitter.
///
/// Phase R6 stub — panics until Msil.Codegen is implemented.
/// The F# bootstrap emitter handles all production dotnet builds today.
pub func compileToMsil(source: in String, outputPath: in String): Bool {
  panic("Msil.Bridge.compileToMsil: self-hosted MSIL codegen (Msil.Codegen) is not yet implemented. Use the F# bootstrap emitter (lyric build without --target msil-self-hosted). See docs/33-platform-parity-remediation.md §5.5 for the Phase R6 plan.")
}
