# lyric-mail: STARTTLS round trip in CI (#8573)

`scripts/ci/smtp_capture_server.py` gains `--tls CERT KEY`: it advertises
STARTTLS, upgrades the session with the given PEM pair, refuses `AUTH` and
`MAIL` until the client has done so (RFC 3207 section 4) and records
`tls=yes|no` in each envelope. `scripts/ci/smtp-roundtrip-e2e.sh` makes a
one-day certificate for `127.0.0.1` per run and, on dotnet and the JVM:

- sends the round-trip messages with `LYRIC_CONFIG_SMTP_USETLS=true` to the TLS
  server, checks them with `smtp_verify.py`, and requires `tls=yes` on every
  envelope;
- requires the same send to fail, delivering nothing, against a server that
  offers no STARTTLS ("Server does not support secure connections" on dotnet)
  and against the TLS server when the client does not trust its certificate
  (`UntrustedRoot` on dotnet, a certificate alert from Jakarta Mail).

Only the test process trusts the certificate: `SSL_CERT_FILE` for .NET's
OpenSSL store, a PKCS12 trust store appended to `JAVA_TOOL_OPTIONS` for the
JVM. lyric-mail's trust and identity settings are unchanged. Verified locally
with `smtp-roundtrip-e2e.sh dotnet jvm`.
