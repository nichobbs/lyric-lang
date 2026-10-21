# `Std.Linalg`: vectors, matrices, quaternions, colours (docs/67 G6, #7945, D198)

- `lyric-stdlib/std/linalg.l`: `Vec2`/`Vec3`/`Vec4`, `Quat`, `Mat3`, `Mat4`, `Rgba8`, registered in
  the stdlib bundle manifest.
- `lyric-stdlib/tests/linalg_tests.l`: 12 tests (derive arithmetic, dot/cross/normalize, lerp and
  reflect, matrix products and inverses, rotations, quaternions vs matrices, projections and
  `lookAt`, `Mat3` 2D transforms, colours), run on dotnet, the JVM and native.
- Native: the `Std.String.normalize` / `isNormalized` bodies trap at run time instead of failing
  the build when merely reachable.
- Docs: D198, docs/67 §4.6 and status, book chapter 12.
