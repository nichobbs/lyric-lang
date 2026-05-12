/// Lyric code generator for OpenAPI 3.x specs.
///
/// Takes a parsed `OpenApi.Spec` and emits a single `.l` file containing:
///
/// - One Lyric record per distinct named object schema (collected from
///   request/response bodies).  Unnamed / inline scalars produce no type.
/// - A `<ClientName>Client` opaque type wrapping `Std.Rest.RestClient`.
/// - One `async func` per OpenAPI operation, with path parameters
///   interpolated into the URL string and query parameters appended.
/// - A constructor `<ClientName>Client.create(baseUrl)` that delegates
///   to `RestClient.create`.
/// - A `withAuth` pass-through for attaching bearer / API-key tokens.
///
/// Bootstrap scope:
/// - Only `application/json` bodies are supported.
/// - Generic body deserialization is `RestClient.jsonBody` (returns raw
///   JSON string); typed field accessors for leaf scalars are emitted
///   for operations whose success response is a flat object schema.
/// - YAML specs are not yet supported; pass a JSON file.
module Lyric.Cli.OpenApiGen

open System
open System.Text

// ---------------------------------------------------------------------------
// Identifier helpers.
// ---------------------------------------------------------------------------

/// Convert a string to PascalCase (public; used by the CLI dispatch).
let toPascalPublic (s: string) =
    if String.IsNullOrEmpty s then "Unknown"
    else
        // Split on non-alphanumeric runs, capitalise each segment.
        let segments =
            s.Split([| ' '; '-'; '_'; '/'; '.'; '{'; '}' |],
                    StringSplitOptions.RemoveEmptyEntries)
        segments
        |> Array.map (fun seg ->
            if seg.Length = 0 then ""
            else seg.[0..0].ToUpperInvariant() + seg.[1..])
        |> String.concat ""

let private toPascal = toPascalPublic

let private toCamel (s: string) =
    let p = toPascal s
    if p.Length = 0 then "unknown"
    else p.[0..0].ToLowerInvariant() + p.[1..]

// ---------------------------------------------------------------------------
// Lyric type names for schema kinds.
// ---------------------------------------------------------------------------

let rec private lyricType (kind: OpenApi.SchemaKind) : string =
    match kind with
    | OpenApi.String_  -> "String"
    | OpenApi.Integer  -> "Int"
    | OpenApi.Number   -> "Double"
    | OpenApi.Boolean  -> "Bool"
    | OpenApi.Array k  -> "List[" + lyricType k + "]"
    | OpenApi.Object _ -> "String"   // raw JSON until derive(Json) lands
    | OpenApi.Unknown  -> "String"

// ---------------------------------------------------------------------------
// Named record types from object schemas.
// ---------------------------------------------------------------------------

/// Collect every named (non-scalar) object schema from the spec's
/// request and response bodies.  Returns `(typeName, properties)` pairs
/// de-duplicated by type name.
let private collectRecordTypes (spec: OpenApi.Spec) : (string * OpenApi.Property list) list =
    let seen = System.Collections.Generic.HashSet<string>()
    [ for op in spec.Operations do
        let schemas =
            [ match op.RequestBody with
              | Some rb -> yield rb.Kind
              | None    -> ()
              for r in op.Responses do
                yield r.Kind ]
        for schema in schemas do
            match schema with
            | OpenApi.Object props ->
                let name = toPascal op.OperationId + "Body"
                if seen.Add name then
                    yield name, props
            | _ -> () ]

// ---------------------------------------------------------------------------
// Path parameter interpolation.
// ---------------------------------------------------------------------------

let private buildPathExpr (path: string) (pathParams: OpenApi.Parameter list) : string =
    // Replace `{paramName}` with `" + paramName + "` for string concat.
    // E.g. `/pets/{petId}/photos/{photoId}` →
    //   "/pets/" + petId + "/photos/" + photoId
    let paramNames = pathParams |> List.map (fun p -> p.Name) |> Set.ofList
    let mutable result = path
    for name in paramNames do
        result <- result.Replace("{" + name + "}", "\" + " + toCamel name + " + \"")
    // Wrap in quotes; strip trailing empty-string concat that appears
    // when a path ends with a path-parameter template.
    let wrapped = "\"" + result + "\""
    let trailingEmpty = " + \"\""
    if wrapped.EndsWith trailingEmpty then
        wrapped.[..wrapped.Length - trailingEmpty.Length - 1]
    else
        wrapped

// ---------------------------------------------------------------------------
// Query string builder expression.
// ---------------------------------------------------------------------------

let private buildQueryExpr (queryParams: OpenApi.Parameter list) : string option =
    if List.isEmpty queryParams then None
    else
        // Emit: "?key1=" + key1 + "&key2=" + key2 (all strings for now)
        let parts =
            queryParams
            |> List.mapi (fun i p ->
                let sep = if i = 0 then "?" else "&"
                "\"" + sep + p.Name + "=\" + " + toCamel p.Name)
        Some (String.concat " + " parts)

// ---------------------------------------------------------------------------
// Code generation.
// ---------------------------------------------------------------------------

