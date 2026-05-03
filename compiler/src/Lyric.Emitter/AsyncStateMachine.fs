/// Hand-rolled async state machine synthesis (C2 / D-progress-024,
/// Phase A).
///
/// For each `async func` whose body contains no `await` expressions,
/// the emitter synthesises a sibling class implementing
/// `IAsyncStateMachine` and rewrites the user's function into a
/// kickoff stub that creates the SM, calls
/// `AsyncTaskMethodBuilder<T>.Start`, and returns the builder's task.
///
/// Phase A scope (this file):
///   * Top-level non-generic non-instance async functions.
///   * Bodies that contain no internal `await` (i.e. the user code
///     never suspends).  This covers the four cases in
///     `AsyncTests.fs` plus any other async function whose value is
///     produced synchronously.  Even though these bodies don't
///     suspend, routing them through the real builder/Start/SetResult
///     plumbing exercises the whole structural shape we'll need for
///     Phase B and replaces the M1.4 `Task.FromResult` shim with
///     spec-correct codegen.
///
/// Phase B (follow-up): `await` inside an async body — real
/// `AwaitUnsafeOnCompleted` suspend/resume protocol with state
/// dispatch, locals promoted to fields.  Async funcs whose bodies
/// contain `await` keep the M1.4 `Task.FromResult` path until Phase
/// B lands.
module Lyric.Emitter.AsyncStateMachine

open System
open System.Collections.Generic
open System.Reflection
open System.Reflection.Emit
open System.Runtime.CompilerServices
open Lyric.Lexer
open Lyric.Parser.Ast

/// Walk a function body looking for any `EAwait` expression.  An
/// `EAwait` anywhere — in a sub-expression, match arm, defer, etc. —
/// disqualifies the function from Phase A SM lowering.
let rec private exprHasAwait (e: Expr) : bool =
    match e.Kind with
    | EAwait _ -> true
    | ELiteral _ | EPath _ | ESelf | EResult | EError -> false
    | EInterpolated segs ->
        segs |> List.exists (function
            | ISText _ -> false
            | ISExpr e -> exprHasAwait e)
    | EParen e | ESpawn e | EOld e | EPropagate e | ETry e -> exprHasAwait e
    | ETuple es | EList es -> es |> List.exists exprHasAwait
    | EIf (c, t, eOpt, _) ->
        exprHasAwait c
        || branchHasAwait t
        || (match eOpt with Some b -> branchHasAwait b | None -> false)
    | EMatch (s, arms) ->
        exprHasAwait s
        || arms |> List.exists (fun a ->
            (match a.Guard with Some g -> exprHasAwait g | None -> false)
            || branchHasAwait a.Body)
    | EForall (_, where, body)
    | EExists (_, where, body) ->
        (match where with Some w -> exprHasAwait w | None -> false)
        || exprHasAwait body
    | ELambda (_, blk) -> blockHasAwait blk
    | ECall (f, args) ->
        exprHasAwait f
        || args |> List.exists (function
            | CANamed (_, v, _) -> exprHasAwait v
            | CAPositional v    -> exprHasAwait v)
    | ETypeApp (f, _) -> exprHasAwait f
    | EIndex (r, idxs) -> exprHasAwait r || idxs |> List.exists exprHasAwait
    | EMember (r, _) -> exprHasAwait r
    | EPrefix (_, op) -> exprHasAwait op
    | EBinop (_, l, r) -> exprHasAwait l || exprHasAwait r
    | ERange rb ->
        match rb with
        | RBClosed (a, b) | RBHalfOpen (a, b) -> exprHasAwait a || exprHasAwait b
        | RBLowerOpen a | RBUpperOpen a       -> exprHasAwait a
    | EAssign (t, _, v) -> exprHasAwait t || exprHasAwait v
    | EBlock b -> blockHasAwait b

and private branchHasAwait (eob: ExprOrBlock) : bool =
    match eob with
    | EOBExpr e  -> exprHasAwait e
    | EOBBlock b -> blockHasAwait b

and private blockHasAwait (b: Block) : bool =
    b.Statements |> List.exists stmtHasAwait

and private stmtHasAwait (s: Statement) : bool =
    match s.Kind with
    | SExpr e | SThrow e -> exprHasAwait e
    | SReturn (Some e) -> exprHasAwait e
    | SReturn None | SBreak _ | SContinue _ -> false
    | SAssign (t, _, v) -> exprHasAwait t || exprHasAwait v
    | SLocal (LBVal (_, _, e)) | SLocal (LBLet (_, _, e)) -> exprHasAwait e
    | SLocal (LBVar (_, _, Some e)) -> exprHasAwait e
    | SLocal (LBVar (_, _, None)) -> false
    | STry (body, catches) ->
        blockHasAwait body
        || catches |> List.exists (fun c -> blockHasAwait c.Body)
    | SDefer b | SScope (_, b) | SLoop (_, b) -> blockHasAwait b
    | SFor (_, _, iter, body) -> exprHasAwait iter || blockHasAwait body
    | SWhile (_, cond, body) -> exprHasAwait cond || blockHasAwait body
    | SRule (lhs, rhs) -> exprHasAwait lhs || exprHasAwait rhs
    | SItem _ -> false

/// Public re-export so Codegen.fs's SFor handler can detect a body
/// containing an await (Phase B+++ for-await routing).
let hasAwaitInBlock (b: Block) : bool = blockHasAwait b

/// Top-level entry: does this function's body contain any `await`?
let bodyContainsAwait (fn: FunctionDecl) : bool =
    match fn.Body with
    | None -> false
    | Some (FBExpr e) -> exprHasAwait e
    | Some (FBBlock b) -> blockHasAwait b

/// Phase B safe-position checker: every `EAwait` in the body must
/// appear at a "top-level" statement position so the IL stack is
/// empty at the suspend point.  Awaits inside sub-expressions
/// (e.g. `1 + await foo()`, `f(await g())`) would require stack-
/// spilling that Phase B doesn't yet do.
///
/// Safe positions (Phase B + B.1 control-flow extension):
///   * `EAwait inner` as the entire expression body of an FBExpr.
///   * `EAwait inner` as the immediate Init of a top-level
///     `val`/`let`/`var` declaration.
///   * `EAwait inner` as the immediate Value of a top-level
///     `SAssign` / `SReturn (Some _)`.
///   * `EAwait inner` as the entire expression of a top-level
///     `SExpr` / `SThrow`.
///   * `EIf` whose condition has no awaits and whose branches are
///     each in safe expression position (recursive).  The IL
///     stack is empty at the branch entry / suspend points
///     because branches are emitted as independent IL flows that
///     converge at the end-of-`if` label.
///   * `EMatch` whose scrutinee has no awaits and whose arm
///     bodies are each in safe expression position.  The
///     scrutinee value is stored to a temp before pattern
///     matching, so the stack is empty entering each arm.
///
/// `inner` (the awaited task) must itself contain no nested
/// awaits — the stack must be empty at the suspend's `Leave`.
///
/// Statements that don't introduce sub-expression contexts —
/// `SBreak`, `SContinue`, `SReturn None`, `SItem` — are always
/// safe.  Statements that introduce nested control flow — `STry`,
/// `SDefer`, `SFor`, `SWhile`, `SLoop`, `SScope` — are unsafe iff
/// they (transitively) contain an `EAwait`.  Phase B+ will lift
/// those restrictions piece by piece.
let rec private isSafeExprPosition (e: Expr) : bool =
    if not (exprHasAwait e) then true
    else
    match e.Kind with
    // `await inner` — safe if inner is await-free.
    | EAwait inner -> not (exprHasAwait inner)
    // `if` and `match` distribute the safe check over the cond/
    // scrutinee + each branch.  Each branch is independent in IL
    // terms (separate basic block), so an await at the branch's
    // top level is structurally fine.
    | EIf (cond, thenB, elseOpt, _) ->
        // The cond's value is consumed by `brtrue` / `brfalse` —
        // an `await` cond stashes its awaiter in a local before
        // suspend, so the IL stack is empty at the suspend point;
        // after resume, GetResult pushes the bool and the branch
        // sees it normally.  Branches recurse via
        // `isSafeExprOrBlock`.
        isSafeExprPosition cond
        && isSafeExprOrBlock thenB
        && (match elseOpt with
            | Some b -> isSafeExprOrBlock b
            | None   -> true)
    | EMatch (scrut, arms) ->
        // Same story for the match scrutinee — it's `Stloc`'d to
        // a temp before pattern matching, so the IL stack is
        // empty at suspend.  Awaits inside scrutinees like
        // `match await foo() { ... }` (the canonical Std.Http /
        // BankingSmoke pattern) become safe via this case.
        isSafeExprPosition scrut
        && arms |> List.forall (fun a ->
            (match a.Guard with Some g -> isSafeExprPosition g | None -> true)
            && isSafeExprOrBlock a.Body)
    // `EParen` and `EBlock` wrap expression flow without
    // introducing stack pressure on the await itself, so descend.
    | EParen inner -> isSafeExprPosition inner
    // EBlock inside an expression context (e.g. `return try {...} catch
    // ...`).  Use the stricter `isSafeStmtNested` so STry+await falls
    // back to the M1.4 blocking shim — the duplicated-post-await
    // emit only handles statement-form STry, not try-as-expression.
    | EBlock blk   -> blk.Statements |> List.forall isSafeStmtNested
    | _ -> false

