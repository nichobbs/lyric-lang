# D223 - Extern package members are registered with the type checker

**Status:** accepted, implemented (#7934; extends #7921)

## Context

#7921 gave `extern func` and `@externTarget` functions a signature, so a call to one is checked. The third form, a
function member of an `extern package <path> { ... }` block, still had none: `registerItem` only indexed its name for
the unknown-name check (#6361), so a call found no signature, typed as `TyError`, and nothing about its arguments or
result was checked on any target.

## Decision

1. **Each function member is a symbol and a signature.** The member is registered as a body-less function whose
   `originPackage` is the block's own path, the spelling callers use (`lyric.db.Postgres.connect(...)`). Its types
   resolve in the enclosing package's scope, since the enclosing file's imports name them. Calls use the ordinary
   `T0042`/`T0043` checks; no new code is needed, and the signature is not marked `isExternFunc` (that mode is the
   native C-ABI adaptation).
2. **A member is also addressed through the enclosing package.** `Grpc.Kernel.Jvm.netOpenChannel(a)` names a member of
   a block in package `Grpc.Kernel.Jvm`. The member is registered under the enclosing package too, unless that package
   declares a function of the same name and arity itself (lyric-db's kernel wraps `lyric.db.JdbcConnections.query`
   in a package-level `query`); the package's own function is then what the package's name means, and the block's
   path stays the only way to the member.
3. **The block's path is not importable.** It is a host binding, so a qualified call through it is exempt from the
   import-reachability check (T0020), and the receiver chain `lyric.db.Postgres` is not inferred as a value.

## Audit

The only callers of extern-package members are `lyric-grpc/src/grpc.l` into `Grpc.Kernel.Jvm`, and they type-check
against the declared signatures. The `lyric-aws-xray` kernels declare blocks nothing calls (the library moved to
`import extern`), and the stdlib no longer has `extern package` blocks. `lyric-db/src/_kernel/jvm/db_kernel.l` does
not parse (nested `pub package` blocks) and is not in the manifest, as `lyric-db/README.md` records; it is left as
the documented vaporware it is.
