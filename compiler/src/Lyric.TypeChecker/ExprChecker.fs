/// Bottom-up type inference for expressions.
///
/// `inferExpr` consumes a parser AST `Expr` and returns the resolved
/// `Type`. Unsupported or recovery cases return `TyError`, which the
/// equivalence rules in `Type.equiv` treat as compatible with anything
/// to suppress cascading diagnostics.
///
/// T4 implements: literals, single-segment paths (scope + global),
/// parens, tuples, lists, prefix operators, binary operators
/// (arithmetic + comparison + logical), function calls, member
/// access, and the contract atoms `self` / `result` / `old(_)`.
/// Lambdas, full control-flow expressions (`if` / `match`), block
/// expressions, async / spawn semantics, and `?` propagation are
/// deferred to T5+.
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
    | LInt(_, NoIntSuffix) -> TyPrim PtInt        // default
    | LInt(_, I8)  -> TyPrim PtByte               // (signed 8-bit; closest in Lyric)
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
// Path resolution at expression-level.
// ---------------------------------------------------------------------------

/// Bootstrap-grade closed list of names handled directly by the
/// codegen as builtins (println, panic, expect, assert, host parse
/// helpers, …).  Returning a function type from `resolvePath` keeps
/// the type checker silent on these names; the codegen owns the
/// dispatch.
let private codegenBuiltinType (name: string) : Type option =
    match name with
    | "println" ->
        // `println` is polymorphic in its argument: codegen routes
        // string args through Console.Println(string) and everything
        // else through Console.PrintlnAny(obj) with auto-boxing.  The
        // type checker mirrors that by accepting any single argument.
        Some (TyFunction([TyError], TyPrim PtUnit, false))
    | "toString" ->
        // Polymorphic in its argument like `println`; codegen routes
        // through Console.ToStr(obj) with auto-boxing for value types.
        Some (TyFunction([TyError], TyPrim PtString, false))
    // `format1`/`format2`/`format3`/`format4`/`format5`/`format6`
    // are arity-specialised String.Format wrappers.  Lyric has no
    // varargs, so each arity is a separate name; codegen routes to
    // Format.Of1..Of6.
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
        // Polymorphic in its return — codegen reads `ctx.ExpectedType`
        // to pick the actual CLR type and emits the right zero-init
        // (`Initobj` for value types, `Ldnull` for refs).  The
        // type checker accepts the call; downstream call sites
        // (val ascription, byref out-arg pre-fill) push their
        // expected type into `ExpectedType`.
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

    // File I/O host helpers.
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

let private resolvePath
        (scope: Scope)
        (table: SymbolTable)
        (sigs:  Map<string, ResolvedSignature>)
        (diags: ResizeArray<Diagnostic>)
        (path:  ModulePath)
        (span:  Span)
        : Type =
    match path.Segments with
    | [name] ->
        // 1. Local binding (parameter or val/var/let).
        match scope.TryFind(name) with
        | Some b -> b.Type
        | None ->
            // 2. Function in the package.
            match Map.tryFind name sigs with
            | Some s ->
                let paramTypes = s.Params |> List.map (fun p -> p.Type)
                TyFunction(paramTypes, s.Return, s.IsAsync)
            | None ->
                // 3. Codegen builtin (println, panic, host-parse, …).
                match codegenBuiltinType name with
                | Some t -> t
                | None ->
                    // 4. Other named symbol (for now, return TyError;
                    // T5+ resolves vals / consts / union ctors).
                    match table.TryFindOne name with
                    | Some _ -> TyError
                    | None ->
                        err diags "T0020"
                            (sprintf "unknown name '%s'" name)
                            span
                        TyError
    | _ ->
        // Multi-segment expression path (e.g. `Module.func`). Cross-
        // package resolution is T7+.
        TyError

// ---------------------------------------------------------------------------
// Operator semantics.
// ---------------------------------------------------------------------------

let private isNumeric (t: Type) : bool =
    match t with
    | TyPrim PtByte | TyPrim PtInt | TyPrim PtLong
    | TyPrim PtUInt | TyPrim PtULong | TyPrim PtNat
    | TyPrim PtFloat | TyPrim PtDouble -> true
    | TyError -> true   // poisoning
    | _ -> false

let private isOrdered (t: Type) : bool =
    isNumeric t
    || (match t with
        | TyPrim PtChar | TyPrim PtString -> true
        | _ -> false)

