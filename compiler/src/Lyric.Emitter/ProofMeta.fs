/// Proof-only metadata format + embed/extract for cross-package
/// SMT datatype encoding (D-progress-086).
///
/// Per the Phase 4 plan §3.2, the verifier needs the *internal*
/// representation of records, unions, opaque types, and enums so
/// that cross-package proofs can do field-projection and case-
/// analysis reasoning.  We deliberately do **not** include this
/// information in the public `Lyric.Contract` resource because:
///
/// * `Lyric.Contract` is a documented public artifact consumed by
///   `lyric public-api-diff`, the LSP, and external tooling.  The
///   internal layout of an `opaque type` is, by language design,
///   not part of a package's public surface.
/// * Putting the rep in JSON invites users to depend on the shape
///   of opaque types.  Even with a documented "do not depend on
///   this" warning, structural access through JSON is a slippery
///   slope.
///
/// The resolution is a **separate embedded resource named
/// `Lyric.Proof`** with a custom binary layout.  Anyone with a
/// reflection probe can still extract it (this is .NET; no resource
/// is truly secret), but the binary format is enough deterrent
/// against ad-hoc consumption that the resource stays an
/// implementation detail of the verifier.
///
/// The format is intentionally simple: a magic header, format
/// version, length-prefixed strings, length-prefixed lists.  No
/// compression, no string deduplication.  Stable byte layout so
/// the goal cache (D-progress-087) can hash it.
module Lyric.Emitter.ProofMeta

open System
open System.IO
open System.Text
open Lyric.Parser.Ast

let private MAGIC : byte array =
    [| 0x4Cuy; 0x59uy; 0x50uy; 0x52uy; 0x46uy |]    // "LYPRF"

let private FORMAT_VERSION : byte = 1uy

/// One field on a record / union case / opaque type.
type ProofField =
    { Name: string
      /// Source-level representation of the field's type.  The
      /// verifier re-parses this back into a `TypeExpr` via
      /// `parseTypeFromString` so the existing `Theory.sortOfTypeExpr`
      /// pipeline can consume it.
      TypeRepr: string }

/// One case on a union or enum.
type ProofCase =
    { Name:   string
      Fields: ProofField list }

/// Proof-only schema for one type declaration.
type ProofTypeKind =
    | PTKRecord  of fields: ProofField list
    | PTKUnion   of cases: ProofCase list
    | PTKEnum    of cases: string list
    | PTKOpaque  of fields: ProofField list

type ProofType =
    { Name: string
      Kind: ProofTypeKind }

/// Proof-only metadata for one assembly.  Lives next to
/// `Lyric.Contract` but is independently versioned and binary-
/// encoded.
type ProofMeta =
    { PackageName: string
      Version:     string
      Types:       ProofType list }

// -----------------------------------------------------------------------
// Binary encoding.
//
// Layout (all little-endian where applicable):
//
//   magic         5 bytes "LYPRF"
//   formatVersion 1 byte
//   pkgLen        u16
//   pkgName       <pkgLen> bytes UTF-8
//   verLen        u16
//   verName       <verLen> bytes UTF-8
//   typeCount     u16
//   types         <typeCount> ProofType
//
//   ProofType layout:
//     nameLen     u16
//     name        UTF-8
//     kindTag     u8       (0 = record, 1 = union, 2 = enum, 3 = opaque)
//     payload     depends on kindTag
//
//   Record / Opaque payload:
//     fieldCount  u16
//     fields      <fieldCount> ProofField
//
//   Union payload:
//     caseCount   u16
//     cases       <caseCount> ProofCase
//
//   Enum payload:
//     caseCount   u16
//     cases       <caseCount> length-prefixed strings
//
//   ProofField:
//     nameLen     u16
//     name        UTF-8
//     typeLen     u16
//     typeRepr    UTF-8
//
//   ProofCase:
//     nameLen     u16
//     name        UTF-8
//     fieldCount  u16
//     fields      <fieldCount> ProofField
//
// Length-prefixed strings cap at 65535 bytes; longer strings are
// truncated (and a debug warning logged), but no realistic Lyric
// type or field name is anywhere near that size.

let private writeStr (w: BinaryWriter) (s: string) : unit =
    let bytes = Encoding.UTF8.GetBytes s
    let len =
        if bytes.Length > 0xFFFF then 0xFFFF else bytes.Length
    w.Write(uint16 len)
    if len > 0 then w.Write(bytes, 0, len)

let private readStr (r: BinaryReader) : string =
    let len = int (r.ReadUInt16())
    if len = 0 then ""
    else Encoding.UTF8.GetString(r.ReadBytes(len))

