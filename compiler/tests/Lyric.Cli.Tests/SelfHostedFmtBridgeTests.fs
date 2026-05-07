/// Phase 5 §M5.3 stage 3 — exercises `Lyric.Cli.SelfHostedFmt`, the
/// reflection bridge from the F# `lyric fmt` subcommand into the
/// self-hosted `Lyric.Fmt` (M5.3 stage 2 / D-progress-131).
///
/// The bridge compiles a tiny driver Lyric program on first use to
/// trigger the emitter's stdlib precompile path for `Lyric.Fmt.dll`,
/// then loads the resulting assembly and invokes `formatSource(string)`
/// / `isFormattedSource(string)` via reflection.  These tests verify
/// the round-trip works AND that comments — which the F# AST formatter
/// drops — are preserved.
module Lyric.Cli.Tests.SelfHostedFmtBridgeTests

open Expecto
open Lyric.Cli

let tests =
    testList "Lyric.Cli.SelfHostedFmt (Phase 5 §M5.3 stage 3)" [

        testCase "bridge: package-only file round-trips" <| fun () ->
            let formatted = SelfHostedFmt.format "package Foo.Bar\n"
            Expect.equal formatted "package Foo.Bar\n"
                "self-hosted formatter produces canonical Lyric source"

        testCase "bridge: line comment between items survives" <| fun () ->
            // The F# AST formatter would drop this `//` comment per the
            // header banner in compiler/src/Lyric.Cli/Fmt.fs.  The
            // self-hosted formatter walks the CST and keeps it.
            let source =
                "package P\n\nalias A = Int\n\n// keep me between items\nalias B = String\n"
            let formatted = SelfHostedFmt.format source
            Expect.stringContains formatted "// keep me between items"
                "non-doc comment between items survives the bridge"
            Expect.stringContains formatted "alias A = Int"
                "first item still emitted"
            Expect.stringContains formatted "alias B = String"
                "second item still emitted"

        testCase "bridge: leading line comment before first item survives" <| fun () ->
            let source = "package P\n\n// header comment\nalias A = Int\n"
            let formatted = SelfHostedFmt.format source
            Expect.stringContains formatted "// header comment"
                "leading comment is preserved"

        testCase "bridge: trailing comment after last item survives" <| fun () ->
            let source = "package P\n\nalias A = Int\n\n// trailing\n"
            let formatted = SelfHostedFmt.format source
            Expect.stringContains formatted "// trailing"
                "trailing comment is preserved"

        testCase "bridge: block comment between items survives" <| fun () ->
            let source =
                "package P\n\nalias A = Int\n\n/* block between */\nalias B = String\n"
            let formatted = SelfHostedFmt.format source
            Expect.stringContains formatted "/* block between */"
                "block comment between items survives"

        testCase "bridge: idempotence — formatted output is canonical" <| fun () ->
            let source =
                "package P\n\n// explainer\nalias A = Int\n"
            let f1 = SelfHostedFmt.format source
            let f2 = SelfHostedFmt.format f1
            Expect.equal f2 f1 "format(format(x)) == format(x)"
            Expect.isTrue (SelfHostedFmt.isFormatted f1)
                "isFormatted reports the canonical output as canonical"

        testCase "bridge: isFormatted distinguishes canonical from non-canonical" <| fun () ->
            // Trailing whitespace + missing blank line between items
            // → not canonical.
            let messy = "package P\nalias A = Int   \nalias B = String\n"
            Expect.isFalse (SelfHostedFmt.isFormatted messy)
                "messy input is correctly flagged as non-canonical"
            let cleaned = SelfHostedFmt.format messy
            Expect.isTrue (SelfHostedFmt.isFormatted cleaned)
                "cleaned output round-trips as canonical"
    ]
