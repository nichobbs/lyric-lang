/// IL generation for expression and statement bodies.
///
/// E3 introduces a `FunctionCtx` that carries the per-function IL
/// state: the scope stack of local variables, the loop-label stack
/// for break/continue, and the enclosing return type so `return` can
/// validate at IL-time. `emitExpr` / `emitStatement` / `emitBlock`
/// all take this context now.
module Lyric.Emitter.Codegen

open System
open System.Collections.Generic
open System.Reflection
open System.Reflection.Emit
open Lyric.Lexer
open Lyric.Parser.Ast

type private ClrType = System.Type

/// A single loop frame — break exits, continue rejoins the head.
type LoopFrame =
    { BreakLabel:    Label
      ContinueLabel: Label }

/// Per-function emit context. Mutable on purpose: F# expression
/// emission threads through a long mutual-recursion graph and a
/// record makes the call sites unreadable.
type FunctionCtx =
    { IL:         ILGenerator
      ReturnType: ClrType
      Scopes:     Stack<Dictionary<string, LocalBuilder>>
      Loops:      Stack<LoopFrame>
      /// Parameters by name → (CLR-arg-index, declared CLR type).
      Params:     Dictionary<string, int * ClrType>
      /// Same-package functions visible at codegen time. E4 only
      /// resolves single-segment calls; cross-package linking is
      /// M1.4 work.
      Funcs:      Dictionary<string, MethodBuilder>
      /// Same-package records visible at codegen time. E5 supports
      /// constructor calls and field reads; mutation via `with`
      /// lands in E5 polish.
      Records:    Lyric.Emitter.Records.RecordTable }

module FunctionCtx =

    let make
            (il: ILGenerator)
            (returnType: ClrType)
            (paramList: (string * ClrType) list)
            (funcs: Dictionary<string, MethodBuilder>)
            (records: Lyric.Emitter.Records.RecordTable) : FunctionCtx =
        let s = Stack<Dictionary<string, LocalBuilder>>()
        s.Push(Dictionary())
        let p = Dictionary<string, int * ClrType>()
        paramList
        |> List.iteri (fun i (name, ty) -> p.[name] <- (i, ty))
        { IL         = il
          ReturnType = returnType
          Scopes     = s
          Loops      = Stack()
          Params     = p
          Funcs      = funcs
          Records    = records }

    let pushScope (ctx: FunctionCtx) : unit =
        ctx.Scopes.Push(Dictionary())

    let popScope (ctx: FunctionCtx) : unit =
        ctx.Scopes.Pop() |> ignore

    let defineLocal (ctx: FunctionCtx) (name: string) (ty: ClrType) : LocalBuilder =
        let lb = ctx.IL.DeclareLocal(ty)
        let frame = ctx.Scopes.Peek()
        frame.[name] <- lb
        lb

    let tryLookup (ctx: FunctionCtx) (name: string) : LocalBuilder option =
        let mutable found : LocalBuilder option = None
        let arr = ctx.Scopes.ToArray()  // top-down
        let mutable i = 0
        while found.IsNone && i < arr.Length do
            match arr.[i].TryGetValue name with
            | true, lb -> found <- Some lb
            | _        -> ()
            i <- i + 1
        found

    let pushLoop (ctx: FunctionCtx) (frame: LoopFrame) : unit =
        ctx.Loops.Push frame

    let popLoop (ctx: FunctionCtx) : unit =
        ctx.Loops.Pop() |> ignore

    let currentLoop (ctx: FunctionCtx) : LoopFrame option =
        if ctx.Loops.Count = 0 then None else Some (ctx.Loops.Peek())

// ---------------------------------------------------------------------------
// Stdlib bindings.
// ---------------------------------------------------------------------------

let private printlnString : Lazy<MethodInfo> =
    lazy (
        let consoleTy = typeof<Lyric.Stdlib.Console>
        let mi = consoleTy.GetMethod("Println", [| typeof<string> |])
        match Option.ofObj mi with
        | Some m -> m
        | None   -> failwith "Lyric.Stdlib.Console::Println(string) not found")

let private printlnAny : Lazy<MethodInfo> =
    lazy (
        let consoleTy = typeof<Lyric.Stdlib.Console>
        let mi = consoleTy.GetMethod("PrintlnAny", [| typeof<obj> |])
        match Option.ofObj mi with
        | Some m -> m
        | None   -> failwith "Lyric.Stdlib.Console::PrintlnAny(object) not found")

