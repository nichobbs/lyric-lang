/// Bottom-up type inference for expressions and top-down checking for
/// statements and blocks, united in one mutually recursive module.
///
/// `inferExpr`, `checkStatement`, and `checkBlock` are mutually
/// recursive — expression-level blocks (EBlock, EIf branches, EMatch
/// arms, ELambda bodies) call into `checkBlock`; statement-level
/// constructs call `inferExpr` for sub-expression type inference.
///
/// Implements all T5 constructs:
///   - EIf / EMatch / EBlock / EUnsafe  (control-flow expressions)
///   - ELambda                          (anonymous functions → TyFunction)
///   - EIndex                           (array/slice/string element access)
///   - ERange                           (range literals → TyRange)
///   - EInterpolated                    (interpolated strings → String)
///   - ETypeApp                         (type-argument application, pass-through)
///   - EForall / EExists                (quantifier atoms → Bool)
///   - EAssign in expression position   (type-checks RHS; mutability deferred to T6+)
///   - DKConst / DKVal / DKUnionCase / DKEnumCase resolution
///   - PTuple with element types from TyTuple scrutinee
///   - PConstructor with field types from union symbol
///   - POr   (all alternatives walked; first alternative's bindings used)
///   - PRecord field bindings
///   - PTypeTest narrows to tested type
///   - PRange  (no bindings produced)
///   - for-loop element type for TyRange iterables
module Lyric.TypeChecker.ExprChecker

open Lyric.Lexer
open Lyric.Parser.Ast

let private err
        (diags: ResizeArray<Diagnostic>)
        (code:  string)
        (msg:   string)
        (span:  Span) =
    diags.Add(Diagnostic.error code msg span)

// ---------------------------------------------------------------------------
// Literals.
// ---------------------------------------------------------------------------

let typeOfLiteral (lit: Literal) : Type =
    match lit with
    | LInt(_, NoIntSuffix) -> TyPrim PtInt
    | LInt(_, I8)  -> TyPrim PtByte
    | LInt(_, I16) -> TyPrim PtInt
    | LInt(_, I32) -> TyPrim PtInt
    | LInt(_, I64) -> TyPrim PtLong
    | LInt(_, U8)  -> TyPrim PtByte
    | LInt(_, U16) -> TyPrim PtUInt
    | LInt(_, U32) -> TyPrim PtUInt
    | LInt(_, U64) -> TyPrim PtULong
    | LFloat(_, NoFloatSuffix) -> TyPrim PtDouble
    | LFloat(_, F32) -> TyPrim PtFloat
    | LFloat(_, F64) -> TyPrim PtDouble
    | LChar _   -> TyPrim PtChar
    | LString _ | LTripleString _ | LRawString _ -> TyPrim PtString
    | LBool _   -> TyPrim PtBool
    | LUnit     -> TyPrim PtUnit

// ---------------------------------------------------------------------------
// Codegen builtins.
// ---------------------------------------------------------------------------

/// Bootstrap-grade closed list of names handled directly by the
/// codegen as builtins (println, panic, expect, assert, host parse
/// helpers, …).
let private codegenBuiltinType (name: string) : Type option =
    match name with
    | "println" ->
        Some (TyFunction([TyError], TyPrim PtUnit, false))
    | "toString" ->
        Some (TyFunction([TyError], TyPrim PtString, false))
    | "format1" ->
        Some (TyFunction([TyPrim PtString; TyError], TyPrim PtString, false))
    | "format2" ->
        Some (TyFunction([TyPrim PtString; TyError; TyError], TyPrim PtString, false))
    | "format3" ->
        Some (TyFunction([TyPrim PtString; TyError; TyError; TyError], TyPrim PtString, false))
    | "format4" ->
        Some (TyFunction([TyPrim PtString; TyError; TyError; TyError; TyError], TyPrim PtString, false))
    | "format5" ->
        Some (TyFunction([TyPrim PtString; TyError; TyError; TyError; TyError; TyError], TyPrim PtString, false))
    | "format6" ->
        Some (TyFunction([TyPrim PtString; TyError; TyError; TyError; TyError; TyError; TyError], TyPrim PtString, false))
    | "panic" ->
        Some (TyFunction([TyPrim PtString], TyPrim PtNever, false))
    | "default" ->
        Some (TyFunction([], TyError, false))
    | "expect" ->
        Some (TyFunction([TyPrim PtBool; TyPrim PtString], TyPrim PtUnit, false))
    | "assert" ->
        Some (TyFunction([TyPrim PtBool], TyPrim PtUnit, false))
    | "hostParseIntIsValid"    -> Some (TyFunction([TyPrim PtString], TyPrim PtBool, false))
    | "hostParseIntValue"      -> Some (TyFunction([TyPrim PtString], TyPrim PtInt, false))
    | "hostParseLongIsValid"   -> Some (TyFunction([TyPrim PtString], TyPrim PtBool, false))
    | "hostParseLongValue"     -> Some (TyFunction([TyPrim PtString], TyPrim PtLong, false))
    | "hostParseDoubleIsValid" -> Some (TyFunction([TyPrim PtString], TyPrim PtBool, false))
    | "hostParseDoubleValue"   -> Some (TyFunction([TyPrim PtString], TyPrim PtDouble, false))
    | "hostFileExists"          -> Some (TyFunction([TyPrim PtString], TyPrim PtBool, false))
    | "hostReadAllTextIsValid"  -> Some (TyFunction([TyPrim PtString], TyPrim PtBool, false))
    | "hostReadAllTextValue"    -> Some (TyFunction([TyPrim PtString], TyPrim PtString, false))
    | "hostReadAllTextError"    -> Some (TyFunction([TyPrim PtString], TyPrim PtString, false))
    | "hostWriteAllTextIsValid" ->
        Some (TyFunction([TyPrim PtString; TyPrim PtString], TyPrim PtBool, false))
    | "hostWriteAllTextError"   ->
        Some (TyFunction([TyPrim PtString; TyPrim PtString], TyPrim PtString, false))
    | "hostDirectoryExists"     -> Some (TyFunction([TyPrim PtString], TyPrim PtBool, false))
    | "hostCreateDirectoryIsValid" ->
        Some (TyFunction([TyPrim PtString], TyPrim PtBool, false))
    | _ -> None

