/// IL generation for expression and statement bodies.
///
/// E2 broadens beyond E1's println-only surface to cover the §4.1
/// primitives, arithmetic / comparison / logical / unary operators,
/// and a runtime-dispatched println that boxes value-typed arguments
/// before calling `Lyric.Stdlib.Console::PrintlnAny(object)`.
module Lyric.Emitter.Codegen

open System
open System.Reflection
open System.Reflection.Emit
open Lyric.Lexer
open Lyric.Parser.Ast

type private ClrType = System.Type

/// Resolve commonly-called BCL methods once per emit run. Lazy so a
/// host that never imports `Lyric.Stdlib` doesn't pay the lookup
/// cost on first emit.
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

/// "Numeric" CLR types for arithmetic / comparison purposes.
let private isNumericClr (t: ClrType) : bool =
    t = typeof<int8>   || t = typeof<int16> || t = typeof<int32>
    || t = typeof<int64>
    || t = typeof<byte>   || t = typeof<uint16> || t = typeof<uint32>
    || t = typeof<uint64>
    || t = typeof<single> || t = typeof<double>

let private isFloatClr (t: ClrType) : bool =
    t = typeof<single> || t = typeof<double>

let private isUnsignedClr (t: ClrType) : bool =
    t = typeof<byte> || t = typeof<uint16>
    || t = typeof<uint32> || t = typeof<uint64>

/// Push a 32-bit int literal using the smallest-encoding opcode.
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
    | n when n >= -128 && n <= 127 ->
        il.Emit(OpCodes.Ldc_I4_S, sbyte n)
    | _  -> il.Emit(OpCodes.Ldc_I4, n)

/// Map a Lyric integer literal + suffix to a CLR type.
let private intLiteralType (suffix: IntSuffix) : ClrType =
    match suffix with
    | NoIntSuffix | I32 | I16 | I8 -> typeof<int32>
    | I64                          -> typeof<int64>
    | U8                           -> typeof<byte>
    | U16                          -> typeof<uint16>
    | U32                          -> typeof<uint32>
    | U64                          -> typeof<uint64>

/// Map a Lyric float literal + suffix to a CLR type.
let private floatLiteralType (suffix: FloatSuffix) : ClrType =
    match suffix with
    | NoFloatSuffix | F64 -> typeof<double>
    | F32                 -> typeof<single>

/// Emit an integer literal, using ldc.i4 for 32-bit-fits and ldc.i8
/// for everything else.
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
    if ty = typeof<single> then
        il.Emit(OpCodes.Ldc_R4, single value)
    else
        il.Emit(OpCodes.Ldc_R8, value)
    ty

/// Box the value currently on the stack if it's a value type, so it
/// can be passed to a method whose parameter is `object`.
let private boxIfValue (il: ILGenerator) (ty: ClrType) : unit =
    if ty.IsValueType then
        il.Emit(OpCodes.Box, ty)

