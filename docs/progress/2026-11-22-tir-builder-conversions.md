# Builder conversions the TIR gate stopped (D746-D748)

A tuple literal converts element by element, a negated `Double` literal is a `Float` literal where a `Float` is wanted (D746), a function-valued binding keeps its built type and a union case's fields convert to the node's type (D747), and a package-qualified distinct factory builds (D748). Self-tests: `range_refinement`, `record_arith`, `distinct_ops`.