// ---------------------------------------------------------------------------
// Operator semantics.
// ---------------------------------------------------------------------------

let private isNumeric (t: Type) : bool =
    match t with
    | TyPrim PtByte | TyPrim PtInt | TyPrim PtLong
    | TyPrim PtUInt | TyPrim PtULong | TyPrim PtNat
    | TyPrim PtFloat | TyPrim PtDouble -> true
    | TyError -> true
    // TyVar is treated as potentially numeric in the bootstrap (full
    // constraint inference is deferred to T6+).
    | TyVar _ -> true
    | _ -> false

let private isOrdered (t: Type) : bool =
    isNumeric t
    || (match t with
        | TyPrim PtChar | TyPrim PtString -> true
        | _ -> false)

let private hasDerive (table: SymbolTable) (marker: string) (t: Type) : bool =
    match t with
    | TyUser(id, _) ->
        table.All()
        |> Seq.exists (fun s ->
            match s.Kind with
            | DKDistinctType(tid, dt) when tid = id ->
                List.contains marker dt.Derives
            | _ -> false)
    | _ -> false

let private arithMarker (op: BinOp) : string =
    match op with
    | BAdd -> "Add" | BSub -> "Sub" | BMul -> "Mul"
    | BDiv -> "Div" | BMod -> "Mod" | _    -> ""

let private inferBinop
        (table: SymbolTable)
        (diags: ResizeArray<Diagnostic>)
        (op:    BinOp)
        (lhs:   Type)
        (rhs:   Type)
        (span:  Span)
        : Type =
    match op with
    | BAdd | BSub | BMul | BDiv | BMod ->
        match op, lhs with
        | BAdd, TyPrim PtString -> TyPrim PtString
        | _ ->
            let lhsOk = isNumeric lhs || hasDerive table (arithMarker op) lhs
            if not lhsOk then
                err diags "T0030"
                    (sprintf "left operand of arithmetic operator is not numeric (got %s)"
                        (Type.render lhs))
                    span
            // Cross-numeric arithmetic (e.g. Long + Int, Byte * Int) is allowed
            // in the bootstrap; return TyError to suppress downstream type errors.
            // Full coercion rules are deferred to T6+.
            if not (Type.equiv lhs rhs) && not (isNumeric lhs && isNumeric rhs) then
                err diags "T0031"
                    (sprintf "arithmetic operands must have the same type (got %s and %s)"
                        (Type.render lhs) (Type.render rhs))
                    span
            if not (Type.equiv lhs rhs) && isNumeric lhs && isNumeric rhs then
                TyError
            else
                lhs
    | BEq | BNeq ->
        // Cross-numeric equality (e.g. Byte == Int) is allowed in the
        // bootstrap; full coercion rules are deferred to T6+.
        if not (Type.equiv lhs rhs) && not (isNumeric lhs && isNumeric rhs) then
            err diags "T0032"
                (sprintf "equality operands must have the same type (got %s and %s)"
                    (Type.render lhs) (Type.render rhs))
                span
        TyPrim PtBool
    | BLt | BLte | BGt | BGte ->
        let lhsOk = isOrdered lhs || hasDerive table "Compare" lhs
        if (not lhsOk) || not (Type.equiv lhs rhs) then
            err diags "T0033"
                (sprintf "comparison operands must be matching ordered types (got %s and %s)"
                    (Type.render lhs) (Type.render rhs))
                span
        TyPrim PtBool
    | BAnd | BOr | BXor | BImplies ->
        if not (Type.equiv lhs (TyPrim PtBool)) then
            err diags "T0034"
                (sprintf "left operand of logical operator must be Bool (got %s)"
                    (Type.render lhs))
                span
        if not (Type.equiv rhs (TyPrim PtBool)) then
            err diags "T0034"
                (sprintf "right operand of logical operator must be Bool (got %s)"
                    (Type.render rhs))
                span
        TyPrim PtBool
    | BCoalesce ->
        match lhs with
        | TyNullable inner ->
            if not (Type.equiv inner rhs) then
                err diags "T0035"
                    (sprintf "?? RHS type %s must match the nullable's inner type %s"
                        (Type.render rhs) (Type.render inner))
                    span
            inner
        | TyError -> TyError
        | other ->
            err diags "T0035"
                (sprintf "?? LHS must be a nullable type (got %s)" (Type.render other))
                span
            rhs

let private inferPrefix
        (diags: ResizeArray<Diagnostic>)
        (op:    PrefixOp)
        (inner: Type)
        (span:  Span)
        : Type =
    match op with
    | PreNeg ->
        if not (isNumeric inner) then
            err diags "T0036"
                (sprintf "unary minus requires a numeric operand (got %s)"
                    (Type.render inner))
                span
        inner
    | PreNot ->
        if not (Type.equiv inner (TyPrim PtBool)) then
            err diags "T0037"
                (sprintf "'not' requires a Bool operand (got %s)"
                    (Type.render inner))
                span
        TyPrim PtBool
    | PreRef ->
        // Prefix-ref (`&x`) is a no-op at the type level in the bootstrap;
        // reference semantics are deferred to T6+ (Phase 2).
        inner

