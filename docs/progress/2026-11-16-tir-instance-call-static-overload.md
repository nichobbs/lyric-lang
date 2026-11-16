# 2026-11-16 - TIR builder: an instance call of a host method skips a same-named static overload (D479)

docs/70 phase 3a, #8613. `buildExternCall` prefers instance overloads when the receiver is a value, falling back to static ones only when none fits (the #6765 rule). Found by the self-tests census as an I0003 `call-result-type`; the fixture in `jvm_auto_ffi_bridge_self_test.l` now builds and verifies.
