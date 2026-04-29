/// IL generation for expression and statement bodies.
///
/// E1 only handles the narrow shape needed for Hello World:
///   * String literals (`ldstr`).
///   * Calls to a hardcoded `println` builtin that maps to
///     `Lyric.Stdlib.Console::Println(string)`.
/// Subsequent slices broaden this.
module Lyric.Emitter.Codegen

open System
open System.Reflection
open System.Reflection.Emit
open Lyric.Parser.Ast

/// Resolve the `Lyric.Stdlib.Console::Println(string)` MethodInfo
/// once per emit run. Lazy because the type's containing assembly
/// must be loaded by the host AppDomain — which is the case for any
/// process that has already referenced `Lyric.Stdlib`.
let private printlnMethod : Lazy<MethodInfo> =
    lazy (
        let consoleTy = typeof<Lyric.Stdlib.Console>
        let mi = consoleTy.GetMethod("Println", [| typeof<string> |])
        match Option.ofObj mi with
        | Some m -> m
        | None ->
            failwith "Lyric.Stdlib.Console::Println(string) not found")

/// Emit a single expression. Returns `unit`; callers are responsible
/// for any pop/return shaping. E1 only reaches the println-and-string
/// path; everything else fails fast so misuse surfaces loudly.
let rec emitExpr (il: ILGenerator) (e: Expr) : unit =
    match e.Kind with
    | ELiteral (LString s) ->
        il.Emit(OpCodes.Ldstr, s)

    | ECall ({ Kind = EPath { Segments = ["println"] } }, [arg]) ->
        let payload =
            match arg with
            | CAPositional ex | CANamed (_, ex, _) -> ex
        emitExpr il payload
        il.Emit(OpCodes.Call, printlnMethod.Value)

    | _ ->
        // E1 explicitly limits its surface area. Surfacing a hard
        // failure here keeps the test-driven slice scope honest;
        // E2+ replaces this with proper diagnostics.
        failwithf "E1 codegen does not yet handle expression: %A" e.Kind

/// Emit a statement. E1 only needs the expression-statement form
/// (`println("hello")`). Other statement kinds are deferred.
let emitStatement (il: ILGenerator) (s: Statement) : unit =
    match s.Kind with
    | SExpr e -> emitExpr il e
    | _ ->
        failwithf "E1 codegen does not yet handle statement: %A" s.Kind

/// Emit every statement in a block. The block's value is discarded
/// (E1 functions return `Unit`).
let emitBlock (il: ILGenerator) (blk: Block) : unit =
    for stmt in blk.Statements do
        emitStatement il stmt
