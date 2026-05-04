/// End-to-end protocol tests for the bootstrap Lyric LSP.
///
/// We drive the server in-process by piping pre-formed JSON-RPC frames
/// into `Server.runLoop` over a `MemoryStream` pair, then parse the
/// captured stdout back into individual frames.  No `dotnet exec`,
/// no real stdio — the streams are just buffers.
module Lyric.Lsp.Tests.ProtocolTests

open System
open System.IO
open System.Text
open System.Text.Json.Nodes
open Expecto
open Lyric.Lsp
open Lyric.Lsp.Server

let private frame (payload: string) : byte array =
    let body = Encoding.UTF8.GetBytes payload
    let header = Encoding.UTF8.GetBytes(sprintf "Content-Length: %d\r\n\r\n" body.Length)
    Array.append header body

let private encodeAll (payloads: string list) : byte array =
    payloads |> List.map frame |> Array.concat

let private decodeAll (bytes: byte array) : JsonNode list =
    let result = ResizeArray<JsonNode>()
    let mutable i = 0
    while i < bytes.Length do
        let mutable contentLen = -1
        let mutable headerEnd  = -1
        let mutable j = i
        while j < bytes.Length - 3 && headerEnd = -1 do
            if bytes.[j]   = byte '\r' && bytes.[j + 1] = byte '\n'
               && bytes.[j + 2] = byte '\r' && bytes.[j + 3] = byte '\n'
            then headerEnd <- j + 4
            else j <- j + 1
        if headerEnd = -1 then i <- bytes.Length
        else
            let header = Encoding.UTF8.GetString(bytes, i, headerEnd - i)
            for line in header.Split([| "\r\n" |], System.StringSplitOptions.RemoveEmptyEntries) do
                let idx = line.IndexOf(':')
                if idx > 0 then
                    let k = line.Substring(0, idx).Trim()
                    let v = line.Substring(idx + 1).Trim()
                    if System.String.Equals(k, "Content-Length",
                                             System.StringComparison.OrdinalIgnoreCase)
                    then contentLen <- System.Int32.Parse v
            if contentLen <= 0 then i <- bytes.Length
            else
                let body = Encoding.UTF8.GetString(bytes, headerEnd, contentLen)
                match Option.ofObj (JsonNode.Parse body) with
                | Some n -> result.Add n
                | None   -> ()
                i <- headerEnd + contentLen
    List.ofSeq result

let private runWith (inputs: string list) : JsonNode list =
    let inBytes = encodeAll inputs
    use input  = new MemoryStream(inBytes)
    use output = new MemoryStream()
    Server.runLoop input output
    decodeAll (output.ToArray())

let private prop (n: JsonNode) (path: string) : JsonNode option =
    match n with
    | :? JsonObject as o ->
        // Explicit byref disambiguates between the .NET 10 2-arg and
        // 3-arg `TryGetPropertyValue` overloads.
        let mutable v : JsonNode | null = null
        if o.TryGetPropertyValue(path, &v) then Option.ofObj v else None
    | _ -> None

let private propStr (n: JsonNode) (path: string) : string =
    match prop n path with
    | Some v -> try v.GetValue<string>() with _ -> ""
    | None   -> ""

let private propInt (n: JsonNode) (path: string) : int =
    match prop n path with
    | Some v -> try v.GetValue<int>() with _ -> -1
    | None   -> -1

let private didOpenFor (uri: string) (text: string) : string =
    let p = JsonObject()
    let td = JsonObject()
    td.["uri"]        <- JsonValue.Create uri
    td.["languageId"] <- JsonValue.Create "lyric"
    td.["version"]    <- JsonValue.Create 1
    td.["text"]       <- JsonValue.Create text
    p.["textDocument"] <- td :> JsonNode
    let m = JsonObject()
    m.["jsonrpc"] <- JsonValue.Create "2.0"
    m.["method"]  <- JsonValue.Create "textDocument/didOpen"
    m.["params"]  <- p :> JsonNode
    m.ToJsonString()

