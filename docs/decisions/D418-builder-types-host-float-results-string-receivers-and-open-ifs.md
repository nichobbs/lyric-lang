# D418 - The builder types a host `float` result, a member call on a language `String`, and an `if`/`else` of untyped host calls (docs/70 phase 3a, #8613)

**Status:** shipped; extends D416 and D444. The checker is unchanged: docs/01 section 2.11 still leaves a host result unchecked.

## Context

The JVM wide census (21 ecosystem libraries built and tested on `--target jvm` with the typed-IR census on, 0 I0003) left four host-shaped bodies the checker leaves untyped.

- `Db.Kernel.Jvm::serializeValue` reads `rs.getFloat(i).toString()`. The checker types `getDouble` but not `getFloat`, and the builder refused a host `float` result because the host's single and double classes are ones the checker maps to Lyric types.
- `Mail.Kernel.Jvm::attachmentPart` calls `encoded.getBytes("US-ASCII")` on a language `String`. `hostChainReceiver` took only a host class as the receiver.
- `Mail.Kernel.Jvm::deliver` runs `if secure { transport.connect(host, port, user, pw) } else { transport.connect() }` as a statement. The checker types neither branch, so it gives the `if` no type.
- `Std.FormatHost::hostDoubleToString` and `Storage.Kernel.Jvm::listChildren` bind an untyped host result to a local that they index or count.

## Decision

- `hostChainResult` types a host `float` result as `Float` and a host `double` result as `Double`; the call node converts the host's result with `CvFromHost`, as it does where the checker types the call (D359).
- `hostChainReceiver` takes a language `String` as the receiver of a member the checker has no case for, as the host string class under the name the active target's metadata knows (`hostStringReceiver`: the JVM resolver reads JDK classes, the dotnet one reference assemblies).
- `openHoleTy` types an `if`/`else` the checker left open as the type its two branches agree on (`openIfTy`), each branch's tail taken from the checker's type or the builder's host chain typing.
- The kernels declare the host results they bind (docs/01 section 2.11, D436, D416): `Std.FormatHost` (`val s: String = scaled.toPlainString()`) and `Storage.Kernel.Jvm::listChildren` (`val children: slice[JFile] = d.listFiles()`, read with `.length`).

## Results

`Db.Kernel.Jvm`, `Mail.Kernel.Jvm`, `Std.FormatHost` and `Storage.Kernel.Jvm` build every body with 0 I0003. The 21 ecosystem libraries' JVM suites pass (storage 36, db 23 and 12, mail 82), and `format_tests.l` passes on the JVM. `tir-builder-shapes-e2e.sh` gains `floatText`, `stringByteCount` and `joinEither` in `jvm_host_overload_shapes` (built and run).

## Not covered

The remaining unbuilt JVM bodies belong to other kinds, not host results: `list.toArray().count` chains in `lyric-generator-sdk`'s tests, the weaver's synthesized B-mode specialisations in `lyric-resilience`'s tests, the "checker recorded no type" bodies of `lyric-docker` and `lyric-grpc`, and `Std.Iter::find`.
