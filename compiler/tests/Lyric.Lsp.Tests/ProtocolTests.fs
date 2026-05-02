/// End-to-end protocol tests for the bootstrap Lyric LSP.
///
/// We drive the server in-process by piping pre-formed JSON-RPC frames
/// into `Server.runLoop` over a `MemoryStream` pair, then parse the
/// captured stdout back into individual frames.  No `dotnet exec`,
/// no real stdio — the streams are just buffers.
module Lyric.Lsp.Tests.ProtocolTests

open System.IO
open System.Text
open System.Text.Json.Nodes
open Expecto
open Lyric.Lsp

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
        match o.TryGetPropertyValue path with
        | true, v -> Option.ofObj v
        | _ -> None
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
    ]
