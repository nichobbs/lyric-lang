/// OpenAPI 3.x spec model and JSON parser.
///
/// Parses a subset of OpenAPI 3.0/3.1 sufficient to generate a typed
/// Lyric REST client: paths, operations (get/post/put/patch/delete),
/// path and query parameters, JSON request/response bodies, and inline
/// schema objects (object, string, integer, number, boolean, array).
///
/// The parser is intentionally lenient: unknown fields are silently
/// ignored so real-world specs with vendor extensions do not abort.
///
/// Usage:
///   let spec = OpenApi.parseFile "petstore.json"
///   // or from a string:
///   let spec = OpenApi.parseText jsonSource
module Lyric.Cli.OpenApi

open System
open System.Text.Json

// ---------------------------------------------------------------------------
// Schema model.
// ---------------------------------------------------------------------------

/// The JSON/OpenAPI schema type of a property or parameter.
type SchemaKind =
    | String_
    | Integer
    | Number
    | Boolean
    | Array  of itemKind : SchemaKind
    | Object of properties : Property list
    | Unknown

/// One property in an object schema.
and Property = {
    Name     : string
    Kind     : SchemaKind
    Required : bool
}

// ---------------------------------------------------------------------------
// Parameter model.
// ---------------------------------------------------------------------------

type ParameterIn = Path | Query | Header | Cookie

type Parameter = {
    Name        : string
    In          : ParameterIn
    Required    : bool
    Description : string
    Kind        : SchemaKind
}

// ---------------------------------------------------------------------------
// Request / response body model.
// ---------------------------------------------------------------------------

type RequestBody = {
    Required    : bool
    Description : string
    Kind        : SchemaKind     // schema of the application/json content
}

type ResponseBody = {
    StatusCode  : string         // "200", "201", "default", …
    Description : string
    Kind        : SchemaKind     // None_ when body is absent
}

// ---------------------------------------------------------------------------
// Operation model.
// ---------------------------------------------------------------------------

type HttpVerb = Get | Post | Put | Patch | Delete | Head | Options

type Operation = {
    OperationId : string
    Verb        : HttpVerb
    Path        : string
    Summary     : string
    Description : string
    Parameters  : Parameter list
    RequestBody : RequestBody option
    Responses   : ResponseBody list
    Tags        : string list
}

// ---------------------------------------------------------------------------
// Top-level spec model.
// ---------------------------------------------------------------------------

type Info = {
    Title       : string
    Description : string
    Version     : string
}

type Spec = {
    Info       : Info
    BasePath   : string       // from servers[0].url, stripped of {vars}
    Operations : Operation list
}

// ---------------------------------------------------------------------------
// JSON navigation helpers (over System.Text.Json).
// ---------------------------------------------------------------------------

let private strProp (el: JsonElement) (key: string) =
    match el.TryGetProperty key with
    | true, v when v.ValueKind = JsonValueKind.String ->
        match v.GetString() with
        | null -> ""
        | s    -> s
    | _ -> ""

let private boolProp (el: JsonElement) (key: string) (def: bool) =
    match el.TryGetProperty key with
    | true, v when v.ValueKind = JsonValueKind.True  -> true
    | true, v when v.ValueKind = JsonValueKind.False -> false
    | _ -> def

let private tryObj (el: JsonElement) (key: string) =
    match el.TryGetProperty key with
    | true, v when v.ValueKind = JsonValueKind.Object -> Some v
    | _ -> None

let private tryArr (el: JsonElement) (key: string) =
    match el.TryGetProperty key with
    | true, v when v.ValueKind = JsonValueKind.Array -> Some v
    | _ -> None

// ---------------------------------------------------------------------------
// Schema parsing.
// ---------------------------------------------------------------------------

