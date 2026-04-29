module Lyric.Emitter.Tests.StdlibSmokeTests

open System.IO
open Expecto
open Lyric.Stdlib

/// Capture stdout produced by `action` and return it as a string.
/// Used to verify the F#-side stdlib shim before the emitter is
/// online — once E1 lands, equivalent end-to-end tests will compile
/// real Lyric programs and observe their stdout.
let private captureStdout (action: unit -> unit) : string =
    let saved = System.Console.Out
    use writer = new StringWriter()
    try
        System.Console.SetOut(writer)
        action ()
        writer.ToString()
    finally
        System.Console.SetOut(saved)

// `System.Console.SetOut` is process-global, so the captureStdout
// pattern cannot run in parallel with anything else that writes to
// stdout. Mark this list as sequenced.
let tests =
    testSequenced
    <| testList "stdlib shim" [

        test "Console.Println writes the line plus newline" {
            let out = captureStdout (fun () -> Console.Println("hello"))
            Expect.equal out (sprintf "hello%s" System.Environment.NewLine)
                "println output"
        }

        test "Console.Print writes without a newline" {
            let out = captureStdout (fun () -> Console.Print("hi"))
            Expect.equal out "hi" "print output"
        }

        test "Contracts.Expect succeeds on a true condition" {
            // No exception should escape.
            Contracts.Expect(true, "should hold")
        }

        test "Contracts.Expect raises on a false condition" {
            Expect.throwsT<LyricAssertionException>
                (fun () -> Contracts.Expect(false, "boom"))
                "expect throws"
        }

        test "Contracts.Assert raises with a default message" {
            Expect.throwsT<LyricAssertionException>
                (fun () -> Contracts.Assert(false))
                "assert throws"
        }

        test "Contracts.Panic always throws" {
            Expect.throwsT<LyricAssertionException>
                (fun () -> Contracts.Panic("bad state"))
                "panic throws"
        }
    ]