and private isSafeExprOrBlock (eob: ExprOrBlock) : bool =
    match eob with
    | EOBExpr e  -> isSafeExprPosition e
    | EOBBlock b -> b.Statements |> List.forall isSafeStmtNested

and private isSafeStmt (s: Statement) : bool =
    match s.Kind with
    | SExpr e | SThrow e -> isSafeExprPosition e
    | SLocal (LBVal (_, _, init))
    | SLocal (LBLet (_, _, init))
    | SLocal (LBVar (_, _, Some init)) -> isSafeExprPosition init
    | SLocal (LBVar (_, _, None)) -> true
    | SAssign (target, _, value) ->
        not (exprHasAwait target) && isSafeExprPosition value
    | SReturn None | SBreak _ | SContinue _ | SItem _ | SRule _ -> true
    | SReturn (Some e) -> isSafeExprPosition e
    // Phase B+ control-flow extensions: `while` and `loop` whose
    // body statements are each in safe position (and whose
    // condition is await-free) work with the same suspend/resume
    // IL pattern as straight-line code — each iteration is
    // structurally identical, the resume label can sit anywhere
    // inside the body, and the dispatch table jumps to it
    // directly.  `for` loops aren't yet covered because they
    // bind an iteration variable per iteration (would need
    // nested-local promotion).
    // Phase B++ (D-progress-042): `while` and `loop` bodies may
    // contain `SLocal` declarations.  Their locals are promoted
    // to SM fields by `collectPromotableLocals` (which walks one
    // level into loop bodies); the IL preserves their values
    // across the cross-resume gap via the existing field-shadow
    // protocol.  `for` loops still require iteration-variable
    // promotion plumbing not yet implemented.
    | SWhile (_, cond, body) ->
        (not (exprHasAwait cond))
        && safeStmtList body.Statements
    | SLoop (_, body) ->
        safeStmtList body.Statements
    // Phase B+++ (D-progress-056): STry with one trailing await in
    // body and no awaits in catches lowers to the duplicated-post-
    // await pattern.  Pre-stmts execute only on the first-time path;
    // resume re-enters a duplicate user try whose body is just the
    // GetResult.  Catches are emitted twice (once per .try copy).
    | STry (body, catches) ->
        if not (stmtHasAwait s) then true
        elif catches |> List.exists (fun c -> blockHasAwait c.Body) then false
        else isPhaseBPlusPlusPlusTryAwaitBody body
    // Phase B+++ (D-progress-058): `for x in iter { body }` with an
    // award in body.  Iterator state (slice, index) and the loop
    // variable are field-backed so they survive cross-resume.
    // Single-name-binding shape only (matches today's codegen
    // restriction).  Iter expression is await-free.
    | SFor (_, { Kind = PBinding (_, None) }, iter, body) ->
        if not (stmtHasAwait s) then true
        else
            (not (exprHasAwait iter))
            && safeStmtList body.Statements
    | SFor _ ->
        not (stmtHasAwait s)
    | SDefer _ | SScope _ ->
        not (stmtHasAwait s)

/// Like `isSafeStmt` but stricter: rejects STry with await in body.
/// Used inside expression contexts (try-as-expression / EBlock-in-
/// expression) where the duplicated-post-await emit isn't wired
/// through the EBlock codegen path.
and private isSafeStmtNested (s: Statement) : bool =
    match s.Kind with
    | STry _ -> not (stmtHasAwait s)
    | _ -> isSafeStmt s

/// Walks a stmt list enforcing the Phase B / B+++ "scope-positional"
/// rules: every stmt is `isSafeStmt`, AND if the list contains a
/// `defer { ... }`, the stmts that follow it satisfy the
/// duplicated-emit defer-await constraint — either entirely
/// award-free, or exactly one trailing top-level await preceded by
/// award-free stmts.
///
/// Recursive into loop/while bodies because a defer inside a loop's
/// body still needs to obey the rule within its own scope.
and private safeStmtList (stmts: Statement list) : bool =
    if not (stmts |> List.forall isSafeStmt) then false
    else
        let arr = List.toArray stmts
        let n = arr.Length
        let mutable firstDefer = -1
        let mutable i = 0
        while firstDefer = -1 && i < n do
            (match arr.[i].Kind with
             | SDefer _ -> firstDefer <- i
             | _ -> ())
            i <- i + 1
        if firstDefer = -1 then
            // No defer at this level — recurse into nested loop/while
            // body scopes that haven't been checked by `isSafeStmt`.
            stmts
            |> List.forall (fun s ->
                match s.Kind with
                | SWhile (_, _, body) | SLoop (_, body) ->
                    safeStmtList body.Statements
                | _ -> true)
        else
            // Stmts after the first defer.
            let afterCount = n - firstDefer - 1
            if afterCount = 0 then true
            else
                let mutable awaits = 0
                for j in firstDefer + 1 .. n - 1 do
                    if stmtHasAwait arr.[j] then awaits <- awaits + 1
                if awaits = 0 then true
                elif awaits = 1 then
                    // Must be at the last position AND a top-level await.
                    let last = arr.[n - 1]
                    stmtHasAwait last && stmtIsTopLevelAwait last
                else false

/// True when this Try body fits the Phase B+++ "single-trailing-
/// await" shape: pre-stmts are await-free and at safe positions,
/// last stmt is a top-level await (val/let/var binding, SAssign,
/// SReturn, or bare SExpr).
and private isPhaseBPlusPlusPlusTryAwaitBody (body: Block) : bool =
    if not (blockHasAwait body) then false
    else
        let stmts = body.Statements
        match List.tryLast stmts with
        | None -> false
        | Some last when not (stmtIsTopLevelAwait last) -> false
        | Some _ ->
            let preLen = List.length stmts - 1
            let pre = List.truncate preLen stmts
            (not (pre |> List.exists stmtHasAwait))
            && (pre |> List.forall isSafeStmt)

and private stmtIsTopLevelAwait (s: Statement) : bool =
    // Phase B+++ scope: bare await statement or `val/let/var name =
    // await ...` binding.  SAssign / SReturn whose value is an
    // await fall back to the M1.4 blocking shim until follow-up
    // work plumbs the post-result store/return into the try-await
    // duplicated emit.
    let rec exprIsAwait (e: Expr) =
        match e.Kind with
        | EAwait _ -> true
        | EParen inner -> exprIsAwait inner
        | _ -> false
    match s.Kind with
    | SExpr e -> exprIsAwait e
    | SLocal (LBVal ({ Kind = PBinding (_, None) }, _, init))
    | SLocal (LBLet (_, _, init))
    | SLocal (LBVar (_, _, Some init)) -> exprIsAwait init
    | _ -> false

/// Public re-export so Codegen.fs's STry handler can detect the
/// Phase B+++ shape at emit time.  Mirrors `isPhaseBPlusPlusPlusTryAwaitBody`.
let isTryAwaitBodyShape (body: Block) (catches: CatchClause list) : bool =
    if not (blockHasAwait body) then false
    elif catches |> List.exists (fun c -> blockHasAwait c.Body) then false
    else isPhaseBPlusPlusPlusTryAwaitBody body

/// Detect the Phase B+++ defer-await trailing pattern in a function
/// body.  Returns `Some (preDefer, deferBody, between, awaitStmt)`
/// when the function body matches:
///
///     [pre-defer await-free stmts...]
///     defer { await-free body }
///     [between-defer-and-await await-free stmts...]
///     trailing top-level await statement
///
/// Returns `None` otherwise.  The codegen path bypasses the regular
/// `try/finally` defer emit and routes through the duplicated-post-
/// await pattern, with cleanup running at scope exit (success or
/// exception) but NOT at the suspend point.
let tryMatchDeferAwaitTrailingShape (stmts: Statement list)
    : (Statement list * Block * Statement list * Statement) option =
    let deferIdx =
        stmts
        |> List.tryFindIndex (fun s ->
            match s.Kind with SDefer _ -> true | _ -> false)
    match deferIdx with
    | None -> None
    | Some di ->
        let deferStmt = stmts.[di]
        let deferBody =
            match deferStmt.Kind with
            | SDefer b -> b
            | _ -> failwith "unreachable"
        if blockHasAwait deferBody then None
        else
            let preDefer = List.take di stmts
            let after = List.skip (di + 1) stmts
            if preDefer |> List.exists stmtHasAwait then None
            elif List.isEmpty after then None
            else
                let last = List.last after
                if not (stmtIsTopLevelAwait last) then None
                else
                    let between = List.take (List.length after - 1) after
                    if between |> List.exists stmtHasAwait then None
                    else Some (preDefer, deferBody, between, last)

/// Public re-export of `stmtIsTopLevelAwait` for Codegen.fs.
let isStmtTopLevelAwait (s: Statement) : bool = stmtIsTopLevelAwait s

let allAwaitsSafe (fn: FunctionDecl) : bool =
    match fn.Body with
    | None -> true
    | Some (FBExpr e) -> isSafeExprPosition e
    | Some (FBBlock blk) -> safeStmtList blk.Statements