let private writeField (w: BinaryWriter) (f: ProofField) : unit =
    writeStr w f.Name
    writeStr w f.TypeRepr

let private readField (r: BinaryReader) : ProofField =
    let n = readStr r
    let t = readStr r
    { Name = n; TypeRepr = t }

let private writeFieldList (w: BinaryWriter) (xs: ProofField list) : unit =
    w.Write(uint16 (List.length xs))
    for f in xs do writeField w f

let private readFieldList (r: BinaryReader) : ProofField list =
    let n = int (r.ReadUInt16())
    [ for _ in 1 .. n -> readField r ]

let private writeCase (w: BinaryWriter) (c: ProofCase) : unit =
    writeStr w c.Name
    writeFieldList w c.Fields

let private readCase (r: BinaryReader) : ProofCase =
    let n = readStr r
    let fs = readFieldList r
    { Name = n; Fields = fs }

let private writeType (w: BinaryWriter) (t: ProofType) : unit =
    writeStr w t.Name
    match t.Kind with
    | PTKRecord fs ->
        w.Write 0uy
        writeFieldList w fs
    | PTKUnion cs ->
        w.Write 1uy
        w.Write(uint16 (List.length cs))
        for c in cs do writeCase w c
    | PTKEnum cs ->
        w.Write 2uy
        w.Write(uint16 (List.length cs))
        for n in cs do writeStr w n
    | PTKOpaque fs ->
        w.Write 3uy
        writeFieldList w fs

let private readType (r: BinaryReader) : ProofType =
    let name = readStr r
    let tag  = r.ReadByte()
    let kind =
        match tag with
        | 0uy -> PTKRecord (readFieldList r)
        | 1uy ->
            let n = int (r.ReadUInt16())
            PTKUnion [ for _ in 1 .. n -> readCase r ]
        | 2uy ->
            let n = int (r.ReadUInt16())
            PTKEnum [ for _ in 1 .. n -> readStr r ]
        | 3uy -> PTKOpaque (readFieldList r)
        | other ->
            failwithf "ProofMeta: unknown type-kind tag 0x%02x" (int other)
    { Name = name; Kind = kind }

/// Serialize `meta` to a byte array suitable for embedding as a
/// managed resource.
let toBytes (meta: ProofMeta) : byte array =
    use ms = new MemoryStream()
    use w  = new BinaryWriter(ms)
    w.Write(MAGIC, 0, MAGIC.Length)
    w.Write FORMAT_VERSION
    writeStr w meta.PackageName
    writeStr w meta.Version
    w.Write(uint16 (List.length meta.Types))
    for t in meta.Types do writeType w t
    ms.ToArray()

/// Deserialize a byte array back to `ProofMeta`.  Returns `None`
/// when the magic / format version doesn't match.
let fromBytes (bytes: byte array) : ProofMeta option =
    if bytes.Length < MAGIC.Length + 1 then None
    else
    let magicOk =
        Array.zip MAGIC (Array.sub bytes 0 MAGIC.Length)
        |> Array.forall (fun (a, b) -> a = b)
    if not magicOk then None
    else
    try
        use ms = new MemoryStream(bytes)
        use r  = new BinaryReader(ms)
        // Skip magic.
        r.ReadBytes MAGIC.Length |> ignore
        let formatVer = r.ReadByte()
        if formatVer <> FORMAT_VERSION then None
        else
        let pkg = readStr r
        let ver = readStr r
        let n   = int (r.ReadUInt16())
        let ts  = [ for _ in 1 .. n -> readType r ]
        Some { PackageName = pkg; Version = ver; Types = ts }
    with _ -> None

// -----------------------------------------------------------------------
// AST -> ProofMeta
// -----------------------------------------------------------------------

let private renderTypeExpr (te: TypeExpr) : string =
    let rec go (te: TypeExpr) =
        match te.Kind with
        | TRef p          -> String.concat "." p.Segments
        | TGenericApp (h, args) ->
            let head = String.concat "." h.Segments
            let argStrs =
                args
                |> List.map (function
                    | TAType t  -> go t
                    | TAValue _ -> "<expr>")
            head + "[" + String.concat ", " argStrs + "]"
        | TArray (_, elem) -> sprintf "array[..., %s]" (go elem)
        | TSlice elem      -> sprintf "slice[%s]" (go elem)
        | TRefined (h, _)  -> String.concat "." h.Segments + " range ..."
        | TTuple ts        ->
            "(" + (ts |> List.map go |> String.concat ", ") + ")"
        | TNullable t      -> go t + "?"
        | TFunction (ps, r) ->
            sprintf "(%s) -> %s"
                (ps |> List.map go |> String.concat ", ") (go r)
        | TUnit  -> "Unit"
        | TSelf  -> "Self"
        | TNever -> "Never"
        | TParen t -> "(" + go t + ")"
        | TError -> "<?>"
    go te

