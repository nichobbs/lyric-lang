# 2026-11-13 - TIR: host supertype and byte array arguments (D599)

A host value passed as one of its supertypes (read from the host metadata) and a `slice[Byte]` or `array[N, Byte]` passed
for a host array parameter are `CvBoxToHost` arguments; the supertype case ranks as a widening in the overload score, the
array case with boxing. Tests: `tir_build_self_test.l` (`File.WriteAllBytes`, `HttpClient.new(HttpClientHandler)`, the
`hostBoxKind` table).
