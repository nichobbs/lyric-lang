/// LSP request / notification dispatch for Lyric.
///
/// The server keeps a small in-memory document store keyed by URI.
/// `textDocument/didOpen` and `textDocument/didChange` re-parse and
/// re-type-check the document, then publish the resulting diagnostics
/// back to the client via `textDocument/publishDiagnostics`.
///
/// Capabilities exposed in `initialize`:
///   - textDocumentSync: Full (we keep a full string copy per buffer)
///   - hoverProvider:    true  (full resolved signature for functions)
///   - completionProvider: true (all top-level names in the file)
///   - definitionProvider: true (go-to-definition for top-level names)
///   - signatureHelpProvider: true (triggered by '(' and ',')
module Lyric.Lsp.Server

open System
open System.Collections.Generic
open System.IO
open System.Text.Json.Nodes
open Lyric.Lexer
open Lyric.Parser
open Lyric.TypeChecker
open Lyric.TypeChecker.Checker
open Lyric.Lsp.JsonRpc

// ---------------------------------------------------------------------------
// Document store — caches the full analysis result per URI.
// ---------------------------------------------------------------------------

type CachedDoc =
    { Source:      string
      CheckResult: CheckResult }

type DocumentStore() =
    let docs = Dictionary<string, CachedDoc>()
    member _.Set(uri: string, doc: CachedDoc)    = docs.[uri] <- doc
    member _.Remove(uri: string)                 = docs.Remove(uri) |> ignore
    member _.TryGet(uri: string) : CachedDoc option =
        match docs.TryGetValue uri with
        | true, d -> Some d
        | _       -> None

// ---------------------------------------------------------------------------
// Analysis helpers.
// ---------------------------------------------------------------------------

/// Run lex → parse → type-check on `text`.  Returns all diagnostics
/// together with the cached CheckResult for subsequent LSP lookups.
let analyzeText (text: string) : Diagnostic list * CheckResult =
    let parsed   = Parser.parse text
    let checked' = Lyric.TypeChecker.Checker.check parsed.File
    parsed.Diagnostics @ checked'.Diagnostics, checked'

// ---------------------------------------------------------------------------
// Type / signature rendering helpers.
// ---------------------------------------------------------------------------

/// Build a reverse map from TypeId → declared name using the symbol table
/// so that `TyUser` entries display as `Account` instead of `<#3>`.
let private buildTypeNames (cr: CheckResult) : Map<int, string> =
    cr.Symbols.All()
    |> Seq.choose (fun sym ->
        match Symbol.typeIdOpt sym with
        | Some (TypeId id) -> Some (id, sym.Name)
        | None -> None)
    |> Map.ofSeq

let private renderType (typeNames: Map<int, string>) (ty: Type) : string =
    let rec render = function
        | TyPrim p -> Type.primName p
        | TyUser(TypeId id, []) ->
            typeNames |> Map.tryFind id |> Option.defaultValue (sprintf "<#%d>" id)
        | TyUser(TypeId id, args) ->
            let name = typeNames |> Map.tryFind id |> Option.defaultValue (sprintf "<#%d>" id)
            name + "[" + (args |> List.map render |> String.concat ", ") + "]"
        | TyTuple xs    -> "(" + (xs |> List.map render |> String.concat ", ") + ")"
        | TyNullable x  -> render x + "?"
        | TyFunction(ps, r, isAsync) ->
            let prefix = if isAsync then "async " else ""
            prefix + "(" + (ps |> List.map render |> String.concat ", ") + ") -> " + render r
        | TyArray(Some n, e) -> sprintf "array[%d, %s]" n (render e)
        | TyArray(None, e)   -> sprintf "array[?, %s]" (render e)
        | TySlice x  -> sprintf "slice[%s]" (render x)
        | TySelf     -> "Self"
        | TyVar n    -> n
        | TyError    -> "<error>"
    render ty

