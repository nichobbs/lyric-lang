/// Minimal-subset TOML parser + manifest model for `lyric.toml`
/// (C8 part 2 / D-progress-077).
///
/// The `lyric.toml` schema piggybacks on NuGet's `<PackageReference>`
/// model — the manifest is lowered to a generated `.csproj` that
/// `lyric publish` runs through `dotnet pack` and `lyric restore`
/// runs through `dotnet restore`.  See `docs/12-todo-plan.md` C8
/// for the design rationale.
///
/// Supported TOML subset (intentionally tight — bigger TOML support
/// follows when a real package needs it):
///   - Section headers `[name]` and `[a.b]`.
///   - `key = value` pairs where value is a quoted string, a bare
///     number, `true` / `false`, or an inline array of strings.
///   - Comments starting with `#`.
///   - Bare keys (alphanum + `_`/`-`) and quoted keys ("foo.bar").
///   - Trailing commas inside arrays are tolerated.
///
/// Out of scope for the bootstrap: nested arrays-of-tables, multi-
/// line strings, datetimes, integers ≥ 2^53, hexadecimal literals.
/// The parser surfaces a structured `ManifestError` for unsupported
/// syntax so the CLI can render a friendly diagnostic.
module Lyric.Cli.Manifest

open System
open System.IO
open System.Collections.Generic

type ManifestError =
    | MissingFile      of path: string
    | ParseError       of line: int * column: int * message: string
    | MissingField     of section: string * key: string
    | InvalidFieldType of section: string * key: string * expected: string

/// One package dependency: `<name> = "<version>"`.
type Dependency =
    { Name:    string
      Version: string }

/// `[package]` section.
type PackageMetadata =
    { Name:        string
      Version:     string
      Description: string option
      Authors:     string list
      License:     string option
      Repository:  string option }

/// `[build]` section — optional, defaults applied below.
type BuildSection =
    { /// Source files to compile in dependency order.  When `None`,
      /// the publish flow uses the user's already-built DLL at
      /// `<repoRoot>/bin/<package>.dll` (run `lyric build` first).
      Sources: string list option
      /// Output directory for the .nupkg (`dotnet pack -o <dir>`).
      /// Defaults to `pkg/`.
      OutputDir: string option }

/// Whole-manifest record.
type Manifest =
    { Package:      PackageMetadata
      Build:        BuildSection
      Dependencies: Dependency list }

// ---------------------------------------------------------------------------
// TOML token / value model.  Hand-rolled because the bootstrap doesn't
// already pull in a TOML library and the schema only needs ~5 % of TOML.
// ---------------------------------------------------------------------------

type private Value =
    | VString of string
    | VBool   of bool
    | VInt    of int64
    | VArray  of Value list

type private Section =
    | RootSection
    | NamedSection of string

type private Cursor =
    { Text:        string
      mutable Pos: int
      mutable Line:   int
      mutable Column: int }

let private mkCursor (text: string) : Cursor =
    { Text = text; Pos = 0; Line = 1; Column = 1 }

let private peek (c: Cursor) : char option =
    if c.Pos >= c.Text.Length then None
    else Some c.Text.[c.Pos]

let private advance (c: Cursor) : char =
    let ch = c.Text.[c.Pos]
    c.Pos <- c.Pos + 1
    if ch = '\n' then
        c.Line <- c.Line + 1
        c.Column <- 1
    else
        c.Column <- c.Column + 1
    ch

let private skipBlanksAndComments (c: Cursor) : unit =
    let mutable continue' = true
    while continue' && c.Pos < c.Text.Length do
        let ch = c.Text.[c.Pos]
        if ch = ' ' || ch = '\t' then advance c |> ignore
        elif ch = '\n' || ch = '\r' then advance c |> ignore
        elif ch = '#' then
            // Skip to end of line.
            while c.Pos < c.Text.Length && c.Text.[c.Pos] <> '\n' do
                advance c |> ignore
        else continue' <- false

