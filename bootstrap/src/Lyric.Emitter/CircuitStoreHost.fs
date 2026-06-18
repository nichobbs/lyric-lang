/// Process-global circuit-breaker state store for `Lyric.Resilience`.
///
/// Issue #365: the previous design declared
/// `extern package Lyric.Resilience.CircuitStore { ... }` in
/// `lyric-resilience/src/_kernel/net/resilience_kernel.l` but no host-side
/// implementation existed anywhere in the repo, so the library threw
/// `MissingMethodException` at runtime.  This module supplies the
/// missing host realization.
///
/// The state machine here is the in-process realization of the formal
/// model declared as `pub protected type CircuitBreakerState` in
/// `lyric-resilience/src/resilience.l`.  Both must stay in sync — the
/// Lyric protected type is the verifier-visible source of truth (it
/// carries the invariants `consecutiveFailures >= 0` and
/// `isOpen ==> openedAtMs > 0`); this F# shim is the runtime that
/// honours those invariants until M5.2 wire-singleton support lets
/// Lyric own the registry directly.
///
/// State per circuit (keyed by name):
///   ConsecutiveFailures    : Int   — count since last success
///   IsOpen                 : Bool  — true ⇒ rejecting calls
///   OpenedAtMs             : Int64 — UTC ms at last open
///   HalfOpenProbeInFlight  : Bool  — true ⇒ one probe is in flight
///
/// Transitions (all mutations under a per-entry lock):
///   recordSuccess               → closed; counters reset
///   recordFailure when closed   → counter++; opens when counter >= threshold
///   recordFailure when open     → re-open with fresh OpenedAtMs (probe failed)
///   circuitIsOpen when closed   → false (allow)
///   circuitIsOpen when open and elapsed <  cooldownMs → true (block)
///   circuitIsOpen when open and elapsed >= cooldownMs
///       and !probe-in-flight    → false (allow probe); set probe-in-flight
///       and  probe-in-flight    → true (block; another probe is running)
///
/// Per-entry locks are taken on the entry object itself; concurrent
/// callers for different circuit names never contend.
module Lyric.Resilience.CircuitStore

open System
open System.Collections.Concurrent

[<Sealed>]
type private Entry() =
    let mutable consecutiveFailures : int   = 0
    let mutable isOpen              : bool  = false
    let mutable openedAtMs          : int64 = 0L
    let mutable halfOpenProbeInFlight : bool = false

    static let nowMs () : int64 =
        DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()

    member this.CheckOpen(cooldownMs: int) : bool =
        lock this (fun () ->
            if not isOpen then false
            else
                let elapsed = nowMs() - openedAtMs
                if elapsed < int64 cooldownMs then true
                elif halfOpenProbeInFlight then true
                else
                    halfOpenProbeInFlight <- true
                    false)

    member this.RecordSuccess() : unit =
        lock this (fun () ->
            consecutiveFailures   <- 0
            isOpen                <- false
            openedAtMs            <- 0L
            halfOpenProbeInFlight <- false)

    member this.RecordFailure(threshold: int) : unit =
        lock this (fun () ->
            consecutiveFailures <- consecutiveFailures + 1
            if isOpen then
                // Half-open probe failed — re-open with a fresh cooldown.
                openedAtMs            <- nowMs()
                halfOpenProbeInFlight <- false
            elif consecutiveFailures >= threshold then
                isOpen                <- true
                openedAtMs            <- nowMs()
                halfOpenProbeInFlight <- false)

    /// Test-only: read the four state fields without mutation.  Returned
    /// as a tuple so F# tests can assert against them without exposing
    /// mutable accessors on the production path.
    member this.Snapshot() : int * bool * int64 * bool =
        lock this (fun () ->
            consecutiveFailures, isOpen, openedAtMs, halfOpenProbeInFlight)

let private store : ConcurrentDictionary<string, Entry> =
    ConcurrentDictionary<string, Entry>()

let private getOrCreate (name: string) : Entry =
    store.GetOrAdd(name, fun _ -> Entry())

/// Resolved from `extern package Lyric.Resilience.CircuitStore` in
/// `lyric-resilience/src/_kernel/net/resilience_kernel.l`.  Returns true
/// when the named circuit is currently rejecting calls.  When the
/// circuit is open but `cooldownMs` has elapsed since the last open,
/// the first caller to observe the elapsed cooldown is granted the
/// half-open probe and returns false; concurrent callers continue to
/// see true until the probe records its outcome.
let circuitIsOpen (name: string, cooldownMs: int) : bool =
    (getOrCreate name).CheckOpen(cooldownMs)

/// Record a successful call against the named circuit.  Resets the
/// failure counter, closes the circuit, and clears the half-open probe
/// flag.  Idempotent.
let circuitRecordSuccess (name: string) : unit =
    (getOrCreate name).RecordSuccess()

/// Record a failed call against the named circuit.  Increments the
/// consecutive-failure counter; opens the circuit when the counter
/// reaches `failureThreshold`.  When already open, refreshes the
/// `openedAtMs` timestamp so the cooldown window restarts (a failing
/// half-open probe should not immediately re-arm).
let circuitRecordFailure (name: string, failureThreshold: int) : unit =
    (getOrCreate name).RecordFailure(failureThreshold)

/// Test-only: drop the named entry from the registry.  Used to reset
/// state between F# unit tests; the public Lyric surface has no such
/// helper because user code never needs to forget circuit history.
let resetForTesting (name: string) : unit =
    store.TryRemove(name) |> ignore

/// Test-only: drop every entry from the registry.
let resetAllForTesting () : unit =
    store.Clear()

/// Test-only: peek at an entry's state without mutating it.  Returns
/// `None` if the named circuit has no recorded state yet.
let snapshotForTesting (name: string) : (int * bool * int64 * bool) option =
    match store.TryGetValue name with
    | true, entry -> Some (entry.Snapshot())
    | _ -> None