type GenOptions = {
    ClientName   : string   // e.g. "Petstore" → PetstoreClient
    PackageName  : string   // e.g. "MyApp.Petstore"
}

/// Derive the default gen options from a parsed spec (public).
let defaultOptions (spec: OpenApi.Spec) : GenOptions =
    let title = if String.IsNullOrWhiteSpace spec.Info.Title then "Api" else spec.Info.Title
    { ClientName  = toPascal title
      PackageName = "Gen." + toPascal title }

/// Generate the full `.l` source for a typed REST client from an OpenAPI spec.
let generate (spec: OpenApi.Spec) (opts: GenOptions option) : string =
    let o = opts |> Option.defaultWith (fun () -> defaultOptions spec)
    let clientTypeName = o.ClientName + "Client"
    let sb = StringBuilder()

    let line (s: string) = sb.AppendLine s |> ignore
    let blank ()         = sb.AppendLine "" |> ignore

    // ---------------------------------------------------------------------------
    // Header.
    // ---------------------------------------------------------------------------
    line (sprintf "// Generated by `lyric openapi` from OpenAPI %s." spec.Info.Version)
    line (sprintf "// Title: %s" spec.Info.Title)
    if not (String.IsNullOrWhiteSpace spec.Info.Description) then
        line (sprintf "// %s" spec.Info.Description)
    blank ()
    line "@runtime_checked"
    line (sprintf "package %s" o.PackageName)
    blank ()
    line "import Std.Core"
    line "import Std.Rest"
    blank ()

    // ---------------------------------------------------------------------------
    // Named record types.
    // ---------------------------------------------------------------------------
    let records = collectRecordTypes spec
    for (typeName, props) in records do
        line (sprintf "/// Generated record for '%s' schema." typeName)
        line (sprintf "pub record %s {" typeName)
        for p in props do
            let annotation = if p.Required then "" else "  // optional"
            line (sprintf "  %s: %s%s" (toCamel p.Name) (lyricType p.Kind) annotation)
        line "}"
        blank ()

    // ---------------------------------------------------------------------------
    // Client opaque type.
    // ---------------------------------------------------------------------------
    line (sprintf "/// Typed REST client for the %s API." o.ClientName)
    line (sprintf "/// Base URL: %s" (if String.IsNullOrWhiteSpace spec.BasePath then "(caller-supplied)" else spec.BasePath))
    line "@stable(since=\"1.0\")"
    line (sprintf "pub opaque type %s {" clientTypeName)
    line "  inner: RestClient"
    line "}"
    blank ()

    // Constructor.
    let defaultBase =
        if String.IsNullOrWhiteSpace spec.BasePath then ""
        else spec.BasePath
    line (sprintf "/// Construct a %s.  `baseUrl` overrides the default base URL." clientTypeName)
    line "@stable(since=\"1.0\")"
    line (sprintf "pub func %s.create(baseUrl: in String): %s {" clientTypeName clientTypeName)
    line (sprintf "  return %s(inner = RestClient.create(baseUrl))" clientTypeName)
    line "}"
    blank ()

    // Default base URL convenience constructor (when the spec provides one).
    if not (String.IsNullOrWhiteSpace defaultBase) then
        line (sprintf "/// Construct a %s using the spec's default base URL." clientTypeName)
        line "@stable(since=\"1.0\")"
        line (sprintf "pub func %s.default(): %s {" clientTypeName clientTypeName)
        line (sprintf "  return %s.create(\"%s\")" clientTypeName defaultBase)
        line "}"
        blank ()

    // withAuth pass-through.
    line (sprintf "/// Attach an authentication strategy (Bearer, Basic, ApiKey).")
    line "@pure"
    line "@stable(since=\"1.0\")"
    line (sprintf "pub func %s.withAuth(client: in %s, auth: in RestAuth): %s {"
                  clientTypeName clientTypeName clientTypeName)
    line (sprintf "  return %s(inner = RestClient.withAuth(client.inner, auth))"
                  clientTypeName)
    line "}"
    blank ()

    // ---------------------------------------------------------------------------
    // Operation methods.
    // ---------------------------------------------------------------------------
    for op in spec.Operations do
        let pathParams  = op.Parameters |> List.filter (fun p -> p.In = OpenApi.Path)
        let queryParams = op.Parameters |> List.filter (fun p -> p.In = OpenApi.Query)
        let hasBody     = Option.isSome op.RequestBody

        // Determine the primary success response kind (first 2xx or "default").
        let successResp =
            op.Responses
            |> List.tryFind (fun r ->
                r.StatusCode.StartsWith "2" || r.StatusCode = "default")

        // Build function signature.
        let funcName = toCamel op.OperationId

        // Path parameter arguments.
        let pathArgs =
            pathParams
            |> List.map (fun p ->
                sprintf "%s: in %s" (toCamel p.Name) (lyricType p.Kind))

        // Query parameter arguments (all optional Strings for now).
        let queryArgs =
            queryParams
            |> List.map (fun p ->
                sprintf "%s: in %s" (toCamel p.Name) (lyricType p.Kind))

        // Body argument when the operation has a request body.
        let bodyArg =
            if hasBody then [ "body: in String" ] else []

        let allArgs = pathArgs @ queryArgs @ bodyArg
        let argsStr =
            ("client: in " + clientTypeName)
            :: allArgs
            |> String.concat ", "

        // Doc comment.
        if not (String.IsNullOrWhiteSpace op.Summary) then
            line (sprintf "/// %s" op.Summary)
        elif not (String.IsNullOrWhiteSpace op.Description) then
            line (sprintf "/// %s" op.Description)
        else
            line (sprintf "/// %s %s" (sprintf "%A" op.Verb) op.Path)

        line "@stable(since=\"1.0\")"
        line (sprintf "pub async func %s.%s(%s): Result[String, RestError] {"
                      clientTypeName funcName argsStr)

        // Build path expression.
        let pathExpr = buildPathExpr op.Path pathParams
        // Append query string if needed.
        let urlExpr =
            match buildQueryExpr queryParams with
            | None       -> pathExpr
            | Some qExpr -> pathExpr + " + " + qExpr

        let verbStr =
            match op.Verb with
            | OpenApi.Get     -> "get"
            | OpenApi.Post    -> "post"
            | OpenApi.Put     -> "put"
            | OpenApi.Patch   -> "patch"
            | OpenApi.Delete  -> "delete"
            | OpenApi.Head    -> "get"
            | OpenApi.Options -> "get"

        // Emit the underlying RestClient call.
        match op.Verb with
        | OpenApi.Get | OpenApi.Delete | OpenApi.Head | OpenApi.Options ->
            line (sprintf "  match await RestClient.%s(client.inner, %s) {" verbStr urlExpr)
        | _ ->
            let bodyExpr = if hasBody then "body" else "\"\""
            line (sprintf "  match await RestClient.%s(client.inner, %s, %s) {" verbStr urlExpr bodyExpr)

        line "    case Err(e) -> return Err(error = e)"
        line "    case Ok(response) ->"
        line "      match await RestClient.ensureSuccess(response, \"\") {"
        line "        case Err(e) -> return Err(error = e)"
        line "        case Ok(r) ->"
        line "          match await RestClient.jsonBody(r) {"
        line "            case Err(e) -> return Err(error = e)"
        line "            case Ok(json) -> return Ok(value = json)"
        line "          }"
        line "      }"
        line "  }"
        line "}"
        blank ()

        // Convenience scalar accessors for flat object responses.
        match successResp with
        | Some { Kind = OpenApi.Object props } ->
            for p in props do
                match p.Kind with
                | OpenApi.String_ | OpenApi.Integer | OpenApi.Boolean ->
                    let accessorSuffix =
                        match p.Kind with
                        | OpenApi.String_  -> "String"
                        | OpenApi.Integer  -> "Int"
                        | OpenApi.Boolean  -> "Bool"
                        | _                -> ""
                    let lyricFn = "RestClient.json" + accessorSuffix
                    let accessorName = funcName + toPascal p.Name
                    line (sprintf "/// Read the `%s` field from a `%s` response body."
                                  p.Name funcName)
                    line "@stable(since=\"1.0\")"
                    line (sprintf "pub async func %s.%s(%s): Result[%s, RestError] {"
                                  clientTypeName accessorName argsStr (lyricType p.Kind))
                    line (sprintf "  match await %s.%s(client%s) {" clientTypeName funcName
                                  (if List.isEmpty allArgs then ""
                                   else ", " + (allArgs |> List.map (fun a -> a.Split(':').[0].Trim()) |> String.concat ", ")))
                    line "    case Err(e) -> return Err(error = e)"
                    line "    case Ok(r) ->"
                    line "      val doc = parseJson(r)"
                    line "      val root = rootElement(doc)"
                    line (sprintf "      match tryGetProperty(root, \"%s\") {" p.Name)
                    line "        case None -> return Err(error = Deserialize(url = \"\", reason = \"missing field\"))"
                    line "        case Some(elem) ->"
                    match p.Kind with
                    | OpenApi.String_  -> line "          return Ok(value = getString(elem))"
                    | OpenApi.Integer  -> line "          return Ok(value = getInt32(elem))"
                    | OpenApi.Boolean  -> line "          return Ok(value = getBoolean(elem))"
                    | _                -> ()
                    line "      }"
                    line "  }"
                    line "}"
                    blank ()
                | _ -> ()  // skip complex nested fields
        | _ -> ()

    sb.ToString()

/// Generate Lyric source and write it to `outPath`.
/// Returns `Ok outPath` on success, `Error message` on failure.
let generateToFile
        (spec: OpenApi.Spec)
        (opts: GenOptions option)
        (outPath: string) : Result<string, string> =
    try
        let source = generate spec opts
        let dir =
            match System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath outPath) with
            | null -> "."
            | d    -> d
        System.IO.Directory.CreateDirectory dir |> ignore
        System.IO.File.WriteAllText(outPath, source)
        Ok outPath
    with ex ->
        Error (sprintf "could not write '%s': %s" outPath ex.Message)
