/// Aspect weaver — A1 bootstrap-grade implementation.
///
/// Transforms a SourceFile's item list before IL emission:
///   1. Collects every IAspect item (those with Around advice).
///   2. Matches each IFunc against the aspect's `matches:` glob(s).
///   3. For each matched function, renames the original to
///      `<name>__aspect_target` and splices in a wrapper IFunc that
///      carries the aspect's `around` body, with every call of the form
///      `proceed(args)` rewritten to `<targetName>(p1, p2, …)`.
///   4. IAspect items are dropped from the resulting item list (they
///      have no IL representation).
///
/// Bootstrap-grade limitations (deferred to v1.x):
///   - Only the `proceed(args)` form is rewritten; `args.field` access
///     inside the around body is not yet supported.
///   - The `call` ambient value (call.shortName, call.elapsed, …) is not
///     injected; references to `call` compile as unresolved identifiers
///     and surface as type-check errors.
///   - Multi-aspect composition and ordering (§6 of docs/26-aspects.md)
///     is deferred; multiple aspects compose naively in declaration order.
///   - Contract augmentation (§5) is deferred; aspect requires:/ensures:
///     clauses are not yet merged into the wrapper's contract list.
///   - `@no_aspect` opt-out annotations are not yet checked.
///
/// Glob syntax supported: * (any), ? (one char), [abc]/[a-z] (char set),
/// all other chars literal.  Glob is matched against the short function name.
module Lyric.Emitter.Weaver

open Lyric.Parser.Ast
open Lyric.Lexer

// ---------------------------------------------------------------------------
// Glob matching (POSIX-ish subset)
// ---------------------------------------------------------------------------

let private globMatch (glob: string) (name: string) : bool =
    let rec m gi ni =
        if gi = glob.Length && ni = name.Length then true
        elif gi = glob.Length then false
        else
            match glob.[gi] with
            | '*' ->
                let mutable matched = false
                let mutable k = ni
                while k <= name.Length && not matched do
                    if m (gi + 1) k then matched <- true
                    k <- k + 1
                matched
            | '?' ->
                ni < name.Length && m (gi + 1) (ni + 1)
            | '[' ->
                let mutable j = gi + 1
                let mutable found = false
                let mutable closed = false
                while j < glob.Length && not closed do
                    if glob.[j] = ']' then
                        closed <- true
                    elif j + 2 < glob.Length && glob.[j + 1] = '-' && glob.[j + 2] <> ']' then
                        if ni < name.Length && name.[ni] >= glob.[j] && name.[ni] <= glob.[j + 2] then
                            found <- true
                        j <- j + 3
                    else
                        if ni < name.Length && glob.[j] = name.[ni] then
                            found <- true
                        j <- j + 1
                found && closed && m j (ni + 1)
            | c ->
                ni < name.Length && c = name.[ni] && m (gi + 1) (ni + 1)
    m 0 0

// ---------------------------------------------------------------------------
// Build synthetic AST nodes with a dummy span
// ---------------------------------------------------------------------------

let private zeroPos  : Position = { Offset = 0; Line = 1; Column = 1 }
let private zeroSpan : Span     = { Start = zeroPos; End = zeroPos }

let private makePath (segments: string list) : Expr =
    { Kind = EPath { Segments = segments; Span = zeroSpan }; Span = zeroSpan }

// ---------------------------------------------------------------------------
// Rewrite `proceed(args)` → `targetName(p1, p2, …)` in an expression tree
// ---------------------------------------------------------------------------