let private renderMode (mode: Lyric.Parser.Ast.ParamMode) =
    match mode with
    | Lyric.Parser.Ast.PMIn    -> "in"
    | Lyric.Parser.Ast.PMOut   -> "out"
    | Lyric.Parser.Ast.PMInout -> "inout"

/// Render a full resolved function signature as a one-liner, e.g.:
///   `pub async func transfer[T](from: in Account, to: in Account, amount: in T): Bool`
let private renderFullSig
        (name:       string)
        (vis:        Lyric.Parser.Ast.Visibility option)
        (sg:         ResolvedSignature)
        (typeNames:  Map<int, string>) : string =
    let visStr    = match vis with Some _ -> "pub " | None -> ""
    let asyncStr  = if sg.IsAsync then "async " else ""
    let generics  =
        if sg.Generics.IsEmpty then ""
        else "[" + String.concat ", " sg.Generics + "]"
    let paramsStr =
        sg.Params
        |> List.map (fun p ->
            sprintf "%s %s: %s" (renderMode p.Mode) p.Name (renderType typeNames p.Type))
        |> String.concat ", "
    let retStr    = renderType typeNames sg.Return
    sprintf "%s%sfunc %s%s(%s): %s" visStr asyncStr name generics paramsStr retStr

// ---------------------------------------------------------------------------
// Position / offset helpers.
// ---------------------------------------------------------------------------

/// Convert a Lyric `Position` (1-based line/col) to LSP's 0-based shape.
/// LSP columns are UTF-16 code units; for ASCII they match.
let private toLspPosition (p: Position) : JsonNode =
    let o = JsonObject()
    o.["line"]      <- JsonValue.Create(p.Line - 1)
    o.["character"] <- JsonValue.Create(p.Column - 1)
    o :> JsonNode

let private toLspRange (s: Span) : JsonNode =
    let o = JsonObject()
    o.["start"] <- toLspPosition s.Start
    o.["end"]   <- toLspPosition s.End
    o :> JsonNode

let private toLspDiagnostic (d: Diagnostic) : JsonNode =
    let o = JsonObject()
    o.["range"]    <- toLspRange d.Span
    o.["severity"] <-
        match d.Severity with
        | DiagError   -> JsonValue.Create 1
        | DiagWarning -> JsonValue.Create 2
    o.["code"]    <- JsonValue.Create d.Code
    o.["source"]  <- JsonValue.Create "lyric"
    o.["message"] <- JsonValue.Create d.Message
    o :> JsonNode

/// Convert a 1-based Lyric line/col to a 0-based flat offset in `text`.
let private posToOffset (text: string) (line: int) (col: int) : int =
    let lines = text.Split('\n')
    let lineIdx = line - 1
    if lineIdx < 0 || lineIdx >= lines.Length then text.Length
    else
        let baseOffset =
            lines
            |> Array.take lineIdx
            |> Array.sumBy (fun l -> l.Length + 1) // +1 for the '\n'
        baseOffset + min (col - 1) lines.[lineIdx].Length

/// Convert a 0-based flat offset to a 1-based Lyric Position.
let private lspToLyric (line: int) (character: int) : Position =
    { Line = line + 1; Column = character + 1; Offset = 0 }

let private posInSpan (p: Position) (s: Span) : bool =
    let cmp (a: Position) (b: Position) =
        if a.Line <> b.Line then compare a.Line b.Line
        else compare a.Column b.Column
    cmp s.Start p <= 0 && cmp p s.End < 0

// ---------------------------------------------------------------------------
// Identifier and call-context scanning helpers.
// ---------------------------------------------------------------------------

let private isIdChar (c: char) = Char.IsLetterOrDigit c || c = '_'

