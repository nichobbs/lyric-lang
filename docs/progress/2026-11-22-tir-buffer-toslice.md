# `buffer[T].toSlice()` is typed (D765)

A buffer's `.toSlice()` method call has the built-in member type an array's has, so the call is typed and the typed IR builder builds it. `buffer_self_test.l` builds.
