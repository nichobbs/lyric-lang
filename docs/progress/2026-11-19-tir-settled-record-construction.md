# docs/70 phase 3a: a generic record built where the checker left its arguments open builds at the settled type (D408)

A generic record constructed in a lambda whose parameter types the checker erased (`Std.Collections::mapEntries`) takes its fields from the type the node settled at, so the body is no longer counted (I0002). New shape `settled_record_ctor`.
