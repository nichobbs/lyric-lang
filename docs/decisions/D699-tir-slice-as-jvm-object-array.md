# A slice is passed as the JVM's Object[] (docs/70 phase 3a, #8613; extends D472)

**Status:** shipped.

## Context

D472 let a host array parameter that names its element take a slice of that element, and an `Object[]` take a slice of host values. A slice of `Int` passed for a varargs `Object[]` (`Arrays.asList(slice[Int])`, `Objects.hash(slice[Int])`, `String.format(String, slice[Int])`) stayed "an extern call no host overload fits", although `auto_ffi_jvm_self_test` runs them. The JVM backend's resolver accepts the match (`Jvm.AutoFfi`, #6696) because a Lyric slice's runtime representation is always an `Object[]` of boxed elements, whatever its element type: the call passes the slice itself, with no per-element conversion.

## Decision

`hostBoxKind` accepts a slice of any element for the host array of `java.lang.Object` and records it as `CvBoxToHost` on the host array, as D472 does for the other host arrays. The conversion names what the backend does: the elements are already boxed, so the slice is the host array. D472 stays as written; this extends its `Object[]` rule from host-value slices to every slice.

- An `array[N, T]` is not included: a fixed array is not an `Object[]`.
- The CLR's `object[]` is not included: a slice is not an `object[]` there.
- A host method that also has an overload for the slice's own primitive array (`Arrays.copyOf(int[], int)` against `copyOf(T[], int)`) still takes the exact element match, which scores above a boxing, so D472's `int[]` resolution is unchanged.

## Consequences

`auto_ffi_jvm_self_test` builds `Arrays.asList`, `Objects.hash` and `String.format` over a slice. The D472 assertion "an Int slice is not a host Object[]" is replaced by its opposite, with the two exclusions above asserted.
