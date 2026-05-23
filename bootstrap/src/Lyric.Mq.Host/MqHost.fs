/// Lyric.Mq.Host — .NET host shim for the lyric-mq kernel.
///
/// Phase 5 of #733: in-memory message queue backend only.  RabbitMQ,
/// Azure Service Bus, AWSSDK.SQS, and Confluent.Kafka shims are tracked
/// under #779 as separate phases — each needs broker-specific
/// Testcontainers infrastructure for regression coverage, while the
/// in-memory path stays self-contained on the BCL.
///
/// The kernel file `lyric-mq/src/_kernel/net/mq_kernel.l` declares each
/// entry point with `@externTarget("Lyric.Mq.InMemoryHost.<method>")`;
/// the emitter resolves those references to the static methods below
/// at codegen time.
///
/// Wire format for messages returned by `consume`:
///   {"id":"...","body":"...","headers":[],"deliveryCount":N}
///   Empty string "" signals a timeout (no message available).
///
/// The in-memory backend tracks unacknowledged messages so consume + ack /
/// nack semantics match RabbitMQ's "one-shot delivery, requeue on nack"
/// behaviour.  Delivery count increments on each consume of a previously
/// nack'd message — useful for poison-message detection in downstream code.

namespace Lyric.Mq

open System
open System.Collections.Concurrent
open System.Threading

/// Single in-flight message.
type private Message =
    { Id:                 string
      Body:               string
      HeadersJson:        string
      mutable DeliveryCount: int }

/// Per-queue state.  `Pending` is the FIFO ready queue; `InFlight` tracks
/// messages currently consumed but not yet ack'd.
type private InMemoryQueue =
    { Name:     string
      Pending:  ConcurrentQueue<Message>
      InFlight: ConcurrentDictionary<string, Message> }

