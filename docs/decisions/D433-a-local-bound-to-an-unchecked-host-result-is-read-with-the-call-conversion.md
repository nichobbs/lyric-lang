# D433 - A local bound to an unchecked host result is read with the conversion the call would have (docs/70 phase 3a, #8613)

**Status:** shipped; extends D359 and D445. The checker is unchanged and the language is unchanged.

## Context

docs/01 section 2.11 leaves a host result unchecked. In `val v = m.computeIfAbsent("key", { k: String -> prefix + k })` on a raw `java.util.HashMap`, the checker types the call as the host's `Object`, binds `v` at that type, and then types each read of `v` at the type its context wants (`String` for `assertEqual(v, "v:key")`, or a `String` return). The builder declared the local at the call's type, `extern java.lang.Object`, and built the read at the checker's `String`, so `Lyric.Tir.Verify` reported I0003 `local-type` (`lyric-compiler/jvm/sam_detection_self_test.l`, `testSamBridgedFunction`).

## Decision

A read of a local whose declared type is a host result type the checker maps to the type read (`hostResultIsCallType(declared, read)`) builds as `CvFromHost` over the local, the conversion the call itself takes where the checker types it. The local keeps the host's type, so the declaration and every read agree.

## Results

`sam_detection_self_test.l` builds with 0 I0003 (it was 1), and `tir-builder-shapes-e2e.sh` gains `jvm_host_local_read` (built with `--target jvm --verify-ir`).
