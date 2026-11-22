# A static member read through the extern type name of a host class that has a Lyric type (docs/70 phase 3a, #8613)

**Status:** shipped; builder only.

## Context

`extern type ByteT = "System.Byte"` names a host class the checker has a Lyric type for (`Byte`), so it types the path `ByteT` as that primitive. `ByteT.MaxValue` (`auto_ffi_self_test`, #7889) is a static constant of the host class, which the checker has no case for and leaves untyped (docs/01 section 2.11); the builder types such a read from the host metadata (D444) through `hostChainReceiver`, but that function took a receiver typed as a primitive for a value and never looked the extern type name up. Types with no Lyric counterpart (`SByteT`, `UInt16T`) and `Int32T` (whose `MaxValue` the checker types itself) were unaffected, so only `Byte`'s constants stopped the gate.

## Decision

`hostChainReceiver` falls back to `hostStaticReceiver` when the receiver the checker typed is neither a host class nor a string: a bare name of a non-generic `extern type` that no local shadows is the host class itself, as it is where the checker recorded no type. A value of a primitive type is unaffected, `hostStaticReceiver` names only a type.

## Consequences

`auto_ffi_self_test` body 23 (`ByteT.MaxValue`) builds. Test: `tir_build_self_test.l`.
