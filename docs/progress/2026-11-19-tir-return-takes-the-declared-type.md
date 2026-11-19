# docs/70 phase 3a: a bare `None` in a `return` takes the function's declared return type (D409)

`return None` in a generic function settles to the declared return type, as the body's tail does, so the body is no longer counted (I0002) (`Std.Task::runWithin` on the JVM). New shape `return_hole_in_generic`.
