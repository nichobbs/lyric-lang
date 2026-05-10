/// Aspect weaver — A1/A2/A3/A4 bootstrap-grade implementation.
///
/// Transforms a SourceFile's item list before IL emission:
///   1. Collects every IAspect item (those with Around advice).
///   2. Matches each IFunc against the aspect's `matches:` glob(s),
///      respecting `@no_aspect` and `@no_aspect("Name")` opt-outs.
///   3. For each matched function, renames the original to
///      `<name>__aspect_target`, sorts the matching aspects by `wraps:`/
///      `inside:` clauses (lexical order within a file as the tiebreak),
///      and splices in a chain of wrapper IFuncs — innermost calling the
///      target, outermost keeping the original name.
///   4. IAspect items are dropped from the resulting item list (they
///      have no IL representation).
///
/// Bootstrap-grade limitations (deferred to v1.x):
///   - Only the `proceed(args)` form is rewritten; `args.field` access
///     inside the around body is not yet supported.
///   - The `call` ambient value (call.shortName, call.elapsed, …) is not
///     injected; references to `call` compile as unresolved identifiers
///     and surface as type-check errors.
///   - Cross-file multi-aspect ordering conflict (A0007) and cycle detection
///     (A0008) are not yet emitted; `wraps:`/`inside:` is recorded in the AST
///     and drives single-file ordering, but the diagnostic pass is deferred.
///   - Contract augmentation (§5) is implemented: requires:/ensures: clauses
///     on an aspect body are parsed and composed with the target's own
///     contracts in the wrapper (aspect contracts ++ target contracts).
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
                found && closed && m (j + 1) (ni + 1)
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

/// Build a wrapper FunctionDecl for `originalFn` that carries `aspect`'s
/// around body, with proceed(args) → callTargetName(p1, p2, …).
/// The wrapper keeps originalFn's params/return/contracts (composed with
/// the aspect's contracts).  `callTargetName` is what proceed() forwards to;
/// the caller is responsible for naming the wrapper itself.
let private buildWrapper
        (originalFn: FunctionDecl)
        (aspect: AspectDecl)
        (callTargetName: string)
        : FunctionDecl =
    let around = aspect.Around.Value
    let paramNames = originalFn.Params |> List.map (fun p -> p.Name)

    // Rewrite every occurrence of proceed(args) in the around body, including
    // inside loops, try blocks, and other nested statement bodies.
    // Delegate to rewriteProceeds (which is already fully recursive) by wrapping
    // the block as an EBlock expression, rewriting, and unwrapping.
    let rewiredBody =
        let b = around.Body
        let blockExpr : Expr = { Kind = EBlock b; Span = zeroSpan }
        let rewritten = rewriteProceeds callTargetName paramNames blockExpr
        match rewritten.Kind with
        | EBlock blk -> blk
        | _          -> b  // cannot happen

    // Wrapper FunctionDecl: same params/return as original; around body.
    // §5 composition: wrapper contract = aspect contracts ++ target contracts.
    { originalFn with
        Body        = Some (FBBlock rewiredBody)
        Contracts   = aspect.Contracts @ originalFn.Contracts
        Annotations = []       // strip @no_aspect etc. from wrapper
    }

// ---------------------------------------------------------------------------
// §6 ordering: topological sort of aspects by wraps:/inside:
// ---------------------------------------------------------------------------