// ---------------------------------------------------------------------------
// Member access helpers.
// ---------------------------------------------------------------------------

let private fieldsOfRecord (table: SymbolTable) (id: TypeId) : (string * Type) list =
    let extract (rd: RecordDecl) =
        rd.Members
        |> List.choose (fun m ->
            match m with
            | RMField fd ->
                let ctx = GenericContext()
                let diags2 = ResizeArray<Diagnostic>()
                let t = Resolver.resolveType table ctx diags2 fd.Type
                Some (fd.Name, t)
            | _ -> None)
    table.All()
    |> Seq.tryPick (fun s ->
        match s.Kind with
        | DKRecord(tid, rd) when tid = id     -> Some (extract rd)
        | DKExposedRec(tid, rd) when tid = id -> Some (extract rd)
        | _ -> None)
    |> Option.defaultValue []

let private builtinMember (receiver: Type) (name: string) : Type option =
    match receiver, name with
    | TySlice _,        "length"   -> Some (TyPrim PtInt)
    | TyArray _,        "length"   -> Some (TyPrim PtInt)
    | TyPrim PtString,  "length"   -> Some (TyPrim PtInt)
    | TyPrim PtString,  "isEmpty"  -> Some (TyPrim PtBool)
    | _ -> None

let private inferMember
        (table: SymbolTable)
        (diags: ResizeArray<Diagnostic>)
        (receiver: Type)
        (name:  string)
        (span:  Span)
        : Type =
    match receiver with
    | TyUser(id, _) ->
        let fs = fieldsOfRecord table id
        match List.tryFind (fun (n, _) -> n = name) fs with
        | Some (_, t) -> t
        | None ->
            // TyError without a diagnostic: the member could be a BCL method
            // on a CLR type or a union-case accessor, both of which the
            // bootstrap emitter handles directly without a type-checker symbol.
            // Emitting T0020 here would produce noise on every valid BCL call.
            TyError
    | TyError -> TyError
    | other ->
        match builtinMember other name with
        | Some t -> t
        | None   -> TyError

// ---------------------------------------------------------------------------
// Generic context helper.
// ---------------------------------------------------------------------------

let private mkGenericCtx (genericNames: string list) : GenericContext =
    let ctx = GenericContext()
    if not genericNames.IsEmpty then ctx.Push genericNames
    ctx

/// Return the generic parameter names declared on the parent union whose
/// TypeId is `parentId`.  Used to resolve union-case field type expressions
/// (which reference the union's own type variables, e.g. `T` in
/// `case Some(value: T)`) and to build the constructor's return type.
let private unionGenericParamsFor (table: SymbolTable) (parentId: TypeId) : string list =
    table.All()
    |> Seq.tryPick (fun sym ->
        match sym.Kind with
        | DKUnion(id, u) when id = parentId ->
            let names =
                match u.Generics with
                | Some gs ->
                    gs.Params |> List.map (function
                        | GPType(n, _) | GPValue(n, _, _) -> n)
                | None -> []
            Some names
        | _ -> None)
    |> Option.defaultValue []

// ---------------------------------------------------------------------------
// Pattern binding.
// ---------------------------------------------------------------------------

/// Walk a pattern and add name bindings into the scope with their inferred
/// types.  `ty` is the type of the scrutinee (or sub-expression) being
/// matched by `pat`.
let rec private bindPattern
        (table: SymbolTable)
        (scope: Scope)
        (diags: ResizeArray<Diagnostic>)
        (pat:   Pattern)
        (ty:    Type)
        : unit =
    match pat.Kind with
    | PWildcard | PBinding("_", _) ->
        ()
    | PBinding(name, None) ->
        // If this name resolves to a zero-field union case constructor
        // (e.g. `case None ->` parsed without parens), treat it as a
        // constructor match rather than a new variable binding so the
        // name is not shadowed in the arm body.
        let isZeroArgCtor =
            match table.TryFindOne name with
            | Some sym ->
                match sym.Kind with
                | DKUnionCase(_, uc) when uc.Fields.IsEmpty -> true
                | _ -> false
            | None -> false
        if not isZeroArgCtor then
            scope.Add({ Name = name; Type = ty; IsMutable = false })
    | PBinding(name, Some inner) ->
        scope.Add({ Name = name; Type = ty; IsMutable = false })
        bindPattern table scope diags inner ty
    | PTuple ps ->
        let elemTypes =
            match ty with
            | TyTuple ts when List.length ts = List.length ps -> ts
            | _ -> List.replicate ps.Length TyError
        List.iter2 (fun sp et -> bindPattern table scope diags sp et) ps elemTypes
    | PConstructor(head, args) ->
        // Resolve the union case's field types from the symbol table.
        let fieldTypes =
            match head.Segments with
            | [name] ->
                match table.TryFindOne name with
                | Some sym ->
                    match sym.Kind with
                    | DKUnionCase(parentId, uc) ->
                        let ctx = mkGenericCtx (unionGenericParamsFor table parentId)
                        uc.Fields |> List.map (fun f ->
                            match f with
                            | UFNamed(_, te, _) | UFPos(te, _) ->
                                Resolver.resolveType table ctx diags te)
                    | _ -> List.replicate args.Length TyError
                | None -> List.replicate args.Length TyError
            | _ -> List.replicate args.Length TyError
        let pairs =
            if List.length fieldTypes = List.length args
            then List.zip args fieldTypes
            else args |> List.map (fun a -> a, TyError)
        pairs |> List.iter (fun (sp, ft) -> bindPattern table scope diags sp ft)
    | POr alts ->
        // Walk the first alternative to put bindings into scope; walk
        // remaining alternatives into a dummy scope (same diagnostics,
        // no duplicate registrations).  T6 will enforce that all
        // alternatives bind the same names.
        match alts with
        | [] -> ()
        | first :: rest ->
            bindPattern table scope diags first ty
            for sp in rest do
                let dummy = Scope()
                bindPattern table dummy diags sp ty
    | PRange _ ->
        // Range pattern: no bindings produced.
        ()
    | PRecord(_, fields, _) ->
        let recFields =
            match ty with
            | TyUser(id, _) -> fieldsOfRecord table id
            | _ -> []
        for field in fields do
            match field with
            | RPFNamed(name, innerPat, _) ->
                let ft =
                    recFields |> List.tryFind (fun (n, _) -> n = name)
                    |> Option.map snd |> Option.defaultValue TyError
                bindPattern table scope diags innerPat ft
            | RPFShort(name, _) ->
                let ft =
                    recFields |> List.tryFind (fun (n, _) -> n = name)
                    |> Option.map snd |> Option.defaultValue TyError
                scope.Add({ Name = name; Type = ft; IsMutable = false })
    | PParen inner ->
        bindPattern table scope diags inner ty
    | PTypeTest(inner, te) ->
        // The pattern narrows the scrutinee to the tested type.
        let ctx = GenericContext()
        let narrowed = Resolver.resolveType table ctx diags te
        bindPattern table scope diags inner narrowed
    | PLiteral _ | PError ->
        ()

