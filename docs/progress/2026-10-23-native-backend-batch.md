# Native backend and kernel batch: wrong results, compiler panics and missing kernels

A batch of `--target native` fixes, each with a regression test (native
self-tests compile with `-fsanitize=address`).

**Silent wrong results**

- `Char.toString()` and `"" + c` on an element of a `slice[Char]`, `List[Char]`
  or `array[N, Char]` binding printed the code point (#7339): `Char` and `Int`
  share the erased `i32`, and the best-effort `Char` tracking now records a
  binding's Char-collection annotation, so `cs[i]` is known to be a `Char`.
- `o == None`, `None == o` and `o != None` took no type arguments for the bare
  generic case (#8014); the other operand's type now flows into it.
- `NativeWeak.upgrade()` resolved to the first union named `Option` in the
  bundle (#7922); it now resolves `Std.Core.Option`.

**Compiler panics and missing lowering**

- `String.substring(start)` (#8335), `List.contains`/`indexOf` for every
  element type (#7429; a synthesised linear scan comparing under the D172
  relation), `for (k, v) in pairs` over a list of tuples (#8348), a method
  call on a captured `List` inside a lambda (#8330: the capture walk now
  sees the receiver of a dotted callee), and a record-body method beside a
  top-level dot-named function of the same name and arity (#8360: the body
  method owns its own symbol; D181) lower.
- A single-file native build brings `Std.Core` into the bundle without an
  import, as the managed targets do (#8256).
- `formatN` inside a bundled `Std.*` package is lowered (#7984).
- A `config { }` block is rejected with `N0025` instead of an unhandled
  codegen exception (#7435, the lowering itself stays open).

**Kernels**

- `Std.Hash` runs on native: `sha512OfFile` no longer needs `try`/`catch`; it
  goes through a `hostSha512FileResult` seam in all three kernels (#7684).
  `hash_tests.l` runs in the native smoke test.
- `Std.Char` classifies and case-maps every code point on native from a
  generated Unicode 17.0.0 general-category table in lyric-rt
  (`scripts/gen_unicode_category_tables.py`), replacing the ASCII-only twin
  (#6858). `char_native_tests.l` covers Latin-1, Greek, Han, titlecase,
  C1 controls and case mapping.
- A missing executable under the captured runs (`Std.Process.runCapture`,
  `runCaptureWithInput`, the async capture) is a spawn failure, not exit code
  127: `runCapture` returns `Err`, `Std.ProcessCapture` reports exit code `-1`
  with empty output, matching the managed targets and `CaptureResult`'s
  contract (#7968). A program that really exits 127 still reports 127. The
  fork child reports a failed `execvp` to the parent through a close-on-exec
  pipe, as the inherited-stdio run already did.
- The `ok` out-flags of `lyric_file_read_bytes`, `lyric_dir_list2` and
  `lyric_dir_list_typed` are `int64_t*`, written through `NativePtr[Long]`
  (#4845). The old report of a codegen bug in `nativeAddrOf` was a width
  mismatch: a native `Int` is 32-bit, so an 8-byte kernel write through the
  address of a `var ok: Int` ran into the next stack slot.
- `Std.Random` has a native test (`random_native_tests.l`) beside the
  existing `Std.SecureRandom` and `Std.Task` ones (#7667, #7664).

Already fixed on `main`, verified and closed: #6901, #7637, #8315 (and #7664,
#7667 apart from the new Random test).
