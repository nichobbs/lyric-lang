/// Minimal JSON-RPC 2.0 framing over stdio for the Lyric LSP.
///
/// The LSP transport per spec is "Content-Length: N\r\n\r\n<body>"
/// where the body is a JSON-RPC payload.  We sidestep heavyweight
/// libraries (StreamJsonRpc, OmniSharp.Extensions.LanguageServer)
/// because all we need is: read a frame, write a frame.  System.Text.Json
/// handles the JSON; the framing is ~20 lines.
module Lyric.Lsp.JsonRpc

open System
open System.IO
open System.Text
open System.Text.Json
open System.Text.Json.Nodes

/// Read one LSP-framed message from `input`.  Returns the raw body
/// as a JsonNode, or `None` on clean EOF.  The caller decides what
/// to do with malformed frames.
let readMessage (input: Stream) : JsonNode option =
    // Headers: read line by line until empty line.  LSP only really
    // uses Content-Length; Content-Type defaults to UTF-8 JSON.  We
    // accept both \r\n and bare \n to be lenient.
    let mutable contentLength = -1
    let mutable headerDone = false
    let mutable eof = false
    while not headerDone && not eof do
        let line = StringBuilder()
        let mutable lineDone = false
        while not lineDone && not eof do
            let b = input.ReadByte()
            if b = -1 then eof <- true
            elif b = int '\n' then lineDone <- true
            elif b = int '\r' then ()
            else line.Append(char b) |> ignore
        if eof then ()
        elif line.Length = 0 then headerDone <- true
        else
            let s = line.ToString()
            let idx = s.IndexOf(':')
            if idx > 0 then
                let key   = s.Substring(0, idx).Trim()
                let value = s.Substring(idx + 1).Trim()
                if String.Equals(key, "Content-Length", StringComparison.OrdinalIgnoreCase) then
                    contentLength <- Int32.Parse(value)
    if eof || contentLength < 0 then None
    else
        let buffer = Array.zeroCreate<byte> contentLength
        let mutable read = 0
        while read < contentLength do
            let n = input.Read(buffer, read, contentLength - read)
            if n <= 0 then read <- contentLength   // give up on truncated input
            else read <- read + n
        let json = Encoding.UTF8.GetString(buffer)
        try
            match Option.ofObj (JsonNode.Parse(json)) with
            | Some n -> Some n
            | None   -> None
        with _ -> None

let private serializerOpts =
    let o = JsonSerializerOptions()
    o.WriteIndented <- false
    o

/// Write one LSP-framed message to `output`.  Caller passes a fully-
/// formed JsonNode (request/response/notification per JSON-RPC 2.0).
let writeMessage (output: Stream) (msg: JsonNode) : unit =
    let body  = msg.ToJsonString(serializerOpts)
    let bytes = Encoding.UTF8.GetBytes(body)
    let header =
        sprintf "Content-Length: %d\r\n\r\n" bytes.Length
        |> Encoding.UTF8.GetBytes
    output.Write(header, 0, header.Length)
    output.Write(bytes, 0, bytes.Length)
    output.Flush()

let private cloneIdOrNull (id: JsonNode | null) : JsonNode | null =
    match Option.ofObj id with
    | Some n -> n.DeepClone()
    | None   -> null

/// Build a JSON-RPC response payload.  `id` echoes the request's id.
let mkResponse (id: JsonNode | null) (result: JsonNode) : JsonNode =
    let o = JsonObject()
    o.["jsonrpc"] <- JsonValue.Create "2.0"
    o.["id"]      <- cloneIdOrNull id
    o.["result"]  <- result
    o :> JsonNode

let mkErrorResponse (id: JsonNode | null) (code: int) (message: string) : JsonNode =
    let o = JsonObject()
    o.["jsonrpc"] <- JsonValue.Create "2.0"
    o.["id"]      <- cloneIdOrNull id
    let err = JsonObject()
    err.["code"]    <- JsonValue.Create code
    err.["message"] <- JsonValue.Create message
    o.["error"] <- err
    o :> JsonNode

/// Build a JSON-RPC notification (no id, no response expected).
let mkNotification (method': string) (paramsObj: JsonNode) : JsonNode =
    let o = JsonObject()
    o.["jsonrpc"] <- JsonValue.Create "2.0"
    o.["method"]  <- JsonValue.Create method'
    o.["params"]  <- paramsObj
    o :> JsonNode