// ---------------------------------------------------------------------------
// Mutually recursive inference engine.
// ---------------------------------------------------------------------------

let rec inferExpr
        (scope: Scope)
        (table: SymbolTable)
        (sigs:  Map<string, ResolvedSignature>)
        (genericNames: string list)
        (returnType: Type)
        (diags: ResizeArray<Diagnostic>)
        (e:     Expr)
        : Type =

    let infer = inferExpr scope table sigs genericNames returnType diags

    /// Infer the type of an expression-or-block branch.
    let inferBranch (b: ExprOrBlock) : Type =
        match b with
        | EOBExpr ex   -> infer ex
        | EOBBlock blk -> checkBlock scope table sigs genericNames returnType diags blk

    /// Resolve a path in expression position.  Defined as a nested helper
    /// so it has access to `infer` (needed for DKVal.Init fallback).
    let resolvePath (path: ModulePath) (span: Span) : Type =
        match path.Segments with
        | [name] ->
            // 1. Local binding (parameter, val/var/let).
            match scope.TryFind name with
            | Some b -> b.Type
            | None ->
                // 2. Function in the package.
                match Map.tryFind name sigs with
                | Some s ->
                    let paramTypes = s.Params |> List.map (fun p -> p.Type)
                    TyFunction(paramTypes, s.Return, s.IsAsync)
                | None ->
                    // 3. Codegen builtin (println, panic, …).
                    match codegenBuiltinType name with
                    | Some t -> t
                    | None ->
                        // 4. Named package-level symbol.
                        match table.TryFindOne name with
                        | Some sym ->
                            match sym.Kind with
                            | DKConst cd ->
                                let ctx = mkGenericCtx genericNames
                                Resolver.resolveType table ctx diags cd.Type
                            | DKVal vd ->
                                match vd.Type with
                                | Some te ->
                                    let ctx = mkGenericCtx genericNames
                                    Resolver.resolveType table ctx diags te
                                | None ->
                                    // No annotation — infer from the init expression.
                                    infer vd.Init
                            | DKUnionCase(parentId, uc) ->
                                let parentGenerics = unionGenericParamsFor table parentId
                                let returnArgs = parentGenerics |> List.map TyVar
                                if uc.Fields.IsEmpty then
                                    TyUser(parentId, returnArgs)
                                else
                                    let ctx = mkGenericCtx parentGenerics
                                    let fieldTypes =
                                        uc.Fields |> List.map (fun f ->
                                            match f with
                                            | UFNamed(_, te, _) | UFPos(te, _) ->
                                                Resolver.resolveType table ctx diags te)
                                    TyFunction(fieldTypes, TyUser(parentId, returnArgs), false)
                            | DKEnumCase(parentId, _) ->
                                // Enum cases carry no fields; they are plain values.
                                TyUser(parentId, [])
                            | _ ->
                                // Type-level symbol or other non-value — no error to
                                // avoid noise on, e.g., a union name used as a
                                // constructor head (the emitter handles those).
                                TyError
                        | None ->
                            err diags "T0020"
                                (sprintf "unknown name '%s'" name)
                                span
                            TyError
        | _ ->
            // Multi-segment expression path. Cross-package resolution is T7+.
            TyError

    match e.Kind with
    | ELiteral lit       -> typeOfLiteral lit
    | EPath path         -> resolvePath path e.Span
    | EParen inner       -> infer inner
    | ETuple xs          -> TyTuple (xs |> List.map infer)
    | EList xs ->
        let elemTypes = xs |> List.map infer
        let elem =
            match elemTypes with
            | []      -> TyError
            | t :: ts ->
                if List.forall (Type.equiv t) ts then t
                else
                    err diags "T0041"
                        "list literal elements must share a type" e.Span
                    t
        TySlice elem

    | EPrefix(op, inner) ->
        let innerT = infer inner
        inferPrefix diags op innerT e.Span

    | EBinop(op, l, r) ->
        let lT = infer l
        let rT = infer r
        inferBinop table diags op lT rT e.Span

    | ECall(fn, args) ->
        let fnT = infer fn
        let argTypes = args |> List.map (function
                                          | CAPositional e -> infer e
                                          | CANamed(_, e, _) -> infer e)
        let directSig =
            match fn.Kind with
            | EPath { Segments = [name] } ->
                match Map.tryFind name sigs with
                | Some s -> Some s
                | None ->
                    Map.tryFind (name + "/" + string args.Length) sigs
            | _ -> None
        let isAddressableLValue (e: Expr) : bool =
            match e.Kind with
            | EPath { Segments = [_] } -> true
            | EIndex (_, [_]) -> true
            | EMember (_, _) -> true
            | _ -> false
        let validateModeArg (p: ResolvedParam) (arg: CallArg) =
            match p.Mode with
            | PMOut | PMInout ->
                let payload =
                    match arg with
                    | CAPositional e -> e
                    | CANamed (_, e, _) -> e
                if not (isAddressableLValue payload) then
                    err diags "T0085"
                        (sprintf "argument to %s parameter '%s' must be a mutable l-value (variable, array element, or field)"
                            (match p.Mode with PMOut -> "out" | _ -> "inout") p.Name)
                        payload.Span
            | _ -> ()
        match directSig with
        | Some s ->
            if List.length s.Params <> List.length args then
                err diags "T0042"
                    (sprintf "expected %d argument(s), got %d"
                        (List.length s.Params) (List.length args))
                    e.Span
            else
                List.iter2 validateModeArg s.Params args
                List.iter2 (fun (p: ResolvedParam) a ->
                    if not (Type.equiv p.Type a) then
                        err diags "T0043"
                            (sprintf "argument type %s does not match parameter type %s"
                                (Type.render a) (Type.render p.Type))
                            e.Span)
                    s.Params argTypes
            s.Return
        | None ->
        match fnT with
        | TyFunction(paramTypes, ret, _) ->
            if List.length paramTypes <> List.length argTypes then
                err diags "T0042"
                    (sprintf "expected %d argument(s), got %d"
                        (List.length paramTypes) (List.length argTypes))
                    e.Span
            else
                List.iter2 (fun p a ->
                    if not (Type.equiv p a) then
                        err diags "T0043"
                            (sprintf "argument type %s does not match parameter type %s"
                                (Type.render a) (Type.render p))
                            e.Span)
                    paramTypes argTypes
            ret
        | TyError -> TyError
        | other ->
            err diags "T0044"
                (sprintf "called value of non-function type %s" (Type.render other))
                e.Span
            TyError

    | EMember(receiver, name) ->
        let rT = infer receiver
        inferMember table diags rT name e.Span

    | EPropagate inner ->
        // `e?` — check the inner expression, but the Ok-projection type
        // is deferred until the Result type model is added to TyResult.
        let _ = infer inner
        TyError

    | EAwait inner | ESpawn inner | EOld inner ->
        infer inner

    | ESelf -> TySelf

    | EResult ->
        // Resolved by the contract elaborator.
        TyError

    // ----- control-flow expressions -----

    | EIf(cond, thenBranch, elseOpt, _) ->
        let condT = infer cond
        if not (Type.equiv condT (TyPrim PtBool)) then
            err diags "T0067"
                (sprintf "if-condition must be Bool (got %s)" (Type.render condT))
                e.Span
        let thenT = inferBranch thenBranch
        match elseOpt with
        | None -> TyPrim PtUnit
        | Some elseBranch ->
            let elseT = inferBranch elseBranch
            // Never propagates; if both are Never, return Never.
            // When one branch is Unit the value is discarded; the whole
            // expression is Unit (covers statement-position if-else).
            if thenT = TyPrim PtNever then elseT
            elif elseT = TyPrim PtNever then thenT
            elif Type.equiv thenT elseT then thenT
            elif thenT = TyPrim PtUnit || elseT = TyPrim PtUnit then
                TyPrim PtUnit
            else
                err diags "T0068"
                    (sprintf "if-expression branches have incompatible types (%s vs %s)"
                        (Type.render thenT) (Type.render elseT))
                    e.Span
                thenT

    | EMatch(scrutinee, arms) ->
        let scrutT = infer scrutinee
        if arms.IsEmpty then TyPrim PtNever
        else
            let armTypes =
                arms |> List.map (fun arm ->
                    scope.Push()
                    bindPattern table scope diags arm.Pattern scrutT
                    arm.Guard |> Option.iter (fun g ->
                        let gT = infer g
                        if not (Type.equiv gT (TyPrim PtBool)) then
                            err diags "T0067"
                                (sprintf "match guard must be Bool (got %s)" (Type.render gT))
                                arm.Span)
                    let bodyT = inferBranch arm.Body
                    scope.Pop()
                    bodyT)
            // The result type is the first non-Never arm type; all non-Never
            // arm types must agree.
            let nonNever = armTypes |> List.filter (fun t -> t <> TyPrim PtNever)
            match nonNever with
            | [] -> TyPrim PtNever
            | first :: rest ->
                rest |> List.iter (fun t ->
                    if not (Type.equiv t first) then
                        err diags "T0068"
                            (sprintf "match arms have incompatible types (%s vs %s)"
                                (Type.render first) (Type.render t))
                            e.Span)
                first

    | EBlock blk | EUnsafe blk ->
        checkBlock scope table sigs genericNames returnType diags blk

    // ----- lambdas -----

    | ELambda(params', body) ->
        let ctx = mkGenericCtx genericNames
        let paramTypes =
            params' |> List.map (fun p ->
                match p.Type with
                | Some te -> Resolver.resolveType table ctx diags te
                | None    -> TyError)   // unannotated param — codegen infers from context
        scope.Push()
        List.iter2 (fun (p: LambdaParam) pt ->
            scope.Add({ Name = p.Name; Type = pt; IsMutable = false }))
            params' paramTypes
        let bodyT = checkBlock scope table sigs genericNames returnType diags body
        scope.Pop()
        TyFunction(paramTypes, bodyT, false)

    // ----- indexing -----

    | EIndex(receiver, indices) ->
        let receiverT = infer receiver
        let idxTs = indices |> List.map infer
        let checkIdxsAre (expectedT: Type) =
            List.iter2 (fun (idx: Expr) idxT ->
                if not (Type.equiv idxT expectedT) then
                    err diags "T0069"
                        (sprintf "index must be %s (got %s)" (Type.render expectedT) (Type.render idxT))
                        idx.Span) indices idxTs
        match receiverT with
        | TyArray(_, elem) | TySlice elem ->
            checkIdxsAre (TyPrim PtInt)
            elem
        | TyPrim PtString ->
            checkIdxsAre (TyPrim PtInt)
            TyPrim PtChar
        // 1-arg generic types (List[T], Set[T], etc.) index by Int.
        // 2-arg generic types (Map[K,V]) index by K (firstArg) and return V (secondArg).
        // Full operator-based dispatch is deferred to T6+.
        | TyUser(_, [elem]) ->
            checkIdxsAre (TyPrim PtInt)
            elem
        | TyUser(_, keyT :: valT :: _) ->
            checkIdxsAre keyT
            valT
        | TyUser(_, [])    -> TyError
        | TyError | TyVar _ -> TyError
        | other ->
            err diags "T0069"
                (sprintf "cannot index into type %s" (Type.render other))
                e.Span
            TyError

    // ----- ranges -----

    | ERange rb ->
        let elemType =
            match rb with
            | RBClosed(lo, hi) | RBHalfOpen(lo, hi) ->
                let loT = infer lo
                let hiT = infer hi
                if Type.equiv loT hiT then loT
                else
                    err diags "T0068"
                        (sprintf "range bounds have incompatible types (%s vs %s)"
                            (Type.render loT) (Type.render hiT))
                        e.Span
                    TyError
            | RBLowerOpen hi -> infer hi
            | RBUpperOpen lo -> infer lo
        TyRange elemType

    // ----- interpolated strings -----

    | EInterpolated segments ->
        for seg in segments do
            match seg with
            | ISExpr ex -> infer ex |> ignore
            | ISText _  -> ()
        TyPrim PtString

    // ----- generic instantiation -----

    | ETypeApp(fn, _typeArgs) ->
        // Pass through to get the underlying function type; codegen owns
        // actual monomorphisation.
        infer fn

    // ----- assignment in expression position -----

    | EAssign(target, _, value) ->
        let targetType = infer target
        let valueType  = infer value
        if not (Type.equiv targetType valueType) then
            err diags "T0063"
                (sprintf "assigned value of type %s does not match target of type %s"
                    (Type.render valueType) (Type.render targetType))
                e.Span
        TyPrim PtUnit

    // ----- quantifier atoms (proof sub-language) -----

    | EForall(binders, whereExpr, body) | EExists(binders, whereExpr, body) ->
        scope.Push()
        for b in binders do
            let ctx = GenericContext()
            let bt = Resolver.resolveType table ctx diags b.Type
            scope.Add({ Name = b.Name; Type = bt; IsMutable = false })
        whereExpr |> Option.iter (infer >> ignore)
        let bodyT = infer body
        if not (Type.equiv bodyT (TyPrim PtBool)) then
            err diags "T0067"
                (sprintf "quantifier body must be Bool (got %s)" (Type.render bodyT))
                e.Span
        scope.Pop()
        TyPrim PtBool

    // ----- try expression -----

    | ETry inner ->
        // `try e` wraps the result in a Result-like type. Until the
        // Result type is modelled in TyResult, return TyError (suppresses
        // cascading diagnostics) but still check the inner expression.
        let _ = infer inner
        TyError

    | EError -> TyError