// ---------------------------------------------------------------------------
// CLR-type predicates used by the binop emitter.
// ---------------------------------------------------------------------------

let private isFloatClr (t: ClrType) : bool =
    t = typeof<single> || t = typeof<double>

let private isUnsignedClr (t: ClrType) : bool =
    t = typeof<byte> || t = typeof<uint16>
    || t = typeof<uint32> || t = typeof<uint64>

// ---------------------------------------------------------------------------
// Literal helpers.
// ---------------------------------------------------------------------------

let private emitLdcI4 (il: ILGenerator) (n: int) : unit =
    match n with
    | -1 -> il.Emit(OpCodes.Ldc_I4_M1)
    | 0  -> il.Emit(OpCodes.Ldc_I4_0)
    | 1  -> il.Emit(OpCodes.Ldc_I4_1)
    | 2  -> il.Emit(OpCodes.Ldc_I4_2)
    | 3  -> il.Emit(OpCodes.Ldc_I4_3)
    | 4  -> il.Emit(OpCodes.Ldc_I4_4)
    | 5  -> il.Emit(OpCodes.Ldc_I4_5)
    | 6  -> il.Emit(OpCodes.Ldc_I4_6)
    | 7  -> il.Emit(OpCodes.Ldc_I4_7)
    | 8  -> il.Emit(OpCodes.Ldc_I4_8)
    | n when n >= -128 && n <= 127 -> il.Emit(OpCodes.Ldc_I4_S, sbyte n)
    | _  -> il.Emit(OpCodes.Ldc_I4, n)

let private intLiteralType (suffix: IntSuffix) : ClrType =
    match suffix with
    | NoIntSuffix | I32 | I16 | I8 -> typeof<int32>
    | I64                          -> typeof<int64>
    | U8                           -> typeof<byte>
    | U16                          -> typeof<uint16>
    | U32                          -> typeof<uint32>
    | U64                          -> typeof<uint64>

let private floatLiteralType (suffix: FloatSuffix) : ClrType =
    match suffix with
    | NoFloatSuffix | F64 -> typeof<double>
    | F32                 -> typeof<single>

let private emitIntLiteral (il: ILGenerator) (value: uint64) (suffix: IntSuffix) : ClrType =
    let ty = intLiteralType suffix
    if ty = typeof<int64> then
        il.Emit(OpCodes.Ldc_I8, int64 value)
    elif ty = typeof<uint64> then
        il.Emit(OpCodes.Ldc_I8, int64 value)
        il.Emit(OpCodes.Conv_U8) |> ignore
    elif ty = typeof<uint32> then
        emitLdcI4 il (int (uint32 value))
        il.Emit(OpCodes.Conv_U4) |> ignore
    elif ty = typeof<uint16> then
        emitLdcI4 il (int (uint16 value))
        il.Emit(OpCodes.Conv_U2) |> ignore
    elif ty = typeof<byte> then
        emitLdcI4 il (int (byte value))
        il.Emit(OpCodes.Conv_U1) |> ignore
    else
        emitLdcI4 il (int value)
    ty

let private emitFloatLiteral (il: ILGenerator) (value: double) (suffix: FloatSuffix) : ClrType =
    let ty = floatLiteralType suffix
    if ty = typeof<single> then il.Emit(OpCodes.Ldc_R4, single value)
    else                        il.Emit(OpCodes.Ldc_R8, value)
    ty

let private boxIfValue (il: ILGenerator) (ty: ClrType) : unit =
    if ty.IsValueType then il.Emit(OpCodes.Box, ty)

// ---------------------------------------------------------------------------
// Expression / statement emission.
// ---------------------------------------------------------------------------