let private rewriteProceeds (targetName: string) (paramNames: string list) (rootExpr: Expr) : Expr =
    let argExprs = paramNames |> List.map (fun n -> CAPositional (makePath [n]))
    let isProceedCall (expr: Expr) =
        match expr.Kind with
        | ECall ({ Kind = EPath { Segments = ["proceed"] } }, _) -> true
        | _ -> false
    let substitute () : Expr =
        { Kind = ECall (makePath [targetName], argExprs); Span = zeroSpan }

    let rec rwExpr (x: Expr) : Expr =
        if isProceedCall x then substitute ()
        else
        match x.Kind with
        | ECall (f, a)          -> { x with Kind = ECall (rwExpr f, a |> List.map rwCallArg) }
        | EParen inner          -> { x with Kind = EParen (rwExpr inner) }
        | ETuple xs             -> { x with Kind = ETuple (xs |> List.map rwExpr) }
        | EList xs              -> { x with Kind = EList (xs |> List.map rwExpr) }
        | EAwait inner          -> { x with Kind = EAwait (rwExpr inner) }
        | ESpawn inner          -> { x with Kind = ESpawn (rwExpr inner) }
        | ETry inner            -> { x with Kind = ETry (rwExpr inner) }
        | EOld inner            -> { x with Kind = EOld (rwExpr inner) }
        | EPropagate inner      -> { x with Kind = EPropagate (rwExpr inner) }
        | EPrefix (op, inner)   -> { x with Kind = EPrefix (op, rwExpr inner) }
        | EBinop (op, l, r)     -> { x with Kind = EBinop (op, rwExpr l, rwExpr r) }
        | EAssign (t, op, v)    -> { x with Kind = EAssign (rwExpr t, op, rwExpr v) }
        | EMember (recv, n)     -> { x with Kind = EMember (rwExpr recv, n) }
        | EIndex (recv, idxs)   -> { x with Kind = EIndex (rwExpr recv, idxs |> List.map rwExpr) }
        | ETypeApp (f, ts)      -> { x with Kind = ETypeApp (rwExpr f, ts) }
        | EIf (c, th, el, form) ->
            { x with Kind = EIf (rwExpr c, rwEOB th, el |> Option.map rwEOB, form) }
        | EMatch (scrut, arms)  ->
            { x with Kind = EMatch (rwExpr scrut, arms |> List.map rwArm) }
        | ELambda (ps, body)    -> { x with Kind = ELambda (ps, rwBlock body) }
        | EBlock blk            -> { x with Kind = EBlock (rwBlock blk) }
        | EUnsafe body               -> { x with Kind = EUnsafe (rwBlock body) }
        | EForall _ | EExists _ | ERange _ | EInterpolated _ | ELiteral _
        | EPath _ | ESelf | EResult | EError -> x

    and rwCallArg arg =
        match arg with
        | CAPositional v     -> CAPositional (rwExpr v)
        | CANamed (n, v, sp) -> CANamed (n, rwExpr v, sp)

    and rwEOB (eob: ExprOrBlock) : ExprOrBlock =
        match eob with
        | EOBBlock blk  -> EOBBlock (rwBlock blk)
        | EOBExpr  expr -> EOBExpr  (rwExpr expr)

    and rwArm (arm: MatchArm) : MatchArm =
        { arm with Body = rwEOB arm.Body; Guard = arm.Guard |> Option.map rwExpr }

    and rwBlock (blk: Block) : Block =
        { blk with Statements = blk.Statements |> List.map rwStmt }

    and rwStmt (s: Statement) : Statement =
        let kind' =
            match s.Kind with
            | SExpr e                            -> SExpr (rwExpr e)
            | SReturn (Some e)                   -> SReturn (Some (rwExpr e))
            | SReturn None                       -> SReturn None
            | SLocal (LBVal (p, t, init))        -> SLocal (LBVal (p, t, rwExpr init))
            | SLocal (LBVar (n, t, Some init))   -> SLocal (LBVar (n, t, Some (rwExpr init)))
            | SLocal (LBVar (n, t, None))        -> SLocal (LBVar (n, t, None))
            | SLocal (LBLet (n, t, init))        -> SLocal (LBLet (n, t, rwExpr init))
            | SAssign (t, op, v)                 -> SAssign (rwExpr t, op, rwExpr v)
            | SThrow e                           -> SThrow (rwExpr e)
            | SFor (lbl, pat, iter, body)        -> SFor (lbl, pat, rwExpr iter, rwBlock body)
            | SWhile (lbl, cond, body)           -> SWhile (lbl, rwExpr cond, rwBlock body)
            | SLoop (lbl, body)                  -> SLoop (lbl, rwBlock body)
            | SScope (b, body)                   -> SScope (b, rwBlock body)
            | STry (body, catches)               ->
                STry (rwBlock body,
                      catches |> List.map (fun c -> { c with Body = rwBlock c.Body }))
            | SDefer body                        -> SDefer (rwBlock body)
            | SInvariant _ | SBreak _ | SContinue _ | SRule _ | SItem _ -> s.Kind
        { s with Kind = kind' }

    rwExpr rootExpr

// ---------------------------------------------------------------------------
// Build the wrapper IFunc for one matched function + one aspect
// ---------------------------------------------------------------------------

let private buildWrapper
        (originalFn: FunctionDecl)
        (aspect: AspectDecl)
        (targetName: string)
        : FunctionDecl =
    let around = aspect.Around.Value
    let paramNames = originalFn.Params |> List.map (fun p -> p.Name)

    // Rewrite every statement in the around body so proceed(args) → targetName(p1, p2, …).
    let rwStmt (s: Statement) : Statement =
        let rwE e = rewriteProceeds targetName paramNames e
        let kind' =
            match s.Kind with
            | SExpr e                            -> SExpr (rwE e)
            | SReturn (Some e)                   -> SReturn (Some (rwE e))
            | SReturn None                       -> s.Kind
            | SLocal (LBVal (p, t, init))        -> SLocal (LBVal (p, t, rwE init))
            | SLocal (LBVar (n, t, Some init))   -> SLocal (LBVar (n, t, Some (rwE init)))
            | SLocal (LBVar (n, t, None))        -> s.Kind
            | SLocal (LBLet (n, t, init))        -> SLocal (LBLet (n, t, rwE init))
            | SAssign (t, op, v)                 -> SAssign (rwE t, op, rwE v)
            | SThrow e                           -> SThrow (rwE e)
            | SFor (lbl, pat, iter, body)        -> SFor (lbl, pat, rwE iter, body)
            | SWhile (lbl, cond, body)           -> SWhile (lbl, rwE cond, body)
            | _                                  -> s.Kind
        { s with Kind = kind' }
    let rewiredBody =
        let b = around.Body
        { b with Statements = b.Statements |> List.map rwStmt }

    // Wrapper FunctionDecl: same name/params/return as original; around body.
    { originalFn with
        Body        = Some (FBBlock rewiredBody)
        Contracts   = []       // contract composition deferred to v1.x
        Annotations = []       // strip @no_aspect etc. from wrapper
    }

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Transform `items` by weaving every matching `IAspect`.
/// Returns items with:
///   - IAspect items removed (no IL generated for them)
///   - Matched IFunc items replaced with [renamed-target; wrapper]
///   - Unmatched IFunc items unchanged
let weaveItems (items: Item list) : Item list =
    let aspects =
        items
        |> List.choose (fun it ->
            match it.Kind with
            | IAspect a when a.Around.IsSome -> Some a
            | _ -> None)

    if aspects.IsEmpty then
        items |> List.filter (fun it ->
            match it.Kind with
            | IAspect _ -> false
            | _ -> true)
    else
        let result = System.Collections.Generic.List<Item>()
        for item in items do
            match item.Kind with
            | IAspect _ -> ()
            | IFunc fn ->
                let matchedAspect =
                    aspects
                    |> List.tryFind (fun a ->
                        a.Matches
                        |> List.exists (fun m ->
                            match m with
                            | AMNameLike (glob, _) -> globMatch glob fn.Name))
                match matchedAspect with
                | None ->
                    result.Add item
                | Some aspect ->
                    let targetName = fn.Name + "__aspect_target"
                    let targetFn : FunctionDecl =
                        { fn with Name = targetName; Visibility = None }
                    let targetItem : Item = { item with Kind = IFunc targetFn }
                    let wrapperFn = buildWrapper fn aspect targetName
                    let wrapperItem : Item = { item with Kind = IFunc wrapperFn }
                    result.Add targetItem
                    result.Add wrapperItem
            | _ ->
                result.Add item
        result |> Seq.toList