/// Find the identifier token that covers `pos` in `text`, or None.
let private identifierAt (text: string) (pos: Position) : (string * Span) option =
    let lines = text.Split('\n')
    if pos.Line < 1 || pos.Line > lines.Length then None
    else
        let line = lines.[pos.Line - 1]
        let col  = pos.Column - 1
        if col < 0 || col > line.Length then None
        else
            let mutable startCol = col
            while startCol > 0 && isIdChar line.[startCol - 1] do
                startCol <- startCol - 1
            let mutable endCol = col
            while endCol < line.Length && isIdChar line.[endCol] do
                endCol <- endCol + 1
            if startCol = endCol then None
            else
                let ident = line.Substring(startCol, endCol - startCol)
                if not (Char.IsLetter ident.[0] || ident.[0] = '_') then None
                else
                    let span : Span =
                        { Start = { Line = pos.Line; Column = startCol + 1; Offset = 0 }
                          End   = { Line = pos.Line; Column = endCol + 1;   Offset = 0 } }
                    Some (ident, span)

/// Scan backward from `offset` to find the innermost unclosed `(`.
/// Returns `(funcName, activeParamIndex)` if a call site is found.
///
/// Skips string literals approximately (good enough for the bootstrap).
let private findCallContext (text: string) (offset: int) : (string * int) option =
    if offset <= 0 then None
    else
        // Phase 1: scan backward to find the matching unclosed '('.
        let mutable i      = offset - 1
        let mutable depth  = 0
        let mutable found  = -1
        while i >= 0 && found = -1 do
            match text.[i] with
            | ')' | ']' -> depth <- depth + 1;     i <- i - 1
            | '(' | '[' ->
                if depth = 0 then found <- i
                else depth <- depth - 1; i <- i - 1
            | _ -> i <- i - 1
        if found < 0 then None
        else
            // Phase 2: find the identifier immediately before the '('.
            let mutable j = found - 1
            while j >= 0 && (text.[j] = ' ' || text.[j] = '\t') do
                j <- j - 1
            if j < 0 then None
            else
                let endJ = j + 1
                while j >= 0 && isIdChar text.[j] do
                    j <- j - 1
                let funcName = text.Substring(j + 1, endJ - (j + 1))
                if funcName = "" || Char.IsDigit funcName.[0] then None
                else
                    // Phase 3: count commas at depth 0 between '(' and cursor.
                    let mutable k        = found + 1
                    let mutable nest     = 0
                    let mutable paramIdx = 0
                    while k < offset do
                        match text.[k] with
                        | '(' | '[' | '{' -> nest <- nest + 1
                        | ')' | ']' | '}' -> nest <- nest - 1
                        | ',' when nest = 0 -> paramIdx <- paramIdx + 1
                        | _ -> ()
                        k <- k + 1
                    Some (funcName, paramIdx)

// ---------------------------------------------------------------------------
// AST item helpers (for hover / completion).
// ---------------------------------------------------------------------------

let private itemSummary (it: Lyric.Parser.Ast.Item) : string =
    let visPrefix =
        match it.Visibility with
        | Some _ -> "pub "
        | None   -> ""
    match it.Kind with
    | Lyric.Parser.Ast.IFunc fn ->
        let asyncTag = if fn.IsAsync then "async " else ""
        sprintf "%s%sfunc %s(...)" visPrefix asyncTag fn.Name
    | Lyric.Parser.Ast.IRecord rd ->
        sprintf "%srecord %s" visPrefix rd.Name
    | Lyric.Parser.Ast.IExposedRec rd ->
        sprintf "%sexposed record %s" visPrefix rd.Name
    | Lyric.Parser.Ast.IUnion ud ->
        sprintf "%sunion %s" visPrefix ud.Name
    | Lyric.Parser.Ast.IEnum ed ->
        sprintf "%senum %s" visPrefix ed.Name
    | Lyric.Parser.Ast.IOpaque od ->
        sprintf "%sopaque type %s" visPrefix od.Name
    | Lyric.Parser.Ast.IInterface iface ->
        sprintf "%sinterface %s" visPrefix iface.Name
    | Lyric.Parser.Ast.IConst cd ->
        sprintf "%sconst %s" visPrefix cd.Name
    | Lyric.Parser.Ast.ITypeAlias ta ->
        sprintf "%salias %s" visPrefix ta.Name
    | Lyric.Parser.Ast.IDistinctType dt ->
        sprintf "%sdistinct type %s" visPrefix dt.Name
    | Lyric.Parser.Ast.IExternType et ->
        sprintf "extern type %s" et.Name
    | _ -> "(item)"