let rec private parseSchema (el: JsonElement) : SchemaKind =
    let ty = strProp el "type"
    match ty with
    | "string"  -> String_
    | "integer" -> Integer
    | "number"  -> Number
    | "boolean" -> Boolean
    | "array"   ->
        match tryObj el "items" with
        | Some items -> Array (parseSchema items)
        | None       -> Array Unknown
    | "object" | "" ->
        // Treat "object" and bare `{}` the same.  Pull required[] set.
        let requiredSet =
            match tryArr el "required" with
            | None -> Set.empty
            | Some arr ->
                arr.EnumerateArray()
                |> Seq.choose (fun v ->
                    if v.ValueKind = JsonValueKind.String then
                        match v.GetString() with
                        | null -> None
                        | s    -> Some s
                    else None)
                |> Set.ofSeq
        let props =
            match tryObj el "properties" with
            | None -> []
            | Some propsEl ->
                propsEl.EnumerateObject()
                |> Seq.map (fun kv ->
                    { Name     = kv.Name
                      Kind     = parseSchema kv.Value
                      Required = Set.contains kv.Name requiredSet })
                |> Seq.toList
        if List.isEmpty props then Unknown
        else Object props
    | _ -> Unknown

// ---------------------------------------------------------------------------
// Parameter parsing.
// ---------------------------------------------------------------------------

let private parseParamIn (raw: string) =
    match raw.ToLowerInvariant() with
    | "path"   -> Path
    | "query"  -> Query
    | "header" -> Header
    | "cookie" -> Cookie
    | _        -> Query

let private parseParameter (el: JsonElement) : Parameter =
    let schemaKind =
        match tryObj el "schema" with
        | Some s -> parseSchema s
        | None   -> Unknown
    { Name        = strProp el "name"
      In          = parseParamIn (strProp el "in")
      Required    = boolProp el "required" false
      Description = strProp el "description"
      Kind        = schemaKind }

// ---------------------------------------------------------------------------
// Request body parsing.
// ---------------------------------------------------------------------------

let private parseRequestBody (el: JsonElement) : RequestBody =
    let kind =
        tryObj el "content"
        |> Option.bind (fun content ->
            tryObj content "application/json")
        |> Option.bind (fun mediaType ->
            tryObj mediaType "schema")
        |> Option.map parseSchema
        |> Option.defaultValue Unknown
    { Required    = boolProp el "required" false
      Description = strProp el "description"
      Kind        = kind }

// ---------------------------------------------------------------------------
// Response parsing.
// ---------------------------------------------------------------------------

let private parseResponse (statusCode: string) (el: JsonElement) : ResponseBody =
    let kind =
        tryObj el "content"
        |> Option.bind (fun content ->
            tryObj content "application/json")
        |> Option.bind (fun mediaType ->
            tryObj mediaType "schema")
        |> Option.map parseSchema
        |> Option.defaultValue Unknown
    { StatusCode  = statusCode
      Description = strProp el "description"
      Kind        = kind }

// ---------------------------------------------------------------------------
// Operation parsing.
// ---------------------------------------------------------------------------

let private parseTags (el: JsonElement) : string list =
    match tryArr el "tags" with
    | None -> []
    | Some arr ->
        arr.EnumerateArray()
        |> Seq.choose (fun v ->
            if v.ValueKind = JsonValueKind.String then
                match v.GetString() with
                | null -> None
                | s    -> Some s
            else None)
        |> Seq.toList

let private parseOperation
        (verb: HttpVerb)
        (path: string)
        (el: JsonElement) : Operation =
    let parameters =
        match tryArr el "parameters" with
        | None -> []
        | Some arr ->
            arr.EnumerateArray()
            |> Seq.map parseParameter
            |> Seq.toList
    let requestBody =
        tryObj el "requestBody"
        |> Option.map parseRequestBody
    let responses =
        match tryObj el "responses" with
        | None -> []
        | Some resp ->
            resp.EnumerateObject()
            |> Seq.map (fun kv -> parseResponse kv.Name kv.Value)
            |> Seq.toList
    // Synthesise an operationId from verb + path when the spec omits it.
    let defaultId =
        let slug =
            path.Split('/', StringSplitOptions.RemoveEmptyEntries)
            |> Array.map (fun seg ->
                if seg.StartsWith "{" then
                    // {petId} -> ByPetId
                    let inner = seg.TrimStart('{').TrimEnd('}')
                    "By" + inner.[0..0].ToUpperInvariant() + inner.[1..]
                else
                    seg.[0..0].ToUpperInvariant() + seg.[1..])
            |> String.concat ""
        (sprintf "%A" verb).ToLowerInvariant() + slug
    let operationId =
        match strProp el "operationId" with
        | "" -> defaultId
        | s  -> s
    { OperationId = operationId
      Verb        = verb
      Path        = path
      Summary     = strProp el "summary"
      Description = strProp el "description"
      Parameters  = parameters
      RequestBody = requestBody
      Responses   = responses
      Tags        = parseTags el }

