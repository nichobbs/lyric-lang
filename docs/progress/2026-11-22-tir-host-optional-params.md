# Optional trailing host parameters (D762)

A host call may leave out the optional trailing parameters the metadata declares: `ExternMemberSig.optionalTrailing`, `HostMemberRef.omitted`, a verifier rule and interface format 6. `auto_ffi_self_test.l` bodies `JsonEncodedText.Encode`, `JsonDocument.Parse` and `File.OpenHandle` build.
