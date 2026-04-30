/// Statement-level type checking and function-body validation.
///
/// `checkStatement` updates the scope (for val/var/let bindings) and
/// emits diagnostics for type-incompatible operations. `checkBlock`
/// drives a sequence of statements and returns the block's value
/// type — either the type of its trailing expression, or Unit.
///
/// `checkFunctionBody` ties everything together: pushes the
/// function's parameters onto a fresh Scope, checks the body, and
/// verifies the body's value type is compatible with the declared
/// return type.
module Lyric.TypeChecker.StmtChecker

open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.TypeChecker.ExprChecker

let private err
        (diags: ResizeArray<Diagnostic>)
        (code:  string)
        (msg:   string)
        (span:  Span) =
    diags.Add(Diagnostic.error code msg span)

/// Walk a pattern and bind any single-ident bindings into the scope.
/// Tuple, constructor, and record patterns destructure into multiple
/// bindings; for T5 we only handle single-ident bindings, leaving
/// the rest to T6+ when the pattern type checker lands.
let private bindPattern
        (scope: Scope)
        (diags: ResizeArray<Diagnostic>)
        (pat:   Pattern)
        (ty:    Type)
        : unit =
    match pat.Kind with
    | PBinding(name, None) when name <> "_" ->
        scope.Add({ Name = name; Type = ty; IsMutable = false })
    | PWildcard | PBinding("_", _) ->
        ()
    | PBinding(name, Some _) ->
        // `name @ inner` — bind name; pattern walking for inner is
        // T6 work.
        scope.Add({ Name = name; Type = ty; IsMutable = false })
    | _ ->
        // Tuple / constructor / record / range patterns are accepted
        // syntactically but not yet bound by the checker. Emit no
        // diagnostic — the binding is silently dropped.
        ()

let rec checkStatement
        (scope: Scope)
        (table: SymbolTable)
        (sigs:  Map<string, ResolvedSignature>)
        (returnType: Type)
        (diags: ResizeArray<Diagnostic>)
        (stmt:  Statement)
        : unit =

    match stmt.Kind with
    | SLocal (LBVal(pat, declType, init)) ->
        let initType = inferExpr scope table sigs diags init
        let bindType =
            match declType with
            | Some te ->
                let ctx = GenericContext()
                let declT = Resolver.resolveType table ctx diags te
                if not (Type.equiv declT initType) then
                    err diags "T0060"
                        (sprintf
                            "val binding declared as %s but initialiser has type %s"
                            (Type.render declT) (Type.render initType))
                        stmt.Span
                declT
            | None -> initType
        bindPattern scope diags pat bindType

    | SLocal (LBVar(name, declType, init)) ->
        let initType =
            match init with
            | Some e -> inferExpr scope table sigs diags e
            | None -> TyError
        let bindType =
            match declType with
            | Some te ->
                let ctx = GenericContext()
                let declT = Resolver.resolveType table ctx diags te
                if init.IsSome && not (Type.equiv declT initType) then
                    err diags "T0061"
                        (sprintf
                            "var binding declared as %s but initialiser has type %s"
                            (Type.render declT) (Type.render initType))
                        stmt.Span
                declT
            | None -> initType
        scope.Add({ Name = name; Type = bindType; IsMutable = true })

    | SLocal (LBLet(name, declType, init)) ->
        let initType = inferExpr scope table sigs diags init
        let bindType =
            match declType with
            | Some te ->
                let ctx = GenericContext()
                let declT = Resolver.resolveType table ctx diags te
                if not (Type.equiv declT initType) then
                    err diags "T0062"
                        (sprintf
                            "let binding declared as %s but initialiser has type %s"
                            (Type.render declT) (Type.render initType))
                        stmt.Span
                declT
            | None -> initType
        scope.Add({ Name = name; Type = bindType; IsMutable = false })

    | SAssign(target, op, value) ->
        let _ = op   // operator class doesn't change the type rules at this stage
        let targetType = inferExpr scope table sigs diags target
        let valueType  = inferExpr scope table sigs diags value
        if not (Type.equiv targetType valueType) then
            err diags "T0063"
                (sprintf
                    "assigned value of type %s does not match target of type %s"
                    (Type.render valueType) (Type.render targetType))
                stmt.Span

    | SReturn None ->
        if not (Type.equiv returnType (TyPrim PtUnit)) then
            err diags "T0064"
                (sprintf
                    "return without value but enclosing function returns %s"
                    (Type.render returnType))
                stmt.Span

    | SReturn (Some e) ->
        let t = inferExpr scope table sigs diags e
        // TyPrim PtNever satisfies any return type — let it through.
        if t <> TyPrim PtNever && not (Type.equiv t returnType) then
            err diags "T0065"
                (sprintf
                    "returned value of type %s does not match declared return type %s"
                    (Type.render t) (Type.render returnType))
                stmt.Span

    | SThrow e ->
        // The thrown expression should be an Error-typed value; for
        // now we only ensure it type-checks.
        let _ = inferExpr scope table sigs diags e
        ()

    | SBreak _ | SContinue _ -> ()

    | SExpr e ->
        // Expression statement: infer for diagnostic side effects;
        // discard the value.
        let _ = inferExpr scope table sigs diags e
        ()

    | SDefer blk
    | SScope(_, blk)
    | SLoop(_, blk) ->
        checkBlock scope table sigs returnType diags blk |> ignore

    | SFor(_, pat, iter, body) ->
        let iterType = inferExpr scope table sigs diags iter
        // Element type extraction — handle slice[T], array[N, T];
        // anything else is TyError pending T6.
        let elemType =
            match iterType with
            | TySlice e -> e
            | TyArray(_, e) -> e
            | _ -> TyError
        scope.Push()
        bindPattern scope diags pat elemType
        checkBlock scope table sigs returnType diags body |> ignore
        scope.Pop()

    | SWhile(_, cond, body) ->
        let condT = inferExpr scope table sigs diags cond
        if not (Type.equiv condT (TyPrim PtBool)) then
            err diags "T0066"
                (sprintf "while-condition must be Bool (got %s)"
                    (Type.render condT))
                stmt.Span
        checkBlock scope table sigs returnType diags body |> ignore

    | STry(body, catches) ->
        checkBlock scope table sigs returnType diags body |> ignore
        for c in catches do
            scope.Push()
            match c.Bind with
            | Some name ->
                scope.Add({ Name = name; Type = TyError; IsMutable = false })
            | None -> ()
            checkBlock scope table sigs returnType diags c.Body |> ignore
            scope.Pop()

    | SItem _ ->
        // Nested item declarations are rare; defer to T6+.
        ()

    | SRule (_, _) ->
        // Stub-builder DSL rule entries (`it.foo() -> bar`) parse
        // inside `{ … }` lambdas. The Phase 1 type checker tolerates
        // them but doesn't yet model the stub-builder protocol; full
        // checking lands when @stubbable lands in T6+.
        ()