let private fieldOf (rd: RecordMember) : ProofField option =
    match rd with
    | RMField fd ->
        Some
            { Name     = fd.Name
              TypeRepr = renderTypeExpr fd.Type }
    | _ -> None

let private opaqueFieldOf (om: OpaqueMember) : ProofField option =
    match om with
    | OMField fd ->
        Some
            { Name     = fd.Name
              TypeRepr = renderTypeExpr fd.Type }
    | _ -> None

let private caseOf (uc: UnionCase) : ProofCase =
    let fields =
        uc.Fields
        |> List.mapi (fun i uf ->
            match uf with
            | UFNamed(n, te, _) ->
                { Name = n; TypeRepr = renderTypeExpr te }
            | UFPos(te, _) ->
                // Positional field: synthesise a name `_n`.
                { Name = "_" + string i; TypeRepr = renderTypeExpr te })
    { Name = uc.Name; Fields = fields }

let private typeOf (it: Item) : ProofType option =
    match it.Kind with
    | IRecord rd | IExposedRec rd ->
        let fs = rd.Members |> List.choose fieldOf
        Some { Name = rd.Name; Kind = PTKRecord fs }
    | IUnion ud ->
        let cs = ud.Cases |> List.map caseOf
        Some { Name = ud.Name; Kind = PTKUnion cs }
    | IEnum ed ->
        let cs = ed.Cases |> List.map (fun c -> c.Name)
        Some { Name = ed.Name; Kind = PTKEnum cs }
    | IOpaque od ->
        // Opaque type rep IS captured here — that's the whole point of
        // a separate proof resource.  The language reference §2.9
        // semantics still hold for the runtime / source-level world;
        // proof consumers see through the cell deliberately.
        let fs = od.Members |> List.choose opaqueFieldOf
        Some { Name = od.Name; Kind = PTKOpaque fs }
    | _ -> None

/// Walk a parsed source file and collect proof-only metadata for
/// every type declaration.  Visibility doesn't gate inclusion here —
/// even a private record's rep flows to proof consumers, since the
/// consumer's reasoning may need it for callee unfolds; the
/// public/private distinction is enforced at the *Lyric* level
/// (via the type checker) rather than at the proof layer.
let buildProofMeta (sf: SourceFile) (version: string) : ProofMeta =
    let pkg = String.concat "." sf.Package.Path.Segments
    let types = sf.Items |> List.choose typeOf
    { PackageName = pkg
      Version     = version
      Types       = types }

// -----------------------------------------------------------------------
// Embed / extract on a .dll.  Mirrors `ContractMeta.embedIntoAssembly`
// but uses the resource name `Lyric.Proof` and binary payload.
// -----------------------------------------------------------------------

let private RESOURCE_NAME = "Lyric.Proof"

let embedIntoAssembly (dllPath: string) (bytes: byte array) : unit =
    let assembly =
        Mono.Cecil.AssemblyDefinition.ReadAssembly(
            dllPath,
            Mono.Cecil.ReaderParameters(InMemory = true))
    let mainModule = assembly.MainModule
    let toDelete =
        mainModule.Resources
        |> Seq.filter (fun r -> r.Name = RESOURCE_NAME)
        |> Seq.toList
    for r in toDelete do
        mainModule.Resources.Remove r |> ignore
    // Mark `Private` (vs ContractMeta's `Public`) so the binary
    // metadata stays out of the assembly's public-resource listing.
    let resource =
        Mono.Cecil.EmbeddedResource(
            RESOURCE_NAME,
            Mono.Cecil.ManifestResourceAttributes.Private,
            bytes)
    mainModule.Resources.Add(resource)
    let tmp = dllPath + ".tmp"
    assembly.Write(tmp)
    File.Move(tmp, dllPath, overwrite = true)

let readFromAssembly (dllPath: string) : ProofMeta option =
    let assembly =
        Mono.Cecil.AssemblyDefinition.ReadAssembly(
            dllPath,
            Mono.Cecil.ReaderParameters(InMemory = true))
    let resource =
        assembly.MainModule.Resources
        |> Seq.tryFind (fun r -> r.Name = RESOURCE_NAME)
    match resource with
    | Some r ->
        match r with
        | :? Mono.Cecil.EmbeddedResource as er ->
            fromBytes (er.GetResourceData())
        | _ -> None
    | None -> None
