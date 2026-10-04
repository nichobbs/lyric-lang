# Native: by-value records cross the C boundary as C passes structs (#8009)

On `--target native` a record with no `var` field whose fields are all
values is an LLVM struct value (docs/67 §4.2). LLVM passes a first-class
aggregate argument field by field, which is not how C passes a struct, so an
`extern func` naming one was rejected (`N0010`). It is now declared and called
the way clang lowers the matching C prototype for the target:

- **x86-64 (System V).** A record of at most 16 bytes travels as one or two
  eightbytes, a `double` for one holding only floating-point fields (an SSE
  register) and an `i64` otherwise (a general register). A larger record, or
  one the remaining argument registers cannot hold, is `byval` memory. A
  result over 16 bytes comes back through an `sret` pointer.
- **AArch64 (AAPCS64).** A homogeneous aggregate of one to four `float`s or
  `double`s is an `[N x T]` in FP registers (returned as the record itself);
  any other record of at most 16 bytes is an `i64` or `[2 x i64]`; a larger
  one is passed as a pointer to a copy the caller makes and returned through
  `sret`.
- **wasm32 (the basic C ABI).** A record of a single scalar is that scalar;
  any other is `byval` and returned through `sret`.

A coerced record goes through a 16-byte stack buffer in the function's entry
block, so an eightbyte that runs past the end of the record never reads
beyond its storage.

Callbacks take the same form: a Lyric closure handed to C whose signature
carries a by-value record gets a trampoline that accepts the C-ABI form,
rebuilds each record, calls the closure, and returns the result as C
expects. `NParam` and `NArg` carry parameter attributes (`byval`, `sret`,
`align`, `alignstack`) for this.

`N0010` remains for what has no C equivalent (an inline `array[N, T]` or a
by-value union in an `extern func` signature) and for a by-value record on a
target the lowering does not cover; its messages now say which.

Tests: the new `llvm_c_abi_self_test.l` compiles C helpers with clang and
checks every value that crosses on the host (x86-64 in CI): a three-float
vector, `{double, int}`, a 32-byte record (memory class and `sret`), a
four-float aggregate, a padded `{byte, int, byte}`, a seventh record that no
longer fits the registers, callbacks from C into Lyric closures taking and
returning records (ASan), and 1000 calls in a loop (ASan). The AArch64,
wasm32 and x86-64 declarations are checked against what clang 18 emits for
the same prototypes.