let private didChangeFor (uri: string) (version: int) (text: string) : string =
    let p = JsonObject()
    let td = JsonObject()
    td.["uri"]     <- JsonValue.Create uri
    td.["version"] <- JsonValue.Create version
    p.["textDocument"] <- td :> JsonNode
    let arr = JsonArray()
    let chg = JsonObject()
    chg.["text"] <- JsonValue.Create text
    arr.Add(chg)
    p.["contentChanges"] <- arr :> JsonNode
    let m = JsonObject()
    m.["jsonrpc"] <- JsonValue.Create "2.0"
    m.["method"]  <- JsonValue.Create "textDocument/didChange"
    m.["params"]  <- p :> JsonNode
    m.ToJsonString()

let tests =
    testList "Lyric LSP — JSON-RPC protocol" [

        testCase "initialize advertises the bootstrap capabilities" <| fun () ->
            let out =
                runWith [
                    """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"""
                    """{"jsonrpc":"2.0","method":"exit"}"""
                ]
            Expect.isNonEmpty out "initialize should produce a response"
            let resp = out.[0]
            Expect.equal (propInt resp "id") 1 "id is echoed"
            match prop resp "result" with
            | None -> failtest "no result"
            | Some r ->
                match prop r "capabilities" with
                | None -> failtest "no capabilities"
                | Some caps ->
                    match prop caps "textDocumentSync" with
                    | Some sync ->
                        Expect.equal (propInt sync "change") 1 "Full sync mode (change=1)"
                    | None -> failtest "no textDocumentSync"

        testCase "didOpen with broken source publishes diagnostics" <| fun () ->
            let badSource = "package T\n\nfunc main(): Unit { let x = (}\n"
            let out =
                runWith [
                    """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"""
                    didOpenFor "file:///t.l" badSource
                    """{"jsonrpc":"2.0","method":"exit"}"""
                ]
            let pub =
                out
                |> List.tryFind (fun n -> propStr n "method" = "textDocument/publishDiagnostics")
            match pub with
            | None -> failtest "no publishDiagnostics notification"
            | Some n ->
                match prop n "params" with
                | None -> failtest "no params on publishDiagnostics"
                | Some p ->
                    match prop p "diagnostics" with
                    | Some d ->
                        match d with
                        | :? JsonArray as a ->
                            Expect.isGreaterThan a.Count 0 "at least one diagnostic"
                        | _ -> failtest "diagnostics not an array"
                    | None -> failtest "no diagnostics field"

        testCase "didChange to clean source clears diagnostics" <| fun () ->
            let out =
                runWith [
                    """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"""
                    didOpenFor "file:///t.l" "package T\nfunc main(){"
                    didChangeFor "file:///t.l" 2
                        "package T\nfunc main(): Unit { println(\"hi\") }\n"
                    """{"jsonrpc":"2.0","method":"exit"}"""
                ]
            let pubs =
                out
                |> List.filter (fun n -> propStr n "method" = "textDocument/publishDiagnostics")
            Expect.isGreaterThanOrEqual pubs.Length 2
                "two publishDiagnostics (open + change)"
            let last = List.last pubs
            match prop last "params" |> Option.bind (fun p -> prop p "diagnostics") with
            | Some (:? JsonArray as a) ->
                Expect.equal a.Count 0 "no diagnostics on clean source"
            | _ -> failtest "diagnostics array missing on last publish"

        testCase "shutdown returns a response with matching id" <| fun () ->
            let out =
                runWith [
                    """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"""
                    """{"jsonrpc":"2.0","id":7,"method":"shutdown"}"""
                    """{"jsonrpc":"2.0","method":"exit"}"""
                ]
            let sd = out |> List.tryFind (fun n -> propInt n "id" = 7)
            Expect.isSome sd "shutdown reply present"

        testCase "unknown request gets method-not-found error" <| fun () ->
            let out =
                runWith [
                    """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"""
                    """{"jsonrpc":"2.0","id":42,"method":"some/unknown/thing"}"""
                    """{"jsonrpc":"2.0","method":"exit"}"""
                ]
            let unk = out |> List.tryFind (fun n -> propInt n "id" = 42)
            match unk with
            | None -> failtest "no reply for unknown request"
            | Some r ->
                match prop r "error" with
                | None -> failtest "expected error payload"
                | Some err ->
                    Expect.equal (propInt err "code") -32601 "method-not-found"

        testCase "initialize advertises completion + definition (D-progress-066)" <| fun () ->
            let out =
                runWith [
                    """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"""
                    """{"jsonrpc":"2.0","method":"exit"}"""
                ]
            let resp = out.[0]
            match prop resp "result"
                  |> Option.bind (fun r -> prop r "capabilities") with
            | Some caps ->
                Expect.isSome (prop caps "completionProvider")
                    "completionProvider declared"
                Expect.isSome (prop caps "definitionProvider")
                    "definitionProvider declared"
            | None -> failtest "no capabilities"

        testCase "completion lists top-level items" <| fun () ->
            let source =
                "package T\n"
                + "pub func greet(name: in String): String { name }\n"
                + "pub record User { name: String }\n"
                + "func main(): Unit { println(\"hi\") }\n"
            let comp = JsonObject()
            comp.["jsonrpc"] <- JsonValue.Create "2.0"
            comp.["id"]      <- JsonValue.Create 5
            comp.["method"]  <- JsonValue.Create "textDocument/completion"
            let cp = JsonObject()
            let td = JsonObject()
            td.["uri"] <- JsonValue.Create "file:///t.l"
            cp.["textDocument"] <- td :> JsonNode
            let pos = JsonObject()
            pos.["line"]      <- JsonValue.Create 0
            pos.["character"] <- JsonValue.Create 0
            cp.["position"] <- pos :> JsonNode
            comp.["params"]  <- cp :> JsonNode
            let out =
                runWith [
                    """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"""
                    didOpenFor "file:///t.l" source
                    comp.ToJsonString()
                    """{"jsonrpc":"2.0","method":"exit"}"""
                ]
            let r = out |> List.tryFind (fun n -> propInt n "id" = 5)
            match r |> Option.bind (fun n -> prop n "result") with
            | Some (:? JsonArray as a) ->
                let labels =
                    a
                    |> Seq.choose (fun n ->
                        match Option.ofObj n with
                        | Some node -> Some (propStr node "label")
                        | None -> None)
                    |> Seq.toList
                Expect.contains labels "greet" "func name listed"
                Expect.contains labels "User" "record name listed"
                Expect.contains labels "main" "main listed"
            | _ -> failtest "completion result missing or not an array"

        testCase "hover on an identifier returns its summary" <| fun () ->
            let source =
                "package T\n"
                + "pub func greet(name: in String): String { name }\n"
                + "func main(): Unit { greet(\"x\") }\n"
            let req = JsonObject()
            req.["jsonrpc"] <- JsonValue.Create "2.0"
            req.["id"]      <- JsonValue.Create 8
            req.["method"]  <- JsonValue.Create "textDocument/hover"
            let rp = JsonObject()
            let td = JsonObject()
            td.["uri"] <- JsonValue.Create "file:///t.l"
            rp.["textDocument"] <- td :> JsonNode
            let pos = JsonObject()
            // Line 2 (0-indexed) col 22 — middle of "greet" call
            pos.["line"]      <- JsonValue.Create 2
            pos.["character"] <- JsonValue.Create 22
            rp.["position"] <- pos :> JsonNode
            req.["params"] <- rp :> JsonNode
            let out =
                runWith [
                    """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"""
                    didOpenFor "file:///t.l" source
                    req.ToJsonString()
                    """{"jsonrpc":"2.0","method":"exit"}"""
                ]
            let r = out |> List.tryFind (fun n -> propInt n "id" = 8)
            match r |> Option.bind (fun n -> prop n "result") with
            | Some res ->
                match prop res "contents" with
                | Some contents ->
                    let v = propStr contents "value"
                    Expect.stringContains v "greet" "hover mentions the func name"
                | None -> failtest "no contents on hover"
            | None -> failtest "hover response missing"

        testCase "definition on an identifier returns its location" <| fun () ->
            let source =
                "package T\n"
                + "pub func greet(name: in String): String { name }\n"
                + "func main(): Unit { greet(\"x\") }\n"
            let req = JsonObject()
            req.["jsonrpc"] <- JsonValue.Create "2.0"
            req.["id"]      <- JsonValue.Create 9
            req.["method"]  <- JsonValue.Create "textDocument/definition"
            let rp = JsonObject()
            let td = JsonObject()
            td.["uri"] <- JsonValue.Create "file:///t.l"
            rp.["textDocument"] <- td :> JsonNode
            let pos = JsonObject()
            pos.["line"]      <- JsonValue.Create 2
            pos.["character"] <- JsonValue.Create 22
            rp.["position"] <- pos :> JsonNode
            req.["params"] <- rp :> JsonNode
            let out =
                runWith [
                    """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"""
                    didOpenFor "file:///t.l" source
                    req.ToJsonString()
                    """{"jsonrpc":"2.0","method":"exit"}"""
                ]
            let r = out |> List.tryFind (fun n -> propInt n "id" = 9)
            match r |> Option.bind (fun n -> prop n "result") with
            | Some res ->
                Expect.equal (propStr res "uri") "file:///t.l" "uri echoed"
                Expect.isSome (prop res "range") "range present"
            | None -> failtest "definition response missing"

        testCase "initialize advertises signatureHelpProvider (D-lsp-001)" <| fun () ->
            let out =
                runWith [
                    """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"""
                    """{"jsonrpc":"2.0","method":"exit"}"""
                ]
            let resp = out.[0]
            match prop resp "result"
                  |> Option.bind (fun r -> prop r "capabilities") with
            | Some caps ->
                Expect.isSome (prop caps "signatureHelpProvider")
                    "signatureHelpProvider declared"
            | None -> failtest "no capabilities"

        testCase "signatureHelp returns signature for a call site (D-lsp-001)" <| fun () ->
            // Source: func add(a: in Int, b: in Int): Int
            // Cursor is inside `add(` — should get back the signature with activeParameter=0.
            let source =
                "package T\n"
                + "pub func add(a: in Int, b: in Int): Int { a }\n"
                + "func main(): Unit { let x = add(1, 2) }\n"
            // Position on line 2 (0-indexed), column 32 — inside `add(1, 2)` at the first arg.
            // "func main(): Unit { let x = add(" is 33 chars; col 32 = just after '('.
            let req = JsonObject()
            req.["jsonrpc"] <- JsonValue.Create "2.0"
            req.["id"]      <- JsonValue.Create 10
            req.["method"]  <- JsonValue.Create "textDocument/signatureHelp"
            let rp = JsonObject()
            let td = JsonObject()
            td.["uri"] <- JsonValue.Create "file:///t.l"
            rp.["textDocument"] <- td :> JsonNode
            let pos = JsonObject()
            pos.["line"]      <- JsonValue.Create 2
            pos.["character"] <- JsonValue.Create 32   // just after the '('
            rp.["position"] <- pos :> JsonNode
            req.["params"] <- rp :> JsonNode
            let out =
                runWith [
                    """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"""
                    didOpenFor "file:///t.l" source
                    req.ToJsonString()
                    """{"jsonrpc":"2.0","method":"exit"}"""
                ]
            let r = out |> List.tryFind (fun n -> propInt n "id" = 10)
            match r |> Option.bind (fun n -> prop n "result") with
            | Some res ->
                match prop res "signatures" with
                | Some (:? JsonArray as sigs) ->
                    Expect.isGreaterThan sigs.Count 0 "at least one signature"
                    let sig0 = Option.ofObj sigs.[0] |> Option.defaultWith (fun () -> failtest "sig0 null"; JsonObject() :> JsonNode)
                    let label = propStr sig0 "label"
                    Expect.stringContains label "add" "label contains function name"
                    Expect.stringContains label "Int" "label contains param type"
                    Expect.equal (propInt res "activeSignature") 0 "activeSignature=0"
                    Expect.equal (propInt res "activeParameter") 0 "activeParameter=0 (first arg)"
                | _ -> failtest "signatures array missing or wrong type"
            | None -> failtest "signatureHelp response missing"

        testCase "signatureHelp activeParameter advances past comma (D-lsp-001)" <| fun () ->
            let source =
                "package T\n"
                + "pub func add(a: in Int, b: in Int): Int { a }\n"
                + "func main(): Unit { let x = add(1, 2) }\n"
            // Column 35 = just after the ',' and space, landing on the `2` (second arg).
            let req = JsonObject()
            req.["jsonrpc"] <- JsonValue.Create "2.0"
            req.["id"]      <- JsonValue.Create 11
            req.["method"]  <- JsonValue.Create "textDocument/signatureHelp"
            let rp = JsonObject()
            let td = JsonObject()
            td.["uri"] <- JsonValue.Create "file:///t.l"
            rp.["textDocument"] <- td :> JsonNode
            let pos = JsonObject()
            pos.["line"]      <- JsonValue.Create 2
            pos.["character"] <- JsonValue.Create 35   // past the comma
            rp.["position"] <- pos :> JsonNode
            req.["params"] <- rp :> JsonNode
            let out =
                runWith [
                    """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"""
                    didOpenFor "file:///t.l" source
                    req.ToJsonString()
                    """{"jsonrpc":"2.0","method":"exit"}"""
                ]
            let r = out |> List.tryFind (fun n -> propInt n "id" = 11)
            match r |> Option.bind (fun n -> prop n "result") with
            | Some res ->
                Expect.equal (propInt res "activeParameter") 1
                    "activeParameter=1 (second arg)"
            | None -> failtest "signatureHelp response missing"

        testCase "hover shows full resolved signature for a function (D-lsp-001)" <| fun () ->
            let source =
                "package T\n"
                + "pub func add(a: in Int, b: in Int): Int { a }\n"
                + "func main(): Unit { add(1, 2) }\n"
            // Hover on 'add' in the call on line 2.
            let req = JsonObject()
            req.["jsonrpc"] <- JsonValue.Create "2.0"
            req.["id"]      <- JsonValue.Create 12
            req.["method"]  <- JsonValue.Create "textDocument/hover"
            let rp = JsonObject()
            let td = JsonObject()
            td.["uri"] <- JsonValue.Create "file:///t.l"
            rp.["textDocument"] <- td :> JsonNode
            let pos = JsonObject()
            pos.["line"]      <- JsonValue.Create 2
            pos.["character"] <- JsonValue.Create 21  // on 'add' in the call
            rp.["position"] <- pos :> JsonNode
            req.["params"] <- rp :> JsonNode
            let out =
                runWith [
                    """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"""
                    didOpenFor "file:///t.l" source
                    req.ToJsonString()
                    """{"jsonrpc":"2.0","method":"exit"}"""
                ]
            let r = out |> List.tryFind (fun n -> propInt n "id" = 12)
            match r |> Option.bind (fun n -> prop n "result") with
            | Some res ->
                match prop res "contents" with
                | Some contents ->
                    let v = propStr contents "value"
                    // Full signature — contains param names and types, not just `add(...)`.
                    Expect.stringContains v "add"  "hover mentions function name"
                    Expect.stringContains v "Int"  "hover mentions param type"
                    Expect.isFalse (v.Contains "...") "hover shows full params, not '...'"
                | None -> failtest "no contents on hover"
            | None -> failtest "hover response missing"
    ]

