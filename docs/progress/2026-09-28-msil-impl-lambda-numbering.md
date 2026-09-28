# MSIL lambda numbering agrees across impl blocks and other items (#7693)

On `--target dotnet`, a file failed to build with

    error[T0115]: cannot resolve name '<captured-name>' to a value here
    (in <pkg>.__lambda_<n>)

when a top-level `impl <Iface> for <Record>` method held a capturing closure
and another item declared before it (for example a record method) held one
too. The captures did not need to be `var`s or share names.

## Root cause

`liftLambdasMsil` numbers every lambda `__lambda_<i>` in file-declaration
order: each top-level item's direct lambdas, then the nested lambdas
breadth-first. `codegenMPackage` numbered them again with one running
counter, `cctx.lambdaTicker`, as it lowered each `ELambda`. It does not lower
items in file order, though. `collectImplEntriesMsil` lowers every `impl`
block's methods before the main per-item loop starts. The impl method's
lambda therefore took the index the lift had given the first earlier item's
lambda, and every `ELambda` site after it was bound to another lambda's
lifted body and capture list.

The same walk also skipped default interface method bodies (`IMFunc` in an
`interface`), so a lambda inside one had no lifted token at all.

## Fix

In `lyric-compiler/msil/codegen.l`:

- The lift's per-item walk is now its own function,
  `collectItemLambdasBfsMsil`, used by `liftLambdasMsil`.
- `computeLambdaBasesMsil` replays that walk over the lifted file and records
  each item's starting lambda index. The lifted `__lambda_<i>` items come
  last, in deferred order, and their bodies are the deferred blocks, so the
  replay also reproduces the nested-lambda numbering.
- `alignLambdaTickerMsil` moves `cctx.lambdaTicker` to an item's starting
  index. It runs before each impl block in `collectImplEntriesMsil` and
  before each item in `codegenMPackage`'s main loop. Items lowered in file
  order are already in step, so for them it does nothing.
- `collectItemLambdasBfsMsil` now also walks default interface method bodies,
  in the member order that the `IInterface` arm of `codegenMPackage` lowers
  them in.

The JVM backend needed no change. It names each `<pkg>$Lambda$<n>` class
where it lowers the `ELambda` and has no separate lifting pass, so its two
numberings cannot drift apart.

## Tests

`impl_method_closure_var_capture_self_test.l` was kept separate only
because of this bug. It is now merged back into
`method_closure_var_capture_self_test.l` (11 cases, dotnet and JVM). The
record-method closures come first in that file, followed by the impl blocks
and a default interface method, so the file reproduces the original failure.
New cases:

- A record-method closure and an impl-method closure capturing plain `val`s
  under different names, including a closure nested inside the impl-method
  closure.
- Record-method and impl-method closures called through the interface in
  one test.
- A default interface method whose closure captures a local `val`.

The deleted file's entries were removed from `compiler-self-tests-batch.sh`
and `jvm-generics-self-tests-batch.sh`.
