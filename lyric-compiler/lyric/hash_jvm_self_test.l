//! lyric-compiler/lyric/hash_jvm_self_test.l
//!
//! @test_module proving the target-aware kernel source loader (J6 M-10)
//! actually loads `lyric-stdlib/std/_kernel_jvm/hash_host.l` on a JVM
//! build, and that the JVM SHA-512 host (M-9) produces correct digests.
//!
//! Importing `Std.Hash` pulls in `Std.HashHost`.  On `.NET` that resolves
//! to `_kernel/hash_host.l` (System.Security.Cryptography.SHA512); on JVM
//! the loader prefers `_kernel_jvm/hash_host.l`
//! (java.security.MessageDigest via auto-FFI) — the file under test.  The
//! test asserts the canonical NIST SHA-512 vectors, so a wrong / missing
//! JVM host fails the run instead of silently linking the .NET externs.
//!
//! Input bytes come from `String.getBytes()` (a real JDK `byte[]`); the
//! self-hosted JVM backend boxes that primitive array into the erased
//! `slice[Byte]` representation at the call boundary, and the kernel host
//! unboxes it back to a `byte[]` for `MessageDigest.digest`.
//!
//! Run via `lyric test --target jvm` so the self-hosted Jvm.Bridge
//! pipeline (compileToJarBundled) loads the JVM kernel and runs under
//! `java`.
//!
//! Manual run (from repo root, after `make lyric`):
//!   ./bin/lyric test --target jvm \
//!     lyric-compiler/lyric/hash_jvm_self_test.l
@test_module
package Lyric.HashJvmSelfTest

import Std.Core
import Std.Testing
import Std.Hash

// SHA-512("abc") — NIST FIPS 180-4 worked example, uppercase hex.
test "sha512OfBytes of \"abc\" matches the NIST vector" {
  val digest = sha512OfBytes("abc".getBytes())
  assertEqual(
    digest,
    "DDAF35A193617ABACC417349AE20413112E6FA4E89A97EA20A9EEEE64B55D39A2192992A274FC1A836BA3C23A3FEEBBD454D4423643CE80E2A9AC94FA54CA49F",
    "SHA-512(\"abc\")"
  )
}

// SHA-512("") — the empty-input digest, uppercase hex.
test "sha512OfBytes of empty input matches the known digest" {
  val digest = sha512OfBytes("".getBytes())
  assertEqual(
    digest,
    "CF83E1357EEFB8BDF1542850D66D8007D620E4050B5715DC83F4A921D36CE9CE47D0D13C5D85F2B0FF8318D2877EEC2F63B931BD47417A81A538327AF927DA3E",
    "SHA-512(\"\")"
  )
}

// A third independent vector ("hello") guards against accidental constant
// folding and confirms the JVM SHA-512 host is exercised per call.
test "sha512OfBytes of \"hello\" matches the known digest" {
  val digest = sha512OfBytes("hello".getBytes())
  assertEqual(
    digest,
    "9B71D224BD62F3785D96D46AD3EA3D73319BFBC2890CAADAE2DFF72519673CA72323C3D99BA5C11D7C7ACC6E14B8C5DA0C4663475C2E5C3ADEF46F73BCDEC043",
    "SHA-512(\"hello\")"
  )
}