module private Registry =
    let queues : ConcurrentDictionary<int, InMemoryQueue> =
        ConcurrentDictionary<int, InMemoryQueue>()
    let nextHandle : int ref = ref 0

    let register (q: InMemoryQueue) : int =
        let h = Interlocked.Increment(nextHandle)
        queues.[h] <- q
        h

    let lookup (h: int) : Result<InMemoryQueue, string> =
        match queues.TryGetValue(h) with
        | true, q -> Ok q
        | false, _ -> Error (sprintf "unknown queue handle %d" h)

    let safeCall (op: unit -> 'T) : Result<'T, string> =
        try Ok (op())
        with ex -> Error (sprintf "%s: %s" (ex.GetType().Name) ex.Message)

    /// Minimal JSON-string escape (matches the kernel's escape chain).
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

    let renderMessage (m: Message) : string =
        sprintf "{\"id\":%s,\"body\":%s,\"headers\":%s,\"deliveryCount\":%d}"
            (jsonString m.Id) (jsonString m.Body)
            (if String.IsNullOrEmpty(m.HeadersJson) then "[]" else m.HeadersJson)
            m.DeliveryCount

/// `Lyric.Mq.InMemoryHost` — the static class the kernel's
/// `@externTarget("Lyric.Mq.InMemoryHost.<method>")` references resolve
/// to at codegen time.
[<Sealed; AbstractClass>]
type InMemoryHost private () =

    /// Open an in-memory queue identified by `queueName`.  The `url`
    /// parameter is ignored (there's no remote broker to connect to);
    /// it's part of the kernel signature for parity with the RabbitMQ /
    /// SQS shims.
    static member connect(url: string, queueName: string) : Result<int, string> =
        if String.IsNullOrEmpty(queueName) then
            Error "Lyric.Mq.InMemoryHost.connect: queueName must be non-empty"
        else
            Registry.safeCall (fun () ->
                let q = {
                    Name = queueName
                    Pending = ConcurrentQueue<Message>()
                    InFlight = ConcurrentDictionary<string, Message>()
                }
                Registry.register q)

    /// Publish a single message to the queue's FIFO ready queue.
    static member publish(queueId: int, messageId: string, body: string,
                           headersJson: string) : Result<unit, string> =
        if String.IsNullOrEmpty(messageId) then
            Error "Lyric.Mq.InMemoryHost.publish: messageId must be non-empty"
        else
            match Registry.lookup queueId with
            | Error e -> Error e
            | Ok q ->
                Registry.safeCall (fun () ->
                    let m = { Id = messageId; Body = body; HeadersJson = headersJson; DeliveryCount = 0 }
                    q.Pending.Enqueue(m))

    /// Publish multiple messages atomically.  The kernel pre-serialises
    /// the array into JSON; the shim's path-finder splits it into
    /// individual `publish` calls.  Real broker batching (single AMQP
    /// frame, SQS BatchEntryList, etc.) is tracked for the future
    /// driver shims under #779.
    static member publishBatch(queueId: int, messagesJson: string) : Result<unit, string> =
        if String.IsNullOrEmpty(messagesJson) then
            Error "Lyric.Mq.InMemoryHost.publishBatch: messagesJson must be non-empty"
        else
            match Registry.lookup queueId with
            | Error e -> Error e
            | Ok _ ->
                // Phase 5 scope: messagesJson is accepted but the shim is
                // a no-op stub for batch publish — single-message publish
                // already covers the path-finder happy path, and the JSON
                // array splitter would need a real parser.  Returns Err
                // so callers see the gap.
                Error "Lyric.Mq.InMemoryHost.publishBatch: batch publish not yet wired in the in-memory backend (#733 follow-up; use publish() in a loop for now)"

    /// Block for up to `timeoutMs` milliseconds waiting for a message.
    /// Returns an empty string on timeout; the message JSON on success.
    /// Polls the underlying ConcurrentQueue every 25ms to balance
    /// latency against CPU; a future shim should use a proper waiter
    /// (SemaphoreSlim) to avoid polling.
    static member consume(queueId: int, timeoutMs: int) : Result<string, string> =
        if timeoutMs <= 0 then
            Error "Lyric.Mq.InMemoryHost.consume: timeoutMs must be > 0"
        else
            match Registry.lookup queueId with
            | Error e -> Error e
            | Ok q ->
                let sw = System.Diagnostics.Stopwatch.StartNew()
                let mutable result : Message option = None
                while result.IsNone && sw.ElapsedMilliseconds < int64 timeoutMs do
                    let success, msg = q.Pending.TryDequeue()
                    if success then
                        msg.DeliveryCount <- msg.DeliveryCount + 1
                        q.InFlight.[msg.Id] <- msg
                        result <- Some msg
                    else
                        Thread.Sleep(25)
                match result with
                | Some m -> Ok (Registry.renderMessage m)
                | None   -> Ok ""

    /// Acknowledge a message — removes it from the in-flight set.
    /// Idempotent: no error if the deliveryTag is unknown.
    static member ack(queueId: int, deliveryTag: string) : Result<unit, string> =
        if String.IsNullOrEmpty(deliveryTag) then
            Error "Lyric.Mq.InMemoryHost.ack: deliveryTag must be non-empty"
        else
            match Registry.lookup queueId with
            | Error e -> Error e
            | Ok q ->
                q.InFlight.TryRemove(deliveryTag) |> ignore
                Ok ()

    /// Negatively acknowledge: if `requeue` is true, returns the message
    /// to the ready queue.  Otherwise drops it (matches RabbitMQ basic.nack
    /// with `requeue = false`).
    static member nack(queueId: int, deliveryTag: string, requeue: bool) : Result<unit, string> =
        if String.IsNullOrEmpty(deliveryTag) then
            Error "Lyric.Mq.InMemoryHost.nack: deliveryTag must be non-empty"
        else
            match Registry.lookup queueId with
            | Error e -> Error e
            | Ok q ->
                match q.InFlight.TryRemove(deliveryTag) with
                | true, m ->
                    if requeue then q.Pending.Enqueue(m)
                | false, _ -> ()
                Ok ()

    /// Close the queue.  Drops all in-flight + pending messages.
    static member close(queueId: int) : unit =
        Registry.queues.TryRemove(queueId) |> ignore

    // ── Placeholders for the four broker-driver feature arms ───────────────────

    static member rabbitmqConnectNotYet(url: string, queueName: string) : Result<int, string> =
        Error "lyric-mq: RabbitMQ backend not yet implemented (Phase 5 follow-up of #733)"

    static member azureServiceBusConnectNotYet(url: string, queueName: string) : Result<int, string> =
        Error "lyric-mq: Azure Service Bus backend not yet implemented (Phase 5 follow-up of #733)"

    static member sqsConnectNotYet(url: string, queueName: string) : Result<int, string> =
        Error "lyric-mq: AWSSDK.SQS backend not yet implemented (Phase 5 follow-up of #733)"

    static member kafkaConnectNotYet(url: string, queueName: string) : Result<int, string> =
        Error "lyric-mq: Confluent.Kafka backend not yet implemented (Phase 5 follow-up of #733)"
