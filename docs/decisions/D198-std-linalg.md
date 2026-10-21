# D198 - `Std.Linalg`: vectors, matrices, quaternions and colours

**Status:** accepted, implemented on dotnet, the JVM and native (docs/67 phase G6, §4.6, #7945); refines D155 item 8

## Decision

1. **Package name.** The types live in `Std.Linalg` (`lyric-stdlib/std/linalg.l`), not in
   `Std.Math` as docs/67 §4.6 first wrote. `Std.Math` is the `Double` surface over the kernel
   boundary (`@externTarget` trampolines); the by-value `Float` records are a separate concern with
   a separate import, and keeping them out of `Std.Math` leaves its audited kernel surface alone.
2. **Types.** `Vec2`, `Vec3`, `Vec4`, `Quat`, `Mat3`, `Mat4` (column-major `array[N, Float]`) and
   `Rgba8` (four `Byte`s). All are records without `var` fields, so they are inline values on
   native and heap objects on dotnet and the JVM (D157). `Vec2`/`Vec3`/`Vec4` derive component-wise
   `+` and `-` (D155); everything else is a dot-named method (`a.dot(b)`, `m.mul(n)`), which is
   the spelling the language already has and needs no operator overloading.
3. **Conventions.** They match WebGPU/WGSL so a `Mat4` uploads as it is: column-major storage,
   right-handed coordinates with a view looking down -Z, clip-space depth 0 to 1 in `perspective`
   and `orthographic`, angles in radians. `a.mul(b)` applies `b` first.
4. **Partial operations.** `normalize` of a zero vector returns the zero vector (and of a zero
   quaternion the identity); `inverse` returns `Option` (`None` when singular).
   `perspective` and `orthographic` carry `requires:` clauses.
5. **Native reachability fix.** Native reachability marks a function by its bare trailing name, so
   a program importing `Std.String` that called any `x.normalize()` (this module's `Vec3.normalize`
   among them) also pulled in `Std.String.normalize`, whose body hit the compile-time "not yet
   supported" panic (#7304). Inside `Std.String` that failure is now a runtime trap with the same
   message; a `.normalize()` on a `String` receiver anywhere else is still the compile-time error.

## Not in this slice

SIMD (docs/04 stands: no intrinsics), a GPU-side `Plain` layout check for `Mat4` uniforms beyond
what `buffer[T]` gives, and `Mat2`/double-precision variants.
