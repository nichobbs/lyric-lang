# 2026-11-13 - TIR: host property reads and writes (D598)

`recv.name` on a host value builds as a call of the property getter (`HMPropertyGet`, or `HMFieldGet` for a public field)
and `recv.name = v` as a call of the setter (`HMPropertySet`) of type `Unit`, from the host metadata. `ExternMemberSig` and
`HostMemberSigInfo` gain `isField`. The uncovered messages for member access, assignment to a member and extern calls with
no fitting overload now name the site. Tests: `tir_build_self_test.l` (read, write, compound assignment counted).
