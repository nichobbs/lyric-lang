/// End-to-end tests for `Std.File` — the bootstrap-grade file I/O
/// wrapper.  Each test writes / reads a temp file from inside the
/// emitted Lyric program (host calls route to `Lyric.Stdlib.FileHost`)
/// and verifies the round-trip.
module Lyric.Emitter.Tests.StdFileTests

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private tempDir () : string =
    let d = Path.Combine(Path.GetTempPath(),
                         "lyric-stdfile-" + Guid.NewGuid().ToString("N"))
    Directory.CreateDirectory d |> ignore
    d

let private withTempDir (action: string -> 'a) : 'a =
    let dir = tempDir ()
    try action dir
    finally try Directory.Delete(dir, true) with _ -> ()

let private compile (label: string) (source: string) : string =
    let _, stdout, stderr, exitCode = compileAndRun label source
    Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
    stdout.TrimEnd()

let private esc (p: string) : string = p.Replace("\\", "\\\\")

let private writeReadSource (path: string) : string =
    let p = esc path
    sprintf "package SF1\nimport Std.Core\nimport Std.File\n\nfunc main(): Unit {\n  match writeText(\"%s\", \"hello, file\") {\n    case Ok(_)  -> println(\"wrote\")\n    case Err(_) -> println(\"write failed\")\n  }\n  match readText(\"%s\") {\n    case Ok(text) -> println(text)\n    case Err(_)   -> println(\"read failed\")\n  }\n}\n" p p

let private existsSource (path: string) : string =
    let p = esc path
    sprintf "package SF2\nimport Std.Core\nimport Std.File\n\nfunc main(): Unit {\n  match writeText(\"%s\", \"x\") {\n    case Ok(_)  -> println(\"wrote\")\n    case Err(_) -> println(\"write failed\")\n  }\n  if fileExists(\"%s\") {\n    println(\"yes\")\n  } else {\n    println(\"no\")\n  }\n}\n" p p

let private missingSource (path: string) : string =
    let p = esc path
    sprintf "package SF3\nimport Std.Core\nimport Std.File\nimport Std.Errors\n\nfunc main(): Unit {\n  match readText(\"%s\") {\n    case Ok(_)  -> println(\"unexpected ok\")\n    case Err(e) -> println(IOError.message(e))\n  }\n}\n" p

let private invalidPathSource () : string =
    "package SF4\nimport Std.Core\nimport Std.File\nimport Std.Errors\n\nfunc main(): Unit {\n  match readText(\"\") {\n    case Ok(_)  -> println(\"unexpected ok\")\n    case Err(e) -> println(IOError.message(e))\n  }\n}\n"

let private createDirSource (dirPath: string) (filePath: string) : string =
    let d = esc dirPath
    let f = esc filePath
    sprintf "package SF5\nimport Std.Core\nimport Std.File\n\nfunc main(): Unit {\n  match createDir(\"%s\") {\n    case Ok(_)  -> println(\"made\")\n    case Err(_) -> println(\"mkdir failed\")\n  }\n  match writeText(\"%s\", \"nested\") {\n    case Ok(_)  -> println(\"wrote\")\n    case Err(_) -> println(\"write failed\")\n  }\n  match readText(\"%s\") {\n    case Ok(t)  -> println(t)\n    case Err(_) -> println(\"read failed\")\n  }\n}\n" d f f

let tests =
    testSequenced
    <| testList "Std.File round-trip" [

        testCase "[write_then_read]" <| fun () ->
            withTempDir (fun dir ->
                let path = Path.Combine(dir, "scratch.txt")
                let stdout = compile "write_then_read" (writeReadSource path)
                Expect.equal stdout "wrote\nhello, file" "round-trip text")

        testCase "[exists_after_write]" <| fun () ->
            withTempDir (fun dir ->
                let path = Path.Combine(dir, "scratch.txt")
                let stdout = compile "exists_after_write" (existsSource path)
                Expect.equal stdout "wrote\nyes" "exists after write")

        testCase "[missing_file_returns_FileNotFound]" <| fun () ->
            withTempDir (fun dir ->
                let path = Path.Combine(dir, "missing.txt")
                let stdout = compile "missing_file_returns_FileNotFound" (missingSource path)
                Expect.equal stdout (sprintf "file not found: %s" path)
                    "FileNotFound surfaced")

        testCase "[empty_path_returns_InvalidPath]" <| fun () ->
            let stdout = compile "empty_path_returns_InvalidPath" (invalidPathSource ())
            Expect.equal stdout "invalid path:  (path must not be empty)"
                "InvalidPath surfaced for empty input"

        testCase "[create_dir_then_write]" <| fun () ->
            withTempDir (fun dir ->
                let sub  = Path.Combine(dir, "sub")
                let file = Path.Combine(sub, "inner.txt")
                let stdout = compile "create_dir_then_write" (createDirSource sub file)
                Expect.equal stdout "made\nwrote\nnested" "create dir + nested write/read")
    ]
