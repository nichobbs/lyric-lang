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
    let info = JsonObject()
    info.["name"]    <- JsonValue.Create "lyric-lsp"
    info.["version"] <- JsonValue.Create "0.1.0"
    let r = JsonObject()
    r.["capabilities"] <- caps :> JsonNode
    r.["serverInfo"]   <- info :> JsonNode
    r :> JsonNode

let private nodeAt (n: JsonNode | null) (path: string) : JsonNode | null =
    match Option.ofObj n with
    | Some node ->
        match node with
        | :? JsonObject as o ->
            match o.TryGetPropertyValue path with
            | true, v -> v
            | _ -> null
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
        | :? JsonObject as o ->
            match o.TryGetPropertyValue "method" with
            | true, v -> v
            | _ -> null
        | _ -> null
    let method' = asStr methodNode
    let id =
        match msg with
        | :? JsonObject as o ->
            match o.TryGetPropertyValue "id" with
            | true, v -> v
            | _ -> null
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
        // Bootstrap-grade hover — always returns a one-line "Lyric"
        // placeholder.  Real type-resolution-on-position is a Phase 3
        // follow-up; the server returns *something* so editors don't
        // log a "method not found" warning.
        let result =
            let o = JsonObject()
            let contents = JsonObject()
            contents.["kind"]  <- JsonValue.Create "markdown"
            contents.["value"] <- JsonValue.Create "_Lyric LSP — hover not yet implemented._"
            o.["contents"] <- contents :> JsonNode
            o :> JsonNode
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
