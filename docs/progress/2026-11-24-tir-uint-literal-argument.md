# An unsuffixed literal above Int's range builds as a UInt argument (D501)

`convertValue` in `Lyric.Tir.Build` retypes an integer literal the checker typed `Long` (a value above `Int`'s range, such as `3000000000`) to `UInt`, `ULong` or `Byte` when it fits, as it already did for `Int` literals. Fixes `lyric build --target native` rejecting `f(200u8, 3000000000)` with I0002. Test: `tir_build_self_test.l`.
