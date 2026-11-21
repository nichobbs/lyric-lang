# TIR builder: a bare name of a payload-bearing case (D685)

`case Err -> ...` (a case name with no payload pattern, which matches the case whatever its payload) builds as the case with a wildcard per payload field instead of an unbuilt body, so `lyric prove` reaches the verifier on `examples/prove-unmodelled-match/bare_err.l` as before. Shapes e2e: `bare_payload_case`.
