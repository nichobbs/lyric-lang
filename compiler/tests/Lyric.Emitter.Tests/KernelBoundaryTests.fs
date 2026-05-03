/// Kernel-boundary ratchet for the Lyric stdlib (D038 / Decision F).
///
/// The plan in `docs/14-native-stdlib-plan.md` §3 establishes a hard
/// cap of 150 host-extern declarations across the stdlib for v1.0,
/// concentrated in `compiler/lyric/std/_kernel/`.  This test enforces
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

/// Locate `compiler/lyric/std/`. Mirror of `StdlibSeedTests`'
/// search for symmetry; failure should be impossible in CI.
let private locateStdlibDir () : string =
    let mutable dir = Some (DirectoryInfo(System.AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let d = dir.Value
        let candidate = Path.Combine(d.FullName, "lyric", "std")
        if Directory.Exists candidate then found <- Some candidate
        dir <- d.Parent |> Option.ofObj
    match found with
    | Some p -> p
    | None ->
        failwithf "could not locate lyric/std directory from %s"
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
/// declarations into the kernel.  Last update: P0/4c PR introducing
/// this ratchet (2026-05).
let private outsideCeiling : int = 139

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
                     externs into compiler/lyric/std/_kernel/ or, \
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
            Expect.isLessThanOrEqual total 250
                "total extern surface unexpectedly large"
        }
    ]
