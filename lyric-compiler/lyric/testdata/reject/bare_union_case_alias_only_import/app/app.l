package App

import Lib as L

// An aliased import makes no name of the package bare (docs/70 §4.3, #8722):
// `Timeout` is `L.Timeout`, so the bare case constructor is unknown.
func main(): Unit {
  println(L.describe(Timeout(message = "slow")))
}
