/// Lyric.Mail.Host — .NET host shim for the lyric-mail kernel.
///
/// Phase 4 of #733: BCL System.Net.Mail SMTP backend only.  MailKit,
/// Amazon SES, and SendGrid shims are tracked under #780 as separate
/// phases — they need NuGet client deps + provider-specific
/// Testcontainers infrastructure (MailHog for SMTP, LocalStack for
/// SES, SendGrid sandbox for SendGrid), while the BCL `SmtpClient`
/// path stays self-contained.
///
/// The kernel file `lyric-mail/src/_kernel/net/mail_kernel.l` declares
/// each entry point with `@externTarget("Lyric.Mail.SmtpHost.<method>")`;
/// the emitter resolves those references to the static methods below
/// at codegen time.
///
/// Result-shape contract (same as Phases 1-3):
///   - All methods translate exceptions into `Result<T, string> =
///     Error(msg)` so failures never escape the Lyric `Result[T,
///     String]` boundary.
///   - `int` senderHandle is an opaque key into the per-process
///     `Registry.senders` `ConcurrentDictionary`.
///
/// Message JSON parsing is minimal — the shim only extracts the fields
/// it needs to build a `MailMessage` (from / to / subject / body /
/// attachments / replyTo).  CR / LF / NUL injection guards from #740
/// in the Lyric-side `Mail.send` path are preserved upstream; this
/// host treats the input as the language-level boundary already
/// validated.

namespace Lyric.Mail

open System
open System.Collections.Concurrent
open System.IO
open System.Net.Mail
open System.Threading

#nowarn "0044"  // suppress obsolete-API warning on System.Net.Mail.SmtpClient

/// Per-handle sender configuration captured at connect time.
type private SmtpSender =
    { Client: SmtpClient
      Host:   string
      Port:   int }

