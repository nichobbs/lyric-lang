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
///   - completionProvider: true (all top-level names, including imports)
///   - definitionProvider: true (go-to-definition, including imported files)
///   - signatureHelpProvider: true (triggered by '(' and ',')
///
/// M-L4 — cross-file workspace support:
///   - On `initialize`, the workspace root is extracted and a
///     `WorkspaceIndex` (package-name → file-path) is built by scanning
///     all *.l files under the root.
///   - `import Pkg` declarations are resolved against the index;
///     the imported file's items are passed to `checkWithImports` so
///     the type checker sees the full cross-file symbol table.
///   - Completion draws from `CheckResult.Symbols` (which includes
///     imported symbols) rather than just the local AST items.
///   - Go-to-definition searches imported files when no local match is
///     found.
///   - `workspace/didChangeWatchedFiles` rebuilds the index so newly
///     created files are discovered on the next keystroke.
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
// Workspace index — maps package name to file path.
// ---------------------------------------------------------------------------

type WorkspaceIndex =
    { Root:          string
      /// "Pkg" or "Pkg.Sub" → absolute file path of the declaring .l file.
      PackageToFile: Map<string, string> }

/// Convert an LSP `file://` URI to an absolute file-system path.
let private uriToPath (uri: string) : string option =
    try Some (Uri(uri).LocalPath)
    with _ -> None

/// Convert an absolute file-system path to an LSP `file://` URI.
let private pathToUri (path: string) : string =
    try Uri(path).AbsoluteUri
    with _ -> "file://" + path.Replace('\\', '/')

/// Scan every *.l file under `root`, parse its package declaration, and
/// build the package-name → file-path map.  Files that fail to parse are
/// silently skipped so a broken file never crashes the whole index.
let buildWorkspaceIndex (root: string) : WorkspaceIndex =
    let mutable m = Map.empty
    try
        let files = Directory.GetFiles(root, "*.l", SearchOption.AllDirectories)
        for filePath in files do
            try
                let text = File.ReadAllText filePath
                let parsed = Parser.parse text
                let key = String.concat "." parsed.File.Package.Path.Segments
                if key <> "" then
                    m <- Map.add key filePath m
            with _ -> ()
    with _ -> ()
    { Root = root; PackageToFile = m }

// ---------------------------------------------------------------------------
// Document store — caches the full analysis result per URI.
// ---------------------------------------------------------------------------

type CachedDoc =
    { Source:        string
      CheckResult:   CheckResult
      /// URI → SourceFile for each directly-imported package.  Used by
      /// go-to-definition to resolve symbols declared in other files.
      ImportedFiles: Map<string, Lyric.Parser.Ast.SourceFile> }

type DocumentStore() =
    let docs = Dictionary<string, CachedDoc>()
    member _.Set(uri: string, doc: CachedDoc)    = docs.[uri] <- doc
    member _.Remove(uri: string)                 = docs.Remove(uri) |> ignore
    member _.TryGet(uri: string) : CachedDoc option =
        match docs.TryGetValue uri with
        | true, d -> Some d
        | _       -> None
    member _.AllUris() : string seq =
        seq { for kvp in docs do yield kvp.Key }

// ---------------------------------------------------------------------------
// Import resolution — discover items from other workspace files.
// ---------------------------------------------------------------------------

/// For each `import Pkg` in `file`, look up the package in `wsIdx`, parse
/// (or read from the doc store if already open), and collect its top-level
/// items for passing to `checkWithImports`.
///
/// Also returns a map of URI → SourceFile for cross-file go-to-definition.
let private resolveImportedItems
        (wsIdx: WorkspaceIndex option)
        (store: DocumentStore)
        (file:  Lyric.Parser.Ast.SourceFile)
        : Lyric.Parser.Ast.Item list * Map<string, Lyric.Parser.Ast.SourceFile> =
    match wsIdx with
    | None -> [], Map.empty
    | Some idx ->
        let mutable items : Lyric.Parser.Ast.Item list = []
        let mutable importedFiles = Map.empty
        for importDecl in file.Imports do
            let pkgKey = String.concat "." importDecl.Path.Segments
            match Map.tryFind pkgKey idx.PackageToFile with
            | None -> ()
            | Some filePath ->
                let fileUri = pathToUri filePath
                let srcFileOpt =
                    // Prefer the editor's live version if the file is open.
                    match store.TryGet fileUri with
                    | Some doc -> Some doc.CheckResult.File
                    | None ->
                        try
                            let text = File.ReadAllText filePath
                            let parsed = Parser.parse text
                            Some parsed.File
                        with _ -> None
                match srcFileOpt with
                | None -> ()
                | Some sf ->
                    items <- items @ sf.Items
                    importedFiles <- Map.add fileUri sf importedFiles
        items, importedFiles

// ---------------------------------------------------------------------------
// Analysis helpers.
// ---------------------------------------------------------------------------

