# `Std.Tls.Certificate` trusts every certificate of a PEM bundle on every target (#9146, D610)

`Certificate.fromPem`/`fromPemFile` given a PEM text with several certificates
used only the first on dotnet (`X509CertificateLoader.LoadCertificate` returns
one) and the JVM (`CertificateFactory.generateCertificate` reads one), and
dropped the rest without a diagnostic; native handed the text to OpenSSL and
trusted all of it. A `Certificate` now carries every `CERTIFICATE` block of its
text (`Std.Tls` splits the text and loads each block through the unchanged
kernel `hostCertFromPemBytes`), and every consumer adds all of them as trust
anchors: the dotnet client chain (`_kernel/http_host.l`) and server `clientCa`
(`_kernel/tcp_host.l`), the JVM client `KeyStore`s (`_kernel_jvm/http_host.l`)
and the mTLS server `KeyStore` (`_kernel_jvm/http_server.l`), and the native
client and server contexts (`TlsHost.hostCertsPem` over the handles). Text
outside the blocks is skipped; a malformed or unterminated block anywhere is
`PemMalformed` naming its position; no block, one block and DER input behave as
before. `Identity` is unchanged: its first block is the leaf. See D610.

Verified with `lyric-stdlib/tests/tls_tests.l` (the 15 added cases, dotnet, JVM
and native): a real `Std.HttpServer.startListenerTls` listener whose
certificate is signed by the second CA of a two-CA bundle is trusted through
`withExclusiveCaCertificate` and `withCaCertificate`, in either bundle order
and from a file, and rejected when only the first CA is trusted; a client
certificate signed by the second CA of a `clientCa` bundle is accepted
(dotnet, native; the JVM `HttpsServer` listener does not support mTLS, #5930);
malformed, unterminated and certificate-less texts are `PemMalformed`. Before
the change 8 of the 15 failed on dotnet and 7 of the 13 cases it then had on
the JVM; on native the trust cases already passed and the
malformed-second-certificate case failed.
