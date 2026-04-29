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

/// A resolved function signature. Generic-parameter names are
/// recorded here; bound enforcement (where T: Compare) is the type
/// checker's later concern (T6).
type ResolvedSignature =
    { Generics: string list
      Params:   ResolvedParam list
      Return:   Type
      IsAsync:  bool
      Span:     Span }