and checkStatement
        (scope: Scope)
        (table: SymbolTable)
        (sigs:  Map<string, ResolvedSignature>)
        (genericNames: string list)
        (returnType: Type)
        (diags: ResizeArray<Diagnostic>)
        (stmt:  Statement)
        : unit =

    let inferE = inferExpr scope table sigs genericNames returnType diags

    match stmt.Kind with
    | SLocal (LBVal(pat, declType, init)) ->
        let initType = inferE init
        let bindType =
            match declType with
            | Some te ->
                let ctx = mkGenericCtx genericNames
                let declT = Resolver.resolveType table ctx diags te
                if not (Type.equiv declT initType) then
                    err diags "T0060"
                        (sprintf "val binding declared as %s but initialiser has type %s"
                            (Type.render declT) (Type.render initType))
                        stmt.Span
                declT
            | None -> initType
        bindPattern table scope diags pat bindType

    | SLocal (LBVar(name, declType, init)) ->
        let initType =
            match init with
            | Some e -> inferE e
            | None -> TyError
        let bindType =
            match declType with
            | Some te ->
                let ctx = mkGenericCtx genericNames
                let declT = Resolver.resolveType table ctx diags te
                if init.IsSome && not (Type.equiv declT initType) then
                    err diags "T0061"
                        (sprintf "var binding declared as %s but initialiser has type %s"
                            (Type.render declT) (Type.render initType))
                        stmt.Span
                declT
            | None -> initType
        scope.Add({ Name = name; Type = bindType; IsMutable = true })

    | SLocal (LBLet(name, declType, init)) ->
        let initType = inferE init
        let bindType =
            match declType with
            | Some te ->
                let ctx = mkGenericCtx genericNames
                let declT = Resolver.resolveType table ctx diags te
                if not (Type.equiv declT initType) then
                    err diags "T0062"
                        (sprintf "let binding declared as %s but initialiser has type %s"
                            (Type.render declT) (Type.render initType))
                        stmt.Span
                declT
            | None -> initType
        scope.Add({ Name = name; Type = bindType; IsMutable = false })

    | SAssign(target, op, value) ->
        let _ = op  // compound-op semantics (+=, -=, …) deferred to T6+
        let targetType = inferE target
        let valueType  = inferE value
        if not (Type.equiv targetType valueType) then
            err diags "T0063"
                (sprintf "assigned value of type %s does not match target of type %s"
                    (Type.render valueType) (Type.render targetType))
                stmt.Span

    | SReturn None ->
        if not (Type.equiv returnType (TyPrim PtUnit)) then
            err diags "T0064"
                (sprintf "return without value but enclosing function returns %s"
                    (Type.render returnType))
                stmt.Span

    | SReturn (Some e) ->
        let t = inferE e
        if t <> TyPrim PtNever && not (Type.equiv t returnType) then
            err diags "T0065"
                (sprintf "returned value of type %s does not match declared return type %s"
                    (Type.render t) (Type.render returnType))
                stmt.Span

    | SThrow e ->
        let _ = inferE e
        ()

    | SBreak _ | SContinue _ -> ()

    | SInvariant e ->
        let _ = inferE e
        ()

    | SExpr e ->
        let _ = inferE e
        ()

    | SDefer blk
    | SScope(_, blk)
    | SLoop(_, blk) ->
        checkBlock scope table sigs genericNames returnType diags blk |> ignore

    | SFor(_, pat, iter, body) ->
        let iterType = inferE iter
        let elemType =
            match iterType with
            | TySlice e   -> e
            | TyArray(_, e) -> e
            | TyRange e   -> e
            | _ -> TyError
        scope.Push()
        bindPattern table scope diags pat elemType
        checkBlock scope table sigs genericNames returnType diags body |> ignore
        scope.Pop()

    | SWhile(_, cond, body) ->
        let condT = inferE cond
        if not (Type.equiv condT (TyPrim PtBool)) then
            err diags "T0066"
                (sprintf "while-condition must be Bool (got %s)"
                    (Type.render condT))
                stmt.Span
        checkBlock scope table sigs genericNames returnType diags body |> ignore

    | STry(body, catches) ->
        checkBlock scope table sigs genericNames returnType diags body |> ignore
        for c in catches do
            scope.Push()
            match c.Bind with
            | Some name ->
                scope.Add({ Name = name; Type = TyError; IsMutable = false })
            | None -> ()
            checkBlock scope table sigs genericNames returnType diags c.Body |> ignore
            scope.Pop()

    | SItem _ ->
        // Nested item declarations — deferred to T6+.
        ()

    | SRule (_, _) ->
        // Stub-builder DSL — deferred to T6+ with @stubbable.
        ()

