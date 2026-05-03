/// AST-level rewriter for `import X as A` package aliases.
///
/// The bootstrap-grade alias semantics (D-progress-018):
///
///   import Std.Collections as Coll
///   val xs: Coll.List[Int] = Coll.newList()
///   xs.add(7)
///
/// is treated as syntactic sugar for
///
///   import Std.Collections
///   val xs: List[Int] = newList()
///   xs.add(7)
///
/// The rewriter runs after parsing and before type-check, walking
/// every `Expr`, `TypeExpr`, `Pattern`, and `ConstraintRef` in the
/// user's source file.  Selector-level aliases
/// (`import X.{foo as bar}`) are NOT handled here — they're cloned
/// into the imported-items list by the emitter so the original symbol
/// is registered under both names.
///
/// Out-of-scope (bootstrap):
///   - The rewriter is scope-blind.  A local variable named `Coll`
///     after `import X as Coll` would collide; users should pick alias
///     names that don't shadow locals.
///   - Aliases on non-`Std.*` user packages aren't yet wired through
///     the emitter's package resolver, so this only meaningfully fires
///     for stdlib imports today.
module Lyric.Parser.AliasRewriter

open Lyric.Lexer
open Lyric.Parser.Ast

/// Build a set of single-segment alias names from the source file's
/// imports.  Only `import X as A`-style aliases participate; selector
/// aliases (`{ foo as bar }`) are handled elsewhere.
let private collectAliases (imports: ImportDecl list) : Set<string> =
    imports
    |> List.choose (fun i -> i.Alias)
    |> Set.ofList

let private rewritePath (aliases: Set<string>) (p: ModulePath) : ModulePath =
    match p.Segments with
    | head :: rest when not rest.IsEmpty && Set.contains head aliases ->
        { p with Segments = rest }
    | _ -> p

let rec private rewriteTypeExpr (aliases: Set<string>) (te: TypeExpr) : TypeExpr =
    match te.Kind with
    | TRef p ->
        { te with Kind = TRef (rewritePath aliases p) }
    | TGenericApp (head, args) ->
        let head' = rewritePath aliases head
        let args' = args |> List.map (rewriteTypeArg aliases)
        { te with Kind = TGenericApp (head', args') }
    | TArray (size, elem) ->
        { te with Kind = TArray (rewriteTypeArg aliases size, rewriteTypeExpr aliases elem) }
    | TSlice elem ->
        { te with Kind = TSlice (rewriteTypeExpr aliases elem) }
    | TRefined (head, range) ->
        { te with Kind = TRefined (rewritePath aliases head, rewriteRangeBound aliases range) }
    | TTuple elems ->
        { te with Kind = TTuple (elems |> List.map (rewriteTypeExpr aliases)) }
    | TNullable t ->
        { te with Kind = TNullable (rewriteTypeExpr aliases t) }
    | TFunction (ps, r) ->
        { te with Kind = TFunction (ps |> List.map (rewriteTypeExpr aliases), rewriteTypeExpr aliases r) }
    | TParen t ->
        { te with Kind = TParen (rewriteTypeExpr aliases t) }
    | TUnit | TSelf | TNever | TError -> te

and private rewriteTypeArg (aliases: Set<string>) (a: TypeArg) : TypeArg =
    match a with
    | TAType t  -> TAType (rewriteTypeExpr aliases t)
    | TAValue e -> TAValue (rewriteExpr aliases e)

and private rewriteRangeBound (aliases: Set<string>) (rb: RangeBound) : RangeBound =
    match rb with
    | RBClosed (lo, hi)    -> RBClosed (rewriteExpr aliases lo, rewriteExpr aliases hi)
    | RBHalfOpen (lo, hi)  -> RBHalfOpen (rewriteExpr aliases lo, rewriteExpr aliases hi)
    | RBLowerOpen hi       -> RBLowerOpen (rewriteExpr aliases hi)
    | RBUpperOpen lo       -> RBUpperOpen (rewriteExpr aliases lo)

and private rewriteConstraintRef (aliases: Set<string>) (cr: ConstraintRef) : ConstraintRef =
    { cr with
        Head = rewritePath aliases cr.Head
        Args = cr.Args |> List.map (rewriteTypeArg aliases) }