let private itemName (it: Lyric.Parser.Ast.Item) : string option =
    match it.Kind with
    | Lyric.Parser.Ast.IFunc fn         -> Some fn.Name
    | Lyric.Parser.Ast.IRecord rd
    | Lyric.Parser.Ast.IExposedRec rd   -> Some rd.Name
    | Lyric.Parser.Ast.IUnion ud        -> Some ud.Name
    | Lyric.Parser.Ast.IEnum ed         -> Some ed.Name
    | Lyric.Parser.Ast.IOpaque od       -> Some od.Name
    | Lyric.Parser.Ast.IInterface iface -> Some iface.Name
    | Lyric.Parser.Ast.IConst cd        -> Some cd.Name
    | Lyric.Parser.Ast.ITypeAlias ta    -> Some ta.Name
    | Lyric.Parser.Ast.IDistinctType dt -> Some dt.Name
    | Lyric.Parser.Ast.IExternType et   -> Some et.Name
    | _ -> None

// ---------------------------------------------------------------------------
// LSP wire helpers.
// ---------------------------------------------------------------------------

let private publishDiagnostics
        (output: Stream) (uri: string) (diags: Diagnostic list) : unit =
    let arr = JsonArray()
    for d in diags do
        arr.Add(toLspDiagnostic d)
    let p = JsonObject()
    p.["uri"]         <- JsonValue.Create uri
    p.["diagnostics"] <- arr
    let msg = mkNotification "textDocument/publishDiagnostics" (p :> JsonNode)
    writeMessage output msg

/// `initialize` reply — the static capabilities table the client uses
/// to decide which subsequent requests to send.
let private initializeResult () : JsonNode =
    let caps = JsonObject()
    let sync = JsonObject()
    sync.["openClose"] <- JsonValue.Create true
    sync.["change"]    <- JsonValue.Create 1  // 1 = Full sync.
    caps.["textDocumentSync"] <- sync :> JsonNode
    caps.["hoverProvider"]    <- JsonValue.Create true
    let completion = JsonObject()
    completion.["resolveProvider"] <- JsonValue.Create false
    let triggerChars = JsonArray()
    triggerChars.Add(JsonValue.Create ".")
    completion.["triggerCharacters"] <- triggerChars :> JsonNode
    caps.["completionProvider"] <- completion :> JsonNode
    caps.["definitionProvider"] <- JsonValue.Create true
    // D-lsp-001: signature help triggered by '(' and ','.
    let sigHelp = JsonObject()
    let sigTriggers = JsonArray()
    sigTriggers.Add(JsonValue.Create "(")
    sigTriggers.Add(JsonValue.Create ",")
    sigHelp.["triggerCharacters"] <- sigTriggers :> JsonNode
    let sigRetriggers = JsonArray()
    sigRetriggers.Add(JsonValue.Create ",")
    sigHelp.["retriggerCharacters"] <- sigRetriggers :> JsonNode
    caps.["signatureHelpProvider"] <- sigHelp :> JsonNode
    let info = JsonObject()
    info.["name"]    <- JsonValue.Create "lyric-lsp"
    info.["version"] <- JsonValue.Create "0.1.0"
    let r = JsonObject()
    r.["capabilities"] <- caps :> JsonNode
    r.["serverInfo"]   <- info :> JsonNode
    r :> JsonNode