let private skipInlineWhitespace (c: Cursor) : unit =
    while c.Pos < c.Text.Length
          && (c.Text.[c.Pos] = ' ' || c.Text.[c.Pos] = '\t') do
        advance c |> ignore

let private parseError (c: Cursor) (msg: string) : Result<'a, ManifestError> =
    Error (ParseError (c.Line, c.Column, msg))

let private isBareKeyChar (ch: char) : bool =
    Char.IsLetterOrDigit ch || ch = '_' || ch = '-'

let private parseBareKey (c: Cursor) : Result<string, ManifestError> =
    let start = c.Pos
    while c.Pos < c.Text.Length && isBareKeyChar c.Text.[c.Pos] do
        advance c |> ignore
    if c.Pos = start then parseError c "expected a key"
    else Ok (c.Text.Substring(start, c.Pos - start))

let private parseQuotedString (c: Cursor) : Result<string, ManifestError> =
    if peek c <> Some '"' then parseError c "expected '\"'"
    else
        advance c |> ignore
        let sb = System.Text.StringBuilder()
        let mutable err : ManifestError option = None
        let mutable closed = false
        while err.IsNone && not closed && c.Pos < c.Text.Length do
            let ch = advance c
            match ch with
            | '"' -> closed <- true
            | '\\' ->
                if c.Pos >= c.Text.Length then
                    err <- Some (ParseError (c.Line, c.Column, "unterminated string escape"))
                else
                    let esc = advance c
                    match esc with
                    | 'n'  -> sb.Append '\n' |> ignore
                    | 't'  -> sb.Append '\t' |> ignore
                    | 'r'  -> sb.Append '\r' |> ignore
                    | '"'  -> sb.Append '"'  |> ignore
                    | '\\' -> sb.Append '\\' |> ignore
                    | '0'  -> sb.Append '\000' |> ignore
                    | other ->
                        err <- Some (ParseError (c.Line, c.Column,
                                     sprintf "unsupported string escape '\\%c'" other))
            | '\n' ->
                err <- Some (ParseError (c.Line, c.Column,
                             "unterminated string (newline before closing quote)"))
            | other -> sb.Append other |> ignore
        if not closed && err.IsNone then
            err <- Some (ParseError (c.Line, c.Column, "unterminated string literal"))
        match err with
        | Some e -> Error e
        | None   -> Ok (sb.ToString())

let private parseKey (c: Cursor) : Result<string, ManifestError> =
    if peek c = Some '"' then parseQuotedString c
    else parseBareKey c

let private parseHeader (c: Cursor) : Result<string, ManifestError> =
    if peek c <> Some '[' then parseError c "expected '['"
    else
        advance c |> ignore
        skipInlineWhitespace c
        let nameStart = c.Pos
        while c.Pos < c.Text.Length
              && c.Text.[c.Pos] <> ']'
              && c.Text.[c.Pos] <> '\n' do
            advance c |> ignore
        if c.Pos >= c.Text.Length || c.Text.[c.Pos] <> ']' then
            parseError c "expected ']' to close section header"
        else
            let name = c.Text.Substring(nameStart, c.Pos - nameStart).Trim()
            advance c |> ignore   // consume ']'
            skipInlineWhitespace c
            // Discard any trailing comment.
            if peek c = Some '#' then
                while c.Pos < c.Text.Length && c.Text.[c.Pos] <> '\n' do
                    advance c |> ignore
            Ok name

let rec private parseValue (c: Cursor) : Result<Value, ManifestError> =
    skipInlineWhitespace c
    match peek c with
    | Some '"' ->
        match parseQuotedString c with
        | Ok s -> Ok (VString s)
        | Error e -> Error e
    | Some '[' -> parseArray c
    | Some 't' | Some 'f' -> parseBool c
    | Some ch when ch = '-' || Char.IsDigit ch -> parseInt c
    | Some other -> parseError c (sprintf "unexpected '%c' starting value" other)
    | None -> parseError c "unexpected end of file in value"

