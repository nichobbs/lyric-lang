/// Unit tests for `parseMajorMinor`, the version-string helper behind
/// the B0050/B0051 SDK-skew diagnostics in `Lyric.Emitter.Emitter`.
module Lyric.Emitter.Tests.SdkVersionSkewTests

open Expecto

let tests =
    testList "SDK version skew (B0050/B0051)" [

        testCase "[parseMajorMinor: simple semver]" <| fun () ->
            Expect.equal
                (Lyric.Emitter.Emitter.parseMajorMinor "0.1.0")
                (Some (0, 1))
                "0.1.0 -> Some(0, 1)"

        testCase "[parseMajorMinor: semver with patch]" <| fun () ->
            Expect.equal
                (Lyric.Emitter.Emitter.parseMajorMinor "1.2.3")
                (Some (1, 2))
                "1.2.3 -> Some(1, 2)"

        testCase "[parseMajorMinor: pre-release suffix on minor]" <| fun () ->
            Expect.equal
                (Lyric.Emitter.Emitter.parseMajorMinor "0.2-rc1")
                (Some (0, 2))
                "0.2-rc1 strips the suffix on the minor component"

        testCase "[parseMajorMinor: two segments only]" <| fun () ->
            Expect.equal
                (Lyric.Emitter.Emitter.parseMajorMinor "4.7")
                (Some (4, 7))
                "4.7 -> Some(4, 7)"

        testCase "[parseMajorMinor: single segment is None]" <| fun () ->
            Expect.isNone
                (Lyric.Emitter.Emitter.parseMajorMinor "42")
                "single-segment version is unparseable"

        testCase "[parseMajorMinor: empty string]" <| fun () ->
            Expect.isNone
                (Lyric.Emitter.Emitter.parseMajorMinor "")
                "empty string is None"

        testCase "[parseMajorMinor: non-numeric major]" <| fun () ->
            Expect.isNone
                (Lyric.Emitter.Emitter.parseMajorMinor "alpha.1.0")
                "non-numeric major is None"

        testCase "[parseMajorMinor: non-numeric minor]" <| fun () ->
            Expect.isNone
                (Lyric.Emitter.Emitter.parseMajorMinor "1.alpha.0")
                "non-numeric minor is None"
    ]
