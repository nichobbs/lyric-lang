/// Tests for `Lyric.Resilience.CircuitStore` — the F# host backing
/// `lyric-resilience`'s circuit-breaker state machine (issue #365).
///
/// Each test uses a unique circuit name so test ordering doesn't matter,
/// and a `resetForTesting` helper ensures clean state where order-
/// sensitive scenarios (half-open, re-open, cooldown) need it.
module Lyric.Emitter.Tests.CircuitStoreHostTests

open System.Threading
open Expecto
open Lyric.Resilience

let tests =
    testList "CircuitStoreHost (Lyric.Resilience.CircuitStore)" [

        testCase "fresh circuit reports closed" <| fun () ->
            let name = "fresh-circuit-test"
            CircuitStore.resetForTesting name
            Expect.isFalse
                (CircuitStore.circuitIsOpen(name, 30000))
                "fresh circuit must be closed"

        testCase "failures below threshold leave circuit closed" <| fun () ->
            let name = "below-threshold-test"
            CircuitStore.resetForTesting name
            CircuitStore.circuitRecordFailure(name, 5)
            CircuitStore.circuitRecordFailure(name, 5)
            CircuitStore.circuitRecordFailure(name, 5)
            CircuitStore.circuitRecordFailure(name, 5)
            Expect.isFalse
                (CircuitStore.circuitIsOpen(name, 30000))
                "four failures below threshold of 5: circuit stays closed"

        testCase "reaching threshold opens the circuit" <| fun () ->
            let name = "at-threshold-test"
            CircuitStore.resetForTesting name
            for _ in 1 .. 5 do
                CircuitStore.circuitRecordFailure(name, 5)
            Expect.isTrue
                (CircuitStore.circuitIsOpen(name, 30000))
                "five failures at threshold of 5: circuit opens"

        testCase "recordSuccess closes an open circuit" <| fun () ->
            let name = "success-closes-test"
            CircuitStore.resetForTesting name
            for _ in 1 .. 3 do
                CircuitStore.circuitRecordFailure(name, 3)
            Expect.isTrue
                (CircuitStore.circuitIsOpen(name, 30000))
                "circuit must open after 3 failures (threshold 3)"
            CircuitStore.circuitRecordSuccess name
            Expect.isFalse
                (CircuitStore.circuitIsOpen(name, 30000))
                "circuit must close after recordSuccess"

        testCase "snapshot tracks failure counter" <| fun () ->
            let name = "snapshot-failures-test"
            CircuitStore.resetForTesting name
            CircuitStore.circuitRecordFailure(name, 10)
            CircuitStore.circuitRecordFailure(name, 10)
            match CircuitStore.snapshotForTesting name with
            | Some (failures, isOpen, _, _) ->
                Expect.equal failures 2 "consecutiveFailures should be 2"
                Expect.isFalse isOpen "circuit still closed below threshold"
            | None ->
                failtest "expected snapshot to exist after recordFailure"

        testCase "snapshot reflects open state with timestamp" <| fun () ->
            let name = "snapshot-open-test"
            CircuitStore.resetForTesting name
            CircuitStore.circuitRecordFailure(name, 2)
            CircuitStore.circuitRecordFailure(name, 2)
            match CircuitStore.snapshotForTesting name with
            | Some (failures, isOpen, openedAt, halfOpenProbeInFlight) ->
                Expect.equal failures 2 "consecutiveFailures should be 2"
                Expect.isTrue isOpen "circuit should be open"
                Expect.isGreaterThan openedAt 0L "openedAtMs should be set"
                Expect.isFalse halfOpenProbeInFlight "no probe in flight yet"
            | None ->
                failtest "expected snapshot to exist after recordFailure"

        testCase "after cooldown, first checkOpen grants a probe" <| fun () ->
            let name = "half-open-grant-test"
            CircuitStore.resetForTesting name
            for _ in 1 .. 2 do
                CircuitStore.circuitRecordFailure(name, 2)
            Expect.isTrue
                (CircuitStore.circuitIsOpen(name, 30000))
                "circuit open while cooldown holds"
            // cooldownMs=1 + 25ms sleep guarantees we're past the cooldown.
            Thread.Sleep(25)
            Expect.isFalse
                (CircuitStore.circuitIsOpen(name, 1))
                "first checkOpen past cooldown grants the probe (returns false)"

        testCase "concurrent checks past cooldown allow only one probe" <| fun () ->
            let name = "half-open-single-probe-test"
            CircuitStore.resetForTesting name
            for _ in 1 .. 2 do
                CircuitStore.circuitRecordFailure(name, 2)
            Thread.Sleep(25)
            let cooldown = 1
            let probe1 = CircuitStore.circuitIsOpen(name, cooldown)
            let probe2 = CircuitStore.circuitIsOpen(name, cooldown)
            Expect.isFalse probe1 "first caller past cooldown gets the probe"
            Expect.isTrue probe2 "second caller is still blocked (probe in flight)"

        testCase "successful probe closes the circuit" <| fun () ->
            let name = "half-open-success-test"
            CircuitStore.resetForTesting name
            for _ in 1 .. 2 do
                CircuitStore.circuitRecordFailure(name, 2)
            Thread.Sleep(25)
            // Take the probe.
            Expect.isFalse
                (CircuitStore.circuitIsOpen(name, 1))
                "first caller gets the probe"
            // Probe succeeded → circuit closes.
            CircuitStore.circuitRecordSuccess name
            match CircuitStore.snapshotForTesting name with
            | Some (failures, isOpen, _, halfOpenProbeInFlight) ->
                Expect.equal failures 0 "consecutiveFailures reset to 0"
                Expect.isFalse isOpen "circuit closed"
                Expect.isFalse halfOpenProbeInFlight "probe flag cleared"
            | None ->
                failtest "expected snapshot to exist"
            Expect.isFalse
                (CircuitStore.circuitIsOpen(name, 30000))
                "circuit is closed after probe success"

        testCase "failed probe re-opens with fresh cooldown" <| fun () ->
            let name = "half-open-failure-test"
            CircuitStore.resetForTesting name
            for _ in 1 .. 2 do
                CircuitStore.circuitRecordFailure(name, 2)
            // Capture initial open timestamp.
            let initialOpenedAt =
                match CircuitStore.snapshotForTesting name with
                | Some (_, _, ts, _) -> ts
                | None -> -1L
            Thread.Sleep(25)
            // Take the probe.
            Expect.isFalse
                (CircuitStore.circuitIsOpen(name, 1))
                "first caller past cooldown gets the probe"
            // Probe fails → circuit re-opens with fresh openedAtMs.
            CircuitStore.circuitRecordFailure(name, 2)
            match CircuitStore.snapshotForTesting name with
            | Some (failures, isOpen, openedAt, halfOpenProbeInFlight) ->
                Expect.isGreaterThan failures 2 "failures continued accumulating"
                Expect.isTrue isOpen "circuit re-opens after failed probe"
                Expect.isGreaterThan openedAt initialOpenedAt
                    "openedAtMs refreshed after failed probe"
                Expect.isFalse halfOpenProbeInFlight "probe flag cleared on failure"
            | None ->
                failtest "expected snapshot to exist"

        testCase "circuits with different names are independent" <| fun () ->
            let a = "independent-circuit-a"
            let b = "independent-circuit-b"
            CircuitStore.resetForTesting a
            CircuitStore.resetForTesting b
            for _ in 1 .. 3 do
                CircuitStore.circuitRecordFailure(a, 3)
            Expect.isTrue
                (CircuitStore.circuitIsOpen(a, 30000))
                "circuit a is open"
            Expect.isFalse
                (CircuitStore.circuitIsOpen(b, 30000))
                "circuit b is still closed (independent)"

        testCase "recordSuccess on a fresh circuit is idempotent" <| fun () ->
            let name = "idempotent-success-test"
            CircuitStore.resetForTesting name
            CircuitStore.circuitRecordSuccess name
            CircuitStore.circuitRecordSuccess name
            Expect.isFalse
                (CircuitStore.circuitIsOpen(name, 30000))
                "repeated recordSuccess leaves circuit closed"
    ]
