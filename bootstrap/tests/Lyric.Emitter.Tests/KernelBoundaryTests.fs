/// Kernel-boundary ratchet for the Lyric stdlib (D038 / Decision F).
///
/// The plan in `docs/14-native-stdlib-plan.md` §3 establishes a hard
/// cap of 150 host-extern declarations across the stdlib for v1.0,
/// concentrated in `lyric-stdlib/std/_kernel/`.  This test enforces
/// the migration as a one-way ratchet:
///
/// * `externsOutsideKernel` may **never** exceed `outsideCeiling`.
///   Whenever a PR moves an extern into `_kernel/` (or rewrites it
///   in pure Lyric), the PR also drops `outsideCeiling`.  PRs that
///   add new extern declarations outside `_kernel/` flip the test
///   red — by design.
///
/// * `externsTotal` is reported only as a soft signal; the
///   `totalSoftCap` is the v1.0 figure from Decision F.  The current
///   total is documented below; PRs that nudge it upward should
///   justify themselves in the description.  When v1.0 lands the
///   cap flips to a hard assertion.
///
/// "Extern declaration" here means any line whose first
/// non-whitespace text is `@externTarget`, `extern type`, or
/// `extern package`.  `extern package { ... }` blocks count as one
/// each — the block IS the boundary, the contents are interface.
module Lyric.Emitter.Tests.KernelBoundaryTests

open System.IO
open System.Text.RegularExpressions
open Expecto

