module Lyric.Parser.Tests.ItemBodyTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Parser.Parser

let private prelude = "package P\n"

let private parseClean (src: string) =
    let r = parse (prelude + src)
    Expect.isEmpty r.Diagnostics
        (sprintf "expected no diagnostics for: %s\nactual: %A" src r.Diagnostics)
    r.File

let private getOnlyItem (file: SourceFile) : Item =
    Expect.equal file.Items.Length 1 "exactly one item"
    file.Items.[0]

let tests =
    testList "item bodies (P5b)" [

        // ----- alias -----

        test "type alias to a primitive" {
            let f = parseClean "pub alias Distance = Long"
            match (getOnlyItem f).Kind with
            | ITypeAlias { Name = "Distance"; RHS = rhs } ->
                match rhs.Kind with
                | TRef p -> Expect.equal p.Segments ["Long"] "rhs"
                | other -> failtestf "rhs: %A" other
            | other -> failtestf "expected ITypeAlias, got %A" other
        }

        // ----- distinct type -----

        test "distinct type wrapping Long" {
            let f = parseClean "pub type UserId = Long"
            match (getOnlyItem f).Kind with
            | IDistinctType d ->
                Expect.equal d.Name "UserId" "name"
                Expect.isNone d.Range "no range"
                Expect.isEmpty d.Derives "no derives"
            | other -> failtestf "expected IDistinctType, got %A" other
        }

        test "distinct type with closed range" {
            let f = parseClean "pub type Cents = Long range 0 ..= 1_000_000_000_00"
            match (getOnlyItem f).Kind with
            | IDistinctType d ->
                Expect.equal d.Name "Cents" "name"
                match d.Range with
                | Some (RBClosed(_, hi)) ->
                    match hi.Kind with
                    | ELiteral (LInt(100000000000UL, _)) -> ()
                    | other -> failtestf "hi: %A" other
                | other -> failtestf "range: %A" other
            | other -> failtestf "expected IDistinctType, got %A" other
        }

        test "distinct type with derives clause" {
            let f =
                parseClean
                    "pub type Cents = Long range 0 ..= 100 derives Add, Sub, Compare"
            match (getOnlyItem f).Kind with
            | IDistinctType d ->
                Expect.equal d.Derives ["Add"; "Sub"; "Compare"] "derives"
            | other -> failtestf "expected IDistinctType, got %A" other
        }

        test "distinct type derives without range" {
            let f = parseClean "pub type UserId = Long derives Compare, Hash"
            match (getOnlyItem f).Kind with
            | IDistinctType d ->
                Expect.isNone d.Range "no range"
                Expect.equal d.Derives ["Compare"; "Hash"] "derives"
            | other -> failtestf "expected IDistinctType, got %A" other
        }

        // ----- record -----

        test "record with two fields" {
            let f = parseClean "record Point { x: Double, y: Double }"
            match (getOnlyItem f).Kind with
            | IRecord r ->
                Expect.equal r.Name "Point" "name"
                Expect.equal r.Members.Length 2 "two members"
                match r.Members.[0] with
                | RMField fd ->
                    Expect.equal fd.Name "x" "field 0 name"
                    match fd.Type.Kind with
                    | TRef p -> Expect.equal p.Segments ["Double"] "field 0 type"
                    | other -> failtestf "field 0 type kind: %A" other
                | other -> failtestf "field 0: %A" other
            | other -> failtestf "expected IRecord, got %A" other
        }

        test "record with default field value" {
            let f = parseClean "record Counter { count: Int = 0 }"
            match (getOnlyItem f).Kind with
            | IRecord r ->
                match r.Members.[0] with
                | RMField fd ->
                    Expect.isSome fd.Default "default present"
                | other -> failtestf "field: %A" other
            | other -> failtestf "expected IRecord, got %A" other
        }

        test "record with field-level annotation" {
            let f = parseClean "record User { passwordHash: String @hidden }"
            match (getOnlyItem f).Kind with
            | IRecord r ->
                match r.Members.[0] with
                | RMField fd ->
                    Expect.equal fd.Annotations.Length 1 "one annotation"
                | other -> failtestf "field: %A" other
            | other -> failtestf "expected IRecord, got %A" other
        }

        // ----- exposed record -----

        test "exposed record" {
            let f =
                parseClean
                    "exposed record TransferRequest { fromId: Guid, toId: Guid, amountCents: Long }"
            match (getOnlyItem f).Kind with
            | IExposedRec r ->
                Expect.equal r.Name "TransferRequest" "name"
                Expect.equal r.Members.Length 3 "three fields"
            | other -> failtestf "expected IExposedRec, got %A" other
        }

        // ----- union -----

        test "union with mixed payload-less and payload cases" {
            let src = """union Shape {
                case Circle(radius: Double),
                case Rectangle(width: Double, height: Double),
                case Empty
            }"""
            let f = parseClean src
            match (getOnlyItem f).Kind with
            | IUnion u ->
                Expect.equal u.Name "Shape" "name"
                Expect.equal u.Cases.Length 3 "three cases"
                Expect.equal u.Cases.[0].Name "Circle" "case 0 name"
                Expect.equal u.Cases.[0].Fields.Length 1 "case 0 fields"
                Expect.equal u.Cases.[1].Fields.Length 2 "case 1 fields"
                Expect.equal u.Cases.[2].Fields.Length 0 "case 2 fields"
            | other -> failtestf "expected IUnion, got %A" other
        }

        test "union case with positional fields" {
            let f = parseClean "union Result { case Ok(Int), case Err(String) }"
            match (getOnlyItem f).Kind with
            | IUnion u ->
                match u.Cases.[0].Fields.[0] with
                | UFPos _ -> ()
                | other -> failtestf "expected positional, got %A" other
            | other -> failtestf "expected IUnion, got %A" other
        }

        // ----- enum -----

        test "enum with three cases" {
            let f = parseClean "enum Color { case Red, case Green, case Blue }"
            match (getOnlyItem f).Kind with
            | IEnum e ->
                Expect.equal e.Name "Color" "name"
                Expect.equal e.Cases.Length 3 "three cases"
                Expect.equal e.Cases.[0].Name "Red" "first case"
            | other -> failtestf "expected IEnum, got %A" other
        }

        test "enum rejects generics" {
            let r = parse (prelude + "generic[T] enum E { case A }")
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "P0100" "P0100 reported"
        }

        // ----- opaque type -----

        test "opaque type with body and invariant" {
            let src = """opaque type Account {
                balance: Cents,
                invariant: balance >= 0
            }"""
            let f = parseClean src
            match (getOnlyItem f).Kind with
            | IOpaque o ->
                Expect.equal o.Name "Account" "name"
                Expect.isTrue o.HasBody "has body"
                Expect.equal o.Members.Length 2 "field + invariant"
                let invariants =
                    o.Members
                    |> List.choose (fun m ->
                        match m with OMInvariant i -> Some i | _ -> None)
                Expect.equal invariants.Length 1 "one invariant"
            | other -> failtestf "expected IOpaque, got %A" other
        }

        test "opaque type without body (header-only)" {
            let f = parseClean "opaque type AccountId"
            match (getOnlyItem f).Kind with
            | IOpaque o ->
                Expect.equal o.Name "AccountId" "name"
                Expect.isFalse o.HasBody "no body"
                Expect.isEmpty o.Members "no members"
            | other -> failtestf "expected IOpaque, got %A" other
        }

        test "projectable opaque type with post-name annotation" {
            let f = parseClean "opaque type Amount @projectable { value: Cents }"
            match (getOnlyItem f).Kind with
            | IOpaque o ->
                Expect.equal o.Annotations.Length 1 "one post-name annotation"
                Expect.equal o.Annotations.[0].Name.Segments ["projectable"] "name"
            | other -> failtestf "expected IOpaque, got %A" other
        }

        // ----- generics, where -----

        test "record with prefix-form generic[T]" {
            let f = parseClean "generic[T] record Box { value: T }"
            match (getOnlyItem f).Kind with
            | IRecord r ->
                Expect.isSome r.Generics "generics present"
            | other -> failtestf "expected IRecord, got %A" other
        }

        test "record with where-clause" {
            let f = parseClean "generic[T] record Box where T: Default { value: T }"
            match (getOnlyItem f).Kind with
            | IRecord r ->
                Expect.isSome r.Where "where-clause present"
            | other -> failtestf "expected IRecord, got %A" other
        }

        test "union with generics and where-clause" {
            let f =
                parseClean
                    "generic[T, E] union Result where T: Equals { case Ok(value: T), case Err(error: E) }"
            match (getOnlyItem f).Kind with
            | IUnion u ->
                Expect.isSome u.Generics "generics"
                Expect.isSome u.Where "where"
            | other -> failtestf "expected IUnion, got %A" other
        }

        // ----- multi-item file -----

        test "file with seven mixed items" {
            let src = """
                alias D = Long
                pub type Cents = Long range 0 ..= 100
                record P { x: Int, y: Int }
                exposed record Req { id: Long }
                union U { case A, case B(x: Int) }
                enum E { case Red, case Green }
                opaque type Tag
            """
            let f = parseClean src
            Expect.equal f.Items.Length 7 "seven items"
            // No P0098 — every item parses fully.
            let r = parse (prelude + src)
            let p98s = r.Diagnostics |> List.filter (fun d -> d.Code = "P0098")
            Expect.equal p98s.Length 0 "no P0098"
        }
    ]