// ---------------------------------------------------------------------------
// Stack-spilling AST rewrite (D-progress-074).
//
// Async functions whose bodies contain `EAwait` nested in a sub-
// expression position — `f(await g())`, `1 + await foo()`,
// `(await x).field`, etc. — fail `allAwaitsSafe` and route through
// the M1.4 blocking shim.  The rewrite below normalises those bodies
// by hoisting each non-safe-position await into a preceding
// `val __spill_<n> = await innerExpr` binding so the existing
// Phase B safe-position machinery applies unchanged.
//
// The rewrite is intentionally conservative — bootstrap-grade scope:
//
//   * Inner-task type inference uses the function-signature table the
//     emitter already builds.  Only `EAwait (ECall (EPath name, args))`
//     and `EAwait (EMember _)` shapes are covered today; awaits over
//     more elaborate expressions (lambda calls, dynamic dispatch) bail
//     and the function falls back to M1.4.
//
//   * Evaluation-order preservation is *trusted*: the rewrite emits
//     spill bindings in source order, which matches Lyric's left-to-
//     right evaluation rule for the common patterns
//     (`f(await g())`, `f(await a(), await b())`).  In edge cases
//     where a side-effecting sibling sits to the left of the spilled
//     await — e.g. `f(printAndReturn(), await g())` — the rewrite
//     would reorder.  The Roslyn-style "spill everything to the left
//     of an await" pass that fixes this is follow-up work.
//
//   * Awaits inside lambda bodies aren't touched (they're a separate
//     async function).
//
// If any spill local fails type inference, the rewrite returns
// `None` so the caller falls back to M1.4 instead of producing a
// half-rewritten function.
// ---------------------------------------------------------------------------

/// Resolved Lyric type of an `await innerExpr`.  The bootstrap
/// inferer handles the shapes `await someFunc(args)` and
/// `await receiver.method(args)` by looking up the signature in
/// the supplied lookup table; awaits over arbitrary expressions
/// return `None` and abandon the rewrite.
let private tryInferAwaitInnerType
        (sigOf: string -> Lyric.TypeChecker.ResolvedSignature option)
        (inner: Expr) : Lyric.TypeChecker.Type option =
    let unwrapTaskLike (ty: Lyric.TypeChecker.Type) : Lyric.TypeChecker.Type option =
        // The bootstrap type checker doesn't model `Task[T]` distinctly
        // from its element type — `inferExpr` for `EAwait inner` simply
        // returns the inner's type.  So whatever the function's
        // declared return type is, we use it directly.  When the spec
        // tightens to a real `Task` wrapper, this is where the unwrap
        // happens.
        Some ty
    let rec go (e: Expr) =
        match e.Kind with
        | EParen inner -> go inner
        | ECall ({ Kind = EPath p }, _) when not (List.isEmpty p.Segments) ->
            let last = List.last p.Segments
            match sigOf last with
            | Some sg -> unwrapTaskLike sg.Return
            | None -> None
        | ECall ({ Kind = EMember (_, name) }, _) ->
            match sigOf name with
            | Some sg -> unwrapTaskLike sg.Return
            | None -> None
        | _ -> None
    go inner

/// Rewriter state: monotonically-increasing spill counter, a buffer
/// for pending `val __spill_<n> = await ...` bindings local to the
/// current statement, and a side-table of inferred Lyric types for
/// each spilled local.
type private Spiller =
    { mutable Next:    int
      Pending:         ResizeArray<Statement>
      Types:           ResizeArray<string * Lyric.TypeChecker.Type>
      mutable Bailed:  bool }

let private freshSpiller () =
    { Next   = 0
      Pending = ResizeArray<Statement>()
      Types   = ResizeArray<string * Lyric.TypeChecker.Type>()
      Bailed  = false }

/// Synthesise an `EPath` for a spill-name binding lookup.
let private mkPath (name: string) (span: Span) : Expr =
    let mp : ModulePath = { Segments = [name]; Span = span }
    { Kind = EPath mp; Span = span }

/// Synthesise `val __spill_<n> = await innerExpr`.
let private mkSpillBinding (name: string) (awaitExpr: Expr) (span: Span) : Statement =
    let pat : Pattern = { Kind = PBinding (name, None); Span = span }
    let stmt : Statement =
        { Kind = SLocal (LBVal (pat, None, awaitExpr))
          Span = span }
    stmt

/// Conservative "no observable side effects" predicate.  Used by the
/// spill-prior-siblings rule (D-progress-076 follow-up) to decide
/// which left-of-an-await siblings to leave in place vs. hoist into
/// a `val __tmp_<n> = expr` binding so the original left-to-right
/// evaluation order survives the await rewrite.
let rec private isSideEffectFreeExpr (e: Expr) : bool =
    match e.Kind with
    | ELiteral _ | EPath _ | ESelf | EResult | EError -> true
    | EParen inner -> isSideEffectFreeExpr inner
    // Treat the rest as potentially side-effecting: function calls,
    // member loads (could throw on null receiver), index ops, prefix
    // ops, binops, etc.  Over-spilling here is harmless — at worst we
    // synthesise a redundant local — but under-spilling reorders.
    | _ -> false

