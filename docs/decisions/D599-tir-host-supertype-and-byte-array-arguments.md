# D599 - A host call's arguments pass a host subtype as its supertype and a Byte slice as a host array (docs/70 phase 3a, #8613)

**Status:** shipped; extends D597.

## Context

After D597 the compiler census still counted "an extern call no host overload fits" for `HttpClient.new(handler)` (an
`HttpClientHandler` or `SocketsHttpHandler` for an `HttpMessageHandler` parameter), `Stream.CopyToAsync(memoryStream)`,
and the calls that pass a `slice[Byte]` for a host `byte[]` (`File.WriteAllBytes`, `SHA256.HashData`,
`Convert.ToHexString`, `ByteArrayContent.new`, `X509CertificateLoader.LoadCertificate`).

## Decision

- A host value passed for a parameter of one of its host supertypes is `CvBoxToHost(supertype)`, found with the resolver's
  `resolveBases` (the same question the checker asks for extern assignability, #8787). It ranks as a widening
  (score 1 per argument), above boxing to `object` and narrowing (score 0); `object` is boxing, not an upcast.
- A `slice[Byte]` or `array[N, Byte]` passed for the host's array parameter (the metadata names every array parameter
  "an array, pointer or by-reference type" without its element type) is `CvBoxToHost` of that placeholder, ranked with
  boxing. A slice of any other element type is not accepted, since the placeholder cannot tell `byte[]` from `int[]`;
  two array overloads that both accept a `Byte` slice tie and are counted as ambiguous.
- `CvBoxToHost` therefore means "a value passed as a host type" for all of these; the operand keeps its own type and the
  node has the host type. The verifier's rule is unchanged.

Limit: the same placeholder names a by-reference or pointer parameter (`byte&`, `byte*`), so a `Byte` slice can fit such an overload until the metadata distinguishes them; the overload score cannot rank them apart from a real `byte[]`. Carrying the element type in the placeholder is the follow-up.