let rec emitExpr (ctx: FunctionCtx) (e: Expr) : ClrType =
    let il = ctx.IL
    match e.Kind with

    // ---- literals -----------------------------------------------------

    | ELiteral (LString s) ->
        il.Emit(OpCodes.Ldstr, s)
        typeof<string>

    | ELiteral (LBool b) ->
        emitLdcI4 il (if b then 1 else 0)
        typeof<bool>

    | ELiteral (LInt (value, suffix)) ->
        emitIntLiteral il value suffix

    | ELiteral (LFloat (value, suffix)) ->
        emitFloatLiteral il value suffix

    | ELiteral (LChar c) ->
        emitLdcI4 il c
        typeof<char>

    | ELiteral LUnit ->
        emitLdcI4 il 0
        typeof<int32>

    | EParen inner -> emitExpr ctx inner

    // ---- field access (record member) ---------------------------------

    | EMember (recv, fieldName) ->
        let recvTy = emitExpr ctx recv
        // The receiver's CLR type tells us which record's field
        // table to consult. Walk the records dict to find a match.
        let info =
            ctx.Records.Values
            |> Seq.tryFind (fun r -> (r.Type :> ClrType) = recvTy)
        match info with
        | Some r ->
            match r.Fields |> List.tryFind (fun f -> f.Name = fieldName) with
            | Some f ->
                il.Emit(OpCodes.Ldfld, f.Field)
                f.Type
            | None ->
                failwithf "E5 codegen: record '%s' has no field '%s'"
                    r.Name fieldName
        | None ->
            failwithf "E5 codegen: receiver type %s is not a known record"
                recvTy.Name

    // ---- variable read ------------------------------------------------

    | EPath { Segments = [name] } ->
        // Order: parameter slot → local variable → function name
        // (which loads a delegate; deferred to E8). Locals shadow
        // params shadow functions, mirroring the type checker's
        // lookup order.
        match FunctionCtx.tryLookup ctx name with
        | Some lb ->
            il.Emit(OpCodes.Ldloc, lb)
            lb.LocalType
        | None ->
            match ctx.Params.TryGetValue name with
            | true, (idx, pty) ->
                il.Emit(OpCodes.Ldarg, idx)
                pty
            | _ ->
                failwithf "E4 codegen: unknown name '%s'" name

    // ---- prefix -------------------------------------------------------

    | EPrefix (PreNeg, operand) ->
        let t = emitExpr ctx operand
        il.Emit(OpCodes.Neg)
        t

    | EPrefix (PreNot, operand) ->
        let _ = emitExpr ctx operand
        emitLdcI4 il 0
        il.Emit(OpCodes.Ceq)
        typeof<bool>

    // ---- binary operators ---------------------------------------------

    | EBinop (BAnd, lhs, rhs) ->
        let _ = emitExpr ctx lhs
        let lblFalse = il.DefineLabel()
        let lblEnd   = il.DefineLabel()
        il.Emit(OpCodes.Brfalse_S, lblFalse)
        let _ = emitExpr ctx rhs
        il.Emit(OpCodes.Br_S, lblEnd)
        il.MarkLabel(lblFalse)
        emitLdcI4 il 0
        il.MarkLabel(lblEnd)
        typeof<bool>

    | EBinop (BOr, lhs, rhs) ->
        let _ = emitExpr ctx lhs
        let lblTrue = il.DefineLabel()
        let lblEnd  = il.DefineLabel()
        il.Emit(OpCodes.Brtrue_S, lblTrue)
        let _ = emitExpr ctx rhs
        il.Emit(OpCodes.Br_S, lblEnd)
        il.MarkLabel(lblTrue)
        emitLdcI4 il 1
        il.MarkLabel(lblEnd)
        typeof<bool>

    | EBinop (op, lhs, rhs) ->
        let lt = emitExpr ctx lhs
        let _  = emitExpr ctx rhs
        let opTy = lt
        match op with
        | BAdd ->
            if isFloatClr opTy then il.Emit(OpCodes.Add)
            elif isUnsignedClr opTy then il.Emit(OpCodes.Add_Ovf_Un)
            else il.Emit(OpCodes.Add_Ovf)
            opTy
        | BSub ->
            if isFloatClr opTy then il.Emit(OpCodes.Sub)
            elif isUnsignedClr opTy then il.Emit(OpCodes.Sub_Ovf_Un)
            else il.Emit(OpCodes.Sub_Ovf)
            opTy
        | BMul ->
            if isFloatClr opTy then il.Emit(OpCodes.Mul)
            elif isUnsignedClr opTy then il.Emit(OpCodes.Mul_Ovf_Un)
            else il.Emit(OpCodes.Mul_Ovf)
            opTy
        | BDiv ->
            if isUnsignedClr opTy then il.Emit(OpCodes.Div_Un)
            else il.Emit(OpCodes.Div)
            opTy
        | BMod ->
            if isUnsignedClr opTy then il.Emit(OpCodes.Rem_Un)
            else il.Emit(OpCodes.Rem)
            opTy
        | BXor ->
            il.Emit(OpCodes.Xor)
            opTy
        | BEq  -> il.Emit(OpCodes.Ceq); typeof<bool>
        | BNeq -> il.Emit(OpCodes.Ceq); emitLdcI4 il 0; il.Emit(OpCodes.Ceq); typeof<bool>
        | BLt  ->
            if isUnsignedClr opTy then il.Emit(OpCodes.Clt_Un) else il.Emit(OpCodes.Clt)
            typeof<bool>
        | BGt  ->
            if isUnsignedClr opTy then il.Emit(OpCodes.Cgt_Un) else il.Emit(OpCodes.Cgt)
            typeof<bool>
        | BLte ->
            if isUnsignedClr opTy then il.Emit(OpCodes.Cgt_Un) else il.Emit(OpCodes.Cgt)
            emitLdcI4 il 0; il.Emit(OpCodes.Ceq); typeof<bool>
        | BGte ->
            if isUnsignedClr opTy then il.Emit(OpCodes.Clt_Un) else il.Emit(OpCodes.Clt)
            emitLdcI4 il 0; il.Emit(OpCodes.Ceq); typeof<bool>
        | BCoalesce -> opTy
        | BImplies  ->
            il.Emit(OpCodes.Pop); il.Emit(OpCodes.Pop); emitLdcI4 il 1; typeof<bool>
        | BAnd | BOr ->
            failwith "logical op fell through to fallback"

    // ---- if-expression ------------------------------------------------

    | EIf (cond, thenBranch, elseBranch, _isThen) ->
        let _ = emitExpr ctx cond
        match elseBranch with
        | None ->
            // Statement-form `if cond { ... }` — no value, no
            // stack effect.
            let lblEnd = il.DefineLabel()
            il.Emit(OpCodes.Brfalse, lblEnd)
            let thenTy = emitBranch ctx thenBranch
            // If the then-branch left a value, drop it so the merge
            // point is balanced.
            if thenTy <> typeof<System.Void> then
                il.Emit(OpCodes.Pop)
            il.MarkLabel(lblEnd)
            typeof<System.Void>
        | Some elseB ->
            let lblElse = il.DefineLabel()
            let lblEnd  = il.DefineLabel()
            il.Emit(OpCodes.Brfalse, lblElse)
            let thenTy = emitBranch ctx thenBranch
            il.Emit(OpCodes.Br, lblEnd)
            il.MarkLabel(lblElse)
            let elseTy = emitBranch ctx elseB
            il.MarkLabel(lblEnd)
            // Both branches must agree on whether they push a value.
            if thenTy = typeof<System.Void> || elseTy = typeof<System.Void> then
                typeof<System.Void>
            else
                thenTy

    // ---- record construction ------------------------------------------

    | ECall ({ Kind = EPath { Segments = [name] } }, args)
        when ctx.Records.ContainsKey name ->
        let info = ctx.Records.[name]
        // Sort arguments into field-declaration order. Positional
        // and named args may mix; named args win.
        let namedMap =
            args
            |> List.choose (function
                | CANamed (n, ex, _) -> Some (n, ex)
                | _ -> None)
            |> Map.ofList
        let positional =
            args
            |> List.choose (function
                | CAPositional ex -> Some ex
                | _ -> None)
        let mutable posIdx = 0
        for f in info.Fields do
            let argExpr =
                match Map.tryFind f.Name namedMap with
                | Some ex -> ex
                | None ->
                    if posIdx < List.length positional then
                        let ex = List.item posIdx positional
                        posIdx <- posIdx + 1
                        ex
                    else
                        failwithf "E5 codegen: record '%s' missing field '%s'"
                            name f.Name
            let _ = emitExpr ctx argExpr
            ()
        il.Emit(OpCodes.Newobj, info.Ctor)
        info.Type :> ClrType

    // ---- user-defined call --------------------------------------------

    | ECall ({ Kind = EPath { Segments = [name] } }, args)
        when ctx.Funcs.ContainsKey name ->
        let mb = ctx.Funcs.[name]
        for a in args do
            let payload =
                match a with
                | CAPositional ex | CANamed (_, ex, _) -> ex
            let _ = emitExpr ctx payload
            ()
        il.Emit(OpCodes.Call, mb)
        if mb.ReturnType = typeof<System.Void> then
            typeof<System.Void>
        else
            mb.ReturnType

    // ---- println builtin ----------------------------------------------

    | ECall ({ Kind = EPath { Segments = ["println"] } }, [arg]) ->
        let payload =
            match arg with
            | CAPositional ex | CANamed (_, ex, _) -> ex
        let argTy = emitExpr ctx payload
        if argTy = typeof<string> then
            il.Emit(OpCodes.Call, printlnString.Value)
        else
            boxIfValue il argTy
            il.Emit(OpCodes.Call, printlnAny.Value)
        typeof<System.Void>

    | _ ->
        failwithf "E3 codegen does not yet handle expression: %A" e.Kind

