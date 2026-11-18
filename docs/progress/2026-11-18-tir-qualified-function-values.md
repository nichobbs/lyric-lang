# docs/70 phase 3a: a function of another package used as a value through its alias or package path builds (D424)

`AL.update` (an import alias) and `Reg.Lib.update` (a package path) record the function reference under their node as a bare `update` does, so the bodies using them are no longer counted (I0002).