// ---------------------------------------------------------------------------
// JSON utility helpers (keep them local so they don't leak into public API).
// ---------------------------------------------------------------------------

let private tryGetProperty (o: JsonObject) (name: string) : JsonNode | null =
    let mutable v : JsonNode | null = null
    if o.TryGetPropertyValue(name, &v) then v else null

let private nodeAt (n: JsonNode | null) (path: string) : JsonNode | null =
    match Option.ofObj n with
    | Some node ->
        match node with
        | :? JsonObject as o -> tryGetProperty o path
        | _ -> null
    | None -> null

let private asStr (n: JsonNode | null) : string =
    match Option.ofObj n with
    | Some node -> try node.GetValue<string>() with _ -> ""
    | None -> ""

let private asInt (n: JsonNode | null) : int =
    match Option.ofObj n with
    | Some node -> try node.GetValue<int>() with _ -> 0
    | None -> 0

// ---------------------------------------------------------------------------
// Dispatch.
// ---------------------------------------------------------------------------

/// Dispatch one inbound LSP message.  Returns `false` when the client
/// has signalled `exit`, telling the main loop to drop out cleanly.
let dispatch
        (store:  DocumentStore)
        (output: Stream)
        (msg:    JsonNode) : bool =
    let methodNode =
        match msg with
        | :? JsonObject as o -> tryGetProperty o "method"
        | _ -> null
    let method' = asStr methodNode
    let id =
        match msg with
        | :? JsonObject as o -> tryGetProperty o "id"
        | _ -> null
    let params' = nodeAt msg "params"
    match method' with

    | "initialize" ->
        writeMessage output (mkResponse id (initializeResult ()))
        true

    | "initialized" ->
        true

    | "shutdown" ->
        writeMessage output (mkResponse id (JsonObject() :> JsonNode))
        true

    | "exit" ->
        false

    // -----------------------------------------------------------------------
    // Document synchronisation.
    // -----------------------------------------------------------------------

    | "textDocument/didOpen" ->
        let td   = nodeAt params' "textDocument"
        let uri  = asStr (nodeAt td "uri")
        let text = asStr (nodeAt td "text")
        if uri <> "" then
            try
                let diags, cr = analyzeText text
                store.Set(uri, { Source = text; CheckResult = cr })
                publishDiagnostics output uri diags
            with _ -> ()
        true

    | "textDocument/didChange" ->
        let td      = nodeAt params' "textDocument"
        let uri     = asStr (nodeAt td "uri")
        let changes = nodeAt params' "contentChanges"
        let newText =
            match changes with
            | :? JsonArray as a when a.Count > 0 ->
                asStr (nodeAt a.[a.Count - 1] "text")
            | _ -> ""
        if uri <> "" && newText <> "" then
            try
                let diags, cr = analyzeText newText
                store.Set(uri, { Source = newText; CheckResult = cr })
                publishDiagnostics output uri diags
            with _ -> ()
        true

    | "textDocument/didClose" ->
        let td  = nodeAt params' "textDocument"
        let uri = asStr (nodeAt td "uri")
        if uri <> "" then
            store.Remove(uri)
            try publishDiagnostics output uri []
            with _ -> ()
        true

    // -----------------------------------------------------------------------
    // Hover — full resolved signature for functions, summary for other items.
    // -----------------------------------------------------------------------

    | "textDocument/hover" ->
        let td      = nodeAt params' "textDocument"
        let uri     = asStr (nodeAt td "uri")
        let posNode = nodeAt params' "position"
        let line    = asInt (nodeAt posNode "line")
        let chr     = asInt (nodeAt posNode "character")
        let result =
            match store.TryGet uri with
            | None -> JsonObject() :> JsonNode
            | Some doc ->
                let p = lspToLyric line chr
                match identifierAt doc.Source p with
                | None -> JsonObject() :> JsonNode
                | Some (ident, span) ->
                    let cr = doc.CheckResult
                    let matchItem =
                        cr.File.Items
                        |> List.tryFind (fun it ->
                            match itemName it with
                            | Some n -> n = ident
                            | None   -> false)
                    match matchItem with
                    | None -> JsonObject() :> JsonNode
                    | Some it ->
                        let typeNames = buildTypeNames cr
                        let summary =
                            match it.Kind with
                            | Lyric.Parser.Ast.IFunc fn ->
                                // Prefer the resolved signature over the raw AST summary.
                                let arityKey = fn.Name + "/" + string fn.Params.Length
                                let sgOpt =
                                    match Map.tryFind arityKey cr.Signatures with
                                    | Some s -> Some s
                                    | None   -> Map.tryFind fn.Name cr.Signatures
                                match sgOpt with
                                | Some sg -> renderFullSig fn.Name it.Visibility sg typeNames
                                | None    -> itemSummary it
                            | _ -> itemSummary it
                        let docLines =
                            it.DocComments |> List.map (fun dc -> dc.Text.Trim())
                        let body =
                            if List.isEmpty docLines then summary
                            else summary + "\n\n" + String.concat "\n" docLines
                        let o = JsonObject()
                        let contents = JsonObject()
                        contents.["kind"]  <- JsonValue.Create "markdown"
                        contents.["value"] <- JsonValue.Create ("```lyric\n" + body + "\n```")
                        o.["contents"] <- contents :> JsonNode
                        o.["range"]    <- toLspRange span
                        o :> JsonNode
        writeMessage output (mkResponse id result)
        true

    // -----------------------------------------------------------------------
    // Completion — all top-level items in the file.
    // -----------------------------------------------------------------------

    | "textDocument/completion" ->
        let td  = nodeAt params' "textDocument"
        let uri = asStr (nodeAt td "uri")
        let result =
            match store.TryGet uri with
            | None -> JsonArray() :> JsonNode
            | Some doc ->
                let items = JsonArray()
                for it in doc.CheckResult.File.Items do
                    match itemName it with
                    | Some n ->
                        let entry = JsonObject()
                        entry.["label"] <- JsonValue.Create n
                        let kindCode =
                            match it.Kind with
                            | Lyric.Parser.Ast.IFunc _       -> 3   // Function
                            | Lyric.Parser.Ast.IRecord _
                            | Lyric.Parser.Ast.IExposedRec _ -> 22  // Struct
                            | Lyric.Parser.Ast.IUnion _      -> 7   // Class
                            | Lyric.Parser.Ast.IEnum _       -> 13  // Enum
                            | Lyric.Parser.Ast.IOpaque _     -> 22  // Struct
                            | Lyric.Parser.Ast.IInterface _  -> 8   // Interface
                            | Lyric.Parser.Ast.IConst _      -> 21  // Constant
                            | Lyric.Parser.Ast.IExternType _ -> 7
                            | _                              -> 1
                        entry.["kind"]   <- JsonValue.Create kindCode
                        entry.["detail"] <- JsonValue.Create (itemSummary it)
                        items.Add entry
                    | None -> ()
                items :> JsonNode
        writeMessage output (mkResponse id result)
        true

    // -----------------------------------------------------------------------
    // Go-to-definition — top-level item declarations.
    // -----------------------------------------------------------------------

    | "textDocument/definition" ->
        let td      = nodeAt params' "textDocument"
        let uri     = asStr (nodeAt td "uri")
        let posNode = nodeAt params' "position"
        let line    = asInt (nodeAt posNode "line")
        let chr     = asInt (nodeAt posNode "character")
        let result =
            match store.TryGet uri with
            | None -> JsonArray() :> JsonNode
            | Some doc ->
                let p = lspToLyric line chr
                match identifierAt doc.Source p with
                | None -> JsonArray() :> JsonNode
                | Some (ident, _) ->
                    let matchItem =
                        doc.CheckResult.File.Items
                        |> List.tryFind (fun it ->
                            match itemName it with
                            | Some n -> n = ident
                            | None   -> false)
                    match matchItem with
                    | None -> JsonArray() :> JsonNode
                    | Some it ->
                        let loc = JsonObject()
                        loc.["uri"]   <- JsonValue.Create uri
                        loc.["range"] <- toLspRange it.Span
                        loc :> JsonNode
        writeMessage output (mkResponse id result)
        true

    // -----------------------------------------------------------------------
    // Signature help — triggered by '(' and ','.
    // -----------------------------------------------------------------------

    | "textDocument/signatureHelp" ->
        let td      = nodeAt params' "textDocument"
        let uri     = asStr (nodeAt td "uri")
        let posNode = nodeAt params' "position"
        let line    = asInt (nodeAt posNode "line")
        let chr     = asInt (nodeAt posNode "character")
        let result =
            match store.TryGet uri with
            | None -> JsonObject() :> JsonNode
            | Some doc ->
                let offset = posToOffset doc.Source (line + 1) (chr + 1)
                match findCallContext doc.Source offset with
                | None -> JsonObject() :> JsonNode
                | Some (funcName, activeParam) ->
                    let cr = doc.CheckResult
                    // Try arity-qualified key first, then bare name.
                    let sgOpt =
                        cr.Signatures
                        |> Map.toSeq
                        |> Seq.tryPick (fun (k, sg) ->
                            // Accept any key that starts with `funcName` (bare or arity).
                            if k = funcName || k.StartsWith(funcName + "/") then Some sg
                            else None)
                    match sgOpt with
                    | None -> JsonObject() :> JsonNode
                    | Some sg ->
                        let typeNames = buildTypeNames cr
                        let paramLabels =
                            sg.Params
                            |> List.map (fun p ->
                                sprintf "%s %s: %s"
                                    (renderMode p.Mode)
                                    p.Name
                                    (renderType typeNames p.Type))
                        let generics =
                            if sg.Generics.IsEmpty then ""
                            else "[" + String.concat ", " sg.Generics + "]"
                        let asyncStr = if sg.IsAsync then "async " else ""
                        let label =
                            sprintf "%sfunc %s%s(%s): %s"
                                asyncStr funcName generics
                                (String.concat ", " paramLabels)
                                (renderType typeNames sg.Return)
                        // Build per-parameter sub-labels for highlighting.
                        let paramsArr = JsonArray()
                        for pl in paramLabels do
                            let pm = JsonObject()
                            pm.["label"] <- JsonValue.Create pl
                            paramsArr.Add pm
                        let sig' = JsonObject()
                        sig'.["label"]      <- JsonValue.Create label
                        sig'.["parameters"] <- paramsArr :> JsonNode
                        let sigArr = JsonArray()
                        sigArr.Add sig'
                        let o = JsonObject()
                        o.["signatures"]      <- sigArr :> JsonNode
                        o.["activeSignature"] <- JsonValue.Create 0
                        o.["activeParameter"] <- JsonValue.Create (
                            if sg.Params.IsEmpty then 0
                            else min activeParam (sg.Params.Length - 1))
                        o :> JsonNode
        writeMessage output (mkResponse id result)
        true

    // -----------------------------------------------------------------------
    // Catch-all — method-not-found for unhandled requests; silent for
    // notifications (no id).
    // -----------------------------------------------------------------------

    | _ when not (isNull id) ->
        writeMessage output (mkErrorResponse id -32601 (sprintf "method not found: %s" method'))
        true

    | _ ->
        true

let runLoop (input: Stream) (output: Stream) : unit =
    let store = DocumentStore()
    let mutable keepRunning = true
    while keepRunning do
        match readMessage input with
        | None -> keepRunning <- false
        | Some msg ->
            try
                if not (dispatch store output msg) then
                    keepRunning <- false
            with _ ->
                eprintfn "lyric-lsp: dispatch error"
