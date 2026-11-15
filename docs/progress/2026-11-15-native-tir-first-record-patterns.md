# Native backend on TIR: TIR first, record patterns (docs/70 phase 4a, D520 slice 29)

`--via-tir` builds try the TIR lowering of each function first and lower from the AST only what TIR
refuses (the AST signature is derived without lowering the body). Record patterns lower from TIR in
`match` arms and destructuring `val`. `native-via-tir/recpat.l` lowers 5 of 5.
