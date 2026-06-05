//! typechecker_signature.l — resolved function signature representation.
//! Mirrors compiler/src/Lyric.TypeChecker/Signature.fs.
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Resolved parameter.
// ─────────────────────────────────────────────────────────────────────────────
@stable(since = "0.1")
pub record ResolvedParam {
  name: String
  ty: Type
  mode: ParamMode
  hasDefault: Bool
  span: Span
  // ─────────────────────────────────────────────────────────────────────────────
  // §2. Resolved where-clause bound.
  // ─────────────────────────────────────────────────────────────────────────────
}

@stable(since = "0.1")
pub record ResolvedBound {
  name: String
  constraints: List[String]
  // ─────────────────────────────────────────────────────────────────────────────
  // §3. Resolved function signature.
  // ─────────────────────────────────────────────────────────────────────────────
}

@stable(since = "0.1")
pub record ResolvedSignature {
  generics: List[String]
  bounds: List[ResolvedBound]
  params: List[ResolvedParam]
  returnTy: Type
  isAsync: Bool
  isHot: Bool
  isGenerator: Bool
  /// Dotted name of the package that declared this function (empty for the
  /// flat `checkWithImports` shim).  Disambiguates a qualified call
  /// `Pkg.func(...)` between two same-name/same-signature overloads in
  /// different packages (the alias-rewritten `Rx.tryCompile` case, #1488).
  originPackage: String
  span: Span
}