/// Locate `lyric-stdlib/std/`. Mirror of `StdlibSeedTests`'
/// search for symmetry; failure should be impossible in CI.
let private locateStdlibDir () : string =
    let mutable dir = Some (DirectoryInfo(System.AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let d = dir.Value
        let candidate = Path.Combine(d.FullName, "lyric-stdlib", "std")
        if Directory.Exists candidate then found <- Some candidate
        dir <- d.Parent |> Option.ofObj
    match found with
    | Some p -> p
    | None ->
        failwithf "could not locate lyric-stdlib/std directory from %s"
            System.AppContext.BaseDirectory

let private externRegex =
    Regex(@"^\s*(@externTarget|extern\s+type|extern\s+package)\b",
          RegexOptions.Compiled ||| RegexOptions.Multiline)

/// Count extern-boundary declarations in a single .l file.
let private countExternsIn (path: string) : int =
    let text = File.ReadAllText(path)
    externRegex.Matches(text).Count

/// (outside, inside) pair for the stdlib root.
let private surveyExterns () : int * int =
    let root = locateStdlibDir ()
    let kernel = Path.Combine(root, "_kernel")
    let outside =
        Directory.EnumerateFiles(root, "*.l", SearchOption.TopDirectoryOnly)
        |> Seq.sumBy countExternsIn
    let inside =
        if Directory.Exists kernel then
            Directory.EnumerateFiles(kernel, "*.l", SearchOption.AllDirectories)
            |> Seq.sumBy countExternsIn
        else 0
    outside, inside

// ---- The ratchet ----------------------------------------------------------
//
// Update these numbers when migrations land.  The `outsideCeiling`
// is a one-way ratchet — only ever drops.  `totalSoftCap` matches
// Decision F's v1.0 release gate and is informational today.

/// Ceiling for `@externTarget` / `extern type` / `extern package`
/// declarations OUTSIDE `_kernel/`.  Drops as P0/4b migrations move
/// declarations into the kernel.
///
/// History:
///   139 — P0/4c PR introducing this ratchet (2026-05)
///   103 — P0/4b batch 1: io.l, parse.l, testing_mocking.l,
///         regex.l, random.l, http_server.l moved into _kernel/
///    44 — P0/4b batch 2: math.l + time.l split into native
///         trampolines (math.l, time.l) and `_kernel/{math,time}_host.l`
///     5 — P0/4b batch 3: json.l split, task.l moved.
///     0 — Q022 fix: collections.l's externs moved to
///         `_kernel/collections_host.l`; transitive symbol
///         propagation in the artifact compiler + cross-artifact
///         selector-alias resolution land in Emitter.fs.
let private outsideCeiling : int = 0

/// Soft cap on the total extern surface across the whole stdlib.
/// Decision F (D038): hard cap of 150 at v1.0.  Currently reported
/// only — flip to a hard assertion when v1.0 ships.
let private totalSoftCap : int = 150

let tests =
    testList "stdlib kernel boundary (D038 / Decision F)" [

        test "extern declarations outside _kernel/ never grow" {
            let outside, _ = surveyExterns ()
            Expect.isLessThanOrEqual outside outsideCeiling
                (sprintf
                    "found %d extern declarations outside _kernel/; \
                     the ratchet ceiling is %d.  Either move new \
                     externs into lyric-stdlib/std/_kernel/ or, \
                     if this PR is migrating externs INTO the kernel, \
                     drop `outsideCeiling` in KernelBoundaryTests.fs."
                    outside outsideCeiling)
        }

        test "kernel total reported (soft cap)" {
            let outside, inside = surveyExterns ()
            let total = outside + inside
            // Informational only at this stage; flip to a hard
            // assertion at v1.0 per Decision F.
            if total > totalSoftCap then
                printfn
                    "[D038/F] note: %d total externs, soft cap is %d \
                     (will become hard at v1.0)"
                    total totalSoftCap
            // Sanity: kernel can't be negative or wildly huge.
            Expect.isGreaterThanOrEqual inside 0 "kernel count >= 0"
            // Hard cap history:
            //   294 → 296 — `Std.HashHost` externs (`hostSha512Bytes`,
            //               `hostBytesToHex`) for #738 (lock-file
            //               content integrity).
            //   296 → 297 — `Std.FileHost.hostDeleteFile` for #845
            //               (`Std.File.deleteFile` so callers can
            //               clean up temp files explicitly).
            //   297 → 302 — `Std.ProcessCaptureHost`: `extern type
            //               ProcessCaptureResult` + four field-accessor
            //               externs (`pcResultStdout`, `pcResultStderr`,
            //               `pcResultExitCode`, `pcResultTimedOut`) for
            //               #1025 / #743 (propagate exit code + stderr
            //               through the generator / solver pipeline).
            //   302 → 303 — `Std.ProcessCaptureHost.hostRunCaptureTimeout`:
            //               timeout-aware capture entry point for
            //               `Std.Process.runCapture` / `runCaptureWithInput`
            //               (#1023 / #743).
            //   303 → 305 — `Std.EnvironmentHost.hostAppBaseDirectory` +
            //               `hostCurrentDirectory` for #1183 Phase 5: the
            //               in-process MSIL bridge's `findStdlibSources`
            //               needs to locate `lyric-stdlib/std/` at runtime
            //               (replaces the F# `SelfHostedBridge.findStdlibSources`
            //               shim).
            //   305 → 316 — `Std.AssemblyResourcesHost` for #1229 Phase A.2:
            //               three extern types (`RuntimeAssembly`,
            //               `ResStream`, `ResMemoryStream`) + eight host
            //               functions (`hostAssemblyLoadFrom`,
            //               `hostAssemblyResourceNames`,
            //               `hostAssemblyResourceStream`,
            //               `hostNewMemoryStream`, `hostStreamCopyTo`,
            //               `hostMemoryStreamToArray`,
            //               `hostStreamDispose`, `hostMemoryStreamDispose`).
            //               In-process embedded-resource reader for the
            //               self-hosted MSIL bridge's restored-dependency
            //               loader.  High-level `Assembly.LoadFrom` API
            //               chosen over `System.Reflection.Metadata.PEReader`
            //               to avoid unsafe pointer arithmetic / a 12-extern
            //               `BlobReader` chain.  Dispose calls let
            //               consumers reading many resources release
            //               unmanaged buffers deterministically rather
            //               than waiting for GC.
            //   316 → 317 — `Std.TimeHost.hostSleepMillis`: synchronous
            //               `System.Threading.Thread.Sleep` backing
            //               `Std.Time.sleepMillis`, the poll interval for
            //               `lyric run/build --watch` (#1974).
            //   317 → 321 — `Std.EncodingHost` (4 externs): `extern type Enc`
            //               + `@externTarget` for `hostGetUtf8Enc`,
            //               `hostEncodeUtf8`, `hostFromBase64`.  BCL-backed
            //               encoding boundary replacing the pure-Lyric
            //               accumulator that produced `object[]` instead of
            //               `byte[]` on .NET due to List<object> type erasure.
            //   321 → 322 — `Std.EnvironmentHost.hostGetRuntimeDirectory`:
            //               `@externTarget("System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory")`
            //               for `lyric run/build --watch` stdlib path
            //               discovery.
            //   322 → 323 — `Std.HashHost.hostSha256Bytes`:
            //               `@externTarget("System.Security.Cryptography.SHA256.HashData")`
            //               for SHA-256 hashing infrastructure (Std.Hash.sha256OfBytes).
            //   323 → 334 — `Std.ProcessCaptureHost` BCL-direct rewrite (#1489):
            //               replaces the F# `ProcessCapture` shim with direct
            //               `@externTarget` bindings to `ProcessStartInfo`,
            //               `Process`, `StreamWriter`, `StreamReader`, and
            //               `Task<string>` (5 extern types + 19 extern funcs).
            //               `ProcessCaptureResult` promoted from opaque F#-shim
            //               extern type to a native Lyric `pub record`.
            //   334 → 335 — `Std.HttpHost.hostDefaultClient` restored to
            //               `@externTarget("Lyric.Emitter.HttpClientHost.defaultClient")`
            //               so the process-wide `Lazy<HttpClient>` singleton is
            //               preserved (#3027 tracks the follow-up that replaces
            //               this with a pure-Lyric `ldsfld` path once the F#
            //               emitter gains module-val `ldsfld` support).
            //   335 → 334 — `Lyric.Emitter.HttpClientHost.defaultClient` @externTarget
            //               removed: F# emitter EPath handler now emits `ldsfld` for
            //               reference-typed module-level `pub val` fields (#3027).
            //               `hostDefaultClient()` returns the `defaultClient` singleton
            //               directly; `HttpClientHost.fs` deleted.
            //   334 → 335 — `taskWaitMs` extern added to
            //               `Std.ProcessCaptureHost` so pipe-drain collection
            //               has a bounded timeout after process kill (#3029).
            //   335 → 324 — `Std.AssemblyResourcesHost` deleted (#3201): the
            //               3 extern types + 8 host functions backing the
            //               `Assembly.Load(byte[])` resource read are gone.
            //               The embedded contract-metadata read is now
            //               metadata-direct (`Msil.MetadataReader`, pure byte
            //               reading, AOT-safe), needing no host extern at all.
            //   324 → 325 — `Std.EnvironmentHost.hostSetEnvironmentVariable`:
            //               `@externTarget("System.Environment.SetEnvironmentVariable")`
            //               backing `Std.Environment.setVar`, used by the
            //               JVM build pipeline to inject `LYRIC_FFI_JARS`
            //               before `emitProject` (#2668 J5 Maven resolver).
            //   325 → 329 — `DictKeyCollection[K,V]` and `DictValueCollection[K,V]`
            //               extern types plus `dictGetKeys` and `dictGetValues`
            //               `@externTarget` functions added to `Std.CollectionsHost`
            //               to support IEnumerator for-loop protocol over Dictionary
            //               key/value collections (#3511).
            Expect.isLessThanOrEqual total 329
                "total extern surface unexpectedly large"
        }
    ]
