# TIR builder: a host call may leave out trailing parameters the host defaults (D770)

`JsonEncodedText.Encode("hi")`, `JsonDocument.Parse(s)` and `File.OpenHandle(path)` build: the metadata resolver reports overloads whose trailing parameters all have a default, the node's `HostMemberRef.omitted` records how many the call leaves out, and the verifier checks the arguments are the rest. Interface format 6. Self-tests: `tir_build_self_test.l`, `tir_verify_self_test.l`.