let private verbFromKey (key: string) : HttpVerb option =
    match key.ToLowerInvariant() with
    | "get"     -> Some Get
    | "post"    -> Some Post
    | "put"     -> Some Put
    | "patch"   -> Some Patch
    | "delete"  -> Some Delete
    | "head"    -> Some Head
    | "options" -> Some Options
    | _         -> None

// ---------------------------------------------------------------------------
// Top-level spec parsing.
// ---------------------------------------------------------------------------

let private parseInfo (root: JsonElement) : Info =
    match tryObj root "info" with
    | None ->
        { Title = "Api"; Description = ""; Version = "0.0.0" }
    | Some info ->
        { Title       = strProp info "title"
          Description = strProp info "description"
          Version     = strProp info "version" }

let private parseBasePath (root: JsonElement) : string =
    match tryArr root "servers" with
    | None -> ""
    | Some arr ->
        let first = arr.EnumerateArray() |> Seq.tryHead
        match first with
        | None -> ""
        | Some srv ->
            let url = strProp srv "url"
            // Strip trailing slash; strip variable templates like {basePath}.
            let stripped =
                let mutable s = url.TrimEnd('/')
                while s.Contains "{" && s.Contains "}" do
                    let lbrace = s.LastIndexOf '{'
                    let rbrace = s.IndexOf('}', lbrace)
                    if rbrace > lbrace then
                        s <- s.[..lbrace - 1].TrimEnd('/').TrimEnd('{')
                    else
                        s <- s.[..lbrace - 1]
                s
            stripped

let private parsePaths (root: JsonElement) : Operation list =
    match tryObj root "paths" with
    | None -> []
    | Some paths ->
        [ for pathItem in paths.EnumerateObject() do
            let path = pathItem.Name
            // Merge path-level parameters into each operation's parameter list.
            let pathLevelParams =
                match tryArr pathItem.Value "parameters" with
                | None -> []
                | Some arr ->
                    arr.EnumerateArray()
                    |> Seq.map parseParameter
                    |> Seq.toList
            for opItem in pathItem.Value.EnumerateObject() do
                match verbFromKey opItem.Name with
                | None -> ()
                | Some verb ->
                    let op = parseOperation verb path opItem.Value
                    // Path-level params are lower priority; deduplicate by name.
                    let opParamNames = op.Parameters |> List.map (fun p -> p.Name) |> Set.ofList
                    let merged =
                        op.Parameters
                        @ (pathLevelParams |> List.filter (fun p -> not (Set.contains p.Name opParamNames)))
                    yield { op with Parameters = merged } ]

/// Parse an OpenAPI 3.x spec from a JSON string.
let parseText (json: string) : Result<Spec, string> =
    try
        use doc = JsonDocument.Parse json
        let root = doc.RootElement
        let info       = parseInfo root
        let basePath   = parseBasePath root
        let operations = parsePaths root
        Ok { Info = info; BasePath = basePath; Operations = operations }
    with ex ->
        Error (sprintf "JSON parse error: %s" ex.Message)

/// Parse an OpenAPI 3.x spec from a file path (JSON only).
let parseFile (path: string) : Result<Spec, string> =
    try
        let text = System.IO.File.ReadAllText path
        parseText text
    with ex ->
        Error (sprintf "could not read '%s': %s" path ex.Message)
