# D610 - A `Std.Tls.Certificate` carries every certificate of its PEM text (#9146)

**Status:** shipped.

## Context

`Certificate.fromPem` and `Certificate.fromPemFile` accepted a PEM text with
several certificates, a CA bundle (`ca-bundle.crt`, the file `SSL_CERT_FILE`
names) being the usual shape. What happened to the rest depended on the
target. On dotnet `X509CertificateLoader.LoadCertificate` returns the first
certificate of the text; on the JVM `CertificateFactory.generateCertificate`
reads one. Both dropped the others without a diagnostic, so a server signed by
the second CA of a bundle failed with a certificate error, and the cause was
invisible. On native the text itself is handed to OpenSSL, which loads all of
it, so every certificate was trusted. The same program behaved differently on
the three targets, and the native behaviour is the one users expect of a CA
bundle.

## Decision

1. **A `Certificate` carries every `CERTIFICATE` block of the text, in order.**
   The opaque type holds a non-empty list of host handles instead of one.
   Every certificate is a trust anchor wherever a `Certificate` is used as a
   CA: `HttpClientBuilder.withCaCertificate` (additive) and
   `withExclusiveCaCertificate`, and `TlsServerConfig.clientCa` (the dotnet and
   native transports and the JVM `serverSslContextFromConfigMtls`). The
   behaviour is the same on dotnet, the JVM and native.
2. **The text is split once, in `Std.Tls`, not in each kernel.** `certificateBlocks`
   finds the `-----BEGIN CERTIFICATE-----` / `-----END CERTIFICATE-----`
   blocks; everything outside them (comments, blank lines, blocks with another
   label such as a private key) is skipped, as OpenSSL skips it. Each block
   goes through the existing per-target kernel function `hostCertFromPemBytes`
   unchanged, so the kernels' parsers, error messages and the native `CertHandle`
   (the PEM text) did not change. A consumer that needs every anchor loops over
   `Certificate.rawHandles` (dotnet `X509Certificate2Collection.Add` /
   JVM `KeyStore.setCertificateEntry` under an indexed alias / native: the
   handles' PEM texts concatenated, `TlsHost.hostCertsPem`).
3. **A malformed certificate is an error wherever it is.** A block that does
   not parse, or has no END line, is `PemMalformed`, and the message gives its
   position ("certificate 2 of 3: ..."); the other certificates are not used
   either. Silently dropping one would reproduce the bug in a different shape:
   a trust list missing an anchor with no sign of it.
4. **Unchanged cases.** A text with no `CERTIFICATE` block is passed to the
   kernel as given, so it fails with the kernel's own `PemMalformed` as before,
   and so does DER input (`fromPemFile` of a DER file works on dotnet and the
   JVM as it did). A text with exactly one block is also passed to the kernel
   as given, byte for byte. The empty string is `PemMalformed`, as before.
5. **`Identity` is not changed, and the two are told apart by their type.**
   An `Identity` is a leaf certificate with its private key; the first
   `CERTIFICATE` block of its text is the leaf the key must match, and further
   blocks (the intermediates of a chain file) are ignored on every target: the
   dotnet `CreateFromPemFile`, the JVM `CertificateFactory` and the native
   validation all read the first certificate, and the peer is sent the leaf
   alone. A chain is a different thing from a bundle (an ordered path to one
   anchor, against an unordered set of anchors), and which one a text is
   follows from the API it is given to, not from the text. Sending the
   intermediates is not part of this decision.
6. **No public API was added.** `Certificate.rawHandle` (internal) became
   `Certificate.rawHandles`, which also removes the native bridge's
   `rawHandle/1` name clash with `Identity.rawHandle`.

## Consequences

A program that passed a multi-certificate file to `withExclusiveCaCertificate`
on dotnet or the JVM and worked because the first certificate was the only one
needed keeps working; one that worked because the extra certificates were
ignored cannot exist, since they could only add trust. A bundle that contains a
malformed certificate, which dotnet and the JVM used to accept if it was not
first, is now `PemMalformed`. `tls_tests.l` runs on all three
targets.

`lyric-ecosystem`'s `storage-s3` and `mq-sqs` tests asserted the old per-target
behaviour; they become one assertion.