/// Spill any `EAwait` encountered while walking `e`.  Returns the
/// rewritten expression with spilled awaits replaced by `EPath
/// __spill_<n>`.  Side-effects: appends the synthesised
/// `val __spill_<n> = …` bindings to `sp.Pending` in evaluation
/// order, and records each spilled local's inferred Lyric type in
/// `sp.Types`.  Sets `sp.Bailed` if a spill site's inner type can't
/// be inferred.
let rec private spillAwaits
        (sigOf: string -> Lyric.TypeChecker.ResolvedSignature option)
        (sp: Spiller) (e: Expr) : Expr =
    if sp.Bailed then e
    else
    match e.Kind with
    | EAwait inner ->
        // Recursively spill the inner first so nested awaits emit
        // their bindings before the outer one.
        let innerRew = spillAwaits sigOf sp inner
        if sp.Bailed then e
        else
            match tryInferAwaitInnerType sigOf innerRew with
            | None ->
                sp.Bailed <- true
                e
            | Some lyTy ->
                let n = sp.Next
                sp.Next <- n + 1
                let spillName = sprintf "__spill_%d" n
                sp.Types.Add(spillName, lyTy)
                let awaitExpr : Expr =
                    { Kind = EAwait innerRew; Span = e.Span }
                sp.Pending.Add(mkSpillBinding spillName awaitExpr e.Span)
                mkPath spillName e.Span
    | ELiteral _ | EPath _ | ESelf | EResult | EError -> e
    | EInterpolated segs ->
        let segs' =
            segs
            |> List.map (function
                | ISText _ as s -> s
                | ISExpr e' -> ISExpr (spillAwaits sigOf sp e'))
        { e with Kind = EInterpolated segs' }
    | EParen inner ->
        { e with Kind = EParen (spillAwaits sigOf sp inner) }
    | ESpawn inner ->
        // `spawn { … }` has its own closure; don't descend.
        e
    | EOld inner ->
        { e with Kind = EOld (spillAwaits sigOf sp inner) }
    | EPropagate inner ->
        { e with Kind = EPropagate (spillAwaits sigOf sp inner) }
    | ETry inner ->
        { e with Kind = ETry (spillAwaits sigOf sp inner) }
    | ETuple es ->
        { e with Kind = ETuple (spillSiblings sigOf sp es) }
    | EList es ->
        { e with Kind = EList (spillSiblings sigOf sp es) }
    | EIf _ | EMatch _ | EBlock _ ->
        // These are already safe positions for awaits (Phase B+).
        // The existing safe-position machinery descends into branches /
        // arms.  Don't rewrite — over-spilling here would defeat the
        // current Phase B+ tests' control-flow expectations.
        e
    | EForall _ | EExists _ | ELambda _ ->
        // Lambdas / quantifiers are their own scopes; awaits inside
        // belong to a different function body.
        e
    | ECall (fnE, args) ->
        // Pull out each arg's expression so the spill-prior rule can
        // see them as a single sibling list, then thread them back in
        // order with their original named/positional shape preserved.
        let argExprs =
            args
            |> List.map (function
                | CAPositional v -> v
                | CANamed (_, v, _) -> v)
            |> List.toArray
        let argsRew =
            // Treat the callee as a sibling positioned before all args
            // so a side-effecting callee gets spilled when an arg
            // contains an await.
            let combined = (fnE :: List.ofArray argExprs) |> spillSiblings sigOf sp
            match combined with
            | [] -> [||], fnE
            | fnRew :: argTail -> List.toArray argTail, fnRew
        let argTail, fnRew = argsRew
        let argsOut =
            args
            |> List.mapi (fun i a ->
                let rew = argTail.[i]
                match a with
                | CAPositional _ -> CAPositional rew
                | CANamed (n, _, sp') -> CANamed (n, rew, sp'))
        { e with Kind = ECall (fnRew, argsOut) }
    | ETypeApp (fnE, ts) ->
        { e with Kind = ETypeApp (spillAwaits sigOf sp fnE, ts) }
    | EIndex (recv, idxs) ->
        // `xs[i, j]` — receiver evaluates first, then each index left-
        // to-right.  Treat `recv :: idxs` as a single sibling list.
        let combined = (recv :: idxs) |> spillSiblings sigOf sp
        match combined with
        | [] -> e
        | recvRew :: idxsRew ->
            { e with Kind = EIndex (recvRew, idxsRew) }
    | EMember (recv, name) ->
        { e with Kind = EMember (spillAwaits sigOf sp recv, name) }
    | EPrefix (op, inner) ->
        { e with Kind = EPrefix (op, spillAwaits sigOf sp inner) }
    | EBinop (op, l, r) ->
        match spillSiblings sigOf sp [l; r] with
        | [lRew; rRew] -> { e with Kind = EBinop (op, lRew, rRew) }
        | _ -> e
    | ERange rb ->
        let rb' =
            match rb with
            | RBClosed (a, b) -> RBClosed (spillAwaits sigOf sp a, spillAwaits sigOf sp b)
            | RBHalfOpen (a, b) -> RBHalfOpen (spillAwaits sigOf sp a, spillAwaits sigOf sp b)
            | RBLowerOpen a -> RBLowerOpen (spillAwaits sigOf sp a)
            | RBUpperOpen a -> RBUpperOpen (spillAwaits sigOf sp a)
        { e with Kind = ERange rb' }
    | EAssign (t, op, v) ->
        // Targets are l-values; avoid descending so we don't
        // accidentally spill a write target.  Right-hand side is
        // walked normally.
        { e with Kind = EAssign (t, op, spillAwaits sigOf sp v) }

/// Apply the spill-prior-siblings rule (D-progress-076 follow-up):
/// when a list of sibling sub-expressions contains an `EAwait`,
/// every preceding side-effecting sibling is hoisted to a
/// `val __tmp_<n> = expr` binding before the await is hoisted, so
/// the original left-to-right evaluation order survives the
/// rewrite.  Pure siblings (literals, paths, parens-of-pure)
/// stay in place — over-spilling here is harmless but unnecessary.
///
/// Sets `sp.Bailed` when a side-effecting sibling needs spilling
/// but its CLR type can't be inferred.
and private spillSiblings
        (sigOf: string -> Lyric.TypeChecker.ResolvedSignature option)
        (sp: Spiller) (es: Expr list) : Expr list =
    if sp.Bailed then es
    else
    let arr = List.toArray es
    let n = arr.Length
    let mutable lastAwait = -1
    for i in 0 .. n - 1 do
        if exprHasAwait arr.[i] then lastAwait <- i
    if lastAwait < 0 then
        // No awaits anywhere in this sibling list — descend normally.
        es |> List.map (spillAwaits sigOf sp)
    else
        let result = ResizeArray<Expr>()
        for i in 0 .. n - 1 do
            if sp.Bailed then result.Add arr.[i]
            elif i >= lastAwait || exprHasAwait arr.[i] || isSideEffectFreeExpr arr.[i] then
                // At-or-after the last await: regular spill (the
                // EAwait branch handles its own hoisting).  Sibling
                // contains an award: regular spill.  Pure sibling:
                // safe to leave in place.
                result.Add (spillAwaits sigOf sp arr.[i])
            else
                // Side-effecting sibling to the left of an await —
                // hoist into a `val __tmp_<n> = expr` so its side
                // effects fire BEFORE the await suspends.
                let exprRew = spillAwaits sigOf sp arr.[i]
                if sp.Bailed then result.Add exprRew
                else
                    match tryInferAwaitInnerType sigOf exprRew with
                    | None ->
                        sp.Bailed <- true
                        result.Add exprRew
                    | Some lyTy ->
                        let nIdx = sp.Next
                        sp.Next <- nIdx + 1
                        let tmpName = sprintf "__tmp_%d" nIdx
                        sp.Types.Add(tmpName, lyTy)
                        let pat : Pattern =
                            { Kind = PBinding (tmpName, None); Span = exprRew.Span }
                        let stmt : Statement =
                            { Kind = SLocal (LBVal (pat, None, exprRew))
                              Span = exprRew.Span }
                        sp.Pending.Add stmt
                        result.Add (mkPath tmpName exprRew.Span)
        List.ofSeq result

/// Drain `sp.Pending` since the start index, returning the spilled
/// statements in source order and clearing them from the buffer.
let private drainPending (sp: Spiller) (start: int) : Statement list =
    if sp.Pending.Count = start then []
    else
        let acc = ResizeArray<Statement>()
        for i in start .. sp.Pending.Count - 1 do
            acc.Add sp.Pending.[i]
        while sp.Pending.Count > start do
            sp.Pending.RemoveAt(sp.Pending.Count - 1)
        List.ofSeq acc

/// Rewrite a statement so any contained non-safe-position `EAwait`
/// is hoisted to a preceding `val __spill_<n> = await …` binding.
/// Recurses into nested control-flow blocks.  Returns the rewritten
/// statement list (a single statement may expand into N+1 stmts —
/// the prepended spill bindings plus the rewritten original).
let rec private rewriteStmt
        (sigOf: string -> Lyric.TypeChecker.ResolvedSignature option)
        (sp: Spiller) (s: Statement) : Statement list =
    if sp.Bailed then [s]
    elif isSafeStmt s then [s]
    else
    let rebuild kind = { s with Kind = kind }
    let pendingStart = sp.Pending.Count
    let kind' =
        match s.Kind with
        | SExpr e -> SExpr (spillAwaits sigOf sp e)
        | SThrow e -> SThrow (spillAwaits sigOf sp e)
        | SReturn (Some e) -> SReturn (Some (spillAwaits sigOf sp e))
        | SReturn None -> SReturn None
        | SAssign (t, op, v) -> SAssign (t, op, spillAwaits sigOf sp v)
        | SLocal (LBVal (p, ann, init)) ->
            SLocal (LBVal (p, ann, spillAwaits sigOf sp init))
        | SLocal (LBLet (n, ann, init)) ->
            SLocal (LBLet (n, ann, spillAwaits sigOf sp init))
        | SLocal (LBVar (n, ann, Some init)) ->
            SLocal (LBVar (n, ann, Some (spillAwaits sigOf sp init)))
        | SLocal (LBVar (_, _, None) as lb) -> SLocal lb
        | SBreak _ | SContinue _ as k -> k
        | SItem _ as k -> k
        | SRule (lhs, rhs) ->
            SRule (spillAwaits sigOf sp lhs, spillAwaits sigOf sp rhs)
        | STry (body, catches) ->
            // Phase B+++ already handles the safe try-await shapes.
            // For unsafe awaits inside a try body, recurse into both
            // the body and each catch.  Spill bindings injected here
            // sit *outside* the try region; that's a semantics shift
            // for awaits whose results escape the try, so we stay
            // conservative and bail.
            sp.Bailed <- true
            STry (body, catches)
        | SDefer body ->
            // Same conservative bail — defer cleanup interactions with
            // hoisted spill bindings need explicit semantics.
            sp.Bailed <- true
            SDefer body
        | SScope (b, body) ->
            let body' = rewriteBlock sigOf sp body
            SScope (b, body')
        | SFor (lbl, pat, iter, body) ->
            let iter' = spillAwaits sigOf sp iter
            let body' = rewriteBlock sigOf sp body
            SFor (lbl, pat, iter', body')
        | SWhile (lbl, cond, body) ->
            // `while` cond can't safely host a spilled binding (the
            // spill needs to re-execute every iteration).  Walk for
            // awaits but bail if any are present in the cond — the
            // existing safe-position checker already requires
            // award-free conditions.
            let cond' = cond
            if exprHasAwait cond then sp.Bailed <- true
            let body' = rewriteBlock sigOf sp body
            SWhile (lbl, cond', body')
        | SLoop (lbl, body) ->
            let body' = rewriteBlock sigOf sp body
            SLoop (lbl, body')
    let prepended = drainPending sp pendingStart
    if sp.Bailed then [s]
    else prepended @ [rebuild kind']

and private rewriteBlock
        (sigOf: string -> Lyric.TypeChecker.ResolvedSignature option)
        (sp: Spiller) (blk: Block) : Block =
    if sp.Bailed then blk
    else
        let acc = ResizeArray<Statement>()
        for s in blk.Statements do
            if sp.Bailed then acc.Add s
            else
                for s' in rewriteStmt sigOf sp s do acc.Add s'
        { blk with Statements = List.ofSeq acc }

/// Public entry: try to rewrite an async function's body so every
/// `EAwait` sits at a safe top-level position.  Returns
/// `Some (rewrittenFn, spillTypeMap)` when the rewrite succeeded
/// (every spill-local's inner-await type was inferred), or `None`
/// when (a) the function is already safe, (b) the body is an
/// expression-form FBExpr (no statement scope to inject spill
/// bindings into), or (c) any spill site failed type inference.
///
/// `spillTypeMap` keys are the synthesised `__spill_<n>` names; the
/// caller pairs them with the function's local-collection pre-pass
/// so they enter the Phase B SM-field promotion table with the
/// correct CLR type.
let tryStackSpill
        (sigOf: string -> Lyric.TypeChecker.ResolvedSignature option)
        (fn: FunctionDecl)
        : (FunctionDecl * Map<string, Lyric.TypeChecker.Type>) option =
    if not (bodyContainsAwait fn) then None
    elif allAwaitsSafe fn then None
    else
    match fn.Body with
    | None | Some (FBExpr _) -> None
    | Some (FBBlock blk) ->
        let sp = freshSpiller ()
        let blk' = rewriteBlock sigOf sp blk
        if sp.Bailed then None
        elif sp.Pending.Count <> 0 then
            // Defensive: every drainPending should have flushed.  If
            // anything is left over the caller can't reason about
            // ordering, so bail.
            None
        else
            let fn' = { fn with Body = Some (FBBlock blk') }
            // Confirm the rewrite actually moved every await to a
            // safe position; if we missed a corner case, surface it
            // here instead of producing IL that fails later.
            if not (allAwaitsSafe fn') then None
            else
                let typeMap =
                    sp.Types
                    |> Seq.fold (fun m (n, t) -> Map.add n t m) Map.empty
                Some (fn', typeMap)

/// Returns true when this async function is eligible for the SM
/// lowering (covers both Phase A — await-free body — and Phase B —
/// awaits at safe top-level positions).  Currently:
///   * top-level (caller responsibility)
///   * non-instance (caller responsibility) — generic instance
///     impl methods still route to the M1.4 shim
///   * either no body await (Phase A) or every await is at a safe
///     top-level position (Phase B)
///   * no `@externTarget` annotation
///
/// Generic top-level async funcs are eligible: the kickoff site
/// closes the SM via `MakeGenericType` against the user method's
/// own GTPBs, and MoveNext IL references SM-side generic params
/// the JIT closes at runtime.  See `defineStateMachineHeader` /
/// `emitKickoff` and the free-standing async path in `Emitter.fs`.
let isAsyncSmEligible (fn: FunctionDecl) : bool =
    allAwaitsSafe fn
    && not (fn.Annotations
            |> List.exists (fun a ->
                match a.Name.Segments with
                | ["externTarget"] -> true
                | _ -> false))

/// Phase A vs Phase B distinguisher (caller side decides which
/// codegen path to take).  Phase B fires when the body contains
/// awaits AND every await is at a safe position; Phase A fires
/// when the body has no awaits.  When both predicates fire, the
/// function is Phase A (the await-free path is simpler).
let isPhaseB (fn: FunctionDecl) : bool =
    bodyContainsAwait fn && allAwaitsSafe fn

/// Legacy alias preserved so the M1.4 → Phase A migration in
/// `Emitter.fs` keeps compiling.  Equivalent to "Phase A only" —
/// caller routes Phase B separately.
let isPhaseAEligible (fn: FunctionDecl) : bool =
    isAsyncSmEligible fn && not (bodyContainsAwait fn)

/// Walk the body and return the inner-task expressions of every
/// `EAwait` in source order.  Phase B's pre-pass uses this to
/// peek the awaiter type for each suspension point.  Awaits
/// inside nested protected regions / non-safe positions never
/// reach this function because `isPhaseB` is false for those
/// functions; defensively the walk still descends into all sub-
/// expressions so the collector works on any AST shape.
let collectAwaitInners (fn: FunctionDecl) : Expr list =
    let acc = ResizeArray<Expr>()
    let rec walkExpr (e: Expr) : unit =
        match e.Kind with
        | EAwait inner ->
            acc.Add inner
            walkExpr inner
        | ELiteral _ | EPath _ | ESelf | EResult | EError -> ()
        | EInterpolated segs ->
            for s in segs do
                match s with
                | ISText _ -> ()
                | ISExpr e -> walkExpr e
        | EParen e | ESpawn e | EOld e | EPropagate e | ETry e -> walkExpr e
        | ETuple es | EList es -> for e in es do walkExpr e
        | EIf (c, t, eOpt, _) ->
            walkExpr c
            walkBranch t
            match eOpt with Some b -> walkBranch b | None -> ()
        | EMatch (s, arms) ->
            walkExpr s
            for a in arms do
                match a.Guard with Some g -> walkExpr g | None -> ()
                walkBranch a.Body
        | EForall (_, where, body) | EExists (_, where, body) ->
            match where with Some w -> walkExpr w | None -> ()
            walkExpr body
        | ELambda (_, blk) -> walkBlock blk
        | ECall (f, args) ->
            walkExpr f
            for a in args do
                match a with
                | CANamed (_, v, _) -> walkExpr v
                | CAPositional v    -> walkExpr v
        | ETypeApp (f, _) -> walkExpr f
        | EIndex (r, idxs) ->
            walkExpr r
            for i in idxs do walkExpr i
        | EMember (r, _) -> walkExpr r
        | EPrefix (_, op) -> walkExpr op
        | EBinop (_, l, r) -> walkExpr l; walkExpr r
        | ERange rb ->
            match rb with
            | RBClosed (a, b) | RBHalfOpen (a, b) -> walkExpr a; walkExpr b
            | RBLowerOpen a | RBUpperOpen a       -> walkExpr a
        | EAssign (t, _, v) -> walkExpr t; walkExpr v
        | EBlock b -> walkBlock b
    and walkBranch (eob: ExprOrBlock) =
        match eob with
        | EOBExpr e  -> walkExpr e
        | EOBBlock b -> walkBlock b
    and walkBlock (b: Block) =
        for s in b.Statements do walkStmt s
    and walkStmt (s: Statement) =
        match s.Kind with
        | SExpr e | SThrow e -> walkExpr e
        | SReturn (Some e) -> walkExpr e
        | SReturn None | SBreak _ | SContinue _ -> ()
        | SAssign (t, _, v) -> walkExpr t; walkExpr v
        | SLocal (LBVal (_, _, e)) | SLocal (LBLet (_, _, e)) -> walkExpr e
        | SLocal (LBVar (_, _, Some e)) -> walkExpr e
        | SLocal (LBVar (_, _, None)) -> ()
        | STry (body, catches) ->
            walkBlock body
            for c in catches do walkBlock c.Body
        | SDefer b | SScope (_, b) | SLoop (_, b) -> walkBlock b
        | SFor (_, _, iter, body) -> walkExpr iter; walkBlock body
        | SWhile (_, cond, body) -> walkExpr cond; walkBlock body
        | SRule (lhs, rhs) -> walkExpr lhs; walkExpr rhs
        | SItem _ -> ()
    match fn.Body with
    | None -> ()
    | Some (FBExpr e) -> walkExpr e
    | Some (FBBlock b) -> walkBlock b
    List.ofSeq acc

/// Collect top-level locals (`val`/`let`/`var name [: T] = …`) from
/// the function body.  Phase B promotes every top-level local to
/// an SM field.  Returns each local as `(name, typeAnnotationOpt)`
/// in source order; nested declarations inside conditionals or
/// loops are not currently promoted (Phase B+ work).  Locals
/// whose binding pattern isn't a simple `name` (tuple destructure,
/// pattern match) come back as `None` and disqualify the function
/// from Phase B (caller checks for `None` to fall back to M1.4).
type CollectedLocal =
    { Name:        string
      Annotation:  TypeExpr option
      /// True when the binding is a `var` (mutable); informational only.
      IsMutable:   bool
      Span:        Span }

let collectTopLevelLocals (fn: FunctionDecl) : CollectedLocal list option =
    // Returns None if any local binding isn't a simple `name`.
    let acc = ResizeArray<CollectedLocal>()
    let mutable bail = false
    let visit (s: Statement) =
        match s.Kind with
        | SLocal (LBVal ({ Kind = PBinding (name, None) }, ann, _)) ->
            acc.Add { Name = name; Annotation = ann; IsMutable = false; Span = s.Span }
        | SLocal (LBLet (name, ann, _)) ->
            acc.Add { Name = name; Annotation = ann; IsMutable = false; Span = s.Span }
        | SLocal (LBVar (name, ann, _)) ->
            acc.Add { Name = name; Annotation = ann; IsMutable = true; Span = s.Span }
        | SLocal _ -> bail <- true
        | _ -> ()
    let walkBlock (b: Block) =
        for s in b.Statements do visit s
    match fn.Body with
    | None -> ()
    | Some (FBExpr _) -> ()
    | Some (FBBlock b) -> walkBlock b
    if bail then None else Some (List.ofSeq acc)

/// Collect locals that need promotion when an async body contains
/// awaits inside `while`/`loop` bodies.  Each loop body's locals
/// are scanned one level deep — this lets `while cond { val x = …;
/// await foo(x) }` work without blanket-promoting deeply nested
/// declarations.  Top-level locals are also included (one pass
/// instead of two).  Names are deduplicated; if the same name is
/// declared in two scopes the first occurrence wins (subsequent
/// declarations reuse the same SM field, which is the standard
/// Roslyn pattern for "hoisted local" variables).
let collectPromotableLocals (fn: FunctionDecl) : CollectedLocal list option =
    let acc = ResizeArray<CollectedLocal>()
    let seen = HashSet<string>()
    let mutable bail = false
    let consider (s: Statement) =
        match s.Kind with
        | SLocal (LBVal ({ Kind = PBinding (name, None) }, ann, _)) when not (seen.Contains name) ->
            seen.Add name |> ignore
            acc.Add { Name = name; Annotation = ann; IsMutable = false; Span = s.Span }
        | SLocal (LBLet (name, ann, _)) when not (seen.Contains name) ->
            seen.Add name |> ignore
            acc.Add { Name = name; Annotation = ann; IsMutable = false; Span = s.Span }
        | SLocal (LBVar (name, ann, _)) when not (seen.Contains name) ->
            seen.Add name |> ignore
            acc.Add { Name = name; Annotation = ann; IsMutable = true; Span = s.Span }
        | SLocal _ -> bail <- true
        | _ -> ()
    let rec walkBlock (b: Block) =
        for s in b.Statements do
            consider s
            match s.Kind with
            // Recurse into loops so iteration-body locals get
            // promoted alongside the top-level ones.  We do *not*
            // recurse into `if`/`match`/`try` bodies because they
            // don't require their locals to survive across an
            // await (each branch runs to completion before next
            // iteration's body re-enters the same SLocal site).
            | SWhile (_, _, body) | SLoop (_, body) -> walkBlock body
            | _ -> ()
    match fn.Body with
    | None -> ()
    | Some (FBExpr _) -> ()
    | Some (FBBlock b) -> walkBlock b
    if bail then None else Some (List.ofSeq acc)

// ---------------------------------------------------------------------------
// State-machine info shared across the three emit phases.
// ---------------------------------------------------------------------------

/// One field on the SM corresponding to a Lyric parameter.  Per
/// Phase A, parameters are stored by value (no byref-on-field
/// support); the M1.4 stdlib + tests don't pass `out`/`inout`
/// parameters to async funcs, and Reflection.Emit doesn't allow
/// FieldBuilder field types to be `T&`.  An async func using a
/// byref param falls back to the M1.4 path via
/// `isPhaseAEligible = false` if/when needed.
type SmParamField =
    { Name:  string
      Field: FieldBuilder
      /// CLR storage type (the "stripped" type — non-byref).
      Type:  Type }

/// One promoted local — Lyric `val`/`let`/`var` whose lifetime
/// straddles an `await`.  Stored as an SM field so its value
/// survives `MoveNext` re-entries.  At MoveNext entry the field's
/// value is copied into a regular IL local; at every suspend
/// point (just before `AwaitUnsafeOnCompleted`) the IL local is
/// copied back to the field.
type SmPromotedLocal =
    { LocalName:  string
      LocalField: FieldBuilder
      LocalType:  Type }

/// Everything codegen needs to wire a state machine.
type StateMachineInfo =
    { /// The synthesised SM type.
      Type: TypeBuilder
      /// SM's own generic type parameters (mirrors the user
      /// function's `Generics`).  Empty for non-generic async funcs.
      /// When non-empty, the kickoff site (which runs inside the
      /// user's generic method) closes the SM via
      /// `sm.Type.MakeGenericType(userMethodTypeParams)` and routes
      /// every `Newobj` / `Stfld` / `Ldfld` / call through
      /// `TypeBuilder.GetConstructor` / `TypeBuilder.GetField` /
      /// `TypeBuilder.GetMethod` against that closed instance.  See
      /// `closedSmType`, `smField`, `smCtor`, `smMethod`.
      GenericParams: GenericTypeParameterBuilder[]
      /// Default no-arg constructor on the SM (used by the kickoff).
      Ctor: ConstructorBuilder
      /// `<>state : int` field.
      State: FieldBuilder
      /// `<>builder : AsyncTaskMethodBuilder` (or `<R>`).
      Builder: FieldBuilder
      /// The closed builder type (`AsyncTaskMethodBuilder` for void,
      /// `AsyncTaskMethodBuilder<R>` for value-returning funcs).
      BuilderType: Type
      /// The bare return type (e.g. `int`); `typeof<Void>` for unit.
      BareReturn: Type
      /// True when the function returns `Unit` and the builder is
      /// non-generic.
      IsVoid: bool
      /// One field per parameter, in order.
      ParamFields: SmParamField list
      /// One field per promoted local (Phase B only); `[]` for Phase A.
      PromotedLocals: SmPromotedLocal list
      /// `MoveNext` method header.
      MoveNext: MethodBuilder
      /// `IAsyncStateMachine.SetStateMachine` method header.
      SetStateMachine: MethodBuilder }

/// Per-MoveNext context threaded into `Codegen.FunctionCtx` so the
/// `EAwait` handler can switch from the M1.4 blocking shim to the
/// real Phase B suspend/resume protocol.  Populated by `Emitter.fs`
/// at the start of MoveNext emission and consumed by Codegen each
/// time it descends into an `EAwait` node.
type SmAwaitInfo =
    { /// The owning state machine.
      Sm: StateMachineInfo
      /// Counter incremented on each `EAwait` emit; the next slot
      /// (state index) to allocate.  Tied to source-order traversal
      /// of the body.
      mutable NextAwaitIndex: int
      /// Awaiter fields, populated lazily as each `EAwait` emits.
      /// Keyed by state index (`0`..N-1`).  Lazy because the
      /// awaiter type is only known after `emitExpr` on the inner
      /// task expression returns its CLR type.
      AwaiterFields: Dictionary<int, FieldBuilder>
      /// One label per state index, pre-defined at MoveNext entry
      /// and marked at the resume point inside the body during
      /// `EAwait` emit.  The state-dispatch switch at MoveNext
      /// entry targets these labels.
      ResumeLabels: Label[]
      /// The label suspend `leave`s to: jumps past the entire
      /// try/catch + SetResult block, straight to the `ret`.
      SuspendLeaveLabel: Label
      /// Promoted-local IL-local + SM-field pairs.  At every suspend
      /// point, each IL local is flushed to its field (`Ldarg.0;
      /// Ldloc; Stfld`) so the value survives the cross-resume gap.
      /// At MoveNext entry, fields are loaded back into the IL
      /// locals (`Ldarg.0; Ldfld; Stloc`).  Body codegen still
      /// reads/writes via `Ldloc`/`Stloc` on the IL local — promotion
      /// is invisible to the regular emit pipeline.
      PromotedShadows: ResizeArray<LocalBuilder * FieldBuilder> }

/// Lazily define an awaiter field on the SM for the next state
/// index.  Called from `EAwait` emit when each new state index is
/// encountered.  Field name follows the C# Roslyn convention
/// (`<>u__1`, `<>u__2`, …).
let defineAwaiterField (sm: StateMachineInfo) (stateIndex: int) (awaiterTy: Type) : FieldBuilder =
    sm.Type.DefineField(
        sprintf "<>u__%d" (stateIndex + 1),
        awaiterTy,
        FieldAttributes.Public)

let private iAsmType : Type = typeof<IAsyncStateMachine>

let private builderTypeFor (bareReturn: Type) (isVoid: bool) : Type =
    if isVoid then typeof<AsyncTaskMethodBuilder>
    else typedefof<AsyncTaskMethodBuilder<_>>.MakeGenericType([| bareReturn |])

/// SM-class header — the bare TypeBuilder plus its (possibly empty)
/// generic-parameter builders.  Generic async funcs first define
/// the SM's own `GenericTypeParameterBuilder[]` here, then the
/// caller builds a `name -> SmGenericParam` substitution map and
/// uses it when computing CLR types for fields / locals / return.
type StateMachineHeader =
    { Type:          TypeBuilder
      GenericParams: GenericTypeParameterBuilder[] }

/// Step 1 of SM definition — define the type and (when the user
/// function is generic) its generic parameters.  The caller uses
/// `header.GenericParams` to build a `Map<string, Type>` from each
/// generic name to the SM-side parameter, then computes
/// `paramSpecs` / `localSpecs` / `bareReturn` against that map and
/// passes everything to `defineStateMachineBody` which finishes the
/// SM type.
///
/// For non-generic async funcs, callers can keep using
/// `defineStateMachine` (the tail-end thin wrapper that bundles
/// header + body for the `genericParamNames = []` case).
let defineStateMachineHeader
        (md: ModuleBuilder)
        (nsName: string)
        (funcName: string)
        (uniq: int)
        (genericParamNames: string list) : StateMachineHeader =
    let typeName =
        let baseName = sprintf "<%s>__SM_%d" funcName uniq
        if String.IsNullOrEmpty nsName then baseName
        else nsName + "." + baseName
    let tb =
        md.DefineType(
            typeName,
            TypeAttributes.Public
            ||| TypeAttributes.Sealed
            ||| TypeAttributes.BeforeFieldInit,
            typeof<obj>,
            [| iAsmType |])
    let genParams =
        if List.isEmpty genericParamNames then [||]
        else tb.DefineGenericParameters(List.toArray genericParamNames)
    { Type = tb; GenericParams = genParams }

/// Step 2 of SM definition — add fields, the default ctor, and the
/// MoveNext / SetStateMachine method headers, then hook them into
/// `IAsyncStateMachine`.  All CLR types in `bareReturn` /
/// `paramSpecs` / `localSpecs` must already be expressed in terms
/// of `header.GenericParams` (not the user method's generic
/// parameters) for generic async; non-generic callers pass plain
/// CLR types as before.
///
/// `localSpecs` is the list of (name, clrType) pairs for promoted
/// locals (Phase B).  `[]` for a Phase A function.  Awaiter fields
/// are defined lazily during MoveNext emit via
/// `defineAwaiterField` because the awaiter's CLR type is only
/// known after the inner task expression has been emitted.
let defineStateMachineBody
        (header: StateMachineHeader)
        (bareReturn: Type)
        (paramSpecs: (string * Type) list)
        (localSpecs: (string * Type) list) : StateMachineInfo =
    let tb = header.Type
    let isVoid = bareReturn = typeof<Void>
    let builderTy = builderTypeFor bareReturn isVoid
    let stateField =
        tb.DefineField("<>1__state", typeof<int>, FieldAttributes.Public)
    let builderField =
        tb.DefineField("<>t__builder", builderTy, FieldAttributes.Public)
    let defaultCtor =
        tb.DefineDefaultConstructor(MethodAttributes.Public)
    let paramFields =
        paramSpecs
        |> List.map (fun (name, ty) ->
            // Async funcs with byref params route to the M1.4 path
            // via `isPhaseAEligible` — defensive check here keeps
            // `DefineField` from throwing if a future caller misroutes.
            let storeTy : Type =
                if ty.IsByRef then
                    match Option.ofObj (ty.GetElementType()) with
                    | Some t -> t
                    | None   -> ty
                else ty
            let f = tb.DefineField(name, storeTy, FieldAttributes.Public)
            { Name = name; Field = f; Type = storeTy })

    let promotedLocals =
        localSpecs
        |> List.map (fun (name, ty) ->
            let storeTy : Type =
                if ty.IsByRef then
                    match Option.ofObj (ty.GetElementType()) with
                    | Some t -> t
                    | None   -> ty
                else ty
            let f =
                tb.DefineField(
                    "<l>__" + name,
                    storeTy,
                    FieldAttributes.Public)
            { LocalName = name; LocalField = f; LocalType = storeTy })

    let moveNext =
        tb.DefineMethod(
            "MoveNext",
            MethodAttributes.Public
            ||| MethodAttributes.HideBySig
            ||| MethodAttributes.Virtual
            ||| MethodAttributes.Final
            ||| MethodAttributes.NewSlot,
            typeof<Void>,
            [||])

    let setSm =
        tb.DefineMethod(
            "SetStateMachine",
            MethodAttributes.Public
            ||| MethodAttributes.HideBySig
            ||| MethodAttributes.Virtual
            ||| MethodAttributes.Final
            ||| MethodAttributes.NewSlot,
            typeof<Void>,
            [| iAsmType |])
    setSm.DefineParameter(1, ParameterAttributes.None, "stateMachine") |> ignore

    // Hook IAsyncStateMachine.MoveNext + SetStateMachine.
    let iasMove =
        match Option.ofObj (iAsmType.GetMethod("MoveNext")) with
        | Some m -> m
        | None   -> failwith "BCL: IAsyncStateMachine.MoveNext not found"
    let iasSet =
        match Option.ofObj (iAsmType.GetMethod("SetStateMachine")) with
        | Some m -> m
        | None   -> failwith "BCL: IAsyncStateMachine.SetStateMachine not found"
    tb.DefineMethodOverride(moveNext, iasMove)
    tb.DefineMethodOverride(setSm, iasSet)

    { Type            = tb
      GenericParams   = header.GenericParams
      Ctor            = defaultCtor
      State           = stateField
      Builder         = builderField
      BuilderType     = builderTy
      BareReturn      = bareReturn
      IsVoid          = isVoid
      ParamFields     = paramFields
      PromotedLocals  = promotedLocals
      MoveNext        = moveNext
      SetStateMachine = setSm }

/// Legacy entry point kept for non-generic call sites — combines
/// header + body in one call.  Generic async funcs use the split
/// form so they can build a CLR-type substitution against the
/// header's generic parameters before computing field types.
let defineStateMachine
        (md: ModuleBuilder)
        (nsName: string)
        (funcName: string)
        (uniq: int)
        (bareReturn: Type)
        (paramSpecs: (string * Type) list)
        (localSpecs: (string * Type) list) : StateMachineInfo =
    let header = defineStateMachineHeader md nsName funcName uniq []
    defineStateMachineBody header bareReturn paramSpecs localSpecs

// ---------------------------------------------------------------------------
// IL helpers.
// ---------------------------------------------------------------------------

/// True when `BuilderType` is `AsyncTaskMethodBuilder<T>` closed
/// over an unbaked argument — a TypeBuilder (Lyric record/union
/// still under construction) or a GenericTypeParameterBuilder
/// (an SM-side generic param the JIT will substitute at runtime).
/// In either case `BuilderType.GetMethod` raises
/// `NotSupportedException` and we have to route through
/// `TypeBuilder.GetMethod(closedType, openMethod)`.
let internal builderClosedOverTypeBuilder (sm: StateMachineInfo) : bool =
    let isUnbaked (t: Type) =
        t :? TypeBuilder || t :? GenericTypeParameterBuilder
    sm.BuilderType.IsGenericType
    && sm.BuilderType.GetGenericArguments()
       |> Array.exists (fun a ->
           isUnbaked a
           || (a.IsGenericType && a.GetGenericArguments() |> Array.exists isUnbaked))

let private builderOpenDef : Type = typedefof<AsyncTaskMethodBuilder<_>>
let private builderNonGen  : Type = typeof<AsyncTaskMethodBuilder>

/// Resolve a BCL method on `BuilderType`.  Falls back to
/// `TypeBuilder.GetMethod` when `BuilderType` is closed over a
/// TypeBuilder (`Type.GetMethod` throws NotSupportedException on
/// such types).  Pass `getter=true` for property getters.
let internal builderMember
        (sm: StateMachineInfo)
        (name: string) : MethodInfo =
    let isGenericClosedOverTb =
        sm.BuilderType.IsGenericType
        && sm.BuilderType.GetGenericTypeDefinition() = builderOpenDef
        && builderClosedOverTypeBuilder sm
    if isGenericClosedOverTb then
        // Look up the open generic method on the open builder
        // definition, then specialise via `TypeBuilder.GetMethod`.
        let candidates = builderOpenDef.GetMethods()
        let openMI =
            candidates
            |> Array.tryFind (fun m -> m.Name = name)
            |> Option.orElseWith (fun () ->
                candidates |> Array.tryFind (fun m -> m.Name = "get_" + name))
        match openMI with
        | Some m -> TypeBuilder.GetMethod(sm.BuilderType, m)
        | None ->
            failwithf "BCL: %s.%s not found (open def lookup)" sm.BuilderType.Name name
    else
        match Option.ofObj (sm.BuilderType.GetMethod(name)) with
        | Some m -> m
        | None ->
            match Option.ofObj (sm.BuilderType.GetMethod("get_" + name)) with
            | Some m -> m
            | None -> failwithf "BCL: %s.%s not found" sm.BuilderType.Name name

/// `AsyncTaskMethodBuilder[<T>]::Create()` (static).
let private builderCreate (sm: StateMachineInfo) : MethodInfo =
    let isGenericClosedOverTb =
        sm.BuilderType.IsGenericType
        && sm.BuilderType.GetGenericTypeDefinition() = builderOpenDef
        && builderClosedOverTypeBuilder sm
    if isGenericClosedOverTb then
        let openCreate =
            builderOpenDef.GetMethod("Create", BindingFlags.Public ||| BindingFlags.Static)
        match Option.ofObj openCreate with
        | Some m -> TypeBuilder.GetMethod(sm.BuilderType, m)
        | None   -> failwith "BCL: AsyncTaskMethodBuilder<>.Create not found"
    else
        match Option.ofObj (sm.BuilderType.GetMethod("Create", BindingFlags.Public ||| BindingFlags.Static)) with
        | Some m -> m
        | None   -> failwithf "BCL: %s.Create not found" sm.BuilderType.Name

/// Closed `Start<TStateMachine>(ref TStateMachine)` for our SM type.
let private builderStart (sm: StateMachineInfo) : MethodInfo =
    let isGenericClosedOverTb =
        sm.BuilderType.IsGenericType
        && sm.BuilderType.GetGenericTypeDefinition() = builderOpenDef
        && builderClosedOverTypeBuilder sm
    let openStart =
        if isGenericClosedOverTb then
            let openOnDef =
                match Option.ofObj
                          (builderOpenDef.GetMethod("Start", BindingFlags.Public ||| BindingFlags.Instance)) with
                | Some m -> m
                | None   -> failwith "BCL: AsyncTaskMethodBuilder<>.Start not found"
            TypeBuilder.GetMethod(sm.BuilderType, openOnDef)
        else
            match Option.ofObj
                      (sm.BuilderType.GetMethod("Start", BindingFlags.Public ||| BindingFlags.Instance)) with
            | Some m -> m
            | None   -> failwithf "BCL: %s.Start not found" sm.BuilderType.Name
    openStart.MakeGenericMethod([| sm.Type :> Type |])

// ---------------------------------------------------------------------------
// Kickoff body.
// ---------------------------------------------------------------------------

/// True when this SM is generic (mirrors a generic user function).
let isGenericSm (sm: StateMachineInfo) : bool =
    sm.GenericParams.Length > 0

/// Closed builder type at a kickoff site.  For non-generic SMs the
/// SM's stored `BuilderType` is already fully closed; for generic
/// SMs the stored type is `AsyncTaskMethodBuilder<R>` where `R` is
/// open over the SM's generic parameters and we close it again
/// against the user-method-context return type.
let private closedKickoffBuilderType (sm: StateMachineInfo) (kickoffBareReturn: Type) : Type =
    if not (isGenericSm sm) then sm.BuilderType
    elif sm.IsVoid then sm.BuilderType
    else typedefof<AsyncTaskMethodBuilder<_>>.MakeGenericType([| kickoffBareReturn |])

/// True when `kickoffBuilderTy` is `AsyncTaskMethodBuilder<R>`
/// closed over a TypeBuilder / GenericTypeParameterBuilder, in
/// which case `Type.GetMethod` raises NotSupportedException and
/// we have to route through `TypeBuilder.GetMethod`.  For
/// fully-closed-over-BCL-types instances (e.g.
/// `AsyncTaskMethodBuilder<int>`) the regular `Type.GetMethod`
/// path works.
let private kickoffBuilderClosedOverTb (kickoffBuilderTy: Type) : bool =
    kickoffBuilderTy.IsGenericType
    && kickoffBuilderTy.GetGenericTypeDefinition() = builderOpenDef
    && (kickoffBuilderTy.GetGenericArguments()
        |> Array.exists (fun a ->
            a :? TypeBuilder
            || a :? GenericTypeParameterBuilder
            || (a.IsGenericType
                && a.GetGenericArguments()
                   |> Array.exists (fun b ->
                       b :? TypeBuilder
                       || b :? GenericTypeParameterBuilder))))

/// `AsyncTaskMethodBuilder[<R>]::Create` resolved against the
/// kickoff-context closed builder type.  Mirrors `builderCreate`
/// but without an `sm` dependency.
let private kickoffBuilderCreate (kickoffBuilderTy: Type) : MethodInfo =
    if kickoffBuilderClosedOverTb kickoffBuilderTy then
        match Option.ofObj (builderOpenDef.GetMethod("Create", BindingFlags.Public ||| BindingFlags.Static)) with
        | Some m -> TypeBuilder.GetMethod(kickoffBuilderTy, m)
        | None   -> failwith "BCL: AsyncTaskMethodBuilder<>.Create not found"
    else
        match Option.ofObj (kickoffBuilderTy.GetMethod("Create", BindingFlags.Public ||| BindingFlags.Static)) with
        | Some m -> m
        | None   -> failwithf "BCL: %s.Create not found" kickoffBuilderTy.Name

/// `AsyncTaskMethodBuilder[<R>]::<member>` lookup against the
/// kickoff-context closed builder type.  Mirrors `builderMember`.
let private kickoffBuilderMember (kickoffBuilderTy: Type) (name: string) : MethodInfo =
    if kickoffBuilderClosedOverTb kickoffBuilderTy then
        let candidates = builderOpenDef.GetMethods()
        let openMI =
            candidates
            |> Array.tryFind (fun m -> m.Name = name)
            |> Option.orElseWith (fun () ->
                candidates |> Array.tryFind (fun m -> m.Name = "get_" + name))
        match openMI with
        | Some m -> TypeBuilder.GetMethod(kickoffBuilderTy, m)
        | None ->
            failwithf "BCL: %s.%s not found (open def lookup)" kickoffBuilderTy.Name name
    else
        match Option.ofObj (kickoffBuilderTy.GetMethod(name)) with
        | Some m -> m
        | None ->
            match Option.ofObj (kickoffBuilderTy.GetMethod("get_" + name)) with
            | Some m -> m
            | None -> failwithf "BCL: %s.%s not found" kickoffBuilderTy.Name name

/// `AsyncTaskMethodBuilder[<R>]::Start<TSm>(ref TSm)` closed over
/// the kickoff-side SM type.  Mirrors `builderStart`.
let private kickoffBuilderStart (kickoffBuilderTy: Type) (closedSmTy: Type) : MethodInfo =
    let openStart =
        if kickoffBuilderClosedOverTb kickoffBuilderTy then
            let openOnDef =
                match Option.ofObj
                          (builderOpenDef.GetMethod("Start", BindingFlags.Public ||| BindingFlags.Instance)) with
                | Some m -> m
                | None   -> failwith "BCL: AsyncTaskMethodBuilder<>.Start not found"
            TypeBuilder.GetMethod(kickoffBuilderTy, openOnDef)
        else
            match Option.ofObj
                      (kickoffBuilderTy.GetMethod("Start", BindingFlags.Public ||| BindingFlags.Instance)) with
            | Some m -> m
            | None   -> failwithf "BCL: %s.Start not found" kickoffBuilderTy.Name
    openStart.MakeGenericMethod([| closedSmTy |])

/// Emit the user's async function body — now a kickoff stub.  Layout:
///
///     var sm    = new <SM>()
///     sm.<>p0   = arg0
///     sm.<>p1   = arg1   ...
///     sm.<>builder = AsyncTaskMethodBuilder.Create()
///     sm.<>state   = -1
///     sm.<>builder.Start<<SM>>(ref sm)
///     return sm.<>builder.Task
///
/// `userGenericArgs` is `[||]` for non-generic async funcs and the
/// user-method's `GenericTypeParameterBuilder[]` (cast to `Type[]`)
/// for generic async funcs.  When non-empty, every field / ctor /
/// method reference on the SM routes through `TypeBuilder.GetX`
/// against the closed-over-user-method-types instantiation, and
/// the builder is re-closed against the user-method-context bare
/// return.
///
/// `kickoffBareReturn` is the user-method-context bare return type
/// (e.g. for `async func id[T](x: T): T` it's the user method's
/// `T` builder, not the SM's `T`).  Required only for generic SMs;
/// non-generic callers can pass `sm.BareReturn`.
let emitKickoff
        (kickoffMb: MethodBuilder)
        (sm: StateMachineInfo)
        (userGenericArgs: Type[])
        (kickoffBareReturn: Type)
        (paramArgIndices: int list) : unit =
    let il = kickoffMb.GetILGenerator()
    let closedSm =
        if Array.isEmpty userGenericArgs then sm.Type :> Type
        else sm.Type.MakeGenericType(userGenericArgs)
    let smField (openF: FieldBuilder) : FieldInfo =
        if Array.isEmpty userGenericArgs then openF :> FieldInfo
        else TypeBuilder.GetField(closedSm, openF)
    let smCtor : ConstructorInfo =
        if Array.isEmpty userGenericArgs then sm.Ctor :> ConstructorInfo
        else TypeBuilder.GetConstructor(closedSm, sm.Ctor)
    let kickoffBuilderTy = closedKickoffBuilderType sm kickoffBareReturn
    let smLocal = il.DeclareLocal(closedSm)

    // Phase A keeps the SM as a class (sealed reference type), so
    // `newobj` on its default ctor matches C# class-mode (debug-build)
    // emission.  Struct-mode (`initobj` on a value-typed slot) is the
    // C# release-build shape; we'll switch when locals start needing
    // promotion to fields and we want to avoid the heap allocation.
    il.Emit(OpCodes.Newobj, smCtor)
    il.Emit(OpCodes.Stloc, smLocal)

    // sm.<>builder = AsyncTaskMethodBuilder.Create()
    il.Emit(OpCodes.Ldloc, smLocal)
    il.Emit(OpCodes.Call, kickoffBuilderCreate kickoffBuilderTy)
    il.Emit(OpCodes.Stfld, smField sm.Builder)

    // sm.<>state = -1
    il.Emit(OpCodes.Ldloc, smLocal)
    il.Emit(OpCodes.Ldc_I4_M1)
    il.Emit(OpCodes.Stfld, smField sm.State)

    // Copy each parameter into its SM field.  `paramArgIndices` matches
    // `sm.ParamFields` element-for-element; the caller is responsible
    // for the alignment (instance methods shift by 1, etc.).
    List.zip sm.ParamFields paramArgIndices
    |> List.iter (fun (pf, argIdx) ->
        il.Emit(OpCodes.Ldloc, smLocal)
        il.Emit(OpCodes.Ldarg, argIdx)
        il.Emit(OpCodes.Stfld, smField pf.Field))

    // sm.<>builder.Start<SM>(ref sm)
    // `Start` is an instance method on a struct builder — ldflda
    // gives us `&sm.<>builder` as a managed pointer.
    il.Emit(OpCodes.Ldloc, smLocal)
    il.Emit(OpCodes.Ldflda, smField sm.Builder)
    il.Emit(OpCodes.Ldloca, smLocal)
    il.Emit(OpCodes.Call, kickoffBuilderStart kickoffBuilderTy closedSm)

    // return sm.<>builder.Task — `builderMember` routes through
    // `TypeBuilder.GetMethod` when the closing arg is a Lyric
    // record/union still under construction.
    il.Emit(OpCodes.Ldloc, smLocal)
    il.Emit(OpCodes.Ldflda, smField sm.Builder)
    let taskGetter = kickoffBuilderMember kickoffBuilderTy "Task"
    il.Emit(OpCodes.Call, taskGetter)
    il.Emit(OpCodes.Ret)

// ---------------------------------------------------------------------------
// MoveNext body — finished by the caller.
//
// The SM exposes its IL generator via `MoveNext`.  The Emitter sets up
// a FunctionCtx pointing at this generator and runs the regular
// emit-body pipeline against the user's body, with `SmFields`
// populated so parameter access goes through `Ldarg.0; Ldfld <field>`
// instead of `Ldarg N`.  The exit-point block (after the user body
// produces the return value) runs the SetResult/SetException
// finaliser — emitted by `emitMoveNextEpilogue` below.
// ---------------------------------------------------------------------------

/// Emit the SetResult / SetException epilogue at the end of MoveNext.
/// Layout (no real exception handling in Phase A — the user body
/// runs entirely synchronously without any await suspension; a
/// thrown exception bubbles out of MoveNext naturally and is captured
/// by `Start`'s outer try/catch on our behalf):
///
///     this.<>state = -2     // -2 = completed
///     this.<>builder.SetResult(<resultLocal-or-nothing>)
///     ret
///
/// `resultLocal` carries the bare return value (Phase A bodies
/// always run to completion) or `None` for void.
let emitMoveNextEpilogue
        (il: ILGenerator)
        (sm: StateMachineInfo)
        (resultLocal: LocalBuilder option) : unit =
    // this.<>state = -2
    il.Emit(OpCodes.Ldarg_0)
    il.Emit(OpCodes.Ldc_I4, -2)
    il.Emit(OpCodes.Stfld, sm.State)

    // this.<>builder.SetResult(...)
    il.Emit(OpCodes.Ldarg_0)
    il.Emit(OpCodes.Ldflda, sm.Builder)
    match resultLocal with
    | Some loc -> il.Emit(OpCodes.Ldloc, loc)
    | None     -> ()
    let setResult = builderMember sm "SetResult"
    il.Emit(OpCodes.Call, setResult)
    il.Emit(OpCodes.Ret)

/// Emit `SetStateMachine`'s body: just forward to the builder.
let emitSetStateMachine (sm: StateMachineInfo) : unit =
    let il = sm.SetStateMachine.GetILGenerator()
    il.Emit(OpCodes.Ldarg_0)
    il.Emit(OpCodes.Ldflda, sm.Builder)
    il.Emit(OpCodes.Ldarg_1)
    let setSm = builderMember sm "SetStateMachine"
    il.Emit(OpCodes.Call, setSm)
    il.Emit(OpCodes.Ret)