/// Run lex → parse → resolve-imports → type-check on `text`.
/// Returns all diagnostics, the full CheckResult, and a map of imported
/// files for go-to-definition.
let analyzeUri
        (text:   string)
        (wsIdx:  WorkspaceIndex option)
        (store:  DocumentStore)
        : Diagnostic list * CheckResult * Map<string, Lyric.Parser.Ast.SourceFile> =
    let parsed = Parser.parse text
    let importedItems, importedFiles = resolveImportedItems wsIdx store parsed.File
    let checked' = Checker.checkWithImports parsed.File importedItems
    parsed.Diagnostics @ checked'.Diagnostics, checked', importedFiles

// ---------------------------------------------------------------------------
// Type / signature rendering helpers.
// ---------------------------------------------------------------------------

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

let private renderFullSig
        (name:      string)
        (vis:       Lyric.Parser.Ast.Visibility option)
        (sg:        ResolvedSignature)
        (typeNames: Map<int, string>) : string =
    let visStr   = match vis with Some _ -> "pub " | None -> ""
    let asyncStr = if sg.IsAsync then "async " else ""
    let generics =
        if sg.Generics.IsEmpty then ""
        else "[" + String.concat ", " sg.Generics + "]"
    let paramsStr =
        sg.Params
        |> List.map (fun p ->
            sprintf "%s %s: %s" (renderMode p.Mode) p.Name (renderType typeNames p.Type))
        |> String.concat ", "
    let retStr = renderType typeNames sg.Return
    sprintf "%s%sfunc %s%s(%s): %s" visStr asyncStr name generics paramsStr retStr

// ---------------------------------------------------------------------------
// Symbol → completion item helpers.
// ---------------------------------------------------------------------------

/// Map a Symbol to (CompletionItemKind code, detail string).
let private symbolKindAndDetail (sym: Symbol) : int * string =
    let vis = match sym.Visibility with Some _ -> "pub " | None -> ""
    match sym.Kind with
    | DKFunc fn ->
        let a = if fn.IsAsync then "async " else ""
        3, sprintf "%s%sfunc %s(...)" vis a sym.Name
    | DKRecord _
    | DKExposedRec _   -> 22, sprintf "%srecord %s"          vis sym.Name
    | DKUnion _        ->  7, sprintf "%sunion %s"           vis sym.Name
    | DKEnum _         -> 13, sprintf "%senum %s"            vis sym.Name
    | DKOpaque _       -> 22, sprintf "%sopaque type %s"     vis sym.Name
    | DKProtected _    -> 22, sprintf "%sprotected type %s"  vis sym.Name
    | DKDistinctType _ -> 22, sprintf "%sdistinct type %s"   vis sym.Name
    | DKTypeAlias _    ->  7, sprintf "%salias %s"           vis sym.Name
    | DKInterface _    ->  8, sprintf "%sinterface %s"       vis sym.Name
    | DKConst _        -> 21, sprintf "%sconst %s"           vis sym.Name
    | DKVal _          ->  6, sprintf "val %s"                   sym.Name
    | DKExternType _   ->  7, sprintf "extern type %s"           sym.Name
    | DKWire _         ->  1, sprintf "wire %s"                  sym.Name
    | DKExtern _       ->  9, sprintf "import %s"                sym.Name
    | DKScopeKind _
    | DKTest _
    | DKProperty _
    | DKFixture _      ->  1, sym.Name
    | DKUnionCase(_, uc) -> 20, sprintf "case %s" uc.Name
    | DKEnumCase(_, ec)  -> 20, sprintf "case %s" ec.Name

// ---------------------------------------------------------------------------
// Position / offset helpers.
// ---------------------------------------------------------------------------

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

let private posToOffset (text: string) (line: int) (col: int) : int =
    let lines = text.Split('\n')
    let lineIdx = line - 1
    if lineIdx < 0 || lineIdx >= lines.Length then text.Length
    else
        let baseOffset =
            lines
            |> Array.take lineIdx
            |> Array.sumBy (fun l -> l.Length + 1)
        baseOffset + min (col - 1) lines.[lineIdx].Length

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

let private findCallContext (text: string) (offset: int) : (string * int) option =
    if offset <= 0 then None
    else
        let mutable i     = offset - 1
        let mutable depth = 0
        let mutable found = -1
        while i >= 0 && found = -1 do
            match text.[i] with
            | ')' | ']' -> depth <- depth + 1; i <- i - 1
            | '(' | '[' ->
                if depth = 0 then found <- i
                else depth <- depth - 1; i <- i - 1
            | _ -> i <- i - 1
        if found < 0 then None
        else
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
// AST item helpers.
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

