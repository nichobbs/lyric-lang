# `@projectable` views are expanded to ordinary declarations before the check (docs/70 phase 3a, #8613)

**Status:** shipped; `Lyric.Projectable`, both backends.

## Context

`opaque type User @projectable` was the one place a backend invented declarations: the MSIL `lowerMOpaque` and the JVM `lowerProjectableType` each emitted a `<Name>View` class, a `toView()` method and a `tryInto()` method that the checker never saw, so `u.toView()` was an unchecked member call the typed IR (docs/70 section 6.3) could not build.

## Decision

`Lyric.Projectable.projectableRewriteFile` runs in `pipePrepareForCheck`, beside `Lyric.Stubbable`, on the managed targets, and appends ordinary declarations:

```
exposed record UserView { <fields not @hidden> }
func User.toView(self: in User): UserView = UserView(...)
func UserView.tryInto(self: in UserView): Result[User, String] = Ok(User(...))
```

- A `@projectionBoundary` field keeps its source type; a field whose type is another `@projectable` opaque type of the file (and is not a boundary) becomes `<FieldType>View`, and `toView` projects it with `.toView()`.
- `tryInto` is emitted only with no `@hidden` field and no nested projectable field, as before. It is Ok-only: rebuilding through the constructor runs the invariant as an assert (#7222), as the backend twins did not run it at all. The error type is `String`, the type the twins had; changing it is a separate decision.
- A generic opaque type is not projected (the twins never handled one).
- The generated source is parsed and respanned to the opaque type (`Expand.respanGenerated`); source that does not parse is I0006.
- Both backends drop their twin synthesis: MSIL `MOpaque.isProjectable`/masks, the `projectable*` context maps, `prescanProjectableFqns` and the view row pre-allocation; JVM `lowerProjectableType`, `LPProjectable`, `registerProjectableViews`, `allProjFqns` and the unused B117 `lowerProjectable`. A `@projectable` opaque now lowers like any other opaque type. Native still refuses `@projectable` (N0101).

## Results

`projectable_self_test.l` (the pass), `msil_self_test_m87.l` and `projectable_jvm_self_test.l` (runtime, both targets) pass unchanged.