and checkBlock
        (scope: Scope)
        (table: SymbolTable)
        (sigs:  Map<string, ResolvedSignature>)
        (genericNames: string list)
        (returnType: Type)
        (diags: ResizeArray<Diagnostic>)
        (blk:   Block)
        : Type =
    scope.Push()
    let mutable lastExprType : Type = TyPrim PtUnit
    for stmt in blk.Statements do
        match stmt.Kind with
        | SExpr e ->
            lastExprType <- inferExpr scope table sigs genericNames returnType diags e
        | SReturn _ | SThrow _ | SBreak _ | SContinue _ ->
            checkStatement scope table sigs genericNames returnType diags stmt
            lastExprType <- TyPrim PtNever
        | STry _ ->
            // try-catch in expression/block position: value type is deferred to T6+.
            // Return TyError so surrounding SReturn / val-binding do not emit
            // spurious T0065 / T0060 mismatches.
            checkStatement scope table sigs genericNames returnType diags stmt
            lastExprType <- TyError
        | _ ->
            checkStatement scope table sigs genericNames returnType diags stmt
            lastExprType <- TyPrim PtUnit
    scope.Pop()
    lastExprType

// ---------------------------------------------------------------------------
// Definite-assignment analysis for `out` parameters.
//
// Each `out` parameter must be assigned along every normal-completion
// path through the function body.  Loops are treated weakly (their
// bodies may not run).
// ---------------------------------------------------------------------------

