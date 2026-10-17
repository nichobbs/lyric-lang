# D-progress-1051: `.toNat()` and bare `None` branches on the native backend

**Status:** shipped (closes the two native gaps D-progress-1050 disclosed, #8366 and #8363)

## Decision

1. `.toNat()` lowers on `--target native` with the checked behaviour `--target dotnet` has.
   `Nat` lowers as `i64` (D-progress-1050), so `Byte` zero-extends and `Char` (an `i32`
   holding 0..65535) sign-extends with no check; `Int` sign-extends and `Long` is used as is,
   each trapping when negative; `Double` traps unless it is greater than -1.0 (an ordered
   compare, so NaN traps too) and then truncates toward zero, so -0.5 is the `Nat` 0; `Float`
   converts as the `Double` it widens to. The trap is `lyric_panic_msg` with
   `toNat: value must be non-negative`, the text the MSIL backend throws. That text moves to
   `Lyric.Lexer.toNatRangeMessage`, next to `toCharRangeMessage`, so both backends share it.
   `--target jvm` still has no `.toNat()` (#7661).
2. A value-producing `if` or `match` with no expected type (an unannotated `val`) lowers a
   branch whose value is a bare generic union case (`None`), or an `if`/`match` made only of
   such branches, after its siblings, and passes it the type the first value-producing
   sibling fixed. Before this the branch was lowered with no expected type and failed with
   "cannot infer the type arguments of generic union case 'None'". Each branch, and each
   match arm with its pattern test, now lowers into its own instruction list, appended in
   source order, so the lowering order does not change the emitted control flow. With an
   expected type, or with no bare-case branch, the order is the source order as before.
3. The three `Option[String]` annotations added to `HttpClientBuilder.build()` as a
   workaround in D-progress-1050 are removed.

## Tests

`llvm_stdlib_self_test.l` (ASan): `.toNat()` from `Byte`, `Int`, `Long`, `Char`, `Double`
and `Float` receivers; the panic on a negative `Int`, `Long` and `Double` and on NaN; the
`Std.Stream.TextReader` impl test now calls `readToEnd(10.toNat())` through the vtable; and
unannotated `if`, `else if` and `match` bindings mixing `Some(...)` and `None` in either
order, including a block branch.
