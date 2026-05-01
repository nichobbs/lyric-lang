/// AST-level synthesis for `@stubbable` interfaces.
///
/// The full design (D016, language reference §10) ships a builder DSL
/// with `.returning { ... }`, `.failing { ... }`, `.recording()`.  The
/// bootstrap-grade lowering implemented here is the simplest possible
/// stub:
///
///   @stubbable
///   pub interface Clock {
///     func now(): Instant
///   }
///
/// gets a sibling record + impl synthesised before the type checker
/// runs:
///
///   pub record ClockStub {
///     pub now_value: Instant
///   }
///   impl Clock for ClockStub {
///     func now(): Instant = self.now_value
///   }
///
/// Callers construct the stub directly via the record literal:
///
///   val stub = ClockStub(now_value = Instant.epoch)
///   val c: Clock = stub
///
/// Out of bootstrap scope (tracked in `docs/12-todo-plan.md`):
///   - Generic interfaces (`@stubbable interface Repo[T] { ... }`)
///   - Methods with `Self` in return or param positions
///   - Async methods (need `Task[T]` wrapping in the value field)
///   - The `.recording()` / `.failing { ... }` builder DSL
///
/// Methods that fall outside the supported subset are left in the
/// interface untouched — the user gets a normal "no impl found"
/// diagnostic later if they actually rely on them via the stub.
module Lyric.Parser.Stubbable

open Lyric.Lexer
open Lyric.Parser.Ast

let private isStubbable (a: Annotation) : bool =
    match a.Name.Segments with
    | "stubbable" :: _ -> true
    | _ -> false

let private hasStubbable (item: Item) : bool =
    item.Annotations |> List.exists isStubbable

/// Walk a TypeExpr looking for a `Self` mention so we know to skip
/// the method.  A bare `Self` in return position is the most common
/// case; nested forms (`Self?`, `slice[Self]`, `(Self) -> T`) are
/// also rejected for the bootstrap.
let rec private mentionsSelf (te: TypeExpr) : bool =
    match te.Kind with
    | TSelf -> true
    | TRef _ | TUnit | TNever | TError -> false
    | TGenericApp (_, args) ->
        args |> List.exists (fun a ->
            match a with
            | TAType t -> mentionsSelf t
            | TAValue _ -> false)
    | TArray (_, elem) -> mentionsSelf elem
    | TSlice elem -> mentionsSelf elem
    | TRefined _ -> false
    | TTuple ts -> ts |> List.exists mentionsSelf
    | TNullable t -> mentionsSelf t
    | TFunction (ps, r) ->
        (ps |> List.exists mentionsSelf) || mentionsSelf r
    | TParen t -> mentionsSelf t

let private isStubbableMethodSig (sg: FunctionSig) : bool =
    if sg.IsAsync then false
    else
        let returnOk =
            match sg.Return with
            | Some te -> not (mentionsSelf te)
            | None    -> true   // `func m()` (Unit return) is fine
        let paramsOk =
            sg.Params
            |> List.forall (fun p -> not (mentionsSelf p.Type))
        returnOk && paramsOk

let private isUnitReturn (sg: FunctionSig) : bool =
    match sg.Return with
    | None -> true
    | Some te ->
        match te.Kind with
        | TUnit -> true
        // `func m(): Unit` is the spelling users actually write; the
        // parser produces `TRef ["Unit"]` for the bare-name form.
        | TRef p when p.Segments = ["Unit"] -> true
        | _ -> false

let private mkPath (name: string) (span: Span) : ModulePath =
    { Segments = [name]; Span = span }

let private mkType (kind: TypeExprKind) (span: Span) : TypeExpr =
    { Kind = kind; Span = span }

let private mkExpr (kind: ExprKind) (span: Span) : Expr =
    { Kind = kind; Span = span }

let private mkPub (span: Span) : Visibility option =
    Some (Pub span)

let private valueFieldName (methodName: string) : string =
    methodName + "_value"

/// Build the stub record for one `@stubbable` interface.  The record
/// gets one `pub var` field per non-Unit method (so callers can
/// reset the value between scenarios) named `<method>_value`.
let private synthesiseStubRecord (id: InterfaceDecl) : RecordDecl =
    let fields =
        id.Members
        |> List.choose (function
            | IMSig sg when isStubbableMethodSig sg && not (isUnitReturn sg) ->
                let returnTy =
                    match sg.Return with
                    | Some te -> te
                    | None    -> mkType TUnit sg.Span
                Some
                    (RMField
                        { DocComments = []
                          Annotations = []
                          Visibility  = mkPub sg.Span
                          Name        = valueFieldName sg.Name
                          Type        = returnTy
                          Default     = None
                          Span        = sg.Span })
            | _ -> None)
    { Name     = id.Name + "Stub"
      Generics = None
      Where    = None
      Members  = fields
      Span     = id.Span }

/// Build the impl for one `@stubbable` interface — one method per
/// supported sig.  Non-Unit methods return the matching field;
/// Unit methods return `()`.
let private synthesiseStubImpl (id: InterfaceDecl) : ImplDecl =
    let stubName = id.Name + "Stub"
    let methods =
        id.Members
        |> List.choose (function
            | IMSig sg when isStubbableMethodSig sg ->
                let body =
                    if isUnitReturn sg then
                        // `func m(...): Unit { }` — empty block.
                        FBBlock { Statements = []; Span = sg.Span }
                    else
                        // `func m(...): T = self.<m>_value`
                        let selfExpr = mkExpr ESelf sg.Span
                        let memberAccess =
                            mkExpr (EMember (selfExpr, valueFieldName sg.Name))
                                   sg.Span
                        FBExpr memberAccess
                let fn : FunctionDecl =
                    { DocComments = []
                      Annotations = []
                      Visibility  = None
                      IsAsync     = sg.IsAsync
                      Name        = sg.Name
                      Generics    = sg.Generics
                      Params      = sg.Params
                      Return      = sg.Return
                      Where       = sg.Where
                      Contracts   = []
                      Body        = Some body
                      Span        = sg.Span }
                Some (IMplFunc fn)
            | _ -> None)
    let interfaceRef =
        { Head = mkPath id.Name id.Span
          Args = []
          Span = id.Span }
    let target =
        mkType (TRef (mkPath stubName id.Span)) id.Span
    { Generics  = None
      Interface = interfaceRef
      Target    = target
      Where     = None
      Members   = methods
      Span      = id.Span }

/// Append synthesised record + impl items for every `@stubbable`
/// interface in the source file.  The original interface item is
/// kept unchanged — clients still see `interface Foo` with the same
/// shape.
let synthesizeItems (items: Item list) : Item list =
    let result = ResizeArray<Item>(items)
    for it in items do
        match it.Kind with
        | IInterface id when hasStubbable it ->
            // Skip generic interfaces for the bootstrap — they need
            // generic stubs, which require generics-on-impl plus
            // generic field types (currently miss; see Band B in the
            // todo plan).
            if id.Generics.IsNone then
                let recordDecl = synthesiseStubRecord id
                let implDecl   = synthesiseStubImpl id
                result.Add
                    { DocComments = []
                      Annotations = []
                      Visibility  = mkPub id.Span
                      Kind        = IRecord recordDecl
                      Span        = id.Span }
                result.Add
                    { DocComments = []
                      Annotations = []
                      Visibility  = None
                      Kind        = IImpl implDecl
                      Span        = id.Span }
        | _ -> ()
    List.ofSeq result
