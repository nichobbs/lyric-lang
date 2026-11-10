# TIR: a documented or annotated function finds its symbol (D554, #8613)

`symTableFuncSymOf` matched an item span against a declaration span, so a function with a doc
comment or annotation had no symbol and its body was never built. It now compares declaration
spans. Census: bodies built 969 -> 992 of 1165, I0003 0, both "no symbol" kinds 0.