and private parseArray (c: Cursor) : Result<Value, ManifestError> =
    if peek c <> Some '[' then parseError c "expected '['"
    else
        advance c |> ignore
        let acc = ResizeArray<Value>()
        let mutable err : ManifestError option = None
        let mutable closed = false
        skipBlanksAndComments c
        if peek c = Some ']' then
            advance c |> ignore
            closed <- true
        while err.IsNone && not closed do
            match parseValue c with
            | Error e -> err <- Some e
            | Ok v ->
                acc.Add v
                skipBlanksAndComments c
                match peek c with
                | Some ',' ->
                    advance c |> ignore
                    skipBlanksAndComments c
                    if peek c = Some ']' then
                        advance c |> ignore
                        closed <- true
                | Some ']' ->
                    advance c |> ignore
                    closed <- true
                | _ ->
                    err <- Some (ParseError (c.Line, c.Column,
                                 "expected ',' or ']' in array"))
        match err with
        | Some e -> Error e
        | None   -> Ok (VArray (List.ofSeq acc))

and private parseBool (c: Cursor) : Result<Value, ManifestError> =
    let rest = c.Text.Substring c.Pos
    if rest.StartsWith "true" then
        for _ in 0..3 do advance c |> ignore
        Ok (VBool true)
    elif rest.StartsWith "false" then
        for _ in 0..4 do advance c |> ignore
        Ok (VBool false)
    else parseError c "expected 'true' or 'false'"

and private parseInt (c: Cursor) : Result<Value, ManifestError> =
    let start = c.Pos
    if peek c = Some '-' then advance c |> ignore
    while c.Pos < c.Text.Length && Char.IsDigit c.Text.[c.Pos] do
        advance c |> ignore
    if c.Pos = start then parseError c "expected an integer"
    else
        let raw = c.Text.Substring(start, c.Pos - start)
        match Int64.TryParse raw with
        | true, n -> Ok (VInt n)
        | _ -> parseError c (sprintf "could not parse '%s' as int64" raw)

// ---------------------------------------------------------------------------
// Top-level parse: walk the file, collecting (section, key) -> value pairs
// into a flat dictionary keyed by `<section>.<key>` (or just `<key>` for
// the unlikely root-level scalar case).  Then translate into the typed
// `Manifest` record.
// ---------------------------------------------------------------------------

let private parseEntries (text: string) : Result<Map<string * string, Value>, ManifestError> =
    let c = mkCursor text
    let entries = Dictionary<string * string, Value>()
    let mutable section = RootSection
    let mutable err : ManifestError option = None

    let sectionName () =
        match section with
        | RootSection -> ""
        | NamedSection n -> n

    skipBlanksAndComments c
    while err.IsNone && c.Pos < c.Text.Length do
        match peek c with
        | Some '[' ->
            match parseHeader c with
            | Error e -> err <- Some e
            | Ok name -> section <- NamedSection name
        | Some _ ->
            match parseKey c with
            | Error e -> err <- Some e
            | Ok key ->
                skipInlineWhitespace c
                if peek c <> Some '=' then
                    err <- Some (ParseError (c.Line, c.Column,
                                 "expected '=' after key"))
                else
                    advance c |> ignore
                    match parseValue c with
                    | Error e -> err <- Some e
                    | Ok v ->
                        let k = sectionName(), key
                        if entries.ContainsKey k then
                            err <- Some (ParseError (c.Line, c.Column,
                                         sprintf "duplicate key '%s' in section '%s'"
                                                 key (fst k)))
                        else
                            entries.[k] <- v
                        skipInlineWhitespace c
                        // Trailing comment OK.
                        if peek c = Some '#' then
                            while c.Pos < c.Text.Length && c.Text.[c.Pos] <> '\n' do
                                advance c |> ignore
        | None -> ()
        skipBlanksAndComments c

    match err with
    | Some e -> Error e
    | None ->
        let mutable m = Map.empty
        for kv in entries do m <- Map.add kv.Key kv.Value m
        Ok m

