/// Compile-time integer constant folding (C3 / D-progress-025).
///
/// `tryFoldInt` walks a parser `Expr` and returns the folded `int64`
/// when the expression is an integer literal, a reference to a
/// `pub const` of integer type, or an arithmetic combination of
/// either.  Used by the range-bound well-formedness checker (T0090 /
/// T0091) and by the emitter's range-check IL emission so symbolic
/// bounds like `type Age = Int range MIN_AGE ..= MAX_AGE` get
/// validated and enforced like their literal-bound siblings.
///
/// Bootstrap-grade scope (option (b) in `docs/12-todo-plan.md` C3):
///
/// - `ELiteral (LInt n)` — the literal.
/// - `EPath { Segments = [name] }` resolving to a `DKConst` symbol
///   whose `Init` itself folds to an integer.  Cycle detection via a
///   `Set<string>` of names currently being resolved.
/// - `EBinop` for `+ - * / %` and `EPrefix` for unary `-` over folded
///   operands, with checked-arithmetic overflow detection.
/// - `EParen` is transparent.
///
/// Anything else returns `Err NotConstant`.  Function calls in
/// bounds, `if`-in-bounds, float literals, and mixed-width
/// arithmetic stay out of scope until a real use case justifies
/// option (c)'s full pure-expression folder.
module Lyric.TypeChecker.ConstFold

open Lyric.Parser.Ast

type FoldError =
    /// The expression isn't a constant we can evaluate at compile
    /// time — used for "shape we don't recognise" cases.
    | NotConstant
    /// A named-const reference loops back through itself.  Carries
    /// the name that closed the cycle for the diagnostic.
    | Cycle of string
    /// Integer overflow during evaluation.  The bound expression
    /// would produce a value outside `int64`'s range.
    | Overflow
    /// Division (or remainder) by zero in a constant expression.
    | DivByZero

/// Fold an Expr to an `int64`, given a symbol table for resolving
/// named const references.  Returns `Error NotConstant` for any
/// expression shape we don't recognise; `Error Cycle name` if a
/// const transitively references itself; `Error Overflow` /
/// `Error DivByZero` for arithmetic faults.
let tryFoldInt (table: SymbolTable) (root: Expr) : Result<int64, FoldError> =
    let rec go (visiting: Set<string>) (e: Expr) : Result<int64, FoldError> =
        match e.Kind with
        | EParen inner -> go visiting inner

        | ELiteral (LInt (n, _)) ->
            if n > uint64 System.Int64.MaxValue then Error Overflow
            else Ok (int64 n)

        | EPrefix (PreNeg, inner) ->
            match go visiting inner with
            | Error e' -> Error e'
            | Ok v ->
                if v = System.Int64.MinValue then Error Overflow
                else Ok (-v)

        | EBinop (op, l, r) ->
            match go visiting l, go visiting r with
            | Error e', _ -> Error e'
            | _, Error e' -> Error e'
            | Ok lv, Ok rv ->
                try
                    match op with
                    | BAdd -> Ok (Microsoft.FSharp.Core.Operators.Checked.(+) lv rv)
                    | BSub -> Ok (Microsoft.FSharp.Core.Operators.Checked.(-) lv rv)
                    | BMul -> Ok (Microsoft.FSharp.Core.Operators.Checked.(*) lv rv)
                    | BDiv ->
                        if rv = 0L then Error DivByZero
                        else Ok (lv / rv)
                    | BMod ->
                        if rv = 0L then Error DivByZero
                        else Ok (lv % rv)
                    | _ -> Error NotConstant
                with :? System.OverflowException -> Error Overflow

        | EPath { Segments = [name] } ->
            if Set.contains name visiting then Error (Cycle name)
            else
                match table.TryFindOne name with
                | None -> Error NotConstant
                | Some sym ->
                    match sym.Kind with
                    | DKConst c -> go (Set.add name visiting) c.Init
                    // `pub val NAME = EXPR` at module level — Lyric
                    // doesn't have a `const` parser yet, so module-
                    // level vals serve as compile-time integer
                    // constants when their initialiser folds.
                    | DKVal v -> go (Set.add name visiting) v.Init
                    | _ -> Error NotConstant

        | _ -> Error NotConstant

    go Set.empty root