and private emitBranch (ctx: FunctionCtx) (b: ExprOrBlock) : ClrType =
    match b with
    | EOBExpr e   -> emitExpr ctx e
    | EOBBlock blk ->
        emitBlock ctx blk
        typeof<System.Void>     // a block leaves nothing on the stack

and emitStatement (ctx: FunctionCtx) (s: Statement) : unit =
    let il = ctx.IL
    match s.Kind with

    | SExpr e ->
        let resultTy = emitExpr ctx e
        if resultTy <> typeof<System.Void> then
            il.Emit(OpCodes.Pop)

    | SLocal (LBVal ({ Kind = PBinding (name, None) }, _annot, init))
    | SLocal (LBLet (name, _annot, init)) ->
        let initTy = emitExpr ctx init
        let lb = FunctionCtx.defineLocal ctx name initTy
        il.Emit(OpCodes.Stloc, lb)

    | SLocal (LBVar (name, annot, initOpt)) ->
        let initTy =
            match initOpt with
            | Some init ->
                let it = emitExpr ctx init
                Some it
            | None -> None
        // Without inference, default-typed `var` falls back to int32
        // so the slot has *some* CLR type. Annotation handling lands
        // when TypeMap can consult the type checker.
        let slotTy = defaultArg initTy typeof<int32>
        ignore annot
        let lb = FunctionCtx.defineLocal ctx name slotTy
        match initOpt with
        | Some _ -> il.Emit(OpCodes.Stloc, lb)
        | None   -> ()

    | SLocal _ ->
        failwithf "E3 codegen does not yet handle this local pattern: %A" s.Kind

    | SAssign (target, AssEq, value) ->
        match target.Kind with
        | EPath { Segments = [name] } ->
            match FunctionCtx.tryLookup ctx name with
            | Some lb ->
                let _ = emitExpr ctx value
                il.Emit(OpCodes.Stloc, lb)
            | None -> failwithf "E3 codegen: assignment to unknown name '%s'" name
        | _ ->
            failwithf "E3 codegen: assignment target not yet supported: %A" target.Kind

    | SAssign (target, op, value) ->
        // Compound assignment: lower to `target = target <op> value`.
        match target.Kind with
        | EPath { Segments = [name] } ->
            match FunctionCtx.tryLookup ctx name with
            | Some lb ->
                let bop =
                    match op with
                    | AssPlus    -> BAdd
                    | AssMinus   -> BSub
                    | AssStar    -> BMul
                    | AssSlash   -> BDiv
                    | AssPercent -> BMod
                    | AssEq      -> BAdd  // already handled
                let synthetic : Expr =
                    { Kind = EBinop (bop, target, value); Span = s.Span }
                let _ = emitExpr ctx synthetic
                il.Emit(OpCodes.Stloc, lb)
            | None -> failwithf "E3 codegen: compound-assign to unknown name '%s'" name
        | _ ->
            failwithf "E3 codegen: compound-assign target not yet supported: %A" target.Kind

    | SReturn None ->
        il.Emit(OpCodes.Ret)

    | SReturn (Some e) ->
        let _ = emitExpr ctx e
        il.Emit(OpCodes.Ret)

    | SWhile (_label, cond, body) ->
        let lblHead = il.DefineLabel()
        let lblEnd  = il.DefineLabel()
        FunctionCtx.pushLoop ctx { BreakLabel = lblEnd; ContinueLabel = lblHead }
        il.MarkLabel(lblHead)
        let _ = emitExpr ctx cond
        il.Emit(OpCodes.Brfalse, lblEnd)
        emitBlock ctx body
        il.Emit(OpCodes.Br, lblHead)
        il.MarkLabel(lblEnd)
        FunctionCtx.popLoop ctx

    | SLoop (_label, body) ->
        let lblHead = il.DefineLabel()
        let lblEnd  = il.DefineLabel()
        FunctionCtx.pushLoop ctx { BreakLabel = lblEnd; ContinueLabel = lblHead }
        il.MarkLabel(lblHead)
        emitBlock ctx body
        il.Emit(OpCodes.Br, lblHead)
        il.MarkLabel(lblEnd)
        FunctionCtx.popLoop ctx

    | SBreak _ ->
        match FunctionCtx.currentLoop ctx with
        | Some f -> il.Emit(OpCodes.Br, f.BreakLabel)
        | None   -> failwith "E3 codegen: 'break' outside of a loop"

    | SContinue _ ->
        match FunctionCtx.currentLoop ctx with
        | Some f -> il.Emit(OpCodes.Br, f.ContinueLabel)
        | None   -> failwith "E3 codegen: 'continue' outside of a loop"

    | SFor (_label, { Kind = PBinding (name, None) }, iter, body) ->
        // `for x in slice { body }` lowers to a counter + ldelem loop.
        // The iter is presumed to be a slice/array (CLR T[]); other
        // iterables land in E7.
        let iterTy = emitExpr ctx iter
        if not iterTy.IsArray then
            failwithf "E3 codegen: for-in expects an array/slice, got %A" iterTy
        let elemTy = iterTy.GetElementType()
        let arrLocal = FunctionCtx.defineLocal ctx ("__iter_" + name) iterTy
        il.Emit(OpCodes.Stloc, arrLocal)
        let idxLocal = FunctionCtx.defineLocal ctx ("__idx_" + name) typeof<int32>
        emitLdcI4 il 0
        il.Emit(OpCodes.Stloc, idxLocal)
        let lblHead = il.DefineLabel()
        let lblEnd  = il.DefineLabel()
        FunctionCtx.pushLoop ctx { BreakLabel = lblEnd; ContinueLabel = lblHead }
        il.MarkLabel(lblHead)
        // if (idx >= length) goto end
        il.Emit(OpCodes.Ldloc, idxLocal)
        il.Emit(OpCodes.Ldloc, arrLocal)
        il.Emit(OpCodes.Ldlen)
        il.Emit(OpCodes.Conv_I4)
        il.Emit(OpCodes.Bge, lblEnd)
        // load element into the loop variable
        FunctionCtx.pushScope ctx
        let elemLocal =
            match elemTy with
            | null -> FunctionCtx.defineLocal ctx name typeof<obj>
            | t    -> FunctionCtx.defineLocal ctx name t
        il.Emit(OpCodes.Ldloc, arrLocal)
        il.Emit(OpCodes.Ldloc, idxLocal)
        il.Emit(OpCodes.Ldelem, elemLocal.LocalType)
        il.Emit(OpCodes.Stloc, elemLocal)
        emitBlock ctx body
        FunctionCtx.popScope ctx
        // idx <- idx + 1
        il.Emit(OpCodes.Ldloc, idxLocal)
        emitLdcI4 il 1
        il.Emit(OpCodes.Add)
        il.Emit(OpCodes.Stloc, idxLocal)
        il.Emit(OpCodes.Br, lblHead)
        il.MarkLabel(lblEnd)
        FunctionCtx.popLoop ctx

    | SFor _ ->
        failwithf "E3 codegen: only single-name for-in patterns are supported: %A" s.Kind

    | SScope (_, blk) | SDefer blk ->
        FunctionCtx.pushScope ctx
        emitBlock ctx blk
        FunctionCtx.popScope ctx

    | _ ->
        failwithf "E3 codegen does not yet handle statement: %A" s.Kind

and emitBlock (ctx: FunctionCtx) (blk: Block) : unit =
    FunctionCtx.pushScope ctx
    for stmt in blk.Statements do
        emitStatement ctx stmt
    FunctionCtx.popScope ctx