and private rewriteExpr (aliases: Set<string>) (e: Expr) : Expr =
    let r = rewriteExpr aliases
    let rt = rewriteTypeExpr aliases
    let kind =
        match e.Kind with
        | EPath p -> EPath (rewritePath aliases p)
        | EMember ({ Kind = EPath p } as recv, name)
            when (match p.Segments with
                  | [head] -> Set.contains head aliases
                  | _ -> false) ->
            // `Coll.foo` collapses to a bare reference `foo` because
            // `Coll` is a known alias.
            EPath { p with Segments = [name] }
        | EMember (recv, name) ->
            EMember (r recv, name)
        | ELiteral _ | ESelf | EResult | EError -> e.Kind
        | EInterpolated segments ->
            let segs' =
                segments
                |> List.map (fun s ->
                    match s with
                    | ISText (t, sp) -> ISText (t, sp)
                    | ISExpr inner   -> ISExpr (r inner))
            EInterpolated segs'
        | EParen inner -> EParen (r inner)
        | ETuple xs    -> ETuple (xs |> List.map r)
        | EList  xs    -> EList (xs |> List.map r)
        | EIf (c, t, el, tf) ->
            EIf (r c, rewriteExprOrBlock aliases t,
                 el |> Option.map (rewriteExprOrBlock aliases), tf)
        | EMatch (sc, arms) ->
            EMatch (r sc, arms |> List.map (rewriteMatchArm aliases))
        | EAwait inner   -> EAwait (r inner)
        | ESpawn inner   -> ESpawn (r inner)
        | ETry inner     -> ETry (r inner)
        | EOld inner     -> EOld (r inner)
        | EForall (bs, w, body) ->
            EForall (bs, w |> Option.map r, r body)
        | EExists (bs, w, body) ->
            EExists (bs, w |> Option.map r, r body)
        | ELambda (ps, body) ->
            ELambda (ps, rewriteBlock aliases body)
        | ECall (fn, args) ->
            ECall (r fn, args |> List.map (rewriteCallArg aliases))
        | ETypeApp (fn, targs) ->
            ETypeApp (r fn, targs |> List.map (rewriteTypeArg aliases))
        | EIndex (recv, idxs) ->
            EIndex (r recv, idxs |> List.map r)
        | EPropagate inner -> EPropagate (r inner)
        | EPrefix (op, x)  -> EPrefix (op, r x)
        | EBinop (op, a, b) -> EBinop (op, r a, r b)
        | ERange rb        -> ERange (rewriteRangeBound aliases rb)
        | EAssign (t, op, v) -> EAssign (r t, op, r v)
        | EBlock blk       -> EBlock (rewriteBlock aliases blk)
    { e with Kind = kind }

and private rewriteCallArg (aliases: Set<string>) (a: CallArg) : CallArg =
    match a with
    | CANamed (n, e, sp) -> CANamed (n, rewriteExpr aliases e, sp)
    | CAPositional e     -> CAPositional (rewriteExpr aliases e)

and private rewriteExprOrBlock (aliases: Set<string>) (eob: ExprOrBlock) : ExprOrBlock =
    match eob with
    | EOBExpr e  -> EOBExpr (rewriteExpr aliases e)
    | EOBBlock b -> EOBBlock (rewriteBlock aliases b)

and private rewriteMatchArm (aliases: Set<string>) (arm: MatchArm) : MatchArm =
    { arm with
        Pattern = rewritePattern aliases arm.Pattern
        Guard   = arm.Guard |> Option.map (rewriteExpr aliases)
        Body    = rewriteExprOrBlock aliases arm.Body }