type private DASet = Set<string>

let private outParamNames (sg: ResolvedSignature) : Set<string> =
    sg.Params
    |> List.choose (fun p ->
        if p.Mode = PMOut then Some p.Name else None)
    |> Set.ofList

let private outArgsAssigned
        (sigs: Map<string, ResolvedSignature>)
        (call: Expr) : Set<string> =
    match call.Kind with
    | ECall (fn, args) ->
        let sigOpt =
            match fn.Kind with
            | EPath { Segments = [name] } ->
                match Map.tryFind name sigs with
                | Some s -> Some s
                | None ->
                    Map.tryFind (name + "/" + string args.Length) sigs
            | _ -> None
        match sigOpt with
        | None -> Set.empty
        | Some sg ->
            List.zip sg.Params args
            |> List.choose (fun (p, a) ->
                if p.Mode = PMOut then
                    let payload =
                        match a with
                        | CAPositional e -> e
                        | CANamed (_, e, _) -> e
                    match payload.Kind with
                    | EPath { Segments = [n] } -> Some n
                    | _ -> None
                else None)
            |> Set.ofList
    | _ -> Set.empty

let rec private daBlock
        (sigs:    Map<string, ResolvedSignature>)
        (outs:    Set<string>)
        (diags:   ResizeArray<Diagnostic>)
        (initial: DASet)
        (blk:     Block) : DASet =
    let mutable cur = initial
    for s in blk.Statements do
        cur <- daStatement sigs outs diags cur s
    cur

