# docs/70 phase 3a: a local bound to an unchecked host result (D433)

A read of a local bound to a host result the checker leaves unchecked (`val v = m.computeIfAbsent(..)`) takes `CvFromHost` to the type the context wants, so the local's declared type and its reads agree and the verifier's `local-type` rule holds. This clears the one I0003 the wide self-tests census reported (`sam_detection_self_test.l`).
