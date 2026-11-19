# docs/70 phase 3a: a pointer in one spelling of a callback's userdata slot used as the other is `CvUserdataSlot` (D427)

`nativeKeepCallback(f)`'s `NativePtr[Byte]` passed where a `NativeUserdata` is declared (or back) converts with `CvUserdataSlot`, so the body is no longer counted (I0002).
