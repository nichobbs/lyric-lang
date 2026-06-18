/// Lyric.Jobs.Host — .NET host shim for the lyric-jobs kernel.
///
/// Phase 3 of #733: in-process scheduler backend only.  Hangfire and
/// Quartz.NET shims are tracked under #781 as separate phases — both
/// need durable persistent storage (SQL Server for Hangfire, SQLite for
/// Quartz) for meaningful regression coverage, while the in-process
/// path stays self-contained on the BCL.
///
/// The kernel file `lyric-jobs/src/_kernel/net/jobs_kernel.l` declares
/// each entry point with `@externTarget("Lyric.Jobs.InProcessHost.<method>")`
/// or `@externTarget("Lyric.Jobs.Threading.<method>")`; the emitter
/// resolves those references to the static methods below at codegen
/// time.
///
/// Threading primitives (`nowMs`, `sleepMs`, `generateId`) live in
/// `Lyric.Jobs.Threading` so they're available without opening a
/// scheduler.
///
/// Job status strings: "Pending" | "Running" | "Succeeded" | "Failed" | "Cancelled".

namespace Lyric.Jobs

open System
open System.Collections.Concurrent
open System.Threading

// ─── Shared threading primitives ─────────────────────────────────────────────

/// Static class exposing the three threading primitives the kernel's
/// `@externTarget("Lyric.Jobs.Threading.<method>")` declarations bind
/// to.  Lives outside the scheduler registry because they're useful
/// independent of any scheduler instance.
[<Sealed; AbstractClass>]
type Threading private () =

    /// Current UTC wall-clock time as Unix epoch milliseconds.
    static member nowMs() : int64 =
        DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()

    /// Block the calling thread for `ms` milliseconds.
    static member sleepMs(ms: int) : unit =
        if ms > 0 then Thread.Sleep(ms)

    /// Random ID backed by `Guid.NewGuid().ToString("N")`.  32 hex chars
    /// without dashes — matches the convention used in lyric-session.
    static member generateId() : string =
        Guid.NewGuid().ToString("N")

// ─── In-process scheduler registry ───────────────────────────────────────────

/// Per-job state tracked by the in-process scheduler.
type private JobRecord =
    { mutable Status:     string
      Name:               string
      Payload:            string
      mutable Attempts:   int
      MaxAttempts:        int
      TimeoutMs:          int
      mutable StartedAt:  int64
      mutable FinishedAt: int64
      mutable Error:      string
      mutable Output:     string }

type private InProcessScheduler =
    { Jobs: ConcurrentDictionary<string, JobRecord>
      mutable Workers: int }