// ---------------------------------------------------------------------------
// Typed-record materialisation.
// ---------------------------------------------------------------------------

let private requireString (entries: Map<string * string, Value>)
                          (section: string) (key: string)
                          : Result<string, ManifestError> =
    match Map.tryFind (section, key) entries with
    | Some (VString s) -> Ok s
    | Some _ -> Error (InvalidFieldType (section, key, "string"))
    | None -> Error (MissingField (section, key))

let private optString (entries: Map<string * string, Value>)
                      (section: string) (key: string)
                      : Result<string option, ManifestError> =
    match Map.tryFind (section, key) entries with
    | Some (VString s) -> Ok (Some s)
    | Some _ -> Error (InvalidFieldType (section, key, "string"))
    | None -> Ok None

let private optStringList (entries: Map<string * string, Value>)
                          (section: string) (key: string)
                          : Result<string list option, ManifestError> =
    match Map.tryFind (section, key) entries with
    | Some (VArray items) ->
        let asStr = ResizeArray<string>()
        let mutable err : ManifestError option = None
        for item in items do
            match item with
            | VString s -> asStr.Add s
            | _ ->
                err <- Some (InvalidFieldType (section, key, "array of strings"))
        match err with
        | Some e -> Error e
        | None -> Ok (Some (List.ofSeq asStr))
    | Some _ -> Error (InvalidFieldType (section, key, "array of strings"))
    | None -> Ok None

let private toManifest (entries: Map<string * string, Value>)
                       : Result<Manifest, ManifestError> =
    let bind r f = match r with Ok v -> f v | Error e -> Error e
    bind (requireString entries "package" "name") <| fun name ->
    bind (requireString entries "package" "version") <| fun version ->
    bind (optString entries "package" "description") <| fun description ->
    bind (optStringList entries "package" "authors") <| fun authors ->
    bind (optString entries "package" "license") <| fun license ->
    bind (optString entries "package" "repository") <| fun repository ->
    bind (optStringList entries "build" "sources") <| fun sources ->
    bind (optString entries "build" "out") <| fun outputDir ->
    let depEntries =
        entries
        |> Map.toList
        |> List.choose (fun ((sec, key), v) ->
            if sec = "dependencies" then
                match v with
                | VString version -> Some (Ok { Name = key; Version = version })
                | _ ->
                    Some (Error (InvalidFieldType (sec, key,
                                                   "dependency version string")))
            else None)
    let firstDepError =
        depEntries |> List.tryPick (function Error e -> Some e | _ -> None)
    match firstDepError with
    | Some e -> Error e
    | None ->
        let deps =
            depEntries
            |> List.choose (function
                | Ok d -> Some d
                | Error _ -> None)
            |> List.sortBy (fun d -> d.Name)
        let pkg =
            { Name        = name
              Version     = version
              Description = description
              Authors     = Option.defaultValue [] authors
              License     = license
              Repository  = repository }
        let build =
            { Sources   = sources
              OutputDir = outputDir }
        Ok { Package = pkg; Build = build; Dependencies = deps }

/// Parse a `lyric.toml` text into a typed `Manifest` record.
let parseText (text: string) : Result<Manifest, ManifestError> =
    match parseEntries text with
    | Error e -> Error e
    | Ok entries -> toManifest entries

/// Locate and parse `lyric.toml` from a file path.
let parseFile (path: string) : Result<Manifest, ManifestError> =
    if not (File.Exists path) then Error (MissingFile path)
    else parseText (File.ReadAllText path)

/// Render a `ManifestError` as a one-line user-facing diagnostic.
let renderError (path: string) (err: ManifestError) : string =
    match err with
    | MissingFile p ->
        sprintf "manifest: '%s' not found" p
    | ParseError (line, col, msg) ->
        sprintf "%s:%d:%d: parse error: %s" path line col msg
    | MissingField (section, key) ->
        sprintf "%s: missing required field '%s.%s'" path section key
    | InvalidFieldType (section, key, expected) ->
        sprintf "%s: '%s.%s' must be a %s" path section key expected