/// Sort `aspects` so that "wraps A" appears before A, and "inside B" appears
/// after B.  Within the same order group, preserve lexical (declaration) order.
/// Returns aspects sorted outermost → innermost (outermost = first in list).
/// Bootstrap-grade: no A0007 conflict diagnostic or A0008 cycle detection yet.
let private sortAspects (aspects: AspectDecl list) : AspectDecl list =
    if aspects.Length <= 1 then aspects
    else
        // Build an adjacency set: outer -> set of inner names.
        // "A wraps B" means A is outer, B is inner (A before B).
        // "A inside B" means B is outer, A is inner (B before A = A after B).
        let edges = System.Collections.Generic.Dictionary<string, System.Collections.Generic.HashSet<string>>()
        for a in aspects do
            if not (edges.ContainsKey a.Name) then
                edges[a.Name] <- System.Collections.Generic.HashSet<string>()
        for a in aspects do
            for inner in a.Wraps do
                edges[a.Name].Add inner |> ignore
            for outer in a.Inside do
                if edges.ContainsKey outer then
                    edges[outer].Add a.Name |> ignore
        // Kahn's algorithm (ignore cycles in bootstrap; fall back to lexical order on cycles).
        let inDegree = System.Collections.Generic.Dictionary<string, int>()
        for a in aspects do inDegree[a.Name] <- 0
        for a in aspects do
            for inner in edges[a.Name] do
                if inDegree.ContainsKey inner then
                    inDegree[inner] <- inDegree[inner] + 1
        let queue = System.Collections.Generic.Queue<string>()
        // Start with aspects that have no predecessors, in lexical order.
        for a in aspects do
            if inDegree[a.Name] = 0 then queue.Enqueue a.Name
        let sorted = System.Collections.Generic.List<string>()
        while queue.Count > 0 do
            let n = queue.Dequeue()
            sorted.Add n
            for inner in edges[n] do
                if inDegree.ContainsKey inner then
                    let d = inDegree[inner] - 1
                    inDegree[inner] <- d
                    if d = 0 then queue.Enqueue inner
        // Any remaining (in a cycle) get appended in lexical order.
        for a in aspects do
            if not (sorted.Contains a.Name) then sorted.Add a.Name
        let byName = aspects |> List.map (fun a -> a.Name, a) |> Map.ofList
        sorted |> Seq.choose (fun n -> Map.tryFind n byName) |> List.ofSeq

// ---------------------------------------------------------------------------
// @no_aspect opt-out check
// ---------------------------------------------------------------------------

/// Returns true if `fn` opts out of aspect `aspectName` via @no_aspect.
/// @no_aspect with no args opts out of all aspects.
/// @no_aspect("Name") opts out of just the named aspect.
let private isOptedOut (fn: FunctionDecl) (aspectName: string) : bool =
    fn.Annotations
    |> List.exists (fun ann ->
        ann.Name.Segments = [ "no_aspect" ] &&
        (ann.Args.IsEmpty ||
         ann.Args |> List.exists (fun arg ->
             match arg with
             | ALiteral (AVString (s, _), _) -> s = aspectName
             | _ -> false)))

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Transform `items` by weaving every matching `IAspect`.
/// Returns items with:
///   - IAspect items removed (no IL generated for them)
///   - Matched IFunc items replaced with [renamed-target; intermediate-wrappers...; outermost-wrapper]
///     (outermost wrapper keeps the original function name, innermost calls __aspect_target)
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
                let matchedAspects =
                    aspects
                    |> List.filter (fun a ->
                        not (isOptedOut fn a.Name) &&
                        a.Matches
                        |> List.exists (fun m ->
                            match m with
                            | AMNameLike (glob, _) -> globMatch glob fn.Name))
                match matchedAspects with
                | [] ->
                    result.Add item
                | _ ->
                    // Sort outermost→innermost by wraps:/inside: clauses.
                    let ordered = sortAspects matchedAspects
                    let targetName = fn.Name + "__aspect_target"
                    // Rename original function.
                    let targetFn : FunctionDecl = { fn with Name = targetName; Visibility = None }
                    result.Add { item with Kind = IFunc targetFn }
                    // Build wrappers from innermost to outermost.
                    // reversed = [innermost, ..., outermost]
                    let reversed = List.rev ordered
                    let n = reversed.Length
                    let mutable callTarget = targetName
                    for i, aspect in reversed |> List.mapi (fun i a -> i, a) do
                        let isOutermost = (i = n - 1)
                        // Outermost wrapper keeps the original name (public API).
                        // Intermediate wrappers get __aspect_<AspectName> names.
                        let wrapperName =
                            if isOutermost then fn.Name
                            else fn.Name + "__aspect_" + aspect.Name
                        let wrapperFn = { buildWrapper fn aspect callTarget with Name = wrapperName }
                        result.Add { item with Kind = IFunc wrapperFn }
                        callTarget <- wrapperName
            | _ ->
                result.Add item
        result |> Seq.toList
