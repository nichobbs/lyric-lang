/// Stability-annotation analysis (Q011 / D040).
///
/// Recognises `@stable(since="X.Y")` and `@experimental` on `pub`
/// items and enforces the one-way rule:
///   a non-experimental `pub` function may not call an `@experimental`
///   item declared in the same source file.
///
/// Cross-package stability enforcement is deferred until the contract-
/// metadata reader (Imports.fs) is extended to carry the `Stability`
/// field added to `ContractDecl` in this slice.
///
/// Diagnostic codes:
///   S0001 — stable pub func calls an @experimental callee in the same
///            package (intra-file enforcement).
///   S0002 — @stable and @experimental both present on the same item.
module Lyric.Verifier.StabilityCheck

open Lyric.Lexer
open Lyric.Parser.Ast

// ---------------------------------------------------------------------------
// Stability levels.
// ---------------------------------------------------------------------------

/// A pub item's stability level.
type StabilityLevel =
    /// `@stable(since="X.Y")` — API is stable from that version.
    | Stable of since: string
    /// `@experimental` — API may change; no SemVer guarantee.
    | Experimental
    /// No annotation present.  Treated as stable for enforcement
    /// (omitting `@experimental` is not an excuse to depend on one).
    | Unmarked

module StabilityLevel =

    let isExperimental = function
        | Experimental -> true
        | _            -> false

    let display = function
        | Stable since -> sprintf "@stable(since=\"%s\")" since
        | Experimental -> "@experimental"
        | Unmarked     -> "(unmarked-stable)"

// ---------------------------------------------------------------------------
// Reading stability from annotation lists.
// ---------------------------------------------------------------------------

/// Read the stability level from any annotation list.
let stabilityOfAnnotations (anns: Annotation list) : StabilityLevel =
    let isNamed name (a: Annotation) =
        match a.Name.Segments with
        | [seg] -> seg = name
        | _     -> false
    let stableAnn = anns |> List.tryFind (isNamed "stable")
    let exptlAnn  = anns |> List.tryFind (isNamed "experimental")
    match exptlAnn, stableAnn with
    | Some _, Some _ ->
        // Conflict resolved below in checkConflicts — return Experimental
        // conservatively so the rest of the analysis treats this item
        // as experimental (no false S0001 fires).
        Experimental
    | Some _, None -> Experimental
    | None, Some a ->
        let since =
            a.Args
            |> List.tryPick (fun arg ->
                match arg with
                | AAName("since", AVString(s, _), _) -> Some s
                | _                                  -> None)
            |> Option.defaultValue ""
        Stable since
    | None, None -> Unmarked

/// Read stability from the outer `Item` wrapper's annotation list.
/// This is the canonical call site for item-level stability because
/// `parseItem` places all prefix annotations (including `@stable` /
/// `@experimental`) in `Item.Annotations`.
let stabilityOfItem (item: Item) : StabilityLevel =
    stabilityOfAnnotations item.Annotations

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

let private isPub (item: Item) : bool =
    match item.Visibility with
    | Some (Pub _) -> true
    | None         -> false

let private nameOfItemKind (kind: ItemKind) : string option =
    match kind with
    | IFunc fn         -> Some fn.Name
    | IRecord rd       -> Some rd.Name
    | IExposedRec rd   -> Some rd.Name
    | IUnion un        -> Some un.Name
    | IEnum en         -> Some en.Name
    | IOpaque op       -> Some op.Name
    | IInterface iface -> Some iface.Name
    | IDistinctType dt -> Some dt.Name
    | ITypeAlias ta    -> Some ta.Name
    | _                -> None

// ---------------------------------------------------------------------------
// Expression walker — collect (callee-name, span) from EPath-headed calls.
// ---------------------------------------------------------------------------