/// Return true if `t` is a distinct type whose declaration includes
/// the given `derives` marker (e.g. "Add", "Sub", "Compare").  Returns
/// false for non-distinct types.
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
    | BAdd -> "Add"
    | BSub -> "Sub"
    | BMul -> "Mul"
    | BDiv -> "Div"
    | BMod -> "Mod"
    | _    -> ""

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
        // String + anything → String concat (codegen handles the
        // boxing + ToString conversion via Console.PrintlnAny).
        // Restricted to BAdd; the other arithmetic operators stay
        // numeric-only.
        match op, lhs with
        | BAdd, TyPrim PtString -> TyPrim PtString
        | _ ->
            let lhsOk = isNumeric lhs || hasDerive table (arithMarker op) lhs
            if not lhsOk then
                err diags "T0030"
                    (sprintf "left operand of arithmetic operator is not numeric (got %s)"
                        (Type.render lhs))
                    span
            if not (Type.equiv lhs rhs) then
                err diags "T0031"
                    (sprintf "arithmetic operands must have the same type (got %s and %s)"
                        (Type.render lhs) (Type.render rhs))
                    span
            lhs
    | BEq | BNeq ->
        if not (Type.equiv lhs rhs) then
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
        // `a ?? b`: `a` should be a nullable T; result is T.
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
        // Reserved prefix operator — return the inner type for now.
        inner

// ---------------------------------------------------------------------------
// Member access.
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

/// Built-in member types that the codegen lowers via direct
/// reflection / opcode (not via a Lyric-defined member).  Each
/// entry maps `(receiver, member-name) -> result-type`.
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
            // Could still be a method or a union case access — for
            // now, return TyError without diagnostic to avoid noise.
            TyError
    | TyError -> TyError
    | other ->
        match builtinMember other name with
        | Some t -> t
        | None ->
            // Method-style calls on BCL types (`s.trim()`, `s.toUpper()`,
            // …) are dispatched at codegen via PascalCase reflection.
            // The type checker can't yet enumerate every BCL method, so
            // it returns `TyError` *without* a diagnostic — letting
            // codegen surface a precise error if the call is bogus,
            // while not blocking valid programs that use BCL methods
            // we haven't yet enumerated here.
            TyError

// ---------------------------------------------------------------------------
// Top-level inference.
// ---------------------------------------------------------------------------

let rec inferExpr
        (scope: Scope)
        (table: SymbolTable)
        (sigs:  Map<string, ResolvedSignature>)
        (diags: ResizeArray<Diagnostic>)
        (e:     Expr)
        : Type =

    let infer = inferExpr scope table sigs diags

    match e.Kind with
    | ELiteral lit       -> typeOfLiteral lit
    | EPath path         -> resolvePath scope table sigs diags path e.Span
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
        // Direct user calls bypass `TyFunction` so the param-mode info
        // from the resolved signature flows in (out/inout args have
        // an l-value rule we want to enforce; `TyFunction` drops mode
        // information).
        let directSig =
            match fn.Kind with
            | EPath { Segments = [name] } ->
                match Map.tryFind name sigs with
                | Some s -> Some s
                | None ->
                    Map.tryFind (name + "/" + string args.Length) sigs
            | _ -> None
        // Out / inout args must be addressable l-values — a direct
        // local / parameter reference.  This guards against passing
        // expression results, literals, etc. that the codegen can't
        // address.  Bug if T0085 fires on a syntactically-valid
        // mutable target the codegen actually accepts (rare).
        let isAddressableLValue (e: Expr) : bool =
            match e.Kind with
            // Named local / param.
            | EPath { Segments = [_] } -> true
            // Array element `xs[i]` (single index).
            | EIndex (_, [_]) -> true
            // Record / distinct-type field `r.f`.
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
        // `e?` propagates an error/null. The result is the inner
        // type's "value" projection — for T4 we return TyError.
        let _ = infer inner
        TyError

    | EAwait inner | ESpawn inner | EOld inner ->
        infer inner

    | ESelf -> TySelf

    | EResult ->
        // Resolved by the contract elaborator; for now, TyError so
        // surrounding expressions don't cascade.
        TyError

    | ELambda _ | EIf _ | EMatch _ | EBlock _
    | ETry _ | EForall _ | EExists _
    | EAssign _ | ERange _ | ETypeApp _ | EIndex _
    | EInterpolated _ -> TyError

    | EError -> TyError