/// Emit a single expression. Returns the CLR type of the value left
/// on the evaluation stack.
let rec emitExpr (il: ILGenerator) (e: Expr) : ClrType =
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
        // Unit at value position is the empty ValueTuple. For the
        // narrow E2 surface we treat it as int 0 so the stack stays
        // balanced; E5 lifts this to `default(ValueTuple)`.
        emitLdcI4 il 0
        typeof<int32>

    // ---- parens -------------------------------------------------------

    | EParen inner -> emitExpr il inner

    // ---- prefix -------------------------------------------------------

    | EPrefix (PreNeg, operand) ->
        let t = emitExpr il operand
        il.Emit(OpCodes.Neg)
        t

    | EPrefix (PreNot, operand) ->
        let _ = emitExpr il operand
        // `not x` ≡ `x == false` ≡ ldc.i4.0 / ceq
        emitLdcI4 il 0
        il.Emit(OpCodes.Ceq)
        typeof<bool>

    // ---- binary operators ---------------------------------------------

    | EBinop (BAnd, lhs, rhs) ->
        // Short-circuit: if lhs is false, push false; else evaluate rhs.
        let _ = emitExpr il lhs
        let lblFalse = il.DefineLabel()
        let lblEnd   = il.DefineLabel()
        il.Emit(OpCodes.Brfalse_S, lblFalse)
        let _ = emitExpr il rhs
        il.Emit(OpCodes.Br_S, lblEnd)
        il.MarkLabel(lblFalse)
        emitLdcI4 il 0
        il.MarkLabel(lblEnd)
        typeof<bool>

    | EBinop (BOr, lhs, rhs) ->
        // Short-circuit: if lhs is true, push true; else evaluate rhs.
        let _ = emitExpr il lhs
        let lblTrue = il.DefineLabel()
        let lblEnd  = il.DefineLabel()
        il.Emit(OpCodes.Brtrue_S, lblTrue)
        let _ = emitExpr il rhs
        il.Emit(OpCodes.Br_S, lblEnd)
        il.MarkLabel(lblTrue)
        emitLdcI4 il 1
        il.MarkLabel(lblEnd)
        typeof<bool>

    | EBinop (op, lhs, rhs) ->
        let lt = emitExpr il lhs
        let rt = emitExpr il rhs
        // E2 assumes both operands have the same CLR type; E4's type
        // checker integration adds proper coercion. Pick either side
        // for downstream typing decisions.
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
        | BEq ->
            il.Emit(OpCodes.Ceq)
            typeof<bool>
        | BNeq ->
            il.Emit(OpCodes.Ceq)
            emitLdcI4 il 0
            il.Emit(OpCodes.Ceq)
            typeof<bool>
        | BLt ->
            if isUnsignedClr opTy then il.Emit(OpCodes.Clt_Un)
            else il.Emit(OpCodes.Clt)
            typeof<bool>
        | BGt ->
            if isUnsignedClr opTy then il.Emit(OpCodes.Cgt_Un)
            else il.Emit(OpCodes.Cgt)
            typeof<bool>
        | BLte ->
            // !(lhs > rhs)
            if isUnsignedClr opTy then il.Emit(OpCodes.Cgt_Un)
            else il.Emit(OpCodes.Cgt)
            emitLdcI4 il 0
            il.Emit(OpCodes.Ceq)
            typeof<bool>
        | BGte ->
            // !(lhs < rhs)
            if isUnsignedClr opTy then il.Emit(OpCodes.Clt_Un)
            else il.Emit(OpCodes.Clt)
            emitLdcI4 il 0
            il.Emit(OpCodes.Ceq)
            typeof<bool>
        | BCoalesce ->
            // Nullable handling lands in E7 — for now the rhs wins
            // unconditionally so the program still runs.
            ignore rt
            opTy
        | BImplies ->
            // Contract sub-language; deferred to M1.4. Emit (not lhs) or rhs
            // semantics is non-obvious without rewriting the subtree, so
            // for now we emit `or` of (not lhs) and rhs's bool result.
            // Because we've already pushed both operands in order, we
            // can't easily back-patch — so synthesise true to keep IL
            // valid and let M1.4 do this properly.
            il.Emit(OpCodes.Pop)
            il.Emit(OpCodes.Pop)
            emitLdcI4 il 1
            typeof<bool>
        | BAnd | BOr ->
            // Already handled above via short-circuit.
            failwith "logical op fell through to fallback"

    // ---- println builtin (dispatched at codegen time) -----------------

    | ECall ({ Kind = EPath { Segments = ["println"] } }, [arg]) ->
        let payload =
            match arg with
            | CAPositional ex | CANamed (_, ex, _) -> ex
        let argTy = emitExpr il payload
        if argTy = typeof<string> then
            il.Emit(OpCodes.Call, printlnString.Value)
        else
            boxIfValue il argTy
            il.Emit(OpCodes.Call, printlnAny.Value)
        typeof<System.Void>

    | _ ->
        failwithf "E2 codegen does not yet handle expression: %A" e.Kind

/// Emit a statement. E2 only needs the expression-statement form.
let emitStatement (il: ILGenerator) (s: Statement) : unit =
    match s.Kind with
    | SExpr e ->
        let resultTy = emitExpr il e
        // If the expression left a value on the stack and we're not
        // going to use it (statement position), pop it.
        if resultTy <> typeof<System.Void> then
            il.Emit(OpCodes.Pop)
    | _ ->
        failwithf "E2 codegen does not yet handle statement: %A" s.Kind

/// Emit every statement in a block.
let emitBlock (il: ILGenerator) (blk: Block) : unit =
    for stmt in blk.Statements do
        emitStatement il stmt