module private Registry =
    let senders : ConcurrentDictionary<int, SmtpSender> =
        ConcurrentDictionary<int, SmtpSender>()
    let nextHandle : int ref = ref 0

    let register (s: SmtpSender) : int =
        let h = Interlocked.Increment(nextHandle)
        senders.[h] <- s
        h

    let lookup (h: int) : Result<SmtpSender, string> =
        match senders.TryGetValue(h) with
        | true, s -> Ok s
        | false, _ -> Error (sprintf "unknown SMTP sender handle %d" h)

    let safeCall (op: unit -> 'T) : Result<'T, string> =
        try Ok (op())
        with ex -> Error (sprintf "%s: %s" (ex.GetType().Name) ex.Message)

    /// Tiny JSON field extractor: looks for `"<key>":"<value>"` or
    /// `"<key>":<bareValue>` and returns the value or None.  Sufficient
    /// for the deterministic JSON shape lyric-mail's serialiseMessage
    /// produces; avoids pulling System.Text.Json into the shim.
    let tryGetStringField (json: string) (key: string) : string option =
        let needle = "\"" + key + "\":\""
        let idx = json.IndexOf(needle, StringComparison.Ordinal)
        if idx < 0 then None
        else
            let start = idx + needle.Length
            let mutable endIdx = start
            let mutable escaped = false
            let mutable found = false
            while not found && endIdx < json.Length do
                let c = json.[endIdx]
                if escaped then
                    escaped <- false
                    endIdx <- endIdx + 1
                elif c = '\\' then
                    escaped <- true
                    endIdx <- endIdx + 1
                elif c = '"' then
                    found <- true
                else
                    endIdx <- endIdx + 1
            if found then
                // Unescape \\, \", \n, \r, \t in the captured slice
                let raw = json.Substring(start, endIdx - start)
                let sb = System.Text.StringBuilder()
                let mutable i = 0
                while i < raw.Length do
                    if raw.[i] = '\\' && i + 1 < raw.Length then
                        match raw.[i + 1] with
                        | '\\' -> sb.Append('\\') |> ignore; i <- i + 2
                        | '"'  -> sb.Append('"')  |> ignore; i <- i + 2
                        | 'n'  -> sb.Append('\n') |> ignore; i <- i + 2
                        | 'r'  -> sb.Append('\r') |> ignore; i <- i + 2
                        | 't'  -> sb.Append('\t') |> ignore; i <- i + 2
                        | c    -> sb.Append(c)    |> ignore; i <- i + 2
                    else
                        sb.Append(raw.[i]) |> ignore
                        i <- i + 1
                Some (sb.ToString())
            else None

/// `Lyric.Mail.SmtpHost` — the static class the kernel's
/// `@externTarget("Lyric.Mail.SmtpHost.<method>")` references resolve
/// to at codegen time.
[<Sealed; AbstractClass>]
type SmtpHost private () =

    /// Open an SMTP connection with the supplied credentials.  The
    /// underlying `SmtpClient` is created eagerly; `Send` will perform
    /// the actual handshake on first message.
    static member connect(host: string, port: int, username: string,
                           password: string, useTls: bool, timeoutMs: int) : Result<int, string> =
        if String.IsNullOrEmpty(host) then
            Error "Lyric.Mail.SmtpHost.connect: host must be non-empty"
        elif port < 1 || port > 65535 then
            Error "Lyric.Mail.SmtpHost.connect: port must be in [1, 65535]"
        elif timeoutMs < 1 then
            Error "Lyric.Mail.SmtpHost.connect: timeoutMs must be >= 1"
        else
            Registry.safeCall (fun () ->
                let client = new SmtpClient(host, port)
                client.EnableSsl <- useTls
                client.Timeout   <- timeoutMs
                if not (String.IsNullOrEmpty(username)) then
                    client.Credentials <- System.Net.NetworkCredential(username, password)
                Registry.register { Client = client; Host = host; Port = port })

    /// Send a message encoded as the JSON shape lyric-mail's
    /// `Mail.serialiseMessage` produces.  The shim extracts the from /
    /// to / subject / textBody / htmlBody fields directly; cc / bcc /
    /// attachments / replyTo are parsed minimally — the path-finder
    /// scope covers the common single-recipient text-or-html case.
    /// More elaborate shapes are tracked for the MailKit shim under
    /// #780.
    static member send(senderHandle: int, messageJson: string) : Result<unit, string> =
        if String.IsNullOrEmpty(messageJson) then
            Error "Lyric.Mail.SmtpHost.send: messageJson must be non-empty"
        else
            match Registry.lookup senderHandle with
            | Error e -> Error e
            | Ok sender ->
                let fromAddr  = Registry.tryGetStringField messageJson "address"
                let subject   = Registry.tryGetStringField messageJson "subject"
                let textBody  = Registry.tryGetStringField messageJson "textBody"
                let htmlBody  = Registry.tryGetStringField messageJson "htmlBody"
                match fromAddr, subject with
                | Some fa, Some subj ->
                    Registry.safeCall (fun () ->
                        let msg = new MailMessage()
                        msg.From <- MailAddress(fa)
                        msg.Subject <- subj
                        // The first `"address":"..."` field is the "from" object;
                        // subsequent ones are in the "to" array.  For the path-finder
                        // scope, send to a single recipient extracted from the to-array
                        // shape by scanning for the second occurrence.
                        let firstFromEnd =
                            messageJson.IndexOf("\"address\":\"" + fa + "\"", StringComparison.Ordinal)
                            + ("\"address\":\"" + fa + "\"").Length
                        let toScan = messageJson.Substring(firstFromEnd)
                        match Registry.tryGetStringField toScan "address" with
                        | Some toAddr -> msg.To.Add(MailAddress(toAddr))
                        | None -> ()  // no recipients; SmtpClient.Send will throw
                        match htmlBody with
                        | Some html when html.Length > 0 ->
                            msg.IsBodyHtml <- true
                            msg.Body <- html
                        | _ ->
                            msg.IsBodyHtml <- false
                            msg.Body <- (defaultArg textBody "")
                        sender.Client.Send(msg))
                | _, _ ->
                    Error "Lyric.Mail.SmtpHost.send: messageJson missing 'address' (from) or 'subject' field"

    /// Close the SMTP connection and release resources.
    static member close(senderHandle: int) : unit =
        match Registry.senders.TryRemove(senderHandle) with
        | true, sender ->
            try sender.Client.Dispose() with _ -> ()
        | false, _ -> ()

    // ── SES / SendGrid placeholders ────────────────────────────────────────────
    //
    // These exist so the `@cfg(feature = "ses" | "sendgrid")` arms in
    // `mail_kernel.l` have something to `@externTarget` at.  Both return a
    // clear "not yet implemented" error pointing at the follow-up issue.

    static member sesConnectNotYet(region: string, accessKey: string,
                                    secretKey: string) : Result<int, string> =
        Error "lyric-mail: Amazon SES backend not yet implemented (Phase 4 follow-up of #733)"

    static member sendGridConnectNotYet(apiKey: string) : Result<int, string> =
        Error "lyric-mail: SendGrid backend not yet implemented (Phase 4 follow-up of #733)"