and checkBlock
        (scope: Scope)
        (table: SymbolTable)
        (sigs:  Map<string, ResolvedSignature>)
        (returnType: Type)
        (diags: ResizeArray<Diagnostic>)
        (blk:   Block)
        : Type =
    scope.Push()
    let mutable lastExprType : Type = TyPrim PtUnit
    for stmt in blk.Statements do
        match stmt.Kind with
        | SExpr e ->
            lastExprType <- inferExpr scope table sigs diags e
        | _ ->
            checkStatement scope table sigs returnType diags stmt
            lastExprType <- TyPrim PtUnit
    scope.Pop()
    lastExprType

/// Check a function declaration's body. Pushes parameters into a
/// fresh scope, type-checks the body, and verifies the body's value
/// type is compatible with the declared return type.
let checkFunctionBody
        (table: SymbolTable)
        (sigs:  Map<string, ResolvedSignature>)
        (diags: ResizeArray<Diagnostic>)
        (fn:    FunctionDecl)
        (sig':  ResolvedSignature)
        : unit =

    // FFI shim: a function with `@externTarget("...")` lowers to a
    // direct CLR call at codegen time; the user-supplied body is
    // ignored.  Skip return-type checking — the body is conventionally
    // a placeholder `()` that wouldn't match the declared return.
    let isExternTarget =
        fn.Annotations
        |> List.exists (fun a ->
            match a.Name.Segments with
            | ["externTarget"] -> true
            | _ -> false)
    if isExternTarget then () else

    let scope = Scope()
    for p in sig'.Params do
        scope.Add(
            { Name      = p.Name
              Type      = p.Type
              IsMutable = (p.Mode <> PMIn) })

    match fn.Body with
    | None -> ()
    | Some (FBExpr e) ->
        let bodyType = inferExpr scope table sigs diags e
        if bodyType <> TyPrim PtNever
           && not (Type.equiv bodyType sig'.Return) then
            err diags "T0070"
                (sprintf
                    "function body has type %s but declared return type is %s"
                    (Type.render bodyType) (Type.render sig'.Return))
                fn.Span
    | Some (FBBlock blk) ->
        let bodyType =
            checkBlock scope table sigs sig'.Return diags blk
        // A trailing expression whose type matches the return type
        // is treated as the function's value (Lyric is expression-
        // oriented). Bodies that end in a return / throw produce
        // PtUnit from checkBlock (the trailing statement isn't an
        // expression), so we don't emit a mismatch in that case.
        if bodyType <> TyPrim PtUnit
           && bodyType <> TyPrim PtNever
           && not (Type.equiv bodyType sig'.Return) then
            err diags "T0070"
                (sprintf
                    "function body trailing expression has type %s but declared return type is %s"
                    (Type.render bodyType) (Type.render sig'.Return))
                fn.Span
