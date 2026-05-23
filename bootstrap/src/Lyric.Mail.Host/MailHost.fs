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
/// Result-shape contract:
///   - All methods translate exceptions into `Result<T, string> =
///     Error(msg)` so failures never escape the Lyric `Result[T,
///     String]` boundary.
///   - `int` senderHandle is an opaque key into the per-process
///     `Registry.senders` `ConcurrentDictionary`.
///
/// The Lyric public layer performs all JSON serialization and field
/// validation before the extern call; this host receives typed native
/// parameters and calls BCL APIs directly — no JSON parsing required.

namespace Lyric.Mail

open System
open System.Collections.Concurrent
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

    /// Send an email with typed native parameters.  The Lyric public layer
    /// assembles these from an `EmailMessage` record; no JSON parsing
    /// is required here.  cc/bcc/attachments/replyTo are handled by the
    /// MailKit shim when it lands (#780).
    static member smtpSend(handle: int, fromAddress: string, toAddresses: string[],
                            subject: string, bodyText: string, bodyHtml: string) : Result<unit, string> =
        if String.IsNullOrEmpty(fromAddress) then
            Error "Lyric.Mail.SmtpHost.smtpSend: fromAddress must be non-empty"
        elif toAddresses.Length = 0 then
            Error "Lyric.Mail.SmtpHost.smtpSend: toAddresses must be non-empty"
        elif String.IsNullOrEmpty(subject) then
            Error "Lyric.Mail.SmtpHost.smtpSend: subject must be non-empty"
        else
            match Registry.lookup handle with
            | Error e -> Error e
            | Ok sender ->
                Registry.safeCall (fun () ->
                    let msg = new MailMessage()
                    msg.From    <- MailAddress(fromAddress)
                    msg.Subject <- subject
                    for addr in toAddresses do
                        if not (String.IsNullOrEmpty(addr)) then
                            msg.To.Add(MailAddress(addr))
                    if not (String.IsNullOrEmpty(bodyHtml)) then
                        msg.IsBodyHtml <- true
                        msg.Body       <- bodyHtml
                    else
                        msg.IsBodyHtml <- false
                        msg.Body       <- bodyText
                    sender.Client.Send(msg))

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