// ---------------------------------------------------------------------------
// M-L4 — workspace / cross-file tests.
// ---------------------------------------------------------------------------

/// Write a Lyric source file to a temp path and return the path + URI.
let private withTempLyricFiles
        (files: (string * string) list)
        (body:  (string -> (string * string) list -> unit)) =
    let dir = Path.Combine(Path.GetTempPath(), "lyric-lsp-test-" + Guid.NewGuid().ToString("N"))
    Directory.CreateDirectory(dir) |> ignore
    try
        let written =
            files
            |> List.map (fun (name, src) ->
                let path = Path.Combine(dir, name)
                File.WriteAllText(path, src)
                path, Uri(path).AbsoluteUri)
        body dir written
    finally
        try Directory.Delete(dir, true) with _ -> ()

let workspaceTests =
    testList "Lyric LSP — workspace (M-L4)" [

        testCase "workspace/didChangeWatchedFiles is handled without error" <| fun () ->
            let notif =
                """{"jsonrpc":"2.0","method":"workspace/didChangeWatchedFiles","params":{"changes":[{"uri":"file:///tmp/x.l","type":2}]}}"""
            let out =
                runWith [
                    """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"""
                    notif
                    """{"jsonrpc":"2.0","method":"exit"}"""
                ]
            // The notification has no id, so no reply is expected; the server
            // must not crash — verify it handled exit cleanly.
            Expect.isNonEmpty out "initialize reply present"
            let initReply = out |> List.tryFind (fun n -> propInt n "id" = 1)
            Expect.isSome initReply "initialize reply is present after didChangeWatchedFiles"

        testCase "initialize with rootUri builds workspace index" <| fun () ->
            // Write two files: a library and a consumer.
            withTempLyricFiles
                [ "lib.l",
                    "package Greetings\n\npub func hello(name: in String): String { name }\n"
                  "main.l",
                    "package Main\nimport Greetings\nfunc main(): Unit { hello(\"world\") }\n" ]
                (fun dir written ->
                    let rootUri = Uri(dir).AbsoluteUri
                    let (_, mainUri) = written |> List.find (fun (p, _) -> p.EndsWith "main.l")
                    let mainSrc = File.ReadAllText(fst (written |> List.find (fun (p, _) -> p.EndsWith "main.l")))
                    let initMsg =
                        sprintf """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootUri":"%s"}}""" rootUri
                    let out =
                        runWith [
                            initMsg
                            didOpenFor mainUri mainSrc
                            """{"jsonrpc":"2.0","method":"exit"}"""
                        ]
                    // The server must have initialized without crashing.
                    let initReply = out |> List.tryFind (fun n -> propInt n "id" = 1)
                    Expect.isSome initReply "initialize reply present"
                    // Diagnostics for main.l: with cross-file resolution `hello` is
                    // known, so there should be no T0043/undefined-name errors.
                    let pub =
                        out
                        |> List.tryFind (fun n ->
                            propStr n "method" = "textDocument/publishDiagnostics"
                            && (match prop n "params" |> Option.bind (fun p -> prop p "uri") with
                                | Some u -> u.GetValue<string>() = mainUri
                                | None   -> false))
                    match pub with
                    | None ->
                        // No diagnostic event is also fine — means no errors were published.
                        ()
                    | Some n ->
                        match prop n "params" |> Option.bind (fun p -> prop p "diagnostics") with
                        | Some (:? JsonArray as a) ->
                            // If diagnostics were published, check none are T0043 (undefined name).
                            let hasUndefined =
                                a |> Seq.exists (fun d ->
                                    match Option.ofObj d with
                                    | Some node ->
                                        match prop node "code" with
                                        | Some c -> (try c.GetValue<string>() with _ -> "") = "T0043"
                                        | None -> false
                                    | None -> false)
                            Expect.isFalse hasUndefined
                                "cross-file import resolves hello — no T0043"
                        | _ -> ())

        testCase "completion includes symbols from imported packages (M-L4)" <| fun () ->
            withTempLyricFiles
                [ "mathlib.l",
                    "package MathLib\n\npub func square(n: in Int): Int { n }\n"
                  "consumer.l",
                    "package Consumer\nimport MathLib\nfunc main(): Unit { square(2) }\n" ]
                (fun dir written ->
                    let rootUri = Uri(dir).AbsoluteUri
                    let (consumerPath, consumerUri) =
                        written |> List.find (fun (p, _) -> p.EndsWith "consumer.l")
                    let consumerSrc = File.ReadAllText consumerPath
                    let initMsg =
                        sprintf """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootUri":"%s"}}""" rootUri
                    let compReq = JsonObject()
                    compReq.["jsonrpc"] <- JsonValue.Create "2.0"
                    compReq.["id"]      <- JsonValue.Create 20
                    compReq.["method"]  <- JsonValue.Create "textDocument/completion"
                    let cp = JsonObject()
                    let td = JsonObject()
                    td.["uri"] <- JsonValue.Create consumerUri
                    cp.["textDocument"] <- td :> JsonNode
                    let pos = JsonObject()
                    pos.["line"]      <- JsonValue.Create 0
                    pos.["character"] <- JsonValue.Create 0
                    cp.["position"] <- pos :> JsonNode
                    compReq.["params"] <- cp :> JsonNode
                    let out =
                        runWith [
                            initMsg
                            didOpenFor consumerUri consumerSrc
                            compReq.ToJsonString()
                            """{"jsonrpc":"2.0","method":"exit"}"""
                        ]
                    let r = out |> List.tryFind (fun n -> propInt n "id" = 20)
                    match r |> Option.bind (fun n -> prop n "result") with
                    | Some (:? JsonArray as a) ->
                        let labels =
                            a |> Seq.choose (fun n ->
                                match Option.ofObj n with
                                | Some node -> Some (propStr node "label")
                                | None -> None)
                            |> Seq.toList
                        // `square` comes from the imported MathLib package.
                        Expect.contains labels "square"
                            "imported symbol 'square' appears in completion"
                    | _ -> failtest "completion result missing or not an array")

        testCase "go-to-definition resolves to imported file (M-L4)" <| fun () ->
            withTempLyricFiles
                [ "shapes.l",
                    "package Shapes\n\npub record Circle { radius: Int }\n"
                  "drawing.l",
                    "package Drawing\nimport Shapes\nfunc draw(c: in Circle): Unit { }\n" ]
                (fun dir written ->
                    let rootUri = Uri(dir).AbsoluteUri
                    let (drawingPath, drawingUri) =
                        written |> List.find (fun (p, _) -> p.EndsWith "drawing.l")
                    let (_, shapesUri) =
                        written |> List.find (fun (p, _) -> p.EndsWith "shapes.l")
                    let drawingSrc = File.ReadAllText drawingPath
                    let initMsg =
                        sprintf """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootUri":"%s"}}""" rootUri
                    let defReq = JsonObject()
                    defReq.["jsonrpc"] <- JsonValue.Create "2.0"
                    defReq.["id"]      <- JsonValue.Create 21
                    defReq.["method"]  <- JsonValue.Create "textDocument/definition"
                    let dp = JsonObject()
                    let td = JsonObject()
                    td.["uri"] <- JsonValue.Create drawingUri
                    dp.["textDocument"] <- td :> JsonNode
                    // Line 2 (0-indexed), "func draw(c: in Circle)" — "Circle" starts at col 17.
                    let pos = JsonObject()
                    pos.["line"]      <- JsonValue.Create 2
                    pos.["character"] <- JsonValue.Create 17
                    dp.["position"] <- pos :> JsonNode
                    defReq.["params"] <- dp :> JsonNode
                    let out =
                        runWith [
                            initMsg
                            didOpenFor drawingUri drawingSrc
                            defReq.ToJsonString()
                            """{"jsonrpc":"2.0","method":"exit"}"""
                        ]
                    let r = out |> List.tryFind (fun n -> propInt n "id" = 21)
                    match r |> Option.bind (fun n -> prop n "result") with
                    | Some res ->
                        // The definition should point at shapes.l, not drawing.l.
                        let targetUri = propStr res "uri"
                        Expect.equal targetUri shapesUri
                            "definition of imported type resolves to the declaring file"
                        Expect.isSome (prop res "range") "range is present"
                    | None -> failtest "definition response missing")

        testCase "buildWorkspaceIndex maps package names to files" <| fun () ->
            withTempLyricFiles
                [ "alpha.l", "package Alpha\npub func f(): Unit { }\n"
                  "beta.l",  "package Beta.Sub\npub func g(): Unit { }\n" ]
                (fun dir _ ->
                    let idx = buildWorkspaceIndex dir
                    Expect.isTrue  (idx.PackageToFile |> Map.containsKey "Alpha")
                        "Alpha is indexed"
                    Expect.isTrue  (idx.PackageToFile |> Map.containsKey "Beta.Sub")
                        "Beta.Sub is indexed"
                    Expect.isFalse (idx.PackageToFile |> Map.containsKey "Gamma")
                        "Gamma is not indexed")
    ]
