/// Resolved function-signature representation, shared by the
/// expression checker (which needs to type calls against the
/// signature) and the top-level Checker (which builds the
/// per-package signature map).
namespace Lyric.TypeChecker

open Lyric.Lexer
open Lyric.Parser.Ast

/// A resolved function/entry parameter — the parser's Param after
/// type resolution.
type ResolvedParam =
    { Name:    string
      Type:    Type
      Mode:    ParamMode
      Default: bool
      Span:    Span }

/// A resolved `where T: M1 + M2` bound: the generic parameter name
/// followed by the markers/interfaces it must satisfy (each as a
/// bare identifier; qualified constraint paths surface as a checker
/// diagnostic at definition time).
type ResolvedBound =
    { Name:        string
      Constraints: string list }

/// A resolved function signature. Generic-parameter names are
/// recorded alongside their `where`-clause bounds so call-site
/// inference can check that inferred type arguments satisfy the
/// declared markers.
type ResolvedSignature =
    { Generics: string list
      Bounds:   ResolvedBound list
      Params:   ResolvedParam list
      Return:   Type
      IsAsync:  bool
      Span:     Span }