let private collectCallNames (body: FunctionBody) : (string * Span) list =
    let acc = ResizeArray<string * Span>()

    let rec visitExpr (e: Expr) =
        match e.Kind with
        | ECall(fn, args) ->
            (match fn.Kind with
             | EPath p ->
                 match p.Segments with
                 | [name] -> acc.Add(name, e.Span)
                 | _      -> ()
             | _ -> ())
            visitExpr fn
            for a in args do
                match a with
                | CANamed(_, v, _) | CAPositional v -> visitExpr v
        | EParen x | ETry x | EOld x | EPropagate x
        | EAwait x | ESpawn x                       -> visitExpr x
        | ETuple xs | EList xs                      -> xs |> List.iter visitExpr
        | EIf(c, t, eOpt, _) ->
            visitExpr c
            visitEOB t
            eOpt |> Option.iter visitEOB
        | EMatch(s, arms) ->
            visitExpr s
            for arm in arms do
                visitEOB arm.Body
                arm.Guard |> Option.iter visitExpr
        | EForall(_, w, body) | EExists(_, w, body) ->
            w |> Option.iter visitExpr
            visitExpr body
        | ETypeApp(fn, _) -> visitExpr fn
        | EIndex(r, ix)   -> visitExpr r; ix |> List.iter visitExpr
        | EMember(r, _)   -> visitExpr r
        | EPrefix(_, x)   -> visitExpr x
        | EBinop(_, l, r) -> visitExpr l; visitExpr r
        | EAssign(t, _, v)-> visitExpr t; visitExpr v
        | EBlock blk | EUnsafe blk -> visitBlock blk
        | EInterpolated segs ->
            segs |> List.iter (function
                | ISExpr x -> visitExpr x
                | ISText _ -> ())
        | ELambda(_, body) -> visitBlock body
        | ERange rb ->
            match rb with
            | RBClosed(a, b) | RBHalfOpen(a, b) -> visitExpr a; visitExpr b
            | RBLowerOpen b                      -> visitExpr b
            | RBUpperOpen a                      -> visitExpr a
        | ELiteral _ | EPath _ | ESelf | EResult | EError -> ()

    and visitEOB (eob: ExprOrBlock) =
        match eob with
        | EOBExpr x  -> visitExpr x
        | EOBBlock b -> visitBlock b

    and visitBlock (blk: Block) =
        for st in blk.Statements do
            match st.Kind with
            | SLocal lb ->
                match lb with
                | LBVal(_, _, init) | LBLet(_, _, init) -> visitExpr init
                | LBVar(_, _, Some init)                 -> visitExpr init
                | LBVar(_, _, None)                      -> ()
            | SAssign(t, _, v)    -> visitExpr t; visitExpr v
            | SReturn(Some v)     -> visitExpr v
            | SReturn None        -> ()
            | SBreak _ | SContinue _ -> ()
            | SThrow x            -> visitExpr x
            | STry(body, catches) ->
                visitBlock body
                catches |> List.iter (fun c -> visitBlock c.Body)
            | SDefer body | SScope(_, body) -> visitBlock body
            | SFor(_, _, iter, body) | SWhile(_, iter, body) ->
                visitExpr iter; visitBlock body
            | SLoop(_, body)  -> visitBlock body
            | SExpr x         -> visitExpr x
            | SInvariant x    -> visitExpr x
            | SRule(l, r)     -> visitExpr l; visitExpr r
            | SItem _         -> ()

    match body with
    | FBExpr e  -> visitExpr e
    | FBBlock b -> visitBlock b
    List.ofSeq acc

// ---------------------------------------------------------------------------
// S0002: @stable and @experimental conflict.
// ---------------------------------------------------------------------------

let private checkConflicts
        (diags: ResizeArray<Diagnostic>)
        (file: SourceFile) : unit =
    for item in file.Items do
        let anns = item.Annotations
        let isNamed name (a: Annotation) =
            match a.Name.Segments with | [seg] -> seg = name | _ -> false
        let hasStable = anns |> List.exists (isNamed "stable")
        let hasExptl  = anns |> List.exists (isNamed "experimental")
        if hasStable && hasExptl then
            let span =
                anns
                |> List.tryFind (isNamed "experimental")
                |> Option.map (fun a -> a.Span)
                |> Option.defaultValue item.Span
            diags.Add(
                Diagnostic.error "S0002"
                    (sprintf "item carries both @stable and @experimental; pick one")
                    span)

// ---------------------------------------------------------------------------
// S0001: stable pub func calls @experimental intra-file callee.
// ---------------------------------------------------------------------------

let private checkCallGraph
        (diags: ResizeArray<Diagnostic>)
        (file: SourceFile) : unit =

    // Map: item name -> stability (for all items in this file).
    let stabilityMap =
        file.Items
        |> List.choose (fun item ->
            match nameOfItemKind item.Kind with
            | Some name -> Some (name, stabilityOfItem item)
            | None      -> None)
        |> Map.ofList

    for item in file.Items do
        if isPub item && not (stabilityOfItem item |> StabilityLevel.isExperimental) then
            match item.Kind with
            | IFunc fn ->
                match fn.Body with
                | None      -> ()
                | Some body ->
                    for (callee, span) in collectCallNames body do
                        match Map.tryFind callee stabilityMap with
                        | Some Experimental ->
                            diags.Add(
                                Diagnostic.error "S0001"
                                    (sprintf "stable pub func '%s' calls @experimental '%s'; mark '%s' @experimental or promote '%s' to @stable"
                                        fn.Name callee fn.Name callee)
                                    span)
                        | _ -> ()
            | _ -> ()

// ---------------------------------------------------------------------------
// Public entry point.
// ---------------------------------------------------------------------------

/// Check a single source file for stability violations.
/// Returns a (possibly empty) list of S0001 / S0002 diagnostics.
let checkFile (file: SourceFile) : Diagnostic list =
    let diags = ResizeArray<Diagnostic>()
    checkConflicts  diags file
    checkCallGraph  diags file
    List.ofSeq diags
