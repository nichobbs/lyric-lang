module Lyric.Cli.Tests.FmtTests

open Expecto
open Lyric.Parser.Parser
open Lyric.Cli.Fmt

/// Round-trip helper: parse `source`, format, parse again, format again.
/// The second format must equal the first (idempotent).
let private roundtrip (source: string) : string =
    let r1 = parse source
    let f1 = format r1.File
    let r2 = parse f1
    let f2 = format r2.File
    Expect.equal f2 f1 "format is idempotent (format ∘ format = format)"
    f1

/// Parse `source`, format, and assert the output matches `expected` exactly
/// (modulo trailing whitespace on each line, normalised to LF).
let private fmtEquals (source: string) (expected: string) =
    let result = roundtrip source
    let norm (s: string) =
        s.Replace("\r\n", "\n")
         .Split('\n')
         |> Array.map (fun l -> l.TrimEnd())
         |> String.concat "\n"
         |> fun s -> s.TrimEnd()
    Expect.equal (norm result) (norm expected) "formatted output"

let tests =
    testList "Lyric.Cli.Fmt" [

        testCase "minimal file: package only" <| fun () ->
            fmtEquals
                "package Foo"
                "package Foo"

        testCase "file-level annotations come before package" <| fun () ->
            fmtEquals
                "@runtime_checked\npackage Foo"
                "@runtime_checked\npackage Foo"

        testCase "imports are separated by blank line" <| fun () ->
            fmtEquals
                "package Foo\nimport Bar\nimport Baz.{X, Y}"
                "package Foo\n\nimport Bar\nimport Baz.{X, Y}"

        testCase "import with alias" <| fun () ->
            fmtEquals
                "package Foo\nimport Bar.Baz as B"
                "package Foo\n\nimport Bar.Baz as B"

        testCase "pub use import" <| fun () ->
            fmtEquals
                "package Foo\npub use Bar.X"
                "package Foo\n\npub use Bar.X"

        testCase "simple function with no contracts — brace inline" <| fun () ->
            fmtEquals
                "package P\npub func add(a: in Int, b: in Int): Int {\n  return a + b\n}"
                "package P\n\npub func add(a: in Int, b: in Int): Int {\n  return a + b\n}"

        testCase "function with contracts — brace on own line" <| fun () ->
            fmtEquals
                "package P\npub func add(a: in Int, b: in Int): Int\n  requires: a > 0\n  ensures: result > a\n{\n  return a + b\n}"
                "package P\n\npub func add(a: in Int, b: in Int): Int\n  requires: a > 0\n  ensures: result > a\n{\n  return a + b\n}"

        testCase "expression-body function" <| fun () ->
            fmtEquals
                "package P\nfunc double(x: in Int): Int = x * 2"
                "package P\n\nfunc double(x: in Int): Int = x * 2"

        testCase "record declaration" <| fun () ->
            fmtEquals
                "package P\npub record Point {\n  x: Int\n  y: Int\n}"
                "package P\n\npub record Point {\n  x: Int\n  y: Int\n}"

        testCase "union declaration" <| fun () ->
            fmtEquals
                "package P\npub union Shape {\n  case Circle(radius: Float)\n  case Rect(w: Float, h: Float)\n}"
                "package P\n\npub union Shape {\n  case Circle(radius: Float)\n  case Rect(w: Float, h: Float)\n}"

        testCase "enum declaration" <| fun () ->
            fmtEquals
                "package P\npub enum Color {\n  case Red\n  case Green\n  case Blue\n}"
                "package P\n\npub enum Color {\n  case Red\n  case Green\n  case Blue\n}"

        testCase "distinct type with range and derives" <| fun () ->
            fmtEquals
                "package P\npub type Age = Int range 0 ..= 150 derives Compare"
                "package P\n\npub type Age = Int range 0 ..= 150 derives Compare"

        testCase "opaque type with body" <| fun () ->
            fmtEquals
                "package P\npub opaque type Amount {\n  value: Int\n  invariant: value > 0\n}"
                "package P\n\npub opaque type Amount {\n  value: Int\n  invariant: value > 0\n}"

        testCase "interface declaration" <| fun () ->
            fmtEquals
                "package P\npub interface Show {\n  func show(self: in Self): String\n}"
                "package P\n\npub interface Show {\n  func show(self: in Self): String\n}"

        testCase "if-then-else expression form" <| fun () ->
            fmtEquals
                "package P\nfunc abs(x: in Int): Int = if x >= 0 then x else 0 - x"
                "package P\n\nfunc abs(x: in Int): Int = if x >= 0 then x else 0 - x"

        testCase "if block form in function body" <| fun () ->
            fmtEquals
                "package P\nfunc check(x: in Int): Unit {\n  if x > 0 {\n    return ()\n  }\n}"
                "package P\n\nfunc check(x: in Int): Unit {\n  if x > 0 {\n    return ()\n  }\n}"

        testCase "val binding with type annotation" <| fun () ->
            fmtEquals
                "package P\nfunc f(x: in Int): Int {\n  val y: Int = x + 1\n  return y\n}"
                "package P\n\nfunc f(x: in Int): Int {\n  val y: Int = x + 1\n  return y\n}"

        testCase "doc comment preserved" <| fun () ->
            fmtEquals
                "package P\n/// Does something useful.\npub func foo(): Unit {\n}"
                "package P\n\n/// Does something useful.\npub func foo(): Unit {\n}"

        testCase "annotation on function preserved" <| fun () ->
            fmtEquals
                "package P\n@stable(since = \"1.0\")\npub func foo(): Unit {\n}"
                "package P\n\n@stable(since = \"1.0\")\npub func foo(): Unit {\n}"

        testCase "items separated by blank line" <| fun () ->
            let src =
                "package P\nfunc a(): Unit {\n}\nfunc b(): Unit {\n}"
            let result = roundtrip src
            let lines = result.Replace("\r\n", "\n").Split('\n')
            // There must be a blank line between the two functions
            let hasBlank =
                lines
                |> Array.pairwise
                |> Array.exists (fun (a, b) ->
                    a.TrimEnd() = "" && b.TrimStart().StartsWith "func b")
            Expect.isTrue hasBlank "blank line between items"

        testCase "isFormatted returns true for canonical source" <| fun () ->
            let src = "package P\n\nfunc f(): Unit {\n  return ()\n}\n"
            let r = parse src
            Expect.isTrue (isFormatted src r.File) "canonical source is already formatted"

        testCase "isFormatted returns false for non-canonical source" <| fun () ->
            let src = "package P\nfunc f(): Unit {\n  return ()\n}\n"
            let r = parse src
            Expect.isFalse (isFormatted src r.File) "missing blank line before item"

        testCase "for loop expanded" <| fun () ->
            fmtEquals
                "package P\nfunc f(xs: in List[Int]): Unit {\n  for x in xs {\n    println(x)\n  }\n}"
                "package P\n\nfunc f(xs: in List[Int]): Unit {\n  for x in xs {\n    println(x)\n  }\n}"

        testCase "while loop expanded" <| fun () ->
            fmtEquals
                "package P\nfunc f(x: in Int): Unit {\n  var i: Int = 0\n  while i < x {\n    i += 1\n  }\n}"
                "package P\n\nfunc f(x: in Int): Unit {\n  var i: Int = 0\n  while i < x {\n    i += 1\n  }\n}"

        testCase "match statement expanded" <| fun () ->
            fmtEquals
                "package P\nfunc describe(n: in Int): String {\n  match n {\n    case 0 -> \"zero\"\n    case _ -> \"other\"\n  }\n}"
                "package P\n\nfunc describe(n: in Int): String {\n  match n {\n    case 0 -> \"zero\"\n    case _ -> \"other\"\n  }\n}"

        testCase "binary operator precedence: no spurious parens" <| fun () ->
            let r = parse "package P\nfunc f(a: in Int, b: in Int, c: in Int): Int = a + b * c"
            let out = format r.File
            Expect.isTrue (out.Contains "a + b * c") "no parens needed for a + b * c"

        testCase "binary operator precedence: parens when needed" <| fun () ->
            let r = parse "package P\nfunc f(a: in Int, b: in Int, c: in Int): Int = (a + b) * c"
            let out = format r.File
            Expect.isTrue (out.Contains "(a + b) * c") "parens preserved for (a+b)*c"

        testCase "module doc comment preserved at top" <| fun () ->
            let src = "//! This is the module.\npackage P\n"
            let r = parse src
            let out = format r.File
            Expect.isTrue (out.StartsWith "//! This is the module.") "module doc at top"
    ]
