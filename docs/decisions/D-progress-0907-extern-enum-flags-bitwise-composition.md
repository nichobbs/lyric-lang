# D-progress-907 — Verify and regression-test bitwise composition of extern `[Flags]` enums

**Status:** shipped

**Context.** A question was raised about whether Lyric can pass a .NET
enum parameter through an `extern type` boundary at all — specifically
`X509Chain`/`X509KeyStorageFlags`, the BCL types needed to verify a
certificate chain against a pinned CA and, separately, to load a
PKCS#12/PFX identity via `X509CertificateLoader.LoadPkcs12`. Reading the
code (not just docs) found the premise only half held:

- A **single-valued** extern enum member (`X509ChainTrustMode.CustomRootTrust`,
  `X509RevocationMode.NoCheck`) already round-trips correctly and is used in
  production today: `lyric-stdlib/std/_kernel/http_host.l` builds a real
  pinned-CA `X509Chain` this way. More generally, *any* extern enum's named
  member resolves directly via the auto-FFI static-member-read path
  (`Mdr.isEnumType` + Constant-table decode, docs/42 §5's 2026-07 status
  update) with no `@externTarget` wrapper needed — it types as the enum's
  own `MValueTypeRef`, not a bare `Int`.
- What genuinely had no path was **composing** a `[Flags]` enum
  (`X509KeyStorageFlags.EphemeralKeySet | X509KeyStorageFlags.Exportable`) —
  needed for `LoadPkcs12`'s `keyStorageFlags` parameter, and the concrete
  reason `lyric-stdlib/std/_kernel/tls_host.l` avoids PKCS#12 entirely today
  (docs/61 Q-TLS-006).

**Investigation.** Lyric's bitwise methods (`.and`/`.or`/`.xor`/`.shl`/
`.shr`, `#1610`, `bitwise_self_test.l`) are documented as covering only
`Int`/`Long`(/`Byte`); it looked plausible that they would need to be
taught about extern enum receivers specifically — a `Msil.Codegen` change.
Reading `lowerMethodCallMsil` (`lyric-compiler/msil/codegen.l`) found this
assumption wrong: the `"and"`/`"or"`/`"xor"`/`"shl"`/`"shr"` arm is reached
purely by member-name string match with **no receiver-type gate at all**,
pushes the argument, emits the bare CIL `and`/`or`/`xor`/`shl`/`shr`
opcode, and returns `recvTy` (the receiver's own type) unchanged. Two
things make this already correct for an extern enum receiver with zero
code changes:

1. CIL's `and`/`or`/`xor`/`shl`/`shr` operate on whatever integral value is
   already on the evaluation stack — an enum value *is* its underlying
   integer there; there is no separate "enum" runtime representation to
   special-case.
2. A `MValueTypeRef` receiver (what an extern enum constant already types
   as) first probes real-CLR-instance-method auto-FFI dispatch
   (`tryInstanceAutoFfiFromMetadata`, Phase 3c step 4b, docs/42) for a
   member literally named `and`/`or`/etc. An enum has no such instance
   method, so the probe misses; codegen already handles a miss by dropping
   the spilled receiver's address and reloading its *value* rather than
   erroring (comment at `codegen.l`'s `MValueTypeRef` arm: "an
   extern-struct-typed value can flow through ordinary declared Lyric
   code, so a miss is not necessarily an error") — falling through cleanly
   into the generic bitwise arm above, exactly as it does for `Int`/`Long`.

So the capability was already shipped as an emergent consequence of two
independently-motivated design choices (name-only bitwise dispatch, and
graceful instance-auto-FFI-miss fallthrough) — it had simply never been
exercised or asserted for a real BCL `[Flags]` enum.

**What shipped.** `lyric-compiler/lyric/extern_enum_flags_self_test.l`: a
`@test_module` proving this end-to-end against a real BCL `[Flags]` enum
(`System.Security.Cryptography.X509Certificates.X509KeyStorageFlags`),
declared via a bare `extern type` with no `@externTarget` wrapper —
single-constant reads, `.or` composing two flags, `.or` chained across
three flags, `.and` isolating a set/unset bit, and `.xor` toggling a bit —
each verified numerically via `System.Convert.ToInt32(object)` as the
oracle (an enum value boxes into `object` like any other value type,
docs/59 §6's boxing fix; Lyric has no direct enum→`Int` cast, so boxing
through the one BCL overload that accepts any value type is the read-back
mechanism). Wired into CI (`.github/workflows/ci.yml`'s `dotnet-a batch 7`
group, alongside `auto_ffi_self_test.l`) and into the `Makefile`'s
`TEST_EMITTER_FILES` fast-loop list. `.NET`-only by construction, not
policy: `[Flags]` enums are a C#/BCL idiom with no JVM equivalent (the
JDK's analogous flag-shaped constants are plain `int`s, which already pass
through as `Int` with no special handling needed), so there is nothing to
port for JVM parity.

**What's NOT done.** This is a compiler-capability verification and
regression test only. It does not wire PKCS#12 loading into `Std.Tls` —
`docs/61` Q-TLS-006 (whether `Std.Tls` should gain a PKCS#12 import path at
all) stays open; what this closes is only the belief that the compiler
couldn't express the parameter such a feature would need. See
`docs/42-extern-metadata-resolution.md` §5's 2026-09 status update and
`docs/61-https-tls-http-versions.md` Q-TLS-006 for the cross-references.