and private rewritePattern (aliases: Set<string>) (p: Pattern) : Pattern =
    let kind =
        match p.Kind with
        | PConstructor (head, args) ->
            PConstructor (rewritePath aliases head,
                          args |> List.map (rewritePattern aliases))
        | PRecord (head, fields, ignoreRest) ->
            let fields' =
                fields
                |> List.map (fun rpf ->
                    match rpf with
                    | RPFNamed (n, inner, sp) ->
                        RPFNamed (n, rewritePattern aliases inner, sp)
                    | RPFShort _ -> rpf)
            PRecord (rewritePath aliases head, fields', ignoreRest)
        | PTuple ps   -> PTuple (ps |> List.map (rewritePattern aliases))
        | PParen inner -> PParen (rewritePattern aliases inner)
        | PTypeTest (inner, ty) ->
            PTypeTest (rewritePattern aliases inner, rewriteTypeExpr aliases ty)
        | POr ps      -> POr (ps |> List.map (rewritePattern aliases))
        | PBinding (n, inner) ->
            PBinding (n, inner |> Option.map (rewritePattern aliases))
        | PRange (lo, incl, hi) ->
            PRange (rewriteExpr aliases lo, incl, rewriteExpr aliases hi)
        | PWildcard | PLiteral _ | PError -> p.Kind
    { p with Kind = kind }

and private rewriteBlock (aliases: Set<string>) (b: Block) : Block =
    { b with Statements = b.Statements |> List.map (rewriteStatement aliases) }

and private rewriteStatement (aliases: Set<string>) (s: Statement) : Statement =
    let kind =
        match s.Kind with
        | SLocal lb -> SLocal (rewriteLocalBinding aliases lb)
        | SAssign (t, op, v) ->
            SAssign (rewriteExpr aliases t, op, rewriteExpr aliases v)
        | SReturn opt -> SReturn (opt |> Option.map (rewriteExpr aliases))
        | SBreak _ | SContinue _ -> s.Kind
        | SThrow e    -> SThrow (rewriteExpr aliases e)
        | STry (body, catches) ->
            let body' = rewriteBlock aliases body
            let catches' =
                catches
                |> List.map (fun c -> { c with Body = rewriteBlock aliases c.Body })
            STry (body', catches')
        | SDefer body -> SDefer (rewriteBlock aliases body)
        | SScope (n, body) -> SScope (n, rewriteBlock aliases body)
        | SFor (l, p, it, body) ->
            SFor (l, rewritePattern aliases p,
                  rewriteExpr aliases it, rewriteBlock aliases body)
        | SWhile (l, c, body) ->
            SWhile (l, rewriteExpr aliases c, rewriteBlock aliases body)
        | SLoop (l, body) -> SLoop (l, rewriteBlock aliases body)
        | SInvariant e -> SInvariant (rewriteExpr aliases e)
        | SExpr e -> SExpr (rewriteExpr aliases e)
        | SRule (lhs, rhs) ->
            SRule (rewriteExpr aliases lhs, rewriteExpr aliases rhs)
        | SItem _ -> s.Kind   // nested items are top-level by the time we recurse
    { s with Kind = kind }

and private rewriteLocalBinding (aliases: Set<string>) (lb: LocalBinding) : LocalBinding =
    match lb with
    | LBVal (pat, ty, init) ->
        LBVal (rewritePattern aliases pat,
               ty |> Option.map (rewriteTypeExpr aliases),
               rewriteExpr aliases init)
    | LBVar (n, ty, init) ->
        LBVar (n,
               ty |> Option.map (rewriteTypeExpr aliases),
               init |> Option.map (rewriteExpr aliases))
    | LBLet (n, ty, init) ->
        LBLet (n,
               ty |> Option.map (rewriteTypeExpr aliases),
               rewriteExpr aliases init)

let private rewriteParam (aliases: Set<string>) (p: Param) : Param =
    { p with
        Type    = rewriteTypeExpr aliases p.Type
        Default = p.Default |> Option.map (rewriteExpr aliases) }

let private rewriteFunctionBody (aliases: Set<string>) (b: FunctionBody) : FunctionBody =
    match b with
    | FBExpr e  -> FBExpr (rewriteExpr aliases e)
    | FBBlock b -> FBBlock (rewriteBlock aliases b)

let private rewriteFunctionDecl (aliases: Set<string>) (fn: FunctionDecl) : FunctionDecl =
    { fn with
        Params = fn.Params |> List.map (rewriteParam aliases)
        Return = fn.Return |> Option.map (rewriteTypeExpr aliases)
        Body   = fn.Body   |> Option.map (rewriteFunctionBody aliases) }

let private rewriteFieldDecl (aliases: Set<string>) (f: FieldDecl) : FieldDecl =
    { f with
        Type    = rewriteTypeExpr aliases f.Type
        Default = f.Default |> Option.map (rewriteExpr aliases) }

let private rewriteRecordDecl (aliases: Set<string>) (rd: RecordDecl) : RecordDecl =
    let members' =
        rd.Members
        |> List.map (fun m ->
            match m with
            | RMField f -> RMField (rewriteFieldDecl aliases f)
            | RMInvariant inv ->
                RMInvariant { inv with Expr = rewriteExpr aliases inv.Expr }
            | RMFunc fn -> RMFunc (rewriteFunctionDecl aliases fn))
    { rd with Members = members' }

let private rewriteImpl (aliases: Set<string>) (impl: ImplDecl) : ImplDecl =
    let members' =
        impl.Members
        |> List.map (fun m ->
            match m with
            | IMplFunc fn -> IMplFunc (rewriteFunctionDecl aliases fn)
            | other       -> other)
    { impl with
        Interface = rewriteConstraintRef aliases impl.Interface
        Target    = rewriteTypeExpr aliases impl.Target
        Members   = members' }

let private rewriteItem (aliases: Set<string>) (it: Item) : Item =
    let kind =
        match it.Kind with
        | IFunc fn       -> IFunc (rewriteFunctionDecl aliases fn)
        | IRecord rd     -> IRecord (rewriteRecordDecl aliases rd)
        | IExposedRec rd -> IExposedRec (rewriteRecordDecl aliases rd)
        | IImpl impl     -> IImpl (rewriteImpl aliases impl)
        | IConst c       ->
            IConst { c with
                        Type = rewriteTypeExpr aliases c.Type
                        Init = rewriteExpr aliases c.Init }
        | IVal v         ->
            IVal { v with
                     Type = v.Type |> Option.map (rewriteTypeExpr aliases)
                     Init = rewriteExpr aliases v.Init }
        | other          -> other
    { it with Kind = kind }

/// Apply package-alias rewriting to every Item in `file`.  No-op when
/// the file has no `import X as Y` declarations.
let rewriteFile (file: SourceFile) : SourceFile =
    let aliases = collectAliases file.Imports
    if Set.isEmpty aliases then file
    else
        { file with
            Items = file.Items |> List.map (rewriteItem aliases) }
