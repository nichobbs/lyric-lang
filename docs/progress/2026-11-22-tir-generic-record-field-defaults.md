# Builder: the field defaults of a generic record (D740)

A generic record's field defaults that mention none of its parameters are carried in its interface, so `Box(item = 1)` in another package takes `policy = lenientRetry()`. Self-test: `llvm_project_self_test.l` (native).
