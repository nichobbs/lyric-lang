# D-progress-961 — MSIL slice element access and copies take a typed fast path (#7259)

**Status:** shipped

## Problem

On MSIL a `slice[T]` value is one of two runtime representations behind the
single static type `MArray(T)`: a genuine CLI `T[]` (slice literals in a
slice context, `.slice`/`.concat`/`.append` results, `List.toArray()`, BCL
arrays) or a `List`-backed slice (a `List` passed where a slice is expected,
#2539). A raw `ldelem` faults on the second, so index reads, index writes,
`for`-loop element reads and the per-element copy loop behind
`.slice`/`.concat`/`.append` all went through the non-generic
`IList.get_Item`/`set_Item`, boxing every primitive element. Every
byte-level stdlib path paid an allocation per byte.

## Decision

Keep both representations and test at each site (issue option 2):

- Index read: `isinst T[]` on the receiver; a hit reads with `ldelem.<T>`,
  a miss takes the existing `IList` path.
- Index write: the same test, then `stelem` or `IList.set_Item`.
- `for x in slice`: the test runs once before the loop; each iteration
  branches on the cached result.
- Slice copies (`emitSliceCopyLoopMsil`): when source and destination are
  both genuine `T[]`, one `System.Array.Copy` replaces the loop.

The fast path covers Int, Long, Double, Bool, Char, Byte and String
elements, the types with an array element token. Record and union elements
keep the `List<object>` path.

Making every `slice[primitive]` a real array (issue option 1) removes even
the type test, but it changes how a `List` passed to a slice parameter is
coerced at every call site and across the restored-package ABI. That is a
larger change than this fix needs, and the per-site `isinst` is a single
type-handle compare.

## Verification

- `slice_fastpath_self_test.l` covers reads, writes, `for` and copies over
  literals, `toArray()` results, sub-slices, concatenations, `encodeUtf8`
  output and `String.Split` arrays, for Int, Byte, String, Char, Bool, Long
  and Double. It passes on dotnet, JVM and native.
- The existing slice suites (`slice_ops`, `slice_array_abi`,
  `for_loop_slice`, `generic_slice`, `inout_slice`, `slice_string`,
  `slice_compound_assign_eval_order`, `slice_append_widening`,
  `slice_byte_lambda_arg`, `iface_slice_arg`) and the stdlib test programs
  pass on dotnet. The stage-1 compiler, which is itself compiled with the
  change, builds and bootstraps.
- A byte-indexing plus sub-slice-copy loop: 455 ms before, 25 ms after.