let private initializeResult () : JsonNode =
    let caps = JsonObject()
    let sync = JsonObject()
    sync.["openClose"] <- JsonValue.Create true
    sync.["change"]    <- JsonValue.Create 1
    caps.["textDocumentSync"] <- sync :> JsonNode
    caps.["hoverProvider"]    <- JsonValue.Create true
    let completion = JsonObject()
    completion.["resolveProvider"] <- JsonValue.Create false
    let triggerChars = JsonArray()
    triggerChars.Add(JsonValue.Create ".")
    completion.["triggerCharacters"] <- triggerChars :> JsonNode
    caps.["completionProvider"] <- completion :> JsonNode
    caps.["definitionProvider"] <- JsonValue.Create true
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
// JSON utility helpers.
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
/// has signalled `exit`.
let dispatch
        (store:  DocumentStore)
        (wsIdx:  WorkspaceIndex option ref)
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
        // Extract workspace root and build the package index.
        let rootUri  = asStr (nodeAt params' "rootUri")
        let rootPath = asStr (nodeAt params' "rootPath")
        let workspaceRoot =
            if rootUri <> "" then uriToPath rootUri
            elif rootPath <> "" then Some rootPath
            else None
        match workspaceRoot with
        | Some root when Directory.Exists root ->
            wsIdx.Value <- Some (buildWorkspaceIndex root)
        | _ -> ()
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
                let diags, cr, importedFiles = analyzeUri text wsIdx.Value store
                store.Set(uri, { Source = text; CheckResult = cr; ImportedFiles = importedFiles })
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
                let diags, cr, importedFiles = analyzeUri newText wsIdx.Value store
                store.Set(uri, { Source = newText; CheckResult = cr; ImportedFiles = importedFiles })
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
    // Workspace file-change events — rebuild the index so new .l files are
    // discovered, but don't force-re-analyse open documents; they'll get
    // fresh analysis on their next edit.
    // -----------------------------------------------------------------------

    | "workspace/didChangeWatchedFiles" ->
        match wsIdx.Value with
        | Some idx ->
            wsIdx.Value <- Some (buildWorkspaceIndex idx.Root)
        | None -> ()
        true

    // -----------------------------------------------------------------------
    // Hover — full resolved signature for functions, summary for others.
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
                    // Search local items first, then imported files.
                    let matchItem =
                        cr.File.Items
                        |> List.tryFind (fun it -> itemName it = Some ident)
                        |> Option.orElseWith (fun () ->
                            doc.ImportedFiles
                            |> Map.toSeq
                            |> Seq.tryPick (fun (_, sf) ->
                                sf.Items |> List.tryFind (fun it -> itemName it = Some ident)))
                    match matchItem with
                    | None -> JsonObject() :> JsonNode
                    | Some it ->
                        let typeNames = buildTypeNames cr
                        let summary =
                            match it.Kind with
                            | Lyric.Parser.Ast.IFunc fn ->
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
    // Completion — all symbols in the type-checked symbol table (local +
    // imported), deduplicated by name.
    // -----------------------------------------------------------------------

    | "textDocument/completion" ->
        let td  = nodeAt params' "textDocument"
        let uri = asStr (nodeAt td "uri")
        let result =
            match store.TryGet uri with
            | None -> JsonArray() :> JsonNode
            | Some doc ->
                let items  = JsonArray()
                let seen   = System.Collections.Generic.HashSet<string>()
                for sym in doc.CheckResult.Symbols.All() do
                    // Skip internal entries (union/enum cases listed separately if desired).
                    if seen.Add(sym.Name) then
                        let (kindCode, detail) = symbolKindAndDetail sym
                        let entry = JsonObject()
                        entry.["label"]  <- JsonValue.Create sym.Name
                        entry.["kind"]   <- JsonValue.Create kindCode
                        entry.["detail"] <- JsonValue.Create detail
                        items.Add entry
                items :> JsonNode
        writeMessage output (mkResponse id result)
        true

    // -----------------------------------------------------------------------
    // Go-to-definition — local items first, then imported files.
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
                    // Local match → current file.
                    let localMatch =
                        doc.CheckResult.File.Items
                        |> List.tryFind (fun it -> itemName it = Some ident)
                        |> Option.map (fun it -> uri, it.Span)
                    // Imported match → the declaring file.
                    let importedMatch =
                        if localMatch.IsSome then None
                        else
                            doc.ImportedFiles
                            |> Map.toSeq
                            |> Seq.tryPick (fun (importUri, sf) ->
                                sf.Items
                                |> List.tryFind (fun it -> itemName it = Some ident)
                                |> Option.map (fun it -> importUri, it.Span))
                    match localMatch |> Option.orElse importedMatch with
                    | None -> JsonArray() :> JsonNode
                    | Some (targetUri, span) ->
                        let loc = JsonObject()
                        loc.["uri"]   <- JsonValue.Create targetUri
                        loc.["range"] <- toLspRange span
                        loc :> JsonNode
        writeMessage output (mkResponse id result)
        true

    // -----------------------------------------------------------------------
    // Signature help.
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
                    let sgOpt =
                        cr.Signatures
                        |> Map.toSeq
                        |> Seq.tryPick (fun (k, sg) ->
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

    | _ when not (isNull id) ->
        writeMessage output (mkErrorResponse id -32601 (sprintf "method not found: %s" method'))
        true

    | _ ->
        true

let runLoop (input: Stream) (output: Stream) : unit =
    let store  = DocumentStore()
    let wsIdx  = ref None
    let mutable keepRunning = true
    while keepRunning do
        match readMessage input with
        | None -> keepRunning <- false
        | Some msg ->
            try
                if not (dispatch store wsIdx output msg) then
                    keepRunning <- false
            with _ ->
                eprintfn "lyric-lsp: dispatch error"