module private Registry =
    let schedulers : ConcurrentDictionary<int, InProcessScheduler> =
        ConcurrentDictionary<int, InProcessScheduler>()
    let nextHandle : int ref = ref 0

    let register (s: InProcessScheduler) : int =
        let h = Interlocked.Increment(nextHandle)
        schedulers.[h] <- s
        h

    let lookup (h: int) : Result<InProcessScheduler, string> =
        match schedulers.TryGetValue(h) with
        | true, s -> Ok s
        | false, _ -> Error (sprintf "unknown scheduler handle %d" h)

    let safeCall (op: unit -> 'T) : Result<'T, string> =
        try Ok (op())
        with ex -> Error (sprintf "%s: %s" (ex.GetType().Name) ex.Message)

    /// Minimal JSON-string escape mirroring the kernel's escape chain.
    let jsonString (s: string) : string =
        let sb = System.Text.StringBuilder()
        sb.Append('"') |> ignore
        for c in s do
            match c with
            | '\\' -> sb.Append("\\\\") |> ignore
            | '"'  -> sb.Append("\\\"") |> ignore
            | '\n' -> sb.Append("\\n")  |> ignore
            | '\r' -> sb.Append("\\r")  |> ignore
            | '\t' -> sb.Append("\\t")  |> ignore
            | _    -> sb.Append(c)      |> ignore
        sb.Append('"') |> ignore
        sb.ToString()

/// `Lyric.Jobs.InProcessHost` — the static class the kernel's
/// `@externTarget("Lyric.Jobs.InProcessHost.<method>")` references
/// resolve to.  The in-process scheduler runs jobs on the .NET thread
/// pool via `Task.Run`; cron is intentionally NOT supported (returns
/// Err) because durable cron without a persistence layer is misleading
/// — Quartz/Hangfire shims fill that role.
[<Sealed; AbstractClass>]
type InProcessHost private () =

    /// Open an in-process scheduler with the given worker count (advisory:
    /// the .NET thread pool auto-sizes, so this only affects diagnostics).
    static member connect(workerCount: int) : Result<int, string> =
        if workerCount < 1 then
            Error "Lyric.Jobs.InProcessHost.connect: workerCount must be >= 1"
        else
            Registry.safeCall (fun () ->
                let s = { Jobs = ConcurrentDictionary<string, JobRecord>(); Workers = workerCount }
                Registry.register s)

    /// Enqueue a fire-and-forget job.  Returns the assigned job ID.
    /// The in-process scheduler stores the job's payload + metadata but
    /// does not execute it (this shim is a lifecycle tracker; runners
    /// dispatch via the Lyric-side `Lyric.Jobs.runHandler` registry).
    /// `nameToHandler` dispatch is the caller's responsibility — see
    /// `lyric-jobs/src/jobs.l`'s `JobHandler` interface.
    static member enqueue(schedulerId: int, name: string, payload: string,
                           maxAttempts: int, timeoutMs: int) : Result<string, string> =
        if String.IsNullOrEmpty(name) then
            Error "Lyric.Jobs.InProcessHost.enqueue: name must be non-empty"
        elif maxAttempts < 1 then
            Error "Lyric.Jobs.InProcessHost.enqueue: maxAttempts must be >= 1"
        elif timeoutMs < 1 then
            Error "Lyric.Jobs.InProcessHost.enqueue: timeoutMs must be >= 1"
        else
            match Registry.lookup schedulerId with
            | Error e -> Error e
            | Ok scheduler ->
                Registry.safeCall (fun () ->
                    let id = Guid.NewGuid().ToString("N")
                    let now = Threading.nowMs()
                    let record = {
                        Status = "Pending"
                        Name = name
                        Payload = payload
                        Attempts = 0
                        MaxAttempts = maxAttempts
                        TimeoutMs = timeoutMs
                        StartedAt = now
                        FinishedAt = 0L
                        Error = ""
                        Output = ""
                    }
                    scheduler.Jobs.[id] <- record
                    id)

    /// Cron scheduling is not supported on the in-process backend —
    /// durable persistence is required to survive process restarts.
    /// Quartz / Hangfire shims fill this role; this method returns Err.
    static member schedule(schedulerId: int, name: string, payload: string,
                            cronExpr: string, maxAttempts: int, timeoutMs: int) : Result<string, string> =
        match Registry.lookup schedulerId with
        | Error e -> Error e
        | Ok _ -> Error "lyric-jobs: cron scheduling not supported on in-process backend (Phase 3 of #733; Hangfire/Quartz shims are follow-ups)"

    /// Cancel a job by ID.  Idempotent: no error if the job doesn't
    /// exist or is already terminal.
    static member cancel(schedulerId: int, jobId: string) : Result<unit, string> =
        if String.IsNullOrEmpty(jobId) then
            Error "Lyric.Jobs.InProcessHost.cancel: jobId must be non-empty"
        else
            match Registry.lookup schedulerId with
            | Error e -> Error e
            | Ok scheduler ->
                Registry.safeCall (fun () ->
                    match scheduler.Jobs.TryGetValue(jobId) with
                    | true, record ->
                        match record.Status with
                        | "Pending" | "Running" ->
                            record.Status <- "Cancelled"
                            record.FinishedAt <- Threading.nowMs()
                        | _ -> ()  // already terminal
                    | false, _ -> ())

    /// Return the current job-status string.
    static member status(schedulerId: int, jobId: string) : Result<string, string> =
        if String.IsNullOrEmpty(jobId) then
            Error "Lyric.Jobs.InProcessHost.status: jobId must be non-empty"
        else
            match Registry.lookup schedulerId with
            | Error e -> Error e
            | Ok scheduler ->
                match scheduler.Jobs.TryGetValue(jobId) with
                | true, record -> Ok record.Status
                | false, _ -> Error (sprintf "unknown job ID '%s'" jobId)

    /// Return a JSON array of result records for this job.
    static member results(schedulerId: int, jobId: string) : Result<string, string> =
        if String.IsNullOrEmpty(jobId) then
            Error "Lyric.Jobs.InProcessHost.results: jobId must be non-empty"
        else
            match Registry.lookup schedulerId with
            | Error e -> Error e
            | Ok scheduler ->
                match scheduler.Jobs.TryGetValue(jobId) with
                | true, r ->
                    let json =
                        sprintf "[{\"jobId\":%s,\"status\":%s,\"output\":%s,\"error\":%s,\"startedAt\":%d,\"finishedAt\":%d}]"
                            (Registry.jsonString jobId) (Registry.jsonString r.Status)
                            (Registry.jsonString r.Output) (Registry.jsonString r.Error)
                            r.StartedAt r.FinishedAt
                    Ok json
                | false, _ -> Ok "[]"

    // ── Hangfire / Quartz placeholders ────────────────────────────────────────
    //
    // These exist so the `@cfg(feature = "hangfire" | "quartz")` arms in
    // `jobs_kernel.l` have something to `@externTarget` at.  Each returns a
    // clear Err pointing at the follow-up issue; the in-process backend
    // (the `local` / `inprocess` feature, when added) is the one fully
    // functional path under Phase 3.

    static member hangfireConnectNotYet(connectionString: string, workerCount: int) : Result<int, string> =
        Error "lyric-jobs: Hangfire backend not yet implemented (Phase 3 follow-up of #733)"

    static member quartzConnectNotYet(workerCount: int) : Result<int, string> =
        Error "lyric-jobs: Quartz.NET backend not yet implemented (Phase 3 follow-up of #733)"
