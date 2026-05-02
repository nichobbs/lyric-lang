/// LSP request / notification dispatch for Lyric.
///
/// The server keeps a small in-memory document store keyed by URI.
/// `textDocument/didOpen` and `textDocument/didChange` re-parse and
/// re-type-check the document, then publish the resulting diagnostics
/// back to the client via `textDocument/publishDiagnostics`.
///
/// Capabilities exposed in `initialize`:
///   - textDocumentSync: Full (we keep a full string copy per buffer)
///   - hoverProvider:    true
///   - diagnosticProvider via push (publishDiagnostics)
module Lyric.Lsp.Server

open System
open System.Collections.Generic
open System.IO
open System.Text.Json.Nodes
open Lyric.Lexer
open Lyric.Parser
open Lyric.Lsp.JsonRpc

type DocumentStore() =
    let docs = Dictionary<string, string>()
    member _.Set(uri: string, text: string) = docs.[uri] <- text
    member _.Remove(uri: string) = docs.Remove(uri) |> ignore
    member _.TryGet(uri: string) =
        match docs.TryGetValue uri with
        | true, t -> Some t
        | _       -> None

/// Convert a Lyric `Position` (1-based line/col) to LSP's 0-based
/// shape.  LSP columns are UTF-16 code units; for ASCII they match.
let private toLspPosition (p: Position) : JsonNode =
    let o = JsonObject()
    o.["line"]      <- JsonValue.Create(p.Line - 1)
    o.["character"] <- JsonValue.Create(p.Column - 1)
    o :> JsonNode

let private toLspRange (s: Span) : JsonNode =
    let o = JsonObject()
    o.["start"] <- toLspPosition s.Start
    // LSP ranges are exclusive at end.  Lyric spans already have an
    // exclusive end position so the conversion is direct.
    o.["end"]   <- toLspPosition s.End
    o :> JsonNode

let private toLspDiagnostic (d: Diagnostic) : JsonNode =
    let o = JsonObject()
    o.["range"]    <- toLspRange d.Span
    o.["severity"] <-
        // 1 = Error, 2 = Warning per LSP spec.
        match d.Severity with
        | DiagError   -> JsonValue.Create 1
        | DiagWarning -> JsonValue.Create 2
    o.["code"]    <- JsonValue.Create d.Code
    o.["source"]  <- JsonValue.Create "lyric"
    o.["message"] <- JsonValue.Create d.Message
    o :> JsonNode

/// Run lex → parse → type-check on `text` and return every diagnostic
/// produced.  We deliberately stop short of emitting IL — the LSP
/// only needs the diagnostic surface, and skipping the emitter keeps
/// per-keystroke latency low and avoids touching the build cache.
let computeDiagnostics (text: string) : Diagnostic list =
    let parsed = Parser.parse text
    let checked' = Lyric.TypeChecker.Checker.check parsed.File
    parsed.Diagnostics @ checked'.Diagnostics

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
/// to decide which subsequent requests to send.  Push diagnostics
/// don't go in capabilities (the server publishes them unsolicited);
/// only declarative providers do.
let private initializeResult () : JsonNode =
    let caps = JsonObject()
    // 1 = Full sync — we re-parse the entire buffer on every change.
    // The bootstrap doesn't try to do incremental parsing.
    let sync = JsonObject()
    sync.["openClose"] <- JsonValue.Create true
    sync.["change"]    <- JsonValue.Create 1
    caps.["textDocumentSync"] <- sync :> JsonNode
    caps.["hoverProvider"]    <- JsonValue.Create true
    // D-progress-066: completion + go-to-def land alongside hover.
    let completion = JsonObject()
    completion.["resolveProvider"] <- JsonValue.Create false
    let triggerChars = JsonArray()
    triggerChars.Add(JsonValue.Create ".")
    completion.["triggerCharacters"] <- triggerChars :> JsonNode
    caps.["completionProvider"] <- completion :> JsonNode
    caps.["definitionProvider"] <- JsonValue.Create true
    let info = JsonObject()
    info.["name"]    <- JsonValue.Create "lyric-lsp"
    info.["version"] <- JsonValue.Create "0.1.0"
    let r = JsonObject()
    r.["capabilities"] <- caps :> JsonNode
    r.["serverInfo"]   <- info :> JsonNode
    r :> JsonNode

// ---------------------------------------------------------------------------
// Position / item lookup helpers (D-progress-066).
//
// LSP positions are 0-based line/character; Lyric's `Position` is
// 1-based.  `lspToLyric` does the conversion; `posInSpan` checks
// whether a Lyric span contains a Lyric position.
// ---------------------------------------------------------------------------

let private lspToLyric (line: int) (character: int) : Position =
    { Line = line + 1; Column = character + 1; Offset = 0 }

let private posInSpan (p: Position) (s: Span) : bool =
    let cmp (a: Position) (b: Position) =
        if a.Line <> b.Line then compare a.Line b.Line
        else compare a.Column b.Column
    cmp s.Start p <= 0 && cmp p s.End < 0