and private daStatement
        (sigs:  Map<string, ResolvedSignature>)
        (outs:  Set<string>)
        (diags: ResizeArray<Diagnostic>)
        (cur:   DASet)
        (s:     Statement) : DASet =
    match s.Kind with
    | SAssign (target, _, value) ->
        let cur' = daExpr sigs outs diags cur value
        match target.Kind with
        | EPath { Segments = [name] } when Set.contains name outs ->
            Set.add name cur'
        | _ -> cur'
    | SLocal (LBVal (_, _, init)) ->
        daExpr sigs outs diags cur init
    | SLocal (LBLet (_, _, init)) ->
        daExpr sigs outs diags cur init
    | SLocal (LBVar (_, _, Some init)) ->
        daExpr sigs outs diags cur init
    | SLocal (LBVar (_, _, None)) ->
        cur
    | SExpr e ->
        daExpr sigs outs diags cur e
    | SReturn rOpt ->
        let cur' =
            match rOpt with
            | Some e -> daExpr sigs outs diags cur e
            | None   -> cur
        let missing = Set.difference outs cur'
        if not missing.IsEmpty then
            err diags "T0086"
                (sprintf "out parameter(s) not assigned before return: %s"
                    (missing |> Set.toList |> String.concat ", "))
                s.Span
        outs  // pretend everything is assigned on dead paths past a return
    | SWhile (_, cond, body) ->
        let afterCond = daExpr sigs outs diags cur cond
        let _ = daBlock sigs outs diags afterCond body
        afterCond
    | SLoop (_, body) ->
        let _ = daBlock sigs outs diags cur body
        cur
    | SFor (_, _, iter, body) ->
        let afterIter = daExpr sigs outs diags cur iter
        let _ = daBlock sigs outs diags afterIter body
        afterIter
    | SBreak _ | SContinue _ -> cur
    | SDefer body ->
        daBlock sigs outs diags cur body
    | _ -> cur

and private daExpr
        (sigs:  Map<string, ResolvedSignature>)
        (outs:  Set<string>)
        (diags: ResizeArray<Diagnostic>)
        (cur:   DASet)
        (e:     Expr) : DASet =
    match e.Kind with
    | ECall (_, args) ->
        let cur' =
            args
            |> List.fold (fun s a ->
                match a with
                | CAPositional ex
                | CANamed (_, ex, _) -> daExpr sigs outs diags s ex)
                cur
        Set.union cur' (Set.intersect outs (outArgsAssigned sigs e))
    | EBinop (_, l, r) ->
        let cur' = daExpr sigs outs diags cur l
        daExpr sigs outs diags cur' r
    | EPrefix (_, x) -> daExpr sigs outs diags cur x
    | EParen x -> daExpr sigs outs diags cur x
    | EIf (cond, thenBranch, elseOpt, _) ->
        let afterCond = daExpr sigs outs diags cur cond
        let daBranch (b: ExprOrBlock) =
            match b with
            | EOBExpr  e -> daExpr sigs outs diags afterCond e
            | EOBBlock blk -> daBlock sigs outs diags afterCond blk
        let afterThen = daBranch thenBranch
        let afterElse =
            match elseOpt with
            | Some b -> daBranch b
            | None   -> afterCond
        Set.intersect afterThen afterElse
    | EMatch (scrutinee, arms) ->
        let afterScrut = daExpr sigs outs diags cur scrutinee
        let armEnds =
            arms |> List.map (fun arm ->
                match arm.Body with
                | EOBExpr e   -> daExpr sigs outs diags afterScrut e
                | EOBBlock b  -> daBlock sigs outs diags afterScrut b)
        match armEnds with
        | []           -> afterScrut
        | first :: rest -> rest |> List.fold Set.intersect first
    | EBlock blk ->
        daBlock sigs outs diags cur blk
    | _ -> cur

// ---------------------------------------------------------------------------
// Function body entry point.
// ---------------------------------------------------------------------------

/// Check a function declaration's body against its resolved signature.
let checkFunctionBody
        (table: SymbolTable)
        (sigs:  Map<string, ResolvedSignature>)
        (diags: ResizeArray<Diagnostic>)
        (fn:    FunctionDecl)
        (sig':  ResolvedSignature)
        : unit =

    // @externTarget functions have a user-supplied placeholder body;
    // skip return-type checking.
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
        let bodyType = inferExpr scope table sigs sig'.Generics sig'.Return diags e
        if bodyType <> TyPrim PtNever
           && not (Type.equiv bodyType sig'.Return) then
            err diags "T0070"
                (sprintf "function body has type %s but declared return type is %s"
                    (Type.render bodyType) (Type.render sig'.Return))
                fn.Span
    | Some (FBBlock blk) ->
        let bodyType =
            checkBlock scope table sigs sig'.Generics sig'.Return diags blk
        if bodyType <> TyPrim PtUnit
           && bodyType <> TyPrim PtNever
           && not (Type.equiv bodyType sig'.Return) then
            err diags "T0070"
                (sprintf "function body trailing expression has type %s but declared return type is %s"
                    (Type.render bodyType) (Type.render sig'.Return))
                fn.Span
        let outs = outParamNames sig'
        if not outs.IsEmpty then
            let finalDA = daBlock sigs outs diags Set.empty blk
            let missing = Set.difference outs finalDA
            if not missing.IsEmpty then
                err diags "T0086"
                    (sprintf "out parameter(s) not assigned along fall-through exit: %s"
                        (missing |> Set.toList |> String.concat ", "))
                    fn.Span
