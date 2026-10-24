# lyric-mail SES and SendGrid over HTTPS; lyric-web static files no longer follow symlinks out of root (#7462, #7249)

**lyric-mail (#7462, partial).** `connectSes()` and `connectSendGrid()` used to
validate their config and then return `NOT_IMPLEMENTED` on every target. Both
providers are HTTPS APIs, so they are now implemented once in `Mail` over
`Std.Http` and behave the same on `dotnet` and `jvm`, with no provider SDK (the
`[nuget]` entries for `AWSSDK.SimpleEmail` and `SendGrid` are gone):

- SendGrid: `POST /v3/mail/send` with a bearer key; `bcc` travels in the
  personalization, the text part precedes the HTML part, attachments are passed
  through as base64.
- SES: SES v2 `SendEmail` signed with AWS Signature V4 (`host`, `x-amz-date` and
  an optional `x-amz-security-token` are signed). `Simple` content when there
  are no attachments, `Raw` MIME otherwise (multipart/mixed, base64 wrapped at
  76 columns, RFC 2047 encoded words for non-ASCII subject and names).
- Config: `LYRIC_CONFIG_SES_{REGION,ACCESSKEY,SECRETKEY,SESSIONTOKEN,ENDPOINT}`,
  `LYRIC_CONFIG_SENDGRIDMAIL_{APIKEY,ENDPOINT}`; a region may only contain
  lowercase letters, digits and `-`, and an endpoint override must be an
  absolute `http(s)` URL.
- A provider rejection returns `Err` with the status and the start of the body,
  `code` `AUTH_FAILED`, `QUOTA_EXCEEDED`, `PROVIDER_ERROR` or `SEND_ERROR`.
- Tests pin the exact request bodies, the MIME layout and the SigV4 signature
  (against the published AWS `get-vanilla` test vector), and drive both senders
  at a closed port. Neither provider has been driven against the live service
  in CI.

SMTP on the JVM (Jakarta Mail) is still `NOT_IMPLEMENTED`; #7462 stays open for
it.

**lyric-web (#7249).** `withinRoot` used `Path.GetFullPath` on `dotnet`, which is
lexical, so a symlink inside a static root could point outside it and still be
served (the JVM resolved links through `getCanonicalPath`). `dotnet` now walks
the path one segment at a time and replaces each symlink by its target, like
`realpath(3)`; a link loop yields an empty path that is within no root.
`dispatch_tests.l` covers a file symlink and a directory symlink pointing out of
root.

The symlink check is resolve-then-open: the path is resolved and compared with
the root, and the file is opened afterwards, so a link swapped between the two
steps by someone who can write to the static root can still win the race. The
static root must not be writable by untrusted parties; the check defends
against links that already exist.

Provider endpoint overrides must use `https://`; plain `http://` is accepted
only for `localhost`, `127.0.0.1` and `[::1]` so credentials never travel in
clear text.
