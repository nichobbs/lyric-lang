module Lyric.Lexer.Keywords

open System.Collections.Generic

/// The canonical source spelling of a keyword.
let spelling (kw: Keyword) : string =
    match kw with
    | KwAlias -> "alias"        | KwAnd -> "and"
    | KwAs -> "as"              | KwAsync -> "async"
    | KwAwait -> "await"        | KwBind -> "bind"
    | KwCase -> "case"          | KwDo -> "do"
    | KwElse -> "else"          | KwEnd -> "end"
    | KwEnsures -> "ensures"    | KwEntry -> "entry"
    | KwEnum -> "enum"          | KwExposed -> "exposed"
    | KwExtern -> "extern"      | KwFalse -> "false"
    | KwFixture -> "fixture"    | KwFor -> "for"
    | KwFunc -> "func"          | KwGeneric -> "generic"
    | KwIf -> "if"              | KwImpl -> "impl"
    | KwImport -> "import"      | KwIn -> "in"
    | KwInout -> "inout"        | KwInterface -> "interface"
    | KwInvariant -> "invariant"| KwIs -> "is"
    | KwLet -> "let"            | KwMatch -> "match"
    | KwMut -> "mut"            | KwNot -> "not"
    | KwOld -> "old"            | KwOpaque -> "opaque"
    | KwOr -> "or"              | KwOut -> "out"
    | KwPackage -> "package"    | KwProperty -> "property"
    | KwProtected -> "protected"| KwPub -> "pub"
    | KwRecord -> "record"      | KwRequires -> "requires"
    | KwResult -> "result"      | KwReturn -> "return"
    | KwScope -> "scope"        | KwScoped -> "scoped"
    | KwSelf -> "self"          | KwSingleton -> "singleton"
    | KwSpawn -> "spawn"        | KwTest -> "test"
    | KwThen -> "then"          | KwThrow -> "throw"
    | KwTrue -> "true"          | KwTry -> "try"
    | KwType -> "type"          | KwUnion -> "union"
    | KwUse -> "use"            | KwVal -> "val"
    | KwVar -> "var"            | KwWhen -> "when"
    | KwWhere -> "where"        | KwWhile -> "while"
    | KwWire -> "wire"          | KwWith -> "with"
    | KwXor -> "xor"

/// Every keyword in declaration order.
let all : Keyword list =
    [ KwAlias; KwAnd; KwAs; KwAsync; KwAwait
      KwBind; KwCase; KwDo; KwElse; KwEnd
      KwEnsures; KwEntry; KwEnum; KwExposed; KwExtern
      KwFalse; KwFixture; KwFor; KwFunc; KwGeneric
      KwIf; KwImpl; KwImport; KwIn; KwInout
      KwInterface; KwInvariant; KwIs; KwLet; KwMatch
      KwMut; KwNot; KwOld; KwOpaque; KwOr
      KwOut; KwPackage; KwProperty; KwProtected; KwPub
      KwRecord; KwRequires; KwResult; KwReturn; KwScope
      KwScoped; KwSelf; KwSingleton; KwSpawn; KwTest
      KwThen; KwThrow; KwTrue; KwTry; KwType
      KwUnion; KwUse; KwVal; KwVar; KwWhen
      KwWhere; KwWhile; KwWire; KwWith; KwXor ]

let private byString : IReadOnlyDictionary<string, Keyword> =
    let d = Dictionary<string, Keyword>()
    for kw in all do
        d.[spelling kw] <- kw
    d :> IReadOnlyDictionary<_, _>

/// If the given identifier-shaped string matches a reserved keyword,
/// return it; else None. Soft keywords ('range', 'derives', 'forall',
/// 'exists', 'implies', 'scope_kind') are *not* recognised here — the
/// parser resolves them contextually.
let tryFromString (s: string) : Keyword option =
    match byString.TryGetValue(s) with
    | true, kw -> Some kw
    | false, _ -> None

/// True iff the given identifier-shaped string is a reserved keyword.
let isKeyword (s: string) : bool =
    byString.ContainsKey(s)