/// Render a `pub`-surface item to a one-line summary suitable for
/// hover / completion display.
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

/// Item name for completion / lookup keying.
let private itemName (it: Lyric.Parser.Ast.Item) : string option =
    match it.Kind with
    | Lyric.Parser.Ast.IFunc fn -> Some fn.Name
    | Lyric.Parser.Ast.IRecord rd | Lyric.Parser.Ast.IExposedRec rd -> Some rd.Name
    | Lyric.Parser.Ast.IUnion ud -> Some ud.Name
    | Lyric.Parser.Ast.IEnum ed -> Some ed.Name
    | Lyric.Parser.Ast.IOpaque od -> Some od.Name
    | Lyric.Parser.Ast.IInterface iface -> Some iface.Name
    | Lyric.Parser.Ast.IConst cd -> Some cd.Name
    | Lyric.Parser.Ast.ITypeAlias ta -> Some ta.Name
    | Lyric.Parser.Ast.IDistinctType dt -> Some dt.Name
    | Lyric.Parser.Ast.IExternType et -> Some et.Name
    | _ -> None

/// Identifier-like span at the given position, or None when the
/// position lies on whitespace / non-identifier text.  Identifiers
/// are recognised by the Lyric lexer's identifier rule
/// (`[A-Za-z_][A-Za-z0-9_]*`); we re-implement the test here
/// without re-tokenising the buffer.
let private identifierAt (text: string) (pos: Position) : (string * Span) option =
    // Convert 1-based line/col to a 0-based offset in `text`.
    let lines = text.Split('\n')
    if pos.Line < 1 || pos.Line > lines.Length then None
    else
        let line = lines.[pos.Line - 1]
        let col = pos.Column - 1
        if col < 0 || col > line.Length then None
        else
            let isIdChar (c: char) =
                System.Char.IsLetterOrDigit c || c = '_'
            // Find the identifier boundaries.
            let mutable startCol = col
            while startCol > 0 && isIdChar line.[startCol - 1] do
                startCol <- startCol - 1
            let mutable endCol = col
            while endCol < line.Length && isIdChar line.[endCol] do
                endCol <- endCol + 1
            if startCol = endCol then None
            else
                let ident = line.Substring(startCol, endCol - startCol)
                // First char must be an identifier-start (letter/_).
                if not (System.Char.IsLetter ident.[0] || ident.[0] = '_') then None
                else
                    let span : Span =
                        { Start = { Line = pos.Line; Column = startCol + 1; Offset = 0 }
                          End   = { Line = pos.Line; Column = endCol + 1;   Offset = 0 } }
                    Some (ident, span)

let private tryGetProperty (o: JsonObject) (name: string) : JsonNode | null =
    // .NET 10 added a 3-arg overload of `TryGetPropertyValue`, which
    // breaks F#'s ability to tuple-destructure the (bool * JsonNode)
    // out-pair on the 2-arg call without a type hint.  Explicit byref
    // here disambiguates and produces identical IL.
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
    | Some node ->
        try node.GetValue<string>()
        with _ -> ""
    | None -> ""

/// Dispatch one inbound LSP message.  Returns `false` when the client
/// has signalled `exit`, telling the main loop to drop out cleanly.
let dispatch
        (store: DocumentStore)
        (output: Stream)
        (msg: JsonNode) : bool =
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
        // Client signals it processed our `initialize` reply.  No-op.
        true

    | "shutdown" ->
        // Per the LSP spec the result of `shutdown` should be `null`;
        // most clients only check that an `id` echo arrives.  Emit an
        // empty object — semantically equivalent for practical purposes
        // and sidesteps the JsonNode-non-nullable-setter constraint
        // when wiring `null` through the JsonObject API.
        writeMessage output (mkResponse id (JsonObject() :> JsonNode))
        true

    | "exit" ->
        false

    | "textDocument/didOpen" ->
        let td = nodeAt params' "textDocument"
        let uri  = asStr (nodeAt td "uri")
        let text = asStr (nodeAt td "text")
        if uri <> "" then
            store.Set(uri, text)
            try
                let diags = computeDiagnostics text
                publishDiagnostics output uri diags
            with _ -> ()
        true

    | "textDocument/didChange" ->
        let td = nodeAt params' "textDocument"
        let uri = asStr (nodeAt td "uri")
        // Full-sync mode: a single change event carries the full text.
        let changes = nodeAt params' "contentChanges"
        let newText =
            match changes with
            | :? JsonArray as a when a.Count > 0 ->
                asStr (nodeAt a.[a.Count - 1] "text")
            | _ -> ""
        if uri <> "" && newText <> "" then
            store.Set(uri, newText)
            try
                let diags = computeDiagnostics newText
                publishDiagnostics output uri diags
            with _ -> ()
        true

    | "textDocument/didClose" ->
        let td = nodeAt params' "textDocument"
        let uri = asStr (nodeAt td "uri")
        if uri <> "" then
            store.Remove(uri)
            // Clear stale diagnostics for the closed document.
            try publishDiagnostics output uri []
            with _ -> ()
        true

    | "textDocument/hover" ->
        // D-progress-066: real hover.  Look up the identifier at
        // the cursor in the parsed AST; if it matches a top-level
        // item, format its summary + doc comments.  Falls back to
        // an empty result for non-identifier positions.
        let td  = nodeAt params' "textDocument"
        let uri = asStr (nodeAt td "uri")
        let posNode = nodeAt params' "position"
        let intAt (parent: JsonNode | null) (key: string) : int =
            let raw : JsonNode | null = nodeAt parent key
            match Option.ofObj raw with
            | None -> 0
            | Some n ->
                try n.GetValue<int>()
                with _ -> 0
        let line = intAt posNode "line"
        let chr  = intAt posNode "character"
        let result =
            match store.TryGet uri with
            | None -> JsonObject() :> JsonNode
            | Some text ->
                let p = lspToLyric line chr
                match identifierAt text p with
                | None -> JsonObject() :> JsonNode
                | Some (ident, span) ->
                    let parsed = Parser.parse text
                    let matchItem =
                        parsed.File.Items
                        |> List.tryFind (fun it ->
                            match itemName it with
                            | Some n -> n = ident
                            | None -> false)
                    match matchItem with
                    | None -> JsonObject() :> JsonNode
                    | Some it ->
                        let summary = itemSummary it
                        let docLines =
                            it.DocComments
                            |> List.map (fun dc -> dc.Text.Trim())
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

    | "textDocument/completion" ->
        // D-progress-066: completion returns every top-level item
        // declared in the current file.  Cross-file imports + scope-
        // aware ranking land in a follow-up; this gets the editor a
        // useful baseline immediately.
        let td  = nodeAt params' "textDocument"
        let uri = asStr (nodeAt td "uri")
        let result =
            match store.TryGet uri with
            | None -> JsonArray() :> JsonNode
            | Some text ->
                let parsed = Parser.parse text
                let items = JsonArray()
                for it in parsed.File.Items do
                    match itemName it with
                    | Some n ->
                        let entry = JsonObject()
                        entry.["label"] <- JsonValue.Create n
                        // 3 = Function, 7 = Class, 13 = Enum, 22 = Struct.
                        // Map item kinds → CompletionItemKind.
                        let kindCode =
                            match it.Kind with
                            | Lyric.Parser.Ast.IFunc _ -> 3
                            | Lyric.Parser.Ast.IRecord _
                            | Lyric.Parser.Ast.IExposedRec _ -> 22
                            | Lyric.Parser.Ast.IUnion _ -> 7
                            | Lyric.Parser.Ast.IEnum _ -> 13
                            | Lyric.Parser.Ast.IOpaque _ -> 22
                            | Lyric.Parser.Ast.IInterface _ -> 8
                            | Lyric.Parser.Ast.IConst _ -> 21
                            | Lyric.Parser.Ast.IExternType _ -> 7
                            | _ -> 1
                        entry.["kind"]   <- JsonValue.Create kindCode
                        entry.["detail"] <- JsonValue.Create (itemSummary it)
                        items.Add entry
                    | None -> ()
                items :> JsonNode
        writeMessage output (mkResponse id result)
        true

    | "textDocument/definition" ->
        // D-progress-066: go-to-definition.  Look up the identifier
        // at the cursor; return a `Location` pointing at the
        // matching top-level item's span.
        let td  = nodeAt params' "textDocument"
        let uri = asStr (nodeAt td "uri")
        let posNode = nodeAt params' "position"
        let intAt (parent: JsonNode | null) (key: string) : int =
            let raw : JsonNode | null = nodeAt parent key
            match Option.ofObj raw with
            | None -> 0
            | Some n ->
                try n.GetValue<int>()
                with _ -> 0
        let line = intAt posNode "line"
        let chr  = intAt posNode "character"
        let result =
            match store.TryGet uri with
            | None -> JsonArray() :> JsonNode
            | Some text ->
                let p = lspToLyric line chr
                match identifierAt text p with
                | None -> JsonArray() :> JsonNode
                | Some (ident, _) ->
                    let parsed = Parser.parse text
                    let matchItem =
                        parsed.File.Items
                        |> List.tryFind (fun it ->
                            match itemName it with
                            | Some n -> n = ident
                            | None -> false)
                    match matchItem with
                    | None -> JsonArray() :> JsonNode
                    | Some it ->
                        let loc = JsonObject()
                        loc.["uri"]   <- JsonValue.Create uri
                        loc.["range"] <- toLspRange it.Span
                        loc :> JsonNode
        writeMessage output (mkResponse id result)
        true

    | _ when not (isNull id) ->
        // Unhandled request — JSON-RPC requires a reply.  Notifications
        // (no id) are silently dropped.
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
                // Per LSP convention, the server should not crash on
                // a single bad message — log to stderr and keep going.
                eprintfn "lyric-lsp: dispatch error"
